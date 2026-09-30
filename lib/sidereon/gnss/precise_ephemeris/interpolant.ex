defmodule Sidereon.GNSS.PreciseEphemeris.Interpolant do
  @moduledoc """
  Cached precise-ephemeris interpolation and exact source-level queries.

  A parsed SP3 product or a sample-built precise source can be converted into a
  persistent interpolant handle. The handle copies the interpolation nodes once,
  then serves repeated GNSS satellite-state queries without re-gathering the
  nodes from the source product.

  State batches return satellite positions in ITRF/IGS ECEF metres and satellite
  clocks in seconds. Query epochs are seconds since J2000 in the source's own
  time scale. Exact source-hook functions also accept broadcast handles and
  preserve independent state and record-selection queries.
  """

  alias Sidereon.GNSS.Broadcast
  alias Sidereon.GNSS.Core.Types
  alias Sidereon.GNSS.PreciseEphemeris
  alias Sidereon.GNSS.PreciseEphemeris.InterpolantArtifact
  alias Sidereon.GNSS.PreciseEphemeris.StateBatch
  alias Sidereon.GNSS.PreciseEphemerisAccuracySample
  alias Sidereon.GNSS.PreciseEphemerisSample
  alias Sidereon.GNSS.SP3
  alias Sidereon.GNSS.Time.ExactEpochQuery
  alias Sidereon.NIF
  alias Sidereon.NifCall

  @max_checksum64 0xFFFF_FFFF_FFFF_FFFF

  @enforce_keys [:handle, :time_scale]
  defstruct [:handle, :time_scale, artifact?: false, byte_len: nil, bytes: nil]

  @typedoc "Precise source accepted by interpolant batch evaluators."
  @type source ::
          SP3.t() | Broadcast.t() | PreciseEphemeris.t() | t() | InterpolantArtifact.t()

  @typedoc "Cached precise-ephemeris interpolant or opened artifact handle."
  @type t :: %__MODULE__{
          handle: reference(),
          time_scale: String.t(),
          artifact?: boolean(),
          byte_len: non_neg_integer() | nil,
          bytes: binary() | nil
        }

  @typedoc "Who computed the checksum carried by an opened artifact handle."
  @type digest_provenance :: :verified | :attested

  @doc """
  Build a cached interpolant from a parsed SP3 product.

  The SP3 product is already parsed and held by the BEAM. This function copies
  its interpolation nodes into a second read-only handle. Returns
  `{:ok, %Sidereon.GNSS.PreciseEphemeris.Interpolant{}}`.

  Options:
    * `:gap_threshold_factor` - override the position-interpolation gap threshold
      factor (default inherits from product).

  A numeric factor at or below `1.0` returns the typed
  `PreciseEphemeris.interpolation_error()` map.
  """
  @spec from_sp3(SP3.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def from_sp3(%SP3{handle: handle}, opts \\ []) do
    with {:ok, factor} <- normalize_gap_threshold_factor(opts) do
      case NIF.precise_interpolant_from_sp3(handle, factor) do
        {:ok, resource} when is_reference(resource) ->
          {:ok, %__MODULE__{handle: resource, time_scale: NIF.precise_interpolant_time_scale(resource)}}

        {:error, _} = err ->
          err

        other ->
          {:error, other}
      end
    end
  rescue
    e in [ErlangError, ArgumentError] -> {:error, nif_error_reason(e)}
  end

  @doc """
  Evaluate states for parallel satellite and epoch arrays, retaining structured
  core error details for failed rows. The legacy `states_at_j2000_s/3` return
  format is unchanged.
  """
  @spec states_at_j2000_s_detailed(source(), [String.t()], [number()]) ::
          {:ok, StateBatch.t()} | {:error, term()}
  def states_at_j2000_s_detailed(source, satellites, epochs_j2000_s)
      when is_list(satellites) and is_list(epochs_j2000_s) do
    with {:ok, handle} <- source_handle(source),
         {:ok, sat_terms} <- satellite_terms(satellites) do
      case NIF.observable_states_at_j2000_s_detailed(
             handle,
             sat_terms,
             Enum.map(epochs_j2000_s, &(&1 / 1.0))
           ) do
        {:ok, tuple} -> {:ok, StateBatch.from_nif_tuple(tuple)}
        {:error, _} = err -> err
        other -> {:error, other}
      end
    end
  rescue
    e in [ErlangError, ArgumentError] -> {:error, nif_error_reason(e)}
  end

  @doc "Alias for `states_at_j2000_s_detailed/3`."
  @spec observable_states_at_j2000_s_detailed(source(), [String.t()], [number()]) ::
          {:ok, StateBatch.t()} | {:error, term()}
  def observable_states_at_j2000_s_detailed(source, satellites, epochs_j2000_s),
    do: states_at_j2000_s_detailed(source, satellites, epochs_j2000_s)

  @doc """
  Build a cached interpolant directly from precise ephemeris samples.

  Samples are `Sidereon.GNSS.PreciseEphemerisSample` structs. They must use one
  time scale, be grouped into at least two strictly increasing epochs per
  satellite, and carry finite positions and clocks. Validation reasons match
  `Sidereon.GNSS.PreciseEphemeris.from_samples/1`.

  Options:
    * `:gap_threshold_factor` - multiple of nominal node spacing above which
      consecutive records mark a coverage gap (default `1.5`, must be > 1.0).

  A numeric factor at or below `1.0` returns the typed
  `PreciseEphemeris.interpolation_error()` map.
  """
  @spec from_samples([PreciseEphemerisSample.t()], keyword()) ::
          {:ok, t()} | {:error, PreciseEphemeris.construction_error()}
  def from_samples(samples, opts \\ []) when is_list(samples) do
    with {:ok, factor} <- normalize_gap_threshold_factor(opts),
         {:ok, tuples} <- to_nif_tuples(samples) do
      case NIF.precise_interpolant_from_samples(tuples, factor) do
        {:ok, resource} when is_reference(resource) ->
          {:ok, %__MODULE__{handle: resource, time_scale: NIF.precise_interpolant_time_scale(resource)}}

        {:error, _} = err ->
          err

        other ->
          {:error, other}
      end
    end
  rescue
    e in [ErlangError, ArgumentError] -> {:error, nif_error_reason(e)}
  end

  @doc """
  Build a cached interpolant from samples and aligned accuracy sidecars.

  A numeric `:gap_threshold_factor` at or below `1.0` returns the typed
  `PreciseEphemeris.interpolation_error()` map.
  """
  @spec from_samples_with_accuracy(
          [PreciseEphemerisSample.t()],
          [PreciseEphemerisAccuracySample.t()],
          keyword()
        ) :: {:ok, t()} | {:error, PreciseEphemeris.construction_error()}
  def from_samples_with_accuracy(samples, accuracy, opts \\ [])

  def from_samples_with_accuracy(samples, accuracy, opts) when is_list(samples) and is_list(accuracy) do
    with {:ok, source} <- PreciseEphemeris.from_samples_with_accuracy(samples, accuracy, opts) do
      from_precise_ephemeris_samples(source, opts)
    end
  end

  def from_samples_with_accuracy(_samples, _accuracy, _opts), do: {:error, :invalid_accuracy_samples}

  @doc """
  Build a cached interpolant from a sample-backed precise ephemeris source.

  This reuses the already validated `Sidereon.GNSS.PreciseEphemeris` handle and
  copies its prepared interpolation nodes. A numeric `:gap_threshold_factor` at
  or below `1.0` returns the typed `PreciseEphemeris.interpolation_error()` map.

  Options:
    * `:gap_threshold_factor` - override the position-interpolation gap threshold
      factor (default inherits from source).

  A numeric factor at or below `1.0` returns the typed
  `PreciseEphemeris.interpolation_error()` map.
  """
  @spec from_precise_ephemeris_samples(PreciseEphemeris.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def from_precise_ephemeris_samples(%PreciseEphemeris{handle: handle}, opts \\ []) do
    with {:ok, factor} <- normalize_gap_threshold_factor(opts) do
      case NIF.precise_interpolant_from_precise_samples(handle, factor) do
        {:ok, resource} when is_reference(resource) ->
          {:ok, %__MODULE__{handle: resource, time_scale: NIF.precise_interpolant_time_scale(resource)}}

        {:error, _} = err ->
          err

        other ->
          {:error, other}
      end
    end
  rescue
    e in [ErlangError, ArgumentError] -> {:error, nif_error_reason(e)}
  end

  @doc """
  Build canonical precise-interpolant artifact bytes from a parsed SP3 product
  or fitted interpolant.

  The returned binary is deterministic for a deterministic source and can be
  persisted by the caller. `open/1` reads the same bytes back into an evaluation
  handle. A numeric `:gap_threshold_factor` at or below `1.0` returns the typed
  `PreciseEphemeris.interpolation_error()` map.

  Options:
    * `:gap_threshold_factor` - override the position-interpolation gap threshold
      factor recorded in the artifact header.
  """
  @spec artifact_bytes(SP3.t() | t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def artifact_bytes(source, opts \\ [])

  def artifact_bytes(%SP3{handle: handle}, opts) do
    with {:ok, factor} <- normalize_gap_threshold_factor(opts) do
      case NIF.precise_interpolant_store_bytes_from_sp3(handle, factor) do
        {:ok, bytes} when is_binary(bytes) -> {:ok, bytes}
        {:error, _} = err -> err
        other -> {:error, other}
      end
    end
  rescue
    e in [ErlangError, ArgumentError] -> {:error, nif_error_reason(e)}
  end

  def artifact_bytes(%__MODULE__{handle: handle}, opts) do
    with {:ok, factor} <- normalize_gap_threshold_factor(opts) do
      case NIF.precise_interpolant_store_bytes_from_interpolant(handle, factor) do
        {:ok, bytes} when is_binary(bytes) -> {:ok, bytes}
        {:error, _} = err -> err
        other -> {:error, other}
      end
    end
  rescue
    e in [ErlangError, ArgumentError] -> {:error, nif_error_reason(e)}
  end

  @doc """
  Open precise-interpolant artifact bytes into an evaluation handle.

  The BEAM binary is copied into the native resource so the resource can outlive
  the caller's binary safely. Inside the resource, the core artifact reader
  borrows its numeric arrays from the owned byte span for repeated evaluation.
  Corrupt and truncated artifacts return typed `{:error, reason}` values.
  """
  @spec open(binary()) :: {:ok, t()} | {:error, term()}
  def open(bytes) when is_binary(bytes) do
    case NIF.precise_interpolant_store_open(bytes) do
      {:ok, resource} when is_reference(resource) ->
        {:ok,
         %__MODULE__{
           handle: resource,
           time_scale: NIF.precise_interpolant_time_scale(resource),
           artifact?: true,
           byte_len: byte_size(bytes),
           bytes: bytes
         }}

      {:error, _} = err ->
        err

      other ->
        {:error, other}
    end
  rescue
    e in [ErlangError, ArgumentError] -> {:error, nif_error_reason(e)}
  end

  @doc """
  Alias for `open/1`, matching the Python artifact `from_bytes` constructor.
  """
  @spec from_bytes(binary()) :: {:ok, t()} | {:error, term()}
  def from_bytes(bytes), do: open(bytes)

  @doc """
  Read precise-interpolant artifact bytes from disk and open them.
  """
  @spec from_path(String.t()) :: {:ok, t()} | {:error, term()}
  def from_path(path) when is_binary(path) do
    with {:ok, bytes} <- File.read(path) do
      open(bytes)
    end
  end

  @doc """
  Open a precise-interpolant artifact using a caller-attested checksum.

  The file is memory-mapped read-only. Construction validates its header,
  index, dimensions, lengths, and payload layout without hashing payloads. The
  claim must equal the checksum declared by the header; a mismatch fails
  immediately and never falls back to hashing.
  """
  @spec from_path_attested(String.t(), non_neg_integer()) ::
          {:ok, t()} | {:error, {:invalid_checksum64, term()} | term()}
  def from_path_attested(path, claimed_checksum64)
      when is_binary(path) and is_integer(claimed_checksum64) and claimed_checksum64 >= 0 and
             claimed_checksum64 <= @max_checksum64 do
    case NIF.precise_interpolant_store_from_path_attested(path, claimed_checksum64) do
      {:ok, resource} when is_reference(resource) ->
        {:ok,
         %__MODULE__{
           handle: resource,
           time_scale: NIF.precise_interpolant_time_scale(resource),
           artifact?: true,
           byte_len: NIF.precise_interpolant_store_byte_len_handle(resource)
         }}

      {:error, _} = err ->
        err

      other ->
        {:error, other}
    end
  rescue
    e in [ErlangError, ArgumentError] -> {:error, nif_error_reason(e)}
  end

  def from_path_attested(path, claimed_checksum64) when is_binary(path) do
    {:error, {:invalid_checksum64, claimed_checksum64}}
  end

  @doc """
  Return the artifact checksum.

  Pass artifact bytes to compute their checksum directly. Passing an opened
  artifact handle returns the checksum of the resource's backing bytes. Passing
  a fitted interpolant builds artifact bytes first and then checksums them.
  """
  @spec checksum(binary() | t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def checksum(bytes) when is_binary(bytes), do: {:ok, NIF.precise_interpolant_store_checksum64_bytes(bytes)}

  def checksum(%__MODULE__{artifact?: true, handle: handle}) do
    {:ok, NIF.precise_interpolant_store_checksum64_handle(handle)}
  rescue
    e in [ErlangError, ArgumentError] -> {:error, nif_error_reason(e)}
  end

  def checksum(%__MODULE__{} = interpolant) do
    with {:ok, bytes} <- artifact_bytes(interpolant) do
      checksum(bytes)
    end
  end

  @doc """
  Alias for `checksum/1`, matching the Python artifact `checksum64` accessor.
  """
  @spec checksum64(binary() | t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def checksum64(source), do: checksum(source)

  @doc """
  Return who computed the checksum carried by an opened artifact handle.
  """
  @spec digest_provenance(t()) :: digest_provenance()
  def digest_provenance(%__MODULE__{artifact?: true, handle: handle}) do
    NIF.precise_interpolant_store_digest_provenance(handle)
  end

  @doc """
  Verify the file-level and per-satellite payload checksums.

  On success, `digest_provenance/1` returns `:verified`.
  """
  @spec verify(t()) :: :ok | {:error, term()}
  def verify(%__MODULE__{artifact?: true, handle: handle}) do
    case NIF.precise_interpolant_store_verify(handle) do
      :ok -> :ok
      {:error, _} = err -> err
      other -> {:error, other}
    end
  rescue
    e in [ErlangError, ArgumentError] -> {:error, nif_error_reason(e)}
  end

  @doc """
  Return canonical artifact bytes for this handle.

  Opened artifacts return the same bytes supplied to `open/1` or `from_bytes/1`;
  fitted interpolants serialize through the core artifact builder.
  """
  @spec as_bytes(t()) :: {:ok, binary()} | {:error, term()}
  def as_bytes(%__MODULE__{bytes: bytes}) when is_binary(bytes), do: {:ok, bytes}

  def as_bytes(%__MODULE__{artifact?: true, handle: handle}) do
    {:ok, NIF.precise_interpolant_store_bytes_handle(handle)}
  rescue
    e in [ErlangError, ArgumentError] -> {:error, nif_error_reason(e)}
  end

  def as_bytes(%__MODULE__{} = interpolant), do: artifact_bytes(interpolant)

  @doc """
  Return the artifact byte length.
  """
  @spec byte_len(t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def byte_len(%__MODULE__{byte_len: byte_len}) when is_integer(byte_len), do: {:ok, byte_len}

  def byte_len(%__MODULE__{} = interpolant) do
    with {:ok, bytes} <- as_bytes(interpolant) do
      {:ok, byte_size(bytes)}
    end
  end

  @doc """
  Return the source time-scale abbreviation, such as `"GPST"`.
  """
  @spec time_scale(t()) :: String.t()
  def time_scale(%__MODULE__{time_scale: time_scale}), do: time_scale

  @doc """
  Return the position-interpolation gap threshold factor carried by this interpolant or opened artifact.
  """
  @spec gap_threshold_factor(t()) :: float()
  def gap_threshold_factor(%__MODULE__{handle: handle}) do
    NIF.precise_interpolant_gap_threshold_factor(handle)
  rescue
    e in ErlangError ->
      reraise ArgumentError,
              [message: "could not read interpolant gap threshold factor: #{NifCall.describe(e)}"],
              __STACKTRACE__
  end

  @doc """
  Return the satellite ids available in the cached interpolant.

  The ids are canonical SP3/RINEX tokens such as `"G01"` and are sorted in core
  satellite order.
  """
  @spec satellite_ids(t()) :: [String.t()]
  def satellite_ids(%__MODULE__{handle: handle}) do
    NIF.precise_interpolant_satellite_ids(handle)
  rescue
    e in ErlangError ->
      reraise ArgumentError,
              [message: "could not read interpolant satellite ids: #{NifCall.describe(e)}"],
              __STACKTRACE__
  end

  @doc """
  Alias for `satellite_ids/1`, matching the Python/WASM `satellites` accessor.
  """
  @spec satellites(t()) :: [String.t()]
  def satellites(%__MODULE__{} = interpolant), do: satellite_ids(interpolant)

  @doc """
  Evaluate one satellite position and clock at a J2000-second epoch.
  """
  @spec position_at_j2000_seconds(source(), String.t(), number()) :: {:ok, SP3.State.t()} | {:error, term()}
  def position_at_j2000_seconds(source, sat_id, epoch_j2000_s) when is_binary(sat_id) do
    with {:ok, batch} <- states_at_shared_j2000_s(source, [sat_id], epoch_j2000_s),
         {:ok, %{position_ecef_m: {x_m, y_m, z_m}, clock_s: clock_s}} <- StateBatch.element(batch, 0) do
      {:ok, %SP3.State{x_m: x_m, y_m: y_m, z_m: z_m, clock_s: clock_s}}
    end
  end

  @doc "Evaluate a satellite state at an exact epoch query without rounding its absolute epoch."
  @spec position_at_epoch_query(source(), String.t(), ExactEpochQuery.t()) ::
          {:ok, SP3.State.t()} | {:error, term()}
  def position_at_epoch_query(source, sat_id, %ExactEpochQuery{handle: query}) when is_binary(sat_id) do
    with {:ok, handle} <- source_handle(source),
         {:ok, letter, prn} <- Types.parse_sat_id(sat_id) do
      case NIF.precise_interpolant_position_at_epoch_query(handle, letter, prn, query) do
        {:ok, {x_m, y_m, z_m, clock_s}} ->
          {:ok, %SP3.State{x_m: x_m, y_m: y_m, z_m: z_m, clock_s: clock_s}}

        {:error, _} = error ->
          error

        other ->
          {:error, other}
      end
    end
  rescue
    error in ErlangError -> NifCall.error(error, __STACKTRACE__, :precise_interpolant_position_at_epoch_query)
  end

  def position_at_epoch_query(_source, _sat_id, _query), do: {:error, :invalid_exact_epoch_query}

  @doc "Read a selected source state while retaining exact state and selection queries."
  @spec selected_state_at_epoch_queries(
          source(),
          String.t(),
          ExactEpochQuery.t(),
          ExactEpochQuery.t()
        ) :: {:ok, nil | map()} | {:error, term()}
  def selected_state_at_epoch_queries(source, sat_id, %ExactEpochQuery{handle: state_query}, %ExactEpochQuery{
        handle: selection_query
      })
      when is_binary(sat_id) do
    with {:ok, state} <-
           source_hook(source, sat_id, state_query, selection_query, "selected_state", nil) do
      case state do
        nil ->
          {:ok, nil}

        {position_x, position_y, position_z, clock_s, group_delay_s, degraded} ->
          {:ok,
           %{
             position_ecef_m: {position_x, position_y, position_z},
             clock_s: clock_s,
             group_delay_s: group_delay_s,
             degraded: degraded
           }}
      end
    end
  end

  def selected_state_at_epoch_queries(_source, _sat_id, _state_query, _selection_query),
    do: {:error, :invalid_exact_epoch_query}

  @doc "Read a transmission-placement clock at exact state and selection queries."
  @spec transmit_clock_at_epoch_queries(
          source(),
          String.t(),
          ExactEpochQuery.t(),
          ExactEpochQuery.t()
        ) :: {:ok, nil | map()} | {:error, term()}
  def transmit_clock_at_epoch_queries(source, sat_id, %ExactEpochQuery{handle: state_query}, %ExactEpochQuery{
        handle: selection_query
      })
      when is_binary(sat_id) do
    with {:ok, clock} <-
           source_hook(source, sat_id, state_query, selection_query, "transmit_clock", nil) do
      case clock do
        nil -> {:ok, nil}
        {clock_s, degraded} -> {:ok, %{clock_s: clock_s, degraded: degraded}}
      end
    end
  end

  def transmit_clock_at_epoch_queries(_source, _sat_id, _state_query, _selection_query),
    do: {:error, :invalid_exact_epoch_query}

  @doc "Evaluate clock relativity for a state at its exact epoch query."
  @spec clock_relativity_for_state_at_epoch_query(
          source(),
          String.t(),
          ExactEpochQuery.t(),
          {number(), number(), number()}
        ) :: :not_applicable | :unavailable | {:term, float()} | {:error, term()}
  def clock_relativity_for_state_at_epoch_query(
        source,
        sat_id,
        %ExactEpochQuery{handle: state_query} = query,
        {position_x, position_y, position_z} = position
      )
      when is_binary(sat_id) and is_number(position_x) and is_number(position_y) and is_number(position_z) do
    source_hook(source, sat_id, state_query, query.handle, "clock_relativity", position)
  end

  def clock_relativity_for_state_at_epoch_query(_source, _sat_id, _state_query, _position),
    do: {:error, :invalid_exact_epoch_query}

  @doc "Read source variance at independent exact state and selection queries."
  @spec ephemeris_variance_at_epoch_queries(
          source(),
          String.t(),
          ExactEpochQuery.t(),
          ExactEpochQuery.t()
        ) :: float() | nil | {:error, term()}
  def ephemeris_variance_at_epoch_queries(source, sat_id, %ExactEpochQuery{handle: state_query}, %ExactEpochQuery{
        handle: selection_query
      })
      when is_binary(sat_id) do
    source_hook(source, sat_id, state_query, selection_query, "ephemeris_variance", nil)
  end

  def ephemeris_variance_at_epoch_queries(_source, _sat_id, _state_query, _selection_query),
    do: {:error, :invalid_exact_epoch_query}

  defp source_hook(source, sat_id, state_query, selection_query, hook, position) do
    with {:ok, handle} <- source_handle(source),
         {:ok, letter, prn} <- Types.parse_sat_id(sat_id) do
      NIF.precise_source_exact_epoch_hook(
        handle,
        letter,
        prn,
        state_query,
        selection_query,
        hook,
        position
      )
    end
  rescue
    error in ErlangError -> NifCall.error(error, __STACKTRACE__, :precise_source_exact_epoch_hook)
  end

  @doc """
  Evaluate states for parallel satellite and epoch arrays.

  `satellites[i]` is evaluated at `epochs_j2000_s[i]`. The lists must have the
  same length. The returned `StateBatch` is index-aligned with the inputs and
  preserves each scalar result in `batch.results`.
  """
  @spec states_at_j2000_s(source(), [String.t()], [number()]) :: {:ok, StateBatch.t()} | {:error, term()}
  def states_at_j2000_s(source, satellites, epochs_j2000_s) when is_list(satellites) and is_list(epochs_j2000_s) do
    with {:ok, handle} <- source_handle(source),
         {:ok, sat_terms} <- satellite_terms(satellites) do
      case NIF.observable_states_at_j2000_s(handle, sat_terms, Enum.map(epochs_j2000_s, &(&1 / 1.0))) do
        {:ok, tuple} -> {:ok, StateBatch.from_nif_tuple(tuple)}
        {:error, _} = err -> err
        other -> {:error, other}
      end
    end
  rescue
    e in [ErlangError, ArgumentError] -> {:error, nif_error_reason(e)}
  end

  @doc """
  Alias for `states_at_j2000_s/3`.
  """
  @spec observable_states_at_j2000_s(source(), [String.t()], [number()]) :: {:ok, StateBatch.t()} | {:error, term()}
  def observable_states_at_j2000_s(source, satellites, epochs_j2000_s),
    do: states_at_j2000_s(source, satellites, epochs_j2000_s)

  @doc """
  Evaluate states for many satellites at one shared J2000-second epoch.

  The returned `StateBatch` is index-aligned with `satellites`. Missing data is
  represented per element rather than failing the whole call.
  """
  @spec states_at_shared_j2000_s(source(), [String.t()], number()) :: {:ok, StateBatch.t()} | {:error, term()}
  def states_at_shared_j2000_s(source, satellites, epoch_j2000_s) when is_list(satellites) do
    with {:ok, handle} <- source_handle(source),
         {:ok, sat_terms} <- satellite_terms(satellites) do
      case NIF.observable_states_at_shared_j2000_s(handle, sat_terms, epoch_j2000_s / 1.0) do
        {:ok, tuple} -> {:ok, StateBatch.from_nif_tuple(tuple)}
        {:error, _} = err -> err
        other -> {:error, other}
      end
    end
  rescue
    e in [ErlangError, ArgumentError] -> {:error, nif_error_reason(e)}
  end

  @doc """
  Alias for `states_at_shared_j2000_s/3`.
  """
  @spec observable_states_at_shared_j2000_s(source(), [String.t()], number()) ::
          {:ok, StateBatch.t()} | {:error, term()}
  def observable_states_at_shared_j2000_s(source, satellites, epoch_j2000_s),
    do: states_at_shared_j2000_s(source, satellites, epoch_j2000_s)

  defp source_handle(%SP3{handle: handle}), do: {:ok, handle}
  defp source_handle(%Broadcast{handle: handle}), do: {:ok, handle}
  defp source_handle(%PreciseEphemeris{handle: handle}), do: {:ok, handle}
  defp source_handle(%__MODULE__{handle: handle}), do: {:ok, handle}
  defp source_handle(%InterpolantArtifact{interpolant: %__MODULE__{handle: handle}}), do: {:ok, handle}
  defp source_handle(_source), do: {:error, :invalid_source}

  defp satellite_terms(satellites) do
    satellites
    |> Enum.reduce_while({:ok, []}, fn sat, {:ok, acc} ->
      case Types.parse_sat_id(sat) do
        {:ok, letter, prn} -> {:cont, {:ok, [{letter, prn} | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, terms} -> {:ok, Enum.reverse(terms)}
      {:error, _} = err -> err
    end
  end

  defp to_nif_tuples(samples) do
    samples
    |> Enum.reduce_while({:ok, []}, fn sample, {:ok, acc} ->
      case PreciseEphemerisSample.to_nif_tuple(sample) do
        {:ok, tuple} -> {:cont, {:ok, [tuple | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, tuples} -> {:ok, Enum.reverse(tuples)}
      {:error, _} = err -> err
    end
  end

  defp nif_error_reason(error), do: Map.get(error, :original, Exception.message(error))

  defp normalize_gap_threshold_factor(opts) when is_list(opts) do
    case Keyword.get(opts, :gap_threshold_factor) do
      nil -> {:ok, nil}
      factor when is_number(factor) -> {:ok, factor / 1.0}
      other -> {:error, {:bad_gap_threshold_factor, other}}
    end
  end

  defp normalize_gap_threshold_factor(other), do: {:error, {:bad_gap_threshold_factor, other}}
end
