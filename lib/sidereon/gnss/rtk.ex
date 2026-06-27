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

  `double_differences/3` returns the normalized measurements. The float solver,
  `solve_float_baseline_epochs/3`, estimates one static base-to-rover baseline
  from code and carrier-phase double differences, keeping one float carrier
  ambiguity per non-reference double-difference arc across the data. Clean arcs
  use the physical satellite id (for example `"G05"`) as the ambiguity id; split
  arcs use explicit ids so a cycle slip resets the ambiguity without pretending
  the satellite disappeared.
  `solve_fixed_baseline_epochs/3` adds LAMBDA integer least-squares ambiguity
  fixing on top of the same correlated double-difference covariance and
  re-solves the baseline with the selected integers held fixed.

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
  alias Sidereon.GNSS.Antex
  alias Sidereon.GNSS.Core.AntennaTerms
  alias Sidereon.GNSS.Core.Observations
  alias Sidereon.GNSS.Core.Types
  alias Sidereon.NIF

  @default_max_iterations 8
  @default_position_tolerance_m 1.0e-4
  @default_ambiguity_tolerance_m 1.0e-4
  @default_code_sigma_m 1.0
  @default_phase_sigma_m 0.02
  @default_stochastic_model :simple
  @default_integer_search_radius_cycles 1
  @default_integer_ratio_threshold 3.0
  @default_integer_candidate_limit 200_000
  @default_partial_min_ambiguities 4
  @default_max_residual_exclusions 1
  @default_cycle_slip_policy :error
  @default_gf_threshold_m 0.05
  @default_mw_threshold_cycles 4.0
  @default_min_arc_gap_s 300.0
  @gap_reference ~N[2000-01-01 00:00:00]
  @default_sagnac true
  @default_hatch_window_cap 100
  @default_filter_baseline_prior_sigma_m 100.0
  @default_filter_ambiguity_prior_sigma_m 1_000.0
  @default_filter_hold_sigma_m 1.0e-4
  @default_filter_process_noise_baseline_sigma_m 0.0
  @default_filter_dynamics_model :constant_position
  @default_filter_innovation_screen_min_rows 8
  @rtk_filter_state_version 3
  @min_elevation_sin 0.05
  @double_difference_options [:reference_satellite_id]
  @float_baseline_options [
    :reference_satellite_id,
    :initial_baseline_m,
    :code_sigma_m,
    :phase_sigma_m,
    :stochastic_model,
    :on_cycle_slip,
    :elevation_weighting,
    :sagnac,
    :receiver_antenna_corrections,
    :elevation_mask_deg,
    :code_smoothing,
    :hatch_window_cap,
    :max_iterations,
    :position_tolerance_m,
    :ambiguity_tolerance_m
  ]
  @integer_baseline_options [
    :ambiguity_wavelength_m,
    :ambiguity_offset_m,
    :integer_search_radius_cycles,
    :integer_ratio_threshold,
    :integer_candidate_limit,
    :partial_ambiguity_resolution,
    :partial_min_ambiguities,
    :float_only_systems
  ]
  @residual_validation_options [:residual_threshold_sigma, :max_residual_exclusions]
  # The opt-in estimation-strategy selector, accepted only on the static
  # baseline solves wired through the shared estimate() selector
  # (solve_float_baseline_epochs/3, solve_fixed_baseline_epochs/3). The sequential
  # filter and wide-lane paths are deliberately excluded: they run through NIFs
  # that do not thread a strategy, so accepting :strategy there would silently
  # ignore it.
  @strategy_baseline_option [:strategy]
  @fixed_baseline_options @float_baseline_options ++
                            @integer_baseline_options ++ @residual_validation_options
  @filter_baseline_options @fixed_baseline_options ++
                             [
                               :baseline_prior_sigma_m,
                               :ambiguity_prior_sigma_m,
                               :hold_sigma_m,
                               :process_noise_baseline_sigma_m,
                               :dynamics_model,
                               :ar_arming_sigma_m,
                               :innovation_screen_sigma,
                               :innovation_screen_min_rows,
                               :filter_kernel
                             ]
  @dual_wide_lane_options [
    :wide_lane_min_epochs,
    :wide_lane_tolerance_cycles,
    :gf_threshold_m,
    :mw_threshold_cycles,
    :troposphere
  ]
  @widelane_baseline_options (@fixed_baseline_options --
                                [:ambiguity_wavelength_m, :ambiguity_offset_m]) ++
                               @dual_wide_lane_options
  @widelane_filter_options (@filter_baseline_options --
                              [:ambiguity_wavelength_m, :ambiguity_offset_m]) ++
                             @dual_wide_lane_options
  @widelane_delegate_drop_options @dual_wide_lane_options ++
                                    [:ambiguity_wavelength_m, :ambiguity_offset_m]

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
      :wide_lane_ambiguities_cycles,
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
      :wide_lane_ambiguities_cycles,
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
            wide_lane_ambiguities_cycles: %{String.t() => integer()} | nil,
            float_solution: FloatBaselineSolution.t(),
            residuals_m: [FloatBaselineSolution.residual()],
            metadata: %{
              required(:iterations) => pos_integer(),
              required(:converged) => boolean(),
              required(:status) => :state_tolerance | :max_iterations,
              required(:integer_status) => :fixed | :not_fixed,
              required(:integer_method) => :lambda | :widelane_narrowlane_lambda,
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
              optional(:wide_lane_fixed) => boolean(),
              optional(:wide_lane_ambiguities_cycles) => %{String.t() => integer()},
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

  defmodule FilterBaselineSolution do
    @moduledoc """
    Sequential RTK baseline-filter result.
    """

    @enforce_keys [
      :baseline_m,
      :rover_position_m,
      :reference_satellite_id,
      :fixed_ambiguities_cycles,
      :epochs,
      :metadata
    ]
    defstruct [
      :baseline_m,
      :rover_position_m,
      :reference_satellite_id,
      :fixed_ambiguities_cycles,
      :epochs,
      :metadata
    ]

    @type ecef :: %{x_m: float(), y_m: float(), z_m: float()}

    @type epoch_result :: %{
            epoch: term(),
            index: non_neg_integer(),
            baseline_m: ecef(),
            integer_status: :fixed | :not_fixed,
            integer_ratio: float() | :infinity | nil,
            integer_best_score: float() | nil,
            integer_second_best_score: float() | nil,
            integer_candidates: non_neg_integer() | nil,
            ambiguity_search: map() | nil,
            residuals_m: [FloatBaselineSolution.residual()],
            newly_fixed_ambiguities: [String.t()],
            fixed_ambiguities: [String.t()]
          }

    @type t :: %__MODULE__{
            baseline_m: ecef(),
            rover_position_m: ecef(),
            reference_satellite_id: String.t() | %{String.t() => String.t()},
            fixed_ambiguities_cycles: %{String.t() => integer()},
            epochs: [epoch_result()],
            metadata: map()
          }
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
  Solve a static float RTK baseline from multi-epoch double differences.

  `base_position` is the surveyed base ECEF position. Each epoch supplies base
  and rover code/carrier observations plus satellite ECEF positions at that
  receive epoch:

      epoch = %{
        epoch: ~N[2026-01-01 00:00:00],
        satellite_positions_m: %{"G01" => {21.0e6, 14.0e6, 20.0e6}, ...},
        # Optional when base/rover transmit-time satellite positions differ:
        base_satellite_positions_m: %{"G01" => {21.0e6, 14.0e6, 20.0e6}, ...},
        rover_satellite_positions_m: %{"G01" => {21.0e6, 14.0e6, 20.0e6}, ...},
        base_observations: [%{satellite_id: "G01", code_m: p_base, phase_m: l_base}, ...],
        rover_observations: [%{satellite_id: "G01", code_m: p_rover, phase_m: l_rover}, ...]
      }

      {:ok, sol} = Sidereon.GNSS.RTK.solve_float_baseline_epochs(base_position, [epoch])

  The model is

      DD = [rho_rover(s) - rho_base(s)] - [rho_rover(ref) - rho_base(ref)]

  for code, and the same geometry plus one float carrier ambiguity per
  non-reference satellite for phase. Receiver clocks and any satellite-common
  short-baseline errors cancel before the solve.

  The normal equations use the full double-difference covariance block for each
  epoch and measurement kind. Double-difference rows sharing the reference
  satellite are therefore correlated, and the returned
  `metadata.ambiguity_float` contains the resulting float ambiguity covariance
  and inverse covariance in metres.

  The reference satellite must be available in every epoch. Other satellites may
  appear in only part of the arc; each available non-reference observation
  contributes a row, and split cycle-slip fragments become independent ambiguity
  ids.

  Options:

    * `:reference_satellite_id` - fixed double-difference reference. Accepts a
      satellite id binary (single-system data only) or a per-system map such as
      `%{"G" => "G04", "E" => "E11"}` covering every observed system. When
      omitted, each system uses its highest-average-elevation satellite common
      to every epoch in which the system appears, with a lexicographic
      tie-break. Every non-reference satellite forms its double difference
      against its own system's reference; there are no cross-system double
      differences.
    * `:initial_baseline_m` - initial base-to-rover ECEF vector, default
      `{0.0, 0.0, 0.0}`.
    * `:code_sigma_m` / `:phase_sigma_m` - undifferenced receiver measurement
      sigmas in metres. The solver propagates them into the non-diagonal
      double-difference covariance where rows sharing the reference satellite
      are correlated. Defaults are `#{@default_code_sigma_m}` and
      `#{@default_phase_sigma_m}`.
    * `:stochastic_model` - `:simple` (default) uses constant sigmas, optionally
      scaled by `:elevation_weighting`. `:rtklib` uses RTKLIB's floor-plus-
      elevation single-difference variance shape, treating `:code_sigma_m` and
      `:phase_sigma_m` as the model's constant/elevation coefficients in
      metres.
    * `:on_cycle_slip` - what to do when a base or rover observation carries an
      LLI loss-of-lock bit: `:error` returns
      `{:error, {:cycle_slip_detected, receiver, sat, epoch, [:lli]}}`
      (default); `:drop_satellite` removes that satellite from the arc;
      `:split_arc` starts a new ambiguity arc at the slipped epoch.
    * `:elevation_weighting` - when `true`, scales each undifferenced
      measurement sigma by `1 / max(sin(elevation), #{@min_elevation_sin})`
      before propagating the double-difference covariance. Default `false`
      preserves the constant-sigma, transcendental-free solve path.
    * `:sagnac` - when `true` (default), applies the standard first-order
      Earth-rotation correction to each receiver-satellite range before
      forming double differences. Set `false` only for synthetic fixtures whose
      observations were generated from plain Euclidean range.
    * `:elevation_mask_deg` - optional elevation mask in degrees. Satellites
      below the mask at the base station are removed before reference selection
      and ambiguity construction.
    * `:code_smoothing` - when `true`, applies per-receiver/per-ambiguity-arc
      Hatch carrier smoothing to code observations before forming double
      differences. Default `false`.
    * `:hatch_window_cap` - maximum Hatch smoothing window when
      `:code_smoothing` is enabled (default `#{@default_hatch_window_cap}`).
    * `:receiver_antenna_corrections` - optional receiver antenna PCO/PCV
      corrections by station. Expected format:
      `%{base: corr, rover: corr}` where `corr` is
      `%{antenna: %Antex.Antenna{}, frequency: "G01"}` or
      `%{antenna: {antex, "TYPE"}, frequency: "G01"}`. Missing or malformed
      values return `{:error, {:invalid_option, :receiver_antenna_corrections}}`.
      Omitted correction leaves behavior unchanged.
    * `:max_iterations`, `:position_tolerance_m`,
      `:ambiguity_tolerance_m`.

  Returns `{:ok, %FloatBaselineSolution{}}` or a tagged error.
  """
  @spec solve_float_baseline_epochs(ecef_input(), [baseline_epoch()], keyword()) ::
          {:ok, FloatBaselineSolution.t()} | {:error, term()}
  def solve_float_baseline_epochs(base_position, epochs, opts \\ [])

  def solve_float_baseline_epochs(base_position, epochs, opts) when is_list(epochs) do
    with :ok <- validate_options(opts, @float_baseline_options ++ @strategy_baseline_option),
         {:ok, strategy} <- baseline_strategy(opts),
         {:ok, receiver_antenna_corrections} <- receiver_antenna_corrections(opts),
         {:ok, base} <- Types.normalize_ecef(base_position, :invalid_base_position),
         {:ok, normalized_epochs, prep_meta} <- prepare_baseline_epochs(base, epochs, opts),
         {:ok, all_sats} <- all_epoch_sats(normalized_epochs),
         :ok <- ensure_baseline_satellites(all_sats),
         {:ok, refs} <-
           baseline_reference_satellites(opts, base, normalized_epochs, all_sats),
         {:ok, solve_opts} <- baseline_solve_options(opts),
         {:ok, weights} <- baseline_weights(opts),
         {:ok, initial_baseline} <- initial_baseline(opts),
         {:ok, ambiguity_ids, ambiguity_satellites} <-
           baseline_ambiguity_index(normalized_epochs, all_sats, refs) do
      physical_sats = nonreference_sats(all_sats, refs)

      if baseline_row_count(normalized_epochs, refs) <
           baseline_unknown_count(ambiguity_ids) do
        {:error,
         {:underdetermined, baseline_row_count(normalized_epochs, refs),
          baseline_unknown_count(ambiguity_ids)}}
      else
        solve_float_baseline_epochs_rust(
          base,
          normalized_epochs,
          refs,
          physical_sats,
          ambiguity_ids,
          ambiguity_satellites,
          weights,
          solve_opts,
          initial_baseline,
          prep_meta,
          receiver_antenna_corrections,
          strategy
        )
      end
    end
  end

  def solve_float_baseline_epochs(_base_position, _epochs, _opts), do: {:error, :invalid_epochs}

  @doc """
  Solve a static RTK baseline with integer-fixed double-difference ambiguities.

  The function first runs `solve_float_baseline_epochs/3`, converts the float
  double-difference ambiguities from metres to cycles using
  `:ambiguity_wavelength_m`, runs the shared LAMBDA/MLAMBDA integer
  least-squares search with the correlated float ambiguity covariance, and then
  re-solves the baseline with the selected integer ambiguities held fixed.

  Required option:

    * `:ambiguity_wavelength_m` - either a positive scalar wavelength in metres
      for every non-reference satellite, or a map `%{"G05" => wavelength_m, ...}`.
    * `:ambiguity_offset_m` - optional fixed ambiguity offset in metres, either
      a scalar or a map keyed by ambiguity id / physical satellite id. The fixed
      carrier ambiguity model is `offset_m + integer * wavelength_m`. Defaults
      to zero and is useful for dual-frequency wide-lane/narrow-lane workflows
      where the wide-lane integer contributes a known ionosphere-free offset.

  Integer search options mirror `Sidereon.GNSS.PrecisePositioning`:

    * `:integer_ratio_threshold` - default `#{@default_integer_ratio_threshold}`.
    * `:integer_search_radius_cycles` / `:integer_candidate_limit` - retained
      and still validated for backward compatibility, but no longer bound the
      search: ambiguity resolution uses the LAMBDA method (decorrelation +
      reduction + MLAMBDA search), which is not a search box.
    * `:partial_ambiguity_resolution` - when `true`, a rejected full-set
      integer fix is followed by confidence-ranked subset searches. A passing
      subset is held fixed while the remaining ambiguities stay in the re-solve
      as float states (default `false`).
    * `:partial_min_ambiguities` - minimum subset size for partial ambiguity
      resolution (default `#{@default_partial_min_ambiguities}`).
    * `:float_only_systems` - list of constellation letters (for example
      `["R"]`) whose double-difference ambiguities are never entered into the
      integer search; they contribute float measurement rows only. GLONASS is
      the canonical use: FDMA inter-channel biases break the clean DD integer
      assumption (default `[]`).
    * `:residual_threshold_sigma` - optional normalized-residual gate. When set,
      the float solve is checked before integer search; the worst offending
      satellite is excluded and the solve retried up to `:max_residual_exclusions`.
    * `:max_residual_exclusions` - maximum satellites the residual gate may
      exclude (default `#{@default_max_residual_exclusions}` when the residual
      gate is enabled).

  The fixed solution is returned even when the ratio test fails; in that case
  `metadata.integer_status` is `:not_fixed`.
  """
  @spec solve_fixed_baseline_epochs(ecef_input(), [baseline_epoch()], keyword()) ::
          {:ok, FixedBaselineSolution.t()} | {:error, term()}
  def solve_fixed_baseline_epochs(base_position, epochs, opts \\ [])

  def solve_fixed_baseline_epochs(base_position, epochs, opts) when is_list(epochs) do
    float_opts = Keyword.take(opts, @float_baseline_options)

    with :ok <- validate_options(opts, @fixed_baseline_options ++ @strategy_baseline_option),
         {:ok, strategy} <- baseline_strategy(opts),
         {:ok, float_only_systems} <- float_only_systems(opts),
         {:ok, residual_opts} <- residual_validation_options(opts),
         {:ok, receiver_antenna_corrections} <- receiver_antenna_corrections(opts),
         {:ok, base} <- Types.normalize_ecef(base_position, :invalid_base_position),
         {:ok, normalized_epochs, prep_meta} <- prepare_baseline_epochs(base, epochs, float_opts),
         {:ok, all_sats} <- all_epoch_sats(normalized_epochs),
         :ok <- ensure_baseline_satellites(all_sats),
         {:ok, refs} <-
           baseline_reference_satellites(float_opts, base, normalized_epochs, all_sats),
         {:ok, solve_opts} <- baseline_solve_options(float_opts),
         {:ok, weights} <- baseline_weights(float_opts),
         {:ok, initial_baseline} <- initial_baseline(float_opts),
         {:ok, ambiguity_ids, ambiguity_satellites} <-
           baseline_ambiguity_index(normalized_epochs, all_sats, refs),
         {:ok, wavelengths} <- ambiguity_wavelengths(ambiguity_ids, ambiguity_satellites, opts),
         {:ok, offsets} <- ambiguity_offsets(ambiguity_ids, ambiguity_satellites, opts),
         {:ok, integer_opts} <- integer_options(opts) do
      physical_sats = nonreference_sats(all_sats, refs)

      if baseline_row_count(normalized_epochs, refs) <
           baseline_unknown_count(ambiguity_ids) do
        {:error,
         {:underdetermined, baseline_row_count(normalized_epochs, refs),
          baseline_unknown_count(ambiguity_ids)}}
      else
        solve_fixed_baseline_epochs_validated_rust(
          base,
          normalized_epochs,
          refs,
          physical_sats,
          ambiguity_ids,
          ambiguity_satellites,
          wavelengths,
          offsets,
          weights,
          solve_opts,
          initial_baseline,
          integer_opts,
          float_only_systems,
          residual_opts,
          prep_meta,
          receiver_antenna_corrections,
          strategy
        )
      end
    end
  end

  def solve_fixed_baseline_epochs(_base_position, _epochs, _opts), do: {:error, :invalid_epochs}

  @doc """
  Run a sequential static RTK baseline filter with per-epoch ambiguity fixing.

  This is the RTKLIB-style real-time path: it carries one static baseline and
  one single-difference ambiguity state per satellite arc across epochs,
  performs a correlated double-difference measurement update at each epoch,
  attempts integer fixing from the posterior covariance of the corresponding
  double-difference ambiguity combinations, and holds accepted integers as tight
  pseudo-measurements on those combinations in later epochs.

  Options are the fixed-baseline options plus the filter parameters below.
  `:partial_ambiguity_resolution` is deliberately rejected for this entry
  point: the sequential filter only holds a full-set fix until partial
  sequential AR has post-fix validation against real data.

    * `:baseline_prior_sigma_m` - initial baseline prior sigma in metres
      (default `#{@default_filter_baseline_prior_sigma_m}`).
    * `:ambiguity_prior_sigma_m` - initial ambiguity prior sigma in metres
      (default `#{@default_filter_ambiguity_prior_sigma_m}`).
    * `:hold_sigma_m` - pseudo-measurement sigma for fixed ambiguity holds
      (default `#{@default_filter_hold_sigma_m}`).
    * `:dynamics_model` - `:constant_position` (default) keeps the carried
      baseline mean fixed between epochs. `:velocity_propagated` advances the
      prediction mean by each epoch's optional `:velocity_mps` times elapsed
      seconds; process-noise meaning is unchanged.
    * `:ar_arming_sigma_m` - optional convergence arming gate. When set, the
      per-epoch integer search is attempted only after the baseline-block
      posterior standard deviation (`sqrt` of the trace of the 3x3 position
      covariance) has converged to at most this value; below it the epoch
      stays float for the unfixed arcs. This stops premature commitment on
      poor-early-geometry arcs (for example PASA/SCOA L1, where it converts a
      confident-wrong fixed population to the oracle class). The gate is
      OPT-IN by design and defaults to `nil` (always armed). It is deliberately
      not default-on: the proxy keys on formal covariance convergence, not on
      truth accuracy, so a wavelength-tied default suppresses dozens of correct
      early fixes on clean, fast-converging arcs whose baseline is already
      truth-accurate from epoch 0. Measured on the Wettzell static and
      kinematic GPS L1 arcs (arming-default-measurement-2026-06.md), a quarter
      to half L1 wavelength default pushes first-fix from epoch 0 to 42 and
      drops fixed epochs from 120/120 to 78/120 (static) with no accuracy gain,
      so a single global default cannot serve both arc classes. Set this
      explicitly on arcs that need the protection.
    * `:innovation_screen_sigma` - optional predicted-residual screen in the
      Rust kernel. When set, epoch rows with `abs(innovation * weight)` above
      this value are rejected before the measurement update.
    * `:innovation_screen_min_rows` - minimum accepted row count for the
      innovation screen. If fewer rows survive, the epoch coasts on the
      predicted state (default `#{@default_filter_innovation_screen_min_rows}`).
    * `:filter_kernel` - selects `:rust` (default) or `:elixir`, the Elixir
      reference implementation, bit-identical to the kernel; every kernel capability is
      gated by === trace tests against it. The kernel carries the per-system
      references and honors `:float_only_systems`.

  Returns `{:ok, %FilterBaselineSolution{}}` or a tagged error.
  """
  @spec solve_filter_baseline_epochs(ecef_input(), [baseline_epoch()], keyword()) ::
          {:ok, FilterBaselineSolution.t()} | {:error, term()}
  def solve_filter_baseline_epochs(base_position, epochs, opts \\ [])

  def solve_filter_baseline_epochs(base_position, epochs, opts) when is_list(epochs) do
    float_opts = Keyword.take(opts, @float_baseline_options)

    with :ok <- validate_options(opts, @filter_baseline_options),
         {:ok, base} <- Types.normalize_ecef(base_position, :invalid_base_position),
         {:ok, filter_opts} <- sequential_filter_options(opts),
         {:ok, filter_kernel} <- filter_kernel(opts),
         {:ok, receiver_antenna_corrections} <- receiver_antenna_corrections(opts),
         :ok <-
           validate_filter_kernel_receiver_corrections(
             filter_kernel,
             receiver_antenna_corrections
           ),
         :ok <-
           validate_filter_kernel_ar_arming(filter_kernel, filter_opts.ar_arming_sigma_m),
         {:ok, float_only_systems} <- float_only_systems(opts),
         {:ok, normalized_epochs, prep_meta} <-
           prepare_baseline_epochs(
             base,
             epochs,
             float_opts,
             prediction_dt_mode(filter_opts.dynamics_model)
           ),
         {:ok, all_sats} <- all_epoch_sats(normalized_epochs),
         :ok <- ensure_baseline_satellites(all_sats),
         {:ok, refs} <-
           baseline_reference_satellites(opts, base, normalized_epochs, all_sats),
         {:ok, weights} <- baseline_weights(float_opts),
         {:ok, solve_opts} <- baseline_solve_options(float_opts),
         {:ok, initial_baseline} <- initial_baseline(float_opts),
         {:ok, sd_ambiguity_ids, sd_ambiguity_satellites} <-
           single_difference_ambiguity_index(normalized_epochs, all_sats),
         {:ok, dd_ambiguity_ids, dd_ambiguity_satellites, dd_ambiguity_pairs} <-
           sequential_dd_ambiguity_index(normalized_epochs, all_sats, refs),
         {:ok, wavelengths} <-
           ambiguity_wavelengths(dd_ambiguity_ids, dd_ambiguity_satellites, opts),
         {:ok, offsets} <- ambiguity_offsets(dd_ambiguity_ids, dd_ambiguity_satellites, opts),
         {:ok, integer_opts} <- integer_options(opts),
         :ok <- validate_filter_integer_options(integer_opts) do
      physical_sats = nonreference_sats(all_sats, refs)

      run_sequential_baseline_filter(
        base,
        normalized_epochs,
        refs,
        physical_sats,
        sd_ambiguity_ids,
        sd_ambiguity_satellites,
        dd_ambiguity_ids,
        dd_ambiguity_satellites,
        dd_ambiguity_pairs,
        float_only_systems,
        wavelengths,
        offsets,
        weights,
        solve_opts,
        integer_opts,
        filter_opts,
        initial_baseline,
        prep_meta,
        filter_kernel,
        receiver_antenna_corrections
      )
    end
  end

  def solve_filter_baseline_epochs(_base_position, _epochs, _opts), do: {:error, :invalid_epochs}

  defp validate_filter_integer_options(%{partial_ambiguity_resolution?: true}),
    do: {:error, {:unsupported_option, :partial_ambiguity_resolution}}

  defp validate_filter_integer_options(_integer_opts), do: :ok

  defp validate_filter_kernel_receiver_corrections(:elixir, _receiver_antenna_corrections),
    do: :ok

  defp validate_filter_kernel_receiver_corrections(:rust, _receiver_antenna_corrections), do: :ok

  defp validate_filter_kernel_ar_arming(_filter_kernel, _threshold_m), do: :ok

  defp receiver_antenna_corrections(opts) do
    case Keyword.get(opts, :receiver_antenna_corrections) do
      nil -> {:ok, nil}
      candidate -> parse_receiver_antenna_corrections(candidate)
    end
  end

  defp parse_receiver_antenna_corrections(%{base: base, rover: rover}) do
    with {:ok, parsed_base} <- parse_receiver_antenna_correction(base),
         {:ok, parsed_rover} <- parse_receiver_antenna_correction(rover) do
      {:ok, %{base: parsed_base, rover: parsed_rover}}
    else
      _ -> {:error, {:invalid_option, :receiver_antenna_corrections}}
    end
  end

  defp parse_receiver_antenna_corrections(_),
    do: {:error, {:invalid_option, :receiver_antenna_corrections}}

  defp parse_receiver_antenna_correction(%{antenna: antenna, frequency: frequency})
       when is_binary(frequency) do
    with {:ok, resolved_antenna} <- resolve_receiver_antenna(antenna),
         :ok <- validate_receiver_frequency(resolved_antenna, frequency) do
      {:ok, %{antenna: resolved_antenna, frequency: frequency}}
    else
      _ -> {:error, {:invalid_option, :receiver_antenna_corrections}}
    end
  end

  defp parse_receiver_antenna_correction(_),
    do: {:error, {:invalid_option, :receiver_antenna_corrections}}

  defp resolve_receiver_antenna(%Antex.Antenna{} = antenna), do: {:ok, antenna}

  defp resolve_receiver_antenna({%Antex{antennas: _} = antex, antenna_type})
       when is_binary(antenna_type) do
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

  defp ensure_single_widelane_system(epochs) do
    epochs
    |> Enum.reduce_while(MapSet.new(), fn epoch, systems ->
      systems =
        epoch
        |> dual_observation_sats()
        |> Enum.reduce(systems, fn sat, acc -> MapSet.put(acc, satellite_system(sat)) end)

      if MapSet.size(systems) > 1 do
        {:halt, {:error, {:unsupported_widelane, :multi_gnss}}}
      else
        {:cont, systems}
      end
    end)
    |> case do
      {:error, _reason} = err -> err
      _systems -> :ok
    end
  end

  defp dual_observation_sats(epoch) do
    epoch.base
    |> Map.keys()
    |> MapSet.new()
    |> MapSet.union(epoch.rover |> Map.keys() |> MapSet.new())
    |> MapSet.to_list()
  end

  defp reference_satellite_set(refs), do: refs |> Map.values() |> MapSet.new()

  defp nonreference_sats(all_sats, refs) do
    ref_set = reference_satellite_set(refs)
    Enum.reject(all_sats, &MapSet.member?(ref_set, &1))
  end

  # Reported reference shape: a single-system solve keeps today's bare satellite
  # id; a multi-system solve reports the per-system reference map.
  defp reference_satellite_report(refs) when map_size(refs) == 1, do: refs |> Map.values() |> hd()

  defp reference_satellite_report(refs), do: refs

  defp float_only_systems(opts) do
    case Keyword.get(opts, :float_only_systems, []) do
      systems when is_list(systems) ->
        if Enum.all?(systems, &system_letter?/1),
          do: {:ok, systems},
          else: {:error, {:invalid_option, :float_only_systems}}

      _other ->
        {:error, {:invalid_option, :float_only_systems}}
    end
  end

  defp system_letter?(<<letter>>) when letter in ?A..?Z, do: true
  defp system_letter?(_other), do: false

  defp float_only_ambiguity_ids(ambiguity_satellites, []) when is_map(ambiguity_satellites),
    do: MapSet.new()

  defp float_only_ambiguity_ids(ambiguity_satellites, float_only_systems)
       when is_map(ambiguity_satellites) do
    ambiguity_satellites
    |> Enum.filter(fn {_ambiguity_id, sat} -> satellite_system(sat) in float_only_systems end)
    |> MapSet.new(fn {ambiguity_id, _sat} -> ambiguity_id end)
  end

  # Per-system double-difference reference selection.
  #
  #   * no option: per system, the highest-average-elevation satellite of
  #     that system's common set (lexicographic tie-break), scored over the
  #     epochs in which the system appears;
  #   * binary (legacy): valid only when a single system is observed;
  #   * map: explicit per-system references covering every observed
  #     system.
  #
  # Returns `{:ok, %{"G" => "G04", ...}}`. With a single system this degenerates
  # to exactly today's selection (same candidate list, same scoring epochs).
  defp baseline_reference_satellites(opts, base, epochs, _all_sats) do
    with {:ok, reference} <- double_difference_reference_term(opts),
         {:ok, refs} <-
           NIF.rtk_baseline_reference_satellites(
             base,
             rtk_baseline_reference_epoch_terms(epochs),
             reference
           ) do
      {:ok, Map.new(refs)}
    end
  end

  defp rtk_baseline_reference_epoch_terms(epochs) do
    Enum.map(epochs, fn epoch ->
      {epoch |> epoch_sats() |> MapSet.to_list() |> Enum.sort(), Map.to_list(epoch.positions)}
    end)
  end

  @doc """
  Solve a static RTK baseline from raw dual-frequency observations by fixing
  wide-lane then narrow-lane double-difference ambiguities.

  This is the dual-frequency convenience layer above
  `solve_fixed_baseline_epochs/3`. Each base and rover observation must carry
  two code and phase measurements:

      %{
        satellite_id: "G05",
        p1_m: 20_200_000.0,
        p2_m: 20_200_004.0,
        phi1_cyc: 106_000_000.0,
        phi2_cyc: 82_000_000.0,
        f1_hz: 1_575_420_000.0,
        f2_hz: 1_227_600_000.0,
        lli1: 0,
        lli2: 0
      }

  For every non-reference double-difference arc the function estimates the
  Melbourne-Wubbena wide-lane integer first. It then forms ionosphere-free code
  and phase double differences and fixes the remaining narrow-lane integer with
  LAMBDA/MLAMBDA integer least-squares. The returned
  `fixed_ambiguities_cycles` are the narrow-lane integers;
  `wide_lane_ambiguities_cycles` reports the fixed wide-lane integers.

  This path is intentionally limited to one constellation at a time. If the
  normalized dual-frequency observations contain multiple constellation
  letters, it returns `{:error, {:unsupported_widelane, :multi_gnss}}` before
  wide-lane estimation.

  Options are the same as `solve_fixed_baseline_epochs/3`, except
  `:ambiguity_wavelength_m` and `:ambiguity_offset_m` are derived internally.
  Additional wide-lane options:

    * `:wide_lane_min_epochs` - minimum Melbourne-Wubbena epochs per
      double-difference arc (default `2`).
    * `:wide_lane_tolerance_cycles` - maximum absolute distance between the
      averaged wide-lane float value and the nearest integer (default `0.5`
      cycles).
    * `:on_cycle_slip` - `:error` (default), `:drop_satellite`, or `:split_arc`.
      Split arcs get fresh ambiguity ids and are fixed independently.
    * `:partial_ambiguity_resolution` - when `true`, a rejected full narrow-lane
      integer fix is followed by confidence-ranked subset searches (and, when
      the greedy ranking finds nothing, a largest-first exhaustive subset
      search). Holding the wide-lane integers fixed collapses the
      per-ambiguity bias for most satellites, so the dual-frequency partial fix
      can safely cover a larger subset than the single-frequency partial. The
      ratio threshold is never weakened (default `false`).
    * `:partial_min_ambiguities` - minimum subset size for partial ambiguity
      resolution (default `#{@default_partial_min_ambiguities}`).

  Returns `{:ok, %FixedBaselineSolution{}}` or a tagged error.
  """
  @spec solve_widelane_fixed_baseline_epochs(
          ecef_input(),
          [dual_frequency_baseline_epoch()],
          keyword()
        ) :: {:ok, FixedBaselineSolution.t()} | {:error, term()}
  def solve_widelane_fixed_baseline_epochs(base_position, dual_epochs, opts \\ [])

  def solve_widelane_fixed_baseline_epochs(base_position, dual_epochs, opts)
      when is_list(dual_epochs) do
    with :ok <- validate_options(opts, @widelane_baseline_options),
         {:ok, base} <- Types.normalize_ecef(base_position, :invalid_base_position),
         :ok <- ensure_nonempty_epochs(dual_epochs),
         {:ok, normalized_dual_epochs} <- normalize_dual_baseline_epochs(dual_epochs),
         :ok <- ensure_single_widelane_system(normalized_dual_epochs),
         {:ok, prepared_dual_epochs, slip_meta} <-
           prepare_dual_baseline_cycle_slips(normalized_dual_epochs, opts),
         {:ok, common_sats, _dropped_sats} <- common_epoch_sats(prepared_dual_epochs),
         :ok <- ensure_baseline_satellites(common_sats),
         {:ok, reference_sat} <-
           widelane_reference_satellite(opts, base, prepared_dual_epochs),
         {:ok, wide_lane_cycles} <-
           estimate_dual_baseline_wide_lanes(prepared_dual_epochs, reference_sat, opts),
         {:ok, tropo} <- dual_tropo_config(opts),
         {:ok, if_epochs, wavelengths, offsets} <-
           ionosphere_free_baseline_epochs(
             base,
             prepared_dual_epochs,
             reference_sat,
             wide_lane_cycles,
             tropo
           ),
         fixed_opts =
           opts
           |> Keyword.drop(@widelane_delegate_drop_options)
           |> Keyword.put(:reference_satellite_id, reference_sat)
           |> Keyword.put(:ambiguity_wavelength_m, wavelengths)
           |> Keyword.put(:ambiguity_offset_m, offsets),
         {:ok, %FixedBaselineSolution{} = sol} <-
           solve_fixed_baseline_epochs(base_position, if_epochs, fixed_opts) do
      used_wide_lane_cycles = Map.take(wide_lane_cycles, sol.used_sats)

      {:ok,
       %{
         sol
         | wide_lane_ambiguities_cycles: used_wide_lane_cycles,
           metadata:
             Map.merge(sol.metadata, %{
               integer_method: :widelane_narrowlane_lambda,
               wide_lane_fixed: true,
               wide_lane_ambiguities_cycles: used_wide_lane_cycles,
               dropped_cycle_slip_sats: slip_meta.dropped_sats,
               split_cycle_slip_arcs: slip_meta.split_arcs
             })
       }}
    end
  end

  def solve_widelane_fixed_baseline_epochs(_base_position, _dual_epochs, _opts),
    do: {:error, :invalid_epochs}

  @doc """
  Run a dual-frequency (L1/L2) sequential per-epoch fix-and-hold RTK filter.

  This is the sequential sibling of `solve_widelane_fixed_baseline_epochs/3`.
  The wide-lane double-difference integers are estimated per arc up front by
  Melbourne-Wubbena averaging (identical to the batch path); the narrow-lane
  single observable per satellite (wavelength `c/(f1+f2)`, offset
  `beta*lambda2*N_wl` with the wide-lane integer baked in) is then carried
  through the existing single-frequency sequential filter
  (`solve_filter_baseline_epochs/3`) with the per-ambiguity narrow-lane
  wavelength and offset maps. Removing the ionosphere via the iono-free
  combination eliminates the residual double-difference ionosphere that biased
  the single-frequency sequential path.

  Wide-lane fixing remains an arc batch pre-step (wide-lane double-difference
  ambiguities are arc-constant and Melbourne-Wubbena averaged, which is standard
  practice and what the oracle config implies). Per-epoch sequential carry of
  the wide-lane ambiguity as a separate filter state is not implemented here.

  Options are the same as `solve_filter_baseline_epochs/3` (including
  `:ar_arming_sigma_m`, `:hold_sigma_m`, `:baseline_prior_sigma_m`,
  `:filter_kernel`, ...), except `:ambiguity_wavelength_m` and
  `:ambiguity_offset_m` are derived internally, plus the wide-lane options of
  `solve_widelane_fixed_baseline_epochs/3` (`:wide_lane_min_epochs`,
  `:wide_lane_tolerance_cycles`, `:on_cycle_slip`, ...).

  This path is intentionally limited to one constellation at a time; multiple
  constellation letters return `{:error, {:unsupported_widelane, :multi_gnss}}`
  before wide-lane estimation.

  Returns `{:ok, %FilterBaselineSolution{}}` with `wide_lane_ambiguities_cycles`
  reported in `metadata`, or a tagged error.
  """
  @spec solve_widelane_filter_baseline_epochs(
          ecef_input(),
          [dual_frequency_baseline_epoch()],
          keyword()
        ) :: {:ok, FilterBaselineSolution.t()} | {:error, term()}
  def solve_widelane_filter_baseline_epochs(base_position, dual_epochs, opts \\ [])

  def solve_widelane_filter_baseline_epochs(base_position, dual_epochs, opts)
      when is_list(dual_epochs) do
    with :ok <- validate_options(opts, @widelane_filter_options),
         {:ok, base} <- Types.normalize_ecef(base_position, :invalid_base_position),
         :ok <- ensure_nonempty_epochs(dual_epochs),
         {:ok, normalized_dual_epochs} <- normalize_dual_baseline_epochs(dual_epochs),
         :ok <- ensure_single_widelane_system(normalized_dual_epochs),
         {:ok, prepared_dual_epochs, slip_meta} <-
           prepare_dual_baseline_cycle_slips(normalized_dual_epochs, opts),
         {:ok, common_sats, _dropped_sats} <- common_epoch_sats(prepared_dual_epochs),
         :ok <- ensure_baseline_satellites(common_sats),
         {:ok, reference_sat} <-
           widelane_reference_satellite(opts, base, prepared_dual_epochs),
         {:ok, wide_lane_cycles} <-
           estimate_dual_baseline_wide_lanes(prepared_dual_epochs, reference_sat, opts),
         {:ok, tropo} <- dual_tropo_config(opts),
         {:ok, if_epochs, wavelengths, offsets} <-
           ionosphere_free_baseline_epochs(
             base,
             prepared_dual_epochs,
             reference_sat,
             wide_lane_cycles,
             tropo
           ),
         filter_opts =
           opts
           |> Keyword.drop(@widelane_delegate_drop_options)
           |> Keyword.put(:reference_satellite_id, reference_sat)
           |> Keyword.put(:ambiguity_wavelength_m, wavelengths)
           |> Keyword.put(:ambiguity_offset_m, offsets),
         {:ok, %FilterBaselineSolution{} = sol} <-
           solve_filter_baseline_epochs(base_position, if_epochs, filter_opts) do
      used_wide_lane_cycles =
        Map.take(wide_lane_cycles, Map.get(sol.metadata, :physical_sats, []))

      {:ok,
       %{
         sol
         | metadata:
             Map.merge(sol.metadata, %{
               integer_method: :widelane_narrowlane_sequential,
               wide_lane_fixed: true,
               wide_lane_ambiguities_cycles: used_wide_lane_cycles,
               dropped_cycle_slip_sats:
                 Enum.uniq(sol.metadata.dropped_cycle_slip_sats ++ slip_meta.dropped_sats),
               split_cycle_slip_arcs: slip_meta.split_arcs
             })
       }}
    end
  end

  def solve_widelane_filter_baseline_epochs(_base_position, _dual_epochs, _opts),
    do: {:error, :invalid_epochs}

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

  def double_differences(_base_observations, _rover_observations, _opts),
    do: {:error, :invalid_observations}

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

  # The opt-in estimation-strategy selector forwarded to the RTK NIF. Absent or
  # `:reference` is the unchanged RTKLIB-faithful default; `:canonical` selects
  # the canonical (CanonicalSquareRoot owned-Cholesky) strategy in the GNSS crate.
  defp baseline_strategy(opts) do
    case Keyword.get(opts, :strategy, :reference) do
      :reference -> {:ok, :reference}
      :canonical -> {:ok, :canonical}
      _ -> {:error, {:invalid_option, :strategy}}
    end
  end

  defp residual_validation_options(opts) do
    threshold = Keyword.get(opts, :residual_threshold_sigma)
    max_exclusions = Keyword.get(opts, :max_residual_exclusions, @default_max_residual_exclusions)

    cond do
      not (is_integer(max_exclusions) and max_exclusions >= 0) ->
        {:error, {:invalid_option, :max_residual_exclusions}}

      is_nil(threshold) ->
        {:ok, %{enabled?: false, threshold_sigma: nil, max_exclusions: max_exclusions}}

      not (is_number(threshold) and threshold > 0.0) ->
        {:error, {:invalid_option, :residual_threshold_sigma}}

      true ->
        {:ok,
         %{
           enabled?: true,
           threshold_sigma: threshold / 1.0,
           max_exclusions: max_exclusions
         }}
    end
  end

  defp normalize_epochs(epochs, prediction_dt_mode) do
    epochs
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {epoch, idx}, {:ok, acc} ->
      case normalize_epoch(epoch, idx) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, _reason} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, normalized} ->
        normalized |> Enum.reverse() |> attach_prediction_dts(prediction_dt_mode)

      {:error, _reason} = err ->
        err
    end
  end

  defp normalize_epoch(
         %{
           base_observations: base_observations,
           rover_observations: rover_observations,
           satellite_positions_m: satellite_positions
         } = epoch,
         idx
       )
       when is_list(base_observations) and is_list(rover_observations) and
              is_map(satellite_positions) do
    base_satellite_positions = Map.get(epoch, :base_satellite_positions_m, satellite_positions)
    rover_satellite_positions = Map.get(epoch, :rover_satellite_positions_m, satellite_positions)

    with {:ok, base} <- normalize_observations(base_observations, :invalid_base_observations),
         {:ok, rover} <- normalize_observations(rover_observations, :invalid_rover_observations),
         {:ok, positions} <- normalize_satellite_positions(satellite_positions),
         {:ok, base_positions} <- normalize_satellite_positions(base_satellite_positions),
         {:ok, rover_positions} <- normalize_satellite_positions(rover_satellite_positions),
         {:ok, velocity_mps} <- normalize_epoch_velocity(epoch, idx) do
      {:ok,
       %{
         idx: idx,
         epoch: Map.get(epoch, :epoch, idx),
         prediction_time: Map.get(epoch, :epoch),
         base: base,
         rover: rover,
         positions: positions,
         base_positions: base_positions,
         rover_positions: rover_positions,
         velocity_mps: velocity_mps
       }}
    end
  end

  defp normalize_epoch(_epoch, idx), do: {:error, {:invalid_epoch_observations, idx}}

  defp normalize_epoch_velocity(epoch, idx) do
    case Map.get(epoch, :velocity_mps) do
      nil ->
        {:ok, nil}

      velocity ->
        case Types.normalize_ecef(velocity, {:invalid_velocity_mps, idx}) do
          {:ok, {vx, vy, vz} = normalized} ->
            if finite_number?(vx) and finite_number?(vy) and finite_number?(vz),
              do: {:ok, normalized},
              else: {:error, {:invalid_velocity_mps, idx}}

          {:error, _reason} = err ->
            err
        end
    end
  end

  defp finite_number?(value) when is_number(value), do: value - value == 0.0
  defp finite_number?(_value), do: false

  defp attach_prediction_dts(epochs, prediction_dt_mode) do
    epochs
    |> Enum.reduce_while({:ok, [], :no_previous}, fn epoch, {:ok, acc, prev_time} ->
      time = Map.get(epoch, :prediction_time)

      case prediction_dt_seconds(prev_time, time, prediction_dt_mode, epoch.idx) do
        {:ok, dt_s} ->
          epoch =
            epoch
            |> Map.put(:prediction_dt_s, dt_s)
            |> Map.delete(:prediction_time)

          {:cont, {:ok, [epoch | acc], time}}

        {:error, _reason} = err ->
          {:halt, err}
      end
    end)
    |> case do
      {:ok, epochs, _prev_time} -> {:ok, Enum.reverse(epochs)}
      {:error, _reason} = err -> err
    end
  end

  defp prediction_dt_seconds(:no_previous, _time, _mode, _idx), do: {:ok, 0.0}

  defp prediction_dt_seconds(prev_time, time, :lenient, _idx),
    do: {:ok, lenient_prediction_dt_seconds(prev_time, time)}

  defp prediction_dt_seconds(prev_time, time, :strict, idx) do
    case comparable_prediction_dt_seconds(prev_time, time) do
      {:ok, dt_s} -> {:ok, dt_s}
      :error -> {:error, {:invalid_epoch_time, idx}}
    end
  end

  defp lenient_prediction_dt_seconds(nil, _time), do: 0.0
  defp lenient_prediction_dt_seconds(_prev_time, nil), do: 0.0

  defp lenient_prediction_dt_seconds(prev_time, time) do
    case comparable_prediction_dt_seconds(prev_time, time) do
      {:ok, dt_s} -> dt_s
      :error -> 0.0
    end
  end

  defp comparable_prediction_dt_seconds(prev, time) when is_number(prev) and is_number(time) do
    if finite_number?(prev) and finite_number?(time),
      do: {:ok, (time - prev) / 1.0},
      else: :error
  end

  defp comparable_prediction_dt_seconds(%DateTime{} = prev, %DateTime{} = time),
    do: {:ok, DateTime.diff(time, prev, :microsecond) / 1_000_000.0}

  defp comparable_prediction_dt_seconds(%NaiveDateTime{} = prev, %NaiveDateTime{} = time),
    do: {:ok, NaiveDateTime.diff(time, prev, :microsecond) / 1_000_000.0}

  defp comparable_prediction_dt_seconds(%Date{} = prev, %Date{} = time),
    do: {:ok, Date.diff(time, prev) * 86_400.0}

  defp comparable_prediction_dt_seconds(_prev_time, _time), do: :error

  defp prediction_dt_mode(:velocity_propagated), do: :strict
  defp prediction_dt_mode(_dynamics_model), do: :lenient

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
       when is_list(base_observations) and is_list(rover_observations) and
              is_map(satellite_positions) do
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

  defp normalize_dual_baseline_epoch(_epoch, idx),
    do: {:error, {:invalid_epoch_observations, idx}}

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

  defp prepare_dual_baseline_cycle_slips(epochs, opts) do
    with {:ok, policy} <- rtk_cycle_slip_policy(opts),
         {gf_threshold_m, mw_threshold_cycles, min_arc_gap_s} <-
           rtk_dual_cycle_slip_options!(opts) do
      case NIF.rtk_prepare_dual_cycle_slip_epochs(
             rtk_dual_cycle_slip_epoch_terms(epochs),
             rtk_cycle_slip_policy_term(policy),
             gf_threshold_m,
             mw_threshold_cycles,
             min_arc_gap_s
           ) do
        {:ok, {prepared_terms, dropped_sats, split_arc_terms}} ->
          prepared = decode_rtk_dual_cycle_slip_epochs(epochs, prepared_terms, dropped_sats)

          meta = %{
            dropped_sats: dropped_sats,
            split_arcs: decode_rtk_cycle_slip_split_arcs(epochs, split_arc_terms)
          }

          {:ok, prepared, meta}

        {:error, {"cycle_slip_detected", receiver, sat, epoch_idx, reasons}} ->
          {:error,
           {:cycle_slip_detected, decode_rtk_cycle_slip_receiver(receiver), sat,
            epoch_value(epochs, epoch_idx), Enum.map(reasons, &decode_rtk_cycle_slip_reason/1)}}

        {:error, _reason} = err ->
          err
      end
    end
  end

  defp rtk_dual_cycle_slip_options!(opts) do
    {
      rtk_non_negative_slip_option!(
        :gf_threshold_m,
        Keyword.get(opts, :gf_threshold_m, @default_gf_threshold_m)
      ),
      rtk_non_negative_slip_option!(
        :mw_threshold_cycles,
        Keyword.get(opts, :mw_threshold_cycles, @default_mw_threshold_cycles)
      ),
      @default_min_arc_gap_s
    }
  end

  defp rtk_non_negative_slip_option!(_name, value) when is_number(value) and value >= 0.0,
    do: value / 1.0

  defp rtk_non_negative_slip_option!(name, value) do
    raise ArgumentError, "#{inspect(name)} must be a non-negative number, got: #{inspect(value)}"
  end

  defp rtk_dual_cycle_slip_epoch_terms(epochs) do
    Enum.map(epochs, fn epoch ->
      {
        inspect(epoch.epoch),
        rtk_gap_time_s(epoch.epoch),
        rtk_dual_cycle_slip_observation_terms(epoch.base),
        rtk_dual_cycle_slip_observation_terms(epoch.rover)
      }
    end)
  end

  defp rtk_gap_time_s(%NaiveDateTime{} = epoch) do
    NaiveDateTime.diff(epoch, @gap_reference, :microsecond) / 1_000_000.0
  end

  defp rtk_gap_time_s(epoch) when is_number(epoch), do: epoch / 1.0
  defp rtk_gap_time_s(_epoch), do: nil

  defp rtk_dual_cycle_slip_observation_terms(observations) do
    observations
    |> Enum.sort_by(fn {sat, _obs} -> sat end)
    |> Enum.map(fn {sat, obs} ->
      {
        sat,
        rtk_dual_observation_term(obs),
        obs.lli1,
        obs.lli2
      }
    end)
  end

  defp decode_rtk_dual_cycle_slip_epochs(epochs, prepared_terms, dropped_sats) do
    epochs
    |> Enum.zip(prepared_terms)
    |> Enum.map(fn {epoch, {base_terms, rover_terms}} ->
      epoch
      |> Map.merge(%{
        base: decode_rtk_dual_cycle_slip_observations(base_terms),
        rover: decode_rtk_dual_cycle_slip_observations(rover_terms)
      })
      |> drop_cycle_slip_position_sats(dropped_sats)
    end)
  end

  defp decode_rtk_dual_cycle_slip_observations(terms) do
    Map.new(terms, fn {sat, {ambiguity_id, p1_m, p2_m, phi1_cyc, phi2_cyc, f1_hz, f2_hz}, lli1,
                       lli2} ->
      {sat,
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
       }}
    end)
  end

  defp estimate_dual_baseline_wide_lanes(epochs, reference_sat, opts) do
    with {:ok, wl_opts} <- dual_wide_lane_options(opts) do
      split_arc? = Keyword.get(opts, :on_cycle_slip, @default_cycle_slip_policy) == :split_arc

      with {:ok, pairs} <-
             NIF.rtk_estimate_wide_lanes(
               rtk_wide_lane_epoch_terms(epochs),
               reference_sat,
               wl_opts.min_epochs,
               wl_opts.tolerance_cycles,
               split_arc?
             ) do
        {:ok, Map.new(pairs)}
      end
    end
  end

  defp dual_wide_lane_options(opts) do
    min_epochs = Keyword.get(opts, :wide_lane_min_epochs, 2)
    tolerance = Keyword.get(opts, :wide_lane_tolerance_cycles, 0.5)

    cond do
      not is_integer(min_epochs) or min_epochs < 1 ->
        {:error, {:invalid_option, :wide_lane_min_epochs}}

      not is_number(tolerance) or tolerance < 0.0 ->
        {:error, {:invalid_option, :wide_lane_tolerance_cycles}}

      true ->
        {:ok, %{min_epochs: min_epochs, tolerance_cycles: tolerance / 1.0}}
    end
  end

  defp rtk_wide_lane_epoch_terms(epochs) do
    Enum.map(epochs, fn epoch ->
      epoch
      |> dual_epoch_common_sats()
      |> Enum.map(fn sat ->
        {sat, rtk_dual_observation_term(Map.fetch!(epoch.base, sat)),
         rtk_dual_observation_term(Map.fetch!(epoch.rover, sat))}
      end)
    end)
  end

  defp rtk_dual_observation_term(obs) do
    {
      obs.ambiguity_id,
      obs.p1_m,
      obs.p2_m,
      obs.phi1_cyc,
      obs.phi2_cyc,
      obs.f1_hz,
      obs.f2_hz
    }
  end

  defp dual_epoch_common_sats(epoch) do
    epoch_sats(epoch)
    |> MapSet.to_list()
    |> Enum.sort()
  end

  defp ionosphere_free_baseline_epochs(base, dual_epochs, reference_sat, wide_lane_cycles, tropo) do
    with {:ok, epoch_terms} <- rtk_ionosphere_free_epoch_terms(dual_epochs, tropo.enabled?),
         wide_lane_terms = wide_lane_cycles |> Map.to_list() |> Enum.sort(),
         {:ok, {if_epoch_terms, wavelength_terms, offset_terms}} <-
           NIF.rtk_ionosphere_free_baseline_epochs(
             base,
             tropo.initial_baseline_m,
             epoch_terms,
             reference_sat,
             wide_lane_terms,
             tropo.enabled?
           ) do
      if_epochs = decode_rtk_ionosphere_free_epochs(dual_epochs, if_epoch_terms)
      wavelengths = Map.new(wavelength_terms)
      offsets = Map.new(offset_terms)
      {:ok, if_epochs, wavelengths, offsets}
    end
  end

  defp rtk_ionosphere_free_epoch_terms(dual_epochs, apply_troposphere?) do
    {:ok, Enum.map(dual_epochs, &rtk_ionosphere_free_epoch_term(&1, apply_troposphere?))}
  end

  defp rtk_ionosphere_free_epoch_term(epoch, apply_troposphere?) do
    {jd_whole, jd_fraction} =
      if apply_troposphere? do
        Sidereon.GNSS.Time.epoch_to_split_jd(epoch.epoch)
      else
        {0.0, 0.0}
      end

    observations =
      epoch
      |> dual_epoch_common_sats()
      |> Enum.map(fn sat ->
        base_obs = Map.fetch!(epoch.base, sat)
        rover_obs = Map.fetch!(epoch.rover, sat)
        {sat, rtk_dual_observation_term(base_obs), rtk_dual_observation_term(rover_obs)}
      end)

    {jd_whole, jd_fraction, rtk_position_terms(epoch.base_positions),
     rtk_position_terms(epoch.rover_positions), observations}
  end

  defp rtk_position_terms(positions) do
    positions
    |> Enum.sort_by(fn {sat, _pos} -> sat end)
    |> Enum.map(fn {sat, position} -> {sat, position} end)
  end

  defp decode_rtk_ionosphere_free_epochs(dual_epochs, if_epoch_terms) do
    Enum.map(if_epoch_terms, fn {idx, keep_sats, base_obs, rover_obs} ->
      epoch = Enum.at(dual_epochs, idx)

      %{
        epoch: epoch.epoch,
        base_observations: Enum.map(base_obs, &decode_rtk_if_observation/1),
        rover_observations: Enum.map(rover_obs, &decode_rtk_if_observation/1),
        satellite_positions_m: Map.take(epoch.positions, keep_sats),
        base_satellite_positions_m: Map.take(epoch.base_positions, keep_sats),
        rover_satellite_positions_m: Map.take(epoch.rover_positions, keep_sats)
      }
    end)
  end

  defp decode_rtk_if_observation({sat, ambiguity_id, code_m, phase_m}) do
    %{
      satellite_id: sat,
      ambiguity_id: ambiguity_id,
      code_m: code_m,
      phase_m: phase_m
    }
  end

  # Resolve the a-priori troposphere configuration for the dual-frequency
  # baseline. On by default (matches RTKLIB `pos1-tropopt=saas`), set
  # `troposphere: false` for an explicit byte-identical off path. The Rust core
  # owns the receiver geodetic conversion, meteorology, elevation, and slant
  # delay math; Elixir only validates the option and marshals the initial
  # baseline used for the rover approximate position.
  defp dual_tropo_config(opts) do
    case Keyword.get(opts, :troposphere, true) do
      false ->
        {:ok, %{enabled?: false, initial_baseline_m: {0.0, 0.0, 0.0}}}

      true ->
        with {:ok, baseline} <- initial_baseline(opts) do
          {:ok, %{enabled?: true, initial_baseline_m: baseline}}
        end

      _other ->
        {:error, {:invalid_option, :troposphere}}
    end
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

  defp prepare_epochs_for_cycle_slips(epochs, opts) do
    with {:ok, policy} <- rtk_cycle_slip_policy(opts) do
      case NIF.rtk_prepare_cycle_slip_epochs(
             rtk_cycle_slip_epoch_terms(epochs),
             rtk_cycle_slip_policy_term(policy)
           ) do
        {:ok, {prepared_terms, dropped_sats, split_arc_terms}} ->
          prepared = decode_rtk_cycle_slip_epochs(epochs, prepared_terms, dropped_sats)

          meta = %{
            dropped_sats: dropped_sats,
            split_arcs: decode_rtk_cycle_slip_split_arcs(epochs, split_arc_terms)
          }

          {:ok, prepared, meta}

        {:error, {"cycle_slip_detected", receiver, sat, epoch_idx, reasons}} ->
          {:error,
           {:cycle_slip_detected, decode_rtk_cycle_slip_receiver(receiver), sat,
            epoch_value(epochs, epoch_idx), Enum.map(reasons, &decode_rtk_cycle_slip_reason/1)}}

        {:error, _reason} = err ->
          err
      end
    end
  end

  defp rtk_cycle_slip_epoch_terms(epochs), do: rtk_code_smoothing_epoch_terms(epochs)

  defp rtk_cycle_slip_policy_term(:error), do: "error"
  defp rtk_cycle_slip_policy_term(:drop_satellite), do: "drop_satellite"
  defp rtk_cycle_slip_policy_term(:split_arc), do: "split_arc"

  defp decode_rtk_cycle_slip_epochs(epochs, prepared_terms, dropped_sats) do
    epochs
    |> Enum.zip(prepared_terms)
    |> Enum.map(fn {epoch, {base_terms, rover_terms}} ->
      epoch
      |> Map.merge(%{
        base: decode_rtk_code_smoothing_observations(base_terms),
        rover: decode_rtk_code_smoothing_observations(rover_terms)
      })
      |> drop_cycle_slip_position_sats(dropped_sats)
    end)
  end

  defp drop_cycle_slip_position_sats(epoch, []), do: epoch

  defp drop_cycle_slip_position_sats(epoch, dropped_sats) do
    %{
      epoch
      | positions: Map.drop(epoch.positions, dropped_sats),
        base_positions: Map.drop(epoch.base_positions, dropped_sats),
        rover_positions: Map.drop(epoch.rover_positions, dropped_sats)
    }
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

  defp prepare_baseline_epochs(base, epochs, opts, prediction_dt_mode \\ :lenient) do
    with :ok <- ensure_nonempty_epochs(epochs),
         {:ok, normalized_epochs} <- normalize_epochs(epochs, prediction_dt_mode),
         {:ok, normalized_epochs, slip_meta} <-
           prepare_epochs_for_cycle_slips(normalized_epochs, opts),
         {:ok, normalized_epochs, smoothing_meta} <-
           prepare_epochs_for_code_smoothing(normalized_epochs, opts),
         {:ok, normalized_epochs, mask_meta} <-
           apply_elevation_mask(base, normalized_epochs, opts) do
      {:ok, normalized_epochs, Map.merge(Map.merge(slip_meta, smoothing_meta), mask_meta)}
    end
  end

  defp prepare_epochs_for_code_smoothing(epochs, opts) do
    with {:ok, smoothing} <- rtk_code_smoothing(opts) do
      case smoothing do
        :none ->
          {:ok, epochs, %{code_smoothing: false, code_smoothing_window_cap: nil}}

        {:hatch, cap} ->
          with {:ok, smoothed_terms} <-
                 NIF.rtk_smooth_code_epochs(rtk_code_smoothing_epoch_terms(epochs), cap) do
            epochs = decode_rtk_code_smoothing_epochs(epochs, smoothed_terms)
            {:ok, epochs, %{code_smoothing: true, code_smoothing_window_cap: cap}}
          end
      end
    end
  end

  defp rtk_code_smoothing(opts) do
    case Keyword.get(opts, :code_smoothing, false) do
      value when value in [false, nil] ->
        {:ok, :none}

      value when value in [true, :hatch] ->
        cap = Keyword.get(opts, :hatch_window_cap, @default_hatch_window_cap)

        if is_integer(cap) and cap >= 1 do
          {:ok, {:hatch, cap}}
        else
          {:error, {:invalid_option, :hatch_window_cap}}
        end

      _other ->
        {:error, {:invalid_option, :code_smoothing}}
    end
  end

  defp rtk_code_smoothing_epoch_terms(epochs) do
    Enum.map(epochs, fn epoch ->
      {rtk_code_smoothing_observation_terms(epoch.base),
       rtk_code_smoothing_observation_terms(epoch.rover)}
    end)
  end

  defp rtk_code_smoothing_observation_terms(observations) do
    observations
    |> Enum.sort_by(fn {sat, _obs} -> sat end)
    |> Enum.map(fn {sat, obs} ->
      {sat, obs.ambiguity_id, obs.code_m, obs.phase_m, obs.lli}
    end)
  end

  defp decode_rtk_code_smoothing_epochs(epochs, smoothed_terms) do
    epochs
    |> Enum.zip(smoothed_terms)
    |> Enum.map(fn {epoch, {base_terms, rover_terms}} ->
      %{
        epoch
        | base: decode_rtk_code_smoothing_observations(base_terms),
          rover: decode_rtk_code_smoothing_observations(rover_terms)
      }
    end)
  end

  defp decode_rtk_code_smoothing_observations(terms) do
    Map.new(terms, fn {sat, ambiguity_id, code_m, phase_m, lli} ->
      {sat,
       %{
         satellite_id: sat,
         ambiguity_id: ambiguity_id,
         code_m: code_m,
         phase_m: phase_m,
         lli: lli
       }}
    end)
  end

  defp apply_elevation_mask(base, epochs, opts) do
    with {:ok, mask_deg} <- elevation_mask_deg(opts) do
      case mask_deg do
        nil ->
          {:ok, epochs, %{elevation_mask_deg: nil, elevation_masked_sats: []}}

        mask_deg ->
          with {:ok, {kept_by_epoch, masked}} <-
                 NIF.rtk_apply_elevation_mask(
                   base,
                   rtk_elevation_mask_epoch_terms(epochs),
                   mask_deg
                 ) do
            epochs =
              epochs
              |> Enum.zip(kept_by_epoch)
              |> Enum.map(fn {epoch, kept} ->
                %{
                  epoch
                  | base: Map.take(epoch.base, kept),
                    rover: Map.take(epoch.rover, kept),
                    positions: Map.take(epoch.positions, kept),
                    base_positions: Map.take(epoch.base_positions, kept),
                    rover_positions: Map.take(epoch.rover_positions, kept)
                }
              end)

            {:ok, epochs, %{elevation_mask_deg: mask_deg, elevation_masked_sats: masked}}
          end
      end
    end
  end

  defp rtk_elevation_mask_epoch_terms(epochs) do
    Enum.map(epochs, fn epoch -> Map.to_list(epoch.positions) end)
  end

  defp elevation_mask_deg(opts) do
    case Keyword.get(opts, :elevation_mask_deg) do
      nil ->
        {:ok, nil}

      deg when is_number(deg) and deg >= 0.0 and deg < 90.0 ->
        {:ok, deg / 1.0}

      _other ->
        {:error, {:invalid_option, :elevation_mask_deg}}
    end
  end

  defp rtk_cycle_slip_policy(opts) do
    case Keyword.get(opts, :on_cycle_slip, @default_cycle_slip_policy) do
      :error -> {:ok, :error}
      :drop_satellite -> {:ok, :drop_satellite}
      :split_arc -> {:ok, :split_arc}
      _other -> {:error, {:invalid_option, :on_cycle_slip}}
    end
  end

  defp common_epoch_sats(epochs) do
    per_epoch =
      Enum.map(epochs, fn epoch ->
        epoch_sats(epoch)
      end)

    common =
      per_epoch
      |> Enum.reduce(fn sats, acc -> MapSet.intersection(acc, sats) end)
      |> MapSet.to_list()
      |> Enum.sort()

    all =
      epochs
      |> Enum.reduce(MapSet.new(), fn epoch, acc ->
        epoch.base
        |> Map.keys()
        |> MapSet.new()
        |> MapSet.union(epoch.rover |> Map.keys() |> MapSet.new())
        |> MapSet.union(epoch.positions |> Map.keys() |> MapSet.new())
        |> MapSet.union(epoch.base_positions |> Map.keys() |> MapSet.new())
        |> MapSet.union(epoch.rover_positions |> Map.keys() |> MapSet.new())
        |> MapSet.union(acc)
      end)

    dropped =
      all
      |> MapSet.difference(MapSet.new(common))
      |> MapSet.to_list()
      |> Enum.sort()

    {:ok, common, dropped}
  end

  defp all_epoch_sats(epochs) do
    all =
      epochs
      |> Enum.reduce(MapSet.new(), fn epoch, acc ->
        epoch_sats(epoch)
        |> MapSet.union(acc)
      end)
      |> MapSet.to_list()
      |> Enum.sort()

    {:ok, all}
  end

  defp epoch_available_nonrefs(epoch, refs, physical_sats \\ nil) do
    available =
      epoch
      |> epoch_sats()
      |> MapSet.difference(reference_satellite_set(refs))

    case physical_sats do
      nil -> available
      sats -> MapSet.intersection(available, MapSet.new(sats))
    end
    |> MapSet.to_list()
    |> Enum.sort()
  end

  defp epoch_available_sats(epoch, physical_sats) do
    epoch
    |> epoch_sats()
    |> MapSet.intersection(MapSet.new(physical_sats))
    |> MapSet.to_list()
    |> Enum.sort()
  end

  defp epoch_sats(epoch) do
    epoch.base
    |> Map.keys()
    |> MapSet.new()
    |> MapSet.intersection(epoch.rover |> Map.keys() |> MapSet.new())
    |> MapSet.intersection(epoch.positions |> Map.keys() |> MapSet.new())
    |> MapSet.intersection(epoch.base_positions |> Map.keys() |> MapSet.new())
    |> MapSet.intersection(epoch.rover_positions |> Map.keys() |> MapSet.new())
  end

  defp ensure_baseline_satellites(common_sats) do
    if length(common_sats) < 4,
      do: {:error, {:too_few_common_satellites, length(common_sats), 4}},
      else: :ok
  end

  defp baseline_solve_options(opts) do
    max_iterations = Keyword.get(opts, :max_iterations, @default_max_iterations)
    position_tolerance_m = Keyword.get(opts, :position_tolerance_m, @default_position_tolerance_m)

    ambiguity_tolerance_m =
      Keyword.get(opts, :ambiguity_tolerance_m, @default_ambiguity_tolerance_m)

    cond do
      not (is_integer(max_iterations) and max_iterations > 0) ->
        {:error, {:invalid_option, :max_iterations}}

      not (is_number(position_tolerance_m) and position_tolerance_m > 0.0) ->
        {:error, {:invalid_option, :position_tolerance_m}}

      not (is_number(ambiguity_tolerance_m) and ambiguity_tolerance_m > 0.0) ->
        {:error, {:invalid_option, :ambiguity_tolerance_m}}

      true ->
        {:ok,
         %{
           max_iterations: max_iterations,
           position_tolerance_m: position_tolerance_m / 1.0,
           ambiguity_tolerance_m: ambiguity_tolerance_m / 1.0
         }}
    end
  end

  defp integer_options(opts) do
    radius =
      Keyword.get(opts, :integer_search_radius_cycles, @default_integer_search_radius_cycles)

    ratio = Keyword.get(opts, :integer_ratio_threshold, @default_integer_ratio_threshold)
    limit = Keyword.get(opts, :integer_candidate_limit, @default_integer_candidate_limit)
    partial? = Keyword.get(opts, :partial_ambiguity_resolution, false)
    partial_min = Keyword.get(opts, :partial_min_ambiguities, @default_partial_min_ambiguities)

    cond do
      not is_integer(radius) or radius < 0 ->
        {:error, {:invalid_option, :integer_search_radius_cycles}}

      # RTKLIB rejects thresar[0] < 1.0: the ratio test compares the
      # second-best to best residual, which is structurally >= 1, so a
      # threshold below 1.0 can never discriminate and is invalid.
      not is_number(ratio) or ratio < 1.0 ->
        {:error, {:invalid_option, :integer_ratio_threshold}}

      not is_integer(limit) or limit < 1 ->
        {:error, {:invalid_option, :integer_candidate_limit}}

      not is_boolean(partial?) ->
        {:error, {:invalid_option, :partial_ambiguity_resolution}}

      not is_integer(partial_min) or partial_min < 1 ->
        {:error, {:invalid_option, :partial_min_ambiguities}}

      true ->
        {:ok,
         %{
           radius_cycles: radius,
           ratio_threshold: ratio / 1.0,
           candidate_limit: limit,
           partial_ambiguity_resolution?: partial?,
           partial_min_ambiguities: partial_min
         }}
    end
  end

  defp sequential_filter_options(opts) do
    with {:ok, baseline_prior_sigma_m} <-
           positive_option(
             opts,
             :baseline_prior_sigma_m,
             @default_filter_baseline_prior_sigma_m
           ),
         {:ok, ambiguity_prior_sigma_m} <-
           positive_option(
             opts,
             :ambiguity_prior_sigma_m,
             @default_filter_ambiguity_prior_sigma_m
           ),
         {:ok, hold_sigma_m} <-
           positive_option(opts, :hold_sigma_m, @default_filter_hold_sigma_m),
         {:ok, process_noise_baseline_sigma_m} <-
           nonnegative_option(
             opts,
             :process_noise_baseline_sigma_m,
             @default_filter_process_noise_baseline_sigma_m
           ),
         {:ok, dynamics_model} <- dynamics_model(opts),
         {:ok, ar_arming_sigma_m} <- optional_positive_option(opts, :ar_arming_sigma_m),
         {:ok, innovation_screen} <- innovation_screen_options(opts) do
      {:ok,
       %{
         baseline_prior_sigma_m: baseline_prior_sigma_m,
         ambiguity_prior_sigma_m: ambiguity_prior_sigma_m,
         hold_sigma_m: hold_sigma_m,
         process_noise_baseline_sigma_m: process_noise_baseline_sigma_m,
         dynamics_model: dynamics_model,
         ar_arming_sigma_m: ar_arming_sigma_m,
         innovation_screen: innovation_screen
       }}
    end
  end

  defp optional_positive_option(opts, key) do
    case Keyword.get(opts, key) do
      nil -> {:ok, nil}
      value when is_number(value) and value > 0.0 -> {:ok, value / 1.0}
      _other -> {:error, {:invalid_option, key}}
    end
  end

  defp dynamics_model(opts) do
    case Keyword.get(opts, :dynamics_model, @default_filter_dynamics_model) do
      value when value in [:constant_position, :velocity_propagated] -> {:ok, value}
      _other -> {:error, {:invalid_option, :dynamics_model}}
    end
  end

  defp innovation_screen_options(opts) do
    threshold = Keyword.get(opts, :innovation_screen_sigma)

    min_rows =
      Keyword.get(opts, :innovation_screen_min_rows, @default_filter_innovation_screen_min_rows)

    cond do
      not is_nil(threshold) and (not is_number(threshold) or threshold <= 0.0) ->
        {:error, {:invalid_option, :innovation_screen_sigma}}

      not is_integer(min_rows) or min_rows < 1 ->
        {:error, {:invalid_option, :innovation_screen_min_rows}}

      is_nil(threshold) ->
        {:ok, %{enabled?: false, threshold_sigma: nil, min_rows: min_rows}}

      true ->
        {:ok, %{enabled?: true, threshold_sigma: threshold / 1.0, min_rows: min_rows}}
    end
  end

  defp filter_kernel(opts) do
    case Keyword.get(opts, :filter_kernel, :rust) do
      value when value in [:elixir, :rust] -> {:ok, value}
      _other -> {:error, {:invalid_option, :filter_kernel}}
    end
  end

  defp positive_option(opts, key, default) do
    value = Keyword.get(opts, key, default)

    if is_number(value) and value > 0.0,
      do: {:ok, value / 1.0},
      else: {:error, {:invalid_option, key}}
  end

  defp nonnegative_option(opts, key, default) do
    value = Keyword.get(opts, key, default)

    if is_number(value) and value >= 0.0,
      do: {:ok, value / 1.0},
      else: {:error, {:invalid_option, key}}
  end

  defp baseline_weights(opts) do
    with {:ok, code_sigma_m} <- measurement_sigma(opts, :code_sigma_m, @default_code_sigma_m),
         {:ok, phase_sigma_m} <- measurement_sigma(opts, :phase_sigma_m, @default_phase_sigma_m),
         {:ok, stochastic_model} <- stochastic_model(opts),
         {:ok, elevation_weighting?} <- elevation_weighting(opts),
         {:ok, sagnac?} <- sagnac(opts) do
      {:ok,
       %{
         code_sigma_m: code_sigma_m,
         phase_sigma_m: phase_sigma_m,
         stochastic_model: stochastic_model,
         elevation_weighting?: elevation_weighting?,
         sagnac?: sagnac?
       }}
    end
  end

  defp measurement_sigma(opts, key, default) do
    sigma = Keyword.get(opts, key, default)

    if is_number(sigma) and sigma > 0.0,
      do: {:ok, sigma / 1.0},
      else: {:error, {:invalid_sigma, key}}
  end

  defp elevation_weighting(opts) do
    case Keyword.get(opts, :elevation_weighting, false) do
      value when is_boolean(value) -> {:ok, value}
      _other -> {:error, {:invalid_option, :elevation_weighting}}
    end
  end

  defp sagnac(opts) do
    case Keyword.get(opts, :sagnac, @default_sagnac) do
      value when is_boolean(value) -> {:ok, value}
      _other -> {:error, {:invalid_option, :sagnac}}
    end
  end

  defp stochastic_model(opts) do
    case Keyword.get(opts, :stochastic_model, @default_stochastic_model) do
      value when value in [:simple, :rtklib] -> {:ok, value}
      _other -> {:error, {:invalid_option, :stochastic_model}}
    end
  end

  defp initial_baseline(opts) do
    opts
    |> Keyword.get(:initial_baseline_m, {0.0, 0.0, 0.0})
    |> Types.normalize_ecef(:invalid_initial_baseline)
  end

  defp baseline_ambiguity_index(epochs, common_sats, refs) do
    physical_sats = nonreference_sats(common_sats, refs)

    epochs
    |> Enum.reduce_while({:ok, %{}}, fn epoch, {:ok, acc} ->
      ref_sds = epoch_reference_sds(epoch, refs)

      epoch
      |> epoch_available_nonrefs(refs, physical_sats)
      |> Enum.reduce_while({:ok, acc}, fn sat, {:ok, acc} ->
        ref_dd = Map.fetch!(ref_sds, satellite_system(sat))
        ambiguity_id = double_difference_measurement(epoch, sat, ref_dd).ambiguity_id

        case Map.fetch(acc, ambiguity_id) do
          {:ok, ^sat} ->
            {:cont, {:ok, acc}}

          {:ok, other_sat} ->
            {:halt, {:error, {:duplicate_ambiguity_id, ambiguity_id, other_sat, sat}}}

          :error ->
            {:cont, {:ok, Map.put(acc, ambiguity_id, sat)}}
        end
      end)
      |> case do
        {:ok, acc} -> {:cont, {:ok, acc}}
        {:error, _reason} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, ambiguity_satellites} ->
        ambiguity_ids =
          ambiguity_satellites
          |> Enum.sort_by(fn {ambiguity_id, sat} -> {sat, ambiguity_id} end)
          |> Enum.map(&elem(&1, 0))

        {:ok, ambiguity_ids, Map.new(ambiguity_satellites)}

      {:error, _reason} = err ->
        err
    end
  end

  defp single_difference_ambiguity_index(epochs, all_sats) do
    epochs
    |> Enum.reduce_while({:ok, %{}}, fn epoch, {:ok, acc} ->
      epoch
      |> epoch_available_sats(all_sats)
      |> Enum.reduce_while({:ok, acc}, fn sat, {:ok, acc} ->
        ambiguity_id = single_difference(epoch, sat).ambiguity_id

        case Map.fetch(acc, ambiguity_id) do
          {:ok, ^sat} ->
            {:cont, {:ok, acc}}

          {:ok, other_sat} ->
            {:halt, {:error, {:duplicate_ambiguity_id, ambiguity_id, other_sat, sat}}}

          :error ->
            {:cont, {:ok, Map.put(acc, ambiguity_id, sat)}}
        end
      end)
      |> case do
        {:ok, acc} -> {:cont, {:ok, acc}}
        {:error, _reason} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, ambiguity_satellites} ->
        ambiguity_ids =
          ambiguity_satellites
          |> Enum.sort_by(fn {ambiguity_id, sat} -> {sat, ambiguity_id} end)
          |> Enum.map(&elem(&1, 0))

        {:ok, ambiguity_ids, Map.new(ambiguity_satellites)}

      {:error, _reason} = err ->
        err
    end
  end

  defp sequential_dd_ambiguity_index(epochs, all_sats, refs) do
    physical_sats = nonreference_sats(all_sats, refs)

    epochs
    |> Enum.reduce_while({:ok, {%{}, %{}}}, fn epoch, {:ok, {satellites, pairs}} ->
      ref_sds = epoch_reference_sds(epoch, refs)

      epoch
      |> epoch_available_nonrefs(refs, physical_sats)
      |> Enum.reduce_while({:ok, {satellites, pairs}}, fn sat, {:ok, {satellites, pairs}} ->
        ref_dd = Map.fetch!(ref_sds, satellite_system(sat))
        sd = single_difference(epoch, sat)
        dd_id = double_difference_ambiguity_id(sat, sd.ambiguity_id, ref_dd)
        pair = %{sat_sd_id: sd.ambiguity_id, ref_sd_id: ref_dd.ambiguity_id}

        case Map.fetch(satellites, dd_id) do
          {:ok, ^sat} ->
            {:cont, {:ok, {satellites, Map.put_new(pairs, dd_id, pair)}}}

          {:ok, other_sat} ->
            {:halt, {:error, {:duplicate_ambiguity_id, dd_id, other_sat, sat}}}

          :error ->
            {:cont, {:ok, {Map.put(satellites, dd_id, sat), Map.put(pairs, dd_id, pair)}}}
        end
      end)
      |> case do
        {:ok, acc} -> {:cont, {:ok, acc}}
        {:error, _reason} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, {ambiguity_satellites, pairs}} ->
        ambiguity_ids =
          ambiguity_satellites
          |> Enum.sort_by(fn {ambiguity_id, sat} -> {sat, ambiguity_id} end)
          |> Enum.map(&elem(&1, 0))

        {:ok, ambiguity_ids, Map.new(ambiguity_satellites), pairs}

      {:error, _reason} = err ->
        err
    end
  end

  defp ambiguity_wavelengths(ambiguity_ids, ambiguity_satellites, opts) do
    case Keyword.fetch(opts, :ambiguity_wavelength_m) do
      {:ok, wavelength} when is_number(wavelength) and wavelength > 0.0 ->
        {:ok, Map.new(ambiguity_ids, &{&1, wavelength / 1.0})}

      {:ok, wavelengths} when is_map(wavelengths) ->
        ambiguity_ids
        |> Enum.reduce_while({:ok, %{}}, fn sat, {:ok, acc} ->
          physical_sat = Map.fetch!(ambiguity_satellites, sat)

          case ambiguity_wavelength(wavelengths, sat, physical_sat) do
            {:ok, wavelength} when is_number(wavelength) and wavelength > 0.0 ->
              {:cont, {:ok, Map.put(acc, sat, wavelength / 1.0)}}

            _other ->
              {:halt, {:error, {:invalid_ambiguity_wavelength, sat}}}
          end
        end)

      {:ok, _other} ->
        {:error, {:invalid_option, :ambiguity_wavelength_m}}

      :error ->
        {:error, :ambiguity_wavelength_required}
    end
  end

  defp ambiguity_offsets(ambiguity_ids, ambiguity_satellites, opts) do
    case Keyword.fetch(opts, :ambiguity_offset_m) do
      {:ok, offset} when is_number(offset) ->
        {:ok, Map.new(ambiguity_ids, &{&1, offset / 1.0})}

      {:ok, offsets} when is_map(offsets) ->
        ambiguity_ids
        |> Enum.reduce_while({:ok, %{}}, fn sat, {:ok, acc} ->
          physical_sat = Map.fetch!(ambiguity_satellites, sat)

          case ambiguity_value(offsets, sat, physical_sat) do
            {:ok, offset} when is_number(offset) ->
              {:cont, {:ok, Map.put(acc, sat, offset / 1.0)}}

            _other ->
              {:halt, {:error, {:invalid_ambiguity_offset, sat}}}
          end
        end)

      {:ok, _other} ->
        {:error, {:invalid_option, :ambiguity_offset_m}}

      :error ->
        {:ok, Map.new(ambiguity_ids, &{&1, 0.0})}
    end
  end

  defp ambiguity_wavelength(wavelengths, ambiguity_id, physical_sat) do
    case ambiguity_value(wavelengths, ambiguity_id, physical_sat) do
      {:ok, _wavelength} = ok -> ok
      :error -> :error
    end
  end

  defp ambiguity_value(values, ambiguity_id, physical_sat) do
    case Map.fetch(values, ambiguity_id) do
      {:ok, _value} = ok -> ok
      :error -> Map.fetch(values, physical_sat)
    end
  end

  defp baseline_row_count(epochs, refs) do
    epochs
    |> Enum.map(fn epoch -> length(epoch_available_nonrefs(epoch, refs)) end)
    |> Enum.sum()
    |> Kernel.*(2)
  end

  defp baseline_unknown_count(ambiguity_ids), do: 3 + length(ambiguity_ids)

  # Per-epoch reference-satellite data, one entry per system whose reference is
  # observed in this epoch. The per-system common invariant guarantees the
  # reference is present in every epoch in which its system appears.
  defp epoch_reference_sds(epoch, refs) do
    available = epoch_sats(epoch)

    refs
    |> Enum.filter(fn {_system, ref} -> MapSet.member?(available, ref) end)
    |> Map.new(fn {system, ref} -> {system, single_difference(epoch, ref)} end)
  end

  defp single_difference(epoch, sat) do
    base_obs = Map.fetch!(epoch.base, sat)
    rover_obs = Map.fetch!(epoch.rover, sat)

    %{
      satellite_id: sat,
      code_m: rover_obs.code_m - base_obs.code_m,
      phase_m: rover_obs.phase_m - base_obs.phase_m,
      ambiguity_id: single_difference_ambiguity_id(sat, base_obs, rover_obs)
    }
  end

  defp double_difference_measurement(epoch, sat, ref_dd) do
    sd = single_difference(epoch, sat)

    %{
      code_m: sd.code_m - ref_dd.code_m,
      phase_m: sd.phase_m - ref_dd.phase_m,
      ambiguity_id: double_difference_ambiguity_id(sat, sd.ambiguity_id, ref_dd)
    }
  end

  defp single_difference_ambiguity_id(sat, base_obs, rover_obs) do
    case {base_obs.ambiguity_id, rover_obs.ambiguity_id} do
      {^sat, ^sat} -> sat
      {^sat, rover_id} -> rover_id
      {base_id, ^sat} -> base_id
      {same_id, same_id} -> same_id
      {base_id, rover_id} -> "#{sat}:base=#{base_id},rover=#{rover_id}"
    end
  end

  defp double_difference_ambiguity_id(sat, sat_sd_id, ref_dd) do
    if sat_sd_id == sat and ref_dd.ambiguity_id == ref_dd.satellite_id,
      do: sat,
      else: "#{sat_sd_id}|ref=#{ref_dd.ambiguity_id}"
  end

  defp solve_float_baseline_epochs_rust(
         base,
         epochs,
         refs,
         physical_sats,
         ambiguity_ids,
         ambiguity_satellites,
         weights,
         solve_opts,
         initial_baseline,
         prep_meta,
         receiver_antenna_corrections,
         strategy
       ) do
    rust_epochs = Enum.map(epochs, &rust_epoch_term(&1, refs, physical_sats))

    case NIF.rtk_solve_float_baseline(
           rust_epochs,
           base,
           ambiguity_ids,
           rust_model_term(weights),
           {initial_baseline, solve_opts.position_tolerance_m, solve_opts.ambiguity_tolerance_m,
            solve_opts.max_iterations},
           rust_receiver_antenna_corrections_term(receiver_antenna_corrections),
           strategy
         ) do
      {:ok,
       {baseline, ambiguities, covariance_m, covariance_inverse_m, residual_terms,
        {iterations, converged?, status, code_rms_m, phase_rms_m, weighted_rms_m, n_observations}}} ->
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

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_rtk_float_status("state_tolerance"), do: :state_tolerance
  defp decode_rtk_float_status("max_iterations"), do: :max_iterations

  defp decode_rtk_float_residual(
         {epoch_idx, sat, ref_sat, ambiguity_id, code_m, phase_m, code_sigma_m, phase_sigma_m,
          code_normalized, phase_normalized},
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
          {iterations, converged?, status, code_rms_m, phase_rms_m, weighted_rms_m,
           n_observations}},
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
          {iterations, converged?, status, code_rms_m, phase_rms_m, weighted_rms_m,
           n_observations}, search_meta_term},
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
       wide_lane_ambiguities_cycles: Map.get(fixed_meta, :wide_lane_ambiguities_cycles),
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

  defp solve_fixed_baseline_epochs_validated_rust(
         base,
         epochs,
         refs,
         physical_sats,
         ambiguity_ids,
         ambiguity_satellites,
         wavelengths,
         offsets,
         weights,
         solve_opts,
         initial_baseline,
         integer_opts,
         float_only_systems,
         residual_opts,
         prep_meta,
         receiver_antenna_corrections,
         strategy
       ) do
    rust_epochs = Enum.map(epochs, &rust_epoch_term(&1, refs, physical_sats))

    case NIF.rtk_solve_fixed_baseline_validated(
           rust_epochs,
           base,
           ambiguity_ids,
           Enum.sort(Map.to_list(wavelengths)),
           Enum.sort(Map.to_list(offsets)),
           Enum.sort(Map.to_list(ambiguity_satellites)),
           rust_model_term(weights),
           {initial_baseline, solve_opts.position_tolerance_m, solve_opts.ambiguity_tolerance_m,
            solve_opts.max_iterations},
           {solve_opts.position_tolerance_m, solve_opts.ambiguity_tolerance_m,
            solve_opts.max_iterations, integer_opts.ratio_threshold,
            integer_opts.partial_ambiguity_resolution?, integer_opts.partial_min_ambiguities,
            float_only_systems},
           {residual_opts.threshold_sigma, residual_opts.max_exclusions},
           rust_receiver_antenna_corrections_term(receiver_antenna_corrections),
           strategy
         ) do
      {:ok, {float_term, fixed_term, validation_term, used_ids, used_satellite_terms}} ->
        used_satellites = Map.new(used_satellite_terms)
        used_physical_sats = used_satellites |> Map.values() |> Enum.uniq() |> Enum.sort()

        {:ok, float_sol} =
          decode_rtk_float_solution(
            float_term,
            base,
            epochs,
            refs,
            used_physical_sats,
            used_ids,
            used_satellites,
            weights,
            prep_meta
          )

        {:ok, fixed_sol} =
          decode_rtk_fixed_solution(
            fixed_term,
            base,
            epochs,
            refs,
            used_physical_sats,
            used_ids,
            used_satellites,
            weights,
            float_sol
          )

        {:ok,
         %{
           fixed_sol
           | metadata:
               maybe_put_residual_validation(
                 fixed_sol.metadata,
                 validation_term,
                 epochs
               )
         }}

      {:error, reason} ->
        decode_validated_fixed_error(reason, epochs)
    end
  end

  defp maybe_put_residual_validation(metadata, nil, _epochs), do: metadata

  defp maybe_put_residual_validation(
         metadata,
         {threshold_sigma, max_exclusions, excluded_sats, exclusions},
         epochs
       ) do
    Map.put(metadata, :residual_validation, %{
      threshold_sigma: threshold_sigma,
      max_exclusions: max_exclusions,
      excluded_sats: excluded_sats,
      exclusions: Enum.map(exclusions, &decode_residual_validation_outlier(&1, epochs))
    })
  end

  defp decode_validated_fixed_error({:residual_validation_failed, outlier, exclusions}, epochs) do
    {:error,
     {:residual_validation_failed, decode_residual_validation_outlier(outlier, epochs),
      Enum.map(exclusions, &decode_residual_validation_outlier(&1, epochs))}}
  end

  defp decode_validated_fixed_error({:duplicate_ambiguity_id, id, first, second}, _epochs),
    do: {:error, {:duplicate_ambiguity_id, id, first, second}}

  defp decode_validated_fixed_error({:underdetermined, rows, unknowns}, _epochs),
    do: {:error, {:underdetermined, rows, unknowns}}

  defp decode_validated_fixed_error(reason, _epochs), do: {:error, reason}

  defp decode_residual_validation_outlier(
         {epoch_idx, sat, ref_sat, ambiguity_id, kind, residual_m, sigma_m, normalized_residual,
          threshold_sigma},
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

  defp maybe_put_fixed_full_set(
         meta,
         {status, ratio, best_score, second_best_score, candidates, order}
       ) do
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

  defp maybe_put_fixed_exhaustive_count(meta, count),
    do: Map.put(meta, :partial_exhaustive_subsets_evaluated, count)

  defp decode_fixed_integer_status("fixed"), do: :fixed
  defp decode_fixed_integer_status("not_fixed"), do: :not_fixed

  defp decode_fixed_integer_method("lambda"), do: :lambda

  defp decode_fixed_optional_number(nil), do: nil
  defp decode_fixed_optional_number(:infinity), do: :infinity
  defp decode_fixed_optional_number(value), do: value

  defp run_sequential_baseline_filter(
         base,
         epochs,
         refs,
         physical_sats,
         sd_ambiguity_ids,
         sd_ambiguity_satellites,
         _dd_ambiguity_ids,
         dd_ambiguity_satellites,
         dd_ambiguity_pairs,
         float_only_systems,
         wavelengths,
         offsets,
         weights,
         solve_opts,
         integer_opts,
         filter_opts,
         initial_baseline,
         prep_meta,
         filter_kernel,
         receiver_antenna_corrections
       ) do
    n = baseline_unknown_count(sd_ambiguity_ids)

    float_only_dd_ids =
      float_only_ambiguity_ids(dd_ambiguity_satellites, float_only_systems)

    {initial_ambiguities, initial_ambiguity_count} =
      initial_sequential_ambiguities(
        epochs,
        Map.values(refs) ++ physical_sats,
        sd_ambiguity_ids
      )

    initial = %{
      state: %{
        baseline: initial_baseline,
        ambiguities: initial_ambiguities
      },
      information:
        sequential_initial_information(
          n,
          filter_opts.baseline_prior_sigma_m,
          filter_opts.ambiguity_prior_sigma_m
        ),
      fixed_cycles: %{},
      fixed_m: %{},
      rust_state: nil,
      epochs: []
    }

    initial = %{
      initial
      | rust_state:
          rust_initial_filter_state(
            epochs,
            refs,
            initial_baseline,
            sd_ambiguity_ids,
            initial_ambiguities,
            filter_opts.baseline_prior_sigma_m,
            filter_opts.ambiguity_prior_sigma_m
          )
    }

    sequential_filter_epochs_rust(
      base,
      epochs,
      refs,
      physical_sats,
      dd_ambiguity_pairs,
      dd_ambiguity_satellites,
      float_only_dd_ids,
      float_only_systems,
      wavelengths,
      offsets,
      weights,
      solve_opts,
      integer_opts,
      filter_opts,
      receiver_antenna_corrections,
      initial
    )
    |> case do
      {:ok, acc} ->
        baseline = acc.state.baseline
        rover = add3(base, baseline)
        epoch_results = Enum.reverse(acc.epochs)
        first_fixed = Enum.find(epoch_results, &(&1.integer_status == :fixed))
        fixed_epochs = Enum.count(epoch_results, &(&1.integer_status == :fixed))

        {:ok,
         %FilterBaselineSolution{
           baseline_m: ecef_map(baseline),
           rover_position_m: ecef_map(rover),
           reference_satellite_id: reference_satellite_report(refs),
           fixed_ambiguities_cycles: acc.fixed_cycles,
           epochs: epoch_results,
           metadata: %{
             integer_method: :sequential_lambda,
             ambiguity_state: :single_difference,
             first_fixed_epoch: first_fixed && first_fixed.epoch,
             first_fixed_index: first_fixed && first_fixed.index,
             fixed_epoch_count: fixed_epochs,
             n_epochs: length(epochs),
             physical_sats: physical_sats,
             reference_satellites: refs,
             float_only_systems: float_only_systems,
             ambiguity_satellites: dd_ambiguity_satellites,
             single_difference_ambiguity_satellites: sd_ambiguity_satellites,
             single_difference_ambiguity_count: length(sd_ambiguity_ids),
             measurement_covariance: %{
               model: :double_difference,
               code_sigma_m: weights.code_sigma_m,
               phase_sigma_m: weights.phase_sigma_m,
               stochastic_model: weights.stochastic_model,
               elevation_weighting: weights.elevation_weighting?,
               sagnac: weights.sagnac?,
               min_elevation_sin: @min_elevation_sin
             },
             dropped_sats:
               Enum.uniq(prep_meta.dropped_sats ++ Map.get(prep_meta, :elevation_masked_sats, []))
               |> Enum.sort(),
             dropped_cycle_slip_sats: prep_meta.dropped_sats,
             elevation_mask_deg: Map.get(prep_meta, :elevation_mask_deg),
             elevation_masked_sats: Map.get(prep_meta, :elevation_masked_sats, []),
             split_cycle_slip_arcs: prep_meta.split_arcs,
             hold_sigma_m: filter_opts.hold_sigma_m,
             baseline_prior_sigma_m: filter_opts.baseline_prior_sigma_m,
             ambiguity_prior_sigma_m: filter_opts.ambiguity_prior_sigma_m,
             dynamics_model: filter_opts.dynamics_model,
             ambiguity_initialization: :phase_code,
             initialized_ambiguity_count: initial_ambiguity_count,
             filter_kernel: filter_kernel
           }
         }}

      {:error, _reason} = err ->
        err
    end
  end

  defp initial_sequential_ambiguities(epochs, physical_sats, sd_ambiguity_ids) do
    zero = Map.new(sd_ambiguity_ids, &{&1, 0.0})
    ambiguity_set = MapSet.new(sd_ambiguity_ids)

    seeded =
      Enum.reduce_while(epochs, %{}, fn epoch, acc ->
        if map_size(acc) == length(sd_ambiguity_ids) do
          {:halt, acc}
        else
          acc =
            epoch
            |> epoch_available_sats(physical_sats)
            |> Enum.reduce(acc, fn sat, sat_acc ->
              sd = single_difference(epoch, sat)

              if MapSet.member?(ambiguity_set, sd.ambiguity_id) and
                   not Map.has_key?(sat_acc, sd.ambiguity_id) do
                # RTK filters conventionally seed carrier ambiguities from the
                # phase-code difference; the prior remains intentionally broad,
                # but starting near the code-pinned level avoids spending early
                # epochs pulling kilometre-scale zero-state ambiguities into place.
                Map.put(sat_acc, sd.ambiguity_id, sd.phase_m - sd.code_m)
              else
                sat_acc
              end
            end)

          {:cont, acc}
        end
      end)

    {Map.merge(zero, seeded), map_size(seeded)}
  end

  defp sequential_filter_epochs_rust(
         base,
         epochs,
         refs,
         physical_sats,
         dd_ambiguity_pairs,
         dd_ambiguity_satellites,
         float_only_dd_ids,
         float_only_systems,
         wavelengths,
         offsets,
         weights,
         solve_opts,
         integer_opts,
         filter_opts,
         receiver_antenna_corrections,
         acc
       ) do
    rust_wavelengths = rust_sd_keyed_values(dd_ambiguity_pairs, wavelengths)
    rust_offsets = rust_sd_keyed_values(dd_ambiguity_pairs, offsets)
    rust_epochs = Enum.map(epochs, &rust_epoch_term(&1, refs, physical_sats))

    case NIF.rtk_filter_update_epochs(
           acc.rust_state,
           rust_epochs,
           base,
           rust_model_term(weights),
           rust_wavelengths,
           rust_offsets,
           rust_update_opts_term(filter_opts, solve_opts, integer_opts, float_only_systems),
           rust_receiver_antenna_corrections_term(receiver_antenna_corrections)
         ) do
      {:ok, updates} ->
        epochs
        |> Enum.zip(updates)
        |> Enum.reduce_while({:ok, acc}, fn {epoch, update}, {:ok, acc} ->
          case apply_rust_filter_update(
                 update,
                 epoch,
                 refs,
                 dd_ambiguity_pairs,
                 dd_ambiguity_satellites,
                 float_only_dd_ids,
                 acc
               ) do
            {:ok, next} -> {:cont, {:ok, next}}
            {:error, _reason} = err -> {:halt, err}
          end
        end)

      # The batch NIF tags a mid-arc failure with its epoch index
      # ({:error, epoch_index, reason}); carry both to the caller.
      {:error, epoch_index, reason} ->
        {:error, {reason, epoch_index: epoch_index}}

      {:error, _reason} = err ->
        err
    end
  end

  defp apply_rust_filter_update(
         {rust_state, reported_baseline, reported_sd_ambiguities, ratio, fixed?, newly_fixed_sd,
          fixed_sd_ids, search_meta_term, innovation_screen, residual_terms},
         epoch,
         refs,
         dd_ambiguity_pairs,
         dd_ambiguity_satellites,
         float_only_dd_ids,
         acc
       ) do
    with {:ok, state, information, header_refs, sd_fixed_cycles, sd_fixed_m, sd_ambiguity_ids} <-
           rust_filter_state_to_elixir(rust_state),
         # The carried state keeps the float baseline; the reported solution is
         # the kernel's ambiguity-conditioned baseline (matches the Elixir path).
         reported_sd_ambiguities =
           reported_sd_ambiguities ||
             Enum.map(sd_ambiguity_ids, &Map.fetch!(state.ambiguities, &1)),
         true <- length(reported_sd_ambiguities) == length(sd_ambiguity_ids),
         report_state = %{
           state
           | baseline: reported_baseline,
             ambiguities: sd_ambiguity_ids |> Enum.zip(reported_sd_ambiguities) |> Map.new()
         },
         {:ok, fixed_cycles} <-
           rust_sd_fixed_map_to_dd_ids(
             sd_fixed_cycles,
             dd_ambiguity_pairs,
             dd_ambiguity_satellites,
             refs,
             header_refs
           ),
         {:ok, fixed_m} <-
           rust_sd_fixed_map_to_dd_ids(
             sd_fixed_m,
             dd_ambiguity_pairs,
             dd_ambiguity_satellites,
             refs,
             header_refs
           ),
         {:ok, newly_fixed} <-
           rust_sd_ids_to_dd_ids(
             newly_fixed_sd,
             dd_ambiguity_pairs,
             dd_ambiguity_satellites,
             refs,
             header_refs
           ),
         {:ok, all_fixed} <-
           rust_sd_ids_to_dd_ids(
             fixed_sd_ids,
             dd_ambiguity_pairs,
             dd_ambiguity_satellites,
             refs,
             header_refs
           ),
         {:ok, search_meta} <-
           rust_filter_search_meta_to_dd_ids(
             search_meta_term,
             dd_ambiguity_pairs,
             dd_ambiguity_satellites,
             refs,
             header_refs
           ) do
      integer_ratio =
        rust_public_integer_ratio(ratio, residual_terms, acc, float_only_dd_ids, search_meta)

      residuals =
        residual_terms
        |> Enum.map(&decode_rtk_filter_residual(&1, epoch))
        |> Enum.sort_by(&{inspect(&1.epoch), &1.satellite_id, &1.ambiguity_id})

      screen_meta = rust_innovation_screen_meta(innovation_screen)

      epoch_result = %{
        epoch: epoch.epoch,
        index: epoch.idx,
        baseline_m: ecef_map(report_state.baseline),
        integer_status:
          if(screen_meta && screen_meta.coasted?,
            do: :coasted,
            else: if(fixed?, do: :fixed, else: :not_fixed)
          ),
        integer_ratio: integer_ratio,
        integer_best_score: search_meta && search_meta.integer_best_score,
        integer_second_best_score: search_meta && search_meta.integer_second_best_score,
        integer_candidates: search_meta && search_meta.integer_candidates,
        ambiguity_search: search_meta && search_meta.ambiguity_search,
        residuals_m: residuals,
        newly_fixed_ambiguities: newly_fixed,
        fixed_ambiguities: all_fixed,
        innovation_screen: screen_meta
      }

      {:ok,
       %{
         acc
         | state: state,
           information: information,
           fixed_cycles: fixed_cycles,
           fixed_m: fixed_m,
           rust_state: rust_state,
           epochs: [epoch_result | acc.epochs]
       }}
    else
      false -> {:error, {:invalid_rust_filter_state, :reported_ambiguity_dimension}}
      {:error, _reason} = err -> err
    end
  end

  defp rust_public_integer_ratio(_ratio, _residual_rows, _acc, _float_only_dd_ids, search_meta)
       when is_map(search_meta), do: search_meta.integer_ratio

  defp rust_public_integer_ratio(ratio, residual_terms, acc, float_only_dd_ids, nil) do
    fixed_set = acc.fixed_cycles |> Map.keys() |> MapSet.new()

    search_ids =
      residual_terms
      |> Enum.map(fn {_idx, _sat, _ref_sat, ambiguity_id, _code_m, _phase_m, _code_sigma_m,
                      _phase_sigma_m, _code_normalized, _phase_normalized} ->
        ambiguity_id
      end)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.reject(&(MapSet.member?(fixed_set, &1) or MapSet.member?(float_only_dd_ids, &1)))

    # The kernel returns ratio 0.0 as the "no search ran" sentinel (no
    # candidates, or the arming gate withheld the search); a real LAMBDA search
    # never yields exactly 0.0. Report nil there, matching the Elixir reference's
    # empty search meta.
    if search_ids != [] and ratio != 0.0, do: ratio
  end

  defp rust_filter_search_meta_to_dd_ids(nil, _pairs, _satellites, _refs, _header_refs),
    do: {:ok, nil}

  defp rust_filter_search_meta_to_dd_ids(
         search_meta_term,
         dd_ambiguity_pairs,
         dd_ambiguity_satellites,
         refs,
         header_refs
       ) do
    meta = decode_fixed_search_meta(search_meta_term)

    with {:ok, order} <-
           rust_sd_ids_to_dd_ids(
             meta.ambiguity_search.order,
             dd_ambiguity_pairs,
             dd_ambiguity_satellites,
             refs,
             header_refs
           ),
         {:ok, float_cycles} <-
           rust_sd_fixed_map_to_dd_ids(
             meta.ambiguity_search.float_cycles,
             dd_ambiguity_pairs,
             dd_ambiguity_satellites,
             refs,
             header_refs
           ),
         {:ok, offsets} <-
           rust_sd_fixed_map_to_dd_ids(
             meta.ambiguity_offsets_m,
             dd_ambiguity_pairs,
             dd_ambiguity_satellites,
             refs,
             header_refs
           ),
         {:ok, partial_fixed} <-
           rust_sd_ids_to_dd_ids(
             Map.get(meta, :partial_fixed_ambiguities, []),
             dd_ambiguity_pairs,
             dd_ambiguity_satellites,
             refs,
             header_refs
           ),
         {:ok, partial_free} <-
           rust_sd_ids_to_dd_ids(
             Map.get(meta, :partial_free_ambiguities, []),
             dd_ambiguity_pairs,
             dd_ambiguity_satellites,
             refs,
             header_refs
           ) do
      ambiguity_search =
        meta.ambiguity_search
        |> Map.put(:order, order)
        |> Map.put(:float_cycles, float_cycles)

      {:ok,
       meta
       |> Map.put(:ambiguity_search, ambiguity_search)
       |> Map.put(:ambiguity_offsets_m, offsets)
       |> Map.put(:partial_fixed_ambiguities, partial_fixed)
       |> Map.put(:partial_free_ambiguities, partial_free)
       |> maybe_translate_rust_full_set_order(
         dd_ambiguity_pairs,
         dd_ambiguity_satellites,
         refs,
         header_refs
       )}
    end
  end

  defp maybe_translate_rust_full_set_order(
         %{partial_full_set: %{order: order} = full_set} = meta,
         dd_ambiguity_pairs,
         dd_ambiguity_satellites,
         refs,
         header_refs
       ) do
    case rust_sd_ids_to_dd_ids(
           order,
           dd_ambiguity_pairs,
           dd_ambiguity_satellites,
           refs,
           header_refs
         ) do
      {:ok, translated} ->
        Map.put(meta, :partial_full_set, Map.put(full_set, :order, translated))

      {:error, _reason} ->
        meta
    end
  end

  defp maybe_translate_rust_full_set_order(meta, _pairs, _satellites, _refs, _header_refs),
    do: meta

  defp rust_initial_filter_state(
         epochs,
         refs,
         initial_baseline,
         sd_ambiguity_ids,
         initial_ambiguities,
         baseline_prior_sigma_m,
         ambiguity_prior_sigma_m
       ) do
    # Per-system reference SD ambiguity ids, each taken from the first epoch in
    # which that system's reference is observed (a reference is present in every
    # epoch where its system appears, but a system may join the arc late).
    header_refs =
      refs
      |> Enum.sort()
      |> Enum.map(fn {system, reference_sat} ->
        epoch = Enum.find(epochs, &MapSet.member?(epoch_sats(&1), reference_sat))
        {system, single_difference(epoch, reference_sat).ambiguity_id}
      end)

    # Pre-size the kernel state with the reference's globally-sorted column order
    # (sd_ambiguity_ids) and seeds, so the kernel's information matrix is
    # column-identical to the Elixir reference. Otherwise the kernel grows columns
    # by first-sighting insertion (reference first), a permutation of the sorted
    # order that takes different partial pivots in the solve, breaking 0-ULP.
    # `ensure_ambiguity` is idempotent, so the per-epoch seeding is a no-op.
    n = baseline_unknown_count(sd_ambiguity_ids)

    information =
      sequential_initial_information(n, baseline_prior_sigma_m, ambiguity_prior_sigma_m)

    ambiguities_m = Enum.map(sd_ambiguity_ids, &Map.fetch!(initial_ambiguities, &1))

    {
      {@rtk_filter_state_version, header_refs, sd_ambiguity_ids, ambiguity_prior_sigma_m, 0},
      initial_baseline,
      ambiguities_m,
      List.flatten(information),
      [],
      []
    }
  end

  defp rust_epoch_term(epoch, refs, physical_sats) do
    available = epoch_sats(epoch)

    references =
      refs
      |> Enum.sort()
      |> Enum.filter(fn {_system, reference_sat} -> MapSet.member?(available, reference_sat) end)
      |> Enum.map(fn {_system, reference_sat} -> rust_sat_term(epoch, reference_sat) end)

    nonref =
      epoch
      |> epoch_available_nonrefs(refs, physical_sats)
      |> Enum.map(&rust_sat_term(epoch, &1))

    {references, nonref, Map.get(epoch, :velocity_mps), Map.get(epoch, :prediction_dt_s, 0.0)}
  end

  defp rust_sat_term(epoch, sat) do
    base = Map.fetch!(epoch.base, sat)
    rover = Map.fetch!(epoch.rover, sat)

    {
      {sat, single_difference_ambiguity_id(sat, base, rover)},
      {base.code_m, base.phase_m, rover.code_m, rover.phase_m},
      {
        Map.fetch!(epoch.base_positions, sat),
        Map.fetch!(epoch.rover_positions, sat),
        Map.fetch!(epoch.positions, sat)
      }
    }
  end

  defp rust_model_term(weights) do
    {
      weights.code_sigma_m,
      weights.phase_sigma_m,
      Atom.to_string(weights.stochastic_model),
      weights.elevation_weighting?,
      weights.sagnac?
    }
  end

  defp rust_update_opts_term(filter_opts, solve_opts, integer_opts, float_only_systems) do
    {
      filter_opts.hold_sigma_m,
      solve_opts.position_tolerance_m,
      solve_opts.ambiguity_tolerance_m,
      solve_opts.max_iterations,
      filter_opts.process_noise_baseline_sigma_m,
      integer_opts.ratio_threshold,
      {
        Atom.to_string(filter_opts.dynamics_model),
        float_only_systems,
        rust_innovation_screen_sigma(filter_opts.innovation_screen),
        filter_opts.innovation_screen.min_rows,
        filter_opts.ar_arming_sigma_m,
        true
      }
    }
  end

  defp rust_innovation_screen_sigma(%{enabled?: true, threshold_sigma: threshold}), do: threshold
  defp rust_innovation_screen_sigma(_screen), do: 0.0

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

  defp decode_rtk_filter_residual(
         {_epoch_idx, sat, ref_sat, ambiguity_id, code_m, phase_m, code_sigma_m, phase_sigma_m,
          code_normalized, phase_normalized},
         epoch
       ) do
    %{
      epoch: epoch.epoch,
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

  defp rust_sd_keyed_values(dd_ambiguity_pairs, values) do
    dd_ambiguity_pairs
    |> Map.new(fn {dd_id, %{sat_sd_id: sat_sd_id}} ->
      {sat_sd_id, Map.fetch!(values, dd_id)}
    end)
    |> Enum.sort()
  end

  defp rust_filter_state_to_elixir(
         {{@rtk_filter_state_version, header_refs, sd_ids, _ambiguity_prior_sigma_m,
           _epoch_count}, baseline, sd_ambiguities, information, fixed_cycles, fixed_m}
       )
       when length(sd_ids) == length(sd_ambiguities) do
    n = 3 + length(sd_ids)

    if length(information) == n * n do
      {:ok,
       %{
         baseline: baseline,
         ambiguities: sd_ids |> Enum.zip(sd_ambiguities) |> Map.new()
       }, unflatten_matrix(information, n), Map.new(header_refs), Map.new(fixed_cycles),
       Map.new(fixed_m), sd_ids}
    else
      {:error, {:invalid_rust_filter_state, :information_dimension}}
    end
  end

  defp rust_filter_state_to_elixir(_state), do: {:error, {:invalid_rust_filter_state, :shape}}

  defp unflatten_matrix(values, n), do: Enum.chunk_every(values, n)

  defp rust_sd_fixed_map_to_dd_ids(
         values,
         dd_ambiguity_pairs,
         dd_ambiguity_satellites,
         refs,
         header_refs
       ) do
    values
    |> Enum.reduce_while({:ok, %{}}, fn {sat_sd_id, value}, {:ok, acc} ->
      case rust_sd_id_to_dd_id(
             sat_sd_id,
             dd_ambiguity_pairs,
             dd_ambiguity_satellites,
             refs,
             header_refs
           ) do
        {:ok, dd_id} -> {:cont, {:ok, Map.put(acc, dd_id, value)}}
        {:error, _reason} = err -> {:halt, err}
      end
    end)
  end

  defp rust_sd_ids_to_dd_ids(ids, dd_ambiguity_pairs, dd_ambiguity_satellites, refs, header_refs) do
    ids
    |> Enum.reduce_while({:ok, []}, fn sat_sd_id, {:ok, acc} ->
      case rust_sd_id_to_dd_id(
             sat_sd_id,
             dd_ambiguity_pairs,
             dd_ambiguity_satellites,
             refs,
             header_refs
           ) do
        {:ok, dd_id} -> {:cont, {:ok, [dd_id | acc]}}
        {:error, _reason} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, dd_ids} -> {:ok, Enum.sort(dd_ids)}
      {:error, _reason} = err -> err
    end
  end

  # Kernel SD ambiguity ids map back to the reference DD ids against their OWN
  # system's reference (the kernel header carries each system's reference SD
  # ambiguity arc, fixed for the run by the ReferenceChanged guard).
  defp rust_sd_id_to_dd_id(
         sat_sd_id,
         dd_ambiguity_pairs,
         dd_ambiguity_satellites,
         refs,
         header_refs
       ) do
    system = String.first(sat_sd_id)
    reference_sat = Map.fetch!(refs, system)
    ref_sd_id = Map.fetch!(header_refs, system)

    case Enum.find(dd_ambiguity_pairs, fn {_dd_id, pair} ->
           pair.sat_sd_id == sat_sd_id and pair.ref_sd_id == ref_sd_id
         end) do
      {dd_id, _pair} ->
        {:ok, dd_id}

      nil ->
        sat =
          Enum.find_value(dd_ambiguity_pairs, fn {dd_id, pair} ->
            if pair.sat_sd_id == sat_sd_id do
              Map.fetch!(dd_ambiguity_satellites, dd_id)
            end
          end)

        if sat do
          {:ok,
           double_difference_ambiguity_id(sat, sat_sd_id, %{
             satellite_id: reference_sat,
             ambiguity_id: ref_sd_id
           })}
        else
          {:error, {:unknown_rust_ambiguity_id, sat_sd_id}}
        end
    end
  end

  defp sequential_initial_information(n, baseline_sigma_m, ambiguity_sigma_m) do
    for i <- 0..(n - 1) do
      for j <- 0..(n - 1) do
        cond do
          i != j -> 0.0
          i < 3 -> 1.0 / (baseline_sigma_m * baseline_sigma_m)
          true -> 1.0 / (ambiguity_sigma_m * ambiguity_sigma_m)
        end
      end
    end
  end

  defp add3({ax, ay, az}, {bx, by, bz}), do: {ax + bx, ay + by, az + bz}

  defp ecef_map({x, y, z}), do: %{x_m: x, y_m: y, z_m: z}

  defp normalize_observations(observations, error_tag) do
    Observations.normalize_code_phase(observations,
      container: :map,
      sort?: false,
      include_raw?: false,
      lli: :single,
      error_tag: error_tag,
      validate_lli?: true
    )
  end

  defp normalize_widelane_reference_option(opts) do
    case Keyword.get(opts, :reference_satellite_id) do
      nil -> :ok
      sat when is_binary(sat) -> :ok
      _other -> {:error, {:invalid_option, :reference_satellite_id}}
    end
  end

  defp widelane_reference_satellite(opts, base, epochs) do
    with :ok <- normalize_widelane_reference_option(opts),
         {:ok, refs} <- baseline_reference_satellites(opts, base, epochs, nil) do
      case Map.values(refs) do
        [sat] -> {:ok, sat}
        _multi -> {:error, {:unsupported_widelane, :multi_gnss}}
      end
    else
      {:error, _reason} = err -> err
      _other -> {:error, {:invalid_option, :reference_satellite_id}}
    end
  end
end
