defmodule Sidereon.GNSS.SP3 do
  @moduledoc """
  SP3-c / SP3-d precise-ephemeris products (IGS precise orbits + clocks).

  This is the Elixir surface over the `astrodynamics-gnss` SP3 parser and
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
  def coverage(%__MODULE__{
        coverage_start: coverage_start,
        coverage_end: coverage_end,
        time_scale: time_scale
      }) do
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
      raise ArgumentError, "could not read SP3 satellite ids: #{inspect(e.original)}"
  end

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
      raise ArgumentError, "could not read SP3 epoch count: #{inspect(e.original)}"
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
      raise ArgumentError, "could not read SP3 epochs: #{inspect(e.original)}"
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
  def states_at(%__MODULE__{handle: handle}, epoch_index)
      when is_integer(epoch_index) and epoch_index >= 0 do
    case NIF.sp3_states_at(handle, epoch_index) do
      {:ok, rows} ->
        {:ok,
         Enum.map(rows, fn {satellite_id, encoded} -> {satellite_id, decode_state(encoded)} end)}

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
  Serialize the product to standard SP3-c / SP3-d text as iodata. Pure, no I/O.

  This is the inverse of `load/1` / `parse/1`: a read → (`merge/2`) → write
  pipeline round-trips to a single standard SP3 file any reader consumes. The
  output is deterministic (same product → identical bytes). Header fields
  (version, epoch count, satellite list, time system, week / seconds-of-week /
  MJD / interval) are derived from the product. A satellite absent at an epoch is
  written as the SP3 missing-orbit sentinel, so a quarantined `merge/2` cell
  re-reads as missing, never a fabricated position.

  To write to disk (optionally gzipped, with an atomic commit), use
  `Sidereon.GNSS.Data.write_sp3/3`.

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
      raise ArgumentError, "could not serialize SP3 product: #{inspect(e.original)}"
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
  epochs on one shared time grid. Mixed-cadence products are rejected unless
  callers resample before merging; they are never unioned onto a finer grid.
  For every `(epoch, satellite)` cell on the shared grid:

    * **Union satellite coverage**: a satellite present in any input may appear
      in the merged product, but only on epochs that keep a coherent arc.
    * **Consensus**: the largest subset of sources agreeing within tolerance is
      combined; sources outside it are recorded as outliers. A cell with no
      agreeing subset of `:min_agree` is *quarantined* (omitted), never averaged
      across disagreeing centers. A lone source is carried through.
    * **Precedence arcs**: with `combine: :precedence`, source selection is
      per satellite arc, not per cell. A satellite never alternates centers at
      adjacent epochs; if the chosen source lacks a cell, that cell is omitted
      rather than filled from a lower-precedence source.

  Returns `{:ok, %Sidereon.GNSS.SP3{}, report}` or `{:error, reason}`, where
  `report` is a map with `:quarantined`, `:single_source`, and
  `:position_outliers` lists. Each entry is a map
  `%{satellite: "G03", jd_whole: float, jd_fraction: float, sources: [0, 2]}`
  (`sources` are zero-based indices into `sources`).

  ## Options

    * `:position_tolerance_m`: position agreement tolerance, meters (default `0.5`)
    * `:clock_tolerance_s`: clock agreement tolerance, seconds (default `5.0e-9`)
    * `:min_agree`: agreeing sources required to accept a contested cell (default `2`)
    * `:clock_min_common`: common clocked satellites for the clock-datum estimate (default `5`)
    * `:combine`: `:mean` (default), `:median`, or `:precedence`
    * `:epoch_interval_s`: require this target epoch interval, seconds
    * `:systems`: restrict output to systems such as `[:gps]` or `["G", "E"]`
  """
  @spec merge([t()], keyword()) :: {:ok, t(), map()} | {:error, term()}
  def merge(sources, opts \\ []) when is_list(sources) do
    with {:ok, system_letters} <- normalize_merge_systems(Keyword.get(opts, :systems, [])) do
      handles = Enum.map(sources, fn %__MODULE__{handle: handle} -> handle end)
      position_tolerance_m = Keyword.get(opts, :position_tolerance_m, 0.5)
      clock_tolerance_s = Keyword.get(opts, :clock_tolerance_s, 5.0e-9)
      min_agree = Keyword.get(opts, :min_agree, 2)
      clock_min_common = Keyword.get(opts, :clock_min_common, 5)
      combine = opts |> Keyword.get(:combine, :mean) |> to_string()
      epoch_interval_s = Keyword.get(opts, :epoch_interval_s)

      case NIF.sp3_merge(
             handles,
             position_tolerance_m,
             clock_tolerance_s,
             min_agree,
             clock_min_common,
             combine,
             epoch_interval_s,
             system_letters
           ) do
        {handle, {quarantined, single_source, position_outliers}} when is_reference(handle) ->
          report = %{
            quarantined: Enum.map(quarantined, &to_flag/1),
            single_source: Enum.map(single_source, &to_flag/1),
            position_outliers: Enum.map(position_outliers, &to_flag/1)
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
  def clock_reference_offset(
        %__MODULE__{handle: reference},
        %__MODULE__{handle: other},
        opts \\ []
      ) do
    min_common = Keyword.get(opts, :min_common, 5)

    reference
    |> NIF.sp3_clock_reference_offset(other, min_common)
    |> Enum.map(fn {jd_whole, jd_fraction, offset_s, satellites} ->
      %{jd_whole: jd_whole, jd_fraction: jd_fraction, offset_s: offset_s, satellites: satellites}
    end)
  rescue
    e in ErlangError ->
      raise ArgumentError, "could not estimate clock reference offset: #{inspect(e.original)}"
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
  def align_clock_reference(
        %__MODULE__{handle: reference},
        %__MODULE__{handle: other} = other_sp3,
        opts \\ []
      ) do
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

  defp attach_coverage({:ok, %__MODULE__{handle: handle} = sp3, report}) do
    with {:ok, {coverage_start, coverage_end}} <- coverage_from_bytes(NIF.sp3_to_iodata(handle)) do
      {:ok, %{sp3 | coverage_start: coverage_start, coverage_end: coverage_end}, report}
    end
  end

  defp attach_coverage(other), do: other

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
