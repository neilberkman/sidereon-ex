defmodule Sidereon.EstimationPrimitivesTest do
  use ExUnit.Case, async: true

  alias Sidereon.Estimation
  alias Sidereon.Estimation.AlphaBetaGains
  alias Sidereon.Estimation.AlphaBetaState
  alias Sidereon.Estimation.TrackFilter
  alias Sidereon.Estimation.TrackInnovation

  test "alpha-beta and scalar Kalman gains match the 0.13 reference values" do
    assert {:ok, gains} = Estimation.alpha_beta_steady_state_gains(4.0)
    assert_in_delta gains.alpha, 0.864_145_399_682_717_8, 1.0e-12
    assert_in_delta gains.beta, 0.737_169_180_900_238_8, 1.0e-12

    assert {:ok, kalman} = Estimation.kalman_cv_steady_state_gains(4.0, 1.0, 1.0)
    assert_in_delta kalman.position_gain, gains.alpha, 1.0e-12
    assert_in_delta kalman.rate_gain, gains.beta, 1.0e-12
  end

  test "alpha-beta step, NIS, MAD, EWMA, and CA-CFAR match analytic references" do
    state = %AlphaBetaState{level: 5.0, rate: 2.0}
    gains = %AlphaBetaGains{alpha: 0.6, beta: 0.8}

    assert {:ok, step} = Estimation.alpha_beta_filter_step(state, 8.0, 2.0, gains)
    assert step.predicted == %AlphaBetaState{level: 9.0, rate: 2.0}
    assert step.updated == %AlphaBetaState{level: 8.4, rate: 1.6}
    assert step.innovation == -1.0

    assert {:ok, gate} = Estimation.nis_gate(1.0, 1.0, 1, 0.95)
    assert_in_delta gate.threshold, 3.841_458_820_694_124, 1.0e-12
    assert gate.in_gate
    assert {:ok, 3.0} = Estimation.nis_expected_value(3)
    assert {:ok, 1.0} = Estimation.normalized_innovation(2.0, 4.0)
    assert {:ok, 4.0} = Estimation.nis(2.0, 1.0)
    assert {:ok, 4.0} = Estimation.nis_statistic(2.0, 1.0)
    assert {:ok, gate_test} = Estimation.nis_gate_test(1.0, 1.0, 1, 0.95)
    assert_in_delta gate_test.threshold, 3.841_458_820_694_124, 1.0e-12
    assert gate_test.in_gate

    q75 = 0.674_489_750_196_081_7
    assert {:ok, spread} = Estimation.mad([-2.0 * q75, -q75, 0.0, q75, 2.0 * q75], 1.0e-12)
    assert_in_delta spread, 1.0, 1.0e-12
    assert {:ok, spread_alias} = Estimation.mad_spread([-2.0 * q75, -q75, 0.0, q75, 2.0 * q75], 1.0e-12)
    assert_in_delta spread_alias, 1.0, 1.0e-12

    assert {:ok, ewma} = Estimation.ewma(16.0, 2.0, 1.0 / 16.0)
    assert {:ok, ewma_pow2} = Estimation.ewma_power_of_two(16.0, 2.0, 4)
    assert {:ok, ewma_update} = Estimation.ewma_update(16.0, 2.0, 1.0 / 16.0)
    assert {:ok, ewma_update_pow2} = Estimation.ewma_update_power_of_two(16.0, 2.0, 4)
    assert_in_delta ewma, 15.125, 1.0e-12
    assert_in_delta ewma_pow2, ewma, 1.0e-15
    assert_in_delta ewma_update, 15.125, 1.0e-12
    assert_in_delta ewma_update_pow2, 15.125, 1.0e-12

    assert {:ok, multiplier} = Estimation.cfar_ca_multiplier_from_pfa(4, 1.0e-3)
    assert_in_delta multiplier, 18.493_653_007_613_965, 1.0e-12
    assert {:ok, threshold} = Estimation.cfar_ca_threshold(4, 1.0e-3, 5.0)
    assert threshold == 5.0 * multiplier
    assert {:ok, pfa_back} = Estimation.cfar_ca_false_alarm_probability(4, threshold, 5.0)
    assert_in_delta pfa_back, 1.0e-3, 1.0e-12
  end

  test "track innovation gate uses the NIF-backed chi-square threshold" do
    assert {:ok, filter} =
             TrackFilter.from_position(%{
               frame: :enu,
               initial_t_s: 0.0,
               initial_position_m: [0.0, 0.0],
               position_covariance_m2: [[4.0, 0.0], [0.0, 4.0]],
               initial_velocity_variance_m2_s2: 1.0,
               acceleration_variance_spectral_density_m2_s3: 0.1
             })

    assert {:ok, _prediction} = TrackFilter.predict(filter, 1.0)
    assert {:ok, innovation} = TrackFilter.position_innovation(filter, [0.5, 0.0], [[1.0, 0.0], [0.0, 1.0]])
    assert {:ok, gate} = TrackInnovation.gate(innovation, 0.95)

    assert gate.dof == 2
    assert gate.in_gate
    assert_in_delta gate.threshold, 5.991_464_547_107_979, 1.0e-12
  end
end
