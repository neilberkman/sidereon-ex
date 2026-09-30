defmodule Sidereon.Tides.StationTideConstants do
  @moduledoc "Selects the Step 2 diurnal constants used by the solid-Earth tide model."

  @enforce_keys [:variant]
  defstruct [:variant]

  @type t :: :conventions | :iers_routine | %__MODULE__{variant: :conventions | :iers_routine}

  @spec conventions() :: t()
  def conventions, do: %__MODULE__{variant: :conventions}

  @spec iers_routine() :: t()
  def iers_routine, do: %__MODULE__{variant: :iers_routine}
end

defmodule Sidereon.Tides.StationDisplacement do
  @moduledoc "Component-resolved station displacement and UT1 validity."

  @enforce_keys [:ecef_m, :valid]
  defstruct [:ecef_m, :solid_earth_tide_ecef_m, :pole_tide_ecef_m, :ocean_loading_ecef_m, :degraded, :valid]

  @type t :: %__MODULE__{
          ecef_m: [float()],
          solid_earth_tide_ecef_m: [float()] | nil,
          pole_tide_ecef_m: [float()] | nil,
          ocean_loading_ecef_m: [float()] | nil,
          degraded: :before_coverage | :after_coverage | nil,
          valid: boolean()
        }
end

defmodule Sidereon.Tides.TideSystem do
  @moduledoc "Identifies the permanent-tide convention carried by gravity coefficients."

  @type t :: :tide_free | :zero_tide | :mean_tide

  @spec tide_free() :: :tide_free
  def tide_free, do: :tide_free

  @spec zero_tide() :: :zero_tide
  def zero_tide, do: :zero_tide

  @spec mean_tide() :: :mean_tide
  def mean_tide, do: :mean_tide

  @spec solid_earth_tide_force(t()) :: {:solid_earth_tide, t()}
  def solid_earth_tide_force(system) when system in [:tide_free, :zero_tide, :mean_tide],
    do: {:solid_earth_tide, system}
end

defmodule Sidereon.Tides do
  @moduledoc "High-level geophysical tide corrections."

  alias Sidereon.NIF
  alias Sidereon.Tides.StationDisplacement
  alias Sidereon.Tides.StationTideConstants
  alias Sidereon.Tides.TideSystem

  @type validity_mode :: :strict | :permissive
  @type station_tide_error :: %{
          variant: String.t(),
          field: String.t() | nil,
          kind: String.t() | nil,
          source: String.t() | nil,
          line: non_neg_integer() | nil,
          block: non_neg_integer() | nil,
          detail_variant: String.t() | nil,
          station: String.t() | nil,
          token: String.t() | nil,
          constituent: String.t() | nil,
          expected: non_neg_integer() | nil,
          found: non_neg_integer() | nil,
          index: non_neg_integer() | nil,
          row: non_neg_integer() | nil
        }
  @type station_displacement_row ::
          StationDisplacement.t()
          | {:error, {:station_tide, station_tide_error()} | term()}

  @doc "Evaluate station displacement from ECEF or WGS84 geodetic coordinates."
  @spec station_displacement(map(), map(), keyword() | map()) ::
          {:ok, StationDisplacement.t()} | {:error, term()}
  def station_displacement(position, epoch, opts \\ []) do
    with {:ok, request} <- request(position, epoch, opts) do
      case NIF.station_displacement(request) do
        {:ok, result} -> {:ok, displacement(result)}
        {:error, fields} -> {:error, {:station_tide, fields}}
      end
    end
  rescue
    error in ErlangError -> Sidereon.NifCall.error(error, __STACKTRACE__, :station_displacement)
  end

  @doc "Alias for `station_displacement/3` with the station-tide name."
  @spec station_tide_displacement(map(), map(), keyword() | map()) ::
          {:ok, StationDisplacement.t()} | {:error, term()}
  def station_tide_displacement(position, epoch, opts \\ []), do: station_displacement(position, epoch, opts)

  @doc "Evaluate station displacement under an explicit UT1 table-validity policy."
  @spec station_displacement_with_validity(map(), map(), validity_mode(), keyword() | map()) ::
          {:ok, StationDisplacement.t()} | {:error, term()}
  def station_displacement_with_validity(position, epoch, validity, opts \\ [])

  def station_displacement_with_validity(position, epoch, validity, opts) when validity in [:strict, :permissive] do
    station_displacement(position, epoch, Map.put(normalize_options(opts), :validity, validity))
  end

  def station_displacement_with_validity(_position, _epoch, _validity, _opts), do: {:error, :invalid_validity_mode}

  @doc "Station-tide displacement with an explicit UT1 validity policy."
  @spec station_tide_displacement_with_validity(map(), map(), validity_mode(), keyword() | map()) ::
          {:ok, StationDisplacement.t()} | {:error, term()}
  def station_tide_displacement_with_validity(position, epoch, validity, opts \\ []),
    do: station_displacement_with_validity(position, epoch, validity, opts)

  @doc "Evaluate station displacement independently at each epoch, retaining row-local errors."
  @spec station_displacement_batch(map(), [map()], keyword() | map()) ::
          {:ok, [station_displacement_row()]}
  def station_displacement_batch(position, epochs, opts \\ []) when is_list(epochs) do
    prepared = Enum.map(epochs, &request(position, &1, opts))

    valid_requests =
      prepared
      |> Enum.with_index()
      |> Enum.filter(fn {result, _index} -> match?({:ok, _}, result) end)

    nif_results =
      case valid_requests do
        [] ->
          {:ok, []}

        requests ->
          NIF.station_displacement_batch(Enum.map(requests, fn {{:ok, row}, _index} -> row end))
      end

    case nif_results do
      {:ok, rows} ->
        decoded =
          Enum.zip(valid_requests, rows)
          |> Map.new(fn {{{:ok, _request}, index}, row} -> {index, decode_batch_row(row)} end)

        results =
          prepared
          |> Enum.with_index()
          |> Enum.map(fn
            {{:ok, _request}, index} -> Map.fetch!(decoded, index)
            {{:error, reason}, _index} -> {:error, reason}
          end)

        {:ok, results}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error in ErlangError -> Sidereon.NifCall.error(error, __STACKTRACE__, :station_displacement_batch)
  end

  defp decode_batch_row({:ok, result}), do: displacement(result)
  defp decode_batch_row({:error, fields}), do: {:error, {:station_tide, fields}}

  defp displacement(result) do
    struct(StationDisplacement, %{result | degraded: degrade_reason(result.degraded)})
  end

  defp degrade_reason(nil), do: nil
  defp degrade_reason("before_coverage"), do: :before_coverage
  defp degrade_reason("after_coverage"), do: :after_coverage

  @doc "Evaluate station displacement at each epoch under a selected validity mode."
  @spec station_displacement_batch_with_validity(map(), [map()], validity_mode(), keyword() | map()) ::
          {:ok, [station_displacement_row()]}
  def station_displacement_batch_with_validity(position, epochs, validity, opts \\ [])

  def station_displacement_batch_with_validity(position, epochs, validity, opts)
      when validity in [:strict, :permissive] do
    station_displacement_batch(position, epochs, Map.put(normalize_options(opts), :validity, validity))
  end

  def station_displacement_batch_with_validity(_position, _epochs, _validity, _opts),
    do: {:error, :invalid_validity_mode}

  @doc "Validate and return a core tide-system label."
  @spec tide_system(TideSystem.t()) :: TideSystem.t()
  def tide_system(system) when system in [:tide_free, :zero_tide, :mean_tide], do: system

  defp request(position, epoch, opts) do
    options = normalize_options(opts)
    {position_kind, position_values} = position_values(position)

    with {:ok, second} <- finite_number(field!(epoch, :second), :second),
         {:ok, polar_motion} <- polar_motion(field(options, :polar_motion_arcsec, nil)),
         {:ok, ocean_amplitude, ocean_phase} <- ocean_loading(field(options, :ocean_loading, nil)),
         {:ok, tide_constants} <- constants(field(options, :solid_earth_tide_constants, :conventions)),
         {:ok, validity} <- validity(field(options, :validity, :strict)) do
      {:ok,
       %{
         position_kind: position_kind,
         position: position_values,
         year: integer!(epoch, :year),
         month: integer!(epoch, :month),
         day: integer!(epoch, :day),
         hour: integer!(epoch, :hour),
         minute: integer!(epoch, :minute),
         second: second,
         polar_motion_arcsec: polar_motion,
         solid_earth_tide: field(options, :solid_earth_tide, true),
         pole_tide: field(options, :pole_tide, false),
         ocean_loading_amplitude_m: ocean_amplitude,
         ocean_loading_phase_deg: ocean_phase,
         tide_constants: tide_constants,
         validity: validity
       }}
    end
  rescue
    error in ArgumentError -> {:error, {:invalid_input, Exception.message(error)}}
  end

  defp position_values(%{position_ecef_m: values}), do: {"ecef", vec3!(values, :position_ecef_m)}
  defp position_values(%{ecef_m: values}), do: {"ecef", vec3!(values, :ecef_m)}

  defp position_values(%{lat_rad: latitude, lon_rad: longitude, height_m: height}) do
    {"geodetic", Enum.map([latitude, longitude, height], &number!/1)}
  end

  defp position_values(_), do: raise(ArgumentError, "position must be ECEF or geodetic coordinates")

  defp polar_motion(nil), do: {:ok, nil}
  defp polar_motion(values), do: {:ok, vec2!(values, :polar_motion_arcsec)}

  defp ocean_loading(nil), do: {:ok, nil, nil}

  defp ocean_loading(%{amplitude_m: amplitude, phase_deg: phase}) do
    {:ok, matrix!(amplitude, 3, 11, :amplitude_m), matrix!(phase, 3, 11, :phase_deg)}
  end

  defp ocean_loading(_), do: {:error, :invalid_ocean_loading}

  defp constants(:conventions), do: {:ok, "conventions"}
  defp constants(:iers_routine), do: {:ok, "iers_routine"}
  defp constants(%StationTideConstants{variant: variant}), do: constants(variant)
  defp constants(_), do: {:error, :invalid_tide_constants}

  defp validity(:strict), do: {:ok, "strict"}
  defp validity(:permissive), do: {:ok, "permissive"}
  defp validity(_), do: {:error, :invalid_validity_mode}

  defp normalize_options(options) when is_list(options), do: Map.new(options)
  defp normalize_options(options) when is_map(options), do: options

  defp vec3!(values, field), do: fixed_values!(values, 3, field)
  defp vec2!(values, field), do: fixed_values!(values, 2, field)

  defp matrix!(rows, row_count, column_count, field) when is_list(rows) do
    if length(rows) == row_count and Enum.all?(rows, &(is_list(&1) and length(&1) == column_count)) do
      Enum.map(rows, fn row -> Enum.map(row, &number!/1) end)
    else
      raise ArgumentError, "#{field} must be a #{row_count}x#{column_count} matrix"
    end
  end

  defp fixed_values!(values, expected, field) do
    values = if is_tuple(values), do: Tuple.to_list(values), else: values

    if length(values) == expected,
      do: Enum.map(values, &number!/1),
      else: raise(ArgumentError, "#{field} must have #{expected} values")
  end

  defp finite_number(value, _field) when is_number(value) do
    normalized = value / 1.0
    if is_finite(normalized), do: {:ok, normalized}, else: {:error, :non_finite}
  rescue
    ArithmeticError -> {:error, :out_of_range}
  end

  defp finite_number(_value, _field), do: {:error, :invalid_number}

  defp number!(value) when is_number(value) do
    normalized = value / 1.0
    if is_finite(normalized), do: normalized, else: raise(ArgumentError, "number must be finite")
  rescue
    ArithmeticError -> raise ArgumentError, "number is outside binary64 range"
  end

  defp number!(_), do: raise(ArgumentError, "expected a number")
  defp integer!(map, key) when is_map(map), do: map |> field!(key) |> integer_value!()
  defp integer!(list, key) when is_list(list), do: list |> Keyword.fetch!(key) |> integer_value!()
  defp integer_value!(value) when is_integer(value), do: value
  defp integer_value!(_), do: raise(ArgumentError, "calendar fields must be integers")

  defp field!(map, key) when is_map(map), do: Map.fetch!(map, key)
  defp field!(list, key) when is_list(list), do: Keyword.fetch!(list, key)
  defp field(map, key, default) when is_map(map), do: Map.get(map, key, default)
  defp field(list, key, default) when is_list(list), do: Keyword.get(list, key, default)

  defp is_finite(value), do: value == value and value not in [:infinity, :neg_infinity]
end
