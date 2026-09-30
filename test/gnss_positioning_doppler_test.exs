defmodule Sidereon.GNSS.PositioningDopplerTest do
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.Positioning
  alias Sidereon.GNSS.SP3
  alias Sidereon.Test.CoreGolden

  @sp3_path Path.join(__DIR__, "fixtures/sp3/GRG0MGXFIN_20201760000_01D_15M_ORB.SP3")
  @c 299_792_458.0

  # The core's own SPP agreement bound (`AGREEMENT_BOUND_M` in its SPP tests):
  # the binding's solve agrees with the core's solve of the same inputs to
  # within it, and a clock to within it over c.
  @core_agreement_bound_m 1.0e-6

  setup_all do
    golden = CoreGolden.load("doppler_solve.json")

    doppler_rows =
      Enum.map(golden["doppler"], fn [sat, doppler_hz, carrier_hz, drift] ->
        {sat, CoreGolden.f(doppler_hz), CoreGolden.f(carrier_hz), CoreGolden.f(drift)}
      end)

    {:ok,
     sp3: SP3.load!(@sp3_path),
     golden: golden,
     epoch: NaiveDateTime.from_iso8601!(golden["epoch"]),
     pseudoranges: CoreGolden.observations(golden["observations"]),
     doppler_rows: doppler_rows}
  end

  test "matches the core Doppler solve of the same pseudoranges and Doppler rows", ctx do
    assert {:ok, %Positioning.DopplerSolution{} = solution} =
             Positioning.solve_with_doppler(ctx.sp3, ctx.pseudoranges, ctx.doppler_rows, ctx.epoch,
               initial_guess: ctx.golden["initial_guess"] |> CoreGolden.f() |> List.to_tuple()
             )

    receiver = solution.receiver
    expected = ctx.golden["receiver"]

    [ex, ey, ez] = CoreGolden.f(expected["position_m"])
    assert_in_delta receiver.position.x_m, ex, @core_agreement_bound_m
    assert_in_delta receiver.position.y_m, ey, @core_agreement_bound_m
    assert_in_delta receiver.position.z_m, ez, @core_agreement_bound_m
    assert_in_delta receiver.rx_clock_s, CoreGolden.f(expected["rx_clock_s"]), @core_agreement_bound_m / @c

    assert_in_delta receiver.rx_clock_drift_s_s,
                    CoreGolden.f(expected["rx_clock_drift_s_s"]),
                    @core_agreement_bound_m / @c

    assert receiver.used_sats == expected["used_sats"]
    assert receiver.metadata.status == CoreGolden.status_atom(expected["status"])
    assert receiver.metadata.iterations == expected["iterations"]

    # The covariances are the geometry's, which moves with the solution only by
    # the agreement bound over the satellite range, about 5e-14 relative;
    # 1e-9 relative is far above that and far below any real change.
    assert_matrix_relative(receiver.position_covariance.ecef_m2, CoreGolden.f(expected["position_covariance_ecef_m2"]))
    assert_matrix_relative(receiver.position_covariance.enu_m2, CoreGolden.f(expected["position_covariance_enu_m2"]))
    assert receiver.system_clocks_s == %{"G" => receiver.rx_clock_s}
    assert receiver.system_tdops == %{"G" => receiver.dop.tdop}

    velocity = ctx.golden["velocity"]
    assert solution.velocity_error == nil
    assert solution.velocity.n_satellites == length(velocity["used_sats"])
    assert solution.velocity.used_sats == velocity["used_sats"]

    # The velocity rows are linearized at the solved position, so the velocity
    # agrees with the core's to the agreement bound over the satellite range
    # times the satellite speed, below 1e-9 m/s; 1e-9 bounds it.
    {vx, vy, vz} = solution.velocity.velocity_m_s
    [evx, evy, evz] = CoreGolden.f(velocity["velocity_m_s"])
    assert_in_delta vx, evx, 1.0e-9
    assert_in_delta vy, evy, 1.0e-9
    assert_in_delta vz, evz, 1.0e-9
    assert_in_delta solution.velocity.clock_drift_s_s, CoreGolden.f(velocity["clock_drift_s_s"]), 1.0e-9 / @c
    assert_in_delta solution.velocity.speed_m_s, CoreGolden.f(velocity["speed_m_s"]), 1.0e-9
    assert_matrix_relative(solution.velocity.state_covariance, CoreGolden.f(velocity["state_covariance"]))
  end

  test "recovers the receiver, velocity and clock drift the rows were formed at", ctx do
    assert {:ok, solution} =
             Positioning.solve_with_doppler(ctx.sp3, ctx.pseudoranges, ctx.doppler_rows, ctx.epoch,
               initial_guess: {4_400_000.0, 400_000.0, 4_400_000.0, 0.0}
             )

    {tx, ty, tz} = CoreGolden.tuple3(ctx.golden["receiver_truth_m"])
    assert_in_delta solution.receiver.position.x_m, tx, 1.0e-3
    assert_in_delta solution.receiver.position.y_m, ty, 1.0e-3
    assert_in_delta solution.receiver.position.z_m, tz, 1.0e-3

    # The Doppler rows are formed from the forward prediction's range rate,
    # the satellite velocity differenced over +/- 0.5 s in the rotated frame;
    # the solve forms it from the state the pseudorange places and the
    # first-order Sagnac rate, as RTKLIB does. The two differ by under 1 mm/s
    # here, so the truth is recovered to that level.
    {vx, vy, vz} = solution.velocity.velocity_m_s
    [tvx, tvy, tvz] = CoreGolden.f(ctx.golden["velocity_truth_m_s"])
    assert_in_delta vx, tvx, 1.0e-3
    assert_in_delta vy, tvy, 1.0e-3
    assert_in_delta vz, tvz, 1.0e-3
    assert_in_delta solution.velocity.clock_drift_s_s, CoreGolden.f(ctx.golden["clock_drift_truth_s_s"]), 1.0e-3 / @c
  end

  defp assert_matrix_relative(actual, expected) do
    for {row, expected_row} <- Enum.zip(actual, expected), {value, expected_value} <- Enum.zip(row, expected_row) do
      assert abs(value - expected_value) <= 1.0e-9 * abs(expected_value),
             "expected #{value} within 1e-9 relative of #{expected_value}"
    end
  end
end
