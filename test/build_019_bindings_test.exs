defmodule Sidereon.Build019BindingsTest do
  use ExUnit.Case, async: true

  alias Sidereon.Estimation
  alias Sidereon.Estimation.SmoothedTrack
  alias Sidereon.Estimation.TrackFilter
  alias Sidereon.Estimation.TrackFilterConfig
  alias Sidereon.Estimation.TrackGatedUpdate
  alias Sidereon.Estimation.TrackRtsHistory
  alias Sidereon.Estimation.TrackRtsHistoryBuilder
  alias Sidereon.Estimation.TrackUpdate
  alias Sidereon.Propagator

  test "track filter binding suppresses a position spike through the NIS gate" do
    measurement_covariance = diagonal(3, 9.0)
    spike = [1_000.0, -1_000.0, 500.0]

    assert {:ok, filter} =
             TrackFilter.from_position(%{
               frame: :ecef,
               initial_t_s: 0.0,
               initial_position_m: [0.0, 0.0, 0.0],
               position_covariance_m2: diagonal(3, 25.0),
               initial_velocity_variance_m2_s2: 25.0,
               acceleration_variance_spectral_density_m2_s3: 0.05
             })

    assert {:ok, history} = TrackRtsHistoryBuilder.from_filter(filter)

    assert {:ok, _prediction} = TrackFilter.predict_recorded(filter, 1.0, history)

    assert {:ok, %TrackGatedUpdate{} = accepted} =
             TrackFilter.update_position_gated_recorded(filter, [1.0, 0.2, -0.1], measurement_covariance, 0.99, history)

    assert accepted.gate.in_gate
    assert %TrackUpdate{} = accepted.update

    assert {:ok, _prediction} = TrackFilter.predict_recorded(filter, 1.0, history)

    assert {:ok, %TrackGatedUpdate{} = rejected} =
             TrackFilter.update_position_gated_recorded(filter, spike, measurement_covariance, 0.99, history)

    refute rejected.gate.in_gate
    assert rejected.update == nil
    assert norm(rejected.state.position_m) < norm(spike) / 100.0

    assert {:ok, final_state} = TrackFilter.state(filter)
    assert final_state.position_m == rejected.state.position_m
  end

  test "track history records fix covariance flow and produces smoothed epochs" do
    measurement_covariance = diagonal(3, 4.0)

    assert {:ok, config} =
             TrackFilterConfig.from_position(
               :ecef,
               0.0,
               [0.0, 0.0, 0.0],
               diagonal(3, 16.0),
               36.0,
               0.02
             )

    assert {:ok, filter} = TrackFilter.new(config)
    assert {:ok, history_builder} = TrackRtsHistoryBuilder.from_filter(filter)

    fixes = [[1.0, 0.1, 0.0], [2.0, 0.0, 0.1], [3.0, -0.1, 0.0]]

    Enum.each(fixes, fn fix ->
      assert {:ok, _prediction} = TrackFilter.predict_recorded(filter, 1.0, history_builder)

      assert {:ok, %TrackUpdate{} = update} =
               TrackFilter.update_position_recorded(filter, fix, measurement_covariance, history_builder)

      assert update.innovation.nis >= 0.0
      assert update.updated.dimension == length(fix)
    end)

    assert {:ok, history} = TrackRtsHistoryBuilder.finish(history_builder)
    history_epochs = TrackRtsHistory.epochs(history)
    assert TrackRtsHistory.epoch_count(history) == length(history_epochs)
    assert length(history_epochs) == length(fixes) + 1

    assert {:ok, smoothed} = Estimation.smooth_track_rts(history)
    smoothed_epochs = SmoothedTrack.epochs(smoothed)
    assert SmoothedTrack.epoch_count(smoothed) == length(smoothed_epochs)
    assert length(smoothed_epochs) == length(history_epochs)
    assert List.last(smoothed_epochs).state.position_m == List.last(history_epochs).updated.position_m
  end

  test "solid Earth tide force tokens marshal through propagation" do
    state = {{7000.0, 0.0, 1300.0}, {0.0, 7.4, 1.0}}

    assert {:ok, {{x, y, z}, {vx, vy, vz}}} =
             Propagator.propagate(state, 10.0,
               forces: [:composite, {:geopotential, 4, 0}, :solid_earth_tide, :solid_earth_pole_tide],
               tolerance: 1.0e-10
             )

    assert Enum.all?([x, y, z, vx, vy, vz], &is_float/1)
  end

  defp diagonal(size, value) do
    for row <- 0..(size - 1) do
      for col <- 0..(size - 1) do
        if row == col, do: value, else: 0.0
      end
    end
  end

  defp norm(values) do
    values
    |> Enum.map(&(&1 * &1))
    |> Enum.sum()
    |> :math.sqrt()
  end
end
