defmodule Sidereon.ArchiveListingSchedulerTest do
  @moduledoc """
  Scheduler safety for `Sidereon.GNSS.Data.parse_archive_listing/1`.

  An archive-listing body is untrusted in size: AIUB's public whole-tree CSV is
  roughly 426k rows. A NIF that parses one on an ordinary scheduler occupies
  that scheduler until it returns and cannot be preempted, so unrelated
  processes stop running. That is a property of the scheduling annotation, not
  of how fast the parser happens to be, so it is proven structurally here
  rather than with a wall-clock bound.

  The check needs a VM with a single normal scheduler (`+S 1:1`); with the
  default scheduler count a blocked scheduler is invisible because the other
  schedulers keep running. A peer node supplies that.
  """
  use ExUnit.Case, async: false

  # Large enough that an ordinary-scheduler parse would visibly stall the
  # heartbeat, while staying quick to generate.
  alias Sidereon.GNSS.Data

  @rows 50_000
  @heartbeat_ms 1

  test "parsing a large listing does not starve a single normal scheduler" do
    # The peer talks over its standard I/O rather than Erlang distribution, so
    # neither this VM nor the peer needs a node name or a running epmd. That
    # keeps the test hermetic: CI runners have no epmd, and a test that only
    # passed where one happened to be running would be measuring the host.
    {:ok, peer, _node} =
      :peer.start_link(%{
        connection: :standard_io,
        args: [~c"+S", ~c"1:1"] ++ code_path_args()
      })

    # `start_link` ties the peer's lifetime to this process, so by the time
    # `on_exit` runs the peer is usually already gone.
    # `start_link` ties the peer's lifetime to this process, so by the time
    # `on_exit` runs the peer is usually already gone.
    on_exit(fn ->
      try do
        :peer.stop(peer)
      catch
        :exit, _ -> :ok
      end
    end)

    # Load the NIF on the peer before timing anything.
    {:ok, _} = :peer.call(peer, Data, :parse_archive_listing, ["a;1;;x"])

    {ticks, parse_ms} =
      :peer.call(
        peer,
        Sidereon.SchedulerProbe,
        :heartbeat_ticks_during_parse,
        [@rows, @heartbeat_ms],
        300_000
      )

    # A heartbeat with a 1 ms cadence should tick roughly once per millisecond
    # of parse. Require a quarter of that: generous next to scheduling jitter,
    # and far above the handful of ticks a starved heartbeat manages. With
    # DirtyCpu the parse runs off the normal scheduler and the heartbeat keeps
    # its cadence; on an ordinary scheduler it cannot run until the parse
    # returns, so its count stays near zero however long the parse takes.
    expected_floor = trunc(parse_ms / @heartbeat_ms / 4)

    assert ticks >= expected_floor,
           "heartbeat ticked #{ticks} times during a #{Float.round(parse_ms, 0)} ms parse " <>
             "(expected at least #{expected_floor}): the normal scheduler was starved, " <>
             "which means the listing NIF is not scheduled as dirty CPU work"
  end

  defp code_path_args do
    Enum.flat_map(:code.get_path(), fn dir -> [~c"-pa", dir] end)
  end
end
