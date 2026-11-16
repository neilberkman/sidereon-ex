defmodule Sidereon.GNSS.SPP.RinexTest do
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.Broadcast
  alias Sidereon.GNSS.Positioning.Solution
  alias Sidereon.GNSS.QC
  alias Sidereon.GNSS.RINEX.Observations
  alias Sidereon.GNSS.SBAS
  alias Sidereon.GNSS.SPP
  alias Sidereon.GNSS.SPP.{EpochInputs, EpochSolution}
  alias Sidereon.GNSS.Time.ExactEpoch

  @obs_path Path.join(__DIR__, "fixtures/obs/ESBC00DNK_R_20201770000_01D_30S_MO_trim.rnx")
  @nav_path Path.join(__DIR__, "fixtures/nav/ESBC00DNK_R_20201770000_01D_MN.rnx")

  test "assembles and solves RINEX OBS epochs from broadcast NAV" do
    obs = Observations.load!(@obs_path)
    nav = Broadcast.load!(@nav_path)

    opts = [
      codes: %{"G" => ["C1C"]},
      ionosphere: false,
      troposphere: true,
      qzss_clock: :separate,
      troposphere_model: :saastamoinen_niell
    ]

    assert {:ok, [%EpochInputs{} = first | _] = inputs} = SPP.spp_inputs_from_rinex_obs(nav, obs, opts)
    assert length(inputs) == length(Observations.epochs(obs))
    assert first.epoch_index == 0
    assert first.epoch == {{2020, 6, 25}, {0, 0, 0.0}}
    assert length(first.observations) >= 5
    assert Enum.all?(first.observations, fn {sat, range_m} -> String.starts_with?(sat, "G") and is_float(range_m) end)
    assert first.initial_guess == {3_582_105.291, 532_589.7313, 5_232_754.8054, 0.0}
    assert first.corrections == %{ionosphere: false, troposphere: true}
    assert first.qzss_clock == :separate
    assert first.troposphere_model == :saastamoinen_niell

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

  test "RINEX solve forwards the GDOP ceiling" do
    obs = Observations.load!(@obs_path)
    nav = Broadcast.load!(@nav_path)
    assert {:error, {:invalid_option, :max_gdop}} = SPP.solve_spp_from_rinex_obs(nav, obs, max_gdop: 0.0)

    assert {:ok, [%EpochSolution{solution: {:error, {:degenerate_geometry_gdop, gdop}}} | _]} =
             SPP.solve_spp_from_rinex_obs(nav, obs, codes: %{"G" => ["C1C"]}, max_gdop: 0.1)

    assert gdop > 0.1
  end

  test "both broadcast FDE paths forward the GDOP ceiling" do
    obs = Observations.load!(@obs_path)
    nav = Broadcast.load!(@nav_path)
    assert {:ok, [first | _]} = SPP.spp_inputs_from_rinex_obs(nav, obs, codes: %{"G" => ["C1C"]})
    opts = [initial_guess: first.initial_guess, ionosphere: false, troposphere: false, max_gdop: 0.1]

    for fun <- [&QC.fde/4, &QC.robust_fde/4] do
      assert {:error, {:degenerate_geometry_gdop, gdop}} = fun.(nav, first.observations, ~N[2020-06-25 00:00:00], opts)
      assert gdop > 0.1
    end
  end

  test "both SBAS broadcast solves forward the GDOP ceiling" do
    obs = Observations.load!(@obs_path)
    nav = Broadcast.load!(@nav_path)
    store = SBAS.new()
    assert {:ok, [first | _]} = SPP.spp_inputs_from_rinex_obs(nav, obs, codes: %{"G" => ["C1C"]})
    epoch = ~N[2020-06-25 00:00:00]
    assert {:ok, exact} = ExactEpoch.from_civil(2020, 6, 25, 0, 0, 0)
    opts = [initial_guess: first.initial_guess, ionosphere: false, troposphere: false, max_gdop: 0.1]

    assert {:error, {:degenerate_geometry_gdop, gdop}} =
             SBAS.solve_broadcast(nav, store, "S120", first.observations, epoch, opts)

    assert gdop > 0.1

    assert {:error, {:degenerate_geometry_gdop, gdop}} =
             SBAS.solve_broadcast_at_exact_epoch(nav, store, "S120", first.observations, epoch, exact, opts)

    assert gdop > 0.1
  end

  test "rejects unknown model selectors before calling the native assembler" do
    obs = Observations.load!(@obs_path)
    nav = Broadcast.load!(@nav_path)

    assert {:error, {:invalid_option, :qzss_clock}} =
             SPP.spp_inputs_from_rinex_obs(nav, obs, qzss_clock: :independent)

    assert {:error, {:invalid_option, :troposphere_model}} =
             SPP.solve_spp_from_rinex_obs(nav, obs, troposphere_model: :other)
  end
end
