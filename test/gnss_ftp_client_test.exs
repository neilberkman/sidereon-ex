defmodule Sidereon.GNSS.FtpClientTest do
  use ExUnit.Case, async: false

  alias Sidereon.GNSS.Data
  alias Sidereon.GNSS.FtpClient
  alias Sidereon.TestSupport.FakeFtpServer

  setup do
    {:ok, server} =
      FakeFtpServer.start_link(
        files: %{
          "/some/file" => :crypto.strong_rand_bytes(10_000),
          "/chunked/file" => String.duplicate("0123456789", 5000)
        },
        listings: %{
          "/some/dir/" => "-rw-r--r-- 1 ftp ftp 1000 Jan 1 00:00 file1.dat\r\n"
        }
      )

    port = FakeFtpServer.port(server)

    on_exit(fn ->
      FakeFtpServer.stop(server)
    end)

    {:ok, server: server, port: port}
  end

  describe "unit tests" do
    test "file retrieval chunking", %{port: port} do
      old_port = Application.get_env(:sidereon, :ftp_port)
      Application.put_env(:sidereon, :ftp_port, port)

      on_exit(fn ->
        if old_port,
          do: Application.put_env(:sidereon, :ftp_port, old_port),
          else: Application.delete_env(:sidereon, :ftp_port)
      end)

      {:ok, pid} = FtpClient.open(~c"127.0.0.1", timeout: 2000, mode: :passive)
      assert :ok == FtpClient.user(pid, ~c"anonymous", ~c"sidereon@")
      assert :ok == FtpClient.type(pid, :binary)
      assert :ok == FtpClient.recv_chunk_start(pid, ~c"/chunked/file")

      chunks = read_all_chunks(pid, [])
      assert chunks != []
      full_data = IO.iodata_to_binary(chunks)
      assert byte_size(full_data) == 50_000
      assert full_data == String.duplicate("0123456789", 5000)

      assert :ok == FtpClient.close(pid)
    end

    test "LIST text", %{port: port} do
      old_port = Application.get_env(:sidereon, :ftp_port)
      Application.put_env(:sidereon, :ftp_port, port)

      on_exit(fn ->
        if old_port,
          do: Application.put_env(:sidereon, :ftp_port, old_port),
          else: Application.delete_env(:sidereon, :ftp_port)
      end)

      {:ok, pid} = FtpClient.open(~c"127.0.0.1", timeout: 2000, mode: :passive)
      assert :ok == FtpClient.user(pid, ~c"anonymous", ~c"sidereon@")
      assert :ok == FtpClient.type(pid, :binary)

      assert {:ok, listing} = FtpClient.ls(pid, ~c"/some/dir/")
      assert listing == "-rw-r--r-- 1 ftp ftp 1000 Jan 1 00:00 file1.dat\r\n"

      assert :ok == FtpClient.close(pid)
    end

    test "550 -> :epath on both ls and recv_chunk_start", %{port: port} do
      old_port = Application.get_env(:sidereon, :ftp_port)
      Application.put_env(:sidereon, :ftp_port, port)

      on_exit(fn ->
        if old_port,
          do: Application.put_env(:sidereon, :ftp_port, old_port),
          else: Application.delete_env(:sidereon, :ftp_port)
      end)

      {:ok, pid} = FtpClient.open(~c"127.0.0.1", timeout: 2000, mode: :passive)
      assert :ok == FtpClient.user(pid, ~c"anonymous", ~c"sidereon@")
      assert :ok == FtpClient.type(pid, :binary)

      assert {:error, :epath} == FtpClient.ls(pid, ~c"/nonexistent/dir/")
      assert {:error, :epath} == FtpClient.recv_chunk_start(pid, ~c"/nonexistent/file")

      assert :ok == FtpClient.close(pid)
    end

    test "timeout on a non-answering port" do
      {:ok, quiet_server} = FakeFtpServer.start_link(non_answering_control: true)
      quiet_port = FakeFtpServer.port(quiet_server)

      old_port = Application.get_env(:sidereon, :ftp_port)
      Application.put_env(:sidereon, :ftp_port, quiet_port)

      on_exit(fn ->
        FakeFtpServer.stop(quiet_server)

        if old_port,
          do: Application.put_env(:sidereon, :ftp_port, old_port),
          else: Application.delete_env(:sidereon, :ftp_port)
      end)

      assert {:error, :timeout} == FtpClient.open(~c"127.0.0.1", timeout: 100, mode: :passive)
    end

    test "multiline reply parsing" do
      {:ok, multi_server} =
        FakeFtpServer.start_link(
          greeting: "220-Header Line 1\r\n220-Header Line 2\r\n220 Ready\r\n",
          user_reply: "331-Please provide pass\r\n331 Pass needed\r\n",
          pass_reply: "230-Welcome back!\r\n230 User logged in\r\n"
        )

      multi_port = FakeFtpServer.port(multi_server)

      old_port = Application.get_env(:sidereon, :ftp_port)
      Application.put_env(:sidereon, :ftp_port, multi_port)

      on_exit(fn ->
        FakeFtpServer.stop(multi_server)

        if old_port,
          do: Application.put_env(:sidereon, :ftp_port, old_port),
          else: Application.delete_env(:sidereon, :ftp_port)
      end)

      {:ok, pid} = FtpClient.open(~c"127.0.0.1", timeout: 2000, mode: :passive)
      assert :ok == FtpClient.user(pid, ~c"anonymous", ~c"sidereon@")
      assert :ok == FtpClient.type(pid, :binary)
      assert :ok == FtpClient.close(pid)
    end
  end

  describe "integration test via Sidereon.GNSS.Data.ftp_fetch/2" do
    test "round-trip file, listing, and 550 not_found_on_archive mapping", %{port: port} do
      old_module = Application.get_env(:sidereon, :ftp_module)
      old_port = Application.get_env(:sidereon, :ftp_port)

      Application.put_env(:sidereon, :ftp_module, FtpClient)
      Application.put_env(:sidereon, :ftp_port, port)

      on_exit(fn ->
        if old_module,
          do: Application.put_env(:sidereon, :ftp_module, old_module),
          else: Application.delete_env(:sidereon, :ftp_module)

        if old_port,
          do: Application.put_env(:sidereon, :ftp_port, old_port),
          else: Application.delete_env(:sidereon, :ftp_port)
      end)

      # 1. File download round-trip
      file_url = "ftp://127.0.0.1/some/file"
      assert {:ok, file_bytes} = Data.ftp_fetch(file_url, [])
      assert byte_size(file_bytes) == 10_000

      # 2. Directory listing round-trip
      dir_url = "ftp://127.0.0.1/some/dir/"
      assert {:ok, listing_bytes} = Data.ftp_fetch(dir_url, [])
      assert listing_bytes == "-rw-r--r-- 1 ftp ftp 1000 Jan 1 00:00 file1.dat\r\n"

      # 3. 550 -> not_found_on_archive mapping
      missing_url = "ftp://127.0.0.1/nonexistent/file"
      assert {:error, {:not_found_on_archive, ^missing_url}} = Data.ftp_fetch(missing_url, [])
    end
  end

  defp read_all_chunks(pid, acc) do
    case FtpClient.recv_chunk(pid) do
      :ok ->
        Enum.reverse(acc)

      {:ok, chunk} ->
        read_all_chunks(pid, [chunk | acc])

      {:error, reason} ->
        flunk("Unexpected recv_chunk error: #{inspect(reason)}")
    end
  end
end
