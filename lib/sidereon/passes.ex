defmodule Sidereon.Passes do
  @moduledoc """
  Satellite pass prediction over a ground station.

  Finds time windows when a satellite is above the local horizon (or a
  minimum elevation threshold) as seen from a ground station. The pass-search
  orchestration and coordinate math live in the Rust core; this module keeps
  the public Sidereon API shape.
  """

  alias Sidereon.Elements
  alias Sidereon.NIF
  alias Sidereon.SGP4

  @allowed_options [:min_elevation, :step_seconds, :opsmode]
  @allowed_opsmodes [:afspc, :improved]

  @type ground_station :: %{
          latitude: float(),
          longitude: float(),
          altitude_m: float()
        }

  @type pass :: Sidereon.Pass.t()

  @type predict_error ::
          SGP4.element_error()
          | {:missing_field, atom()}
          | {:invalid_field, atom(), term()}
          | {:invalid_option, atom()}
          | {:nif_error, String.t()}

  @doc """
  Predict visible passes of a satellite over a ground station.

  ## Parameters

    * `tle` - parsed `%Sidereon.Elements{}` struct
    * `ground_station` - `%{latitude: deg, longitude: deg, altitude_m: m}`
    * `start_time` - `DateTime.t()` beginning of the search window
    * `end_time` - `DateTime.t()` end of the search window
    * `opts` - keyword list
      * `:min_elevation` - minimum peak elevation in degrees to keep a pass
        (default `0.0`)
      * `:step_seconds` - coarse propagation step in seconds (default `60`)
      * `:opsmode` - SGP4 operation mode, `:afspc` (default) or `:improved`.
        The pass search builds the satellite with this opsmode, so passes are
        consistent with `Sidereon.look_angle/4` under the same opsmode.

  ## Returns

  `{:ok, passes}` with pass structs sorted by rise time:

      {:ok, [%Sidereon.Pass{
        rise: DateTime.t(),
        set: DateTime.t(),
        max_elevation: float(),       # degrees
        max_elevation_time: DateTime.t(),
        duration_seconds: float()
      }]}

  Returns `{:error, reason}` for malformed elements, station fields, options,
  or NIF boundary failures. Use `predict!/5` for the raising form.
  """
  @spec predict(Elements.t(), ground_station(), DateTime.t(), DateTime.t(), keyword()) ::
          {:ok, [pass()]} | {:error, predict_error()}
  def predict(tle, ground_station, start_time, end_time, opts \\ []) do
    with {:ok, %Elements{} = tle} <- validate_tle(tle),
         {:ok, %DateTime{} = start_time} <- validate_datetime(start_time, :start_time),
         {:ok, %DateTime{} = end_time} <- validate_datetime(end_time, :end_time),
         {:ok, station} <- validate_ground_station(ground_station),
         {:ok, options} <- validate_options(opts),
         {:ok, elements_map} <- SGP4.to_nif_elements_map(tle),
         {:ok, pass_terms} <-
           predict_with_elements(elements_map, station, start_time, end_time, options) do
      {:ok, Enum.map(pass_terms, &decode_pass/1)}
    end
  end

  @doc """
  Predict visible passes, raising `ArgumentError` on errors.
  """
  @spec predict!(Elements.t(), ground_station(), DateTime.t(), DateTime.t(), keyword()) ::
          [pass()]
  def predict!(tle, ground_station, start_time, end_time, opts \\ []) do
    case predict(tle, ground_station, start_time, end_time, opts) do
      {:ok, passes} -> passes
      {:error, reason} -> raise ArgumentError, "pass prediction failed: #{inspect(reason)}"
    end
  end

  defp validate_tle(%Elements{} = tle), do: {:ok, tle}
  defp validate_tle(value), do: {:error, {:invalid_field, :tle, value}}

  defp validate_datetime(%DateTime{} = datetime, _field), do: {:ok, datetime}
  defp validate_datetime(value, field), do: {:error, {:invalid_field, field, value}}

  defp validate_ground_station(%{} = station) do
    with {:ok, latitude} <- required_number(station, :latitude),
         {:ok, longitude} <- required_number(station, :longitude),
         {:ok, altitude_m} <- required_number(station, :altitude_m) do
      {:ok, %{latitude: latitude, longitude: longitude, altitude_m: altitude_m}}
    end
  end

  defp validate_ground_station(value), do: {:error, {:invalid_field, :ground_station, value}}

  defp required_number(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_number(value) -> {:ok, value}
      {:ok, value} -> {:error, {:invalid_field, key, value}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp validate_options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      with :ok <- validate_option_keys(opts),
           {:ok, min_elevation} <- optional_number(opts, :min_elevation, 0.0),
           {:ok, step_seconds} <- optional_positive_integer(opts, :step_seconds, 60),
           {:ok, opsmode} <- optional_opsmode(opts, :opsmode, :afspc) do
        {:ok, %{min_elevation: min_elevation, step_seconds: step_seconds, opsmode: opsmode}}
      end
    else
      {:error, {:invalid_option, :opts}}
    end
  end

  defp validate_options(_opts), do: {:error, {:invalid_option, :opts}}

  defp validate_option_keys(opts) do
    case Enum.find(opts, fn {key, _value} -> key not in @allowed_options end) do
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

  defp optional_opsmode(opts, key, default) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when value in @allowed_opsmodes -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_option, key}}
      :error -> {:ok, default}
    end
  end

  defp predict_with_elements(elements_map, station, start_time, end_time, options) do
    {:ok,
     NIF.predict_passes(
       elements_map,
       station.latitude,
       station.longitude,
       station.altitude_m,
       to_nif_datetime(start_time),
       to_nif_datetime(end_time),
       options.min_elevation,
       options.step_seconds,
       options.opsmode
     )}
  rescue
    e in ErlangError -> {:error, {:nif_error, Exception.message(e)}}
  end

  defp decode_pass({rise_us, set_us, max_elevation, max_elevation_time_us}) do
    rise = DateTime.from_unix!(rise_us, :microsecond)
    set = DateTime.from_unix!(set_us, :microsecond)

    %Sidereon.Pass{
      rise: rise,
      set: set,
      max_elevation: max_elevation,
      max_elevation_time: DateTime.from_unix!(max_elevation_time_us, :microsecond),
      duration_seconds: (set_us - rise_us) / 1_000_000
    }
  end

  defp to_nif_datetime(%DateTime{} = dt) do
    {{dt.year, dt.month, dt.day}, {dt.hour, dt.minute, dt.second, elem(dt.microsecond, 0)}}
  end
end
