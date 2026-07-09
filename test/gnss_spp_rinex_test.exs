defmodule Sidereon.GNSS.SPP.RinexTest do
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.Broadcast
  alias Sidereon.GNSS.Positioning.Solution
  alias Sidereon.GNSS.RINEX.Observations
  alias Sidereon.GNSS.SPP
  alias Sidereon.GNSS.SPP.{EpochInputs, EpochSolution}

  @obs_path Path.join(__DIR__, "fixtures/obs/ESBC00DNK_R_20201770000_01D_30S_MO_trim.rnx")
  @nav_path Path.join(__DIR__, "fixtures/nav/ESBC00DNK_R_20201770000_01D_MN.rnx")

  test "assembles and solves RINEX OBS epochs from broadcast NAV" do
    obs = Observations.load!(@obs_path)
    nav = Broadcast.load!(@nav_path)
    opts = [codes: %{"G" => ["C1C"]}, ionosphere: false, troposphere: true]

    assert {:ok, [%EpochInputs{} = first | _] = inputs} = SPP.spp_inputs_from_rinex_obs(nav, obs, opts)
    assert length(inputs) == length(Observations.epochs(obs))
    assert first.epoch_index == 0
    assert first.epoch == {{2020, 6, 25}, {0, 0, 0.0}}
    assert length(first.observations) >= 5
    assert Enum.all?(first.observations, fn {sat, range_m} -> String.starts_with?(sat, "G") and is_float(range_m) end)
    assert first.initial_guess == {3_582_105.291, 532_589.7313, 5_232_754.8054, 0.0}
    assert first.corrections == %{ionosphere: false, troposphere: true}

    assert {:ok, [%EpochSolution{} = solved | _] = solutions} = SPP.solve_spp_from_rinex_obs(nav, obs, opts)
    assert length(solutions) == length(inputs)
    assert solved.epoch_index == first.epoch_index
    assert solved.solved?
    assert {:ok, %Solution{} = solution} = solved.solution
    assert solution.geodetic != nil
    assert is_float(solution.position.x_m)
    assert is_float(solution.position.y_m)
    assert is_float(solution.position.z_m)
    assert solution.used_sats != []
  end
end
