defmodule Sidereon.GNSSFusionTest do
  use ExUnit.Case

  alias Sidereon.GNSS.Fusion
  alias Sidereon.GNSS.Fusion.FusionRtsHistory
  alias Sidereon.GNSS.Fusion.FusionRtsHistoryBuilder
  alias Sidereon.GNSS.Fusion.SmoothedFusionTrajectory
  alias Sidereon.GNSS.SP3

  @wgs84_a_m 6_378_137.0
  @omega_e_dot_rad_s 7.292_115_146_7e-5
  @sp3_path "test/fixtures/sp3/GBM0MGXRAP_20201770000_01D_05M_ORB_73epoch.sp3"
  @c_m_s 299_792_458.0

  describe "GNSS/INS fusion parity" do
    test "encodes and decodes state bytes" do
      {:ok, filter} = Fusion.new(initial_state(), config(:ekf))
      assert {:ok, bytes} = Fusion.encode_state(filter)
      assert byte_size(bytes) > 0

      assert {:ok, restored} = Fusion.from_state_bytes(bytes, config(:ekf))
      assert {:ok, restored_state} = Fusion.state(restored)

      assert restored_state.nominal.position_ecef_m == [@wgs84_a_m, 0.0, 0.0]
      assert restored_state.nominal.velocity_ecef_mps == [0.0, 0.0, 0.0]
      assert restored_state.nominal.t_j2000_s == 0.0
      assert_close_matrix(top_left(restored_state.covariance, 3), diagonal3(1.0), 0.0)

      assert {:ok, _report} =
               Fusion.update_loose(filter, loose_measurement(0.0, {@wgs84_a_m + 0.25, -0.5, 0.75}))

      assert {:ok, updated_bytes} = Fusion.encode_state(filter)
      assert {:ok, updated_restored} = Fusion.from_state_bytes(updated_bytes, config(:ekf))
      assert {:ok, updated_state} = Fusion.state(updated_restored)

      assert_close_list(updated_state.nominal.position_ecef_m, [6_378_137.05, -0.1, 0.15], 1.0e-12)
    end

    test "pins loose EKF and UKF updates" do
      measurement = loose_measurement(0.0, {@wgs84_a_m + 0.25, -0.5, 0.75})

      {:ok, ekf} = Fusion.new(initial_state(), config(:ekf))
      assert {:ok, ekf_report} = Fusion.update_loose(ekf, measurement)
      assert ekf_report.rows == 3
      assert ekf_report.applied
      assert_close(ekf_report.nis, 0.175, 0.0)
      assert_close_list(Enum.take(ekf_report.ekf.dx, 3), [-0.05, 0.1, -0.15], 1.0e-16)

      assert {:ok, ekf_state} = Fusion.state(ekf)
      assert_close_list(ekf_state.nominal.position_ecef_m, [6_378_137.05, -0.1, 0.15], 1.0e-12)
      assert_close_matrix(top_left(ekf_state.covariance, 3), diagonal3(0.8), 0.0)

      {:ok, ukf} = Fusion.new(initial_state(), config(:ukf))
      assert {:ok, ukf_report} = Fusion.update_loose(ukf, measurement)
      assert ukf_report.rows == 3
      assert ukf_report.applied
      assert_close(ukf_report.nis, 0.175, 0.0)

      assert {:ok, ukf_state} = Fusion.state(ukf)
      assert_close_list(ukf_state.nominal.position_ecef_m, [6_378_137.05, -0.1, 0.15], 1.0e-12)
    end

    test "marshals loose position-velocity fixes with 6x6 covariance" do
      measurement =
        0.0
        |> loose_measurement({@wgs84_a_m + 0.25, -0.5, 0.75})
        |> Map.put(:velocity_ecef_mps, {0.1, -0.2, 0.3})
        |> Map.put(:covariance, diagonal(6, 4.0))

      {:ok, filter} = Fusion.new(initial_state(), config(:ekf))
      assert {:ok, report} = Fusion.update_loose(filter, measurement)

      assert report.rows == 6
      assert report.applied
      assert_close(report.nis, 0.20299999999999999, 0.0)
      assert_close_list(Enum.take(report.ekf.dx, 6), [-0.05, 0.1, -0.15, -0.02, 0.04, -0.06], 1.0e-16)

      assert {:ok, state} = Fusion.state(filter)
      assert_close_list(state.nominal.position_ecef_m, [6_378_137.05, -0.1, 0.15], 1.0e-12)
      assert_close_list(state.nominal.velocity_ecef_mps, [0.02, -0.04, 0.06], 1.0e-16)
      assert_close_matrix(top_left(state.covariance, 6), diagonal(6, 0.8), 0.0)
    end

    test "replays a late loose fix through time-sync checkpoints" do
      {:ok, filter} = Fusion.new(initial_state(), config(:ekf))
      assert {:ok, status0} = Fusion.configure_time_sync(filter, imu_capacity: 4, checkpoint_capacity: 4)
      assert status0.checkpoint_len == 1

      assert {:ok, _state} = Fusion.propagate(filter, increment_sample(1.0, 1.0))

      measurement = loose_measurement(0.75, {@wgs84_a_m + 0.125, -0.0625, 0.03125})
      assert {:ok, replay} = Fusion.update_loose_time_sync(filter, measurement)

      assert replay.late_measurement
      assert replay.replayed_imu_segments == 2
      assert replay.restored_checkpoint_epoch_j2000_s == 0.0
      assert replay.current_epoch_j2000_s == 1.0
      assert_close(replay.update.ekf.normalized_innovation_squared, 1.4621778929641867, 1.0e-15)

      assert {:ok, state} = Fusion.state(filter)

      assert_close_list(
        state.nominal.position_ecef_m,
        [6_378_133.079894195, -0.024082608777344475, 0.012045192861894557],
        1.0e-9
      )

      assert_close_list(
        state.nominal.velocity_ecef_mps,
        [-9.239849729735642, -0.018580347981844634, 0.009352192649096992],
        1.0e-12
      )

      assert_close_list(
        state.nominal.accel_bias_mps2,
        [-0.14311361988921348, 0.003005825348950222, -0.0015030196794807622],
        1.0e-15
      )

      assert_close_matrix(
        Enum.take(state.covariance, 3),
        [
          [1.6164049342830498, 3.9115321562775126e-5, -1.948803723289005e-5],
          [3.9115321562775126e-5, 1.616530643848043, 5.628511790746189e-6],
          [-1.948803723289005e-5, 5.628511790746189e-6, 1.6165390997724811]
        ],
        1.0e-15
      )

      assert {:ok, status} = Fusion.time_sync_status(filter)
      assert status.imu_len == 1
      assert status.checkpoint_len == 2
      assert status.newest_checkpoint_epoch_j2000_s == 0.75
    end

    test "applies tight pseudorange and range-rate rows from an SP3 source" do
      sp3 = SP3.load!(@sp3_path)
      epoch = SP3.coverage(sp3).start_j2000_s
      {:ok, satellite} = SP3.state(sp3, "G01", 0)

      rho =
        :math.sqrt(
          :math.pow(satellite.x_m - @wgs84_a_m, 2) +
            :math.pow(satellite.y_m, 2) +
            :math.pow(satellite.z_m, 2)
        ) + satellite.clock_s * @c_m_s

      tight_config =
        Fusion.filter_config(zero_imu_spec(), filter_kind: :ekf, tight: %{light_time: false, sagnac: false})

      {:ok, filter} = Fusion.new(%{initial_state(100.0) | t_j2000_s: epoch}, tight_config)

      epoch_observation = %{
        t_j2000_s: epoch,
        observations: [
          %{
            satellite_id: "G01",
            pseudorange_m: rho + 2.0,
            pseudorange_sigma_m: 10.0,
            range_rate: %{
              measured_range_rate_m_s: 0.5,
              sigma_m_s: 2.0,
              satellite_clock_drift_m_s: 0.0
            }
          }
        ]
      }

      assert {:ok, report} = Fusion.update_tight(filter, sp3, epoch_observation)
      assert report.rows == 2
      assert report.applied
      assert_close(report.nis, 0.08525833579508538, 1.0e-15)
      assert_close_list(Enum.take(report.ekf.dx, -2), [9_561.485104261606, -291.81853498313416], 1.0e-9)

      assert {:ok, clock} = Fusion.tight_clock_state(filter)
      assert_close(clock.bias_m, 9_561.485104261606, 1.0e-9)
      assert_close(clock.drift_m_s, -291.81853498313416, 1.0e-12)
      assert_close_matrix(clock.covariance, [[199.99999996000003, 0.0], [0.0, 103.98918512474701]], 1.0e-9)
    end

    test "records robust loose history and smooths fusion RTS output" do
      loose = %{
        update_options: %{innovation_gate: %{threshold_sigma: 4.0, min_rows: 2}},
        measurement_reweighting: :standard,
        prediction_adaptation: :standard
      }

      config = Fusion.filter_config(:mems, loose: loose)
      assert config.loose.measurement_reweighting.k0_sigma == 2.0
      assert config.loose.measurement_reweighting.k1_sigma == 5.0
      assert config.loose.prediction_adaptation.threshold == 1.0
      assert config.loose.prediction_adaptation.outlier_gate_probability == 0.99

      {:ok, filter} = Fusion.new(initial_state(1.0), config)
      assert {:ok, history_builder} = FusionRtsHistoryBuilder.from_filter(filter)

      rate_sample = %{
        t_j2000_s: 1.0,
        kind: :rate,
        specific_force_mps2: {0.0, 0.0, 0.0},
        angular_rate_rps: {0.0, 0.0, 0.0}
      }

      assert {:ok, _state} = Fusion.propagate_recorded(filter, rate_sample, history_builder)

      measurement = %{
        t_j2000_s: 1.0,
        position_ecef_m: {@wgs84_a_m + 0.35, 0.2, -0.1},
        covariance: diagonal3(0.5),
        satellites_used: 7
      }

      assert {:ok, update} = Fusion.update_loose_recorded(filter, measurement, history_builder)
      assert update.applied
      assert {update.rows, update.accepted_rows, update.rejected_rows} == {3, 3, 0}
      assert bits(update.nis) == 0x400A42AD3B07976F
      assert bits(update.ekf.innovation_gate.max_abs_normalized_innovation) == 0x3FFCF4BA7AE7BCC0
      assert update.ekf.innovation_gate.max_rejected_abs_normalized_innovation == nil

      assert {:ok, state} = Fusion.state(filter)

      assert Enum.map(state.nominal.position_ecef_m, &bits/1) == [
               0x415854A602757FB6,
               0x3FC7B6B11D7FA0D8,
               0xBFB7B6B11D5C2B22
             ]

      assert {:ok, recorded} = FusionRtsHistoryBuilder.finish(history_builder)
      recorded_epochs = FusionRtsHistory.epochs(recorded)
      assert FusionRtsHistory.epoch_count(recorded) == 2
      assert length(recorded_epochs) == 2
      assert hd(recorded_epochs).transition_from_previous == nil

      transition = Enum.at(recorded_epochs, 1).transition_from_previous
      assert length(transition) == 15
      assert transition |> hd() |> length() == 15

      assert [
               bits(Enum.at(Enum.at(transition, 0), 0)),
               bits(Enum.at(Enum.at(transition, 1), 1)),
               bits(Enum.at(Enum.at(transition, 2), 2))
             ] == [
               0x3FF000019D17A15A,
               0x3FEFFFFE650C7E2C,
               0x3FEFFFFE639F13D3
             ]

      assert {:ok, smoothed} = Fusion.smooth_fusion_rts(recorded)
      smoothed_epochs = SmoothedFusionTrajectory.epochs(smoothed)
      assert SmoothedFusionTrajectory.epoch_count(smoothed) == 2
      assert length(smoothed_epochs) == 2

      smoothed0 = Enum.at(smoothed_epochs, 0)
      smoothed1 = Enum.at(smoothed_epochs, 1)
      assert length(smoothed0.rts_gain_to_next) == 17
      assert smoothed0.rts_gain_to_next |> hd() |> length() == 17
      assert smoothed1.rts_gain_to_next == nil

      assert Enum.map(smoothed0.snapshot.state.nominal.position_ecef_m, &bits/1) == [
               0x415854A6AFB47DAB,
               0x3FB5122C16E56642,
               0xBFA5122C1780E0A5
             ]

      assert Enum.map(smoothed1.snapshot.state.nominal.position_ecef_m, &bits/1) == [
               0x415854A602757FB6,
               0x3FC7B6B11D7FA0D8,
               0xBFB7B6B11D5C2B22
             ]

      assert smoothed0.error_state_correction |> Enum.take(6) |> Enum.map(&bits/1) == [
               0xBFFBED1F6AC3E068,
               0xBFB5122C16E56642,
               0x3FA5122C1780E0A5,
               0xBFFBED164E925C0A,
               0xBFB51A847AAA1978,
               0x3FA5122D270AB803
             ]

      assert [
               bits(Enum.at(Enum.at(smoothed0.covariance, 0), 0)),
               bits(Enum.at(Enum.at(smoothed0.covariance, 1), 1)),
               bits(Enum.at(Enum.at(smoothed0.covariance, 2), 2))
             ] == [
               0x3FFDC64F219100F6,
               0x3FFA44D611536A90,
               0x3FFA44D6119F127C
             ]
    end
  end

  defp config(kind), do: Fusion.filter_config(zero_imu_spec(), filter_kind: kind)

  defp zero_imu_spec do
    %{
      accel_vrw_mps_sqrt_s: 0.0,
      gyro_arw_rad_sqrt_s: 0.0,
      accel_bias_instab_mps2: 0.0,
      gyro_bias_instab_rps: 0.0,
      accel_bias_tau_s: 3_600.0,
      gyro_bias_tau_s: 3_600.0,
      accel_scale_instab_ppm: nil,
      gyro_scale_instab_ppm: nil
    }
  end

  defp initial_state(covariance \\ 1.0) do
    %{
      t_j2000_s: 0.0,
      position_ecef_m: {@wgs84_a_m, 0.0, 0.0},
      velocity_ecef_mps: {0.0, 0.0, 0.0},
      attitude_body_to_ecef: diagonal3(1.0),
      covariance_diagonal: List.duplicate(covariance, 15)
    }
  end

  defp loose_measurement(t_j2000_s, position_ecef_m) do
    %{
      t_j2000_s: t_j2000_s,
      position_ecef_m: position_ecef_m,
      covariance: diagonal3(4.0),
      satellites_used: 8
    }
  end

  defp increment_sample(t_j2000_s, dt_s) do
    %{
      t_j2000_s: t_j2000_s,
      kind: :increment,
      delta_velocity_mps: {0.015625 * dt_s, -0.0078125 * dt_s, 0.00390625 * dt_s},
      delta_theta_rad: {@omega_e_dot_rad_s * dt_s, 0.0009765625 * dt_s, -0.00048828125 * dt_s},
      dt_s: dt_s
    }
  end

  defp diagonal3(value), do: diagonal(3, value)

  defp diagonal(size, value) do
    Enum.map(0..(size - 1), fn row ->
      Enum.map(0..(size - 1), fn column ->
        if row == column, do: value, else: 0.0
      end)
    end)
  end

  defp assert_close(actual, expected, tolerance) do
    if tolerance == 0.0 do
      assert actual == expected
    else
      assert_in_delta actual, expected, tolerance
    end
  end

  defp bits(value) do
    <<bits::64>> = <<value::float-64>>
    bits
  end

  defp assert_close_list(actual, expected, tolerance) do
    if tolerance == 0.0 do
      assert actual == expected
    else
      actual
      |> Enum.zip(expected)
      |> Enum.each(fn {actual_value, expected_value} ->
        assert_in_delta actual_value, expected_value, tolerance
      end)
    end
  end

  defp assert_close_matrix(actual, expected, tolerance) do
    actual
    |> Enum.zip(expected)
    |> Enum.each(fn {actual_row, expected_row} ->
      assert_close_list(actual_row, expected_row, tolerance)
    end)
  end

  defp top_left(matrix, size) do
    matrix
    |> Enum.take(size)
    |> Enum.map(&Enum.take(&1, size))
  end
end
