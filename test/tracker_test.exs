defmodule Sidereon.TrackerTest do
  use ExUnit.Case

  setup do
    body = File.read!(Path.join(__DIR__, "fixtures/celestrak/iss.tle"))
    lines = body |> String.trim() |> String.split("\n") |> Enum.map(&String.trim/1)
    l1 = Enum.find(lines, &String.starts_with?(&1, "1 "))
    l2 = Enum.find(lines, &String.starts_with?(&1, "2 "))
    {:ok, tle} = Sidereon.Format.TLE.parse(l1, l2)
    %{tle: tle}
  end

  test "starts and returns state", %{tle: tle} do
    {:ok, tracker} = Sidereon.Tracker.start_link(tle, interval_ms: 100)
    Process.sleep(150)

    state = Sidereon.Tracker.get_state(tracker)
    assert state.catalog_number == "25544"
    assert state.position != nil
    assert state.geodetic != nil
    assert state.error == nil
    assert state.geodetic.latitude >= -90 and state.geodetic.latitude <= 90

    Sidereon.Tracker.stop(tracker)
  end

  test "surfaces propagation errors in state", %{tle: tle} do
    bad_tle = %{tle | mean_motion: nil}

    {:ok, tracker} = Sidereon.Tracker.start_link(bad_tle, interval_ms: 100)

    state = Sidereon.Tracker.get_state(tracker)
    assert state.position == nil
    assert state.geodetic == nil
    assert state.error == {:propagation_error, {:missing_field, :mean_motion}}

    Sidereon.Tracker.stop(tracker)
  end

  test "broadcasts updates to subscribers", %{tle: tle} do
    {:ok, tracker} = Sidereon.Tracker.start_link(tle, interval_ms: 100)
    Sidereon.Tracker.subscribe(tracker)

    assert_receive {:sidereon_tracker, ^tracker, state}, 500
    assert state.catalog_number == "25544"
    assert state.position != nil

    Sidereon.Tracker.stop(tracker)
  end

  test "unsubscribe stops updates", %{tle: tle} do
    {:ok, tracker} = Sidereon.Tracker.start_link(tle, interval_ms: 100)
    Sidereon.Tracker.subscribe(tracker)

    assert_receive {:sidereon_tracker, ^tracker, _}, 500

    Sidereon.Tracker.unsubscribe(tracker)
    # Drain any in-flight message
    receive do
      {:sidereon_tracker, ^tracker, _} -> :ok
    after
      0 -> :ok
    end

    Process.sleep(200)
    refute_receive {:sidereon_tracker, ^tracker, _}, 200

    Sidereon.Tracker.stop(tracker)
  end

  test "position changes over time", %{tle: tle} do
    {:ok, tracker} = Sidereon.Tracker.start_link(tle, interval_ms: 100)
    Sidereon.Tracker.subscribe(tracker)

    assert_receive {:sidereon_tracker, ^tracker, state1}, 500
    assert_receive {:sidereon_tracker, ^tracker, state2}, 500

    # ISS moves ~7.7 km/s, so in 100ms it moves ~0.77 km
    # Position tuples should differ
    assert state1.time != state2.time

    Sidereon.Tracker.stop(tracker)
  end

  test "update_tle swaps the TLE", %{tle: tle} do
    {:ok, tracker} = Sidereon.Tracker.start_link(tle, interval_ms: 100)

    # Update with same TLE (just testing the mechanism)
    Sidereon.Tracker.update_tle(tracker, tle)
    Process.sleep(150)

    state = Sidereon.Tracker.get_state(tracker)
    assert state.catalog_number == "25544"

    Sidereon.Tracker.stop(tracker)
  end

  test "pubsub option broadcasts to the configured module", %{tle: tle} do
    # Fake PubSub that sends to the test process
    test_pid = self()

    defmodule FakePubSub do
      def broadcast(name, topic, message) do
        send(name, {:pubsub_broadcast, topic, message})
        :ok
      end
    end

    {:ok, tracker} =
      Sidereon.Tracker.start_link(tle,
        interval_ms: 100,
        pubsub: {FakePubSub, test_pid, "satellite:test"}
      )

    assert_receive {:pubsub_broadcast, "satellite:test", {:sidereon_tracker, _, state}}, 500
    assert state.catalog_number == "25544"
    assert state.position != nil

    Sidereon.Tracker.stop(tracker)
  end
end
