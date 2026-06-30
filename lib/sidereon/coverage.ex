defmodule Sidereon.Coverage do
  @moduledoc """
  Batch single-epoch coverage helpers backed by the Rust core.
  """

  alias Sidereon.Elements
  alias Sidereon.NIF
  alias Sidereon.SGP4

  @type station :: {number(), number(), number()} | %{latitude: number(), longitude: number(), altitude_m: number()}
  @type datetime ::
          DateTime.t()
          | NaiveDateTime.t()
          | {{integer(), integer(), integer()}, {integer(), integer(), integer()}}
          | {{integer(), integer(), integer()}, {integer(), integer(), integer(), integer()}}
  @type look_cell :: {:ok, {float(), float(), float()}} | :error

  @doc """
  Compute `{azimuth_deg, elevation_deg, range_km}` for every satellite/station pair.
  """
  @spec look_angles([Elements.t()], [station()], datetime()) :: [[look_cell()]]
  def look_angles(elements, stations, datetime) when is_list(elements) and is_list(stations) do
    NIF.coverage_look_angles(tle_maps(elements), station_terms(stations), to_nif_datetime(datetime))
  end

  defp tle_maps(elements) do
    Enum.map(elements, fn
      %Elements{} = elements ->
        case SGP4.to_nif_elements_map(elements) do
          {:ok, map} -> map
          {:error, reason} -> raise ArgumentError, "invalid elements: #{inspect(reason)}"
        end

      other ->
        raise ArgumentError, "expected Sidereon.Elements, got: #{inspect(other)}"
    end)
  end

  defp station_terms(stations), do: Enum.map(stations, &station_term/1)

  defp station_term({lat_deg, lon_deg, alt_m}) do
    {lat_deg / 1.0, lon_deg / 1.0, alt_m / 1.0}
  end

  defp station_term(%{latitude: lat_deg, longitude: lon_deg, altitude_m: alt_m}) do
    {lat_deg / 1.0, lon_deg / 1.0, alt_m / 1.0}
  end

  defp to_nif_datetime({{_y, _m, _d}, {_h, _min, _s, _us}} = datetime), do: datetime

  defp to_nif_datetime({{y, m, d}, {h, min, s}}) do
    {{y, m, d}, {h, min, s, 0}}
  end

  defp to_nif_datetime(%DateTime{} = dt) do
    {{dt.year, dt.month, dt.day}, {dt.hour, dt.minute, dt.second, elem(dt.microsecond, 0)}}
  end

  defp to_nif_datetime(%NaiveDateTime{} = dt) do
    {{dt.year, dt.month, dt.day}, {dt.hour, dt.minute, dt.second, elem(dt.microsecond, 0)}}
  end
end
