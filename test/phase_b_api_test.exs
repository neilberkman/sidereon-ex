defmodule Sidereon.PhaseBApiTest do
  use ExUnit.Case, async: true

  alias Sidereon.Angles
  alias Sidereon.Astro.Almanac
  alias Sidereon.Astro.Anomaly
  alias Sidereon.Astro.Equinoctial
  alias Sidereon.Astro.Observe
  alias Sidereon.Astro.Relative
  alias Sidereon.Drag
  alias Sidereon.GNSS.Bias
  alias Sidereon.GNSS.Broadcast
  alias Sidereon.GNSS.Ephemeris
  alias Sidereon.GNSS.SBAS
  alias Sidereon.GNSS.SP3
  alias Sidereon.GNSS.SSR
  alias Sidereon.GNSS.Time.ExactEpochQuery
  alias Sidereon.OrbitalElements
  alias Sidereon.Terrain

  @core_fixtures Path.join(__DIR__, "fixtures")

  test "anomaly conversions and Kepler solver delegate to core" do
    assert {:ok, solution} = Anomaly.solve_kepler(1.0, 0.1)
    assert_in_delta solution.anomaly, 1.0885977523978936, 1.0e-14
    assert solution.iterations > 0

    assert {:ok, true_anom} = Anomaly.mean_to_true(1.0, 0.1)
    assert {:ok, mean_anom} = Anomaly.true_to_mean(true_anom, 0.1)
    assert_in_delta mean_anom, 1.0, 1.0e-12
  end

  test "equinoctial and modified equinoctial element conversions round trip a Cartesian state" do
    r = {7000.0, 100.0, 1300.0}
    v = {-0.5, 7.35, 1.0}

    assert {:ok, eq} = Equinoctial.rv2eq(r, v)
    assert %Equinoctial.EquinoctialElements{} = eq
    assert {:ok, eq_rv} = Equinoctial.eq2rv(eq)
    assert_vec3(eq_rv.position_km, r, 1.0e-8)
    assert_vec3(eq_rv.velocity_km_s, v, 1.0e-11)

    assert {:ok, mee} = Equinoctial.rv2mee(r, v)
    assert %Equinoctial.ModifiedEquinoctialElements{} = mee
    assert {:ok, coe} = Equinoctial.mee2coe(mee)
    assert %OrbitalElements{} = coe
  end

  test "angle helpers include angular separation, position angle, and beta angle" do
    assert_in_delta Angles.angular_separation({1, 0, 0}, {0, 1, 0}), 90.0, 1.0e-12
    assert_in_delta Angles.angular_separation_coords({0, 0}, {90, 0}), 90.0, 1.0e-12
    assert_in_delta Angles.position_angle({0, 0}, {0, 10}), 0.0, 1.0e-12
    assert_in_delta Angles.beta_angle({0, 0, 1}, {0, 0, 5}), 90.0, 1.0e-12
    assert_in_delta Angles.beta_angle_from_state({1, 0, 0}, {0, 1, 0}, {0, 0, 5}), 90.0, 1.0e-12
  end

  test "relative frame and Clohessy-Wiltshire helpers expose core results" do
    chief = %Relative.State{epoch_tdb_seconds: 0.0, position_km: {7000.0, 0.0, 0.0}, velocity_km_s: {0.0, 7.5, 0.0}}
    deputy = %Relative.State{epoch_tdb_seconds: 0.0, position_km: {7001.0, 0.0, 0.0}, velocity_km_s: {0.0, 7.5, 0.0}}

    assert {:ok, rotation} = Relative.rotation(:rtn, chief)
    assert tuple_size(rotation) == 3
    assert {:ok, rel} = Relative.relative_state(chief, deputy)
    assert %Relative.State{} = rel

    n = 0.001
    dt = 100.0
    initial = %Relative.State{epoch_tdb_seconds: 0.0, position_km: {0.0, 0.0, 1.0}, velocity_km_s: {0.0, 0.0, 0.0}}
    assert {:ok, propagated} = Relative.cw_propagate(initial, n, dt)
    {_, _, z} = propagated.position_km
    {_, _, zdot} = propagated.velocity_km_s
    assert_in_delta z, :math.cos(n * dt), 1.0e-12
    assert_in_delta zdot, -n * :math.sin(n * dt), 1.0e-12
  end

  test "observe and almanac analytic wrappers return structured events" do
    station = {40.0, -105.0, 1.6}
    assert {:ok, observation} = Observe.observe(station, ~U[2025-03-20 12:00:00Z], :sun)
    assert is_float(observation.horizontal.azimuth_deg)
    assert is_float(observation.astrometric.right_ascension_deg)

    assert {:ok, seasons} =
             Almanac.seasons({~U[2025-03-19 00:00:00Z], ~U[2025-03-22 00:00:00Z]}, step_seconds: 21_600.0)

    assert Enum.any?(seasons, &(&1.kind == :march_equinox))

    assert {:ok, transits} =
             Almanac.meridian_transits(:sun, station, {~U[2025-03-20 00:00:00Z], ~U[2025-03-21 00:00:00Z]},
               step_seconds: 1_800.0
             )

    assert Enum.any?(transits, &(&1.kind == :upper))
  end

  test "drag parameters, acceleration, and decay estimate wrappers call core" do
    assert {:ok, params} = Drag.from_bc_factor(0.01)
    state = %Relative.State{epoch_tdb_seconds: 0.0, position_km: {6778.0, 0.0, 0.0}, velocity_km_s: {0.0, 7.67, 0.0}}

    assert {:ok, {ax, ay, az}} = Drag.acceleration(params, state)
    assert is_float(ax) and is_float(ay) and is_float(az)
  end

  test "core ephemeris sampler powers the Elixir sample API" do
    sp3 = SP3.load!(Path.join(__DIR__, "fixtures/sp3/GRG0MGXFIN_20201760000_01D_15M_ORB.SP3"))
    [sat | _] = SP3.satellite_ids(sp3)

    rows =
      Ephemeris.sample(sp3, [sat], %{
        from: ~N[2020-06-24 00:00:00],
        to: ~N[2020-06-24 00:05:00],
        step_s: 300
      })

    assert length(rows) == 2
    assert Enum.all?(rows, &(&1.satellite_id == sat))
  end

  test "bias SINEX and code DCB loaders use the core parsers" do
    assert {:ok, bias} =
             Bias.load_bias_sinex(Path.join(@core_fixtures, "bias/COD0OPSFIN_20261330000_01D_01D_OSB.BIA.gz"))

    assert bias.info.records > 0
    assert [%Bias.Record{} | _] = Bias.records(bias)

    assert {:ok, dcb} =
             Bias.load_code_dcb(Path.join(@core_fixtures, "bias/P1C1_RINEX.DCB"),
               pair: {"P1", "C1"},
               year: 2026,
               month: 6
             )

    assert dcb.info.records > 0
  end

  test "bias SINEX header-layout failures and lenient notices retain typed details" do
    compressed =
      File.read!(Path.join(@core_fixtures, "bias/COD0OPSFIN_20261330000_01D_01D_OSB.BIA.gz"))

    input = :zlib.gunzip(compressed)
    newline = elem(:binary.match(input, "\n"), 0)

    malformed =
      binary_part(input, 0, newline) <>
        "X" <>
        binary_part(input, newline, byte_size(input) - newline)

    assert {:error, {:departure, {:header_layout, reason}}} = Bias.parse_bias_sinex(malformed)
    assert reason == "header line is not 74 columns"

    assert {:ok, bias} = Bias.parse_bias_sinex(malformed, policy: :lenient)
    assert {:departure, {:header_layout, reason}} in Bias.notices(bias)
  end

  test "bias file readers retain typed I/O failures" do
    missing_path =
      Path.join(
        System.tmp_dir!(),
        "sidereon-missing-bias-product-#{System.unique_integer([:positive])}"
      )

    assert {:error, {:io, message}} = Bias.load_bias_sinex(missing_path)
    assert is_binary(message)
  end

  test "bias writers preserve source bytes and report typed text and DCB errors" do
    compressed =
      File.read!(Path.join(@core_fixtures, "bias/COD0OPSFIN_20261330000_01D_01D_OSB.BIA.gz"))

    source = :zlib.gunzip(compressed)
    assert {:ok, bias} = Bias.parse_bias_sinex(source)
    assert {:ok, ^source} = Bias.write_bias_sinex_bytes(bias)

    invalid_utf8_source =
      :binary.replace(source, "* Bias Solution", <<"* ", 255, "Bias Solution">>, [:global])

    assert {:ok, invalid_utf8_bias} = Bias.parse_bias_sinex(invalid_utf8_source)
    assert {:ok, ^invalid_utf8_source} = Bias.write_bias_sinex_bytes(invalid_utf8_bias)
    assert {:error, {:invalid_utf8, line}} = Bias.write_bias_sinex(invalid_utf8_bias)
    assert is_integer(line) and line > 0

    assert {:error, {:missing_writer_metadata, "dcb_meta"}} = Bias.write_code_dcb(bias)
  end

  test "CODE DCB text and byte writers preserve the same source" do
    source = File.read!(Path.join(@core_fixtures, "bias/P1C1_RINEX.DCB"))

    assert {:ok, bias} =
             Bias.parse_code_dcb(source, pair: {"P1", "C1"}, year: 2026, month: 6)

    assert {:ok, text} = Bias.write_code_dcb(bias)
    assert {:ok, bytes} = Bias.write_code_dcb_bytes(bias)
    assert text == bytes
    assert bytes == source
  end

  test "bias lookups return the value with its records, or a typed status" do
    {:ok, bias} =
      Bias.load_bias_sinex(Path.join(@core_fixtures, "bias/COD0OPSFIN_20261330000_01D_01D_OSB.BIA.gz"))

    assert bias.info.mode == :absolute
    assert bias.info.time_scale == "GPST"
    assert bias.info.time_system_label == "G"
    assert is_list(Bias.notices(bias))

    # OSB  G080 G01 C1C 2026:133:00000 2026:134:00000 ns -6.0355
    assert {:ok, value, %{records: [index], overridden: []}} =
             Bias.code_osb(bias, "G01", "C1C", ~N[2026-05-13 12:00:00])

    assert_in_delta value, -6.0355e-9, 1.0e-18

    record = Enum.at(Bias.records(bias), index)
    assert %Bias.Record{obs1: "C1C", family: :code, unit: :nanoseconds} = record
    assert is_integer(record.line)

    assert {:error, :absent} = Bias.code_osb(bias, "G01", "C1C", ~N[2026-05-20 12:00:00])
  end

  test "SBAS message decode and store construction use core" do
    body = hex_bytes("5308DFFC010005FFC00DFFC009FFDFFC001FFDFFDFFFBABBBBBB9BBB80")

    assert {:ok, message} = SBAS.decode(body, :body_226)
    assert message.kind == :fast_corrections
    assert message.message_type == 2

    line = "2360 259200 120 2 : 5308DFFC010005FFC00DFFC009FFDFFC001FFDFFDFFFBABBBBBB9BBB80\n"
    assert {:ok, [%SBAS.LogBlock{} = block]} = SBAS.parse_rtklib(line)
    assert block.satellite_id == "S20"
    assert block.declared_message_type == 2
    assert block.pad_bits == 0

    # A record whose type field differs from the type its message carries is
    # refused under :strict and read with the departure under :lenient.
    mislabelled = String.replace(line, " 120 2 :", " 120 1 :")
    assert {:error, _reason} = SBAS.parse_rtklib(mislabelled)

    assert {:ok, %SBAS.Log{blocks: [%SBAS.LogBlock{declared_message_type: 1}], departures: [{1, departure}]}} =
             SBAS.parse_rtklib_log(mislabelled, policy: :lenient)

    assert departure == {:declared_message_type, 1, 2}

    assert {:ok, store} = SBAS.store_from_rtklib(line)
    assert %SBAS{} = store

    # The message reached the PRN 120 partition; with no PRN mask no
    # correction was addressed to an unassigned bit. A GEO the store has not
    # heard has no partition.
    assert SBAS.unassigned_mask_corrections(store, "S120") == {:ok, %{}}
    assert SBAS.unassigned_mask_corrections(store, "S121") == {:error, :not_found}
  end

  test "SSR RTCM decode exposes orbit corrections and corrected broadcast states" do
    bytes = @core_fixtures |> Path.join("ssr/SSRA02IGS0_2026181234930_1060.hex") |> File.read!() |> hex_bytes()

    assert {:ok, store, report} = SSR.from_rtcm(bytes, 2425, 344_970.0)
    assert %{diagnostics: %{crc_failures: _, departures: _}, trailing_partial_frame_len: _} = report
    assert is_list(report.ingest_refusals)
    assert {:ok, orbit} = SSR.orbit(store, "G30")
    assert is_float(orbit.radial_m)
    assert orbit.has_nav_message == nil
    assert is_float(orbit.transmitted_epoch_j2000_s)

    broadcast = Broadcast.load!(Path.join(@core_fixtures, "ssr/BRDC00WRD_S_20261820000_G30_G31.rnx"))

    assert {:ok, corrected} =
             SSR.corrected_position(broadcast, store, "G30", ssr_j2000(344_970.0), fallback_to_broadcast: true)

    assert {x, y, z} = corrected.position_ecef_m
    assert is_float(x) and is_float(y) and is_float(z)

    {:ok, exact_query} =
      ExactEpochQuery.from_binary_j2000_seconds(ssr_j2000(344_970.0))

    {:ok, state_query} = ExactEpochQuery.checked_add_binary_seconds(exact_query, 0.125)

    assert {:ok, selected} =
             SSR.selected_state_at_epoch_queries(
               broadcast,
               store,
               "G30",
               state_query,
               exact_query,
               fallback_to_broadcast: true
             )

    assert {:ok, exact_corrected} =
             SSR.corrected_position_at_epoch_query(
               broadcast,
               store,
               "G30",
               state_query,
               selection_epoch_query: exact_query,
               fallback_to_broadcast: true
             )

    assert selected.position_ecef_m == exact_corrected.position_ecef_m
    assert selected.clock_s == exact_corrected.clock_s

    assert {:ok, %{clock_s: placement_clock_s}} =
             SSR.transmit_clock_at_epoch_queries(
               broadcast,
               store,
               "G30",
               state_query,
               exact_query,
               fallback_to_broadcast: true
             )

    assert is_float(placement_clock_s)

    assert :not_applicable ==
             SSR.clock_relativity_for_state_at_epoch_query(
               broadcast,
               store,
               "G30",
               state_query,
               selected.position_ecef_m,
               fallback_to_broadcast: true
             )

    variance =
      SSR.ephemeris_variance_at_epoch_queries(
        broadcast,
        store,
        "G30",
        state_query,
        exact_query,
        fallback_to_broadcast: true
      )

    assert is_nil(variance) or is_number(variance)
  end

  test "DTED terrain wrappers use core terrain lookup" do
    terrain = Terrain.dted!(Path.join(@core_fixtures, "dted/tiles"))

    assert {:ok, height} = Terrain.height(terrain, -106.875, 36.125)
    assert_in_delta height, -18.75, 1.0e-9

    tile = Terrain.load_tile!(Path.join(@core_fixtures, "dted/tiles/n36_w107_1arc_v3.dt2"))
    assert {:ok, posting} = Terrain.tile_elevation(tile, -107.0, 36.25)
    assert is_integer(posting)
  end

  defp assert_vec3({ax, ay, az}, {ex, ey, ez}, tolerance) do
    assert_in_delta ax, ex, tolerance
    assert_in_delta ay, ey, tolerance
    assert_in_delta az, ez, tolerance
  end

  defp hex_bytes(hex) do
    hex
    |> String.replace(~r/[^0-9a-fA-F]/, "")
    |> Base.decode16!(case: :mixed)
  end

  defp ssr_j2000(tow_s), do: 2425 * 604_800.0 + tow_s - 630_763_200.0
end
