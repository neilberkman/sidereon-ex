defmodule Sidereon.GNSS.RTKTest do
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.{Antex, RTK}

  @base {1_110_000.0, -4_840_000.0, 3_980_000.0}
  @truth_baseline {12.5, -4.25, 2.75}
  @c 299_792_458.0
  @earth_rotation_rate_rad_s 7.2921151467e-5
  @f_l1 1_575_420_000.0
  @f_l2 1_227_600_000.0
  @l1_wavelength_m 299_792_458.0 / 1_575_420_000.0
  @l2_wavelength_m @c / @f_l2
  @narrow_lane_wavelength_m @c / (@f_l1 + @f_l2)
  @sat_positions [
    %{
      "G01" => {21_000_000.0, 14_000_000.0, 20_000_000.0},
      "G02" => {-18_000_000.0, 19_000_000.0, 18_500_000.0},
      "G03" => {15_000_000.0, -21_000_000.0, 17_000_000.0},
      "G04" => {-20_000_000.0, -12_000_000.0, 21_000_000.0},
      "G05" => {24_000_000.0, -5_000_000.0, 16_000_000.0}
    },
    %{
      "G01" => {21_020_000.0, 13_960_000.0, 20_010_000.0},
      "G02" => {-18_030_000.0, 19_020_000.0, 18_470_000.0},
      "G03" => {15_040_000.0, -20_970_000.0, 17_020_000.0},
      "G04" => {-19_980_000.0, -12_050_000.0, 21_030_000.0},
      "G05" => {23_960_000.0, -4_970_000.0, 16_050_000.0}
    },
    %{
      "G01" => {21_050_000.0, 13_910_000.0, 20_030_000.0},
      "G02" => {-18_070_000.0, 19_050_000.0, 18_430_000.0},
      "G03" => {15_090_000.0, -20_930_000.0, 17_060_000.0},
      "G04" => {-19_950_000.0, -12_090_000.0, 21_060_000.0},
      "G05" => {23_930_000.0, -4_940_000.0, 16_100_000.0}
    }
  ]
  @ambiguities %{"G01" => 0.0, "G02" => 0.42, "G03" => -0.73, "G04" => 1.12, "G05" => -0.38}
  @fixed_cycles %{"G01" => 0, "G02" => 5, "G03" => -7, "G04" => 12, "G05" => -4}
  @wide_lane_cycles %{"G01" => 0, "G02" => 3, "G03" => -5, "G04" => 8, "G05" => -2}

  # Multi-GNSS fixtures: Galileo on a deliberately non-L1 wavelength to prove
  # per-satellite wavelengths flow through the integer search, and GLONASS on
  # per-slot FDMA wavelengths used float-only.
  @e_wavelength_m 0.25
  @e_cycles %{"E02" => 7, "E11" => -5, "E19" => 3}
  @r_slots %{"R05" => -1, "R12" => 4, "R21" => -7}
  @r_ambiguities_m %{"R05" => 0.31, "R12" => -0.27, "R21" => 0.55}
  @extra_sat_positions [
    %{
      "E02" => {20_500_000.0, 6_000_000.0, 21_500_000.0},
      "E11" => {-16_000_000.0, -18_500_000.0, 19_500_000.0},
      "E19" => {12_500_000.0, 20_500_000.0, 18_200_000.0},
      "R05" => {23_000_000.0, 2_000_000.0, 17_500_000.0},
      "R12" => {-21_000_000.0, 10_000_000.0, 19_800_000.0},
      "R21" => {16_500_000.0, -19_000_000.0, 18_800_000.0}
    },
    %{
      "E02" => {20_530_000.0, 5_950_000.0, 21_520_000.0},
      "E11" => {-16_040_000.0, -18_470_000.0, 19_530_000.0},
      "E19" => {12_540_000.0, 20_470_000.0, 18_230_000.0},
      "R05" => {22_960_000.0, 2_040_000.0, 17_540_000.0},
      "R12" => {-20_970_000.0, 9_960_000.0, 19_830_000.0},
      "R21" => {16_540_000.0, -18_960_000.0, 18_830_000.0}
    },
    %{
      "E02" => {20_560_000.0, 5_900_000.0, 21_550_000.0},
      "E11" => {-16_080_000.0, -18_440_000.0, 19_560_000.0},
      "E19" => {12_580_000.0, 20_440_000.0, 18_260_000.0},
      "R05" => {22_920_000.0, 2_080_000.0, 17_580_000.0},
      "R12" => {-20_940_000.0, 9_920_000.0, 19_860_000.0},
      "R21" => {16_580_000.0, -18_920_000.0, 18_860_000.0}
    }
  ]

  describe "double_differences/3" do
    test "receiver clocks and common satellite errors cancel" do
      sats = ["G01", "G02", "G03", "G04"]
      reference = "G01"
      base_clock_m = 125.0
      rover_clock_m = -42.0

      base_ranges = %{"G01" => 20_000.0, "G02" => 21_000.0, "G03" => 22_500.0, "G04" => 23_100.0}
      rover_ranges = %{"G01" => 20_010.0, "G02" => 21_025.0, "G03" => 22_480.0, "G04" => 23_150.0}
      common_errors = %{"G01" => 3.25, "G02" => -12.0, "G03" => 8.5, "G04" => 1.0}
      base_phase_ambiguities = %{"G01" => 2.0, "G02" => -3.0, "G03" => 7.0, "G04" => 11.0}
      rover_phase_ambiguities = %{"G01" => 5.0, "G02" => 4.0, "G03" => 1.0, "G04" => 19.0}

      base =
        synth_observations(sats, base_ranges, base_clock_m, common_errors, base_phase_ambiguities)

      rover =
        synth_observations(
          sats,
          rover_ranges,
          rover_clock_m,
          common_errors,
          rover_phase_ambiguities
        )

      assert {:ok, result} =
               RTK.double_differences(base, rover, reference_satellite_id: reference)

      assert result.reference_satellite_id == reference
      assert result.dropped_sats == []

      by_sat = Map.new(result.double_differences, &{&1.satellite_id, &1})

      for sat <- sats -- [reference] do
        expected_code =
          Map.fetch!(rover_ranges, sat) - Map.fetch!(base_ranges, sat) -
            (Map.fetch!(rover_ranges, reference) - Map.fetch!(base_ranges, reference))

        expected_phase =
          expected_code +
            (Map.fetch!(rover_phase_ambiguities, sat) -
               Map.fetch!(base_phase_ambiguities, sat)) -
            (Map.fetch!(rover_phase_ambiguities, reference) -
               Map.fetch!(base_phase_ambiguities, reference))

        assert by_sat[sat].reference_satellite_id == reference
        assert by_sat[sat].code_m == expected_code
        assert by_sat[sat].phase_m == expected_phase
      end
    end

    test "selects a deterministic default reference and reports dropped satellites" do
      base = [{"G02", 210.0, 211.0}, {"G01", 100.0, 101.0}, {"G09", 900.0, 901.0}]
      rover = [{"G02", 230.0, 233.0}, {"G01", 105.0, 108.0}, {"G10", 1000.0, 1001.0}]

      assert {:ok, result} = RTK.double_differences(base, rover)

      assert result.reference_satellite_id == "G01"
      assert result.dropped_sats == ["G09", "G10"]

      assert result.double_differences == [
               %{
                 satellite_id: "G02",
                 reference_satellite_id: "G01",
                 ambiguity_id: "G02",
                 code_m: 15.0,
                 phase_m: 15.0
               }
             ]
    end

    test "reports double-difference ambiguity ids when carrier arcs are explicit" do
      base = [
        %{satellite_id: "G01", code_m: 100.0, phase_m: 101.0},
        %{satellite_id: "G02", code_m: 210.0, phase_m: 211.0}
      ]

      rover = [
        %{satellite_id: "G01", code_m: 105.0, phase_m: 108.0, ambiguity_id: "G01#2"},
        %{satellite_id: "G02", code_m: 230.0, phase_m: 233.0, ambiguity_id: "G02#2"}
      ]

      assert {:ok, result} = RTK.double_differences(base, rover, reference_satellite_id: "G01")

      assert [%{ambiguity_id: ambiguity_id}] = result.double_differences

      assert ambiguity_id == "G02#2|ref=G01#2"
    end

    test "bad inputs are tagged" do
      assert RTK.double_differences([{"G01", 1.0, 2.0}], [{"G01", 1.0, 2.0}]) ==
               {:error, {:too_few_common_satellites, 1, 2}}

      assert RTK.double_differences(
               [{"G01", 1.0, 2.0}, {"G01", 3.0, 4.0}],
               [{"G01", 1.0, 2.0}, {"G02", 3.0, 4.0}]
             ) == {:error, {:duplicate_observation, "G01"}}

      assert RTK.double_differences(
               [{"G01", 1.0, 2.0}, {"G02", 3.0, 4.0}],
               [{"G01", 1.0, 2.0}, {"G02", 3.0, 4.0}],
               reference_satellite_id: "G99"
             ) == {:error, {:reference_satellite_missing, "G99"}}

      assert RTK.double_differences([{"G01", :bad, 2.0}], [{"G01", 1.0, 2.0}]) ==
               {:error, {:invalid_base_observations, {"G01", :bad, 2.0}}}

      assert RTK.double_differences([{"G01", 1.0, 2.0}], [{"G01", 1.0, :bad}]) ==
               {:error, {:invalid_rover_observations, {"G01", 1.0, :bad}}}

      assert RTK.double_differences(
               [{"G01", 1.0, 2.0}, {"G02", 3.0, 4.0}],
               [{"G01", 1.0, 2.0}, {"G02", 3.0, 4.0}],
               reference_satellite: "G01"
             ) == {:error, {:invalid_option, :reference_satellite}}

      assert RTK.double_differences(
               [{"G01", 1.0, 2.0}, {"G02", 3.0, 4.0}],
               [{"G01", 1.0, 2.0}, {"G02", 3.0, 4.0}],
               [:not_a_keyword]
             ) == {:error, {:invalid_option, :opts}}
    end
  end

  describe "solve_float_baseline_epochs/3" do
    test "recovers a static baseline and float DD ambiguities from a wrong seed" do
      epochs =
        @sat_positions
        |> Enum.with_index()
        |> Enum.map(fn {positions, idx} ->
          synthetic_baseline_epoch(@base, @truth_baseline, positions,
            epoch: idx,
            base_clock_m: 120.0 - 3.0 * idx,
            rover_clock_m: -45.0 + 7.0 * idx,
            common_errors_m: %{
              "G01" => 2.0 + idx,
              "G02" => -3.5,
              "G03" => 1.25 * idx,
              "G04" => -0.75,
              "G05" => 4.0
            },
            ambiguities_m: @ambiguities
          )
        end)

      assert {:ok, sol} =
               RTK.solve_float_baseline_epochs(@base, epochs,
                 reference_satellite_id: "G01",
                 initial_baseline_m: {-40.0, 35.0, 12.0}
               )

      assert sol.reference_satellite_id == "G01"
      assert sol.used_sats == ["G02", "G03", "G04", "G05"]
      assert sol.metadata.converged
      assert sol.metadata.n_epochs == 3
      assert sol.metadata.dropped_sats == []

      assert sol.metadata.measurement_covariance == %{
               model: :double_difference,
               code_sigma_m: 1.0,
               phase_sigma_m: 0.02,
               stochastic_model: :simple,
               elevation_weighting: false,
               sagnac: true,
               min_elevation_sin: 0.05
             }

      assert sol.metadata.ambiguity_float.order == sol.used_sats
      assert length(sol.metadata.ambiguity_float.covariance_m) == length(sol.used_sats)
      assert nonzero_off_diagonal?(sol.metadata.ambiguity_float.covariance_m)

      assert_identity(
        matmul(
          sol.metadata.ambiguity_float.covariance_m,
          sol.metadata.ambiguity_float.covariance_inverse_m
        ),
        1.0e-6
      )

      assert position_error(sol.baseline_m, @truth_baseline) < 1.0e-5

      for {sat, expected} <- Map.delete(@ambiguities, "G01") do
        assert abs(Map.fetch!(sol.ambiguities_m, sat) - expected) < 1.0e-5
      end

      for residual <- sol.residuals_m do
        assert abs(residual.code_m) < 1.0e-5
        assert abs(residual.phase_m) < 1.0e-5
      end
    end

    test "selects the highest-elevation default reference and uses epoch-local satellites" do
      [first, second | _] = @sat_positions

      epoch_a =
        synthetic_baseline_epoch(@base, @truth_baseline, first,
          ambiguities_m: @ambiguities,
          epoch: :a
        )

      epoch_b =
        synthetic_baseline_epoch(@base, @truth_baseline, Map.delete(second, "G05"),
          ambiguities_m: @ambiguities,
          epoch: :b
        )

      assert {:ok, sol} = RTK.solve_float_baseline_epochs(@base, [epoch_a, epoch_b])

      assert sol.reference_satellite_id == "G03"
      assert sol.used_sats == ["G01", "G02", "G04", "G05"]
      assert sol.metadata.dropped_sats == []
      assert sol.metadata.n_observations == 14
      assert position_error(sol.baseline_m, @truth_baseline) < 1.0e-4
    end

    test "can use elevation-dependent stochastic weighting" do
      epochs =
        @sat_positions
        |> Enum.with_index()
        |> Enum.map(fn {positions, idx} ->
          synthetic_baseline_epoch(@base, @truth_baseline, positions,
            epoch: idx,
            ambiguities_m: @ambiguities
          )
        end)

      assert {:ok, unweighted} =
               RTK.solve_float_baseline_epochs(@base, epochs,
                 reference_satellite_id: "G01",
                 initial_baseline_m: {-40.0, 35.0, 12.0}
               )

      assert {:ok, weighted} =
               RTK.solve_float_baseline_epochs(@base, epochs,
                 reference_satellite_id: "G01",
                 elevation_weighting: true,
                 initial_baseline_m: {-40.0, 35.0, 12.0}
               )

      assert weighted.metadata.measurement_covariance.elevation_weighting

      refute unweighted.metadata.ambiguity_float.covariance_m ==
               weighted.metadata.ambiguity_float.covariance_m

      assert position_error(weighted.baseline_m, @truth_baseline) < 1.0e-5
    end

    test "can use an RTKLIB-style floor plus elevation stochastic model" do
      epochs =
        @sat_positions
        |> Enum.with_index()
        |> Enum.map(fn {positions, idx} ->
          synthetic_baseline_epoch(@base, @truth_baseline, positions,
            epoch: idx,
            ambiguities_m: @ambiguities
          )
        end)

      assert {:ok, simple} =
               RTK.solve_float_baseline_epochs(@base, epochs,
                 reference_satellite_id: "G01",
                 elevation_weighting: true,
                 code_sigma_m: 0.3,
                 phase_sigma_m: 0.003,
                 initial_baseline_m: {-40.0, 35.0, 12.0}
               )

      assert {:ok, rtklib} =
               RTK.solve_float_baseline_epochs(@base, epochs,
                 reference_satellite_id: "G01",
                 stochastic_model: :rtklib,
                 code_sigma_m: 0.3,
                 phase_sigma_m: 0.003,
                 initial_baseline_m: {-40.0, 35.0, 12.0}
               )

      assert rtklib.metadata.measurement_covariance.stochastic_model == :rtklib
      assert rtklib.metadata.measurement_covariance.code_sigma_m == 0.3
      assert rtklib.metadata.measurement_covariance.phase_sigma_m == 0.003

      refute rtklib.metadata.ambiguity_float.covariance_m ==
               simple.metadata.ambiguity_float.covariance_m

      assert position_error(rtklib.baseline_m, @truth_baseline) < 1.0e-5
    end

    test "can apply an elevation mask before reference and ambiguity selection" do
      base = {6_378_137.0, 0.0, 0.0}
      baseline = {1.0, 0.2, -0.1}

      positions_a = %{
        "G01" => {26_000_000.0, 0.0, 0.0},
        "G02" => {24_000_000.0, 4_000_000.0, 8_000_000.0},
        "G03" => {23_500_000.0, -5_000_000.0, 9_000_000.0},
        "G04" => {6_378_137.0, 26_000_000.0, 0.0},
        "G05" => {25_000_000.0, 2_000_000.0, -7_000_000.0}
      }

      positions_b = %{
        "G01" => {26_020_000.0, 20_000.0, 10_000.0},
        "G02" => {24_010_000.0, 4_020_000.0, 8_010_000.0},
        "G03" => {23_490_000.0, -4_980_000.0, 9_020_000.0},
        "G04" => {6_378_137.0, 26_020_000.0, 20_000.0},
        "G05" => {25_020_000.0, 2_010_000.0, -6_980_000.0}
      }

      epochs =
        [positions_a, positions_b]
        |> Enum.with_index()
        |> Enum.map(fn {positions, idx} ->
          synthetic_baseline_epoch(base, baseline, positions,
            epoch: idx,
            ambiguities_m: %{
              "G01" => 0.0,
              "G02" => 0.2,
              "G03" => -0.3,
              "G04" => 0.4,
              "G05" => -0.5
            }
          )
        end)

      assert {:ok, sol} =
               RTK.solve_float_baseline_epochs(base, epochs,
                 elevation_mask_deg: 5.0,
                 reference_satellite_id: "G01"
               )

      assert sol.used_sats == ["G02", "G03", "G05"]
      assert sol.metadata.elevation_mask_deg == 5.0
      assert sol.metadata.elevation_masked_sats == ["G04"]
      assert sol.metadata.dropped_sats == ["G04"]
      assert position_error(sol.baseline_m, baseline) < 1.0e-5
    end

    test "can Hatch-smooth code observations before forming double differences" do
      epochs =
        @sat_positions
        |> Enum.with_index()
        |> Enum.map(fn {positions, idx} ->
          synthetic_baseline_epoch(@base, @truth_baseline, positions,
            epoch: idx,
            ambiguities_m: @ambiguities
          )
        end)
        |> add_rover_code_noise(%{"G02" => [0.6, -0.3, 0.2], "G04" => [-0.5, 0.4, -0.1]})

      assert {:ok, raw} =
               RTK.solve_float_baseline_epochs(@base, epochs,
                 reference_satellite_id: "G01",
                 initial_baseline_m: {-40.0, 35.0, 12.0},
                 code_sigma_m: 100.0
               )

      assert {:ok, smoothed} =
               RTK.solve_float_baseline_epochs(@base, epochs,
                 reference_satellite_id: "G01",
                 initial_baseline_m: {-40.0, 35.0, 12.0},
                 code_sigma_m: 100.0,
                 code_smoothing: true,
                 hatch_window_cap: 2
               )

      assert smoothed.metadata.code_smoothing
      assert smoothed.metadata.code_smoothing_window_cap == 2
      assert smoothed.metadata.code_rms_m < raw.metadata.code_rms_m
    end

    test "defaults to an error on LLI cycle slips" do
      [first, second | _] = @sat_positions

      epoch_a =
        synthetic_baseline_epoch(@base, @truth_baseline, first,
          ambiguities_m: @ambiguities,
          epoch: 0
        )

      epoch_b =
        @base
        |> synthetic_baseline_epoch(@truth_baseline, second,
          ambiguities_m: @ambiguities,
          epoch: 1
        )
        |> mark_rover_lli("G02", 1)

      assert RTK.solve_float_baseline_epochs(@base, [epoch_a, epoch_b]) ==
               {:error, {:cycle_slip_detected, :rover, "G02", 1, [:lli]}}
    end

    test "can drop satellites with LLI cycle slips" do
      epochs =
        @sat_positions
        |> Enum.with_index()
        |> Enum.map(fn {positions, idx} ->
          epoch =
            synthetic_baseline_epoch(@base, @truth_baseline, positions,
              ambiguities_m: @ambiguities,
              epoch: idx
            )

          if idx == 1, do: mark_rover_lli(epoch, "G02", 1), else: epoch
        end)

      assert {:ok, sol} =
               RTK.solve_float_baseline_epochs(@base, epochs,
                 reference_satellite_id: "G01",
                 on_cycle_slip: :drop_satellite,
                 initial_baseline_m: {-40.0, 35.0, 12.0}
               )

      assert sol.used_sats == ["G03", "G04", "G05"]
      assert sol.metadata.dropped_cycle_slip_sats == ["G02"]
      assert sol.metadata.dropped_sats == ["G02"]
      assert position_error(sol.baseline_m, @truth_baseline) < 1.0e-5
    end

    test "can split ambiguity arcs at LLI cycle slips" do
      epochs =
        @sat_positions
        |> Enum.with_index()
        |> Enum.map(fn {positions, idx} ->
          ambiguities =
            if idx == 0 do
              Map.put(@ambiguities, "G02", 5.0 * @l1_wavelength_m)
            else
              Map.put(@ambiguities, "G02", 8.0 * @l1_wavelength_m)
            end

          epoch =
            synthetic_baseline_epoch(@base, @truth_baseline, positions,
              ambiguities_m: ambiguities,
              epoch: idx
            )

          if idx == 1, do: mark_rover_lli(epoch, "G02", 1), else: epoch
        end)

      assert {:ok, sol} =
               RTK.solve_float_baseline_epochs(@base, epochs,
                 reference_satellite_id: "G01",
                 on_cycle_slip: :split_arc,
                 initial_baseline_m: {-40.0, 35.0, 12.0}
               )

      g02_ids = Enum.filter(sol.used_sats, &String.contains?(&1, "G02"))
      assert length(g02_ids) == 2

      split_ids = sol.metadata.split_cycle_slip_arcs |> Enum.map(& &1.ambiguity_id) |> Enum.sort()
      assert length(split_ids) == 2

      g02_ambiguities =
        g02_ids
        |> Enum.map(&Map.fetch!(sol.ambiguities_m, &1))
        |> Enum.sort()

      assert Enum.zip(g02_ambiguities, [5.0 * @l1_wavelength_m, 8.0 * @l1_wavelength_m])
             |> Enum.all?(fn {got, expected} -> abs(got - expected) < 1.0e-5 end)

      assert position_error(sol.baseline_m, @truth_baseline) < 1.0e-5
    end

    test "bad baseline-solve inputs are tagged" do
      epoch = synthetic_baseline_epoch(@base, @truth_baseline, hd(@sat_positions))

      assert RTK.solve_float_baseline_epochs(:bad, [epoch]) == {:error, :invalid_base_position}
      assert RTK.solve_float_baseline_epochs(@base, []) == {:error, :no_epochs}
      assert RTK.solve_float_baseline_epochs(@base, :bad) == {:error, :invalid_epochs}

      assert RTK.solve_float_baseline_epochs(@base, [
               %{base_observations: [], rover_observations: []}
             ]) ==
               {:error, {:invalid_epoch_observations, 0}}

      assert RTK.solve_float_baseline_epochs(@base, [epoch], reference_satellite_id: "G99") ==
               {:error, {:reference_satellite_missing, "G99"}}

      assert RTK.solve_float_baseline_epochs(@base, [epoch], phase_sigma_m: 0.0) ==
               {:error, {:invalid_sigma, :phase_sigma_m}}

      assert RTK.solve_float_baseline_epochs(@base, [epoch], max_iterations: 0) ==
               {:error, {:invalid_option, :max_iterations}}

      assert RTK.solve_float_baseline_epochs(@base, [epoch], on_cycle_slip: :bad) ==
               {:error, {:invalid_option, :on_cycle_slip}}

      assert RTK.solve_float_baseline_epochs(@base, [epoch], elevation_weighting: :bad) ==
               {:error, {:invalid_option, :elevation_weighting}}

      assert RTK.solve_float_baseline_epochs(@base, [epoch], stochastic_model: :bad) ==
               {:error, {:invalid_option, :stochastic_model}}

      assert RTK.solve_float_baseline_epochs(@base, [epoch], sagnac: :bad) ==
               {:error, {:invalid_option, :sagnac}}

      assert RTK.solve_float_baseline_epochs(@base, [epoch], elevation_mask_deg: -1.0) ==
               {:error, {:invalid_option, :elevation_mask_deg}}

      assert RTK.solve_float_baseline_epochs(@base, [epoch], elevation_mask_deg: 90.0) ==
               {:error, {:invalid_option, :elevation_mask_deg}}

      assert RTK.solve_float_baseline_epochs(@base, [epoch], code_smoothing: :bad) ==
               {:error, {:invalid_option, :code_smoothing}}

      assert RTK.solve_float_baseline_epochs(@base, [epoch],
               code_smoothing: true,
               hatch_window_cap: 0
             ) == {:error, {:invalid_option, :hatch_window_cap}}

      assert RTK.solve_float_baseline_epochs(@base, [epoch], receiver_antenna_corrections: :bad) ==
               {:error, {:invalid_option, :receiver_antenna_corrections}}

      assert RTK.solve_float_baseline_epochs(@base, [epoch], phase_sigma: 0.02) ==
               {:error, {:invalid_option, :phase_sigma}}
    end

    test "float batch applies up-only receiver antenna corrections" do
      base_pco_up_m = 0.10
      rover_pco_up_m = 0.05
      epoch = synthetic_baseline_epoch(@base, @truth_baseline, hd(@sat_positions))

      corrected_epoch =
        apply_receiver_antenna_corrections_to_epoch(
          epoch,
          base_pco_up_m,
          rover_pco_up_m
        )

      {:ok, raw_dd} =
        RTK.double_differences(epoch.base_observations, epoch.rover_observations,
          reference_satellite_id: "G01"
        )

      {:ok, corrected_dd} =
        RTK.double_differences(
          corrected_epoch.base_observations,
          corrected_epoch.rover_observations,
          reference_satellite_id: "G01"
        )

      by_sat_raw = Map.new(raw_dd.double_differences, &{&1.satellite_id, &1})
      by_sat_corrected = Map.new(corrected_dd.double_differences, &{&1.satellite_id, &1})
      sat = "G02"
      ref = "G01"

      observed_delta =
        by_sat_raw[sat].code_m - by_sat_corrected[sat].code_m

      expected_delta =
        receiver_antenna_dd_correction(
          sat,
          ref,
          epoch.satellite_positions_m,
          base_pco_up_m,
          rover_pco_up_m
        )

      # The synthetic code generation uses
      #   corrected_range = geometric_range - δr·u
      # so observed double-difference changes by
      #   (δr·u)_rover,sat - (δr·u)_base,sat - (δr·u)_rover,ref + (δr·u)_base,ref.
      assert_in_delta observed_delta, expected_delta, 1.0e-6

      assert_in_delta by_sat_raw[sat].phase_m - by_sat_corrected[sat].phase_m,
                      expected_delta,
                      1.0e-6

      assert {:ok, sol} =
               RTK.solve_float_baseline_epochs(
                 @base,
                 [corrected_epoch],
                 reference_satellite_id: "G01",
                 initial_baseline_m: {-40.0, 35.0, 12.0},
                 receiver_antenna_corrections:
                   receiver_antenna_corrections_option(base_pco_up_m, rover_pco_up_m)
               )

      assert position_error(sol.baseline_m, @truth_baseline) < 2.0e-5
    end
  end

  describe "solve_fixed_baseline_epochs/3" do
    test "recovers a fixed static baseline and integer DD ambiguities" do
      ambiguities_m =
        Map.new(@fixed_cycles, fn {sat, cycles} -> {sat, cycles * @l1_wavelength_m} end)

      epochs =
        @sat_positions
        |> Enum.with_index()
        |> Enum.map(fn {positions, idx} ->
          synthetic_baseline_epoch(@base, @truth_baseline, positions,
            epoch: idx,
            base_clock_m: 80.0 + idx,
            rover_clock_m: -25.0 + 2.0 * idx,
            common_errors_m: %{
              "G01" => 1.5,
              "G02" => -2.0 + idx,
              "G03" => 0.25 * idx,
              "G04" => 3.0,
              "G05" => -0.5
            },
            ambiguities_m: ambiguities_m
          )
        end)

      assert {:ok, sol} =
               RTK.solve_fixed_baseline_epochs(@base, epochs,
                 reference_satellite_id: "G01",
                 ambiguity_wavelength_m: @l1_wavelength_m,
                 initial_baseline_m: {-40.0, 35.0, 12.0}
               )

      assert sol.reference_satellite_id == "G01"
      assert sol.used_sats == ["G02", "G03", "G04", "G05"]
      assert sol.metadata.integer_status == :fixed
      assert sol.metadata.integer_method == :lambda
      assert sol.metadata.integer_ratio > 1.0e6
      assert sol.metadata.ambiguity_search.order == sol.used_sats
      assert position_error(sol.baseline_m, @truth_baseline) < 1.0e-5

      for sat <- sol.used_sats do
        expected_cycles = Map.fetch!(@fixed_cycles, sat)
        assert Map.fetch!(sol.fixed_ambiguities_cycles, sat) == expected_cycles

        assert abs(Map.fetch!(sol.fixed_ambiguities_m, sat) - expected_cycles * @l1_wavelength_m) <
                 1.0e-12
      end

      for residual <- sol.residuals_m do
        assert abs(residual.code_m) < 1.0e-5
        assert abs(residual.phase_m) < 1.0e-5
      end
    end

    test "fixed solve respects split ambiguity arcs" do
      epochs =
        @sat_positions
        |> Enum.with_index()
        |> Enum.map(fn {positions, idx} ->
          cycles = if idx == 0, do: 5, else: 8

          ambiguities_m =
            @fixed_cycles
            |> Map.put("G02", cycles)
            |> Map.new(fn {sat, sat_cycles} -> {sat, sat_cycles * @l1_wavelength_m} end)

          epoch =
            synthetic_baseline_epoch(@base, @truth_baseline, positions,
              epoch: idx,
              ambiguities_m: ambiguities_m
            )

          if idx == 1, do: mark_rover_lli(epoch, "G02", 1), else: epoch
        end)

      assert {:ok, sol} =
               RTK.solve_fixed_baseline_epochs(@base, epochs,
                 reference_satellite_id: "G01",
                 ambiguity_wavelength_m: @l1_wavelength_m,
                 on_cycle_slip: :split_arc,
                 initial_baseline_m: {-40.0, 35.0, 12.0}
               )

      g02_ids = Enum.filter(sol.used_sats, &String.contains?(&1, "G02"))
      assert length(g02_ids) == 2
      assert sol.metadata.integer_status == :fixed
      assert sol.metadata.dropped_cycle_slip_sats == []
      assert length(sol.metadata.split_cycle_slip_arcs) == 2

      g02_cycles =
        g02_ids
        |> Enum.map(&Map.fetch!(sol.fixed_ambiguities_cycles, &1))
        |> Enum.sort()

      assert g02_cycles == [5, 8]
      assert position_error(sol.baseline_m, @truth_baseline) < 1.0e-5
    end

    test "partial ambiguity resolution fixes a clean subset and keeps weak arcs float" do
      bad_cycles = Map.put(@fixed_cycles, "G05", -3.49)

      ambiguities_m =
        Map.new(bad_cycles, fn {sat, cycles} -> {sat, cycles * @l1_wavelength_m} end)

      epochs =
        @sat_positions
        |> Enum.with_index()
        |> Enum.map(fn {positions, idx} ->
          synthetic_baseline_epoch(@base, @truth_baseline, positions,
            epoch: idx,
            ambiguities_m: ambiguities_m
          )
        end)

      common_opts = [
        reference_satellite_id: "G01",
        ambiguity_wavelength_m: @l1_wavelength_m,
        initial_baseline_m: {-40.0, 35.0, 12.0}
      ]

      assert {:ok, full} = RTK.solve_fixed_baseline_epochs(@base, epochs, common_opts)
      assert full.metadata.integer_status == :not_fixed
      refute full.metadata.partial_ambiguity_resolution

      assert {:ok, partial} =
               RTK.solve_fixed_baseline_epochs(
                 @base,
                 epochs,
                 Keyword.merge(common_opts,
                   partial_ambiguity_resolution: true,
                   partial_min_ambiguities: 2
                 )
               )

      assert partial.metadata.integer_status == :fixed
      assert partial.metadata.partial_ambiguity_resolution
      assert partial.metadata.partial_fixed
      assert length(partial.metadata.partial_fixed_ambiguities) >= 2
      assert "G05" in partial.metadata.partial_free_ambiguities
      refute Map.has_key?(partial.fixed_ambiguities_cycles, "G05")

      for sat <- partial.metadata.partial_fixed_ambiguities do
        assert Map.fetch!(partial.fixed_ambiguities_cycles, sat) == Map.fetch!(@fixed_cycles, sat)
      end

      assert position_error(partial.baseline_m, @truth_baseline) < 1.0e-5
    end

    test "residual validation can exclude a biased satellite before integer search" do
      ambiguities_m =
        Map.new(@fixed_cycles, fn {sat, cycles} -> {sat, cycles * @l1_wavelength_m} end)

      epochs =
        @sat_positions
        |> Enum.with_index()
        |> Enum.map(fn {positions, idx} ->
          synthetic_baseline_epoch(@base, @truth_baseline, positions,
            epoch: idx,
            ambiguities_m: ambiguities_m
          )
        end)
        |> add_rover_code_noise(%{"G05" => [40.0, -40.0, 40.0]})

      common_opts = [
        reference_satellite_id: "G01",
        ambiguity_wavelength_m: @l1_wavelength_m,
        initial_baseline_m: {-40.0, 35.0, 12.0},
        residual_threshold_sigma: 6.0
      ]

      assert {:error, {:residual_validation_failed, outlier, []}} =
               RTK.solve_fixed_baseline_epochs(
                 @base,
                 epochs,
                 Keyword.put(common_opts, :max_residual_exclusions, 0)
               )

      assert outlier.satellite_id == "G05"
      assert outlier.kind == :code
      assert abs(outlier.normalized_residual) > outlier.threshold_sigma

      assert {:ok, sol} = RTK.solve_fixed_baseline_epochs(@base, epochs, common_opts)

      assert sol.metadata.integer_status == :fixed
      assert sol.metadata.residual_validation.excluded_sats == ["G05"]
      assert [%{satellite_id: "G05", kind: :code}] = sol.metadata.residual_validation.exclusions
      refute "G05" in sol.used_sats
      assert position_error(sol.baseline_m, @truth_baseline) < 1.0e-5

      for sat <- sol.used_sats do
        assert Map.fetch!(sol.fixed_ambiguities_cycles, sat) == Map.fetch!(@fixed_cycles, sat)
      end
    end

    test "fixed solve supports per-ambiguity metre offsets" do
      offsets_m = %{"G02" => 0.35, "G03" => -0.22, "G04" => 0.12, "G05" => -0.41}

      ambiguities_m =
        Map.new(@fixed_cycles, fn
          {"G01", _cycles} -> {"G01", 0.0}
          {sat, cycles} -> {sat, Map.fetch!(offsets_m, sat) + cycles * @l1_wavelength_m}
        end)

      epochs =
        @sat_positions
        |> Enum.with_index()
        |> Enum.map(fn {positions, idx} ->
          synthetic_baseline_epoch(@base, @truth_baseline, positions,
            epoch: idx,
            ambiguities_m: ambiguities_m
          )
        end)

      assert {:ok, sol} =
               RTK.solve_fixed_baseline_epochs(@base, epochs,
                 reference_satellite_id: "G01",
                 ambiguity_wavelength_m: @l1_wavelength_m,
                 ambiguity_offset_m: offsets_m,
                 initial_baseline_m: {-40.0, 35.0, 12.0}
               )

      assert sol.metadata.integer_status == :fixed
      assert sol.metadata.ambiguity_offsets_m == offsets_m
      assert position_error(sol.baseline_m, @truth_baseline) < 1.0e-5

      for sat <- sol.used_sats do
        expected_cycles = Map.fetch!(@fixed_cycles, sat)
        expected_m = Map.fetch!(offsets_m, sat) + expected_cycles * @l1_wavelength_m

        assert Map.fetch!(sol.fixed_ambiguities_cycles, sat) == expected_cycles
        assert abs(Map.fetch!(sol.fixed_ambiguities_m, sat) - expected_m) < 1.0e-12
      end
    end

    test "bad fixed-baseline inputs are tagged" do
      epoch = synthetic_baseline_epoch(@base, @truth_baseline, hd(@sat_positions))

      assert RTK.solve_fixed_baseline_epochs(@base, [epoch]) ==
               {:error, :ambiguity_wavelength_required}

      assert RTK.solve_fixed_baseline_epochs(@base, [epoch], ambiguity_wavelength_m: 0.0) ==
               {:error, {:invalid_option, :ambiguity_wavelength_m}}

      assert RTK.solve_fixed_baseline_epochs(@base, [epoch],
               ambiguity_wavelength_m: %{"G02" => @l1_wavelength_m}
             ) == {:error, {:invalid_ambiguity_wavelength, "G01"}}

      assert RTK.solve_fixed_baseline_epochs(@base, [epoch],
               ambiguity_wavelength_m: @l1_wavelength_m,
               integer_ratio_threshold: -1.0
             ) == {:error, {:invalid_option, :integer_ratio_threshold}}

      # RTKLIB rejects thresar[0] < 1.0: a sub-1.0 ratio threshold can never
      # discriminate the second-best from the best candidate.
      assert RTK.solve_fixed_baseline_epochs(@base, [epoch],
               ambiguity_wavelength_m: @l1_wavelength_m,
               integer_ratio_threshold: 0.5
             ) == {:error, {:invalid_option, :integer_ratio_threshold}}

      assert RTK.solve_fixed_baseline_epochs(@base, [epoch],
               ambiguity_wavelength_m: @l1_wavelength_m,
               partial_ambiguity_resolution: :bad
             ) == {:error, {:invalid_option, :partial_ambiguity_resolution}}

      assert RTK.solve_fixed_baseline_epochs(@base, [epoch],
               ambiguity_wavelength_m: @l1_wavelength_m,
               partial_min_ambiguities: 0
             ) == {:error, {:invalid_option, :partial_min_ambiguities}}

      assert RTK.solve_fixed_baseline_epochs(@base, [epoch],
               reference_satellite_id: "G01",
               ambiguity_wavelength_m: @l1_wavelength_m,
               ambiguity_offset_m: %{"G02" => 0.25}
             ) == {:error, {:invalid_ambiguity_offset, "G03"}}

      assert RTK.solve_fixed_baseline_epochs(@base, [epoch],
               reference_satellite_id: "G01",
               ambiguity_wavelength_m: @l1_wavelength_m,
               ambiguity_offset_m: :bad
             ) == {:error, {:invalid_option, :ambiguity_offset_m}}

      assert RTK.solve_fixed_baseline_epochs(@base, [epoch],
               ambiguity_wavelength_m: @l1_wavelength_m,
               integer_ratio: 3.0
             ) == {:error, {:invalid_option, :integer_ratio}}

      assert RTK.solve_fixed_baseline_epochs(@base, [epoch],
               ambiguity_wavelength_m: @l1_wavelength_m,
               residual_threshold_sigma: 0.0
             ) == {:error, {:invalid_option, :residual_threshold_sigma}}

      assert RTK.solve_fixed_baseline_epochs(@base, [epoch],
               ambiguity_wavelength_m: @l1_wavelength_m,
               max_residual_exclusions: -1
             ) == {:error, {:invalid_option, :max_residual_exclusions}}

      assert RTK.solve_fixed_baseline_epochs(
               @base,
               [epoch],
               ambiguity_wavelength_m: @l1_wavelength_m,
               receiver_antenna_corrections: :bad
             ) == {:error, {:invalid_option, :receiver_antenna_corrections}}
    end
  end

  describe "solve_filter_baseline_epochs/3" do
    test "sequentially fixes and holds static RTK ambiguities" do
      ambiguities_m =
        Map.new(@fixed_cycles, fn {sat, cycles} -> {sat, cycles * @l1_wavelength_m} end)

      epochs =
        @sat_positions
        |> Enum.with_index()
        |> Enum.map(fn {positions, idx} ->
          synthetic_baseline_epoch(@base, @truth_baseline, positions,
            epoch: idx,
            base_clock_m: 15.0 + idx,
            rover_clock_m: -8.0 + idx,
            ambiguities_m: ambiguities_m
          )
        end)

      opts = [
        reference_satellite_id: "G01",
        ambiguity_wavelength_m: @l1_wavelength_m,
        initial_baseline_m: {-40.0, 35.0, 12.0}
      ]

      assert {:ok, default_sol} = RTK.solve_filter_baseline_epochs(@base, epochs, opts)
      assert default_sol.metadata.filter_kernel == :rust
      assert position_error(default_sol.baseline_m, @truth_baseline) < 2.0e-4

      assert {:ok, sol} =
               RTK.solve_filter_baseline_epochs(@base, epochs, opts ++ [filter_kernel: :elixir])

      assert sol.reference_satellite_id == "G01"
      assert sol.metadata.integer_method == :sequential_lambda
      assert sol.metadata.ambiguity_state == :single_difference
      assert sol.metadata.ambiguity_initialization == :phase_code
      assert sol.metadata.filter_kernel == :elixir

      assert sol.metadata.initialized_ambiguity_count == map_size(@fixed_cycles)

      assert sol.metadata.first_fixed_index != nil
      assert sol.metadata.fixed_epoch_count > 0
      assert position_error(sol.baseline_m, @truth_baseline) < 2.0e-4

      fixed_epoch = Enum.find(sol.epochs, &(&1.integer_status == :fixed))
      expected_order = @fixed_cycles |> Map.delete("G01") |> Map.keys() |> Enum.sort()

      assert fixed_epoch.integer_ratio >= 3.0
      assert fixed_epoch.integer_best_score <= fixed_epoch.integer_second_best_score
      assert fixed_epoch.integer_candidates > 0
      assert fixed_epoch.ambiguity_search.order == expected_order

      assert Map.keys(fixed_epoch.ambiguity_search.float_cycles) ==
               fixed_epoch.ambiguity_search.order

      assert length(fixed_epoch.ambiguity_search.covariance_cycles) ==
               length(fixed_epoch.ambiguity_search.order)

      assert length(fixed_epoch.ambiguity_search.covariance_inverse_cycles) ==
               length(fixed_epoch.ambiguity_search.order)

      assert length(fixed_epoch.residuals_m) == length(expected_order)
      assert Enum.all?(fixed_epoch.residuals_m, &(&1.reference_satellite_id == "G01"))
      assert Enum.all?(fixed_epoch.residuals_m, &is_number(&1.phase_normalized))

      for {sat, expected_cycles} <- Map.delete(@fixed_cycles, "G01") do
        assert Map.fetch!(sol.fixed_ambiguities_cycles, sat) == expected_cycles
      end
    end

    test "AR arming gate withholds fixes until the baseline posterior converges" do
      ambiguities_m =
        Map.new(@fixed_cycles, fn {sat, cycles} -> {sat, cycles * @l1_wavelength_m} end)

      epochs =
        @sat_positions
        |> Enum.with_index()
        |> Enum.map(fn {positions, idx} ->
          synthetic_baseline_epoch(@base, @truth_baseline, positions,
            epoch: idx,
            base_clock_m: 15.0 + idx,
            rover_clock_m: -8.0 + idx,
            ambiguities_m: ambiguities_m
          )
        end)

      opts = [
        reference_satellite_id: "G01",
        ambiguity_wavelength_m: @l1_wavelength_m,
        initial_baseline_m: {-40.0, 35.0, 12.0},
        filter_kernel: :elixir
      ]

      # Without the gate the synthetic arc fixes.
      assert {:ok, armed_off} = RTK.solve_filter_baseline_epochs(@base, epochs, opts)
      assert armed_off.metadata.first_fixed_index != nil
      assert armed_off.metadata.fixed_epoch_count > 0

      # A threshold below any achievable baseline posterior sigma withholds every
      # fix, yet the filter still solves and returns the float baseline.
      assert {:ok, armed_tight} =
               RTK.solve_filter_baseline_epochs(
                 @base,
                 epochs,
                 opts ++ [ar_arming_sigma_m: 1.0e-9]
               )

      assert armed_tight.metadata.first_fixed_index == nil
      assert armed_tight.metadata.fixed_epoch_count == 0
      assert Enum.all?(armed_tight.epochs, &(&1.integer_status != :fixed))

      # A threshold far above any sigma leaves the always-armed behavior intact.
      assert {:ok, armed_loose} =
               RTK.solve_filter_baseline_epochs(@base, epochs, opts ++ [ar_arming_sigma_m: 1.0e3])

      assert armed_loose.metadata.first_fixed_index == armed_off.metadata.first_fixed_index
      assert armed_loose.fixed_ambiguities_cycles == armed_off.fixed_ambiguities_cycles

      # Default-flip decision record (arming-default-spec.md /
      # arming-default-measurement-2026-06.md): a wavelength-tied default was
      # measured against the clean Wettzell static and kinematic arcs and
      # regresses them (first-fix 0 -> 42, fixed 120/120 -> 78/120 static), so
      # the default is NOT flipped and stays opt-in. This arc demonstrates the
      # hazard the decision turns on: a quarter-L1-wavelength threshold delays
      # the first fix on this clean, fast-converging arc relative to the unset
      # default, which is exactly why one global default cannot serve both arc
      # classes.
      quarter_l1_wl = @l1_wavelength_m / 4.0

      assert {:ok, armed_quarter_wl} =
               RTK.solve_filter_baseline_epochs(
                 @base,
                 epochs,
                 opts ++ [ar_arming_sigma_m: quarter_l1_wl]
               )

      assert is_integer(armed_off.metadata.first_fixed_index)

      assert armed_quarter_wl.metadata.first_fixed_index == nil or
               armed_quarter_wl.metadata.first_fixed_index >
                 armed_off.metadata.first_fixed_index
    end

    test "AR arming gate rejects bad values and is accepted by both kernels" do
      epoch = synthetic_baseline_epoch(@base, @truth_baseline, hd(@sat_positions))

      assert RTK.solve_filter_baseline_epochs(@base, [epoch],
               ambiguity_wavelength_m: @l1_wavelength_m,
               ar_arming_sigma_m: 0.0
             ) == {:error, {:invalid_option, :ar_arming_sigma_m}}

      assert RTK.solve_filter_baseline_epochs(@base, [epoch],
               ambiguity_wavelength_m: @l1_wavelength_m,
               ar_arming_sigma_m: -1.0
             ) == {:error, {:invalid_option, :ar_arming_sigma_m}}

      assert {:ok, _} =
               RTK.solve_filter_baseline_epochs(@base, [epoch],
                 ambiguity_wavelength_m: @l1_wavelength_m,
                 filter_kernel: :rust,
                 ar_arming_sigma_m: 0.05
               )
    end

    test "Rust filter kernel matches the Elixir sequential filter" do
      ambiguities_m =
        Map.new(@fixed_cycles, fn {sat, cycles} -> {sat, cycles * @l1_wavelength_m} end)

      epochs =
        @sat_positions
        |> Enum.with_index()
        |> Enum.map(fn {positions, idx} ->
          synthetic_baseline_epoch(@base, @truth_baseline, positions,
            epoch: idx,
            base_clock_m: 15.0 + idx,
            rover_clock_m: -8.0 + idx,
            ambiguities_m: ambiguities_m
          )
        end)

      opts = [
        reference_satellite_id: "G01",
        ambiguity_wavelength_m: @l1_wavelength_m,
        initial_baseline_m: {-40.0, 35.0, 12.0}
      ]

      assert {:ok, elixir_sol} =
               RTK.solve_filter_baseline_epochs(@base, epochs, opts ++ [filter_kernel: :elixir])

      assert {:ok, rust_sol} =
               RTK.solve_filter_baseline_epochs(@base, epochs, opts ++ [filter_kernel: :rust])

      assert elixir_sol.metadata.filter_kernel == :elixir
      assert rust_sol.metadata.filter_kernel == :rust
      assert rust_sol.metadata.first_fixed_index == elixir_sol.metadata.first_fixed_index
      assert rust_sol.metadata.fixed_epoch_count == elixir_sol.metadata.fixed_epoch_count
      assert rust_sol.fixed_ambiguities_cycles == elixir_sol.fixed_ambiguities_cycles
      assert length(rust_sol.epochs) == length(elixir_sol.epochs)

      for {rust_epoch, elixir_epoch} <- Enum.zip(rust_sol.epochs, elixir_sol.epochs) do
        assert rust_epoch.index == elixir_epoch.index
        assert rust_epoch.integer_status == elixir_epoch.integer_status
        assert rust_epoch.newly_fixed_ambiguities == elixir_epoch.newly_fixed_ambiguities
        assert rust_epoch.fixed_ambiguities == elixir_epoch.fixed_ambiguities
        assert ecef_delta_norm(rust_epoch.baseline_m, elixir_epoch.baseline_m) < 1.0e-6

        if is_number(rust_epoch.integer_ratio) and is_number(elixir_epoch.integer_ratio) do
          assert abs(rust_epoch.integer_ratio - elixir_epoch.integer_ratio) < 1.0e-6
        end
      end

      assert ecef_delta_norm(rust_sol.baseline_m, elixir_sol.baseline_m) < 1.0e-6
      assert position_error(rust_sol.baseline_m, @truth_baseline) < 2.0e-4
    end

    test "velocity-propagated dynamics stays bit-exact across filter kernels" do
      velocity_mps = {0.45, -0.2, 0.12}

      ambiguities_m =
        Map.new(@fixed_cycles, fn {sat, cycles} -> {sat, cycles * @l1_wavelength_m} end)

      epochs =
        [0.0, 1.0, 2.0, 3.0]
        |> Enum.with_index()
        |> Enum.map(fn {t, idx} ->
          baseline = add3(@truth_baseline, scale3(velocity_mps, t))
          positions = Enum.at(@sat_positions, rem(idx, length(@sat_positions)))

          synthetic_baseline_epoch(@base, baseline, positions,
            epoch: t,
            velocity_mps: velocity_mps,
            base_clock_m: 15.0 + idx,
            rover_clock_m: -8.0 + idx,
            ambiguities_m: ambiguities_m
          )
        end)

      opts = [
        reference_satellite_id: "G01",
        ambiguity_wavelength_m: @l1_wavelength_m,
        initial_baseline_m: @truth_baseline,
        process_noise_baseline_sigma_m: 0.5,
        dynamics_model: :velocity_propagated
      ]

      assert {:ok, elixir_sol} =
               RTK.solve_filter_baseline_epochs(@base, epochs, opts ++ [filter_kernel: :elixir])

      assert {:ok, rust_sol} =
               RTK.solve_filter_baseline_epochs(@base, epochs, opts ++ [filter_kernel: :rust])

      assert elixir_sol.metadata.dynamics_model == :velocity_propagated
      assert rust_sol.metadata.dynamics_model == :velocity_propagated
      assert rust_sol.metadata.fixed_epoch_count == elixir_sol.metadata.fixed_epoch_count
      assert rust_sol.fixed_ambiguities_cycles == elixir_sol.fixed_ambiguities_cycles
      assert_exact_ecef_map(rust_sol.baseline_m, elixir_sol.baseline_m)

      for {rust_epoch, elixir_epoch} <- Enum.zip(rust_sol.epochs, elixir_sol.epochs) do
        assert rust_epoch.index == elixir_epoch.index
        assert rust_epoch.integer_status == elixir_epoch.integer_status
        assert rust_epoch.newly_fixed_ambiguities == elixir_epoch.newly_fixed_ambiguities
        assert rust_epoch.fixed_ambiguities == elixir_epoch.fixed_ambiguities
        assert_exact_ecef_map(rust_epoch.baseline_m, elixir_epoch.baseline_m)

        if is_number(rust_epoch.integer_ratio) and is_number(elixir_epoch.integer_ratio) do
          assert rust_epoch.integer_ratio === elixir_epoch.integer_ratio
        else
          assert rust_epoch.integer_ratio == elixir_epoch.integer_ratio
        end
      end
    end

    test "velocity-propagated dynamics requires comparable epoch times after the first" do
      velocity_mps = {0.45, -0.2, 0.12}

      opts = [
        reference_satellite_id: "G01",
        ambiguity_wavelength_m: @l1_wavelength_m,
        initial_baseline_m: @truth_baseline,
        dynamics_model: :velocity_propagated
      ]

      missing_times =
        @sat_positions
        |> Enum.take(2)
        |> Enum.map(fn positions ->
          synthetic_baseline_epoch(@base, @truth_baseline, positions, velocity_mps: velocity_mps)
        end)

      assert RTK.solve_filter_baseline_epochs(@base, missing_times, opts) ==
               {:error, {:invalid_epoch_time, 1}}

      incompatible_times = [
        synthetic_baseline_epoch(@base, @truth_baseline, hd(@sat_positions),
          epoch: 0.0,
          velocity_mps: velocity_mps
        ),
        synthetic_baseline_epoch(@base, @truth_baseline, Enum.at(@sat_positions, 1),
          epoch: ~N[2026-01-01 00:00:01],
          velocity_mps: velocity_mps
        )
      ]

      assert RTK.solve_filter_baseline_epochs(@base, incompatible_times, opts) ==
               {:error, {:invalid_epoch_time, 1}}
    end

    test "innovation screen stays bit-exact across filter kernels and fires" do
      ambiguities_m =
        Map.new(@fixed_cycles, fn {sat, cycles} -> {sat, cycles * @l1_wavelength_m} end)

      # G05 takes a hard code bias on epoch 2 only: the screen must REJECT its
      # rows there (a gate that never fires the branch proves nothing).
      epochs =
        for idx <- 0..4 do
          positions = Enum.at(@sat_positions, rem(idx, length(@sat_positions)))

          synthetic_baseline_epoch(@base, @truth_baseline, positions,
            epoch: idx,
            base_clock_m: 15.0 + idx,
            rover_clock_m: -8.0 + idx,
            ambiguities_m: ambiguities_m
          )
        end
        |> List.update_at(2, fn epoch ->
          [bumped] = add_rover_code_noise([epoch], %{"G05" => [60.0]})
          bumped
        end)

      opts = [
        reference_satellite_id: "G01",
        ambiguity_wavelength_m: @l1_wavelength_m,
        initial_baseline_m: @truth_baseline,
        innovation_screen_sigma: 10.0,
        innovation_screen_min_rows: 4
      ]

      assert {:ok, elixir_sol} =
               RTK.solve_filter_baseline_epochs(@base, epochs, opts ++ [filter_kernel: :elixir])

      assert {:ok, rust_sol} =
               RTK.solve_filter_baseline_epochs(@base, epochs, opts ++ [filter_kernel: :rust])

      # The screen demonstrably fired: epoch 2 rejected G05's biased rows.
      elixir_fired = Enum.find(elixir_sol.epochs, &(&1.innovation_screen.rejected_rows > 0))
      assert elixir_fired, "screen never fired on the elixir path"
      assert elixir_fired.index == 2

      assert rust_sol.fixed_ambiguities_cycles == elixir_sol.fixed_ambiguities_cycles
      assert_exact_ecef_map(rust_sol.baseline_m, elixir_sol.baseline_m)

      for {rust_epoch, elixir_epoch} <- Enum.zip(rust_sol.epochs, elixir_sol.epochs) do
        assert rust_epoch.index == elixir_epoch.index
        assert rust_epoch.integer_status == elixir_epoch.integer_status
        assert rust_epoch.fixed_ambiguities == elixir_epoch.fixed_ambiguities
        assert_exact_ecef_map(rust_epoch.baseline_m, elixir_epoch.baseline_m)
        # The screen metadata itself is part of the contract: counts exact,
        # normalized-innovation extrema bit-equal.
        assert rust_epoch.innovation_screen == elixir_epoch.innovation_screen

        if is_number(rust_epoch.integer_ratio) and is_number(elixir_epoch.integer_ratio) do
          assert rust_epoch.integer_ratio === elixir_epoch.integer_ratio
        else
          assert rust_epoch.integer_ratio == elixir_epoch.integer_ratio
        end
      end
    end

    test "innovation screen coasts bit-exactly across filter kernels" do
      ambiguities_m =
        Map.new(@fixed_cycles, fn {sat, cycles} -> {sat, cycles * @l1_wavelength_m} end)

      epochs =
        for idx <- 0..3 do
          positions = Enum.at(@sat_positions, rem(idx, length(@sat_positions)))

          synthetic_baseline_epoch(@base, @truth_baseline, positions,
            epoch: idx,
            base_clock_m: 15.0 + idx,
            rover_clock_m: -8.0 + idx,
            ambiguities_m: ambiguities_m
          )
        end
        |> List.update_at(3, fn epoch ->
          # Every non-reference satellite biased hard: with the default
          # min-rows floor, the epoch must coast on both kernels.
          [bumped] =
            add_rover_code_noise([epoch], %{
              "G02" => [80.0],
              "G03" => [-90.0],
              "G04" => [70.0],
              "G05" => [-75.0]
            })

          bumped
        end)

      opts = [
        reference_satellite_id: "G01",
        ambiguity_wavelength_m: @l1_wavelength_m,
        initial_baseline_m: @truth_baseline,
        innovation_screen_sigma: 8.0
      ]

      assert {:ok, elixir_sol} =
               RTK.solve_filter_baseline_epochs(@base, epochs, opts ++ [filter_kernel: :elixir])

      assert {:ok, rust_sol} =
               RTK.solve_filter_baseline_epochs(@base, epochs, opts ++ [filter_kernel: :rust])

      coasted = Enum.find(elixir_sol.epochs, &(&1.integer_status == :coasted))
      assert coasted, "no epoch coasted on the elixir path"
      assert coasted.innovation_screen.coasted?

      for {rust_epoch, elixir_epoch} <- Enum.zip(rust_sol.epochs, elixir_sol.epochs) do
        assert rust_epoch.integer_status == elixir_epoch.integer_status
        assert rust_epoch.innovation_screen == elixir_epoch.innovation_screen
        assert_exact_ecef_map(rust_epoch.baseline_m, elixir_epoch.baseline_m)
      end
    end

    test "re-initializes the ambiguity of a satellite that sets and re-rises" do
      ref = "G01"
      sats = ["G01", "G02", "G03", "G04", "G05"]
      base_positions = hd(@sat_positions)

      others_m = %{
        "G02" => 5 * @l1_wavelength_m,
        "G03" => -7 * @l1_wavelength_m,
        "G04" => 12 * @l1_wavelength_m
      }

      # G05's carrier integer changes across the outage (lock lost): -4 -> +9.
      g05_pre_m = -4 * @l1_wavelength_m
      g05_post_m = 9 * @l1_wavelength_m

      epochs =
        for idx <- 0..14 do
          positions =
            Map.new(sats, fn sat ->
              {x, y, z} = Map.fetch!(base_positions, sat)
              {sat, {x + idx * 1_000.0, y - idx * 800.0, z + idx * 1_200.0}}
            end)

          {positions, ambiguities_m} =
            cond do
              # G05 has set below the horizon for three epochs.
              idx in 6..8 -> {Map.delete(positions, "G05"), others_m}
              idx <= 5 -> {positions, Map.put(others_m, "G05", g05_pre_m)}
              # Re-risen with a DIFFERENT integer and NO loss-of-lock flag.
              true -> {positions, Map.put(others_m, "G05", g05_post_m)}
            end

          synthetic_baseline_epoch(@base, @truth_baseline, positions,
            epoch: idx,
            base_clock_m: 15.0 + idx,
            rover_clock_m: -8.0 + idx,
            ambiguities_m: ambiguities_m
          )
        end

      for kernel <- [:elixir, :rust] do
        assert {:ok, sol} =
                 RTK.solve_filter_baseline_epochs(@base, epochs,
                   reference_satellite_id: ref,
                   ambiguity_wavelength_m: @l1_wavelength_m,
                   initial_baseline_m: {-40.0, 35.0, 12.0},
                   filter_kernel: kernel
                 )

        # A stale G05 ambiguity held from the pre-outage arc (N=-4) conflicts with
        # the post-outage truth (N=+9); if the filter does not start a fresh arc on
        # re-rise it corrupts the static baseline.
        assert position_error(sol.baseline_m, @truth_baseline) < 1.0e-3

        # G05 must resolve as TWO separate ambiguity arcs: the pre-outage arc keeps
        # its true integer (-4) and the post-outage arc resolves to its own true
        # integer (+9). With the stale-carry bug, G05 stays a single arc pinned to
        # -4 and the baseline is corrupted (asserted above).
        g05_fixed =
          for {id, cycles} <- sol.fixed_ambiguities_cycles,
              String.starts_with?(id, "G05"),
              do: cycles

        assert Enum.sort(g05_fixed) == [-4, 9]
      end
    end

    test "bad filter options are tagged" do
      epoch = synthetic_baseline_epoch(@base, @truth_baseline, hd(@sat_positions))

      assert RTK.solve_filter_baseline_epochs(@base, [epoch]) ==
               {:error, :ambiguity_wavelength_required}

      assert RTK.solve_filter_baseline_epochs(@base, [epoch],
               ambiguity_wavelength_m: @l1_wavelength_m,
               baseline_prior_sigma_m: 0.0
             ) == {:error, {:invalid_option, :baseline_prior_sigma_m}}

      assert RTK.solve_filter_baseline_epochs(@base, [epoch],
               ambiguity_wavelength_m: @l1_wavelength_m,
               ambiguity_prior_sigma_m: -1.0
             ) == {:error, {:invalid_option, :ambiguity_prior_sigma_m}}

      assert RTK.solve_filter_baseline_epochs(@base, [epoch],
               ambiguity_wavelength_m: @l1_wavelength_m,
               hold_sigma_m: :bad
             ) == {:error, {:invalid_option, :hold_sigma_m}}

      assert RTK.solve_filter_baseline_epochs(@base, [epoch],
               ambiguity_wavelength_m: @l1_wavelength_m,
               partial_ambiguity_resolution: true
             ) == {:error, {:unsupported_option, :partial_ambiguity_resolution}}

      assert RTK.solve_filter_baseline_epochs(@base, [epoch],
               ambiguity_wavelength_m: @l1_wavelength_m,
               filter_kernel: :python
             ) == {:error, {:invalid_option, :filter_kernel}}

      assert RTK.solve_filter_baseline_epochs(@base, [epoch],
               ambiguity_wavelength_m: @l1_wavelength_m,
               dynamics_model: :bad
             ) == {:error, {:invalid_option, :dynamics_model}}

      assert RTK.solve_filter_baseline_epochs(@base, [epoch],
               ambiguity_wavelength_m: @l1_wavelength_m,
               innovation_screen_sigma: 0.0
             ) == {:error, {:invalid_option, :innovation_screen_sigma}}

      assert RTK.solve_filter_baseline_epochs(@base, [epoch],
               ambiguity_wavelength_m: @l1_wavelength_m,
               innovation_screen_min_rows: 0
             ) == {:error, {:invalid_option, :innovation_screen_min_rows}}

      assert RTK.solve_filter_baseline_epochs(
               @base,
               [Map.put(epoch, :velocity_mps, {1.0, :bad, 0.0})],
               ambiguity_wavelength_m: @l1_wavelength_m
             ) == {:error, {:invalid_velocity_mps, 0}}
    end

    test "elixir filter applies up-only receiver antenna corrections" do
      base_pco_up_m = 0.10
      rover_pco_up_m = 0.05

      epochs =
        @sat_positions
        |> Enum.take(3)
        |> Enum.map(fn positions ->
          synthetic_baseline_epoch(@base, @truth_baseline, positions)
        end)
        |> Enum.map(
          &apply_receiver_antenna_corrections_to_epoch(
            &1,
            base_pco_up_m,
            rover_pco_up_m
          )
        )

      assert {:ok, sol} =
               RTK.solve_filter_baseline_epochs(
                 @base,
                 epochs,
                 reference_satellite_id: "G01",
                 ambiguity_wavelength_m: @l1_wavelength_m,
                 initial_baseline_m: {-40.0, 35.0, 12.0},
                 filter_kernel: :elixir,
                 receiver_antenna_corrections:
                   receiver_antenna_corrections_option(base_pco_up_m, rover_pco_up_m)
               )

      assert sol.metadata.filter_kernel == :elixir
      assert position_error(sol.baseline_m, @truth_baseline) < 2.0e-4
    end

    test "Rust filter kernel matches Elixir with up-only receiver antenna corrections" do
      base_pco_up_m = 0.10
      rover_pco_up_m = 0.05

      epochs =
        @sat_positions
        |> Enum.take(3)
        |> Enum.map(fn positions ->
          synthetic_baseline_epoch(@base, @truth_baseline, positions)
        end)
        |> Enum.map(
          &apply_receiver_antenna_corrections_to_epoch(
            &1,
            base_pco_up_m,
            rover_pco_up_m
          )
        )

      opts = [
        reference_satellite_id: "G01",
        ambiguity_wavelength_m: @l1_wavelength_m,
        initial_baseline_m: {-40.0, 35.0, 12.0},
        receiver_antenna_corrections:
          receiver_antenna_corrections_option(base_pco_up_m, rover_pco_up_m)
      ]

      assert {:ok, elixir_sol} =
               RTK.solve_filter_baseline_epochs(@base, epochs, opts ++ [filter_kernel: :elixir])

      assert {:ok, rust_sol} =
               RTK.solve_filter_baseline_epochs(@base, epochs, opts ++ [filter_kernel: :rust])

      assert_filter_kernel_trace_exact(rust_sol, elixir_sol)
    end
  end

  describe "solve_widelane_fixed_baseline_epochs/3" do
    test "fixes wide-lane then narrow-lane DD ambiguities" do
      epochs =
        @sat_positions
        |> Enum.with_index()
        |> Enum.map(fn {positions, idx} ->
          synthetic_dual_baseline_epoch(@base, @truth_baseline, positions,
            epoch: idx,
            base_clock_m: 70.0 - idx,
            rover_clock_m: -31.0 + 2.0 * idx,
            n1_cycles: @fixed_cycles,
            wide_lane_cycles: @wide_lane_cycles
          )
        end)

      assert {:ok, sol} =
               RTK.solve_widelane_fixed_baseline_epochs(@base, epochs,
                 reference_satellite_id: "G01",
                 initial_baseline_m: {-40.0, 35.0, 12.0},
                 wide_lane_tolerance_cycles: 0.01,
                 troposphere: false
               )

      assert sol.metadata.integer_status == :fixed
      assert sol.metadata.integer_method == :widelane_narrowlane_lambda
      assert sol.metadata.wide_lane_fixed
      assert sol.wide_lane_ambiguities_cycles == Map.delete(@wide_lane_cycles, "G01")
      assert sol.metadata.wide_lane_ambiguities_cycles == sol.wide_lane_ambiguities_cycles
      assert sol.metadata.ambiguity_offsets_m == expected_narrow_lane_offsets(@wide_lane_cycles)
      assert position_error(sol.baseline_m, @truth_baseline) < 1.0e-5

      for sat <- sol.used_sats do
        assert Map.fetch!(sol.fixed_ambiguities_cycles, sat) == Map.fetch!(@fixed_cycles, sat)

        expected_m =
          narrow_lane_offset_m(Map.fetch!(@wide_lane_cycles, sat)) +
            Map.fetch!(@fixed_cycles, sat) * @narrow_lane_wavelength_m

        assert abs(Map.fetch!(sol.fixed_ambiguities_m, sat) - expected_m) < 1.0e-9
      end
    end

    test "re-initializes the wide-lane and narrow-lane ambiguity of a satellite that sets and re-rises" do
      ref = "G01"
      sats = ["G01", "G02", "G03", "G04", "G05"]
      base_positions = hd(@sat_positions)

      others_n1 = %{"G02" => 5, "G03" => -7, "G04" => 12}
      others_wl = %{"G02" => 3, "G03" => -5, "G04" => 8}

      # G05's carrier integers change across the outage (lock lost):
      # pre-outage n1=-4 / wide-lane=-2, post-outage n1=9 / wide-lane=6.
      g05_pre_n1 = -4
      g05_pre_wl = -2
      g05_post_n1 = 9
      g05_post_wl = 6

      epochs =
        for idx <- 0..14 do
          positions =
            Map.new(sats, fn sat ->
              {x, y, z} = Map.fetch!(base_positions, sat)
              {sat, {x + idx * 1_000.0, y - idx * 800.0, z + idx * 1_200.0}}
            end)

          {positions, n1_cycles, wide_lane_cycles} =
            cond do
              # G05 has set below the horizon for three epochs.
              idx in 6..8 ->
                {Map.delete(positions, "G05"), Map.put(others_n1, "G01", 0),
                 Map.put(others_wl, "G01", 0)}

              idx <= 5 ->
                {positions, others_n1 |> Map.put("G01", 0) |> Map.put("G05", g05_pre_n1),
                 others_wl |> Map.put("G01", 0) |> Map.put("G05", g05_pre_wl)}

              # Re-risen with DIFFERENT integers and NO loss-of-lock flag.
              true ->
                {positions, others_n1 |> Map.put("G01", 0) |> Map.put("G05", g05_post_n1),
                 others_wl |> Map.put("G01", 0) |> Map.put("G05", g05_post_wl)}
            end

          synthetic_dual_baseline_epoch(@base, @truth_baseline, positions,
            epoch: idx,
            base_clock_m: 70.0 - idx,
            rover_clock_m: -31.0 + 2.0 * idx,
            n1_cycles: n1_cycles,
            wide_lane_cycles: wide_lane_cycles
          )
        end

      assert {:ok, sol} =
               RTK.solve_widelane_fixed_baseline_epochs(@base, epochs,
                 reference_satellite_id: ref,
                 initial_baseline_m: {-40.0, 35.0, 12.0},
                 wide_lane_tolerance_cycles: 0.01,
                 # Disable threshold-based slip detection so the only arc break is
                 # the G05 outage gap (which is detected independently of LLI).
                 gf_threshold_m: 1.0e9,
                 mw_threshold_cycles: 1.0e9,
                 troposphere: false
               )

      assert sol.metadata.integer_status == :fixed

      # A stale G05 ambiguity held from the pre-outage arc conflicts with the
      # post-outage truth; if the wide-lane prep does not start a fresh arc on
      # re-rise the offset map keys diverge and the post-outage arc silently
      # inherits the pre-outage offset, corrupting the static baseline.
      assert position_error(sol.baseline_m, @truth_baseline) < 1.0e-3

      # G05 must resolve as TWO separate arcs, each fixing to its own true
      # integers: narrow-lane n1 {-4, 9} and wide-lane {-2, 6}.
      g05_ids = Enum.filter(sol.used_sats, &String.contains?(&1, "G05"))
      assert length(g05_ids) == 2

      assert g05_ids
             |> Enum.map(&Map.fetch!(sol.fixed_ambiguities_cycles, &1))
             |> Enum.sort() == [-4, 9]

      assert g05_ids
             |> Enum.map(&Map.fetch!(sol.wide_lane_ambiguities_cycles, &1))
             |> Enum.sort() == [-2, 6]
    end

    test "can split dual-frequency ambiguity arcs at cycle slips" do
      epochs =
        @sat_positions
        |> Enum.with_index()
        |> Enum.map(fn {positions, idx} ->
          {n1_cycles, wide_lane_cycles} =
            if idx == 0 do
              {@fixed_cycles, @wide_lane_cycles}
            else
              {
                Map.put(@fixed_cycles, "G02", 9),
                Map.put(@wide_lane_cycles, "G02", 6)
              }
            end

          epoch =
            synthetic_dual_baseline_epoch(@base, @truth_baseline, positions,
              epoch: idx,
              n1_cycles: n1_cycles,
              wide_lane_cycles: wide_lane_cycles
            )

          if idx == 1, do: mark_dual_rover_lli(epoch, "G02", 1), else: epoch
        end)

      assert {:ok, sol} =
               RTK.solve_widelane_fixed_baseline_epochs(@base, epochs,
                 reference_satellite_id: "G01",
                 on_cycle_slip: :split_arc,
                 wide_lane_min_epochs: 1,
                 wide_lane_tolerance_cycles: 0.01,
                 initial_baseline_m: {-40.0, 35.0, 12.0},
                 troposphere: false
               )

      g02_ids = Enum.filter(sol.used_sats, &String.contains?(&1, "G02"))
      assert length(g02_ids) == 2
      assert sol.metadata.integer_status == :fixed
      assert length(sol.metadata.split_cycle_slip_arcs) == 2

      assert g02_ids
             |> Enum.map(&Map.fetch!(sol.fixed_ambiguities_cycles, &1))
             |> Enum.sort() == [5, 9]

      assert g02_ids
             |> Enum.map(&Map.fetch!(sol.wide_lane_ambiguities_cycles, &1))
             |> Enum.sort() == [3, 6]

      assert position_error(sol.baseline_m, @truth_baseline) < 1.0e-5
    end

    test "split-arc dual-frequency solve skips short fragments and keeps valid fragments" do
      epochs =
        @sat_positions
        |> Enum.with_index()
        |> Enum.map(fn {positions, idx} ->
          {n1_cycles, wide_lane_cycles} =
            if idx == 0 do
              {@fixed_cycles, @wide_lane_cycles}
            else
              {
                Map.put(@fixed_cycles, "G02", 9),
                Map.put(@wide_lane_cycles, "G02", 6)
              }
            end

          epoch =
            synthetic_dual_baseline_epoch(@base, @truth_baseline, positions,
              epoch: idx,
              n1_cycles: n1_cycles,
              wide_lane_cycles: wide_lane_cycles
            )

          if idx == 1, do: mark_dual_rover_lli(epoch, "G02", 1), else: epoch
        end)

      assert {:ok, sol} =
               RTK.solve_widelane_fixed_baseline_epochs(@base, epochs,
                 reference_satellite_id: "G01",
                 on_cycle_slip: :split_arc,
                 wide_lane_min_epochs: 2,
                 wide_lane_tolerance_cycles: 0.01,
                 initial_baseline_m: {-40.0, 35.0, 12.0},
                 troposphere: false
               )

      g02_ids = Enum.filter(sol.used_sats, &String.contains?(&1, "G02"))
      assert g02_ids == ["G02@rover#2|ref=G01"]
      assert sol.metadata.integer_status == :fixed
      refute Map.has_key?(sol.wide_lane_ambiguities_cycles, "G02")
      assert sol.wide_lane_ambiguities_cycles["G02@rover#2|ref=G01"] == 6
      assert position_error(sol.baseline_m, @truth_baseline) < 1.0e-5
    end

    test "multi-GNSS dual-frequency input is rejected before wide-lane estimation" do
      e_wide_lane_cycles = %{"E02" => 2, "E11" => -3, "E19" => 1}

      epochs =
        @sat_positions
        |> Enum.zip(@extra_sat_positions)
        |> Enum.with_index()
        |> Enum.map(fn {{g_positions, extra_positions}, idx} ->
          positions =
            extra_positions
            |> Map.take(Map.keys(@e_cycles))
            |> Map.merge(g_positions)

          synthetic_dual_baseline_epoch(@base, @truth_baseline, positions,
            epoch: idx,
            n1_cycles: Map.merge(@fixed_cycles, @e_cycles),
            wide_lane_cycles: Map.merge(@wide_lane_cycles, e_wide_lane_cycles)
          )
        end)

      assert RTK.solve_widelane_fixed_baseline_epochs(@base, epochs,
               reference_satellite_id: "G01"
             ) == {:error, {:unsupported_widelane, :multi_gnss}}
    end

    test "bad dual-frequency inputs are tagged" do
      epoch =
        synthetic_dual_baseline_epoch(@base, @truth_baseline, hd(@sat_positions),
          n1_cycles: @fixed_cycles,
          wide_lane_cycles: @wide_lane_cycles
        )

      assert RTK.solve_widelane_fixed_baseline_epochs(@base, []) == {:error, :no_epochs}

      malformed =
        update_in(epoch.base_observations, fn observations ->
          Enum.map(observations, fn
            %{satellite_id: "G02"} = obs -> %{obs | f2_hz: @f_l1}
            obs -> obs
          end)
        end)

      assert {:error, {:wide_lane_failed, "G02", :equal_frequencies}} =
               RTK.solve_widelane_fixed_baseline_epochs(@base, [malformed],
                 reference_satellite_id: "G01"
               )

      assert RTK.solve_widelane_fixed_baseline_epochs(@base, [epoch], wide_lane_min_epochs: 0) ==
               {:error, {:invalid_option, :wide_lane_min_epochs}}

      assert RTK.solve_widelane_fixed_baseline_epochs(@base, [epoch],
               ambiguity_wavelength_m: @l1_wavelength_m
             ) == {:error, {:invalid_option, :ambiguity_wavelength_m}}
    end
  end

  describe "solve_widelane_filter_baseline_epochs/3" do
    test "sequentially fixes narrow-lane DDs with wide-lane fixed up front" do
      epochs =
        @sat_positions
        |> Enum.with_index()
        |> Enum.map(fn {positions, idx} ->
          synthetic_dual_baseline_epoch(@base, @truth_baseline, positions,
            epoch: idx,
            base_clock_m: 70.0 - idx,
            rover_clock_m: -31.0 + 2.0 * idx,
            n1_cycles: @fixed_cycles,
            wide_lane_cycles: @wide_lane_cycles
          )
        end)

      assert {:ok, sol} =
               RTK.solve_widelane_filter_baseline_epochs(@base, epochs,
                 reference_satellite_id: "G01",
                 initial_baseline_m: {-40.0, 35.0, 12.0},
                 wide_lane_tolerance_cycles: 0.01,
                 filter_kernel: :elixir,
                 troposphere: false
               )

      assert sol.metadata.integer_method == :widelane_narrowlane_sequential
      assert sol.metadata.wide_lane_fixed
      assert sol.metadata.wide_lane_ambiguities_cycles == Map.delete(@wide_lane_cycles, "G01")

      # The whole arc is well-conditioned synthetic data; every epoch fixes and
      # the held baseline lands on truth.
      assert sol.metadata.fixed_epoch_count == length(epochs)
      assert List.last(sol.epochs).integer_status == :fixed
      assert position_error(sol.baseline_m, @truth_baseline) < 1.0e-3
    end

    test "wide-lane filter is additive: single-frequency filter is unaffected" do
      # The new entry point shares the sequential machinery but the single
      # frequency path keeps its scalar-wavelength contract unchanged.
      dual_epochs =
        @sat_positions
        |> Enum.with_index()
        |> Enum.map(fn {positions, idx} ->
          synthetic_dual_baseline_epoch(@base, @truth_baseline, positions,
            epoch: idx,
            n1_cycles: @fixed_cycles,
            wide_lane_cycles: @wide_lane_cycles
          )
        end)

      assert {:ok, dual} =
               RTK.solve_widelane_filter_baseline_epochs(@base, dual_epochs,
                 reference_satellite_id: "G01",
                 wide_lane_tolerance_cycles: 0.01,
                 filter_kernel: :elixir,
                 troposphere: false
               )

      assert dual.metadata.integer_method == :widelane_narrowlane_sequential

      # The wide-lane filter derives the ambiguity wavelength internally, so a
      # caller may not pass it.
      assert RTK.solve_widelane_filter_baseline_epochs(@base, dual_epochs,
               ambiguity_wavelength_m: @l1_wavelength_m
             ) == {:error, {:invalid_option, :ambiguity_wavelength_m}}
    end

    test "multi-GNSS dual-frequency input is rejected before wide-lane estimation" do
      e_wide_lane_cycles = %{"E02" => 2, "E11" => -3, "E19" => 1}

      epochs =
        @sat_positions
        |> Enum.zip(@extra_sat_positions)
        |> Enum.with_index()
        |> Enum.map(fn {{g_positions, extra_positions}, idx} ->
          positions =
            extra_positions
            |> Map.take(Map.keys(@e_cycles))
            |> Map.merge(g_positions)

          synthetic_dual_baseline_epoch(@base, @truth_baseline, positions,
            epoch: idx,
            n1_cycles: Map.merge(@fixed_cycles, @e_cycles),
            wide_lane_cycles: Map.merge(@wide_lane_cycles, e_wide_lane_cycles)
          )
        end)

      assert RTK.solve_widelane_filter_baseline_epochs(@base, epochs,
               reference_satellite_id: "G01"
             ) == {:error, {:unsupported_widelane, :multi_gnss}}
    end

    test "bad inputs are tagged" do
      assert RTK.solve_widelane_filter_baseline_epochs(@base, []) == {:error, :no_epochs}
      assert RTK.solve_widelane_filter_baseline_epochs(@base, :nope) == {:error, :invalid_epochs}
    end
  end

  describe "multi-GNSS per-system references" do
    test "fixed solve recovers per-system references and exact DD integers across G+E" do
      epochs = multignss_epochs(["G", "E"])

      assert {:ok, sol} =
               RTK.solve_fixed_baseline_epochs(@base, epochs,
                 ambiguity_wavelength_m: multignss_wavelengths(),
                 initial_baseline_m: {-40.0, 35.0, 12.0}
               )

      assert %{"G" => g_ref, "E" => e_ref} = sol.metadata.reference_satellites
      assert String.starts_with?(g_ref, "G")
      assert String.starts_with?(e_ref, "E")
      assert sol.reference_satellite_id == sol.metadata.reference_satellites

      assert sol.metadata.integer_status == :fixed
      assert position_error(sol.baseline_m, @truth_baseline) < 1.0e-5

      cycles = Map.merge(@fixed_cycles, @e_cycles)
      refs = sol.metadata.reference_satellites

      assert Enum.sort(sol.used_sats) ==
               Enum.sort(Map.keys(cycles) -- Map.values(refs))

      for sat <- sol.used_sats do
        ref = Map.fetch!(refs, String.first(sat))
        expected = Map.fetch!(cycles, sat) - Map.fetch!(cycles, ref)
        assert Map.fetch!(sol.fixed_ambiguities_cycles, sat) == expected
      end

      # Every residual is differenced against its OWN system's reference.
      for residual <- sol.residuals_m do
        assert residual.reference_satellite_id ==
                 Map.fetch!(refs, String.first(residual.satellite_id))
      end
    end

    test "float-only systems stay out of the fixed set but contribute float rows" do
      epochs = multignss_epochs(["G", "E", "R"])

      assert {:ok, sol} =
               RTK.solve_fixed_baseline_epochs(@base, epochs,
                 ambiguity_wavelength_m: multignss_wavelengths(),
                 float_only_systems: ["R"],
                 initial_baseline_m: {-40.0, 35.0, 12.0}
               )

      assert %{"G" => _, "E" => _, "R" => r_ref} = sol.metadata.reference_satellites
      assert sol.metadata.integer_status == :fixed
      assert position_error(sol.baseline_m, @truth_baseline) < 1.0e-5

      r_used = Enum.filter(sol.used_sats, &String.starts_with?(&1, "R"))
      assert length(r_used) == 2

      # GLONASS ambiguities are never entered into the integer search.
      refute Enum.any?(Map.keys(sol.fixed_ambiguities_cycles), &String.starts_with?(&1, "R"))
      refute Enum.any?(sol.metadata.ambiguity_search.order, &String.starts_with?(&1, "R"))

      # They still resolve as float DD ambiguities in the re-solve.
      for sat <- r_used do
        expected = Map.fetch!(@r_ambiguities_m, sat) - Map.fetch!(@r_ambiguities_m, r_ref)
        assert abs(Map.fetch!(sol.float_solution.ambiguities_m, sat) - expected) < 1.0e-5
      end

      # The fixable systems still fix exactly.
      cycles = Map.merge(@fixed_cycles, @e_cycles)

      for sat <- sol.used_sats -- r_used do
        ref = Map.fetch!(sol.metadata.reference_satellites, String.first(sat))
        expected = Map.fetch!(cycles, sat) - Map.fetch!(cycles, ref)
        assert Map.fetch!(sol.fixed_ambiguities_cycles, sat) == expected
      end
    end

    test "multi-GNSS option validation is tagged" do
      epochs = multignss_epochs(["G", "E"])

      assert RTK.solve_float_baseline_epochs(@base, epochs, reference_satellite_id: "G01") ==
               {:error, {:reference_satellite_single_system, "G01"}}

      assert RTK.solve_float_baseline_epochs(@base, epochs,
               reference_satellite_id: %{"G" => "G01"}
             ) == {:error, {:reference_satellite_missing_system, "E"}}

      assert {:ok, _sol} =
               RTK.solve_float_baseline_epochs(@base, epochs,
                 reference_satellite_id: %{"G" => "G01", "E" => "E02"}
               )

      assert RTK.solve_fixed_baseline_epochs(@base, epochs,
               ambiguity_wavelength_m: multignss_wavelengths(),
               float_only_systems: "R"
             ) == {:error, {:invalid_option, :float_only_systems}}

      assert RTK.solve_fixed_baseline_epochs(@base, epochs,
               ambiguity_wavelength_m: multignss_wavelengths(),
               float_only_systems: ["GR"]
             ) == {:error, {:invalid_option, :float_only_systems}}

      assert RTK.solve_filter_baseline_epochs(@base, epochs,
               ambiguity_wavelength_m: multignss_wavelengths(),
               float_only_systems: [:r]
             ) == {:error, {:invalid_option, :float_only_systems}}
    end

    test "sequential filter fixes G+E per epoch and keeps GLONASS float" do
      epochs = multignss_epochs(["G", "E", "R"])

      assert {:ok, sol} =
               RTK.solve_filter_baseline_epochs(@base, epochs,
                 ambiguity_wavelength_m: multignss_wavelengths(),
                 float_only_systems: ["R"],
                 initial_baseline_m: {-40.0, 35.0, 12.0}
               )

      assert %{"G" => _, "E" => _, "R" => _} = sol.metadata.reference_satellites
      assert sol.metadata.float_only_systems == ["R"]
      assert sol.metadata.filter_kernel == :rust
      assert sol.metadata.fixed_epoch_count > 0
      assert Enum.all?(sol.epochs, &(&1.integer_status in [:fixed, :not_fixed]))
      assert Enum.any?(sol.epochs, &(&1.integer_status == :fixed))

      for epoch <- sol.epochs do
        refute Enum.any?(epoch.fixed_ambiguities, &String.starts_with?(&1, "R"))
      end

      refute Enum.any?(Map.keys(sol.fixed_ambiguities_cycles), &String.starts_with?(&1, "R"))

      # The fixed integers are the per-system DD truth.
      cycles = Map.merge(@fixed_cycles, @e_cycles)

      for {sat, fixed} <- sol.fixed_ambiguities_cycles do
        ref = Map.fetch!(sol.metadata.reference_satellites, String.first(sat))
        assert fixed == Map.fetch!(cycles, sat) - Map.fetch!(cycles, ref)
      end

      assert position_error(sol.baseline_m, @truth_baseline) < 1.0e-3
    end

    test "the Rust filter kernel matches multi-system Elixir filter with float-only systems" do
      epochs = multignss_epochs(["G", "E", "R"])

      opts = [
        ambiguity_wavelength_m: multignss_wavelengths(),
        float_only_systems: ["R"],
        initial_baseline_m: {-40.0, 35.0, 12.0}
      ]

      assert {:ok, elixir_sol} =
               RTK.solve_filter_baseline_epochs(@base, epochs, opts ++ [filter_kernel: :elixir])

      assert {:ok, rust_sol} =
               RTK.solve_filter_baseline_epochs(@base, epochs, opts ++ [filter_kernel: :rust])

      assert elixir_sol.metadata.filter_kernel == :elixir
      assert rust_sol.metadata.filter_kernel == :rust
      assert rust_sol.metadata.reference_satellites == elixir_sol.metadata.reference_satellites
      assert rust_sol.metadata.float_only_systems == ["R"]
      assert rust_sol.metadata.fixed_epoch_count == elixir_sol.metadata.fixed_epoch_count
      assert rust_sol.fixed_ambiguities_cycles == elixir_sol.fixed_ambiguities_cycles
      refute Enum.any?(Map.keys(rust_sol.fixed_ambiguities_cycles), &String.starts_with?(&1, "R"))
      assert position_error(rust_sol.baseline_m, @truth_baseline) < 1.0e-3

      for {rust_epoch, elixir_epoch} <- Enum.zip(rust_sol.epochs, elixir_sol.epochs) do
        assert rust_epoch.index == elixir_epoch.index
        assert rust_epoch.integer_status == elixir_epoch.integer_status
        assert rust_epoch.newly_fixed_ambiguities == elixir_epoch.newly_fixed_ambiguities
        assert rust_epoch.fixed_ambiguities == elixir_epoch.fixed_ambiguities
        assert ecef_delta_norm(rust_epoch.baseline_m, elixir_epoch.baseline_m) < 1.0e-6
      end
    end
  end

  defp synth_observations(sats, ranges, clock_m, errors, phase_ambiguities) do
    Enum.map(sats, fn sat ->
      code = Map.fetch!(ranges, sat) + clock_m + Map.fetch!(errors, sat)
      phase = code + Map.fetch!(phase_ambiguities, sat)
      %{satellite_id: sat, code_m: code, phase_m: phase}
    end)
  end

  defp multignss_epochs(systems) do
    g_ambiguities_m = Map.new(@fixed_cycles, fn {sat, cyc} -> {sat, cyc * @l1_wavelength_m} end)
    e_ambiguities_m = Map.new(@e_cycles, fn {sat, cyc} -> {sat, cyc * @e_wavelength_m} end)

    ambiguities_m =
      %{}
      |> merge_if(g_ambiguities_m, "G" in systems)
      |> merge_if(e_ambiguities_m, "E" in systems)
      |> merge_if(@r_ambiguities_m, "R" in systems)

    @sat_positions
    |> Enum.zip(@extra_sat_positions)
    |> Enum.with_index()
    |> Enum.map(fn {{g_positions, extra_positions}, idx} ->
      positions =
        extra_positions
        |> Enum.filter(fn {sat, _pos} -> String.first(sat) in systems end)
        |> Map.new()
        |> merge_if(g_positions, "G" in systems)

      synthetic_baseline_epoch(@base, @truth_baseline, positions,
        epoch: idx,
        base_clock_m: 12.0 + idx,
        rover_clock_m: -6.0 + 2.0 * idx,
        ambiguities_m: ambiguities_m
      )
    end)
  end

  defp merge_if(map, extra, true), do: Map.merge(map, extra)
  defp merge_if(map, _extra, false), do: map

  defp r_wavelength_m(sat), do: @c / (1_602_000_000.0 + Map.fetch!(@r_slots, sat) * 562_500.0)

  defp multignss_wavelengths do
    @fixed_cycles
    |> Map.keys()
    |> Map.new(&{&1, @l1_wavelength_m})
    |> Map.merge(Map.new(Map.keys(@e_cycles), &{&1, @e_wavelength_m}))
    |> Map.merge(Map.new(Map.keys(@r_slots), &{&1, r_wavelength_m(&1)}))
  end

  defp position_error(%{x_m: x, y_m: y, z_m: z}, {tx, ty, tz}) do
    :math.sqrt((x - tx) * (x - tx) + (y - ty) * (y - ty) + (z - tz) * (z - tz))
  end

  defp ecef_delta_norm(%{x_m: x1, y_m: y1, z_m: z1}, %{x_m: x2, y_m: y2, z_m: z2}) do
    dx = x1 - x2
    dy = y1 - y2
    dz = z1 - z2
    :math.sqrt(dx * dx + dy * dy + dz * dz)
  end

  defp assert_exact_ecef_map(%{x_m: x, y_m: y, z_m: z}, %{x_m: tx, y_m: ty, z_m: tz}) do
    assert x === tx
    assert y === ty
    assert z === tz
  end

  defp assert_filter_kernel_trace_exact(rust_sol, elixir_sol) do
    assert Map.delete(rust_sol.metadata, :filter_kernel) ===
             Map.delete(elixir_sol.metadata, :filter_kernel)

    assert rust_sol.fixed_ambiguities_cycles === elixir_sol.fixed_ambiguities_cycles
    assert length(rust_sol.epochs) == length(elixir_sol.epochs)
    assert_exact_ecef_map(rust_sol.baseline_m, elixir_sol.baseline_m)

    for {rust_epoch, elixir_epoch} <- Enum.zip(rust_sol.epochs, elixir_sol.epochs) do
      assert rust_epoch.epoch === elixir_epoch.epoch
      assert rust_epoch.index === elixir_epoch.index
      assert_exact_ecef_map(rust_epoch.baseline_m, elixir_epoch.baseline_m)
      assert rust_epoch.integer_status === elixir_epoch.integer_status
      assert rust_epoch.integer_ratio === elixir_epoch.integer_ratio
      assert rust_epoch.residuals_m === elixir_epoch.residuals_m
      assert rust_epoch.newly_fixed_ambiguities === elixir_epoch.newly_fixed_ambiguities
      assert rust_epoch.fixed_ambiguities === elixir_epoch.fixed_ambiguities
      assert rust_epoch.innovation_screen === elixir_epoch.innovation_screen
    end
  end

  defp nonzero_off_diagonal?(matrix) do
    matrix
    |> Enum.with_index()
    |> Enum.any?(fn {row, i} ->
      row
      |> Enum.with_index()
      |> Enum.any?(fn {value, j} -> i != j and abs(value) > 1.0e-12 end)
    end)
  end

  defp assert_identity(matrix, tol) do
    matrix
    |> Enum.with_index()
    |> Enum.each(fn {row, i} ->
      row
      |> Enum.with_index()
      |> Enum.each(fn {value, j} ->
        expected = if i == j, do: 1.0, else: 0.0
        assert abs(value - expected) < tol
      end)
    end)
  end

  defp matmul(a, b) do
    b_t = transpose(b)

    Enum.map(a, fn row ->
      Enum.map(b_t, fn col ->
        row
        |> Enum.zip(col)
        |> Enum.reduce(0.0, fn {x, y}, acc -> acc + x * y end)
      end)
    end)
  end

  defp transpose(matrix) do
    matrix
    |> Enum.zip()
    |> Enum.map(&Tuple.to_list/1)
  end

  defp mark_rover_lli(epoch, sat, lli) do
    %{epoch | rover_observations: mark_observation_lli(epoch.rover_observations, sat, lli)}
  end

  defp mark_observation_lli(observations, sat, lli) do
    Enum.map(observations, fn
      {^sat, code, phase} -> %{satellite_id: sat, code_m: code, phase_m: phase, lli: lli}
      %{satellite_id: ^sat} = obs -> Map.put(obs, :lli, lli)
      obs -> obs
    end)
  end

  defp add_rover_code_noise(epochs, noise_by_sat) do
    epochs
    |> Enum.with_index()
    |> Enum.map(fn {epoch, idx} ->
      rover =
        Enum.map(epoch.rover_observations, fn
          {sat, code, phase} ->
            {sat, code + noise_at(noise_by_sat, sat, idx), phase}

          %{satellite_id: sat, code_m: code} = obs ->
            %{obs | code_m: code + noise_at(noise_by_sat, sat, idx)}
        end)

      %{epoch | rover_observations: rover}
    end)
  end

  defp rover_position do
    add3(@base, @truth_baseline)
  end

  defp receiver_antenna(freq_offset_map) do
    %Antex.Antenna{
      id: "UNIT_TEST/ANTENNA",
      kind: :receiver,
      type: "UNIT_TEST",
      serial: "TEST",
      dazi_deg: 0.0,
      zenith_start_deg: 0.0,
      zenith_end_deg: 0.0,
      zenith_step_deg: 0.0,
      sinex_code: nil,
      frequencies: freq_offset_map
    }
  end

  defp frequency_block(up_m) do
    %Antex.Frequency{
      frequency: "G01",
      pco_m: {0.0, 0.0, up_m},
      pcv_samples: []
    }
  end

  defp receiver_antenna_corrections_option(base_pco_up_m, rover_pco_up_m) do
    base = receiver_antenna(%{"G01" => frequency_block(base_pco_up_m)})
    rover = receiver_antenna(%{"G01" => frequency_block(rover_pco_up_m)})

    %{
      base: %{antenna: base, frequency: "G01"},
      rover: %{antenna: rover, frequency: "G01"}
    }
  end

  defp apply_receiver_antenna_corrections_to_epoch(epoch, base_pco_up_m, rover_pco_up_m) do
    sat_positions = epoch.satellite_positions_m

    base_observations =
      epoch.base_observations
      |> Enum.map(fn {sat, code, phase} ->
        sat_pos = Map.fetch!(sat_positions, sat)
        correction = up_only_correction(sat_pos, @base, base_pco_up_m)
        {sat, code - correction, phase - correction}
      end)

    rover_observations =
      epoch.rover_observations
      |> Enum.map(fn {sat, code, phase} ->
        sat_pos = Map.fetch!(sat_positions, sat)
        correction = up_only_correction(sat_pos, rover_position(), rover_pco_up_m)
        {sat, code - correction, phase - correction}
      end)

    %{epoch | base_observations: base_observations, rover_observations: rover_observations}
  end

  defp receiver_antenna_dd_correction(sat, ref, sat_positions, base_pco_up_m, rover_pco_up_m) do
    sat_pos = Map.fetch!(sat_positions, sat)
    ref_pos = Map.fetch!(sat_positions, ref)

    rover_sat_corr = up_only_correction(sat_pos, rover_position(), rover_pco_up_m)
    base_sat_corr = up_only_correction(sat_pos, @base, base_pco_up_m)
    rover_ref_corr = up_only_correction(ref_pos, rover_position(), rover_pco_up_m)
    base_ref_corr = up_only_correction(ref_pos, @base, base_pco_up_m)

    rover_sat_corr - base_sat_corr - rover_ref_corr + base_ref_corr
  end

  defp up_only_correction(sat_pos, receiver_pos, pco_up_m) do
    with {:ok, los} <- unit3(sub3(sat_pos, receiver_pos)),
         {:ok, up_unit} <- unit3(receiver_pos) do
      pco_up_m * dot3(los, up_unit)
    else
      _ -> 0.0
    end
  end

  defp noise_at(noise_by_sat, sat, idx) do
    case Map.fetch(noise_by_sat, sat) do
      {:ok, values} -> Enum.at(values, idx, 0.0)
      :error -> 0.0
    end
  end

  defp synthetic_baseline_epoch(base, baseline, satellite_positions_m, opts \\ []) do
    base_clock_m = Keyword.get(opts, :base_clock_m, 0.0)
    rover_clock_m = Keyword.get(opts, :rover_clock_m, 0.0)
    common_errors_m = Keyword.get(opts, :common_errors_m, %{})
    ambiguities_m = Keyword.get(opts, :ambiguities_m, %{})
    epoch = Keyword.get(opts, :epoch)
    rover = add3(base, baseline)

    {base_obs, rover_obs} =
      satellite_positions_m
      |> Enum.sort_by(fn {sat, _pos} -> sat end)
      |> Enum.map(fn {sat, sat_pos} ->
        common = Map.get(common_errors_m, sat, 0.0)
        base_range = sagnac_range(sat_pos, base)
        rover_range = sagnac_range(sat_pos, rover)
        base_code = base_range + base_clock_m + common
        rover_code = rover_range + rover_clock_m + common

        {{sat, base_code, base_code},
         {sat, rover_code, rover_code + Map.get(ambiguities_m, sat, 0.0)}}
      end)
      |> Enum.unzip()

    epoch = %{
      epoch: epoch,
      base_observations: base_obs,
      rover_observations: rover_obs,
      satellite_positions_m: satellite_positions_m
    }

    case Keyword.get(opts, :velocity_mps) do
      nil -> epoch
      velocity_mps -> Map.put(epoch, :velocity_mps, velocity_mps)
    end
  end

  defp synthetic_dual_baseline_epoch(base, baseline, satellite_positions_m, opts) do
    base_clock_m = Keyword.get(opts, :base_clock_m, 0.0)
    rover_clock_m = Keyword.get(opts, :rover_clock_m, 0.0)
    n1_cycles = Keyword.fetch!(opts, :n1_cycles)
    wide_lane_cycles = Keyword.fetch!(opts, :wide_lane_cycles)
    epoch_idx = Keyword.get(opts, :epoch, 0)
    epoch = Keyword.get(opts, :epoch)
    rover = add3(base, baseline)

    {base_obs, rover_obs} =
      satellite_positions_m
      |> Enum.sort_by(fn {sat, _pos} -> sat end)
      |> Enum.with_index()
      |> Enum.map(fn {{sat, sat_pos}, sat_idx} ->
        base_range = sagnac_range(sat_pos, base)
        rover_range = sagnac_range(sat_pos, rover)
        common = 0.4 + 0.03 * sat_idx
        iono1_m = 1.7 + 0.04 * epoch_idx + 0.02 * sat_idx
        iono2_m = iono1_m * :math.pow(@f_l1 / @f_l2, 2)

        n1 = Map.fetch!(n1_cycles, sat)
        n2 = n1 - Map.fetch!(wide_lane_cycles, sat)

        {
          dual_observation(sat, base_range, base_clock_m, common, iono1_m, iono2_m, 0, 0),
          dual_observation(
            sat,
            rover_range,
            rover_clock_m,
            common,
            iono1_m,
            iono2_m,
            n1,
            n2
          )
        }
      end)
      |> Enum.unzip()

    %{
      epoch: epoch,
      base_observations: base_obs,
      rover_observations: rover_obs,
      satellite_positions_m: satellite_positions_m
    }
  end

  defp dual_observation(sat, range_m, clock_m, common_m, iono1_m, iono2_m, n1, n2) do
    p1 = range_m + clock_m + common_m + iono1_m
    p2 = range_m + clock_m + common_m + iono2_m
    l1 = range_m + clock_m + common_m - iono1_m + n1 * @l1_wavelength_m
    l2 = range_m + clock_m + common_m - iono2_m + n2 * @l2_wavelength_m

    %{
      satellite_id: sat,
      p1_m: p1,
      p2_m: p2,
      phi1_cyc: l1 / @l1_wavelength_m,
      phi2_cyc: l2 / @l2_wavelength_m,
      f1_hz: @f_l1,
      f2_hz: @f_l2,
      lli1: 0,
      lli2: 0
    }
  end

  defp mark_dual_rover_lli(epoch, sat, lli) do
    %{epoch | rover_observations: mark_dual_observation_lli(epoch.rover_observations, sat, lli)}
  end

  defp mark_dual_observation_lli(observations, sat, lli) do
    Enum.map(observations, fn
      %{satellite_id: ^sat} = obs -> %{obs | lli1: lli}
      obs -> obs
    end)
  end

  defp expected_narrow_lane_offsets(wide_lane_cycles) do
    wide_lane_cycles
    |> Map.delete("G01")
    |> Map.new(fn {sat, wide_lane} -> {sat, narrow_lane_offset_m(wide_lane)} end)
  end

  defp narrow_lane_offset_m(wide_lane_cycles) do
    {:ok, gamma} = Sidereon.GNSS.IonosphereFree.gamma(@f_l1, @f_l2)
    (gamma - 1.0) * @l2_wavelength_m * wide_lane_cycles
  end

  defp add3({ax, ay, az}, {bx, by, bz}), do: {ax + bx, ay + by, az + bz}
  defp sub3({ax, ay, az}, {bx, by, bz}), do: {ax - bx, ay - by, az - bz}
  defp scale3({x, y, z}, s), do: {x * s, y * s, z * s}
  defp norm({x, y, z}), do: :math.sqrt(x * x + y * y + z * z)

  defp unit3(v) do
    if norm(v) > 0.0 do
      {:ok, scale3(v, 1.0 / norm(v))}
    else
      :zero
    end
  end

  defp dot3({ax, ay, az}, {bx, by, bz}), do: ax * bx + ay * by + az * bz

  defp sagnac_range(sat_pos, receiver) do
    {sx, sy, _sz} = sat_pos
    {rx, ry, _rz} = receiver

    norm(sub3(sat_pos, receiver)) + @earth_rotation_rate_rad_s * (sx * ry - sy * rx) / @c
  end
end
