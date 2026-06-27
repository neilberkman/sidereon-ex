defmodule Sidereon.GNSS.Observables do
  @moduledoc """
  Predict the GNSS observables a receiver at a known ECEF position would see for
  a satellite, from a precise (SP3) or broadcast ephemeris source.

  This is the forward model behind the question "is this measurement physically
  plausible?": given a receiver position, a satellite, and a receive epoch, it
  computes the geometric range, the line-of-sight range rate, the L1 Doppler,
  the topocentric azimuth/elevation, the satellite clock offset, and the signal
  transmit time. The Rust core evaluates the loaded SP3 or broadcast ephemeris
  handle and applies standard textbook GNSS geometry; this module keeps only the
  Elixir API shape and result mapping. It never solves the inverse
  (positioning) problem.

  ## Algorithm (standard GNSS geometry)

  * **Light-time / transmit-time correction.** The signal seen at the receive
    epoch `t_rx` left the satellite earlier, at
    `t_tx = t_rx - |r_sat(t_tx) - r_rx| / c`. This is solved by fixed-point
    iteration starting from `t_tx = t_rx`; a couple of iterations converge to
    sub-millimetre level for a coarse receiver position. The satellite state is
    evaluated at the fractional epoch `t_tx` (the SP3 spline is sampled at
    sub-second precision).

  * **Sagnac / Earth-rotation correction.** During the travel time `tau` the
    Earth-fixed (ECEF) frame rotates by `omega_e * tau`. The satellite position
    computed in the ECEF frame at `t_tx` is rotated about the Z axis by
    `Rz(omega_e * tau)` into the receive-epoch ECEF frame before differencing,
    with `omega_e = 7.2921151467e-5 rad/s`. This is the Sagnac (Earth-rotation)
    correction.

  * **Geometric range** is `|r_sat_rot - r_rx|` in metres, and the
    line-of-sight unit vector points from the receiver to the satellite.

  * **Range rate.** The satellite velocity at `t_tx` is obtained by central
    finite difference of `Sidereon.GNSS.SP3.position/3` (+/- 0.5 s). For a static
    receiver (`v_rx = 0`) the range rate is the LOS projection
    `los . (v_sat - v_rx)`, which equals `d(range)/dt`.

  * **Doppler (IS-GPS-200 L1 carrier).** `doppler_hz = -range_rate * f / c`
    with the L1 carrier `f = 1575.42 MHz` and `c = 299792458 m/s`.

  ## Sign conventions

  `range_rate_m_s` is the time derivative of the geometric range: it is
  **negative when the satellite is approaching** (range decreasing) and positive
  when receding. The Doppler shift is the negative of the (scaled) range rate, so
  an **approaching satellite gives a positive Doppler** and a receding satellite
  a negative one.

  ## Result map

      %{
        geometric_range_m: float(),    # metres
        range_rate_m_s:    float(),    # d(range)/dt; negative = approaching
        doppler_hz:        float(),    # = -range_rate * carrier / c; + = approaching
        sat_clock_s:       float() | nil,  # SP3 clock offset at transmit time
        elevation_deg:     float(),    # topocentric elevation
        azimuth_deg:       float(),    # topocentric azimuth, [0, 360)
        transmit_time:     NaiveDateTime.t(),  # t_tx
        los_unit:          {float(), float(), float()},  # receiver -> satellite, ECEF unit
        sat_pos_ecef_m:    {float(), float(), float()},  # Sagnac-rotated sat position
        sat_velocity_m_s:  {float(), float(), float()}   # Sagnac-rotated sat velocity
      }
  """

  alias Sidereon.GNSS.{Broadcast, SP3, Time}
  alias Sidereon.GNSS.Core.Constants
  alias Sidereon.GNSS.Core.Types
  alias Sidereon.NIF

  @type vec3 :: {float(), float(), float()}

  @type observables :: %{
          geometric_range_m: float(),
          range_rate_m_s: float(),
          doppler_hz: float(),
          sat_clock_s: float() | nil,
          elevation_deg: float(),
          azimuth_deg: float(),
          transmit_time: NaiveDateTime.t(),
          los_unit: vec3(),
          sat_pos_ecef_m: vec3(),
          sat_velocity_m_s: vec3()
        }

  @doc """
  Predict the observables for `satellite_id` seen from `receiver_ecef` at `epoch`.

  `receiver_ecef` is the static receiver position in ITRF/ECEF metres, given as
  `{x_m, y_m, z_m}` or `%{x_m: _, y_m: _, z_m: _}`. `epoch` is the receive epoch,
  a `NaiveDateTime` (interpreted in the ephemeris source's own time scale).

  ## Options

    * `:carrier_hz` - carrier frequency for the Doppler, default the L1 carrier
      `1575.42 MHz`.
    * `:light_time` - apply the light-time / transmit-time correction, default
      `true`. When `false`, the satellite is evaluated at `epoch`.
    * `:sagnac` - apply the Sagnac / Earth-rotation correction, default `true`.
    * `:extrapolate` - for SP3 sources, allow evaluation outside the parsed
      product coverage. Default `false`.

  Returns `{:ok, observables}`, `{:error, :invalid_receiver}` for a malformed
  receiver position, or propagates any ephemeris position error (e.g. an unknown
  satellite or a malformed satellite token) verbatim as
  `{:error, reason}`. Never raises.
  """
  @spec predict(SP3.t() | Broadcast.t(), String.t(), vec3() | map(), NaiveDateTime.t(), keyword()) ::
          {:ok, observables()} | {:error, term()}
  def predict(source, satellite_id, receiver_ecef, epoch, opts \\ [])

  def predict(%SP3{} = source, satellite_id, receiver_ecef, %NaiveDateTime{} = epoch, opts)
      when is_binary(satellite_id) do
    do_predict(source, satellite_id, receiver_ecef, epoch, opts)
  end

  def predict(%Broadcast{} = source, satellite_id, receiver_ecef, %NaiveDateTime{} = epoch, opts)
      when is_binary(satellite_id) do
    do_predict(source, satellite_id, receiver_ecef, epoch, opts)
  end

  defp do_predict(source, satellite_id, receiver_ecef, epoch, opts) do
    carrier_hz = Keyword.get(opts, :carrier_hz, Constants.gps_l1_hz())
    light_time? = Keyword.get(opts, :light_time, true)
    sagnac? = Keyword.get(opts, :sagnac, true)

    with {:ok, receiver} <- Types.normalize_ecef(receiver_ecef),
         {:ok, system_letter, prn} <- Types.parse_sat_id(satellite_id),
         :ok <- validate_source_coverage(source, epoch, opts),
         {:ok, result} <-
           core_predict(
             source,
             system_letter,
             prn,
             receiver,
             epoch,
             carrier_hz,
             light_time?,
             sagnac?
           ) do
      {:ok, to_observables_map(result, epoch)}
    end
  end

  @doc """
  Predict observables for every satellite in the product, seen from `receiver_ecef`.

  Returns a map `satellite_id => {:ok, observables} | {:error, reason}`, so one
  satellite failing (e.g. no estimate at this epoch) does not sink the batch.
  Options are the same as `predict/5`.
  """
  @spec predict_all(SP3.t(), vec3() | map(), NaiveDateTime.t(), keyword()) ::
          %{optional(String.t()) => {:ok, observables()} | {:error, term()}}
  def predict_all(%SP3{} = sp3, receiver_ecef, %NaiveDateTime{} = epoch, opts \\ []) do
    sp3
    |> SP3.satellite_ids()
    |> Map.new(fn sat_id -> {sat_id, predict(sp3, sat_id, receiver_ecef, epoch, opts)} end)
  end

  defp core_predict(
         %SP3{handle: handle},
         system_letter,
         prn,
         receiver,
         epoch,
         carrier_hz,
         light_time?,
         sagnac?
       ) do
    {jd_whole, jd_fraction} = Time.epoch_to_split_jd(epoch)

    case NIF.sp3_observables(
           handle,
           system_letter,
           prn,
           jd_whole,
           jd_fraction,
           receiver,
           carrier_hz,
           light_time?,
           sagnac?
         ) do
      {:ok, result} -> {:ok, result}
      {:error, _} = err -> err
      other -> {:error, other}
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  defp core_predict(
         %Broadcast{handle: handle},
         system_letter,
         prn,
         receiver,
         epoch,
         carrier_hz,
         light_time?,
         sagnac?
       ) do
    with {:ok, t_j2000_s} <- Time.epoch_to_j2000_seconds_fractional(epoch) do
      case NIF.broadcast_observables(
             handle,
             system_letter,
             prn,
             t_j2000_s,
             receiver,
             carrier_hz,
             light_time?,
             sagnac?
           ) do
        {:ok, result} -> {:ok, result}
        {:error, _} = err -> err
        other -> {:error, other}
      end
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  defp to_observables_map(
         {[
            range,
            range_rate,
            doppler_hz,
            sat_clock_s,
            elevation_deg,
            azimuth_deg,
            transmit_offset_us,
            _transmit_time_j2000_s
          ], [los, sat_pos, sat_velocity]},
         epoch
       ) do
    transmit_time =
      if transmit_offset_us == 0 do
        epoch
      else
        NaiveDateTime.add(epoch, -transmit_offset_us, :microsecond)
      end

    %{
      geometric_range_m: range,
      range_rate_m_s: range_rate,
      doppler_hz: doppler_hz,
      sat_clock_s: sat_clock_s,
      elevation_deg: elevation_deg,
      azimuth_deg: azimuth_deg,
      transmit_time: transmit_time,
      los_unit: los,
      sat_pos_ecef_m: sat_pos,
      sat_velocity_m_s: sat_velocity
    }
  end

  defp validate_source_coverage(%SP3{} = sp3, epoch, opts) do
    if extrapolate?(opts) or SP3.covers_epoch?(sp3, epoch) do
      :ok
    else
      {:error, :outside_coverage}
    end
  end

  defp validate_source_coverage(_source, _epoch, _opts), do: :ok

  defp extrapolate?(opts) when is_list(opts), do: Keyword.get(opts, :extrapolate, false) == true
  defp extrapolate?(_opts), do: false
end
