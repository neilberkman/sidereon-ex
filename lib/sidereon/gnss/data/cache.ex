defmodule Sidereon.GNSS.Data.Cache do
  @moduledoc """
  Local, on-disk cache for decompressed GNSS products, with atomic writes,
  SHA-256 integrity, gzip decompression (with a bomb guard), and a JSON
  provenance sidecar.

  The cache stores **decompressed** product files keyed by their canonical IGS
  long-name (path-traversal-safe: the filename is validated to contain no path
  separators or `..`). A successful fetch is committed atomically: bytes are
  written to a temporary file in the same directory, then `File.rename/2`d into
  place, so a crashed or partial download can never leave a half-written file
  visible under its real name.

  Alongside each cached file `<name>` a `<name>.provenance.json` sidecar records
  the source URL, the SHA-256 of both the compressed and decompressed bytes,
  the byte sizes, and the fetch timestamp. The sidecar is **part of the commit
  contract**: `commit/3` returns `{:ok, path}` only if both the product and its
  sidecar are written (if the sidecar cannot be written the product is rolled
  back), so a committed file always carries its integrity hash. `classify/2`
  uses that stored hash to verify a cache hit when the caller supplies no
  explicit checksum.
  """

  # Generous but finite cap on a single decompressed product (gzip-bomb guard).
  @default_max_decompressed_bytes 500 * 1024 * 1024

  @doc """
  The default cache directory, `:filename.basedir(:user_cache, "sidereon/gnss")`.
  """
  @spec default_dir() :: String.t()
  def default_dir, do: :filename.basedir(:user_cache, "sidereon/gnss")

  @doc """
  Resolve the absolute path a product would occupy in `cache_dir`.

  The filename is the product's canonical long-name. The name is validated to
  contain no directory separators, no `..`, and no leading `/`, so a malformed
  product (or any future change to the catalog) can never escape the cache root.
  """
  @spec path_for(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def path_for(cache_dir, filename) when is_binary(cache_dir) and is_binary(filename) do
    with :ok <- validate_filename(filename) do
      {:ok, Path.join(cache_dir, filename)}
    end
  end

  @doc """
  Classify the cache entry at `path` for integrity.

  Returns one of:

    * `{:hit, path}`: present and verified, against `expected_sha256` when the
      caller supplies one, otherwise against the provenance sidecar's stored
      decompressed SHA-256;
    * `:absent`: no cached file;
    * `{:stale, {:checksum_mismatch, expected, got}}`: present but failed
      verification (corrupt or stale);
    * `:unverified`: present but no checksum is available to verify it (no
      caller hash and no usable sidecar, as with a file placed by hand);
    * `{:error, reason}`: the file exists but could not be read.

  The caller decides what to do per mode: a `{:hit, _}` is always usable; online,
  a `:stale` or `:unverified` entry should be re-downloaded; offline, a `:stale`
  entry is terminal while an `:unverified` one is the best available.
  """
  @spec classify(String.t(), String.t() | nil) ::
          {:hit, String.t()} | :absent | {:stale, term()} | :unverified | {:error, term()}
  def classify(path, expected_sha256 \\ nil) when is_binary(path) do
    case File.read(path) do
      {:ok, bytes} -> classify_bytes(path, bytes, expected_sha256)
      {:error, :enoent} -> :absent
      {:error, reason} -> {:error, {:temp_file_error, reason}}
    end
  end

  defp classify_bytes(path, bytes, expected) when is_binary(expected) do
    check(path, bytes, expected)
  end

  defp classify_bytes(path, bytes, nil) do
    case read_provenance(path) do
      {:ok, %{"sha256_decompressed" => hash}} when is_binary(hash) -> check(path, bytes, hash)
      _ -> :unverified
    end
  end

  defp check(path, bytes, expected) do
    got = sha256(bytes)

    if secure_equal?(got, String.downcase(expected)) do
      {:hit, path}
    else
      {:stale, {:checksum_mismatch, expected, got}}
    end
  end

  @doc """
  Decompress a gzip byte buffer, capping the output at `max_bytes`.

  The cap protects against gzip bombs: decompression runs in a streaming
  inflate loop that feeds the compressed input in bounded slices, accumulates
  output chunk by chunk, and aborts the moment the running output size would
  exceed the limit, so the remainder of a bomb is never materialized and peak
  memory stays bounded to roughly `max_bytes`. Returns `{:ok, decompressed}` or
  one of
  `{:error, {:decompress_failed, reason}}` /
  `{:error, {:decompress_size_exceeded, max_bytes, got}}`.
  """
  @spec gunzip(binary(), pos_integer()) ::
          {:ok, binary()} | {:error, term()}
  def gunzip(compressed, max_bytes \\ @default_max_decompressed_bytes)
      when is_binary(compressed) and is_integer(max_bytes) and max_bytes > 0 do
    z = :zlib.open()

    try do
      # 16 + 15 selects gzip wrapping with the default window size.
      :zlib.inflateInit(z, 16 + 15)
      inflate_streaming(z, compressed, max_bytes)
      # Note: we intentionally do not call inflateEnd/1 here. When we abort early
      # at the bomb cap the stream is mid-inflate, and inflateEnd/1 raises
      # :data_error on an unfinished stream, which would clobber our typed error.
      # close/1 in the `after` clause frees the z_stream either way.
    catch
      :error, reason -> {:error, {:decompress_failed, reason}}
    after
      :zlib.close(z)
    end
  rescue
    e -> {:error, {:decompress_failed, Exception.message(e)}}
  end

  @doc """
  Atomically commit decompressed bytes **and** their provenance sidecar.

  Both files are staged to unique temp files in the cache directory and then
  renamed into place (rename is atomic on POSIX). The sidecar is required: if it
  cannot be encoded or renamed, the just-committed product is removed and an
  error is returned, so a `{:ok, path}` result always has a matching sidecar
  carrying the decompressed SHA-256 that `classify/2` later verifies against.
  Creates the cache directory if needed. Returns `{:ok, path}` or a typed error
  (`{:error, {:cache_dir_not_writable, reason}}` /
  `{:error, {:provenance_write_failed, reason}}` /
  `{:error, {:temp_file_error, reason}}`).
  """
  @spec commit(String.t(), binary(), map()) :: {:ok, String.t()} | {:error, term()}
  def commit(path, decompressed, provenance) when is_binary(path) and is_binary(decompressed) do
    dir = Path.dirname(path)
    sidecar = provenance_path(path)

    with :ok <- ensure_dir(dir),
         {:ok, json} <- encode_provenance(provenance),
         {:ok, data_tmp} <- write_temp(dir, decompressed),
         {:ok, prov_tmp} <- write_temp_or_cleanup(dir, json, data_tmp) do
      commit_renames(data_tmp, prov_tmp, path, sidecar)
    end
  end

  @doc """
  Compute the lowercase hex SHA-256 of a byte buffer.
  """
  @spec sha256(binary()) :: String.t()
  def sha256(bytes) when is_binary(bytes) do
    :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  end

  @doc """
  Read and decode a product's provenance sidecar, if present.

  Returns `{:ok, map}`, `:none` when there is no sidecar, or
  `{:error, reason}` when the sidecar exists but cannot be decoded.
  """
  @spec read_provenance(String.t()) :: {:ok, map()} | :none | {:error, term()}
  def read_provenance(path) when is_binary(path) do
    sidecar = provenance_path(path)

    case File.read(sidecar) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, map} -> {:ok, map}
          {:error, reason} -> {:error, {:bad_provenance, reason}}
        end

      {:error, :enoent} ->
        :none

      {:error, reason} ->
        {:error, {:temp_file_error, reason}}
    end
  end

  @doc """
  The default gzip-bomb decompression cap, in bytes.
  """
  @spec default_max_decompressed_bytes() :: pos_integer()
  def default_max_decompressed_bytes, do: @default_max_decompressed_bytes

  # --- helpers -------------------------------------------------------------

  defp validate_filename(filename) do
    cond do
      filename == "" -> {:error, {:unsupported_product, :empty_filename}}
      String.contains?(filename, ["/", "\\", <<0>>]) -> traversal(filename)
      filename in [".", ".."] -> traversal(filename)
      String.contains?(filename, "..") -> traversal(filename)
      Path.type(filename) != :relative -> traversal(filename)
      true -> :ok
    end
  end

  defp traversal(name), do: {:error, {:unsafe_cache_name, name}}

  # Constant-time comparison of two fixed-length hex digests.
  defp secure_equal?(a, b) when byte_size(a) == byte_size(b), do: :crypto.hash_equals(a, b)
  defp secure_equal?(_a, _b), do: false

  # Stream the output through `:zlib.safeInflate/2`. Each call decompresses at
  # most one internal buffer and returns either `{:continue, out}` (more output
  # remains) or `{:finished, out}`. We pass the
  # compressed bytes once, then drain with `[]`, checking the running output
  # length after every chunk so we abort before allocating past `max_bytes`.
  # The remainder of a bomb is therefore never materialized.
  defp inflate_streaming(z, compressed, max_bytes) do
    drain(z, compressed, max_bytes, [], 0)
  end

  defp drain(z, input, max_bytes, acc, running) do
    case :zlib.safeInflate(z, input) do
      {:continue, output} ->
        case accumulate(output, max_bytes, acc, running) do
          {:ok, acc, running} -> drain(z, [], max_bytes, acc, running)
          {:error, _} = err -> err
        end

      {:finished, output} ->
        with {:ok, acc, _running} <- accumulate(output, max_bytes, acc, running) do
          {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}
        end
    end
  end

  defp accumulate(output, max_bytes, acc, running) do
    running = running + IO.iodata_length(output)

    if running > max_bytes do
      {:error, {:decompress_size_exceeded, max_bytes, running}}
    else
      {:ok, [output | acc], running}
    end
  end

  defp ensure_dir(dir) do
    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> {:error, {:cache_dir_not_writable, reason}}
    end
  end

  defp write_temp(dir, bytes) do
    tmp = Path.join(dir, ".tmp-#{System.unique_integer([:positive])}-#{:os.getpid()}")

    case File.write(tmp, bytes) do
      :ok ->
        {:ok, tmp}

      {:error, reason} when reason in [:eacces, :erofs, :enospc] ->
        {:error, {:cache_dir_not_writable, reason}}

      {:error, reason} ->
        {:error, {:temp_file_error, reason}}
    end
  end

  # Stage the second temp; if it fails, remove the first so no orphan is left.
  defp write_temp_or_cleanup(dir, bytes, other_tmp) do
    case write_temp(dir, bytes) do
      {:ok, tmp} ->
        {:ok, tmp}

      {:error, _} = err ->
        File.rm(other_tmp)
        err
    end
  end

  # Rename the product in, then the sidecar. Any failure rolls back so we never
  # leave a product without its sidecar (or a stray temp).
  defp commit_renames(data_tmp, prov_tmp, path, sidecar) do
    case File.rename(data_tmp, path) do
      {:error, reason} ->
        File.rm(data_tmp)
        File.rm(prov_tmp)
        {:error, {:temp_file_error, reason}}

      :ok ->
        case File.rename(prov_tmp, sidecar) do
          :ok ->
            {:ok, path}

          {:error, reason} ->
            File.rm(prov_tmp)
            File.rm(path)
            {:error, {:provenance_write_failed, reason}}
        end
    end
  end

  defp encode_provenance(provenance) do
    case Jason.encode(provenance, pretty: true) do
      {:ok, json} -> {:ok, json}
      {:error, reason} -> {:error, {:provenance_write_failed, reason}}
    end
  end

  defp provenance_path(path), do: path <> ".provenance.json"
end
