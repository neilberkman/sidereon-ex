defmodule Sidereon.GNSS.NtripTest do
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.Ntrip
  alias Sidereon.GNSS.Ntrip.GgaPosition
  alias Sidereon.GNSS.SSR

  @core_fixtures Path.join(__DIR__, "fixtures")
  @table """
  STR;MOUNT;ID;RTCM 3.2;1004(1),1006(10);2;GPS;NET;USA;40.0;-105.0;1;0;GEN;none;B;N;9600;misc
  """

  test "sourcetable parser returns typed records and serializes through core" do
    assert {:ok, table} = Ntrip.parse_sourcetable(@table)
    assert [%Ntrip.StrRecord{} = stream] = table.records
    assert stream.mountpoint == "MOUNT"
    assert stream.nmea_required == true
    assert stream.authentication == :basic

    assert {:ok, text} = Ntrip.sourcetable_to_text(table)
    assert text =~ "STR;MOUNT;ID"
  end

  test "format_gga delegates sentence generation to core" do
    assert {:ok, sentence} =
             Ntrip.format_gga(%GgaPosition{lat_deg: 40.0, lon_deg: -105.0, height_m: 1600.0}, 12_345.67)

    assert sentence |> String.starts_with?("$GPGGA,032545.67")
    assert String.ends_with?(sentence, "\r\n")
  end

  test "sourcetable fetch can run over an injected raw transport" do
    transport = fn request, _opts ->
      assert request =~ "GET / HTTP/1.0"
      {:ok, ["SOURCETABLE 200 OK\r\n", @table]}
    end

    assert {:ok, table} = Ntrip.sourcetable("caster.invalid", version: :rev1, transport_fun: transport)
    assert [%Ntrip.StrRecord{mountpoint: "MOUNT"}] = table.records
  end

  test "stream process delivers payload from an injected transport" do
    owner = self()

    transport = fn request, _opts ->
      assert request =~ "GET /MOUNT HTTP/1.0"
      {:ok, ["ICY 200 OK\r\n\r\nabc"]}
    end

    assert {:ok, _pid} =
             Ntrip.Stream.start_link(
               host: "caster.invalid",
               mountpoint: "MOUNT",
               version: :rev1,
               sink: owner,
               transport_fun: transport
             )

    assert_receive {:ntrip, _ref, {:payload, "abc"}}
    assert_receive {:ntrip, _ref, {:down, :normal}}
  end

  test "fake caster reconnects with backoff after a stream disconnect" do
    caster =
      start_fake_caster([
        accept_stream("one"),
        accept_stream("two", 50)
      ])

    assert {:ok, pid} =
             Ntrip.Stream.start_link(
               host: "127.0.0.1",
               port: caster.port,
               mountpoint: "MOUNT",
               version: :rev1,
               sink: self(),
               stall_timeout_s: 1.0,
               reconnect: %{initial_s: 0.01, factor: 1.0, cap_s: 0.01, max_reconnects: 1}
             )

    on_exit(fn -> stop_stream(pid) end)

    assert_receive {:fake_caster, :accepted, 1}, 1_000
    assert_receive {:fake_caster, :request, 1, request1}, 1_000
    assert request1 =~ "GET /MOUNT HTTP/1.0"
    assert_receive {:ntrip, _ref, {:payload, "one"}}, 1_000
    assert_receive {:ntrip, _ref, {:reconnecting, :stream_ended, 1}}, 1_000

    assert_receive {:fake_caster, :accepted, 2}, 1_000
    assert_receive {:fake_caster, :request, 2, request2}, 1_000
    assert request2 =~ "GET /MOUNT HTTP/1.0"
    assert_receive {:ntrip, _ref, {:payload, "two"}}, 1_000
  end

  test "fake caster observes immediate and paced GGA writes" do
    caster = start_fake_caster([accept_gga_probe()])

    assert {:ok, pid} =
             Ntrip.Stream.start_link(
               host: "127.0.0.1",
               port: caster.port,
               mountpoint: "VRS",
               version: :rev1,
               sink: self(),
               stall_timeout_s: 1.0,
               gga: %{
                 position: %GgaPosition{lat_deg: 40.0, lon_deg: -105.0, height_m: 1600.0},
                 interval_s: 0.1
               },
               reconnect: %{initial_s: 1.0, factor: 1.0, cap_s: 1.0, max_reconnects: 0}
             )

    on_exit(fn -> stop_stream(pid) end)

    assert_receive {:fake_caster, :accepted, 1}, 1_000
    assert_receive {:fake_caster, :gga, 1, first_gga, first_delay_ms}, 1_000
    assert_receive {:fake_caster, :gga, 2, second_gga, second_delay_ms}, 1_000

    assert first_gga =~ "$GPGGA,"
    assert second_gga =~ "$GPGGA,"
    assert first_delay_ms < 300
    assert second_delay_ms - first_delay_ms >= 75
    assert second_delay_ms - first_delay_ms < 350
  end

  test "fake caster payload can ingest decoded SSR messages into a store sink" do
    ssr_bytes =
      @core_fixtures
      |> Path.join("ssr/SSRA02IGS0_2026181234930_1060.hex")
      |> File.read!()
      |> hex_bytes()

    caster = start_fake_caster([accept_stream(ssr_bytes)])
    store = SSR.new()

    assert {:ok, pid} =
             Ntrip.Stream.start_link(
               host: "127.0.0.1",
               port: caster.port,
               mountpoint: "SSR",
               version: :rev1,
               sink: self(),
               sink_mode: :store,
               store: store,
               week_fun: fn -> {2425, 344_970.0} end,
               stall_timeout_s: 1.0,
               reconnect: %{initial_s: 1.0, factor: 1.0, cap_s: 1.0, max_reconnects: 0}
             )

    on_exit(fn -> stop_stream(pid) end)

    assert_receive {:fake_caster, :accepted, 1}, 1_000
    assert_receive {:ntrip, _ref, {:down, :stream_ended}}, 1_000
    assert {:ok, orbit} = SSR.orbit(store, "G30")
    assert is_float(orbit.radial_m)
  end

  test "fake caster sourcetable for a non-empty mountpoint is terminal" do
    caster =
      start_fake_caster([
        accept_sourcetable(),
        fn socket, parent, index ->
          send(parent, {:fake_caster, :unexpected_reconnect, index})
          recv_request(socket)
        end
      ])

    assert {:ok, pid} =
             Ntrip.Stream.start_link(
               host: "127.0.0.1",
               port: caster.port,
               mountpoint: "MISSING",
               version: :rev1,
               sink: self(),
               stall_timeout_s: 1.0,
               reconnect: %{initial_s: 0.01, factor: 1.0, cap_s: 0.01, max_reconnects: :infinity}
             )

    assert_receive {:fake_caster, :accepted, 1}, 1_000
    assert_receive {:ntrip, _ref, {:down, {:mountpoint_not_found, %Ntrip.Sourcetable{} = table}}}, 1_000
    assert [%Ntrip.StrRecord{mountpoint: "MOUNT"}] = table.records

    refute_receive {:fake_caster, :accepted, 2}, 150
    refute_receive {:fake_caster, :unexpected_reconnect, 2}, 0
    refute Process.alive?(pid)
  end

  test "public stream drains non-payload NTRIP messages across reconnects" do
    caster =
      start_fake_caster([
        accept_stream("one"),
        accept_stream("two", 50)
      ])

    chunks =
      Ntrip.stream(
        host: "127.0.0.1",
        port: caster.port,
        mountpoint: "MOUNT",
        version: :rev1,
        stall_timeout_s: 1.0,
        reconnect: %{initial_s: 0.01, factor: 1.0, cap_s: 0.01, max_reconnects: 1}
      )
      |> Enum.take(2)

    assert chunks == ["one", "two"]
    refute_receive {:ntrip, _ref, {:reconnecting, _reason, _attempt}}, 50
  end

  defp start_fake_caster(handlers) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, packet: :raw, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)
    parent = self()

    pid =
      spawn(fn ->
        handlers
        |> Enum.with_index(1)
        |> Enum.each(fn {handler, index} ->
          case :gen_tcp.accept(listen) do
            {:ok, socket} ->
              send(parent, {:fake_caster, :accepted, index})

              try do
                handler.(socket, parent, index)
              after
                :gen_tcp.close(socket)
              end

            {:error, _reason} ->
              :ok
          end
        end)
      end)

    on_exit(fn ->
      :gen_tcp.close(listen)
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)

    %{port: port, pid: pid}
  end

  defp accept_stream(payload, hold_ms \\ 0) do
    fn socket, parent, index ->
      {:ok, request} = recv_request(socket)
      send(parent, {:fake_caster, :request, index, request})
      :ok = :gen_tcp.send(socket, ["ICY 200 OK\r\n\r\n", payload])
      if hold_ms > 0, do: Process.sleep(hold_ms)
    end
  end

  defp accept_gga_probe do
    fn socket, parent, _index ->
      {:ok, _request} = recv_request(socket)
      :ok = :gen_tcp.send(socket, "ICY 200 OK\r\n\r\n")
      started_ms = System.monotonic_time(:millisecond)

      {:ok, first_gga} = recv_until(socket, "\r\n", 1_000)
      first_delay_ms = System.monotonic_time(:millisecond) - started_ms
      send(parent, {:fake_caster, :gga, 1, first_gga, first_delay_ms})

      {:ok, second_gga} = recv_until(socket, "\r\n", 1_000)
      second_delay_ms = System.monotonic_time(:millisecond) - started_ms
      send(parent, {:fake_caster, :gga, 2, second_gga, second_delay_ms})

      Process.sleep(50)
    end
  end

  defp accept_sourcetable do
    fn socket, _parent, _index ->
      {:ok, _request} = recv_request(socket)
      :ok = :gen_tcp.send(socket, ["SOURCETABLE 200 OK\r\n", @table, "ENDSOURCETABLE\r\n"])
      Process.sleep(20)
    end
  end

  defp recv_request(socket), do: recv_until(socket, "\r\n\r\n", 1_000)

  defp recv_until(socket, marker, timeout_ms, acc \\ "") do
    if :binary.match(acc, marker) == :nomatch do
      case :gen_tcp.recv(socket, 0, timeout_ms) do
        {:ok, bytes} -> recv_until(socket, marker, timeout_ms, acc <> bytes)
        {:error, _reason} = error -> error
      end
    else
      {:ok, acc}
    end
  end

  defp stop_stream(pid) do
    if Process.alive?(pid), do: Process.exit(pid, :normal)
  end

  defp hex_bytes(hex) do
    hex
    |> String.replace(~r/\s+/, "")
    |> Base.decode16!(case: :mixed)
  end
end
