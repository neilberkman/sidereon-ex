defmodule Sidereon.Astro.Almanac do
  @moduledoc """
  Almanac event finders.

  Event searches delegate to the core almanac module and return events tagged by
  UTC Unix microsecond epochs.
  """

  alias Sidereon.Ephemeris
  alias Sidereon.NIF

  @type time :: DateTime.t() | NaiveDateTime.t() | {tuple(), tuple()}

  @doc "Find equinoxes and solstices."
  def seasons(window, opts \\ []), do: seasons(:analytic, window, opts)

  def seasons(:analytic, {start_time, end_time}, opts),
    do: call_events(:almanac_seasons_analytic, [datetime(start_time), datetime(end_time)], opts)

  def seasons(%Ephemeris{handle: handle}, {start_time, end_time}, opts),
    do: call_events(:almanac_seasons_spk, [handle, datetime(start_time), datetime(end_time)], opts)

  def seasons!(window, opts \\ []), do: bang(seasons(window, opts))
  def seasons!(source, window, opts), do: bang(seasons(source, window, opts))

  @doc "Find principal Moon phases."
  def moon_phases(window, opts \\ []), do: moon_phases(:analytic, window, opts)

  def moon_phases(:analytic, {start_time, end_time}, opts),
    do: call_events(:almanac_moon_phases_analytic, [datetime(start_time), datetime(end_time)], opts)

  def moon_phases(%Ephemeris{handle: handle}, {start_time, end_time}, opts),
    do: call_events(:almanac_moon_phases_spk, [handle, datetime(start_time), datetime(end_time)], opts)

  def moon_phases!(window, opts \\ []), do: bang(moon_phases(window, opts))
  def moon_phases!(source, window, opts), do: bang(moon_phases(source, window, opts))

  @doc "Find planetary conjunctions or oppositions from an SPK kernel."
  def planetary_events(%Ephemeris{handle: handle}, planet, kind, {start_time, end_time}, opts \\ []) do
    call_events(
      :almanac_planetary_events_spk,
      [handle, name(planet), name(kind), datetime(start_time), datetime(end_time)],
      opts
    )
  end

  def planetary_events!(kernel, planet, kind, window, opts \\ []),
    do: bang(planetary_events(kernel, planet, kind, window, opts))

  @doc "Find upper and lower meridian transits."
  def meridian_transits(body, station, window, opts \\ []),
    do: meridian_transits(:analytic, body, station, window, opts)

  def meridian_transits(:analytic, body, station, {start_time, end_time}, opts) do
    {lat, lon, alt} = station_parts(station)

    call_events(
      :almanac_meridian_transits_analytic,
      [name(body), lat, lon, alt, datetime(start_time), datetime(end_time)],
      opts
    )
  end

  def meridian_transits(%Ephemeris{handle: handle}, body, station, {start_time, end_time}, opts) do
    {lat, lon, alt} = station_parts(station)

    call_events(
      :almanac_meridian_transits_spk,
      [handle, name(body), lat, lon, alt, datetime(start_time), datetime(end_time)],
      opts
    )
  end

  def meridian_transits!(body, station, window, opts \\ []), do: bang(meridian_transits(body, station, window, opts))

  def meridian_transits!(source, body, station, window, opts),
    do: bang(meridian_transits(source, body, station, window, opts))

  @doc "Find lunar and solar eclipses whose maxima fall inside the window."
  def lunar_solar_eclipses(window, opts \\ []), do: lunar_solar_eclipses(:analytic, window, opts)

  def lunar_solar_eclipses(:analytic, {start_time, end_time}, opts),
    do: call_events(:almanac_lunar_solar_eclipses_analytic, [datetime(start_time), datetime(end_time)], opts)

  def lunar_solar_eclipses(%Ephemeris{handle: handle}, {start_time, end_time}, opts),
    do: call_events(:almanac_lunar_solar_eclipses_spk, [handle, datetime(start_time), datetime(end_time)], opts)

  def lunar_solar_eclipses!(window, opts \\ []), do: bang(lunar_solar_eclipses(window, opts))
  def lunar_solar_eclipses!(source, window, opts), do: bang(lunar_solar_eclipses(source, window, opts))

  defp call_events(nif, args, opts) do
    step = Keyword.get(opts, :step_seconds, default_step(nif)) / 1.0
    tol = Keyword.get(opts, :time_tolerance_seconds, 1.0) / 1.0

    case apply(NIF, nif, args ++ [step, tol]) do
      {:ok, rows} -> {:ok, Enum.map(rows, &event_row/1)}
      {:error, _} = err -> err
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  defp default_step(:almanac_moon_phases_analytic), do: 86_400.0
  defp default_step(:almanac_moon_phases_spk), do: 86_400.0
  defp default_step(:almanac_lunar_solar_eclipses_analytic), do: 86_400.0
  defp default_step(:almanac_lunar_solar_eclipses_spk), do: 86_400.0
  defp default_step(:almanac_meridian_transits_analytic), do: 1_800.0
  defp default_step(:almanac_meridian_transits_spk), do: 1_800.0
  defp default_step(_), do: 86_400.0

  defp event_row(%{unix_microseconds: us, kind: kind} = row),
    do: row |> Map.put(:time, DateTime.from_unix!(us, :microsecond)) |> Map.put(:kind, kind_atom(kind))

  defp event_row(%{maximum_unix_microseconds: us, kind: kind} = row),
    do: row |> Map.put(:maximum_time, DateTime.from_unix!(us, :microsecond)) |> Map.put(:kind, kind_atom(kind))

  defp datetime(%DateTime{} = dt),
    do: {{dt.year, dt.month, dt.day}, {dt.hour, dt.minute, dt.second, elem(dt.microsecond, 0)}}

  defp datetime(%NaiveDateTime{} = dt),
    do: {{dt.year, dt.month, dt.day}, {dt.hour, dt.minute, dt.second, elem(dt.microsecond, 0)}}

  defp datetime({{_y, _m, _d}, {_h, _min, _s, _us}} = tuple), do: tuple

  defp name(value) when is_atom(value), do: Atom.to_string(value)
  defp name(value) when is_binary(value), do: value

  defp station_parts({lat, lon, alt}), do: {lat / 1.0, lon / 1.0, alt / 1.0}
  defp station_parts(%{latitude_deg: lat, longitude_deg: lon, altitude_km: alt}), do: station_parts({lat, lon, alt})

  defp kind_atom("march_equinox"), do: :march_equinox
  defp kind_atom("june_solstice"), do: :june_solstice
  defp kind_atom("september_equinox"), do: :september_equinox
  defp kind_atom("december_solstice"), do: :december_solstice
  defp kind_atom("new"), do: :new
  defp kind_atom("first_quarter"), do: :first_quarter
  defp kind_atom("full"), do: :full
  defp kind_atom("last_quarter"), do: :last_quarter
  defp kind_atom("conjunction"), do: :conjunction
  defp kind_atom("opposition"), do: :opposition
  defp kind_atom("upper"), do: :upper
  defp kind_atom("lower"), do: :lower
  defp kind_atom("lunar_penumbral"), do: :lunar_penumbral
  defp kind_atom("lunar_partial"), do: :lunar_partial
  defp kind_atom("lunar_total"), do: :lunar_total
  defp kind_atom("solar_partial"), do: :solar_partial
  defp kind_atom("solar_annular"), do: :solar_annular
  defp kind_atom("solar_total"), do: :solar_total
  defp kind_atom("solar_hybrid"), do: :solar_hybrid
  defp kind_atom(other), do: other

  defp bang({:ok, value}), do: value
  defp bang({:error, reason}), do: raise(ArgumentError, inspect(reason))
end
