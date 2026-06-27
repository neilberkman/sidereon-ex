defmodule Sidereon.GNSS.VelocityTest do
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.Geometry
  alias Sidereon.GNSS.Observables
  alias Sidereon.GNSS.SP3
  alias Sidereon.GNSS.Velocity

  # The velocity estimate is validated by injected-velocity recovery, not by
  # self-consistency: we pick a TRUE receiver velocity and clock drift, synthesize
  # the pseudorange rate each visible GPS satellite would produce under the
  # documented model, then assert the solve recovers the truth. The forward
  # geometry (line of sight and the e.v_sat projection) comes from the same
  # precise SP3 fixture used by the positioning tests.
  @sp3_path Path.join(__DIR__, "fixtures/sp3/GRG0MGXFIN_20201760000_01D_15M_ORB.SP3")
  @epoch ~N[2020-06-24 12:00:00]

  # A receiver position with good GPS visibility for this fixture/epoch (the
  # positioning test's frozen initial guess sits in this region).
  @receiver {4_500_000.0, 500_000.0, 4_500_000.0}

  # Speed of light, m/s (matches Sidereon.GNSS.Observables and the module under test).
  @c 299_792_458.0
  @f_l1 1_575_420_000.0

  setup_all do
    sp3 = SP3.load!(@sp3_path)

    sats =
      sp3
      |> Geometry.visible(@receiver, @epoch, systems: ["G"], elevation_mask_deg: 5.0)
      |> Enum.map(& &1.satellite_id)

    # Sanity: the velocity solve needs at least four satellites.
    true = length(sats) >= 4

    {:ok, sp3: sp3, sats: sats}
  end

  # The static-receiver e.v_sat term for a satellite, from the forward model.
  defp e_dot_vsat(sp3, sat) do
    {:ok, obs} = Observables.predict(sp3, sat, @receiver, @epoch)
    obs.range_rate_m_s
  end

  # Synthesize the measured pseudorange rate for `sat` under a TRUE receiver
  # velocity and clock drift, with the satellite clock drift taken as zero (the
  # estimator's default), so the model term cancels exactly:
  #   rho_dot = e.(v_sat - v_true) + c*drift_true
  #           = (e.v_sat) - e.v_true + c*drift_true.
  defp synth_rho_dot(sp3, sat, {tx, ty, tz}, drift_true) do
    {:ok, obs} = Observables.predict(sp3, sat, @receiver, @epoch)
    {ex, ey, ez} = obs.los_unit
    e_dot_vtrue = ex * tx + ey * ty + ez * tz
    obs.range_rate_m_s - e_dot_vtrue + @c * drift_true
  end

  defp synth_observations(sp3, sats, v_true, drift_true) do
    Enum.map(sats, fn sat -> {sat, synth_rho_dot(sp3, sat, v_true, drift_true)} end)
  end

  describe "solve/5 injected-velocity recovery" do
    test "recovers a nonzero receiver velocity and clock drift to sub-mm/s", ctx do
      v_true = {12.0, -7.0, 3.0}
      drift_true = 1.0e-9

      observations = synth_observations(ctx.sp3, ctx.sats, v_true, drift_true)

      assert {:ok, result} = Velocity.solve(ctx.sp3, observations, @epoch, @receiver)

      {vx, vy, vz} = result.velocity_m_s
      {tx, ty, tz} = v_true

      max_err =
        [abs(vx - tx), abs(vy - ty), abs(vz - tz)] |> Enum.max()

      assert max_err < 1.0e-4, "velocity max error #{max_err} m/s"
      assert abs(result.clock_drift_s_s - drift_true) < 1.0e-13
      assert result.n_satellites == length(ctx.sats)
      assert result.used_sats == ctx.sats
    end

    test "recovers a static receiver as ~zero speed", ctx do
      observations = synth_observations(ctx.sp3, ctx.sats, {0.0, 0.0, 0.0}, 0.0)

      assert {:ok, result} = Velocity.solve(ctx.sp3, observations, @epoch, @receiver)

      assert result.speed_m_s < 1.0e-4
      {vx, vy, vz} = result.velocity_m_s
      assert abs(vx) < 1.0e-4 and abs(vy) < 1.0e-4 and abs(vz) < 1.0e-4
      assert abs(result.clock_drift_s_s) < 1.0e-13
    end
  end

  describe "solve/5 Doppler path" do
    test "agrees with the range-rate path", ctx do
      v_true = {12.0, -7.0, 3.0}
      drift_true = 1.0e-9

      rr_obs = synth_observations(ctx.sp3, ctx.sats, v_true, drift_true)

      doppler_obs =
        Enum.map(rr_obs, fn {sat, rho_dot} ->
          {sat, Velocity.range_rate_to_doppler(rho_dot, @f_l1)}
        end)

      assert {:ok, rr} = Velocity.solve(ctx.sp3, rr_obs, @epoch, @receiver)

      assert {:ok, dop} =
               Velocity.solve(ctx.sp3, doppler_obs, @epoch, @receiver, observable: :doppler)

      {rx, ry, rz} = rr.velocity_m_s
      {dx, dy, dz} = dop.velocity_m_s

      assert abs(rx - dx) < 1.0e-6
      assert abs(ry - dy) < 1.0e-6
      assert abs(rz - dz) < 1.0e-6
      assert abs(rr.clock_drift_s_s - dop.clock_drift_s_s) < 1.0e-15
    end
  end

  describe "solve/5 per-satellite Doppler carrier (GLONASS FDMA)" do
    # Assign each satellite a distinct carrier the way GLONASS FDMA does:
    # G1 = 1602 MHz + k * 562.5 kHz, sweeping k across [-7, 6].
    defp per_sat_carriers(sats) do
      sats
      |> Enum.with_index()
      |> Map.new(fn {sat, i} ->
        k = rem(i, 14) - 7
        {sat, 1_602_000_000.0 + k * 562_500.0}
      end)
    end

    test "omitting :carrier_hz_by_sat reproduces the single-carrier result exactly", ctx do
      v_true = {12.0, -7.0, 3.0}
      drift_true = 1.0e-9
      rr_obs = synth_observations(ctx.sp3, ctx.sats, v_true, drift_true)

      doppler_obs =
        Enum.map(rr_obs, fn {sat, rho_dot} ->
          {sat, Velocity.range_rate_to_doppler(rho_dot, @f_l1)}
        end)

      assert {:ok, base} =
               Velocity.solve(ctx.sp3, doppler_obs, @epoch, @receiver, observable: :doppler)

      assert {:ok, same} =
               Velocity.solve(ctx.sp3, doppler_obs, @epoch, @receiver,
                 observable: :doppler,
                 carrier_hz: @f_l1
               )

      assert same.velocity_m_s == base.velocity_m_s
      assert same.clock_drift_s_s == base.clock_drift_s_s
    end

    test "per-sat carriers recover the truth that the single-L1 path gets wrong", ctx do
      v_true = {12.0, -7.0, 3.0}
      drift_true = 1.0e-9
      carriers = per_sat_carriers(ctx.sats)
      rr_obs = synth_observations(ctx.sp3, ctx.sats, v_true, drift_true)

      # Synthesize each Doppler with that satellite's OWN carrier.
      doppler_obs =
        Enum.map(rr_obs, fn {sat, rho_dot} ->
          {sat, Velocity.range_rate_to_doppler(rho_dot, Map.fetch!(carriers, sat))}
        end)

      # Solving with the correct per-sat carriers recovers the truth.
      assert {:ok, good} =
               Velocity.solve(ctx.sp3, doppler_obs, @epoch, @receiver,
                 observable: :doppler,
                 carrier_hz_by_sat: carriers
               )

      {gx, gy, gz} = good.velocity_m_s
      {tx, ty, tz} = v_true
      good_err = [abs(gx - tx), abs(gy - ty), abs(gz - tz)] |> Enum.max()
      assert good_err < 1.0e-4, "per-sat carrier velocity max error #{good_err} m/s"

      # Solving the SAME Doppler with the single GPS-L1 carrier is materially off
      # (the FDMA carrier mismatch biases the range rate), proving the per-sat
      # wiring is load-bearing.
      assert {:ok, wrong} =
               Velocity.solve(ctx.sp3, doppler_obs, @epoch, @receiver, observable: :doppler)

      {wx, wy, wz} = wrong.velocity_m_s
      wrong_err = [abs(wx - tx), abs(wy - ty), abs(wz - tz)] |> Enum.max()
      assert wrong_err > 0.1, "single-L1 path was unexpectedly accurate (#{wrong_err} m/s)"
    end

    test "a function resolver works when it covers every satellite", ctx do
      v_true = {12.0, -7.0, 3.0}
      drift_true = 1.0e-9
      carriers = per_sat_carriers(ctx.sats)
      rr_obs = synth_observations(ctx.sp3, ctx.sats, v_true, drift_true)

      doppler_obs =
        Enum.map(rr_obs, fn {sat, rho_dot} ->
          {sat, Velocity.range_rate_to_doppler(rho_dot, Map.fetch!(carriers, sat))}
        end)

      assert {:ok, via_fun} =
               Velocity.solve(ctx.sp3, doppler_obs, @epoch, @receiver,
                 observable: :doppler,
                 carrier_hz_by_sat: fn sat -> Map.get(carriers, sat) end
               )

      assert {:ok, via_map} =
               Velocity.solve(ctx.sp3, doppler_obs, @epoch, @receiver,
                 observable: :doppler,
                 carrier_hz_by_sat: carriers
               )

      assert via_fun.velocity_m_s == via_map.velocity_m_s
    end

    test "an explicit carrier map missing a satellite is tagged", ctx do
      [first | _] = ctx.sats
      doppler_obs = Enum.map(ctx.sats, fn sat -> {sat, 1.0} end)

      assert {:error, {:missing_carrier, ^first}} =
               Velocity.solve(ctx.sp3, doppler_obs, @epoch, @receiver,
                 observable: :doppler,
                 carrier_hz_by_sat: %{}
               )
    end

    test "an explicit carrier function returning nil is tagged", ctx do
      [first | _] = ctx.sats
      doppler_obs = Enum.map(ctx.sats, fn sat -> {sat, 1.0} end)

      assert {:error, {:missing_carrier, ^first}} =
               Velocity.solve(ctx.sp3, doppler_obs, @epoch, @receiver,
                 observable: :doppler,
                 carrier_hz_by_sat: fn _sat -> nil end
               )
    end

    test "a non-positive per-sat carrier surfaces {:invalid_carrier, sat}", ctx do
      [first | _] = ctx.sats
      doppler_obs = Enum.map(ctx.sats, fn sat -> {sat, 1.0} end)

      assert {:error, {:invalid_carrier, ^first}} =
               Velocity.solve(ctx.sp3, doppler_obs, @epoch, @receiver,
                 observable: :doppler,
                 carrier_hz_by_sat: %{first => -1.0}
               )
    end

    test "a non-finite per-sat carrier surfaces {:invalid_carrier, sat}", ctx do
      [first | _] = ctx.sats
      doppler_obs = Enum.map(ctx.sats, fn sat -> {sat, 1.0} end)

      assert {:error, {:invalid_carrier, ^first}} =
               Velocity.solve(ctx.sp3, doppler_obs, @epoch, @receiver,
                 observable: :doppler,
                 carrier_hz_by_sat: %{first => :infinity}
               )
    end

    test "per-sat carriers are ignored on the :range_rate path", ctx do
      observations = synth_observations(ctx.sp3, ctx.sats, {12.0, -7.0, 3.0}, 1.0e-9)

      assert {:ok, base} = Velocity.solve(ctx.sp3, observations, @epoch, @receiver)

      # A bogus carrier map must not affect the range-rate path (no conversion).
      assert {:ok, same} =
               Velocity.solve(ctx.sp3, observations, @epoch, @receiver,
                 carrier_hz_by_sat: %{hd(ctx.sats) => -1.0}
               )

      assert same.velocity_m_s == base.velocity_m_s
    end
  end

  describe "solve/5 residuals" do
    test "a consistent set has ~zero residuals", ctx do
      observations = synth_observations(ctx.sp3, ctx.sats, {12.0, -7.0, 3.0}, 1.0e-9)

      assert {:ok, result} = Velocity.solve(ctx.sp3, observations, @epoch, @receiver)

      for {_sat, r} <- result.residuals_m_s do
        assert abs(r) < 1.0e-6
      end
    end

    test "perturbing one observation shows up in that satellite's residual", ctx do
      observations = synth_observations(ctx.sp3, ctx.sats, {12.0, -7.0, 3.0}, 1.0e-9)

      [{bad_sat, bad_val} | rest] = observations
      perturbed = [{bad_sat, bad_val + 2.0} | rest]

      assert {:ok, result} = Velocity.solve(ctx.sp3, perturbed, @epoch, @receiver)

      perturbed_residual = abs(result.residuals_m_s[bad_sat])

      others_max =
        result.residuals_m_s
        |> Map.delete(bad_sat)
        |> Map.values()
        |> Enum.map(&abs/1)
        |> Enum.max()

      # The perturbed satellite's residual is clearly nonzero and dominates.
      assert perturbed_residual > 0.5
      assert perturbed_residual > others_max
    end
  end

  describe "solve/5 errors (no raise)" do
    test "empty observations is tagged", ctx do
      assert {:error, :no_observations} = Velocity.solve(ctx.sp3, [], @epoch, @receiver)
    end

    test "fewer than four satellites is tagged", ctx do
      three = ctx.sats |> Enum.take(3) |> synth_three(ctx.sp3)

      assert {:error, {:too_few_satellites, 3, 4}} =
               Velocity.solve(ctx.sp3, three, @epoch, @receiver)
    end

    test "a malformed receiver is tagged", ctx do
      observations = synth_observations(ctx.sp3, ctx.sats, {1.0, 2.0, 3.0}, 0.0)

      assert {:error, :invalid_receiver} =
               Velocity.solve(ctx.sp3, observations, @epoch, {:bad, :receiver, nil})
    end

    test "a malformed observation entry is tagged", ctx do
      assert {:error, {:invalid_observation, {"G01", :nope}}} =
               Velocity.solve(ctx.sp3, [{"G01", :nope}], @epoch, @receiver)
    end

    test "a malformed satellite id is tagged instead of dropped", ctx do
      assert {:error, {:bad_sat_id, "GXX"}} =
               Velocity.solve(ctx.sp3, [{"GXX", 1.0}], @epoch, @receiver)
    end

    test "a duplicate satellite is tagged", ctx do
      assert {:error, {:duplicate_observation, "G01"}} =
               Velocity.solve(
                 ctx.sp3,
                 [{"G01", 1.0}, {"G02", 2.0}, {"G01", 3.0}, {"G05", 4.0}],
                 @epoch,
                 @receiver
               )
    end

    test "a rank-deficient normal matrix is reported as singular (no raise)", _ctx do
      # A full-rank four-satellite geometry from a real precise ephemeris never
      # produces a rank-deficient normal matrix, so the solve's singular branch is
      # exercised at the inverse it depends on: Geometry.inv4/1 returns
      # :singular for a rank-deficient matrix, which solve/5 maps to
      # {:error, :singular_geometry}. This is the same contract the positioning
      # path documents for its own non-physical singular case.
      assert :singular =
               Geometry.inv4(
                 {{1.0, 0.0, 0.0, 0.0}, {0.0, 1.0, 0.0, 0.0}, {0.0, 0.0, 1.0, 0.0},
                  {0.0, 0.0, 0.0, 0.0}}
               )
    end
  end

  # Build observations for exactly three given sats (for the too-few test).
  defp synth_three(sats, sp3) do
    Enum.map(sats, fn sat -> {sat, e_dot_vsat(sp3, sat)} end)
  end
end
