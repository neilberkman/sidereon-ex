defmodule Sidereon.SchedulerProbe do
  @moduledoc """
  Peer-side helper for the archive-listing scheduler-safety test.

  This lives in `test/support` rather than in the test file because ExUnit
  compiles test modules in memory: a peer node has no copy of them and cannot
  run a closure defined there. `test/support` is compiled to disk for the test
  environment, so the peer picks this module up from the shared code path.
  """

  alias Sidereon.GNSS.Data

  @doc """
  Build a `rows`-row AIUB-format CSV body.

  Generated on the node that will parse it, so a multi-megabyte body is never
  shipped across the distribution link.
  """
  @spec listing_body(pos_integer()) :: binary()
  def listing_body(rows) do
    Enum.map_join(1..rows, "\n", fn i ->
      "CODE/2026/COD0OPSFIN_2026#{rem(i, 365)}0000_01D_05M_ORB_#{i}.SP3;123456;2026-01-01 00:00:00;x"
    end)
  end

  @doc """
  Parse a generated `rows`-row listing while a heartbeat counts how often it
  is scheduled, and return `{heartbeat_ticks, parse_ms}`.

  The heartbeat is the observation; the parse is the disturbance. A parse that
  occupies the single normal scheduler leaves the heartbeat unable to run for
  the whole parse, so its tick count stays near zero no matter how long the
  parse takes. A dirty-CPU parse leaves the heartbeat running at its cadence
  throughout, so ticks scale with parse duration.

  Ticks are counted on the heartbeat's own timeline and the parse is timed on
  the caller's, so the two are compared directly rather than inferred from a
  gap the starved heartbeat could never record.
  """
  @spec heartbeat_ticks_during_parse(pos_integer(), pos_integer()) ::
          {non_neg_integer(), float()}
  def heartbeat_ticks_during_parse(rows, heartbeat_ms) do
    body = listing_body(rows)
    parent = self()
    heartbeat = spawn(fn -> loop(0, heartbeat_ms) end)

    started = System.monotonic_time()
    {:ok, _objects} = Data.parse_archive_listing(body)
    parse_ms = System.convert_time_unit(System.monotonic_time() - started, :native, :microsecond) / 1000.0

    send(heartbeat, {:stop, parent})

    receive do
      {:ticks, n} -> {n, parse_ms}
    after
      5_000 -> {0, parse_ms}
    end
  end

  defp loop(n, heartbeat_ms) do
    receive do
      {:stop, from} -> send(from, {:ticks, n})
    after
      heartbeat_ms -> loop(n + 1, heartbeat_ms)
    end
  end
end
