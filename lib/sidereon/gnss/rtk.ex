defmodule Sidereon.GNSS.RTK do
  @moduledoc """
  RTK-facing carrier/code double-difference primitives.

  A base receiver and a rover receiver observing the same satellites have
  receiver-clock terms that differ by station but are common to every satellite.
  A *single difference* subtracts base from rover for the same satellite; a
  *double difference* subtracts a reference satellite's single difference:

      DD_s = (rover_s - base_s) - (rover_ref - base_ref)

  The receiver clocks cancel in the second subtraction. Satellite-clock,
  ephemeris, and short-baseline atmosphere errors that are common between base
  and rover also cancel in the receiver single difference. The remaining
  carrier-phase double differences are the measurement surface used by RTK
  baseline estimation and integer ambiguity fixing.

  `double_differences/3` returns normalized measurements. `solve_rtk_float/1`
  and `solve_rtk_fixed/1` operate on already prepared RTK epochs.

  ## Example

      iex> base = [
      ...>   {"G01", 20_100.0, 20_103.0},
      ...>   {"G02", 21_105.0, 21_110.0}
      ...> ]
      iex> rover = [
      ...>   {"G01", 20_040.0, 20_044.0},
      ...>   {"G02", 21_060.0, 21_066.0}
      ...> ]
      iex> {:ok, result} = Sidereon.GNSS.RTK.double_differences(base, rover, reference_satellite_id: "G01")
      iex> result.double_differences
      [%{satellite_id: "G02", reference_satellite_id: "G01", ambiguity_id: "G02", code_m: 15.0, phase_m: 17.0}]
  """
  alias Sidereon.GeometryQuality
  alias Sidereon.GNSS.Antex
  alias Sidereon.GNSS.Core.AntennaTerms
  alias Sidereon.GNSS.Core.Observations
  alias Sidereon.GNSS.Core.Types
  alias Sidereon.GNSS.RINEX.Observations, as: RinexObservations
  alias Sidereon.GNSS.SP3
  alias Sidereon.NIF

  # Sourced from the canonical core defaults (`sidereon_core::rtk_filter::defaults`,
  # mirrored by `Sidereon.NIF.core_defaults/0`). `test/constants_test.exs` pins the
  # core values and `test/gnss_rtk_test.exs` checks the default flows through the
  # solve metadata, so the binding default cannot drift from the core.
  @default_code_sigma_m 0.3
  @default_phase_sigma_m 0.003
  @default_max_iterations 10
  @default_position_tolerance_m 1.0e-4
  @default_ambiguity_tolerance_m 1.0e-4
  @default_integer_ratio_threshold 3.0
  @default_partial_min_ambiguities 4
  @default_max_residual_exclusions 1
  @default_prior_sigma_m 30.0
  @gap_reference ~N[2000-01-01 00:00:00]
  @min_elevation_sin 0.05
  @double_difference_options [:reference_satellite_id]
  defmodule FloatBaselineSolution do
    @moduledoc """
    Float RTK baseline solution from code/carrier double differences.
    """

    @enforce_keys [
      :baseline_m,
      :rover_position_m,
      :reference_satellite_id,
      :used_sats,
      :ambiguities_m,
      :residuals_m,
      :metadata
    ]
    defstruct [
      :baseline_m,
      :rover_position_m,
      :reference_satellite_id,
      :used_sats,
      :ambiguities_m,
      :residuals_m,
      :metadata
    ]

    @type ecef :: %{x_m: float(), y_m: float(), z_m: float()}

    @type residual :: %{
            epoch: term(),
            satellite_id: String.t(),
            reference_satellite_id: String.t(),
            ambiguity_id: String.t(),
            code_m: float(),
            phase_m: float(),
            code_sigma_m: float(),
            phase_sigma_m: float(),
            code_normalized: float(),
            phase_normalized: float()
          }

    @type t :: %__MODULE__{
            baseline_m: ecef(),
            rover_position_m: ecef(),
            reference_satellite_id: String.t() | %{String.t() => String.t()},
            used_sats: [String.t()],
            ambiguities_m: %{String.t() => float()},
            residuals_m: [residual()],
            metadata: %{
              iterations: pos_integer(),
              converged: boolean(),
              status: :state_tolerance | :max_iterations,
              physical_sats: [String.t()],
              reference_satellites: %{String.t() => String.t()},
              ambiguity_satellites: %{String.t() => String.t()},
              ambiguity_float: %{
                order: [String.t()],
                covariance_m: [[float()]],
                covariance_inverse_m: [[float()]]
              },
              measurement_covariance: %{
                model: :double_difference,
                code_sigma_m: float(),
                phase_sigma_m: float(),
                stochastic_model: :simple | :rtklib,
                elevation_weighting: boolean(),
                sagnac: boolean(),
                min_elevation_sin: float()
              },
              code_rms_m: float(),
              phase_rms_m: float(),
              weighted_rms_m: float(),
              geometry_quality: GeometryQuality.t(),
              n_epochs: pos_integer(),
              n_observations: pos_integer(),
              dropped_sats: [String.t()],
              dropped_cycle_slip_sats: [String.t()],
              elevation_mask_deg: float() | nil,
              elevation_masked_sats: [String.t()],
              split_cycle_slip_arcs: [map()]
            }
          }
  end

  defmodule FixedBaselineSolution do
    @moduledoc """
    Integer-fixed RTK baseline solution from code/carrier double differences.
    """

    @enforce_keys [
      :baseline_m,
      :rover_position_m,
      :reference_satellite_id,
      :used_sats,
      :fixed_ambiguities_cycles,
      :fixed_ambiguities_m,
      :float_solution,
      :residuals_m,
      :metadata
    ]
    defstruct [
      :baseline_m,
      :rover_position_m,
      :reference_satellite_id,
      :used_sats,
      :fixed_ambiguities_cycles,
      :fixed_ambiguities_m,
      :float_solution,
      :residuals_m,
      :metadata
    ]

    @type ecef :: %{x_m: float(), y_m: float(), z_m: float()}

    @type t :: %__MODULE__{
            baseline_m: ecef(),
            rover_position_m: ecef(),
            reference_satellite_id: String.t() | %{String.t() => String.t()},
            used_sats: [String.t()],
            fixed_ambiguities_cycles: %{String.t() => integer()},
            fixed_ambiguities_m: %{String.t() => float()},
            float_solution: FloatBaselineSolution.t(),
            residuals_m: [FloatBaselineSolution.residual()],
            metadata: %{
              required(:iterations) => pos_integer(),
              required(:converged) => boolean(),
              required(:status) => :state_tolerance | :max_iterations,
              required(:integer_status) => :fixed | :not_fixed,
              required(:integer_method) => :lambda,
              required(:integer_ratio) => float() | :infinity,
              required(:integer_best_score) => float(),
              required(:integer_second_best_score) => float() | nil,
              required(:integer_candidates) => pos_integer(),
              required(:code_rms_m) => float(),
              required(:phase_rms_m) => float(),
              required(:weighted_rms_m) => float(),
              required(:n_epochs) => pos_integer(),
              required(:n_observations) => pos_integer(),
              required(:measurement_covariance) => %{
                model: :double_difference,
                code_sigma_m: float(),
                phase_sigma_m: float(),
                stochastic_model: :simple | :rtklib,
                elevation_weighting: boolean(),
                sagnac: boolean(),
                min_elevation_sin: float()
              },
              required(:ambiguity_search) => %{
                order: [String.t()],
                float_cycles: %{String.t() => float()},
                covariance_cycles: [[float()]],
                covariance_inverse_cycles: [[float()]]
              },
              required(:ambiguity_offsets_m) => %{String.t() => float()},
              optional(:physical_sats) => [String.t()],
              optional(:reference_satellites) => %{String.t() => String.t()},
              optional(:ambiguity_satellites) => %{String.t() => String.t()},
              optional(:partial_ambiguity_resolution) => boolean(),
              optional(:partial_fixed) => boolean(),
              optional(:partial_fixed_ambiguities) => [String.t()],
              optional(:partial_free_ambiguities) => [String.t()],
              optional(:partial_full_set) => map(),
              optional(:dropped_cycle_slip_sats) => [String.t()],
              optional(:elevation_mask_deg) => float() | nil,
              optional(:elevation_masked_sats) => [String.t()],
              optional(:split_cycle_slip_arcs) => [map()]
            }
          }
  end

  defmodule StaticReferenceStationCovariance do
    @moduledoc """
    Position covariance blocks for a static reference-station coordinate.
    """

    @enforce_keys [:position_ecef_m2, :position_enu_m2]
    defstruct [:position_ecef_m2, :position_enu_m2]

    @type t :: %__MODULE__{
            position_ecef_m2: [[float()]],
            position_enu_m2: [[float()]]
          }
  end

  defmodule StaticReferenceEpochDiagnostic do
    @moduledoc """
    Per-epoch diagnostic row from a static reference-station mode.
    """

    @enforce_keys [
      :mode,
      :epoch_index,
      :used_satellites,
      :rejected_satellite_count,
      :code_residual_rms_m,
      :phase_residual_rms_m,
      :residual_rms_m
    ]
    defstruct [
      :mode,
      :epoch_index,
      :used_satellites,
      :rejected_satellite_count,
      :code_residual_rms_m,
      :phase_residual_rms_m,
      :residual_rms_m
    ]

    @type t :: %__MODULE__{
            mode: :code_dgnss | :carrier_float | :carrier_fixed,
            epoch_index: non_neg_integer(),
            used_satellites: [String.t()],
            rejected_satellite_count: non_neg_integer(),
            code_residual_rms_m: float() | nil,
            phase_residual_rms_m: float() | nil,
            residual_rms_m: float() | nil
          }
  end

  defmodule StaticReferenceModeReport do
    @moduledoc """
    Per-mode attempt report for the static reference-station solver.
    """

    @enforce_keys [:mode, :status, :used_epochs, :skipped_epochs, :used_measurements, :error]
    defstruct [:mode, :status, :used_epochs, :skipped_epochs, :used_measurements, :error]

    @type mode_error ::
            {:rinex_assembly, String.t(), String.t()}
            | :no_matched_code_epochs
            | {:code_dgnss, String.t()}
            | {:static_solve, String.t()}
            | {:carrier_arc, String.t()}
            | {:carrier_solve, String.t()}
            | {:frame, String.t(), String.t()}
            | {:corrected_observation, String.t()}
            | {:invalid_corrected_satellite_id, String.t()}

    @type t :: %__MODULE__{
            mode: :code_dgnss | :carrier_float | :carrier_fixed,
            status: :solved | :failed,
            used_epochs: non_neg_integer(),
            skipped_epochs: non_neg_integer(),
            used_measurements: non_neg_integer(),
            error: mode_error() | nil
          }
  end

  defmodule StaticReferenceCodeSolution do
    @moduledoc """
    Code-DGNSS detail from a static reference-station solve.
    """

    @enforce_keys [:position_m, :geodetic, :covariance, :baseline_vector_m, :baseline_m, :diagnostics]
    defstruct [:position_m, :geodetic, :covariance, :baseline_vector_m, :baseline_m, :diagnostics]

    @type t :: %__MODULE__{
            position_m: ecef(),
            geodetic: map() | nil,
            covariance: StaticReferenceStationCovariance.t(),
            baseline_vector_m: ecef(),
            baseline_m: float(),
            diagnostics: [StaticReferenceEpochDiagnostic.t()]
          }

    @type ecef :: %{x_m: float(), y_m: float(), z_m: float()}
  end

  defmodule StaticReferenceCarrierSolution do
    @moduledoc """
    Carrier RTK detail from a static reference-station solve.
    """

    @enforce_keys [
      :position_m,
      :geodetic,
      :covariance,
      :baseline_vector_m,
      :baseline_m,
      :integer_status,
      :integer_ratio,
      :diagnostics
    ]
    defstruct [
      :position_m,
      :geodetic,
      :covariance,
      :baseline_vector_m,
      :baseline_m,
      :integer_status,
      :integer_ratio,
      :diagnostics
    ]

    @type t :: %__MODULE__{
            position_m: ecef(),
            geodetic: map() | nil,
            covariance: StaticReferenceStationCovariance.t(),
            baseline_vector_m: ecef(),
            baseline_m: float(),
            integer_status: :fixed | :not_fixed,
            integer_ratio: float() | nil,
            diagnostics: [StaticReferenceEpochDiagnostic.t()]
          }

    @type ecef :: %{x_m: float(), y_m: float(), z_m: float()}
  end

  defmodule StaticReferenceStationSolution do
    @moduledoc """
    Static reference-station coordinate with covariance and mode diagnostics.
    """

    @enforce_keys [
      :mode,
      :fix_status,
      :position_m,
      :geodetic,
      :covariance,
      :baseline_vector_m,
      :baseline_m,
      :code_solution,
      :carrier_solution,
      :mode_reports,
      :diagnostics
    ]
    defstruct [
      :mode,
      :fix_status,
      :position_m,
      :geodetic,
      :covariance,
      :baseline_vector_m,
      :baseline_m,
      :code_solution,
      :carrier_solution,
      :mode_reports,
      :diagnostics
    ]

    @type t :: %__MODULE__{
            mode: :code_dgnss | :carrier_float | :carrier_fixed,
            fix_status: :code_dgnss | :carrier_float | :carrier_fixed,
            position_m: ecef(),
            geodetic: map() | nil,
            covariance: StaticReferenceStationCovariance.t(),
            baseline_vector_m: ecef(),
            baseline_m: float(),
            code_solution: StaticReferenceCodeSolution.t() | nil,
            carrier_solution: StaticReferenceCarrierSolution.t() | nil,
            mode_reports: [StaticReferenceModeReport.t()],
            diagnostics: [StaticReferenceEpochDiagnostic.t()]
          }

    @type ecef :: %{x_m: float(), y_m: float(), z_m: float()}
  end

  @typedoc """
  Code and carrier-phase observation in metres.

  Map observations may optionally carry `:ambiguity_id` to identify a carrier
  arc and `:lli` (or `:loss_of_lock_indicator`) for single-frequency
  loss-of-lock handling. Tuple observations use the satellite id as the
  ambiguity id and have no LLI.
  """
  @type observation ::
          %{
            required(:satellite_id) => String.t(),
            required(:code_m) => number(),
            required(:phase_m) => number(),
            optional(:ambiguity_id) => String.t(),
            optional(:lli) => integer() | nil,
            optional(:loss_of_lock_indicator) => integer() | nil
          }
          | {String.t(), number(), number()}

  @typedoc "ECEF position in metres."
  @type ecef_input ::
          {number(), number(), number()} | %{x_m: number(), y_m: number(), z_m: number()}

  @typedoc "Satellite ECEF position keyed by satellite id."
  @type satellite_positions :: %{required(String.t()) => ecef_input()}

  @typedoc """
  One RTK epoch carrying paired base/rover observations and satellite positions.

  `:epoch` is preserved in residual diagnostics; it is not interpreted by this
  first solver layer because satellite positions are supplied by the caller.
  `:satellite_positions_m` is used for satellite selection and elevation
  weighting. When the caller has receiver-specific transmit-time positions, it
  may also provide `:base_satellite_positions_m` and
  `:rover_satellite_positions_m`; otherwise both default to
  `:satellite_positions_m`.
  """
  @type baseline_epoch :: %{
          required(:base_observations) => [observation()],
          required(:rover_observations) => [observation()],
          required(:satellite_positions_m) => satellite_positions(),
          optional(:base_satellite_positions_m) => satellite_positions(),
          optional(:rover_satellite_positions_m) => satellite_positions(),
          optional(:velocity_mps) => ecef_input(),
          optional(:epoch) => term()
        }

  @typedoc """
  Raw dual-frequency code/carrier observation for wide-lane/narrow-lane RTK.

  `p1_m` / `p2_m` are code pseudoranges in metres, `phi1_cyc` / `phi2_cyc` are
  carrier phases in cycles, and `f1_hz` / `f2_hz` are the corresponding carrier
  frequencies. `:ambiguity_id` is normally omitted; the wide-lane solver sets it
  internally when `:on_cycle_slip` is `:split_arc`.
  """
  @type dual_frequency_observation :: %{
          required(:satellite_id) => String.t(),
          required(:p1_m) => number(),
          required(:p2_m) => number(),
          required(:phi1_cyc) => number(),
          required(:phi2_cyc) => number(),
          required(:f1_hz) => number(),
          required(:f2_hz) => number(),
          optional(:ambiguity_id) => String.t(),
          optional(:lli1) => integer() | nil,
          optional(:lli2) => integer() | nil
        }

  @typedoc "One RTK epoch carrying raw dual-frequency base/rover observations."
  @type dual_frequency_baseline_epoch :: %{
          required(:base_observations) => [dual_frequency_observation()],
          required(:rover_observations) => [dual_frequency_observation()],
          required(:satellite_positions_m) => satellite_positions(),
          optional(:base_satellite_positions_m) => satellite_positions(),
          optional(:rover_satellite_positions_m) => satellite_positions(),
          optional(:epoch) => term()
        }

  @typedoc "One non-reference satellite's double-difference observation."
  @type double_difference :: %{
          satellite_id: String.t(),
          reference_satellite_id: String.t(),
          ambiguity_id: String.t(),
          code_m: float(),
          phase_m: float()
        }

  @typedoc "Double-difference result with deterministic satellite ordering."
  @type result :: %{
          reference_satellite_id: String.t(),
          double_differences: [double_difference()],
          dropped_sats: [String.t()]
        }

  @doc """
  Solve a static float RTK baseline from normalized RTK epochs.
  """
  @spec solve_rtk_float(map()) :: {:ok, FloatBaselineSolution.t()} | {:error, term()}
  def solve_rtk_float(config) when is_map(config) do
    with {:ok, epochs} <- direct_epochs(config),
         {:ok, base} <- direct_base(config),
         {:ok, ambiguity_ids} <- direct_ambiguity_ids(config),
         {:ok, initial_baseline} <- direct_initial_baseline(config),
         {:ok, model} <- direct_model(config),
         {:ok, weights} <- direct_weights(config),
         {:ok, float_opts} <- direct_float_opts(Map.get(config, :options, %{}), initial_baseline),
         {:ok, receiver_antenna_corrections} <- direct_receiver_antenna_corrections(config) do
      case NIF.rtk_solve_float(
             Enum.map(epochs, &rtk_epoch_term/1),
             base,
             ambiguity_ids,
             initial_baseline,
             model,
             float_opts,
             receiver_antenna_corrections
           ) do
        {:ok, term} ->
          decode_rtk_float_solution(
            term,
            base,
            static_decode_epochs(epochs),
            direct_references(epochs),
            direct_physical_sats(epochs),
            ambiguity_ids,
            Map.new(ambiguity_ids, &{&1, &1}),
            weights,
            direct_preprocess_meta()
          )

        {:error, reason} ->
          {:error, reason}
      end
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Solve a static integer-fixed RTK baseline from normalized RTK epochs.
  """
  @spec solve_rtk_fixed(map()) :: {:ok, FixedBaselineSolution.t()} | {:error, term()}
  def solve_rtk_fixed(config) when is_map(config) do
    with {:ok, epochs} <- direct_epochs(config),
         {:ok, base} <- direct_base(config),
         {:ok, ambiguity_ids} <- direct_ambiguity_ids(config),
         {:ok, ambiguity_satellites} <- direct_string_map(config, :ambiguity_satellites),
         {:ok, wavelengths_m} <- direct_number_map(config, :wavelengths_m),
         {:ok, offsets_m} <- direct_number_map(config, :offsets_m),
         {:ok, initial_baseline} <- direct_initial_baseline(config),
         {:ok, model} <- direct_model(config),
         {:ok, weights} <- direct_weights(config),
         {:ok, float_opts} <- direct_float_opts(Map.get(config, :float_options, %{}), initial_baseline),
         {:ok, fixed_opts} <-
           direct_fixed_opts(Map.get(config, :fixed_options, %{}), Map.get(config, :float_only_systems, [])),
         {:ok, residual_opts} <- direct_residual_opts(Map.get(config, :residual_options, %{})),
         {:ok, float_only_systems} <- direct_float_only_systems(Map.get(config, :float_only_systems, [])),
         {:ok, receiver_antenna_corrections} <- direct_receiver_antenna_corrections(config) do
      case NIF.rtk_solve_fixed(
             Enum.map(epochs, &rtk_epoch_term/1),
             base,
             ambiguity_ids,
             Map.to_list(ambiguity_satellites),
             Map.to_list(wavelengths_m),
             Map.to_list(offsets_m),
             float_only_systems,
             initial_baseline,
             model,
             float_opts,
             fixed_opts,
             residual_opts,
             receiver_antenna_corrections
           ) do
        {:ok, {float_term, fixed_term, validation_term, used_ids, used_satellite_terms}} ->
          used_satellites = Map.new(used_satellite_terms)
          used_physical_sats = used_satellites |> Map.values() |> Enum.uniq() |> Enum.sort()

          with {:ok, float_solution} <-
                 decode_rtk_float_solution(
                   float_term,
                   base,
                   static_decode_epochs(epochs),
                   direct_references(epochs),
                   used_physical_sats,
                   used_ids,
                   used_satellites,
                   weights,
                   direct_preprocess_meta()
                 ),
               {:ok, fixed_solution} <-
                 decode_rtk_fixed_solution(
                   fixed_term,
                   base,
                   static_decode_epochs(epochs),
                   direct_references(epochs),
                   used_physical_sats,
                   used_ids,
                   used_satellites,
                   weights,
                   float_solution
                 ) do
            {:ok,
             %{
               fixed_solution
               | metadata:
                   maybe_put_residual_validation(
                     fixed_solution.metadata,
                     validation_term,
                     static_decode_epochs(epochs)
                   )
             }}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Solve a sequential RTK baseline arc from raw rover+base epochs, delegating the
  whole driver (epoch normalization, reference selection, sequential filter, and
  per-epoch ambiguity search) to the `sidereon-core` `solve_rtk_arc` kernel.

  This is a thin delegation to the core arc driver. `epochs` is a list of raw
  epoch maps:

    * `:base`, `:rover` - lists of observation maps
      `%{satellite_id:, ambiguity_id:, code_m:, phase_m:}`
    * `:satellite_positions_m` - `%{satellite_id => {x, y, z}}` shared-position map
    * `:base_satellite_positions_m`, `:rover_satellite_positions_m` - optional
      per-receiver transmit-time position maps (default to the shared map)
    * `:velocity_mps` - optional rover ECEF velocity `{vx, vy, vz}`
    * `:prediction_time_s` - optional epoch time coordinate

  `config` is a map:

    * `:base_m` - base station ECEF `{x, y, z}`
    * `:reference` - `:auto` (default), `{:satellite, id}`, or
      `{:per_system, %{letter => id}}`
    * `:model` - `%{code_sigma_m:, phase_sigma_m:, stochastic_model:,
      elevation_weighting?:, sagnac?:}`
    * `:baseline_prior_sigma_m`, `:ambiguity_prior_sigma_m`
    * `:initial_baseline_m` - `{x, y, z}` (default `{0, 0, 0}`)
    * `:wavelengths_m`, `:offsets_m` - `%{ambiguity_id => value}`
    * `:update_opts` - the per-epoch update controls (see `arc_update_opts`)

  Returns `{:ok, solution}` with `:references`, per-epoch `:epochs`, and the
  carried `:final_state`, or `{:error, reason}`. Each epoch map includes
  `:geometry_quality`.
  """
  @spec solve_arc([map()], map()) :: {:ok, map()} | {:error, term()}
  def solve_arc(epochs, config) when is_list(epochs) and is_map(config) do
    case NIF.rtk_solve_arc(Enum.map(epochs, &arc_epoch_term/1), arc_config_term(config)) do
      {:ok, solution} -> {:ok, decode_arc_solution(solution)}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Solve a static RTK arc with a typed core-style configuration map.

  The returned map includes `:geometry_quality` for the static batch design.
  """
  @spec solve_static_arc([map()], map()) :: {:ok, map()} | {:error, term()}
  def solve_static_arc(epochs, config) when is_list(epochs) and is_map(config) do
    case NIF.rtk_solve_static_arc(Enum.map(epochs, &arc_epoch_term/1), static_arc_config_term(config)) do
      {:ok, solution} -> {:ok, decode_static_arc_solution(solution)}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Fix wide-lane RTK arc ambiguities by delegating to the core arc helper.

  The returned map includes `:geometry_quality` for the wide-lane ambiguity
  design.
  """
  @spec fix_wide_lane_rtk_arc([dual_frequency_baseline_epoch()], map()) :: {:ok, map()} | {:error, term()}
  def fix_wide_lane_rtk_arc(epochs, config) when is_list(epochs) and is_map(config) do
    with :ok <- ensure_nonempty_epochs(epochs),
         {:ok, normalized_epochs} <- normalize_dual_baseline_epochs(epochs) do
      case NIF.rtk_fix_wide_lane_arc(
             dual_frequency_arc_epoch_terms(normalized_epochs, false),
             wide_lane_arc_config_term(config)
           ) do
        {:ok, solution} -> {:ok, decode_wide_lane_arc_solution(solution, normalized_epochs)}
        {:error, reason} -> decode_wide_lane_arc_error(reason, normalized_epochs)
      end
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  def fix_wide_lane_rtk_arc(_epochs, _config), do: {:error, :invalid_epochs}

  @doc """
  Build ionosphere-free RTK arc epochs from dual-frequency epochs and fixed wide-lane integers.
  """
  @spec prepare_ionosphere_free_rtk_arc([dual_frequency_baseline_epoch()], %{String.t() => integer()}, map()) ::
          {:ok, map()} | {:error, term()}
  def prepare_ionosphere_free_rtk_arc(epochs, wide_lane_cycles, config)
      when is_list(epochs) and is_map(wide_lane_cycles) and is_map(config) do
    with :ok <- ensure_nonempty_epochs(epochs),
         {:ok, normalized_epochs} <- normalize_dual_baseline_epochs(epochs) do
      wide_lane_terms = wide_lane_cycles |> Map.to_list() |> Enum.sort()
      apply_troposphere? = Map.get(config, :apply_troposphere, false)

      case NIF.rtk_prepare_ionosphere_free_arc(
             dual_frequency_arc_epoch_terms(normalized_epochs, apply_troposphere?),
             wide_lane_terms,
             ionosphere_free_arc_config_term(config)
           ) do
        {:ok, solution} ->
          {if_epochs, wavelengths, offsets, references} =
            decode_ionosphere_free_arc_solution(solution, normalized_epochs)

          {:ok,
           %{
             references: references,
             epochs: if_epochs,
             wavelengths_m: wavelengths,
             offsets_m: offsets
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  def prepare_ionosphere_free_rtk_arc(_epochs, _wide_lane_cycles, _config), do: {:error, :invalid_epochs}

  @doc """
  Solve a static RTK baseline directly from parsed RINEX OBS handles and SP3.

  `base_m` is the base antenna reference point in ECEF metres. Options include
  `:model`, `:reference`, `:max_epochs`, `:arc_options`, `:preprocessing`,
  `:float_options`, `:fixed_options`, `:residual_options`, `:float_only_systems`,
  `:initial_baseline_m`, and `:receiver_antenna_corrections`.
  """
  @spec solve_static_rinex_rtk_baseline(
          SP3.t(),
          RinexObservations.t(),
          RinexObservations.t(),
          ecef_input(),
          keyword() | map()
        ) :: {:ok, map()} | {:error, term()}
  def solve_static_rinex_rtk_baseline(sp3, base_obs, rover_obs, base_m, opts \\ [])

  def solve_static_rinex_rtk_baseline(
        %SP3{handle: sp3_handle},
        %RinexObservations{handle: base_handle},
        %RinexObservations{handle: rover_handle},
        base_m,
        opts
      ) do
    with {:ok, opts} <- rinex_opts_map(opts),
         {:ok, base} <- Types.normalize_ecef(base_m, :invalid_base_position),
         {:ok, config} <- rinex_static_config_term(base, opts) do
      case NIF.rtk_solve_static_rinex_baseline(sp3_handle, base_handle, rover_handle, config.term) do
        {:ok, {solution_term, skipped_epoch_count, epoch_count}} ->
          decode_rinex_static_solution(solution_term, base, config, skipped_epoch_count, epoch_count)

        {:error, reason} ->
          {:error, reason}
      end
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  def solve_static_rinex_rtk_baseline(_sp3, _base_obs, _rover_obs, _base_m, _opts), do: {:error, :invalid_input}

  @doc """
  Solve a static reference-station coordinate from paired RINEX OBS handles and SP3.

  `reference_position_m` is the known reference receiver ECEF position in
  metres. Options mirror `solve_static_rinex_rtk_baseline/5` for the carrier
  path and also accept `:enable_code_dgnss`, `:enable_carrier_rtk`, and
  `:with_geodetic`.
  """
  @spec solve_static_reference_station_rinex(
          SP3.t(),
          RinexObservations.t(),
          RinexObservations.t(),
          ecef_input(),
          keyword() | map()
        ) :: {:ok, StaticReferenceStationSolution.t()} | {:error, term()}
  def solve_static_reference_station_rinex(sp3, reference_obs, rover_obs, reference_position_m, opts \\ [])

  def solve_static_reference_station_rinex(
        %SP3{handle: sp3_handle},
        %RinexObservations{handle: reference_handle},
        %RinexObservations{handle: rover_handle},
        reference_position_m,
        opts
      ) do
    with {:ok, opts} <- rinex_opts_map(opts),
         {:ok, reference_position} <- Types.normalize_ecef(reference_position_m, :invalid_reference_position),
         {:ok, config} <- static_reference_station_config_term(reference_position, opts) do
      case NIF.rtk_solve_static_reference_station_rinex(sp3_handle, reference_handle, rover_handle, config) do
        {:ok, solution_term} -> {:ok, decode_static_reference_station_solution(solution_term)}
        {:error, reason} -> {:error, decode_static_reference_station_error(reason)}
      end
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  def solve_static_reference_station_rinex(_sp3, _reference_obs, _rover_obs, _reference_position_m, _opts),
    do: {:error, :invalid_input}

  @doc """
  Solve a static dual-frequency wide-lane fixed RTK baseline from RINEX OBS and SP3.

  The result contains the decoded static float and fixed solutions plus
  `:wide_lane` metadata for the wide-lane integers used before the final
  narrow-lane solve.
  """
  @spec solve_wide_lane_fixed_rinex_rtk_baseline(
          SP3.t(),
          RinexObservations.t(),
          RinexObservations.t(),
          ecef_input(),
          keyword() | map()
        ) :: {:ok, map()} | {:error, term()}
  def solve_wide_lane_fixed_rinex_rtk_baseline(sp3, base_obs, rover_obs, base_m, opts \\ [])

  def solve_wide_lane_fixed_rinex_rtk_baseline(
        %SP3{handle: sp3_handle},
        %RinexObservations{handle: base_handle},
        %RinexObservations{handle: rover_handle},
        base_m,
        opts
      ) do
    with {:ok, opts} <- rinex_opts_map(opts),
         {:ok, base} <- Types.normalize_ecef(base_m, :invalid_base_position),
         {:ok, config} <- rinex_wide_lane_fixed_config_term(base, opts) do
      case NIF.rtk_solve_wide_lane_fixed_rinex_baseline(sp3_handle, base_handle, rover_handle, config.term) do
        {:ok, {solution_term, metadata_term, skipped_epoch_count, epoch_count}} ->
          with {:ok, solution} <-
                 decode_rinex_static_solution(solution_term, base, config, skipped_epoch_count, epoch_count) do
            {:ok, Map.put(solution, :wide_lane, decode_wide_lane_fixed_metadata(metadata_term))}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  def solve_wide_lane_fixed_rinex_rtk_baseline(_sp3, _base_obs, _rover_obs, _base_m, _opts),
    do: {:error, :invalid_input}

  defp static_arc_config_term(config) do
    solve_opts = Map.fetch!(config, :float_opts)
    fixed_opts = Map.fetch!(config, :fixed_opts)
    residual_opts = Map.fetch!(config, :residual_opts)

    %{
      base_m: arc_vec3(Map.fetch!(config, :base_m)),
      reference: arc_reference_term(Map.get(config, :reference, :auto)),
      model: arc_model_term(Map.fetch!(config, :model)),
      initial_baseline_m: arc_vec3(Map.get(config, :initial_baseline_m, {0.0, 0.0, 0.0})),
      wavelengths_m: Map.fetch!(config, :wavelengths_m),
      offsets_m: Map.fetch!(config, :offsets_m),
      float_opts:
        {arc_vec3(Map.get(config, :initial_baseline_m, {0.0, 0.0, 0.0})), solve_opts.position_tolerance_m,
         solve_opts.ambiguity_tolerance_m, solve_opts.max_iterations},
      fixed_opts:
        {solve_opts.position_tolerance_m, solve_opts.ambiguity_tolerance_m, solve_opts.max_iterations,
         fixed_opts.ratio_threshold, fixed_opts.partial_ambiguity_resolution?, fixed_opts.partial_min_ambiguities,
         Map.fetch!(config, :float_only_systems)},
      residual_opts: {residual_opts.threshold_sigma, residual_opts.max_exclusions},
      preprocessing: arc_preprocessing_term(Map.get(config, :preprocessing, %{})),
      receiver_antenna_corrections:
        rust_receiver_antenna_corrections_term(Map.get(config, :receiver_antenna_corrections))
    }
  end

  defp decode_static_arc_solution(
         {references, ambiguity_ids, ambiguity_satellite_terms, float_term, fixed_term, dropped_sats, split_terms,
          elevation_masked_sats, geometry_quality}
       ) do
    %{
      references: Map.new(references),
      ambiguity_ids: ambiguity_ids,
      ambiguity_satellites: Map.new(ambiguity_satellite_terms),
      float_term: float_term,
      fixed_term: fixed_term,
      dropped_sats: dropped_sats,
      split_cycle_slip_arcs: Enum.map(split_terms, &decode_arc_split_cycle_slip_arc/1),
      elevation_masked_sats: elevation_masked_sats,
      geometry_quality: GeometryQuality.from_nif(geometry_quality)
    }
  end

  defp rinex_opts_map(opts) when is_map(opts), do: {:ok, opts}

  defp rinex_opts_map(opts) when is_list(opts) do
    if Keyword.keyword?(opts), do: {:ok, Map.new(opts)}, else: {:error, {:invalid_option, :opts}}
  end

  defp rinex_opts_map(_opts), do: {:error, {:invalid_option, :opts}}

  defp rinex_static_config_term(base, opts) do
    with {:ok, reference} <- rinex_reference(opts),
         {:ok, arc_options} <- rinex_single_arc_options_term(opts),
         {:ok, _model, model_term, weights} <- rinex_model(opts),
         {:ok, initial_baseline} <- rinex_initial_baseline(opts),
         {:ok, float_options} <- rinex_nested_options(opts, :float_options),
         {:ok, fixed_options} <- rinex_nested_options(opts, :fixed_options),
         {:ok, residual_options} <- rinex_nested_options(opts, :residual_options),
         {:ok, preprocessing} <- rinex_nested_options(opts, :preprocessing),
         {:ok, float_only_systems} <- direct_float_only_systems(Map.get(opts, :float_only_systems, [])),
         {:ok, float_opts} <- direct_float_opts(float_options, initial_baseline),
         {:ok, fixed_opts} <- direct_fixed_opts(fixed_options, float_only_systems),
         {:ok, residual_opts} <- direct_residual_opts(residual_options),
         {:ok, update_opts} <- rinex_update_opts_term(opts, float_options, fixed_options, float_only_systems),
         {:ok, receiver_antenna_corrections} <- direct_receiver_antenna_corrections(opts) do
      {:ok,
       %{
         term: %{
           base_m: arc_vec3(base),
           arc_options: arc_options,
           reference: arc_reference_term(reference),
           model: model_term,
           baseline_prior_sigma_m: Map.get(opts, :baseline_prior_sigma_m, @default_prior_sigma_m) / 1.0,
           ambiguity_prior_sigma_m: Map.get(opts, :ambiguity_prior_sigma_m, @default_prior_sigma_m) / 1.0,
           initial_baseline_m: arc_vec3(initial_baseline),
           update_opts: update_opts,
           preprocessing: arc_preprocessing_term(preprocessing),
           float_opts: float_opts,
           fixed_opts: fixed_opts,
           residual_opts: residual_opts,
           receiver_antenna_corrections: rust_receiver_antenna_corrections_term(receiver_antenna_corrections)
         },
         weights: weights,
         preprocessing: preprocessing
       }}
    end
  end

  defp static_reference_station_config_term(reference_position, opts) do
    with {:ok, enable_code_dgnss} <- boolean_option(Map.get(opts, :enable_code_dgnss, true), :enable_code_dgnss),
         {:ok, enable_carrier_rtk} <- boolean_option(Map.get(opts, :enable_carrier_rtk, true), :enable_carrier_rtk),
         {:ok, with_geodetic} <- boolean_option(Map.get(opts, :with_geodetic, true), :with_geodetic),
         {:ok, carrier_config} <- rinex_static_config_term(reference_position, opts) do
      {:ok,
       %{
         reference_position_m: arc_vec3(reference_position),
         enable_code_dgnss: enable_code_dgnss,
         enable_carrier_rtk: enable_carrier_rtk,
         with_geodetic: with_geodetic,
         carrier: carrier_config.term
       }}
    end
  end

  defp rinex_wide_lane_fixed_config_term(base, opts) do
    with {:ok, reference} <- rinex_reference(opts),
         {:ok, arc_options} <- rinex_dual_arc_options_term(opts),
         {:ok, _model, model_term, weights} <- rinex_model(opts),
         {:ok, initial_baseline} <- rinex_initial_baseline(opts),
         {:ok, float_options} <- rinex_nested_options(opts, :float_options),
         {:ok, fixed_options} <- rinex_nested_options(opts, :fixed_options),
         {:ok, residual_options} <- rinex_nested_options(opts, :residual_options),
         {:ok, float_only_systems} <- direct_float_only_systems(Map.get(opts, :float_only_systems, [])),
         {:ok, float_opts} <- direct_float_opts(float_options, initial_baseline),
         {:ok, fixed_opts} <- direct_fixed_opts(fixed_options, float_only_systems),
         {:ok, residual_opts} <- direct_residual_opts(residual_options),
         {:ok, update_opts} <- rinex_update_opts_term(opts, float_options, fixed_options, float_only_systems),
         {:ok, receiver_antenna_corrections} <- direct_receiver_antenna_corrections(opts) do
      {:ok,
       %{
         term: %{
           base_m: arc_vec3(base),
           arc_options: arc_options,
           reference: arc_reference_term(reference),
           model: model_term,
           baseline_prior_sigma_m: Map.get(opts, :baseline_prior_sigma_m, @default_prior_sigma_m) / 1.0,
           ambiguity_prior_sigma_m: Map.get(opts, :ambiguity_prior_sigma_m, @default_prior_sigma_m) / 1.0,
           initial_baseline_m: arc_vec3(initial_baseline),
           update_opts: update_opts,
           float_opts: float_opts,
           fixed_opts: fixed_opts,
           residual_opts: residual_opts,
           receiver_antenna_corrections: rust_receiver_antenna_corrections_term(receiver_antenna_corrections),
           apply_troposphere: Map.get(opts, :apply_troposphere, true)
         },
         weights: weights,
         preprocessing: %{}
       }}
    end
  end

  defp rinex_model(opts) do
    model = Map.get(opts, :model, default_rinex_model())

    with {:ok, model_term} <- direct_model(%{model: model}),
         {:ok, weights} <- direct_weights(%{model: model}) do
      {:ok, model, model_term, weights}
    end
  end

  defp default_rinex_model do
    %{
      code_sigma_m: @default_code_sigma_m,
      phase_sigma_m: @default_phase_sigma_m,
      stochastic_model: :simple,
      elevation_weighting?: false,
      sagnac?: true
    }
  end

  defp rinex_reference(opts) do
    case Map.get(opts, :reference, Map.get(opts, :reference_satellite_id, :auto)) do
      :auto -> {:ok, :auto}
      sat when is_binary(sat) -> {:ok, {:satellite, sat}}
      {:satellite, sat} when is_binary(sat) -> {:ok, {:satellite, sat}}
      {:per_system, refs} when is_map(refs) -> {:ok, {:per_system, refs}}
      refs when is_map(refs) -> {:ok, {:per_system, refs}}
      _other -> {:error, {:invalid_option, :reference}}
    end
  end

  defp rinex_initial_baseline(opts) do
    opts
    |> Map.get(:initial_baseline_m, {0.0, 0.0, 0.0})
    |> Types.normalize_ecef(:invalid_initial_baseline)
  end

  defp rinex_nested_options(opts, key) do
    case Map.get(opts, key, %{}) do
      value when is_map(value) ->
        {:ok, value}

      value when is_list(value) ->
        if Keyword.keyword?(value), do: {:ok, Map.new(value)}, else: {:error, {:invalid_option, key}}

      _value ->
        {:error, {:invalid_option, key}}
    end
  end

  defp rinex_single_arc_options_term(opts) do
    with {:ok, arc_options} <- rinex_nested_options(opts, :arc_options),
         {:ok, signal_pairs} <- rinex_signal_pair_terms(Map.get(arc_options, :signal_pairs, []), :single) do
      {:ok,
       %{
         signal_pairs: signal_pairs,
         max_epochs: Map.get(arc_options, :max_epochs, Map.get(opts, :max_epochs)),
         min_common_satellites: Map.get(arc_options, :min_common_satellites, 4),
         include_prediction_time: Map.get(arc_options, :include_prediction_time, true)
       }}
    end
  end

  defp rinex_dual_arc_options_term(opts) do
    with {:ok, arc_options} <- rinex_nested_options(opts, :arc_options),
         {:ok, signal_pairs} <- rinex_signal_pair_terms(Map.get(arc_options, :signal_pairs, []), :dual) do
      {:ok,
       %{
         signal_pairs: signal_pairs,
         max_epochs: Map.get(arc_options, :max_epochs, Map.get(opts, :max_epochs)),
         min_common_satellites: Map.get(arc_options, :min_common_satellites, 4),
         include_prediction_time: Map.get(arc_options, :include_prediction_time, true)
       }}
    end
  end

  defp rinex_signal_pair_terms(pairs, kind) when is_list(pairs) do
    pairs
    |> Enum.reduce_while({:ok, []}, fn pair, {:ok, acc} ->
      case rinex_signal_pair_term(pair, kind) do
        {:ok, term} -> {:cont, {:ok, [term | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, terms} -> {:ok, Enum.reverse(terms)}
      {:error, _reason} = error -> error
    end
  end

  defp rinex_signal_pair_terms(_pairs, _kind), do: {:error, {:invalid_option, :signal_pairs}}

  defp rinex_signal_pair_term(%{system: system, code_observable: code, phase_observable: phase}, :single)
       when is_binary(code) and is_binary(phase) do
    with {:ok, system} <- rinex_system_term(system) do
      {:ok, %{system: system, code_observable: code, phase_observable: phase}}
    end
  end

  defp rinex_signal_pair_term({system, code, phase}, :single) when is_binary(code) and is_binary(phase) do
    with {:ok, system} <- rinex_system_term(system) do
      {:ok, %{system: system, code_observable: code, phase_observable: phase}}
    end
  end

  defp rinex_signal_pair_term(
         %{
           system: system,
           code1_observable: code1,
           phase1_observable: phase1,
           code2_observable: code2,
           phase2_observable: phase2
         },
         :dual
       )
       when is_binary(code1) and is_binary(phase1) and is_binary(code2) and is_binary(phase2) do
    with {:ok, system} <- rinex_system_term(system) do
      {:ok,
       %{
         system: system,
         code1_observable: code1,
         phase1_observable: phase1,
         code2_observable: code2,
         phase2_observable: phase2
       }}
    end
  end

  defp rinex_signal_pair_term({system, code1, phase1, code2, phase2}, :dual)
       when is_binary(code1) and is_binary(phase1) and is_binary(code2) and is_binary(phase2) do
    with {:ok, system} <- rinex_system_term(system) do
      {:ok,
       %{
         system: system,
         code1_observable: code1,
         phase1_observable: phase1,
         code2_observable: code2,
         phase2_observable: phase2
       }}
    end
  end

  defp rinex_signal_pair_term(_pair, _kind), do: {:error, {:invalid_option, :signal_pairs}}

  defp rinex_system_term(system) when is_binary(system), do: {:ok, system}
  defp rinex_system_term(system) when is_atom(system), do: {:ok, Atom.to_string(system)}
  defp rinex_system_term(_system), do: {:error, {:invalid_option, :signal_pairs}}

  defp rinex_update_opts_term(opts, float_options, fixed_options, float_only_systems) do
    with {:ok, update_options} <- rinex_update_options_map(opts) do
      position_tol_m =
        Map.get(
          float_options,
          :position_tol_m,
          Map.get(float_options, :position_tolerance_m, @default_position_tolerance_m)
        )

      ambiguity_tol_m =
        Map.get(
          float_options,
          :ambiguity_tol_m,
          Map.get(float_options, :ambiguity_tolerance_m, @default_ambiguity_tolerance_m)
        )

      update_options =
        %{
          hold_sigma_m: @default_ambiguity_tolerance_m,
          position_tol_m: position_tol_m,
          ambiguity_tol_m: ambiguity_tol_m,
          max_iterations: Map.get(float_options, :max_iterations, @default_max_iterations),
          process_noise_baseline_sigma_m: 0.0,
          ratio_threshold: Map.get(fixed_options, :ratio_threshold, @default_integer_ratio_threshold),
          dynamics_model: :constant_position,
          float_only_systems: float_only_systems,
          innovation_screen_sigma: 0.0,
          innovation_screen_min_rows: 0,
          report_residuals?: false
        }
        |> Map.merge(update_options)
        |> Map.put(:float_only_systems, float_only_systems)

      {:ok, arc_update_opts_term(update_options)}
    end
  end

  defp rinex_update_options_map(opts) do
    case Map.get(opts, :update_options, Map.get(opts, :update_opts, %{})) do
      value when is_map(value) ->
        {:ok, value}

      value when is_list(value) ->
        if Keyword.keyword?(value), do: {:ok, Map.new(value)}, else: {:error, {:invalid_option, :update_options}}

      _value ->
        {:error, {:invalid_option, :update_options}}
    end
  end

  defp decode_static_reference_station_solution(
         {mode, fix_status, position, geodetic, covariance, baseline_vector, baseline_m, code_solution,
          carrier_solution, mode_reports, diagnostics}
       ) do
    %StaticReferenceStationSolution{
      mode: mode,
      fix_status: fix_status,
      position_m: ecef_map(position),
      geodetic: decode_static_reference_geodetic(geodetic),
      covariance: decode_static_reference_covariance(covariance),
      baseline_vector_m: ecef_map(baseline_vector),
      baseline_m: baseline_m,
      code_solution: decode_static_reference_code_solution(code_solution),
      carrier_solution: decode_static_reference_carrier_solution(carrier_solution),
      mode_reports: Enum.map(mode_reports, &decode_static_reference_mode_report/1),
      diagnostics: Enum.map(diagnostics, &decode_static_reference_diagnostic/1)
    }
  end

  defp decode_static_reference_code_solution(nil), do: nil

  defp decode_static_reference_code_solution({position, geodetic, covariance, baseline_vector, baseline_m, diagnostics}) do
    %StaticReferenceCodeSolution{
      position_m: ecef_map(position),
      geodetic: decode_static_reference_geodetic(geodetic),
      covariance: decode_static_reference_covariance(covariance),
      baseline_vector_m: ecef_map(baseline_vector),
      baseline_m: baseline_m,
      diagnostics: Enum.map(diagnostics, &decode_static_reference_diagnostic/1)
    }
  end

  defp decode_static_reference_carrier_solution(nil), do: nil

  defp decode_static_reference_carrier_solution(
         {position, geodetic, covariance, baseline_vector, baseline_m, integer_status, integer_ratio, diagnostics}
       ) do
    %StaticReferenceCarrierSolution{
      position_m: ecef_map(position),
      geodetic: decode_static_reference_geodetic(geodetic),
      covariance: decode_static_reference_covariance(covariance),
      baseline_vector_m: ecef_map(baseline_vector),
      baseline_m: baseline_m,
      integer_status: decode_fixed_integer_status(integer_status),
      integer_ratio: integer_ratio,
      diagnostics: Enum.map(diagnostics, &decode_static_reference_diagnostic/1)
    }
  end

  defp decode_static_reference_covariance({position_ecef_m2, position_enu_m2}) do
    %StaticReferenceStationCovariance{
      position_ecef_m2: position_ecef_m2,
      position_enu_m2: position_enu_m2
    }
  end

  defp decode_static_reference_geodetic(nil), do: nil

  defp decode_static_reference_geodetic({lat_rad, lon_rad, height_m}) do
    %{lat_rad: lat_rad, lon_rad: lon_rad, height_m: height_m}
  end

  defp decode_static_reference_diagnostic(
         {mode, epoch_index, used_satellites, rejected_satellite_count, code_residual_rms_m, phase_residual_rms_m,
          residual_rms_m}
       ) do
    %StaticReferenceEpochDiagnostic{
      mode: mode,
      epoch_index: epoch_index,
      used_satellites: used_satellites,
      rejected_satellite_count: rejected_satellite_count,
      code_residual_rms_m: code_residual_rms_m,
      phase_residual_rms_m: phase_residual_rms_m,
      residual_rms_m: residual_rms_m
    }
  end

  defp decode_static_reference_mode_report({mode, status, used_epochs, skipped_epochs, used_measurements, error}) do
    %StaticReferenceModeReport{
      mode: mode,
      status: status,
      used_epochs: used_epochs,
      skipped_epochs: skipped_epochs,
      used_measurements: used_measurements,
      error: error
    }
  end

  defp decode_static_reference_station_error({:all_modes_failed, mode_reports}) do
    {:all_modes_failed, Enum.map(mode_reports, &decode_static_reference_mode_report/1)}
  end

  defp decode_static_reference_station_error(reason), do: reason

  defp decode_rinex_static_solution(solution_term, base, config, skipped_epoch_count, epoch_count) do
    static = decode_static_arc_solution(solution_term)
    epochs = rinex_static_epochs(epoch_count)
    prep_meta = rinex_static_prep_meta(static, config)

    with {:ok, float_solution} <-
           decode_rtk_float_solution(
             static.float_term,
             base,
             epochs,
             static.references,
             rinex_physical_sats(static),
             static.ambiguity_ids,
             static.ambiguity_satellites,
             config.weights,
             prep_meta
           ) do
      {_float_term, fixed_term, validation_term, used_ids, used_satellite_terms} = static.fixed_term
      used_satellites = Map.new(used_satellite_terms)
      used_physical_sats = used_satellites |> Map.values() |> Enum.uniq() |> Enum.sort()

      with {:ok, fixed_solution} <-
             decode_rtk_fixed_solution(
               fixed_term,
               base,
               epochs,
               static.references,
               used_physical_sats,
               used_ids,
               used_satellites,
               config.weights,
               float_solution
             ) do
        {:ok,
         %{
           references: static.references,
           ambiguity_ids: static.ambiguity_ids,
           ambiguity_satellites: static.ambiguity_satellites,
           float_solution: float_solution,
           fixed_solution: %{
             fixed_solution
             | metadata: maybe_put_residual_validation(fixed_solution.metadata, validation_term, epochs)
           },
           dropped_sats: static.dropped_sats,
           split_cycle_slip_arcs: static.split_cycle_slip_arcs,
           elevation_masked_sats: static.elevation_masked_sats,
           geometry_quality: static.geometry_quality,
           skipped_epoch_count: skipped_epoch_count,
           epoch_count: epoch_count
         }}
      end
    end
  end

  defp rinex_static_epochs(epoch_count) when epoch_count <= 0, do: []

  defp rinex_static_epochs(epoch_count) do
    for idx <- 0..(epoch_count - 1), do: %{idx: idx, epoch: idx}
  end

  defp rinex_static_prep_meta(static, config) do
    %{
      dropped_sats: static.dropped_sats,
      split_arcs: static.split_cycle_slip_arcs,
      code_smoothing: Map.has_key?(config.preprocessing, :hatch_window_cap),
      code_smoothing_window_cap: Map.get(config.preprocessing, :hatch_window_cap),
      elevation_mask_deg: Map.get(config.preprocessing, :elevation_mask_deg),
      elevation_masked_sats: static.elevation_masked_sats
    }
  end

  defp rinex_physical_sats(static) do
    static.ambiguity_satellites
    |> Map.values()
    |> Kernel.++(Map.values(static.references))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp decode_wide_lane_fixed_metadata(
         {method, fixed?, wide_lane_cycles, dropped_cycle_slip_sats, split_cycle_slip_arcs}
       ) do
    cycles = Map.new(wide_lane_cycles)

    %{
      integer_method: decode_wide_lane_fixed_integer_method(method),
      fixed?: fixed?,
      cycles: cycles,
      ambiguity_count: map_size(cycles),
      dropped_cycle_slip_sats: dropped_cycle_slip_sats,
      split_cycle_slip_arcs: Enum.map(split_cycle_slip_arcs, &decode_arc_split_cycle_slip_arc/1)
    }
  end

  defp decode_wide_lane_fixed_integer_method("wide_lane_narrow_lane_lambda"), do: :wide_lane_narrow_lane_lambda

  defp decode_wide_lane_fixed_integer_method("wide_lane_narrow_lane_sequential"), do: :wide_lane_narrow_lane_sequential

  defp static_decode_epochs(input_epochs) do
    input_epochs
    |> Enum.with_index()
    |> Enum.map(fn {epoch, idx} -> %{idx: idx, epoch: Map.get(epoch, :epoch, idx)} end)
  end

  defp direct_epochs(%{epochs: epochs}) when is_list(epochs), do: {:ok, epochs}
  defp direct_epochs(_config), do: {:error, {:missing_field, :epochs}}

  defp boolean_option(value, _option) when is_boolean(value), do: {:ok, value}
  defp boolean_option(_value, option), do: {:error, {:invalid_option, option}}

  defp direct_base(config) do
    case Map.fetch(config, :base) do
      {:ok, base} -> Types.normalize_ecef(base, :invalid_base_position)
      :error -> Types.normalize_ecef(Map.get(config, :base_m), :invalid_base_position)
    end
  end

  defp direct_ambiguity_ids(%{ambiguity_ids: ids}) when is_list(ids), do: {:ok, ids}
  defp direct_ambiguity_ids(_config), do: {:error, {:missing_field, :ambiguity_ids}}

  defp direct_initial_baseline(config) do
    config
    |> Map.get(:initial_baseline_m, {0.0, 0.0, 0.0})
    |> Types.normalize_ecef(:invalid_initial_baseline)
  end

  defp direct_model(%{model: model}) when is_map(model) do
    with {:ok, stochastic} <- direct_stochastic(Map.get(model, :stochastic_model, Map.get(model, :stochastic, :simple))),
         {:ok, elevation_weighting?} <-
           direct_boolean(Map.get(model, :elevation_weighting?, Map.get(model, :elevation_weighting, false))),
         {:ok, sagnac?} <- direct_boolean(Map.get(model, :sagnac?, Map.get(model, :sagnac, true))) do
      {:ok,
       {
         Map.fetch!(model, :code_sigma_m) / 1.0,
         Map.fetch!(model, :phase_sigma_m) / 1.0,
         stochastic,
         elevation_weighting?,
         sagnac?
       }}
    end
  end

  defp direct_model(_config), do: {:error, {:missing_field, :model}}

  defp direct_weights(%{model: model}) when is_map(model) do
    with {:ok, stochastic} <-
           direct_stochastic_atom(Map.get(model, :stochastic_model, Map.get(model, :stochastic, :simple))),
         {:ok, elevation_weighting?} <-
           direct_boolean(Map.get(model, :elevation_weighting?, Map.get(model, :elevation_weighting, false))),
         {:ok, sagnac?} <- direct_boolean(Map.get(model, :sagnac?, Map.get(model, :sagnac, true))) do
      {:ok,
       %{
         code_sigma_m: Map.fetch!(model, :code_sigma_m) / 1.0,
         phase_sigma_m: Map.fetch!(model, :phase_sigma_m) / 1.0,
         stochastic_model: stochastic,
         elevation_weighting?: elevation_weighting?,
         sagnac?: sagnac?
       }}
    end
  end

  defp direct_stochastic(value) when value in [:simple, :rtklib], do: {:ok, Atom.to_string(value)}
  defp direct_stochastic(value) when value in ["simple", "rtklib"], do: {:ok, value}
  defp direct_stochastic(_value), do: {:error, {:invalid_option, :stochastic_model}}

  defp direct_stochastic_atom(value) when value in [:simple, :rtklib], do: {:ok, value}
  defp direct_stochastic_atom("simple"), do: {:ok, :simple}
  defp direct_stochastic_atom("rtklib"), do: {:ok, :rtklib}
  defp direct_stochastic_atom(_value), do: {:error, {:invalid_option, :stochastic_model}}

  defp direct_boolean(value) when is_boolean(value), do: {:ok, value}
  defp direct_boolean(_value), do: {:error, :invalid_boolean}

  defp direct_float_opts(opts, initial_baseline) when is_map(opts) do
    {:ok,
     {
       initial_baseline,
       Map.get(opts, :position_tol_m, Map.get(opts, :position_tolerance_m, @default_position_tolerance_m)) / 1.0,
       Map.get(opts, :ambiguity_tol_m, Map.get(opts, :ambiguity_tolerance_m, @default_ambiguity_tolerance_m)) / 1.0,
       Map.get(opts, :max_iterations, @default_max_iterations)
     }}
  end

  defp direct_float_opts(_opts, _initial_baseline), do: {:error, {:invalid_option, :options}}

  defp direct_fixed_opts(opts, float_only_systems) when is_map(opts) do
    {:ok,
     {
       Map.get(opts, :position_tol_m, Map.get(opts, :position_tolerance_m, @default_position_tolerance_m)) / 1.0,
       Map.get(opts, :ambiguity_tol_m, Map.get(opts, :ambiguity_tolerance_m, @default_ambiguity_tolerance_m)) / 1.0,
       Map.get(opts, :max_iterations, @default_max_iterations),
       Map.get(opts, :ratio_threshold, @default_integer_ratio_threshold) / 1.0,
       Map.get(opts, :partial_ambiguity_resolution?, Map.get(opts, :partial_ambiguity_resolution, false)),
       Map.get(opts, :partial_min_ambiguities, @default_partial_min_ambiguities),
       float_only_systems
     }}
  end

  defp direct_fixed_opts(_opts, _float_only_systems), do: {:error, {:invalid_option, :fixed_options}}

  defp direct_residual_opts(opts) when is_map(opts) do
    {:ok, {Map.get(opts, :threshold_sigma), Map.get(opts, :max_exclusions, @default_max_residual_exclusions)}}
  end

  defp direct_residual_opts(_opts), do: {:error, {:invalid_option, :residual_options}}

  defp direct_float_only_systems(systems) when is_list(systems) do
    if Enum.all?(systems, &system_letter?/1), do: {:ok, systems}, else: {:error, {:invalid_option, :float_only_systems}}
  end

  defp direct_float_only_systems(_systems), do: {:error, {:invalid_option, :float_only_systems}}

  defp direct_receiver_antenna_corrections(config) do
    case Map.get(config, :receiver_antenna_corrections) do
      nil -> {:ok, nil}
      candidate -> parse_receiver_antenna_corrections(candidate)
    end
  end

  defp direct_string_map(config, key) do
    case Map.fetch(config, key) do
      {:ok, values} when is_map(values) ->
        if Enum.all?(values, fn {id, value} -> is_binary(id) and is_binary(value) end) do
          {:ok, values}
        else
          {:error, {:invalid_field, key}}
        end

      {:ok, _values} ->
        {:error, {:invalid_field, key}}

      :error ->
        {:error, {:missing_field, key}}
    end
  end

  defp direct_number_map(config, key) do
    case Map.fetch(config, key) do
      {:ok, values} when is_map(values) ->
        if Enum.all?(values, fn {id, value} -> is_binary(id) and is_number(value) end) do
          {:ok, Map.new(values, fn {id, value} -> {id, value / 1.0} end)}
        else
          {:error, {:invalid_field, key}}
        end

      {:ok, _values} ->
        {:error, {:invalid_field, key}}

      :error ->
        {:error, {:missing_field, key}}
    end
  end

  defp rtk_epoch_term(epoch) do
    {
      Enum.map(Map.fetch!(epoch, :references), &rtk_sat_term/1),
      Enum.map(Map.fetch!(epoch, :nonref), &rtk_sat_term/1),
      arc_vec3_or_nil(Map.get(epoch, :velocity_mps)),
      Map.get(epoch, :dt_s, 0.0) / 1.0
    }
  end

  defp rtk_sat_term(sat) do
    {
      {Map.get(sat, :sat, Map.get(sat, :satellite_id)), Map.get(sat, :sd_ambiguity_id, Map.get(sat, :ambiguity_id))},
      {sat.base_code_m / 1.0, sat.base_phase_m / 1.0, sat.rover_code_m / 1.0, sat.rover_phase_m / 1.0},
      {arc_vec3(sat.base_tx_pos), arc_vec3(sat.rover_tx_pos), arc_vec3(sat.pos)}
    }
  end

  defp direct_references(epochs) do
    epochs
    |> List.first(%{references: []})
    |> Map.get(:references, [])
    |> Map.new(fn sat ->
      {sat |> Map.get(:sat, Map.get(sat, :satellite_id)) |> satellite_system(),
       Map.get(sat, :sat, Map.get(sat, :satellite_id))}
    end)
  end

  defp direct_physical_sats(epochs) do
    epochs
    |> Enum.flat_map(&(Map.get(&1, :references, []) ++ Map.get(&1, :nonref, [])))
    |> Enum.map(&Map.get(&1, :sat, Map.get(&1, :satellite_id)))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp direct_preprocess_meta do
    %{
      dropped_sats: [],
      split_arcs: [],
      code_smoothing: false,
      code_smoothing_window_cap: nil,
      elevation_mask_deg: nil,
      elevation_masked_sats: []
    }
  end

  defp arc_epoch_term(epoch) do
    %{
      base: Enum.map(Map.fetch!(epoch, :base), &arc_observation_term/1),
      rover: Enum.map(Map.fetch!(epoch, :rover), &arc_observation_term/1),
      satellite_positions_m: arc_position_pairs(Map.fetch!(epoch, :satellite_positions_m)),
      base_satellite_positions_m: arc_position_pairs(Map.get(epoch, :base_satellite_positions_m, %{})),
      rover_satellite_positions_m: arc_position_pairs(Map.get(epoch, :rover_satellite_positions_m, %{})),
      velocity_mps: arc_vec3_or_nil(Map.get(epoch, :velocity_mps)),
      prediction_time_s: arc_float_or_nil(Map.get(epoch, :prediction_time_s))
    }
  end

  defp arc_observation_term(
         %{satellite_id: satellite_id, ambiguity_id: ambiguity_id, code_m: code_m, phase_m: phase_m} = obs
       ) do
    %{
      satellite_id: satellite_id,
      ambiguity_id: ambiguity_id,
      code_m: code_m / 1.0,
      phase_m: phase_m / 1.0,
      lli: Map.get(obs, :lli)
    }
  end

  defp arc_config_term(config) do
    %{
      base_m: arc_vec3(Map.fetch!(config, :base_m)),
      reference: arc_reference_term(Map.get(config, :reference, :auto)),
      model: arc_model_term(Map.fetch!(config, :model)),
      baseline_prior_sigma_m: Map.fetch!(config, :baseline_prior_sigma_m) / 1.0,
      ambiguity_prior_sigma_m: Map.fetch!(config, :ambiguity_prior_sigma_m) / 1.0,
      initial_baseline_m: arc_vec3(Map.get(config, :initial_baseline_m, {0.0, 0.0, 0.0})),
      wavelengths_m: arc_float_pairs(Map.fetch!(config, :wavelengths_m)),
      offsets_m: arc_float_pairs(Map.fetch!(config, :offsets_m)),
      update_opts: arc_update_opts_term(Map.fetch!(config, :update_opts)),
      preprocessing: arc_preprocessing_term(Map.get(config, :preprocessing, %{})),
      receiver_antenna_corrections:
        rust_receiver_antenna_corrections_term(Map.get(config, :receiver_antenna_corrections))
    }
  end

  defp arc_preprocessing_term(preprocessing) do
    %{
      cycle_slip: arc_cycle_slip_policy_term(Map.get(preprocessing, :cycle_slip)),
      hatch_window_cap: Map.get(preprocessing, :hatch_window_cap),
      elevation_mask_deg: arc_float_or_nil(Map.get(preprocessing, :elevation_mask_deg))
    }
  end

  defp arc_cycle_slip_policy_term(nil), do: nil
  defp arc_cycle_slip_policy_term(:error), do: "error"
  defp arc_cycle_slip_policy_term(:drop_satellite), do: "drop_satellite"
  defp arc_cycle_slip_policy_term(:split_arc), do: "split_arc"
  defp arc_cycle_slip_policy_term("error"), do: "error"
  defp arc_cycle_slip_policy_term("drop_satellite"), do: "drop_satellite"
  defp arc_cycle_slip_policy_term("split_arc"), do: "split_arc"

  defp arc_reference_term(:auto), do: %{mode: "auto", satellite: nil, per_system: []}

  defp arc_reference_term({:satellite, satellite}), do: %{mode: "satellite", satellite: satellite, per_system: []}

  defp arc_reference_term({:per_system, per_system}),
    do: %{mode: "per_system", satellite: nil, per_system: Map.to_list(per_system)}

  defp arc_model_term(model) do
    {
      Map.fetch!(model, :code_sigma_m) / 1.0,
      Map.fetch!(model, :phase_sigma_m) / 1.0,
      Atom.to_string(Map.get(model, :stochastic_model, :simple)),
      Map.get(model, :elevation_weighting?, false),
      Map.get(model, :sagnac?, true)
    }
  end

  defp arc_update_opts_term(opts) do
    {
      Map.fetch!(opts, :hold_sigma_m) / 1.0,
      Map.fetch!(opts, :position_tol_m) / 1.0,
      Map.fetch!(opts, :ambiguity_tol_m) / 1.0,
      Map.fetch!(opts, :max_iterations),
      Map.get(opts, :process_noise_baseline_sigma_m, 0.0) / 1.0,
      Map.fetch!(opts, :ratio_threshold) / 1.0,
      {
        Atom.to_string(Map.get(opts, :dynamics_model, :constant_position)),
        Map.get(opts, :float_only_systems, []),
        Map.get(opts, :innovation_screen_sigma, 0.0) / 1.0,
        Map.get(opts, :innovation_screen_min_rows, 0),
        arc_float_or_nil(Map.get(opts, :ar_arming_sigma_m)),
        Map.get(opts, :report_residuals?, false)
      }
    }
  end

  defp arc_position_pairs(positions) do
    for {id, position} <- positions, do: {id, arc_vec3(position)}
  end

  defp arc_float_pairs(values) do
    for {id, value} <- values, do: {id, value / 1.0}
  end

  defp arc_vec3({x, y, z}), do: {x / 1.0, y / 1.0, z / 1.0}

  defp arc_vec3_or_nil(nil), do: nil
  defp arc_vec3_or_nil({_x, _y, _z} = vec), do: arc_vec3(vec)

  defp arc_float_or_nil(nil), do: nil
  defp arc_float_or_nil(value), do: value / 1.0

  defp decode_arc_solution(
         {references, epochs, final_state, dropped_sats, split_cycle_slip_arcs, elevation_masked_sats,
          measurement_covariance}
       ) do
    %{
      references: Map.new(references),
      epochs: Enum.map(epochs, &decode_arc_epoch_solution/1),
      final_state: decode_arc_state(final_state),
      dropped_sats: dropped_sats,
      split_cycle_slip_arcs: Enum.map(split_cycle_slip_arcs, &decode_arc_split_cycle_slip_arc/1),
      elevation_masked_sats: elevation_masked_sats,
      measurement_covariance: measurement_covariance
    }
  end

  defp decode_arc_split_cycle_slip_arc(
         {receiver, satellite_id, ambiguity_id, start_epoch_index, end_epoch_index, n_epochs}
       ) do
    %{
      receiver: decode_rtk_cycle_slip_receiver(receiver),
      satellite_id: satellite_id,
      ambiguity_id: ambiguity_id,
      start_epoch_index: start_epoch_index,
      end_epoch_index: end_epoch_index,
      n_epochs: n_epochs
    }
  end

  defp decode_arc_epoch_solution(
         {reported_baseline_m, float_baseline_m, integer_fixed, integer_ratio, newly_fixed, fixed_ids, sd_ambiguities_m,
          fixed_double_difference_ids, used_satellite_ids, search, residuals, geometry_quality, innovation_screen}
       ) do
    %{
      reported_baseline_m: reported_baseline_m,
      float_baseline_m: float_baseline_m,
      integer_fixed: integer_fixed,
      integer_ratio: integer_ratio,
      newly_fixed: newly_fixed,
      fixed_ids: fixed_ids,
      sd_ambiguities_m: sd_ambiguities_m,
      fixed_double_difference_ids: fixed_double_difference_ids,
      used_satellite_ids: used_satellite_ids,
      search: search,
      residuals: residuals,
      geometry_quality: GeometryQuality.from_nif(geometry_quality),
      innovation_screen: rust_innovation_screen_meta(innovation_screen)
    }
  end

  defp decode_arc_state(
         {{version, references, sd_ambiguity_ids, ambiguity_prior_sigma_m, epoch_count}, baseline_m, sd_ambiguities_m,
          information, fixed_cycles, fixed_m}
       ) do
    %{
      version: version,
      references: Map.new(references),
      sd_ambiguity_ids: sd_ambiguity_ids,
      ambiguity_prior_sigma_m: ambiguity_prior_sigma_m,
      epoch_count: epoch_count,
      baseline_m: baseline_m,
      sd_ambiguities_m: sd_ambiguities_m,
      information: information,
      fixed_cycles: Map.new(fixed_cycles),
      fixed_m: Map.new(fixed_m)
    }
  end

  defp parse_receiver_antenna_corrections(%{base: base, rover: rover}) do
    with {:ok, parsed_base} <- parse_receiver_antenna_correction(base),
         {:ok, parsed_rover} <- parse_receiver_antenna_correction(rover) do
      {:ok, %{base: parsed_base, rover: parsed_rover}}
    else
      _ -> {:error, {:invalid_option, :receiver_antenna_corrections}}
    end
  end

  defp parse_receiver_antenna_corrections(_), do: {:error, {:invalid_option, :receiver_antenna_corrections}}

  defp parse_receiver_antenna_correction(%{antenna: antenna, frequency: frequency}) when is_binary(frequency) do
    with {:ok, resolved_antenna} <- resolve_receiver_antenna(antenna),
         :ok <- validate_receiver_frequency(resolved_antenna, frequency) do
      {:ok, %{antenna: resolved_antenna, frequency: frequency}}
    else
      _ -> {:error, {:invalid_option, :receiver_antenna_corrections}}
    end
  end

  defp parse_receiver_antenna_correction(_), do: {:error, {:invalid_option, :receiver_antenna_corrections}}

  defp resolve_receiver_antenna(%Antex.Antenna{} = antenna), do: {:ok, antenna}

  defp resolve_receiver_antenna({%Antex{antennas: _} = antex, antenna_type}) when is_binary(antenna_type) do
    case Antex.antenna(antex, antenna_type) do
      nil -> {:error, {:invalid_option, :receiver_antenna_corrections}}
      antenna -> {:ok, antenna}
    end
  end

  defp resolve_receiver_antenna(_), do: {:error, {:invalid_option, :receiver_antenna_corrections}}

  defp validate_receiver_frequency(antenna, frequency) do
    case Antex.pco(antenna, frequency) do
      {:ok, {north, east, up}}
      when is_number(north) and is_number(east) and is_number(up) ->
        :ok

      _ ->
        {:error, {:invalid_option, :receiver_antenna_corrections}}
    end
  end

  # The satellite system is the constellation letter, the first grapheme of the
  # RINEX satellite id ("G01" -> "G", "R12" -> "R").
  defp satellite_system(satellite_id), do: String.first(satellite_id)

  defp reference_satellite_report(refs) when map_size(refs) == 1, do: refs |> Map.values() |> hd()

  defp reference_satellite_report(refs), do: refs

  defp system_letter?(<<letter>>) when letter in ?A..?Z, do: true
  defp system_letter?(_other), do: false

  @doc """
  Build code and carrier-phase double differences from base and rover observations.

  Observations can be maps with `:satellite_id`, `:code_m`, and `:phase_m`, or
  `{satellite_id, code_m, phase_m}` tuples. Satellites are paired by id; any
  satellite not present at both receivers is reported in `:dropped_sats`.

  Options:

    * `:reference_satellite_id` - reference satellite for the second
      difference: a satellite id binary (single-system data only) or a
      per-system map covering every observed system. When omitted, each
      system's lexicographically first common satellite is selected
      deterministically. Non-reference satellites difference against their own
      system's reference.

  Returns `{:ok, result}` or a tagged error. At least two common satellites are
  required so one non-reference double difference can be produced.
  """
  @spec double_differences([observation()], [observation()], keyword()) ::
          {:ok, result()} | {:error, term()}
  def double_differences(base_observations, rover_observations, opts \\ [])

  def double_differences(base_observations, rover_observations, opts)
      when is_list(base_observations) and is_list(rover_observations) do
    with :ok <- validate_options(opts, @double_difference_options),
         {:ok, base} <-
           normalize_observation_terms(base_observations, :invalid_base_observations),
         {:ok, rover} <-
           normalize_observation_terms(rover_observations, :invalid_rover_observations),
         {:ok, reference} <- double_difference_reference_term(opts),
         {:ok, {reference_report, dds, dropped}} <-
           NIF.rtk_double_differences(base, rover, reference) do
      {:ok,
       %{
         reference_satellite_id: decode_rtk_reference_report(reference_report),
         double_differences: Enum.map(dds, &decode_rtk_double_difference/1),
         dropped_sats: dropped
       }}
    end
  end

  def double_differences(_base_observations, _rover_observations, _opts), do: {:error, :invalid_observations}

  defp normalize_observation_terms(observations, error_tag) do
    observations
    |> Enum.reduce_while({:ok, []}, fn observation, {:ok, acc} ->
      case Observations.normalize_code_phase([observation],
             container: :list,
             sort?: false,
             include_raw?: false,
             lli: :single,
             validate_lli?: true
           ) do
        {:ok, [obs]} ->
          {:cont, {:ok, [{obs.satellite_id, obs.ambiguity_id, obs.code_m, obs.phase_m} | acc]}}

        {:error, _} ->
          {:halt, {:error, {error_tag, observation}}}
      end
    end)
    |> case do
      {:ok, terms} -> {:ok, Enum.reverse(terms)}
      {:error, _reason} = err -> err
    end
  end

  defp double_difference_reference_term(opts) do
    case Keyword.get(opts, :reference_satellite_id) do
      nil ->
        {:ok, {"auto", "", []}}

      sat when is_binary(sat) ->
        {:ok, {"satellite", sat, []}}

      refs when is_map(refs) ->
        ref_pairs = Map.to_list(refs)

        if Enum.all?(ref_pairs, fn {system, sat} -> is_binary(system) and is_binary(sat) end) do
          {:ok, {"per_system", "", Enum.sort(ref_pairs)}}
        else
          {:error, {:invalid_option, :reference_satellite_id}}
        end

      _other ->
        {:error, {:invalid_option, :reference_satellite_id}}
    end
  end

  defp decode_rtk_reference_report({"satellite", sat, []}), do: sat
  defp decode_rtk_reference_report({"per_system", "", refs}), do: Map.new(refs)

  defp decode_rtk_double_difference({sat, ref, ambiguity_id, code_m, phase_m}) do
    %{
      satellite_id: sat,
      reference_satellite_id: ref,
      ambiguity_id: ambiguity_id,
      code_m: code_m,
      phase_m: phase_m
    }
  end

  defp ensure_nonempty_epochs([]), do: {:error, :no_epochs}
  defp ensure_nonempty_epochs(_epochs), do: :ok

  defp validate_options(opts, allowed) when is_list(opts) do
    if Keyword.keyword?(opts) do
      allowed = MapSet.new(allowed)

      case Enum.find(Keyword.keys(opts), &(not MapSet.member?(allowed, &1))) do
        nil -> :ok
        key -> {:error, {:invalid_option, key}}
      end
    else
      {:error, {:invalid_option, :opts}}
    end
  end

  defp validate_options(_opts, _allowed), do: {:error, {:invalid_option, :opts}}

  defp normalize_dual_baseline_epochs(epochs) do
    epochs
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {epoch, idx}, {:ok, acc} ->
      case normalize_dual_baseline_epoch(epoch, idx) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, _reason} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, _reason} = err -> err
    end
  end

  defp normalize_dual_baseline_epoch(
         %{
           base_observations: base_observations,
           rover_observations: rover_observations,
           satellite_positions_m: satellite_positions
         } = epoch,
         idx
       )
       when is_list(base_observations) and is_list(rover_observations) and is_map(satellite_positions) do
    base_satellite_positions = Map.get(epoch, :base_satellite_positions_m, satellite_positions)
    rover_satellite_positions = Map.get(epoch, :rover_satellite_positions_m, satellite_positions)

    with {:ok, base} <-
           normalize_dual_observations(base_observations, :invalid_base_observations),
         {:ok, rover} <-
           normalize_dual_observations(rover_observations, :invalid_rover_observations),
         {:ok, positions} <- normalize_satellite_positions(satellite_positions),
         {:ok, base_positions} <- normalize_satellite_positions(base_satellite_positions),
         {:ok, rover_positions} <- normalize_satellite_positions(rover_satellite_positions) do
      {:ok,
       %{
         idx: idx,
         epoch: Map.get(epoch, :epoch, idx),
         base: base,
         rover: rover,
         positions: positions,
         base_positions: base_positions,
         rover_positions: rover_positions
       }}
    end
  end

  defp normalize_dual_baseline_epoch(_epoch, idx), do: {:error, {:invalid_epoch_observations, idx}}

  defp normalize_dual_observations(observations, error_tag) do
    Observations.normalize_dual_frequency(observations,
      container: :map,
      sort?: false,
      include_raw?: false,
      lli: :dual,
      error_tag: error_tag,
      validate_lli?: true
    )
  end

  defp wide_lane_arc_config_term(config) do
    %{
      base_m: arc_vec3(Map.fetch!(config, :base_m)),
      reference: arc_reference_term(Map.fetch!(config, :reference)),
      min_epochs: Map.fetch!(config, :min_epochs),
      tolerance_cycles: Map.fetch!(config, :tolerance_cycles) / 1.0,
      skip_short_fragments: Map.fetch!(config, :skip_short_fragments),
      cycle_slip: Map.fetch!(config, :cycle_slip)
    }
  end

  defp ionosphere_free_arc_config_term(config) do
    %{
      base_m: arc_vec3(Map.fetch!(config, :base_m)),
      initial_baseline_m: arc_vec3(Map.fetch!(config, :initial_baseline_m)),
      reference: arc_reference_term(Map.fetch!(config, :reference)),
      apply_troposphere: Map.fetch!(config, :apply_troposphere)
    }
  end

  defp dual_frequency_arc_epoch_terms(epochs, apply_troposphere?) do
    epochs
    |> Enum.with_index()
    |> Enum.map(fn {epoch, idx} -> dual_frequency_arc_epoch_term(epoch, idx, apply_troposphere?) end)
  end

  defp dual_frequency_arc_epoch_term(epoch, idx, apply_troposphere?) do
    {jd_whole, jd_fraction} =
      if apply_troposphere? do
        Sidereon.GNSS.Time.epoch_to_split_jd(epoch.epoch)
      else
        {0.0, 0.0}
      end

    %{
      jd_whole: jd_whole,
      jd_fraction: jd_fraction,
      epoch_sort_key: inspect(epoch.epoch),
      gap_time_s: rtk_gap_time_s(epoch.epoch),
      observations:
        epoch
        |> dual_epoch_common_sats()
        |> Enum.map(fn sat ->
          %{
            satellite_id: sat,
            base: dual_frequency_observation_term(Map.fetch!(epoch.base, sat)),
            rover: dual_frequency_observation_term(Map.fetch!(epoch.rover, sat))
          }
        end),
      satellite_positions_m: rtk_position_terms(epoch.positions),
      base_satellite_positions_m: rtk_position_terms(epoch.base_positions),
      rover_satellite_positions_m: rtk_position_terms(epoch.rover_positions),
      velocity_mps: nil,
      prediction_time_s: idx / 1.0
    }
  end

  defp dual_frequency_observation_term(obs) do
    %{
      ambiguity_id: obs.ambiguity_id,
      p1_m: obs.p1_m,
      p2_m: obs.p2_m,
      phi1_cycles: obs.phi1_cyc,
      phi2_cycles: obs.phi2_cyc,
      f1_hz: obs.f1_hz,
      f2_hz: obs.f2_hz,
      lli1: obs.lli1,
      lli2: obs.lli2
    }
  end

  defp decode_wide_lane_arc_solution(
         {references, wide_lane_cycles, epoch_terms, dropped_sats, split_arc_terms, geometry_quality},
         input_epochs
       ) do
    %{
      references: Map.new(references),
      wide_lane_cycles: Map.new(wide_lane_cycles),
      epochs: decode_dual_frequency_arc_epochs(input_epochs, epoch_terms),
      dropped_sats: dropped_sats,
      split_arcs: decode_rtk_cycle_slip_split_arcs(input_epochs, split_arc_terms),
      geometry_quality: GeometryQuality.from_nif(geometry_quality)
    }
  end

  defp decode_wide_lane_arc_error({:cycle_slip_detected, receiver, sat, epoch_idx, reasons}, epochs) do
    {:error,
     {:cycle_slip_detected, decode_rtk_cycle_slip_receiver(receiver), sat, epoch_value(epochs, epoch_idx),
      Enum.map(reasons, &decode_rtk_cycle_slip_reason/1)}}
  end

  defp decode_wide_lane_arc_error({"cycle_slip_detected", receiver, sat, epoch_idx, reasons}, epochs) do
    {:error,
     {:cycle_slip_detected, decode_rtk_cycle_slip_receiver(receiver), sat, epoch_value(epochs, epoch_idx),
      Enum.map(reasons, &decode_rtk_cycle_slip_reason/1)}}
  end

  defp decode_wide_lane_arc_error(reason, _epochs), do: {:error, reason}

  defp decode_dual_frequency_arc_epochs(input_epochs, epoch_terms) do
    Enum.map(epoch_terms, fn term ->
      idx = dual_frequency_epoch_index(term)
      source = Enum.at(input_epochs, idx)
      decode_dual_frequency_arc_epoch(source, term)
    end)
  end

  defp dual_frequency_epoch_index(
         {_jd_whole, _jd_fraction, _sort_key, _gap, _obs, _pos, _base_pos, _rover_pos, _vel, idx}
       )
       when is_number(idx), do: trunc(idx)

  defp decode_dual_frequency_arc_epoch(
         source,
         {_jd_whole, _jd_fraction, _sort_key, _gap, observation_terms, positions, base_positions, rover_positions,
          _velocity, _prediction_time}
       ) do
    observations = decode_dual_frequency_observations(observation_terms)

    %{
      source
      | base: Map.new(observations, fn {sat, base, _rover} -> {sat, base} end),
        rover: Map.new(observations, fn {sat, _base, rover} -> {sat, rover} end),
        positions: Map.new(positions),
        base_positions: Map.new(base_positions),
        rover_positions: Map.new(rover_positions)
    }
  end

  defp decode_dual_frequency_observations(terms) do
    Enum.map(terms, fn {sat, base, rover} ->
      {sat, decode_dual_frequency_observation(sat, base), decode_dual_frequency_observation(sat, rover)}
    end)
  end

  defp decode_dual_frequency_observation(sat, {ambiguity_id, p1_m, p2_m, phi1_cyc, phi2_cyc, f1_hz, f2_hz, lli1, lli2}) do
    %{
      satellite_id: sat,
      ambiguity_id: ambiguity_id,
      p1_m: p1_m,
      p2_m: p2_m,
      phi1_cyc: phi1_cyc,
      phi2_cyc: phi2_cyc,
      f1_hz: f1_hz,
      f2_hz: f2_hz,
      lli1: lli1,
      lli2: lli2
    }
  end

  defp decode_ionosphere_free_arc_solution({references, if_epoch_terms, wavelength_terms, offset_terms}, input_epochs) do
    {
      decode_ionosphere_free_arc_epochs(input_epochs, if_epoch_terms),
      Map.new(wavelength_terms),
      Map.new(offset_terms),
      Map.new(references)
    }
  end

  defp decode_ionosphere_free_arc_epochs(input_epochs, if_epoch_terms) do
    Enum.map(if_epoch_terms, fn
      {base_obs, rover_obs, positions, base_positions, rover_positions, _velocity, idx} when is_number(idx) ->
        source = Enum.at(input_epochs, trunc(idx))

        %{
          epoch: source.epoch,
          base_observations: Enum.map(base_obs, &decode_rtk_if_arc_observation/1),
          rover_observations: Enum.map(rover_obs, &decode_rtk_if_arc_observation/1),
          satellite_positions_m: Map.new(positions),
          base_satellite_positions_m: Map.new(base_positions),
          rover_satellite_positions_m: Map.new(rover_positions)
        }
    end)
  end

  defp decode_rtk_if_arc_observation({sat, ambiguity_id, code_m, phase_m, _lli}) do
    %{
      satellite_id: sat,
      ambiguity_id: ambiguity_id,
      code_m: code_m,
      phase_m: phase_m
    }
  end

  defp rtk_gap_time_s(%NaiveDateTime{} = epoch) do
    NaiveDateTime.diff(epoch, @gap_reference, :microsecond) / 1_000_000.0
  end

  defp rtk_gap_time_s(epoch) when is_number(epoch), do: epoch / 1.0
  defp rtk_gap_time_s(_epoch), do: nil

  defp dual_epoch_common_sats(epoch) do
    epoch_sats(epoch)
    |> MapSet.to_list()
    |> Enum.sort()
  end

  defp rtk_position_terms(positions) do
    positions
    |> Enum.sort_by(fn {sat, _pos} -> sat end)
    |> Enum.map(fn {sat, position} -> {sat, position} end)
  end

  defp normalize_satellite_positions(positions) do
    positions
    |> Enum.reduce_while({:ok, %{}}, fn
      {sat, position}, {:ok, acc} when is_binary(sat) ->
        case Types.normalize_ecef(position, :invalid_satellite_position) do
          {:ok, ecef} -> {:cont, {:ok, Map.put(acc, sat, ecef)}}
          {:error, _reason} -> {:halt, {:error, {:invalid_satellite_position, sat}}}
        end

      {sat, _position}, {:ok, _acc} ->
        {:halt, {:error, {:invalid_satellite_position, sat}}}
    end)
  end

  defp decode_rtk_cycle_slip_split_arcs(epochs, split_arc_terms) do
    Enum.map(split_arc_terms, fn {receiver, sat, ambiguity_id, start_idx, end_idx, n_epochs} ->
      %{
        receiver: decode_rtk_cycle_slip_receiver(receiver),
        satellite_id: sat,
        ambiguity_id: ambiguity_id,
        start_epoch: epoch_value(epochs, start_idx),
        end_epoch: epoch_value(epochs, end_idx),
        n_epochs: n_epochs
      }
    end)
  end

  defp epoch_value(epochs, idx), do: epochs |> Enum.at(idx) |> Map.fetch!(:epoch)

  defp decode_rtk_cycle_slip_receiver("base"), do: :base
  defp decode_rtk_cycle_slip_receiver("rover"), do: :rover

  defp decode_rtk_cycle_slip_reason("lli"), do: :lli
  defp decode_rtk_cycle_slip_reason("data_gap"), do: :data_gap
  defp decode_rtk_cycle_slip_reason("geometry_free"), do: :geometry_free
  defp decode_rtk_cycle_slip_reason("melbourne_wubbena"), do: :melbourne_wubbena

  defp epoch_sats(epoch) do
    epoch.base
    |> Map.keys()
    |> MapSet.new()
    |> MapSet.intersection(epoch.rover |> Map.keys() |> MapSet.new())
    |> MapSet.intersection(epoch.positions |> Map.keys() |> MapSet.new())
    |> MapSet.intersection(epoch.base_positions |> Map.keys() |> MapSet.new())
    |> MapSet.intersection(epoch.rover_positions |> Map.keys() |> MapSet.new())
  end

  defp decode_rtk_float_status("state_tolerance"), do: :state_tolerance
  defp decode_rtk_float_status("max_iterations"), do: :max_iterations

  defp decode_rtk_float_residual(
         {epoch_idx, sat, ref_sat, ambiguity_id, code_m, phase_m, code_sigma_m, phase_sigma_m, code_normalized,
          phase_normalized},
         epochs
       ) do
    epoch = epochs |> Enum.find(&(&1.idx == epoch_idx)) |> Map.fetch!(:epoch)

    %{
      epoch: epoch,
      satellite_id: sat,
      reference_satellite_id: ref_sat,
      ambiguity_id: ambiguity_id,
      code_m: code_m,
      phase_m: phase_m,
      code_sigma_m: code_sigma_m,
      phase_sigma_m: phase_sigma_m,
      code_normalized: code_normalized,
      phase_normalized: phase_normalized
    }
  end

  defp decode_rtk_float_solution(
         {baseline, ambiguities, covariance_m, covariance_inverse_m, residual_terms,
          {iterations, converged?, status, code_rms_m, phase_rms_m, weighted_rms_m, n_observations, geometry_quality}},
         base,
         epochs,
         refs,
         physical_sats,
         ambiguity_ids,
         ambiguity_satellites,
         weights,
         prep_meta
       ) do
    rover = add3(base, baseline)

    residuals =
      residual_terms
      |> Enum.map(&decode_rtk_float_residual(&1, epochs))
      |> Enum.sort_by(&{inspect(&1.epoch), &1.satellite_id, &1.ambiguity_id})

    {:ok,
     %FloatBaselineSolution{
       baseline_m: ecef_map(baseline),
       rover_position_m: ecef_map(rover),
       reference_satellite_id: reference_satellite_report(refs),
       used_sats: ambiguity_ids,
       ambiguities_m: Map.new(ambiguities),
       residuals_m: residuals,
       metadata: %{
         iterations: iterations,
         converged: converged?,
         status: decode_rtk_float_status(status),
         physical_sats: physical_sats,
         reference_satellites: refs,
         ambiguity_satellites: ambiguity_satellites,
         ambiguity_float: %{
           order: ambiguity_ids,
           covariance_m: covariance_m,
           covariance_inverse_m: covariance_inverse_m
         },
         measurement_covariance: %{
           model: :double_difference,
           code_sigma_m: weights.code_sigma_m,
           phase_sigma_m: weights.phase_sigma_m,
           stochastic_model: weights.stochastic_model,
           elevation_weighting: weights.elevation_weighting?,
           sagnac: weights.sagnac?,
           min_elevation_sin: @min_elevation_sin
         },
         code_rms_m: code_rms_m,
         phase_rms_m: phase_rms_m,
         weighted_rms_m: weighted_rms_m,
         geometry_quality: GeometryQuality.from_nif(geometry_quality),
         n_epochs: length(epochs),
         n_observations: n_observations,
         dropped_sats:
           Enum.uniq(
             prep_meta.dropped_sats ++
               Map.get(prep_meta, :elevation_masked_sats, [])
           )
           |> Enum.sort(),
         dropped_cycle_slip_sats: prep_meta.dropped_sats,
         elevation_mask_deg: Map.get(prep_meta, :elevation_mask_deg),
         elevation_masked_sats: Map.get(prep_meta, :elevation_masked_sats, []),
         split_cycle_slip_arcs: prep_meta.split_arcs,
         code_smoothing: Map.get(prep_meta, :code_smoothing, false),
         code_smoothing_window_cap: Map.get(prep_meta, :code_smoothing_window_cap)
       }
     }}
  end

  defp decode_rtk_fixed_solution(
         {baseline, _free_ambiguities, fixed_cycle_terms, fixed_m_terms, residual_terms,
          {iterations, converged?, status, code_rms_m, phase_rms_m, weighted_rms_m, n_observations}, search_meta_term},
         base,
         epochs,
         refs,
         physical_sats,
         ambiguity_ids,
         ambiguity_satellites,
         weights,
         float_sol
       ) do
    rover = add3(base, baseline)
    fixed_cycles = Map.new(fixed_cycle_terms)
    fixed_m = Map.new(fixed_m_terms)
    fixed_meta = decode_fixed_search_meta(search_meta_term)

    residuals =
      residual_terms
      |> Enum.map(&decode_rtk_float_residual(&1, epochs))
      |> Enum.sort_by(&{inspect(&1.epoch), &1.satellite_id, &1.ambiguity_id})

    {:ok,
     %FixedBaselineSolution{
       baseline_m: ecef_map(baseline),
       rover_position_m: ecef_map(rover),
       reference_satellite_id: reference_satellite_report(refs),
       used_sats: ambiguity_ids,
       fixed_ambiguities_cycles: fixed_cycles,
       fixed_ambiguities_m: fixed_m,
       float_solution: float_sol,
       residuals_m: residuals,
       metadata:
         Map.merge(fixed_meta, %{
           iterations: iterations,
           converged: converged?,
           status: decode_rtk_float_status(status),
           code_rms_m: code_rms_m,
           phase_rms_m: phase_rms_m,
           weighted_rms_m: weighted_rms_m,
           n_epochs: length(epochs),
           n_observations: n_observations,
           physical_sats: physical_sats,
           reference_satellites: refs,
           ambiguity_satellites: ambiguity_satellites,
           dropped_cycle_slip_sats: Map.get(float_sol.metadata, :dropped_cycle_slip_sats, []),
           elevation_mask_deg: Map.get(float_sol.metadata, :elevation_mask_deg),
           elevation_masked_sats: Map.get(float_sol.metadata, :elevation_masked_sats, []),
           split_cycle_slip_arcs: Map.get(float_sol.metadata, :split_cycle_slip_arcs, []),
           measurement_covariance: %{
             model: :double_difference,
             code_sigma_m: weights.code_sigma_m,
             phase_sigma_m: weights.phase_sigma_m,
             stochastic_model: weights.stochastic_model,
             elevation_weighting: weights.elevation_weighting?,
             sagnac: weights.sagnac?,
             min_elevation_sin: @min_elevation_sin
           }
         })
     }}
  end

  defp maybe_put_residual_validation(metadata, nil, _epochs), do: metadata

  defp maybe_put_residual_validation(metadata, {threshold_sigma, max_exclusions, excluded_sats, exclusions}, epochs) do
    Map.put(metadata, :residual_validation, %{
      threshold_sigma: threshold_sigma,
      max_exclusions: max_exclusions,
      excluded_sats: excluded_sats,
      exclusions: Enum.map(exclusions, &decode_residual_validation_outlier(&1, epochs))
    })
  end

  defp decode_residual_validation_outlier(
         {epoch_idx, sat, ref_sat, ambiguity_id, kind, residual_m, sigma_m, normalized_residual, threshold_sigma},
         epochs
       ) do
    epoch = epochs |> Enum.find(&(&1.idx == epoch_idx)) |> Map.fetch!(:epoch)

    %{
      epoch: epoch,
      satellite_id: sat,
      reference_satellite_id: ref_sat,
      ambiguity_id: ambiguity_id,
      kind: decode_residual_validation_kind(kind),
      residual_m: residual_m,
      sigma_m: sigma_m,
      normalized_residual: normalized_residual,
      threshold_sigma: threshold_sigma
    }
  end

  defp decode_residual_validation_kind("code"), do: :code
  defp decode_residual_validation_kind("phase"), do: :phase

  defp decode_fixed_search_meta(
         {status, method, ratio, best_score, second_best_score, candidates,
          {order, float_cycles, covariance_cycles, covariance_inverse_cycles}, offsets,
          {partial_enabled?, partial_fixed?, partial_fixed_ids, partial_free_ids, full_set,
           exhaustive_subsets_evaluated}}
       ) do
    %{
      integer_status: decode_fixed_integer_status(status),
      integer_method: decode_fixed_integer_method(method),
      integer_ratio: decode_fixed_optional_number(ratio),
      integer_best_score: decode_fixed_optional_number(best_score),
      integer_second_best_score: decode_fixed_optional_number(second_best_score),
      integer_candidates: candidates,
      ambiguity_search: %{
        order: order,
        float_cycles: Map.new(float_cycles),
        covariance_cycles: covariance_cycles,
        covariance_inverse_cycles: covariance_inverse_cycles
      },
      ambiguity_offsets_m: Map.new(offsets),
      partial_ambiguity_resolution: partial_enabled?,
      partial_fixed: partial_fixed?,
      partial_fixed_ambiguities: partial_fixed_ids,
      partial_free_ambiguities: partial_free_ids
    }
    |> maybe_put_fixed_full_set(full_set)
    |> maybe_put_fixed_exhaustive_count(exhaustive_subsets_evaluated)
  end

  defp maybe_put_fixed_full_set(meta, nil), do: meta

  defp maybe_put_fixed_full_set(meta, {status, ratio, best_score, second_best_score, candidates, order}) do
    Map.put(meta, :partial_full_set, %{
      integer_status: decode_fixed_integer_status(status),
      integer_ratio: decode_fixed_optional_number(ratio),
      integer_best_score: decode_fixed_optional_number(best_score),
      integer_second_best_score: decode_fixed_optional_number(second_best_score),
      integer_candidates: candidates,
      order: order
    })
  end

  defp maybe_put_fixed_exhaustive_count(meta, nil), do: meta

  defp maybe_put_fixed_exhaustive_count(meta, count), do: Map.put(meta, :partial_exhaustive_subsets_evaluated, count)

  defp decode_fixed_integer_status("fixed"), do: :fixed
  defp decode_fixed_integer_status("not_fixed"), do: :not_fixed

  defp decode_fixed_integer_method("lambda"), do: :lambda

  defp decode_fixed_optional_number(nil), do: nil
  defp decode_fixed_optional_number(:infinity), do: :infinity
  defp decode_fixed_optional_number(value), do: value

  defp rust_receiver_antenna_corrections_term(nil), do: nil

  defp rust_receiver_antenna_corrections_term(%{base: base, rover: rover}) do
    {
      rust_receiver_antenna_correction_term(base),
      rust_receiver_antenna_correction_term(rover)
    }
  end

  defp rust_receiver_antenna_correction_term(%{antenna: antenna, frequency: frequency}) do
    AntennaTerms.receiver_correction_term(antenna, frequency)
  end

  defp rust_innovation_screen_meta(nil), do: nil

  defp rust_innovation_screen_meta(
         {threshold, min_rows, input_rows, accepted_rows, rejected_rows, rejected_code_rows,
          {rejected_phase_rows, max_normalized, max_rejected_normalized, coasted?}}
       ) do
    %{
      threshold_sigma: threshold,
      min_rows: min_rows,
      input_rows: input_rows,
      accepted_rows: accepted_rows,
      rejected_rows: rejected_rows,
      rejected_code_rows: rejected_code_rows,
      rejected_phase_rows: rejected_phase_rows,
      max_abs_normalized_innovation: max_normalized,
      max_rejected_abs_normalized_innovation: max_rejected_normalized,
      coasted?: coasted?
    }
  end

  defp add3({ax, ay, az}, {bx, by, bz}), do: {ax + bx, ay + by, az + bz}

  defp ecef_map({x, y, z}), do: %{x_m: x, y_m: y, z_m: z}
end
