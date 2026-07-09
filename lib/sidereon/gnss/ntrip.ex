defmodule Sidereon.GNSS.NTRIP do
  @moduledoc """
  NTRIP client helpers and stream process.

  Protocol handling is delegated to the core sans-I/O machine through the NIF.
  This module owns transport, reconnect timing, and delivery of opaque payload
  bytes or decoded RTCM messages. User-supplied NTRIP endpoints are not checked
  against the archive host allowlist; redirects are classified as terminal
  protocol rejections and are never followed.

  Basic credentials over plain TCP are sent in cleartext. Use `tls: true` when
  the caster supports it.
  """

  alias Sidereon.GNSS.NTRIP
  alias Sidereon.GNSS.SSR
  alias Sidereon.NIF

  @default_port 2101
  @default_stall_timeout_s 30.0
  @default_user_agent "sidereon/0.10.1"

  defmodule GgaPosition do
    @moduledoc """
    Position fields for NTRIP VRS GGA output.
    """
    defstruct lat_deg: 0.0,
              lon_deg: 0.0,
              height_m: 0.0,
              fix_quality: 1,
              num_satellites: 10,
              hdop: 1.0
  end

  defmodule Sourcetable do
    @moduledoc """
    Parsed NTRIP sourcetable resource and record list.
    """
    @enforce_keys [:handle, :records]
    defstruct [:handle, :records]

    @type t :: %__MODULE__{
            handle: term(),
            records: [term()]
          }
  end

  defmodule StrRecord do
    @moduledoc "NTRIP STR record."
    defstruct [
      :mountpoint,
      :identifier,
      :format,
      :format_details,
      :carrier,
      :nav_system,
      :network,
      :country,
      :lat_deg,
      :lon_deg,
      :nmea_required,
      :network_solution,
      :generator,
      :compression,
      :authentication,
      :fee,
      :bitrate,
      :misc
    ]
  end

  defmodule CasRecord do
    @moduledoc "NTRIP CAS record."
    defstruct [
      :host,
      :port,
      :identifier,
      :operator,
      :nmea_required,
      :country,
      :lat_deg,
      :lon_deg,
      :fallback_host,
      :fallback_port,
      :misc
    ]
  end

  defmodule NetRecord do
    @moduledoc "NTRIP NET record."
    defstruct [:identifier, :operator, :authentication, :fee, :web_net, :web_str, :web_reg, :misc]
  end

  defmodule OtherRecord do
    @moduledoc "Unknown NTRIP sourcetable record with fields preserved."
    defstruct [:type_tag, fields: []]
  end

  @type error_reason ::
          :unauthorized
          | :digest_not_supported
          | {:mountpoint_not_found, Sourcetable.t() | nil}
          | {:caster_error, String.t()}
          | {:http_status, non_neg_integer(), String.t()}
          | {:unexpected_content_type, String.t()}
          | {:protocol, term()}
          | {:network, term()}
          | {:stream_stalled, number()}

  @doc """
  Build the raw NTRIP request bytes for a host and option set.

  The options match `sourcetable/2` and `Stream.start_link/1`: `:mountpoint`,
  `:port`, `:version`, `:credentials`, `:user_agent_product`, and `:gga`.
  This is the public sans-I/O request builder used by the stream and raw
  sourcetable flows.
  """
  @spec request_bytes(String.t(), keyword()) :: {:ok, binary()} | {:error, error_reason()}
  def request_bytes(host, opts \\ []) when is_binary(host) and is_list(opts) do
    with {:ok, config} <- config(host, opts) do
      NIF.ntrip_request_bytes(config)
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Alias for `request_bytes/2`, matching the canonical facade function name.
  """
  @spec ntrip_request_bytes(String.t(), keyword()) :: {:ok, binary()} | {:error, error_reason()}
  def ntrip_request_bytes(host, opts \\ []), do: request_bytes(host, opts)

  @doc """
  Fetch and parse a caster sourcetable.
  """
  @spec sourcetable(String.t(), keyword()) :: {:ok, Sourcetable.t()} | {:error, error_reason()}
  def sourcetable(host, opts \\ []) when is_binary(host) do
    opts = Keyword.put(opts, :mountpoint, "")

    cond do
      fun = Keyword.get(opts, :transport_fun) ->
        raw_sourcetable(host, opts, fun)

      Keyword.get(opts, :version, :auto) in [:auto, :rev2] and not Keyword.has_key?(opts, :gga) ->
        http_sourcetable(host, opts)

      true ->
        raw_sourcetable(host, opts, nil)
    end
  end

  @doc """
  Parse sourcetable bytes through the core parser.
  """
  def parse_sourcetable(bytes) when is_binary(bytes) do
    case NIF.ntrip_parse_sourcetable(bytes) do
      {:ok, table} -> {:ok, to_table(table)}
      {:error, reason} -> {:error, {:protocol, reason}}
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Serialize a parsed sourcetable through the core serializer.
  """
  def sourcetable_to_text(%Sourcetable{handle: handle}), do: NIF.ntrip_sourcetable_to_text(handle)

  @doc """
  Format one NMEA GGA sentence for a VRS feed.
  """
  def format_gga(%GgaPosition{} = position, utc_seconds_of_day) when is_number(utc_seconds_of_day) do
    NIF.ntrip_format_gga(Map.from_struct(position), utc_seconds_of_day / 1.0)
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Return an Elixir stream of payload binaries from a started NTRIP stream process.
  """
  def stream(opts) when is_list(opts) do
    Stream.resource(
      fn ->
        owner = self()
        {:ok, pid} = __MODULE__.Stream.start_link(Keyword.put(opts, :sink, owner))
        {pid, nil}
      end,
      fn {pid, _} ->
        stream_next(pid)
      end,
      fn {pid, _} -> Process.exit(pid, :normal) end
    )
  end

  defp stream_next(pid) do
    receive do
      {:ntrip, ref, {:payload, bytes}} -> {[bytes], {pid, ref}}
      {:ntrip, ref, {:down, _reason}} -> {:halt, {pid, ref}}
      {:ntrip, _ref, _message} -> stream_next(pid)
    end
  end

  defp http_sourcetable(host, opts) do
    with {:ok, config} <- config(host, Keyword.put(opts, :version, :rev2)),
         {:ok, {path, headers}} <- NIF.ntrip_request_headers(config),
         url = http_url(host, path, opts),
         {:ok, status, reason, response_headers, body} <- http_get(url, headers, opts) do
      case NIF.ntrip_classify_http_response(status, reason, response_headers) do
        {:sourcetable, _} -> parse_sourcetable(IO.iodata_to_binary(body))
        {:rejected, rejection} -> {:error, map_rejection(rejection, nil)}
        {:stream, _} -> {:error, {:protocol, :expected_sourcetable}}
      end
    end
  end

  defp raw_sourcetable(host, opts, transport_fun) do
    version = opts |> Keyword.get(:version, :rev1) |> raw_version()

    with {:ok, config} <- config(host, Keyword.put(opts, :version, version)),
         {:ok, request} <- NIF.ntrip_request_bytes(config),
         machine = NIF.ntrip_machine_new(config),
         {:ok, chunks} <- raw_exchange(host, request, opts, transport_fun) do
      events =
        chunks
        |> Enum.flat_map(&NIF.ntrip_machine_push(machine, IO.iodata_to_binary(&1)))
        |> Kernel.++(NIF.ntrip_machine_finish(machine))

      case Enum.find(events, &match?({:sourcetable, _}, &1)) do
        {:sourcetable, table} -> {:ok, to_table(table)}
        nil -> raw_terminal(events)
      end
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  defp raw_terminal(events) do
    case Enum.find(events, &match?({:rejected, _}, &1)) do
      {:rejected, rejection} -> {:error, map_rejection(rejection, nil)}
      nil -> {:error, {:protocol, :no_sourcetable}}
    end
  end

  defp http_get(url, headers, opts) do
    case Keyword.get(opts, :http_client) do
      fun when is_function(fun, 2) ->
        normalize_http_response(fun.(url, Keyword.put(opts, :headers, headers)))

      nil ->
        req_get(url, headers, opts)
    end
  rescue
    e -> {:error, {:network, Exception.message(e)}}
  catch
    kind, reason -> {:error, {:network, {kind, reason}}}
  end

  defp req_get(url, headers, opts) do
    timeout_ms = seconds_to_ms(Keyword.get(opts, :timeout_s, @default_stall_timeout_s))

    case Req.get(
           url: url,
           headers: headers,
           redirect: false,
           retry: false,
           receive_timeout: timeout_ms,
           finch: :"Elixir.Sidereon.GNSS.NTRIP.Finch",
           decode_body: false
         ) do
      {:ok, %Req.Response{status: status, headers: headers, body: body}} ->
        normalize_http_response({:ok, status, "OK", headers, body})

      {:error, reason} ->
        {:error, {:network, reason}}
    end
  end

  defp normalize_http_response({:ok, status, headers, body}) when is_integer(status),
    do: normalize_http_response({:ok, status, "OK", headers, body})

  defp normalize_http_response({:ok, status, reason, headers, body}) when is_integer(status),
    do: {:ok, status, to_string(reason), normalize_headers(headers), IO.iodata_to_binary(body)}

  defp normalize_http_response({:ok, %{status: status, headers: headers, body: body}}),
    do: normalize_http_response({:ok, status, "OK", headers, body})

  defp normalize_http_response({:error, reason}), do: {:error, {:network, reason}}
  defp normalize_http_response(other), do: {:error, {:network, {:bad_http_response, other}}}

  defp normalize_headers(headers) when is_map(headers), do: headers |> Map.to_list() |> normalize_headers()

  defp normalize_headers(headers) when is_list(headers),
    do: Enum.map(headers, fn {k, v} -> {to_string(k), to_string(v)} end)

  @doc false
  def config(host, opts) do
    credentials =
      case Keyword.get(opts, :credentials) do
        {username, password} -> {to_string(username), to_string(password)}
        nil -> {nil, nil}
      end

    {username, password} = credentials

    term = %{
      host: host,
      port: Keyword.get(opts, :port, @default_port),
      mountpoint: Keyword.get(opts, :mountpoint, "") |> to_string(),
      version: opts |> Keyword.get(:version, :rev2) |> version_string(),
      username: username,
      password: password,
      user_agent_product: Keyword.get(opts, :user_agent_product, @default_user_agent),
      gga_interval_s: gga_interval(opts)
    }

    case NIF.ntrip_config_new(term) do
      {:ok, handle} -> {:ok, handle}
      {:error, reason} -> {:error, {:protocol, reason}}
    end
  end

  defp gga_interval(opts) do
    case Keyword.get(opts, :gga) do
      %{interval_s: interval} -> interval / 1.0
      %{} -> 10.0
      _ -> nil
    end
  end

  defp raw_exchange(_host, request, opts, fun) when is_function(fun, 2) do
    case fun.(request, opts) do
      {:ok, chunks} when is_list(chunks) -> {:ok, chunks}
      {:ok, body} when is_binary(body) -> {:ok, [body]}
      {:error, reason} -> {:error, {:network, reason}}
      other -> {:error, {:network, {:bad_transport_response, other}}}
    end
  end

  defp raw_exchange(host, request, opts, nil) do
    transport = if Keyword.get(opts, :tls, false), do: :ssl, else: :gen_tcp
    port = Keyword.get(opts, :port, @default_port)
    timeout = seconds_to_ms(Keyword.get(opts, :timeout_s, @default_stall_timeout_s))

    with {:ok, socket} <- connect(transport, host, port, timeout),
         :ok <- send_bytes(transport, socket, request) do
      result = recv_all(transport, socket, timeout, [])
      close_socket(transport, socket)
      result
    end
  end

  @doc false
  def connect(:ssl, host, port, timeout),
    do: :ssl.connect(String.to_charlist(host), port, [:binary, active: false], timeout)

  @doc false
  def connect(:gen_tcp, host, port, timeout),
    do: :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: false, packet: :raw], timeout)

  @doc false
  def send_bytes(:ssl, socket, bytes), do: :ssl.send(socket, bytes)

  @doc false
  def send_bytes(:gen_tcp, socket, bytes), do: :gen_tcp.send(socket, bytes)
  defp close_socket(:ssl, socket), do: :ssl.close(socket)
  defp close_socket(:gen_tcp, socket), do: :gen_tcp.close(socket)

  defp recv_all(transport, socket, timeout, acc) do
    recv =
      case transport do
        :ssl -> :ssl.recv(socket, 0, timeout)
        :gen_tcp -> :gen_tcp.recv(socket, 0, timeout)
      end

    case recv do
      {:ok, bytes} -> recv_all(transport, socket, timeout, [bytes | acc])
      {:error, :closed} -> {:ok, Enum.reverse(acc)}
      {:error, reason} -> {:error, {:network, reason}}
    end
  end

  defp http_url(host, path, opts) do
    scheme = if Keyword.get(opts, :tls, false), do: "https", else: "http"
    port = Keyword.get(opts, :port, @default_port)
    scheme <> "://" <> host <> ":" <> Integer.to_string(port) <> path
  end

  @doc false
  def raw_version(:auto), do: :rev2

  def raw_version(version), do: version
  defp version_string(:rev1), do: "rev1"
  defp version_string(:rev2), do: "rev2"
  defp version_string("rev1"), do: "rev1"
  defp version_string("rev2"), do: "rev2"

  @doc false
  def to_table({handle, records}), do: %Sourcetable{handle: handle, records: Enum.map(records, &to_record/1)}
  defp to_record({:str, fields}), do: struct!(StrRecord, fields)
  defp to_record({:cas, fields}), do: struct!(CasRecord, fields)
  defp to_record({:net, fields}), do: struct!(NetRecord, fields)
  defp to_record({:other, fields}), do: struct!(OtherRecord, fields)

  @doc false
  def map_rejection(:unauthorized, _table), do: :unauthorized
  def map_rejection(:digest_not_supported, _table), do: :digest_not_supported
  def map_rejection(:mountpoint_not_found, table), do: {:mountpoint_not_found, table}
  def map_rejection({:caster_error, reason}, _table), do: {:caster_error, reason}
  def map_rejection({:unexpected_content_type, content_type}, _table), do: {:unexpected_content_type, content_type}
  def map_rejection({:http_status, status, reason}, _table), do: {:http_status, status, reason}
  def map_rejection({:malformed_handshake, prefix}, _table), do: {:protocol, {:malformed_handshake, prefix}}
  def map_rejection(other, _table), do: {:protocol, other}

  @doc false
  def seconds_to_ms(seconds) when is_integer(seconds) and seconds > 1000, do: seconds
  def seconds_to_ms(seconds) when is_number(seconds), do: max(1, round(seconds * 1000))

  defmodule Stream do
    @moduledoc """
    GenServer that owns an NTRIP stream connection.
    """
    use GenServer

    alias Sidereon.NIF

    @default_port 2101
    @default_stall_timeout_s 30.0

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts) do
      state = %{
        opts: opts,
        sink: Keyword.get(opts, :sink),
        ref: make_ref(),
        machine: nil,
        assembler: NIF.rtcm_assembler_new(),
        socket: nil,
        transport: nil,
        attempt: 0,
        last_rx: System.monotonic_time(:millisecond),
        gga_timer_ref: nil
      }

      {:ok, state, {:continue, :connect}}
    end

    @impl true
    def handle_continue(:connect, state), do: connect_stream(state)

    @impl true
    def handle_info({:tcp, socket, bytes}, %{socket: socket, transport: :gen_tcp} = state) do
      :inet.setopts(socket, active: :once)

      bytes
      |> process_bytes(%{state | last_rx: System.monotonic_time(:millisecond)})
      |> stream_reply()
    end

    def handle_info({:ssl, socket, bytes}, %{socket: socket, transport: :ssl} = state) do
      :ssl.setopts(socket, active: :once)

      bytes
      |> process_bytes(%{state | last_rx: System.monotonic_time(:millisecond)})
      |> stream_reply()
    end

    def handle_info({:tcp_closed, socket}, %{socket: socket, transport: :gen_tcp} = state),
      do: socket_closed(state, :stream_ended)

    def handle_info({:ssl_closed, socket}, %{socket: socket, transport: :ssl} = state),
      do: socket_closed(state, :stream_ended)

    def handle_info({:tcp_closed, _socket}, state), do: {:noreply, state}
    def handle_info({:ssl_closed, _socket}, state), do: {:noreply, state}
    def handle_info(:stall_check, state), do: stall_check(state)
    def handle_info(:connect_after_backoff, state), do: connect_stream(state)

    def handle_info({:gga_tick, ref}, %{gga_timer_ref: ref} = state) do
      state
      |> send_gga()
      |> case do
        {:ok, next} -> {:noreply, schedule_gga(next)}
        {:reconnect, next, reason} -> reconnect(next, reason)
        {:stop, next, reason} -> down(next, reason)
      end
    end

    def handle_info({:gga_tick, _ref}, state), do: {:noreply, state}

    defp connect_stream(state) do
      opts = state.opts
      host = Keyword.fetch!(opts, :host)
      version = opts |> Keyword.get(:version, :auto) |> NTRIP.raw_version()

      with {:ok, config} <- NTRIP.config(host, Keyword.put(opts, :version, version)),
           {:ok, request} <- NIF.ntrip_request_bytes(config) do
        machine = NIF.ntrip_machine_new(config)

        case Keyword.get(opts, :transport_fun) do
          fun when is_function(fun, 2) ->
            run_injected(fun, request, %{state | machine: machine})

          _ ->
            open_socket(request, %{state | machine: machine})
        end
      else
        {:error, reason} -> down(state, reason)
      end
    end

    defp run_injected(fun, request, state) do
      case fun.(request, state.opts) do
        {:ok, chunks} when is_list(chunks) ->
          chunks
          |> Enum.reduce_while({:ok, state}, fn chunk, {:ok, next} ->
            case process_bytes(IO.iodata_to_binary(chunk), next) do
              {:ok, next} -> {:cont, {:ok, next}}
              other -> {:halt, other}
            end
          end)
          |> stream_terminal(:normal)

        {:ok, body} when is_binary(body) ->
          body
          |> process_bytes(state)
          |> stream_terminal(:normal)

        {:error, reason} ->
          reconnect(state, {:network, reason})
      end
    end

    defp open_socket(request, state) do
      opts = state.opts
      transport = if Keyword.get(opts, :tls, false), do: :ssl, else: :gen_tcp
      timeout = NTRIP.seconds_to_ms(Keyword.get(opts, :connect_timeout_s, 10.0))
      host = Keyword.fetch!(opts, :host)
      port = Keyword.get(opts, :port, @default_port)

      with {:ok, socket} <- NTRIP.connect(transport, host, port, timeout),
           :ok <- NTRIP.send_bytes(transport, socket, request),
           :ok <- set_active_once(transport, socket) do
        schedule_stall(opts)
        {:noreply, %{state | socket: socket, transport: transport}}
      else
        {:error, reason} -> reconnect(state, {:network, reason})
      end
    end

    defp set_active_once(:ssl, socket), do: :ssl.setopts(socket, active: :once)
    defp set_active_once(:gen_tcp, socket), do: :inet.setopts(socket, active: :once)

    defp process_bytes(bytes, state) do
      events = NIF.ntrip_machine_push(state.machine, bytes)
      process_events(events, state)
    end

    defp process_events(events, state) do
      Enum.reduce_while(events, {:ok, state}, fn event, {:ok, next} ->
        case handle_event(event, next) do
          {:ok, next} -> {:cont, {:ok, next}}
          other -> {:halt, other}
        end
      end)
    end

    defp handle_event({:connected, _handshake}, state) do
      state
      |> send_gga()
      |> case do
        {:ok, next} -> {:ok, schedule_gga(next)}
        other -> other
      end
    end

    defp handle_event({:payload, bytes}, state) do
      if payload_sink_mode(state) != :store do
        deliver(state, {:payload, bytes})
      end

      case payload_sink_mode(state) do
        :rtcm ->
          state.assembler
          |> NIF.rtcm_assembler_push(bytes)
          |> Enum.each(fn
            {:ok, message} -> deliver(state, {:rtcm, message})
            {:error, _reason} -> :ok
          end)

          {:ok, state}

        :store ->
          case ingest_store_payload(state, bytes) do
            :ok -> {:ok, state}
            {:error, reason} -> {:stop, state, reason}
          end

        _ ->
          {:ok, state}
      end
    end

    defp handle_event({:sourcetable, table}, state) do
      table = NTRIP.to_table(table)

      if Keyword.get(state.opts, :mountpoint, "") == "" do
        deliver(state, {:sourcetable, table})
        {:ok, state}
      else
        {:stop, state, {:mountpoint_not_found, table}}
      end
    end

    defp handle_event({:rejected, rejection}, state) do
      {:stop, state, NTRIP.map_rejection(rejection, nil)}
    end

    defp handle_event({:stream_corrupted, detail}, state) do
      {:reconnect, state, {:protocol, detail}}
    end

    defp handle_event(:stream_ended, state) do
      {:reconnect, state, :stream_ended}
    end

    defp stream_reply({:ok, state}), do: {:noreply, state}
    defp stream_reply({:reconnect, state, reason}), do: reconnect(state, reason)
    defp stream_reply({:stop, state, reason}), do: down(state, reason)

    defp stream_terminal({:ok, state}, reason), do: down(state, reason)
    defp stream_terminal({:reconnect, state, reason}, _normal), do: reconnect(state, reason)
    defp stream_terminal({:stop, state, reason}, _normal), do: down(state, reason)

    defp socket_closed(state, reason) do
      state = %{state | socket: nil, transport: nil, gga_timer_ref: nil}

      if state.machine do
        state.machine
        |> NIF.ntrip_machine_finish()
        |> process_events(state)
        |> case do
          {:ok, next} -> reconnect(next, reason)
          other -> stream_reply(other)
        end
      else
        reconnect(state, reason)
      end
    end

    defp reconnect(state, reason) do
      max_reconnects = get_in(state.opts, [:reconnect, :max_reconnects])

      if max_reconnects not in [nil, :infinity] and state.attempt >= max_reconnects do
        down(state, reason)
      else
        attempt = state.attempt + 1
        deliver(state, {:reconnecting, reason, attempt})
        backoff = backoff_ms(state.opts, attempt)
        if state.machine, do: NIF.ntrip_machine_reset(state.machine)
        close_state_socket(state)
        Process.send_after(self(), :connect_after_backoff, backoff)
        {:noreply, %{state | attempt: attempt, socket: nil, transport: nil, gga_timer_ref: nil}}
      end
    end

    defp stall_check(%{socket: nil} = state), do: {:noreply, state}

    defp stall_check(state) do
      timeout = NTRIP.seconds_to_ms(Keyword.get(state.opts, :stall_timeout_s, @default_stall_timeout_s))
      elapsed = System.monotonic_time(:millisecond) - state.last_rx

      if elapsed >= timeout do
        reconnect(state, {:stream_stalled, elapsed / 1000.0})
      else
        schedule_stall(state.opts)
        {:noreply, state}
      end
    end

    defp schedule_stall(opts) do
      timeout = NTRIP.seconds_to_ms(Keyword.get(opts, :stall_timeout_s, @default_stall_timeout_s))
      Process.send_after(self(), :stall_check, min(1_000, timeout))
      :ok
    end

    defp backoff_ms(opts, attempt) do
      policy = Keyword.get(opts, :reconnect, %{})
      initial = Map.get(policy, :initial_s, 1.0)
      factor = Map.get(policy, :factor, 2.0)
      cap = Map.get(policy, :cap_s, 60.0)
      min(cap, initial * :math.pow(factor, attempt - 1)) |> NTRIP.seconds_to_ms()
    end

    defp send_gga(%{machine: nil} = state), do: {:ok, state}
    defp send_gga(%{socket: nil} = state), do: {:ok, state}

    defp send_gga(state) do
      with {:ok, position} <- gga_position(state.opts),
           {:ok, sentence} <-
             NIF.ntrip_machine_gga(
               state.machine,
               monotonic_seconds(),
               Map.from_struct(position),
               utc_seconds_of_day()
             ) do
        case sentence do
          nil ->
            {:ok, state}

          bytes ->
            case NTRIP.send_bytes(state.transport, state.socket, bytes) do
              :ok -> {:ok, state}
              {:error, reason} -> {:reconnect, state, {:network, reason}}
            end
        end
      else
        :none -> {:ok, state}
        {:error, reason} -> {:stop, state, {:protocol, reason}}
      end
    end

    defp schedule_gga(state) do
      case gga_interval_s(state.opts) do
        nil ->
          %{state | gga_timer_ref: nil}

        interval ->
          ref = make_ref()
          Process.send_after(self(), {:gga_tick, ref}, NTRIP.seconds_to_ms(interval))
          %{state | gga_timer_ref: ref}
      end
    end

    defp gga_interval_s(opts) do
      case Keyword.get(opts, :gga) do
        %{interval_s: interval} -> interval / 1.0
        %{} -> 10.0
        _ -> nil
      end
    end

    defp gga_position(opts) do
      case Keyword.get(opts, :gga) do
        %{position: fun} when is_function(fun, 0) -> normalize_gga_position(fun.())
        %{position: %NTRIP.GgaPosition{} = position} -> {:ok, position}
        %{position: position} when is_map(position) -> {:ok, struct!(NTRIP.GgaPosition, position)}
        %{} -> {:error, :missing_gga_position}
        _ -> :none
      end
    rescue
      e in ArgumentError -> {:error, Exception.message(e)}
    end

    defp normalize_gga_position(%NTRIP.GgaPosition{} = position), do: {:ok, position}
    defp normalize_gga_position(position) when is_map(position), do: {:ok, struct!(NTRIP.GgaPosition, position)}
    defp normalize_gga_position(position), do: {:error, {:bad_gga_position, position}}

    defp monotonic_seconds, do: System.monotonic_time(:microsecond) / 1_000_000.0

    defp utc_seconds_of_day do
      now = DateTime.utc_now()
      {microsecond, _precision} = now.microsecond
      now.hour * 3600.0 + now.minute * 60.0 + now.second + microsecond / 1_000_000.0
    end

    defp payload_sink_mode(state) do
      case Keyword.get(state.opts, :sink_mode) do
        nil ->
          case state.sink do
            {:store, _store, _week_fun} -> :store
            _ -> :payload
          end

        mode ->
          mode
      end
    end

    defp ingest_store_payload(state, bytes) do
      state.assembler
      |> NIF.rtcm_assembler_push(bytes)
      |> Enum.reduce_while(:ok, fn
        {:ok, message}, :ok ->
          case ingest_store_message(state, message) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        {:error, _reason}, :ok ->
          {:cont, :ok}
      end)
    end

    defp ingest_store_message(state, message) do
      with {:ok, store, week_fun} <- store_sink(state),
           {:ok, {week, tow_s}} <- store_epoch(week_fun) do
        SSR.ingest(store, message, week, tow_s)
      end
    end

    defp store_sink(%{sink: {:store, %SSR{} = store, week_fun}}), do: {:ok, store, week_fun}

    defp store_sink(state) do
      case {Keyword.get(state.opts, :store), Keyword.get(state.opts, :week_fun)} do
        {%SSR{} = store, week_fun} when not is_nil(week_fun) -> {:ok, store, week_fun}
        _ -> {:error, :missing_store_sink}
      end
    end

    defp store_epoch(fun) when is_function(fun, 0), do: store_epoch(fun.())
    defp store_epoch({week, tow_s}) when is_integer(week) and is_number(tow_s), do: {:ok, {week, tow_s}}
    defp store_epoch(other), do: {:error, {:bad_store_epoch, other}}

    defp close_state_socket(%{socket: nil}), do: :ok
    defp close_state_socket(%{transport: nil}), do: :ok
    defp close_state_socket(%{transport: transport, socket: socket}), do: close_socket(transport, socket)

    defp close_socket(:ssl, socket), do: :ssl.close(socket)
    defp close_socket(:gen_tcp, socket), do: :gen_tcp.close(socket)

    defp deliver(%{sink: nil}, _message), do: :ok
    defp deliver(%{sink: pid, ref: ref}, message) when is_pid(pid), do: send(pid, {:ntrip, ref, message})
    defp deliver(_state, _message), do: :ok

    defp down(state, reason) do
      deliver(state, {:down, reason})
      close_state_socket(state)
      {:stop, :normal, %{state | socket: nil, transport: nil, gga_timer_ref: nil}}
    end
  end
end
