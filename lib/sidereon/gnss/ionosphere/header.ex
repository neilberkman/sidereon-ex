defmodule Sidereon.GNSS.Ionosphere.Header do
  @moduledoc """
  The descriptive IONEX header records a product carries.

  The records a product's grid determines (`EPOCH OF FIRST MAP`,
  `EPOCH OF LAST MAP`, `MAP DIMENSION`) are derived by the reader and writer and
  are not held here. `# OF MAPS IN FILE` is held as the file wrote it, because
  IONEX 1 describes it as the total TEC/RMS/height map count while producers
  write the TEC map count, and a product written back carries the one it came
  with.

  ## Mapping function

  `mapping_function` distinguishes a product that declares no
  `MAPPING FUNCTION` record from one that declares a code:

    * `nil` - the product carries no `MAPPING FUNCTION` record.
    * `:none`, `:cosz`, `:qfac` - the three codes IONEX 1 names.
    * a string - any other code, kept exactly as written. `""` is a declared
      blank code, which is a different statement from `nil`.

  A field left at its struct default reads as the value IONEX 1 gives for an
  unstated record: version `1.0`, blank text fields, no descriptions or
  comments, an `INTERVAL` of `0` (may vary), an `ELEVATION CUTOFF` of `0.0`
  (unknown), and no station, satellite or map count.

  ## What is refused

    * `{:invalid_header_field, field, value}` - a field whose value is not of the
      field's type, such as a count that is not an integer or a description list
      holding something other than strings.
    * `{:value_out_of_range, field, value}` - a count outside `0..4294967295`,
      the unsigned 32-bit range `INTERVAL`, `# OF STATIONS`, `# OF SATELLITES`
      and `# OF MAPS IN FILE` cross the boundary in, or a version or elevation
      cutoff that is an integer larger in magnitude than the largest finite
      double, which has no double to be read onto. The offending value is
      returned as given.
    * `{:invalid_mapping_function, value}` - a mapping function that is neither
      `nil`, one of the three atoms, nor a string.

  A mapping code is carried to the product exactly as given. Writing it back out
  as text is a separate, fallible step: `Sidereon.GNSS.Ionosphere.ionex_to_string/1`
  refuses a code the reader would not read back as itself, such as `""` or a
  code longer than four characters, rather than writing something else. Such a
  code is held and read back unchanged until a caller asks for text.
  """

  alias Sidereon.GNSS.Ionosphere.Numeric

  defstruct version: 1.0,
            satellite_system: "",
            program: "",
            run_by: "",
            date: "",
            descriptions: [],
            comments: [],
            interval_s: 0,
            mapping_function: nil,
            elevation_cutoff_deg: 0.0,
            observables_used: "",
            station_count: nil,
            satellite_count: nil,
            maps_in_file: nil

  @type mapping_function :: :none | :cosz | :qfac | String.t() | nil

  @type t :: %__MODULE__{
          version: float(),
          satellite_system: String.t(),
          program: String.t(),
          run_by: String.t(),
          date: String.t(),
          descriptions: [String.t()],
          comments: [String.t()],
          interval_s: non_neg_integer(),
          mapping_function: mapping_function(),
          elevation_cutoff_deg: float(),
          observables_used: String.t(),
          station_count: non_neg_integer() | nil,
          satellite_count: non_neg_integer() | nil,
          maps_in_file: non_neg_integer() | nil
        }

  @known_codes [:none, :cosz, :qfac]

  @u32_max 4_294_967_295

  @doc """
  A header declaring `mapping_function`, with every other record at the value
  IONEX 1 gives for an unstated one.

  Pass `nil` to declare no `MAPPING FUNCTION` record at all. `opts` sets any of
  the other records.
  """
  @spec new(mapping_function(), keyword()) :: t()
  def new(mapping_function \\ nil, opts \\ []) do
    struct!(__MODULE__, Keyword.put(opts, :mapping_function, mapping_function))
  end

  @doc false
  @spec to_nif_map(t()) :: {:ok, map()} | {:error, term()}
  def to_nif_map(%__MODULE__{} = header) do
    with {:ok, mapping_function} <- mapping_function(header.mapping_function),
         {:ok, version} <- number(header.version, :version),
         {:ok, cutoff} <- number(header.elevation_cutoff_deg, :elevation_cutoff_deg),
         {:ok, descriptions} <- strings(header.descriptions, :descriptions),
         {:ok, comments} <- strings(header.comments, :comments),
         {:ok, satellite_system} <- string(header.satellite_system, :satellite_system),
         {:ok, program} <- string(header.program, :program),
         {:ok, run_by} <- string(header.run_by, :run_by),
         {:ok, date} <- string(header.date, :date),
         {:ok, observables_used} <- string(header.observables_used, :observables_used),
         {:ok, interval_s} <- count(header.interval_s, :interval_s),
         {:ok, station_count} <- optional_count(header.station_count, :station_count),
         {:ok, satellite_count} <- optional_count(header.satellite_count, :satellite_count),
         {:ok, maps_in_file} <- optional_count(header.maps_in_file, :maps_in_file) do
      {:ok,
       %{
         version: version,
         satellite_system: satellite_system,
         program: program,
         run_by: run_by,
         date: date,
         descriptions: descriptions,
         comments: comments,
         interval_s: interval_s,
         mapping_function: mapping_function,
         elevation_cutoff_deg: cutoff,
         observables_used: observables_used,
         station_count: station_count,
         satellite_count: satellite_count,
         maps_in_file: maps_in_file
       }}
    end
  end

  def to_nif_map(_other), do: {:error, :bad_ionex_header}

  @doc false
  @spec from_nif_map(map()) :: t()
  def from_nif_map(fields) when is_map(fields), do: struct!(__MODULE__, fields)

  # A declared code is passed through exactly as given; `nil` is the absent
  # declaration, which no blank string stands in for.
  defp mapping_function(nil), do: {:ok, nil}
  defp mapping_function(code) when code in @known_codes, do: {:ok, code}
  defp mapping_function(code) when is_binary(code), do: {:ok, code}
  defp mapping_function(other), do: {:error, {:invalid_mapping_function, other}}

  defp number(value, field) do
    case Numeric.float(value) do
      {:ok, float} -> {:ok, float}
      {:out_of_range, value} -> {:error, {:value_out_of_range, field, value}}
      :not_a_number -> {:error, {:invalid_header_field, field, value}}
    end
  end

  # The counts cross as `u32`. A non-integer is a typed field failure and an
  # integer outside the range is a named range failure carrying the value, so
  # neither arrives as an opaque decode error from the boundary. `u32` is not a
  # range `Numeric` names, since no other IONEX field crosses in it.
  defp count(value, _field) when is_integer(value) and value >= 0 and value <= @u32_max do
    {:ok, value}
  end

  defp count(value, field) when is_integer(value), do: {:error, {:value_out_of_range, field, value}}
  defp count(value, field), do: {:error, {:invalid_header_field, field, value}}

  defp optional_count(nil, _field), do: {:ok, nil}
  defp optional_count(value, field), do: count(value, field)

  defp string(value, _field) when is_binary(value), do: {:ok, value}
  defp string(value, field), do: {:error, {:invalid_header_field, field, value}}

  defp strings(values, field) when is_list(values) do
    if Enum.all?(values, &is_binary/1) do
      {:ok, values}
    else
      {:error, {:invalid_header_field, field, values}}
    end
  end

  defp strings(values, field), do: {:error, {:invalid_header_field, field, values}}
end
