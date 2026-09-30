defmodule Sidereon.GNSS.RINEX.Clock do
  @moduledoc """
  RINEX clock (`.CLK`) products: lossless reading, typed views, editing,
  writing and satellite clock-bias interpolation.

  Precise clock products are distributed as RINEX clock files alongside the SP3
  orbit. The SP3 orbit carries satellite clocks too, but only at the SP3 epoch
  spacing (15 minutes for IGS final), whereas the companion `.CLK` file carries
  the same clocks at a much finer cadence (30 seconds for IGS final). Linearly
  interpolating a 15-minute clock across the gap is a metre-level error on the
  faster satellite oscillators; the 30s clock removes almost all of it.

  ## The product keeps its text

  A product read from text keeps the text as its authority: every header line
  with its exact label and payload, and every body line in order, including
  blank lines, `AR`, `AS`, `CR`, `DR` and `MS` records, continuation lines and,
  after `parse_lossy/1`, the lines that do not read as a record.
  `to_rinex_string/1` restates an unedited product byte for byte. The views are
  derived from those lines:

    * `header_records/1` - every header line with its exact text and typed
      reading (`Sidereon.GNSS.RINEX.Clock.HeaderRecord`),
    * `records/1` - every data record with its type, name, civil epoch, instant,
      declared values, surplus values and how it was read
      (`Sidereon.GNSS.RINEX.Clock.Record`),
    * `series/1` - the per-satellite series of `AS` records whose epoch resolves
      to an instant, with every declared value (`Sidereon.GNSS.RINEX.Clock.Point`),
    * `skipped_records/1`, `diagnostics/1` and `notices/1` - records outside
      the satellite series, lines a lossy read kept without reading, and
      findings that do not stop a read,
    * `version/1`, `layout/1`, `satellite_system/1`, `time_system/1`,
      `time_system_status/1` and `time_scale/1` - the header facts. `time_scale`
      is `nil` when the time system is missing, unrecognised, conflicting or has
      no core scale (`IRN`); record epochs then keep their civil fields with no
      instant.

  `TIME SYSTEM ID` reads `GPS`, `GLO`, `GAL`, `QZS`, `BDS` (and `BDT`), `IRN`,
  `UTC` and `TAI`. `GLO` is UTC, so a `23:59:60` label on a leap-second day is an
  epoch. A file without the record takes the 3.00 default with a notice.

  The `series` field of the struct holds the GPST and QZSST samples as
  `%{satellite => [{gps_seconds, bias_s}]}`, the shape the precise-positioning
  satellite-clock option reads; `series/1` returns every sample with its
  scale-tagged epoch.

  ## Editing

  Edits never change a product: `set_time_system/2`, `set_record_values/3`,
  `insert_record/3`, `remove_record/2`, `retain_records/2` and
  `edit_records/2` return a new product, after the core has validated the
  whole change. An edit the writer would refuse, including one that would drop
  a record's surplus values, is refused and changes nothing.

  ## Writing

  `to_rinex_string/1` writes every value only when it reads back to the same
  bits and an epoch only as a seconds field that states it exactly, and refuses
  by name what it cannot state. `to_rinex_string_with_policy/2` with a
  `Sidereon.GNSS.RINEX.Clock.WritePolicy` allowing `nearest_microsecond_epochs`
  writes such an epoch at the nearest microsecond and reports each departure.
  A product built from rows is written with a header stating its version,
  satellite system, `TIME SYSTEM ID` and data types.

  ## Refusals

  Errors are `{:error, {tag, fields}}` with every field the core's error
  carries: `{:malformed_as_record, %{line, reason, record}}`,
  `{:missing_continuation, %{line, record_type}}`,
  `{:malformed_continuation, %{line, reason, record}}`,
  `{:bad_field, %{line, field, value}}`, `{:invalid_input, %{field, reason}}`
  and `{:unsupported_time_scale, %{scale}}`. An argument the boundary cannot
  carry is named before the call as `{:invalid_epoch_field, field, value}`,
  `{:value_out_of_range, field, value}` or `{:invalid_argument, field, value}`.
  """

  alias Sidereon.GNSS.Ionosphere.Epoch
  alias Sidereon.GNSS.Ionosphere.Epoch, as: Instant
  alias Sidereon.GNSS.Ionosphere.Numeric
  alias Sidereon.GNSS.RINEX.Clock.CivilEpoch
  alias Sidereon.GNSS.RINEX.Clock.Diagnostic
  alias Sidereon.GNSS.RINEX.Clock.HeaderRecord
  alias Sidereon.GNSS.RINEX.Clock.Point
  alias Sidereon.GNSS.RINEX.Clock.Record
  alias Sidereon.GNSS.RINEX.Clock.Skip
  alias Sidereon.GNSS.RINEX.Clock.WritePolicy
  alias Sidereon.NIF
  alias Sidereon.NifCall

  defstruct [:handle, trailing_suffixes: %{}, series: %{}]

  @type time_system :: :gps | :glo | :gal | :qzs | :bds | :irn | :utc | :tai
  @type t :: %__MODULE__{
          handle: reference() | nil,
          trailing_suffixes: %{non_neg_integer() => {binary(), non_neg_integer()}},
          series: %{String.t() => [{float(), float()}]}
        }
  @type civil_epoch ::
          NaiveDateTime.t() | CivilEpoch.t() | {{integer(), integer(), integer()}, {integer(), integer(), number()}}

  @time_systems [:gps, :glo, :gal, :qzs, :bds, :irn, :utc, :tai]
  @record_types [:ar, :as, :cr, :dr, :ms]
  @usize_limit Integer.pow(2, :erlang.system_info(:wordsize) * 8)

  defmodule CivilEpoch do
    @moduledoc """
    A civil epoch in a product's time scale. `second` carries the fraction; on a
    UTC product it may be `60.x` on a day that ends with a positive leap second.
    """
    @enforce_keys [:year, :month, :day, :hour, :minute, :second]
    defstruct [:year, :month, :day, :hour, :minute, :second]

    @type t :: %__MODULE__{
            year: integer(),
            month: integer(),
            day: integer(),
            hour: integer(),
            minute: integer(),
            second: float()
          }
  end

  defmodule Point do
    @moduledoc """
    One satellite clock-bias sample: its scale-tagged epoch
    (`Sidereon.GNSS.Ionosphere.Epoch`), the bias in seconds, and the further
    declared values in Table A16 order (bias sigma, rate, rate sigma,
    acceleration, acceleration sigma).
    """
    @enforce_keys [:epoch, :bias_s]
    defstruct [:epoch, :bias_s, additional_values: []]

    @type t :: %__MODULE__{
            epoch: Epoch.t(),
            bias_s: float(),
            additional_values: [float()]
          }
  end

  defmodule Record do
    @moduledoc """
    One data record with its typed reading.

    `record_type` is `:ar`, `:as`, `:cr`, `:dr` or `:ms`; `satellite` is the
    canonical identifier of an `AS` record and `nil` otherwise. `civil_epoch`
    keeps the epoch fields, its `second` the nearest double to every digit the
    seconds field states; `epoch` is the instant in the product's time scale,
    `nil` when the time system resolves to no scale. `values` are the declared
    values, bias first; `surplus_values` are values present beyond the declared
    count as `%{position: index, value: value}`. `line` is the one-based line of
    the record in the source (`nil` for a record built or edited through the
    API) and `line_count` the lines it spans. `reading` and
    `continuation_reading` say how the first and continuation lines were read:
    `{:columns, :v300 | :v304}`, `{:columns_trailing_text, :v300 | :v304}`,
    `:whitespace` or `:edited`. The trailing suffix itself remains retained by
    the core when declared values are edited and the product is written;
    `trailing_text_bytes` and zero-based `trailing_text_column` expose it on the
    record and survive value edits.
    """
    @enforce_keys [:record_type, :name, :civil_epoch, :values]
    defstruct [
      :record_type,
      :name,
      :satellite,
      :civil_epoch,
      :epoch,
      :values,
      :line,
      :reading,
      :continuation_reading,
      surplus_values: [],
      trailing_text_bytes: nil,
      trailing_text_column: nil,
      line_count: 0
    ]

    @type reading ::
            {:columns, :v300 | :v304}
            | {:columns_trailing_text, :v300 | :v304}
            | :whitespace
            | :edited
            | {:other, String.t()}

    @type t :: %__MODULE__{
            record_type: :ar | :as | :cr | :dr | :ms,
            name: String.t(),
            satellite: String.t() | nil,
            civil_epoch: CivilEpoch.t(),
            epoch: Epoch.t() | nil,
            values: [float()],
            surplus_values: [%{position: non_neg_integer(), value: float()}],
            line: pos_integer() | nil,
            line_count: non_neg_integer(),
            reading: reading() | nil,
            continuation_reading: reading() | nil,
            trailing_text_bytes: binary() | nil,
            trailing_text_column: non_neg_integer() | nil
          }
  end

  defmodule HeaderRecord do
    @moduledoc """
    One header line with its exact text and typed reading.

    `field` is the typed reading, `nil` when the fields do not read: a
    `{tag, fields}` pair such as `{:version_type, %{version, file_type,
    satellite_system}}`, `{:time_system, %{label}}`, `{:types_of_data, %{count,
    types}}`, `{:solution_station, %{name, identifier, xyz_mm}}` or
    `{:clock_ref_count, %{count, start, stop}}`; the value itself for a
    single-valued record (`{:comment, text}`, `{:leap_seconds, n}`,
    `{:prn_list, satellites}`); or `:end_of_header`. `reading` is `:columns`,
    `:other_version_columns`, `:whitespace`, `:uninterpreted` or
    `:unknown_label`.
    """
    @enforce_keys [:text, :label, :label_column, :payload, :reading]
    defstruct [:line, :text, :label, :label_column, :payload, :field, :reading]

    @type t :: %__MODULE__{
            line: pos_integer() | nil,
            text: String.t(),
            label: String.t(),
            label_column: non_neg_integer(),
            payload: String.t(),
            field: term(),
            reading: atom()
          }
  end

  defmodule Skip do
    @moduledoc "A record read from the source that is not in the satellite series (`AR`, `CR`, `DR`, `MS`)."
    @enforce_keys [:line, :record_type]
    defstruct [:line, :record_type]
    @type t :: %__MODULE__{line: pos_integer(), record_type: String.t()}
  end

  defmodule Diagnostic do
    @moduledoc "A line a lossy read kept without reading it, or a header time-system error, with its typed error."
    @enforce_keys [:line, :error]
    defstruct [:line, :error]
    @type t :: %__MODULE__{line: pos_integer(), error: term()}
  end

  defmodule WritePolicy do
    @moduledoc """
    Which departures from what a product states the writer may emit.

    `nearest_microsecond_epochs: :allow` writes an epoch no microsecond text
    states exactly at the nearest microsecond and reports it; `:strict`, the
    default, refuses it. Values are never approximated under any policy.
    """
    defstruct nearest_microsecond_epochs: :strict
    @type t :: %__MODULE__{nearest_microsecond_epochs: :strict | :allow}
  end

  @doc """
  Load a RINEX clock file, raising on error.
  """
  @spec load!(String.t()) :: t()
  def load!(path) when is_binary(path), do: bang(load(path), path)

  @doc """
  Load a RINEX clock file keeping unreadable lines with diagnostics, raising on
  file errors.
  """
  @spec load_lossy!(String.t()) :: t()
  def load_lossy!(path) when is_binary(path), do: bang(load_lossy(path), path)

  @doc """
  Load a RINEX clock file strictly. See `parse/1`.
  """
  @spec load(String.t()) :: {:ok, t()} | {:error, term()}
  def load(path) when is_binary(path) do
    with {:ok, contents} <- File.read(path), do: parse(contents)
  end

  @doc """
  Load a RINEX clock file keeping unreadable lines with diagnostics. See
  `parse_lossy/1`.
  """
  @spec load_lossy(String.t()) :: {:ok, t()} | {:error, term()}
  def load_lossy(path) when is_binary(path) do
    with {:ok, contents} <- File.read(path), do: parse_lossy(contents)
  end

  @doc """
  Parse RINEX clock text, failing on the first line that does not read.

  Records are read at the columns of the file's declared version (the
  80-column layout before 3.04, the 85-column layout from 3.04), then at the
  other version's columns, then as whitespace-separated values; each record
  reports how it was read.
  """
  @spec parse(binary()) :: {:ok, t()} | {:error, term()}
  def parse(contents) when is_binary(contents) do
    product(NIF.rinex_clock_parse(contents))
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :rinex_clock_parse)
  end

  @doc """
  Parse RINEX clock text keeping every line that does not read verbatim with a
  diagnostic (`diagnostics/1`). Nothing is dropped: `to_rinex_string/1` on the
  result restates the input exactly.
  """
  @spec parse_lossy(binary()) :: {:ok, t()} | {:error, term()}
  def parse_lossy(contents) when is_binary(contents) do
    product(NIF.rinex_clock_parse_lossy(contents))
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :rinex_clock_parse_lossy)
  end

  @doc """
  Build a GPST product from `%{satellite => [{gps_seconds, bias_s}]}` (or a list
  of `{satellite, rows}`). Each satellite's seconds must be strictly
  increasing; seconds outside the civil years 1 through 9999 are refused.
  """
  @spec from_series_rows(map() | [{String.t(), [{number(), number()}]}]) :: {:ok, t()} | {:error, term()}
  def from_series_rows(rows) when is_map(rows) or is_list(rows) do
    with {:ok, rows} <- series_row_terms(rows) do
      product(NIF.rinex_clock_from_series_rows(rows))
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :rinex_clock_from_series_rows)
  end

  @doc """
  Build a product in `time_scale` (a core scale abbreviation such as `"GPST"`,
  `"UTC"` or `"BDT"`) from `%{satellite => [%Point{}]}` (or a list of
  `{satellite, points}`), keeping every declared value of each point.

  The writer writes QZSST and BDT products as 3.04 and the others as 3.00, and
  refuses a scale no RINEX clock time system names (GLONASS system time among
  them, since `GLO` names UTC hours) as `{:unsupported_time_scale, %{scale}}`.
  """
  @spec from_clock_points(String.t(), map() | [{String.t(), [Point.t()]}]) :: {:ok, t()} | {:error, term()}
  def from_clock_points(time_scale, rows) when is_binary(time_scale) and (is_map(rows) or is_list(rows)) do
    with {:ok, rows} <- point_row_terms(rows) do
      product(NIF.rinex_clock_from_clock_points(time_scale, rows))
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :rinex_clock_from_clock_points)
  end

  @doc "Declared format version; for a product built from rows, the version it is written in."
  @spec version(t()) :: float() | nil
  def version(clock), do: info(clock).version

  @doc "Column layout records are read and written in: `:v300`, `:v304` or `nil`."
  @spec layout(t()) :: :v300 | :v304 | nil
  def layout(clock), do: info(clock).layout

  @doc "Satellite system code of the `RINEX VERSION / TYPE` record, when one is written."
  @spec satellite_system(t()) :: String.t() | nil
  def satellite_system(clock), do: info(clock).satellite_system

  @doc "The product's time system, when one is declared, defaulted or built in."
  @spec time_system(t()) :: time_system() | nil
  def time_system(clock), do: info(clock).time_system

  @doc """
  How the time system was established: `:declared`, `:defaulted`,
  `{:unrecognized, label}`, `{:conflicting, labels}` or `:constructed`.
  """
  @spec time_system_status(t()) :: term()
  def time_system_status(clock), do: info(clock).time_system_status

  @doc """
  The core time scale record epochs are interpreted in (`"GPST"`, `"UTC"`, ...),
  or `nil` when the time system does not resolve to one.
  """
  @spec time_scale(t()) :: String.t() | nil
  def time_scale(clock), do: info(clock).time_scale

  @doc "Number of data records."
  @spec record_count(t()) :: non_neg_integer()
  def record_count(clock), do: info(clock).record_count

  @doc """
  The header facts in one map: `version`, `layout`, `satellite_system`,
  `time_system`, `time_system_status`, `time_scale` and `record_count`.
  """
  @spec info(t()) :: map()
  def info(clock), do: view(clock, &NIF.rinex_clock_info/1)

  @doc "Every data record in order, including repeated records for one name and epoch."
  @spec records(t()) :: [Record.t()]
  def records(%__MODULE__{} = clock) do
    clock
    |> view(&NIF.rinex_clock_records/1)
    |> Enum.with_index()
    |> Enum.map(fn {fields, index} -> record(fields, Map.get(clock.trailing_suffixes, index)) end)
  end

  @doc "Every header line in order with its typed reading. A product built from rows has none."
  @spec header_records(t()) :: [HeaderRecord.t()]
  def header_records(clock) do
    clock
    |> view(&NIF.rinex_clock_header_records/1)
    |> Enum.map(fn fields -> struct!(HeaderRecord, %{fields | field: header_field(fields.field)}) end)
  end

  @doc """
  The per-satellite series of `AS` records whose epoch resolves to an instant,
  each strictly time-ordered, with scale-tagged epochs and every declared value.
  Where records repeat one satellite and instant, the last in file order is the
  sample; every such record remains in `records/1`.
  """
  @spec series(t()) :: %{String.t() => [Point.t()]}
  def series(clock) do
    clock
    |> view(&NIF.rinex_clock_series/1)
    |> Map.new(fn {satellite, points} -> {satellite, Enum.map(points, &point/1)} end)
  end

  @doc "The GPST and QZSST samples as `%{satellite => [{gps_seconds, bias_s}]}`."
  @spec series_rows(t()) :: %{String.t() => [{float(), float()}]}
  def series_rows(%__MODULE__{series: series}), do: series

  @doc "Records read from the source that are not in the satellite series."
  @spec skipped_records(t()) :: [Skip.t()]
  def skipped_records(clock) do
    clock |> view(&NIF.rinex_clock_skipped_records/1) |> Enum.map(&struct!(Skip, &1))
  end

  @doc "Lines a lossy read kept without reading them as records, and header time-system errors."
  @spec diagnostics(t()) :: [Diagnostic.t()]
  def diagnostics(clock) do
    clock |> view(&NIF.rinex_clock_diagnostics/1) |> Enum.map(&struct!(Diagnostic, &1))
  end

  @doc """
  Findings about how the product was read that do not stop it being read, such
  as `{:time_system_defaulted, %{system}}`, `:time_system_missing`,
  `{:surplus_values, %{records, first_line}}` or
  `{:whitespace_records, %{records, first_line}}` and
  `{:trailing_text_records, %{records, first_line}}`.
  """
  @spec notices(t()) :: [term()]
  def notices(clock), do: view(clock, &NIF.rinex_clock_notices/1)

  @doc "One line of the source text by one-based line number, without its terminator, or `nil`."
  @spec source_line(t(), pos_integer()) :: String.t() | nil
  def source_line(clock, line) when is_integer(line) and line >= 0 and line < @usize_limit do
    view(clock, &NIF.rinex_clock_source_line(&1, line))
  end

  def source_line(_clock, _line), do: nil

  @doc """
  Interpolated satellite clock bias in seconds at `epoch`.

  `epoch` is a civil epoch in the product's time scale (a `NaiveDateTime`, a
  `Sidereon.GNSS.RINEX.Clock.CivilEpoch` or a `{{y, m, d}, {h, min, s}}` tuple
  whose `s` may carry a fraction and, on a UTC product, be `60.x` on a
  leap-second day) or a scale-tagged `Sidereon.GNSS.Ionosphere.Epoch`. The
  query second is read as the shortest decimal of the double given, every digit
  kept, so a query at a record's stated epoch lands on that record.

  Returns `{:ok, bias_s}` when the satellite has records bracketing the epoch
  (or an exact-match record), `{:error, :no_clock}` when the satellite is
  unknown or the epoch lies outside its record span, or `{:error, reason}` when
  the product's time system resolves to no scale or the epoch is not valid in
  it. Linear interpolation between the two nearest records, across a UTC leap
  second by elapsed time; no extrapolation.
  """
  @spec clock_s(t(), String.t(), civil_epoch() | Instant.t()) :: {:ok, float()} | {:error, term()}
  def clock_s(clock, satellite_id, %Instant{} = epoch) when is_binary(satellite_id) do
    with {:ok, term} <- Instant.to_nif_term(epoch) do
      with_handle(clock, &NIF.rinex_clock_clock_s_at_instant(&1, satellite_id, term))
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :rinex_clock_clock_s_at_instant)
  end

  def clock_s(clock, satellite_id, epoch) when is_binary(satellite_id) do
    with {:ok, civil} <- civil_term(epoch) do
      with_handle(clock, &NIF.rinex_clock_clock_s(&1, satellite_id, civil))
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :rinex_clock_clock_s)
  end

  @doc """
  Interpolated satellite clock bias at GPS seconds. GPST and QZSST series
  answer; seconds outside the civil years 1 through 9999 are refused.
  """
  @spec clock_s_at_gps_seconds(t(), String.t(), number()) :: {:ok, float()} | {:error, term()}
  def clock_s_at_gps_seconds(clock, satellite_id, gps_seconds) when is_binary(satellite_id) do
    with {:ok, seconds} <- double(gps_seconds, :gps_seconds) do
      with_handle(clock, &NIF.rinex_clock_clock_s_at_gps_seconds(&1, satellite_id, seconds))
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :rinex_clock_clock_s_at_gps_seconds)
  end

  @doc """
  A civil clock tag in `time_scale` as a scale-tagged instant, reading the
  second as `clock_s/3` does: `{:ok, epoch}` or `{:error, :invalid_epoch}`. A
  `23:59:60` label is accepted for UTC on a day that ends with a positive leap
  second; every other scale refuses it.
  """
  @spec civil_to_instant(String.t(), civil_epoch()) :: {:ok, Instant.t()} | {:error, term()}
  def civil_to_instant(time_scale, epoch) when is_binary(time_scale) do
    with {:ok, civil} <- civil_term(epoch),
         {:ok, term} <- NIF.rinex_clock_civil_to_instant(time_scale, civil) do
      {:ok, Instant.from_nif_term(term)}
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :rinex_clock_civil_to_instant)
  end

  @doc "A civil GPS-time tag as GPS seconds, reading the second as `clock_s/3` does."
  @spec civil_to_gps_seconds(civil_epoch()) :: {:ok, float()} | {:error, term()}
  def civil_to_gps_seconds(epoch) do
    with {:ok, civil} <- civil_term(epoch), do: NIF.rinex_clock_civil_to_gps_seconds(civil)
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :rinex_clock_civil_to_gps_seconds)
  end

  @doc """
  Write the product as RINEX clock text, refusing by name a value or epoch it
  cannot state exactly.
  """
  @spec to_rinex_string(t()) :: {:ok, String.t()} | {:error, term()}
  def to_rinex_string(clock) do
    with_handle(clock, &NIF.rinex_clock_to_string/1)
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :rinex_clock_to_string)
  end

  @doc """
  Write the product under a `Sidereon.GNSS.RINEX.Clock.WritePolicy`, returning
  `{:ok, %{text: text, departures: departures}}` with every departure the policy
  allowed and the writer emitted, as
  `{:epoch_at_nearest_microsecond, %{record, name, epoch, written}}`: the
  record's index in `records/1`, its name, the epoch the product holds (`nil`
  without an instant) and the epoch fields as written.
  """
  @spec to_rinex_string_with_policy(t(), WritePolicy.t()) ::
          {:ok, %{text: String.t(), departures: [term()]}} | {:error, term()}
  def to_rinex_string_with_policy(clock, %WritePolicy{nearest_microsecond_epochs: leniency})
      when leniency in [:strict, :allow] do
    case with_handle(clock, &NIF.rinex_clock_to_string_with_policy(&1, leniency)) do
      {:ok, text, departures} -> {:ok, %{text: text, departures: Enum.map(departures, &departure/1)}}
      {:error, _reason} = error -> error
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :rinex_clock_to_string_with_policy)
  end

  def to_rinex_string_with_policy(_clock, policy), do: {:error, {:invalid_argument, :policy, policy}}

  @doc """
  Write the product as RINEX clock text to `path`.
  """
  @spec write(t(), String.t()) :: :ok | {:error, term()}
  def write(%__MODULE__{} = clock, path) when is_binary(path) do
    with {:ok, text} <- to_rinex_string(clock), do: File.write(path, text)
  end

  @doc """
  Declare the product's time system (`:gps`, `:glo`, `:gal`, `:qzs`, `:bds`,
  `:irn`, `:utc` or `:tai`), replacing every `TIME SYSTEM ID` record or
  inserting one. Every record epoch is checked in the new system first; if one
  does not convert, nothing changes. A product with no header section, or built
  from rows, is refused.
  """
  @spec set_time_system(t(), time_system()) :: {:ok, t()} | {:error, term()}
  def set_time_system(clock, system) when system in @time_systems do
    clock |> with_handle(&NIF.rinex_clock_set_time_system(&1, system)) |> edited(clock.trailing_suffixes)
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :rinex_clock_set_time_system)
  end

  def set_time_system(_clock, system), do: {:error, {:invalid_argument, :time_system, system}}

  @doc """
  Replace the declared values of the record at `index` (in `records/1` order),
  bias first. The record keeps its type, name and epoch, including the exact
  text of its seconds field. An edit that would drop the record's surplus
  values, or that the writer could not state, is refused.
  """
  @spec set_record_values(t(), non_neg_integer(), [number()]) :: {:ok, t()} | {:error, term()}
  def set_record_values(clock, index, values) do
    with :ok <- index(index),
         {:ok, values} <- doubles(values, :values) do
      clock
      |> with_handle(&NIF.rinex_clock_set_record_values(&1, index, values))
      |> edited(clock.trailing_suffixes)
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :rinex_clock_set_record_values)
  end

  @doc """
  Insert a record before the record at `index`, or after the last when `index`
  is `record_count/1`.

  `record` is a map with `record_type` (`:ar`, `:as`, `:cr`, `:dr` or `:ms`),
  `name` (a satellite identifier for `:as`), `epoch` (a civil epoch as
  `clock_s/3` takes one) and `values` (the bias followed by up to five further
  values). The record must be writable in the product's layout and its epoch
  valid in the product's time scale.
  """
  @spec insert_record(t(), non_neg_integer(), map()) :: {:ok, t()} | {:error, term()}
  def insert_record(clock, index, %{record_type: record_type, name: name, epoch: epoch, values: values})
      when record_type in @record_types and is_binary(name) do
    with :ok <- index(index),
         {:ok, civil} <- civil_term(epoch),
         {:ok, values} <- doubles(values, :values) do
      record = %{record_type: record_type, name: name, epoch: civil, values: values}

      clock
      |> with_handle(&NIF.rinex_clock_insert_record(&1, index, record))
      |> edited(shift_suffixes(clock.trailing_suffixes, index, 1))
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :rinex_clock_insert_record)
  end

  def insert_record(_clock, _index, record), do: {:error, {:invalid_argument, :record, record}}

  @doc """
  Remove the record at `index` with every line it spans, returning
  `{:ok, {clock, removed_record}}`.
  """
  @spec remove_record(t(), non_neg_integer()) :: {:ok, {t(), Record.t()}} | {:error, term()}
  def remove_record(clock, index) do
    with :ok <- index(index) do
      case with_handle(clock, &NIF.rinex_clock_remove_record(&1, index)) do
        {:ok, handle, rows, removed} ->
          suffixes = remove_suffix_index(clock.trailing_suffixes, index)
          {:ok, {from_handle(handle, rows, suffixes), record(removed)}}

        {:error, _reason} = error ->
          error
      end
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :rinex_clock_remove_record)
  end

  @doc """
  Keep the records `keep` accepts (a truthy result) and remove every other,
  with every line it spans, in one pass; returns `{:ok, {clock, removed_count}}`.
  Blank and unread lines stay.
  """
  @spec retain_records(t(), (Record.t() -> as_boolean(term()))) :: {:ok, {t(), non_neg_integer()}} | {:error, term()}
  def retain_records(clock, keep) when is_function(keep, 1) do
    flags = clock |> records() |> Enum.map(&(keep.(&1) not in [nil, false]))

    case with_handle(clock, &NIF.rinex_clock_retain_records(&1, flags)) do
      {:ok, handle, rows, removed} ->
        suffixes = retain_suffixes(clock.trailing_suffixes, flags)
        {:ok, {from_handle(handle, rows, suffixes), removed}}

      {:error, _reason} = error ->
        error
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :rinex_clock_retain_records)
  end

  @doc """
  Replace the declared values of every record for which `edit` returns a list
  of values (bias first), in one pass; `nil` leaves a record unchanged. The
  whole batch is checked before anything changes: if one edit is refused, none
  is applied. Returns `{:ok, {clock, edited_count}}`.
  """
  @spec edit_records(t(), (Record.t() -> [number()] | nil)) :: {:ok, {t(), non_neg_integer()}} | {:error, term()}
  def edit_records(clock, edit) when is_function(edit, 1) do
    with {:ok, entries} <- edit_entries(records(clock), edit) do
      case with_handle(clock, &NIF.rinex_clock_edit_records(&1, entries)) do
        {:ok, handle, rows, count} -> {:ok, {from_handle(handle, rows, clock.trailing_suffixes), count}}
        {:error, _reason} = error -> error
      end
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :rinex_clock_edit_records)
  end

  # --- handles ----------------------------------------------------------------

  # A product with a handle is read through it; a struct holding only GPS-second
  # rows is built into a GPST product first.
  defp handle(%__MODULE__{handle: handle}) when is_reference(handle), do: {:ok, handle}

  defp handle(%__MODULE__{series: series}) do
    with {:ok, %__MODULE__{handle: handle}} <- from_series_rows(series), do: {:ok, handle}
  end

  # For a call whose contract is `{:ok, _} | {:error, _}`: rows that build no
  # product are that call's error.
  defp with_handle(clock, fun) do
    with {:ok, handle} <- handle(clock), do: fun.(handle)
  end

  # For a view, which has no error of its own to return: rows that build no
  # product are the caller's mistake.
  defp view(clock, fun) do
    case handle(clock) do
      {:ok, handle} -> fun.(handle)
      {:error, reason} -> raise ArgumentError, "RINEX clock rows build no product: #{inspect(reason)}"
    end
  end

  defp product({:ok, handle, rows}), do: {:ok, from_handle(handle, rows)}
  defp product({:error, _reason} = error), do: error

  defp edited({:ok, handle, rows}, suffixes), do: {:ok, from_handle(handle, rows, suffixes)}
  defp edited({:error, _reason} = error, _suffixes), do: error

  defp from_handle(handle, rows, suffixes \\ nil) do
    retained =
      if is_nil(suffixes) do
        handle
        |> NIF.rinex_clock_records()
        |> Enum.with_index()
        |> Enum.reduce(%{}, fn {fields, index}, acc ->
          case {fields.trailing_text_bytes, fields.trailing_text_column} do
            {bytes, column} when is_binary(bytes) and is_integer(column) ->
              Map.put(acc, index, {bytes, column})

            _ ->
              acc
          end
        end)
      else
        suffixes
      end

    %__MODULE__{handle: handle, series: Map.new(rows), trailing_suffixes: retained}
  end

  defp shift_suffixes(suffixes, index, delta) do
    Map.new(suffixes, fn {position, suffix} ->
      {if(position >= index, do: position + delta, else: position), suffix}
    end)
  end

  defp remove_suffix_index(suffixes, index) do
    suffixes
    |> Enum.reject(fn {position, _suffix} -> position == index end)
    |> Map.new(fn {position, suffix} -> {if(position > index, do: position - 1, else: position), suffix} end)
  end

  defp retain_suffixes(suffixes, flags) do
    flags
    |> Enum.with_index()
    |> Enum.reduce({%{}, 0}, fn {keep?, old_index}, {acc, new_index} ->
      if keep? do
        next =
          case Map.fetch(suffixes, old_index) do
            {:ok, suffix} -> Map.put(acc, new_index, suffix)
            :error -> acc
          end

        {next, new_index + 1}
      else
        {acc, new_index}
      end
    end)
    |> elem(0)
  end

  defp bang({:ok, clock}, _path), do: clock
  defp bang({:error, reason}, path), do: raise(ArgumentError, "could not load RINEX clock #{path}: #{inspect(reason)}")

  # --- terms ------------------------------------------------------------------

  defp series_row_terms(rows) do
    collect(rows, fn
      {satellite, points} when is_binary(satellite) and is_list(points) ->
        with {:ok, points} <- collect(points, &series_row_point/1), do: {:ok, {satellite, points}}

      other ->
        {:error, {:invalid_argument, :series, other}}
    end)
  end

  defp series_row_point({gps_seconds, bias_s}) do
    with {:ok, gps_seconds} <- double(gps_seconds, :gps_seconds),
         {:ok, bias_s} <- double(bias_s, :bias_s) do
      {:ok, {gps_seconds, bias_s}}
    end
  end

  defp series_row_point(other), do: {:error, {:invalid_argument, :series, other}}

  defp point_row_terms(rows) do
    collect(rows, fn
      {satellite, points} when is_binary(satellite) and is_list(points) ->
        with {:ok, points} <- collect(points, &point_term/1), do: {:ok, {satellite, points}}

      other ->
        {:error, {:invalid_argument, :rows, other}}
    end)
  end

  defp point_term(%Point{epoch: %Instant{} = epoch, bias_s: bias_s, additional_values: additional}) do
    with {:ok, epoch} <- Instant.to_nif_term(epoch),
         {:ok, bias_s} <- double(bias_s, :bias_s),
         {:ok, additional} <- doubles(additional, :additional_values) do
      {:ok, %{epoch: epoch, bias_s: bias_s, additional_values: additional}}
    end
  end

  defp point_term(other), do: {:error, {:invalid_argument, :point, other}}

  # A civil epoch as the fields the boundary carries: a 32-bit year, byte-sized
  # date and clock fields and a double second. Whether the epoch is valid is the
  # product's time scale's question, answered by the core.
  defp civil_term(%NaiveDateTime{microsecond: {microsecond, _precision}} = ndt) do
    second = String.to_float("#{ndt.second}.#{String.pad_leading(Integer.to_string(microsecond), 6, "0")}")
    civil_term({{ndt.year, ndt.month, ndt.day}, {ndt.hour, ndt.minute, second}})
  end

  defp civil_term(%CivilEpoch{} = epoch) do
    civil_term({{epoch.year, epoch.month, epoch.day}, {epoch.hour, epoch.minute, epoch.second}})
  end

  defp civil_term({{year, month, day}, {hour, minute, second}}) do
    with :ok <- i32(year, :year),
         :ok <- u8(month, :month),
         :ok <- u8(day, :day),
         :ok <- u8(hour, :hour),
         :ok <- u8(minute, :minute),
         {:ok, second} <- epoch_second(second) do
      {:ok, %{year: year, month: month, day: day, hour: hour, minute: minute, second: second}}
    end
  end

  defp civil_term(other), do: {:error, {:invalid_argument, :epoch, other}}

  defp i32(value, field) do
    cond do
      Numeric.i32?(value) -> :ok
      is_integer(value) -> {:error, {:value_out_of_range, field, value}}
      true -> {:error, {:invalid_epoch_field, field, value}}
    end
  end

  defp u8(value, _field) when is_integer(value) and value >= 0 and value <= 255, do: :ok
  defp u8(value, field) when is_integer(value), do: {:error, {:value_out_of_range, field, value}}
  defp u8(value, field), do: {:error, {:invalid_epoch_field, field, value}}

  defp epoch_second(second) do
    case Numeric.float(second) do
      {:ok, float} -> {:ok, float}
      {:out_of_range, value} -> {:error, {:value_out_of_range, :second, value}}
      :not_a_number -> {:error, {:invalid_epoch_field, :second, second}}
    end
  end

  defp index(index) when is_integer(index) and index >= 0 and index < @usize_limit, do: :ok
  defp index(index), do: {:error, {:invalid_argument, :index, index}}

  defp double(value, field) do
    case Numeric.float(value) do
      {:ok, float} -> {:ok, float}
      {:out_of_range, value} -> {:error, {:value_out_of_range, field, value}}
      :not_a_number -> {:error, {:invalid_argument, field, value}}
    end
  end

  defp doubles(values, field) when is_list(values), do: collect(values, &double(&1, field))
  defp doubles(values, field), do: {:error, {:invalid_argument, field, values}}

  defp edit_entries(records, edit) do
    collect(records, fn record ->
      case edit.(record) do
        nil -> {:ok, nil}
        values -> doubles(values, :values)
      end
    end)
  end

  defp collect(items, fun) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, term} -> {:cont, {:ok, [term | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, terms} -> {:ok, Enum.reverse(terms)}
      {:error, _reason} = error -> error
    end
  end

  defp record(fields, suffix_override \\ nil) do
    {trailing_text_bytes, trailing_text_column} =
      suffix_override || {fields.trailing_text_bytes, fields.trailing_text_column}

    struct!(Record, %{
      fields
      | civil_epoch: struct!(CivilEpoch, fields.civil_epoch),
        epoch: instant(fields.epoch),
        trailing_text_bytes: trailing_text_bytes,
        trailing_text_column: trailing_text_column
    })
  end

  defp point(fields), do: struct!(Point, %{fields | epoch: Instant.from_nif_term(fields.epoch)})

  defp instant(nil), do: nil
  defp instant(term), do: Instant.from_nif_term(term)

  defp header_field({:clock_ref_count, %{start: start, stop: stop} = fields}) do
    {:clock_ref_count, %{fields | start: civil(start), stop: civil(stop)}}
  end

  defp header_field(field), do: field

  defp civil(nil), do: nil
  defp civil(fields), do: struct!(CivilEpoch, fields)

  defp departure({:epoch_at_nearest_microsecond, %{epoch: epoch} = fields}) do
    {:epoch_at_nearest_microsecond, %{fields | epoch: instant(epoch)}}
  end

  defp departure(other), do: other
end
