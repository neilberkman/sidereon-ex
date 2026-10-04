defmodule Sidereon.GNSS.StaticPositioningNestedErrorTest do
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.SP3
  alias Sidereon.GNSS.StaticPositioning

  @degenerate_sp3 Path.join(__DIR__, "fixtures/sp3/degenerate_coincident_5sat.sp3")

  test "an epoch's singular SPP cause remains available in the static error" do
    sp3 = SP3.load!(@degenerate_sp3)
    observations = for prn <- 1..5, do: {"G0#{prn}", 20_181_863.0}
    epoch = ~N[2020-06-24 00:03:20]

    assert {:error, {:singular_geometry, :singular_jacobian}} =
             StaticPositioning.solve(sp3, [{observations, epoch}], initial_position: {6_378_137.0, 0.0, 0.0})
  end

  test "an epoch input refusal retains its SPP field and stable kind" do
    sp3 = SP3.load!(@degenerate_sp3)
    observations = [{"G01", 0.0}]
    epoch = ~N[2020-06-24 00:03:20]

    assert {:error, {:epoch_input, 0, {:invalid_input, "observation.pseudorange_m", "not_positive"}}} =
             StaticPositioning.solve(sp3, [{observations, epoch}])
  end
end
