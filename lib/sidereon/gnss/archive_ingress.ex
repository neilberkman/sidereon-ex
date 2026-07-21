defmodule Sidereon.GNSS.ArchiveIngress do
  @moduledoc false

  @response_private_key :sidereon_gnss_archive_ingress

  defstruct [:limit, size: 0, chunks: [], overflow?: false]

  @type t :: %__MODULE__{
          limit: pos_integer(),
          size: non_neg_integer(),
          chunks: [binary()],
          overflow?: boolean()
        }

  @spec new(pos_integer()) :: t()
  def new(limit) when is_integer(limit) and limit > 0, do: %__MODULE__{limit: limit}

  @doc false
  @spec append(t(), binary()) :: {:cont | :halt, t()}
  def append(%__MODULE__{overflow?: true} = state, _chunk), do: {:halt, state}

  def append(%__MODULE__{} = state, chunk) when is_binary(chunk) do
    remaining = state.limit + 1 - state.size
    kept_size = min(byte_size(chunk), remaining)

    chunks =
      case kept_size do
        0 -> state.chunks
        size when size == byte_size(chunk) -> [chunk | state.chunks]
        size -> [:binary.copy(binary_part(chunk, 0, size)) | state.chunks]
      end

    size = state.size + kept_size
    state = %{state | chunks: chunks, size: size, overflow?: size > state.limit}

    if state.overflow?, do: {:halt, state}, else: {:cont, state}
  end

  @doc false
  @spec finish(t()) :: {:ok, binary(), boolean()}
  def finish(%__MODULE__{} = state) do
    {:ok, state.chunks |> Enum.reverse() |> IO.iodata_to_binary(), state.overflow?}
  end

  @doc false
  @spec req_into(pos_integer()) :: function()
  def req_into(limit) do
    initial = new(limit)

    fn {:data, chunk}, {request, response} ->
      state = Map.get(response.private, @response_private_key, initial)
      {instruction, state} = append(state, chunk)
      response = put_in(response.private[@response_private_key], state)
      {instruction, {request, response}}
    end
  end

  @doc false
  @spec finish_response(Req.Response.t(), pos_integer()) :: {:ok, binary(), boolean()}
  def finish_response(%Req.Response{} = response, limit) do
    response.private
    |> Map.get(@response_private_key, new(limit))
    |> finish()
  end

  @doc false
  @spec read_file(Path.t(), pos_integer()) ::
          {:ok, binary()} | {:error, {:download_size_exceeded, pos_integer()} | File.posix()}
  def read_file(path, limit) when is_binary(path) and is_integer(limit) and limit > 0 do
    case :file.open(path, [:read, :binary, :raw]) do
      {:ok, file} ->
        try do
          read_bounded(fn count -> :file.read(file, count) end, limit)
        after
          :file.close(file)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  @spec read_bounded((pos_integer() -> {:ok, binary()} | :eof | {:error, term()}), pos_integer()) ::
          {:ok, binary()} | {:error, {:download_size_exceeded, pos_integer()} | term()}
  def read_bounded(reader, limit) when is_function(reader, 1) and is_integer(limit) and limit > 0 do
    do_read_bounded(reader, new(limit))
  end

  defp do_read_bounded(reader, %__MODULE__{} = state) do
    requested = state.limit + 1 - state.size

    case reader.(requested) do
      {:ok, ""} ->
        finish_read(state)

      {:ok, bytes} when is_binary(bytes) ->
        case append(state, bytes) do
          {:cont, state} -> do_read_bounded(reader, state)
          {:halt, state} -> {:error, {:download_size_exceeded, state.limit}}
        end

      :eof ->
        finish_read(state)

      {:error, reason} ->
        {:error, reason}

      _invalid ->
        {:error, :invalid_read_result}
    end
  end

  defp finish_read(state) do
    {:ok, bytes, false} = finish(state)
    {:ok, bytes}
  end
end
