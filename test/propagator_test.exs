defmodule Sidereon.PropagatorTest do
  use ExUnit.Case, async: true

  alias Sidereon.Forces.J2
  alias Sidereon.Forces.TwoBody
  alias Sidereon.Propagator

  describe "force acceleration bindings" do
    test "two-body acceleration is delegated to the core force model" do
      acceleration = TwoBody.acceleration({7000.0, -1210.0, 1300.0}, {0.0, 0.0, 0.0})

      assert bits_tuple(acceleration) ==
               {13_798_562_943_973_640_097, 4_563_548_234_789_153_053, 13_787_359_517_156_423_902}
    end

    test "J2 acceleration is delegated to the core force model" do
      acceleration = J2.acceleration({7000.0, -1210.0, 1300.0}, {0.0, 0.0, 0.0})

      assert bits_tuple(acceleration) ==
               {13_754_131_348_549_160_135, 4_519_025_615_523_880_849, 13_750_824_904_549_515_386}
    end
  end

  describe "Two-Body RK4 propagation (Elixir)" do
    test "circular orbit remains circular after one step" do
      r0 = {7000.0, 0.0, 0.0}
      v0 = {0.0, 7.5460533, 0.0}
      state = {r0, v0}
      forces = [&TwoBody.acceleration/2]
      {r1, v1} = Propagator.propagate_rk4(state, 10.0, forces)
      dist1 = :math.sqrt(elem(r1, 0) ** 2 + elem(r1, 1) ** 2 + elem(r1, 2) ** 2)
      assert_in_delta dist1, 7000.0, 1.0e-3
      speed1 = :math.sqrt(elem(v1, 0) ** 2 + elem(v1, 1) ** 2 + elem(v1, 2) ** 2)
      assert_in_delta speed1, 7.5460533, 1.0e-6
    end
  end

  describe "J2 Perturbation (NIF)" do
    test "nodes regress for an inclined orbit" do
      r0 = {7000.0, 0.0, 0.0}
      v_mag = :math.sqrt(398_600.4418 / 7000.0)
      i = 98.0 * :math.pi() / 180.0
      v0 = {0.0, v_mag * :math.cos(i), v_mag * :math.sin(i)}
      state = {r0, v0}

      # Propagate for one orbit (~5828s)
      dt = 5828.5

      {:ok, final_kepler} = Propagator.propagate(state, dt, forces: ["twobody"])
      {:ok, final_j2} = Propagator.propagate(state, dt, forces: ["twobody", "j2"])

      {rk, _} = final_kepler
      {rj, _} = final_j2

      diff =
        :math.sqrt(
          (elem(rk, 0) - elem(rj, 0)) ** 2 +
            (elem(rk, 1) - elem(rj, 1)) ** 2 +
            (elem(rk, 2) - elem(rj, 2)) ** 2
        )

      # J2 should cause a several-kilometer difference after one orbit
      assert diff > 30.0
      assert diff < 40.0
    end
  end

  describe "High-Precision Adaptive Propagation (NIF Adaptive DP54)" do
    test "circular orbit is accurate to machine precision over a full period" do
      r_mag = 7000.0
      mu = 398_600.4418
      v_mag = :math.sqrt(mu / r_mag)
      period = 2.0 * :math.pi() * :math.sqrt(:math.pow(r_mag, 3) / mu)

      r0 = {r_mag, 0.0, 0.0}
      v0 = {0.0, v_mag, 0.0}
      state = {r0, v0}

      e0 = 0.5 * v_mag ** 2 - mu / r_mag

      # NIF Adaptive with strict tolerance
      {:ok, final_state} = Propagator.propagate(state, period, tolerance: 1.0e-12)

      {rf, vf} = final_state
      # Return to start {7000, 0, 0} with sub-millimeter precision
      assert_in_delta elem(rf, 0), 7000.0, 1.0e-7
      assert_in_delta elem(rf, 1), 0.0, 1.0e-7

      # Energy conservation
      rf_mag = :math.sqrt(elem(rf, 0) ** 2 + elem(rf, 1) ** 2 + elem(rf, 2) ** 2)
      vf_mag = :math.sqrt(elem(vf, 0) ** 2 + elem(vf, 1) ** 2 + elem(vf, 2) ** 2)
      ef = 0.5 * vf_mag ** 2 - mu / rf_mag

      assert_in_delta ef, e0, 1.0e-10
    end

    test "circular orbit with J2 matches analytical RAAN drift rate" do
      # Analytical RAAN drift rate: -1.5 * J2 * (Re/a)^2 * n * cos(i)
      r_mag = 7000.0
      inc_deg = 98.0
      inc_rad = inc_deg * :math.pi() / 180.0
      mu = 398_600.4418
      re = 6378.137
      j2 = 1.08262668e-3

      v_mag = :math.sqrt(mu / r_mag)
      r0 = {r_mag, 0.0, 0.0}
      v0 = {0.0, v_mag * :math.cos(inc_rad), v_mag * :math.sin(inc_rad)}
      state = {r0, v0}

      t_end = 86400.0

      {:ok, {rf, vf}} =
        Propagator.propagate(state, t_end, forces: ["twobody", "j2"], tolerance: 1.0e-12)

      n = :math.sqrt(mu / :math.pow(r_mag, 3))
      raan_drift_rate = -1.5 * j2 * :math.pow(re / r_mag, 2) * n * :math.cos(inc_rad)
      expected_drift = raan_drift_rate * t_end

      {rx, ry, rz} = rf
      {vx, vy, vz} = vf
      h = {ry * vz - rz * vy, rz * vx - rx * vz, rx * vy - ry * vx}
      node_vec = {-elem(h, 1), elem(h, 0), 0.0}
      actual_raan = :math.atan2(elem(node_vec, 1), elem(node_vec, 0))

      h0 = {0.0, -r_mag * v_mag * :math.sin(inc_rad), r_mag * v_mag * :math.cos(inc_rad)}
      n0 = {-elem(h0, 1), elem(h0, 0), 0.0}
      initial_raan = :math.atan2(elem(n0, 1), elem(n0, 0))

      actual_drift = actual_raan - initial_raan
      actual_drift = normalize_angle(actual_drift)

      assert_in_delta actual_drift, expected_drift, abs(expected_drift) * 0.01
    end
  end

  defp normalize_angle(angle) do
    cond do
      angle > :math.pi() -> normalize_angle(angle - 2 * :math.pi())
      angle <= -:math.pi() -> normalize_angle(angle + 2 * :math.pi())
      true -> angle
    end
  end

  defp bits_tuple({x, y, z}), do: {float_bits(x), float_bits(y), float_bits(z)}

  defp float_bits(value) do
    <<bits::64>> = <<value::float-64>>
    bits
  end
end
