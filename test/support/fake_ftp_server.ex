defmodule Sidereon.TestSupport.FakeFtpServer do
  @moduledoc false

  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @spec port(pid()) :: :inet.port_number()
  def port(pid) do
    GenServer.call(pid, :port)
  end

  @spec stop(pid()) :: :ok
  def stop(pid) do
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
  def init(opts) do
    tcp_opts = [:binary, packet: :line, active: false, reuseaddr: true, ip: {127, 0, 0, 1}]

    case :gen_tcp.listen(0, tcp_opts) do
      {:ok, listen_socket} ->
        {:ok, port} = :inet.port(listen_socket)
        {:ok, _acceptor} = Task.start_link(fn -> accept_loop(listen_socket, opts) end)

        state = %{
          listen_socket: listen_socket,
          port: port,
          opts: opts
        }

        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:port, _from, state) do
    {:reply, state.port, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.listen_socket do
      :gen_tcp.close(state.listen_socket)
    end

    :ok
  end

  # --- Internal Helpers ---

  defp accept_loop(listen_socket, opts) do
    case :gen_tcp.accept(listen_socket, 1000) do
      {:ok, socket} ->
        Task.start(fn -> handle_control(socket, opts) end)
        accept_loop(listen_socket, opts)

      {:error, :timeout} ->
        accept_loop(listen_socket, opts)

      {:error, _closed} ->
        :ok
    end
  end

  defp handle_control(socket, opts) do
    if Keyword.get(opts, :non_answering_control, false) do
      # Do not send greeting or process commands (used for timeout testing)
      Process.sleep(:infinity)
    else
      greeting = Keyword.get(opts, :greeting, "220 Fake FTP Server Ready\r\n")

      if greeting != :no_greeting do
        _ = :gen_tcp.send(socket, greeting)
      end

      session_state = %{
        control_socket: socket,
        data_listener: nil,
        opts: opts
      }

      command_loop(session_state)
    end
  end

  defp command_loop(state) do
    case :gen_tcp.recv(state.control_socket, 0, 5000) do
      {:ok, line} ->
        case process_command(line, state) do
          {:ok, new_state} ->
            command_loop(new_state)

          {:stop, new_state} ->
            if new_state.data_listener, do: :gen_tcp.close(new_state.data_listener)
            :gen_tcp.close(new_state.control_socket)
        end

      {:error, _reason} ->
        if state.data_listener, do: :gen_tcp.close(state.data_listener)
        :gen_tcp.close(state.control_socket)
    end
  end

  defp process_command(line, state) do
    clean_line = line |> String.trim_trailing("\r\n") |> String.trim_trailing("\n")

    case parse_cmd(clean_line) do
      {"USER", _user} ->
        user_reply = Keyword.get(state.opts, :user_reply, "331 Password required\r\n")
        _ = :gen_tcp.send(state.control_socket, user_reply)
        {:ok, state}

      {"PASS", _pass} ->
        pass_reply = Keyword.get(state.opts, :pass_reply, "230 User logged in\r\n")
        _ = :gen_tcp.send(state.control_socket, pass_reply)
        {:ok, state}

      {"TYPE", _type} ->
        _ = :gen_tcp.send(state.control_socket, "200 Type set to I\r\n")
        {:ok, state}

      {"PASV", _} ->
        tcp_opts = [:binary, packet: :raw, active: false, reuseaddr: true, ip: {127, 0, 0, 1}]

        case :gen_tcp.listen(0, tcp_opts) do
          {:ok, data_listener} ->
            {:ok, data_port} = :inet.port(data_listener)
            p1 = div(data_port, 256)
            p2 = rem(data_port, 256)
            reply = "227 Entering Passive Mode (127,0,0,1,#{p1},#{p2})\r\n"
            _ = :gen_tcp.send(state.control_socket, reply)
            {:ok, %{state | data_listener: data_listener}}

          {:error, _reason} ->
            _ = :gen_tcp.send(state.control_socket, "425 Cannot open data connection\r\n")
            {:ok, state}
        end

      {"LIST", path} ->
        if path_550?(path, state.opts) do
          _ = :gen_tcp.send(state.control_socket, "550 Directory not found\r\n")
          if state.data_listener, do: :gen_tcp.close(state.data_listener)
          {:ok, %{state | data_listener: nil}}
        else
          _ =
            :gen_tcp.send(
              state.control_socket,
              "150 Opening BINARY mode data connection for LIST\r\n"
            )

          content = get_listing_content(path, state.opts)

          case accept_data_and_send(state.data_listener, content) do
            :ok ->
              _ = :gen_tcp.send(state.control_socket, "226 Transfer complete\r\n")
              {:ok, %{state | data_listener: nil}}

            {:error, _reason} ->
              _ = :gen_tcp.send(state.control_socket, "425 Data connection failed\r\n")
              {:ok, %{state | data_listener: nil}}
          end
        end

      {"RETR", path} ->
        if path_550?(path, state.opts) do
          _ = :gen_tcp.send(state.control_socket, "550 File not found\r\n")
          if state.data_listener, do: :gen_tcp.close(state.data_listener)
          {:ok, %{state | data_listener: nil}}
        else
          _ =
            :gen_tcp.send(
              state.control_socket,
              "150 Opening BINARY mode data connection for RETR\r\n"
            )

          content = get_file_content(path, state.opts)

          case accept_data_and_send(state.data_listener, content) do
            :ok ->
              _ = :gen_tcp.send(state.control_socket, "226 Transfer complete\r\n")
              {:ok, %{state | data_listener: nil}}

            {:error, _reason} ->
              _ = :gen_tcp.send(state.control_socket, "425 Data connection failed\r\n")
              {:ok, %{state | data_listener: nil}}
          end
        end

      {"QUIT", _} ->
        _ = :gen_tcp.send(state.control_socket, "221 Goodbye\r\n")
        {:stop, state}

      {cmd, _arg} ->
        _ = :gen_tcp.send(state.control_socket, "500 Command #{cmd} not understood\r\n")
        {:ok, state}
    end
  end

  defp parse_cmd(line) do
    case String.split(line, " ", parts: 2) do
      [cmd] -> {String.upcase(cmd), ""}
      [cmd, arg] -> {String.upcase(cmd), arg}
    end
  end

  defp path_550?(path, opts) do
    missing_paths =
      Keyword.get(opts, :missing_paths, ["nonexistent", "missing", "550", "/unknown"])

    Enum.any?(missing_paths, fn p -> String.contains?(path, p) end)
  end

  defp get_listing_content(path, opts) do
    listings = Keyword.get(opts, :listings, %{})
    Map.get(listings, path, "-rw-r--r-- 1 ftp ftp 123 Jan 1 00:00 test_file.txt\r\n")
  end

  defp get_file_content(path, opts) do
    files = Keyword.get(opts, :files, %{})
    Map.get(files, path, "DEFAULT_FILE_CONTENT_FOR_TESTING")
  end

  defp accept_data_and_send(nil, _content), do: {:error, :no_listener}

  defp accept_data_and_send(data_listener, content) do
    case :gen_tcp.accept(data_listener, 2000) do
      {:ok, data_socket} ->
        _ = :gen_tcp.send(data_socket, content)
        :gen_tcp.close(data_socket)
        :gen_tcp.close(data_listener)
        :ok

      {:error, reason} ->
        :gen_tcp.close(data_listener)
        {:error, reason}
    end
  end
end
