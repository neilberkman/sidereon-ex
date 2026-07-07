defmodule Sidereon.GNSS.RTKTest do
  use ExUnit.Case, async: true

  alias Sidereon.GeometryQuality
  alias Sidereon.GNSS.RINEX.Observations, as: RinexObservations
  alias Sidereon.GNSS.RTK
  alias Sidereon.GNSS.SP3

  @base {1_110_000.0, -4_840_000.0, 3_980_000.0}
  @truth_baseline {12.5, -4.25, 2.75}
  @rtk_sp3_path Path.join(__DIR__, "fixtures/sp3/GBM0MGXRAP_20201770000_01D_05M_ORB_120epoch.sp3")
  @wtzr_obs_path Path.join(__DIR__, "fixtures/obs/WTZR00DEU_R_20201770000_01D_30S_MO_120epoch.rnx")
  @wtzz_obs_path Path.join(__DIR__, "fixtures/obs/WTZZ00DEU_R_20201770000_01D_30S_MO_120epoch.rnx")
  @wtzr_marker {4_075_580.3111, 931_854.0543, 4_801_568.2808}
  @wtzz_marker {4_075_579.1913, 931_853.3696, 4_801_569.1897}
  @c 299_792_458.0
  @f_l1 1_575_420_000.0
  @f_l2 1_227_600_000.0
  @l1_wavelength_m @c / @f_l1
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
  @fixed_cycles %{"G01" => 0, "G02" => 5, "G03" => -7, "G04" => 12, "G05" => -4}
  @ambiguity_ids ["G02", "G03", "G04", "G05"]

  describe "double_differences/3" do
    test "receiver clocks and common satellite errors cancel" do
      base = [{"G01", 100.0, 102.0}, {"G02", 210.0, 211.0}, {"G03", 320.0, 324.0}]
      rover = [{"G01", 106.0, 109.0}, {"G02", 221.0, 225.0}, {"G03", 340.0, 343.0}]

      assert {:ok, result} = RTK.double_differences(base, rover, reference_satellite_id: "G01")

      assert result.reference_satellite_id == "G01"
      assert result.dropped_sats == []

      assert result.double_differences == [
               %{
                 satellite_id: "G02",
                 reference_satellite_id: "G01",
                 ambiguity_id: "G02",
                 code_m: 5.0,
                 phase_m: 7.0
               },
               %{
                 satellite_id: "G03",
                 reference_satellite_id: "G01",
                 ambiguity_id: "G03",
                 code_m: 14.0,
                 phase_m: 12.0
               }
             ]
    end

    test "bad inputs are tagged" do
      assert RTK.double_differences([{"G01", 1.0, 2.0}], [{"G01", 1.0, 2.0}]) ==
               {:error, {:too_few_common_satellites, 1, 2}}

      assert RTK.double_differences([{"G01", :bad, 2.0}], [{"G01", 1.0, 2.0}]) ==
               {:error, {:invalid_base_observations, {"G01", :bad, 2.0}}}

      assert RTK.double_differences(
               [{"G01", 1.0, 2.0}, {"G02", 3.0, 4.0}],
               [{"G01", 1.0, 2.0}, {"G02", 3.0, 4.0}],
               reference_satellite: "G01"
             ) == {:error, {:invalid_option, :reference_satellite}}
    end
  end

  describe "solve_rtk_float/1" do
    test "delegates direct prepared epochs to the core float solver" do
      assert {:ok, solution} =
               RTK.solve_rtk_float(%{
                 epochs: prepared_epochs(),
                 base: @base,
                 ambiguity_ids: @ambiguity_ids,
                 model: model(),
                 initial_baseline_m: {0.0, 0.0, 0.0},
                 options: %{max_iterations: 20}
               })

      assert norm(sub3(ecef_tuple(solution.baseline_m), @truth_baseline)) < 1.0e-3
      assert solution.used_sats == @ambiguity_ids
      assert solution.metadata.converged
      assert solution.metadata.n_epochs == 3

      assert %GeometryQuality{
               tier: :nominal,
               raim_checkable: true,
               covariance_validated: true
             } = solution.metadata.geometry_quality
    end

    test "rank-deficient geometry returns the singular error" do
      assert RTK.solve_rtk_float(%{
               epochs: rank_deficient_prepared_epochs(),
               base: @base,
               ambiguity_ids: @ambiguity_ids,
               model: model(),
               initial_baseline_m: {0.0, 0.0, 0.0},
               options: %{max_iterations: 20}
             }) == {:error, :singular_geometry}
    end
  end

  describe "solve_rtk_fixed/1" do
    test "delegates direct prepared epochs to the core fixed solver" do
      assert {:ok, solution} =
               RTK.solve_rtk_fixed(%{
                 epochs: prepared_epochs(),
                 base: @base,
                 ambiguity_ids: @ambiguity_ids,
                 ambiguity_satellites: Map.new(@ambiguity_ids, &{&1, &1}),
                 wavelengths_m: Map.new(@ambiguity_ids, &{&1, @l1_wavelength_m}),
                 offsets_m: Map.new(@ambiguity_ids, &{&1, 0.0}),
                 model: model(),
                 initial_baseline_m: {0.0, 0.0, 0.0},
                 float_options: %{max_iterations: 20},
                 fixed_options: %{ratio_threshold: 3.0},
                 residual_options: %{threshold_sigma: nil, max_exclusions: 0},
                 float_only_systems: []
               })

      assert norm(sub3(ecef_tuple(solution.baseline_m), @truth_baseline)) < 1.0e-3
      assert solution.metadata.integer_status == :fixed

      assert Map.take(solution.fixed_ambiguities_cycles, @ambiguity_ids) ==
               Map.take(@fixed_cycles, @ambiguity_ids)
    end
  end

  describe "solve_arc/2" do
    test "delegates raw arc epochs to the core sequential arc solver" do
      assert {:ok, solution} = RTK.solve_arc(arc_epochs(), arc_config())

      assert Map.has_key?(solution.references, "G")
      assert length(solution.epochs) == 3
      assert List.last(solution.epochs).integer_fixed
      assert norm(sub3(List.last(solution.epochs).reported_baseline_m, @truth_baseline)) < 1.0e-3
    end
  end

  describe "solve_static_arc/2" do
    test "delegates raw arc epochs to the core static arc solver" do
      assert {:ok, solution} =
               RTK.solve_static_arc(
                 arc_epochs(),
                 arc_config()
                 |> Map.put(:float_opts, float_opts())
                 |> Map.put(:fixed_opts, fixed_opts())
                 |> Map.put(:residual_opts, residual_opts())
                 |> Map.put(:float_only_systems, [])
                 |> Map.put(:wavelengths_m, {"scalar", @l1_wavelength_m, []})
                 |> Map.put(:offsets_m, {"none", 0.0, []})
               )

      assert solution.references == %{"G" => "G01"}
      assert solution.ambiguity_ids == @ambiguity_ids
      assert solution.dropped_sats == []

      assert %GeometryQuality{
               tier: :nominal,
               raim_checkable: true,
               covariance_validated: true
             } = solution.geometry_quality
    end
  end

  describe "fix_wide_lane_rtk_arc/2" do
    test "surfaces geometry quality for a synthetic dual-frequency arc" do
      assert {:ok, solution} =
               RTK.fix_wide_lane_rtk_arc(dual_frequency_epochs(), wide_lane_config())

      assert map_size(solution.wide_lane_cycles) == 3

      assert %GeometryQuality{
               tier: :nominal,
               raim_checkable: true,
               covariance_validated: true
             } = solution.geometry_quality
    end
  end

  describe "RINEX RTK baseline conveniences" do
    setup do
      base_obs = RinexObservations.load!(@wtzr_obs_path)
      rover_obs = RinexObservations.load!(@wtzz_obs_path)
      base_arp = arp_position(@wtzr_marker, base_obs)
      rover_arp = arp_position(@wtzz_marker, rover_obs)

      {:ok,
       %{
         sp3: SP3.load!(@rtk_sp3_path),
         base_obs: base_obs,
         rover_obs: rover_obs,
         base_arp: base_arp,
         truth_baseline: sub3(rover_arp, base_arp)
       }}
    end

    test "solves the WTZR to WTZZ static baseline from raw RINEX", ctx do
      assert {:ok, solution} =
               RTK.solve_static_rinex_rtk_baseline(
                 ctx.sp3,
                 ctx.base_obs,
                 ctx.rover_obs,
                 ctx.base_arp,
                 rinex_oracle_opts()
               )

      assert solution.epoch_count == 120
      assert solution.skipped_epoch_count == 0
      assert solution.references == %{"G" => "G30"}

      float_error_m = norm(sub3(ecef_tuple(solution.float_solution.baseline_m), ctx.truth_baseline))
      fixed_error_m = norm(sub3(ecef_tuple(solution.fixed_solution.baseline_m), ctx.truth_baseline))

      assert float_error_m < 0.02
      assert fixed_error_m < 0.01
      assert solution.fixed_solution.metadata.integer_status == :not_fixed
      assert solution.fixed_solution.metadata.integer_ratio < 3.0
      assert length(solution.float_solution.metadata.ambiguity_float.covariance_m) == 11
    end

    test "solves the WTZR to WTZZ wide-lane fixed baseline from raw dual-frequency RINEX", ctx do
      assert {:ok, solution} =
               RTK.solve_wide_lane_fixed_rinex_rtk_baseline(
                 ctx.sp3,
                 ctx.base_obs,
                 ctx.rover_obs,
                 ctx.base_arp,
                 rinex_oracle_opts()
               )

      assert solution.epoch_count == 120
      assert solution.skipped_epoch_count == 0
      assert solution.wide_lane.fixed?
      assert solution.wide_lane.ambiguity_count == 7

      float_error_m = norm(sub3(ecef_tuple(solution.float_solution.baseline_m), ctx.truth_baseline))
      fixed_error_m = norm(sub3(ecef_tuple(solution.fixed_solution.baseline_m), ctx.truth_baseline))

      assert float_error_m < 0.1
      assert fixed_error_m < 0.01
      assert solution.fixed_solution.metadata.integer_status == :fixed
      assert solution.fixed_solution.metadata.integer_ratio > 3.0
      assert length(solution.float_solution.metadata.ambiguity_float.covariance_m) == 7
    end
  end

  defp prepared_epochs do
    @sat_positions
    |> Enum.with_index()
    |> Enum.map(fn {positions, idx} ->
      rows =
        positions
        |> Enum.sort_by(fn {sat, _position} -> sat end)
        |> Enum.map(fn {sat, position} -> prepared_sat(sat, position, idx) end)

      %{
        references: [Enum.find(rows, &(&1.sat == "G01"))],
        nonref: Enum.reject(rows, &(&1.sat == "G01")),
        dt_s: idx * 30.0
      }
    end)
  end

  defp rank_deficient_prepared_epochs do
    reference = prepared_sat("G01", {15_000_000.0, 7_000_000.0, 21_000_000.0}, 0)
    repeated = {-12_000_000.0, 18_000_000.0, 19_000_000.0}

    [
      %{
        references: [reference],
        nonref: Enum.map(@ambiguity_ids, &prepared_sat(&1, repeated, 0)),
        dt_s: 0.0
      }
    ]
  end

  defp prepared_sat(sat, sat_pos, idx) do
    rover = add3(@base, @truth_baseline)
    base_range = norm(sub3(sat_pos, @base))
    rover_range = norm(sub3(sat_pos, rover))
    base_clock_m = 120.0 - 3.0 * idx
    rover_clock_m = -45.0 + 7.0 * idx
    common_error_m = idx + String.to_integer(String.slice(sat, 1, 2)) * 0.25
    ambiguity_m = Map.fetch!(@fixed_cycles, sat) * @l1_wavelength_m

    %{
      sat: sat,
      sd_ambiguity_id: sat,
      base_code_m: base_range + base_clock_m + common_error_m,
      base_phase_m: base_range + base_clock_m + common_error_m,
      rover_code_m: rover_range + rover_clock_m + common_error_m,
      rover_phase_m: rover_range + rover_clock_m + common_error_m + ambiguity_m,
      base_tx_pos: sat_pos,
      rover_tx_pos: sat_pos,
      pos: sat_pos
    }
  end

  defp arc_epochs do
    prepared_epochs()
    |> Enum.map(fn epoch ->
      rows = epoch.references ++ epoch.nonref

      %{
        base: Enum.map(rows, &arc_observation(&1, :base)),
        rover: Enum.map(rows, &arc_observation(&1, :rover)),
        satellite_positions_m: Map.new(rows, &{&1.sat, &1.pos}),
        base_satellite_positions_m: Map.new(rows, &{&1.sat, &1.base_tx_pos}),
        rover_satellite_positions_m: Map.new(rows, &{&1.sat, &1.rover_tx_pos}),
        prediction_time_s: epoch.dt_s
      }
    end)
  end

  defp arc_observation(row, :base) do
    %{satellite_id: row.sat, ambiguity_id: row.sd_ambiguity_id, code_m: row.base_code_m, phase_m: row.base_phase_m}
  end

  defp arc_observation(row, :rover) do
    %{satellite_id: row.sat, ambiguity_id: row.sd_ambiguity_id, code_m: row.rover_code_m, phase_m: row.rover_phase_m}
  end

  defp arc_config do
    %{
      base_m: @base,
      reference: {:satellite, "G01"},
      model: model(),
      baseline_prior_sigma_m: 100.0,
      ambiguity_prior_sigma_m: 100.0,
      initial_baseline_m: {0.0, 0.0, 0.0},
      wavelengths_m: Map.new(Map.keys(@fixed_cycles), &{&1, @l1_wavelength_m}),
      offsets_m: Map.new(Map.keys(@fixed_cycles), &{&1, 0.0}),
      update_opts: %{
        hold_sigma_m: 1.0e-4,
        position_tol_m: 1.0e-4,
        ambiguity_tol_m: 1.0e-4,
        max_iterations: 20,
        process_noise_baseline_sigma_m: 0.0,
        ratio_threshold: 3.0,
        dynamics_model: :constant_position,
        float_only_systems: [],
        innovation_screen_sigma: 0.0,
        innovation_screen_min_rows: 8,
        ar_arming_sigma_m: nil,
        report_residuals?: true
      },
      preprocessing: %{}
    }
  end

  defp dual_frequency_epochs do
    positions =
      @sat_positions
      |> hd()
      |> Map.take(["G01", "G02", "G03", "G04"])

    for idx <- 0..2 do
      rows = [
        dual_frequency_pair("G01", 2.0, 5.0),
        dual_frequency_pair("G02", 1.0, 7.0),
        dual_frequency_pair("G03", -2.0, 0.0),
        dual_frequency_pair("G04", 4.0, 8.0)
      ]

      %{
        epoch: idx,
        base_observations: Enum.map(rows, fn {base, _rover} -> base end),
        rover_observations: Enum.map(rows, fn {_base, rover} -> rover end),
        satellite_positions_m: positions
      }
    end
  end

  defp dual_frequency_pair(sat, base_wide_lane, rover_wide_lane) do
    base_code = 20_000_000.0 + base_wide_lane * 10.0
    rover_code = base_code + 25.0 + rover_wide_lane

    {
      dual_frequency_observation(sat, base_code, base_code + 2.0, base_wide_lane),
      dual_frequency_observation(sat, rover_code, rover_code + 2.5, rover_wide_lane)
    }
  end

  defp dual_frequency_observation(sat, p1_m, p2_m, wide_lane_phase_cycles) do
    %{
      satellite_id: sat,
      ambiguity_id: sat,
      p1_m: p1_m,
      p2_m: p2_m,
      phi1_cyc: wide_lane_phase_cycles,
      phi2_cyc: 0.0,
      f1_hz: @f_l1,
      f2_hz: @f_l2
    }
  end

  defp wide_lane_config do
    %{
      base_m: @base,
      reference: :auto,
      min_epochs: 2,
      tolerance_cycles: 0.5,
      skip_short_fragments: false,
      cycle_slip: nil
    }
  end

  defp rinex_oracle_opts do
    [
      max_epochs: 120,
      model: %{
        code_sigma_m: 2.0,
        phase_sigma_m: 0.01,
        stochastic_model: :simple,
        elevation_weighting?: true,
        sagnac?: true
      },
      preprocessing: %{cycle_slip: :split_arc},
      float_options: %{max_iterations: 10},
      fixed_options: %{ratio_threshold: 3.0},
      residual_options: %{threshold_sigma: nil, max_exclusions: 0},
      apply_troposphere: true
    ]
  end

  defp arp_position(marker, obs) do
    {height_m, east_m, north_m} = RinexObservations.antenna_delta_hen(obs)
    up = unit3(marker)
    east = unit3({-elem(up, 1), elem(up, 0), 0.0})
    north = unit3(cross3(up, east))

    marker
    |> add3(scale3(up, height_m))
    |> add3(scale3(east, east_m))
    |> add3(scale3(north, north_m))
  end

  defp model do
    %{
      code_sigma_m: 0.3,
      phase_sigma_m: 0.003,
      stochastic_model: :simple,
      elevation_weighting?: false,
      sagnac?: true
    }
  end

  defp float_opts do
    %{
      position_tolerance_m: 1.0e-4,
      ambiguity_tolerance_m: 1.0e-4,
      max_iterations: 20
    }
  end

  defp fixed_opts do
    %{
      ratio_threshold: 3.0,
      partial_ambiguity_resolution?: false,
      partial_min_ambiguities: 4
    }
  end

  defp residual_opts do
    %{threshold_sigma: nil, max_exclusions: 0}
  end

  defp ecef_tuple(%{x_m: x, y_m: y, z_m: z}), do: {x, y, z}

  defp add3({ax, ay, az}, {bx, by, bz}), do: {ax + bx, ay + by, az + bz}
  defp sub3({ax, ay, az}, {bx, by, bz}), do: {ax - bx, ay - by, az - bz}
  defp scale3({x, y, z}, scale), do: {x * scale, y * scale, z * scale}
  defp norm({x, y, z}), do: :math.sqrt(x * x + y * y + z * z)

  defp unit3(vec) do
    scale3(vec, 1.0 / norm(vec))
  end

  defp cross3({ax, ay, az}, {bx, by, bz}) do
    {ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx}
  end
end
