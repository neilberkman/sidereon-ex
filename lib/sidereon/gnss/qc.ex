defmodule Sidereon.GNSS.QC do
  @moduledoc """
  Measurement-quality control for single-point positioning.

  The numerical modeling and FDE orchestration live in the
  `sidereon-core` Rust core. This module keeps the Elixir API,
  normalizes options and epochs for the NIF, maps errors, and decodes the
  unchanged public result maps.
  """

  alias Sidereon.Constants
  alias Sidereon.GNSS.Broadcast
  alias Sidereon.GNSS.Positioning
  alias Sidereon.GNSS.Positioning.Decode
  alias Sidereon.GNSS.Positioning.Solution
  alias Sidereon.GNSS.QC.{QualityError, RaimInput, RaimResult}
  alias Sidereon.GNSS.RINEX.Observations
  alias Sidereon.GNSS.SP3
  alias Sidereon.GNSS.Time
  alias Sidereon.NIF
  alias Sidereon.NifCall

  @default_a 0.3
  @default_b 0.3
  @default_p_fa 1.0e-3
  @default_max_exclusions 1
  @default_max_exclusion_rms_m 100.0
  @quality_error_kinds [
    :invalid_elevation,
    :missing_cn0,
    :invalid_parameter,
    :invalid_reliability_parameter,
    :invalid_probability,
    :invalid_system_count,
    :invalid_dof,
    :invalid_weight,
    :invalid_residuals,
    :invalid_design,
    :singular_geometry,
    :missing_variances,
    :invalid_variance
  ]

  @default_initial_guess {0.0, 0.0, 0.0, 0.0}
  @default_alpha {0.0, 0.0, 0.0, 0.0}
  @default_beta {0.0, 0.0, 0.0, 0.0}
  # Standard-atmosphere surface meteorology fallback, sourced from the single
  # binding home `Sidereon.Constants` (mirrors
  # `sidereon_core::positioning::SurfaceMet::default()`, drift-tested against
  # `Sidereon.NIF.core_defaults/0`) so it cannot diverge from the core.
  @default_pressure_hpa Constants.surface_met_pressure_hpa()
  @default_temperature_k Constants.surface_met_temperature_k()
  @default_relative_humidity Constants.surface_met_relative_humidity()

  defmodule ObservationReport do
    @moduledoc "RINEX observation QC report."
    alias Sidereon.GNSS.QC.ClockJump
    alias Sidereon.GNSS.QC.CycleSlipQc
    alias Sidereon.GNSS.QC.DataGap
    alias Sidereon.GNSS.QC.MultipathReport
    alias Sidereon.GNSS.QC.ObservationFinding
    alias Sidereon.GNSS.QC.ObservationHeader
    alias Sidereon.GNSS.QC.ObservationNote
    alias Sidereon.GNSS.QC.SatelliteObservation
    alias Sidereon.GNSS.QC.SatelliteSignal
    alias Sidereon.GNSS.QC.SystemObservation
    alias Sidereon.GNSS.QC.SystemSignal

    @derive {Inspect, except: [:handle]}
    defstruct [
      :handle,
      :header,
      :total_epoch_records,
      :observation_epochs,
      :event_records,
      :power_failure_epochs,
      :skipped_records,
      :interval_s,
      :interval_source,
      :missing_epochs,
      data_gaps: [],
      clock_jumps: [],
      cycle_slips: nil,
      multipath: nil,
      systems: [],
      satellites: [],
      satellite_signals: [],
      system_signals: [],
      lint_findings: [],
      notes: []
    ]

    @type t :: %__MODULE__{
            handle: reference(),
            header: ObservationHeader.t(),
            total_epoch_records: non_neg_integer(),
            observation_epochs: non_neg_integer(),
            event_records: non_neg_integer(),
            power_failure_epochs: non_neg_integer(),
            skipped_records: non_neg_integer(),
            interval_s: float() | nil,
            interval_source: String.t(),
            missing_epochs: non_neg_integer(),
            data_gaps: [DataGap.t()],
            clock_jumps: [ClockJump.t()],
            cycle_slips: CycleSlipQc.t(),
            multipath: MultipathReport.t(),
            systems: [SystemObservation.t()],
            satellites: [SatelliteObservation.t()],
            satellite_signals: [SatelliteSignal.t()],
            system_signals: [SystemSignal.t()],
            lint_findings: [ObservationFinding.t()],
            notes: [ObservationNote.t()]
          }
  end

  defmodule ObservationHeader do
    @moduledoc "Header metadata copied into a QC report."
    alias Sidereon.GNSS.QC.ObservationAntenna
    alias Sidereon.GNSS.QC.ObservationReceiver
    alias Sidereon.GNSS.QC.ObservationTime

    defstruct [
      :marker_name,
      :marker_number,
      :marker_type,
      :receiver,
      :antenna,
      :approx_position_m,
      :antenna_delta_hen_m,
      :time_of_first_obs,
      :time_of_last_obs,
      :duration_s
    ]

    @type t :: %__MODULE__{
            marker_name: String.t() | nil,
            marker_number: String.t() | nil,
            marker_type: String.t() | nil,
            receiver: ObservationReceiver.t() | nil,
            antenna: ObservationAntenna.t() | nil,
            approx_position_m: {float(), float(), float()} | nil,
            antenna_delta_hen_m: {float(), float(), float()} | nil,
            time_of_first_obs: ObservationTime.t() | nil,
            time_of_last_obs: ObservationTime.t() | nil,
            duration_s: float() | nil
          }
  end

  defmodule ObservationReceiver do
    @moduledoc "Receiver identity from `REC # / TYPE / VERS`."
    defstruct [:number, :receiver_type, :version]

    @type t :: %__MODULE__{
            number: String.t(),
            receiver_type: String.t(),
            version: String.t()
          }
  end

  defmodule ObservationAntenna do
    @moduledoc "Antenna identity from `ANT # / TYPE`."
    defstruct [:number, :antenna_type]

    @type t :: %__MODULE__{number: String.t(), antenna_type: String.t()}
  end

  defmodule ObservationTime do
    @moduledoc "Observation epoch with an optional RINEX time-scale label."
    defstruct [:epoch, :time_scale]

    @type t :: %__MODULE__{
            epoch: {{integer(), integer(), integer()}, {integer(), integer(), float()}},
            time_scale: String.t() | nil
          }
  end

  defmodule DataGap do
    @moduledoc "Detected gap between adjacent observation epochs."
    defstruct [:start_epoch, :end_epoch, :nominal_interval_s, :observed_delta_s, :missing_epochs]

    @type t :: %__MODULE__{
            start_epoch: term(),
            end_epoch: term(),
            nominal_interval_s: float(),
            observed_delta_s: float(),
            missing_epochs: non_neg_integer()
          }
  end

  defmodule SystemObservation do
    @moduledoc "Per-constellation observation completeness row."
    defstruct [
      :system,
      :satellites_seen,
      :epochs_with_observations,
      :value_observations,
      :expected_observations,
      :completeness_ratio,
      :gap_count,
      :total_gap_s
    ]

    @type t :: %__MODULE__{
            system: String.t(),
            satellites_seen: non_neg_integer(),
            epochs_with_observations: non_neg_integer(),
            value_observations: non_neg_integer(),
            expected_observations: non_neg_integer(),
            completeness_ratio: float() | nil,
            gap_count: non_neg_integer(),
            total_gap_s: float()
          }
  end

  defmodule SatelliteObservation do
    @moduledoc "Per-satellite observation completeness row."
    defstruct [:satellite, :epochs_with_observations, :value_observations]

    @type t :: %__MODULE__{
            satellite: String.t(),
            epochs_with_observations: non_neg_integer(),
            value_observations: non_neg_integer()
          }
  end

  defmodule SsiHistogram do
    @moduledoc "Histogram over RINEX SSI digits."
    defstruct counts: []

    @type t :: %__MODULE__{counts: [non_neg_integer()]}
  end

  defmodule SnrStats do
    @moduledoc "Summary statistics over raw numeric S-code observations."
    defstruct [:n, :mean, :min, :max, :std]

    @type t :: %__MODULE__{
            n: non_neg_integer(),
            mean: float(),
            min: float(),
            max: float(),
            std: float() | nil
          }
  end

  defmodule SatelliteSignal do
    @moduledoc "Per-satellite, per-code observation completeness row."
    alias Sidereon.GNSS.QC.SnrStats
    alias Sidereon.GNSS.QC.SsiHistogram

    defstruct [:satellite, :code, :value_observations, :ssi, :snr]

    @type t :: %__MODULE__{
            satellite: String.t(),
            code: String.t(),
            value_observations: non_neg_integer(),
            ssi: SsiHistogram.t() | nil,
            snr: SnrStats.t() | nil
          }
  end

  defmodule SystemSignal do
    @moduledoc "Per-constellation, per-code observation completeness row."
    alias Sidereon.GNSS.QC.SnrStats
    alias Sidereon.GNSS.QC.SsiHistogram

    defstruct [:system, :code, :value_observations, :ssi, :snr]

    @type t :: %__MODULE__{
            system: String.t(),
            code: String.t(),
            value_observations: non_neg_integer(),
            ssi: SsiHistogram.t() | nil,
            snr: SnrStats.t() | nil
          }
  end

  defmodule ObservationFinding do
    @moduledoc "Compact lint finding retained by a QC report."
    defstruct [:code, :severity, :spec_ref]

    @type t :: %__MODULE__{code: String.t(), severity: String.t(), spec_ref: String.t()}
  end

  defmodule ClockJump do
    @moduledoc "Detected receiver-clock jump."
    defstruct [:epoch_index, :epoch, :delta_s]

    @type t :: %__MODULE__{epoch_index: non_neg_integer(), epoch: term(), delta_s: float()}
  end

  defmodule CycleSlipQc do
    @moduledoc "Aggregate dual-frequency cycle-slip counts."
    alias Sidereon.GNSS.QC.SystemCycleSlipQc

    defstruct [:observations, :total_slips, :observations_per_slip, by_system: []]

    @type t :: %__MODULE__{
            observations: non_neg_integer(),
            total_slips: non_neg_integer(),
            observations_per_slip: float() | nil,
            by_system: [SystemCycleSlipQc.t()]
          }
  end

  defmodule SystemCycleSlipQc do
    @moduledoc "Per-constellation cycle-slip counts."
    defstruct [:system, :observations, :slips, :observations_per_slip]

    @type t :: %__MODULE__{
            system: String.t(),
            observations: non_neg_integer(),
            slips: non_neg_integer(),
            observations_per_slip: float() | nil
          }
  end

  defmodule MultipathReport do
    @moduledoc "MP1/MP2 multipath RMS report."
    alias Sidereon.GNSS.QC.SatelliteMultipath
    alias Sidereon.GNSS.QC.SystemMultipath

    defstruct satellites: [], systems: []

    @type t :: %__MODULE__{
            satellites: [SatelliteMultipath.t()],
            systems: [SystemMultipath.t()]
          }
  end

  defmodule SatelliteMultipath do
    @moduledoc "Per-satellite MP1/MP2 RMS row."
    alias Sidereon.GNSS.QC.MultipathStats

    defstruct [:satellite, :mp1, :mp2]

    @type t :: %__MODULE__{
            satellite: String.t(),
            mp1: MultipathStats.t() | nil,
            mp2: MultipathStats.t() | nil
          }
  end

  defmodule SystemMultipath do
    @moduledoc "Per-constellation MP1/MP2 RMS row."
    alias Sidereon.GNSS.QC.MultipathStats

    defstruct [:system, :mp1, :mp2]

    @type t :: %__MODULE__{
            system: String.t(),
            mp1: MultipathStats.t() | nil,
            mp2: MultipathStats.t() | nil
          }
  end

  defmodule MultipathStats do
    @moduledoc "RMS statistics for one multipath series."
    defstruct [:n, :rms_m]

    @type t :: %__MODULE__{n: non_neg_integer(), rms_m: float()}
  end

  defmodule ObservationNote do
    @moduledoc """
    Non-fatal QC note.

    `kind` is one of:

      * `"non_monotonic_epoch"` - the observation epoch at `epoch_index` is a
        duplicate of, or earlier than, the one before it.
      * `"interval_unresolved"` - no epoch interval could be resolved.
      * `"event_header_records_unread"` - an event's header records did not
        read, so every epoch was taken with the file header. A product read
        from text always reads, so a product this binding parsed never carries
        this note.

    `epoch_index` is `nil` for every kind but `"non_monotonic_epoch"`.
    """
    defstruct [:kind, :epoch_index]

    @type t :: %__MODULE__{kind: String.t(), epoch_index: non_neg_integer() | nil}
  end

  @typedoc "A `{satellite_id, elevation_deg}` or `{satellite_id, elevation_deg, cn0_dbhz}` entry."
  @type weight_entry ::
          {String.t(), number()} | {String.t(), number(), number()}

  defmodule RaimInput do
    @moduledoc """
    Post-solve RAIM input.

    `:used_sats` and `:residuals_m` must use the same order. Residuals are the
    post-fit range residuals in meters. `:variances_m2`, when supplied, are the
    positive finite variances the estimator used, in that same order.
    """

    @enforce_keys [:used_sats, :residuals_m]
    defstruct [:used_sats, :residuals_m, :variances_m2]

    @type t :: %__MODULE__{
            used_sats: [String.t()],
            residuals_m: [float()],
            variances_m2: [float()] | nil
          }

    @doc """
    Build post-solve RAIM input from satellite ids and residuals.
    """
    @spec new([String.t()], [number()]) :: t()
    @spec new([String.t()], [number()], [number()] | nil) :: t()
    def new(used_sats, residuals_m, variances_m2 \\ nil)

    def new(used_sats, residuals_m, variances_m2)
        when is_list(used_sats) and is_list(residuals_m) and (is_list(variances_m2) or is_nil(variances_m2)) do
      %__MODULE__{
        used_sats: used_sats,
        residuals_m: Enum.map(residuals_m, &(&1 / 1.0)),
        variances_m2: if(variances_m2, do: Enum.map(variances_m2, &(&1 / 1.0)))
      }
    end
  end

  defmodule QualityError do
    @moduledoc "A unit core quality-control refusal, retaining its core variant as `kind`."

    @enforce_keys [:kind]
    defexception [:kind, :message]

    @type kind ::
            :invalid_elevation
            | :missing_cn0
            | :invalid_parameter
            | :invalid_reliability_parameter
            | :invalid_probability
            | :invalid_system_count
            | :invalid_dof
            | :invalid_weight
            | :invalid_residuals
            | :invalid_design
            | :singular_geometry
            | :missing_variances
            | :invalid_variance

    @type t :: %__MODULE__{kind: kind(), message: String.t() | nil}

    @impl true
    def message(%__MODULE__{message: message}) when is_binary(message), do: message

    def message(%__MODULE__{kind: kind}), do: "quality control refused input: #{kind}"
  end

  defmodule RaimResult do
    @moduledoc """
    Post-solve RAIM fault-detection result.
    """

    @enforce_keys [
      :fault_detected,
      :test_statistic,
      :threshold,
      :worst_sat,
      :reduced_chi_square,
      :normalized_residuals,
      :rms_m,
      :dof,
      :testable
    ]
    defstruct [
      :fault_detected,
      :test_statistic,
      :threshold,
      :worst_sat,
      :reduced_chi_square,
      :normalized_residuals,
      :rms_m,
      :dof,
      :testable
    ]

    @type t :: %__MODULE__{
            fault_detected: boolean(),
            test_statistic: float(),
            threshold: float() | nil,
            worst_sat: String.t() | nil,
            reduced_chi_square: float() | nil,
            normalized_residuals: %{String.t() => float()},
            rms_m: float(),
            dof: integer(),
            testable: boolean()
          }
  end

  @typedoc """
  The result of `raim/2`.
  """
  @type raim_result :: %{
          fault_detected?: boolean(),
          fault_detected: boolean(),
          test_statistic: float(),
          threshold: float() | nil,
          reduced_chi_square: float() | nil,
          dof: integer(),
          testable?: boolean(),
          testable: boolean(),
          normalized_residuals: %{String.t() => float()},
          rms_m: float(),
          worst_sat: String.t() | nil
        }

  @typedoc "The public exception raised or returned for a core quality-control refusal."
  @type quality_error :: QualityError.t()

  @typedoc "FDE state returned when the core stops with a detected fault."
  @type fde_unresolved :: %{
          reason: String.t(),
          solution: Solution.t(),
          excluded: [{String.t(), :raim_excluded}],
          iterations: non_neg_integer(),
          raim: raim_result()
        }

  @doc """
  Pseudorange measurement variance (m^2) from satellite elevation.

  Returns a float or a tagged core refusal. The core accepts finite elevations
  in `[-90, 90]`; a zero-elevation observation is valid when `b: 0.0`, while a
  nonzero elevation-scaled term has undefined variance at the horizon.
  """
  @spec pseudorange_variance(number(), keyword()) :: float() | {:error, QualityError.kind()}
  def pseudorange_variance(elevation_deg, opts \\ [])

  def pseudorange_variance(elevation_deg, opts) do
    {a, b, model, cn0, scale} = variance_args(opts)

    case NIF.qc_pseudorange_variance(elevation_deg / 1.0, a, b, model, cn0, scale) do
      {:ok, value} -> value
      {:error, kind} when kind in @quality_error_kinds -> {:error, kind}
    end
  end

  @doc """
  Build a `satellite => sigma_m` map for a list of weight entries.
  """
  @spec sigmas([weight_entry()], keyword()) :: %{String.t() => float()}
  def sigmas(entries, opts \\ []) when is_list(entries) do
    {a, b, model, cn0, scale} = variance_args(opts)

    entries
    |> Enum.map(&encode_weight_entry/1)
    |> NIF.qc_sigmas(a, b, model, cn0, scale)
    |> Map.new()
  end

  @doc """
  Build a `satellite => inverse_variance_weight` map for a list of weight entries.
  """
  @spec weight_vector([weight_entry()], keyword()) :: %{String.t() => float()}
  def weight_vector(entries, opts \\ []) when is_list(entries) do
    {a, b, model, cn0, scale} = variance_args(opts)

    entries
    |> Enum.map(&encode_weight_entry/1)
    |> NIF.qc_weight_vector(a, b, model, cn0, scale)
    |> Map.new()
  end

  @doc """
  Residual-based RAIM: a chi-square goodness-of-fit test on a positioning solution.

  The default `weights: :solution` uses the actual per-satellite variances from
  the solution or `RaimInput`; pass `weights: :unit` or a satellite-weight map
  for the other modes. Solution input also carries its actual receiver-clock
  count so shared GPS/QZSS/SBAS clocks are not counted as separate parameters.

  Pass inverse-variance weights derived from per-satellite residual variances,
  either as a `%{sat => weight}` map or as weight entries consumed by
  `weight_vector/2`. Unit weights with metre-scale residuals make
  `fault_detected` saturate near 100%.

  A core refusal raises `Sidereon.GNSS.QC.QualityError`, whose `:kind` is the
  core variant (for example `:missing_variances` or `:invalid_variance`).
  Binding-level malformed options continue to raise `ArgumentError`.

      entries = [
        %{satellite_id: "G01", elevation_deg: 72.0},
        %{satellite_id: "G02", elevation_deg: 42.0}
      ]

      weights = Sidereon.GNSS.QC.weight_vector(entries, a_m: 0.8, b_m: 0.8)
      Sidereon.GNSS.QC.raim(input, weights: weights)
  """
  @spec raim(Solution.t() | RaimInput.t(), keyword()) :: raim_result() | RaimResult.t()
  def raim(input, opts \\ [])

  def raim(%RaimInput{} = input, opts) do
    input.used_sats
    |> run_raim(input.residuals_m, input.variances_m2, opts)
    |> decode_raim_result(:struct)
  end

  def raim(%Solution{} = solution, opts) do
    solution.used_sats
    |> run_raim(
      solution.residuals_m,
      solution.pseudorange_variances_m2,
      solution_raim_opts(solution, opts)
    )
    |> decode_raim_result(:map)
  end

  @doc """
  Residual-based RAIM for an existing SPP solution.

  This is the direct post-solve variant matching the Rust and C
  `raim_for_solution` surface. It uses the solution's used satellites and
  post-fit residuals, actual variances and solved receiver-clock count, with the
  same options accepted by `raim/2`. An explicit `:n_systems` overrides that
  count.
  """
  @spec raim_for_solution(Solution.t(), keyword()) :: raim_result()
  def raim_for_solution(%Solution{} = solution, opts \\ []) do
    solution.used_sats
    |> run_raim(
      solution.residuals_m,
      solution.pseudorange_variances_m2,
      solution_raim_opts(solution, opts)
    )
    |> decode_raim_result(:map)
  end

  @doc """
  Standalone range RAIM/FDE over a caller-supplied linearized measurement set,
  independent of any full positioning solve.

  Each row of `rows` is a map describing one linearized range measurement:

    * `:id` - stable measurement identifier (e.g. a satellite token `"G01"`)
    * `:residual_m` - observed-minus-computed range residual, metres
    * `:design_row` - the measurement's row of the design matrix (a list of the
      partials of the predicted range with respect to each estimated state
      parameter); every row must carry the same length
    * `:weight` - inverse-variance weight `1 / sigma^2`, strictly positive

  Options:

    * `:p_fa` - false-alarm probability for the global chi-square test
      (default `#{@default_p_fa}`)
    * `:max_exclusions` - maximum measurements the exclusion loop may remove
      (default: one, matching RTKLIB demo5)
    * `:min_redundancy` - minimum redundancy an exclusion must leave behind
      (default `1`)
    * `:max_exclusion_rms_m` - largest admissible unweighted residual RMS for a
      leave-one-out candidate (default `100.0`; `:infinity` disables this cap)

  Returns `{:ok, result}` where `result` carries the protected
  `:state_correction`, `:state_covariance`, the `:global_test` chi-square map,
  the `:excluded` ids, per-measurement `:diagnostics`, and the exclusion
  `:iterations`; or `{:error, reason}` for a malformed or rank-deficient input.
  The removed `:max_iterations` option is explicitly rejected as
  `{:invalid_option, :max_iterations}`.
  Core quality refusals return `{:error, %Sidereon.GNSS.QC.QualityError{}}`.
  """
  @spec raim_fde_design([map()], keyword()) :: {:ok, map()} | {:error, term()}
  def raim_fde_design(rows, opts \\ []) when is_list(rows) do
    p_fa = Keyword.get(opts, :p_fa, @default_p_fa)
    max_exclusions = Keyword.get(opts, :max_exclusions, @default_max_exclusions)
    min_redundancy = Keyword.get(opts, :min_redundancy, 1)
    max_exclusion_rms_m = Keyword.get(opts, :max_exclusion_rms_m, @default_max_exclusion_rms_m)

    with false <- Keyword.has_key?(opts, :max_iterations),
         {:ok, max_exclusions} <- max_exclusions_arg(max_exclusions),
         {:ok, min_redundancy} <- min_redundancy_arg(min_redundancy),
         {:ok, cap} <- exclusion_rms_cap_arg(max_exclusion_rms_m) do
      case NIF.qc_raim_fde_design(
             Enum.map(rows, &normalize_fde_row/1),
             p_fa / 1.0,
             max_exclusions,
             min_redundancy,
             cap
           ) do
        {:ok, result} -> {:ok, result}
        {:error, kind} when kind in @quality_error_kinds -> {:error, quality_error(kind)}
        {:error, reason} -> {:error, reason}
      end
    else
      true -> {:error, {:invalid_option, :max_iterations}}
      other -> other
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :qc_raim_fde_design)
  end

  @doc """
  Fault detection and exclusion: solve, run RAIM, compare leave-one-out
  candidate solves when a fault is detected, and repeat until the accepted
  solution passes RAIM or the exclusion budget is exhausted.

  `:pseudorange_code` selects the code of the pseudoranges as in
  `Sidereon.GNSS.Positioning.solve/4` (default `:single_frequency`).

  Malformed FDE options are returned as tagged errors, including
  `{:invalid_option, :p_fa}`, `{:invalid_option, :weights}`,
  `{:invalid_option, :max_exclusions}`, `{:invalid_option, :max_exclusion_rms_m}`
  and `{:invalid_option, :pseudorange_code}`. Weighting defaults to the solution's
  actual per-satellite variances; `weights: :unit` and a positive satellite map
  remain explicit alternatives. `max_exclusions` defaults to one and the RMS cap
  defaults to 100 metres; use `:infinity` to remove the cap.
  The removed `:max_iterations` option is explicitly rejected, including when
  supplied together with `:max_exclusions`.
  Core quality refusals return `{:error, %Sidereon.GNSS.QC.QualityError{}}`;
  malformed binding options remain tagged with `:invalid_option`.
  Success returns the accepted `:solution`, ordered `:excluded` list, number of
  exclusions, and the accepted solution's `:raim` result. An unresolved fault
  returns `{:error, {:fault_unresolved, unresolved}}`; the map includes the
  core `:reason` (`"exclusion_budget_exhausted"` or
  `"no_admissible_exclusion"`), last `:solution`, `:excluded` list,
  `:iterations`, and its faulted `:raim` result. An ephemeris source that
  refuses a satellite state reading UT1 outside the UT1 table fails with
  `{:ut1_outside_coverage, :before_coverage | :after_coverage}`.
  """
  @spec fde(term(), [Positioning.observation()], Positioning.epoch(), keyword()) ::
          {:ok,
           %{
             solution: Solution.t(),
             excluded: [{String.t(), :raim_excluded}],
             iterations: non_neg_integer(),
             raim: raim_result()
           }}
          | {:error, {:fault_unresolved, fde_unresolved()}}
          | {:error, term()}
  def fde(source, observations, epoch, opts \\ [])

  def fde(%SP3{handle: handle}, observations, epoch, opts) when is_list(observations) do
    fde_impl(:sp3, handle, observations, epoch, opts, false)
  end

  def fde(%Broadcast{handle: handle}, observations, epoch, opts) when is_list(observations) do
    fde_impl(:broadcast, handle, observations, epoch, opts, false)
  end

  @doc """
  Core robust-reweighted SPP under the RAIM/FDE exclusion loop.

  The successful result carries the accepted solution, ordered exclusions,
  exclusion count and that solution's `:raim` test. An unresolved fault carries
  the core stop reason, last solution, exclusions and faulted RAIM result.
  """
  @spec robust_fde(term(), [Positioning.observation()], Positioning.epoch(), keyword()) ::
          {:ok,
           %{
             solution: Solution.t(),
             excluded: [{String.t(), :raim_excluded}],
             iterations: non_neg_integer(),
             raim: raim_result()
           }}
          | {:error, {:fault_unresolved, fde_unresolved()}}
          | {:error, term()}
  def robust_fde(source, observations, epoch, opts \\ [])

  def robust_fde(%SP3{handle: handle}, observations, epoch, opts) when is_list(observations) do
    fde_impl(:sp3, handle, observations, epoch, opts, true)
  end

  def robust_fde(%Broadcast{handle: handle}, observations, epoch, opts) when is_list(observations) do
    fde_impl(:broadcast, handle, observations, epoch, opts, true)
  end

  @doc """
  Observation completeness and signal-quality rollup for a parsed RINEX OBS file.
  """
  @spec observation_report(Observations.t(), keyword()) ::
          {:ok, ObservationReport.t()} | {:error, term()}
  def observation_report(%Observations{handle: handle}, opts \\ []) do
    interval = Keyword.get(opts, :interval_s)
    gap_factor = Keyword.get(opts, :gap_factor, 1.5)

    clock_jump_threshold_s =
      case Keyword.get(opts, :clock_jump_threshold_s) do
        nil -> nil
        value -> value / 1.0
      end

    case NIF.rinex_obs_observation_qc(handle, interval, gap_factor / 1.0, clock_jump_threshold_s) do
      {:ok, report} -> {:ok, normalize_observation_report(report)}
      {:error, _reason} = err -> err
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :rinex_obs_observation_qc)
  end

  @doc """
  Render an observation QC report as fixed-width text.
  """
  @spec render_text(ObservationReport.t()) :: {:ok, String.t()} | {:error, term()}
  def render_text(%ObservationReport{handle: handle}) when is_reference(handle) do
    {:ok, NIF.rinex_qc_report_render_text(handle)}
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :rinex_qc_report_render_text)
  end

  def render_text(%ObservationReport{}), do: {:error, :missing_report_handle}

  @doc """
  Render an observation QC report as HTML.
  """
  @spec render_html(ObservationReport.t()) :: {:ok, String.t()} | {:error, term()}
  def render_html(%ObservationReport{handle: handle}) when is_reference(handle) do
    {:ok, NIF.rinex_qc_report_render_html(handle)}
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :rinex_qc_report_render_html)
  end

  def render_html(%ObservationReport{}), do: {:error, :missing_report_handle}

  @doc """
  Serialize an observation QC report as JSON.
  """
  @spec to_json(ObservationReport.t()) :: {:ok, String.t()} | {:error, term()}
  def to_json(%ObservationReport{handle: handle}) when is_reference(handle) do
    case NIF.rinex_qc_report_to_json(handle) do
      {:ok, json} -> {:ok, json}
      {:error, _reason} = err -> err
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :rinex_qc_report_to_json)
  end

  def to_json(%ObservationReport{}), do: {:error, :missing_report_handle}

  @doc """
  Lint a parsed RINEX OBS file.
  """
  @spec lint_obs(Observations.t()) :: {:ok, map()} | {:error, term()}
  def lint_obs(%Observations{handle: handle}) do
    case NIF.rinex_qc_lint_obs(handle) do
      {:ok, report} -> {:ok, normalize_lint_report(report)}
      {:error, _reason} = err -> err
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :rinex_qc_lint_obs)
  end

  @doc """
  Lint RINEX OBS or CRINEX text.
  """
  @spec lint_obs_text(String.t()) :: {:ok, map()} | {:error, term()}
  def lint_obs_text(text) when is_binary(text) do
    case NIF.rinex_qc_lint_obs_text(text) do
      {:ok, report} -> {:ok, normalize_lint_report(report)}
      {:error, _reason} = err -> err
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :rinex_qc_lint_obs_text)
  end

  @doc """
  Lint RINEX NAV text.
  """
  @spec lint_nav_text(String.t()) :: {:ok, map()} | {:error, term()}
  def lint_nav_text(text) when is_binary(text) do
    case NIF.rinex_qc_lint_nav_text(text) do
      {:ok, report} -> {:ok, normalize_lint_report(report)}
      {:error, _reason} = err -> err
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :rinex_qc_lint_nav_text)
  end

  @doc """
  Mechanically repair RINEX OBS or CRINEX text.

  Content-changing repairs other than record sorting are opt-in. Set
  `:set_interval` to `true` to replace an unavailable or mismatched `INTERVAL`
  from the observed epoch cadence, for example.

  The repaired product is written with the observation writer, which returns
  text only when it reads back as the product, and that text is then
  compressed to CRINEX. On success the map holds both texts, the actions taken
  and the lint report after repair. Each failure keeps its own shape:

    * `{:error, {:parse, message}}` or `{:error, {:invalid_input, message}}` -
      the input does not read, or repair refuses it, such as text whose
      unretained header records a repair would drop without
      `drop_unsupported: true`.
    * `{:error, {:repaired_product_unwritable, {tag, fields}}}` - the repaired
      product cannot be written exactly; `{tag, fields}` is one of the writer
      refusals `Sidereon.GNSS.RINEX.Observations` lists.
    * `{:error, {:crinex_encode_failed, {kind, message}}}` - the written RINEX
      does not compress, `kind` being `:parse`, `:invalid_input` or
      `:unhandled`.
  """
  @spec repair_obs_text(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def repair_obs_text(text, opts \\ []) when is_binary(text) do
    case NIF.rinex_qc_repair_obs_text(text, repair_options(opts)) do
      {:ok, repair} -> {:ok, normalize_repair(repair)}
      {:error, _reason} = err -> err
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :rinex_qc_repair_obs_text)
  end

  @doc """
  Mechanically repair RINEX NAV text.

  Content-changing repairs other than record sorting are opt-in. The repaired
  product's `iono` map carries every broadcast ionosphere set the header
  states: `gps`, `beidou`, `qzss` and `navic` Klobuchar `{alpha, beta}` pairs,
  `galileo` NeQuick G coefficients, `galileo_disturbance_flags` and the BeiDou
  BDGIM `beidou_bdgim` coefficients, each `nil` when absent.

  Returns `{:error, {:repaired_product_unwritable, {:not_representable, line,
  reason}}}` when the repaired record set cannot be written as RINEX
  navigation text, such as a set holding both a CNAV-family record and an
  unclassified Galileo record.
  """
  @spec repair_nav_text(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def repair_nav_text(text, opts \\ []) when is_binary(text) do
    case NIF.rinex_qc_repair_nav_text(text, repair_options(opts)) do
      {:ok, repair} -> {:ok, normalize_repair(repair)}
      {:error, _reason} = err -> err
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :rinex_qc_repair_nav_text)
  end

  @doc """
  Chi-square inverse CDF (quantile).
  """
  @spec chi2_inv(number(), integer()) :: float()
  def chi2_inv(p, k)
      when is_number(p) and is_integer(k) and k >= -9_223_372_036_854_775_808 and k <= 9_223_372_036_854_775_807 do
    case chi2_probability_float(p) do
      {:ok, probability} ->
        case NIF.qc_chi2_inv(probability, k) do
          {:ok, value} -> value
          {:error, kind} when kind in @quality_error_kinds -> raise quality_error(kind)
          {:error, _reason} -> raise_chi2_error!(p, k)
        end

      :unrepresentable ->
        raise_chi2_error!(p, k)
    end
  end

  def chi2_inv(p, k), do: raise_chi2_error!(p, k)

  defp chi2_probability_float(p) do
    {:ok, p / 1.0}
  rescue
    ArithmeticError -> :unrepresentable
  end

  defp variance_args(opts) do
    a = Keyword.get(opts, :a, @default_a) / 1.0
    b = Keyword.get(opts, :b, @default_b) / 1.0

    model =
      case Keyword.get(opts, :model, :elevation) do
        :elevation -> "elevation"
        :elevation_cn0 -> "elevation_cn0"
      end

    cn0 =
      case Keyword.get(opts, :cn0) do
        nil -> nil
        value -> value / 1.0
      end

    scale = Keyword.get(opts, :cn0_scale, 1.0) / 1.0
    {a, b, model, cn0, scale}
  end

  defp encode_weight_entry({sat, el}) do
    %{satellite_id: sat, elevation_deg: el / 1.0, cn0: nil}
  end

  defp encode_weight_entry({sat, el, cn0}) do
    %{satellite_id: sat, elevation_deg: el / 1.0, cn0: cn0 / 1.0}
  end

  defp run_raim(used_sats, residuals_m, variances_m2, opts) do
    p_fa = Keyword.get(opts, :p_fa, @default_p_fa)
    weights_opt = Keyword.get(opts, :weights, :solution)

    validate_p_fa!(p_fa)
    validate_weights!(weights_opt)
    {weights_mode, weights} = raim_weight_args(weights_opt, opts)
    n_systems = n_systems_arg(Keyword.get(opts, :n_systems))

    case NIF.qc_raim(
           used_sats,
           residuals_m,
           variances_m2,
           p_fa / 1.0,
           weights_mode,
           weights,
           n_systems
         ) do
      {:ok, result} ->
        result

      {:error, kind} when kind in @quality_error_kinds ->
        raise quality_error(kind)

      {:error, reason} ->
        raise ArgumentError, "RAIM refused input: #{inspect(reason)}"
    end
  end

  defp solution_raim_opts(solution, opts) do
    case Keyword.fetch(opts, :n_systems) do
      {:ok, nil} -> Keyword.put(opts, :n_systems, map_size(solution.system_clocks_s))
      {:ok, _explicit} -> opts
      :error -> Keyword.put(opts, :n_systems, map_size(solution.system_clocks_s))
    end
  end

  defp quality_error(kind) when kind in @quality_error_kinds do
    %QualityError{kind: kind, message: quality_error_message(kind)}
  end

  defp quality_error_message(:invalid_elevation), do: "invalid elevation"
  defp quality_error_message(:missing_cn0), do: "missing C/N0"
  defp quality_error_message(:invalid_parameter), do: "invalid quality parameter"
  defp quality_error_message(:invalid_reliability_parameter), do: "invalid reliability parameter"
  defp quality_error_message(:invalid_probability), do: "invalid probability"
  defp quality_error_message(:invalid_system_count), do: "invalid RAIM system count"
  defp quality_error_message(:invalid_dof), do: "invalid degrees of freedom"
  defp quality_error_message(:invalid_weight), do: "invalid RAIM weight"
  defp quality_error_message(:invalid_residuals), do: "invalid RAIM residuals"
  defp quality_error_message(:invalid_design), do: "invalid linearized measurement design"
  defp quality_error_message(:singular_geometry), do: "singular or rank-deficient geometry"

  defp quality_error_message(:missing_variances),
    do: "RAIM solution weighting requires actual variances in residual order"

  defp quality_error_message(:invalid_variance),
    do: "RAIM variances must be finite, positive, and aligned with used satellites"

  defp decode_raim_result(fields, :map) do
    %{
      fault_detected?: fields.fault_detected,
      fault_detected: fields.fault_detected,
      test_statistic: fields.test_statistic,
      threshold: fields.threshold,
      reduced_chi_square: fields.reduced_chi_square,
      dof: fields.dof,
      testable?: fields.testable,
      testable: fields.testable,
      normalized_residuals: Map.new(fields.normalized_residuals),
      rms_m: fields.rms_m,
      worst_sat: fields.worst_sat
    }
  end

  defp decode_raim_result(fields, :struct) do
    %RaimResult{
      fault_detected: fields.fault_detected,
      test_statistic: fields.test_statistic,
      threshold: fields.threshold,
      worst_sat: fields.worst_sat,
      reduced_chi_square: fields.reduced_chi_square,
      normalized_residuals: Map.new(fields.normalized_residuals),
      rms_m: fields.rms_m,
      dof: fields.dof,
      testable: fields.testable
    }
  end

  defp validate_p_fa!(p) do
    case validate_p_fa(p) do
      :ok ->
        :ok

      {:error, {:invalid_option, :p_fa}} ->
        raise ArgumentError,
              "raim :p_fa must be a number strictly between 0 and 1, got: #{inspect(p)}"
    end
  end

  defp validate_p_fa(p) when is_number(p) and p > 0.0 and p < 1.0, do: :ok

  defp validate_p_fa(_p), do: {:error, {:invalid_option, :p_fa}}

  defp validate_weights!(weights) do
    case validate_weights(weights) do
      :ok ->
        :ok

      {:error, {:invalid_option, :weights}} when is_map(weights) ->
        raise_weights_error!(weights)

      {:error, {:invalid_option, :weights}} ->
        raise ArgumentError,
              "raim :weights must be :solution, :unit, a %{sat => weight} map, or weight-entry list, got: #{inspect(weights)}"
    end
  end

  defp validate_weights(:solution), do: :ok
  defp validate_weights(:unit), do: :ok

  defp validate_weights(weights) when is_map(weights) do
    if Enum.all?(weights, fn {sat, w} -> is_binary(sat) and positive_finite_number?(w) end) do
      :ok
    else
      {:error, {:invalid_option, :weights}}
    end
  end

  defp validate_weights(entries) when is_list(entries) do
    if Enum.all?(entries, &valid_weight_entry?/1) do
      :ok
    else
      {:error, {:invalid_option, :weights}}
    end
  end

  defp validate_weights(_other), do: {:error, {:invalid_option, :weights}}

  defp valid_weight_entry?({sat, elevation}) do
    is_binary(sat) and finite_number?(elevation)
  end

  defp valid_weight_entry?({sat, elevation, cn0}) do
    is_binary(sat) and finite_number?(elevation) and finite_number?(cn0)
  end

  defp valid_weight_entry?(_entry), do: false

  defp positive_finite_number?(value), do: finite_number?(value) and value > 0

  defp finite_number?(value) when is_number(value) do
    converted = value / 1.0
    converted == converted and abs(converted) <= 1.7976931348623157e308
  rescue
    ArithmeticError -> false
  end

  defp finite_number?(_value), do: false

  defp raise_weights_error!(weights) do
    raise ArgumentError, "raim :weights must all be positive numbers, got: #{inspect(weights)}"
  end

  defp raim_weight_args(:solution, _opts), do: {:solution, []}
  defp raim_weight_args(:unit, _opts), do: {:unit, []}

  defp raim_weight_args(weights, _opts) when is_map(weights) do
    validate_weights!(weights)
    {:satellite, string_weight_pairs(weights)}
  end

  defp raim_weight_args(entries, opts) when is_list(entries) do
    weights =
      entries
      |> weight_vector(raim_variance_opts(opts))
      |> string_weight_pairs()

    {:satellite, weights}
  end

  defp raim_weight_args(weights, _opts) when not is_map(weights) and not is_list(weights) do
    raise ArgumentError,
          "raim :weights must be :solution, :unit, a %{sat => weight} map, or a weight-entry list, got: #{inspect(weights)}"
  end

  defp raim_variance_opts(opts) do
    opts
    |> Keyword.take([:a, :b, :model, :cn0, :cn0_scale])
    |> Keyword.update(:model, :elevation, & &1)
  end

  defp raise_chi2_error!(p, k) do
    raise ArgumentError,
          "chi2_inv probability must be strictly between 0 and 1 and dof must be a positive integer, got p=#{inspect(p)}, dof=#{inspect(k)}"
  end

  defp string_weight_pairs(weights) do
    for {sat, weight} <- weights, is_binary(sat), do: {sat, weight / 1.0}
  end

  defp n_systems_arg(nil), do: nil

  defp n_systems_arg(value) when is_integer(value) and value > 0 and value <= 9_223_372_036_854_775_807, do: value

  defp n_systems_arg(_value), do: raise(quality_error(:invalid_system_count))

  defp normalize_fde_row(%{id: id, residual_m: residual_m, design_row: design_row, weight: weight})
       when is_binary(id) and is_list(design_row) do
    %{
      id: id,
      residual_m: residual_m / 1.0,
      design_row: Enum.map(design_row, &(&1 / 1.0)),
      weight: weight / 1.0
    }
  end

  defp fde_impl(source, handle, observations, epoch, opts, robust?) do
    huber? = Keyword.get(opts, :huber, false)

    cond do
      Keyword.has_key?(opts, :max_iterations) ->
        {:error, {:invalid_option, :max_iterations}}

      huber? == true ->
        {:error, {:incompatible_options, [:robust, :huber]}}

      not is_boolean(huber?) ->
        {:error, {:invalid_option, :huber}}

      true ->
        run_core_fde(source, handle, observations, epoch, opts, robust?)
    end
  end

  defp run_core_fde(source, handle, observations, epoch, opts, robust?) do
    p_fa = Keyword.get(opts, :p_fa, @default_p_fa)
    weights_opt = Keyword.get(opts, :weights, :solution)
    max_exclusions = Keyword.get(opts, :max_exclusions, @default_max_exclusions)
    max_exclusion_rms_m = Keyword.get(opts, :max_exclusion_rms_m, @default_max_exclusion_rms_m)

    with :ok <- validate_p_fa(p_fa),
         :ok <- validate_weights(weights_opt),
         :ok <- validate_max_pdop(Keyword.get(opts, :max_pdop)),
         {:ok, max_exclusions} <- max_exclusions_arg(max_exclusions),
         {:ok, max_exclusion_rms_m} <- exclusion_rms_cap_arg(max_exclusion_rms_m),
         {:ok, pseudorange_code} <- Positioning.pseudorange_code_option(opts),
         {:ok, qzss_clock, troposphere_model} <- Positioning.model_options(opts),
         {:ok, args} <- fde_common_args(observations, epoch, opts) do
      {weights_mode, weights} = raim_weight_args(weights_opt, opts)
      n_systems = n_systems_arg(Keyword.get(opts, :n_systems))
      max_pdop = Keyword.get(opts, :max_pdop)

      nif_fun =
        case {source, robust?} do
          {:sp3, false} -> :qc_fde_sp3
          {:broadcast, false} -> :qc_fde_broadcast
          {:sp3, true} -> :qc_robust_fde_sp3
          {:broadcast, true} -> :qc_robust_fde_broadcast
        end

      result =
        apply(
          NIF,
          nif_fun,
          [handle | args] ++
            [
              p_fa / 1.0,
              weights_mode,
              weights,
              n_systems,
              max_exclusions,
              max_exclusion_rms_m,
              max_pdop,
              pseudorange_code,
              qzss_clock,
              troposphere_model
            ]
        )

      decode_fde_result(result)
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :qc_fde)
  end

  defp validate_max_pdop(nil), do: :ok
  defp validate_max_pdop(value) when is_number(value) and value > 0.0, do: :ok
  defp validate_max_pdop(_value), do: {:error, {:invalid_option, :max_pdop}}

  defp fde_common_args(observations, epoch, opts) do
    with {:ok, t_rx_j2000_s} <- Time.epoch_to_j2000_seconds_fractional(epoch),
         {:ok, sod} <- Time.second_of_day(epoch),
         {:ok, doy} <- Time.day_of_year(epoch) do
      obs = Enum.map(observations, fn {sat, pr} -> {sat, pr / 1.0} end)

      {:ok,
       [
         obs,
         t_rx_j2000_s,
         sod,
         doy,
         to_tuple4(Keyword.get(opts, :initial_guess, @default_initial_guess)),
         Keyword.get(opts, :ionosphere, false),
         Keyword.get(opts, :troposphere, false),
         to_tuple4(Keyword.get(opts, :klobuchar_alpha, @default_alpha)),
         to_tuple4(Keyword.get(opts, :klobuchar_beta, @default_beta)),
         Keyword.get(opts, :pressure_hpa, @default_pressure_hpa) / 1.0,
         Keyword.get(opts, :temperature_k, @default_temperature_k) / 1.0,
         Keyword.get(opts, :relative_humidity, @default_relative_humidity) / 1.0,
         Keyword.get(opts, :with_geodetic, true)
       ]}
    end
  end

  defp max_exclusions_arg(n) when is_integer(n) and n >= 0 and n <= 18_446_744_073_709_551_615, do: {:ok, n}

  defp max_exclusions_arg(_n), do: {:error, {:invalid_option, :max_exclusions}}

  defp min_redundancy_arg(n) when is_integer(n) and n >= 0 and n <= 18_446_744_073_709_551_615, do: {:ok, n}

  defp min_redundancy_arg(_n), do: {:error, {:invalid_option, :min_redundancy}}

  defp exclusion_rms_cap_arg(:infinity), do: {:ok, :infinity}

  defp exclusion_rms_cap_arg(n) when is_number(n) and n > 0 do
    if finite_number?(n) do
      {:ok, n / 1.0}
    else
      {:error, {:invalid_option, :max_exclusion_rms_m}}
    end
  rescue
    ArithmeticError -> {:error, {:invalid_option, :max_exclusion_rms_m}}
  end

  defp exclusion_rms_cap_arg(_n), do: {:error, {:invalid_option, :max_exclusion_rms_m}}

  defp decode_fde_result({:ok, {solution_raw, excluded, iterations, raim_fields}}) do
    case Decode.decode(solution_raw) do
      {:ok, solution} ->
        {:ok,
         %{
           solution: solution,
           excluded: excluded,
           iterations: iterations,
           raim: decode_raim_result(raim_fields, :map)
         }}

      {:error, _reason} = error ->
        error
    end
  end

  defp decode_fde_result({:error, {:fault_unresolved, {reason, solution_raw, excluded, iterations, raim_fields}}}) do
    case Decode.decode(solution_raw) do
      {:ok, solution} ->
        {:error,
         {:fault_unresolved,
          %{
            reason: reason,
            solution: solution,
            excluded: excluded,
            iterations: iterations,
            raim: decode_raim_result(raim_fields, :map)
          }}}

      {:error, _reason} = error ->
        error
    end
  end

  defp decode_fde_result({:error, kind}) when kind in @quality_error_kinds, do: {:error, quality_error(kind)}

  defp decode_fde_result({:error, reason}), do: {:error, reason}

  defp to_tuple4({_a, _b, _c, _d} = t), do: t

  defp to_tuple4([a, b, c, d]), do: {a / 1.0, b / 1.0, c / 1.0, d / 1.0}

  defp repair_options(opts) do
    %{
      file_stamp: file_stamp(Keyword.get(opts, :file_stamp)),
      set_interval: Keyword.get(opts, :set_interval, false),
      set_time_of_last_obs: Keyword.get(opts, :set_time_of_last_obs, false),
      set_obs_counts: Keyword.get(opts, :set_obs_counts, false),
      drop_empty_records: Keyword.get(opts, :drop_empty_records, false),
      sort_records: Keyword.get(opts, :sort_records, true),
      drop_unsupported: Keyword.get(opts, :drop_unsupported, false)
    }
  end

  defp file_stamp(nil), do: nil

  defp file_stamp({program, run_by, date}) do
    %{program: to_string(program), run_by: to_string(run_by), date: to_string(date)}
  end

  defp file_stamp(%{} = stamp) do
    %{
      program: Map.fetch!(stamp, :program),
      run_by: Map.fetch!(stamp, :run_by),
      date: Map.fetch!(stamp, :date)
    }
  end

  defp normalize_observation_report(report) when is_map(report) do
    %ObservationReport{
      handle: Map.fetch!(report, :handle),
      header: normalize_observation_header(report.header),
      total_epoch_records: report.total_epoch_records,
      observation_epochs: report.observation_epochs,
      event_records: report.event_records,
      power_failure_epochs: report.power_failure_epochs,
      skipped_records: report.skipped_records,
      interval_s: report.interval_s,
      interval_source: report.interval_source,
      missing_epochs: report.missing_epochs,
      data_gaps: structs(report.data_gaps, DataGap),
      clock_jumps: structs(report.clock_jumps, ClockJump),
      cycle_slips: normalize_cycle_slips(report.cycle_slips),
      multipath: normalize_multipath(report.multipath),
      systems: structs(report.systems, SystemObservation),
      satellites: structs(report.satellites, SatelliteObservation),
      satellite_signals: Enum.map(report.satellite_signals, &normalize_satellite_signal/1),
      system_signals: Enum.map(report.system_signals, &normalize_system_signal/1),
      lint_findings: structs(report.lint_findings, ObservationFinding),
      notes: structs(report.notes, ObservationNote)
    }
  end

  defp normalize_observation_header(header) when is_map(header) do
    %ObservationHeader{
      marker_name: header.marker_name,
      marker_number: header.marker_number,
      marker_type: header.marker_type,
      receiver: optional_struct(header.receiver, ObservationReceiver),
      antenna: optional_struct(header.antenna, ObservationAntenna),
      approx_position_m: header.approx_position_m,
      antenna_delta_hen_m: header.antenna_delta_hen_m,
      time_of_first_obs: optional_struct(header.time_of_first_obs, ObservationTime),
      time_of_last_obs: optional_struct(header.time_of_last_obs, ObservationTime),
      duration_s: header.duration_s
    }
  end

  defp normalize_cycle_slips(row) when is_map(row) do
    %CycleSlipQc{
      observations: row.observations,
      total_slips: row.total_slips,
      observations_per_slip: row.observations_per_slip,
      by_system: structs(row.by_system, SystemCycleSlipQc)
    }
  end

  defp normalize_multipath(report) when is_map(report) do
    %MultipathReport{
      satellites: Enum.map(report.satellites, &normalize_satellite_multipath/1),
      systems: Enum.map(report.systems, &normalize_system_multipath/1)
    }
  end

  defp normalize_satellite_multipath(row) when is_map(row) do
    %SatelliteMultipath{
      satellite: row.satellite,
      mp1: optional_struct(row.mp1, MultipathStats),
      mp2: optional_struct(row.mp2, MultipathStats)
    }
  end

  defp normalize_system_multipath(row) when is_map(row) do
    %SystemMultipath{
      system: row.system,
      mp1: optional_struct(row.mp1, MultipathStats),
      mp2: optional_struct(row.mp2, MultipathStats)
    }
  end

  defp normalize_satellite_signal(row) when is_map(row) do
    %SatelliteSignal{
      satellite: row.satellite,
      code: row.code,
      value_observations: row.value_observations,
      ssi: optional_struct(row.ssi, SsiHistogram),
      snr: optional_struct(row.snr, SnrStats)
    }
  end

  defp normalize_system_signal(row) when is_map(row) do
    %SystemSignal{
      system: row.system,
      code: row.code,
      value_observations: row.value_observations,
      ssi: optional_struct(row.ssi, SsiHistogram),
      snr: optional_struct(row.snr, SnrStats)
    }
  end

  defp optional_struct(nil, _module), do: nil
  defp optional_struct(value, module) when is_map(value), do: struct(module, value)

  defp structs(rows, module), do: Enum.map(rows, &struct(module, &1))

  defp normalize_repair(repair) when is_map(repair) do
    repair
    |> Map.update(:remaining, nil, &normalize_lint_report/1)
  end

  defp normalize_lint_report(report) when is_map(report) do
    report
    |> Map.put(:clean?, Map.get(report, :clean))
  end
end
