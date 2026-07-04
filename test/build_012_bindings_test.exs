defmodule SidereonBuild012BindingsTest do
  use ExUnit.Case, async: true

  alias Sidereon.ClockStability
  alias Sidereon.GNSS.{ARAIM, Ionosphere, SBAS}
  alias Sidereon.GNSS.Ionosphere.{TecGridSamples, TecSample}
  alias Sidereon.GNSS.RINEX.Observations
  alias Sidereon.Terrain

  # Provenance:
  # - Terrain, IONEX, ARAIM, SBAS, and angle fixtures mirror the local
  #   sidereon-core main tests under crates/sidereon-core/src.
  # - Clock-stability constants are the closed-form IEEE-1139 second-difference
  #   values for the quadratic phase series below, using the core formulas.
  @dted_root Path.join(__DIR__, "fixtures/dted/tiles")
  @ionex_path Path.join(__DIR__, "fixtures/synthetic_2map_7x7.20i")
  @obs_path Path.join(__DIR__, "fixtures/obs/ESBC00DNK_R_20201770000_01D_30S_MO_trim.rnx")
  @gps_l1_hz 1_575_420_000.0
  @inv_sqrt_3 0.577_350_269_189_625_8

  test "clock stability estimators expose core Allan-family curves" do
    phase = {:phase_seconds, [0.0, 1.0e-9, 4.0e-9, 9.0e-9, 16.0e-9, 25.0e-9]}

    assert {:ok, adev} = ClockStability.allan_deviation(phase, 1.0, [1, 2])
    assert adev.tau_s == [1.0, 2.0]
    assert adev.n == [4, 1]
    assert_in_delta Enum.at(adev.deviation, 0), 1.414_213_562_373_095e-9, 1.0e-21
    assert_in_delta Enum.at(adev.deviation, 1), 2.828_427_124_746_190e-9, 1.0e-21

    assert {:ok, curves} =
             ClockStability.compute_allan_deviations(phase, 1.0,
               estimators: :all,
               tau_grid: {:explicit, [1]}
             )

    assert_in_delta hd(curves.overlapping_adev.deviation), 1.414_213_562_373_095e-9, 1.0e-21
    assert_in_delta hd(curves.mdev.deviation), 1.414_213_562_373_095e-9, 1.0e-21
    assert_in_delta hd(curves.hdev.deviation), 0.0, 1.0e-21
    assert_in_delta hd(curves.tdev.deviation), 8.164_965_809_277_26e-10, 1.0e-21

    {:ok, obs} = Observations.load(@obs_path)
    phases = ClockStability.receiver_clock_phase_deviations(obs)
    assert length(phases) == length(Observations.epochs(obs))
  end

  test "terrain height_batch matches scalar DTED lookups in longitude-first order" do
    {:ok, terrain} = Terrain.dted(@dted_root)
    points = [{-106.875, 36.125}, {-106.625, 36.375}, {-106.0, 36.5}]

    scalar =
      Enum.map(points, fn {lon, lat} ->
        Terrain.height(terrain, lon, lat, interpolation: :bilinear)
      end)

    assert Terrain.height_batch(terrain, points, interpolation: :bilinear) == scalar
  end

  test "IONEX sample IR rebuilds parsed and node-sample products" do
    {:ok, parsed} = Ionosphere.parse_ionex(File.read!(@ionex_path))
    assert %TecGridSamples{} = samples = Ionosphere.tec_grid_samples(parsed)

    {:ok, from_grid} = Ionosphere.from_samples(samples)
    assert [%TecSample{} | _] = node_samples = Ionosphere.tec_samples(parsed)

    {:ok, from_nodes} =
      Ionosphere.from_node_samples(node_samples, samples.shell_height_km, samples.base_radius_km, samples.exponent)

    epoch = {{2020, 6, 24}, {0, 0, 0}}
    assert {:ok, parsed_delay} = Ionosphere.ionex_slant_delay(parsed, 45.0, 10.0, 60.0, 60.0, epoch, @gps_l1_hz)
    assert {:ok, grid_delay} = Ionosphere.ionex_slant_delay(from_grid, 45.0, 10.0, 60.0, 60.0, epoch, @gps_l1_hz)
    assert {:ok, node_delay} = Ionosphere.ionex_slant_delay(from_nodes, 45.0, 10.0, 60.0, 60.0, epoch, @gps_l1_hz)
    assert grid_delay == parsed_delay
    assert node_delay == parsed_delay
  end

  test "SBAS raw decode exposes typed payload fields and store construction" do
    body = hex_bytes("5308DFFC010005FFC00DFFC009FFDFFC001FFDFFDFFFBABBBBBB9BBB80")

    assert {:ok, message} = SBAS.decode(body, :body_226)
    assert message.kind == :fast_corrections
    assert message.message_type == 2
    assert message.payload.iodf == 0
    assert message.payload.iodp == 3
    assert message.payload.prc == [2047, 4, 1, 2047, 3, 2047, 2, 2047, 2047, 0, 2047, 2047, 2047]
    assert message.payload.udrei == [14, 14, 10, 14, 14, 14, 14, 14, 14, 6, 14, 14, 14]

    line = "2360 259200 120 1 : 5308DFFC010005FFC00DFFC009FFDFFC001FFDFFDFFFBABBBBBB9BBB80\n"
    assert {:ok, [%SBAS.LogBlock{message: ^message}]} = SBAS.parse_rtklib(line)
    assert {:ok, %SBAS{}} = SBAS.store_from_rtklib(line)
  end

  test "ARAIM LPV-200 allocation and snapshot solve match core reference geometry" do
    geometry =
      ARAIM.Geometry.new(
        [
          ARAIM.Row.new("G01", {@inv_sqrt_3, @inv_sqrt_3, @inv_sqrt_3}, :math.pi() / 2.0, :gps),
          ARAIM.Row.new("G02", {@inv_sqrt_3, -@inv_sqrt_3, -@inv_sqrt_3}, :math.pi() / 2.0, :gps),
          ARAIM.Row.new("G03", {-@inv_sqrt_3, @inv_sqrt_3, -@inv_sqrt_3}, :math.pi() / 2.0, :gps),
          ARAIM.Row.new("G04", {-@inv_sqrt_3, -@inv_sqrt_3, @inv_sqrt_3}, :math.pi() / 2.0, :gps)
        ],
        {0.0, 0.0, 0.0},
        [:gps]
      )

    model = ARAIM.SatelliteIsmModel.new(2.0, 1.0, 0.25, 0.0)
    ism = ARAIM.Ism.new([ARAIM.ConstellationIsm.new(:gps, 0.0, model)])
    allocation = %{ARAIM.IntegrityAllocation.lpv_200() | max_fault_order: 0, p_threshold_unmonitored: 0.0}

    assert {:ok, result} = ARAIM.araim(geometry, ism, allocation)
    assert result.availability
    assert_in_delta result.hpl_m, 15.630_862_038_940_084, 1.0e-12
    assert_in_delta result.vpl_m, 9.870_971_389_055_294, 1.0e-12
    assert result.emt_m == 0.0
    assert [%ARAIM.FaultMode{monitorable: true, excluded: []}] = result.fault_modes
  end

  test "angular separation and position angle match core reference cases" do
    sirius = {101.287_155_333, -16.716_115_861}
    procyon = {114.825_493_028, 5.224_993_306}

    assert_in_delta Sidereon.Angles.angular_separation_coords(sirius, procyon), 25.701_364_640_362_3, 1.0e-9
    assert_in_delta Sidereon.Angles.position_angle(sirius, procyon), 32.516_736_600_993_02, 1.0e-9
  end

  defp hex_bytes(hex), do: Base.decode16!(hex, case: :mixed)
end
