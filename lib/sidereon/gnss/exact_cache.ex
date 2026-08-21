defmodule Sidereon.GNSS.ExactCache do
  @moduledoc """
  Atomic exact-product cache transactions.

  The cache binds the complete distributor-independent product identity, the
  resolved distribution source, and digests and lengths for validated product,
  distributor archive, and provenance bytes. Native publication uses a bounded
  cross-process lock and one atomic reader-visible commit marker.

  Transport and product-format validation remain caller responsibilities. A
  cache hit returns authenticated bytes; callers must still parse the product
  and interpret the authenticated provenance before use.
  """

  alias Sidereon.GNSS.Distribution.ProductIdentity
  alias Sidereon.NIF

  @control_directory ".sidereon-cache-v3"
  @default_poll_interval_ms 50
  @default_heartbeat_interval_ms 5_000
  @default_liveness_timeout_ms 30_000
  @default_wait_timeout_ms 1_800_000
  @max_duration_ms 18_446_744_073_709_551_615
  @single_flight_option_keys [
    :poll_interval_ms,
    :heartbeat_interval_ms,
    :liveness_timeout_ms,
    :wait_timeout_ms
  ]

  defmodule Owner do
    @moduledoc """
    Exclusive single-flight acquisition ownership for one exact cache miss.

    The native resource refreshes its lease automatically. Publish validated
    bytes through `Sidereon.GNSS.ExactCache.publish/4`, or explicitly release
    the acquisition with `Sidereon.GNSS.ExactCache.abandon/1`.
    """

    @derive {Inspect, except: [:handle]}
    @enforce_keys [:handle]
    defstruct [:handle]

    @opaque t :: %__MODULE__{handle: reference()}
  end

  @type entry :: %{
          product: String.t(),
          archive: String.t(),
          provenance: String.t(),
          entry_id: String.t(),
          product_bytes: binary(),
          archive_bytes: binary(),
          provenance_bytes: binary()
        }

  @type single_flight_option ::
          {:poll_interval_ms, pos_integer()}
          | {:heartbeat_interval_ms, pos_integer()}
          | {:liveness_timeout_ms, pos_integer()}
          | {:wait_timeout_ms, pos_integer()}

  @type single_flight_open :: {:hit, entry()} | {:owner, Owner.t()}

  @type single_flight_error ::
          :single_flight_timeout
          | :single_flight_ownership_lost
          | {:invalid_option, atom()}
          | {:cache_read_failed, term()}
          | {:cache_write_failed, term()}

  @doc "Returns the shared cache protocol's control-directory name."
  @spec control_directory() :: String.t()
  def control_directory, do: @control_directory

  @doc "Runs an operation while holding the bounded cross-process writer lock."
  @spec with_lock(String.t(), ProductIdentity.t(), atom(), non_neg_integer(), (term() -> result)) :: result
        when result: term()
  def with_lock(path, identity, source, timeout_ms \\ 30_000, operation) when is_function(operation, 1) do
    fields = identity_fields(identity)

    case NIF.data_exact_cache_open(path, fields, Atom.to_string(source), timeout_ms) do
      {:ok, cache} ->
        try do
          operation.(cache)
        after
          NIF.data_exact_cache_close(cache)
        end

      {:error, reason} ->
        detail =
          if String.contains?(to_string(reason), "timed out") do
            {:lock_timeout, Path.basename(path)}
          else
            {:lock, reason}
          end

        {:error, {:cache_write_failed, detail}}
    end
  end

  @doc """
  Opens an exact cache with bounded single-flight acquisition.

  A `{:hit, entry}` result contains a complete digest-verified transaction and
  the caller must not fetch. A `{:owner, owner}` result grants this caller the
  exclusive right to fetch, validate, and publish through `publish/4`.

  Timing options are positive integer milliseconds. Defaults are 50 ms for
  `:poll_interval_ms`, 5 seconds for `:heartbeat_interval_ms`, 30 seconds for
  `:liveness_timeout_ms`, and 30 minutes for `:wait_timeout_ms`. The heartbeat
  interval must be shorter than the liveness timeout.
  """
  @spec open_single_flight(String.t(), ProductIdentity.t(), atom(), [single_flight_option()]) ::
          single_flight_open() | {:error, single_flight_error()}
  def open_single_flight(path, identity, source, opts \\ []) do
    with {:ok, {poll_interval_ms, heartbeat_interval_ms, liveness_timeout_ms, wait_timeout_ms}} <-
           single_flight_options(opts) do
      path
      |> NIF.data_exact_cache_open_single_flight(
        identity_fields(identity),
        Atom.to_string(source),
        poll_interval_ms,
        heartbeat_interval_ms,
        liveness_timeout_ms,
        wait_timeout_ms
      )
      |> decode_single_flight_open()
    end
  end

  @doc "Reads a complete digest-verified entry through a lock-owning handle."
  @spec committed_files(term()) :: {:ok, entry()} | :miss | {:error, term()}
  def committed_files(cache) do
    decode_read(NIF.data_exact_cache_read(cache))
  end

  @doc "Reads a complete digest-verified entry without taking the writer lock."
  @spec committed_files(String.t(), ProductIdentity.t(), atom()) ::
          {:ok, entry()} | :miss | {:error, term()}
  def committed_files(path, identity, source) do
    decode_read(
      NIF.data_exact_cache_read_unlocked(
        path,
        identity_fields(identity),
        Atom.to_string(source)
      )
    )
  end

  @doc "Publishes validated bytes as one immutable transaction."
  @spec publish(term() | Owner.t(), binary(), binary(), binary()) :: {:ok, entry()} | {:error, term()}
  def publish(%Owner{handle: owner}, content, archive, provenance) do
    case decode_read(NIF.data_exact_cache_owner_publish(owner, content, archive, provenance)) do
      {:ok, files} -> {:ok, files}
      {:error, {:cache_read_failed, reason}} -> decode_single_flight_write_error(reason)
    end
  end

  def publish(cache, content, archive, provenance) do
    case decode_read(NIF.data_exact_cache_publish(cache, content, archive, provenance)) do
      {:ok, files} -> {:ok, files}
      {:error, {:cache_read_failed, reason}} -> {:error, {:cache_write_failed, reason}}
    end
  end

  @doc "Requests an immediate liveness heartbeat from a single-flight owner."
  @spec heartbeat(Owner.t()) :: :ok | {:error, single_flight_error()}
  def heartbeat(%Owner{handle: owner}) do
    case NIF.data_exact_cache_owner_heartbeat(owner) do
      :ok -> :ok
      {:error, :single_flight_ownership_lost} = error -> error
      {:error, reason} -> {:error, {:cache_write_failed, reason}}
    end
  end

  @doc "Abandons a single-flight acquisition without publishing."
  @spec abandon(Owner.t()) :: :ok | {:error, term()}
  def abandon(%Owner{handle: owner}) do
    case NIF.data_exact_cache_owner_abandon(owner) do
      :ok -> :ok
      {:error, reason} -> {:error, {:cache_write_failed, reason}}
    end
  end

  @doc "Removes unreferenced transaction artifacts while the writer lock is held."
  @spec cleanup_abandoned(term()) :: :ok | {:error, term()}
  def cleanup_abandoned(cache) do
    case NIF.data_exact_cache_cleanup(cache) do
      :ok -> :ok
      {:error, reason} -> {:error, {:cache_write_failed, reason}}
    end
  end

  @doc false
  @spec identity_fields(ProductIdentity.t()) :: [String.t()]
  def identity_fields(%ProductIdentity{} = identity) do
    [
      identity.family,
      identity.analysis_center,
      identity.publisher,
      identity.solution_class,
      identity.campaign,
      Integer.to_string(identity.filename_version),
      Integer.to_string(identity.date.year),
      Integer.to_string(identity.date.month),
      Integer.to_string(identity.date.day),
      identity.issue || "",
      identity.span,
      identity.sample,
      identity.official_filename,
      identity.format,
      identity.format_version || "",
      if(identity.prediction_horizon_days,
        do: Integer.to_string(identity.prediction_horizon_days),
        else: ""
      )
    ]
  end

  defp decode_read(:miss), do: :miss

  defp decode_read({:ok, product, archive, provenance, entry_id, product_bytes, archive_bytes, provenance_bytes}) do
    {:ok, entry(product, archive, provenance, entry_id, product_bytes, archive_bytes, provenance_bytes)}
  end

  defp decode_read({:error, reason}), do: {:error, {:cache_read_failed, reason}}

  defp decode_single_flight_open(
         {:hit, product, archive, provenance, entry_id, product_bytes, archive_bytes, provenance_bytes}
       ) do
    {:hit, entry(product, archive, provenance, entry_id, product_bytes, archive_bytes, provenance_bytes)}
  end

  defp decode_single_flight_open({:owner, owner}), do: {:owner, %Owner{handle: owner}}
  defp decode_single_flight_open({:error, :single_flight_timeout} = error), do: error

  defp decode_single_flight_open({:error, :invalid_single_flight_options}), do: {:error, {:invalid_option, :opts}}

  defp decode_single_flight_open({:error, reason}), do: {:error, {:cache_read_failed, reason}}

  defp decode_single_flight_write_error(:single_flight_ownership_lost), do: {:error, :single_flight_ownership_lost}

  defp decode_single_flight_write_error(reason), do: {:error, {:cache_write_failed, reason}}

  defp entry(product, archive, provenance, entry_id, product_bytes, archive_bytes, provenance_bytes) do
    %{
      product: product,
      archive: archive,
      provenance: provenance,
      entry_id: entry_id,
      product_bytes: product_bytes,
      archive_bytes: archive_bytes,
      provenance_bytes: provenance_bytes
    }
  end

  defp single_flight_options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      case Enum.find(Keyword.keys(opts), &(&1 not in @single_flight_option_keys)) do
        nil -> duration_options(opts)
        key -> {:error, {:invalid_option, key}}
      end
    else
      {:error, {:invalid_option, :opts}}
    end
  end

  defp single_flight_options(_opts), do: {:error, {:invalid_option, :opts}}

  defp duration_options(opts) do
    with {:ok, poll_interval_ms} <-
           duration_option(opts, :poll_interval_ms, @default_poll_interval_ms),
         {:ok, heartbeat_interval_ms} <-
           duration_option(opts, :heartbeat_interval_ms, @default_heartbeat_interval_ms),
         {:ok, liveness_timeout_ms} <-
           duration_option(opts, :liveness_timeout_ms, @default_liveness_timeout_ms),
         {:ok, wait_timeout_ms} <-
           duration_option(opts, :wait_timeout_ms, @default_wait_timeout_ms),
         :ok <- validate_liveness(heartbeat_interval_ms, liveness_timeout_ms) do
      {:ok, {poll_interval_ms, heartbeat_interval_ms, liveness_timeout_ms, wait_timeout_ms}}
    end
  end

  defp duration_option(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 and value <= @max_duration_ms -> {:ok, value}
      _value -> {:error, {:invalid_option, key}}
    end
  end

  defp validate_liveness(heartbeat_interval_ms, liveness_timeout_ms) when heartbeat_interval_ms < liveness_timeout_ms,
    do: :ok

  defp validate_liveness(_heartbeat_interval_ms, _liveness_timeout_ms),
    do: {:error, {:invalid_option, :heartbeat_interval_ms}}
end
