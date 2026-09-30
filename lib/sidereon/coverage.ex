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
  @type sgp4_error ::
          {:invalid_input, atom(), atom()}
          | {:non_finite_output, atom()}
          | {:invalid_tle, String.t()}
          | {:sgp4, integer()}
          | {:resonance_step_budget, non_neg_integer()}
  @type frame_transform_error ::
          {:invalid_input, String.t(), String.t()}
          | {:ut1_outside_coverage, :before_coverage | :after_coverage}
  @type look_angle_error ::
          {:invalid_input, String.t(), String.t()}
          | {:init, sgp4_error()}
          | {:propagate, sgp4_error()}
          | {:frame_transform, frame_transform_error()}
  @type detailed_look_cell :: {:ok, {float(), float(), float()}} | {:error, look_angle_error()}

  @doc """
  Compute `{azimuth_deg, elevation_deg, range_km}` for every satellite/station pair.

  If SGP4 initialization fails, this legacy API raises `ErlangError` with the
  typed, unindexed `sgp4_error()` in `error.original`. Use `look_angles_detailed/3`
  to retain one row per input satellite when stations are present.
  """
  @spec look_angles([Elements.t()], [station()], datetime()) :: [[look_cell()]]
  def look_angles(elements, stations, datetime) when is_list(elements) and is_list(stations) do
    NIF.coverage_look_angles(tle_maps(elements), station_terms(stations), to_nif_datetime(datetime))
  end

  @doc """
  Compute detailed per-cell results while retaining input satellite row positions.

  With stations present, a satellite initialization failure fills that satellite's
  row with `{:error, {:init, sgp4_error()}}`. If there are no stations and an
  initialization fails, no cell can carry the failure, so this function raises
  `ErlangError` whose `original` is
  `{:satellite_initialization, input_index, sgp4_error()}`.
  """
  @spec look_angles_detailed([Elements.t()], [station()], datetime()) :: [[detailed_look_cell()]]
  def look_angles_detailed(elements, stations, datetime) when is_list(elements) and is_list(stations) do
    NIF.coverage_look_angles_detailed(tle_maps(elements), station_terms(stations), to_nif_datetime(datetime))
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
