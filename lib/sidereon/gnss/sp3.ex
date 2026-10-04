defmodule Sidereon.GNSS.SP3 do
  @moduledoc """
  SP3-c / SP3-d precise-ephemeris products (IGS precise orbits + clocks).

  This is the Elixir surface over the `sidereon-core` SP3 parser and
  `scipy.interpolate`-matched position/clock interpolation. It is **not** the
  JPL-SPK reader (`Sidereon.Ephemeris`): SP3 carries GNSS satellite states in the
  ITRF/IGS ECEF frame, in meters, tagged by a GNSS satellite id like `"G01"`.

  A file is parsed **once** into a resource handle held by the BEAM; evaluation
  operates on that handle and never re-reads the file.

  ## Example

      {:ok, sp3} = Sidereon.GNSS.SP3.load("/path/to/igs.sp3")
      {:ok, state} =
        Sidereon.GNSS.SP3.position(sp3, "G01", ~N[2020-06-24 00:00:00])

      state.x_m       # ITRF/IGS ECEF X, meters
      state.clock_s   # satellite clock offset, seconds (or nil if no estimate)

  ## Epochs

  The query epoch is interpreted in the file's **own** time scale (read from the
  SP3 header, typically GPST). Pass a `NaiveDateTime` or a
  `{{year, month, day}, {hour, minute, second}}` tuple; it is converted to the
  split Julian date with the same midnight-boundary convention the parser uses
  (no leap-second shifting; the epoch stays in the file's scale).
  """

  alias Sidereon.GNSS.Core.Types
  alias Sidereon.GNSS.Distribution
  alias Sidereon.GNSS.Distribution.ProductIdentity
  alias Sidereon.GNSS.ExactCache
  alias Sidereon.GNSS.PreciseEphemeris.Interpolant
  alias Sidereon.GNSS.PreciseEphemeris.StateBatch
  alias Sidereon.GNSS.PreciseEphemerisAccuracySample
  alias Sidereon.GNSS.PreciseEphemerisSample
  alias Sidereon.GNSS.SP3.RawRecordAccuracy
  alias Sidereon.GNSS.SP3.RecordAccuracy
  alias Sidereon.GNSS.Time
  alias Sidereon.GNSS.Time.ExactEpochQuery
  alias Sidereon.NIF
  alias Sidereon.NifCall

  @enforce_keys [:handle, :time_scale, :coverage_start, :coverage_end]
  defstruct [:handle, :time_scale, :coverage_start, :coverage_end]

  @type t :: %__MODULE__{
          handle: reference(),
          time_scale: String.t(),
          coverage_start: float(),
          coverage_end: float()
        }

  @typedoc "Typed refusal for a numeric SP3 interpolation-policy input."
  @type interpolation_error :: %{
          kind: String.t(),
          field: String.t(),
          value: String.t(),
          reason: String.t()
        }

  @typedoc "Exact declared-span representation found by the core validator."
  @type exact_coverage :: :half_open | :inclusive

  defmodule ExactRequest do
    @moduledoc """
    Source-independent request used to validate one exact SP3 product.

    Construct requests with `new/4` or `from_identity/1`. The opaque core
    handle retains identity-derived format-revision and producing-agency
    constraints; the remaining fields are exposed for inspection only.
    """

    alias Sidereon.NIF
    alias Sidereon.NifCall

    @derive {Inspect, except: [:handle]}
    @enforce_keys [:handle, :date, :span, :sample]
    defstruct [:handle, :date, :issue, :span, :sample, :format_version, :expected_agency]

    @type t :: %__MODULE__{
            handle: reference(),
            date: Date.t(),
            issue: String.t() | nil,
            span: String.t(),
            sample: String.t(),
            format_version: String.t() | nil,
            expected_agency: String.t() | nil
          }

    @doc """
    Build and validate an exact SP3 request.

    `opts` accepts `:issue` (`HHMM`) and `:expected_agency` (the one-to-four
    character upper-case SP3 producer code).
    """
    @spec new(Date.t() | NaiveDateTime.t() | tuple(), String.t(), String.t(), keyword()) ::
            {:ok, t()} | {:error, term()}
    def new(date, span, sample, opts \\ [])

    def new(date, span, sample, opts) when is_binary(span) and is_binary(sample) and is_list(opts) do
      with {:ok, date} <- normalize_date(date),
           issue = optional_string(Keyword.get(opts, :issue)),
           expected_agency = optional_string(Keyword.get(opts, :expected_agency)),
           {:ok, handle} <-
             NIF.sp3_exact_request_new(
               date.year,
               date.month,
               date.day,
               issue,
               span,
               sample,
               expected_agency
             ) do
        {:ok, from_handle(handle)}
      end
    rescue
      e in ErlangError -> NifCall.error(e, __STACKTRACE__, :sp3_exact_request_new)
    end

    def new(_date, _span, _sample, _opts),
      do: {:error, {:exact_sp3_validation_failed, "invalid exact SP3 request arguments"}}

    @doc "Build an exact request from a complete catalog product identity."
    @spec from_identity(ProductIdentity.t()) :: {:ok, t()} | {:error, term()}
    def from_identity(%ProductIdentity{} = identity) do
      with {:ok, handle} <- NIF.sp3_exact_request_from_identity(ExactCache.identity_fields(identity)) do
        {:ok, from_handle(handle)}
      end
    rescue
      e in ErlangError -> NifCall.error(e, __STACKTRACE__, :sp3_exact_request_from_identity)
      _error -> {:error, {:exact_sp3_validation_failed, "invalid exact SP3 identity"}}
    end

    def from_identity(_identity), do: {:error, {:exact_sp3_validation_failed, "expected a product identity"}}

    @doc "Return a copy requiring a particular SP3 producing-agency code."
    @spec require_agency(t(), String.t()) :: {:ok, t()} | {:error, term()}
    def require_agency(%__MODULE__{handle: handle}, agency) when is_binary(agency) do
      with {:ok, updated} <- NIF.sp3_exact_request_require_agency(handle, agency) do
        {:ok, from_handle(updated)}
      end
    rescue
      e in ErlangError -> NifCall.error(e, __STACKTRACE__, :sp3_exact_request_require_agency)
    end

    def require_agency(_request, _agency),
      do: {:error, {:exact_sp3_validation_failed, "invalid exact SP3 agency constraint"}}

    defp from_handle(handle) do
      {{year, month, day}, issue, span, sample, format_version, expected_agency} =
        NIF.sp3_exact_request_fields(handle)

      %__MODULE__{
        handle: handle,
        date: Date.new!(year, month, day),
        issue: issue,
        span: span,
        sample: sample,
        format_version: format_version,
        expected_agency: expected_agency
      }
    end

    defp normalize_date(%Date{} = date), do: {:ok, date}
    defp normalize_date(%NaiveDateTime{} = datetime), do: {:ok, NaiveDateTime.to_date(datetime)}
    defp normalize_date({year, month, day}), do: Date.new(year, month, day)
    defp normalize_date({{year, month, day}, _time}), do: Date.new(year, month, day)

    defp normalize_date(_date), do: {:error, {:exact_sp3_validation_failed, "invalid exact SP3 date"}}

    defp optional_string(nil), do: nil
    defp optional_string(value) when is_binary(value), do: value
    defp optional_string(value), do: to_string(value)
  end

  defmodule State do
    @moduledoc """
    An SP3 satellite state at one epoch.

    Position is ITRF/IGS-realization ECEF, in meters (frame and unit are fixed
    in the field names per the spec's frames-in-the-type-system rule). `clock_s`
    is the satellite clock offset in seconds, or `nil` when the product carries
    no clock estimate for that satellite/epoch.

    Exact parsed records may also carry `velocity_m_s`, `clock_rate_s_s`, and
    the four SP3 status flags. Interpolated states leave velocity and clock-rate
    as `nil` and all flags as `false`.
    """
    @enforce_keys [:x_m, :y_m, :z_m, :clock_s]
    defstruct [
      :x_m,
      :y_m,
      :z_m,
      :clock_s,
      :velocity_m_s,
      :clock_rate_s_s,
      clock_event: false,
      clock_predicted: false,
      maneuver: false,
      orbit_predicted: false
    ]

    @type vec3 :: {float(), float(), float()}

    @type t :: %__MODULE__{
            x_m: float(),
            y_m: float(),
            z_m: float(),
            clock_s: float() | nil,
            velocity_m_s: vec3() | nil,
            clock_rate_s_s: float() | nil,
            clock_event: boolean(),
            clock_predicted: boolean(),
            maneuver: boolean(),
            orbit_predicted: boolean()
          }
  end

  @doc """
  Load and parse an SP3-c / SP3-d file into a product handle.

  Returns `{:ok, %Sidereon.GNSS.SP3{}}` or `{:error, reason}`. The file is read and
  parsed exactly once; the parsed product is held as a resource handle.

  Options:
    * `:gap_threshold_factor` - multiple of nominal node spacing above which
      consecutive records mark a coverage gap (default `1.5`, must be > 1.0).

  A numeric factor at or below `1.0` returns `{:error, interpolation_error()}`
  with the supplied value and core refusal reason.
  """
  @spec load(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def load(path, opts \\ []) when is_binary(path) and is_list(opts) do
    with {:ok, bytes} <- File.read(path) do
      parse_bytes(bytes, opts)
    end
  end

  @doc """
  Like `load/2` but raises on failure.
  """
  @spec load!(String.t(), keyword()) :: t()
  def load!(path, opts \\ []) when is_binary(path) and is_list(opts) do
    case load(path, opts) do
      {:ok, sp3} -> sp3
      {:error, reason} -> raise ArgumentError, "could not load SP3 #{path}: #{inspect(reason)}"
    end
  end

  @doc """
  Parse an in-memory SP3 byte buffer (already decompressed) into a handle.

  Options:
    * `:gap_threshold_factor` - multiple of nominal node spacing above which
      consecutive records mark a coverage gap (default `1.5`, must be > 1.0).

  A numeric factor at or below `1.0` returns
  `{:error, interpolation_error()}` with the supplied factor and core refusal
  reason. SP3 grammar failures keep their existing error term.
  """
  @spec parse(binary(), keyword()) :: {:ok, t()} | {:error, term()}
  def parse(bytes, opts \\ []) when is_binary(bytes) and is_list(opts), do: parse_bytes(bytes, opts)

  defp parse_bytes(bytes, opts) do
    with {:ok, factor} <- normalize_gap_threshold_factor(opts) do
      case NIF.sp3_parse(bytes, factor) do
        handle when is_reference(handle) ->
          from_handle(handle, bytes)

        {:error, _} = err ->
          err

        other ->
          {:error, other}
      end
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :sp3_parse)
  end

  @doc """
  Parse and validate decompressed SP3 bytes against an exact request.

  Returns the parsed product together with `:half_open` or `:inclusive` to
  identify the accepted boundary representation. Parse, identity, cadence,
  grid, and span failures are returned as exact-product integrity errors.

  Options:
    * `:gap_threshold_factor` - multiple of nominal node spacing above which
      consecutive records mark a coverage gap (default `1.5`, must be > 1.0).
  """
  @spec parse_exact(binary(), ExactRequest.t(), keyword()) ::
          {:ok, t(), exact_coverage()} | {:error, term()}
  def parse_exact(bytes, request, opts \\ [])

  def parse_exact(bytes, %ExactRequest{handle: request}, opts) when is_binary(bytes) and is_list(opts) do
    with {:ok, factor} <- normalize_gap_threshold_factor(opts) do
      case NIF.sp3_parse_exact(bytes, request, factor) do
        {:ok, {handle, coverage}} when is_reference(handle) and coverage in [:half_open, :inclusive] ->
          with {:ok, product} <- from_handle(handle, bytes) do
            {:ok, product, coverage}
          end

        {:error, _reason} = error ->
          error

        other ->
          {:error, other}
      end
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :sp3_parse_exact)
  end

  def parse_exact(_bytes, _request, _opts),
    do: {:error, {:exact_sp3_validation_failed, "invalid exact SP3 parse arguments"}}

  @doc """
  Validate an already parsed SP3 product against an exact request.

  The returned coverage atom has the same meaning as `parse_exact/2`.
  """
  @spec validate_exact(t(), ExactRequest.t()) ::
          {:ok, exact_coverage()} | {:error, term()}
  def validate_exact(%__MODULE__{handle: product}, %ExactRequest{handle: request}) do
    NIF.sp3_validate_exact(product, request)
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :sp3_validate_exact)
  end

  def validate_exact(_product, _request),
    do: {:error, {:exact_sp3_validation_failed, "invalid exact SP3 validation arguments"}}

  @doc """
  Return the product coverage interval.

  The start and end are the first and last SP3 node epochs, expressed as
  seconds since J2000 in the product's own time scale. Public evaluators reject
  epochs outside this interval by default; pass `extrapolate: true` to the
  evaluator to opt into the lower-level interpolation behavior.
  """
  @spec coverage(t()) :: %{start_j2000_s: float(), end_j2000_s: float(), time_scale: String.t()}
  def coverage(%__MODULE__{coverage_start: coverage_start, coverage_end: coverage_end, time_scale: time_scale}) do
    %{start_j2000_s: coverage_start, end_j2000_s: coverage_end, time_scale: time_scale}
  end

  @doc false
  @spec covers_epoch?(t(), NaiveDateTime.t() | tuple()) :: boolean()
  def covers_epoch?(%__MODULE__{coverage_start: start_s, coverage_end: end_s}, epoch) do
    {:ok, epoch_s} = Time.epoch_to_j2000_seconds_fractional(epoch)
    epoch_s >= start_s and epoch_s <= end_s
  end

  @doc false
  @spec covers_window?(t(), {NaiveDateTime.t(), NaiveDateTime.t()}) :: boolean()
  def covers_window?(%__MODULE__{} = sp3, {t0, t1}) do
    covers_epoch?(sp3, t0) and covers_epoch?(sp3, t1)
  end

  @doc """
  Return the SP3/RINEX satellite identifiers declared by the product header.

  These are canonical three-character tokens such as `"G01"`, `"E12"`, or
  `"C30"`. The list is read from the already-loaded SP3 handle; no file I/O or
  interpolation is performed.

  ## Examples

      {:ok, sp3} = Sidereon.GNSS.SP3.parse(sp3_bytes)
      ids = Sidereon.GNSS.SP3.satellite_ids(sp3)
      "G01" in ids
  """
  @spec satellite_ids(t()) :: [String.t()]
  def satellite_ids(%__MODULE__{handle: handle}) do
    NIF.sp3_satellite_ids(handle)
  rescue
    e in ErlangError ->
      reraise ArgumentError, [message: "could not read SP3 satellite ids: #{NifCall.describe(e)}"], __STACKTRACE__
  end

  @doc """
  Alias for `satellite_ids/1`, matching the Python/WASM `satellites` accessor.
  """
  @spec satellites(t()) :: [String.t()]
  def satellites(%__MODULE__{} = sp3), do: satellite_ids(sp3)

  @doc """
  Number of parsed epochs held by the SP3 product.

  This is the count of actual `*` epoch nodes parsed from the file, not just the
  header declaration. The value matches `length(epochs_j2000_seconds(sp3))` for
  ordinary SP3 products.
  """
  @spec epoch_count(t()) :: non_neg_integer()
  def epoch_count(%__MODULE__{handle: handle}) do
    NIF.sp3_epoch_count(handle)
  rescue
    e in ErlangError ->
      reraise ArgumentError, [message: "could not read SP3 epoch count: #{NifCall.describe(e)}"], __STACKTRACE__
  end

  @doc """
  Return the epoch count declared on SP3 header line 1.

  This can differ from `epoch_count/1` for a truncated or inconsistent product
  accepted by the compatibility parser. `validate_exact/2` requires equality.
  """
  @spec declared_epoch_count(t()) :: non_neg_integer()
  def declared_epoch_count(%__MODULE__{handle: handle}) do
    NIF.sp3_declared_epoch_count(handle)
  rescue
    e in ErlangError ->
      reraise ArgumentError,
              [message: "could not read declared SP3 epoch count: #{NifCall.describe(e)}"],
              __STACKTRACE__
  end

  @doc """
  Return the start epoch declared on SP3 header line 1.

  The value is seconds since J2000 in the product's own time scale, or `nil`
  when the permissive parser could not interpret the declaration.
  """
  @spec declared_start_j2000_seconds(t()) :: float() | nil
  def declared_start_j2000_seconds(%__MODULE__{handle: handle}) do
    NIF.sp3_declared_start_j2000_seconds(handle)
  rescue
    e in ErlangError ->
      reraise ArgumentError, [message: "could not read declared SP3 start: #{NifCall.describe(e)}"], __STACKTRACE__
  end

  @doc "Alias for `declared_start_j2000_seconds/1`."
  @spec declared_start_j2000_s(t()) :: float() | nil
  def declared_start_j2000_s(%__MODULE__{} = sp3), do: declared_start_j2000_seconds(sp3)

  @doc """
  Return the parsed SP3 epoch grid as seconds since J2000.

  Values are in the product's own time scale, ascending, and correspond exactly
  to the parsed SP3 node epochs. Use this accessor when a caller needs the
  original sample grid rather than an interpolated state.
  """
  @spec epochs_j2000_seconds(t()) :: [float()]
  def epochs_j2000_seconds(%__MODULE__{handle: handle}) do
    NIF.sp3_epochs_j2000_seconds(handle)
  rescue
    e in ErlangError ->
      reraise ArgumentError, [message: "could not read SP3 epochs: #{NifCall.describe(e)}"], __STACKTRACE__
  end

  @doc """
  Return the position-interpolation gap threshold factor carried by the product.
  """
  @spec gap_threshold_factor(t()) :: float()
  def gap_threshold_factor(%__MODULE__{handle: handle}) do
    NIF.sp3_gap_threshold_factor(handle)
  rescue
    e in ErlangError ->
      reraise ArgumentError,
              [message: "could not read SP3 gap threshold factor: #{NifCall.describe(e)}"],
              __STACKTRACE__
  end

  @doc """
  Return the time reach of the product's position-interpolation stencil.

  The core derives both extents from the parsed epoch interval and the same
  node count used by the interpolator. Callers never supply a stencil width.
  """
  @spec stencil_extent(t()) ::
          {:ok, %{before_s: float(), after_s: float()}} | {:error, term()}
  def stencil_extent(%__MODULE__{handle: handle}) do
    case NIF.sp3_stencil_extent(handle) do
      {:ok, {before_s, after_s}} -> {:ok, %{before_s: before_s, after_s: after_s}}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :sp3_stencil_extent)
  end

  @doc """
  Epochs of the position nodes that some interpolation of `satellite` in the
  inclusive J2000-seconds window selects, ascending; `[]` when no query in the
  window is served for it.

  The core applies the position interpolator's own serving and node-selection
  rule to the satellite's node series, under the product's interpolation
  options. Merge continuity verdicts read the merged product's nodes this way.
  """
  @spec selected_nodes(t(), String.t(), number(), number()) :: {:ok, [float()]} | {:error, term()}
  def selected_nodes(%__MODULE__{handle: handle}, satellite, from_j2000_s, through_j2000_s)
      when is_binary(satellite) and is_number(from_j2000_s) and is_number(through_j2000_s) do
    NIF.sp3_selected_nodes(handle, satellite, from_j2000_s / 1.0, through_j2000_s / 1.0)
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :sp3_selected_nodes)
  end

  def selected_nodes(_sp3, _satellite, _from_j2000_s, _through_j2000_s), do: {:error, :invalid_selected_nodes_query}

  @doc """
  Attest that this product is physically continuous, or report each violation.

  A merged product is assembled per satellite and epoch from several analysis
  centers, which is exactly the operation that can splice two physically
  inconsistent arcs together while every input stays individually well-formed.
  This runs two checks with different jobs:

    * a physical earth-fixed speed gate, whose bound is a true upper bound for
      the orbit class, so it cannot false-positive. It catches gross corruption
      (a record from the wrong satellite or the wrong day) and is insensitive by
      construction: adjacent GNSS MEO epochs are hundreds of kilometres apart,
      so a metre-scale splice moves the implied speed by a fraction of a percent.

    * a hold-out interpolation residual, which supplies the sensitivity. Each
      interior sample is predicted from its neighbours through the product's own
      interpolator and compared against the stored record, resolving a splice of
      a few metres.

  Options:

    * `:orbit_class` - `:meo_gnss` (default), `:geosynchronous`, `:leo`, or
      `nil` to disable the speed gate.
    * `:residual_tolerance_m` - tolerance for the residual check, default
      `1.0`; `nil` disables it.

  Returns `{:ok, report}` where `report` has `:defects`, `:attested?`, and the
  counts of what was examined, so "checked and clean" stays distinguishable from
  "not checked". This reports rather than refuses: whether a product with
  defects is acceptable is the caller's decision.

  Each defect has `:kind` (`:duplicate_epoch`, `:single_sample_series`,
  `:unusable_sample`, `:speed_bound` or `:hold_out_residual`), `:satellite`, the summary
  `:from_j2000_s`, `:to_j2000_s`, `:magnitude` and `:bound` (`nil` where the
  kind has none), and every field of its kind under the core's name:
  `:epoch_j2000_s` and `:occurrences`; `:interval_s`, `:displacement_m`,
  `:implied_speed_m_s` and `:bound_m_s`; or `:epoch_j2000_s`,
  `:preceding_j2000_s`, `:residual_m`, `:tolerance_m` and `:node_epochs_j2000_s`.
  An `:unusable_sample` also includes `:sample_index`, `:epoch_j2000_s` (when
  placed), and a `:reason` of `:epoch_not_placed` or `:non_finite_position`.

  ## Example

      {:ok, report} = Sidereon.GNSS.SP3.check_continuity(sp3)
      report.attested?
  """
  @spec check_continuity(t(), keyword()) :: {:ok, map()} | {:error, term()}
  def check_continuity(%__MODULE__{handle: handle}, opts \\ []) do
    with {:ok, class, tolerance, gap_factor} <- normalize_continuity_options(opts) do
      case NIF.sp3_check_continuity(handle, class, tolerance, gap_factor) do
        {:ok, report} -> {:ok, decode_continuity_report(report)}
        {:error, reason} -> {:error, reason}
      end
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :sp3_check_continuity)
  end

  @doc """
  Decide whether recorded defects can influence an inclusive product-scale
  J2000-seconds evaluation window.

  The existing product-wide checks and options are unchanged. The core filters
  their report using the interpolation reach returned by `stencil_extent/1`,
  retaining both the influencing subset and every product-wide finding.
  """
  @spec continuity_verdict(t(), number(), number(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def continuity_verdict(sp3, from_j2000_s, through_j2000_s, opts \\ [])

  def continuity_verdict(%__MODULE__{handle: handle}, from_j2000_s, through_j2000_s, opts)
      when is_number(from_j2000_s) and is_number(through_j2000_s) do
    with {:ok, class, tolerance, gap_factor} <- normalize_continuity_options(opts),
         {:ok, verdict} <-
           NIF.sp3_continuity_verdict(
             handle,
             from_j2000_s / 1.0,
             through_j2000_s / 1.0,
             class,
             tolerance,
             gap_factor
           ) do
      {:ok, decode_window_continuity_verdict(verdict)}
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :sp3_continuity_verdict)
  end

  def continuity_verdict(_sp3, _from_j2000_s, _through_j2000_s, _opts), do: {:error, :invalid_continuity_window}

  defp decode_continuity_report({defects, {pairs, residuals, skipped}}) do
    decoded = Enum.map(defects, &decode_continuity_defect/1)

    %{
      defects: decoded,
      attested?: decoded == [],
      pairs_checked: pairs,
      residuals_checked: residuals,
      residuals_skipped: skipped
    }
  end

  # The summary fields every kind fills where it has them, then every field of
  # the defect's kind under the core's name; the NIF leaves the fields of other
  # kinds nil, and none of a kind's own fields is ever nil.
  defp decode_continuity_defect({kind, satellite, {from_s, to_s}, {magnitude, bound}, details}) do
    kind_fields = for {field, value} <- details, value != nil, into: %{}, do: {field, value}

    kind_fields =
      if kind == "unusable_sample" and Map.has_key?(kind_fields, :reason),
        do: Map.update!(kind_fields, :reason, &unusable_sample_reason/1),
        else: kind_fields

    Map.merge(
      %{
        kind: continuity_defect_kind(kind),
        satellite: satellite,
        from_j2000_s: from_s,
        to_j2000_s: to_s,
        magnitude: magnitude,
        bound: bound
      },
      kind_fields
    )
  end

  defp continuity_defect_kind("duplicate_epoch"), do: :duplicate_epoch
  defp continuity_defect_kind("single_sample_series"), do: :single_sample_series
  defp continuity_defect_kind("unusable_sample"), do: :unusable_sample
  defp continuity_defect_kind("speed_bound"), do: :speed_bound
  defp continuity_defect_kind("hold_out_residual"), do: :hold_out_residual

  defp unusable_sample_reason("epoch_not_placed"), do: :epoch_not_placed
  defp unusable_sample_reason("non_finite_position"), do: :non_finite_position

  defp decode_merge_continuity_violation({defect, from_sources, to_sources, crosses_contributors, cells, sources}) do
    %{
      defect: decode_continuity_defect(defect),
      from_sources: from_sources,
      to_sources: to_sources,
      cells: Enum.map(cells, &decode_merge_continuity_cell/1),
      sources: sources,
      crosses_contributors: crosses_contributors
    }
  end

  defp decode_merge_continuity_cell(%{epoch_j2000_s: epoch_j2000_s, role: role, selection: selection}) do
    %{
      epoch_j2000_s: epoch_j2000_s,
      role: merge_continuity_cell_role(role),
      selection: decode_cell_selection(selection)
    }
  end

  defp merge_continuity_cell_role("held_out"), do: :held_out
  defp merge_continuity_cell_role("interpolation_node"), do: :interpolation_node
  defp merge_continuity_cell_role("pair_end"), do: :pair_end
  defp merge_continuity_cell_role("repeated_epoch"), do: :repeated_epoch

  defp decode_cell_selection(nil), do: nil

  defp decode_cell_selection(%{kind: "single_source", source: source}), do: %{kind: :single_source, source: source}

  defp decode_cell_selection(%{kind: "precedence", source: source, members: members}),
    do: %{kind: :precedence, source: source, members: members}

  defp decode_cell_selection(%{kind: "combined", rule: rule, members: members}),
    do: %{kind: :combined, rule: merge_rule(rule), members: members}

  defp merge_rule("mean"), do: :mean
  defp merge_rule("median"), do: :median
  defp merge_rule("precedence"), do: :precedence

  defp decode_merge_continuity_report(nil), do: nil

  defp decode_merge_continuity_report({report, violations}) do
    decoded_violations = Enum.map(violations, &decode_merge_continuity_violation/1)

    report
    |> decode_continuity_report()
    |> Map.put(:violations, decoded_violations)
    |> Map.put(:splices, Enum.filter(decoded_violations, & &1.crosses_contributors))
  end

  defp decode_window_continuity_verdict(
         {decision, accepted, influencing_defects, influencing_splices, all_defects, all_splices}
       ) do
    %{
      decision: continuity_decision(decision),
      accepted: accepted,
      influencing_defects: Enum.map(influencing_defects, &decode_continuity_defect/1),
      influencing_splices: Enum.map(influencing_splices, &decode_merge_continuity_violation/1),
      all_defects: Enum.map(all_defects, &decode_continuity_defect/1),
      all_splices: Enum.map(all_splices, &decode_merge_continuity_violation/1)
    }
  end

  defp continuity_decision("accept"), do: :accept
  defp continuity_decision("refuse"), do: :refuse

  defp normalize_continuity_options(opts) when is_list(opts) do
    orbit_class =
      case Keyword.get(opts, :orbit_class, :meo_gnss) do
        nil -> nil
        atom when atom in [:meo_gnss, :geosynchronous, :leo] -> Atom.to_string(atom)
        other -> {:bad_orbit_class, other}
      end

    tolerance = Keyword.get(opts, :residual_tolerance_m, 1.0)
    gap_threshold_factor = Keyword.get(opts, :gap_threshold_factor)

    cond do
      match?({:bad_orbit_class, _}, orbit_class) ->
        {:bad_orbit_class, other} = orbit_class
        {:error, {:bad_orbit_class, other}}

      # A residual tolerance is a distance.
      not (is_nil(tolerance) or (is_number(tolerance) and tolerance >= 0)) ->
        {:error,
         {:continuity_options,
          %{
            field: :residual_tolerance_m,
            value: if(is_number(tolerance), do: json_safe_number(tolerance), else: inspect(tolerance)),
            reason: if(is_number(tolerance) and tolerance < 0, do: :negative, else: :not_numeric_or_finite)
          }}}

      not (is_nil(gap_threshold_factor) or is_number(gap_threshold_factor)) ->
        {:error, {:bad_gap_threshold_factor, gap_threshold_factor}}

      true ->
        tolerance = if is_number(tolerance), do: tolerance / 1.0
        gap_factor = if is_number(gap_threshold_factor), do: gap_threshold_factor / 1.0
        {:ok, orbit_class, tolerance, gap_factor}
    end
  end

  defp normalize_continuity_options(opts), do: {:error, {:bad_continuity_options, opts}}

  @doc """
  Return observed/predicted status derived from the SP3 record flags.

  `:epochs` contains one entry per parsed epoch with `:observed`,
  `:orbit_predicted_satellites`, and `:clock_predicted_satellites`. The
  `:observed_through` split-Julian-date map is the last epoch before the first
  predicted record, or the final epoch for a fully observed product. It is
  `nil` when the first epoch is already predicted or the product is empty.

  This metadata uses the file's actual per-record `P` flags and never assumes a
  fixed ultra-rapid observed duration. Per-cell flags are also available from
  `state/3` and `states_at/2`.
  """
  @spec prediction_summary(t()) :: %{
          epochs: [map()],
          observed_through: map() | nil
        }
  def prediction_summary(%__MODULE__{handle: handle}) do
    {epochs, observed_through} = NIF.sp3_prediction_summary(handle)

    %{
      epochs:
        Enum.map(epochs, fn {{jd_whole, jd_fraction}, observed, orbit_satellites, clock_satellites} ->
          %{
            jd_whole: jd_whole,
            jd_fraction: jd_fraction,
            observed: observed,
            orbit_predicted_satellites: orbit_satellites,
            clock_predicted_satellites: clock_satellites
          }
        end),
      observed_through: split_jd_map(observed_through)
    }
  rescue
    e in ErlangError ->
      reraise ArgumentError, [message: "could not read SP3 prediction status: #{NifCall.describe(e)}"], __STACKTRACE__
  end

  @doc """
  Return the exact parsed state of `sat_id` at `epoch_index`.

  `epoch_index` is zero-based into `epochs_j2000_seconds/1`. This accessor does
  no interpolation: the returned state is the record stored in the SP3 file,
  including optional velocity, optional clock-rate, and the SP3 status flags.
  Missing all-zero orbit records are not fabricated; querying such a cell returns
  `{:error, {:unknown_satellite, sat_id}}`.

  Returns `{:ok, %Sidereon.GNSS.SP3.State{}}` or `{:error, reason}`.
  """
  @spec state(t(), String.t(), non_neg_integer()) :: {:ok, State.t()} | {:error, term()}
  def state(%__MODULE__{handle: handle}, sat_id, epoch_index)
      when is_binary(sat_id) and is_integer(epoch_index) and epoch_index >= 0 do
    with {:ok, system_letter, prn} <- Types.parse_sat_id(sat_id) do
      case NIF.sp3_state(handle, system_letter, prn, epoch_index) do
        {:ok, encoded} -> {:ok, decode_state(encoded)}
        {:error, _} = err -> err
        other -> {:error, other}
      end
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :sp3_state)
  end

  def state(%__MODULE__{}, sat_id, epoch_index) do
    cond do
      not is_binary(sat_id) -> {:error, {:bad_sat_id, sat_id}}
      not is_integer(epoch_index) or epoch_index < 0 -> {:error, {:bad_epoch_index, epoch_index}}
    end
  end

  @doc """
  Return all exact parsed states at `epoch_index`.

  The result is an ascending satellite-id list of `{satellite_id, state}` pairs
  for records actually present at that SP3 epoch. Satellites whose position
  record is the SP3 missing-orbit sentinel are absent from the list.

  Returns `{:ok, [{satellite_id, %Sidereon.GNSS.SP3.State{}}]}` or
  `{:error, reason}`.
  """
  @spec states_at(t(), non_neg_integer()) ::
          {:ok, [{String.t(), State.t()}]} | {:error, term()}
  def states_at(%__MODULE__{handle: handle}, epoch_index) when is_integer(epoch_index) and epoch_index >= 0 do
    case NIF.sp3_states_at(handle, epoch_index) do
      {:ok, rows} ->
        {:ok, Enum.map(rows, fn {satellite_id, encoded} -> {satellite_id, decode_state(encoded)} end)}

      {:error, _} = err ->
        err

      other ->
        {:error, other}
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :sp3_states_at)
  end

  def states_at(%__MODULE__{}, epoch_index), do: {:error, {:bad_epoch_index, epoch_index}}

  @doc """
  Extract the product as the canonical precise-ephemeris samples, in SI units,
  one per real position record in ascending epoch order.

  Each element is a `Sidereon.GNSS.PreciseEphemerisSample` carrying the satellite
  token, the epoch (split Julian date tagged with the product's time scale), the
  ECEF position in meters, the optional clock in seconds, and the SP3 `E`
  clock-event flag. Round-tripping these back through
  `Sidereon.GNSS.PreciseEphemeris.from_samples/1` rebuilds the same interpolatable
  source.

  ## Examples

      {:ok, sp3} = Sidereon.GNSS.SP3.load("igs.sp3")
      samples = Sidereon.GNSS.SP3.precise_ephemeris_samples(sp3)
      {:ok, source} = Sidereon.GNSS.PreciseEphemeris.from_samples(samples)
  """
  @spec precise_ephemeris_samples(t()) :: [PreciseEphemerisSample.t()]
  def precise_ephemeris_samples(%__MODULE__{handle: handle}) do
    handle
    |> NIF.sp3_precise_ephemeris_samples()
    |> Enum.map(&PreciseEphemerisSample.from_nif_tuple/1)
  rescue
    e in ErlangError ->
      reraise ArgumentError,
              [message: "could not extract precise-ephemeris samples: #{NifCall.describe(e)}"],
              __STACKTRACE__
  end

  @doc "Return raw signed P/V accuracy codes and their source bases for one record."
  @spec record_accuracy_codes(t(), String.t(), non_neg_integer()) ::
          {:ok, RawRecordAccuracy.t()} | {:error, term()}
  def record_accuracy_codes(%__MODULE__{handle: handle}, sat_id, epoch_index)
      when is_binary(sat_id) and is_integer(epoch_index) and epoch_index >= 0 do
    with {:ok, letter, prn} <- Types.parse_sat_id(sat_id) do
      case NIF.sp3_record_accuracy_codes(handle, letter, prn, epoch_index) do
        {:ok, tuple} -> {:ok, RawRecordAccuracy.from_nif_tuple(tuple)}
        {:error, _} = error -> error
        other -> {:error, other}
      end
    end
  rescue
    error in ErlangError -> NifCall.error(error, __STACKTRACE__, :sp3_record_accuracy_codes)
  end

  def record_accuracy_codes(_sp3, _satellite, _epoch_index), do: {:error, :invalid_sp3_accuracy_query}

  @doc "Return decoded P/V standard deviations for one retained satellite record."
  @spec record_accuracy(t(), String.t(), non_neg_integer()) ::
          {:ok, RecordAccuracy.t()} | {:error, term()}
  def record_accuracy(%__MODULE__{handle: handle}, sat_id, epoch_index)
      when is_binary(sat_id) and is_integer(epoch_index) and epoch_index >= 0 do
    with {:ok, letter, prn} <- Types.parse_sat_id(sat_id) do
      case NIF.sp3_record_accuracy(handle, letter, prn, epoch_index) do
        {:ok, tuple} -> {:ok, RecordAccuracy.from_nif_tuple(tuple)}
        {:error, _} = error -> error
        other -> {:error, other}
      end
    end
  rescue
    error in ErlangError -> NifCall.error(error, __STACKTRACE__, :sp3_record_accuracy)
  end

  def record_accuracy(_sp3, _satellite, _epoch_index), do: {:error, :invalid_sp3_accuracy_query}

  @doc "Extract variance sidecars aligned by satellite and epoch with precise samples."
  @spec precise_ephemeris_accuracy_samples(t()) :: [PreciseEphemerisAccuracySample.t()]
  def precise_ephemeris_accuracy_samples(%__MODULE__{handle: handle}) do
    handle
    |> NIF.sp3_precise_ephemeris_accuracy_samples()
    |> Enum.map(&PreciseEphemerisAccuracySample.from_nif_tuple/1)
  rescue
    error in ErlangError -> NifCall.error(error, __STACKTRACE__, :sp3_precise_ephemeris_accuracy_samples)
  end

  @doc """
  Build canonical precise-interpolant artifact bytes from this SP3 product.

  Options:
    * `:gap_threshold_factor` - override the position-interpolation gap threshold
      factor recorded in the artifact header.
  """
  @spec precise_interpolant_artifact_bytes(t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def precise_interpolant_artifact_bytes(%__MODULE__{} = sp3, opts \\ []) when is_list(opts) do
    Interpolant.artifact_bytes(sp3, opts)
  end

  @typedoc """
  Typed refusal returned by `to_iodata/2` and `to_sp3_string/2`.
  The final `{atom(), map()}` case covers additional already named variants.
  """
  @type writer_error ::
          {
            :satellite_not_representable,
            %{satellite: binary(), system: binary(), prn: 0..255}
          }
          | {
              :accuracy_not_representable,
              %{
                satellite: binary(),
                epoch_index: non_neg_integer(),
                component: binary(),
                exponent: integer() | nil,
                message: binary()
              }
            }
          | {
              :accuracy_record_mismatch | :accuracy_basis_missing,
              %{satellite: binary(), epoch_index: non_neg_integer(), message: binary()}
            }
          | {atom(), map()}

  @doc """
  Serialize the product to standard SP3-c / SP3-d text as iodata. Pure, no I/O.

  In 3.0 this returns `{:ok, iodata}` or `{:error, {tag, fields}}`. Match the
  result and unwrap the iodata before passing it to an iodata consumer; see the
  [README migration example](README.md#sp3-writer-return-values-in-30).

  This is the inverse of `load/1` / `parse/1`: a read → (`merge/2`) → write
  pipeline round-trips to a single standard SP3 file any reader consumes. The
  output is deterministic (same product → identical bytes). A satellite absent
  at an epoch is written as the SP3 missing-orbit sentinel, so a quarantined
  `merge/2` cell re-reads as missing, never a fabricated position. A satellite
  holding a clock and no position at an epoch is written as that clock-only
  record and reads back as one.

  The writer states back the header descriptors the product holds and checks
  every numeric field by reading its column back the way the reader does. A
  value its column cannot state bit for bit, a value that would read back as one
  of the format's absence sentinels, an epoch no record restates exactly, or
  text that would not survive the reader's trim is refused by name rather than
  rounded, shifted or dropped. A mean-combined `merge/2` product commonly holds
  positions finer than the millimetre columns and is refused for that reason;
  a precedence merge keeps each contributor's own values.

  Returns `{:ok, iodata}` or `{:error, {tag, fields}}`, `tag` naming the refusal
  and `fields` holding every field it carries. The record-field refusals are
  `:record_value_not_representable`, `:record_value_too_wide`,
  `:record_value_non_finite`, `:record_reads_as_absent` and
  `:record_fields_disagree`, each with `field`, `satellite` and `epoch_index`;
  the epoch refusals are `:epoch_not_restatable` (with `field_seconds` and
  `residual_s`),
  `:epoch_time_scale_mismatch` and `:year_not_representable`;
  `:accuracy_not_representable` carries `satellite`, `epoch_index`,
  `component`, `exponent` and the core `message`; `:accuracy_record_mismatch`
  and `:accuracy_basis_missing` carry `satellite`, `epoch_index` and `message`.
  `:satellite_not_representable` carries the rendered identifier and its separate
  constellation `system` and numeric `prn`, since the identifier cannot be
  written as a two-digit SP3 token. The remaining entries name the header field
  or count they concern.
  A double the BEAM cannot hold, such as
  the `NaN` residual of an epoch no candidate record reads back, is
  `{:nonfinite, bits}`. A refusal this binding predates is
  `{:unhandled, %{message: text}}` with the core's own text.

  ## Examples

      {:ok, sp3} = Sidereon.GNSS.SP3.load("igs.sp3")
      {:ok, iodata} = Sidereon.GNSS.SP3.to_iodata(sp3)
      {:ok, reparsed} = Sidereon.GNSS.SP3.parse(IO.iodata_to_binary(iodata))
      Sidereon.GNSS.SP3.satellite_ids(reparsed) == Sidereon.GNSS.SP3.satellite_ids(sp3)
      #=> true
  """
  @spec to_iodata(t(), keyword()) :: {:ok, iodata()} | {:error, writer_error()}
  def to_iodata(%__MODULE__{handle: handle}, _opts \\ []) do
    case NIF.sp3_to_iodata(handle) do
      {:ok, text} -> {:ok, text}
      {:error, _reason} = error -> error
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :sp3_to_iodata)
  end

  @doc """
  Serialize the product to an SP3 text binary.

  In 3.0 this returns `{:ok, text}` or `{:error, {tag, fields}}`; callers
  should match and unwrap the result. See the [README migration example](README.md#sp3-writer-return-values-in-30).

  Returns `{:ok, text}` or the refusal `to_iodata/2` documents.
  """
  @spec to_sp3_string(t(), keyword()) :: {:ok, binary()} | {:error, writer_error()}
  def to_sp3_string(%__MODULE__{} = sp3, opts \\ []) do
    case to_iodata(sp3, opts) do
      {:ok, iodata} -> {:ok, IO.iodata_to_binary(iodata)}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Interpolate one satellite at J2000-second epochs in the product time scale.

  This returns the same `Sidereon.GNSS.PreciseEphemeris.StateBatch` used by the
  precise-interpolant accessors.
  """
  @spec interpolate(t(), String.t(), [number()]) ::
          {:ok, StateBatch.t()} | {:error, term()}
  def interpolate(%__MODULE__{} = sp3, sat_id, epochs_j2000_s) when is_binary(sat_id) and is_list(epochs_j2000_s) do
    satellites = List.duplicate(sat_id, length(epochs_j2000_s))
    Interpolant.states_at_j2000_s(sp3, satellites, epochs_j2000_s)
  end

  @doc """
  Interpolate the state of satellite `sat_id` at `epoch`.

  `sat_id` is the canonical SP3/RINEX token, e.g. `"G01"` (GPS PRN 1), `"E12"`,
  `"C30"`. `epoch` is a `NaiveDateTime` or a
  `{{year, month, day}, {hour, minute, second}}` tuple, interpreted in the
  file's own time scale.

  By default, epochs outside the parsed SP3 node coverage return
  `{:error, :outside_coverage}`. Pass `extrapolate: true` to opt into the
  lower-level interpolation behavior near the product edges.

  Positions are interpolated from the eleven nodes RTKLIB pephpos selects; a
  query whose contiguous run holds fewer returns
  `{:error, {:insufficient_precise_nodes, sat_id, nodes, 11}}`.

  Returns `{:ok, %Sidereon.GNSS.SP3.State{}}` or `{:error, reason}`.
  """
  @spec position(t(), String.t(), NaiveDateTime.t() | tuple(), keyword()) ::
          {:ok, State.t()} | {:error, term()}
  def position(%__MODULE__{handle: handle, time_scale: scale} = sp3, sat_id, epoch, opts \\ [])
      when is_binary(sat_id) do
    with {:ok, system_letter, prn} <- Types.parse_sat_id(sat_id),
         :ok <- validate_coverage(sp3, epoch, opts),
         {:ok, {jd_whole, jd_fraction}} <- Time.epoch_to_split_jd(epoch) do
      case NIF.sp3_position(handle, system_letter, prn, scale, jd_whole, jd_fraction) do
        {x_m, y_m, z_m, clock} ->
          # `clock` is already `nil` (no estimate) or a float (seconds).
          {:ok, %State{x_m: x_m, y_m: y_m, z_m: z_m, clock_s: clock}}

        {:error, _} = err ->
          err

        other ->
          {:error, other}
      end
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :sp3_position)
  end

  @doc "Interpolate an SP3 state at an exact query without converting it to a civil float."
  @spec position_at_epoch_query(t(), String.t(), ExactEpochQuery.t()) ::
          {:ok, State.t()} | {:error, term()}
  def position_at_epoch_query(%__MODULE__{handle: handle}, sat_id, %ExactEpochQuery{handle: query})
      when is_binary(sat_id) do
    with {:ok, system_letter, prn} <- Types.parse_sat_id(sat_id) do
      case NIF.sp3_position_at_epoch_query(handle, system_letter, prn, query) do
        {x_m, y_m, z_m, clock} -> {:ok, %State{x_m: x_m, y_m: y_m, z_m: z_m, clock_s: clock}}
        {:error, _} = error -> error
        other -> {:error, other}
      end
    end
  rescue
    error in ErlangError -> NifCall.error(error, __STACKTRACE__, :sp3_position_at_epoch_query)
  end

  def position_at_epoch_query(_sp3, _satellite, _query), do: {:error, :invalid_exact_epoch_query}

  @doc "Read selected state and group delay at independent exact state and selection queries."
  @spec selected_state_at_epoch_queries(t(), String.t(), ExactEpochQuery.t(), ExactEpochQuery.t()) ::
          {:ok, nil | map()} | {:error, term()}
  def selected_state_at_epoch_queries(
        %__MODULE__{handle: handle},
        sat_id,
        %ExactEpochQuery{handle: state_query},
        %ExactEpochQuery{handle: selection_query}
      ) do
    with {:ok, letter, prn} <- Types.parse_sat_id(sat_id) do
      case NIF.sp3_selected_state_at_epoch_queries(
             handle,
             letter,
             prn,
             state_query,
             selection_query
           ) do
        {:ok, nil} ->
          {:ok, nil}

        {:ok, {position_x, position_y, position_z, clock_s, group_delay_s, degraded}} ->
          {:ok,
           %{
             position_ecef_m: {position_x, position_y, position_z},
             clock_s: clock_s,
             group_delay_s: group_delay_s,
             degraded: degraded
           }}

        {:error, _} = error ->
          error

        other ->
          {:error, other}
      end
    end
  rescue
    error in ErlangError -> NifCall.error(error, __STACKTRACE__, :sp3_selected_state_at_epoch_queries)
  end

  def selected_state_at_epoch_queries(_sp3, _satellite, _state_query, _selection_query),
    do: {:error, :invalid_exact_epoch_query}

  @doc "Read the clock used for transmission placement at exact state and selection queries."
  def transmit_clock_at_epoch_queries(
        %__MODULE__{handle: handle},
        sat_id,
        %ExactEpochQuery{handle: state_query},
        %ExactEpochQuery{handle: selection_query}
      ) do
    with {:ok, letter, prn} <- Types.parse_sat_id(sat_id) do
      case NIF.sp3_transmit_clock_at_epoch_queries(
             handle,
             letter,
             prn,
             state_query,
             selection_query
           ) do
        {:ok, nil} -> {:ok, nil}
        {:ok, {clock_s, degraded}} -> {:ok, %{clock_s: clock_s, degraded: degraded}}
        {:error, _} = error -> error
        other -> {:error, other}
      end
    end
  rescue
    error in ErlangError -> NifCall.error(error, __STACKTRACE__, :sp3_transmit_clock_at_epoch_queries)
  end

  def transmit_clock_at_epoch_queries(_sp3, _satellite, _state_query, _selection_query),
    do: {:error, :invalid_exact_epoch_query}

  @doc "Evaluate the product-clock relativistic term for an exact queried state."
  def clock_relativity_for_state_at_epoch_query(
        %__MODULE__{handle: handle},
        sat_id,
        %ExactEpochQuery{handle: query},
        {position_x, position_y, position_z} = position
      )
      when is_number(position_x) and is_number(position_y) and is_number(position_z) do
    with {:ok, letter, prn} <- Types.parse_sat_id(sat_id) do
      case NIF.sp3_clock_relativity_for_state_at_epoch_query(
             handle,
             letter,
             prn,
             query,
             position
           ) do
        :not_applicable -> :not_applicable
        :unavailable -> :unavailable
        {:term, seconds} -> {:term, seconds}
        {:error, _} = error -> error
        other -> {:error, other}
      end
    end
  rescue
    error in ErlangError ->
      NifCall.error(error, __STACKTRACE__, :sp3_clock_relativity_for_state_at_epoch_query)
  end

  def clock_relativity_for_state_at_epoch_query(_sp3, _satellite, _query, _position),
    do: {:error, :invalid_exact_epoch_query}

  @doc "Read SP3 position variance at independent exact state and selection queries."
  def ephemeris_variance_at_epoch_queries(
        %__MODULE__{handle: handle},
        sat_id,
        %ExactEpochQuery{handle: state_query},
        %ExactEpochQuery{handle: selection_query}
      ) do
    with {:ok, letter, prn} <- Types.parse_sat_id(sat_id) do
      NIF.sp3_ephemeris_variance_at_epoch_queries(
        handle,
        letter,
        prn,
        state_query,
        selection_query
      )
    end
  rescue
    error in ErlangError -> NifCall.error(error, __STACKTRACE__, :sp3_ephemeris_variance_at_epoch_queries)
  end

  def ephemeris_variance_at_epoch_queries(_sp3, _satellite, _state_query, _selection_query),
    do: {:error, :invalid_exact_epoch_query}

  @doc """
  Merge several SP3 products from different analysis centers into one consistent
  precise-ephemeris dataset.

  `sources` is a list of loaded products **in precedence order** (earlier wins
  ties). This is orthogonal to time-stitching: it combines providers at the same
  epochs on one shared time grid. By default the grid step is the greatest
  common divisor of the inputs' epoch steps and offsets, which holds every input
  epoch (900 s and 400 s products merge on a 100 s grid); only records actually
  present in an input are used, and nothing is interpolated. For every `(epoch, satellite)` cell:

    * **Union satellite coverage**: a satellite present in any input may appear
      in the merged product wherever a source actually carries it.
    * **Consensus**: the largest subset of sources agreeing within tolerance is
      combined; sources outside it are recorded as outliers. A cell with no
      agreeing subset of `:min_agree` is *quarantined* (omitted), never averaged
      across disagreeing centers. A lone source is carried through.
    * **Cell precedence**: with `combine: :precedence`, the earliest source
      present in each cell wins, so a lower-precedence source fills a preferred
      source's missing cell. Set `precedence_scope: :satellite_arc` to retain
      one owner for a whole satellite arc.
    * **Optional precedence guard**: `:outlier_reject` makes a contested
      precedence cell require a mutually agreeing cluster of at least
      `max(:min_agree, 2)` sources. A corrupt preferred value is replaced by the
      earliest member of the deterministic largest cluster and recorded.

  Returns `{:ok, %Sidereon.GNSS.SP3{}, report}` or `{:error, reason}`, where
  `report` is a map with `:quarantined`, `:single_source`, and
  `:position_outliers`, and `:clock_outliers` lists. Each entry is a map
  `%{satellite: "G03", jd_whole: float, jd_fraction: float, sources: [0, 2]}`
  (`sources` are zero-based indices into `sources`).

  `report.agreement` quantifies how tightly the consensus sources clustered about
  the combined product. It is a map with the whole-product aggregates
  `:position_rms_m`, `:position_max_m`, `:clock_rms_s`, and `:clock_max_s`, plus
  `:cells` (per-(epoch, satellite) statistics, one per accepted cell) and
  `:epochs` (per-epoch aggregates). The whole-product RMS fields are `nil` when
  no multi-source consensus exists for that channel; its maxima cover every
  accepted position cell and every clock-bearing cell, so either may be `0.0`
  for single-source cells, and is `nil` when no accepted cell carries that
  channel. A cell's position fields are `nil` when the cell
  carries no position, such as a clock-only record, and its clock fields `nil`
  when it carries no clock; neither is read as `0.0`. An epoch's aggregates
  cover its multi-source cells and are `nil` for a channel with none there.

  The report also states what the merge did not write:

    * `:dropped_input_epochs` - input epochs that took no part, in (source,
      epoch) order, each `%{source: 0, epoch_index: 3, epoch: epoch, reason:
      reason}` with `reason` `:off_target_grid` (off an explicit
      `:epoch_interval_s` grid) or `:not_on_tick_axis` (no SP3 epoch record
      states the instant exactly).
    * `:omitted_epochs` - union-grid epochs at which the merge accepted no cell
      and wrote no epoch.
    * `:arc_withheld` - cells whose position `:precedence` did not write because
      the preferred source carried none there, each
      `%{satellite: "G03", epoch: epoch, sources: [1]}`.
    * `:clock_omissions` - each source clock the merge did not write, in
      (epoch, satellite, source) order, each `%{epoch: epoch, satellite: "G03",
      source: 1, reason: reason, preferred: nil | 0, cell_has_clock: true}` with
      `reason` `:datum_not_observable`, `:preferred_source_without_clock` (with
      the preferred source under `:preferred` when the merge had one) or
      `:no_consensus`.

  An `epoch` there is `%{time_scale: "GPST", jd_whole: float, jd_fraction:
  float}` or, for an integer-nanosecond instant,
  `%{time_scale: "GPST", nanos_since_j2000: integer}`, as the merge recorded it.

  `report.continuity` is `nil` unless `:verify_continuity` was set, and
  otherwise the `check_continuity/2` report of the merged product with
  `:violations` and `:splices` (the violations that cross a contributor change).
  Each violation has `:defect`, `:from_sources`, `:to_sources`, `:sources`,
  `:crosses_contributors` and `:cells`, each cell `%{epoch_j2000_s: float,
  role: role, selection: selection | nil}` with `role` `:held_out`,
  `:interpolation_node`, `:pair_end` or `:repeated_epoch`. A selection is
  `%{kind: :single_source, source: 0}`, `%{kind: :precedence, source: 0,
  members: [0, 1]}` or `%{kind: :combined, rule: :mean, members: [0, 1]}`.

  `report.provenance` is `nil` unless `:provenance` was set, and otherwise
  `%{mode: mode, cells: cells, transitions: transitions, coverage: coverage}`:
  `:cells` has one `%{epoch: epoch, satellite: "G03", position: selection |
  nil, clock: selection | nil}` per accepted cell under `:full` and none under
  `:summary`; each transition is `%{satellite: "G03", epoch: epoch,
  from_source: 0 | nil, to_source: 1 | nil, reason: reason}` with `reason`
  `:sole_availability`, `:precedence`, `:outlier_rejection` or
  `:consensus_change`; each coverage entry is `%{source: 0, cells_contributed:
  integer, cells_selected: integer, first_epoch: epoch | nil, last_epoch: epoch
  | nil, cells_absent: integer}`.

  ## Options

    * `:position_tolerance_m`: position agreement tolerance, meters (default `0.5`)
    * `:clock_tolerance_s`: clock agreement tolerance, seconds (default `5.0e-9`)
    * `:min_agree`: agreeing sources required to accept a contested cell (default `2`)
    * `:clock_min_common`: common clocked satellites for the clock-datum estimate (default `5`)
    * `:combine`: `:mean` (default), `:median`, or `:precedence`
    * `:precedence_scope`: `:cell` (default) or `:satellite_arc`
    * `:outlier_reject`: `nil` (default/current behavior), or a map/keyword list
      with `:position_m` and `:clock_ns` tolerances
    * `:epoch_interval_s`: require this target epoch interval, seconds: a whole
      number of the 10-nanosecond ticks an SP3 interval states. The grid is
      anchored at the earliest input epoch.
    * `:systems`: restrict output to systems such as `[:gps]` or `["G", "E"]`
    * `:asserted_frame_label_sets`: coordinate-label sets the caller asserts
      are equivalent without frame math
    * `:helmert`: enable catalog Helmert reconciliation for known ITRF/IGS
      labels
    * `:verify_continuity`: `false` (default), `true` for the standard options,
      or continuity options with `:orbit_class` and `:residual_tolerance_m`
    * `:provenance`: `nil` (default, none recorded), `:summary` or `:full`
  """
  @spec merge([t()], keyword()) :: {:ok, t(), map()} | {:error, term()}
  def merge(sources, opts \\ []) when is_list(sources) do
    with {:ok, policy} <- normalize_merge_policy(opts) do
      handles = Enum.map(sources, fn %__MODULE__{handle: handle} -> handle end)

      case NIF.sp3_merge(
             handles,
             policy.position_tolerance_m,
             policy.clock_tolerance_s,
             policy.min_agree,
             policy.clock_min_common,
             Atom.to_string(policy.combine),
             Atom.to_string(policy.precedence_scope),
             policy.outlier_reject,
             policy.epoch_interval_s,
             policy.systems,
             policy.asserted_frame_label_sets,
             policy.helmert,
             policy.verify_continuity,
             policy.provenance && Atom.to_string(policy.provenance)
           ) do
        {handle,
         {quarantined, single_source, position_outliers, clock_outliers,
          {frame_reconciliations, agreement, continuity, report_handle}}}
        when is_reference(handle) ->
          report = %{
            handle: report_handle,
            frame_reconciliations: Enum.map(frame_reconciliations, &to_frame_reconciliation/1),
            quarantined: Enum.map(quarantined, &to_flag/1),
            single_source: Enum.map(single_source, &to_flag/1),
            position_outliers: Enum.map(position_outliers, &to_flag/1),
            clock_outliers: Enum.map(clock_outliers, &to_flag/1),
            agreement: to_agreement(agreement),
            continuity: decode_merge_continuity_report(continuity)
          }

          report =
            report
            |> Map.merge(merge_omissions(report_handle))
            |> Map.put(:provenance, merge_provenance(report_handle))

          {:ok,
           %__MODULE__{
             handle: handle,
             time_scale: NIF.sp3_time_scale(handle),
             coverage_start: 0.0,
             coverage_end: 0.0
           }, report}
          |> attach_coverage()

        {:error, _} = err ->
          err

        other ->
          {:error, other}
      end
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :sp3_merge)
  end

  @doc """
  Decide whether an opt-in merge continuity report influences an inclusive
  evaluation window on the merged product's J2000-seconds axis.

  The report holds the merged product's interpolation nodes, so a violation
  influences the window when the nodes its interpolations select include the
  violation's held-out, repeated or pair-end record or straddle a handover
  between its records.

  Returns `{:ok, nil}` when merge continuity verification was not requested.
  """
  @spec merge_continuity_verdict(map(), number(), number()) ::
          {:ok, map() | nil} | {:error, term()}
  def merge_continuity_verdict(%{handle: report_handle}, from_j2000_s, through_j2000_s)
      when is_number(from_j2000_s) and is_number(through_j2000_s) do
    case NIF.sp3_merge_continuity_verdict(report_handle, from_j2000_s / 1.0, through_j2000_s / 1.0) do
      {:ok, nil} -> {:ok, nil}
      {:ok, verdict} -> {:ok, decode_window_continuity_verdict(verdict)}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :sp3_merge_continuity_verdict)
  end

  def merge_continuity_verdict(_report, _from_j2000_s, _through_j2000_s), do: {:error, :invalid_merge_continuity_query}

  @doc """
  Epochs of the merged product's position nodes that some interpolation of
  `satellite` in the inclusive window selects, ascending and seconds since
  J2000: the nodes `merge_continuity_verdict/3` reads for that window.

  Returns `{:ok, nil}` when merge continuity verification was not requested.
  """
  @spec merge_continuity_selected_nodes(map(), String.t(), number(), number()) ::
          {:ok, [float()] | nil} | {:error, term()}
  def merge_continuity_selected_nodes(%{handle: report_handle}, satellite, from_j2000_s, through_j2000_s)
      when is_binary(satellite) and is_number(from_j2000_s) and is_number(through_j2000_s) do
    NIF.sp3_merge_continuity_selected_nodes(report_handle, satellite, from_j2000_s / 1.0, through_j2000_s / 1.0)
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :sp3_merge_continuity_selected_nodes)
  end

  def merge_continuity_selected_nodes(_report, _satellite, _from_j2000_s, _through_j2000_s),
    do: {:error, :invalid_merge_continuity_query}

  @doc """
  Build the versioned stable identity for exact SP3 artifacts and merge policy.

  Contributor order and map order do not affect mean or median identity. With
  `combine: :precedence`, source order is an effective policy control and is
  therefore bound in order. Every contributor must carry complete
  requested/resolved identity, distributor, product and archive digests and
  lengths, official filename, and compression. Cache and HTTP observations are
  intentionally excluded. The returned map includes core's complete canonical
  `:contributors` and, for precedence combination, the ordered
  `:precedence_contributors`.

  The options are those of `merge/2`, including the same exact positive
  10-nanosecond tick and under-100000-second interval validation. The returned
  `:merge_policy` records every option, including `:verify_continuity` (`nil`
  or `%{orbit_class: ..., residual_tolerance_m: ..., gap_threshold_factor:
  ...}`) and `:provenance` (`nil`, `"summary"` or `"full"`), which change
  neither the merged product nor the stable identity.
  """
  @spec merge_input_identity([map()], keyword()) :: {:ok, map()} | {:error, term()}
  def merge_input_identity(contributors, opts \\ [])

  def merge_input_identity(contributors, opts) when is_list(contributors) do
    with {:ok, encoded} <- encode_merge_contributors(contributors),
         {:ok, policy} <- normalize_merge_policy(opts),
         :ok <- validate_core_identity_interval(policy.epoch_interval_s) do
      result =
        NIF.sp3_merge_input_identity(
          encoded,
          policy.position_tolerance_m,
          policy.clock_tolerance_s,
          policy.min_agree,
          policy.clock_min_common,
          Atom.to_string(policy.combine),
          Atom.to_string(policy.precedence_scope),
          policy.outlier_reject,
          policy.epoch_interval_s,
          policy.systems,
          policy.asserted_frame_label_sets,
          policy.helmert
        )

      case result do
        {schema_version, stable_id, canonical, precedence}
        when is_integer(schema_version) and is_binary(stable_id) and is_list(canonical) ->
          with {:ok, canonical} <- decode_core_artifacts(canonical),
               {:ok, precedence} <- decode_optional_core_artifacts(precedence) do
            {:ok,
             %{
               schema_version: schema_version,
               stable_id: stable_id,
               contributors: canonical,
               precedence_contributors: precedence,
               merge_policy: merge_policy_map(policy, precedence)
             }}
          end

        {:error, _reason} = error ->
          error

        other ->
          {:error, {:invalid_merge_input_identity, other}}
      end
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :sp3_merge_input_identity)
  end

  def merge_input_identity(_contributors, _opts), do: {:error, {:invalid_merge_contributors, :not_a_list}}

  # The policy checks merge/2 and merge_input_identity/2 apply to their
  # options, without products, so a caller can refuse a policy before it
  # fetches any.
  @doc false
  @spec validate_identity_policy(keyword()) :: :ok | {:error, term()}
  def validate_identity_policy(opts) do
    with {:ok, policy} <- normalize_merge_policy(opts) do
      validate_core_identity_interval(policy.epoch_interval_s)
    end
  end

  @doc """
  Estimate the per-epoch reference-clock offset of `other` relative to
  `reference` (the clock-datum primitive).

  Precise clock products from different centers are referenced to different
  station/ensemble clocks, so their raw clocks differ by a per-epoch common
  offset that drifts over the day. This returns that datum: a list of maps
  `%{jd_whole: float, jd_fraction: float, offset_s: float, satellites: integer}`,
  one per epoch where at least `:min_common` common clocked satellites let the
  (robust median) offset be estimated. Subtract `offset_s` from `other`'s clocks
  to put both products on `reference`'s datum. Orbit positions need no such
  treatment; every center reports ITRF center-of-mass coordinates.

  ## Options

    * `:min_common`: minimum common clocked satellites per epoch (default `5`)
  """
  @spec clock_reference_offset(t(), t(), keyword()) :: [map()]
  def clock_reference_offset(%__MODULE__{handle: reference}, %__MODULE__{handle: other}, opts \\ []) do
    min_common = Keyword.get(opts, :min_common, 5)

    reference
    |> NIF.sp3_clock_reference_offset(other, min_common)
    |> Enum.map(fn {jd_whole, jd_fraction, offset_s, satellites} ->
      %{jd_whole: jd_whole, jd_fraction: jd_fraction, offset_s: offset_s, satellites: satellites}
    end)
  rescue
    e in ErlangError ->
      reraise ArgumentError,
              [message: "could not estimate clock reference offset: #{NifCall.describe(e)}"],
              __STACKTRACE__
  end

  @doc """
  Return a copy of `other` with its clocks shifted onto `reference`'s clock datum
  (the clock-datum primitive, applied).

  At every epoch the offset could be estimated, each clocked satellite's offset
  has the datum subtracted, so the result's clocks are directly comparable to
  `reference`'s. Positions are untouched. Epochs without an estimate are left
  unchanged. The returned product interpolates like any other SP3.

  Returns `{:ok, %Sidereon.GNSS.SP3{}}` or `{:error, reason}`.

  ## Options

    * `:min_common`: minimum common clocked satellites per epoch (default `5`)
  """
  @spec align_clock_reference(t(), t(), keyword()) :: {:ok, t()} | {:error, term()}
  def align_clock_reference(%__MODULE__{handle: reference}, %__MODULE__{handle: other} = other_sp3, opts \\ []) do
    min_common = Keyword.get(opts, :min_common, 5)

    case NIF.sp3_align_clock_reference(reference, other, min_common) do
      handle when is_reference(handle) ->
        {:ok,
         %__MODULE__{
           handle: handle,
           time_scale: NIF.sp3_time_scale(handle),
           coverage_start: other_sp3.coverage_start,
           coverage_end: other_sp3.coverage_end
         }}

      {:error, _} = err ->
        err

      other_result ->
        {:error, other_result}
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :sp3_align_clock_reference)
  end

  # --- helpers -------------------------------------------------------------

  defp decode_state(
         {x_m, y_m, z_m, clock_s, velocity_m_s, clock_rate_s_s,
          {clock_event, clock_predicted, maneuver, orbit_predicted}}
       ) do
    %State{
      x_m: x_m,
      y_m: y_m,
      z_m: z_m,
      clock_s: clock_s,
      velocity_m_s: velocity_m_s,
      clock_rate_s_s: clock_rate_s_s,
      clock_event: clock_event,
      clock_predicted: clock_predicted,
      maneuver: maneuver,
      orbit_predicted: orbit_predicted
    }
  end

  defp merge_omissions(report_handle) do
    omissions = NIF.sp3_merge_report_omissions(report_handle)

    %{
      dropped_input_epochs:
        Enum.map(omissions.dropped_input_epochs, fn dropped ->
          %{
            source: dropped.source,
            epoch_index: dropped.epoch_index,
            epoch: merge_epoch(dropped.epoch),
            reason: merge_omission_reason(dropped.reason)
          }
        end),
      omitted_epochs: Enum.map(omissions.omitted_epochs, &merge_epoch/1),
      arc_withheld:
        Enum.map(omissions.arc_withheld, fn flag ->
          %{satellite: flag.satellite, epoch: merge_epoch(flag.epoch), sources: flag.sources}
        end),
      clock_omissions:
        Enum.map(omissions.clock_omissions, fn omission ->
          %{
            epoch: merge_epoch(omission.epoch),
            satellite: omission.satellite,
            source: omission.source,
            reason: merge_omission_reason(omission.reason),
            preferred: omission.preferred,
            cell_has_clock: omission.cell_has_clock
          }
        end)
    }
  end

  defp merge_provenance(report_handle) do
    case NIF.sp3_merge_report_provenance(report_handle) do
      nil ->
        nil

      provenance ->
        %{
          mode: provenance_mode(provenance.mode),
          cells:
            Enum.map(provenance.cells, fn cell ->
              %{
                epoch: merge_epoch(cell.epoch),
                satellite: cell.satellite,
                position: decode_cell_selection(cell.position),
                clock: decode_cell_selection(cell.clock)
              }
            end),
          transitions:
            Enum.map(provenance.transitions, fn transition ->
              %{
                satellite: transition.satellite,
                epoch: merge_epoch(transition.epoch),
                from_source: transition.from_source,
                to_source: transition.to_source,
                reason: transition_reason(transition.reason)
              }
            end),
          coverage:
            Enum.map(provenance.coverage, fn coverage ->
              %{
                source: coverage.source,
                cells_contributed: coverage.cells_contributed,
                cells_selected: coverage.cells_selected,
                first_epoch: coverage.first_epoch && merge_epoch(coverage.first_epoch),
                last_epoch: coverage.last_epoch && merge_epoch(coverage.last_epoch),
                cells_absent: coverage.cells_absent
              }
            end)
        }
    end
  end

  defp provenance_mode("summary"), do: :summary
  defp provenance_mode("full"), do: :full

  defp transition_reason("sole_availability"), do: :sole_availability
  defp transition_reason("precedence"), do: :precedence
  defp transition_reason("outlier_rejection"), do: :outlier_rejection
  defp transition_reason("consensus_change"), do: :consensus_change

  defp merge_epoch(%{time_scale: scale, julian_date: {jd_whole, jd_fraction}}),
    do: %{time_scale: scale, jd_whole: jd_whole, jd_fraction: jd_fraction}

  defp merge_epoch(%{time_scale: scale, nanos_since_j2000: nanos}) when is_binary(nanos),
    do: %{time_scale: scale, nanos_since_j2000: String.to_integer(nanos)}

  defp merge_omission_reason("off_target_grid"), do: :off_target_grid
  defp merge_omission_reason("not_on_tick_axis"), do: :not_on_tick_axis
  defp merge_omission_reason("datum_not_observable"), do: :datum_not_observable
  defp merge_omission_reason("preferred_source_without_clock"), do: :preferred_source_without_clock
  defp merge_omission_reason("no_consensus"), do: :no_consensus

  defp to_flag({satellite, jd_whole, jd_fraction, sources}) do
    %{satellite: satellite, jd_whole: jd_whole, jd_fraction: jd_fraction, sources: sources}
  end

  defp split_jd_map(nil), do: nil
  defp split_jd_map({jd_whole, jd_fraction}), do: %{jd_whole: jd_whole, jd_fraction: jd_fraction}

  defp to_frame_reconciliation(
         {{source_index, source_label, target_label, method}, {asserted_label_set, {source_frame, target_frame}},
          {{catalog_source_frame, catalog_target_frame, catalog_inverse}, reference_epoch_year, parameters},
          {rates, provenance, epoch_year_span, {records_affected, identity}}}
       ) do
    %{
      source_index: source_index,
      source_label: source_label,
      target_label: target_label,
      method: String.to_atom(method),
      asserted_label_set: asserted_label_set,
      source_frame: source_frame,
      target_frame: target_frame,
      catalog_source_frame: catalog_source_frame,
      catalog_target_frame: catalog_target_frame,
      catalog_inverse: catalog_inverse,
      reference_epoch_year: reference_epoch_year,
      parameters: helmert_parameters(parameters),
      rates: helmert_rates(rates),
      provenance: provenance,
      epoch_year_span: epoch_year_span,
      records_affected: records_affected,
      identity: identity
    }
  end

  defp helmert_parameters(nil), do: nil

  defp helmert_parameters({translation_mm, scale_ppb, rotation_mas}) do
    %{translation_mm: translation_mm, scale_ppb: scale_ppb, rotation_mas: rotation_mas}
  end

  defp helmert_rates(nil), do: nil

  defp helmert_rates({translation_mm_per_year, scale_ppb_per_year, rotation_mas_per_year}) do
    %{
      translation_mm_per_year: translation_mm_per_year,
      scale_ppb_per_year: scale_ppb_per_year,
      rotation_mas_per_year: rotation_mas_per_year
    }
  end

  defp to_agreement({aggregate, per_cell, per_epoch}) do
    {position_rms_m, position_max_m, clock_rms_s, clock_max_s} = aggregate

    %{
      position_rms_m: position_rms_m,
      position_max_m: position_max_m,
      clock_rms_s: clock_rms_s,
      clock_max_s: clock_max_s,
      cells: Enum.map(per_cell, &to_agreement_cell/1),
      epochs: Enum.map(per_epoch, &to_agreement_epoch/1)
    }
  end

  defp to_agreement_cell(
         {satellite, {jd_whole, jd_fraction}, {position_members, position_rms_m, position_max_m},
          {clock_members, clock_rms_s, clock_max_s}}
       ) do
    %{
      satellite: satellite,
      jd_whole: jd_whole,
      jd_fraction: jd_fraction,
      position_members: position_members,
      position_rms_m: position_rms_m,
      position_max_m: position_max_m,
      clock_members: clock_members,
      clock_rms_s: clock_rms_s,
      clock_max_s: clock_max_s
    }
  end

  defp to_agreement_epoch(
         {{jd_whole, jd_fraction}, satellites, {position_rms_m, position_max_m}, {clock_rms_s, clock_max_s}}
       ) do
    %{
      jd_whole: jd_whole,
      jd_fraction: jd_fraction,
      satellites: satellites,
      position_rms_m: position_rms_m,
      position_max_m: position_max_m,
      clock_rms_s: clock_rms_s,
      clock_max_s: clock_max_s
    }
  end

  # The merged product's coverage is its first and last epoch on the J2000-second
  # axis it interpolates on. It is read from the product rather than from text
  # written for it, because the writer refuses a product it cannot state
  # exactly - a mean-combined merge commonly holds positions finer than the
  # record columns - and a merge the core performed is not refused for that.
  defp attach_coverage({:ok, %__MODULE__{handle: handle} = sp3, report}) do
    case NIF.sp3_epochs_j2000_seconds(handle) do
      [] ->
        {:error, :missing_coverage}

      [coverage_start | _rest] = epochs ->
        {:ok, %{sp3 | coverage_start: coverage_start, coverage_end: List.last(epochs)}, report}
    end
  end

  defp encode_merge_contributors(contributors) do
    contributors
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {contributor, index}, {:ok, encoded} ->
      case encode_merge_contributor(contributor) do
        {:ok, value} -> {:cont, {:ok, [value | encoded]}}
        {:error, reason} -> {:halt, {:error, {:invalid_merge_contributor, index, reason}}}
      end
    end)
    |> case do
      {:ok, encoded} -> {:ok, Enum.reverse(encoded)}
      {:error, _reason} = error -> error
    end
  end

  defp encode_merge_contributor(%{
         requested_identity: requested_identity,
         resolved_identity: resolved_identity,
         distribution_source: distribution_source,
         official_filename: official_filename,
         product_sha256: product_sha256,
         product_byte_length: product_byte_length,
         archive_sha256: archive_sha256,
         archive_byte_length: archive_byte_length,
         compression: compression
       })
       when is_atom(distribution_source) and is_binary(official_filename) and is_binary(product_sha256) and
              is_integer(product_byte_length) and is_binary(archive_sha256) and is_integer(archive_byte_length) and
              is_atom(compression) do
    {:ok,
     {
       {ExactCache.identity_fields(requested_identity), ExactCache.identity_fields(resolved_identity)},
       {Atom.to_string(distribution_source), official_filename},
       {product_sha256, product_byte_length},
       {archive_sha256, archive_byte_length},
       Atom.to_string(compression)
     }}
  rescue
    _error -> {:error, :identity}
  end

  defp encode_merge_contributor(_contributor), do: {:error, :incomplete}

  defp decode_core_artifacts(artifacts) do
    artifacts
    |> Enum.reduce_while({:ok, []}, fn artifact, {:ok, acc} ->
      case decode_core_artifact(artifact) do
        {:ok, decoded} -> {:cont, {:ok, [decoded | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      {:error, _} = error -> error
    end
  end

  defp decode_optional_core_artifacts(nil), do: {:ok, nil}
  defp decode_optional_core_artifacts(artifacts) when is_list(artifacts), do: decode_core_artifacts(artifacts)
  defp decode_optional_core_artifacts(_artifacts), do: {:error, :invalid_core_precedence_contributors}

  defp decode_core_artifact(
         {{requested, resolved}, {source, official_filename}, {product_sha256, product_byte_length},
          {archive_sha256, archive_byte_length}, compression}
       ) do
    with {:ok, requested} <- decode_core_product_identity(requested),
         {:ok, resolved} <- decode_core_product_identity(resolved),
         {:ok, source} <- decode_core_source(source),
         {:ok, compression} <- decode_core_compression(compression) do
      {:ok,
       %{
         requested_identity: requested,
         resolved_identity: resolved,
         distribution_source: source,
         official_filename: official_filename,
         product_sha256: product_sha256,
         product_byte_length: product_byte_length,
         archive_sha256: archive_sha256,
         archive_byte_length: archive_byte_length,
         compression: compression
       }}
    end
  end

  defp decode_core_artifact(_artifact), do: {:error, :invalid_core_contributor}

  defp decode_core_product_identity([
         family,
         analysis_center,
         publisher,
         solution_class,
         campaign,
         filename_version,
         year,
         month,
         day,
         issue,
         span,
         sample,
         official_filename,
         format,
         format_version,
         prediction_horizon_days
       ]) do
    with {filename_version, ""} <- Integer.parse(filename_version),
         {year, ""} <- Integer.parse(year),
         {month, ""} <- Integer.parse(month),
         {day, ""} <- Integer.parse(day),
         {:ok, date} <- Date.new(year, month, day),
         {:ok, prediction_horizon_days} <- decode_optional_integer(prediction_horizon_days) do
      {:ok,
       %Distribution.ProductIdentity{
         family: family,
         analysis_center: analysis_center,
         publisher: publisher,
         solution_class: solution_class,
         campaign: campaign,
         filename_version: filename_version,
         date: date,
         issue: empty_to_nil(issue),
         span: span,
         sample: sample,
         official_filename: official_filename,
         format: format,
         format_version: empty_to_nil(format_version),
         prediction_horizon_days: prediction_horizon_days
       }}
    else
      _ -> {:error, :invalid_core_product_identity}
    end
  end

  defp decode_core_product_identity(_fields), do: {:error, :invalid_core_product_identity}

  defp decode_optional_integer(""), do: {:ok, nil}

  defp decode_optional_integer(value) do
    case Integer.parse(value) do
      {integer, ""} -> {:ok, integer}
      _ -> {:error, :invalid_core_product_identity}
    end
  end

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value

  defp decode_core_source("direct"), do: {:ok, :direct}
  defp decode_core_source("nasa_cddis"), do: {:ok, :nasa_cddis}
  defp decode_core_source("local_file"), do: {:ok, :local_file}
  defp decode_core_source("in_memory"), do: {:ok, :in_memory}
  defp decode_core_source(_source), do: {:error, :invalid_core_distribution_source}

  defp decode_core_compression("gzip"), do: {:ok, :gzip}
  defp decode_core_compression("none"), do: {:ok, :none}
  defp decode_core_compression("unix_compress"), do: {:ok, :unix_compress}
  defp decode_core_compression(_compression), do: {:error, :invalid_core_compression}

  defp merge_policy_map(policy, precedence) do
    %{
      position_tolerance_m: policy.position_tolerance_m,
      clock_tolerance_s: policy.clock_tolerance_s,
      min_agree: policy.min_agree,
      clock_min_common: policy.clock_min_common,
      combine: Atom.to_string(policy.combine),
      precedence_artifact_sha256: if(precedence, do: Enum.map(precedence, & &1.product_sha256)),
      precedence_scope: Atom.to_string(policy.precedence_scope),
      outlier_reject: outlier_reject_map(policy.outlier_reject),
      epoch_interval_s: policy.epoch_interval_s,
      systems: policy.systems,
      asserted_frame_label_sets: policy.asserted_frame_label_sets,
      helmert: policy.helmert,
      verify_continuity: continuity_policy_map(policy.verify_continuity),
      provenance: policy.provenance && Atom.to_string(policy.provenance)
    }
  end

  # Neither option changes the merged product or the stable identity; the
  # policy records them so a persisted report states what its merge was asked
  # to report.
  defp continuity_policy_map(nil), do: nil

  defp continuity_policy_map({orbit_class, residual_tolerance_m, gap_threshold_factor}) do
    %{
      orbit_class: orbit_class,
      residual_tolerance_m: residual_tolerance_m,
      gap_threshold_factor: gap_threshold_factor
    }
  end

  @merge_policy_keys [
    :position_tolerance_m,
    :clock_tolerance_s,
    :min_agree,
    :clock_min_common,
    :combine,
    :precedence_scope,
    :outlier_reject,
    :epoch_interval_s,
    :systems,
    :asserted_frame_label_sets,
    :helmert,
    :verify_continuity,
    :provenance
  ]

  defp normalize_merge_policy(opts) when is_list(opts) do
    keys = Keyword.keys(opts)

    with true <- Keyword.keyword?(opts) || {:error, {:invalid_merge_policy, :not_keyword}},
         true <- Enum.all?(keys, &(&1 in @merge_policy_keys)) || {:error, {:invalid_merge_policy, :unknown_option}},
         true <- length(keys) == MapSet.size(MapSet.new(keys)) || {:error, {:invalid_merge_policy, :duplicate_option}},
         {:ok, position_tolerance_m} <-
           normalize_nonnegative_float(Keyword.get(opts, :position_tolerance_m, 0.5), :position_tolerance_m),
         {:ok, clock_tolerance_s} <-
           normalize_nonnegative_float(Keyword.get(opts, :clock_tolerance_s, 5.0e-9), :clock_tolerance_s),
         {:ok, min_agree} <- normalize_positive_integer(Keyword.get(opts, :min_agree, 2), :min_agree),
         {:ok, clock_min_common} <-
           normalize_positive_integer(Keyword.get(opts, :clock_min_common, 5), :clock_min_common),
         {:ok, combine} <- normalize_combine(Keyword.get(opts, :combine, :mean)),
         {:ok, precedence_scope} <-
           normalize_precedence_scope(Keyword.get(opts, :precedence_scope, :cell)),
         {:ok, outlier_reject} <- normalize_outlier_reject(Keyword.get(opts, :outlier_reject)),
         {:ok, epoch_interval_s} <- normalize_epoch_interval(Keyword.get(opts, :epoch_interval_s)),
         {:ok, systems} <- normalize_policy_systems(opts),
         {:ok, asserted_frame_label_sets} <-
           normalize_asserted_frame_label_sets(Keyword.get(opts, :asserted_frame_label_sets, [])),
         {:ok, helmert} <- normalize_boolean(Keyword.get(opts, :helmert, false), :helmert),
         {:ok, verify_continuity} <-
           normalize_verify_continuity(Keyword.get(opts, :verify_continuity, false)),
         {:ok, provenance} <- normalize_provenance(Keyword.get(opts, :provenance)) do
      {:ok,
       %{
         position_tolerance_m: position_tolerance_m,
         clock_tolerance_s: clock_tolerance_s,
         min_agree: min_agree,
         clock_min_common: clock_min_common,
         combine: combine,
         precedence_scope: precedence_scope,
         outlier_reject: outlier_reject,
         epoch_interval_s: epoch_interval_s,
         systems: systems,
         asserted_frame_label_sets: asserted_frame_label_sets,
         helmert: helmert,
         verify_continuity: verify_continuity,
         provenance: provenance
       }}
    else
      false -> {:error, {:invalid_merge_policy, :invalid}}
      {:error, _} = error -> error
    end
  end

  defp normalize_merge_policy(_opts), do: {:error, {:invalid_merge_policy, :not_keyword}}

  defp normalize_nonnegative_float(value, field) when is_number(value) do
    value = value / 1.0

    if value >= 0.0 and value - value == 0.0 do
      {:ok, if(value == 0.0, do: 0.0, else: value)}
    else
      reason = if value < 0.0, do: :negative, else: :not_finite

      {:error, {:sp3_merge_tolerance, %{field: field, value: json_safe_number(value), reason: reason}}}
    end
  end

  defp normalize_nonnegative_float(value, field),
    do: {:error, {:sp3_merge_tolerance, %{field: field, value: inspect(value), reason: :not_numeric}}}

  defp normalize_positive_integer(value, _field) when is_integer(value) and value > 0, do: {:ok, value}
  defp normalize_positive_integer(_value, field), do: {:error, {:invalid_merge_policy, field}}

  defp normalize_combine(value) when value in [:mean, :median, :precedence], do: {:ok, value}
  defp normalize_combine(_value), do: {:error, {:invalid_merge_policy, :combine}}

  defp normalize_provenance(nil), do: {:ok, nil}
  defp normalize_provenance(mode) when mode in [:summary, :full], do: {:ok, mode}
  defp normalize_provenance(_mode), do: {:error, {:invalid_merge_policy, :provenance}}

  defp normalize_epoch_interval(nil), do: {:ok, nil}

  # Preserve the caller's interval for the core's exact 10 ns tick and range
  # validation; rounding here would erase the value the core needs to report.
  defp normalize_epoch_interval(value) when is_number(value) do
    {:ok, value / 1.0}
  end

  defp normalize_epoch_interval(_value), do: {:error, {:invalid_merge_policy, :epoch_interval_s}}

  # Ask the core's identity validator to check the same exact tick interval
  # and specification range before data acquisition begins.
  defp validate_core_identity_interval(value) do
    case NIF.sp3_validate_merge_target_interval(value) do
      {:ok, {}} -> :ok
      :ok -> :ok
      {:error, _reason} = error -> error
      other -> {:error, {:invalid_merge_input_identity, other}}
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :sp3_validate_merge_target_interval)
  end

  defp json_safe_number(value) when is_float(value) do
    if value - value == 0.0, do: value, else: inspect(value)
  end

  defp json_safe_number(value), do: value

  defp normalize_policy_systems(opts) do
    case Keyword.fetch(opts, :systems) do
      :error -> {:ok, []}
      {:ok, nil} -> {:ok, []}
      {:ok, []} -> {:error, {:invalid_merge_policy, :systems}}
      {:ok, systems} -> normalize_merge_systems(systems)
    end
  end

  defp normalize_boolean(value, _field) when is_boolean(value), do: {:ok, value}
  defp normalize_boolean(_value, field), do: {:error, {:invalid_merge_policy, field}}

  defp normalize_verify_continuity(value) when value in [nil, false], do: {:ok, nil}
  defp normalize_verify_continuity(true), do: normalize_verify_continuity([])

  defp normalize_verify_continuity(opts) when is_list(opts) do
    case normalize_continuity_options(opts) do
      {:ok, orbit_class, residual_tolerance_m, gap_threshold_factor} ->
        {:ok, {orbit_class, residual_tolerance_m, gap_threshold_factor}}

      {:error, reason} ->
        {:error, {:invalid_verify_continuity, reason}}
    end
  end

  defp normalize_verify_continuity(value), do: {:error, {:invalid_verify_continuity, value}}

  defp normalize_gap_threshold_factor(opts) when is_list(opts) do
    case Keyword.get(opts, :gap_threshold_factor) do
      nil -> {:ok, nil}
      factor when is_number(factor) -> {:ok, factor / 1.0}
      other -> {:error, {:bad_gap_threshold_factor, other}}
    end
  end

  defp normalize_gap_threshold_factor(other), do: {:error, {:bad_gap_threshold_factor, other}}

  defp outlier_reject_map(nil), do: nil

  defp outlier_reject_map({position_tolerance_m, clock_tolerance_s}) do
    %{
      position_tolerance_m: position_tolerance_m,
      clock_tolerance_s: clock_tolerance_s
    }
  end

  defp normalize_asserted_frame_label_sets(nil), do: {:ok, []}

  defp normalize_asserted_frame_label_sets(label_sets) when is_list(label_sets) do
    label_sets
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {labels, index}, {:ok, acc} ->
      cond do
        not is_list(labels) ->
          {:halt, {:error, {:invalid_frame_label_set, index, labels}}}

        length(labels) < 2 ->
          {:halt, {:error, {:invalid_frame_label_set, index, labels}}}

        true ->
          case normalize_frame_labels(labels, index) do
            {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
            {:error, _} = err -> {:halt, err}
          end
      end
    end)
    |> case do
      {:ok, sets} ->
        sets = sets |> Enum.reverse() |> Enum.sort()

        if length(sets) == MapSet.size(MapSet.new(sets)),
          do: {:ok, sets},
          else: {:error, {:invalid_frame_label_sets, :duplicate}}

      {:error, _} = err ->
        err
    end
  end

  defp normalize_asserted_frame_label_sets(value), do: {:error, {:invalid_frame_label_sets, value}}

  defp normalize_precedence_scope(:cell), do: {:ok, :cell}
  defp normalize_precedence_scope(:satellite_arc), do: {:ok, :satellite_arc}
  defp normalize_precedence_scope(value), do: {:error, {:invalid_precedence_scope, value}}

  defp normalize_outlier_reject(nil), do: {:ok, nil}

  defp normalize_outlier_reject(value) when is_list(value) do
    if Keyword.keyword?(value) and length(Keyword.keys(value)) == MapSet.size(MapSet.new(Keyword.keys(value))) do
      value |> Map.new() |> normalize_outlier_reject()
    else
      {:error, {:invalid_outlier_reject, value}}
    end
  end

  defp normalize_outlier_reject(%{} = value) do
    case value do
      %{position_tolerance_m: position_m, clock_tolerance_s: clock_s} when map_size(value) == 2 ->
        with {:ok, position_m} <- normalize_nonnegative_float(position_m, :outlier_position_tolerance_m),
             {:ok, clock_s} <- normalize_nonnegative_float(clock_s, :outlier_clock_tolerance_s) do
          {:ok, {position_m, clock_s}}
        end

      _other ->
        position_m = Map.get(value, :position_m)
        clock_ns = Map.get(value, :clock_ns)

        if map_size(value) == 2 do
          with {:ok, position_m} <- normalize_nonnegative_float(position_m, :outlier_position_m),
               {:ok, clock_ns} <- normalize_nonnegative_float(clock_ns, :outlier_clock_ns) do
            {:ok, {position_m, canonical_zero(clock_ns * 1.0e-9)}}
          else
            _ -> {:error, {:invalid_outlier_reject, value}}
          end
        else
          {:error, {:invalid_outlier_reject, value}}
        end
    end
  end

  defp normalize_outlier_reject(value), do: {:error, {:invalid_outlier_reject, value}}

  defp normalize_frame_labels(labels, index) do
    labels
    |> Enum.reduce_while({:ok, []}, fn label, {:ok, acc} ->
      normalized = if(is_binary(label), do: String.trim(label))

      if not is_binary(normalized) or normalized == "" do
        {:halt, {:error, {:invalid_frame_label_set, index, labels}}}
      else
        {:cont, {:ok, [normalized | acc]}}
      end
    end)
    |> case do
      {:ok, normalized} ->
        normalized = normalized |> Enum.reverse() |> Enum.uniq() |> Enum.sort()

        if length(normalized) >= 2,
          do: {:ok, normalized},
          else: {:error, {:invalid_frame_label_set, index, labels}}

      {:error, _} = err ->
        err
    end
  end

  defp normalize_merge_systems(systems) when is_list(systems) do
    systems
    |> Enum.reduce_while({:ok, []}, fn system, {:ok, acc} ->
      case normalize_merge_system(system) do
        {:ok, letter} -> {:cont, {:ok, [letter | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, letters} -> {:ok, letters |> Enum.reverse() |> Enum.uniq() |> Enum.sort()}
      {:error, _} = err -> err
    end
  end

  defp normalize_merge_systems(system), do: {:error, {:unsupported_systems_filter, system}}

  defp normalize_merge_system(system) when is_atom(system) do
    case system do
      :gps -> {:ok, "G"}
      :glonass -> {:ok, "R"}
      :galileo -> {:ok, "E"}
      :beidou -> {:ok, "C"}
      :qzss -> {:ok, "J"}
      :navic -> {:ok, "I"}
      :sbas -> {:ok, "S"}
      other -> {:error, {:unsupported_system, other}}
    end
  end

  defp normalize_merge_system(<<letter::binary-size(1)>>) do
    case String.upcase(letter) do
      system when system in ~w(G R E C J I S) -> {:ok, system}
      other -> {:error, {:unsupported_system, other}}
    end
  end

  defp normalize_merge_system(other), do: {:error, {:unsupported_system, other}}

  defp canonical_zero(value) when value == 0.0, do: 0.0
  defp canonical_zero(value), do: value

  defp validate_coverage(%__MODULE__{} = sp3, epoch, opts) do
    if extrapolate?(opts) or covers_epoch?(sp3, epoch) do
      :ok
    else
      {:error, :outside_coverage}
    end
  end

  defp extrapolate?(opts) when is_list(opts), do: Keyword.get(opts, :extrapolate, false) == true
  defp extrapolate?(_opts), do: false

  defp coverage_from_bytes(bytes) when is_binary(bytes) do
    bytes
    |> :binary.split("\n", [:global])
    |> Enum.filter(&match?(<<"*", _::binary>>, &1))
    |> case do
      [] ->
        {:error, :missing_coverage}

      epochs ->
        with {:ok, start_s} <- epochs |> hd() |> coverage_epoch_seconds(),
             {:ok, end_s} <- epochs |> List.last() |> coverage_epoch_seconds() do
          {:ok, {start_s, end_s}}
        end
    end
  end

  defp from_handle(handle, bytes) do
    with {:ok, {coverage_start, coverage_end}} <- coverage_from_bytes(bytes) do
      {:ok,
       %__MODULE__{
         handle: handle,
         time_scale: NIF.sp3_time_scale(handle),
         coverage_start: coverage_start,
         coverage_end: coverage_end
       }}
    end
  end

  defp coverage_epoch_seconds(<<"*", rest::binary>>) do
    case String.split(rest) do
      [year, month, day, hour, minute, second | _] ->
        with {year, ""} <- Integer.parse(year),
             {month, ""} <- Integer.parse(month),
             {day, ""} <- Integer.parse(day),
             {hour, ""} <- Integer.parse(hour),
             {minute, ""} <- Integer.parse(minute),
             {second, ""} <- Float.parse(second) do
          Time.epoch_to_j2000_seconds_fractional({{year, month, day}, {hour, minute, second}})
        else
          _ -> {:error, :invalid_coverage}
        end

      _ ->
        {:error, :invalid_coverage}
    end
  end
end
