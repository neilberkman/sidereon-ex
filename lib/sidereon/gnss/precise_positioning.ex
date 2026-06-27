defmodule Sidereon.GNSS.PrecisePositioning do
  @moduledoc """
  Carrier-phase precise-positioning primitives.

  This is the first precise-positioning layer above the code and carrier-phase
  combinations in `Sidereon.GNSS.IonosphereFree` / `Sidereon.GNSS.CarrierPhase`. It
  solves one SP3-backed epoch from dual-frequency ionosphere-free code and phase
  observations:

      P_IF_i = rho_i(x) + b - c * dt_sat_i + T_i
      L_IF_i = rho_i(x) + b - c * dt_sat_i + T_i + N_i

  where `x` is the receiver ECEF position, `b` is the receiver clock in metres,
  `T_i` is the optional a-priori slant tropospheric delay plus any estimated
  residual zenith delay mapped to the line of sight, and `N_i` is one float
  carrier-phase ambiguity per satellite, also in metres. The single-epoch state
  is linearized and iterated over `[x, y, z, b, N_1, N_2, ...]`.

  `solve_float/4` solves one epoch. `solve_float_epochs/3` solves a static
  multi-epoch arc with one receiver position, one receiver clock per epoch, and
  one ambiguity per satellite held constant across the arc. That multi-epoch
  model is the first step where carrier phase can tighten position instead of
  being absorbed entirely by one ambiguity per epoch. Multi-epoch and fixed
  solves can also estimate one residual zenith troposphere delay over the arc
  (`estimate_ztd: true`) after the a-priori Saastamoinen/Niell correction.

  `solve_fixed_epochs/3` starts from the same multi-epoch float model, runs
  LAMBDA/MLAMBDA integer least-squares on an explicit caller-supplied wavelength
  grid, then re-solves position and per-epoch clocks with those ambiguities held
  fixed. `solve_widelane_fixed_epochs/3` is the dual-frequency convenience path:
  it fixes the Melbourne-Wubbena wide-lane integer first, subtracts that known
  contribution from the ionosphere-free phase ambiguity, then runs the
  LAMBDA/MLAMBDA integer least-squares search on the remaining narrow-lane
  integer.

  ## Observation shape

  Observations may be maps or tuples:

      %{satellite_id: "G05", code_m: 24_000_000.0, phase_m: 24_012_345.0}
      {"G05", 24_000_000.0, 24_012_345.0}

  `code_m` and `phase_m` should normally be ionosphere-free combinations. Use
  `Sidereon.GNSS.IonosphereFree.iono_free/4` and
  `Sidereon.GNSS.IonosphereFree.iono_free_phase_cycles/4` to form them from raw
  dual-frequency RINEX observations.
  """

  alias Sidereon.GNSS.Antex
  alias Sidereon.GNSS.Core.AntennaTerms
  alias Sidereon.GNSS.Core.Constants
  alias Sidereon.GNSS.Core.Epoch
  alias Sidereon.GNSS.Core.Observations, as: CoreObservations
  alias Sidereon.GNSS.IonosphereFree
  alias Sidereon.GNSS.Positioning
  alias Sidereon.GNSS.SP3
  alias Sidereon.GNSS.Time
  alias Sidereon.NIF

  @default_max_iterations 8
  @default_position_tolerance_m 1.0e-4
  @default_clock_tolerance_m 1.0e-4
  @default_code_sigma_m 1.0
  @default_phase_sigma_m 0.01
  @default_pressure_hpa 1013.25
  @default_temperature_k 288.15
  @default_relative_humidity 0.5
  @default_ztd_tolerance_m 1.0e-4
  @default_integer_search_radius_cycles 1
  @default_integer_ratio_threshold 3.0
  @default_integer_candidate_limit 200_000
  @default_cycle_slip_policy :error
  @default_gf_threshold_m 0.05
  @default_mw_threshold_cycles 4.0
  @default_min_arc_gap_s 300.0
  @gap_reference ~N[2000-01-01 00:00:00]

  defmodule Solution do
    @moduledoc """
    Float-ambiguity phase positioning solution for one epoch.
    """

    @enforce_keys [
      :position,
      :rx_clock_s,
      :rx_clock_m,
      :ambiguities_m,
      :residuals_m,
      :used_sats,
      :metadata
    ]
    defstruct [
      :position,
      :rx_clock_s,
      :rx_clock_m,
      :ambiguities_m,
      :residuals_m,
      :used_sats,
      :metadata
    ]

    @type position :: %{x_m: float(), y_m: float(), z_m: float()}
    @type residual :: %{code_m: float(), phase_m: float()}

    @type t :: %__MODULE__{
            position: position(),
            rx_clock_s: float(),
            rx_clock_m: float(),
            ambiguities_m: %{String.t() => float()},
            residuals_m: %{String.t() => residual()},
            used_sats: [String.t()],
            metadata: %{
              iterations: pos_integer(),
              converged: boolean(),
              status: :position_tolerance | :max_iterations,
              code_rms_m: float(),
              phase_rms_m: float(),
              weighted_rms_m: float(),
              troposphere_applied: boolean()
            }
          }
  end

  defmodule MultiEpochSolution do
    @moduledoc """
    Static multi-epoch float-ambiguity phase positioning solution.
    """

    @enforce_keys [
      :position,
      :epoch_clocks,
      :ambiguities_m,
      :ztd_residual_m,
      :residuals_m,
      :used_sats,
      :epochs,
      :metadata
    ]
    defstruct [
      :position,
      :epoch_clocks,
      :ambiguities_m,
      :ztd_residual_m,
      :residuals_m,
      :used_sats,
      :epochs,
      :metadata
    ]

    @type position :: %{x_m: float(), y_m: float(), z_m: float()}

    @type epoch_clock :: %{
            epoch: NaiveDateTime.t(),
            rx_clock_s: float(),
            rx_clock_m: float()
          }

    @type residual :: %{
            required(:epoch) => NaiveDateTime.t(),
            required(:satellite_id) => String.t(),
            required(:code_m) => float(),
            required(:phase_m) => float(),
            optional(:code_weight) => float(),
            optional(:phase_weight) => float()
          }

    @type t :: %__MODULE__{
            position: position(),
            epoch_clocks: [epoch_clock()],
            ambiguities_m: %{String.t() => float()},
            ztd_residual_m: float() | nil,
            residuals_m: [residual()],
            used_sats: [String.t()],
            epochs: [NaiveDateTime.t()],
            metadata: %{
              iterations: pos_integer(),
              converged: boolean(),
              status: :state_tolerance | :max_iterations,
              n_epochs: pos_integer(),
              n_observations: pos_integer(),
              code_rms_m: float(),
              phase_rms_m: float(),
              weighted_rms_m: float(),
              troposphere_applied: boolean(),
              ztd_estimated: boolean()
            }
          }
  end

  defmodule FixedSolution do
    @moduledoc """
    Static multi-epoch integer-fixed carrier-phase solution.
    """

    @enforce_keys [
      :position,
      :epoch_clocks,
      :fixed_ambiguities_cycles,
      :fixed_ambiguities_m,
      :wide_lane_ambiguities_cycles,
      :ztd_residual_m,
      :float_solution,
      :residuals_m,
      :used_sats,
      :epochs,
      :metadata
    ]
    defstruct [
      :position,
      :epoch_clocks,
      :fixed_ambiguities_cycles,
      :fixed_ambiguities_m,
      :wide_lane_ambiguities_cycles,
      :ztd_residual_m,
      :float_solution,
      :residuals_m,
      :used_sats,
      :epochs,
      :metadata
    ]

    @type position :: %{x_m: float(), y_m: float(), z_m: float()}

    @type epoch_clock :: %{
            epoch: NaiveDateTime.t(),
            rx_clock_s: float(),
            rx_clock_m: float()
          }

    @type residual :: %{
            required(:epoch) => NaiveDateTime.t(),
            required(:satellite_id) => String.t(),
            required(:code_m) => float(),
            required(:phase_m) => float(),
            optional(:code_weight) => float(),
            optional(:phase_weight) => float()
          }

    @type t :: %__MODULE__{
            position: position(),
            epoch_clocks: [epoch_clock()],
            fixed_ambiguities_cycles: %{String.t() => integer()},
            fixed_ambiguities_m: %{String.t() => float()},
            wide_lane_ambiguities_cycles: %{String.t() => integer()} | nil,
            ztd_residual_m: float() | nil,
            float_solution: MultiEpochSolution.t(),
            residuals_m: [residual()],
            used_sats: [String.t()],
            epochs: [NaiveDateTime.t()],
            metadata: %{
              required(:iterations) => pos_integer(),
              required(:converged) => boolean(),
              required(:status) => :state_tolerance | :max_iterations,
              required(:n_epochs) => pos_integer(),
              required(:n_observations) => pos_integer(),
              required(:code_rms_m) => float(),
              required(:phase_rms_m) => float(),
              required(:weighted_rms_m) => float(),
              required(:integer_status) => :fixed | :not_fixed,
              required(:integer_method) => :lambda | :widelane_narrowlane_lambda,
              required(:integer_ratio) => float() | :infinity,
              required(:integer_best_score) => float(),
              required(:integer_second_best_score) => float() | nil,
              required(:integer_candidates) => pos_integer(),
              required(:troposphere_applied) => boolean(),
              required(:ztd_estimated) => boolean(),
              optional(:wide_lane_fixed) => boolean(),
              optional(:dropped_cycle_slip_sats) => [String.t()],
              optional(:split_cycle_slip_arcs) => [map()],
              optional(:ambiguity_search) => %{
                required(:order) => [String.t()],
                required(:float_cycles) => %{String.t() => float()},
                required(:covariance_cycles) => [[float()]],
                required(:covariance_inverse_cycles) => [[float()]]
              }
            }
          }
  end

  @typedoc "A dual-frequency ionosphere-free code/phase observation."
  @type observation ::
          %{satellite_id: String.t(), code_m: number(), phase_m: number()}
          | {String.t(), number(), number()}

  @typedoc "Raw dual-frequency code/phase observation for wide-lane/narrow-lane fixing."
  @type dual_frequency_observation :: %{
          required(:satellite_id) => String.t(),
          required(:p1_m) => number(),
          required(:p2_m) => number(),
          required(:phi1_cyc) => number(),
          required(:phi2_cyc) => number(),
          required(:f1_hz) => number(),
          required(:f2_hz) => number(),
          optional(:lli1) => integer() | nil,
          optional(:lli2) => integer() | nil
        }

  @typedoc "A receiver ECEF position in metres."
  @type receiver ::
          {number(), number(), number()} | %{x_m: number(), y_m: number(), z_m: number()}

  @typedoc "A set of code/phase observations for one epoch."
  @type epoch_observations ::
          %{epoch: NaiveDateTime.t(), observations: [observation()]}
          | {NaiveDateTime.t(), [observation()]}

  @typedoc "A set of raw dual-frequency observations for one epoch."
  @type dual_frequency_epoch_observations ::
          %{epoch: NaiveDateTime.t(), observations: [dual_frequency_observation()]}
          | {NaiveDateTime.t(), [dual_frequency_observation()]}

  @doc """
  Solve a float-ambiguity carrier-phase position for one SP3-backed epoch.

  `source` is a loaded `Sidereon.GNSS.SP3` product. `observations` is a list of
  ionosphere-free code/phase pairs for one epoch. `epoch` is interpreted in the
  SP3 product's time scale.

  ## Options

    * `:initial_guess` - `{x_m, y_m, z_m, clock_m}`. If omitted, the code
      observations are first passed through `Sidereon.GNSS.Positioning.solve/4`
      with ionosphere/troposphere disabled, and that code-only solution seeds
      the float solve.
    * `:spp_initial_guess` - code-only SPP seed used only when `:initial_guess`
      is omitted (default `{0, 0, 0, 0}`).
    * `:code_sigma_m` - code row standard deviation (default `1.0` m).
    * `:phase_sigma_m` - phase row standard deviation (default `0.01` m).
    * `:elevation_weighting` - when `true`, scale both code and phase row
      standard deviations by `1 / sin(elevation)` so low-elevation
      observations contribute less to the float, fixed, and ambiguity-covariance
      solves (default `false`).
    * `:max_iterations` - maximum nonlinear iterations (default `8`).
    * `:position_tolerance_m` - position-update convergence threshold
      (default `1.0e-4` m).
    * `:clock_tolerance_m` - receiver-clock update threshold (default
      `1.0e-4` m).
    * `:troposphere` - apply an a-priori Saastamoinen/Niell slant
      tropospheric delay to both code and phase (default `false`).
    * `:pressure_hpa` - surface pressure in hPa when `:troposphere` is true
      (default `1013.25`).
    * `:temperature_k` - surface temperature in kelvin when `:troposphere` is
      true (default `288.15`).
    * `:relative_humidity` - relative humidity fraction when `:troposphere` is
      true (default `0.5`).
    * `:estimate_ztd` - on multi-epoch/fixed solves only, estimate one residual
      zenith troposphere delay in metres over the whole static arc, mapped with
      the Niell wet mapping factor. Requires `troposphere: true` (default
      `false`).
    * `:ztd_tolerance_m` - residual-ZTD update convergence threshold when
      `:estimate_ztd` is true (default `1.0e-4` m).

  Returns `{:ok, %Solution{}}` or `{:error, reason}`. Reasons include
  `:no_observations`, `{:too_few_satellites, used, 4}`,
  `{:duplicate_observation, sat}`, `{:invalid_observation, entry}`,
  `:invalid_initial_guess`, `{:invalid_sigma, key}`, `{:invalid_option, key}`,
  `{:code_seed_failed, reason}`, `{:no_ephemeris, sat, reason}`,
  `{:troposphere_failed, sat, reason}`, and `:singular_geometry`. If the
  iteration limit is reached after a valid solve step, the function returns a
  solution with `metadata.converged == false` and
  `metadata.status == :max_iterations` so callers can inspect the residuals and
  decide whether to reject it.
  """
  @spec solve_float(SP3.t(), [observation()], NaiveDateTime.t(), keyword()) ::
          {:ok, Solution.t()} | {:error, term()}
  def solve_float(source, observations, epoch, opts \\ [])

  def solve_float(%SP3{} = sp3, observations, %NaiveDateTime{} = epoch, opts)
      when is_list(observations) do
    with :ok <- ensure_nonempty(observations),
         {:ok, obs} <- normalize_observations(observations),
         :ok <- ensure_enough(obs),
         {:ok, weights} <- weights(opts),
         {:ok, solve_opts} <- solve_options(opts),
         {:ok, tropo} <- troposphere_options(opts),
         :ok <- ensure_single_epoch_troposphere(tropo),
         {:ok, state} <- initial_state(sp3, obs, epoch, opts) do
      solve_float_core(sp3, epoch, obs, state, weights, tropo, solve_opts)
    end
  end

  def solve_float(%SP3{}, observations, %NaiveDateTime{}, _opts) when not is_list(observations),
    do: {:error, :no_observations}

  @doc """
  Solve a static multi-epoch float-ambiguity carrier-phase position.

  `epoch_observations` is a list of `%{epoch: epoch, observations: obs}` maps or
  `{epoch, obs}` tuples. The receiver position is static across the whole arc,
  each epoch gets its own receiver clock, and each satellite gets one ambiguity
  held constant across every epoch where that satellite appears.

  This model is still float ambiguity only. It does not fix integer ambiguities
  or estimate a stochastic PPP process, but it lets changing geometry across the
  arc separate position from carrier ambiguities.

  Options are the same as `solve_float/4`, plus:

    * `:ambiguity_tolerance_m` - maximum ambiguity-update convergence threshold
      (default `1.0e-4` m).

  Returns `{:ok, %MultiEpochSolution{}}` or `{:error, reason}`. Reasons include
  `:no_epochs`, `{:too_few_epochs, used, 2}`, `{:duplicate_epoch, epoch}`,
  `{:too_few_epoch_observations, epoch, used, 4}`,
  `{:too_few_equations, equations, unknowns}`, and the same observation,
  option, ephemeris, seeding, and geometry errors as `solve_float/4`.
  """
  @spec solve_float_epochs(SP3.t(), [epoch_observations()], keyword()) ::
          {:ok, MultiEpochSolution.t()} | {:error, term()}
  def solve_float_epochs(source, epoch_observations, opts \\ [])

  def solve_float_epochs(%SP3{} = sp3, epoch_observations, opts)
      when is_list(epoch_observations) do
    with {:ok, epochs} <- normalize_epoch_observations(epoch_observations),
         {:ok, cycle_slip_policy} <- float_cycle_slip_policy(opts),
         {:ok, epochs} <- split_float_arcs_on_cycle_slips(epochs, cycle_slip_policy, opts),
         {:ok, tropo} <- troposphere_options(opts),
         :ok <- ensure_multi_enough(epochs, tropo),
         {:ok, weights} <- weights(opts),
         {:ok, solve_opts} <- solve_options(opts),
         {:ok, state} <- initial_multi_state(sp3, epochs, opts),
         {:ok, screen?} <- residual_screen_option(opts),
         {:ok, strategy} <- strategy_option(opts) do
      state = state_with_ztd(state, tropo)
      solve_float_epochs_core(sp3, epochs, state, weights, tropo, solve_opts, screen?, strategy)
    end
  end

  def solve_float_epochs(%SP3{}, _epoch_observations, _opts), do: {:error, :no_epochs}

  defp position_tuple3(%{x_m: x, y_m: y, z_m: z}), do: {x, y, z}
  defp position_tuple3({x, y, z}), do: {x, y, z}

  defp solve_float_core(%SP3{handle: handle}, epoch, obs, state, weights, tropo, solve_opts) do
    [epoch_term] = core_epoch_terms([%{epoch: epoch, observations: obs}], tropo)

    case NIF.precise_positioning_solve_float(
           handle,
           epoch_term,
           core_single_initial_state_term(state),
           {weights.code, weights.phase, weights.elevation_weighting?},
           {solve_opts.max_iterations, solve_opts.position_tolerance_m,
            solve_opts.clock_tolerance_m, solve_opts.ambiguity_tolerance_m,
            solve_opts.ztd_tolerance_m},
           core_tropo_term(tropo),
           core_corrections_term(tropo)
         ) do
      {:ok, payload} -> {:ok, core_single_solution(payload, obs, tropo)}
      {:error, _reason} = err -> err
    end
  end

  defp solve_float_epochs_core(
         %SP3{handle: handle},
         epochs,
         state,
         weights,
         tropo,
         solve_opts,
         screen?,
         strategy
       ) do
    case NIF.precise_positioning_solve_float_epochs(
           handle,
           core_epoch_terms(epochs, tropo),
           core_initial_state_term(state, tropo),
           {weights.code, weights.phase, weights.elevation_weighting?},
           {solve_opts.max_iterations, solve_opts.position_tolerance_m,
            solve_opts.clock_tolerance_m, solve_opts.ambiguity_tolerance_m,
            solve_opts.ztd_tolerance_m},
           core_tropo_term(tropo),
           core_corrections_term(tropo),
           screen?,
           strategy
         ) do
      {:ok, payload} -> {:ok, core_multi_solution(payload, epochs, tropo)}
      {:error, _reason} = err -> err
    end
  end

  defp solve_fixed_epochs_core(
         %SP3{handle: handle},
         epochs,
         state,
         weights,
         tropo,
         solve_opts,
         screen?,
         integer_opts,
         wavelengths,
         offsets,
         strategy
       ) do
    case NIF.precise_positioning_solve_fixed_epochs(
           handle,
           core_epoch_terms(epochs, tropo),
           core_initial_state_term(state, tropo),
           {weights.code, weights.phase, weights.elevation_weighting?},
           {solve_opts.max_iterations, solve_opts.position_tolerance_m,
            solve_opts.clock_tolerance_m, solve_opts.ambiguity_tolerance_m,
            solve_opts.ztd_tolerance_m},
           core_tropo_term(tropo),
           core_corrections_term(tropo),
           screen?,
           {Map.to_list(wavelengths), Map.to_list(offsets), integer_opts.ratio_threshold},
           strategy
         ) do
      {:ok, payload} -> {:ok, core_fixed_solution(payload, epochs, tropo)}
      {:error, _reason} = err -> err
    end
  end

  defp core_epoch_terms(epochs, tropo) do
    needs_observation_frequency? =
      get_in(tropo, [:corrections, :phase_windup?]) and
        is_nil(get_in(tropo, [:corrections, :satellite_antenna]))

    Enum.map(epochs, fn %{epoch: %NaiveDateTime{} = epoch, observations: observations} ->
      {jd_whole, jd_fraction} = Time.epoch_to_split_jd(epoch)

      {
        Epoch.datetime_tuple(epoch),
        jd_whole,
        jd_fraction,
        Enum.map(observations, &core_observation_term(&1, needs_observation_frequency?))
      }
    end)
  end

  defp core_observation_term(observation, needs_frequency?) do
    raw = Map.get(observation, :raw, observation)
    f1 = if needs_frequency?, do: Map.fetch!(raw, :f1_hz), else: Map.get(raw, :f1_hz, 0.0)
    f2 = if needs_frequency?, do: Map.fetch!(raw, :f2_hz), else: Map.get(raw, :f2_hz, 0.0)

    {
      Map.fetch!(observation, :satellite_id),
      ambiguity_id(observation),
      Map.fetch!(observation, :code_m),
      Map.fetch!(observation, :phase_m),
      f1,
      f2
    }
  end

  defp core_initial_state_term(state, tropo) do
    {
      position_tuple3(state.position),
      state.clocks_m,
      Map.to_list(state.ambiguities),
      if(tropo.estimate_ztd?, do: state_ztd_m(state))
    }
  end

  defp core_single_initial_state_term(state) do
    {
      position_tuple3(state.position),
      [state.clock_m],
      Map.to_list(state.ambiguities),
      nil
    }
  end

  defp core_tropo_term(%{enabled?: false}) do
    {false, false, @default_pressure_hpa, @default_temperature_k, @default_relative_humidity}
  end

  defp core_tropo_term(%{enabled?: true, estimate_ztd?: estimate_ztd?, met: met}) do
    {true, estimate_ztd?, met.pressure_hpa, met.temperature_k, met.relative_humidity}
  end

  defp core_corrections_term(tropo) do
    corr = Map.get(tropo, :corrections, %{})

    {
      Map.get(corr, :sat_clock_relativity?, false),
      satellite_clock_term(Map.get(corr, :satellite_clock)),
      receiver_antenna_term(Map.get(corr, :receiver_antenna)),
      Map.get(corr, :solid_earth_tide?, false),
      Map.get(corr, :phase_windup?, false),
      satellite_antenna_term(Map.get(corr, :satellite_antenna))
    }
  end

  defp satellite_clock_term(nil), do: nil

  defp satellite_clock_term(%Sidereon.GNSS.RINEX.Clock{series: series}) do
    Enum.map(series, fn {sat, records} -> {sat, records} end)
  end

  defp receiver_antenna_term(nil), do: nil

  defp receiver_antenna_term(%{antenna: %Antex.Antenna{} = antenna, freq1: freq1, freq2: freq2})
       when is_binary(freq1) and is_binary(freq2) do
    {freq1, AntennaTerms.frequency_hz!(freq1), freq2, AntennaTerms.frequency_hz!(freq2),
     AntennaTerms.receiver_frequency_terms(antenna)}
  end

  defp satellite_antenna_term(nil), do: nil

  defp satellite_antenna_term(%{antex: %Antex{} = antex, freq1: freq1, freq2: freq2})
       when is_binary(freq1) and is_binary(freq2) do
    {freq1, AntennaTerms.frequency_hz!(freq1), freq2, AntennaTerms.frequency_hz!(freq2),
     AntennaTerms.satellite_terms(antex)}
  end

  defp core_multi_solution(
         {position, clocks_m, ambiguities, ztd, residuals, used_sats,
          {iterations, converged, status, code_rms_m, phase_rms_m, weighted_rms_m}},
         epochs,
         tropo
       ) do
    {x, y, z} = position
    epoch_by_index = epochs |> Enum.with_index() |> Map.new(fn {row, idx} -> {idx, row.epoch} end)

    %MultiEpochSolution{
      position: %{x_m: x, y_m: y, z_m: z},
      epoch_clocks:
        epochs
        |> Enum.map(& &1.epoch)
        |> Enum.zip(clocks_m)
        |> Enum.map(fn {epoch, clock_m} ->
          %{
            epoch: epoch,
            rx_clock_s: clock_m / Constants.speed_of_light_m_s(),
            rx_clock_m: clock_m
          }
        end),
      ambiguities_m: Map.new(ambiguities),
      ztd_residual_m: ztd,
      residuals_m:
        Enum.map(residuals, fn {idx, sat, code_m, phase_m, code_weight, phase_weight} ->
          %{
            epoch: Map.fetch!(epoch_by_index, idx),
            satellite_id: sat,
            code_m: code_m,
            phase_m: phase_m,
            code_weight: code_weight,
            phase_weight: phase_weight
          }
        end),
      used_sats: used_sats,
      epochs: Enum.map(epochs, & &1.epoch),
      metadata: %{
        iterations: iterations,
        converged: converged,
        status: status,
        n_epochs: length(epochs),
        n_observations: multi_observation_count(epochs),
        code_rms_m: code_rms_m,
        phase_rms_m: phase_rms_m,
        weighted_rms_m: weighted_rms_m,
        troposphere_applied: tropo.enabled?,
        ztd_estimated: tropo.estimate_ztd?
      }
    }
  end

  defp core_single_solution(
         {position, [clock_m], ambiguities, _ztd, residuals, _used_sats,
          {iterations, converged, status, code_rms_m, phase_rms_m, weighted_rms_m}},
         obs,
         tropo
       ) do
    {x, y, z} = position

    %Solution{
      position: %{x_m: x, y_m: y, z_m: z},
      rx_clock_s: clock_m / Constants.speed_of_light_m_s(),
      rx_clock_m: clock_m,
      ambiguities_m: Map.new(ambiguities),
      residuals_m:
        Map.new(residuals, fn {_idx, sat, code_m, phase_m, _code_weight, _phase_weight} ->
          {sat, %{code_m: code_m, phase_m: phase_m}}
        end),
      used_sats: Enum.map(obs, & &1.satellite_id),
      metadata: %{
        iterations: iterations,
        converged: converged,
        status: core_single_status(status),
        code_rms_m: code_rms_m,
        phase_rms_m: phase_rms_m,
        weighted_rms_m: weighted_rms_m,
        troposphere_applied: tropo.enabled?
      }
    }
  end

  defp core_single_status(:state_tolerance), do: :position_tolerance
  defp core_single_status(status), do: status

  defp core_fixed_solution(
         {position, clocks_m, {fixed_cycles, fixed_m}, {ztd, float_payload}, residuals, used_sats,
          {iterations, converged, status, code_rms_m, phase_rms_m, weighted_rms_m,
           {integer_status, integer_ratio, integer_best_score, integer_second_best_score,
            integer_candidates,
            {search_order, search_float_cycles, covariance_cycles, covariance_inverse_cycles}}}},
         epochs,
         tropo
       ) do
    {x, y, z} = position
    epoch_by_index = epochs |> Enum.with_index() |> Map.new(fn {row, idx} -> {idx, row.epoch} end)

    %FixedSolution{
      position: %{x_m: x, y_m: y, z_m: z},
      epoch_clocks:
        epochs
        |> Enum.map(& &1.epoch)
        |> Enum.zip(clocks_m)
        |> Enum.map(fn {epoch, clock_m} ->
          %{
            epoch: epoch,
            rx_clock_s: clock_m / Constants.speed_of_light_m_s(),
            rx_clock_m: clock_m
          }
        end),
      fixed_ambiguities_cycles: Map.new(fixed_cycles),
      fixed_ambiguities_m: Map.new(fixed_m),
      wide_lane_ambiguities_cycles: nil,
      ztd_residual_m: ztd,
      float_solution: core_multi_solution(float_payload, epochs, tropo),
      residuals_m:
        Enum.map(residuals, fn {idx, sat, code_m, phase_m, code_weight, phase_weight} ->
          %{
            epoch: Map.fetch!(epoch_by_index, idx),
            satellite_id: sat,
            code_m: code_m,
            phase_m: phase_m,
            code_weight: code_weight,
            phase_weight: phase_weight
          }
        end),
      used_sats: used_sats,
      epochs: Enum.map(epochs, & &1.epoch),
      metadata: %{
        iterations: iterations,
        converged: converged,
        status: status,
        n_epochs: length(epochs),
        n_observations: multi_observation_count(epochs),
        code_rms_m: code_rms_m,
        phase_rms_m: phase_rms_m,
        weighted_rms_m: weighted_rms_m,
        integer_status: integer_status,
        integer_method: :lambda,
        integer_ratio: integer_ratio,
        integer_best_score: integer_best_score,
        integer_second_best_score: integer_second_best_score,
        integer_candidates: integer_candidates,
        troposphere_applied: tropo.enabled?,
        ztd_estimated: tropo.estimate_ztd?,
        ambiguity_search: %{
          order: search_order,
          float_cycles: Map.new(search_float_cycles),
          covariance_cycles: covariance_cycles,
          covariance_inverse_cycles: covariance_inverse_cycles
        }
      }
    }
  end

  @doc """
  Solve a static multi-epoch position with integer-fixed ambiguities.

  The function first solves the float multi-epoch model (`solve_float_epochs/3`),
  converts each float ambiguity from metres to cycles using the explicit
  `:ambiguity_wavelength_m` option, runs the LAMBDA/MLAMBDA integer
  least-squares search, and re-solves the receiver position and per-epoch clocks
  with the best integer ambiguities held fixed.

  ## Required option

    * `:ambiguity_wavelength_m` - either a positive scalar wavelength in metres
      for every satellite, or a map `%{"G05" => wavelength_m, ...}`.

  ## Additional options

    * `:integer_ratio_threshold` - minimum second-best / best weighted-score
      ratio for `metadata.integer_status == :fixed` (default `3.0`).
    * `:integer_search_radius_cycles` / `:integer_candidate_limit` - retained and
      still validated for backward compatibility, but no longer bound the search:
      integer resolution uses the LAMBDA method (decorrelation + reduction +
      MLAMBDA search), which finds the true integer-least-squares optimum for any
      geometry with no search box, so it cannot return
      `{:error, {:too_many_integer_candidates, ...}}`.
    * `:ambiguity_offset_m` - optional scalar or `%{"G05" => offset_m, ...}` map
      subtracted from each float ambiguity before converting to cycles and added
      back after fixing (default `0.0`). This is mainly for affine carrier-phase
      combinations such as wide-lane/narrow-lane fixing.

  The fixed solution is returned even when the ratio test is not met; in that
  case `metadata.integer_status` is `:not_fixed` so callers can reject it.
  """
  @spec solve_fixed_epochs(SP3.t(), [epoch_observations()], keyword()) ::
          {:ok, FixedSolution.t()} | {:error, term()}
  def solve_fixed_epochs(source, epoch_observations, opts \\ [])

  def solve_fixed_epochs(%SP3{} = sp3, epoch_observations, opts)
      when is_list(epoch_observations) do
    with {:ok, epochs} <- normalize_epoch_observations(epoch_observations),
         {:ok, tropo} <- troposphere_options(opts),
         :ok <- ensure_multi_enough(epochs, tropo),
         {:ok, weights} <- weights(opts),
         {:ok, solve_opts} <- solve_options(opts),
         {:ok, integer_opts} <- integer_options(opts),
         {:ok, state} <- initial_multi_state(sp3, epochs, opts),
         {:ok, screen?} <- residual_screen_option(opts),
         sat_ids = multi_satellite_ids(epochs),
         {:ok, wavelengths} <- ambiguity_wavelengths(sat_ids, opts),
         {:ok, offsets} <- ambiguity_offsets(sat_ids, opts),
         {:ok, strategy} <- strategy_option(opts) do
      state = state_with_ztd(state, tropo)

      solve_fixed_epochs_core(
        sp3,
        epochs,
        state,
        weights,
        tropo,
        solve_opts,
        screen?,
        integer_opts,
        wavelengths,
        offsets,
        strategy
      )
    end
  end

  def solve_fixed_epochs(%SP3{}, _epoch_observations, _opts), do: {:error, :no_epochs}

  @doc """
  Solve a static multi-epoch position from raw dual-frequency observations by
  fixing wide-lane then narrow-lane ambiguities.

  This is the real-data convenience layer above `solve_fixed_epochs/3`. Each
  observation must carry both code and carrier phase on two bands:

      %{
        satellite_id: "G05",
        p1_m: 24_000_000.0,
        p2_m: 24_000_004.0,
        phi1_cyc: 123_456_789.0,
        phi2_cyc: 96_123_456.0,
        f1_hz: 1_575_420_000.0,
        f2_hz: 1_227_600_000.0,
        lli1: 0,
        lli2: 0
      }

  For each satellite the function first estimates the Melbourne-Wubbena
  wide-lane integer `Nw = N1 - N2` over the arc. It then forms ionosphere-free
  code/phase observations and fixes the remaining band-1 narrow-lane integer
  with LAMBDA/MLAMBDA integer least-squares using `lambda_NL = c / (f1 + f2)`.
  The returned `fixed_ambiguities_cycles` are those band-1 narrow-lane
  integers; the wide-lane integers are exposed as `wide_lane_ambiguities_cycles`.

  ## Options

  Accepts the same solve and integer-search options as `solve_fixed_epochs/3`,
  plus:

    * `:wide_lane_min_epochs` - minimum usable Melbourne-Wubbena epochs per
      satellite (default `2`).
    * `:wide_lane_tolerance_cycles` - maximum absolute distance between the
      averaged wide-lane float value and the nearest integer (default `0.5`
      cycles).
    * `:on_cycle_slip` - what to do when a satellite arc has a detected cycle
      slip: `:error` returns `{:error, {:cycle_slip_detected, sat, epoch,
      reasons}}` (default); `:drop_satellite` removes that satellite from the
      wide-lane and narrow-lane solve; `:split_arc` resets that satellite's
      ambiguity at each slip and keeps any resulting arc with at least
      `:wide_lane_min_epochs` usable epochs. Dropped satellites are reported in
      `metadata.dropped_cycle_slip_sats`; split fragments are reported in
      `metadata.split_cycle_slip_arcs`. Split fragments use ambiguity ids such
      as `"G21#2"` in `used_sats` and the ambiguity maps, while ephemeris lookup
      and residual rows continue to use the physical satellite id (`"G21"`).

  Cycle slips are detected with `Sidereon.GNSS.CarrierPhase.detect_cycle_slips/2`;
  pass `:gf_threshold_m` / `:mw_threshold_cycles` to tune that detector.
  """
  @spec solve_widelane_fixed_epochs(SP3.t(), [dual_frequency_epoch_observations()], keyword()) ::
          {:ok, FixedSolution.t()} | {:error, term()}
  def solve_widelane_fixed_epochs(source, dual_epoch_observations, opts \\ [])

  def solve_widelane_fixed_epochs(%SP3{} = sp3, dual_epoch_observations, opts)
      when is_list(dual_epoch_observations) do
    with {:ok, dual_epochs} <- normalize_dual_epoch_observations(dual_epoch_observations),
         {:ok, prep} <- prepare_widelane_fixed_epochs(dual_epochs, opts),
         fixed_opts =
           opts
           |> Keyword.put(:ambiguity_wavelength_m, prep.wavelengths)
           |> Keyword.put(:ambiguity_offset_m, prep.offsets),
         {:ok, %FixedSolution{} = sol} <- solve_fixed_epochs(sp3, prep.if_epochs, fixed_opts) do
      {:ok,
       %{
         sol
         | wide_lane_ambiguities_cycles: prep.wide_lane_cycles,
           metadata:
             Map.merge(sol.metadata, %{
               integer_method: :widelane_narrowlane_lambda,
               wide_lane_fixed: true,
               dropped_cycle_slip_sats: prep.slip_meta.dropped_sats,
               split_cycle_slip_arcs: prep.slip_meta.split_arcs
             })
       }}
    end
  end

  def solve_widelane_fixed_epochs(%SP3{}, _dual_epoch_observations, _opts),
    do: {:error, :no_epochs}

  # --- input normalization -------------------------------------------------

  defp ensure_nonempty([]), do: {:error, :no_observations}
  defp ensure_nonempty(_), do: :ok

  defp normalize_observations(observations) do
    CoreObservations.normalize_code_phase(observations,
      container: :list,
      sort?: true,
      include_raw?: true,
      lli: :none
    )
  end

  defp ensure_enough(obs) when length(obs) >= 4, do: :ok
  defp ensure_enough(obs), do: {:error, {:too_few_satellites, length(obs), 4}}

  defp normalize_epoch_observations([]), do: {:error, :no_epochs}

  defp normalize_epoch_observations(epoch_observations) do
    epoch_observations
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn entry, {:ok, acc, seen} ->
      case normalize_epoch_entry(entry) do
        {:ok, epoch, observations} ->
          if MapSet.member?(seen, epoch) do
            {:halt, {:error, {:duplicate_epoch, epoch}}}
          else
            with {:ok, obs} <- normalize_observations(observations),
                 :ok <- ensure_epoch_enough(epoch, obs) do
              {:cont, {:ok, [%{epoch: epoch, observations: obs} | acc], MapSet.put(seen, epoch)}}
            else
              {:error, _} = err -> {:halt, err}
            end
          end

        {:error, _} = err ->
          {:halt, err}
      end
    end)
    |> case do
      {:ok, acc, _seen} ->
        {:ok, Enum.sort_by(acc, &NaiveDateTime.to_iso8601(&1.epoch))}

      {:error, _} = err ->
        err
    end
  end

  defp normalize_epoch_entry(%{epoch: %NaiveDateTime{} = epoch, observations: observations})
       when is_list(observations), do: {:ok, epoch, observations}

  defp normalize_epoch_entry({%NaiveDateTime{} = epoch, observations}) when is_list(observations),
    do: {:ok, epoch, observations}

  defp normalize_epoch_entry(entry), do: {:error, {:invalid_epoch_observations, entry}}

  defp ensure_epoch_enough(_epoch, obs) when length(obs) >= 4, do: :ok

  defp ensure_epoch_enough(epoch, obs),
    do: {:error, {:too_few_epoch_observations, epoch, length(obs), 4}}

  defp normalize_dual_epoch_observations([]), do: {:error, :no_epochs}

  defp normalize_dual_epoch_observations(epoch_observations) do
    epoch_observations
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn entry, {:ok, acc, seen} ->
      case normalize_dual_epoch_entry(entry) do
        {:ok, epoch, observations} ->
          if MapSet.member?(seen, epoch) do
            {:halt, {:error, {:duplicate_epoch, epoch}}}
          else
            with {:ok, obs} <- normalize_dual_observations(observations),
                 :ok <- ensure_dual_epoch_enough(epoch, obs) do
              {:cont, {:ok, [%{epoch: epoch, observations: obs} | acc], MapSet.put(seen, epoch)}}
            else
              {:error, _} = err -> {:halt, err}
            end
          end

        {:error, _} = err ->
          {:halt, err}
      end
    end)
    |> case do
      {:ok, acc, _seen} ->
        {:ok, Enum.sort_by(acc, &NaiveDateTime.to_iso8601(&1.epoch))}

      {:error, _} = err ->
        err
    end
  end

  defp normalize_dual_epoch_entry(%{epoch: %NaiveDateTime{} = epoch, observations: observations})
       when is_list(observations), do: {:ok, epoch, observations}

  defp normalize_dual_epoch_entry({%NaiveDateTime{} = epoch, observations})
       when is_list(observations), do: {:ok, epoch, observations}

  defp normalize_dual_epoch_entry(entry), do: {:error, {:invalid_epoch_observations, entry}}

  defp normalize_dual_observations(observations) do
    CoreObservations.normalize_dual_frequency(observations,
      container: :list,
      sort?: true,
      include_raw?: true,
      lli: :dual,
      ambiguity_id: :satellite
    )
  end

  defp ensure_dual_epoch_enough(_epoch, obs) when length(obs) >= 4, do: :ok

  defp ensure_dual_epoch_enough(epoch, obs),
    do: {:error, {:too_few_epoch_observations, epoch, length(obs), 4}}

  defp ensure_multi_enough(epochs, _tropo) when length(epochs) < 2,
    do: {:error, {:too_few_epochs, length(epochs), 2}}

  defp ensure_multi_enough(epochs, tropo) do
    n_epochs = length(epochs)
    n_sats = length(multi_satellite_ids(epochs))
    n_observations = multi_observation_count(epochs)
    equations = 2 * n_observations
    unknowns = 3 + n_epochs + ztd_unknown_count(tropo) + n_sats

    cond do
      n_sats < 4 ->
        {:error, {:too_few_satellites, n_sats, 4}}

      equations < unknowns ->
        {:error, {:too_few_equations, equations, unknowns}}

      true ->
        :ok
    end
  end

  defp weights(opts) do
    code_sigma = Keyword.get(opts, :code_sigma_m, @default_code_sigma_m)
    phase_sigma = Keyword.get(opts, :phase_sigma_m, @default_phase_sigma_m)
    elevation_weighting = Keyword.get(opts, :elevation_weighting, false)

    cond do
      not is_number(code_sigma) or code_sigma <= 0.0 ->
        {:error, {:invalid_sigma, :code_sigma_m}}

      not is_number(phase_sigma) or phase_sigma <= 0.0 ->
        {:error, {:invalid_sigma, :phase_sigma_m}}

      elevation_weighting not in [true, false] ->
        {:error, {:invalid_option, :elevation_weighting}}

      true ->
        {:ok,
         %{
           code: 1.0 / code_sigma,
           phase: 1.0 / phase_sigma,
           elevation_weighting?: elevation_weighting
         }}
    end
  end

  defp solve_options(opts) do
    max_iterations = Keyword.get(opts, :max_iterations, @default_max_iterations)
    pos_tol = Keyword.get(opts, :position_tolerance_m, @default_position_tolerance_m)
    clock_tol = Keyword.get(opts, :clock_tolerance_m, @default_clock_tolerance_m)
    ambiguity_tol = Keyword.get(opts, :ambiguity_tolerance_m, @default_position_tolerance_m)
    ztd_tol = Keyword.get(opts, :ztd_tolerance_m, @default_ztd_tolerance_m)

    cond do
      not is_integer(max_iterations) or max_iterations < 1 ->
        {:error, {:invalid_option, :max_iterations}}

      not is_number(pos_tol) or pos_tol < 0.0 ->
        {:error, {:invalid_option, :position_tolerance_m}}

      not is_number(clock_tol) or clock_tol < 0.0 ->
        {:error, {:invalid_option, :clock_tolerance_m}}

      not is_number(ambiguity_tol) or ambiguity_tol < 0.0 ->
        {:error, {:invalid_option, :ambiguity_tolerance_m}}

      not is_number(ztd_tol) or ztd_tol < 0.0 ->
        {:error, {:invalid_option, :ztd_tolerance_m}}

      true ->
        {:ok,
         %{
           max_iterations: max_iterations,
           position_tolerance_m: pos_tol / 1.0,
           clock_tolerance_m: clock_tol / 1.0,
           ambiguity_tolerance_m: ambiguity_tol / 1.0,
           ztd_tolerance_m: ztd_tol / 1.0
         }}
    end
  end

  defp integer_options(opts) do
    radius =
      Keyword.get(opts, :integer_search_radius_cycles, @default_integer_search_radius_cycles)

    ratio = Keyword.get(opts, :integer_ratio_threshold, @default_integer_ratio_threshold)
    limit = Keyword.get(opts, :integer_candidate_limit, @default_integer_candidate_limit)

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

      true ->
        {:ok,
         %{
           radius_cycles: radius,
           ratio_threshold: ratio / 1.0,
           candidate_limit: limit
         }}
    end
  end

  # Parse the troposphere config and fold in the per-one-way-range correction
  # config under `:corrections`, so the single bundle threads to every
  # build/residual site (all of which already carry `tropo`) and into the shared
  # `range_corrections_m/7` chokepoint.
  defp troposphere_options(opts) do
    with {:ok, tropo} <- base_troposphere_options(opts),
         {:ok, corrections} <- corrections_options(opts) do
      {:ok, Map.put(tropo, :corrections, corrections)}
    end
  end

  defp base_troposphere_options(opts) do
    estimate_ztd = Keyword.get(opts, :estimate_ztd, false)

    case Keyword.get(opts, :troposphere, false) do
      false ->
        if estimate_ztd == false do
          {:ok, %{enabled?: false, met: nil, estimate_ztd?: false}}
        else
          {:error, {:invalid_option, :estimate_ztd}}
        end

      true ->
        pressure = Keyword.get(opts, :pressure_hpa, @default_pressure_hpa)
        temperature = Keyword.get(opts, :temperature_k, @default_temperature_k)
        humidity = Keyword.get(opts, :relative_humidity, @default_relative_humidity)

        cond do
          not is_number(pressure) or pressure <= 0.0 ->
            {:error, {:invalid_option, :pressure_hpa}}

          not is_number(temperature) or temperature <= 0.0 ->
            {:error, {:invalid_option, :temperature_k}}

          not is_number(humidity) or humidity < 0.0 or humidity > 1.0 ->
            {:error, {:invalid_option, :relative_humidity}}

          estimate_ztd not in [true, false] ->
            {:error, {:invalid_option, :estimate_ztd}}

          true ->
            {:ok,
             %{
               enabled?: true,
               estimate_ztd?: estimate_ztd,
               met: %{
                 pressure_hpa: pressure / 1.0,
                 temperature_k: temperature / 1.0,
                 relative_humidity: humidity / 1.0
               }
             }}
        end

      _other ->
        {:error, {:invalid_option, :troposphere}}
    end
  end

  # Per-one-way-range correction configuration, parsed once per solve and
  # threaded alongside the troposphere config to every build/residual site that
  # calls `range_corrections_m/7`.
  #
  #   * `:receiver_antenna` - `%{antenna: %Antex.Antenna{}, freq1: "G01",
  #     freq2: "G02"}` applies the receiver PCO/PCV as the ionosphere-free
  #     combination of the two single-frequency corrections. `nil` (default)
  #     applies no antenna correction.
  #   * `:satellite_clock_relativity` - `true` adds the eccentricity
  #     -2*dot(r_sat, v_sat)/c^2 term to the satellite clock. IGS final SP3/CLK
  #     products EXCLUDE this term, so it must be applied here in the forward
  #     model; broadcast ephemeris already carries it (do not double-apply).
  #     Default `false`.
  defp corrections_options(opts) do
    with {:ok, receiver_antenna} <- receiver_antenna_option(opts),
         {:ok, sat_clock_relativity?} <- sat_clock_relativity_option(opts),
         {:ok, satellite_clock} <- satellite_clock_option(opts),
         {:ok, solid_earth_tide?} <- solid_earth_tide_option(opts),
         {:ok, phase_windup?} <- phase_windup_option(opts),
         {:ok, satellite_antenna} <- satellite_antenna_option(opts) do
      {:ok,
       %{
         receiver_antenna: receiver_antenna,
         sat_clock_relativity?: sat_clock_relativity?,
         satellite_clock: satellite_clock,
         solid_earth_tide?: solid_earth_tide?,
         phase_windup?: phase_windup?,
         satellite_antenna: satellite_antenna,
         # Filled in by the solve entry after the arc + seed are known.
         precomputed: nil
       }}
    end
  end

  defp solid_earth_tide_option(opts) do
    case Keyword.get(opts, :solid_earth_tide, false) do
      v when is_boolean(v) -> {:ok, v}
      _ -> {:error, {:invalid_option, :solid_earth_tide}}
    end
  end

  defp phase_windup_option(opts) do
    case Keyword.get(opts, :phase_windup, false) do
      v when is_boolean(v) -> {:ok, v}
      _ -> {:error, {:invalid_option, :phase_windup}}
    end
  end

  # Satellite antenna PCO/PCV source: %{antex: %Antex{}, freq1: "G01", freq2:
  # "G02"}. The PCO is projected onto the satellite->receiver line of sight,
  # iono-free-combined, plus the nadir PCV, through the shared chokepoint.
  defp satellite_antenna_option(opts) do
    case Keyword.get(opts, :satellite_antenna) do
      nil ->
        {:ok, nil}

      %{antex: %Antex{} = antex, freq1: f1, freq2: f2}
      when is_binary(f1) and is_binary(f2) ->
        with {:ok, _hz1} <- AntennaTerms.frequency_hz(f1),
             {:ok, _hz2} <- AntennaTerms.frequency_hz(f2) do
          {:ok, %{antex: antex, freq1: f1, freq2: f2}}
        end

      _ ->
        {:error, {:invalid_option, :satellite_antenna}}
    end
  end

  defp receiver_antenna_option(opts) do
    case Keyword.get(opts, :receiver_antenna) do
      nil ->
        {:ok, nil}

      %{antenna: %Antex.Antenna{} = antenna, freq1: f1, freq2: f2}
      when is_binary(f1) and is_binary(f2) ->
        with {:ok, hz1} <- AntennaTerms.frequency_hz(f1),
             {:ok, hz2} <- AntennaTerms.frequency_hz(f2),
             {:ok, gamma} <- IonosphereFree.gamma(hz1, hz2) do
          {:ok, %{antenna: antenna, freq1: f1, freq2: f2, gamma: gamma}}
        else
          {:error, {:unsupported_frequency, _frequency}} = err -> err
          _ -> {:error, {:invalid_option, :receiver_antenna}}
        end

      _ ->
        {:error, {:invalid_option, :receiver_antenna}}
    end
  end

  defp sat_clock_relativity_option(opts) do
    case Keyword.get(opts, :satellite_clock_relativity, false) do
      v when is_boolean(v) -> {:ok, v}
      _ -> {:error, {:invalid_option, :satellite_clock_relativity}}
    end
  end

  # A precise RINEX clock product (`Sidereon.GNSS.RINEX.Clock`) whose finer-cadence
  # satellite clocks are preferred over the SP3-interpolated clock through the
  # shared range-corrections chokepoint. `nil` (default) keeps the SP3 clock.
  defp satellite_clock_option(opts) do
    case Keyword.get(opts, :satellite_clock) do
      nil -> {:ok, nil}
      %Sidereon.GNSS.RINEX.Clock{} = clock -> {:ok, clock}
      _ -> {:error, {:invalid_option, :satellite_clock}}
    end
  end

  defp ambiguity_wavelengths(sat_ids, opts) do
    case Keyword.fetch(opts, :ambiguity_wavelength_m) do
      {:ok, wavelength} when is_number(wavelength) and wavelength > 0.0 ->
        {:ok, Map.new(sat_ids, &{&1, wavelength / 1.0})}

      {:ok, wavelength_by_sat} when is_map(wavelength_by_sat) ->
        sat_ids
        |> Enum.reduce_while({:ok, %{}}, fn sat, {:ok, acc} ->
          case Map.fetch(wavelength_by_sat, sat) do
            {:ok, value} when is_number(value) and value > 0.0 ->
              {:cont, {:ok, Map.put(acc, sat, value / 1.0)}}

            _ ->
              {:halt, {:error, {:invalid_ambiguity_wavelength, sat}}}
          end
        end)

      {:ok, _other} ->
        {:error, {:invalid_option, :ambiguity_wavelength_m}}

      :error ->
        {:error, :ambiguity_wavelength_required}
    end
  end

  defp ambiguity_offsets(sat_ids, opts) do
    case Keyword.fetch(opts, :ambiguity_offset_m) do
      {:ok, offset} when is_number(offset) ->
        {:ok, Map.new(sat_ids, &{&1, offset / 1.0})}

      {:ok, offset_by_sat} when is_map(offset_by_sat) ->
        sat_ids
        |> Enum.reduce_while({:ok, %{}}, fn sat, {:ok, acc} ->
          case Map.fetch(offset_by_sat, sat) do
            {:ok, value} when is_number(value) ->
              {:cont, {:ok, Map.put(acc, sat, value / 1.0)}}

            _ ->
              {:halt, {:error, {:invalid_ambiguity_offset, sat}}}
          end
        end)

      {:ok, _other} ->
        {:error, {:invalid_option, :ambiguity_offset_m}}

      :error ->
        {:ok, Map.new(sat_ids, &{&1, 0.0})}
    end
  end

  defp prepare_widelane_fixed_epochs(epochs, opts) do
    with {:ok, wl_opts} <- wide_lane_options(opts),
         {:ok, slip_policy} <- cycle_slip_policy(opts) do
      case NIF.precise_positioning_prepare_widelane_fixed_epochs(
             core_dual_epoch_terms(epochs),
             {wl_opts.min_epochs, wl_opts.tolerance_cycles},
             Atom.to_string(slip_policy),
             cycle_slip_options!(opts)
           ) do
        {:ok, payload} ->
          {:ok, decode_widelane_prep(payload, epochs)}

        {:error, {:cycle_slip_detected, sat, epoch_idx, reasons}} ->
          {:error, {:cycle_slip_detected, sat, epoch_at_index(epochs, epoch_idx), reasons}}

        {:error, _reason} = err ->
          err
      end
    end
  end

  defp decode_widelane_prep(
         {if_epoch_terms, wavelength_terms, offset_terms, wide_lane_terms, dropped_sats,
          split_arc_terms},
         epochs
       ) do
    %{
      if_epochs:
        Enum.map(if_epoch_terms, fn {epoch_idx, observations} ->
          %{
            epoch: epoch_at_index(epochs, epoch_idx),
            observations:
              Enum.map(observations, fn {satellite_id, ambiguity_id, code_m, phase_m} ->
                %{
                  satellite_id: satellite_id,
                  ambiguity_id: ambiguity_id,
                  code_m: code_m,
                  phase_m: phase_m
                }
              end)
          }
        end),
      wavelengths: Map.new(wavelength_terms),
      offsets: Map.new(offset_terms),
      wide_lane_cycles: Map.new(wide_lane_terms),
      slip_meta: %{
        dropped_sats: dropped_sats,
        split_arcs:
          Enum.map(split_arc_terms, fn {satellite_id, ambiguity_id, start_idx, end_idx, n_epochs} ->
            %{
              satellite_id: satellite_id,
              ambiguity_id: ambiguity_id,
              start_epoch: epoch_at_index(epochs, start_idx),
              end_epoch: epoch_at_index(epochs, end_idx),
              n_epochs: n_epochs
            }
          end)
      }
    }
  end

  defp core_dual_epoch_terms(epochs) do
    Enum.map(epochs, fn epoch_row ->
      {epoch_time_s(epoch_row.epoch),
       Enum.map(epoch_row.observations, &core_dual_observation_term/1)}
    end)
  end

  defp core_dual_observation_term(obs) do
    %{
      satellite_id: obs.satellite_id,
      p1_m: obs.p1_m,
      p2_m: obs.p2_m,
      phi1_cyc: obs.phi1_cyc,
      phi2_cyc: obs.phi2_cyc,
      f1_hz: obs.f1_hz,
      f2_hz: obs.f2_hz,
      lli1: obs.lli1,
      lli2: obs.lli2
    }
  end

  defp wide_lane_options(opts) do
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

  defp cycle_slip_policy(opts) do
    case Keyword.get(opts, :on_cycle_slip, @default_cycle_slip_policy) do
      :error -> {:ok, :error}
      :drop_satellite -> {:ok, :drop_satellite}
      :split_arc -> {:ok, :split_arc}
      _other -> {:error, {:invalid_option, :on_cycle_slip}}
    end
  end

  # The float multi-epoch entry holds one ambiguity per (sat, arc). A satellite's
  # ambiguity is constant only within a slip-free arc, so a detected cycle slip
  # must START A NEW float ambiguity from that epoch. `:cycle_slip` selects the
  # behaviour:
  #
  #   * `:off` (default) - one ambiguity per satellite over the whole arc, no slip
  #     handling. Preserves the historical model (and byte-identical synthetic
  #     tests that never carry the dual-frequency slip inputs).
  #   * `:split_arc` - run `CarrierPhase.detect_cycle_slips/2` per satellite over
  #     the arc and start a new float ambiguity (a new `ambiguity_id` arc tag,
  #     e.g. "G21#2") after every slip, exactly as `solve_widelane_fixed_epochs`
  #     splits its wide-lane arcs. Slip detection (LLI bit0 / geometry-free / MW /
  #     300s data-gap) needs the raw dual-frequency observation carried on each
  #     iono-free row; rows missing it cannot be slip-checked and keep their
  #     per-satellite ambiguity unchanged.
  defp float_cycle_slip_policy(opts) do
    case Keyword.get(opts, :cycle_slip, :off) do
      :off -> {:ok, :off}
      :split_arc -> {:ok, :split_arc}
      _other -> {:error, {:invalid_option, :cycle_slip}}
    end
  end

  defp split_float_arcs_on_cycle_slips(epochs, :off, _opts), do: {:ok, epochs}

  defp split_float_arcs_on_cycle_slips(epochs, :split_arc, opts) do
    tagged_epochs =
      NIF.precise_positioning_split_float_cycle_slip_epochs(
        core_float_cycle_slip_terms(epochs),
        cycle_slip_options!(opts)
      )

    rewritten =
      Enum.zip(epochs, tagged_epochs)
      |> Enum.map(fn {epoch_row, tags} ->
        tags_by_sat = Map.new(tags)

        observations =
          Enum.map(epoch_row.observations, fn o ->
            case Map.fetch(tags_by_sat, o.satellite_id) do
              {:ok, ambiguity_id} -> %{o | ambiguity_id: ambiguity_id}
              :error -> o
            end
          end)

        %{
          epoch_row
          | observations: Enum.sort_by(observations, &{&1.satellite_id, ambiguity_id(&1)})
        }
      end)

    {:ok, rewritten}
  end

  defp core_float_cycle_slip_terms(epochs) do
    Enum.map(epochs, fn epoch_row ->
      {epoch_time_s(epoch_row.epoch),
       Enum.map(epoch_row.observations, &core_float_cycle_slip_observation_term/1)}
    end)
  end

  defp core_float_cycle_slip_observation_term(obs) do
    {obs.satellite_id, ambiguity_id(obs), core_dual_raw_term(obs)}
  end

  defp core_dual_raw_term(obs) do
    case dual_frequency_raw(obs) do
      {:ok, raw} ->
        %{
          satellite_id: obs.satellite_id,
          p1_m: raw.p1_m,
          p2_m: raw.p2_m,
          phi1_cyc: raw.phi1_cyc,
          phi2_cyc: raw.phi2_cyc,
          f1_hz: raw.f1_hz,
          f2_hz: raw.f2_hz,
          lli1: raw.lli1,
          lli2: raw.lli2
        }

      :error ->
        nil
    end
  end

  defp dual_frequency_raw(obs) do
    raw = Map.get(obs, :raw, %{})

    with phi1 when is_number(phi1) <- Map.get(raw, :phi1_cyc),
         phi2 when is_number(phi2) <- Map.get(raw, :phi2_cyc),
         p1 when is_number(p1) <- Map.get(raw, :p1_m),
         p2 when is_number(p2) <- Map.get(raw, :p2_m),
         f1 when is_number(f1) <- Map.get(raw, :f1_hz),
         f2 when is_number(f2) <- Map.get(raw, :f2_hz) do
      {:ok,
       %{
         phi1_cyc: phi1,
         phi2_cyc: phi2,
         p1_m: p1,
         p2_m: p2,
         f1_hz: f1,
         f2_hz: f2,
         lli1: Map.get(raw, :lli1),
         lli2: Map.get(raw, :lli2)
       }}
    else
      _ -> :error
    end
  end

  defp ambiguity_id(obs), do: Map.get(obs, :ambiguity_id, obs.satellite_id)

  defp cycle_slip_options!(opts) do
    {
      non_negative_slip_option!(
        :gf_threshold_m,
        Keyword.get(opts, :gf_threshold_m, @default_gf_threshold_m)
      ),
      non_negative_slip_option!(
        :mw_threshold_cycles,
        Keyword.get(opts, :mw_threshold_cycles, @default_mw_threshold_cycles)
      ),
      non_negative_slip_option!(
        :min_arc_gap_s,
        Keyword.get(opts, :min_arc_gap_s, @default_min_arc_gap_s)
      )
    }
  end

  defp non_negative_slip_option!(_name, value) when is_number(value) and value >= 0.0,
    do: value / 1.0

  defp non_negative_slip_option!(name, value) do
    raise ArgumentError, "#{inspect(name)} must be a non-negative number, got: #{inspect(value)}"
  end

  defp epoch_time_s(%NaiveDateTime{} = epoch) do
    NaiveDateTime.diff(epoch, @gap_reference, :microsecond) / 1_000_000.0
  end

  defp epoch_time_s(epoch) when is_number(epoch), do: epoch / 1.0
  defp epoch_time_s(_epoch), do: nil

  defp epoch_at_index(epochs, index), do: epochs |> Enum.at(index) |> Map.fetch!(:epoch)

  # --- initialization ------------------------------------------------------

  defp initial_state(sp3, obs, epoch, opts) do
    case Keyword.fetch(opts, :initial_guess) do
      {:ok, guess} ->
        with {:ok, {x, y, z, clock_m}} <- normalize_guess(guess) do
          {:ok, state_from_guess(obs, {x, y, z}, clock_m)}
        end

      :error ->
        spp_seed(sp3, obs, epoch, opts)
    end
  end

  defp normalize_guess({x, y, z, clock_m})
       when is_number(x) and is_number(y) and is_number(z) and is_number(clock_m),
       do: {:ok, {x / 1.0, y / 1.0, z / 1.0, clock_m / 1.0}}

  defp normalize_guess(_guess), do: {:error, :invalid_initial_guess}

  defp state_from_guess(obs, position, clock_m) do
    ambiguities =
      Map.new(obs, fn o ->
        {ambiguity_id(o), o.phase_m - o.code_m}
      end)

    %{position: position, clock_m: clock_m, ambiguities: ambiguities}
  end

  defp spp_seed(sp3, obs, epoch, opts) do
    observations = Enum.map(obs, &{&1.satellite_id, &1.code_m})
    spp_initial = Keyword.get(opts, :spp_initial_guess, {0.0, 0.0, 0.0, 0.0})

    case Positioning.solve(sp3, observations, epoch, spp_seed_options(opts, spp_initial)) do
      {:ok, sol} ->
        pos = {sol.position.x_m, sol.position.y_m, sol.position.z_m}
        state = state_from_guess(obs, pos, sol.rx_clock_s * Constants.speed_of_light_m_s())
        {:ok, state}

      {:error, reason} ->
        {:error, {:code_seed_failed, reason}}
    end
  end

  defp initial_multi_state(sp3, epochs, opts) do
    case Keyword.fetch(opts, :initial_guess) do
      {:ok, guess} ->
        with {:ok, {x, y, z, clock_m}} <- normalize_guess(guess) do
          {:ok,
           %{
             position: {x, y, z},
             clocks_m: List.duplicate(clock_m, length(epochs)),
             ambiguities: initial_ambiguities(epochs)
           }}
        end

      :error ->
        multi_spp_seed(sp3, epochs, opts)
    end
  end

  defp initial_ambiguities(epochs) do
    epochs
    |> Enum.flat_map(& &1.observations)
    |> Enum.reduce(%{}, fn obs, acc ->
      Map.put_new(acc, ambiguity_id(obs), obs.phase_m - obs.code_m)
    end)
  end

  defp multi_spp_seed(sp3, epochs, opts) do
    epochs
    |> Enum.reduce_while({:ok, [], []}, fn epoch_row, {:ok, positions, clocks} ->
      observations = Enum.map(epoch_row.observations, &{&1.satellite_id, &1.code_m})
      spp_initial = Keyword.get(opts, :spp_initial_guess, {0.0, 0.0, 0.0, 0.0})

      case Positioning.solve(
             sp3,
             observations,
             epoch_row.epoch,
             spp_seed_options(opts, spp_initial)
           ) do
        {:ok, sol} ->
          pos = {sol.position.x_m, sol.position.y_m, sol.position.z_m}
          clock_m = sol.rx_clock_s * Constants.speed_of_light_m_s()
          {:cont, {:ok, [pos | positions], [clock_m | clocks]}}

        {:error, reason} ->
          {:halt, {:error, {:code_seed_failed, epoch_row.epoch, reason}}}
      end
    end)
    |> case do
      {:ok, positions, clocks} ->
        {:ok,
         %{
           position: mean_position(positions),
           clocks_m: Enum.reverse(clocks),
           ambiguities: initial_ambiguities(epochs)
         }}

      {:error, _} = err ->
        err
    end
  end

  defp spp_seed_options(opts, initial_guess) do
    [
      ionosphere: false,
      troposphere: Keyword.get(opts, :troposphere, false),
      pressure_hpa: Keyword.get(opts, :pressure_hpa, @default_pressure_hpa),
      temperature_k: Keyword.get(opts, :temperature_k, @default_temperature_k),
      relative_humidity: Keyword.get(opts, :relative_humidity, @default_relative_humidity),
      initial_guess: initial_guess,
      with_geodetic: false
    ]
  end

  defp mean_position(positions) do
    {sx, sy, sz} =
      Enum.reduce(positions, {0.0, 0.0, 0.0}, fn {x, y, z}, {ax, ay, az} ->
        {ax + x, ay + y, az + z}
      end)

    n = length(positions)
    {sx / n, sy / n, sz / n}
  end

  defp state_with_ztd(state, %{estimate_ztd?: true}), do: Map.put_new(state, :ztd_m, 0.0)
  defp state_with_ztd(state, _tropo), do: state

  defp ztd_unknown_count(%{estimate_ztd?: true}), do: 1
  defp ztd_unknown_count(_tropo), do: 0

  defp ensure_single_epoch_troposphere(%{estimate_ztd?: true}),
    do: {:error, {:invalid_option, :estimate_ztd}}

  defp ensure_single_epoch_troposphere(_tropo), do: :ok

  defp residual_screen_option(opts) do
    case Keyword.get(opts, :residual_screen, false) do
      v when is_boolean(v) -> {:ok, v}
      _ -> {:error, {:invalid_option, :residual_screen}}
    end
  end

  # The opt-in estimation-strategy selector forwarded to the PPP NIF. Absent or
  # `:reference` is the unchanged PPP-oracle-faithful default; `:canonical`
  # selects the canonical (CanonicalSquareRoot owned-Cholesky) strategy, which
  # runs both the float seed and the integer-fixed re-solve under the canonical
  # square-root-information solve.
  defp strategy_option(opts) do
    case Keyword.get(opts, :strategy, :reference) do
      :reference -> {:ok, :reference}
      :canonical -> {:ok, :canonical}
      _ -> {:error, {:invalid_option, :strategy}}
    end
  end

  defp state_ztd_m(state), do: Map.get(state, :ztd_m, 0.0)

  defp multi_satellite_ids(epochs) do
    epochs
    |> Enum.flat_map(& &1.observations)
    |> Enum.map(&ambiguity_id/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp multi_observation_count(epochs) do
    Enum.reduce(epochs, 0, fn epoch, acc -> acc + length(epoch.observations) end)
  end
end
