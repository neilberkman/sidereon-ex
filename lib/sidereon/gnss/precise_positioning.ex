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
  fixed.

  ## Observation format

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
  alias Sidereon.GNSS.RINEX.Clock
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
              required(:integer_method) => :lambda,
              required(:integer_ratio) => float() | :infinity,
              required(:integer_best_score) => float(),
              required(:integer_second_best_score) => float() | nil,
              required(:integer_candidates) => pos_integer(),
              required(:troposphere_applied) => boolean(),
              required(:ztd_estimated) => boolean(),
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

  @typedoc "A receiver ECEF position in metres."
  @type receiver ::
          {number(), number(), number()} | %{x_m: number(), y_m: number(), z_m: number()}

  @typedoc "A set of code/phase observations for one epoch."
  @type epoch_observations ::
          %{epoch: NaiveDateTime.t(), observations: [observation()]}
          | {NaiveDateTime.t(), [observation()]}

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
    * `:tropo_mapping` - the tropospheric mapping function when `:troposphere`
      is true: `:niell` (the climatological default) or `{:vmf1, samples}` where
      `samples` is a non-empty, ascending list of `%{mjd:, ah:, aw:}` site-wise
      VMF1 `a`-coefficient samples (the Saastamoinen zenith delays are unchanged;
      only the mapping differs).
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

  def solve_float(%SP3{} = sp3, observations, %NaiveDateTime{} = epoch, opts) when is_list(observations) do
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

  def solve_float_epochs(%SP3{} = sp3, epoch_observations, opts) when is_list(epoch_observations) do
    solve_float_epochs_auto_init(sp3, epoch_observations, opts)
  end

  def solve_float_epochs(%SP3{}, _epoch_observations, _opts), do: {:error, :no_epochs}

  defp solve_float_epochs_auto_init(%SP3{} = sp3, epoch_observations, opts) do
    spp_troposphere = Keyword.get(opts, :troposphere, false)

    with {:ok, epochs} <- normalize_epoch_observations(epoch_observations),
         {:ok, tropo} <- troposphere_options(opts),
         :ok <- ensure_multi_enough(epochs, tropo),
         {:ok, weights} <- weights(opts),
         {:ok, solve_opts} <- solve_options(opts),
         {:ok, auto_init} <- auto_init_term(opts, spp_troposphere),
         {:ok, screen?} <- residual_screen_option(opts) do
      solve_ppp_auto_init_float_core(sp3, epochs, auto_init, weights, tropo, solve_opts, screen?)
    end
  end

  defp position_tuple3(%{x_m: x, y_m: y, z_m: z}), do: {x, y, z}
  defp position_tuple3({x, y, z}), do: {x, y, z}

  defp solve_float_core(%SP3{handle: handle}, epoch, obs, state, weights, tropo, solve_opts) do
    [epoch_term] = core_epoch_terms([%{epoch: epoch, observations: obs}], tropo)

    case NIF.precise_positioning_solve_float(
           handle,
           epoch_term,
           core_single_initial_state_term(state),
           {weights.code, weights.phase, weights.elevation_weighting?},
           {solve_opts.max_iterations, solve_opts.position_tolerance_m, solve_opts.clock_tolerance_m,
            solve_opts.ambiguity_tolerance_m, solve_opts.ztd_tolerance_m},
           core_tropo_term(tropo),
           core_corrections_term(tropo)
         ) do
      {:ok, payload} -> {:ok, core_single_solution(payload, obs, tropo)}
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

  defp core_single_initial_state_term(state) do
    {
      position_tuple3(state.position),
      [state.clock_m],
      Map.to_list(state.ambiguities),
      nil
    }
  end

  defp explicit_initial_state_term(initial_state) do
    with {:ok, position} <- explicit_position(initial_state),
         {:ok, clocks} <- explicit_number_list(initial_state, :clocks_m),
         {:ok, ambiguities} <- explicit_number_map(initial_state, :ambiguities_m) do
      {:ok, {position, clocks, Map.to_list(ambiguities), Map.get(initial_state, :ztd_m)}}
    end
  end

  defp explicit_position(%{position_m: position}), do: {:ok, position_tuple3(position)}
  defp explicit_position(%{position: position}), do: {:ok, position_tuple3(position)}
  defp explicit_position(_initial_state), do: {:error, {:missing_field, :position_m}}

  defp explicit_number_list(map, key) do
    case Map.fetch(map, key) do
      {:ok, values} when is_list(values) ->
        if Enum.all?(values, &is_number/1) do
          {:ok, Enum.map(values, &(&1 / 1.0))}
        else
          {:error, {:invalid_field, key}}
        end

      {:ok, _values} ->
        {:error, {:invalid_field, key}}

      :error ->
        {:error, {:missing_field, key}}
    end
  end

  defp explicit_number_map(map, key) do
    case Map.fetch(map, key) do
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

  defp float_solution_payload(%MultiEpochSolution{} = solution, epochs) do
    epoch_index =
      epochs
      |> Enum.map(& &1.epoch)
      |> Enum.with_index()
      |> Map.new()

    with {:ok, residuals} <- float_solution_residuals(solution.residuals_m, epoch_index) do
      {:ok,
       {
         position_tuple3(solution.position),
         Enum.map(solution.epoch_clocks, & &1.rx_clock_m),
         Map.to_list(solution.ambiguities_m),
         solution.ztd_residual_m,
         residuals,
         solution.used_sats,
         {
           Map.fetch!(solution.metadata, :iterations),
           Map.fetch!(solution.metadata, :converged),
           Map.fetch!(solution.metadata, :status),
           Map.fetch!(solution.metadata, :code_rms_m),
           Map.fetch!(solution.metadata, :phase_rms_m),
           Map.fetch!(solution.metadata, :weighted_rms_m)
         }
       }}
    end
  end

  defp float_solution_residuals(residuals, epoch_index) do
    Enum.reduce_while(residuals, {:ok, []}, fn residual, {:ok, acc} ->
      case Map.fetch(epoch_index, residual.epoch) do
        {:ok, idx} ->
          {:cont,
           {:ok,
            [
              {
                idx,
                residual.satellite_id,
                residual.code_m,
                residual.phase_m,
                residual.code_weight,
                residual.phase_weight
              }
              | acc
            ]}}

        :error ->
          {:halt, {:error, {:unknown_float_solution_epoch, residual.epoch}}}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp core_tropo_term(%{enabled?: false} = tropo) do
    {false, false, @default_pressure_hpa, @default_temperature_k, @default_relative_humidity, tropo_mapping_term(tropo)}
  end

  defp core_tropo_term(%{enabled?: true, estimate_ztd?: estimate_ztd?, met: met} = tropo) do
    {true, estimate_ztd?, met.pressure_hpa, met.temperature_k, met.relative_humidity, tropo_mapping_term(tropo)}
  end

  # Tropospheric mapping selection. Absent or `:niell` is the Niell (1996)
  # climatological mapping (the default). `{:vmf1, samples}` selects VMF1 driven
  # by a site-wise `a`-coefficient series, each sample `%{mjd:, ah:, aw:}`.
  defp tropo_mapping_term(%{mapping: {:vmf1, samples}}) when is_list(samples) do
    Enum.map(samples, fn %{mjd: mjd, ah: ah, aw: aw} -> {mjd / 1.0, ah / 1.0, aw / 1.0} end)
  end

  defp tropo_mapping_term(_tropo), do: nil

  defp core_corrections_term(tropo) do
    corr = Map.get(tropo, :corrections, %{})

    {
      Map.get(corr, :sat_clock_relativity?, false),
      satellite_clock_term(Map.get(corr, :satellite_clock)),
      receiver_antenna_term(Map.get(corr, :receiver_antenna)),
      Map.get(corr, :solid_earth_tide?, false),
      Map.get(corr, :phase_windup?, false),
      satellite_antenna_term(Map.get(corr, :satellite_antenna)),
      {pole_tide_term(Map.get(corr, :pole_tide)), ocean_loading_term(Map.get(corr, :ocean_loading))}
    }
  end

  defp pole_tide_term(nil), do: nil

  defp pole_tide_term(%{xp_arcsec: xp, yp_arcsec: yp}), do: {xp / 1.0, yp / 1.0}

  defp ocean_loading_term(nil), do: nil

  defp ocean_loading_term(%{amplitude_m: amplitude, phase_deg: phase}) when is_list(amplitude) and is_list(phase) do
    {Enum.map(amplitude, fn row -> Enum.map(row, &(&1 / 1.0)) end),
     Enum.map(phase, fn row -> Enum.map(row, &(&1 / 1.0)) end)}
  end

  defp satellite_clock_term(nil), do: nil

  defp satellite_clock_term(%Clock{series: series}) do
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
           {integer_status, integer_ratio, integer_best_score, integer_second_best_score, integer_candidates,
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

  def solve_fixed_epochs(%SP3{} = sp3, epoch_observations, opts) when is_list(epoch_observations) do
    solve_fixed_epochs_auto_init(sp3, epoch_observations, opts)
  end

  def solve_fixed_epochs(%SP3{}, _epoch_observations, _opts), do: {:error, :no_epochs}

  @doc """
  Solve a static multi-epoch float PPP arc from an explicit initial state.
  """
  @spec solve_ppp_float(SP3.t(), list(), map(), keyword()) ::
          {:ok, MultiEpochSolution.t()} | {:error, term()}
  def solve_ppp_float(source, epoch_observations, initial_state, opts \\ [])

  def solve_ppp_float(%SP3{} = sp3, epoch_observations, initial_state, opts)
      when is_list(epoch_observations) and is_map(initial_state) do
    with {:ok, epochs} <- normalize_epoch_observations(epoch_observations),
         {:ok, initial} <- explicit_initial_state_term(initial_state),
         {:ok, tropo} <- troposphere_options(opts),
         :ok <- ensure_multi_enough(epochs, tropo),
         {:ok, weights} <- weights(opts),
         {:ok, solve_opts} <- solve_options(opts),
         {:ok, screen?} <- residual_screen_option(opts) do
      solve_ppp_float_core(sp3, epochs, initial, weights, tropo, solve_opts, screen?)
    end
  end

  def solve_ppp_float(%SP3{}, _epoch_observations, _initial_state, _opts), do: {:error, :no_epochs}

  @doc """
  Solve a static multi-epoch integer-fixed PPP arc from an existing float solution.
  """
  @spec solve_ppp_fixed(SP3.t(), list(), MultiEpochSolution.t(), keyword()) ::
          {:ok, FixedSolution.t()} | {:error, term()}
  def solve_ppp_fixed(source, epoch_observations, float_solution, opts \\ [])

  def solve_ppp_fixed(%SP3{} = sp3, epoch_observations, %MultiEpochSolution{} = float_solution, opts)
      when is_list(epoch_observations) do
    with {:ok, epochs} <- normalize_epoch_observations(epoch_observations),
         {:ok, tropo} <- troposphere_options(opts),
         :ok <- ensure_multi_enough(epochs, tropo),
         {:ok, weights} <- weights(opts),
         {:ok, solve_opts} <- solve_options(opts),
         {:ok, integer_opts} <- integer_options(opts),
         sat_ids = multi_satellite_ids(epochs),
         {:ok, wavelengths} <- ambiguity_wavelengths(sat_ids, opts),
         {:ok, offsets} <- ambiguity_offsets(sat_ids, opts),
         {:ok, float_payload} <- float_solution_payload(float_solution, epochs) do
      solve_ppp_fixed_core(
        sp3,
        epochs,
        float_payload,
        weights,
        tropo,
        solve_opts,
        integer_opts,
        wavelengths,
        offsets
      )
    end
  end

  def solve_ppp_fixed(%SP3{}, _epoch_observations, _float_solution, _opts), do: {:error, :no_epochs}

  defp solve_fixed_epochs_auto_init(%SP3{} = sp3, epoch_observations, opts) do
    spp_troposphere = Keyword.get(opts, :troposphere, false)

    with {:ok, epochs} <- normalize_epoch_observations(epoch_observations),
         {:ok, tropo} <- troposphere_options(opts),
         :ok <- ensure_multi_enough(epochs, tropo),
         {:ok, weights} <- weights(opts),
         {:ok, solve_opts} <- solve_options(opts),
         {:ok, integer_opts} <- integer_options(opts),
         {:ok, auto_init} <- auto_init_term(opts, spp_troposphere),
         {:ok, screen?} <- residual_screen_option(opts),
         sat_ids = multi_satellite_ids(epochs),
         {:ok, wavelengths} <- ambiguity_wavelengths(sat_ids, opts),
         {:ok, offsets} <- ambiguity_offsets(sat_ids, opts) do
      solve_ppp_auto_init_fixed_core(
        sp3,
        epochs,
        auto_init,
        weights,
        tropo,
        solve_opts,
        screen?,
        integer_opts,
        wavelengths,
        offsets
      )
    end
  end

  @doc """
  Solve a static multi-epoch float PPP arc with SPP auto-initialization,
  delegating the whole driver (the SPP code seed, the mean-position and per-epoch
  clock seeds, the phase-minus-code float ambiguity seeds, and the static float
  solve) to the `sidereon-core` `solve_ppp_auto_init_float` kernel.

  This is a thin delegation to the core auto-init driver: the seed the existing
  `solve_float_epochs/3` builds in Elixir is now formed inside the kernel. The
  `epoch_observations` and the measurement/tropo/correction options are the same
  as `solve_float_epochs/3`. Auto-init specific options:

    * `:initial_guess` - `%{position: {x, y, z}, clock_m: c}` to bypass the SPP
      seed entirely, or absent to run the per-epoch SPP auto-init
    * `:spp_initial_guess` - `{x, y, z, b}` SPP cold-start (default all-zero)
    * `:spp_troposphere` - apply the troposphere in the SPP seed (default `false`)
    * `:spp_met` - `%{pressure_hpa:, temperature_k:, relative_humidity:}` for the
      SPP seed troposphere (default standard atmosphere)

  Returns `{:ok, solution}` or `{:error, reason}`.
  """
  @spec solve_ppp_auto_init_float(SP3.t(), list(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def solve_ppp_auto_init_float(source, epoch_observations, opts \\ [])

  def solve_ppp_auto_init_float(%SP3{} = sp3, epoch_observations, opts) when is_list(epoch_observations) do
    with {:ok, epochs} <- normalize_epoch_observations(epoch_observations),
         {:ok, tropo} <- troposphere_options(opts),
         :ok <- ensure_multi_enough(epochs, tropo),
         {:ok, weights} <- weights(opts),
         {:ok, solve_opts} <- solve_options(opts),
         {:ok, auto_init} <- auto_init_term(opts),
         {:ok, screen?} <- residual_screen_option(opts) do
      solve_ppp_auto_init_float_core(sp3, epochs, auto_init, weights, tropo, solve_opts, screen?)
    end
  end

  def solve_ppp_auto_init_float(%SP3{}, _epoch_observations, _opts), do: {:error, :no_epochs}

  @doc """
  Solve a static multi-epoch integer-fixed PPP arc with SPP auto-initialization,
  delegating the whole driver (auto-init seed, the float solve, the LAMBDA
  integer fix, and the ambiguity-conditioned re-solve) to the `sidereon-core`
  `solve_ppp_auto_init_fixed` kernel.

  Options match `solve_fixed_epochs/3` plus the auto-init options documented on
  `solve_ppp_auto_init_float/3`. Returns `{:ok, solution}` or `{:error, reason}`.
  """
  @spec solve_ppp_auto_init_fixed(SP3.t(), list(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def solve_ppp_auto_init_fixed(source, epoch_observations, opts \\ [])

  def solve_ppp_auto_init_fixed(%SP3{} = sp3, epoch_observations, opts) when is_list(epoch_observations) do
    with {:ok, epochs} <- normalize_epoch_observations(epoch_observations),
         {:ok, tropo} <- troposphere_options(opts),
         :ok <- ensure_multi_enough(epochs, tropo),
         {:ok, weights} <- weights(opts),
         {:ok, solve_opts} <- solve_options(opts),
         {:ok, integer_opts} <- integer_options(opts),
         {:ok, auto_init} <- auto_init_term(opts),
         {:ok, screen?} <- residual_screen_option(opts),
         sat_ids = multi_satellite_ids(epochs),
         {:ok, wavelengths} <- ambiguity_wavelengths(sat_ids, opts),
         {:ok, offsets} <- ambiguity_offsets(sat_ids, opts) do
      solve_ppp_auto_init_fixed_core(
        sp3,
        epochs,
        auto_init,
        weights,
        tropo,
        solve_opts,
        screen?,
        integer_opts,
        wavelengths,
        offsets
      )
    end
  end

  def solve_ppp_auto_init_fixed(%SP3{}, _epoch_observations, _opts), do: {:error, :no_epochs}

  defp solve_ppp_float_core(%SP3{handle: handle}, epochs, initial, weights, tropo, solve_opts, screen?) do
    case NIF.precise_positioning_solve_ppp_float(
           handle,
           core_epoch_terms(epochs, tropo),
           initial,
           {weights.code, weights.phase, weights.elevation_weighting?},
           {solve_opts.max_iterations, solve_opts.position_tolerance_m, solve_opts.clock_tolerance_m,
            solve_opts.ambiguity_tolerance_m, solve_opts.ztd_tolerance_m},
           core_tropo_term(tropo),
           core_corrections_term(tropo),
           screen?
         ) do
      {:ok, payload} -> {:ok, core_multi_solution(payload, epochs, tropo)}
      {:error, _reason} = err -> err
    end
  end

  defp solve_ppp_fixed_core(
         %SP3{handle: handle},
         epochs,
         float_payload,
         weights,
         tropo,
         solve_opts,
         integer_opts,
         wavelengths,
         offsets
       ) do
    case NIF.precise_positioning_solve_ppp_fixed(
           handle,
           core_epoch_terms(epochs, tropo),
           float_payload,
           {weights.code, weights.phase, weights.elevation_weighting?},
           {solve_opts.max_iterations, solve_opts.position_tolerance_m, solve_opts.clock_tolerance_m,
            solve_opts.ambiguity_tolerance_m, solve_opts.ztd_tolerance_m},
           core_tropo_term(tropo),
           core_corrections_term(tropo),
           {Map.to_list(wavelengths), Map.to_list(offsets), integer_opts.ratio_threshold}
         ) do
      {:ok, payload} -> {:ok, core_fixed_solution(payload, epochs, tropo)}
      {:error, _reason} = err -> err
    end
  end

  defp solve_ppp_auto_init_float_core(%SP3{handle: handle}, epochs, auto_init, weights, tropo, solve_opts, screen?) do
    case NIF.precise_positioning_solve_ppp_auto_init_float(
           handle,
           core_epoch_terms(epochs, tropo),
           auto_init,
           {weights.code, weights.phase, weights.elevation_weighting?},
           {solve_opts.max_iterations, solve_opts.position_tolerance_m, solve_opts.clock_tolerance_m,
            solve_opts.ambiguity_tolerance_m, solve_opts.ztd_tolerance_m},
           core_tropo_term(tropo),
           core_corrections_term(tropo),
           screen?
         ) do
      {:ok, payload} -> {:ok, core_multi_solution(payload, epochs, tropo)}
      {:error, _reason} = err -> err
    end
  end

  defp solve_ppp_auto_init_fixed_core(
         %SP3{handle: handle},
         epochs,
         auto_init,
         weights,
         tropo,
         solve_opts,
         screen?,
         integer_opts,
         wavelengths,
         offsets
       ) do
    case NIF.precise_positioning_solve_ppp_auto_init_fixed(
           handle,
           core_epoch_terms(epochs, tropo),
           auto_init,
           {weights.code, weights.phase, weights.elevation_weighting?},
           {solve_opts.max_iterations, solve_opts.position_tolerance_m, solve_opts.clock_tolerance_m,
            solve_opts.ambiguity_tolerance_m, solve_opts.ztd_tolerance_m},
           core_tropo_term(tropo),
           core_corrections_term(tropo),
           screen?,
           {Map.to_list(wavelengths), Map.to_list(offsets), integer_opts.ratio_threshold}
         ) do
      {:ok, payload} -> {:ok, core_fixed_solution(payload, epochs, tropo)}
      {:error, _reason} = err -> err
    end
  end

  defp auto_init_term(opts, spp_troposphere_default \\ false) do
    with {:ok, initial_guess} <- auto_init_guess(Keyword.get(opts, :initial_guess)),
         {:ok, spp_initial_guess} <- auto_init_spp_guess(Keyword.get(opts, :spp_initial_guess)),
         {:ok, spp_troposphere} <-
           auto_init_spp_troposphere(Keyword.get(opts, :spp_troposphere, spp_troposphere_default)),
         {:ok, met} <- auto_init_met(Keyword.get(opts, :spp_met)) do
      {:ok, {initial_guess, spp_initial_guess, spp_troposphere, met}}
    end
  end

  defp auto_init_guess(nil), do: {:ok, nil}

  defp auto_init_guess({x, y, z, clock_m}) when is_number(x) and is_number(y) and is_number(z) and is_number(clock_m),
    do: {:ok, {{x / 1.0, y / 1.0, z / 1.0}, clock_m / 1.0}}

  defp auto_init_guess(%{position: {x, y, z}, clock_m: clock_m})
       when is_number(x) and is_number(y) and is_number(z) and is_number(clock_m),
       do: {:ok, {{x / 1.0, y / 1.0, z / 1.0}, clock_m / 1.0}}

  defp auto_init_guess(_guess), do: {:error, :invalid_initial_guess}

  defp auto_init_spp_guess(nil), do: {:ok, {0.0, 0.0, 0.0, 0.0}}

  defp auto_init_spp_guess({x, y, z, b}) when is_number(x) and is_number(y) and is_number(z) and is_number(b),
    do: {:ok, {x / 1.0, y / 1.0, z / 1.0, b / 1.0}}

  defp auto_init_spp_guess(_guess), do: {:error, :invalid_initial_guess}

  defp auto_init_spp_troposphere(value) when is_boolean(value), do: {:ok, value}
  defp auto_init_spp_troposphere(_value), do: {:error, {:invalid_option, :spp_troposphere}}

  defp auto_init_met(nil), do: {:ok, {1013.25, 288.15, 0.5}}

  defp auto_init_met(%{pressure_hpa: p, temperature_k: t, relative_humidity: rh})
       when is_number(p) and is_number(t) and is_number(rh), do: {:ok, {p / 1.0, t / 1.0, rh / 1.0}}

  defp auto_init_met(_met), do: {:error, {:invalid_option, :spp_met}}

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

  defp normalize_epoch_entry(%{epoch: %NaiveDateTime{} = epoch, observations: observations}) when is_list(observations),
    do: {:ok, epoch, observations}

  defp normalize_epoch_entry({%NaiveDateTime{} = epoch, observations}) when is_list(observations),
    do: {:ok, epoch, observations}

  defp normalize_epoch_entry(entry), do: {:error, {:invalid_epoch_observations, entry}}

  defp ensure_epoch_enough(_epoch, obs) when length(obs) >= 4, do: :ok

  defp ensure_epoch_enough(epoch, obs), do: {:error, {:too_few_epoch_observations, epoch, length(obs), 4}}

  defp ensure_multi_enough(epochs, _tropo) when length(epochs) < 2, do: {:error, {:too_few_epochs, length(epochs), 2}}

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
        mapping = Keyword.get(opts, :tropo_mapping, :niell)

        cond do
          not is_number(pressure) or pressure <= 0.0 ->
            {:error, {:invalid_option, :pressure_hpa}}

          not is_number(temperature) or temperature <= 0.0 ->
            {:error, {:invalid_option, :temperature_k}}

          not is_number(humidity) or humidity < 0.0 or humidity > 1.0 ->
            {:error, {:invalid_option, :relative_humidity}}

          estimate_ztd not in [true, false] ->
            {:error, {:invalid_option, :estimate_ztd}}

          not valid_tropo_mapping?(mapping) ->
            {:error, {:invalid_option, :tropo_mapping}}

          true ->
            {:ok,
             %{
               enabled?: true,
               estimate_ztd?: estimate_ztd,
               mapping: mapping,
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

  # The tropospheric mapping selection (default Niell): `:niell`, or
  # `{:vmf1, samples}` with a non-empty list of `%{mjd:, ah:, aw:}` site-wise
  # VMF1 `a`-coefficient samples (the core validates ordering and positivity).
  defp valid_tropo_mapping?(:niell), do: true

  defp valid_tropo_mapping?({:vmf1, samples}) when is_list(samples) and samples != [] do
    Enum.all?(samples, fn
      %{mjd: mjd, ah: ah, aw: aw} -> is_number(mjd) and is_number(ah) and is_number(aw)
      _ -> false
    end)
  end

  defp valid_tropo_mapping?(_other), do: false

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
      %Clock{} = clock -> {:ok, clock}
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

  defp ambiguity_id(obs), do: Map.get(obs, :ambiguity_id, obs.satellite_id)

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

  defp normalize_guess({x, y, z, clock_m}) when is_number(x) and is_number(y) and is_number(z) and is_number(clock_m),
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

  defp ztd_unknown_count(%{estimate_ztd?: true}), do: 1
  defp ztd_unknown_count(_tropo), do: 0

  defp ensure_single_epoch_troposphere(%{estimate_ztd?: true}), do: {:error, {:invalid_option, :estimate_ztd}}

  defp ensure_single_epoch_troposphere(_tropo), do: :ok

  defp residual_screen_option(opts) do
    case Keyword.get(opts, :residual_screen, false) do
      v when is_boolean(v) -> {:ok, v}
      _ -> {:error, {:invalid_option, :residual_screen}}
    end
  end

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
