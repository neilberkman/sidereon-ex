defmodule Sidereon.GNSS.PrecisePositioningTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Sidereon.Coordinates
  alias Sidereon.GNSS.Antex
  alias Sidereon.GNSS.IonosphereFree
  alias Sidereon.GNSS.Observables
  alias Sidereon.GNSS.PrecisePositioning
  alias Sidereon.GNSS.PrecisePositioning.FixedSolution
  alias Sidereon.GNSS.PrecisePositioning.Solution
  alias Sidereon.GNSS.SP3
  alias Sidereon.GNSS.Troposphere

  @sp3_path Path.join(__DIR__, "fixtures/sp3/GRG0MGXFIN_20201760000_01D_15M_ORB.SP3")
  @epoch ~N[2020-06-24 12:00:00]
  @epoch2 ~N[2020-06-24 12:15:00]
  @epoch3 ~N[2020-06-24 12:30:00]
  @epochs [@epoch, @epoch2, @epoch3]
  @truth {3_512_900.0, 780_500.0, 5_248_700.0}
  @clock_m 12.5
  @epoch_clocks_m [12.5, -8.25, 4.0]
  @met %{pressure_hpa: 1013.25, temperature_k: 288.15, relative_humidity: 0.5}
  @c 299_792_458.0
  @f_l1 1_575_420_000.0
  @f_l2 1_227_600_000.0
  @l1_wavelength_m @c / @f_l1
  @l2_wavelength_m @c / @f_l2
  @narrow_lane_wavelength_m @c / (@f_l1 + @f_l2)
  @residual_ztd_m 0.18

  setup_all do
    sp3 = SP3.load!(@sp3_path)

    sats =
      sp3
      |> SP3.satellite_ids()
      |> Enum.filter(&String.starts_with?(&1, "G"))
      |> Enum.flat_map(fn sat ->
        case Observables.predict(sp3, sat, @truth, @epoch) do
          {:ok, obs} when obs.elevation_deg > 10.0 -> [{sat, obs}]
          _ -> []
        end
      end)
      |> Enum.take(8)

    multi_sats =
      sp3
      |> SP3.satellite_ids()
      |> Enum.filter(&String.starts_with?(&1, "G"))
      |> Enum.flat_map(fn sat ->
        with [_ | _] = predictions <-
               Enum.map(@epochs, fn epoch ->
                 case Observables.predict(sp3, sat, @truth, epoch) do
                   {:ok, obs} when obs.elevation_deg > 10.0 -> {epoch, obs}
                   _ -> nil
                 end
               end),
             false <- Enum.any?(predictions, &is_nil/1) do
          [{sat, predictions}]
        else
          _ -> []
        end
      end)
      |> Enum.take(8)

    true = length(sats) >= 6
    true = length(multi_sats) >= 6

    {:ok,
     sp3: sp3,
     sats: sats,
     observations: synth_observations(sats),
     tropo_observations: synth_observations(sats, troposphere: true, epoch: @epoch),
     multi_sats: multi_sats,
     epoch_observations: synth_epoch_observations(multi_sats),
     tropo_epoch_observations: synth_epoch_observations(multi_sats, troposphere: true),
     ztd_epoch_observations:
       synth_epoch_observations(multi_sats,
         troposphere: true,
         residual_ztd_m: @residual_ztd_m
       ),
     fixed_epoch_observations: synth_fixed_epoch_observations(multi_sats),
     dual_frequency_epoch_observations: synth_dual_frequency_epoch_observations(multi_sats)}
  end

  describe "solve_float/4" do
    test "recovers position, receiver clock, and float ambiguities from exact code+phase", ctx do
      # Known-truth round trip: the observations are synthesized from the SP3 forward
      # model with hidden receiver position, clock, and per-satellite float
      # ambiguities. The estimator must recover those hidden values from a
      # separate initial guess; it is not checked against its own output.
      assert {:ok, %Solution{} = sol} =
               PrecisePositioning.solve_float(ctx.sp3, ctx.observations, @epoch,
                 initial_guess: {3_513_400.0, 780_100.0, 5_249_000.0, -20.0}
               )

      assert position_error(sol.position, @truth) < 1.0e-3
      assert abs(sol.rx_clock_m - @clock_m) < 1.0e-4
      assert abs(sol.rx_clock_s - @clock_m / @c) < 1.0e-13

      for {sat, expected} <- true_ambiguities(ctx.sats) do
        assert abs(sol.ambiguities_m[sat] - expected) < 1.0e-4
      end

      for {_sat, residual} <- sol.residuals_m do
        assert abs(residual.code_m) < 1.0e-4
        assert abs(residual.phase_m) < 1.0e-4
      end

      assert sol.used_sats == Enum.map(ctx.sats, &elem(&1, 0))
      assert sol.metadata.converged
      assert sol.metadata.status == :position_tolerance
      assert sol.metadata.code_rms_m < 1.0e-4
      assert sol.metadata.phase_rms_m < 1.0e-4
    end

    test "applies a-priori troposphere to code and phase", ctx do
      assert {:ok, %Solution{} = sol} =
               PrecisePositioning.solve_float(ctx.sp3, ctx.tropo_observations, @epoch,
                 initial_guess: {3_513_400.0, 780_100.0, 5_249_000.0, -20.0},
                 troposphere: true,
                 pressure_hpa: @met.pressure_hpa,
                 temperature_k: @met.temperature_k,
                 relative_humidity: @met.relative_humidity
               )

      assert position_error(sol.position, @truth) < 1.0e-3
      assert abs(sol.rx_clock_m - @clock_m) < 1.0e-4
      assert sol.metadata.troposphere_applied
      assert sol.metadata.code_rms_m < 1.0e-4
      assert sol.metadata.phase_rms_m < 1.0e-4

      assert {:ok, uncorrected} =
               PrecisePositioning.solve_float(ctx.sp3, ctx.tropo_observations, @epoch,
                 initial_guess: {3_513_400.0, 780_100.0, 5_249_000.0, -20.0}
               )

      refute uncorrected.metadata.troposphere_applied
      assert uncorrected.metadata.code_rms_m > sol.metadata.code_rms_m + 0.1
    end

    test "can seed itself from the code-only SPP solution", ctx do
      assert {:ok, %Solution{} = sol} =
               PrecisePositioning.solve_float(ctx.sp3, ctx.observations, @epoch,
                 spp_initial_guess: {3_513_400.0, 780_100.0, 5_249_000.0, 0.0}
               )

      assert position_error(sol.position, @truth) < 1.0e-3
      assert abs(sol.rx_clock_m - @clock_m) < 1.0e-4
    end

    test "a phase fault appears in the phase residuals, not the code residuals", ctx do
      [{bad_sat, _obs} | _] = ctx.sats

      faulted =
        Enum.map(ctx.observations, fn
          %{satellite_id: ^bad_sat} = obs -> %{obs | phase_m: obs.phase_m + 1.25}
          obs -> obs
        end)

      assert {:ok, %Solution{} = sol} =
               PrecisePositioning.solve_float(ctx.sp3, faulted, @epoch,
                 initial_guess: {3_513_400.0, 780_100.0, 5_249_000.0, -20.0}
               )

      assert abs(sol.residuals_m[bad_sat].code_m) < 1.0e-3

      # A float ambiguity per satellite absorbs a constant phase offset on a
      # one-epoch solve, so the residual stays small and the ambiguity records
      # the faulted offset.
      assert abs(sol.residuals_m[bad_sat].phase_m) < 1.0e-3

      assert abs(
               sol.ambiguities_m[bad_sat] -
                 (Map.fetch!(true_ambiguities(ctx.sats), bad_sat) + 1.25)
             ) < 1.0e-3
    end
  end

  describe "solve_float_epochs/3" do
    test "recovers static position, per-epoch clocks, and constant ambiguities", ctx do
      assert {:ok, sol} =
               PrecisePositioning.solve_float_epochs(ctx.sp3, ctx.epoch_observations,
                 initial_guess: {3_513_400.0, 780_100.0, 5_249_000.0, -20.0}
               )

      assert position_error(sol.position, @truth) < 1.0e-3
      assert sol.epochs == @epochs
      expected_sats = ctx.multi_sats |> Enum.map(&elem(&1, 0)) |> Enum.sort()
      assert sol.used_sats == expected_sats
      assert sol.metadata.n_epochs == 3
      assert sol.metadata.n_observations == 24
      assert sol.metadata.converged
      assert sol.metadata.status == :state_tolerance

      for {clock, expected} <- Enum.zip(sol.epoch_clocks, @epoch_clocks_m) do
        assert abs(clock.rx_clock_m - expected) < 1.0e-4
        assert abs(clock.rx_clock_s - expected / @c) < 1.0e-13
      end

      for {sat, expected} <- true_ambiguities(ctx.multi_sats) do
        assert abs(sol.ambiguities_m[sat] - expected) < 1.0e-4
      end

      for residual <- sol.residuals_m do
        assert abs(residual.code_m) < 1.0e-4
        assert abs(residual.phase_m) < 1.0e-4
      end
    end

    test "multi-epoch arcs apply a-priori troposphere consistently", ctx do
      assert {:ok, sol} =
               PrecisePositioning.solve_float_epochs(ctx.sp3, ctx.tropo_epoch_observations,
                 initial_guess: {3_513_400.0, 780_100.0, 5_249_000.0, -20.0},
                 troposphere: true,
                 pressure_hpa: @met.pressure_hpa,
                 temperature_k: @met.temperature_k,
                 relative_humidity: @met.relative_humidity
               )

      assert position_error(sol.position, @truth) < 1.0e-3
      assert sol.metadata.troposphere_applied
      assert sol.metadata.code_rms_m < 1.0e-4
      assert sol.metadata.phase_rms_m < 1.0e-4
    end

    test "multi-epoch arcs estimate a residual zenith troposphere delay", ctx do
      assert {:ok, sol} =
               PrecisePositioning.solve_float_epochs(ctx.sp3, ctx.ztd_epoch_observations,
                 initial_guess: {3_513_400.0, 780_100.0, 5_249_000.0, -20.0},
                 troposphere: true,
                 estimate_ztd: true,
                 pressure_hpa: @met.pressure_hpa,
                 temperature_k: @met.temperature_k,
                 relative_humidity: @met.relative_humidity
               )

      assert position_error(sol.position, @truth) < 1.0e-3
      assert abs(sol.ztd_residual_m - @residual_ztd_m) < 1.0e-4
      assert sol.metadata.troposphere_applied
      assert sol.metadata.ztd_estimated
      assert sol.metadata.code_rms_m < 1.0e-4
      assert sol.metadata.phase_rms_m < 1.0e-4
    end

    test "can seed a multi-epoch arc from code-only SPP solutions", ctx do
      assert {:ok, sol} =
               PrecisePositioning.solve_float_epochs(ctx.sp3, ctx.epoch_observations,
                 spp_initial_guess: {3_513_400.0, 780_100.0, 5_249_000.0, 0.0}
               )

      assert position_error(sol.position, @truth) < 1.0e-3
      assert abs(hd(Enum.map(sol.epoch_clocks, & &1.rx_clock_m)) - hd(@epoch_clocks_m)) < 1.0e-4
    end

    test "multi-epoch input errors are tagged", ctx do
      one = [hd(ctx.epoch_observations)]

      assert {:error, {:too_few_epochs, 1, 2}} =
               PrecisePositioning.solve_float_epochs(ctx.sp3, one)

      duplicated = [hd(ctx.epoch_observations), hd(ctx.epoch_observations)]

      assert {:error, {:duplicate_epoch, @epoch}} =
               PrecisePositioning.solve_float_epochs(ctx.sp3, duplicated)

      assert {:error, {:invalid_option, :ambiguity_tolerance_m}} =
               PrecisePositioning.solve_float_epochs(ctx.sp3, ctx.epoch_observations,
                 initial_guess: {3_513_400.0, 780_100.0, 5_249_000.0, -20.0},
                 ambiguity_tolerance_m: -1.0
               )

      assert {:error, {:invalid_option, :estimate_ztd}} =
               PrecisePositioning.solve_float_epochs(ctx.sp3, ctx.epoch_observations,
                 initial_guess: {3_513_400.0, 780_100.0, 5_249_000.0, -20.0},
                 estimate_ztd: true
               )

      assert {:error, {:invalid_option, :ztd_tolerance_m}} =
               PrecisePositioning.solve_float_epochs(ctx.sp3, ctx.epoch_observations,
                 initial_guess: {3_513_400.0, 780_100.0, 5_249_000.0, -20.0},
                 troposphere: true,
                 estimate_ztd: true,
                 ztd_tolerance_m: -1.0
               )
    end
  end

  describe "solve_fixed_epochs/3" do
    test "recovers position, clocks, and integer ambiguities from exact code+phase", ctx do
      assert {:ok, %FixedSolution{} = sol} =
               PrecisePositioning.solve_fixed_epochs(ctx.sp3, ctx.fixed_epoch_observations,
                 initial_guess: {3_513_400.0, 780_100.0, 5_249_000.0, -20.0},
                 ambiguity_wavelength_m: @l1_wavelength_m
               )

      assert position_error(sol.position, @truth) < 1.0e-3
      assert sol.epochs == @epochs
      assert sol.used_sats == ctx.multi_sats |> Enum.map(&elem(&1, 0)) |> Enum.sort()
      assert sol.metadata.integer_status == :fixed
      assert sol.metadata.integer_method == :lambda
      assert sol.metadata.integer_ratio > 1.0e6
      assert sol.metadata.integer_candidates == 2

      for {clock, expected} <- Enum.zip(sol.epoch_clocks, @epoch_clocks_m) do
        assert abs(clock.rx_clock_m - expected) < 1.0e-4
      end

      for {sat, cycles} <- true_fixed_cycles(ctx.multi_sats) do
        assert sol.fixed_ambiguities_cycles[sat] == cycles
        assert abs(sol.fixed_ambiguities_m[sat] - cycles * @l1_wavelength_m) < 1.0e-9
      end

      for residual <- sol.residuals_m do
        assert abs(residual.code_m) < 1.0e-4
        assert abs(residual.phase_m) < 1.0e-4
      end
    end

    test "exports ambiguity covariance for independent ILS scoring", ctx do
      assert {:ok, %FixedSolution{} = sol} =
               PrecisePositioning.solve_fixed_epochs(ctx.sp3, ctx.fixed_epoch_observations,
                 initial_guess: {3_513_400.0, 780_100.0, 5_249_000.0, -20.0},
                 ambiguity_wavelength_m: @l1_wavelength_m
               )

      search = sol.metadata.ambiguity_search
      assert search.order == sol.used_sats
      assert Map.keys(search.float_cycles) |> Enum.sort() == search.order
      assert square_matrix?(search.covariance_cycles, length(search.order))
      assert square_matrix?(search.covariance_inverse_cycles, length(search.order))

      [{best_score, best_cycles}, {second_score, _second_cycles} | _] =
        brute_force_ils(search, 1)

      assert best_cycles == sol.fixed_ambiguities_cycles

      assert_in_delta best_score,
                      sol.metadata.integer_best_score,
                      abs(best_score) * 1.0e-6 + 1.0e-12

      assert_in_delta second_score,
                      sol.metadata.integer_second_best_score,
                      abs(second_score) * 1.0e-6 + 1.0e-12
    end

    test "bounded ILS gate catches non-rounding low-ratio candidates", ctx do
      [sat_a, sat_b | _] = ctx.multi_sats |> Enum.map(&elem(&1, 0)) |> Enum.sort()

      biased =
        bias_fixed_epoch_phases(ctx.fixed_epoch_observations, %{
          sat_a => 0.47,
          sat_b => -0.47
        })

      assert {:ok, %FixedSolution{} = sol} =
               PrecisePositioning.solve_fixed_epochs(ctx.sp3, biased,
                 initial_guess: {3_513_400.0, 780_100.0, 5_249_000.0, -20.0},
                 ambiguity_wavelength_m: @l1_wavelength_m
               )

      search = sol.metadata.ambiguity_search
      rounded = coordinate_rounded_cycles(search)
      [{best_score, best_cycles}, {second_score, _second_cycles} | _] = brute_force_ils(search, 1)

      assert sol.metadata.integer_status == :not_fixed
      assert best_cycles == sol.fixed_ambiguities_cycles
      assert best_cycles != rounded

      assert_in_delta best_score,
                      sol.metadata.integer_best_score,
                      abs(best_score) * 1.0e-6 + 1.0e-12

      assert_in_delta second_score,
                      sol.metadata.integer_second_best_score,
                      abs(second_score) * 1.0e-6 + 1.0e-12
    end

    test "fixed-ambiguity arcs apply a-priori troposphere consistently", ctx do
      fixed_tropo = synth_fixed_epoch_observations(ctx.multi_sats, troposphere: true)

      assert {:ok, %FixedSolution{} = sol} =
               PrecisePositioning.solve_fixed_epochs(ctx.sp3, fixed_tropo,
                 initial_guess: {3_513_400.0, 780_100.0, 5_249_000.0, -20.0},
                 ambiguity_wavelength_m: @l1_wavelength_m,
                 troposphere: true,
                 pressure_hpa: @met.pressure_hpa,
                 temperature_k: @met.temperature_k,
                 relative_humidity: @met.relative_humidity
               )

      assert position_error(sol.position, @truth) < 1.0e-3
      assert sol.metadata.troposphere_applied
      assert sol.metadata.integer_status == :fixed
      assert sol.metadata.code_rms_m < 1.0e-4
      assert sol.metadata.phase_rms_m < 1.0e-4
    end

    test "fixed-ambiguity arcs can down-weight low elevations", ctx do
      assert {:ok, %FixedSolution{} = sol} =
               PrecisePositioning.solve_fixed_epochs(ctx.sp3, ctx.fixed_epoch_observations,
                 initial_guess: {3_513_400.0, 780_100.0, 5_249_000.0, -20.0},
                 ambiguity_wavelength_m: @l1_wavelength_m,
                 elevation_weighting: true
               )

      assert position_error(sol.position, @truth) < 1.0e-3
      assert sol.metadata.integer_status == :fixed
      assert sol.metadata.code_rms_m < 1.0e-4
      assert sol.metadata.phase_rms_m < 1.0e-4

      code_weights = Enum.map(sol.residuals_m, & &1.code_weight)
      phase_weights = Enum.map(sol.residuals_m, & &1.phase_weight)

      assert Enum.all?(code_weights, &(&1 > 0.0 and &1 <= 1.0))
      assert Enum.any?(code_weights, &(&1 < 0.95))
      assert Enum.all?(phase_weights, &(&1 > 0.0 and &1 <= 100.0))
    end

    test "fixed-ambiguity arcs estimate a residual zenith troposphere delay", ctx do
      fixed_tropo =
        synth_fixed_epoch_observations(ctx.multi_sats,
          troposphere: true,
          residual_ztd_m: @residual_ztd_m
        )

      assert {:ok, %FixedSolution{} = sol} =
               PrecisePositioning.solve_fixed_epochs(ctx.sp3, fixed_tropo,
                 initial_guess: {3_513_400.0, 780_100.0, 5_249_000.0, -20.0},
                 ambiguity_wavelength_m: @l1_wavelength_m,
                 troposphere: true,
                 estimate_ztd: true,
                 pressure_hpa: @met.pressure_hpa,
                 temperature_k: @met.temperature_k,
                 relative_humidity: @met.relative_humidity
               )

      assert position_error(sol.position, @truth) < 1.0e-3
      assert abs(sol.ztd_residual_m - @residual_ztd_m) < 1.0e-4
      assert sol.metadata.troposphere_applied
      assert sol.metadata.ztd_estimated
      assert sol.metadata.integer_status == :fixed
      assert sol.metadata.code_rms_m < 1.0e-4
      assert sol.metadata.phase_rms_m < 1.0e-4
    end

    test "fixed-ambiguity input errors are tagged", ctx do
      assert {:error, :ambiguity_wavelength_required} =
               PrecisePositioning.solve_fixed_epochs(ctx.sp3, ctx.fixed_epoch_observations,
                 initial_guess: {3_513_400.0, 780_100.0, 5_249_000.0, -20.0}
               )

      assert {:error, {:invalid_option, :integer_search_radius_cycles}} =
               PrecisePositioning.solve_fixed_epochs(ctx.sp3, ctx.fixed_epoch_observations,
                 initial_guess: {3_513_400.0, 780_100.0, 5_249_000.0, -20.0},
                 ambiguity_wavelength_m: @l1_wavelength_m,
                 integer_search_radius_cycles: -1
               )

      assert {:error, {:invalid_option, :elevation_weighting}} =
               PrecisePositioning.solve_fixed_epochs(ctx.sp3, ctx.fixed_epoch_observations,
                 initial_guess: {3_513_400.0, 780_100.0, 5_249_000.0, -20.0},
                 ambiguity_wavelength_m: @l1_wavelength_m,
                 elevation_weighting: :yes
               )

      # RTKLIB rejects thresar[0] < 1.0; a sub-1.0 ratio threshold is invalid.
      assert {:error, {:invalid_option, :integer_ratio_threshold}} =
               PrecisePositioning.solve_fixed_epochs(ctx.sp3, ctx.fixed_epoch_observations,
                 initial_guess: {3_513_400.0, 780_100.0, 5_249_000.0, -20.0},
                 ambiguity_wavelength_m: @l1_wavelength_m,
                 integer_ratio_threshold: 0.5
               )
    end
  end

  describe "solve_widelane_fixed_epochs/3" do
    test "fixes wide-lane then narrow-lane integers from raw dual-frequency observations", ctx do
      assert {:ok, %FixedSolution{} = sol} =
               PrecisePositioning.solve_widelane_fixed_epochs(
                 ctx.sp3,
                 ctx.dual_frequency_epoch_observations,
                 initial_guess: {3_513_400.0, 780_100.0, 5_249_000.0, -20.0},
                 min_arc_gap_s: 1_000.0,
                 wide_lane_tolerance_cycles: 0.01
               )

      assert position_error(sol.position, @truth) < 1.0e-3
      assert sol.metadata.integer_status == :fixed
      assert sol.metadata.integer_method == :widelane_narrowlane_lambda
      assert sol.metadata.wide_lane_fixed
      assert sol.metadata.integer_ratio > 1.0e6

      for {sat, n1} <- true_fixed_cycles(ctx.multi_sats) do
        nw = true_wide_lane_cycles(ctx.multi_sats)[sat]
        assert sol.wide_lane_ambiguities_cycles[sat] == nw
        assert sol.fixed_ambiguities_cycles[sat] == n1

        expected_if_ambiguity_m = narrow_lane_offset_m(nw) + n1 * @narrow_lane_wavelength_m
        assert abs(sol.fixed_ambiguities_m[sat] - expected_if_ambiguity_m) < 1.0e-9
      end

      for residual <- sol.residuals_m do
        assert abs(residual.code_m) < 1.0e-4
        assert abs(residual.phase_m) < 1.0e-4
      end
    end

    test "rejects a wide-lane average that is not close to an integer", ctx do
      [{bad_sat, _predictions} | _] = ctx.multi_sats

      biased =
        Enum.map(ctx.dual_frequency_epoch_observations, fn epoch_row ->
          observations =
            Enum.map(epoch_row.observations, fn
              %{satellite_id: ^bad_sat} = obs -> %{obs | p1_m: obs.p1_m + 1.0}
              obs -> obs
            end)

          %{epoch_row | observations: observations}
        end)

      assert {:error, {:wide_lane_not_integer, ^bad_sat, _mean, _fixed}} =
               PrecisePositioning.solve_widelane_fixed_epochs(ctx.sp3, biased,
                 initial_guess: {3_513_400.0, 780_100.0, 5_249_000.0, -20.0},
                 min_arc_gap_s: 1_000.0,
                 wide_lane_tolerance_cycles: 0.01
               )
    end

    test "rejects a malformed wide-lane frequency pair with a tagged error", ctx do
      [{bad_sat, _predictions} | _] = ctx.multi_sats

      malformed =
        Enum.map(ctx.dual_frequency_epoch_observations, fn epoch_row ->
          observations =
            Enum.map(epoch_row.observations, fn
              %{satellite_id: ^bad_sat} = obs -> %{obs | f2_hz: obs.f1_hz}
              obs -> obs
            end)

          %{epoch_row | observations: observations}
        end)

      assert {:error, {:wide_lane_failed, ^bad_sat, :equal_frequencies}} =
               PrecisePositioning.solve_widelane_fixed_epochs(ctx.sp3, malformed,
                 initial_guess: {3_513_400.0, 780_100.0, 5_249_000.0, -20.0},
                 min_arc_gap_s: 1_000.0,
                 gf_threshold_m: 1.0e12
               )
    end

    test "rejects a detected cycle slip before fixing integers", ctx do
      [{bad_sat, _predictions} | _] = ctx.multi_sats
      slip_epoch = @epoch2

      slipped =
        slip_dual_frequency_after(ctx.dual_frequency_epoch_observations, bad_sat, slip_epoch, 8.0)

      assert {:error, {:cycle_slip_detected, ^bad_sat, ^slip_epoch, reasons}} =
               PrecisePositioning.solve_widelane_fixed_epochs(ctx.sp3, slipped,
                 initial_guess: {3_513_400.0, 780_100.0, 5_249_000.0, -20.0},
                 min_arc_gap_s: 1_000.0
               )

      assert :geometry_free in reasons or :melbourne_wubbena in reasons
    end

    test "can drop a slipped satellite arc before fixing integers", ctx do
      [{bad_sat, _predictions} | _] = ctx.multi_sats
      slip_epoch = @epoch2

      slipped =
        slip_dual_frequency_after(ctx.dual_frequency_epoch_observations, bad_sat, slip_epoch, 8.0)

      assert {:ok, %FixedSolution{} = sol} =
               PrecisePositioning.solve_widelane_fixed_epochs(ctx.sp3, slipped,
                 initial_guess: {3_513_400.0, 780_100.0, 5_249_000.0, -20.0},
                 min_arc_gap_s: 1_000.0,
                 on_cycle_slip: :drop_satellite,
                 wide_lane_tolerance_cycles: 0.01
               )

      assert position_error(sol.position, @truth) < 1.0e-3
      refute bad_sat in sol.used_sats
      refute Map.has_key?(sol.wide_lane_ambiguities_cycles, bad_sat)
      refute Map.has_key?(sol.fixed_ambiguities_cycles, bad_sat)
      assert sol.metadata.dropped_cycle_slip_sats == [bad_sat]
      assert sol.metadata.integer_status == :fixed
    end

    test "can split a slipped satellite into a fresh ambiguity arc", ctx do
      [{bad_sat, _predictions} | _] = ctx.multi_sats
      slip_epoch = @epoch2

      slipped =
        slip_dual_frequency_after(ctx.dual_frequency_epoch_observations, bad_sat, slip_epoch, 8.0)

      split_arc = "#{bad_sat}#2"

      assert {:ok, %FixedSolution{} = sol} =
               PrecisePositioning.solve_widelane_fixed_epochs(ctx.sp3, slipped,
                 initial_guess: {3_513_400.0, 780_100.0, 5_249_000.0, -20.0},
                 min_arc_gap_s: 1_000.0,
                 on_cycle_slip: :split_arc,
                 wide_lane_tolerance_cycles: 0.01
               )

      assert position_error(sol.position, @truth) < 1.0e-3
      assert split_arc in sol.used_sats
      refute bad_sat in sol.used_sats

      assert sol.wide_lane_ambiguities_cycles[split_arc] ==
               true_wide_lane_cycles(ctx.multi_sats)[bad_sat] + 8

      assert sol.fixed_ambiguities_cycles[split_arc] ==
               true_fixed_cycles(ctx.multi_sats)[bad_sat] + 8

      assert sol.metadata.dropped_cycle_slip_sats == []

      assert [
               %{
                 satellite_id: ^bad_sat,
                 ambiguity_id: ^split_arc,
                 start_epoch: ^slip_epoch,
                 end_epoch: @epoch3,
                 n_epochs: 2
               }
             ] = sol.metadata.split_cycle_slip_arcs

      assert sol.metadata.integer_status == :fixed
    end

    test "rejects an unknown cycle-slip policy", ctx do
      assert {:error, {:invalid_option, :on_cycle_slip}} =
               PrecisePositioning.solve_widelane_fixed_epochs(
                 ctx.sp3,
                 ctx.dual_frequency_epoch_observations,
                 initial_guess: {3_513_400.0, 780_100.0, 5_249_000.0, -20.0},
                 min_arc_gap_s: 1_000.0,
                 on_cycle_slip: :bogus
               )
    end
  end

  describe "solve_float_epochs/3 cycle-slip arc-splitting (INCR 0)" do
    test "starts a fresh float ambiguity arc after a detected slip", ctx do
      [{bad_sat, _predictions} | _] = ctx.multi_sats
      slip_epoch = @epoch2
      split_arc = "#{bad_sat}#2"

      # Iono-free rows carrying the raw dual-frequency observation, with an LLI
      # loss-of-lock bit set on the slipped satellite from the slip epoch on.
      slipped =
        iono_free_with_lli_slip(ctx.dual_frequency_epoch_observations, bad_sat, slip_epoch)

      base = [initial_guess: {3_513_400.0, 780_100.0, 5_249_000.0, -20.0}, min_arc_gap_s: 1_000.0]

      # Without slip handling the single-per-sat ambiguity cannot absorb the
      # mid-arc jump; with :split_arc the slipped satellite gets a fresh arc id.
      {:ok, off} = PrecisePositioning.solve_float_epochs(ctx.sp3, slipped, base)
      refute split_arc in off.used_sats

      assert {:ok, split} =
               PrecisePositioning.solve_float_epochs(
                 ctx.sp3,
                 slipped,
                 Keyword.put(base, :cycle_slip, :split_arc)
               )

      # The slipped satellite is split into a pre-slip arc ("G07#1") and a
      # post-slip arc ("G07#2"); the bare physical id no longer carries a single
      # whole-arc ambiguity.
      assert "#{bad_sat}#1" in split.used_sats
      assert split_arc in split.used_sats
      refute bad_sat in split.used_sats
      assert position_error(split.position, @truth) < position_error(off.position, @truth)
    end

    test "is a no-op on a slip-free arc (default :off)", ctx do
      with_raw = iono_free_with_lli_slip(ctx.dual_frequency_epoch_observations, nil, nil)
      base = [initial_guess: {3_513_400.0, 780_100.0, 5_249_000.0, -20.0}, min_arc_gap_s: 1_000.0]

      {:ok, plain} = PrecisePositioning.solve_float_epochs(ctx.sp3, with_raw, base)

      {:ok, split} =
        PrecisePositioning.solve_float_epochs(
          ctx.sp3,
          with_raw,
          Keyword.put(base, :cycle_slip, :split_arc)
        )

      # No slips -> no new arc ids -> byte-identical satellite set and position.
      assert split.used_sats == plain.used_sats
      assert position_error(split.position, position_tuple(plain.position)) < 1.0e-9
    end

    test "rejects an unknown cycle_slip option", ctx do
      assert {:error, {:invalid_option, :cycle_slip}} =
               PrecisePositioning.solve_float_epochs(ctx.sp3, ctx.epoch_observations,
                 initial_guess: {3_513_400.0, 780_100.0, 5_249_000.0, -20.0},
                 cycle_slip: :bogus
               )
    end
  end

  describe "solve_float_epochs/3 precise satellite clock (RINEX 30s)" do
    test "rejects a non-clock satellite_clock option", ctx do
      assert {:error, {:invalid_option, :satellite_clock}} =
               PrecisePositioning.solve_float_epochs(ctx.sp3, ctx.epoch_observations,
                 initial_guess: {3_513_400.0, 780_100.0, 5_249_000.0, -20.0},
                 satellite_clock: :not_a_clock
               )
    end
  end

  describe "solve_float/4 errors" do
    test "empty and too-few observation sets are tagged", ctx do
      assert {:error, :no_observations} = PrecisePositioning.solve_float(ctx.sp3, [], @epoch)

      few = Enum.take(ctx.observations, 3)

      assert {:error, {:too_few_satellites, 3, 4}} =
               PrecisePositioning.solve_float(ctx.sp3, few, @epoch)
    end

    test "duplicate and malformed observations are tagged", ctx do
      [first | rest] = ctx.observations
      first_sat = first.satellite_id

      assert {:error, {:duplicate_observation, ^first_sat}} =
               PrecisePositioning.solve_float(ctx.sp3, [first, first | rest], @epoch)

      assert {:error, {:invalid_observation, {"G01", :bad, 1.0}}} =
               PrecisePositioning.solve_float(ctx.sp3, [{"G01", :bad, 1.0}], @epoch)
    end

    test "bad initial guess and bad sigmas are tagged", ctx do
      assert {:error, :invalid_initial_guess} =
               PrecisePositioning.solve_float(ctx.sp3, ctx.observations, @epoch,
                 initial_guess: {:bad, 0.0, 0.0, 0.0}
               )

      assert {:error, {:invalid_sigma, :code_sigma_m}} =
               PrecisePositioning.solve_float(ctx.sp3, ctx.observations, @epoch,
                 initial_guess: {3_513_400.0, 780_100.0, 5_249_000.0, -20.0},
                 code_sigma_m: 0.0
               )

      assert {:error, {:invalid_option, :max_iterations}} =
               PrecisePositioning.solve_float(ctx.sp3, ctx.observations, @epoch,
                 initial_guess: {3_513_400.0, 780_100.0, 5_249_000.0, -20.0},
                 max_iterations: 0
               )

      assert {:error, {:invalid_option, :position_tolerance_m}} =
               PrecisePositioning.solve_float(ctx.sp3, ctx.observations, @epoch,
                 initial_guess: {3_513_400.0, 780_100.0, 5_249_000.0, -20.0},
                 position_tolerance_m: -1.0
               )

      assert {:error, {:invalid_option, :troposphere}} =
               PrecisePositioning.solve_float(ctx.sp3, ctx.observations, @epoch,
                 initial_guess: {3_513_400.0, 780_100.0, 5_249_000.0, -20.0},
                 troposphere: :yes
               )

      assert {:error, {:invalid_option, :estimate_ztd}} =
               PrecisePositioning.solve_float(ctx.sp3, ctx.observations, @epoch,
                 initial_guess: {3_513_400.0, 780_100.0, 5_249_000.0, -20.0},
                 troposphere: true,
                 estimate_ztd: true
               )

      assert {:error, {:invalid_option, :pressure_hpa}} =
               PrecisePositioning.solve_float(ctx.sp3, ctx.observations, @epoch,
                 initial_guess: {3_513_400.0, 780_100.0, 5_249_000.0, -20.0},
                 troposphere: true,
                 pressure_hpa: :bad
               )

      assert {:error, {:invalid_option, :relative_humidity}} =
               PrecisePositioning.solve_float(ctx.sp3, ctx.observations, @epoch,
                 initial_guess: {3_513_400.0, 780_100.0, 5_249_000.0, -20.0},
                 troposphere: true,
                 relative_humidity: 1.5
               )
    end
  end

  describe "range corrections: receiver ANTEX (INCR 1)" do
    @atx_small Path.join(__DIR__, "fixtures/antex/igs20_mmet_usal_gps.atx")

    setup do
      antex = Antex.load!(@atx_small)
      rx = Antex.antenna(antex, "LEIAR20         NONE") || raise "ANTEX missing LEIAR20"
      {:ok, antex: antex, receiver_antenna: %{antenna: rx, freq1: "G01", freq2: "G02"}}
    end

    test "applying the receiver antenna shifts the recovered position", ctx do
      # Observations are synthesized WITHOUT any antenna correction. Solving with
      # the receiver antenna applies the marker->phase-center projection, so the
      # recovered position must move by the (cm-scale) PCO/PCV magnitude.
      base = [initial_guess: {3_513_400.0, 780_100.0, 5_249_000.0, -20.0}]

      {:ok, plain} = PrecisePositioning.solve_float_epochs(ctx.sp3, ctx.epoch_observations, base)

      {:ok, corrected} =
        PrecisePositioning.solve_float_epochs(
          ctx.sp3,
          ctx.epoch_observations,
          Keyword.put(base, :receiver_antenna, ctx.receiver_antenna)
        )

      shift = position_error(corrected.position, position_tuple(plain.position))

      # LEIAR20 GPS PCO is dominated by a ~10 cm up offset; the IF combination is
      # a few cm to ~0.1 m. The shift must be nonzero and physically small.
      assert shift > 0.005
      assert shift < 0.5
    end

    test "rejects a malformed receiver_antenna option", ctx do
      assert {:error, {:invalid_option, :receiver_antenna}} =
               PrecisePositioning.solve_float_epochs(
                 ctx.sp3,
                 ctx.epoch_observations,
                 initial_guess: {3_513_400.0, 780_100.0, 5_249_000.0, -20.0},
                 receiver_antenna: %{antenna: :not_an_antenna, freq1: "G01", freq2: "G02"}
               )
    end

    test "rejects unsupported ANTEX frequency labels before NIF term construction", ctx do
      assert {:error, {:unsupported_frequency, "X99"}} =
               PrecisePositioning.solve_float_epochs(
                 ctx.sp3,
                 ctx.epoch_observations,
                 initial_guess: {3_513_400.0, 780_100.0, 5_249_000.0, -20.0},
                 receiver_antenna: %{ctx.receiver_antenna | freq1: "X99"}
               )

      assert {:error, {:unsupported_frequency, "X99"}} =
               PrecisePositioning.solve_float_epochs(
                 ctx.sp3,
                 ctx.epoch_observations,
                 initial_guess: {3_513_400.0, 780_100.0, 5_249_000.0, -20.0},
                 satellite_antenna: %{antex: ctx.antex, freq1: "X99", freq2: "G02"}
               )
    end
  end

  describe "range corrections: SP3-clock relativity (INCR 2)" do
    test "the eccentricity term equals 2*dot(r_sat, v_sat)/c and is meter-scale" do
      # Direct check of the exposed satellite position/velocity and the relativity
      # magnitude on a real SP3 satellite.
      {:ok, pred} = @sp3_path |> SP3.load!() |> Observables.predict("G07", @truth, @epoch)

      {rx, ry, rz} = pred.sat_pos_ecef_m
      {vx, vy, vz} = pred.sat_velocity_m_s
      expected = 2.0 * (rx * vx + ry * vy + rz * vz) / @c

      # GPS eccentricity relativity is bounded by ~|2*sqrt(a)*e*... | -> tens of
      # nanoseconds, i.e. a few metres of range; assert it is in that band.
      assert abs(expected) < 25.0
    end

    test "applying relativity shifts the recovered position", ctx do
      base = [initial_guess: {3_513_400.0, 780_100.0, 5_249_000.0, -20.0}]

      {:ok, plain} = PrecisePositioning.solve_float_epochs(ctx.sp3, ctx.epoch_observations, base)

      {:ok, corrected} =
        PrecisePositioning.solve_float_epochs(
          ctx.sp3,
          ctx.epoch_observations,
          Keyword.put(base, :satellite_clock_relativity, true)
        )

      shift = position_error(corrected.position, position_tuple(plain.position))
      assert shift > 0.0
    end

    test "rejects a non-boolean satellite_clock_relativity option", ctx do
      assert {:error, {:invalid_option, :satellite_clock_relativity}} =
               PrecisePositioning.solve_float_epochs(
                 ctx.sp3,
                 ctx.epoch_observations,
                 initial_guess: {3_513_400.0, 780_100.0, 5_249_000.0, -20.0},
                 satellite_clock_relativity: :yes
               )
    end
  end

  describe "res_ppp post-fit residual screen (INCR 3)" do
    test "excludes a single injected outlier and recovers the clean position", ctx do
      [{bad_sat, _} | _] = ctx.multi_sats
      base = [initial_guess: {3_513_400.0, 780_100.0, 5_249_000.0, -20.0}]

      # Inject a large code+phase outlier on one satellite at the first epoch.
      outlier_epoch = @epoch

      contaminated =
        Enum.map(ctx.epoch_observations, fn epoch_row ->
          if epoch_row.epoch == outlier_epoch do
            observations =
              Enum.map(epoch_row.observations, fn
                %{satellite_id: ^bad_sat} = o ->
                  %{o | code_m: o.code_m + 50.0, phase_m: o.phase_m + 50.0}

                o ->
                  o
              end)

            %{epoch_row | observations: observations}
          else
            epoch_row
          end
        end)

      # Without the screen the outlier corrupts the static position.
      {:ok, unscreened} =
        PrecisePositioning.solve_float_epochs(ctx.sp3, contaminated, base)

      # With the screen the worst observation is excluded and the position
      # recovers close to truth.
      {:ok, screened} =
        PrecisePositioning.solve_float_epochs(
          ctx.sp3,
          contaminated,
          Keyword.put(base, :residual_screen, true)
        )

      assert position_error(screened.position, @truth) <
               position_error(unscreened.position, @truth)

      assert position_error(screened.position, @truth) < 1.0e-2
    end

    test "a clean arc is unchanged by the screen", ctx do
      base = [initial_guess: {3_513_400.0, 780_100.0, 5_249_000.0, -20.0}]

      {:ok, plain} = PrecisePositioning.solve_float_epochs(ctx.sp3, ctx.epoch_observations, base)

      {:ok, screened} =
        PrecisePositioning.solve_float_epochs(
          ctx.sp3,
          ctx.epoch_observations,
          Keyword.put(base, :residual_screen, true)
        )

      assert position_error(screened.position, position_tuple(plain.position)) < 1.0e-9
      assert screened.used_sats == plain.used_sats
    end

    test "rejects a non-boolean residual_screen option", ctx do
      assert {:error, {:invalid_option, :residual_screen}} =
               PrecisePositioning.solve_float_epochs(
                 ctx.sp3,
                 ctx.epoch_observations,
                 initial_guess: {3_513_400.0, 780_100.0, 5_249_000.0, -20.0},
                 residual_screen: :yes
               )
    end
  end

  defp synth_observations(sats, opts \\ []) do
    epoch = Keyword.get(opts, :epoch, @epoch)

    sats
    |> Enum.with_index()
    |> Enum.map(fn {{sat, obs}, idx} ->
      tropo_m = synthetic_tropo_m(obs, epoch, opts)
      code = obs.geometric_range_m - @c * obs.sat_clock_s + @clock_m + tropo_m
      ambiguity = ambiguity_m(idx)

      %{
        satellite_id: sat,
        code_m: code,
        phase_m: code + ambiguity
      }
    end)
  end

  defp synth_epoch_observations(multi_sats, opts \\ []) do
    @epochs
    |> Enum.zip(@epoch_clocks_m)
    |> Enum.map(fn {epoch, clock_m} ->
      observations =
        Enum.map(multi_sats, fn {sat, predictions} ->
          {_epoch, obs} =
            Enum.find(predictions, fn {prediction_epoch, _obs} -> prediction_epoch == epoch end)

          tropo_m = synthetic_tropo_m(obs, epoch, opts)
          code = obs.geometric_range_m - @c * obs.sat_clock_s + clock_m + tropo_m
          idx = Enum.find_index(multi_sats, fn {candidate, _} -> candidate == sat end)

          %{
            satellite_id: sat,
            code_m: code,
            phase_m: code + ambiguity_m(idx)
          }
        end)

      %{epoch: epoch, observations: observations}
    end)
  end

  defp synth_fixed_epoch_observations(multi_sats, opts \\ []) do
    @epochs
    |> Enum.zip(@epoch_clocks_m)
    |> Enum.map(fn {epoch, clock_m} ->
      observations =
        Enum.map(multi_sats, fn {sat, predictions} ->
          {_epoch, obs} =
            Enum.find(predictions, fn {prediction_epoch, _obs} -> prediction_epoch == epoch end)

          tropo_m = synthetic_tropo_m(obs, epoch, opts)
          code = obs.geometric_range_m - @c * obs.sat_clock_s + clock_m + tropo_m
          idx = Enum.find_index(multi_sats, fn {candidate, _} -> candidate == sat end)

          %{
            satellite_id: sat,
            code_m: code,
            phase_m: code + fixed_ambiguity_cycles(idx) * @l1_wavelength_m
          }
        end)

      %{epoch: epoch, observations: observations}
    end)
  end

  defp synth_dual_frequency_epoch_observations(multi_sats) do
    @epochs
    |> Enum.zip(@epoch_clocks_m)
    |> Enum.with_index()
    |> Enum.map(fn {{epoch, clock_m}, epoch_idx} ->
      observations =
        Enum.map(multi_sats, fn {sat, predictions} ->
          {_epoch, obs} =
            Enum.find(predictions, fn {prediction_epoch, _obs} -> prediction_epoch == epoch end)

          sat_idx = Enum.find_index(multi_sats, fn {candidate, _} -> candidate == sat end)
          base = obs.geometric_range_m - @c * obs.sat_clock_s + clock_m

          # First-order ionosphere: code delay is positive, carrier phase advance
          # is negative, and the second band scales as 1/f^2.
          iono1_m = 2.0 + 0.05 * epoch_idx + 0.02 * sat_idx
          iono2_m = iono1_m * :math.pow(@f_l1 / @f_l2, 2)
          n1 = fixed_ambiguity_cycles(sat_idx)
          n2 = n1 - wide_lane_cycles(sat_idx)

          %{
            satellite_id: sat,
            p1_m: base + iono1_m,
            p2_m: base + iono2_m,
            phi1_cyc: (base - iono1_m + n1 * @l1_wavelength_m) / @l1_wavelength_m,
            phi2_cyc: (base - iono2_m + n2 * @l2_wavelength_m) / @l2_wavelength_m,
            f1_hz: @f_l1,
            f2_hz: @f_l2,
            lli1: 0,
            lli2: 0
          }
        end)

      %{epoch: epoch, observations: observations}
    end)
  end

  defp synthetic_tropo_m(prediction, epoch, opts) do
    if Keyword.get(opts, :troposphere, false) do
      {x, y, z} = @truth
      geo = Coordinates.to_geodetic({x / 1000.0, y / 1000.0, z / 1000.0})
      height_m = geo.altitude_km * 1000.0

      {:ok, delay_m} =
        Troposphere.slant_delay(
          prediction.elevation_deg,
          geo.latitude,
          geo.longitude,
          height_m,
          @met,
          epoch
        )

      delay_m + synthetic_residual_ztd_m(prediction, geo.latitude, height_m, epoch, opts)
    else
      0.0
    end
  end

  defp synthetic_residual_ztd_m(prediction, latitude_deg, height_m, epoch, opts) do
    case Keyword.get(opts, :residual_ztd_m, 0.0) do
      residual_ztd_m when is_number(residual_ztd_m) ->
        {:ok, %{wet: wet_mapping}} =
          Troposphere.mapping(prediction.elevation_deg, latitude_deg, height_m, epoch)

        residual_ztd_m * wet_mapping

      _other ->
        0.0
    end
  end

  defp true_ambiguities(sats) do
    sats
    |> Enum.with_index()
    |> Map.new(fn {{sat, _obs}, idx} -> {sat, ambiguity_m(idx)} end)
  end

  defp ambiguity_m(idx), do: 15_000.0 + idx * 17.25
  defp fixed_ambiguity_cycles(idx), do: 80_000 + idx * 37
  defp wide_lane_cycles(idx), do: 12 + idx * 3

  defp narrow_lane_offset_m(wide_lane_cycles) do
    {:ok, gamma} = Sidereon.GNSS.IonosphereFree.gamma(@f_l1, @f_l2)
    (gamma - 1.0) * @l2_wavelength_m * wide_lane_cycles
  end

  defp true_fixed_cycles(sats) do
    sats
    |> Enum.with_index()
    |> Map.new(fn {{sat, _obs}, idx} -> {sat, fixed_ambiguity_cycles(idx)} end)
  end

  defp true_wide_lane_cycles(sats) do
    sats
    |> Enum.with_index()
    |> Map.new(fn {{sat, _obs}, idx} -> {sat, wide_lane_cycles(idx)} end)
  end

  defp bias_fixed_epoch_phases(epoch_observations, biases_cycles_by_sat) do
    Enum.map(epoch_observations, fn epoch_row ->
      observations =
        Enum.map(epoch_row.observations, fn obs ->
          case Map.fetch(biases_cycles_by_sat, obs.satellite_id) do
            {:ok, bias_cycles} ->
              %{obs | phase_m: obs.phase_m + bias_cycles * @l1_wavelength_m}

            :error ->
              obs
          end
        end)

      %{epoch_row | observations: observations}
    end)
  end

  defp square_matrix?(matrix, n) do
    length(matrix) == n and Enum.all?(matrix, &(length(&1) == n))
  end

  defp brute_force_ils(search, radius) do
    floats = Enum.map(search.order, &Map.fetch!(search.float_cycles, &1))

    floats
    |> Enum.map(&round/1)
    |> integer_box(radius)
    |> Enum.map(fn cycles ->
      {quadratic_integer_score(floats, cycles, search.covariance_inverse_cycles),
       Map.new(Enum.zip(search.order, cycles))}
    end)
    |> Enum.sort_by(fn {score, fixed_cycles} ->
      {score, Enum.map(search.order, &Map.fetch!(fixed_cycles, &1))}
    end)
  end

  defp coordinate_rounded_cycles(search) do
    coordinate_rounded_cycles(search.order, search.float_cycles)
  end

  defp coordinate_rounded_cycles(order, float_cycles) do
    Map.new(order, fn sat -> {sat, Map.fetch!(float_cycles, sat) |> round()} end)
  end

  defp integer_box(rounded_cycles, radius) do
    rounded_cycles
    |> Enum.reduce([[]], fn center, acc ->
      for prefix <- acc, value <- (center - radius)..(center + radius), do: [value | prefix]
    end)
    |> Enum.map(&Enum.reverse/1)
  end

  defp quadratic_integer_score(float_cycles, fixed_cycles, q_inv) do
    deltas =
      fixed_cycles
      |> Enum.zip(float_cycles)
      |> Enum.map(fn {z, a} -> a - z end)

    n = length(deltas)

    Enum.reduce(0..(n - 1), 0.0, fn i, acc ->
      Enum.reduce(0..(n - 1), acc, fn j, inner ->
        inner + Enum.at(deltas, i) * (q_inv |> Enum.at(i) |> Enum.at(j)) * Enum.at(deltas, j)
      end)
    end)
  end

  defp slip_dual_frequency_after(epoch_observations, sat, slip_epoch, cycles) do
    Enum.map(epoch_observations, fn epoch_row ->
      observations =
        Enum.map(epoch_row.observations, fn
          %{satellite_id: ^sat} = obs ->
            if NaiveDateTime.compare(epoch_row.epoch, slip_epoch) in [:eq, :gt] do
              %{obs | phi1_cyc: obs.phi1_cyc + cycles}
            else
              obs
            end

          obs ->
            obs
        end)

      %{epoch_row | observations: observations}
    end)
  end

  # Build iono-free %{code_m, phase_m, + raw dual-frequency fields} rows from the
  # dual-frequency fixture. On `sat` from `slip_epoch` onward an integer L1 carrier
  # slip is injected (band-1 phase jumps by `slip_cycles`) and the LLI
  # loss-of-lock bit is flagged AT the slip epoch, so the float-path cycle-slip
  # detector starts a fresh ambiguity arc there. `sat`/`slip_epoch` nil leaves a
  # clean (slip-free) arc.
  defp iono_free_with_lli_slip(epoch_observations, sat, slip_epoch, slip_cycles \\ 8.0) do
    Enum.map(epoch_observations, fn epoch_row ->
      at_or_after? =
        not is_nil(slip_epoch) and
          NaiveDateTime.compare(epoch_row.epoch, slip_epoch) in [:eq, :gt]

      # Loss-of-lock is a one-time event: the LLI bit is set only AT the slip
      # epoch (the first epoch of the new arc), not on every later epoch.
      at_slip? =
        not is_nil(slip_epoch) and NaiveDateTime.compare(epoch_row.epoch, slip_epoch) == :eq

      observations =
        Enum.map(epoch_row.observations, fn obs ->
          slipped_sat? = obs.satellite_id == sat

          phi1_cyc =
            if slipped_sat? and at_or_after?, do: obs.phi1_cyc + slip_cycles, else: obs.phi1_cyc

          {:ok, code_m} = IonosphereFree.iono_free(obs.p1_m, obs.p2_m, obs.f1_hz, obs.f2_hz)

          {:ok, phase_m} =
            IonosphereFree.iono_free_phase_cycles(phi1_cyc, obs.phi2_cyc, obs.f1_hz, obs.f2_hz)

          %{
            satellite_id: obs.satellite_id,
            code_m: code_m,
            phase_m: phase_m,
            phi1_cyc: phi1_cyc,
            phi2_cyc: obs.phi2_cyc,
            p1_m: obs.p1_m,
            p2_m: obs.p2_m,
            f1_hz: obs.f1_hz,
            f2_hz: obs.f2_hz,
            lli1: if(slipped_sat? and at_slip?, do: 1, else: 0),
            lli2: 0
          }
        end)

      %{epoch: epoch_row.epoch, observations: observations}
    end)
  end

  defp position_error(%{x_m: x, y_m: y, z_m: z}, {tx, ty, tz}) do
    :math.sqrt((x - tx) * (x - tx) + (y - ty) * (y - ty) + (z - tz) * (z - tz))
  end

  defp position_tuple(%{x_m: x, y_m: y, z_m: z}), do: {x, y, z}
end
