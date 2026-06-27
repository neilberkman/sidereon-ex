defmodule Sidereon.Constellation do
  @moduledoc """
  Manage and propagate satellite constellations.

  Load TLEs for an entire constellation and propagate all satellites
  to a given time. Useful for coverage analysis, constellation status
  monitoring, and visibility computations.

  ## Examples

      # Load from CelesTrak
      {:ok, constellation} = Sidereon.Constellation.load("globalstar")
      constellation.count
      #=> 85

      # Propagate all satellites to now
      positions = Sidereon.Constellation.propagate_all(constellation, DateTime.utc_now())
      Enum.each(positions, fn {norad_id, pos} ->
        IO.puts("\#{norad_id}: \#{inspect(pos)}")
      end)

      # Find visible satellites from a ground station
      {:ok, visible} = Sidereon.Constellation.visible_from(constellation, station, datetime)
  """

  alias Sidereon.Elements
  alias Sidereon.NIF
  alias Sidereon.SGP4

  defstruct [:name, :satellites, :count]

  @type t :: %__MODULE__{
          name: String.t(),
          satellites: [Elements.t()],
          count: non_neg_integer()
        }

  @type visible_satellite :: %{
          catalog_number: String.t(),
          elevation: float(),
          azimuth: float(),
          range_km: float(),
          position: {float(), float(), float()}
        }

  @type invalid_satellites :: [{String.t() | nil, {:error, term()}}]

  @type visible_error ::
          {:invalid_satellites, invalid_satellites()}
          | {:nif_error, String.t()}

  @doc """
  Load a constellation from CelesTrak by group name.

  ## Examples

      {:ok, c} = Sidereon.Constellation.load("globalstar")
      c.count
      #=> 85
  """
  @spec load(String.t()) :: {:ok, t()} | {:error, term()}
  def load(group_name) do
    case Sidereon.CelesTrak.fetch_group(group_name) do
      {:ok, tles} ->
        {:ok,
         %__MODULE__{
           name: group_name,
           satellites: tles,
           count: length(tles)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Create a constellation from a list of TLEs.

  ## Examples

      constellation = Sidereon.Constellation.from_tles("custom", tles)
  """
  @spec from_tles(String.t(), [Elements.t()]) :: t()
  def from_tles(name, tles) do
    %__MODULE__{
      name: name,
      satellites: tles,
      count: length(tles)
    }
  end

  @doc """
  Propagate all satellites to a given time.

  Returns a list of `{catalog_number, {:ok, teme_state}}` or
  `{catalog_number, {:error, reason}}` tuples.

  ## Examples

      results = Sidereon.Constellation.propagate_all(constellation, ~U[2024-07-04 00:00:00Z])
      for {id, {:ok, teme}} <- results do
        IO.puts("\#{id}: \#{inspect(teme.position)}")
      end
  """
  @spec propagate_all(t(), DateTime.t()) :: [
          {String.t() | nil, {:ok, Sidereon.TemeState.t()} | {:error, term()}}
        ]
  def propagate_all(%__MODULE__{satellites: sats}, datetime) do
    sat_refs = Enum.map(sats, &{satellite_catalog_number(&1), &1})
    previous_trap_exit = Process.flag(:trap_exit, true)

    try do
      sat_refs
      |> Task.async_stream(
        fn {catalog_number, tle} ->
          {catalog_number, SGP4.propagate(tle, datetime)}
        end,
        max_concurrency: System.schedulers_online() * 2,
        timeout: 5_000
      )
      |> Enum.zip(sat_refs)
      |> Enum.map(fn
        {{:ok, result}, _sat_ref} ->
          result

        {{:exit, reason}, {catalog_number, _tle}} ->
          {catalog_number, {:error, {:task_exit, reason}}}
      end)
    after
      Process.flag(:trap_exit, previous_trap_exit)
    end
  end

  @doc """
  Find satellites visible from a ground station at a given time.

  Returns satellites above `min_elevation` degrees, sorted by elevation
  (highest first).

  ## Options

    * `:min_elevation` - minimum elevation in degrees (default: 10.0)

  ## Examples

      {:ok, visible} = Sidereon.Constellation.visible_from(constellation, station, datetime)
      for sat <- visible do
        IO.puts("\#{sat.catalog_number}: el=\#{sat.elevation}° range=\#{sat.range_km} km")
      end
  """
  @spec visible_from(t(), map(), DateTime.t(), keyword()) ::
          {:ok, [visible_satellite()]} | {:error, visible_error()}
  def visible_from(%__MODULE__{} = constellation, station, datetime, opts \\ []) do
    min_el = Keyword.get(opts, :min_elevation, 10.0)

    with {:ok, elements_maps} <- constellation_elements_maps(constellation),
         {:ok, visible_terms} <-
           visible_with_elements(elements_maps, station, datetime, min_el) do
      {:ok, Enum.map(visible_terms, &decode_visible/1)}
    end
  end

  defp constellation_elements_maps(%__MODULE__{satellites: satellites}) do
    {element_maps, failures} =
      Enum.reduce(satellites, {[], []}, fn tle, {maps, errors} ->
        catalog_number = satellite_catalog_number(tle)

        case SGP4.to_nif_elements_map(tle) do
          {:ok, elements_map} -> {[elements_map | maps], errors}
          {:error, reason} -> {maps, [{catalog_number, {:error, reason}} | errors]}
        end
      end)

    case failures do
      [] -> {:ok, Enum.reverse(element_maps)}
      _ -> {:error, {:invalid_satellites, Enum.reverse(failures)}}
    end
  end

  defp visible_with_elements(elements_maps, station, datetime, min_el) do
    {:ok,
     NIF.constellation_visible(
       elements_maps,
       station.latitude,
       station.longitude,
       station.altitude_m,
       to_nif_datetime(datetime),
       min_el
     )}
  rescue
    e in ErlangError -> {:error, {:nif_error, Exception.message(e)}}
  end

  defp decode_visible({catalog_number, elevation, azimuth, range_km, position}) do
    %{
      catalog_number: catalog_number,
      elevation: elevation,
      azimuth: azimuth,
      range_km: range_km,
      position: position
    }
  end

  defp satellite_catalog_number(%Elements{catalog_number: catalog_number}), do: catalog_number

  defp to_nif_datetime(%DateTime{} = dt) do
    {{dt.year, dt.month, dt.day}, {dt.hour, dt.minute, dt.second, elem(dt.microsecond, 0)}}
  end
end
