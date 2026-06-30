defmodule Sidereon.Doppler do
  @moduledoc """
  Doppler shift calculation for satellite-ground links.

  Given a satellite's GCRS state vector (position and velocity), a ground
  station, and a carrier frequency, computes the radial velocity (range rate)
  and the resulting Doppler shift.
  """

  @type vec3 :: {number(), number(), number()}
  @type datetime ::
          DateTime.t() | {{integer(), integer(), integer()}, {integer(), integer(), integer()}}
  @type gcrs_state :: %{position: vec3(), velocity: vec3()}
  @type ground_station :: %{
          latitude: number(),
          longitude: number(),
          altitude_m: number()
        }
  @type result :: %{
          range_rate_km_s: float(),
          doppler_hz: float(),
          doppler_ratio: float()
        }

  @doc """
  Compute Doppler shift for a satellite-ground link.

  ## Parameters

    - `gcrs_state` - map with `:position` `{x, y, z}` (km) and `:velocity`
      `{vx, vy, vz}` (km/s) in GCRS
    - `datetime` - observation time (`DateTime` or `{{y,m,d},{h,m,s}}` tuple)
    - `ground_station` - `%{latitude: deg, longitude: deg, altitude_m: meters}`
    - `frequency_hz` - carrier frequency in Hz

  ## Returns

  A map with:
    - `:range_rate_km_s` - radial velocity in km/s (positive = approaching)
    - `:doppler_hz` - Doppler shift in Hz (positive = frequency increase)
    - `:doppler_ratio` - dimensionless Doppler ratio (-range_rate / c)

  ## Example

      gcrs = Sidereon.teme_to_gcrs(teme, datetime)
      station = %{latitude: 40.0, longitude: -74.0, altitude_m: 0.0}
      result = Sidereon.Doppler.shift(gcrs, datetime, station, 437.0e6)
      result.doppler_hz  # => ~10_000.0 (for typical LEO pass)
  """
  @spec shift(gcrs_state(), datetime(), ground_station(), number()) :: result()
  def shift(%{position: {x, y, z}, velocity: {vx, vy, vz}}, datetime, ground_station, frequency_hz) do
    datetime_tuple = to_nif_datetime(datetime)
    alt_km = ground_station.altitude_m / 1000.0

    {range_rate_km_s, doppler_hz, doppler_ratio} =
      Sidereon.NIF.doppler_shift(
        x,
        y,
        z,
        vx,
        vy,
        vz,
        ground_station.latitude,
        ground_station.longitude,
        alt_km,
        datetime_tuple,
        frequency_hz
      )

    %{
      range_rate_km_s: range_rate_km_s,
      doppler_hz: doppler_hz,
      doppler_ratio: doppler_ratio
    }
  end

  defp to_nif_datetime({{y, m, d}, {h, min, s}}) do
    {{y, m, d}, {h, min, s, 0}}
  end

  defp to_nif_datetime(%DateTime{} = dt) do
    {{dt.year, dt.month, dt.day}, {dt.hour, dt.minute, dt.second, elem(dt.microsecond, 0)}}
  end
end
