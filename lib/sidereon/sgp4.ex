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

  @doc false
  @spec to_nif_elements_map(Elements.t()) :: {:ok, map()} | {:error, element_error()}
  def to_nif_elements_map(%Elements{} = tle) do
    with {:ok, fields} <- validate_elements(tle) do
      year = fields.epoch.year
      jan1 = DateTime.new!(Date.new!(year, 1, 1), Time.new!(0, 0, 0, 0), "Etc/UTC")
      diff_us = DateTime.diff(fields.epoch, jan1, :microsecond)
      epochdays = 1.0 + diff_us / (86_400 * 1_000_000)
      epochyr = rem(year, 100)

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
         epochyr: epochyr,
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
