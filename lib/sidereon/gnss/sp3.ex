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
  alias Sidereon.GNSS.PreciseEphemeris.Interpolant
  alias Sidereon.GNSS.PreciseEphemeris.StateBatch
  alias Sidereon.GNSS.PreciseEphemerisSample
  alias Sidereon.GNSS.Time
  alias Sidereon.NIF

  @enforce_keys [:handle, :time_scale, :coverage_start, :coverage_end]
  defstruct [:handle, :time_scale, :coverage_start, :coverage_end]

  @type t :: %__MODULE__{
          handle: reference(),
          time_scale: String.t(),
          coverage_start: float(),
          coverage_end: float()
        }

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
  """
  @spec load(String.t()) :: {:ok, t()} | {:error, term()}
  def load(path) when is_binary(path) do
    with {:ok, bytes} <- File.read(path) do
      parse_bytes(bytes)
    end
  end

  @doc """
  Like `load/1` but raises on failure.
  """
  @spec load!(String.t()) :: t()
  def load!(path) when is_binary(path) do
    case load(path) do
      {:ok, sp3} -> sp3
      {:error, reason} -> raise ArgumentError, "could not load SP3 #{path}: #{inspect(reason)}"
    end
  end

  @doc """
  Parse an in-memory SP3 byte buffer (already decompressed) into a handle.
  """
  @spec parse(binary()) :: {:ok, t()} | {:error, term()}
  def parse(bytes) when is_binary(bytes), do: parse_bytes(bytes)

  defp parse_bytes(bytes) do
    case NIF.sp3_parse(bytes) do
      handle when is_reference(handle) ->
        with {:ok, {coverage_start, coverage_end}} <- coverage_from_bytes(bytes) do
          {:ok,
           %__MODULE__{
             handle: handle,
             time_scale: NIF.sp3_time_scale(handle),
             coverage_start: coverage_start,
             coverage_end: coverage_end
           }}
        end

      {:error, _} = err ->
        err

      other ->
        {:error, other}
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

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
      reraise ArgumentError, [message: "could not read SP3 satellite ids: #{inspect(e.original)}"], __STACKTRACE__
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
      reraise ArgumentError, [message: "could not read SP3 epoch count: #{inspect(e.original)}"], __STACKTRACE__
  end

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
      reraise ArgumentError, [message: "could not read SP3 epochs: #{inspect(e.original)}"], __STACKTRACE__
  end

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
      reraise ArgumentError, [message: "could not read SP3 prediction status: #{inspect(e.original)}"], __STACKTRACE__
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
    e in ErlangError -> {:error, e.original}
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
    e in ErlangError -> {:error, e.original}
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
              [message: "could not extract precise-ephemeris samples: #{inspect(e.original)}"],
              __STACKTRACE__
  end

  @doc """
  Build canonical precise-interpolant artifact bytes from this SP3 product.
  """
  @spec precise_interpolant_artifact_bytes(t()) :: {:ok, binary()} | {:error, term()}
  def precise_interpolant_artifact_bytes(%__MODULE__{} = sp3) do
    Interpolant.artifact_bytes(sp3)
  end

  @doc """
  Serialize the product to standard SP3-c / SP3-d text as iodata. Pure, no I/O.

  This is the inverse of `load/1` / `parse/1`: a read → (`merge/2`) → write
  pipeline round-trips to a single standard SP3 file any reader consumes. The
  output is deterministic (same product → identical bytes). Header fields
  (version, epoch count, satellite list, time system, week / seconds-of-week /
  MJD / interval) are derived from the product. A satellite absent at an epoch is
  written as the SP3 missing-orbit sentinel, so a quarantined `merge/2` cell
  re-reads as missing, never a fabricated position.

  ## Examples

      {:ok, sp3} = Sidereon.GNSS.SP3.load("igs.sp3")
      iodata = Sidereon.GNSS.SP3.to_iodata(sp3)
      {:ok, reparsed} = Sidereon.GNSS.SP3.parse(IO.iodata_to_binary(iodata))
      Sidereon.GNSS.SP3.satellite_ids(reparsed) == Sidereon.GNSS.SP3.satellite_ids(sp3)
      #=> true
  """
  @spec to_iodata(t(), keyword()) :: iodata()
  def to_iodata(%__MODULE__{handle: handle}, _opts \\ []) do
    NIF.sp3_to_iodata(handle)
  rescue
    e in ErlangError ->
      reraise ArgumentError, [message: "could not serialize SP3 product: #{inspect(e.original)}"], __STACKTRACE__
  end

  @doc """
  Serialize the product to an SP3 text binary.
  """
  @spec to_sp3_string(t(), keyword()) :: binary()
  def to_sp3_string(%__MODULE__{} = sp3, opts \\ []) do
    sp3
    |> to_iodata(opts)
    |> IO.iodata_to_binary()
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

  Returns `{:ok, %Sidereon.GNSS.SP3.State{}}` or `{:error, reason}`.
  """
  @spec position(t(), String.t(), NaiveDateTime.t() | tuple(), keyword()) ::
          {:ok, State.t()} | {:error, term()}
  def position(%__MODULE__{handle: handle, time_scale: scale} = sp3, sat_id, epoch, opts \\ [])
      when is_binary(sat_id) do
    with {:ok, system_letter, prn} <- Types.parse_sat_id(sat_id),
         :ok <- validate_coverage(sp3, epoch, opts),
         {jd_whole, jd_fraction} <- Time.epoch_to_split_jd(epoch) do
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
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Merge several SP3 products from different analysis centers into one consistent
  precise-ephemeris dataset.

  `sources` is a list of loaded products **in precedence order** (earlier wins
  ties). This is orthogonal to time-stitching: it combines providers at the same
  epochs on one shared time grid. Mixed-cadence products are unioned onto the
  finest input cadence by default, using only records actually present in an
  input and never interpolating. For every `(epoch, satellite)` cell:

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
  `:position_rms_m`, `:position_max_m`, `:clock_rms_s`, `:clock_max_s` (each
  `nil` when no multi-source consensus existed), plus `:cells` (per-(epoch,
  satellite) statistics, one per accepted cell) and `:epochs` (per-epoch
  aggregates over multi-source cells). The clock fields of a cell are `nil` when
  the cell carries no clock.

  ## Options

    * `:position_tolerance_m`: position agreement tolerance, meters (default `0.5`)
    * `:clock_tolerance_s`: clock agreement tolerance, seconds (default `5.0e-9`)
    * `:min_agree`: agreeing sources required to accept a contested cell (default `2`)
    * `:clock_min_common`: common clocked satellites for the clock-datum estimate (default `5`)
    * `:combine`: `:mean` (default), `:median`, or `:precedence`
    * `:precedence_scope`: `:cell` (default) or `:satellite_arc`
    * `:outlier_reject`: `nil` (default/current behavior), or a map/keyword list
      with `:position_m` and `:clock_ns` tolerances
    * `:epoch_interval_s`: require this target epoch interval, seconds
    * `:systems`: restrict output to systems such as `[:gps]` or `["G", "E"]`
    * `:asserted_frame_label_sets`: coordinate-label sets the caller asserts
      are equivalent without frame math
    * `:helmert`: enable catalog Helmert reconciliation for known ITRF/IGS
      labels
  """
  @spec merge([t()], keyword()) :: {:ok, t(), map()} | {:error, term()}
  def merge(sources, opts \\ []) when is_list(sources) do
    with {:ok, system_letters} <- normalize_merge_systems(Keyword.get(opts, :systems, [])),
         {:ok, precedence_scope} <-
           normalize_precedence_scope(Keyword.get(opts, :precedence_scope, :cell)),
         {:ok, outlier_reject} <- normalize_outlier_reject(Keyword.get(opts, :outlier_reject)),
         {:ok, asserted_frame_label_sets} <-
           normalize_asserted_frame_label_sets(Keyword.get(opts, :asserted_frame_label_sets, [])) do
      handles = Enum.map(sources, fn %__MODULE__{handle: handle} -> handle end)
      position_tolerance_m = Keyword.get(opts, :position_tolerance_m, 0.5)
      clock_tolerance_s = Keyword.get(opts, :clock_tolerance_s, 5.0e-9)
      min_agree = Keyword.get(opts, :min_agree, 2)
      clock_min_common = Keyword.get(opts, :clock_min_common, 5)
      combine = opts |> Keyword.get(:combine, :mean) |> to_string()
      epoch_interval_s = Keyword.get(opts, :epoch_interval_s)
      helmert = Keyword.get(opts, :helmert, false)

      case NIF.sp3_merge(
             handles,
             position_tolerance_m,
             clock_tolerance_s,
             min_agree,
             clock_min_common,
             combine,
             precedence_scope,
             outlier_reject,
             epoch_interval_s,
             system_letters,
             asserted_frame_label_sets,
             helmert
           ) do
        {handle, {quarantined, single_source, position_outliers, clock_outliers, {frame_reconciliations, agreement}}}
        when is_reference(handle) ->
          report = %{
            frame_reconciliations: Enum.map(frame_reconciliations, &to_frame_reconciliation/1),
            quarantined: Enum.map(quarantined, &to_flag/1),
            single_source: Enum.map(single_source, &to_flag/1),
            position_outliers: Enum.map(position_outliers, &to_flag/1),
            clock_outliers: Enum.map(clock_outliers, &to_flag/1),
            agreement: to_agreement(agreement)
          }

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
    e in ErlangError -> {:error, e.original}
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
              [message: "could not estimate clock reference offset: #{inspect(e.original)}"],
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
    e in ErlangError -> {:error, e.original}
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

  defp attach_coverage({:ok, %__MODULE__{handle: handle} = sp3, report}) do
    with {:ok, {coverage_start, coverage_end}} <- coverage_from_bytes(NIF.sp3_to_iodata(handle)) do
      {:ok, %{sp3 | coverage_start: coverage_start, coverage_end: coverage_end}, report}
    end
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
      {:ok, sets} -> {:ok, Enum.reverse(sets)}
      {:error, _} = err -> err
    end
  end

  defp normalize_asserted_frame_label_sets(value), do: {:error, {:invalid_frame_label_sets, value}}

  defp normalize_precedence_scope(:cell), do: {:ok, "cell"}
  defp normalize_precedence_scope(:satellite_arc), do: {:ok, "satellite_arc"}
  defp normalize_precedence_scope(value), do: {:error, {:invalid_precedence_scope, value}}

  defp normalize_outlier_reject(nil), do: {:ok, nil}

  defp normalize_outlier_reject(value) when is_list(value) do
    if Keyword.keyword?(value) do
      value |> Map.new() |> normalize_outlier_reject()
    else
      {:error, {:invalid_outlier_reject, value}}
    end
  end

  defp normalize_outlier_reject(%{} = value) do
    position_m = Map.get(value, :position_m)
    clock_ns = Map.get(value, :clock_ns)

    if is_number(position_m) and position_m >= 0 and is_number(clock_ns) and clock_ns >= 0 do
      {:ok, {position_m / 1.0, clock_ns * 1.0e-9}}
    else
      {:error, {:invalid_outlier_reject, value}}
    end
  end

  defp normalize_outlier_reject(value), do: {:error, {:invalid_outlier_reject, value}}

  defp normalize_frame_labels(labels, index) do
    labels
    |> Enum.reduce_while({:ok, []}, fn label, {:ok, acc} ->
      normalized = label |> to_string() |> String.trim()

      if normalized == "" do
        {:halt, {:error, {:invalid_frame_label_set, index, labels}}}
      else
        {:cont, {:ok, [normalized | acc]}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, _} = err -> err
    end
  end

  defp normalize_merge_systems(nil), do: {:ok, []}

  defp normalize_merge_systems(systems) when is_list(systems) do
    systems
    |> Enum.reduce_while({:ok, []}, fn system, {:ok, acc} ->
      case normalize_merge_system(system) do
        {:ok, letter} -> {:cont, {:ok, [letter | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, letters} -> {:ok, letters |> Enum.reverse() |> Enum.uniq()}
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
