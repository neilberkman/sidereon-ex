defmodule Sidereon.SGP4 do
  @moduledoc """
  SGP4/SDP4 orbit propagation from Two-Line Element sets.
  """

  alias Sidereon.Elements
  alias Sidereon.TemeState

  @required_float_fields [
    :bstar,
    :mean_motion_dot,
    :mean_motion_double_dot,
    :eccentricity,
    :arg_perigee_deg,
    :inclination_deg,
    :mean_anomaly_deg,
    :mean_motion,
    :raan_deg
  ]

  @type element_error ::
          {:missing_field, atom()}
          | {:invalid_field, atom(), term()}

  @type propagation_error ::
          element_error()
          | String.t()
          | {:nif_error, String.t()}

  @doc """
  Propagate a TLE to a specific datetime, returning a TEME state vector.

  Uses the sgp4 Rust crate in AFSPC compatibility mode. Elements are
  passed as individual fields, so this works for both TLE and OMM inputs.

  Returns `{:ok, %Sidereon.TemeState{}}` with position in km and velocity in km/s,
  or `{:error, reason}`.
  """
  @spec propagate(Elements.t(), DateTime.t()) ::
          {:ok, TemeState.t()} | {:error, propagation_error()}
  def propagate(%Elements{} = tle, %DateTime{} = datetime) do
    datetime_tuple =
      {{datetime.year, datetime.month, datetime.day},
       {datetime.hour, datetime.minute, datetime.second, elem(datetime.microsecond, 0)}}

    with {:ok, elements_map} <- to_nif_elements_map(tle),
         {:ok, {position, velocity}} <-
           propagate_with_elements(elements_map, datetime_tuple) do
      {:ok, %TemeState{position: position, velocity: velocity}}
    end
  end

  @doc """
  Propagate many satellites across a shared list of times, in one NIF call.

  Each time is **minutes since that satellite's own epoch** (the core batch
  convention), so element `i` of the result is the arc for `satellites |> Enum.at(i)`
  evaluated at every offset in `times_minutes`. This is the throughput primitive
  over `sidereon_core::astro::sgp4::propagate_batch`; one bad satellite never
  collapses the batch.

  `satellites` is a list of `%Sidereon.Elements{}`. Options:

    * `:opsmode` - `:afspc` (default, matching `propagate/2`) or `:improved`.
    * `:parallel` - when `true`, fans the per-satellite arcs across a thread pool
      (`propagate_batch_parallel`); the results are bit-identical to the serial
      path. Defaults to `false`.

  Returns `{:ok, arcs}` where each arc is `{:ok, [%Sidereon.TemeState{}, ...]}`
  (one state per time, in order) or `{:error, reason}` for a satellite that failed
  to propagate. Returns `{:error, {:invalid_elements, index, reason}}` if an input
  element set cannot be marshalled.
  """
  @spec propagate_batch([Elements.t()], [number()], keyword()) ::
          {:ok, [{:ok, [TemeState.t()]} | {:error, term()}]} | {:error, term()}
  def propagate_batch(satellites, times_minutes, opts \\ []) when is_list(satellites) and is_list(times_minutes) do
    opsmode = Keyword.get(opts, :opsmode, :afspc)
    parallel? = Keyword.get(opts, :parallel, false)

    with {:ok, maps} <- to_nif_elements_maps(satellites) do
      times = Enum.map(times_minutes, &(&1 / 1.0))

      result =
        if parallel? do
          Sidereon.NIF.sgp4_propagate_batch_parallel(maps, times, opsmode)
        else
          Sidereon.NIF.sgp4_propagate_batch(maps, times, opsmode)
        end

      case result do
        {:ok, arcs} -> {:ok, Enum.map(arcs, &decode_arc/1)}
        {:error, _} = err -> err
      end
    end
  rescue
    e in ErlangError -> {:error, {:nif_error, Exception.message(e)}}
  end

  defp to_nif_elements_maps(satellites) do
    satellites
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {sat, index}, {:ok, acc} ->
      case to_nif_elements_map(sat) do
        {:ok, map} -> {:cont, {:ok, [map | acc]}}
        {:error, reason} -> {:halt, {:error, {:invalid_elements, index, reason}}}
      end
    end)
    |> case do
      {:ok, maps} -> {:ok, Enum.reverse(maps)}
      {:error, _} = err -> err
    end
  end

  defp decode_arc({:ok, states}) do
    {:ok, Enum.map(states, fn {position, velocity} -> %TemeState{position: position, velocity: velocity} end)}
  end

  defp decode_arc({:error, reason}), do: {:error, reason}

  @doc false
  @spec to_nif_elements_map(Elements.t()) :: {:ok, map()} | {:error, element_error()}
  def to_nif_elements_map(%Elements{} = tle) do
    with {:ok, fields} <- validate_elements(tle) do
      epoch = fields.epoch
      year = epoch.year

      epochdays =
        Sidereon.NIF.civil_day_of_year(
          year,
          epoch.month,
          epoch.day,
          epoch.hour,
          epoch.minute,
          epoch.second + elem(epoch.microsecond, 0) / 1_000_000
        )

      {:ok,
       %{
         catalog_number: fields.catalog_number,
         bstar: fields.bstar,
         mean_motion_dot: fields.mean_motion_dot,
         mean_motion_double_dot: fields.mean_motion_double_dot,
         eccentricity: fields.eccentricity,
         arg_perigee_deg: fields.arg_perigee_deg,
         inclination_deg: fields.inclination_deg,
         mean_anomaly_deg: fields.mean_anomaly_deg,
         mean_motion: fields.mean_motion,
         raan_deg: fields.raan_deg,
         epoch_year: year,
         epochdays: epochdays
       }}
    end
  end

  @doc false
  @spec validate_elements(Elements.t()) :: {:ok, map()} | {:error, element_error()}
  def validate_elements(%Elements{} = tle) do
    with {:ok, epoch} <- required_datetime(tle, :epoch),
         {:ok, catalog_number} <- required_catalog_number(tle, :catalog_number),
         {:ok, floats} <- required_float_fields(tle) do
      {:ok, Map.merge(%{epoch: epoch, catalog_number: catalog_number}, floats)}
    end
  end

  defp propagate_with_elements(elements_map, datetime_tuple) do
    Sidereon.NIF.propagate_with_elements(elements_map, datetime_tuple)
  rescue
    e in ErlangError -> {:error, {:nif_error, Exception.message(e)}}
  end

  defp required_datetime(tle, field) do
    case Map.fetch!(tle, field) do
      nil -> {:error, {:missing_field, field}}
      %DateTime{} = datetime -> {:ok, datetime}
      value -> {:error, {:invalid_field, field, value}}
    end
  end

  defp required_catalog_number(tle, field) do
    case Map.fetch!(tle, field) do
      nil ->
        {:error, {:missing_field, field}}

      value when is_binary(value) ->
        catalog_number = String.trim(value)

        if catalog_number == "" do
          {:error, {:invalid_field, field, value}}
        else
          {:ok, catalog_number}
        end

      value ->
        {:error, {:invalid_field, field, value}}
    end
  end

  defp required_float_fields(tle) do
    Enum.reduce_while(@required_float_fields, {:ok, %{}}, fn field, {:ok, acc} ->
      case required_float(tle, field) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, field, value)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp required_float(tle, field) do
    case Map.fetch!(tle, field) do
      nil -> {:error, {:missing_field, field}}
      value when is_float(value) -> {:ok, value}
      value when is_integer(value) -> {:ok, value * 1.0}
      value -> {:error, {:invalid_field, field, value}}
    end
  end
end
