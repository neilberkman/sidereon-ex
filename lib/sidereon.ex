defmodule Sidereon do
  @moduledoc """
  Satellite toolkit for Elixir. SGP4 orbit propagation, coordinate
  transformations, and ground station pass prediction.
  """

  @type vec3 :: {number(), number(), number()}
  @type ground_station :: %{
          latitude: number(),
          longitude: number(),
          altitude_m: number()
        }
  @type gcrs_state :: %{position: vec3(), velocity: vec3()}

  @doc """
  Parse a Two-Line Element set.

  Returns `{:ok, %Sidereon.Elements{}}` or `{:error, reason}`.

  ## Examples

      iex> {:ok, el} = Sidereon.parse_tle(
      ...>   "1 25544U 98067A   18184.80969102  .00001614  00000-0  31745-4 0  9993",
      ...>   "2 25544  51.6414 295.8524 0003435 262.6267 204.2868 15.54005638121106"
      ...> )
      iex> el.catalog_number
      "25544"

  """
  @spec parse_tle(String.t(), String.t()) ::
          {:ok, Sidereon.Elements.t()} | {:error, String.t()}
  defdelegate parse_tle(line1, line2), to: Sidereon.Format.TLE, as: :parse

  @doc """
  Propagate orbital elements to a specific datetime, returning TEME position and velocity.

  Returns `{:ok, %Sidereon.TemeState{}}` with position in km and velocity in km/s,
  or `{:error, reason}`.

  ## Examples

      iex> {:ok, el} = Sidereon.parse_tle(
      ...>   "1 25544U 98067A   18184.80969102  .00001614  00000-0  31745-4 0  9993",
      ...>   "2 25544  51.6414 295.8524 0003435 262.6267 204.2868 15.54005638121106"
      ...> )
      iex> {:ok, teme} = Sidereon.propagate(el, ~U[2018-07-04 00:00:00Z])
      iex> {x, _y, _z} = teme.position
      iex> x > 3000 and x < 4000
      true

  """
  @spec propagate(Sidereon.Elements.t(), DateTime.t()) ::
          {:ok, Sidereon.TemeState.t()} | {:error, Sidereon.SGP4.propagation_error()}
  defdelegate propagate(tle, datetime), to: Sidereon.SGP4

  @doc """
  Predict visible passes of a satellite over a ground station.

  See `Sidereon.Passes.predict/5` for full documentation.
  """
  @spec predict_passes(
          Sidereon.Elements.t(),
          Sidereon.Passes.ground_station(),
          DateTime.t(),
          DateTime.t(),
          keyword()
        ) ::
          {:ok, [Sidereon.Pass.t()]} | {:error, Sidereon.Passes.predict_error()}
  defdelegate predict_passes(tle, ground_station, start_time, end_time, opts \\ []),
    to: Sidereon.Passes,
    as: :predict

  @doc """
  Compute the angle between satellite nadir and the Sun direction.

  See `Sidereon.Angles.sun_angle/2` for details.
  """
  @spec sun_angle(vec3(), vec3()) :: float()
  defdelegate sun_angle(satellite_gcrs_position, sun_position_from_earth),
    to: Sidereon.Angles

  @doc """
  Compute the angle between satellite nadir and the Moon direction.

  See `Sidereon.Angles.moon_angle/2` for details.
  """
  @spec moon_angle(vec3(), vec3()) :: float()
  defdelegate moon_angle(satellite_gcrs_position, moon_position_from_earth),
    to: Sidereon.Angles

  @doc """
  Convert a TEME state vector to GCRS (Geocentric Celestial Reference System).

  Set `skyfield_compat: true` to reproduce the committed Skyfield oracle
  vectors used by the validation suite. The default is sidereon's native
  path.

  ## Example

      gcrs = Sidereon.teme_to_gcrs(teme, datetime)
      gcrs = Sidereon.teme_to_gcrs(teme, datetime, skyfield_compat: true)
  """
  @spec teme_to_gcrs(Sidereon.TemeState.t() | gcrs_state(), DateTime.t() | tuple(), keyword()) ::
          gcrs_state()
  def teme_to_gcrs(teme_state, datetime, opts \\ []) do
    Sidereon.Coordinates.teme_to_gcrs(teme_state, datetime, opts)
  end

  @doc """
  Compute geodetic coordinates (lat/lon/alt) for a satellite at a given time.

  Propagates the TLE, transforms TEME -> GCRS -> ITRS, and converts to WGS84.

  Returns `{:ok, %{latitude: deg, longitude: deg, altitude_km: km}}`.

  ## Example

      {:ok, tle} = Sidereon.parse_tle(line1, line2)
      {:ok, geo} = Sidereon.geodetic(tle, datetime)
      geo.latitude  # => 51.23
  """
  @spec geodetic(Sidereon.Elements.t(), DateTime.t()) ::
          {:ok, Sidereon.Geodetic.t()} | {:error, term()}
  def geodetic(%Sidereon.Elements{} = tle, %DateTime{} = datetime) do
    with {:ok, teme} <- Sidereon.SGP4.propagate(tle, datetime) do
      gcrs = Sidereon.Coordinates.teme_to_gcrs(teme, datetime)
      itrs = Sidereon.Coordinates.gcrs_to_itrs(gcrs, datetime)
      {:ok, Sidereon.Coordinates.to_geodetic(itrs)}
    end
  end

  @doc """
  Check whether a satellite is in Earth's shadow (eclipse) at a given time.

  Propagates the TLE, transforms to GCRS, fetches the Sun position from the
  ephemeris, and returns the eclipse status.

  Returns `{:ok, :sunlit | :penumbra | :umbra}` or `{:error, reason}`.

  ## Example

      {:ok, eph} = Sidereon.Ephemeris.load("de421.bsp")
      {:ok, status} = Sidereon.eclipse(tle, datetime, eph)
  """
  @spec eclipse(Sidereon.Elements.t(), DateTime.t(), Sidereon.Ephemeris.t()) ::
          {:ok, :sunlit | :penumbra | :umbra} | {:error, term()}
  defdelegate eclipse(tle, datetime, ephemeris), to: Sidereon.Eclipse, as: :check

  @doc """
  Compute the look angle (azimuth/elevation/range) from a ground station
  to a satellite at a given time.

  The station is a map: `%{latitude: deg, longitude: deg, altitude_m: meters}`.

  Returns `{:ok, %{azimuth: deg, elevation: deg, range_km: km}}`.

  ## Example

      station = %{latitude: 40.0, longitude: -74.0, altitude_m: 0.0}
      {:ok, look} = Sidereon.look_angle(tle, datetime, station)
      look.elevation  # => 25.7
  """
  @spec look_angle(Sidereon.Elements.t(), DateTime.t(), ground_station()) ::
          {:ok, Sidereon.LookAngle.t()} | {:error, term()}
  def look_angle(%Sidereon.Elements{} = tle, %DateTime{} = datetime, station) do
    datetime_tuple =
      {{datetime.year, datetime.month, datetime.day},
       {datetime.hour, datetime.minute, datetime.second, elem(datetime.microsecond, 0)}}

    with {:ok, elements_map} <- Sidereon.SGP4.to_nif_elements_map(tle),
         {:ok, {azimuth, elevation, range_km}} <-
           Sidereon.NIF.tle_look_angle(
             elements_map,
             station.latitude,
             station.longitude,
             station.altitude_m,
             datetime_tuple
           ) do
      {:ok, %Sidereon.LookAngle{azimuth: azimuth, elevation: elevation, range_km: range_km}}
    end
  end

  @doc """
  Compute Doppler shift for a satellite-ground link.

  Propagates the TLE, transforms to GCRS, and computes the range rate and
  Doppler shift at the given carrier frequency.

  The station is a map: `%{latitude: deg, longitude: deg, altitude_m: meters}`.

  Returns `{:ok, %{range_rate_km_s: float, doppler_hz: float, doppler_ratio: float}}`.

  ## Example

      station = %{latitude: 40.0, longitude: -74.0, altitude_m: 0.0}
      {:ok, d} = Sidereon.doppler(tle, datetime, station, 437.0e6)
      d.doppler_hz  # => ~10_000.0
  """
  @spec doppler(Sidereon.Elements.t(), DateTime.t(), ground_station(), number()) ::
          {:ok,
           %{
             range_rate_km_s: float(),
             doppler_hz: float(),
             doppler_ratio: float()
           }}
          | {:error, term()}
  def doppler(%Sidereon.Elements{} = tle, %DateTime{} = datetime, station, frequency_hz) do
    with {:ok, teme} <- Sidereon.SGP4.propagate(tle, datetime) do
      gcrs = Sidereon.Coordinates.teme_to_gcrs(teme, datetime)
      {:ok, Sidereon.Doppler.shift(gcrs, datetime, station, frequency_hz)}
    end
  end
end
