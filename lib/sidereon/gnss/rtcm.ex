defmodule Sidereon.GNSS.RTCM do
  @moduledoc """
  RTCM 3.x differential-GNSS stream decoding.

  RTCM 10403.x is the dominant wire format for real-time GNSS correction and
  observation streams. This module is a thin wrapper over the `sidereon-core`
  `rtcm` sans-I/O decoder: a forgiving frame layer that syncs on the `0xD3`
  preamble and verifies the CRC-24Q, and a canonical message decoder.

  `decode_messages/1` scans a whole byte buffer and returns every CRC-valid
  message; `decode_frame/1` decodes the single frame at the start of a buffer.

  ## Message shapes

  Each decoded message is a `{type, fields}` pair where `type` is one of
  `:station_coordinates` (1005/1006), `:antenna_descriptor` (1007/1008/1033),
  `:gps_ephemeris` (1019), `:glonass_ephemeris` (1020), `:msm` (MSM4/MSM7
  observations), or `:unsupported` (any other number, preserved verbatim). The
  `fields` map carries the raw transmitted integer fields; station coordinates
  additionally carry the scaled `:x_m` / `:y_m` / `:z_m` / `:antenna_height_m`
  values.
  """

  alias Sidereon.NIF

  @type message_type ::
          :station_coordinates
          | :antenna_descriptor
          | :gps_ephemeris
          | :glonass_ephemeris
          | :msm
          | :unsupported
  @type message :: {message_type(), map()}

  @doc """
  Decode every CRC-valid RTCM 3 frame in a byte buffer.

  Frames whose CRC fails or whose body cannot be decoded are skipped, and the
  scan resynchronizes on the next preamble (the forgiving stream contract for a
  noisy feed). Returns `{:ok, [{type, fields}, ...]}` in stream order, or
  `{:error, reason}`.
  """
  @spec decode_messages(binary()) :: {:ok, [message()]} | {:error, term()}
  def decode_messages(bytes) when is_binary(bytes) do
    {:ok, NIF.rtcm_decode_messages(bytes)}
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Decode every CRC-valid RTCM 3 frame in a byte buffer.
  """
  @spec decode(binary()) :: {:ok, [message()]} | {:error, term()}
  def decode(bytes), do: decode_messages(bytes)

  @doc """
  Decode one RTCM message body.
  """
  @spec decode_message(binary()) :: {:ok, message()} | {:error, term()}
  def decode_message(body) when is_binary(body) do
    case NIF.rtcm_decode_message(body) do
      {:ok, message} -> {:ok, message}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Return the message number from one RTCM message body.
  """
  @spec message_number(binary()) :: {:ok, integer()} | {:error, term()}
  def message_number(body) when is_binary(body) do
    case NIF.rtcm_message_number(body) do
      {:ok, number} -> {:ok, number}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Construct a supported RTCM 3 message from a `{type, fields}` pair and encode it
  into a complete transport frame (preamble, length, body, CRC-24Q).

  `type` is one of the supported `message_type/0` atoms (`:unsupported` cannot be
  constructed). `fields` is a map of the raw transmitted fields, the same shape
  `decode_messages/1` produces for that type (the derived `:x_m`/`:y_m`/`:z_m`
  station outputs are ignored when present, so a decoded map round-trips
  directly). Returns `{:ok, frame_binary}` or `{:error, reason}`.

  The output frame feeds back through `decode_messages/1`, so
  `construct -> encode -> decode` reproduces the same message fields.
  """
  @spec encode_message(message()) :: {:ok, binary()} | {:error, term()}
  def encode_message(message), do: encode_frame(message)

  @doc """
  Construct a supported RTCM 3 message and return its message body.
  """
  @spec encode(message()) :: {:ok, binary()} | {:error, term()}
  def encode({type, fields}) when is_atom(type) and is_map(fields) do
    encode_constructed_message(type, fields, &NIF.rtcm_encode/2)
  end

  @doc """
  Construct a supported RTCM 3 message and return its complete frame.
  """
  @spec encode_frame(message() | binary()) :: {:ok, binary()} | {:error, term()}
  def encode_frame({type, fields}) when is_atom(type) and is_map(fields) do
    encode_constructed_message(type, fields, &NIF.rtcm_encode_frame/2)
  end

  def encode_frame(body) when is_binary(body) do
    case NIF.rtcm_encode_frame_body(body) do
      {:ok, frame} -> {:ok, frame}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Decode the single RTCM 3 frame that begins at the start of `bytes`.

  Verifies the preamble and the CRC-24Q. Returns
  `{:ok, %{message_number: n, frame_len: bytes, body: binary}}` or
  `{:error, reason}` for a missing preamble, a truncated buffer, or a CRC
  mismatch. The body can be fed back through `decode_messages/1` after re-framing.
  """
  @spec decode_frame(binary()) ::
          {:ok, %{message_number: integer(), frame_len: integer(), body: binary()}}
          | {:error, term()}
  def decode_frame(bytes) when is_binary(bytes) do
    case NIF.rtcm_decode_frame(bytes) do
      {:ok, %{body: body} = frame} -> {:ok, %{frame | body: :erlang.list_to_binary(body)}}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  defp encode_constructed_message(type, fields, encoder) do
    case encoder.(Atom.to_string(type), fields) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e in ArgumentError -> {:error, e.message}
    e in ErlangError -> {:error, e.original}
  end
end
