defmodule Sidereon.GNSS.ExactCacheSingleFlightTest do
  use ExUnit.Case, async: false

  alias Sidereon.GNSS.Data
  alias Sidereon.GNSS.Distribution
  alias Sidereon.GNSS.ExactCache

  @date ~D[2026-07-12]

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "sidereon-exact-cache-single-flight-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(root)
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, product} = Data.mgex_sp3(:cod, @date)
    {:ok, request} = Data.request(product, [Distribution.in_memory(<<>>, compression: :none)])
    stable = Path.join(root, request.identity.official_filename)

    {:ok, stable: stable, identity: request.identity}
  end

  test "a committed entry opens as a hit without running acquisition", %{
    stable: stable,
    identity: identity
  } do
    assert {:ok, committed} =
             ExactCache.with_lock(stable, identity, :in_memory, 1_000, fn cache ->
               ExactCache.publish(cache, "product", "archive", "provenance")
             end)

    fetch = fn _owner ->
      send(self(), :fetch_invoked)
      flunk("a cache hit must not acquire the product")
    end

    opened =
      case ExactCache.open_single_flight(stable, identity, :in_memory) do
        {:owner, owner} -> fetch.(owner)
        hit -> hit
      end

    assert {:hit, hit} = opened
    assert hit == committed
    refute_received :fetch_invoked
  end

  test "an owner publishes once and the next open is a hit", %{
    stable: stable,
    identity: identity
  } do
    assert {:owner, owner} = ExactCache.open_single_flight(stable, identity, :in_memory)
    assert :ok = ExactCache.heartbeat(owner)

    assert {:ok, published} =
             ExactCache.publish(owner, "validated product", "source archive", "provenance json")

    assert {:hit, hit} = ExactCache.open_single_flight(stable, identity, :in_memory)
    assert hit == published
    assert hit.product_bytes == "validated product"
    assert hit.archive_bytes == "source archive"
    assert hit.provenance_bytes == "provenance json"
  end

  test "a paused live owner maps bounded waiting to the typed timeout", %{
    stable: stable,
    identity: identity
  } do
    options = [
      poll_interval_ms: 1,
      heartbeat_interval_ms: 10,
      liveness_timeout_ms: 200,
      wait_timeout_ms: 25
    ]

    assert {:owner, owner} = ExactCache.open_single_flight(stable, identity, :in_memory, options)

    assert {:error, :single_flight_timeout} =
             ExactCache.open_single_flight(stable, identity, :in_memory, options)

    assert :ok = ExactCache.abandon(owner)
  end

  test "invalid duration options return typed errors", %{stable: stable, identity: identity} do
    invalid_options = [
      {[poll_interval_ms: 0], :poll_interval_ms},
      {[heartbeat_interval_ms: "five seconds"], :heartbeat_interval_ms},
      {[liveness_timeout_ms: -1], :liveness_timeout_ms},
      {[wait_timeout_ms: :infinity], :wait_timeout_ms},
      {[poll_interval_ms: 18_446_744_073_709_551_616], :poll_interval_ms},
      {[heartbeat_interval_ms: 10, liveness_timeout_ms: 10], :heartbeat_interval_ms},
      {[unexpected_ms: 1], :unexpected_ms},
      {%{poll_interval_ms: 1}, :opts}
    ]

    Enum.each(invalid_options, fn {options, key} ->
      assert {:error, {:invalid_option, ^key}} =
               ExactCache.open_single_flight(stable, identity, :in_memory, options)
    end)
  end
end
