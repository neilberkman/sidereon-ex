defmodule Sidereon.GNSS.ArchiveCompression do
  @moduledoc false

  alias Sidereon.NIF

  @type compression :: :none | :gzip | :unix_compress
  @type error_reason ::
          :size_limit
          | :invalid_gzip
          | :dictionary_required
          | {:unix_compress, term()}
          | {:unsupported, term()}

  @spec decompress(binary(), compression(), pos_integer()) ::
          {:ok, binary()} | {:error, error_reason()}
  def decompress(bytes, :none, limit) when is_binary(bytes) and is_integer(limit) and limit > 0 do
    if byte_size(bytes) <= limit, do: {:ok, bytes}, else: {:error, :size_limit}
  end

  def decompress(bytes, :gzip, limit) when is_binary(bytes) and is_integer(limit) and limit > 0 do
    stream = :zlib.open()

    try do
      # `:reset` implements RFC 1952's member-sequence model rather than
      # stopping after the first complete member.
      :ok = :zlib.inflateInit(stream, 31, :reset)

      case bounded_inflate(stream, :zlib.safeInflate(stream, bytes), limit, 0, []) do
        {:ok, content} ->
          # `safeInflate/2` reports queued-input progress. `inflateEnd/1` is the
          # authoritative completion check and raises for an incomplete or
          # corrupt final member/trailer.
          :ok = :zlib.inflateEnd(stream)
          {:ok, content}

        {:error, _reason} = error ->
          error
      end
    rescue
      _error -> {:error, :invalid_gzip}
    catch
      _kind, _reason -> {:error, :invalid_gzip}
    after
      try do
        :zlib.inflateEnd(stream)
      rescue
        _error -> :ok
      catch
        _kind, _reason -> :ok
      end

      :zlib.close(stream)
    end
  end

  def decompress(bytes, :unix_compress, limit) when is_binary(bytes) and is_integer(limit) and limit > 0 do
    case NIF.data_unix_compress_decompress(bytes, limit) do
      {:ok, content} -> {:ok, content}
      {:error, {:decompress, detail}} -> {:error, {:unix_compress, detail}}
      {:error, detail} -> {:error, {:unix_compress, detail}}
    end
  end

  def decompress(_bytes, compression, _limit), do: {:error, {:unsupported, compression}}

  defp bounded_inflate(stream, {status, chunk}, limit, size, chunks) when status in [:continue, :finished] do
    chunk_size = :erlang.iolist_size(chunk)

    cond do
      size + chunk_size > limit ->
        {:error, :size_limit}

      status == :finished ->
        {:ok, [chunk | chunks] |> Enum.reverse() |> IO.iodata_to_binary()}

      true ->
        bounded_inflate(
          stream,
          :zlib.safeInflate(stream, []),
          limit,
          size + chunk_size,
          [chunk | chunks]
        )
    end
  end

  defp bounded_inflate(_stream, {:need_dictionary, _adler, _chunk}, _limit, _size, _chunks),
    do: {:error, :dictionary_required}
end
