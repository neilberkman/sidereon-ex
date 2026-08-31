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

    # Position is pinned to the bit. A 1e-9 m delta on a 4.5e6 m coordinate is
    # below one f64 ULP (0.93 nm), so the old assert_in_delta was a bit check
    # written as a tolerance; say so explicitly.
    assert bits(sol.position.x_m) == 0x41512A880003992C
    assert bits(sol.position.y_m) == 0x411E8480001A3C90
    assert bits(sol.position.z_m) == 0x41512A88000183E4

    assert bits(sol.geodetic.lat_rad) == 0x3FE9244BAE999206
    assert bits(sol.geodetic.lon_rad) == 0x3FBC54081A145860
    assert bits(sol.geodetic.height_m) == 0x40CF6CA090769769

    assert Enum.map(sol.per_epoch_clock, & &1.epoch_index) == [0, 1, 2]
    assert Enum.map(sol.per_epoch_clock, & &1.system) == ["G", "G", "G"]
    assert bits(hd(sol.per_epoch_clock).clock_s) == 0x3D6909F63F3A8670

    assert sol.metadata == %{
             status: :step_tolerance,
             iterations: 7,
             converged: true,
             outer_iterations: 0,
             final_robust_scale_m: nil,
             used_measurements: 21,
             n_parameters: 6,
             redundancy: 15
           }

    assert bits(sol.residual_rms_m) == 0x3F221058BE4B53BD
    assert sol.geometry_quality.tier == :nominal
    assert sol.geometry_quality.redundancy == 15
    assert sol.geometry_quality.rank == 6

    assert Enum.map(sol.covariance.position_ecef_m2, fn row -> Enum.map(row, &bits/1) end) == [
             [
               0x400E2C486755C6FE,
               0x3FF0E157FD4C5137,
               0x4006A4AAB9BC4C9F
             ],
             [
               0x3FF0E157FD4C5137,
               0x3FEBFE260D7365FB,
               0x3FF04568F3C25CA8
             ],
             [
               0x4006A4AAB9BC4C9F,
               0x3FF04568F3C25CA8,
               0x4008B063B684EAA2
             ]
           ]

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

  defp bits(value) when is_float(value), do: :binary.decode_unsigned(<<value::float-64>>)

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
