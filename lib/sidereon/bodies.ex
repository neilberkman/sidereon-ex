defmodule Sidereon.Bodies do
  @moduledoc """
  Ground-observer Sun and Moon geometry.

  From a ground station and a UTC instant, answer the "observe the sky from a
  site" questions: the topocentric azimuth/elevation/range of the Sun or Moon,
  the Moon's illuminated fraction, and the Moon's rise/set and meridian-transit
  events over a window. The azimuth/elevation convention matches the satellite
  look-angle path; the Moon vector is geocentric, so the station-to-target
  reduction applies the diurnal parallax that matters for the nearby Moon.

  Precision follows the underlying analytic Sun/Moon series (sub-degree
  positions); this is a planning/visualization lens, not an almanac-grade
  reduction. The ephemeris, topocentric reduction, phase-angle geometry, and
  event refinement all live in the `sidereon-core` Rust core.

  A `station` is `{latitude_deg, longitude_deg, altitude_km}` or a map with
  `:latitude_deg`, `:longitude_deg`, `:altitude_km`. A time is a `DateTime`, a
  `NaiveDateTime` (interpreted as UTC), or a `{{y, m, d}, {h, min, s, us}}`
  tuple.
  """

  alias Sidereon.NIF

  @type station ::
          {number(), number(), number()}
          | %{latitude_deg: number(), longitude_deg: number(), altitude_km: number()}

  @type time :: DateTime.t() | NaiveDateTime.t() | {tuple(), tuple()}

  @typedoc "Topocentric look angle of a body from a site."
  @type az_el :: %{azimuth_deg: float(), elevation_deg: float(), range_km: float()}

  @typedoc "A Moon rise/set or meridian-transit event."
  @type event :: %{time: DateTime.t(), kind: atom(), elevation_deg: float()}

  @doc """
  Topocentric azimuth/elevation/range of the Sun from a site.
  """
  @spec sun_az_el(station(), time()) :: {:ok, az_el()} | {:error, atom()}
  def sun_az_el(station, time) do
    {lat, lon, alt} = station_parts(station)
    NIF.bodies_sun_az_el(lat, lon, alt, to_nif_datetime(time)) |> decode_az_el()
  end

  @doc """
  Topocentric azimuth/elevation/range of the Moon from a site.
  """
  @spec moon_az_el(station(), time()) :: {:ok, az_el()} | {:error, atom()}
  def moon_az_el(station, time) do
    {lat, lon, alt} = station_parts(station)
    NIF.bodies_moon_az_el(lat, lon, alt, to_nif_datetime(time)) |> decode_az_el()
  end

  @doc """
  Illuminated fraction of the Moon as seen from a site.

  Returns `{:ok, %{illuminated_fraction: k, phase_angle_deg: a}}` with `k` in
  `[0, 1]` (0 = new, 1 = full) and the Sun-Moon-observer phase angle in degrees.
  """
  @spec moon_illumination(station(), time()) ::
          {:ok, %{illuminated_fraction: float(), phase_angle_deg: float()}} | {:error, atom()}
  def moon_illumination(station, time) do
    {lat, lon, alt} = station_parts(station)

    case NIF.bodies_moon_illumination(lat, lon, alt, to_nif_datetime(time)) do
      {:ok, {fraction, phase_angle_deg}} ->
        {:ok, %{illuminated_fraction: fraction, phase_angle_deg: phase_angle_deg}}

      {:error, _reason} = err ->
        err
    end
  end

  @doc """
  Topocentric geometric Moon (disk-center) elevation at a site, degrees.
  """
  @spec moon_elevation_deg(station(), time()) :: {:ok, float()} | {:error, atom()}
  def moon_elevation_deg(station, time) do
    {lat, lon, alt} = station_parts(station)
    NIF.bodies_moon_elevation_deg(lat, lon, alt, to_nif_datetime(time))
  end

  @doc """
  Moon elevation-threshold crossings (moonrise / moonset) over a UTC window.

  ## Options

    * `:elevation_threshold_deg` - crossing threshold (default `-0.833`, the
      standard upper-limb-on-the-horizon convention).
    * `:step_seconds` - event-finder scan step (default `600.0`).
    * `:time_tolerance_seconds` - crossing-time refinement tolerance (default
      `1.0`).

  Returns `{:ok, [%{time: DateTime, kind: :rising | :setting, elevation_deg:}]}`.
  """
  @spec find_moon_elevation_crossings(station(), time(), time(), keyword()) ::
          {:ok, [event()]} | {:error, atom()}
  def find_moon_elevation_crossings(station, start_time, end_time, opts \\ []) do
    {lat, lon, alt} = station_parts(station)

    NIF.bodies_find_moon_elevation_crossings(
      lat,
      lon,
      alt,
      to_nif_datetime(start_time),
      to_nif_datetime(end_time),
      Keyword.get(opts, :elevation_threshold_deg, -0.833) / 1.0,
      Keyword.get(opts, :step_seconds, 600.0) / 1.0,
      Keyword.get(opts, :time_tolerance_seconds, 1.0) / 1.0
    )
    |> decode_events()
  end

  @doc """
  Moon meridian transits (upper and lower culminations) over a UTC window.

  ## Options

    * `:step_seconds` - event-finder scan step (default `600.0`).
    * `:time_tolerance_seconds` - crossing-time refinement tolerance (default
      `1.0`).

  Returns `{:ok, [%{time: DateTime, kind: :upper | :lower, elevation_deg:}]}`.
  """
  @spec find_moon_transits(station(), time(), time(), keyword()) ::
          {:ok, [event()]} | {:error, atom()}
  def find_moon_transits(station, start_time, end_time, opts \\ []) do
    {lat, lon, alt} = station_parts(station)

    NIF.bodies_find_moon_transits(
      lat,
      lon,
      alt,
      to_nif_datetime(start_time),
      to_nif_datetime(end_time),
      Keyword.get(opts, :step_seconds, 600.0) / 1.0,
      Keyword.get(opts, :time_tolerance_seconds, 1.0) / 1.0
    )
    |> decode_events()
  end

  # --- marshalling ----------------------------------------------------------

  defp station_parts({lat, lon, alt}) when is_number(lat) and is_number(lon) and is_number(alt),
    do: {lat / 1.0, lon / 1.0, alt / 1.0}

  defp station_parts(%{latitude_deg: lat, longitude_deg: lon, altitude_km: alt}), do: {lat / 1.0, lon / 1.0, alt / 1.0}

  defp to_nif_datetime(%DateTime{} = dt),
    do: {{dt.year, dt.month, dt.day}, {dt.hour, dt.minute, dt.second, elem(dt.microsecond, 0)}}

  defp to_nif_datetime(%NaiveDateTime{} = dt),
    do: {{dt.year, dt.month, dt.day}, {dt.hour, dt.minute, dt.second, elem(dt.microsecond, 0)}}

  defp to_nif_datetime({{_y, _m, _d}, {_h, _min, _s, _us}} = tuple), do: tuple

  defp decode_az_el({:ok, {azimuth_deg, elevation_deg, range_km}}),
    do: {:ok, %{azimuth_deg: azimuth_deg, elevation_deg: elevation_deg, range_km: range_km}}

  defp decode_az_el({:error, _reason} = err), do: err

  defp decode_events({:ok, rows}) do
    {:ok,
     Enum.map(rows, fn {unix_us, kind, elevation_deg} ->
       %{time: DateTime.from_unix!(unix_us, :microsecond), kind: kind, elevation_deg: elevation_deg}
     end)}
  end

  defp decode_events({:error, _reason} = err), do: err
end
