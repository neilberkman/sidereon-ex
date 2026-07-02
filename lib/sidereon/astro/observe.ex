defmodule Sidereon.Astro.Observe do
  @moduledoc """
  General topocentric body observation.

  This wraps the core observer pipeline for analytic Sun/Moon targets, SPK body
  targets, and caller-supplied barycentric states.
  """

  alias Sidereon.Ephemeris
  alias Sidereon.NIF

  @type station ::
          {number(), number(), number()} | %{latitude_deg: number(), longitude_deg: number(), altitude_km: number()}
  @type time :: DateTime.t() | NaiveDateTime.t() | {tuple(), tuple()}
  @type vec3 :: {number(), number(), number()}

  @doc "Observe the analytic Sun or Moon from a station."
  def observe(station, time, target, opts \\ []) when target in [:sun, :moon, "sun", "moon"] do
    {lat, lon, alt} = station_parts(station)

    NIF.observe_analytic(lat, lon, alt, datetime(time), target_name(target), options(opts))
    |> normalize()
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc "Observe a body from an SPK kernel by NAIF id or known body atom."
  def observe_spk_body(%Ephemeris{handle: handle}, station, time, body, opts \\ []) do
    {lat, lon, alt} = station_parts(station)

    NIF.observe_spk_body_full(handle, lat, lon, alt, datetime(time), body_code(body), options(opts))
    |> normalize()
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc "Observe an SPK body with core default observation options."
  def observe_spk_body_default(%Ephemeris{handle: handle}, station, time, body) do
    {lat, lon, alt} = station_parts(station)

    NIF.observe_spk_body_default(handle, lat, lon, alt, datetime(time), body_code(body))
    |> normalize()
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc "Observe a caller-supplied SSB-centered barycentric state."
  def observe_barycentric_state(%Ephemeris{handle: handle}, station, time, position_km, velocity_km_s, opts \\ []) do
    {lat, lon, alt} = station_parts(station)

    NIF.observe_barycentric_state(
      handle,
      lat,
      lon,
      alt,
      datetime(time),
      vec3(position_km),
      vec3(velocity_km_s),
      options(opts)
    )
    |> normalize()
  rescue
    e in ErlangError -> {:error, e.original}
  end

  def observe!(station, time, target, opts \\ []), do: bang(observe(station, time, target, opts))

  def observe_spk_body!(kernel, station, time, body, opts \\ []),
    do: bang(observe_spk_body(kernel, station, time, body, opts))

  def observe_spk_body_default!(kernel, station, time, body),
    do: bang(observe_spk_body_default(kernel, station, time, body))

  def observe_barycentric_state!(kernel, station, time, position_km, velocity_km_s, opts \\ []),
    do: bang(observe_barycentric_state(kernel, station, time, position_km, velocity_km_s, opts))

  defp normalize({:ok, observation}), do: {:ok, observation}
  defp normalize({:error, _} = err), do: err

  defp options(opts) do
    %{
      polar_motion: Keyword.get(opts, :polar_motion),
      refraction: refraction(Keyword.get(opts, :refraction)),
      deflection: Keyword.get(opts, :deflection, true),
      aberration: Keyword.get(opts, :aberration, true)
    }
  end

  defp refraction(nil), do: nil
  defp refraction({pressure_mbar, temperature_c}), do: {pressure_mbar / 1.0, temperature_c / 1.0}

  defp refraction(%{pressure_mbar: pressure_mbar, temperature_c: temperature_c}),
    do: {pressure_mbar / 1.0, temperature_c / 1.0}

  defp station_parts({lat, lon, alt}), do: {lat / 1.0, lon / 1.0, alt / 1.0}
  defp station_parts(%{latitude_deg: lat, longitude_deg: lon, altitude_km: alt}), do: station_parts({lat, lon, alt})

  defp datetime(%DateTime{} = dt),
    do: {{dt.year, dt.month, dt.day}, {dt.hour, dt.minute, dt.second, elem(dt.microsecond, 0)}}

  defp datetime(%NaiveDateTime{} = dt),
    do: {{dt.year, dt.month, dt.day}, {dt.hour, dt.minute, dt.second, elem(dt.microsecond, 0)}}

  defp datetime({{_y, _m, _d}, {_h, _min, _s, _us}} = tuple), do: tuple

  defp vec3({x, y, z}), do: {x / 1.0, y / 1.0, z / 1.0}

  defp target_name(:sun), do: "sun"
  defp target_name(:moon), do: "moon"
  defp target_name(value) when is_binary(value), do: value

  defp body_code(code) when is_integer(code), do: code
  defp body_code(:ssb), do: 0
  defp body_code(:solar_system_barycenter), do: 0
  defp body_code(:mercury), do: 1
  defp body_code(:venus), do: 2
  defp body_code(:earth_moon_barycenter), do: 3
  defp body_code(:emb), do: 3
  defp body_code(:mars), do: 4
  defp body_code(:jupiter), do: 5
  defp body_code(:saturn), do: 6
  defp body_code(:uranus), do: 7
  defp body_code(:neptune), do: 8
  defp body_code(:pluto), do: 9
  defp body_code(:sun), do: 10
  defp body_code(:moon), do: 301
  defp body_code(:earth), do: 399

  defp bang({:ok, value}), do: value
  defp bang({:error, reason}), do: raise(ArgumentError, inspect(reason))
end
