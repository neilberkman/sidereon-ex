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

  @type entry :: %{
          product: String.t(),
          archive: String.t(),
          provenance: String.t(),
          entry_id: String.t(),
          product_bytes: binary(),
          archive_bytes: binary(),
          provenance_bytes: binary()
        }

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
  @spec publish(term(), binary(), binary(), binary()) :: {:ok, entry()} | {:error, term()}
  def publish(cache, content, archive, provenance) do
    case decode_read(NIF.data_exact_cache_publish(cache, content, archive, provenance)) do
      {:ok, files} -> {:ok, files}
      {:error, {:cache_read_failed, reason}} -> {:error, {:cache_write_failed, reason}}
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
    {:ok,
     %{
       product: product,
       archive: archive,
       provenance: provenance,
       entry_id: entry_id,
       product_bytes: product_bytes,
       archive_bytes: archive_bytes,
       provenance_bytes: provenance_bytes
     }}
  end

  defp decode_read({:error, reason}), do: {:error, {:cache_read_failed, reason}}
end
