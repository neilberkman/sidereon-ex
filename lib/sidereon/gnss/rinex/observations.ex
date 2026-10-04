defmodule Sidereon.GNSS.RINEX.Observations do
  @moduledoc """
  RINEX observation products: parse a station's observation file, read its
  header and epochs, and extract the observations, cycle slips, carrier phases
  and single-frequency pseudoranges the positioning solvers consume.

  This is the Elixir surface over the `sidereon-core` RINEX observation reader
  and writer and its Hatanaka (CRINEX) codec. A file is parsed **once** into a
  resource handle held by the BEAM; accessors operate on that handle and never
  re-read the file. RINEX 2, 3 and 4 observation files are read.

  Both plain RINEX (`.rnx`) and Hatanaka-compressed CRINEX (`.crx`) text are
  accepted: `load/1` and `parse_auto/1` sniff the first line for the
  `CRINEX VERS / TYPE` marker and decode CRINEX before parsing.

  ## Example

      {:ok, obs} = Sidereon.GNSS.RINEX.Observations.load("ESBC00DNK_..._MO.crx")

      Sidereon.GNSS.RINEX.Observations.approx_position(obs)
      # => {3_582_105.291, 532_589.7313, 5_232_754.8054}

      [%{index: i, epoch: epoch} | _] = Sidereon.GNSS.RINEX.Observations.epochs(obs)
      {:ok, prs} = Sidereon.GNSS.RINEX.Observations.pseudoranges(obs, i, codes: %{"G" => ["C1C"]})
      # prs :: [{"G01", range_m}, ...], feeds solve/4 verbatim

  ## Events and headers in effect

  An epoch whose flag is above 1 is an event, except flag 6, whose records are
  cycle slips. Events are kept in their place, with their records verbatim and
  their epoch time or its absence (`Sidereon.GNSS.RINEX.Observations.Epoch`).
  The header records an event carries take effect for the epochs after it:
  `header_at/2` gives the header in effect at an epoch and
  `header_segments/1` every header of the product with the first epoch it is in
  effect at. `phases/3` reads phase shifts and GLONASS channels from the header
  in effect at its epoch.

  ## Writing

  `to_rinex_string/1` writes the product at the version its header carries and
  returns the text only when reading it back gives the product; otherwise it
  refuses by name. `downgrade_to_rinex2/2` is the explicit path for a product
  that has to change to become a version 2 file, and returns every change it
  made. Both refuse with `{:error, {tag, fields}}`:

    * `{:code_lists_not_version_two, %{system, position, code}}` - one list of
      version 2 names cannot read back as each constellation's codes; `code` is
      `nil` where the lists differ in length.
    * `{:not_version_two, %{version}}` - a downgrade to a version that is not 2.
    * `{:scale_factors_in_version_two, %{count}}`
    * `{:values_without_codes, %{epoch_index, satellite, codes, values}}`
    * `{:counts_without_codes, %{satellite, codes, counts}}`
    * `{:code_list_not_stated, %{system}}`
    * `{:epoch_flag_too_wide, %{epoch_index, flag}}`
    * `{:epoch_time_missing, %{epoch_index, flag}}` - an observation or cycle
      slip epoch with no time; only an event may leave its time blank.
    * `{:epoch_picoseconds_not_in_version, %{epoch_index, version}}`
    * `{:too_many_observation_types, %{count}}`
    * `{:code_lists_not_union, %{system}}`
    * `{:value_outside_declared_list, %{epoch_index, satellite, code}}` - `code`
      is `nil` where the constellation has no list in effect at the epoch.
    * `{:declared_list_not_stated, %{system}}`
    * `{:event_records_unreadable, %{message}}`
    * `{:observable_not_representable, %{system, code, version}}` - a code on a
      carrier the target version cannot name without moving the measurement to
      another signal, such as BeiDou B1C in version 2.
    * `{:leap_seconds_time_system_not_in_version, %{time_system, version}}`
    * `{:invalid_leap_seconds_time_system, %{time_system}}`
    * `{:read_back_mismatch, %{what}}` - the text would read back as another
      product; `what` names the first field that would change.

  `system` is a constellation letter and `satellite` a satellite id such as
  `"C05"`.

  ## Default pseudorange codes

  The per-system defaults are version-aware: GPS `C1C`, Galileo `C1C` then
  `C1X`, BeiDou `C1I` for RINEX 3.02 / `C2I` for 3.01 and 3.03+ (the B1I label
  changed between minor versions), GLONASS `C1C`. Override per system with the
  `:codes` option, e.g. `codes: %{"G" => ["C1C"], "C" => ["C2I"]}`. A key that is
  not a constellation letter is refused as `{:error, {:unknown_system, key}}`
  rather than dropped.
  """

  alias Sidereon.GNSS.RINEX.Observations.DowngradeChange
  alias Sidereon.GNSS.RINEX.Observations.Epoch
  alias Sidereon.GNSS.RINEX.Observations.Header
  alias Sidereon.GNSS.RINEX.Observations.PhaseRow
  alias Sidereon.GNSS.RINEX.Observations.PhaseShift
  alias Sidereon.NIF
  alias Sidereon.NifCall

  @enforce_keys [:handle]
  defstruct [:handle]

  @type t :: %__MODULE__{handle: reference()}

  @typedoc "A pseudorange observation `{satellite_id, range_m}`."
  @type observation :: {String.t(), float()}

  @typedoc "An epoch descriptor as returned by `epochs/1`."
  @type epoch_entry :: Epoch.t()

  @typedoc "GLONASS satellite id to FDMA frequency-channel number."
  @type glonass_slot_map :: %{String.t() => integer()}

  @typedoc "A writer refusal, `{tag, fields}`, as the moduledoc lists them."
  @type write_error :: {atom(), map()}

  # The boundary reads an epoch index as an unsigned 64-bit integer. An integer
  # outside that range names no epoch, so it is out of range rather than a
  # decoding failure.
  @max_epoch_index 0xFFFF_FFFF_FFFF_FFFF

  # The largest finite double, as the integer it is.
  @float_max_integer trunc(1.7976931348623157e308)

  defguardp is_epoch_index(index) when is_integer(index) and index >= 0 and index <= @max_epoch_index

  @doc """
  Load and parse a RINEX observation file from disk.

  The file may be plain RINEX (`.rnx`) or Hatanaka CRINEX (`.crx`); the first
  line is sniffed for the CRINEX marker and decoded if present. Returns
  `{:ok, %Sidereon.GNSS.RINEX.Observations{}}` or `{:error, reason}`.
  """
  @spec load(String.t()) :: {:ok, t()} | {:error, term()}
  def load(path) when is_binary(path) do
    with {:ok, text} <- File.read(path) do
      parse_auto(text)
    end
  end

  @doc """
  Like `load/1` but raises on failure.
  """
  @spec load!(String.t()) :: t()
  def load!(path) when is_binary(path) do
    case load(path) do
      {:ok, obs} ->
        obs

      {:error, reason} ->
        raise ArgumentError, "could not load RINEX OBS #{path}: #{inspect(reason)}"
    end
  end

  @doc """
  Parse text, auto-detecting plain RINEX vs CRINEX from the first line.
  """
  @spec parse_auto(binary()) :: {:ok, t()} | {:error, term()}
  def parse_auto(text) when is_binary(text) do
    if crinex?(text), do: parse_crinex(text), else: parse(text)
  end

  @doc """
  Parse plain RINEX observation text into a handle.
  """
  @spec parse(binary()) :: {:ok, t()} | {:error, term()}
  def parse(text) when is_binary(text) do
    wrap(NIF.rinex_obs_parse(text))
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :rinex_obs_parse)
  end

  @doc """
  Decode Hatanaka CRINEX text and parse the result into a handle.
  """
  @spec parse_crinex(binary()) :: {:ok, t()} | {:error, term()}
  def parse_crinex(text) when is_binary(text) do
    wrap(NIF.crinex_obs_parse(text))
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :crinex_obs_parse)
  end

  @doc """
  Decode Hatanaka CRINEX text into the plain RINEX observation text it expands
  to. Returns `{:ok, rinex_text}` or `{:error, reason}`.
  """
  @spec decode_crinex(binary()) :: {:ok, String.t()} | {:error, term()}
  def decode_crinex(text) when is_binary(text) do
    case NIF.crinex_decode(text) do
      rnx when is_binary(rnx) -> {:ok, rnx}
      {:error, _} = err -> err
      other -> {:error, other}
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :crinex_decode)
  end

  @doc """
  Encode plain RINEX observation text into Hatanaka CRINEX text, the inverse of
  `decode_crinex/1`. Returns `{:ok, crinex_text}` or `{:error, reason}`.

  Because CRINEX compression is not unique, the output is the canonical
  all-reset form; it is not byte-identical to an arbitrary `RNX2CRX` stream, but
  `decode_crinex(crinex_text)` reproduces the input RINEX for any text this
  round-trips.

  ## Examples

      {:ok, crx} = Sidereon.GNSS.RINEX.Observations.encode_crinex(rinex_text)
      {:ok, ^rinex_text} = Sidereon.GNSS.RINEX.Observations.decode_crinex(crx)
  """
  @spec encode_crinex(binary()) :: {:ok, String.t()} | {:error, term()}
  def encode_crinex(text) when is_binary(text) do
    case NIF.crinex_encode(text) do
      crx when is_binary(crx) -> {:ok, crx}
      {:error, _} = err -> err
      other -> {:error, other}
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :crinex_encode)
  end

  @doc """
  Serialize a product back to RINEX observation text, at the version its header
  carries: version 2 records below 3.0, version 3 records otherwise.

  The text is returned only when reading it back gives this product: every
  header record, code, value, indicator and event record, compared field by
  field. Nothing is dropped, rounded or truncated to make a product fit; a
  product the version cannot state is refused with the first field that would
  change, as one of the refusals the moduledoc lists. A product that has to
  change to become a version 2 file goes through `downgrade_to_rinex2/2`.

  Returns `{:ok, text}` or `{:error, {tag, fields}}`.

  ## Examples

      {:ok, obs} = Sidereon.GNSS.RINEX.Observations.parse(rinex_text)
      {:ok, text} = Sidereon.GNSS.RINEX.Observations.to_rinex_string(obs)
      {:ok, reparsed} = Sidereon.GNSS.RINEX.Observations.parse(text)
      Sidereon.GNSS.RINEX.Observations.epochs(reparsed) ==
        Sidereon.GNSS.RINEX.Observations.epochs(obs)
      #=> true
  """
  @spec to_rinex_string(t()) :: {:ok, String.t()} | {:error, write_error() | term()}
  def to_rinex_string(%__MODULE__{handle: handle}) do
    case NIF.rinex_obs_to_string(handle) do
      {:ok, text} -> {:ok, text}
      {:error, _reason} = error -> error
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :rinex_obs_to_string)
  end

  @doc """
  This product as one a version 2 file states exactly, with every change that
  took.

  `version` is the version 2 revision to write, such as `2.11`. Version 2 names
  one list of observation types for every constellation, so codes are renamed,
  moved or added to line the constellations' lists up, values move with their
  codes, and what version 2 has no field for is removed. Each such change is
  returned as a `Sidereon.GNSS.RINEX.Observations.DowngradeChange`; nothing is
  changed without being named. What version 2 still cannot state is refused
  instead, including a code on a carrier version 2 cannot name
  (`{:observable_not_representable, %{system, code, version}}`) and a
  `LEAP SECONDS` time system the version does not support.

  Returns `{:ok, %{value: product, changes: changes}}`, `product` being a new
  `%Sidereon.GNSS.RINEX.Observations{}` whose `to_rinex_string/1` succeeds, or
  `{:error, {tag, fields}}` as the moduledoc lists them. An empty `changes`
  list means the product needed none. A `version` that is not a number a double
  holds is `{:error, {:invalid_version, version}}`.
  """
  @spec downgrade_to_rinex2(t(), number()) ::
          {:ok, %{value: t(), changes: [DowngradeChange.t()]}} | {:error, write_error() | term()}
  def downgrade_to_rinex2(%__MODULE__{handle: handle}, version) when is_float(version) do
    case NIF.rinex_obs_downgrade_to_rinex2(handle, version) do
      {:ok, product, changes} ->
        {:ok, %{value: %__MODULE__{handle: product}, changes: Enum.map(changes, &DowngradeChange.from_nif_map/1)}}

      {:error, _reason} = error ->
        error
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :rinex_obs_downgrade_to_rinex2)
  end

  # An integer version crosses as the double it is. One larger in magnitude than
  # the largest finite double has no double, and is refused as a value that is
  # not a version rather than raising out of the conversion.
  def downgrade_to_rinex2(%__MODULE__{} = obs, version)
      when is_integer(version) and abs(version) <= @float_max_integer do
    downgrade_to_rinex2(obs, version / 1.0)
  end

  def downgrade_to_rinex2(%__MODULE__{}, version), do: {:error, {:invalid_version, version}}

  @doc """
  The file header, with every record the product holds.

  See `Sidereon.GNSS.RINEX.Observations.Header` for the fields. The header in
  effect at a later epoch can differ; see `header_at/2`.
  """
  @spec header(t()) :: Header.t()
  def header(%__MODULE__{handle: handle}) do
    handle
    |> NIF.rinex_obs_header()
    |> Header.from_nif_map()
  rescue
    e in ErlangError ->
      reraise ArgumentError, [message: "could not read header: #{NifCall.describe(e)}"], __STACKTRACE__
  end

  @doc """
  The header in effect at an epoch: the file header with the header records of
  every event at or before `epoch_index` laid over it.

  Its `obs_codes` is the product's code union and its `declared_obs_codes` the
  lists in effect at the epoch; its phase shifts, GLONASS channels, interval,
  marker, position and antenna are those in effect there.

  Returns `{:ok, %Header{}}`, `{:error, :epoch_out_of_range}`, or
  `{:error, {:event_header_unreadable, message}}` where an event's header record
  does not read, which a product read from text never holds.
  """
  @spec header_at(t(), non_neg_integer()) :: {:ok, Header.t()} | {:error, term()}
  def header_at(%__MODULE__{handle: handle}, epoch_index) when is_epoch_index(epoch_index) do
    case NIF.rinex_obs_header_at(handle, epoch_index) do
      {:ok, fields} -> {:ok, Header.from_nif_map(fields)}
      {:error, _reason} = error -> error
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :rinex_obs_header_at)
  end

  def header_at(%__MODULE__{}, epoch_index) when is_integer(epoch_index), do: {:error, :epoch_out_of_range}

  @doc """
  Every header of the product with the index of the first epoch it is in effect
  at, in file order, the file header first at index `0`.

  A new header begins at each event whose records take effect. Returns
  `{:ok, [{first_epoch_index, %Header{}}]}` or
  `{:error, {:event_header_unreadable, message}}`.
  """
  @spec header_segments(t()) :: {:ok, [{non_neg_integer(), Header.t()}]} | {:error, term()}
  def header_segments(%__MODULE__{handle: handle}) do
    case NIF.rinex_obs_header_segments(handle) do
      {:ok, segments} ->
        {:ok, Enum.map(segments, fn {first, fields} -> {first, Header.from_nif_map(fields)} end)}

      {:error, _reason} = error ->
        error
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :rinex_obs_header_segments)
  end

  @doc """
  The number of records the reader skipped because their satellite token names
  no representable satellite, such as an extended GLONASS slot `R28`. Such a
  satellite named in a `SYS / PHASE SHIFT` list is kept in the record's
  `unrepresentable_satellites` and counted here too.
  """
  @spec skipped_records(t()) :: non_neg_integer()
  def skipped_records(%__MODULE__{handle: handle}) do
    NIF.rinex_obs_skipped_records(handle)
  rescue
    e in ErlangError ->
      reraise ArgumentError, [message: "could not read skipped records: #{NifCall.describe(e)}"], __STACKTRACE__
  end

  @doc """
  The surveyed a-priori receiver position `{x_m, y_m, z_m}` (ECEF meters), or
  `nil` if the file carries no `APPROX POSITION XYZ`.
  """
  @spec approx_position(t()) :: {float(), float(), float()} | nil
  def approx_position(%__MODULE__{handle: handle}) do
    NIF.rinex_obs_approx_position(handle)
  rescue
    e in ErlangError ->
      reraise ArgumentError, [message: "could not read approx position: #{NifCall.describe(e)}"], __STACKTRACE__
  end

  @doc """
  The antenna reference-point offset from the marker `{height_m, east_m, north_m}`,
  or `nil` if the file carries no `ANTENNA: DELTA H/E/N` header record.

  RINEX stores this field in local height/east/north coordinates. For a station
  whose `APPROX POSITION XYZ` is the marker, add this local offset before
  comparing an observation-derived baseline to antenna-reference-point truth.
  """
  @spec antenna_delta_hen(t()) :: {float(), float(), float()} | nil
  def antenna_delta_hen(%__MODULE__{handle: handle}) do
    NIF.rinex_obs_antenna_delta_hen(handle)
  rescue
    e in ErlangError ->
      reraise ArgumentError, [message: "could not read antenna delta H/E/N: #{NifCall.describe(e)}"], __STACKTRACE__
  end

  @doc """
  The file header's `SYS / PHASE SHIFT` records, in header order.

  Each is a `Sidereon.GNSS.RINEX.Observations.PhaseShift`. A record's `code` is
  `nil` where it names only its constellation, and its `correction_cycles` is
  `nil` where the correction is blank. The correction a phase row takes, and
  whether the header states one, is on the rows `phases/3` returns.
  """
  @spec phase_shifts(t()) :: [PhaseShift.t()]
  def phase_shifts(%__MODULE__{handle: handle}) do
    handle
    |> NIF.rinex_obs_phase_shifts()
    |> Enum.map(&PhaseShift.from_nif_map/1)
  rescue
    e in ErlangError ->
      reraise ArgumentError, [message: "could not read phase shifts: #{NifCall.describe(e)}"], __STACKTRACE__
  end

  @doc """
  The per-constellation observation-code union as a map of system letter to the
  ordered code list, e.g. `%{"G" => ["C1C", ...], "E" => [...]}`.

  Every observation and cycle slip value is index-aligned to this union. The
  lists the file header itself declares are `declared_obs_codes` of `header/1`.
  """
  @spec observation_codes(t()) :: %{String.t() => [String.t()]}
  def observation_codes(%__MODULE__{handle: handle}) do
    handle
    |> NIF.rinex_obs_codes()
    |> Map.new()
  rescue
    e in ErlangError ->
      reraise ArgumentError, [message: "could not read observation codes: #{NifCall.describe(e)}"], __STACKTRACE__
  end

  @doc """
  The GLONASS satellite slot/frequency-channel map from the file header's
  optional `GLONASS SLOT / FRQ #` records.

  The keys are RINEX satellite ids such as `"R01"` and values are the FDMA
  frequency-channel numbers used to derive GLONASS G1/G2 carrier frequencies.
  Returns `%{}` when the file header does not carry the records. A slot an
  event declares is in the header in effect after it; see `header_at/2`.
  """
  @spec glonass_slots(t()) :: glonass_slot_map()
  def glonass_slots(%__MODULE__{handle: handle}) do
    handle
    |> NIF.rinex_obs_glonass_slots()
    |> Map.new()
  rescue
    e in ErlangError ->
      reraise ArgumentError, [message: "could not read GLONASS slots: #{NifCall.describe(e)}"], __STACKTRACE__
  end

  @doc """
  Every epoch record in file order, events and cycle slip records included, as
  `Sidereon.GNSS.RINEX.Observations.Epoch` structs.

  The `:epoch` of an observation epoch is a `{{y, mo, d}, {h, mi, second_float}}`
  tuple in the file's time scale, exactly the form
  `Sidereon.GNSS.Positioning.solve/4` accepts. An event whose epoch fields are
  blank has `epoch: nil`; it is listed in its place all the same.
  """
  @spec epochs(t()) :: [epoch_entry()]
  def epochs(%__MODULE__{handle: handle}) do
    handle
    |> NIF.rinex_obs_epochs()
    |> Enum.with_index()
    |> Enum.map(fn {fields, index} -> Epoch.from_nif_map(fields, index) end)
  rescue
    e in ErlangError ->
      reraise ArgumentError, [message: "could not read epochs: #{NifCall.describe(e)}"], __STACKTRACE__
  end

  @doc """
  Extract single-frequency pseudoranges for one epoch.

  `epoch` is either the integer epoch index (from `epochs/1`) or an epoch tuple
  `{{y, mo, d}, {h, mi, s}}`, which is resolved to the observation epoch (flag 0
  or 1) at that time; an event or cycle slip record sharing the time is not
  taken for it.

  Without `:codes`, the version-aware defaults are applied across every system.
  When `:codes` is given it **defines the whole policy**: only the listed systems
  are extracted, each with its given code preference, e.g. `codes: %{"G" =>
  ["C1C"]}` yields GPS-only pseudoranges and `codes: %{"G" => ["C1C"], "C" =>
  ["C2I"]}` yields GPS + BeiDou.

  Returns `{:ok, [{"G01", range_m}, ...]}` (ascending satellite id),
  `{:error, :epoch_out_of_range}`, `{:error, :unknown_epoch}` or
  `{:error, {:unknown_system, key}}`.
  """
  @spec pseudoranges(t(), non_neg_integer() | tuple(), keyword()) ::
          {:ok, [observation()]} | {:error, term()}
  def pseudoranges(obs, epoch, opts \\ [])

  def pseudoranges(%__MODULE__{handle: handle}, index, opts) when is_epoch_index(index) do
    overrides = codes_overrides(Keyword.get(opts, :codes, %{}))

    case NIF.rinex_obs_pseudoranges(handle, index, overrides) do
      {:ok, prs} -> {:ok, prs}
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :rinex_obs_pseudoranges)
  end

  def pseudoranges(%__MODULE__{}, index, _opts) when is_integer(index), do: {:error, :epoch_out_of_range}

  def pseudoranges(%__MODULE__{} = obs, {{_y, _mo, _d}, {_h, _mi, _s}} = epoch, opts) do
    case observation_epoch_index(obs, epoch) do
      {:ok, index} -> pseudoranges(obs, index, opts)
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Every observation value for one epoch, keyed by satellite.

  `epoch` is the integer index (from `epochs/1`) or an epoch tuple
  `{{y, mo, d}, {h, mi, s}}`, resolved to the observation epoch at that time as
  `pseudoranges/3` resolves it. Unlike `pseudoranges/3` this returns the raw
  RINEX observations across code types: pseudorange, carrier phase, Doppler, and
  signal strength, so callers can build carrier-phase combinations.

  Returns `{:ok, %{satellite_id => [obs]}}` where each `obs` is

      %{code: "L1C", kind: :carrier_phase, value: 1.23e8, units: :cycles,
        lli: 0 | nil, ssi: 7 | nil}

  `kind`/`units` follow the RINEX code's leading letter (`C` → `:pseudorange`/
  `:meters`, `L` → `:carrier_phase`/`:cycles`, `D` → `:doppler`/`:hz`, `S` →
  `:signal_strength`/`:db_hz`). A blank observation has a `nil` value. An event
  and a cycle slip epoch hold no observations, so their result is `%{}`; a
  cycle slip epoch's slips are read with `cycle_slips/3`. Returns
  `{:error, :epoch_out_of_range}`, `{:error, :unknown_epoch}` or
  `{:error, {:unknown_system, key}}` on failure.

  ## Options

    * `:codes`: a per-system code filter, e.g. `%{"G" => ["L1C", "L2W"]}`. By
      default every code for every satellite is returned; a non-empty filter
      restricts the result (and the data crossing the NIF boundary) to the listed
      systems, and within each to the listed codes. A system mapped to `[]` keeps
      all of that system's codes; e.g. `%{"G" => []}` is GPS-only, all codes.
  """
  @spec values(t(), non_neg_integer() | tuple(), keyword()) ::
          {:ok, %{String.t() => [map()]}} | {:error, term()}
  def values(obs, epoch, opts \\ [])

  def values(%__MODULE__{handle: handle}, index, opts) when is_epoch_index(index) do
    overrides = codes_overrides(Keyword.get(opts, :codes, %{}))
    labelled(NIF.rinex_obs_values(handle, index, overrides))
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :rinex_obs_values)
  end

  def values(%__MODULE__{}, index, _opts) when is_integer(index), do: {:error, :epoch_out_of_range}

  def values(%__MODULE__{} = obs, {{_y, _mo, _d}, {_h, _mi, _s}} = epoch, opts) do
    case observation_epoch_index(obs, epoch) do
      {:ok, index} -> values(obs, index, opts)
      {:error, _reason} = error -> error
    end
  end

  @doc """
  The cycle slips a flag 6 epoch reports, keyed by satellite.

  RINEX writes detected and repaired cycle slips in the observation record
  layout, with the slip in place of the observation. They are slips, not
  measurements, so `values/3` does not return them. Each is labelled as
  `values/3` labels an observation: `%{code:, kind:, value:, units:, lli:,
  ssi:}`, `value` being the slip under that code and `nil` where the field is
  blank.

  `epoch` is the integer index or an epoch tuple, which is resolved to the
  cycle slip epoch (flag 6) at that time. Every other epoch has no slips, so
  its result is `%{}`. Takes the `:codes` option of `values/3` and returns its
  errors.
  """
  @spec cycle_slips(t(), non_neg_integer() | tuple(), keyword()) ::
          {:ok, %{String.t() => [map()]}} | {:error, term()}
  def cycle_slips(obs, epoch, opts \\ [])

  def cycle_slips(%__MODULE__{handle: handle}, index, opts) when is_epoch_index(index) do
    overrides = codes_overrides(Keyword.get(opts, :codes, %{}))
    labelled(NIF.rinex_obs_cycle_slips(handle, index, overrides))
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :rinex_obs_cycle_slips)
  end

  def cycle_slips(%__MODULE__{}, index, _opts) when is_integer(index), do: {:error, :epoch_out_of_range}

  def cycle_slips(%__MODULE__{} = obs, {{_y, _mo, _d}, {_h, _mi, _s}} = epoch, opts) do
    case epoch_index_at(obs, epoch, [6]) do
      {:ok, index} -> cycle_slips(obs, index, opts)
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Carrier-phase observations for one epoch (the `L*` codes), keyed by satellite.

  Every carrier-phase observation has a row, a
  `Sidereon.GNSS.RINEX.Observations.PhaseRow`, with the wavelength and the phase
  in meters when the carrier frequency is known for the satellite's system and
  band (GPS, Galileo, BeiDou, and GLONASS when the header in effect carries the
  satellite's `GLONASS SLOT / FRQ #` channel). The header in effect at the epoch
  (`header_at/2`) is the one read, so a phase shift or channel an event declares
  applies from that event on.

  ## `SYS / PHASE SHIFT` correction

  `value_cycles` and `value_m` are the phase as the file records it. RINEX 3
  stores phases already aligned, and `SYS / PHASE SHIFT` reports the correction
  that alignment applied, so the correction is returned beside the phase and
  never added to it; adding it would apply it a second time.

  Each row states what the header says about the correction. Where it states
  one, `phase_shift` is `:available` and `phase_shift_cycles` holds it; a record
  naming the satellite applies over the record for every satellite of its
  system and code, and no record, or a blank correction, is `0.0`. Where it
  states none, `phase_shift_cycles` is `nil`: `phase_shift` is `:unknown` where
  the only record covering the signal names just its constellation, and
  `:ambiguous` where one header block gives the signal different corrections,
  which are listed in `phase_shift_corrections`. Every row keeps its phase
  either way.

  `epoch` is the integer index or an epoch tuple, resolved to the observation
  epoch at that time. Returns `{:ok, %{satellite_id => [PhaseRow.t()]}}`,
  `{:error, :epoch_out_of_range}`, `{:error, :unknown_epoch}`,
  `{:error, {:unknown_system, key}}` or
  `{:error, {:event_header_unreadable, message}}`.

  Takes the `:codes` option of `values/3`.
  """
  @spec phases(t(), non_neg_integer() | tuple(), keyword()) ::
          {:ok, %{String.t() => [PhaseRow.t()]}} | {:error, term()}
  def phases(obs, epoch, opts \\ [])

  def phases(%__MODULE__{handle: handle}, index, opts) when is_epoch_index(index) do
    overrides = codes_overrides(Keyword.get(opts, :codes, %{}))

    case NIF.rinex_obs_phases(handle, index, overrides) do
      {:ok, rows} ->
        {:ok, Map.new(rows, fn {sat, phases} -> {sat, Enum.map(phases, &PhaseRow.from_nif_map/1)} end)}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :rinex_obs_phases)
  end

  def phases(%__MODULE__{}, index, _opts) when is_integer(index), do: {:error, :epoch_out_of_range}

  def phases(%__MODULE__{} = obs, {{_y, _mo, _d}, {_h, _mi, _s}} = epoch, opts) do
    case observation_epoch_index(obs, epoch) do
      {:ok, index} -> phases(obs, index, opts)
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Carrier frequency in hertz for a system letter and RINEX band digit.

  The two-argument form covers fixed-frequency systems (`"G"`, `"E"`, `"C"`)
  and returns `nil` for GLONASS because its G1/G2 carriers are FDMA
  channel-dependent. Use the three-argument form with the parsed GLONASS
  frequency-channel number:

      Sidereon.GNSS.RINEX.Observations.band_frequency_hz("R", "1", 1)
      # => 1602562500.0

  For GLONASS, band `"1"` is G1 (`1602 MHz + k * 562.5 kHz`) and band `"2"` is
  G2 (`1246 MHz + k * 437.5 kHz`), where `k` is the frequency-channel number.
  Unknown bands return `nil`.
  """
  @spec band_frequency_hz(String.t(), String.t()) :: float() | nil
  def band_frequency_hz(system, band), do: band_frequency_hz(system, band, nil)

  @spec band_frequency_hz(String.t(), String.t(), integer() | nil) :: float() | nil
  def band_frequency_hz(system, band, channel)
      when is_binary(system) and is_binary(band) and (is_integer(channel) or is_nil(channel)) do
    NIF.rinex_obs_band_frequency_hz(system, band, channel)
  end

  def band_frequency_hz(_system, _band, _channel), do: nil

  # --- helpers -------------------------------------------------------------

  defp labelled({:ok, rows}) do
    {:ok,
     Map.new(rows, fn {sat, code_values} ->
       {sat,
        Enum.map(code_values, fn {code, kind, units, value, lli, ssi} ->
          %{
            code: code,
            kind: decode_kind(kind),
            value: value,
            units: decode_units(units),
            lli: lli,
            ssi: ssi
          }
        end)}
     end)}
  end

  defp labelled({:error, reason}), do: {:error, reason}
  defp labelled(other), do: {:error, other}

  # An epoch tuple names a time, and an event or cycle slip record can share the
  # time of an observation epoch. Observations are read from observation epochs
  # only, so the tuple is resolved among those.
  defp observation_epoch_index(obs, epoch), do: epoch_index_at(obs, epoch, [0, 1])

  defp epoch_index_at(obs, epoch, flags) do
    case Enum.find(epochs(obs), fn entry -> entry.flag in flags and entry.epoch == epoch end) do
      %Epoch{index: index} -> {:ok, index}
      nil -> {:error, :unknown_epoch}
    end
  end

  defp decode_kind("pseudorange"), do: :pseudorange
  defp decode_kind("carrier_phase"), do: :carrier_phase
  defp decode_kind("doppler"), do: :doppler
  defp decode_kind("signal_strength"), do: :signal_strength
  defp decode_kind(_), do: :unknown

  defp decode_units("meters"), do: :meters
  defp decode_units("cycles"), do: :cycles
  defp decode_units("hz"), do: :hz
  defp decode_units("db_hz"), do: :db_hz
  defp decode_units(_), do: :unknown

  defp wrap(handle) when is_reference(handle), do: {:ok, %__MODULE__{handle: handle}}
  defp wrap({:error, _} = err), do: err
  defp wrap(other), do: {:error, other}

  defp crinex?(text) do
    case String.split(text, "\n", parts: 2) do
      [first | _] -> String.contains?(first, "CRINEX VERS")
      _ -> false
    end
  end

  # Normalize a `%{"G" => ["C1C"]}` override map into the NIF's
  # `[{"G", ["C1C"]}]` form. An empty map means "use the crate defaults".
  defp codes_overrides(map) when is_map(map) do
    Enum.map(map, fn {sys, codes} -> {to_string(sys), Enum.map(codes, &to_string/1)} end)
  end

  defp codes_overrides(list) when is_list(list) do
    Enum.map(list, fn {sys, codes} -> {to_string(sys), Enum.map(codes, &to_string/1)} end)
  end
end
