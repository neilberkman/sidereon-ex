defmodule Sidereon.Coordinates do
  @moduledoc """
  Coordinate frame transformations for satellite state vectors.

  Supports:
  - TEME → GCRS coordinate conversion with committed oracle fixtures
  - GCRS → ITRS (Earth-fixed / ECEF)
  - ITRS → GCRS
  - ITRS → Geodetic (WGS84 lat/lon/alt)
  - Geodetic → ITRS
  - Topocentric (azimuth/elevation/range) from a ground station

  Time-scale handling is intentionally kept behind the public datetime inputs
  in this module. The Rust core and Python binding expose lower-level
  `Instant`, `TimeScale`, leap-second, and UT1 metadata APIs; the Elixir public
  surface does not expose those as standalone modules yet to avoid a partial
  time API.
  """

  @type vec3 :: {number(), number(), number()}
  @type state :: %{position: vec3(), velocity: vec3()}
  @type datetime ::
          DateTime.t() | {{integer(), integer(), integer()}, {integer(), integer(), integer()}}
  @type ground_station :: %{
          latitude: number(),
          longitude: number(),
          altitude_m: number()
        }
  @type geodetic_input ::
          Sidereon.Geodetic.t()
          | %{latitude: number(), longitude: number(), altitude_km: number()}
          | vec3()

  @doc """
  Convert a TEME state vector to GCRS.

  Accepts a map with `:position` and `:velocity` tuples (km and km/s),
  and a datetime (either `DateTime` or `{{y,m,d},{h,m,s}}` tuple).

  ## Options

    * `:skyfield_compat` - when `true`, reproduces the committed Skyfield
      oracle vectors used by the validation suite. Default `false` uses
      sidereon's native path.

  Returns a map with GCRS `:position` and `:velocity`.
  """
  @spec teme_to_gcrs(state(), datetime(), keyword()) :: state()
  def teme_to_gcrs(%{position: {x, y, z}, velocity: {vx, vy, vz}}, datetime, opts \\ []) do
    datetime_tuple = to_nif_datetime(datetime)
    skyfield_compat = Keyword.get(opts, :skyfield_compat, false)

    {{x_gcrs, y_gcrs, z_gcrs}, {vx_gcrs, vy_gcrs, vz_gcrs}} =
      Sidereon.NIF.teme_to_gcrs(x, y, z, vx, vy, vz, datetime_tuple, skyfield_compat)

    %{
      position: {x_gcrs, y_gcrs, z_gcrs},
      velocity: {vx_gcrs, vy_gcrs, vz_gcrs}
    }
  end

  @doc """
  Convert a GCRS position to ITRS (Earth-fixed / ECEF).

  Accepts a map with a `:position` tuple (km) and a datetime.
  Set `skyfield_compat: true` to reproduce the committed Skyfield oracle
  vectors used by the validation suite. The default is sidereon's native path.

  Returns `{x, y, z}` in km.
  """
  @spec gcrs_to_itrs(%{position: vec3()}, datetime(), keyword()) ::
          {float(), float(), float()}
  def gcrs_to_itrs(%{position: {x, y, z}}, datetime, opts \\ []) do
    datetime_tuple = to_nif_datetime(datetime)
    skyfield_compat = Keyword.get(opts, :skyfield_compat, false)
    Sidereon.NIF.gcrs_to_itrs(x, y, z, datetime_tuple, skyfield_compat)
  end

  @doc """
  Convert an ITRS/ECEF position to GCRS.

  Accepts a position tuple `{x, y, z}` in km and a datetime.

  Returns `{x, y, z}` in km.
  """
  @spec itrs_to_gcrs(vec3(), datetime()) :: {float(), float(), float()}
  def itrs_to_gcrs({x, y, z}, datetime) do
    datetime_tuple = to_nif_datetime(datetime)
    Sidereon.NIF.itrs_to_gcrs(x, y, z, datetime_tuple)
  end

  @doc """
  Convert an ITRS/ECEF position to WGS84 geodetic coordinates.

  Accepts a position tuple `{x, y, z}` in km.

  Returns `%{latitude: degrees, longitude: degrees, altitude_km: km}`.
  """
  @spec to_geodetic(vec3()) :: Sidereon.Geodetic.t()
  def to_geodetic({x, y, z}) do
    {lat, lon, alt} = Sidereon.NIF.itrs_to_geodetic(x, y, z)
    %Sidereon.Geodetic{latitude: lat, longitude: lon, altitude_km: alt}
  end

  @doc """
  Convert WGS84 geodetic coordinates to an ITRS/ECEF position.

  Accepts `%Sidereon.Geodetic{}`, a map with `:latitude`, `:longitude`, and
  `:altitude_km`, or a `{latitude, longitude, altitude_km}` tuple. Latitude and
  longitude are degrees; altitude is kilometres.

  Returns `{x, y, z}` in km.
  """
  @spec geodetic_to_itrs(geodetic_input()) :: {float(), float(), float()}
  def geodetic_to_itrs(%Sidereon.Geodetic{
        latitude: latitude,
        longitude: longitude,
        altitude_km: altitude_km
      }) do
    geodetic_to_itrs({latitude, longitude, altitude_km})
  end

  def geodetic_to_itrs(%{latitude: latitude, longitude: longitude, altitude_km: altitude_km}) do
    geodetic_to_itrs({latitude, longitude, altitude_km})
  end

  def geodetic_to_itrs({latitude, longitude, altitude_km}) do
    Sidereon.NIF.geodetic_to_itrs(latitude, longitude, altitude_km)
  end

  @doc """
  Compute topocentric azimuth, elevation, and range from a ground station
  to a satellite given in GCRS.

  ## Parameters

    - `gcrs_state` - map with `:position` tuple (km) in GCRS
    - `datetime` - observation time
    - `station` - `%{latitude: deg, longitude: deg, altitude_m: meters}`

  Returns `%{azimuth: degrees, elevation: degrees, range_km: km}`.
  """
  @spec to_topocentric(%{position: vec3()}, datetime(), ground_station(), keyword()) ::
          Sidereon.LookAngle.t()
  def to_topocentric(%{position: {x, y, z}}, datetime, station, opts \\ []) do
    datetime_tuple = to_nif_datetime(datetime)
    alt_km = station.altitude_m / 1000.0
    skyfield_compat = Keyword.get(opts, :skyfield_compat, false)

    {az, el, range} =
      Sidereon.NIF.gcrs_to_topocentric(
        x,
        y,
        z,
        station.latitude,
        station.longitude,
        alt_km,
        datetime_tuple,
        skyfield_compat
      )

    %Sidereon.LookAngle{azimuth: az, elevation: el, range_km: range}
  end

  defp to_nif_datetime({{y, m, d}, {h, min, s}}) do
    {{y, m, d}, {h, min, s, 0}}
  end

  defp to_nif_datetime(%DateTime{} = dt) do
    {{dt.year, dt.month, dt.day}, {dt.hour, dt.minute, dt.second, elem(dt.microsecond, 0)}}
  end
end
