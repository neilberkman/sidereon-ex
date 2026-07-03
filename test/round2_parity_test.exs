defmodule Sidereon.Round2ParityTest do
  use ExUnit.Case, async: true

  alias Sidereon.Format.TLE
  alias Sidereon.GNSS.Broadcast
  alias Sidereon.GNSS.NMEA
  alias Sidereon.GNSS.QC
  alias Sidereon.GNSS.RINEX.Observations

  defp fixture(parts), do: Path.join(["test", "fixtures" | parts])

  defp assert_close(actual, expected, delta \\ 1.0e-12) do
    assert_in_delta actual, expected, delta
  end

  defp assert_close_list(actual, expected, delta \\ 1.0e-12) do
    assert length(actual) == length(expected)

    Enum.zip(actual, expected)
    |> Enum.each(fn {a, e} -> assert_close(a, e, delta) end)
  end

  test "geoid batch lookup and loaded-grid height conversions are core-pinned" do
    points_deg = [{0.0, 0.0}, {48.1173, 11.5167}, {-33.9, 151.2}]

    assert_close_list(
      Sidereon.Geoid.undulations_deg(points_deg),
      [17.0, 36.5619250495, 20.000400000000006],
      1.0e-12
    )

    assert_close_list(
      Sidereon.Geoid.egm96_undulations_deg(points_deg),
      [17.16, 45.68235391089999, 21.85960000000005],
      1.0e-12
    )

    {:ok, grid} = Sidereon.Geoid.grid(0, 0, 1, 1, 2, 2, [10, 12, 20, 22])

    assert_close_list(Sidereon.Geoid.grid_undulations_deg(grid, [{0.25, 0.25}, {0.5, 0.5}]), [13.0, 16.0])
    assert_close(Sidereon.Geoid.grid_orthometric_height_deg(grid, 100.0, 0.25, 0.25), 87.0)
    assert_close(Sidereon.Geoid.grid_ellipsoidal_height_deg(grid, 88.5, 0.25, 0.25), 101.5)
  end

  test "NMEA parse, accumulation, and GGA writer match core fixtures" do
    line = "$GPGGA,123519,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,*47\r\n"
    {:ok, parsed} = NMEA.parse_sentence(line)

    assert parsed.sentence.kind == :gga
    assert parsed.sentence.talker == "GP"
    assert parsed.sentence.system == "G"
    assert parsed.sentence.body.time.seconds_of_day == 45_319.0
    assert_close(parsed.sentence.body.latitude.degrees_float, 48.1173)
    assert_close(parsed.sentence.body.longitude.degrees_float, 11.516666666666667)
    assert parsed.diagnostics == %{skips: [], warnings: []}

    text =
      "$GPGGA,123519.00,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,*69\r\n" <>
        "$GPGGA,123520.00,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,*63\r\n"

    {:ok, grouped} = NMEA.group_epochs(text)

    assert Enum.map(grouped.epochs, &{&1.time_of_day.second, &1.sentence_count, &1.gga.hdop}) == [
             {19, 1, 0.9},
             {20, 1, 0.9}
           ]

    {:ok, parsed_log} = NMEA.parse(text)
    assert Enum.map(parsed_log.sentences, & &1.kind) == [:gga, :gga]

    {:ok, accumulator} = NMEA.accumulator(date: {2026, 7, 2})
    {:ok, output} = NMEA.push(accumulator, text)
    {:ok, tail} = NMEA.finish(accumulator)

    assert {length(output.sentences), length(output.snapshots), tail.time_of_day.second, tail.date.day} == {2, 1, 20, 2}

    {:ok, gga} =
      NMEA.write_gga(
        talker: "GP",
        time_seconds_of_day: 45_319.0,
        latitude_deg: 48.1173,
        longitude_deg: 11.516666666666667,
        coordinate_decimals: 3,
        quality: :gps_sps,
        satellites_used: 8,
        hdop: 0.9,
        altitude_msl_m: 545.4,
        geoid_separation_m: 46.9
      )

    assert gga == "$GPGGA,123519.00,4807.038,N,01131.000,E,1,08,0.90,545.4,M,46.9,M,,*59\r\n"
  end

  test "6x6 covariance propagation is numerically pinned" do
    {:ok, covariance} = Sidereon.Covariance.from_diagonal6([1.0e-6, 2.0e-6, 3.0e-6, 1.0e-8, 2.0e-8, 3.0e-8])
    state = {0.0, {7000.0, 0.0, 0.0}, {0.0, 7.546049108166282, 0.0}}

    assert {:ok, %{symmetric: true, positive_semidefinite: true}} = Sidereon.Covariance.validate6(covariance)
    assert {:ok, ^covariance} = Sidereon.Covariance.rtn_to_eci6(covariance, state)
    assert {:ok, ^covariance} = Sidereon.Covariance.eci_to_rtn6(covariance, state)

    {:ok, meters} = Sidereon.Covariance.km_to_m6(covariance)
    Enum.at(meters, 0) |> Enum.at(0) |> assert_close(1.0)
    Enum.at(meters, 3) |> Enum.at(3) |> assert_close(0.01)
    assert {:ok, ^covariance} = Sidereon.Covariance.m_to_km6(meters)

    {:ok, interpolated} = Sidereon.Covariance.interpolate_psd6(covariance, meters, 0.25)
    Enum.at(interpolated, 0) |> Enum.at(0) |> assert_close(3.16227766016838e-5, 1.0e-17)

    identity = for i <- 0..5, do: for(j <- 0..5, do: if(i == j, do: 1.0, else: 0.0))
    segments = [%{stm: identity, dt_seconds: 10.0, q_rotation_state: state}]
    assert {:ok, [^covariance, ^covariance]} = Sidereon.Covariance.transport_segments6(covariance, segments)

    {:ok, nodes} =
      Sidereon.Propagator.propagate_covariance(
        {elem(state, 1), elem(state, 2)},
        covariance,
        [60.0, 120.0],
        epoch_tdb_seconds: 0.0,
        forces: ["twobody"],
        integrator: :dp54,
        tolerance: 1.0e-12,
        max_step: 30.0
      )

    [first, second] = nodes
    assert_close(elem(first.state.position_km, 0), 6985.362638866473, 1.0e-9)
    assert_close(elem(first.state.velocity_km_s, 1), 7.530269930140621, 1.0e-12)
    Enum.at(first.covariance, 0) |> Enum.at(0) |> assert_close(3.710871092021438e-5, 1.0e-16)
    Enum.at(first.covariance, 5) |> Enum.at(5) |> assert_close(2.9874682644014395e-8, 1.0e-20)

    assert_close(elem(second.state.position_km, 1), 903.0024564399226, 1.0e-9)
    assert_close(elem(second.state.velocity_km_s, 0), -0.9734440709722663, 1.0e-12)
    Enum.at(second.covariance, 1) |> Enum.at(1) |> assert_close(2.8838820077365464e-4, 1.0e-16)
    Enum.at(second.covariance, 4) |> Enum.at(4) |> assert_close(1.9675566290541275e-8, 1.0e-20)
  end

  test "CNAV RINEX-4 details expose mixed-store preference, URA, and ISC corrections" do
    text = File.read!(fixture(["nav", "BRD400DLR_S_20261800000_01H_MN_trim.rnx"]))
    {:ok, legacy} = Broadcast.parse(text)
    {:ok, modern} = Broadcast.parse(text, message_preference: :modern)

    assert Broadcast.record_count(legacy) == 4
    assert Broadcast.message_preference(legacy) == :legacy
    assert Broadcast.message_preference(modern) == :modern

    records = Broadcast.records_detailed(legacy)
    assert Enum.frequencies_by(records, & &1.message) == %{gps_lnav: 2, qzss_cnav: 1, qzss_cnav2: 1}

    cnav = Enum.find(records, &(&1.cnav != nil))
    assert cnav.satellite_id == "J02"
    assert cnav.message == :qzss_cnav
    assert cnav.issue_of_data.issue == 288
    assert_close(cnav.cnav.adot_m_s, 0.07648849487305, 1.0e-14)
    assert_close(cnav.cnav.ura_ed_nominal_m, 0.125)
    assert_close(cnav.cnav.ura_ned0_nominal_m, 0.7071067811865476)
    assert_close(cnav.cnav_corrections.l2c_s, 1.1932570487261e-9, 1.0e-21)
    assert_close(Broadcast.cnav_ura_nominal(1), 2.8)
    assert_close(Broadcast.cnav_ura_ned(cnav.cnav, cnav.cnav.top), 0.7071067811865476)
  end

  test "GNSS QC suite reports, lints, and repairs fixture data" do
    obs_text = File.read!(fixture(["obs", "ESBC00DNK_R_20201770000_01D_30S_MO_trim.rnx"]))
    {:ok, obs} = Observations.parse(obs_text)

    {:ok, report} = QC.observation_report(obs)

    assert Map.take(report, [
             :total_epoch_records,
             :observation_epochs,
             :event_records,
             :missing_epochs,
             :interval_s,
             :interval_source
           ]) ==
             %{
               total_epoch_records: 2,
               observation_epochs: 2,
               event_records: 0,
               missing_epochs: 0,
               interval_s: 30.0,
               interval_source: "header"
             }

    [first_sat | _] = report.satellites
    assert first_sat == %{satellite: "G02", epochs_with_observations: 2, value_observations: 6}

    {:ok, lint_obs} = QC.lint_obs(obs)
    assert lint_obs.clean? == false
    assert lint_obs.counts == %{fatal: 0, error: 1, warning: 0, info: 0}

    {:ok, lint_obs_text} = QC.lint_obs_text(obs_text)
    assert lint_obs_text.counts == lint_obs.counts

    {:ok, repair_obs} = QC.repair_obs_text(obs_text)

    assert {length(repair_obs.actions), repair_obs.remaining.clean?, byte_size(repair_obs.rinex),
            byte_size(repair_obs.crinex)} ==
             {2, true, 31_658, 26_274}

    nav_text = File.read!(fixture(["nav", "BRD400DLR_S_20261800000_01H_MN_trim.rnx"]))
    {:ok, lint_nav} = QC.lint_nav_text(nav_text)
    assert lint_nav.counts == %{fatal: 0, error: 4, warning: 0, info: 3}

    {:ok, repair_nav} = QC.repair_nav_text(nav_text)
    assert {length(repair_nav.actions), repair_nav.remaining.clean?, repair_nav.leap_seconds} == {4, true, 18.0}
  end

  # The fitted B* and iteration-dependent stats below are pinned to x86-Linux
  # values: fitting the weakly-observable ISS drag term over a short arc lets
  # architecture-level ULP differences steer the last digits, so these are
  # canonical on one platform. Cross-binding alignment is tracked for 0.11.1.
  @tag skip:
         :os.type() != {:unix, :linux} and
           "iterative TLE-fit pins are x86-Linux canonical (see 0.11.1 alignment)"
  test "TLE fitting pins inverse SGP4 output against fixture samples" do
    {:ok, %{satellites: [satellite | _]}} = TLE.parse_file(File.read!(fixture(["core", "iss.tle"])))
    tle = satellite.tle

    as_epoch = fn dt ->
      {{dt.year, dt.month, dt.day}, {dt.hour, dt.minute, dt.second + elem(dt.microsecond, 0) / 1_000_000}}
    end

    samples =
      for seconds <- [-120, -60, 0, 60, 120] do
        dt = DateTime.add(tle.epoch, seconds, :second)
        {:ok, state} = Sidereon.SGP4.propagate(tle, dt)
        {:ok, jd} = Sidereon.GNSS.Time.utc_instant_split(as_epoch.(dt))
        %{epoch: jd, position_teme_km: state.position, velocity_teme_km_s: state.velocity}
      end

    {:ok, fit} =
      Sidereon.SGP4.fit_tle(
        samples,
        epoch: {:sample, 2},
        max_nfev: 80,
        x_scale: :jac,
        loss: :soft_l1,
        f_scale: 0.5,
        metadata: [catalog_number: 25_544, international_designator: "98067A", object_name: "ISS"]
      )

    assert fit.line1 == "1 25544U 98067A   26095.55331950  .00000000  00000-0  23064-5 0    17"
    assert fit.line2 == "2 25544  51.6328 299.5432 0006351 274.8255  85.2008 15.48786980    08"
    assert_close(fit.elements.bstar, 2.30642521665553e-6, 1.0e-18)
    assert_close(fit.elements.mean_motion_rev_per_day, 15.48786979609588, 1.0e-14)
    assert_close(fit.stats.rms_position_km, 5.687504456763275e-6, 1.0e-17)
    assert_close(fit.stats.rms_velocity_km_s, 2.501048751228124e-8, 1.0e-19)
    assert fit.stats.nfev == 22
    assert fit.stats.seed_refine_passes == 2
  end
end
