defmodule Sidereon.GNSS.DGNSS do
  @moduledoc """
  Code-differential GNSS (DGPS) positioning over single-frequency pseudoranges.

  A *base* receiver at a surveyed (known) position turns its raw pseudoranges
  into per-satellite **pseudorange corrections (PRC)**. A *rover* applies those
  corrections to its own pseudoranges and runs a point-positioning solve. The
  subtraction `pr_rover - PRC` forms a single difference between the two
  receivers that cancels every error common to both: satellite-clock error,
  ephemeris error, and (over a short baseline) the ionospheric and tropospheric
  delays, leaving the rover position observable. This is the classical
  code-differential / RTCM-style PRC technique.

  ## Measurement model

  A measured single-frequency pseudorange is

      pr = geometric_range + c*rx_clock - c*sat_clock + atmosphere + ephemeris_error + noise

  At the known base the modelled value, written to match exactly the terms the
  point-positioning estimator removes internally (`geometric_range - c*sat_clock`),
  is

      m_base(sat) = geometric_range(base, sat) - c*sat_clock(sat)

  The pseudorange correction is the standard DGPS PRC

      PRC(sat) = pr_base(sat) - m_base(sat)

  Expanding `pr_base` shows the geometric range and the satellite-clock term
  cancel by construction, so

      PRC(sat) = c*rx_clock_base + atmosphere_base(sat) + ephemeris_error(sat) + noise_base(sat)

  i.e. everything common to both receivers plus the base receiver clock, which is
  a single per-station constant shared by every satellite.

  The rover forms

      pr_rover_corrected(sat) = pr_rover(sat) - PRC(sat)

  and runs `Sidereon.GNSS.Positioning.solve/4` with `ionosphere: false` and
  `troposphere: false` (the differential already removed those delays). The
  estimator re-applies its own `geometric_range(rover, sat) - c*sat_clock +
  c*rx_clock_rover` model. Because `m_base` subtracted `-c*sat_clock` exactly
  once and `pr_rover` still carries `-c*sat_clock` once, the corrected
  pseudorange contains the satellite-clock term exactly once and the estimator
  removes it exactly once: **the satellite clock is never double-counted.**

  ### Single-difference cancellation

  For a per-satellite additive error `e(sat)` common to base and rover (a
  satellite-clock error, an ephemeris error, or a short-baseline atmospheric
  delay): `pr_base` gains `+e(sat)`, so `PRC(sat)` gains `+e(sat)`; then
  `pr_rover_corrected = (pr_rover + e) - (PRC + e)` cancels `e(sat)` to machine
  precision.

  ### Base receiver clock

  PRC contributes the constant `c*rx_clock_base` to every satellite, so after
  `pr_rover - PRC` each rover pseudorange carries the same satellite-independent
  offset. A constant common to all pseudoranges is indistinguishable from a
  receiver-clock bias, so the estimator's recovered rover clock simply absorbs
  `rx_clock_rover - rx_clock_base`; the rover position is unaffected.

  ## Frame consistency

  `Sidereon.GNSS.Observables.predict/5` is evaluated with `light_time: true` and
  `sagnac: true` so the base modelled range lives in the same transmit-time,
  Earth-rotation-corrected frame the estimator uses; this is what makes the PRC
  consistent with the estimator's internal model.

  ## Non-goals

  This module covers single-frequency code-differential positioning only.
  Carrier-phase double differences, RTK / integer-ambiguity resolution, RTCM
  wire-format message encoding/decoding, network/VRS corrections, and a moving
  base are out of scope. A range-rate correction (RRC) is also a non-goal: the
  static single-epoch design carries no base/rover time offset over which to
  propagate it, even though `Sidereon.GNSS.Observables` exposes `range_rate_m_s`.
  """

  alias Sidereon.GNSS.Core.Types
  alias Sidereon.GNSS.Positioning.Decode
  alias Sidereon.GNSS.SP3
  alias Sidereon.GNSS.Time
  alias Sidereon.NIF

  @typedoc "A satellite id string, e.g. `\"G01\"`."
  @type sat :: String.t()

  @typedoc "A `{satellite_id, pseudorange_m}` pseudorange observation."
  @type observation :: {sat(), number()}

  @typedoc "Per-satellite pseudorange corrections in meters."
  @type corrections :: %{optional(sat()) => float()}

  @typedoc "An ECEF position as `{x_m, y_m, z_m}` or `%{x_m, y_m, z_m}`."
  @type position ::
          {number(), number(), number()} | %{x_m: number(), y_m: number(), z_m: number()}

  @default_initial_guess {0.0, 0.0, 0.0, 0.0}

  @doc """
  Compute per-satellite pseudorange corrections (PRC) from the surveyed base.

  `source` is a loaded `Sidereon.GNSS.SP3` product; `base_position` is the known base
  ECEF position; `base_observations` is a list of `{satellite_id,
  pseudorange_m}` pairs; `epoch` is the receive epoch (`NaiveDateTime`, in the
  product's time scale).

  For each base observation the modelled value
  `m_base = geometric_range(base, sat) - c*sat_clock(sat)` is taken from
  `Sidereon.GNSS.Observables.predict/5` (light-time and Sagnac on) and the
  correction is `PRC = pr_base - m_base`. A satellite whose ephemeris cannot be
  evaluated at this epoch is dropped from the result (it cannot be corrected)
  rather than failing the batch.

  Returns `{:ok, %{sat => prc_m}}`, or a tagged error:
  `{:error, :invalid_base_position}` for a malformed base position,
  `{:error, :empty_base_observations}`, or
  `{:error, {:invalid_base_observations, term}}` for a bad shape. Never raises.
  """
  @spec corrections(SP3.t(), position(), [observation()], NaiveDateTime.t(), keyword()) ::
          {:ok, corrections()} | {:error, term()}
  def corrections(source, base_position, base_observations, epoch, opts \\ [])

  def corrections(%SP3{} = source, base_position, base_observations, %NaiveDateTime{} = epoch, _opts)
      when is_list(base_observations) do
    with {:ok, base} <- normalize_position(base_position),
         :ok <- validate_observations(base_observations, :invalid_base_observations),
         :ok <- non_empty(base_observations, :empty_base_observations),
         {:ok, t_rx_j2000_s} <- Time.epoch_to_j2000_seconds_fractional(epoch) do
      prc =
        NIF.dgnss_corrections(
          source.handle,
          base,
          observation_terms(base_observations),
          t_rx_j2000_s
        )

      {:ok, Map.new(prc)}
    end
  end

  def corrections(%SP3{}, _base_position, base_observations, %NaiveDateTime{}, _opts),
    do: {:error, {:invalid_base_observations, base_observations}}

  @doc """
  Apply corrections to rover observations, pairing by satellite.

  Returns `{corrected, dropped}` where `corrected` is the list of
  `{satellite_id, pr_corrected_m}` for every satellite present in **both** the
  rover observations and the corrections (`pr_corrected = pr_rover - PRC(sat)`),
  and `dropped` is the list of rover satellite ids that have no correction.
  Corrections without a matching rover observation are ignored. The pairing is
  order-independent (it is keyed on the satellite id).

  This shadows `Kernel.apply/2` inside the module; call it qualified as
  `Sidereon.GNSS.DGNSS.apply/2`.
  """
  @spec apply([observation()], corrections()) :: {[observation()], [sat()]}
  def apply(rover_observations, corrections) when is_list(rover_observations) and is_map(corrections) do
    NIF.dgnss_apply(observation_terms(rover_observations), Map.to_list(corrections))
  end

  @doc """
  Differential position solve for the rover from base + rover pseudoranges.

  Delegates the whole workflow to the `sidereon_core` DGNSS driver: it computes
  the base corrections, applies them to the rover observations, runs the
  corrected-pseudorange point-positioning solve, and derives the baseline, all in
  the core. The corrected solve always disables the ionosphere and troposphere
  terms because the differential has already removed those delays. The
  `:initial_guess` and `:with_geodetic` options are passed through; any
  meteorology/Klobuchar options have no effect since the atmosphere terms are
  disabled. The result is a `Sidereon.GNSS.Positioning.Solution` paired with the
  baseline, exactly as a corrected-pseudorange `Sidereon.GNSS.Positioning.solve/4`
  would produce.

  On success returns

      {:ok, %{
        solution: %Sidereon.GNSS.Positioning.Solution{},
        baseline_vector_m: %{x_m: float(), y_m: float(), z_m: float()},
        baseline_m: float(),
        dropped_sats: [sat()]
      }}

  where the baseline vector points from the base position to the solved rover
  position and `baseline_m` is its length. Errors from any stage, including a bad
  observation shape or a point-positioning error such as
  `{:too_few_satellites, used, required}`, are propagated as `{:error,
  reason}`. Never raises.
  """
  @spec position(
          SP3.t(),
          position(),
          [observation()],
          [observation()],
          NaiveDateTime.t(),
          keyword()
        ) :: {:ok, map()} | {:error, term()}
  def position(source, base_position, base_observations, rover_observations, epoch, opts \\ [])

  def position(%SP3{} = source, base_position, base_observations, rover_observations, %NaiveDateTime{} = epoch, opts)
      when is_list(base_observations) and is_list(rover_observations) do
    with {:ok, base} <- normalize_position(base_position),
         :ok <- validate_observations(base_observations, :invalid_base_observations),
         :ok <- non_empty(base_observations, :empty_base_observations),
         :ok <- validate_observations(rover_observations, :invalid_rover_observations),
         :ok <- non_empty(rover_observations, :empty_rover_observations),
         {:ok, t_rx_j2000_s} <- Time.epoch_to_j2000_seconds_fractional(epoch) do
      NIF.dgnss_position(
        source.handle,
        base,
        observation_terms(base_observations),
        observation_terms(rover_observations),
        t_rx_j2000_s,
        Time.second_of_day(epoch),
        Time.day_of_year(epoch),
        initial_guess(opts),
        Keyword.get(opts, :with_geodetic, true)
      )
      |> decode_position()
    end
  end

  def position(%SP3{}, _base, _base_obs, rover_observations, %NaiveDateTime{}, _opts)
      when not is_list(rover_observations), do: {:error, {:invalid_rover_observations, rover_observations}}

  def position(%SP3{}, _base, base_observations, _rover_obs, %NaiveDateTime{}, _opts),
    do: {:error, {:invalid_base_observations, base_observations}}

  # --- helpers -------------------------------------------------------------

  defp validate_observations(observations, tag) do
    if Enum.all?(observations, &valid_observation?/1) do
      :ok
    else
      {:error, {tag, observations}}
    end
  end

  defp valid_observation?({sat, pr}) when is_binary(sat) and is_number(pr), do: true
  defp valid_observation?(_), do: false

  defp non_empty([], tag), do: {:error, tag}
  defp non_empty(_list, _tag), do: :ok

  defp normalize_position(position), do: Types.normalize_ecef(position, :invalid_base_position)

  defp observation_terms(observations), do: Enum.map(observations, fn {sat, pr} -> {sat, pr / 1.0} end)

  defp initial_guess(opts) do
    case Keyword.get(opts, :initial_guess, @default_initial_guess) do
      {a, b, c, d} -> {a / 1.0, b / 1.0, c / 1.0, d / 1.0}
      [a, b, c, d] -> {a / 1.0, b / 1.0, c / 1.0, d / 1.0}
    end
  end

  # Decode the single-driver result. The success term carries the SPP solution
  # body (decoded by the shared positioning decoder), the base-to-rover baseline
  # vector and length, and the rover satellites with no matching correction. Any
  # other term is a solve error mapped through the shared error decoder.
  defp decode_position({:ok, {body, {dx, dy, dz}, baseline_m, dropped}}) do
    case Decode.decode({:ok, body}) do
      {:ok, solution} ->
        {:ok,
         %{
           solution: solution,
           baseline_vector_m: %{x_m: dx, y_m: dy, z_m: dz},
           baseline_m: baseline_m,
           dropped_sats: dropped
         }}

      {:error, _reason} = error ->
        error
    end
  end

  defp decode_position(error), do: Decode.map_solve_error(error)
end
