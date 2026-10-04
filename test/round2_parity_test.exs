defmodule Sidereon.Round2ParityTest do
  use ExUnit.Case, async: true

  alias Sidereon.Format.TLE
  alias Sidereon.GNSS.Broadcast
  alias Sidereon.GNSS.NMEA
  alias Sidereon.GNSS.QC
  alias Sidereon.GNSS.RINEX.Observations

  defp fixture(parts), do: Path.join(["test", "fixtures" | parts])

  defp assert_close(actual, expected, _delta_or_opts \\ 1.0e-12)

  defp assert_close(actual, expected, delta) when is_number(delta) do
    assert_in_delta actual, expected, delta
  end

  defp assert_close(actual, expected, opts) when is_list(opts) do
    relative = Keyword.fetch!(opts, :relative)
    absolute = Keyword.get(opts, :absolute, 0.0)

    assert_in_delta actual, expected, max(abs(expected) * relative, absolute)
  end

  defp assert_close_list(actual, expected, delta \\ 1.0e-12) do
    assert length(actual) == length(expected)

    Enum.zip(actual, expected)
    |> Enum.each(fn {a, e} -> assert_close(a, e, delta) end)
  end

  defp bits(value) when is_float(value), do: :binary.decode_unsigned(<<value::float-64>>)

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
    latitude = parsed.sentence.body.latitude
    assert latitude.degrees == 48
    assert latitude.minutes_scaled == 7_038
    assert latitude.decimals == 3
    assert latitude.negative == false
    assert latitude.degrees_float == 48.1173
    assert_in_delta latitude.radians, 0.83980531216986753, 1.0e-15

    longitude = parsed.sentence.body.longitude
    assert longitude.degrees == 11
    assert longitude.minutes_scaled == 31_000
    assert longitude.decimals == 3
    assert longitude.negative == false
    assert longitude.degrees_float == 11.516666666666667
    assert_in_delta longitude.radians, 0.20100375218801364, 1.0e-15
    assert parsed.diagnostics == %{skips: [], warnings: []}

    southwest =
      "$GPGGA,235959.99,3351.9085800,S,15112.5940000,W,4,07,0.75,58.7,M,,,,*3D\r\n"

    assert {:ok, parsed_southwest} = NMEA.parse_sentence(southwest)
    assert parsed_southwest.sentence.body.latitude.negative == true
    assert parsed_southwest.sentence.body.longitude.negative == true
    assert parsed_southwest.sentence.body.latitude.degrees_float == -33.865143
    assert parsed_southwest.sentence.body.longitude.degrees_float == -151.2099

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

  test "NMEA finish_with_output keeps final sentences, epochs, and diagnostics" do
    first = "$GPGGA,123519,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,*47\r\n"
    final = "$GPGGA,123520,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,"
    {:ok, accumulator} = NMEA.accumulator()

    {:ok, first_output} = NMEA.push(accumulator, first)
    assert length(first_output.sentences) == 1
    assert first_output.snapshots == []

    {:ok, pending} = NMEA.push(accumulator, final)
    assert pending.sentences == []
    {:ok, output} = NMEA.finish_with_output(accumulator)

    assert Enum.map(output.sentences, & &1.kind) == [:gga]
    assert Enum.map(output.snapshots, & &1.time_of_day.second) == [19, 20]
    assert output.diagnostics.skips == []
    assert length(output.diagnostics.warnings) == 1
    assert hd(output.diagnostics.warnings).at.line == 2
    assert hd(output.diagnostics.warnings).kind == "missing_metadata"

    {:ok, repeated} = NMEA.finish_with_output(accumulator)
    assert repeated.sentences == []
    assert repeated.snapshots == []
    assert repeated.diagnostics == %{skips: [], warnings: []}

    {:ok, malformed} = NMEA.accumulator()
    {:ok, _pending} = NMEA.push(malformed, "bad")
    {:ok, malformed_output} = NMEA.finish_with_output(malformed)
    assert malformed_output.sentences == []
    assert malformed_output.snapshots == []
    assert length(malformed_output.diagnostics.skips) == 1
    assert hd(malformed_output.diagnostics.skips).at.line == 1
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
    assert Enum.at(second.covariance, 1) |> Enum.at(1) |> bits() == 0x3F32E659E4062FCE
    Enum.at(second.covariance, 4) |> Enum.at(4) |> assert_close(1.9675566290541275e-8, 1.0e-20)
  end

  test "CNAV RINEX-4 details expose mixed-store preference, URA, and ISC corrections" do
    text = File.read!(fixture(["nav", "BRD400DLR_S_20261800000_01H_MN_trim.rnx"]))
    {:ok, legacy} = Broadcast.parse(text)
    {:ok, modern} = Broadcast.parse(text, message_preference: :modern)

    # Every decoded record is kept whatever its health: the GPS CNAV records and
    # the QZSS LNAV record state health 1 and were dropped before. The BeiDou
    # CNAV-2 frame is recognized and not decoded.
    assert Broadcast.record_count(legacy) == 7
    assert Broadcast.message_preference(legacy) == :legacy
    assert Broadcast.message_preference(modern) == :modern

    records = Broadcast.records_detailed(legacy)

    assert Enum.frequencies_by(records, & &1.message) ==
             %{gps_lnav: 2, gps_cnav: 2, qzss_lnav: 1, qzss_cnav: 1, qzss_cnav2: 1}

    assert records |> Enum.filter(&(&1.sv_health != 0.0)) |> Enum.map(&{&1.satellite_id, &1.message}) ==
             [{"G01", :gps_cnav}, {"G03", :gps_cnav}, {"J02", :qzss_lnav}]

    cnav = Enum.find(records, &(&1.message == :qzss_cnav))
    assert cnav.satellite_id == "J02"
    assert cnav.message == :qzss_cnav
    # A RINEX 4 CNAV record states no issue of data.
    assert cnav.issue_of_data == nil
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

    assert first_sat == %QC.SatelliteObservation{
             satellite: "G02",
             epochs_with_observations: 2,
             value_observations: 6
           }

    assert report.clock_jumps == []

    # R09 carries G3 (C3Q/L3Q) in both epochs; its CDMA carrier resolves, so
    # both of its satellite-epochs count for GLONASS. SBAS forms no
    # dual-frequency observation.
    assert report.cycle_slips.observations == 70
    assert report.cycle_slips.total_slips == 0
    assert report.cycle_slips.observations_per_slip == nil

    assert Enum.map(report.cycle_slips.by_system, &{&1.system, &1.observations, &1.slips, &1.observations_per_slip}) ==
             [{"G", 22, 0, nil}, {"R", 16, 0, nil}, {"E", 16, 0, nil}, {"C", 16, 0, nil}]

    gps_mp = Enum.find(report.multipath.systems, &(&1.system == "G"))
    assert gps_mp.mp1.n == 22
    assert_close(gps_mp.mp1.rms_m, 0.1069865674510667)
    assert gps_mp.mp2.n == 22
    assert_close(gps_mp.mp2.rms_m, 0.059282645631154554)

    g08_mp = Enum.find(report.multipath.satellites, &(&1.satellite == "G08"))
    assert g08_mp.mp1.n == 2
    assert_close(g08_mp.mp1.rms_m, 0.29432116710497774)
    assert g08_mp.mp2.n == 2
    assert_close(g08_mp.mp2.rms_m, 0.0019879508256253303)

    {:ok, rendered} = QC.render_text(report)
    assert rendered =~ "G   GPS"
    assert rendered =~ "R   GLONASS"
    assert rendered =~ "E   Galileo"
    assert rendered =~ "C   BeiDou"

    {:ok, html} = QC.render_html(report)
    assert html =~ "<title>RINEX Observation QC</title>"

    {:ok, json} = QC.to_json(report)
    assert json =~ "\"cycle_slips\""
    assert json =~ "\"multipath\""

    {:ok, lint_obs} = QC.lint_obs(obs)
    assert lint_obs.clean? == false
    assert lint_obs.counts == %{fatal: 0, error: 1, warning: 0, info: 0}

    {:ok, lint_obs_text} = QC.lint_obs_text(obs_text)
    assert lint_obs_text.counts == lint_obs.counts

    {:ok, repair_obs} =
      QC.repair_obs_text(obs_text,
        set_interval: true,
        set_time_of_last_obs: true,
        set_obs_counts: true,
        drop_empty_records: true,
        drop_unsupported: true
      )

    assert {length(repair_obs.actions), repair_obs.remaining.clean?, byte_size(repair_obs.rinex),
            byte_size(repair_obs.crinex)} ==
             {2, true, 34_112, 28_728}

    nav_text = File.read!(fixture(["nav", "BRD400DLR_S_20261800000_01H_MN_trim.rnx"]))
    {:ok, lint_nav} = QC.lint_nav_text(nav_text)
    # The CNAV-family records in this fixture decode, so nothing is reported as a
    # dropped block; the remaining findings are informational.
    assert lint_nav.counts == %{fatal: 0, error: 0, warning: 0, info: 6}

    {:ok, repair_nav} =
      QC.repair_nav_text(nav_text,
        set_time_of_last_obs: true,
        set_obs_counts: true,
        drop_empty_records: true,
        drop_unsupported: true
      )

    assert {length(repair_nav.actions), repair_nav.remaining.clean?, repair_nav.leap_seconds} == {4, true, 18.0}
  end

  test "TLE fitting recovers fixture samples with stable observable elements" do
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
        fit_bstar: false,
        metadata: [catalog_number: 25_544, international_designator: "98067A", object_name: "ISS"]
      )

    assert fit.stats.rms_position_km < 1.0e-4
    assert_close(fit.elements.mean_motion_rev_per_day, 15.487869796140957, relative: 1.0e-9)
    assert_close(fit.elements.inclination_deg, 51.63280000001107, relative: 1.0e-9)
    assert_close(fit.elements.eccentricity, 6.351002166405574e-4, relative: 1.0e-9, absolute: 1.0e-12)
    assert_close(fit.elements.right_ascension_deg, 299.5431999999641, relative: 1.0e-9)
    refute fit.stats.bstar_observable
    assert is_nil(fit.elements.omm_epoch_days)
    assert is_tuple(fit.omm_exact_sgp4_epoch)
    assert fit.omm_quantize_tle_derived_fields == false
    assert fit.omm_kvn =~ "CCSDS_OMM_VERS"

    assert Enum.all?(
             [
               :epoch,
               :omm_epoch_days,
               :bstar,
               :mean_motion_dot,
               :mean_motion_double_dot,
               :eccentricity,
               :argument_of_perigee_deg,
               :inclination_deg,
               :mean_anomaly_deg,
               :mean_motion_rev_per_day,
               :right_ascension_deg,
               :catalog_number
             ],
             &Map.has_key?(fit.elements, &1)
           )

    assert Enum.all?(
             [
               :rms_position_km,
               :max_position_km,
               :rms_position_axes_km,
               :rms_velocity_km_s,
               :tle_rms_position_km,
               :status,
               :nfev,
               :njev,
               :cost,
               :optimality,
               :bstar_observable,
               :seed_refine_passes
             ],
             &Map.has_key?(fit.stats, &1)
           )

    assert Enum.all?(
             [
               :ccsds_omm_vers,
               :classification,
               :creation_date,
               :originator,
               :message_id,
               :object_name,
               :object_id,
               :center_name,
               :ref_frame,
               :ref_frame_epoch,
               :time_system,
               :mean_element_theory,
               :epoch,
               :mean_motion,
               :semi_major_axis_km,
               :eccentricity,
               :inclination_deg,
               :ra_of_asc_node_deg,
               :arg_of_pericenter_deg,
               :mean_anomaly_deg,
               :gm_km3_s2,
               :spacecraft,
               :ephemeris_type,
               :classification_type,
               :norad_cat_id,
               :element_set_no,
               :rev_at_epoch,
               :bstar,
               :bterm_m2_kg,
               :mean_motion_dot,
               :mean_motion_ddot,
               :agom_m2_kg,
               :covariance,
               :user_defined,
               :comments
             ],
             &Map.has_key?(fit.omm, &1)
           )

    assert {:error, {:tle_fit_error, :arc_too_short, message, {2, 3}}} =
             Sidereon.SGP4.fit_tle(Enum.take(samples, 2),
               epoch: {:sample, 0},
               fit_bstar: false
             )

    assert message =~ "fit arc has 2 samples; need at least 3"

    assert {:error, {:did_not_converge, best_effort}} =
             Sidereon.SGP4.fit_tle(samples,
               epoch: {:sample, 2},
               max_nfev: 1,
               fit_bstar: false,
               metadata: [catalog_number: 25_544, international_designator: "98067A", object_name: "ISS"]
             )

    assert best_effort.stats.status == 0
    assert best_effort.line1 != ""
    assert best_effort.line2 != ""
    assert is_nil(best_effort.elements.omm_epoch_days)
    assert best_effort.omm_exact_sgp4_epoch == fit.omm_exact_sgp4_epoch
    assert best_effort.omm_quantize_tle_derived_fields == false

    assert Enum.all?(
             [
               :epoch,
               :omm_epoch_days,
               :bstar,
               :mean_motion_dot,
               :mean_motion_double_dot,
               :eccentricity,
               :argument_of_perigee_deg,
               :inclination_deg,
               :mean_anomaly_deg,
               :mean_motion_rev_per_day,
               :right_ascension_deg,
               :catalog_number
             ],
             &Map.has_key?(best_effort.elements, &1)
           )

    assert Enum.all?(
             [
               :rms_position_km,
               :max_position_km,
               :rms_position_axes_km,
               :rms_velocity_km_s,
               :tle_rms_position_km,
               :status,
               :nfev,
               :njev,
               :cost,
               :optimality,
               :bstar_observable,
               :seed_refine_passes
             ],
             &Map.has_key?(best_effort.stats, &1)
           )

    assert Enum.all?(
             [
               :ccsds_omm_vers,
               :classification,
               :creation_date,
               :originator,
               :message_id,
               :object_name,
               :object_id,
               :center_name,
               :ref_frame,
               :ref_frame_epoch,
               :time_system,
               :mean_element_theory,
               :epoch,
               :mean_motion,
               :semi_major_axis_km,
               :eccentricity,
               :inclination_deg,
               :ra_of_asc_node_deg,
               :arg_of_pericenter_deg,
               :mean_anomaly_deg,
               :gm_km3_s2,
               :spacecraft,
               :ephemeris_type,
               :classification_type,
               :norad_cat_id,
               :element_set_no,
               :rev_at_epoch,
               :bstar,
               :bterm_m2_kg,
               :mean_motion_dot,
               :mean_motion_ddot,
               :agom_m2_kg,
               :covariance,
               :user_defined,
               :comments
             ],
             &Map.has_key?(best_effort.omm, &1)
           )

    assert {:error,
            {:tle_fit_error, :invalid_input, "fit input invalid: max_nfev: must be positive",
             {"max_nfev", "must be positive"}}} =
             Sidereon.SGP4.fit_tle(samples,
               epoch: {:sample, 2},
               max_nfev: 0,
               fit_bstar: false,
               metadata: [catalog_number: 25_544, international_designator: "98067A", object_name: "ISS"]
             )
  end
end
