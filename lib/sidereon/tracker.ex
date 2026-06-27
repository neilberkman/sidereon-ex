defmodule Sidereon.Tracker do
  @moduledoc """
  Real-time satellite position tracker.

  A GenServer that continuously propagates a satellite's position and
  broadcasts updates to subscribers. Multiple trackers can run concurrently
  for different satellites.

  ## Examples

      # Start tracking ISS
      {:ok, [tle]} = Sidereon.CelesTrak.fetch_tle(25544)
      {:ok, tracker} = Sidereon.Tracker.start_link(tle, interval_ms: 1000)

      # Get current position
      state = Sidereon.Tracker.get_state(tracker)
      state.position  #=> {x, y, z} in km
      state.geodetic  #=> %{latitude: ..., longitude: ..., altitude_km: ...}

      # Subscribe to updates
      Sidereon.Tracker.subscribe(tracker)
      receive do
        {:sidereon_tracker, ^tracker, state} ->
          IO.puts("ISS at \#{state.geodetic.latitude}, \#{state.geodetic.longitude}")
      end

      # Stop tracking
      Sidereon.Tracker.stop(tracker)
  """

  use GenServer

  require Logger

  defstruct [
    :tle,
    :interval_ms,
    :timer_ref,
    :last_update,
    :position,
    :velocity,
    :geodetic,
    :error,
    :catalog_number,
    :pubsub,
    subscribers: MapSet.new(),
    monitors: %{}
  ]

  @type state :: %__MODULE__{
          tle: Sidereon.Elements.t(),
          interval_ms: pos_integer(),
          timer_ref: reference() | nil,
          last_update: DateTime.t() | nil,
          position: {float(), float(), float()} | nil,
          velocity: {float(), float(), float()} | nil,
          geodetic: map() | nil,
          error: term() | nil,
          catalog_number: String.t(),
          subscribers: MapSet.t()
        }

  # Client API

  @doc """
  Start tracking a satellite.

  ## Options

    * `:interval_ms` - update interval in milliseconds (default: 1000)
    * `:name` - optional registered name for the process
    * `:pubsub` - `{module, pubsub_name, topic}` to broadcast via
      Phoenix.PubSub (or any module implementing `broadcast/3`).
      Messages are sent as `{:sidereon_tracker, tracker_pid, state_map}`,
      the same shape as direct subscriber messages.

  ## Examples

      {:ok, tracker} = Sidereon.Tracker.start_link(tle)
      {:ok, tracker} = Sidereon.Tracker.start_link(tle, interval_ms: 5000)

      # With Phoenix PubSub
      {:ok, tracker} = Sidereon.Tracker.start_link(tle,
        pubsub: {Phoenix.PubSub, MyApp.PubSub, "satellite:25544"})
  """
  @spec start_link(Sidereon.Elements.t(), keyword()) :: GenServer.on_start()
  def start_link(tle, opts \\ []) do
    {gen_opts, tracker_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, {tle, tracker_opts}, gen_opts)
  end

  @doc """
  Get the current tracking state.

  Returns a map with position, velocity, geodetic coordinates, and timestamp.
  """
  @spec get_state(GenServer.server()) :: map()
  def get_state(tracker) do
    GenServer.call(tracker, :get_state)
  end

  @doc """
  Subscribe the calling process to position updates.

  Updates are sent as `{:sidereon_tracker, tracker_pid, state_map}`.
  """
  @spec subscribe(GenServer.server()) :: :ok
  def subscribe(tracker) do
    GenServer.call(tracker, {:subscribe, self()})
  end

  @doc """
  Unsubscribe the calling process from position updates.
  """
  @spec unsubscribe(GenServer.server()) :: :ok
  def unsubscribe(tracker) do
    GenServer.call(tracker, {:unsubscribe, self()})
  end

  @doc """
  Update the TLE for a tracked satellite (e.g., after fetching a newer one).
  """
  @spec update_tle(GenServer.server(), Sidereon.Elements.t()) :: :ok
  def update_tle(tracker, tle) do
    GenServer.cast(tracker, {:update_tle, tle})
  end

  @doc """
  Stop tracking.
  """
  @spec stop(GenServer.server()) :: :ok
  def stop(tracker) do
    GenServer.stop(tracker, :normal)
  end

  # Server callbacks

  @impl true
  def init({tle, opts}) do
    interval_ms = Keyword.get(opts, :interval_ms, 1000)
    pubsub = Keyword.get(opts, :pubsub)

    state = %__MODULE__{
      tle: tle,
      interval_ms: interval_ms,
      catalog_number: tle.catalog_number,
      pubsub: pubsub
    }

    # Propagate immediately, then schedule periodic updates
    state = propagate(state)
    timer_ref = Process.send_after(self(), :tick, interval_ms)

    {:ok, %{state | timer_ref: timer_ref}}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state_to_map(state), state}
  end

  def handle_call({:subscribe, pid}, _from, state) do
    if MapSet.member?(state.subscribers, pid) do
      {:reply, :ok, state}
    else
      ref = Process.monitor(pid)

      {:reply, :ok,
       %{
         state
         | subscribers: MapSet.put(state.subscribers, pid),
           monitors: Map.put(state.monitors, pid, ref)
       }}
    end
  end

  def handle_call({:unsubscribe, pid}, _from, state) do
    case Map.pop(state.monitors, pid) do
      {nil, monitors} ->
        {:reply, :ok,
         %{state | subscribers: MapSet.delete(state.subscribers, pid), monitors: monitors}}

      {ref, monitors} ->
        Process.demonitor(ref, [:flush])

        {:reply, :ok,
         %{state | subscribers: MapSet.delete(state.subscribers, pid), monitors: monitors}}
    end
  end

  @impl true
  def handle_cast({:update_tle, tle}, state) do
    {:noreply, %{state | tle: tle, catalog_number: tle.catalog_number}}
  end

  @impl true
  def handle_info(:tick, state) do
    state = propagate(state)
    broadcast(state)
    timer_ref = Process.send_after(self(), :tick, state.interval_ms)
    {:noreply, %{state | timer_ref: timer_ref}}
  end

  # Clean up dead subscribers and their monitors
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply,
     %{
       state
       | subscribers: MapSet.delete(state.subscribers, pid),
         monitors: Map.delete(state.monitors, pid)
     }}
  end

  # Private

  defp propagate(state) do
    now = DateTime.utc_now()

    case Sidereon.SGP4.propagate(state.tle, now) do
      {:ok, teme} ->
        {geo, error} =
          case geodetic_from_teme(teme, now) do
            {:ok, geo} ->
              {geo, nil}

            {:error, reason} ->
              Logger.warning(
                "Tracker #{state.catalog_number}: coordinate transform error: #{inspect(reason)}"
              )

              {nil, reason}
          end

        %{
          state
          | last_update: now,
            position: teme.position,
            velocity: teme.velocity,
            geodetic: geo,
            error: error
        }

      {:error, reason} ->
        error = {:propagation_error, reason}
        Logger.warning("Tracker #{state.catalog_number}: propagation error: #{inspect(reason)}")
        %{state | last_update: now, error: error}
    end
  end

  defp geodetic_from_teme(teme, now) do
    gcrs = Sidereon.Coordinates.teme_to_gcrs(teme, now)
    itrs = Sidereon.Coordinates.gcrs_to_itrs(gcrs, now)
    {:ok, Sidereon.Coordinates.to_geodetic(itrs)}
  rescue
    e -> {:error, {:transform_error, Exception.message(e)}}
  end

  defp broadcast(state) do
    payload = state_to_map(state)
    msg = {:sidereon_tracker, self(), payload}

    # Direct subscribers
    for pid <- state.subscribers do
      send(pid, msg)
    end

    # PubSub broadcast, matches Phoenix.PubSub.broadcast/3 convention:
    # Phoenix.PubSub.broadcast(pubsub_name, topic, message)
    case state.pubsub do
      {pubsub_module, pubsub_name, topic} ->
        pubsub_module.broadcast(pubsub_name, topic, msg)

      nil ->
        :ok
    end
  end

  defp state_to_map(state) do
    %{
      catalog_number: state.catalog_number,
      time: state.last_update,
      position: state.position,
      velocity: state.velocity,
      geodetic: state.geodetic,
      error: state.error
    }
  end
end
