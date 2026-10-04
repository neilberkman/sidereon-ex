defmodule Sidereon.GNSS.StaticPositioningTest do
  use ExUnit.Case, async: true

  alias Sidereon.Coordinates
  alias Sidereon.GNSS.Geometry
  alias Sidereon.GNSS.SP3
  alias Sidereon.GNSS.StaticPositioning
  alias Sidereon.Test.CoreGolden

  @sp3_path Path.join(__DIR__, "fixtures/sp3/GRG0MGXFIN_20201760000_01D_15M_ORB.SP3")
  @c 299_792_458.0

  # The core's own SPP agreement bound (`AGREEMENT_BOUND_M` in its SPP tests):
  # the binding's solve agrees with the core's solve of the same inputs to
  # within it. An angle of this length on the Earth's surface is at most this
  # over the polar radius, in radians.
  @core_agreement_bound_m 1.0e-6
  @earth_polar_radius_m 6_356_752.314245

  # The pseudoranges are formed by the SPP model at the truth receiver with a
  # zero clock, so the solve returns the truth to within its convergence
  # tolerance; a millimetre bounds that.
  @truth_recovery_m 1.0e-3

  setup_all do
    golden = CoreGolden.load("static_solve.json")

    requests =
      Enum.map(golden["epochs"], fn epoch ->
        {CoreGolden.observations(epoch["observations"]), NaiveDateTime.from_iso8601!(epoch["epoch"])}
      end)

    {:ok, sp3: SP3.load!(@sp3_path), golden: golden, requests: requests}
  end

  test "the golden's satellites are the visible GPS satellites the solve would select", ctx do
    receiver = CoreGolden.tuple3(ctx.golden["receiver_truth_m"])

    for {observations, epoch} <- ctx.requests do
      visible =
        ctx.sp3
        |> Geometry.visible(receiver, epoch, systems: ["G"], elevation_mask_deg: 5.0)
        |> Enum.map(& &1.satellite_id)
        |> Enum.take(7)

      assert observations |> Enum.map(&elem(&1, 0)) |> Enum.sort() == Enum.sort(visible)
    end
  end

  test "matches the core static solve of the same epochs", ctx do
    initial = CoreGolden.tuple3(ctx.golden["initial_position_m"])
    expected = ctx.golden["solution"]

    assert {:ok, %StaticPositioning.Solution{} = sol} =
             StaticPositioning.solve(ctx.sp3, ctx.requests, initial_position: initial)

    [ex, ey, ez] = CoreGolden.f(expected["position_m"])
    assert_in_delta sol.position.x_m, ex, @core_agreement_bound_m
    assert_in_delta sol.position.y_m, ey, @core_agreement_bound_m
    assert_in_delta sol.position.z_m, ez, @core_agreement_bound_m

    geodetic = expected["geodetic"]
    angle_bound = @core_agreement_bound_m / @earth_polar_radius_m
    assert_in_delta sol.geodetic.lat_rad, CoreGolden.f(geodetic["lat_rad"]), angle_bound
    assert_in_delta sol.geodetic.lon_rad, CoreGolden.f(geodetic["lon_rad"]), angle_bound
    assert_in_delta sol.geodetic.height_m, CoreGolden.f(geodetic["height_m"]), @core_agreement_bound_m

    assert Enum.map(sol.per_epoch_clock, & &1.epoch_index) == Enum.map(expected["per_epoch_clock"], & &1["epoch_index"])
    assert Enum.map(sol.per_epoch_clock, & &1.system) == Enum.map(expected["per_epoch_clock"], & &1["system"])

    for {clock, expected_clock} <- Enum.zip(sol.per_epoch_clock, expected["per_epoch_clock"]) do
      assert_in_delta clock.clock_s, CoreGolden.f(expected_clock["clock_s"]), @core_agreement_bound_m / @c
    end

    assert sol.metadata == %{
             status: CoreGolden.status_atom(expected["status"]),
             iterations: expected["iterations"],
             converged: expected["converged"],
             outer_iterations: 0,
             final_robust_scale_m: nil,
             ut1_degraded: nil,
             used_measurements: expected["used_measurements"],
             n_parameters: expected["n_parameters"],
             redundancy: expected["redundancy"]
           }

    assert_in_delta sol.residual_rms_m, CoreGolden.f(expected["residual_rms_m"]), @core_agreement_bound_m
    assert sol.geometry_quality.tier == :nominal
    assert sol.geometry_quality.redundancy == expected["redundancy"]
    assert sol.geometry_quality.rank == expected["n_parameters"]

    # The covariance is the geometry's, which moves with the solution only by
    # the agreement bound over the satellite range, about 5e-14 relative;
    # 1e-9 relative is far above that and far below any real change.
    for {row, expected_row} <-
          Enum.zip(sol.covariance.position_ecef_m2, CoreGolden.f(expected["covariance_position_ecef_m2"])),
        {value, expected_value} <- Enum.zip(row, expected_row) do
      assert abs(value - expected_value) <= 1.0e-9 * abs(expected_value)
    end

    assert Enum.map(sol.per_epoch_influence, & &1.status) == [:solved, :solved, :solved]
    assert length(sol.per_satellite_influence) == 21
    assert length(sol.per_satellite_batch_influence) == 7
    assert Enum.all?(sol.rejected_sats, &(&1 == []))
  end

  test "recovers the truth receiver the pseudoranges were formed at", ctx do
    initial = CoreGolden.tuple3(ctx.golden["initial_position_m"])
    {tx, ty, tz} = truth = CoreGolden.tuple3(ctx.golden["receiver_truth_m"])

    assert {:ok, sol} = StaticPositioning.solve(ctx.sp3, ctx.requests, initial_position: initial)

    assert_in_delta sol.position.x_m, tx, @truth_recovery_m
    assert_in_delta sol.position.y_m, ty, @truth_recovery_m
    assert_in_delta sol.position.z_m, tz, @truth_recovery_m

    # The truth receiver's geodetic position, through the binding's own
    # ECEF-to-geodetic conversion (kilometres and degrees).
    truth_geodetic =
      truth |> then(fn {x, y, z} -> {x / 1000.0, y / 1000.0, z / 1000.0} end) |> Coordinates.to_geodetic()

    angle_bound = @truth_recovery_m / @earth_polar_radius_m
    assert_in_delta sol.geodetic.lat_rad, truth_geodetic.latitude * :math.pi() / 180.0, angle_bound
    assert_in_delta sol.geodetic.lon_rad, truth_geodetic.longitude * :math.pi() / 180.0, angle_bound
    assert_in_delta sol.geodetic.height_m, truth_geodetic.altitude_km * 1000.0, @truth_recovery_m
    assert Enum.all?(sol.per_epoch_clock, &(abs(&1.clock_s) < @truth_recovery_m / @c))
  end

  test "returns typed static solve and option errors", ctx do
    initial = CoreGolden.tuple3(ctx.golden["initial_position_m"])
    assert {:error, :empty_epochs} = StaticPositioning.solve(ctx.sp3, [], initial_position: initial)

    assert {:error, {:invalid_option, :huber}} =
             StaticPositioning.solve(ctx.sp3, ctx.requests,
               initial_position: initial,
               huber: :yes
             )

    assert {:error, {:invalid_option, :qzss_clock}} =
             StaticPositioning.solve(ctx.sp3, ctx.requests, initial_position: initial, qzss_clock: :unknown)
  end
end
