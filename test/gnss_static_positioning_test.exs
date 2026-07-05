defmodule Sidereon.GNSS.StaticPositioningTest do
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.Geometry
  alias Sidereon.GNSS.Observables
  alias Sidereon.GNSS.SP3
  alias Sidereon.GNSS.StaticPositioning

  @sp3_path Path.join(__DIR__, "fixtures/sp3/GRG0MGXFIN_20201760000_01D_15M_ORB.SP3")
  @epochs [
    ~N[2020-06-24 12:00:00],
    ~N[2020-06-24 12:15:00],
    ~N[2020-06-24 12:30:00]
  ]
  @receiver {4_500_000.0, 500_000.0, 4_500_000.0}
  @initial {4_400_000.0, 400_000.0, 4_400_000.0}
  @c 299_792_458.0

  setup_all do
    {:ok, sp3: SP3.load!(@sp3_path)}
  end

  test "pins multi-epoch static solve result surface", %{sp3: sp3} do
    # Reference literals generated from sidereon-core through this binding
    # against the patched core on 2026-07-05.
    requests = Enum.map(@epochs, &epoch_request(sp3, &1))

    assert {:ok, %StaticPositioning.Solution{} = sol} =
             StaticPositioning.solve(sp3, requests, initial_position: @initial)

    assert_in_delta sol.position.x_m, 4_500_000.000219625, 1.0e-9
    assert_in_delta sol.position.y_m, 500_000.00010008493, 1.0e-9
    assert_in_delta sol.position.z_m, 4_500_000.000092482, 1.0e-9

    assert_in_delta sol.geodetic.lat_rad, 0.7856806192544931, 1.0e-15
    assert_in_delta sol.geodetic.lon_rad, 0.1106572211905088, 1.0e-15
    assert_in_delta sol.geodetic.height_m, 16_089.25440867048, 1.0e-9

    assert Enum.map(sol.per_epoch_clock, & &1.epoch_index) == [0, 1, 2]
    assert Enum.map(sol.per_epoch_clock, & &1.system) == ["G", "G", "G"]
    assert_in_delta hd(sol.per_epoch_clock).clock_s, 7.116548471943955e-13, 1.0e-18

    assert sol.metadata == %{
             status: :step_tolerance,
             iterations: 8,
             converged: true,
             outer_iterations: 0,
             final_robust_scale_m: nil,
             used_measurements: 21,
             n_parameters: 6,
             redundancy: 15
           }

    assert_in_delta sol.residual_rms_m, 1.3781657711962284e-4, 1.0e-16
    assert sol.geometry_quality.tier == :nominal
    assert sol.geometry_quality.redundancy == 15
    assert sol.geometry_quality.rank == 6

    assert [
             [3.771621051555918, 1.0550145403545639, 2.830402538809005],
             [1.0550145403545639, 0.874773231946568, 1.0169448207849012],
             [2.830402538809005, 1.0169448207849012, 3.086126641838115]
           ] = sol.covariance.position_ecef_m2

    assert Enum.map(sol.per_epoch_influence, & &1.status) == [:solved, :solved, :solved]
    assert length(sol.per_satellite_influence) == 21
    assert length(sol.per_satellite_batch_influence) == 7
    assert Enum.all?(sol.rejected_sats, &(&1 == []))

    assert Enum.all?(sol.used_sats, fn epoch_sats ->
             epoch_sats == ["G10", "G16", "G18", "G20", "G21", "G26", "G27"]
           end)
  end

  test "returns typed static solve and option errors", %{sp3: sp3} do
    assert {:error, :empty_epochs} = StaticPositioning.solve(sp3, [], initial_position: @initial)

    assert {:error, {:invalid_option, :huber}} =
             StaticPositioning.solve(sp3, Enum.map(@epochs, &epoch_request(sp3, &1)),
               initial_position: @initial,
               huber: :yes
             )
  end

  defp epoch_request(sp3, epoch) do
    satellites =
      sp3
      |> Geometry.visible(@receiver, epoch, systems: ["G"], elevation_mask_deg: 5.0)
      |> Enum.map(& &1.satellite_id)
      |> Enum.take(7)

    observations =
      Enum.map(satellites, fn sat ->
        {:ok, obs} = Observables.predict(sp3, sat, @receiver, epoch, light_time: true, sagnac: true)
        {sat, obs.geometric_range_m + @c * -(obs.sat_clock_s || 0.0)}
      end)

    {observations, epoch}
  end
end
