defmodule Sidereon.GNSS.PrecisePositioningSurfacesTest do
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.PrecisePositioning.{CycleSlip, Kinematic, Prep, RAIM, TEC}
  alias Sidereon.GNSS.Time.ExactEpoch

  @f1 1_575_420_000.0
  @f2 1_227_600_000.0
  @zero %{
    satellite_id: "G01",
    ambiguity_id: "G01",
    p1_m: 0.0,
    p2_m: 0.0,
    phi1_cyc: 0.0,
    phi2_cyc: 0.0,
    f1_hz: @f1,
    f2_hz: @f2,
    lli1: nil,
    lli2: nil
  }

  test "TEC constants, defaults, combinations, mapping, leveling, pierce point and stream estimate" do
    assert TEC.constants() == %{
             default_ionospheric_shell_height_m: 350_000.0,
             electrons_per_tecu_m2: 1.0e16,
             tec_group_delay_coefficient: 4.0308e17
           }

    assert TEC.config() == %{shell_height_m: 350_000.0, earth_radius_m: 6_371_000.0}
    assert TEC.code_geometry_free_m(@zero) == {:ok, 0.0}
    assert TEC.phase_geometry_free_m(@zero) == {:ok, 0.0}
    assert TEC.slant_tec_from_code_geometry_free_m(0.0, @f1, @f2) == {:ok, 0.0}
    assert TEC.slant_tec_from_phase_geometry_free_m(0.0, @f1, @f2) == {:ok, 0.0}
    assert {:ok, %{code_geometry_free_m: 0.0, slant_tec_tecu: 0.0}} = TEC.estimate_code_slant_tec(@zero)
    assert {:ok, %{phase_geometry_free_m: 0.0, slant_tec_tecu: 0.0}} = TEC.estimate_phase_slant_tec(@zero)
    assert TEC.thin_shell_mapping_function(:math.pi() / 2) == {:ok, 1.0}
    assert TEC.vertical_tec_from_slant_tec(20.0, :math.pi() / 2) == {:ok, 20.0}
    sample = %{code_slant_tec_tecu: 20.0, phase_slant_tec_tecu: 25.0, elevation_rad: :math.pi() / 2}

    assert {:ok,
            %{
              phase_bias_tecu: 5.0,
              samples: [%{leveled_slant_tec_tecu: 20.0, mapping_function: 1.0, vertical_tec_tecu: 20.0}]
            }} = TEC.level_slant_tec_arc([sample])

    assert {:ok, point} = TEC.ionospheric_pierce_point(0.0, 0.0, :math.pi() / 2, 0.0)
    assert abs(point.latitude_rad) < 1.0e-15
    assert point.longitude_rad == 0.0
    assert abs(point.earth_central_angle_rad) < 1.0e-15

    epoch = %{
      time_s: 0.0,
      receiver_latitude_rad: 0.0,
      receiver_longitude_rad: 0.0,
      observations: [%{observation: @zero, elevation_rad: :math.pi() / 2, azimuth_rad: 0.0}]
    }

    assert {:error, %TEC.Error{kind: :insufficient_arc_samples}} = TEC.estimate_tec([epoch])
    assert {:ok, %{arcs: [%{samples: [_, _]}]}} = TEC.estimate_tec([epoch, %{epoch | time_s: 1.0}])
  end

  test "TEC refusals preserve stable variants and core display text" do
    assert {:error, %TEC.Error{} = error} = TEC.thin_shell_mapping_function(0.0, %{TEC.config() | shell_height_m: 0.0})
    assert error.kind == :invalid_shell_height
    assert to_string(error) == "TEC shell height must be positive and finite"
    assert {:error, %TEC.Error{kind: :empty_arc}} = TEC.level_slant_tec_arc([])
    assert {:error, %TEC.Error{kind: :no_epochs}} = TEC.estimate_tec([])
  end

  test "cycle-slip defaults, exact epoch state, updates and batch detector" do
    assert CycleSlip.config() == %{
             melbourne_wubbena_threshold_cycles: 4.0,
             geometry_free_threshold_m: 0.05,
             minimum_arc_length: 2,
             running_statistic_k_factor: 4.0,
             maximum_gap_s: 300.0
           }

    assert CycleSlip.melbourne_wubbena_cycles(@zero) == {:ok, 0.0}
    assert CycleSlip.geometry_free_m(@zero) == {:ok, 0.0}
    {:ok, exact} = ExactEpoch.new(10, 25)
    assert {:ok, mw} = CycleSlip.update_melbourne_wubbena(CycleSlip.state(), @zero)
    assert mw.state.melbourne_wubbena.sample_count == 1
    assert {:ok, gf} = CycleSlip.update_geometry_free(mw.state, @zero, 10.0, exact)
    assert ExactEpoch.equal?(gf.state.previous_epoch, exact)
    assert gf == %{gf | geometry_free_m: 0.0, slip: false, reset: false}
    epoch = %{gap_time_s: 10.0, gap_epoch: exact, observations: [@zero]}

    assert {:ok, [%{gap_epoch: returned, observations: [%{slip: false, reasons: []}]}]} =
             CycleSlip.detect_cycle_slips([epoch])

    assert ExactEpoch.equal?(returned, exact)
  end

  test "cycle-slip refusals are typed" do
    bad = %{@zero | f1_hz: 0.0}
    assert {:error, %CycleSlip.Error{kind: :invalid_frequency}} = CycleSlip.geometry_free_m(bad)
    config = %{CycleSlip.config() | minimum_arc_length: 0}
    assert {:error, %CycleSlip.Error{} = error} = CycleSlip.update_melbourne_wubbena(CycleSlip.state(), @zero, config)
    assert error.kind == :invalid_config
    assert error.field == "minimum_arc_length"
    assert to_string(error) == "invalid cycle-slip config: minimum arc length must be nonzero"
  end

  test "prep defaults, float tagging, and structured refusal" do
    assert Prep.cycle_slip_options() == %{gf_threshold_m: 0.05, mw_threshold_cycles: 4.0, min_arc_gap_s: 300.0}
    epochs = [%{gap_time_s: 0.0, gap_epoch: nil, observations: [%{satellite_id: "G01", ambiguity_id: "arc", raw: nil}]}]

    assert Prep.split_float_cycle_slip_epochs(epochs) == [
             %{observations: [%{satellite_id: "G01", ambiguity_id: "arc"}]}
           ]

    dual = [%{gap_time_s: 0.0, gap_epoch: nil, observations: [@zero]}]

    assert {:ok, prepared} =
             Prep.prepare_widelane_fixed_epochs(
               dual ++ [%{gap_time_s: 1.0, gap_epoch: nil, observations: [@zero]}],
               %{min_epochs: 2, tolerance_cycles: 0.25},
               :error
             )

    assert prepared == %{
             dropped_sats: [],
             epochs: [
               %{
                 epoch_index: 0,
                 observations: [%{satellite_id: "G01", ambiguity_id: "G01", code_m: 0.0, phase_m: 0.0}]
               },
               %{
                 epoch_index: 1,
                 observations: [%{satellite_id: "G01", ambiguity_id: "G01", code_m: 0.0, phase_m: 0.0}]
               }
             ],
             offsets_m: %{"G01" => 0.0},
             split_arcs: [],
             wavelengths_m: %{"G01" => 0.10695337814214669},
             wide_lane_cycles: %{"G01" => 0}
           }

    assert {:error, %Prep.Error{} = error} =
             Prep.prepare_widelane_fixed_epochs(dual, %{min_epochs: 2, tolerance_cycles: 0.25}, :error)

    assert error.kind == :too_few_wide_lane_epochs
    assert error.ambiguity_id == "G01"
    assert error.count == 1 and error.minimum == 2
  end

  test "standalone RAIM exact global result and typed refusals" do
    residual = %{
      epoch_index: 0,
      satellite_id: "G01",
      ambiguity_id: "G01",
      code_m: 0.0,
      phase_m: 0.0,
      code_weight: 1.0,
      phase_weight: 1.0
    }

    config = %{RAIM.config() | chi_square_threshold: 10.0}

    assert {:ok, %{status: :passed, detected: false, test_statistic: 0.0, threshold: 10.0, redundancy: 1}} =
             RAIM.global_test([residual], 1, config)

    assert {:error, %RAIM.Error{} = error} = RAIM.global_test([residual], 1, %{config | false_alarm_probability: 0.0})
    assert error.kind == :invalid_config and error.field == "false_alarm_probability"
    assert to_string(error) == "invalid RAIM configuration false_alarm_probability: must be inside (0, 1)"
    bad = %{residual | code_weight: 0.0}
    assert {:error, %RAIM.Error{kind: :invalid_residual, field: "code_weight"}} = RAIM.global_test([bad], 1, config)
  end

  test "standalone RAIM geometry, statistics, protection and refusals" do
    root_three = :math.sqrt(3.0)

    geometry = [
      %{satellite_id: "G01", line_of_sight: {1.0, 0.0, 0.0}},
      %{satellite_id: "G02", line_of_sight: {-1.0, 0.0, 0.0}},
      %{satellite_id: "G03", line_of_sight: {0.0, 1.0, 0.0}},
      %{satellite_id: "G04", line_of_sight: {0.0, 0.0, 1.0}},
      %{
        satellite_id: "G05",
        line_of_sight: {1.0 / root_three, 1.0 / root_three, 1.0 / root_three}
      }
    ]

    residuals =
      Enum.map(1..5, fn index ->
        %{
          epoch_index: 0,
          satellite_id: "G0#{index}",
          ambiguity_id: "G0#{index}",
          code_m: 0.0,
          phase_m: 0.0,
          code_weight: 1.0,
          phase_weight: 1.0
        }
      end)

    config = %{RAIM.config() | chi_square_threshold: 10.0}
    assert {:ok, result} = RAIM.global_test_with_geometry(residuals, geometry, config)
    assert result.status == :passed
    assert result.test_statistic == 0.0
    assert result.redundancy == 1
    assert result.most_likely_fault == "G01"
    assert Enum.map(result.satellite_statistics, & &1.statistic) == [0.0, 0.0, 0.0, 0.0, 0.0]

    assert {:ok, statistics} = RAIM.per_satellite_statistics(residuals, geometry, config)
    assert statistics.most_likely_fault == "G01"
    assert Enum.all?(statistics.statistics, &(&1.code_testable and not &1.phase_testable))

    assert RAIM.protection_levels(geometry, {0.7, -1.2, 0.0}, config) ==
             {:ok, %{hpl_m: 4.684799866357605, vpl_m: 3.2295555725090805}}

    assert {:error, %RAIM.Error{kind: :invalid_geometry, field: "geometry"}} =
             RAIM.global_test_with_geometry(residuals, tl(geometry), config)

    assert {:error, %RAIM.Error{kind: :invalid_geometry}} =
             RAIM.per_satellite_statistics(residuals, tl(geometry), config)

    assert {:error, %RAIM.Error{} = protection_error} =
             RAIM.protection_levels(Enum.take(geometry, 2), {0.7, -1.2, 0.0}, config)

    assert protection_error.kind == :dop
    assert protection_error.reason == "fewer satellites than parameters: geometry is rank-deficient"

    assert to_string(protection_error) ==
             "RAIM DOP failed: fewer satellites than parameters: geometry is rank-deficient"
  end

  test "kinematic defaults and prediction exact values" do
    config = Kinematic.config()
    assert config.initial_state.position_m == {0.0, 0.0, 0.0}
    assert config.new_ambiguity_variance_m2 == 1.0e8

    assert {:ok, predicted} =
             Kinematic.predict_kinematic_state(config.initial_state, config.initial_covariance_m2, 2.0, ["G01"], config)

    assert predicted.state.ambiguities_m == %{"G01" => 0.0}
    assert length(predicted.covariance_m2) == 6
    assert Enum.at(Enum.at(predicted.covariance_m2, 5), 5) == 1.0e8

    assert {:error, %Kinematic.Error{} = error} =
             Kinematic.predict_kinematic_state(config.initial_state, [], 2.0, [], config)

    assert error.kind == :invalid_input
    assert error.field == "kinematic PPP covariance row count"
    assert error.reason == "must match state dimension"

    assert to_string(error) ==
             "invalid kinematic PPP input kinematic PPP covariance row count: must match state dimension"
  end
end
