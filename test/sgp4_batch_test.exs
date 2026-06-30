defmodule Sidereon.SGP4BatchTest do
  use ExUnit.Case, async: true

  alias Sidereon.Format.TLE
  alias Sidereon.SGP4

  @l1 "1 25544U 98067A   18184.80969102  .00001614  00000-0  31745-4 0  9993"
  @l2 "2 25544  51.6414 295.8524 0003435 262.6267 204.2868 15.54005638121106"

  setup do
    {:ok, elements} = TLE.parse(@l1, @l2)
    {:ok, elements: elements}
  end

  test "propagate_batch returns one arc per satellite, one state per time", %{elements: elements} do
    assert {:ok, [{:ok, arc}]} = SGP4.propagate_batch([elements], [0.0, 90.0])
    assert length(arc) == 2

    for %Sidereon.TemeState{position: {x, y, z}} <- arc do
      r = :math.sqrt(x * x + y * y + z * z)
      assert r > 6000.0 and r < 8000.0
    end
  end

  test "batch state at epoch matches a single propagate at the epoch", %{elements: elements} do
    {:ok, single} = SGP4.propagate(elements, elements.epoch)
    {:ok, [{:ok, [first | _]}]} = SGP4.propagate_batch([elements], [0.0])

    {sx, sy, sz} = single.position
    {bx, by, bz} = first.position
    assert_in_delta bx, sx, 1.0e-3
    assert_in_delta by, sy, 1.0e-3
    assert_in_delta bz, sz, 1.0e-3
  end

  test "parallel batch is bit-identical to the serial batch", %{elements: elements} do
    times = [0.0, 30.0, 60.0, 90.0]
    {:ok, serial} = SGP4.propagate_batch([elements, elements], times)
    {:ok, parallel} = SGP4.propagate_batch([elements, elements], times, parallel: true)
    assert serial == parallel
  end

  test "an empty satellite list yields an empty batch" do
    assert {:ok, []} = SGP4.propagate_batch([], [0.0, 1.0])
  end

  test "improved opsmode is accepted", %{elements: elements} do
    assert {:ok, [{:ok, arc}]} = SGP4.propagate_batch([elements], [0.0], opsmode: :improved)
    assert length(arc) == 1
  end
end
