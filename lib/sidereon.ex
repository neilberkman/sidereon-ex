defmodule Sidereon do
  @moduledoc """
  Satellite toolkit for Elixir. SGP4 orbit propagation, coordinate
  transformations, and ground station pass prediction.
  """

  alias Sidereon.Format.TLE
  alias Sidereon.GNSS.Constellation, as: GNSSConstellation
  alias Sidereon.GNSS.PrecisePositioning
  alias Sidereon.GNSS.RINEX.Clock
  alias Sidereon.GNSS.RTCM
  alias Sidereon.GNSS.RTK
  alias Sidereon.NIF

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
  defdelegate parse_tle(line1, line2), to: TLE, as: :parse

  @doc """
  Parse a multi-record TLE file (CelesTrak / Space-Track style) into named satellites.

  Handles bare two-line sets, three-line name+line1+line2 sets, and CelesTrak
  `0 NAME` markers, tolerating blank lines and CRLF. Returns
  `{:ok, %{satellites: [%{name: name, tle: %Sidereon.Elements{}}], skipped: n}}`,
  where each `tle` is ready for `propagate/2`, `look_angle/3`, etc., and `skipped`
  counts records that failed SGP4 initialization.

  ## Examples

      iex> text = \"\"\"
      ...> ISS (ZARYA)
      ...> 1 25544U 98067A   18184.80969102  .00001614  00000-0  31745-4 0  9993
      ...> 2 25544  51.6414 295.8524 0003435 262.6267 204.2868 15.54005638121106
      ...> \"\"\"
      iex> {:ok, %{satellites: [sat], skipped: 0}} = Sidereon.parse_tle_file(text)
      iex> sat.name
      "ISS (ZARYA)"

  """
  @spec parse_tle_file(String.t()) ::
          {:ok,
           %{
             satellites: [%{name: String.t(), tle: Sidereon.Elements.t()}],
             skipped: non_neg_integer()
           }}
  defdelegate parse_tle_file(text), to: TLE, as: :parse_file

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

  defdelegate find_tca_candidates(
                primary_line1,
                primary_line2,
                secondary_line1,
                secondary_line2,
                window_start_jd,
                window_end_jd,
                opts \\ []
              ),
              to: Sidereon.Conjunction

  defdelegate find_tca_conjunctions(
                primary_line1,
                primary_line2,
                secondary_line1,
                secondary_line2,
                window_start_jd,
                window_end_jd,
                hard_body_radius_km,
                opts \\ []
              ),
              to: Sidereon.Conjunction

  defdelegate screen_tca_candidates(
                primary_line1,
                primary_line2,
                secondaries,
                window_start_jd,
                window_end_jd,
                miss_distance_threshold_km,
                opts \\ []
              ),
              to: Sidereon.Conjunction

  defdelegate screen_tca_conjunctions(
                primary_line1,
                primary_line2,
                secondaries,
                window_start_jd,
                window_end_jd,
                miss_distance_threshold_km,
                hard_body_radius_km,
                opts \\ []
              ),
              to: Sidereon.Conjunction

  defdelegate solve_rtk_float(config), to: RTK
  defdelegate solve_rtk_fixed(config), to: RTK

  defdelegate solve_ppp_float(sp3, epochs, initial_state, opts \\ []),
    to: PrecisePositioning

  defdelegate solve_ppp_fixed(sp3, epochs, float_solution, opts \\ []),
    to: PrecisePositioning

  defdelegate lambda_ils_search(float_cycles, covariance, ratio_threshold \\ 3.0),
    to: Sidereon.ILS

  defdelegate bounded_ils_search(
                float_cycles,
                covariance,
                radius \\ 1,
                candidate_limit \\ 200_000,
                ratio_threshold \\ 3.0
              ),
              to: Sidereon.ILS

  defdelegate decode_rtcm(data), to: RTCM, as: :decode
  defdelegate decode_rtcm_message(body), to: RTCM, as: :decode_message
  defdelegate decode_rtcm_frame(frame), to: RTCM, as: :decode_frame
  defdelegate encode_rtcm(message), to: RTCM, as: :encode
  defdelegate encode_rtcm_frame(message_or_body), to: RTCM, as: :encode_frame
  defdelegate rtcm_message_number(body), to: RTCM, as: :message_number

  defdelegate parse_rinex_clock(text), to: Clock, as: :parse
  defdelegate load_rinex_clock(path), to: Clock, as: :load
  defdelegate parse_rinex_clock_lossy(text), to: Clock, as: :parse_lossy
  defdelegate load_rinex_clock_lossy(path), to: Clock, as: :load_lossy
  defdelegate rinex_clock_to_string(clock), to: Clock, as: :to_rinex_string
  defdelegate write_rinex_clock(clock, path), to: Clock, as: :write
  defdelegate from_celestrak_json(json, system \\ :gps), to: GNSSConstellation
  defdelegate from_celestrak_json_lenient(json, system \\ :gps), to: GNSSConstellation
  defdelegate from_celestrak_omm_lenient(json, system \\ :gps), to: GNSSConstellation

  @doc """
  Compute Sun and Moon ECI vectors for UTC Unix microsecond epochs.
  """
  @spec sun_moon_eci([integer()]) ::
          {:ok, %{sun: [vec3()], moon: [vec3()]}} | {:error, term()}
  def sun_moon_eci(epochs_unix_us) when is_list(epochs_unix_us) do
    case NIF.sun_moon_eci_batch(epochs_unix_us) do
      {sun, moon} -> {:ok, %{sun: sun, moon: moon}}
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Compute Sun and Moon ECEF vectors for UTC Unix microsecond epochs.
  """
  @spec sun_moon_ecef([integer()]) ::
          {:ok, %{sun: [vec3()], moon: [vec3()]}} | {:error, term()}
  def sun_moon_ecef(epochs_unix_us) when is_list(epochs_unix_us) do
    case NIF.sun_moon_ecef_batch(epochs_unix_us) do
      {sun, moon} -> {:ok, %{sun: sun, moon: moon}}
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Compute solid-earth tide station displacement in metres, ECEF.
  """
  @spec solid_earth_tide(vec3(), integer(), integer(), integer(), number(), vec3(), vec3()) ::
          {:ok, vec3()} | {:error, term()}
  def solid_earth_tide(station_ecef_m, year, month, day, fhr, sun_ecef_m, moon_ecef_m) do
    with {:ok, station} <- public_vec3(station_ecef_m, :station_ecef_m),
         {:ok, sun} <- public_vec3(sun_ecef_m, :sun_ecef_m),
         {:ok, moon} <- public_vec3(moon_ecef_m, :moon_ecef_m) do
      {x, y, z} = station

      {:ok, NIF.solid_earth_tide(x, y, z, year, month, day, fhr / 1.0, sun, moon)}
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Compute solid-earth pole tide station displacement in metres, ECEF.
  """
  @spec solid_earth_pole_tide(vec3(), integer(), integer(), integer(), number(), number(), number()) ::
          {:ok, vec3()} | {:error, term()}
  def solid_earth_pole_tide(station_ecef_m, year, month, day, fhr, xp_arcsec, yp_arcsec) do
    with {:ok, {x, y, z}} <- public_vec3(station_ecef_m, :station_ecef_m) do
      {:ok,
       NIF.solid_earth_pole_tide(
         x,
         y,
         z,
         year,
         month,
         day,
         fhr / 1.0,
         xp_arcsec / 1.0,
         yp_arcsec / 1.0
       )}
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Compute ocean tide loading station displacement in metres, ECEF.
  """
  @spec ocean_tide_loading(vec3(), integer(), integer(), integer(), number(), [[number()]], [[number()]]) ::
          {:ok, vec3()} | {:error, term()}
  def ocean_tide_loading(station_ecef_m, year, month, day, fhr, amplitude_m, phase_deg) do
    with {:ok, {x, y, z}} <- public_vec3(station_ecef_m, :station_ecef_m),
         {:ok, amplitude_m} <- public_matrix(amplitude_m, :amplitude_m),
         {:ok, phase_deg} <- public_matrix(phase_deg, :phase_deg) do
      {:ok,
       NIF.ocean_tide_loading(
         x,
         y,
         z,
         year,
         month,
         day,
         fhr / 1.0,
         amplitude_m,
         phase_deg
       )}
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Fixed inter-system time offset `to - from`, in seconds, for the atomic scales.

  See `Sidereon.GNSS.Time.timescale_offset/2` for the scale names and the
  epoch-required/unsupported error cases.
  """
  defdelegate timescale_offset(from, to), to: Sidereon.GNSS.Time

  @doc """
  Leap-aware inter-system time offset `to - from`, in seconds, at `utc_jd`.

  See `Sidereon.GNSS.Time.timescale_offset_at/3`.
  """
  defdelegate timescale_offset_at(from, to, utc_jd), to: Sidereon.GNSS.Time

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
  Compute the ground track (sub-satellite points) for a satellite over a list
  of times.

  For each datetime the satellite is propagated and reduced through
  TEME -> GCRS -> ITRS -> WGS84 geodetic, yielding the point on the ellipsoid
  directly beneath the satellite. This is the batch companion to
  `Sidereon.geodetic/2`.

  ## Options

    * `:opsmode` - SGP4 operation mode, `:afspc` (default) or `:improved`. The
      satellite is built with this opsmode, so the track is consistent with
      `Sidereon.geodetic/2` and `Sidereon.predict_passes/5` under the same
      opsmode.

  Returns `{:ok, [%Sidereon.Geodetic{}]}` (one per datetime, in order) or
  `{:error, reason}`.

  ## Example

      now = DateTime.utc_now()
      times = for s <- 0..600//60, do: DateTime.add(now, s, :second)
      {:ok, track} = Sidereon.ground_track(tle, times)
      hd(track).latitude  # => 12.34
  """
  @spec ground_track(Sidereon.Elements.t(), [DateTime.t()], keyword()) ::
          {:ok, [Sidereon.Geodetic.t()]} | {:error, term()}
  def ground_track(%Sidereon.Elements{} = tle, datetimes, opts \\ []) when is_list(datetimes) do
    with {:ok, opsmode} <- validate_opsmode(Keyword.get(opts, :opsmode, :afspc)),
         {:ok, datetimes} <- validate_datetimes(datetimes),
         {:ok, elements_map} <- Sidereon.SGP4.to_nif_elements_map(tle),
         {:ok, points} <- ground_track_nif(elements_map, datetimes, opsmode) do
      {:ok,
       Enum.map(points, fn {lat, lon, alt} ->
         %Sidereon.Geodetic{latitude: lat, longitude: lon, altitude_km: alt}
       end)}
    end
  end

  # Validate every entry up front so a non-`DateTime` element returns a tidy
  # `{:error, {:invalid_field, :datetimes, value}}` instead of raising a
  # `FunctionClauseError` from `to_nif_datetime/1` before the NIF rescue runs.
  defp validate_datetimes(datetimes) do
    Enum.reduce_while(datetimes, {:ok, datetimes}, fn
      %DateTime{}, acc -> {:cont, acc}
      value, _acc -> {:halt, {:error, {:invalid_field, :datetimes, value}}}
    end)
  end

  defp ground_track_nif(elements_map, datetimes, opsmode) do
    tuples = Enum.map(datetimes, &to_nif_datetime/1)
    Sidereon.NIF.ground_track(elements_map, tuples, opsmode)
  rescue
    e in ErlangError -> {:error, {:nif_error, Exception.message(e)}}
  end

  defp to_nif_datetime(%DateTime{} = dt) do
    {{dt.year, dt.month, dt.day}, {dt.hour, dt.minute, dt.second, elem(dt.microsecond, 0)}}
  end

  defp public_vec3({x, y, z}, _name) when is_number(x) and is_number(y) and is_number(z),
    do: {:ok, {x / 1.0, y / 1.0, z / 1.0}}

  defp public_vec3([x, y, z], _name) when is_number(x) and is_number(y) and is_number(z),
    do: {:ok, {x / 1.0, y / 1.0, z / 1.0}}

  defp public_vec3(_value, name), do: {:error, {:invalid_vector, name}}

  defp public_matrix(rows, name) when is_list(rows) do
    if Enum.all?(rows, fn row -> is_list(row) and Enum.all?(row, &is_number/1) end) do
      {:ok, Enum.map(rows, fn row -> Enum.map(row, &(&1 / 1.0)) end)}
    else
      {:error, {:invalid_matrix, name}}
    end
  end

  defp public_matrix(_rows, name), do: {:error, {:invalid_matrix, name}}

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

  ## Options

    * `:opsmode` - SGP4 operation mode, `:afspc` (default) or `:improved`. The
      satellite is built with this opsmode, so the look angle is consistent with
      `Sidereon.predict_passes/5` run under the same opsmode.

  ## Example

      station = %{latitude: 40.0, longitude: -74.0, altitude_m: 0.0}
      {:ok, look} = Sidereon.look_angle(tle, datetime, station)
      look.elevation  # => 25.7
  """
  @spec look_angle(Sidereon.Elements.t(), DateTime.t(), ground_station(), keyword()) ::
          {:ok, Sidereon.LookAngle.t()} | {:error, term()}
  def look_angle(%Sidereon.Elements{} = tle, %DateTime{} = datetime, station, opts \\ []) do
    datetime_tuple =
      {{datetime.year, datetime.month, datetime.day},
       {datetime.hour, datetime.minute, datetime.second, elem(datetime.microsecond, 0)}}

    with {:ok, opsmode} <- validate_opsmode(Keyword.get(opts, :opsmode, :afspc)),
         {:ok, elements_map} <- Sidereon.SGP4.to_nif_elements_map(tle),
         {:ok, {azimuth, elevation, range_km}} <-
           Sidereon.NIF.tle_look_angle(
             elements_map,
             station.latitude,
             station.longitude,
             station.altitude_m,
             datetime_tuple,
             opsmode
           ) do
      {:ok, %Sidereon.LookAngle{azimuth: azimuth, elevation: elevation, range_km: range_km}}
    end
  end

  defp validate_opsmode(opsmode) when opsmode in [:afspc, :improved], do: {:ok, opsmode}
  defp validate_opsmode(opsmode), do: {:error, {:invalid_option, {:opsmode, opsmode}}}

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
