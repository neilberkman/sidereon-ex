defmodule SidereonBuild012BindingsTest do
  use ExUnit.Case, async: true

  alias Sidereon.ClockStability
  alias Sidereon.GNSS.{ARAIM, Ionosphere, SBAS}
  alias Sidereon.GNSS.Ionosphere.{TecGridSamples, TecSample}
  alias Sidereon.GNSS.RINEX.Observations
  alias Sidereon.Terrain
  alias Sidereon.Terrain.{DtedLookupOptions, DtedTile}
  alias Sidereon.Terrain.MmapTerrain
  alias Sidereon.Terrain.MmapTerrain.{Egm96FifteenMinuteGeoid, OrthometricHeightM, TerrainDatumError}

  # Provenance:
  # - Terrain, IONEX, ARAIM, SBAS, and angle fixtures mirror the local
  #   sidereon-core main tests under crates/sidereon-core/src.
  # - Clock-stability constants are the closed-form IEEE-1139 second-difference
  #   values for the quadratic phase series below, using the core formulas.
  @dted_root Path.join(__DIR__, "fixtures/dted/tiles")
  @core_dted_root Path.join(__DIR__, "fixtures/dted/tiles")
  @ionex_path Path.join(__DIR__, "fixtures/synthetic_2map_7x7.20i")
  @obs_path Path.join(__DIR__, "fixtures/obs/ESBC00DNK_R_20201770000_01D_30S_MO_trim.rnx")
  @gps_l1_hz 1_575_420_000.0
  @wg_c_add_v3_rows [
    {:gps, "G01", {0.0225, 0.9951, -0.0966}, 3.8865, 3.5740},
    {:gps, "G02", {0.6750, -0.6900, -0.2612}, 1.4377, 1.1252},
    {:gps, "G03", {0.0723, -0.6601, -0.7477}, 0.8604, 0.5479},
    {:gps, "G04", {-0.9398, 0.2553, -0.2269}, 1.6383, 1.3258},
    {:gps, "G05", {-0.5907, -0.7539, -0.2877}, 1.3229, 1.0104},
    {:galileo, "E01", {-0.3236, -0.0354, -0.9455}, 0.8434, 0.5309},
    {:galileo, "E02", {-0.6748, 0.4356, -0.5957}, 0.8963, 0.5838},
    {:galileo, "E03", {0.0938, -0.7004, -0.7075}, 0.8669, 0.5544},
    {:galileo, "E04", {0.5571, 0.3088, -0.7709}, 0.8573, 0.5448},
    {:galileo, "E05", {0.6622, 0.6958, -0.2780}, 1.3616, 1.0491}
  ]

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

  test "DTED parity aliases accept typed lookup options" do
    {:ok, terrain} = Terrain.dted(@dted_root)
    opts = DtedLookupOptions.new(:nearest_posting)

    assert {:ok, height_m} = Terrain.height_m(terrain, -106.875, 36.125, opts)
    assert {:ok, same_height_m} = Terrain.height_m_with_options(terrain, -106.875, 36.125, opts)
    assert height_m == same_height_m

    assert [{:ok, ^height_m}] = Terrain.height_batch(terrain, [{-106.875, 36.125}], opts)

    tile_path = Path.join(@dted_root, "n36_w107_1arc_v3.dt2")
    assert {:ok, tile} = DtedTile.from_path(tile_path)
    assert {:ok, tile_height_m} = Terrain.tile_elevation(tile, -107.0 + 200 / 3600, 36.0 + 100 / 3600)
    assert tile_height_m == -20
  end

  test "mmap terrain store matches DTED reader and missing EGM96 DAC is typed" do
    {:ok, bytes} = MmapTerrain.dted_tree_to_mmap_store(@core_dted_root)
    assert MmapTerrain.terrain_store_checksum64(bytes) == MmapTerrain.checksum64(bytes)

    out_path = Path.join(System.tmp_dir!(), "sidereon-terrain-store-#{System.unique_integer([:positive])}.bin")
    on_exit(fn -> File.rm(out_path) end)
    assert :ok = MmapTerrain.write_dted_tree_to_mmap_store(@core_dted_root, out_path)

    assert {:ok, store} = MmapTerrain.from_bytes(bytes)
    assert {:ok, from_vec} = MmapTerrain.from_vec(bytes)
    assert {:ok, from_path} = MmapTerrain.from_path(out_path)
    assert MmapTerrain.to_bytes(store) == bytes
    assert MmapTerrain.checksum64(store) == MmapTerrain.checksum64(from_vec)
    assert MmapTerrain.checksum64(store) == MmapTerrain.checksum64(from_path)
    assert MmapTerrain.vertical_datum(store) == :egm96_msl_orthometric
    assert length(MmapTerrain.tile_index(store)) == 2

    {:ok, dted} = Terrain.dted(@core_dted_root)
    points = [{-106.875, 36.125}, {-105.875, 36.125}, {-104.5, 36.5}]
    covered_points = Enum.take(points, 2)

    for interpolation <- [:bilinear, :nearest_posting] do
      store_results = MmapTerrain.orthometric_height_batch(store, points, interpolation: interpolation)
      dted_results = Terrain.height_batch(dted, covered_points, interpolation: interpolation)

      assert store_results |> Enum.take(2) |> Enum.map(&orthometric_result_to_scalar/1) == dted_results
      assert {:error, "missing terrain tile (36,-105)"} = List.last(store_results)

      for {longitude_deg, latitude_deg} <- covered_points do
        assert {:ok, %OrthometricHeightM{} = typed_height} =
                 MmapTerrain.height_m(store, longitude_deg, latitude_deg, interpolation: interpolation)

        assert {:ok, dted_height} = Terrain.height(dted, longitude_deg, latitude_deg, interpolation: interpolation)
        assert typed_height.value_m == dted_height
      end
    end

    missing_path =
      Path.join(System.tmp_dir!(), "sidereon-missing-egm96-#{System.unique_integer([:positive])}/WW15MGH.DAC")

    assert {:error, %TerrainDatumError{kind: :missing_egm96_dac, path: ^missing_path, remediation: remediation}} =
             Egm96FifteenMinuteGeoid.from_ww15mgh_dac_path(missing_path)

    assert remediation =~ "WW15MGH.DAC"
    assert remediation =~ "from_ww15mgh_dac_bytes"
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

  test "ARAIM LPV-200 allocation and snapshot solve match WG-C Appendix D values" do
    geometry =
      ARAIM.Geometry.new(
        Enum.map(@wg_c_add_v3_rows, fn {system, id, design_enu, _c_int_m2, _c_acc_m2} ->
          ARAIM.Row.new(id, wg_c_design_to_los(design_enu), :math.pi() / 2.0, system)
        end),
        {0.0, 0.0, 0.0},
        [:gps, :galileo]
      )

    model = ARAIM.SatelliteIsmModel.new(0.75, 0.5, 0.5, 1.0e-5)

    satellites =
      Enum.map(@wg_c_add_v3_rows, fn {_system, id, _design_enu, c_int_m2, c_acc_m2} ->
        ARAIM.SatelliteIsm.new(id, 0.75, 0.5, 0.5, 1.0e-5,
          effective_sigma_int_m: :math.sqrt(c_int_m2),
          effective_sigma_acc_m: :math.sqrt(c_acc_m2)
        )
      end)

    ism =
      ARAIM.Ism.new(
        [
          ARAIM.ConstellationIsm.new(:gps, 1.0e-4, model),
          ARAIM.ConstellationIsm.new(:galileo, 1.0e-4, model)
        ],
        satellites
      )

    allocation = ARAIM.IntegrityAllocation.lpv_200()

    assert {:ok, result} = ARAIM.araim(geometry, ism, allocation)
    assert result.available
    assert result.availability
    assert_in_delta result.vpl_m, 19.2, 0.05
    assert_in_delta result.hpl_m, 14.5, 0.05
    assert_in_delta result.emt_m, 7.8, 0.05
    assert_in_delta result.sigma_acc_v_m, 1.47, 0.02

    az_el_rows =
      Enum.map(@wg_c_add_v3_rows, fn {system, id, design_enu, _c_int_m2, _c_acc_m2} ->
        {azimuth_deg, elevation_deg} = wg_c_design_to_az_el_deg(design_enu)
        %{id: id, azimuth_deg: azimuth_deg, elevation_deg: elevation_deg, system: system}
      end)

    assert {:ok, az_el_geometry} = ARAIM.Geometry.from_az_el_deg(az_el_rows, {0.0, 0.0, 0.0}, [:gps, :galileo])
    assert {:ok, az_el_result} = ARAIM.araim(az_el_geometry, ism, allocation)
    assert az_el_result.available
    assert az_el_result.availability
    assert_in_delta az_el_result.hpl_m, 14.5, 0.05
    assert_in_delta az_el_result.vpl_m, 19.2, 0.05
    assert_in_delta az_el_result.sigma_acc_h_m, result.sigma_acc_h_m, 0.02
    assert_in_delta az_el_result.sigma_acc_v_m, result.sigma_acc_v_m, 0.02
  end

  test "ARAIM sparse GPS geometry returns unavailable and LOS lists are accepted" do
    s = 0.577_350_269_189_625_8

    geometry =
      ARAIM.Geometry.new(
        [
          ARAIM.Row.new("G01", [s, s, s], :math.pi() / 2.0),
          ARAIM.Row.new("G02", [s, -s, -s], :math.pi() / 2.0),
          ARAIM.Row.new("G03", [-s, s, -s], :math.pi() / 2.0),
          ARAIM.Row.new("G04", [-s, -s, s], :math.pi() / 2.0)
        ],
        {0.0, 0.0, 0.0},
        [:gps]
      )

    model = ARAIM.SatelliteIsmModel.new(0.75, 0.5, 0.75, 1.0e-5)
    ism = ARAIM.Ism.new([ARAIM.ConstellationIsm.new(:gps, 0.0, model)], [])

    assert {:ok, result} = ARAIM.araim(geometry, ism, ARAIM.IntegrityAllocation.lpv_200())
    refute result.available
    refute result.availability
  end

  test "ARAIM bad LOS list returns a typed error" do
    geometry =
      ARAIM.Geometry.new(
        [ARAIM.Row.new("G01", [1.0, 0.0], :math.pi() / 2.0)],
        {0.0, 0.0, 0.0},
        [:gps]
      )

    model = ARAIM.SatelliteIsmModel.new(0.75, 0.5, 0.75, 1.0e-5)
    ism = ARAIM.Ism.new([ARAIM.ConstellationIsm.new(:gps, 0.0, model)], [])

    assert {:error, {:bad_line_of_sight, :expected_ecef_triplet}} =
             ARAIM.araim(geometry, ism, ARAIM.IntegrityAllocation.lpv_200())
  end

  test "angular separation and position angle match core reference cases" do
    sirius = {101.287_155_333, -16.716_115_861}
    procyon = {114.825_493_028, 5.224_993_306}

    assert_in_delta Sidereon.Angles.angular_separation_coords(sirius, procyon), 25.701_364_640_362_3, 1.0e-9
    assert_in_delta Sidereon.Angles.position_angle(sirius, procyon), 32.516_736_600_993_02, 1.0e-9
  end

  defp hex_bytes(hex), do: Base.decode16!(hex, case: :mixed)

  defp wg_c_design_to_los({east_design, north_design, up_design}) do
    {-up_design, -east_design, -north_design}
  end

  defp wg_c_design_to_az_el_deg(design_enu) do
    {e_x, e_y, e_z} = wg_c_design_to_los(design_enu)
    {east, north, up} = {e_y, e_z, e_x}
    elevation_deg = :math.asin(up) * 180.0 / :math.pi()
    azimuth_deg = :math.atan2(east, north) * 180.0 / :math.pi()
    {if(azimuth_deg < 0.0, do: azimuth_deg + 360.0, else: azimuth_deg), elevation_deg}
  end

  defp orthometric_result_to_scalar({:ok, %OrthometricHeightM{value_m: value_m}}), do: {:ok, value_m}
  defp orthometric_result_to_scalar({:error, reason}), do: {:error, reason}
end
