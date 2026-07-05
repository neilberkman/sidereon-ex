defmodule Sidereon.GNSS.PositioningDopplerTest do
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.Geometry
  alias Sidereon.GNSS.Observables
  alias Sidereon.GNSS.Positioning
  alias Sidereon.GNSS.SP3
  alias Sidereon.GNSS.Velocity

  @sp3_path Path.join(__DIR__, "fixtures/sp3/GRG0MGXFIN_20201760000_01D_15M_ORB.SP3")
  @epoch ~N[2020-06-24 12:00:00]
  @receiver {4_500_000.0, 500_000.0, 4_500_000.0}
  @initial_guess {4_400_000.0, 400_000.0, 4_400_000.0, 0.0}
  @c 299_792_458.0
  @f_l1 1_575_420_000.0

  setup_all do
    sp3 = SP3.load!(@sp3_path)

    satellites =
      sp3
      |> Geometry.visible(@receiver, @epoch, systems: ["G"], elevation_mask_deg: 5.0)
      |> Enum.map(& &1.satellite_id)
      |> Enum.take(7)

    {:ok, sp3: sp3, satellites: satellites}
  end

  test "pins receiver clock drift, position covariance, and Doppler velocity solve", ctx do
    # Reference literals generated from sidereon-core through this binding
    # against the patched core on 2026-07-05.
    velocity_m_s = {12.0, -7.0, 3.0}
    clock_drift_s_s = 1.0e-9
    pseudoranges = pseudoranges(ctx.sp3, ctx.satellites)
    doppler_rows = doppler_rows(ctx.sp3, ctx.satellites, velocity_m_s, clock_drift_s_s)

    assert {:ok, %Positioning.DopplerSolution{} = solution} =
             Positioning.solve_with_doppler(ctx.sp3, pseudoranges, doppler_rows, @epoch, initial_guess: @initial_guess)

    receiver = solution.receiver

    assert_in_delta receiver.position.x_m, 4_500_000.000329243, 1.0e-9
    assert_in_delta receiver.position.y_m, 500_000.00014028087, 1.0e-9
    assert_in_delta receiver.position.z_m, 4_499_999.9999882355, 1.0e-9
    assert_in_delta receiver.rx_clock_s, 7.6325410846169e-13, 1.0e-18
    assert_in_delta receiver.rx_clock_drift_s_s, 1.0000000632745418e-9, 1.0e-16

    assert_in_delta hd(hd(receiver.position_covariance.ecef_m2)), 9.547624510565617, 1.0e-15
    assert_in_delta hd(hd(receiver.position_covariance.enu_m2)), 1.762749075088421, 1.0e-15
    assert receiver.system_clocks_s == %{"G" => receiver.rx_clock_s}
    assert receiver.system_tdops == %{"G" => receiver.dop.tdop}

    assert solution.velocity_error == nil
    assert solution.velocity.n_satellites == 7
    assert solution.velocity.used_sats == ctx.satellites

    {vx, vy, vz} = solution.velocity.velocity_m_s
    assert_in_delta vx, 11.999999990551714, 1.0e-9
    assert_in_delta vy, -6.999999944154055, 1.0e-9
    assert_in_delta vz, 3.0000000246636205, 1.0e-9
    assert_in_delta solution.velocity.clock_drift_s_s, 1.0000000632745418e-9, 1.0e-16
    assert_in_delta solution.velocity.speed_m_s, 14.212670373275376, 1.0e-12

    assert length(solution.velocity.state_covariance) == 4
    assert Enum.all?(solution.velocity.state_covariance, &(length(&1) == 4))
    assert_in_delta hd(hd(solution.velocity.state_covariance)), 5.928888619607572, 1.0e-15
  end

  defp pseudoranges(sp3, satellites) do
    Enum.map(satellites, fn sat ->
      {:ok, obs} = Observables.predict(sp3, sat, @receiver, @epoch, light_time: true, sagnac: true)
      {sat, obs.geometric_range_m + @c * -(obs.sat_clock_s || 0.0)}
    end)
  end

  defp doppler_rows(sp3, satellites, {vx, vy, vz}, clock_drift_s_s) do
    Enum.map(satellites, fn sat ->
      {:ok, obs} = Observables.predict(sp3, sat, @receiver, @epoch, light_time: true, sagnac: true)
      {ex, ey, ez} = obs.los_unit
      rho_dot_m_s = obs.range_rate_m_s - (ex * vx + ey * vy + ez * vz) + @c * clock_drift_s_s
      {sat, Velocity.range_rate_to_doppler(rho_dot_m_s, @f_l1), @f_l1, 0.0}
    end)
  end
end
