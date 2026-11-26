defmodule Sidereon.OrbitAttitudeTest do
  use ExUnit.Case, async: true

  alias Sidereon.DeEphemeris
  alias Sidereon.GNSS.Attitude
  alias Sidereon.GNSS.Attitude.AttitudeSample
  alias Sidereon.GNSS.Attitude.DybAxes
  alias Sidereon.GNSS.Attitude.GnssAttitude
  alias Sidereon.GNSS.Attitude.GnssAttitudeError
  alias Sidereon.GNSS.Attitude.GnssAttitudeLaw, as: Law
  alias Sidereon.GNSS.Attitude.GnssBlock
  alias Sidereon.GNSS.Attitude.GnssBlockError
  alias Sidereon.GNSS.Attitude.OrbitAttitudeTrajectory, as: Trajectory
  alias Sidereon.GNSS.Broadcast
  alias Sidereon.GNSS.SP3
  alias Sidereon.Iers2010EarthOrientationProvider, as: Iers
  alias Sidereon.OrbitScoring.BroadcastOrbit
  alias Sidereon.OrbitScoring.OrbitScoreError
  alias Sidereon.OrbitScoring.OrbitScoreOptions
  alias Sidereon.OrbitScoring.OrbitTrajectory
  alias Sidereon.OrbitScoring.PredictedSp3
  alias Sidereon.OrbitScoring.SisreWeights
  alias Sidereon.OrbitScoring.TrajectorySample
  alias Sidereon.Propagator
  alias Sidereon.Propagator.Analytic.BrouwerLyddanePropagator
  alias Sidereon.Propagator.Analytic.CircularElements
  alias Sidereon.Propagator.Analytic.EcksteinHechlerPropagator
  alias Sidereon.Propagator.Analytic.KeplerianElements
  alias Sidereon.Propagator.Analytic.ZonalHarmonics
  alias Sidereon.Propagator.DenseOutput
  alias Sidereon.Propagator.IntegratorOptions
  alias Sidereon.Propagator.PropagationResult
  alias Sidereon.Propagator.PropagationStats
  alias Sidereon.Test.CoreGolden

  @nav Path.expand("fixtures/nav/ESBC00DNK_R_20201770000_01D_MN.rnx", __DIR__)
  @sp3 Path.expand("fixtures/sp3/GBM0MGXRAP_20201770000_01D_05M_ORB_120epoch.sp3", __DIR__)
  @de Path.expand("fixtures/de/lnxp1990.440", __DIR__)
  @gpst %{time_scale: "GPST", nanos_since_j2000: 646_056_000_000_000_000}
  @circular %CircularElements{
    a_km: 7200.0,
    ex: 0.01,
    ey: -0.004,
    i_rad: 0.62,
    raan_rad: 1.2,
    mean_latitude_argument_rad: 0.15
  }
  @keplerian %KeplerianElements{
    a_km: 7200.0,
    e: 0.03,
    i_rad: 0.62,
    arg_perigee_rad: 0.22,
    raan_rad: 1.15,
    mean_anomaly_rad: 0.34
  }

  setup do
    {:ok, golden: CoreGolden.load("orbit_attitude.json")}
  end

  test "SP3 and predicted SP3 supply GCRF states through IERS 2010", %{golden: golden} do
    eop = %Iers.Iers2010EopSample{
      mjd_utc: 59_025,
      xp_arcsec: 0.1,
      yp_arcsec: 0.15,
      ut1_minus_utc_s: -0.21,
      lod_s: 0.001,
      dx_arcsec: 0.0001,
      dy_arcsec: -0.0002,
      pole_rates_rad_s: nil
    }

    assert {:ok, iers} = Iers.new([eop, %{eop | mjd_utc: 59_026}])
    product = SP3.load!(@sp3)
    assert {:ok, trajectory} = Trajectory.from_sp3(product, "G03", iers)
    assert_case(trajectory, golden["sp3"])

    assert {:ok, predicted} = PredictedSp3.with_cutoff(product, @gpst)
    assert {:ok, trajectory} = Trajectory.from_orbit_source(predicted, {:gps, 3}, iers)
    assert_case(trajectory, golden["predicted"])
  end

  test "broadcast navigation and its scoring source supply GCRF states through the TDB provider", %{golden: golden} do
    navigation = Broadcast.load!(@nav)
    assert {:ok, trajectory} = Trajectory.from_broadcast(navigation, "G03")
    assert_case(trajectory, golden["broadcast"])
    assert {:ok, trajectory} = Trajectory.from_broadcast(navigation, "G03", {:tdb, :permissive})
    assert_case(trajectory, golden["broadcast"])

    assert {:ok, source} = BroadcastOrbit.new(navigation, @gpst)
    assert Sidereon.OrbitScoring.frame(source) === {:ok, :broadcast_datums}
    assert Sidereon.OrbitScoring.reference_point(source) === {:ok, :antenna_phase_center}
    assert Sidereon.OrbitScoring.clock_includes_relativity(source) === {:ok, true}
    assert Sidereon.OrbitScoring.time_scale(source) === {:ok, "GPST"}
    assert Sidereon.OrbitScoring.sp3_time_system(source) === {:ok, nil}
    assert {:ok, trajectory} = Trajectory.from_orbit_source(source, "G03", :tdb)
    assert_case(trajectory, golden["broadcast_source"])

    product = SP3.load!(@sp3)
    epoch = CoreGolden.f(golden["sp3"]["epoch"])
    assert {:ok, default} = Trajectory.from_sp3(product, "G03")
    assert {:ok, permissive} = Trajectory.from_sp3(product, "G03", {:tdb, :permissive})
    assert {:ok, %AttitudeSample{}} = sample = Trajectory.sample(default, epoch)
    assert Trajectory.sample(permissive, epoch) === sample

    options = %OrbitScoreOptions{
      horizon_bin_edges_s: [-1.0e7, 1.0e7],
      sisre_weights: {:fixed, %SisreWeights{radial: 0.5, transverse_normal_squared: 0.25}}
    }

    assert {:ok, report} = Sidereon.OrbitScoring.score_orbit(source, product, ["G03"], options)
    assert report.frame === :broadcast_datums
    assert report.source_reference_point === :antenna_phase_center
  end

  test "sampled trajectories use a configurable velocity half step", %{golden: golden} do
    utc = fn shift -> %{time_scale: "UTC", nanos_since_j2000: (646_358_400 + shift) * 1_000_000_000} end

    samples =
      for {shift, position} <- [
            {-2, {21_002_000.0, -15_002_000.0, 8_001_000.0}},
            {0, {21_000_000.0, -15_000_000.0, 8_000_000.0}},
            {2, {20_996_000.0, -14_997_000.0, 7_998_000.0}}
          ] do
        %TrajectorySample{satellite: "G03", epoch: utc.(shift), position_ecef_m: position}
      end

    assert {:ok, source} = OrbitTrajectory.new("ITRF", utc.(0), samples)
    assert {:ok, trajectory} = Trajectory.from_orbit_source(source, "G03")

    assert {:error, %OrbitScoreError{kind: :invalid_input, detail: detail}} =
             Trajectory.with_velocity_half_step_s(trajectory, 5.0e-9)

    assert detail === %{field: "velocity_half_step_s", reason: "below the 1e-8 s resolution of SP3 epochs"}

    assert {:error, %OrbitScoreError{kind: :invalid_input, detail: detail}} =
             Trajectory.with_velocity_half_step_s(trajectory, 0.0)

    assert detail === %{field: "velocity_half_step_s", reason: "not positive and finite"}

    assert {:ok, configured} = Trajectory.with_velocity_half_step_s(trajectory, 2.0)
    assert_case(configured, golden["sampled"])
  end

  test "analytic orbits and JPL DE supply satellite and Sun states", %{golden: golden} do
    gravity = ZonalHarmonics.earth()
    assert {:ok, eh} = EcksteinHechlerPropagator.from_mean_elements(10.0, @circular, gravity)
    assert {:ok, bl} = BrouwerLyddanePropagator.from_mean_elements(10.0, @keplerian, gravity, 1.0e-15)

    assert_case(Trajectory.from_eckstein_hechler(eh), golden["eckstein_hechler"])
    assert_case(Trajectory.from_brouwer_lyddane(bl), golden["brouwer_lyddane"])

    assert {:ok, de} = DeEphemeris.load(@de)
    epoch = CoreGolden.f(golden["de"]["epoch"])
    assert {:ok, eh} = EcksteinHechlerPropagator.from_mean_elements(epoch, @circular, gravity)

    eh |> Trajectory.from_eckstein_hechler() |> Trajectory.with_de_ephemeris(de) |> assert_case(golden["de"])
  end

  test "Earth-fixed trajectories can use permissive TDB orientation outside UT1 coverage" do
    epoch = 3_155_760_000.0
    instant = fn offset -> %{time_scale: "TDB", nanos_since_j2000: trunc(epoch + offset) * 1_000_000_000} end

    samples =
      for offset <- [-1, 0, 1] do
        %TrajectorySample{
          satellite: "G03",
          epoch: instant.(offset),
          position_ecef_m: {21_000_000.0, -15_000_000.0 + offset * 1000.0, 8_000_000.0}
        }
      end

    assert {:ok, source} = OrbitTrajectory.new("ITRF", instant.(0), samples)

    for orientation <- [:tdb, {:tdb, :strict}] do
      assert {:ok, trajectory} = Trajectory.from_orbit_source(source, "G03", orientation)
      assert {:ok, trajectory} = Trajectory.with_velocity_half_step_s(trajectory, 1.0)

      assert {:error, %GnssAttitudeError{kind: :trajectory_unavailable, detail: %{t_s: ^epoch}}} =
               Trajectory.sample(trajectory, epoch)
    end

    assert {:ok, trajectory} = Trajectory.from_orbit_source(source, "G03", {:tdb, :permissive})
    assert {:ok, trajectory} = Trajectory.with_velocity_half_step_s(trajectory, 1.0)
    assert {:ok, %AttitudeSample{}} = Trajectory.sample(trajectory, epoch)
    assert {:ok, %GnssAttitude{}} = Attitude.gnss_attitude(Law.orbit_normal(), trajectory, epoch)

    assert {:error, %OrbitScoreError{kind: :invalid_input, detail: %{reason: {:invalid_input, {:orientation, :bad}}}}} =
             Trajectory.from_orbit_source(source, "G03", :bad)
  end

  test "DP5(4) returns continuous output with closed coverage", %{golden: golden} do
    integration = %{IntegratorOptions.default() | dense_output: true}
    initial = {0.0, {7000.0, 0.0, 0.0}, {0.0, 7.546049108166282, 0.0}}

    assert {:ok, %PropagationResult{dense: %DenseOutput{} = dense} = result} =
             Propagator.propagate_to_with_context(initial, 600.0, integration: integration)

    expected = golden["numerical"]
    assert result.final_state === state(expected["final_state"])
    assert result.points === Enum.map(expected["points"], &state/1)
    assert result.events === []
    assert result.ut1_degraded === nil
    [accepted, rejected, evaluations] = expected["stats"]

    assert result.stats === %PropagationStats{
             accepted_steps: accepted,
             rejected_steps: rejected,
             evaluations: evaluations
           }

    trajectory = Trajectory.from_dense_output(dense)
    assert_case(trajectory, golden["dense"])

    assert {:error, %GnssAttitudeError{kind: :trajectory_unavailable, detail: %{t_s: 601.0} = detail} = error} =
             Attitude.gnss_attitude(Law.orbit_normal(), trajectory, 601.0)

    assert detail === %{t_s: 601.0}
    assert to_string(error) === "trajectory has no state at t = 601 s"
    assert Trajectory.sample(trajectory, 601.0) === {:error, error}

    assert {:ok, %PropagationResult{dense: nil, points: [^initial, final]}} =
             Propagator.propagate_to_with_context(initial, 600.0)

    assert final === state(expected["final_state"])
  end

  test "yaw-law refusals preserve the invalid parameter, epoch and domain limit" do
    elements = %{@circular | ex: 0.001, ey: 0.002, i_rad: 0.5, raan_rad: 0.25, mean_latitude_argument_rad: 0.125}

    assert {:ok, source} =
             EcksteinHechlerPropagator.from_mean_elements(646_315_200.25, elements, ZonalHarmonics.earth())

    trajectory = Trajectory.from_eckstein_hechler(source)
    epoch = 646_315_800.25

    turn = %Attitude.CosineTurnParameters{
      beta_limit_rad: 1.0e-9,
      beta_limit_inclusive: false,
      start_angle: :orbit_angle,
      start_angle_rad: 0.1,
      period_s: 1.0e7
    }

    cases = [
      {Law.fixed_beta_yaw_steering(0.0), :invalid_parameter, %{field: "beta0_rad", value: 0.0}},
      {Law.beidou3_meo_unknown_manufacturer(Attitude.beidou3_cast_meo_turn(), 1.5), :beidou_manufacturer_required,
       %{t_s: epoch}},
      {Law.cosine_turn(turn), :turn_end_not_found, %{t_s: epoch}},
      {Law.gps_iia(1000.0, 0.0, 1.6), :outside_validated_domain,
       %{
         t_s: epoch,
         reason:
           "GPS IIA maximum yaw rate above 1e5 times the orbital rate, where the shadow crossing's yaw is set only to the rate times the uncertainty of the shadow entry"
       }}
    ]

    for {law, kind, detail} <- cases do
      assert {:error, %GnssAttitudeError{kind: ^kind, detail: actual}} = Attitude.gnss_attitude(law, trajectory, epoch)
      assert actual === detail
    end
  end

  test "yaw laws distinguish nominal, noon, midnight, shadow and modified steering", %{golden: golden} do
    elements = %CircularElements{
      a_km: 26_560.0,
      ex: 0.0,
      ey: 0.0,
      i_rad: 0.409,
      raan_rad: 0.0,
      mean_latitude_argument_rad: 0.0
    }

    assert {:ok, source} = EcksteinHechlerPropagator.from_mean_elements(0.0, elements, ZonalHarmonics.earth())
    trajectory = Trajectory.from_eckstein_hechler(source)
    iir = Law.gps_iir(Attitude.gps_iir_default_yaw_rate_rad_s())

    iif =
      Law.gps_iif(
        Attitude.gps_iif_default_yaw_rate_rad_s(),
        Attitude.gps_iif_default_yaw_bias_rad(),
        Attitude.gps_shadow_limit_rad()
      )

    for {name, law} <- [
          {"nominal", iir},
          {"noon_turn", iir},
          {"midnight_turn", iir},
          {"shadow", iif},
          {"modified_yaw_steering", Law.fixed_beta_yaw_steering(0.1)}
        ] do
      %{"epoch" => epoch, "attitude" => attitude} = golden["modes"][name]
      assert_attitude(law, trajectory, CoreGolden.f(epoch), attitude)
    end
  end

  test "published angular constants and cosine-turn criteria in radians" do
    for {name, degrees} <- [
          {:gps_iia_default_yaw_bias_rad, 0.5},
          {:gps_iir_default_yaw_rate_rad_s, 0.2},
          {:gps_iif_default_yaw_rate_rad_s, 0.11},
          {:gps_iif_default_yaw_bias_rad, -0.7},
          {:gps_shadow_limit_rad, 166.75},
          {:glonass_m_default_yaw_rate_rad_s, 0.25},
          {:glonass_m_shadow_limit_rad, 165.8},
          {:galileo_iov_beta_x_rad, 15.0},
          {:galileo_iov_beta_y_rad, 2.0},
          {:gps_iii_beta_x_rad, 15.0},
          {:gps_iii_beta_y_rad, 5.8},
          {:beidou3_secm_beta0_rad, 3.0},
          {:beidou2_ys_to_on_beta_rad, 4.1},
          {:beidou2_on_to_ys_beta_rad, 3.9}
        ] do
      assert apply(Attitude, name, []) === degrees * :math.pi() / 180.0
    end

    assert Attitude.gps_iia_default_yaw_rate_rad_s(1) === 0.1211 * (:math.pi() / 180.0)

    for {getter, beta, inclusive, angle, start, period} <- [
          {:galileo_foc_turn, 4.1, false, :colinearity, 10.0, 5656.0},
          {:beidou3_cast_meo_turn, 3.0, true, :orbit_angle, 6.0, 3090.0},
          {:beidou3_cast_igso_turn, 3.0, true, :orbit_angle, 6.0, 5740.0}
        ] do
      assert apply(Attitude, getter, []) === %Attitude.CosineTurnParameters{
               beta_limit_rad: beta * :math.pi() / 180.0,
               beta_limit_inclusive: inclusive,
               start_angle: angle,
               start_angle_rad: start * :math.pi() / 180.0,
               period_s: period
             }
    end
  end

  test "yaw-law constructors retain every parameter" do
    turn = %Attitude.CosineTurnParameters{
      beta_limit_rad: 0.1,
      beta_limit_inclusive: true,
      start_angle: :orbit_angle,
      start_angle_rad: 0.2,
      period_s: 400.0
    }

    gps = %{yaw_rate_rad_s: 0.25, yaw_bias_rad: 0.125, shadow_limit_rad: 2.0}
    assert Law.gps_iia(0.25, 0.125, 2) === {:gps_iia, gps}
    assert Law.gps_iif(0.25, 0.125, 2) === {:gps_iif, gps}
    assert Law.gps_iir(0.25) === {:gps_iir, %{yaw_rate_rad_s: 0.25}}
    assert Law.glonass_m(0.25, 2) === {:glonass_m, %{yaw_rate_rad_s: 0.25, shadow_limit_rad: 2.0}}
    assert Law.galileo_iov(0.25, 0.125) === {:galileo_iov, %{beta_x_rad: 0.25, beta_y_rad: 0.125}}
    assert Law.cosine_turn(turn) === {:cosine_turn, turn}

    assert Law.beidou_orbit_normal_switch(0.25, 0.125) ===
             {:beidou_orbit_normal_switch, %{ys_to_on_beta_rad: 0.25, on_to_ys_beta_rad: 0.125}}

    assert Law.fixed_beta_yaw_steering(0.25) === {:fixed_beta_yaw_steering, %{beta0_rad: 0.25}}

    assert Law.beidou3_meo_unknown_manufacturer(turn, 0.25) ===
             {:beidou3_meo_unknown_manufacturer, %{cast: turn, secm_beta0_rad: 0.25}}

    assert Law.orbit_normal() === :orbit_normal
  end

  test "published block names and constellations decode to their canonical values" do
    for {name, block, system} <- [
          {"BLOCK IIA", :gps_iia, "G"},
          {"BLOCK IIR-B", :gps_iir, "G"},
          {"BLOCK IIR-M", :gps_iirm, "G"},
          {"BLOCK IIF", :gps_iif, "G"},
          {"BLOCK IIIA", :gps_iii, "G"},
          {"GLONASS-M", :glonass_m, "R"},
          {"GALILEO-1", :galileo_iov, "E"},
          {"GALILEO-2", :galileo_foc, "E"},
          {"BEIDOU-2G", :beidou2_geo, "C"},
          {"BEIDOU-2I", :beidou2_igso, "C"},
          {"BEIDOU-2M", :beidou2_meo, "C"},
          {"BEIDOU-3G-CAST", :beidou3_geo, "C"},
          {"BEIDOU-3I", :beidou3_igso, "C"},
          {"BEIDOU-3M", {:beidou3_meo, nil}, "C"},
          {"BEIDOU-3M-CAST", {:beidou3_meo, :cast}, "C"},
          {"BEIDOU-3M-SECM", {:beidou3_meo, :secm}, "C"}
        ] do
      assert GnssBlock.from_igs_name(name) === {:ok, block}
      assert GnssBlock.igs_name(block) === name
      assert GnssBlock.system(block) === system
    end

    assert GnssBlock.from_constellation_block_type(:beidou, "BDS-2", :geo) === {:ok, :beidou2_geo}
    assert GnssBlock.from_constellation_block_type(:beidou, "BDS-2", :igso) === {:ok, :beidou2_igso}

    assert {:error, %GnssBlockError{kind: :invalid_system, detail: detail}} =
             GnssBlock.from_constellation_block_type(:fictional, "BLOCK IIF")

    assert detail === %{system: :fictional}

    assert {:error, %GnssBlockError{} = error} = GnssBlock.from_igs_name("X")
    assert to_string(error) === ~s(unknown GNSS block name "X")
  end

  defp assert_case(trajectory, %{"epoch" => epoch, "sample" => sample, "attitude" => attitude}) do
    epoch = CoreGolden.f(epoch)

    assert Trajectory.sample(trajectory, epoch) ===
             {:ok,
              %AttitudeSample{
                position_m: CoreGolden.tuple3(sample["position_m"]),
                velocity_m_s: CoreGolden.tuple3(sample["velocity_m_s"]),
                sun_position_m: CoreGolden.tuple3(sample["sun_position_m"])
              }}

    assert_attitude(Law.orbit_normal(), trajectory, epoch, attitude)
  end

  defp assert_attitude(law, trajectory, epoch, attitude) do
    assert Attitude.gnss_attitude(law, trajectory, epoch) ===
             {:ok,
              %GnssAttitude{
                mode: String.to_existing_atom(attitude["mode"]),
                yaw_rad: CoreGolden.f(attitude["yaw_rad"]),
                nominal_yaw_rad: CoreGolden.f(attitude["nominal_yaw_rad"]),
                beta_rad: CoreGolden.f(attitude["beta_rad"]),
                orbit_angle_rad: CoreGolden.f(attitude["orbit_angle_rad"]),
                body_x: CoreGolden.tuple3(attitude["body_x"]),
                body_y: CoreGolden.tuple3(attitude["body_y"]),
                body_z: CoreGolden.tuple3(attitude["body_z"]),
                dyb: %DybAxes{
                  d: CoreGolden.tuple3(attitude["dyb"]["d"]),
                  y: CoreGolden.tuple3(attitude["dyb"]["y"]),
                  b: CoreGolden.tuple3(attitude["dyb"]["b"])
                }
              }}
  end

  defp state([epoch, position, velocity]),
    do: {CoreGolden.f(epoch), CoreGolden.tuple3(position), CoreGolden.tuple3(velocity)}
end
