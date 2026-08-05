defmodule Sidereon.GNSS.FtpClient do
  @moduledoc """
  Minimal anonymous-FTP client implementation over `:gen_tcp`.

  Replaces Erlang/OTP's legacy `:ftp` application (removed in OTP 30) for
  retrieving open GNSS archive files and listings over FTP.

  ## Test Seams

    * `:ftp_port` - Configured via `Application.get_env(:sidereon, :ftp_port, 21)`.
      Allows overriding the default control port (21) for local test servers.
  """

  use GenServer

  @default_port 21
  @default_timeout_ms 5000

  defstruct [:control_socket, :data_socket, :host, :timeout]

  @type host :: charlist() | String.t() | :inet.ip_address()
  @type opt :: {:timeout, pos_integer()} | {:mode, :passive | :active}

  @doc """
  Opens an FTP control connection to `host`.
  """
  @spec open(host(), [opt()]) :: {:ok, pid()} | {:error, term()}
  def open(host, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout_ms)
    port = Application.get_env(:sidereon, :ftp_port, @default_port)

    host_target = normalize_host(host)
    tcp_opts = [:binary, packet: :line, active: false]

    case :gen_tcp.connect(host_target, port, tcp_opts, timeout) do
      {:ok, socket} ->
        case read_reply(socket, timeout) do
          {:ok, code, _msg} when code in 200..299 ->
            GenServer.start_link(__MODULE__, {socket, host_target, timeout})

          {:ok, 550, _msg} ->
            :gen_tcp.close(socket)
            {:error, :epath}

          {:ok, code, msg} ->
            :gen_tcp.close(socket)
            {:error, {:ftp_error, code, msg}}

          {:error, reason} ->
            :gen_tcp.close(socket)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Authenticates with the FTP server (typically anonymous).
  """
  @spec user(pid(), charlist() | String.t(), charlist() | String.t()) ::
          :ok | {:error, :epath} | {:error, term()}
  def user(pid, user, pass) do
    GenServer.call(pid, {:user, user, pass}, :infinity)
  end

  @doc """
  Sets transfer mode (e.g. `:binary` for `TYPE I`).
  """
  @spec type(pid(), :binary | :ascii) :: :ok | {:error, :epath} | {:error, term()}
  def type(pid, mode) do
    GenServer.call(pid, {:type, mode}, :infinity)
  end

  @doc """
  Lists contents of a directory.
  """
  @spec ls(pid(), charlist() | String.t()) :: {:ok, binary()} | {:error, :epath} | {:error, term()}
  def ls(pid, path) do
    GenServer.call(pid, {:ls, path}, :infinity)
  end

  @doc """
  Starts retrieving a file.
  """
  @spec recv_chunk_start(pid(), charlist() | String.t()) ::
          :ok | {:error, :epath} | {:error, term()}
  def recv_chunk_start(pid, path) do
    GenServer.call(pid, {:recv_chunk_start, path}, :infinity)
  end

  @doc """
  Retrieves the next chunk of the file or signals EOF (`:ok`).
  """
  @spec recv_chunk(pid()) :: :ok | {:ok, binary()} | {:error, :epath} | {:error, term()}
  def recv_chunk(pid) do
    GenServer.call(pid, :recv_chunk, :infinity)
  end

  @doc """
  Closes the FTP connection.
  """
  @spec close(pid()) :: :ok
  def close(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      try do
        GenServer.stop(pid, :normal)
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  # --- GenServer Callbacks ---

  @impl true
  def init({socket, host, timeout}) do
    {:ok, %__MODULE__{control_socket: socket, host: host, timeout: timeout}}
  end

  @impl true
  def handle_call({:user, user, pass}, _from, state) do
    user_str = to_string(user)
    pass_str = to_string(pass)
    cmd = "USER #{user_str}\r\n"

    case send_and_read(state.control_socket, cmd, state.timeout) do
      {:ok, code, _msg} when code in 200..299 ->
        {:reply, :ok, state}

      {:ok, 331, _msg} ->
        pass_cmd = "PASS #{pass_str}\r\n"

        case send_and_read(state.control_socket, pass_cmd, state.timeout) do
          {:ok, code, _msg} when code in 200..299 ->
            {:reply, :ok, state}

          {:ok, 550, _msg} ->
            {:reply, {:error, :epath}, state}

          {:ok, code, msg} ->
            {:reply, {:error, {:ftp_error, code, msg}}, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      {:ok, 550, _msg} ->
        {:reply, {:error, :epath}, state}

      {:ok, code, msg} ->
        {:reply, {:error, {:ftp_error, code, msg}}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:type, mode}, _from, state) do
    type_str = if mode == :binary, do: "I", else: "A"
    cmd = "TYPE #{type_str}\r\n"

    case send_and_read(state.control_socket, cmd, state.timeout) do
      {:ok, code, _msg} when code in 200..299 ->
        {:reply, :ok, state}

      {:ok, 550, _msg} ->
        {:reply, {:error, :epath}, state}

      {:ok, code, msg} ->
        {:reply, {:error, {:ftp_error, code, msg}}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:ls, path}, _from, state) do
    path_str = to_string(path)

    with {:ok, data_host, data_port} <- enter_passive_mode(state),
         {:ok, data_socket} <- connect_data_socket(data_host, data_port, state.timeout),
         cmd = "LIST #{path_str}\r\n",
         {:ok, code, _msg} when code in 100..299 <-
           send_and_read(state.control_socket, cmd, state.timeout),
         {:ok, listing} <- recv_all_closing(data_socket, state.timeout) do
      case read_reply(state.control_socket, state.timeout) do
        {:ok, code, _msg} when code in 200..299 ->
          {:reply, {:ok, listing}, state}

        {:ok, 550, _msg} ->
          {:reply, {:error, :epath}, state}

        {:ok, code, msg} ->
          {:reply, {:error, {:ftp_error, code, msg}}, state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:ok, 550, _msg} ->
        {:reply, {:error, :epath}, state}

      {:ok, code, msg} ->
        {:reply, {:error, {:ftp_error, code, msg}}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:recv_chunk_start, path}, _from, state) do
    state = close_data_socket(state)
    path_str = to_string(path)

    with {:ok, data_host, data_port} <- enter_passive_mode(state),
         {:ok, data_socket} <- connect_data_socket(data_host, data_port, state.timeout),
         cmd = "RETR #{path_str}\r\n",
         {:ok, code, _msg} when code in 100..299 <-
           send_and_read(state.control_socket, cmd, state.timeout) do
      {:reply, :ok, %{state | data_socket: data_socket}}
    else
      {:ok, 550, _msg} ->
        {:reply, {:error, :epath}, state}

      {:ok, code, msg} ->
        {:reply, {:error, {:ftp_error, code, msg}}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:recv_chunk, _from, %{data_socket: nil} = state) do
    {:reply, {:error, :no_data_connection}, state}
  end

  def handle_call(:recv_chunk, _from, %{data_socket: data_socket} = state) do
    case :gen_tcp.recv(data_socket, 0, state.timeout) do
      {:ok, chunk} ->
        {:reply, {:ok, chunk}, state}

      {:error, :closed} ->
        :gen_tcp.close(data_socket)
        new_state = %{state | data_socket: nil}

        case read_reply(new_state.control_socket, new_state.timeout) do
          {:ok, code, _msg} when code in 200..299 ->
            {:reply, :ok, new_state}

          {:ok, 550, _msg} ->
            {:reply, {:error, :epath}, new_state}

          {:ok, code, msg} ->
            {:reply, {:error, {:ftp_error, code, msg}}, new_state}

          {:error, reason} ->
            {:reply, {:error, reason}, new_state}
        end

      {:error, reason} ->
        :gen_tcp.close(data_socket)
        new_state = %{state | data_socket: nil}
        {:reply, {:error, reason}, new_state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    _ = close_data_socket(state)

    if state.control_socket do
      _ = :gen_tcp.send(state.control_socket, "QUIT\r\n")
      _ = :gen_tcp.close(state.control_socket)
    end

    :ok
  end

  # --- Internal Helpers ---

  defp normalize_host(host) when is_binary(host), do: String.to_charlist(host)
  defp normalize_host(host) when is_list(host), do: host
  defp normalize_host(host) when is_tuple(host), do: host

  defp send_and_read(socket, cmd, timeout) do
    case :gen_tcp.send(socket, cmd) do
      :ok -> read_reply(socket, timeout)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec read_reply(:gen_tcp.socket(), pos_integer()) ::
          {:ok, integer(), String.t()} | {:error, term()}
  def read_reply(socket, timeout) do
    case :gen_tcp.recv(socket, 0, timeout) do
      {:ok, line} ->
        case parse_reply_line(line) do
          {:single_line, code, rest} ->
            {:ok, code, rest}

          {:multiline_start, code, code_str, rest} ->
            read_multiline_reply(socket, timeout, code, code_str, [rest])

          {:invalid, line} ->
            {:error, {:bad_reply, line}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_multiline_reply(socket, timeout, code, code_str, acc) do
    case :gen_tcp.recv(socket, 0, timeout) do
      {:ok, line} ->
        case check_multiline_end(line, code_str) do
          {:end, rest} ->
            full_msg = Enum.reverse([rest | acc]) |> Enum.join()
            {:ok, code, full_msg}

          :cont ->
            read_multiline_reply(socket, timeout, code, code_str, [line | acc])
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  @spec parse_reply_line(String.t()) ::
          {:single_line, integer(), String.t()}
          | {:multiline_start, integer(), String.t(), String.t()}
          | {:invalid, String.t()}
  def parse_reply_line(line) do
    case line do
      <<c1, c2, c3, ?-, _rest::binary>> when c1 in ?0..?9 and c2 in ?0..?9 and c3 in ?0..?9 ->
        code = String.to_integer(<<c1, c2, c3>>)
        {:multiline_start, code, <<c1, c2, c3>>, line}

      <<c1, c2, c3, ?\s, _rest::binary>> when c1 in ?0..?9 and c2 in ?0..?9 and c3 in ?0..?9 ->
        code = String.to_integer(<<c1, c2, c3>>)
        {:single_line, code, line}

      <<c1, c2, c3, ?\r, ?\n>> when c1 in ?0..?9 and c2 in ?0..?9 and c3 in ?0..?9 ->
        code = String.to_integer(<<c1, c2, c3>>)
        {:single_line, code, line}

      <<c1, c2, c3, ?\n>> when c1 in ?0..?9 and c2 in ?0..?9 and c3 in ?0..?9 ->
        code = String.to_integer(<<c1, c2, c3>>)
        {:single_line, code, line}

      other ->
        {:invalid, other}
    end
  end

  defp check_multiline_end(line, code_str) do
    if String.starts_with?(line, code_str <> " ") or
         line == code_str <> "\r\n" or
         line == code_str <> "\n" do
      {:end, line}
    else
      :cont
    end
  end

  defp enter_passive_mode(state) do
    case send_and_read(state.control_socket, "PASV\r\n", state.timeout) do
      {:ok, 227, msg} ->
        parse_pasv(msg, state.host)

      {:ok, 550, _msg} ->
        {:error, :epath}

      _other ->
        case send_and_read(state.control_socket, "EPSV\r\n", state.timeout) do
          {:ok, 229, msg} ->
            parse_epsv(msg, state.host)

          {:ok, 550, _msg} ->
            {:error, :epath}

          {:ok, code, msg} ->
            {:error, {:ftp_error, code, msg}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp parse_pasv(msg, fallback_host) do
    case Regex.run(~r/227[^(]*\(([^)]+)\)/, msg) do
      [_, nums_str] ->
        parts = String.split(nums_str, ",") |> Enum.map(&String.trim/1)

        case Enum.map(parts, &String.to_integer/1) do
          [h1, h2, h3, h4, p1, p2] ->
            ip = {h1, h2, h3, h4}
            port = p1 * 256 + p2
            host = if ip == {0, 0, 0, 0}, do: fallback_host, else: ip
            {:ok, host, port}

          _ ->
            {:error, {:bad_pasv_response, msg}}
        end

      nil ->
        {:error, {:bad_pasv_response, msg}}
    end
  end

  defp parse_epsv(msg, host) do
    case Regex.run(~r/229[^(]*\(\|\|\|(\d+)\|/, msg) do
      [_, port_str] ->
        port = String.to_integer(port_str)
        {:ok, host, port}

      nil ->
        {:error, {:bad_epsv_response, msg}}
    end
  end

  defp connect_data_socket(host, port, timeout) do
    tcp_opts = [:binary, packet: :raw, active: false]
    :gen_tcp.connect(host, port, tcp_opts, timeout)
  end

  defp recv_all_closing(socket, timeout) do
    result = recv_all(socket, timeout)
    :gen_tcp.close(socket)
    result
  end

  defp recv_all(socket, timeout) do
    recv_all_acc(socket, timeout, [])
  end

  # A clean data-connection close is the ONLY successful end of a listing;
  # any other receive error (timeout, reset) must surface as an error, never
  # as a silently truncated listing that downstream code would read as "the
  # newest published objects".
  defp recv_all_acc(socket, timeout, acc) do
    case :gen_tcp.recv(socket, 0, timeout) do
      {:ok, data} ->
        recv_all_acc(socket, timeout, [data | acc])

      {:error, :closed} ->
        {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp close_data_socket(state) do
    if state.data_socket do
      _ = :gen_tcp.close(state.data_socket)
      %{state | data_socket: nil}
    else
      state
    end
  end
end
