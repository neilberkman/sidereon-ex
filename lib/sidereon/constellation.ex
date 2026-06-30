defmodule Sidereon.Constellation do
  @moduledoc """
  Manage and propagate satellite constellations.

  Build a constellation from parsed TLEs and propagate all satellites to a
  given time. Useful for visibility computations over a shared fleet.

  ## Examples

      constellation = Sidereon.Constellation.from_tles("custom", tles)
      constellation.count

      # Propagate all satellites to now
      positions = Sidereon.Constellation.propagate_all(constellation, DateTime.utc_now())
      Enum.each(positions, fn {norad_id, pos} ->
        IO.puts("\#{norad_id}: \#{inspect(pos)}")
      end)

      # Find visible satellites from a ground station
      {:ok, visible} = Sidereon.Constellation.visible_from(constellation, station, datetime)
  """

  alias Sidereon.Elements
  alias Sidereon.Geodetic
  alias Sidereon.LookAngle
  alias Sidereon.NIF
  alias Sidereon.Pass
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

  @type fleet_pass :: %{
          satellite_index: non_neg_integer(),
          catalog_number: String.t(),
          pass: Pass.t()
        }

  @type batch_error ::
          {:invalid_satellites, invalid_satellites()}
          | {:invalid_option, term()}
          | {:invalid_field, atom(), term()}
          | {:nif_error, String.t()}

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
    * `:opsmode` - SGP4 operation mode, `:afspc` (default) or `:improved`. Each
      satellite is built with this opsmode, so visibility is consistent with the
      look angle and passes computed under the same opsmode.

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

    with {:ok, opsmode} <- validate_opsmode(Keyword.get(opts, :opsmode, :afspc)),
         {:ok, elements_maps} <- constellation_elements_maps(constellation),
         {:ok, visible_terms} <-
           visible_with_elements(elements_maps, station, datetime, min_el, opsmode) do
      {:ok, Enum.map(visible_terms, &decode_visible/1)}
    end
  end

  @doc """
  Compute topocentric look-angle arcs from a ground station for every satellite
  over a shared epoch grid.

  Returns one arc per satellite in fleet order (the constellation's
  `satellites` order): element `i` is a list of `%Sidereon.LookAngle{}` for
  `satellites[i]`, one per datetime. A satellite whose element set fails SGP4
  initialization yields an empty arc, so the result stays index-aligned with the
  constellation. This is the batched companion to `Sidereon.look_angle/4`.

  ## Options

    * `:opsmode` - SGP4 operation mode, `:afspc` (default) or `:improved`. Each
      satellite is built with this opsmode, so the arcs are consistent with
      `visible_from/4` and `passes/5` computed under the same opsmode.

  ## Examples

      times = for s <- 0..600//60, do: DateTime.add(DateTime.utc_now(), s, :second)
      {:ok, arcs} = Sidereon.Constellation.look_angle_arcs(constellation, station, times)
      hd(arcs) |> hd() |> Map.get(:elevation)
  """
  @spec look_angle_arcs(t(), map(), [DateTime.t()], keyword()) ::
          {:ok, [[LookAngle.t()]]} | {:error, batch_error()}
  def look_angle_arcs(%__MODULE__{} = constellation, station, datetimes, opts \\ []) when is_list(datetimes) do
    with {:ok, opsmode} <- validate_opsmode(Keyword.get(opts, :opsmode, :afspc)),
         {:ok, datetimes} <- validate_datetimes(datetimes),
         {:ok, elements_maps} <- constellation_elements_maps(constellation),
         {:ok, arcs} <- look_angle_arcs_nif(elements_maps, station, datetimes, opsmode) do
      {:ok,
       Enum.map(arcs, fn arc ->
         Enum.map(arc, fn {azimuth, elevation, range_km} ->
           %LookAngle{azimuth: azimuth, elevation: elevation, range_km: range_km}
         end)
       end)}
    end
  end

  @doc """
  Compute WGS84 sub-satellite ground tracks for every satellite over a shared
  epoch grid.

  Returns one track per satellite in fleet order: element `i` is a list of
  `%Sidereon.Geodetic{}` (latitude/longitude in degrees, ellipsoidal altitude in
  km) for `satellites[i]`, one per datetime. Each point is reduced
  TEME -> GCRS -> ITRS -> WGS84 geodetic by the engine's transforms. A satellite
  whose element set fails SGP4 initialization yields an empty track, keeping the
  result index-aligned. This is the batched companion to `Sidereon.ground_track/3`.

  ## Options

    * `:opsmode` - SGP4 operation mode, `:afspc` (default) or `:improved`.

  ## Examples

      times = for s <- 0..600//60, do: DateTime.add(DateTime.utc_now(), s, :second)
      {:ok, tracks} = Sidereon.Constellation.ground_tracks(constellation, times)
      hd(tracks) |> hd() |> Map.get(:latitude)
  """
  @spec ground_tracks(t(), [DateTime.t()], keyword()) ::
          {:ok, [[Geodetic.t()]]} | {:error, batch_error()}
  def ground_tracks(%__MODULE__{} = constellation, datetimes, opts \\ []) when is_list(datetimes) do
    with {:ok, opsmode} <- validate_opsmode(Keyword.get(opts, :opsmode, :afspc)),
         {:ok, datetimes} <- validate_datetimes(datetimes),
         {:ok, elements_maps} <- constellation_elements_maps(constellation),
         {:ok, tracks} <- ground_tracks_nif(elements_maps, datetimes, opsmode) do
      {:ok,
       Enum.map(tracks, fn track ->
         Enum.map(track, fn {latitude, longitude, altitude_km} ->
           %Geodetic{latitude: latitude, longitude: longitude, altitude_km: altitude_km}
         end)
       end)}
    end
  end

  @doc """
  Predict passes over a ground station for every satellite within a time window.

  Returns a flat list of passes across the whole constellation, each tagged with
  the fleet-order `:satellite_index` and the `:catalog_number` of the satellite
  it belongs to:

      {:ok, [%{
        satellite_index: non_neg_integer(),
        catalog_number: String.t(),
        pass: %Sidereon.Pass{}
      }]}

  Passes are emitted satellite by satellite in fleet order, each satellite's
  passes ordered by rise time. A satellite whose element set fails SGP4
  initialization contributes no passes (its fleet index is still consumed, so
  indices match the constellation order). This is the constellation companion to
  `Sidereon.Passes.predict/5`.

  ## Options

    * `:min_elevation` - minimum peak elevation in degrees to keep a pass
      (default `0.0`); like `Sidereon.Passes.predict/5`, rise/set always
      reference the 0-degree horizon
    * `:step_seconds` - coarse propagation step in seconds (default `60`)
    * `:opsmode` - SGP4 operation mode, `:afspc` (default) or `:improved`

  ## Examples

      start_dt = DateTime.utc_now()
      end_dt = DateTime.add(start_dt, 86_400, :second)
      {:ok, passes} = Sidereon.Constellation.passes(constellation, station, start_dt, end_dt)
      hd(passes).satellite_index
  """
  @spec passes(t(), map(), DateTime.t(), DateTime.t(), keyword()) ::
          {:ok, [fleet_pass()]} | {:error, batch_error()}
  def passes(%__MODULE__{} = constellation, station, start_dt, end_dt, opts \\ []) do
    with {:ok, %DateTime{} = start_dt} <- validate_datetime(start_dt, :start_dt),
         {:ok, %DateTime{} = end_dt} <- validate_datetime(end_dt, :end_dt),
         {:ok, options} <- validate_pass_options(opts),
         {:ok, elements_maps} <- constellation_elements_maps(constellation),
         {:ok, pass_terms} <-
           passes_nif(elements_maps, station, start_dt, end_dt, options) do
      {:ok, Enum.map(pass_terms, &decode_fleet_pass/1)}
    end
  end

  defp validate_opsmode(opsmode) when opsmode in [:afspc, :improved], do: {:ok, opsmode}
  defp validate_opsmode(opsmode), do: {:error, {:invalid_option, {:opsmode, opsmode}}}

  defp validate_datetime(%DateTime{} = datetime, _field), do: {:ok, datetime}
  defp validate_datetime(value, field), do: {:error, {:invalid_field, field, value}}

  # Validate every entry up front so a non-`DateTime` element returns a tidy
  # `{:error, {:invalid_field, :datetimes, value}}` instead of raising inside
  # `to_nif_datetime/1` before the NIF rescue runs.
  defp validate_datetimes(datetimes) do
    Enum.reduce_while(datetimes, {:ok, datetimes}, fn
      %DateTime{}, acc -> {:cont, acc}
      value, _acc -> {:halt, {:error, {:invalid_field, :datetimes, value}}}
    end)
  end

  defp validate_pass_options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      with :ok <- validate_pass_option_keys(opts),
           {:ok, min_elevation} <- optional_number(opts, :min_elevation, 0.0),
           {:ok, step_seconds} <- optional_positive_integer(opts, :step_seconds, 60),
           {:ok, opsmode} <- validate_opsmode(Keyword.get(opts, :opsmode, :afspc)) do
        {:ok, %{min_elevation: min_elevation, step_seconds: step_seconds, opsmode: opsmode}}
      end
    else
      {:error, {:invalid_option, :opts}}
    end
  end

  defp validate_pass_options(_opts), do: {:error, {:invalid_option, :opts}}

  defp validate_pass_option_keys(opts) do
    case Enum.find(opts, fn {key, _value} -> key not in [:min_elevation, :step_seconds, :opsmode] end) do
      nil -> :ok
      {key, _value} -> {:error, {:invalid_option, key}}
    end
  end

  defp optional_number(opts, key, default) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_number(value) -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_option, key}}
      :error -> {:ok, default}
    end
  end

  defp optional_positive_integer(opts, key, default) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_integer(value) and value > 0 -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_option, key}}
      :error -> {:ok, default}
    end
  end

  defp look_angle_arcs_nif(elements_maps, station, datetimes, opsmode) do
    {:ok,
     NIF.constellation_look_angle_arcs(
       elements_maps,
       station.latitude,
       station.longitude,
       station.altitude_m,
       Enum.map(datetimes, &to_nif_datetime/1),
       opsmode
     )}
  rescue
    e in ErlangError -> {:error, {:nif_error, Exception.message(e)}}
  end

  defp ground_tracks_nif(elements_maps, datetimes, opsmode) do
    {:ok,
     NIF.constellation_ground_tracks(
       elements_maps,
       Enum.map(datetimes, &to_nif_datetime/1),
       opsmode
     )}
  rescue
    e in ErlangError -> {:error, {:nif_error, Exception.message(e)}}
  end

  defp passes_nif(elements_maps, station, start_dt, end_dt, options) do
    {:ok,
     NIF.constellation_passes(
       elements_maps,
       station.latitude,
       station.longitude,
       station.altitude_m,
       to_nif_datetime(start_dt),
       to_nif_datetime(end_dt),
       options.min_elevation,
       options.step_seconds,
       options.opsmode
     )}
  rescue
    e in ErlangError -> {:error, {:nif_error, Exception.message(e)}}
  end

  defp decode_fleet_pass({satellite_index, catalog_number, aos_us, los_us, max_elevation, culmination_us}) do
    %{
      satellite_index: satellite_index,
      catalog_number: catalog_number,
      pass: %Pass{
        rise: DateTime.from_unix!(aos_us, :microsecond),
        set: DateTime.from_unix!(los_us, :microsecond),
        max_elevation: max_elevation,
        max_elevation_time: DateTime.from_unix!(culmination_us, :microsecond),
        duration_seconds: (los_us - aos_us) / 1_000_000
      }
    }
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

  defp visible_with_elements(elements_maps, station, datetime, min_el, opsmode) do
    {:ok,
     NIF.constellation_visible(
       elements_maps,
       station.latitude,
       station.longitude,
       station.altitude_m,
       to_nif_datetime(datetime),
       min_el,
       opsmode
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
