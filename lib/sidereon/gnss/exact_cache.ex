defmodule Sidereon.GNSS.ExactCache do
  @moduledoc false

  alias Sidereon.NIF

  @control_directory ".sidereon-cache-v2"
  @lock_filename ".sidereon-cache.lock"
  @marker_filename "current.json"
  @entry_regex ~r/^[0-9a-f]{32}$/
  @digest_regex ~r/^[0-9a-f]{64}$/

  def with_lock(path, timeout_ms, operation) when is_function(operation, 0) do
    directory = Path.dirname(path)

    with :ok <- durable_mkdir(directory),
         {:ok, lock} <- acquire_lock(Path.join(directory, @lock_filename), timeout_ms) do
      try do
        operation.()
      after
        NIF.data_cache_lock_release(lock)
      end
    end
  end

  def committed_files(path) do
    marker_path = marker_path(path)

    case File.read(marker_path) do
      {:ok, marker_bytes} -> resolve_marker(path, marker_bytes)
      {:error, :enoent} -> :miss
      {:error, _reason} -> {:error, {:cache_read_failed, Path.basename(path)}}
    end
  end

  def publish(path, content, archive, provenance) do
    control = control_directory(path)
    entries = Path.join(control, "entries")
    entry_id = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
    files = entry_files(path, entry_id)
    entry_directory = Path.dirname(files.product)
    marker_path = marker_path(path)
    marker_temp = Path.join(control, ".#{@marker_filename}.#{entry_id}.tmp")

    result =
      with :ok <- durable_mkdir(entries),
           :ok <- mkdir_exclusive(entry_directory),
           :ok <- sync_directory(entries),
           :ok <- write_exclusive(files.product, content),
           :ok <- failpoint(:after_payload),
           :ok <- write_exclusive(files.archive, archive),
           :ok <- failpoint(:after_archive),
           :ok <- write_exclusive(files.provenance, provenance),
           :ok <- failpoint(:after_metadata),
           :ok <- sync_directory(entry_directory),
           :ok <- sync_directory(entries),
           :ok <- failpoint(:after_entry_sync),
           marker =
             Jason.encode!(%{
               "schema_version" => 2,
               "entry" => entry_id,
               "provenance_sha256" => sha256(provenance)
             }),
           :ok <- write_exclusive(marker_temp, marker),
           :ok <- failpoint(:after_marker_write),
           :ok <- rename(marker_temp, marker_path),
           :ok <- failpoint(:after_marker_rename),
           :ok <- sync_directory(control),
           :ok <- failpoint(:after_commit_sync) do
        {:ok, files.product}
      end

    case result do
      {:ok, _path} = success ->
        success

      {:error, _reason} = error ->
        File.rm(marker_temp)

        if current_entry(path) != entry_id do
          File.rm_rf(entry_directory)
        end

        error
    end
  end

  def cleanup_abandoned(path) do
    control = control_directory(path)
    entries = Path.join(control, "entries")

    case cleanup_current_entry(path) do
      {:ok, current} ->
        case File.ls(entries) do
          {:ok, children} ->
            Enum.each(children, fn child ->
              if child != current, do: File.rm_rf(Path.join(entries, child))
            end)

          {:error, :enoent} ->
            :ok

          {:error, _reason} ->
            :ok
        end

        case File.ls(control) do
          {:ok, children} ->
            children
            |> Enum.filter(fn child ->
              String.starts_with?(child, ".#{@marker_filename}.") and
                String.ends_with?(child, ".tmp")
            end)
            |> Enum.each(&File.rm(Path.join(control, &1)))

          _ ->
            :ok
        end

        :ok

      :invalid ->
        :ok
    end
  end

  defp resolve_marker(path, marker_bytes) do
    with {:ok, marker} <- Jason.decode(marker_bytes),
         2 <- marker["schema_version"],
         entry_id when is_binary(entry_id) <- marker["entry"],
         true <- Regex.match?(@entry_regex, entry_id),
         expected when is_binary(expected) <- marker["provenance_sha256"],
         true <- Regex.match?(@digest_regex, expected),
         files = entry_files(path, entry_id),
         {:ok, provenance} <- File.read(files.provenance),
         true <- sha256(provenance) == expected do
      {:ok, Map.put(files, :provenance_bytes, provenance)}
    else
      _ -> {:error, {:cache_read_failed, Path.basename(path)}}
    end
  end

  defp acquire_lock(lock_path, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    try_lock(lock_path, deadline)
  end

  defp try_lock(lock_path, deadline) do
    case NIF.data_cache_lock_try(lock_path) do
      {:ok, lock} ->
        {:ok, lock}

      :busy ->
        remaining = deadline - System.monotonic_time(:millisecond)

        if remaining <= 0 do
          {:error, {:cache_write_failed, {:lock_timeout, Path.basename(lock_path)}}}
        else
          Process.sleep(min(10, remaining))
          try_lock(lock_path, deadline)
        end

      {:error, reason} ->
        {:error, {:cache_write_failed, {:lock, reason}}}
    end
  end

  defp durable_mkdir(path) do
    cond do
      File.dir?(path) ->
        :ok

      Path.dirname(path) == path ->
        :ok

      true ->
        parent = Path.dirname(path)

        with :ok <- durable_mkdir(parent),
             :ok <- mkdir_if_absent(path) do
          sync_directory(parent)
        end
    end
  end

  defp mkdir_if_absent(path) do
    case File.mkdir(path) do
      :ok ->
        :ok

      {:error, :eexist} ->
        if File.dir?(path), do: :ok, else: {:error, {:cache_write_failed, {:mkdir, path}}}

      {:error, _reason} ->
        {:error, {:cache_write_failed, {:mkdir, path}}}
    end
  end

  defp mkdir_exclusive(path) do
    case File.mkdir(path) do
      :ok -> :ok
      {:error, _reason} -> {:error, {:cache_write_failed, {:mkdir, Path.basename(path)}}}
    end
  end

  defp write_exclusive(path, bytes) do
    case :file.open(String.to_charlist(path), [:write, :binary, :exclusive]) do
      {:ok, io} ->
        result =
          with :ok <- :file.write(io, bytes),
               :ok <- :file.sync(io),
               :ok <- :file.close(io) do
            :ok
          else
            _ -> {:error, {:cache_write_failed, {:write, Path.basename(path)}}}
          end

        if match?({:error, _}, result) do
          :file.close(io)
          File.rm(path)
        end

        result

      {:error, _reason} ->
        {:error, {:cache_write_failed, {:open, Path.basename(path)}}}
    end
  end

  defp rename(from, to) do
    case File.rename(from, to) do
      :ok -> :ok
      {:error, _reason} -> {:error, {:cache_write_failed, {:rename, Path.basename(to)}}}
    end
  end

  defp sync_directory(path) do
    case NIF.data_cache_sync_directory(path) do
      :ok -> :ok
      {:error, _reason} -> {:error, {:cache_write_failed, {:sync_directory, path}}}
    end
  end

  defp control_directory(path), do: Path.join(Path.dirname(path), @control_directory)
  defp marker_path(path), do: Path.join(control_directory(path), @marker_filename)

  defp entry_files(path, entry_id) do
    directory = Path.join([control_directory(path), "entries", entry_id])
    filename = Path.basename(path)

    %{
      product: Path.join(directory, filename),
      archive: Path.join(directory, filename <> ".archive"),
      provenance: Path.join(directory, filename <> ".provenance.json"),
      entry_id: entry_id
    }
  end

  defp cleanup_current_entry(path) do
    case File.read(marker_path(path)) do
      {:error, :enoent} ->
        {:ok, nil}

      {:ok, marker} ->
        case Jason.decode(marker) do
          {:ok, %{"entry" => entry}} when is_binary(entry) ->
            if Regex.match?(@entry_regex, entry), do: {:ok, entry}, else: :invalid

          _ ->
            :invalid
        end

      {:error, _reason} ->
        :invalid
    end
  end

  defp current_entry(path) do
    case cleanup_current_entry(path) do
      {:ok, entry} -> entry
      :invalid -> nil
    end
  end

  defp failpoint(step) do
    case Process.get({__MODULE__, :failpoint}) do
      function when is_function(function, 1) -> function.(step)
      _ -> :ok
    end
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
