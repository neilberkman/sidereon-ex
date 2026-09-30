defmodule Sidereon.GNSS.Antex do
  @moduledoc """
  Parser and lookup helpers for ANTEX 1.4 receiver and satellite antenna blocks.

  The ANTEX parser, satellite validity lookup, and PCO/PCV interpolation live in
  the Rust GNSS core. A parsed product keeps every record ANTEX 1.4 defines and
  keeps absent records absent:

    * `header` - `ANTEX VERSION / SYST`, the `PCV TYPE / REFANT` calibration
      type and reference antenna (so relative values can be told apart from
      absolute ones), the header comments, and whether `END OF HEADER` is
      present;
    * `blocks` - every antenna block in file order, including each validity
      interval of one `TYPE / SERIAL NO` id;
    * `antennas` - the latest block for each id, the view `antenna/2` reads;
    * `outer_comments` - comments between and after the blocks, each placed by
      the number of blocks before it;
    * `skipped_records` - the count of records the forgiving parse passed over
      or found inconsistent (a line outside any record, a `# OF FREQUENCIES`
      count that disagrees with the sections read, a block or section not
      closed by its own end record, and similar); the blocks themselves are
      kept.

  Each `Sidereon.GNSS.Antex.Antenna` keeps its comments (those before
  `TYPE / SERIAL NO` apart from the rest), its `METH / BY / # / DATE` records,
  `DAZI` and `ZEN1 / ZEN2 / DZEN` as `nil` when the block has no such record,
  its validity bounds with their exact seconds (`Sidereon.GNSS.Antex.Epoch`),
  and its frequency sections as a list in file order, each with its
  `START OF FREQ RMS` section when it has one. A frequency label may repeat;
  `frequency/2`, `pco/2` and `pcv/4` refuse a label whose sections differ as
  `{:ambiguous_frequency, fields}`.

  ## Refusals

  Parsing, writing and lookups return `{:error, reason}` with the core's typed
  reason and every field it carries:

    * `{:invalid_field, %{antenna_id, record, field, value}}` - a record field
      that is not a valid value, such as a blank, short or malformed validity
      seconds field or a second of 60, which GPS time does not have;
    * `{:repeated_record, %{antenna_id, record}}` - a once-per-block record
      repeated with different content;
    * `{:degenerate_grid, %{antenna_id, frequency, reason}}` - a PCV row that
      would put two values on one zenith;
    * `{:invalid_input, %{field, reason}}` - a lookup argument, such as a
      non-finite zenith;
    * `{:unknown_frequency, %{antenna_id, frequency}}`,
      `{:ambiguous_frequency, %{antenna_id, frequency, sections}}`,
      `{:missing_pco, %{antenna_id, frequency}}` and
      `{:empty_pcv_grid, %{antenna_id, frequency}}`;
    * `{:unwritable, %{field, reason}}` - a product the writer cannot state
      exactly;
    * `:invalid_datetime` - an epoch outside the GPS calendar and clock.
  """

  alias Sidereon.GNSS.Antex.Antenna
  alias Sidereon.GNSS.Antex.Calibration
  alias Sidereon.GNSS.Antex.Epoch
  alias Sidereon.GNSS.Antex.Frequency
  alias Sidereon.GNSS.Antex.FrequencyRms
  alias Sidereon.GNSS.Antex.Header
  alias Sidereon.GNSS.Antex.OuterComment
  alias Sidereon.GNSS.Antex.PcvTypeRecord
  alias Sidereon.GNSS.Antex.Version
  alias Sidereon.GNSS.Antex.ZenithGrid
  alias Sidereon.GNSS.Ionosphere.Numeric
  alias Sidereon.NIF
  alias Sidereon.NifCall

  @u64_limit Integer.pow(2, 64)

  @enforce_keys [:antennas]
  defstruct [:antennas, :handle, blocks: [], header: nil, outer_comments: [], skipped_records: 0]

  defmodule Version do
    @moduledoc "The `ANTEX VERSION / SYST` record: format version and satellite system flag (`nil` when blank)."
    @enforce_keys [:version, :system]
    defstruct [:version, :system]
    @type t :: %__MODULE__{version: float(), system: String.t() | nil}
  end

  defmodule PcvTypeRecord do
    @moduledoc """
    The `PCV TYPE / REFANT` record.

    `pcv_type` is `:absolute` or `:relative`. `reference_antenna` is the antenna
    type relative values refer to: the stated type, or `"AOAD/M_T"` when a
    relative file leaves it blank, as ANTEX 1.4 names it; `nil` for absolute
    values.
    """
    @enforce_keys [:pcv_type, :reference_antenna_type, :reference_antenna_serial, :reference_antenna]
    defstruct [:pcv_type, :reference_antenna_type, :reference_antenna_serial, :reference_antenna]

    @type t :: %__MODULE__{
            pcv_type: :absolute | :relative,
            reference_antenna_type: String.t(),
            reference_antenna_serial: String.t(),
            reference_antenna: String.t() | nil
          }
  end

  defmodule Header do
    @moduledoc """
    ANTEX header records. `version` and `pcv_type` are `nil` when the source has
    no such record; `comments` are the header `COMMENT` texts in file order.
    """
    @enforce_keys [:version, :pcv_type, :comments, :end_of_header]
    defstruct [:version, :pcv_type, :comments, :end_of_header]

    @type t :: %__MODULE__{
            version: Version.t() | nil,
            pcv_type: PcvTypeRecord.t() | nil,
            comments: [String.t()],
            end_of_header: boolean()
          }
  end

  defmodule OuterComment do
    @moduledoc "A `COMMENT` record outside every antenna block, placed by the number of blocks before it."
    @enforce_keys [:blocks_before, :text]
    defstruct [:blocks_before, :text]
    @type t :: %__MODULE__{blocks_before: non_neg_integer(), text: String.t()}
  end

  defmodule Calibration do
    @moduledoc """
    A `METH / BY / # / DATE` record. `antennas_calibrated` is `nil` when the
    count field is blank.
    """
    @enforce_keys [:method, :agency, :antennas_calibrated, :date]
    defstruct [:method, :agency, :antennas_calibrated, :date]

    @type t :: %__MODULE__{
            method: String.t(),
            agency: String.t(),
            antennas_calibrated: non_neg_integer() | nil,
            date: String.t()
          }
  end

  defmodule ZenithGrid do
    @moduledoc "The `ZEN1 / ZEN2 / DZEN` record, in degrees."
    @enforce_keys [:start_deg, :end_deg, :step_deg]
    defstruct [:start_deg, :end_deg, :step_deg]
    @type t :: %__MODULE__{start_deg: float(), end_deg: float(), step_deg: float()}
  end

  defmodule Epoch do
    @moduledoc """
    A GPS-time `VALID FROM` / `VALID UNTIL` bound with its exact fraction of a
    second.

    The `F13.7` seconds field can state more decimals than a `NaiveDateTime`
    holds (`59.9999999`, `.123456789012`, `1.2345678E-9`), so the fraction is
    kept as `fraction_digits / 10^fraction_scale`, normalized with no trailing
    zero digit (a zero fraction is `0` over `0`). `second` is `0..59`: GPS time
    has no leap-second label.
    """
    @enforce_keys [:year, :month, :day, :hour, :minute, :second, :fraction_digits, :fraction_scale]
    defstruct [:year, :month, :day, :hour, :minute, :second, :fraction_digits, :fraction_scale]

    @type t :: %__MODULE__{
            year: integer(),
            month: 1..12,
            day: 1..31,
            hour: 0..23,
            minute: 0..59,
            second: 0..59,
            fraction_digits: non_neg_integer(),
            fraction_scale: non_neg_integer()
          }

    @doc """
    The bound as a `NaiveDateTime` when its fraction is a whole number of
    microseconds, `{:error, :sub_microsecond_fraction}` otherwise.
    """
    @spec to_naive_datetime(t()) :: {:ok, NaiveDateTime.t()} | {:error, term()}
    def to_naive_datetime(%__MODULE__{fraction_digits: digits, fraction_scale: scale} = epoch) when scale <= 6 do
      microsecond = digits * Integer.pow(10, 6 - scale)
      NaiveDateTime.new(epoch.year, epoch.month, epoch.day, epoch.hour, epoch.minute, epoch.second, {microsecond, 6})
    end

    def to_naive_datetime(%__MODULE__{}), do: {:error, :sub_microsecond_fraction}

    @doc "A `NaiveDateTime` as a bound, its microseconds kept exactly."
    @spec from_naive_datetime(NaiveDateTime.t()) :: t()
    def from_naive_datetime(%NaiveDateTime{microsecond: {microsecond, _precision}} = ndt) do
      {digits, scale} = normalize(microsecond, 6)

      %__MODULE__{
        year: ndt.year,
        month: ndt.month,
        day: ndt.day,
        hour: ndt.hour,
        minute: ndt.minute,
        second: ndt.second,
        fraction_digits: digits,
        fraction_scale: scale
      }
    end

    @doc false
    @spec from_native(map() | nil) :: t() | nil
    def from_native(nil), do: nil
    def from_native(%{} = fields), do: struct!(__MODULE__, fields)

    defp normalize(0, _scale), do: {0, 0}
    defp normalize(digits, scale) when rem(digits, 10) == 0, do: normalize(div(digits, 10), scale - 1)
    defp normalize(digits, scale), do: {digits, scale}
  end

  defmodule FrequencyRms do
    @moduledoc """
    A `START OF FREQ RMS` section: RMS of the `NORTH / EAST / UP` eccentricities
    in meters (`nil` when the section has no such record) and of the pattern
    values, placed on the antenna's grid as the frequency's samples are.
    """
    @enforce_keys [:pco_m, :pcv_samples]
    defstruct [:pco_m, :pcv_samples]

    @type t :: %__MODULE__{
            pco_m: {float(), float(), float()} | nil,
            pcv_samples: [Frequency.pcv_sample()]
          }
  end

  defmodule Frequency do
    @moduledoc """
    One frequency section: its label, the `NORTH / EAST / UP` PCO in meters,
    the PCV samples in row order, and its RMS section (`nil` when the file has
    none).
    """
    @enforce_keys [:frequency, :pco_m, :pcv_samples]
    defstruct [:frequency, :pco_m, :pcv_samples, rms: nil]

    @typedoc "One PCV value: `NOAZI` (`:noazi`, `azimuth_deg: nil`) or an azimuth row (`:azi`)."
    @type pcv_sample :: %{
            grid: :azi | :noazi,
            azimuth_deg: float() | nil,
            zenith_deg: float(),
            value_m: float()
          }

    @type t :: %__MODULE__{
            frequency: String.t(),
            pco_m: {float(), float(), float()},
            pcv_samples: [pcv_sample()],
            rms: FrequencyRms.t() | nil
          }
  end

  defmodule Antenna do
    @moduledoc """
    One receiver or satellite antenna block.

    `leading_comments` are the comments between `START OF ANTENNA` and
    `TYPE / SERIAL NO`; `comments` the rest. `dazi_deg` and `zenith_grid` are
    `nil` when the block has no `DAZI` or `ZEN1 / ZEN2 / DZEN` record (a block
    without a zenith grid has no PCV values). `has_frequency_count` says whether
    the block carries `# OF FREQUENCIES`; the writer states the number of
    sections. `frequencies` are the sections in file order.
    """
    @enforce_keys [:id, :kind, :type, :serial, :frequencies]
    defstruct [
      :id,
      :kind,
      :type,
      :serial,
      :dazi_deg,
      :zenith_grid,
      :sinex_code,
      :valid_from,
      :valid_until,
      :frequencies,
      leading_comments: [],
      calibrations: [],
      has_frequency_count: false,
      comments: []
    ]

    @type t :: %__MODULE__{
            id: String.t(),
            kind: :receiver | :satellite,
            type: String.t(),
            serial: String.t(),
            leading_comments: [String.t()],
            calibrations: [Calibration.t()],
            dazi_deg: float() | nil,
            zenith_grid: ZenithGrid.t() | nil,
            has_frequency_count: boolean(),
            sinex_code: String.t() | nil,
            valid_from: Epoch.t() | nil,
            valid_until: Epoch.t() | nil,
            comments: [String.t()],
            frequencies: [Frequency.t()]
          }
  end

  @type t :: %__MODULE__{
          antennas: %{optional(String.t()) => Antenna.t()},
          blocks: [Antenna.t()],
          header: Header.t() | nil,
          outer_comments: [OuterComment.t()],
          skipped_records: non_neg_integer(),
          handle: reference() | nil
        }

  @type parse_error :: {:error, term()}

  @doc """
  Load and parse an ANTEX file from `path`.
  """
  @spec load(String.t()) :: {:ok, t()} | parse_error
  def load(path) when is_binary(path) do
    with {:ok, text} <- File.read(path) do
      parse(text)
    end
  end

  @doc """
  Like `load/1` but raises on failure.
  """
  @spec load!(String.t()) :: t()
  def load!(path) when is_binary(path) do
    case load(path) do
      {:ok, antex} ->
        antex

      {:error, reason} ->
        raise ArgumentError, "could not load ANTEX #{path}: #{inspect(reason)}"
    end
  end

  @doc """
  Parse ANTEX text already in memory.

  Returns `{:ok, %Sidereon.GNSS.Antex{}}` with every retained record, or
  `{:error, reason}` with the typed refusals listed in the module
  documentation.
  """
  @spec parse(binary()) :: {:ok, t()} | parse_error
  def parse(text) when is_binary(text) do
    case NIF.antex_parse(text) do
      {:ok, product, handle} -> {:ok, from_native(product, handle)}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :antex_parse)
  end

  @doc """
  Serialize a parsed ANTEX product back to ANTEX 1.4 text.

  The writer states every record from a retained value and writes no record
  the source did not carry, apart from the start and end records of blocks and
  sections, with antenna blocks and frequency sections in file order and
  validity seconds exactly. Re-parsing the output yields an equal product. The
  serializer works on the full parsed product held alongside the decoded
  antennas, so every validity interval is re-emitted, not just the latest-wins
  view exposed by `antenna/2`.

  The writer refuses a product it cannot state exactly - a field that overflows
  its columns, a value its precision cannot hold, a sample coordinate the reader
  would not reconstruct, a frequency label that is not a system flag and a
  two-column number, validity seconds no decimal form fits in 13 columns - as
  `{:error, {:unwritable, %{field: field, reason: reason}}}` rather than
  rounding or dropping it.
  """
  @spec encode(t()) :: {:ok, String.t()} | {:error, term()}
  def encode(%__MODULE__{handle: handle}) when is_reference(handle) do
    case NIF.antex_encode(handle) do
      {:ok, text} -> {:ok, text}
      {:error, _reason} = error -> error
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :antex_encode)
  end

  @doc """
  Return the latest antenna block for a `TYPE / SERIAL` id, or `nil`.
  """
  @spec antenna(t(), String.t()) :: Antenna.t() | nil
  def antenna(%__MODULE__{antennas: antennas}, id) when is_binary(id) do
    Map.get(antennas, String.trim(id))
  end

  @doc """
  Return every validity block of a `TYPE / SERIAL` id, in file order.
  """
  @spec antenna_intervals(t(), String.t()) :: [Antenna.t()]
  def antenna_intervals(%__MODULE__{blocks: blocks}, id) when is_binary(id) do
    id = String.trim(id)
    Enum.filter(blocks, &(&1.id == id))
  end

  @doc """
  Return the validity block of a `TYPE / SERIAL` id valid at `epoch`, or `nil`.

  `epoch` is a `NaiveDateTime` or a `Sidereon.GNSS.Antex.Epoch` in GPS time;
  bounds are inclusive and compared with their exact seconds.
  """
  @spec antenna_at(t(), String.t(), NaiveDateTime.t() | Epoch.t()) :: Antenna.t() | nil | {:error, term()}
  def antenna_at(%__MODULE__{handle: handle} = antex, id, epoch) when is_reference(handle) and is_binary(id) do
    block_at(antex, :antex_antenna_at, id, epoch)
  end

  @doc """
  Return the satellite antenna block for PRN `prn` (e.g. `"G05"`) valid at the
  given epoch, or `nil` if none.

  Every validity interval in the file is searched, not only the latest block of
  each id. `epoch` is a `NaiveDateTime` or a `Sidereon.GNSS.Antex.Epoch` in GPS
  time. An epoch outside the GPS calendar and clock returns
  `{:error, :invalid_datetime}`.
  """
  @spec satellite_antenna(t(), String.t(), NaiveDateTime.t() | Epoch.t()) :: Antenna.t() | nil | {:error, term()}
  def satellite_antenna(%__MODULE__{handle: handle} = antex, prn, epoch) when is_reference(handle) and is_binary(prn) do
    block_at(antex, :antex_satellite_antenna, prn, epoch)
  end

  @doc """
  Return the number of records the forgiving parse skipped or found
  inconsistent.
  """
  @spec skipped_records(t()) :: non_neg_integer()
  def skipped_records(%__MODULE__{skipped_records: count}), do: count

  @doc """
  The frequency section a label selects.

  When several sections carry the label they must be identical; otherwise the
  lookup is refused as `{:error, {:ambiguous_frequency, fields}}`.
  """
  @spec frequency(Antenna.t(), String.t()) :: {:ok, Frequency.t()} | {:error, term()}
  def frequency(%Antenna{frequencies: frequencies} = antenna, label) when is_binary(label) do
    case NIF.antex_frequency(lookup_term(antenna), label) do
      {:ok, index} -> {:ok, Enum.at(frequencies, index)}
      {:error, _reason} = error -> error
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :antex_frequency)
  end

  @doc """
  Frequency-dependent PCO (north/east/up in meters).

  Returns `{:ok, {north, east, up}}`, `{:error, {:unknown_frequency, fields}}`,
  or `{:error, {:ambiguous_frequency, fields}}`.
  """
  @spec pco(Antenna.t(), String.t()) :: {:ok, {float(), float(), float()}} | {:error, term()}
  def pco(%Antenna{} = antenna, frequency) when is_binary(frequency) do
    case NIF.antex_pco(lookup_term(antenna), frequency) do
      {:ok, pco_m} -> {:ok, pco_m}
      {:error, _reason} = error -> error
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :antex_pco)
  end

  @doc """
  Like `pco/2` but raises on a refused lookup.
  """
  @spec pco!(Antenna.t(), String.t()) :: {float(), float(), float()}
  def pco!(%Antenna{} = antenna, frequency) when is_binary(frequency) do
    case pco(antenna, frequency) do
      {:ok, pco_m} ->
        pco_m

      {:error, reason} ->
        raise ArgumentError, "no PCO for #{inspect(frequency)} of #{inspect(antenna.id)}: #{inspect(reason)}"
    end
  end

  @doc """
  Frequency-dependent phase-center variation in meters.

  Interpolation is linear in zenith and azimuth. Azimuth is optional: when not
  given (or when the antenna has no azimuth-dependent rows), the NOAZI row is
  used. A finite zenith outside the block's `ZEN1..ZEN2` grid is clamped to it.
  Returns `{:ok, value_m}` or `{:error, reason}` with the typed lookup
  refusals (unknown or ambiguous frequency, a non-finite zenith as
  `{:invalid_input, fields}`, an empty grid as `{:empty_pcv_grid, fields}`).
  """
  @spec pcv(Antenna.t(), String.t(), number(), number() | nil) :: {:ok, float()} | {:error, term()}
  def pcv(%Antenna{} = antenna, frequency, zenith_deg, azimuth_deg \\ nil) when is_number(zenith_deg) do
    with {:ok, zenith} <- double(zenith_deg, :zenith_deg),
         {:ok, azimuth} <- optional_double(azimuth_deg, :azimuth_deg) do
      case NIF.antex_pcv(lookup_term(antenna), frequency, zenith, azimuth) do
        {:ok, value_m} -> {:ok, value_m}
        {:error, _reason} = error -> error
      end
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :antex_pcv)
  end

  @doc """
  Like `pcv/4` but raises on a refused lookup.
  """
  @spec pcv!(Antenna.t(), String.t(), number(), number() | nil) :: float()
  def pcv!(%Antenna{} = antenna, frequency, zenith_deg, azimuth_deg \\ nil) when is_number(zenith_deg) do
    case pcv(antenna, frequency, zenith_deg, azimuth_deg) do
      {:ok, value_m} ->
        value_m

      {:error, reason} ->
        raise ArgumentError, "no PCV for #{inspect(frequency)} of #{inspect(antenna.id)}: #{inspect(reason)}"
    end
  end

  defp block_at(%__MODULE__{handle: handle, blocks: blocks}, native_call, key, epoch) do
    with {:ok, epoch} <- epoch_term(epoch) do
      case apply(NIF, native_call, [handle, key, epoch]) do
        {:ok, index} -> Enum.at(blocks, index)
        {:error, :not_found} -> nil
        {:error, _reason} = error -> error
      end
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, native_call)
  end

  defp epoch_term(%NaiveDateTime{} = epoch), do: epoch |> Epoch.from_naive_datetime() |> epoch_term()

  # An epoch the boundary can carry: a year in the GPS calendar, byte-sized
  # clock fields and a 64-bit fraction. Anything else is outside the GPS
  # calendar and clock, which the core reports as `:invalid_datetime` too.
  defp epoch_term(%Epoch{} = epoch) do
    fields = Map.from_struct(epoch)
    clock = [fields.month, fields.day, fields.hour, fields.minute, fields.second]
    fraction = [fields.fraction_digits, fields.fraction_scale]

    if fields.year in 0..9999 and Enum.all?(clock, &(&1 in 0..255)) and Enum.all?(fraction, &u64?/1) do
      {:ok, fields}
    else
      {:error, :invalid_datetime}
    end
  end

  defp epoch_term(_epoch), do: {:error, :invalid_datetime}

  defp u64?(value), do: is_integer(value) and value >= 0 and value < @u64_limit

  # The fields a frequency, PCO or PCV lookup reads; the struct's other
  # records do not take part.
  defp lookup_term(%Antenna{id: id, zenith_grid: zenith_grid, frequencies: frequencies}) do
    %{id: id, zenith_grid: zenith_grid, frequencies: frequencies}
  end

  defp double(value, field) do
    case Numeric.float(value) do
      {:ok, float} -> {:ok, float}
      {:out_of_range, value} -> {:error, {:value_out_of_range, field, value}}
      :not_a_number -> {:error, {:invalid_double, field, value}}
    end
  end

  defp optional_double(nil, _field), do: {:ok, nil}
  defp optional_double(value, field), do: double(value, field)

  defp from_native(product, handle) do
    blocks = Enum.map(product.blocks, &antenna_from_native/1)

    %__MODULE__{
      antennas: Map.new(blocks, &{&1.id, &1}),
      blocks: blocks,
      header: header_from_native(product.header),
      outer_comments: Enum.map(product.outer_comments, &struct!(OuterComment, &1)),
      skipped_records: product.skipped_records,
      handle: handle
    }
  end

  defp header_from_native(header) do
    %Header{
      version: header.version && struct!(Version, header.version),
      pcv_type: header.pcv_type && struct!(PcvTypeRecord, header.pcv_type),
      comments: header.comments,
      end_of_header: header.end_of_header
    }
  end

  defp antenna_from_native(block) do
    %Antenna{
      id: block.id,
      kind: block.kind,
      type: block.antenna_type,
      serial: block.serial,
      leading_comments: block.leading_comments,
      calibrations: Enum.map(block.calibrations, &struct!(Calibration, &1)),
      dazi_deg: block.dazi_deg,
      zenith_grid: block.zenith_grid && struct!(ZenithGrid, block.zenith_grid),
      has_frequency_count: block.has_frequency_count,
      sinex_code: block.sinex_code,
      valid_from: Epoch.from_native(block.valid_from),
      valid_until: Epoch.from_native(block.valid_until),
      comments: block.comments,
      frequencies: Enum.map(block.frequencies, &frequency_from_native/1)
    }
  end

  defp frequency_from_native(frequency) do
    %Frequency{
      frequency: frequency.frequency,
      pco_m: frequency.pco_m,
      pcv_samples: frequency.pcv_samples,
      rms: frequency.rms && struct!(FrequencyRms, frequency.rms)
    }
  end
end
