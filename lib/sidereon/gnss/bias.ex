defmodule Sidereon.GNSS.Bias do
  @moduledoc """
  DCB and OSB bias products backed by the core bias parsers.

  ## Read policy

  Every Bias-SINEX and CODE DCB reader takes a `:policy` option, `:strict`
  (the default) or `:lenient`. `:strict` refuses a Bias-SINEX file that departs
  from something Bias-SINEX 1.00 states explicitly, and a version other than
  `1.00`; `:lenient` reads such a file and reports each departure in
  `notices/1` as `{:departure, departure}`. For CODE DCB, `:lenient` reads a
  generated title whose time-system label names no known scale, leaving the
  set without a time scale.

  Read failures are returned as `{:error, reason}`. Core parser failures retain
  their tagged fields, for example `{:departure, {:header_layout, reason}}`,
  `{:invalid_input, field, reason}`, and `{:unsupported_version, version}`;
  filesystem failures are `{:io, message}`. See `error_reason/0` for the
  complete public term type. String writers refuse source products containing
  invalid UTF-8; byte writers retain their original bytes.

  ## Lookups

  `code_osb/5` and `code_dsb/6` return `{:ok, value_s, provenance}` for an
  available value, where `provenance` is `%{records: [index], overridden:
  [index]}`: the records the value comes from and the covering records a
  later start overrides, as indices into `records/1`. Every other outcome is
  an error naming why no value is given:

    * `{:error, :absent}` - no record covers the query;
    * `{:error, {:unsupported_scale, product_scale | nil, query_scale}}` - the
      query epoch is not on the product's time scale, or the product declares
      no usable one;
    * `{:error, {:ambiguous, [index]}}` - several records apply and give
      different values;
    * `{:error, {:carrier_frequency_required, index}}`,
      `{:error, :invalid_carrier_frequency}`,
      `{:error, {:carrier_frequency_unknown, observable}}` - a conversion
      between nanoseconds and cycles cannot be made;
    * `{:error, {:undefined_slope_reference, index}}` - a sloped record with
      neither a start nor an end;
    * `{:error, :invalid_epoch}` - the query epoch cannot be converted.
  """

  alias Sidereon.GNSS.Time
  alias Sidereon.NIF
  alias Sidereon.NifCall

  defmodule Set do
    @moduledoc """
    Parsed DCB or OSB bias product.

    `info` holds `:records`, `:skipped_records`, `:mode` (`:absolute`,
    `:relative` or `:unspecified`), `:time_scale` (the scale abbreviation, or
    `nil` when the product declares no usable time scale) and
    `:time_system_label` (the `TIME_SYSTEM` label as written, or `nil`).
    """
    @enforce_keys [:handle]
    defstruct [:handle, :info]
    @type t :: %__MODULE__{handle: reference(), info: map() | nil}
  end

  defmodule Record do
    @moduledoc """
    One bias record decoded from a DCB or OSB product.

    `value`, `sigma`, `slope` and `slope_sigma` are seconds (per second for the
    slope) when `unit` is `:nanoseconds`, and cycles when it is `:cycles`.
    `family` is `:code` or `:phase` from the observable code, or `:mixed` for a
    DSB or ISB pairing a code with a phase observable, which code and phase
    lookups do not use. `line` is the one-based source line of the row, `nil`
    for a record not read from text.
    """
    @enforce_keys [:kind, :target, :obs1, :value, :family, :unit]
    defstruct [
      :kind,
      :target,
      :svn,
      :obs1,
      :obs2,
      :valid_from,
      :valid_until,
      :value,
      :sigma,
      :slope,
      :slope_sigma,
      :family,
      :unit,
      :line
    ]

    @type t :: %__MODULE__{
            kind: :osb | :dsb | :isb,
            target: String.t(),
            svn: String.t() | nil,
            obs1: String.t(),
            obs2: String.t() | nil,
            valid_from: String.t() | nil,
            valid_until: String.t() | nil,
            value: float(),
            sigma: float() | nil,
            slope: float() | nil,
            slope_sigma: float() | nil,
            family: :code | :phase | :mixed,
            unit: :nanoseconds | :cycles,
            line: pos_integer() | nil
          }
  end

  @type policy :: :strict | :lenient
  @type provenance :: %{records: [non_neg_integer()], overridden: [non_neg_integer()]}
  @type departure_error ::
          {:header_layout, String.t()}
          | {:other_version, String.t()}
          | :missing_footer
          | {:content_after_footer, pos_integer()}
          | {:unexpected_control_line, pos_integer()}
          | {:unclosed_block, String.t(), pos_integer()}
          | {:unopened_block_end, String.t(), pos_integer()}
          | {:mismatched_block_end, String.t(), String.t(), pos_integer()}
          | {:nested_block, String.t(), String.t(), pos_integer()}
          | {:missing_block, String.t()}
          | {:unknown_block, String.t(), pos_integer()}
          | {:block_start_suffix, pos_integer()}
          | {:data_outside_block, pos_integer()}
          | {:missing_declaration, String.t()}
          | {:unsupported_bias_mode, pos_integer(), String.t()}
          | {:non_standard_time_system, pos_integer(), String.t()}
          | {:header_mode_mismatch, String.t(), String.t()}
          | {:unknown_dcb_time_system, pos_integer(), String.t()}
          | {:estimate_count_mismatch, non_neg_integer(), non_neg_integer()}
          | {:other, String.t()}
  @type error_reason ::
          {:invalid_input, String.t(), String.t()}
          | :invalid_epoch
          | {:unknown_observable, String.t()}
          | {:unsupported_version, String.t()}
          | :missing_dcb_metadata
          | :missing_clock_reference
          | {:missing_writer_metadata, String.t()}
          | :utf8
          | {:departure, departure_error()}
          | {:invalid_utf8, pos_integer()}
          | {:unsupported_time_system, String.t() | nil}
          | {:dcb_record_mismatch, non_neg_integer(), String.t()}
          | {:io, String.t()}
          | {:other, String.t()}
          | String.t()
  @type lookup_error ::
          :absent
          | {:unsupported_scale, String.t() | nil, String.t()}
          | {:ambiguous, [non_neg_integer()]}
          | {:carrier_frequency_required, non_neg_integer()}
          | :invalid_carrier_frequency
          | {:carrier_frequency_unknown, String.t()}
          | {:undefined_slope_reference, non_neg_integer()}
          | :invalid_epoch
          | {:unhandled, String.t()}
  @type lookup :: {:ok, float(), provenance()} | {:error, lookup_error() | term()}

  @spec load_bias_sinex(Path.t(), keyword()) :: {:ok, Set.t()} | {:error, error_reason()}
  def load_bias_sinex(path, opts \\ []), do: load_resource(:bias_load_sinex, [path, policy(opts)])

  @spec load_bias_sinex_lossy(Path.t(), keyword()) ::
          {:ok, Set.t(), map()} | {:error, error_reason()}
  def load_bias_sinex_lossy(path, opts \\ []), do: load_lossy(:bias_load_sinex_lossy, [path, policy(opts)])

  @spec parse_bias_sinex(binary(), keyword()) :: {:ok, Set.t()} | {:error, error_reason()}
  def parse_bias_sinex(bytes, opts \\ []), do: load_resource(:bias_parse_sinex, [bytes, policy(opts)])

  @spec parse_bias_sinex_lossy(binary(), keyword()) ::
          {:ok, Set.t(), map()} | {:error, error_reason()}
  def parse_bias_sinex_lossy(bytes, opts \\ []), do: load_lossy(:bias_parse_sinex_lossy, [bytes, policy(opts)])

  @spec load_code_dcb(Path.t(), keyword()) :: {:ok, Set.t()} | {:error, error_reason()}
  def load_code_dcb(path, opts \\ []), do: load_resource(:bias_load_code_dcb, [path, dcb_options(opts), policy(opts)])

  @spec load_code_dcb_lossy(Path.t(), keyword()) ::
          {:ok, Set.t(), map()} | {:error, error_reason()}
  def load_code_dcb_lossy(path, opts \\ []),
    do: load_lossy(:bias_load_code_dcb_lossy, [path, dcb_options(opts), policy(opts)])

  @spec parse_code_dcb(binary(), keyword()) :: {:ok, Set.t()} | {:error, error_reason()}
  def parse_code_dcb(bytes, opts \\ []),
    do: load_resource(:bias_parse_code_dcb, [bytes, dcb_options(opts), policy(opts)])

  @spec parse_code_dcb_lossy(binary(), keyword()) ::
          {:ok, Set.t(), map()} | {:error, error_reason()}
  def parse_code_dcb_lossy(bytes, opts \\ []),
    do: load_lossy(:bias_parse_code_dcb_lossy, [bytes, dcb_options(opts), policy(opts)])

  @doc "Write a set as Bias-SINEX text, refusing source rows that are not UTF-8."
  @spec write_bias_sinex(Set.t()) :: {:ok, String.t()} | {:error, error_reason()}
  def write_bias_sinex(%Set{handle: handle}), do: NIF.bias_write_sinex(handle)

  @doc "Write a set as Bias-SINEX bytes, preserving source bytes exactly."
  @spec write_bias_sinex_bytes(Set.t()) :: {:ok, binary()} | {:error, error_reason()}
  def write_bias_sinex_bytes(%Set{handle: handle}), do: NIF.bias_write_sinex_bytes(handle)

  @doc "Write a set as CODE DCB text, refusing source rows that are not UTF-8."
  @spec write_code_dcb(Set.t()) :: {:ok, String.t()} | {:error, error_reason()}
  def write_code_dcb(%Set{handle: handle}), do: NIF.bias_write_code_dcb(handle)

  @doc "Write a set as CODE DCB bytes, preserving source bytes exactly."
  @spec write_code_dcb_bytes(Set.t()) :: {:ok, binary()} | {:error, error_reason()}
  def write_code_dcb_bytes(%Set{handle: handle}), do: NIF.bias_write_code_dcb_bytes(handle)

  @doc """
  Summary of a parsed product; see `Sidereon.GNSS.Bias.Set`.
  """
  @spec info(Set.t()) :: map()
  def info(%Set{handle: handle}) do
    fields = NIF.bias_info(handle)

    %{
      records: fields.records,
      skipped_records: fields.skipped_records,
      mode: mode_atom(fields.mode),
      time_scale: fields.time_scale,
      time_system_label: fields.time_system_label
    }
  end

  @doc """
  Non-fatal findings about the product, in the order the reader made them.

  Each is a tagged tuple: `{:departure, departure}` for a departure a
  `:lenient` read accepted, `{:invalid_utf8, line}`,
  `{:repeated_declaration, line, keyword}`,
  `{:conflicting_declaration, line, keyword}`, `{:overlap, first, second}`
  (indices into `records/1`), `:dcb_time_system_assumed` and
  `{:dcb_time_system_alias, line, label}`. A departure is an atom or a tuple
  led by its name, such as `:missing_footer`, `{:other_version, version}`,
  `{:unknown_block, name, line}`, `{:non_standard_time_system, line, label}`
  or `{:estimate_count_mismatch, declared, solution_rows}`.
  """
  @spec notices(Set.t()) :: [atom() | tuple()]
  def notices(%Set{handle: handle}), do: NIF.bias_notices(handle)

  @spec records(Set.t()) :: [Record.t()]
  def records(%Set{handle: handle}) do
    handle
    |> NIF.bias_records()
    |> Enum.map(&record/1)
  end

  @doc """
  Satellite code OSB in seconds for `obs` at `epoch`, on the time scale
  `scale` (default `"GPST"`); see the module documentation for the result.
  """
  @spec code_osb(Set.t(), String.t(), String.t(), NaiveDateTime.t() | tuple(), String.t() | atom()) :: lookup()
  def code_osb(%Set{handle: handle}, satellite_id, obs, epoch, scale \\ "GPST") do
    with {:ok, epoch_s} <- Time.epoch_to_j2000_seconds_fractional(epoch) do
      NIF.bias_code_osb(handle, satellite_id, obs, epoch_s, scale_name(scale))
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :bias_code_osb)
  end

  @doc """
  Satellite code DSB `obs1 - obs2` in seconds at `epoch`, on the time scale
  `scale` (default `"GPST"`); see the module documentation for the result.
  """
  @spec code_dsb(
          Set.t(),
          String.t(),
          String.t(),
          String.t(),
          NaiveDateTime.t() | tuple(),
          String.t() | atom()
        ) :: lookup()
  def code_dsb(%Set{handle: handle}, satellite_id, obs1, obs2, epoch, scale \\ "GPST") do
    with {:ok, epoch_s} <- Time.epoch_to_j2000_seconds_fractional(epoch) do
      NIF.bias_code_dsb(handle, satellite_id, obs1, obs2, epoch_s, scale_name(scale))
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :bias_code_dsb)
  end

  def load_bias_sinex!(path, opts \\ []), do: bang(load_bias_sinex(path, opts))
  def parse_bias_sinex!(bytes, opts \\ []), do: bang(parse_bias_sinex(bytes, opts))
  def load_code_dcb!(path, opts \\ []), do: bang(load_code_dcb(path, opts))
  def parse_code_dcb!(bytes, opts \\ []), do: bang(parse_code_dcb(bytes, opts))

  def code_osb!(set, satellite_id, obs, epoch, scale \\ "GPST"),
    do: bang(code_osb(set, satellite_id, obs, epoch, scale))

  def code_dsb!(set, satellite_id, obs1, obs2, epoch, scale \\ "GPST"),
    do: bang(code_dsb(set, satellite_id, obs1, obs2, epoch, scale))

  defp load_resource(fun, args) do
    case apply(NIF, fun, args) do
      handle when is_reference(handle) ->
        set = %Set{handle: handle}
        {:ok, %{set | info: info(set)}}

      {:error, _} = err ->
        err

      other ->
        {:error, other}
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, fun)
    e in ArgumentError -> {:error, e.message}
  end

  defp load_lossy(fun, args) do
    case apply(NIF, fun, args) do
      {:ok, handle, skipped} ->
        set = %Set{handle: handle}
        {:ok, %{set | info: info(set)}, %{skipped_records: skipped}}

      {:error, _} = err ->
        err

      other ->
        {:error, other}
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, fun)
    e in ArgumentError -> {:error, e.message}
  end

  defp policy(opts) do
    case Keyword.get(opts, :policy, :strict) do
      :strict -> "strict"
      :lenient -> "lenient"
      other -> raise ArgumentError, "unknown bias read policy #{inspect(other)}; expected :strict or :lenient"
    end
  end

  defp dcb_options(opts) do
    opts = Keyword.delete(opts, :policy)

    if opts != [] do
      {obs1, obs2} = Keyword.get(opts, :pair, {"C1C", "C2W"})

      %{
        obs1: obs1,
        obs2: obs2,
        year: Keyword.fetch!(opts, :year),
        month: Keyword.fetch!(opts, :month),
        time_scale: scale_name(Keyword.get(opts, :time_scale, "GPST")),
        receiver_system: system_letter(Keyword.get(opts, :receiver_system))
      }
    end
  end

  defp record(fields) do
    %Record{
      kind: kind_atom(fields.kind),
      target: fields.target,
      svn: fields.svn,
      obs1: fields.obs1,
      obs2: fields.obs2,
      valid_from: fields.valid_from,
      valid_until: fields.valid_until,
      value: fields.value,
      sigma: fields.sigma,
      slope: fields.slope,
      slope_sigma: fields.slope_sigma,
      family: family_atom(fields.family),
      unit: unit_atom(fields.unit),
      line: fields.line
    }
  end

  defp bang({:ok, value}), do: value
  defp bang({:ok, value, _diagnostics}), do: value
  defp bang({:error, reason}), do: raise(ArgumentError, "bias operation failed: #{inspect(reason)}")

  defp kind_atom("osb"), do: :osb
  defp kind_atom("dsb"), do: :dsb
  defp kind_atom("isb"), do: :isb

  defp family_atom("code"), do: :code
  defp family_atom("phase"), do: :phase
  defp family_atom("mixed"), do: :mixed

  defp unit_atom("ns"), do: :nanoseconds
  defp unit_atom("cyc"), do: :cycles

  defp mode_atom("absolute"), do: :absolute
  defp mode_atom("relative"), do: :relative
  defp mode_atom("unspecified"), do: :unspecified

  defp scale_name(scale) when is_atom(scale), do: scale |> Atom.to_string() |> String.upcase()
  defp scale_name(scale) when is_binary(scale), do: String.upcase(scale)

  defp system_letter(nil), do: nil
  defp system_letter(:gps), do: "G"
  defp system_letter(:glonass), do: "R"
  defp system_letter(:galileo), do: "E"
  defp system_letter(:beidou), do: "C"
  defp system_letter(:qzss), do: "J"
  defp system_letter(:navic), do: "I"
  defp system_letter(:sbas), do: "S"
  defp system_letter(value) when is_binary(value), do: value
end
