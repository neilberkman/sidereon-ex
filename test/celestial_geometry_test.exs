defmodule Sidereon.CelestialGeometryTest do
  use ExUnit.Case, async: true

  alias Sidereon.Bodies
  alias Sidereon.Bodies.SunMoonError
  alias Sidereon.Coordinates
  alias Sidereon.Eclipse
  alias Sidereon.Eclipse.EclipseError
  alias Sidereon.Eclipse.ShadowGradientError
  alias Sidereon.GNSS.Attitude
  alias Sidereon.GNSS.Attitude.AttitudeSample
  alias Sidereon.GNSS.Attitude.BeidouManufacturer
  alias Sidereon.GNSS.Attitude.BeidouOrbitClass
  alias Sidereon.GNSS.Attitude.CosineTurnParameters
  alias Sidereon.GNSS.Attitude.DybAxes
  alias Sidereon.GNSS.Attitude.GnssAttitude
  alias Sidereon.GNSS.Attitude.GnssAttitudeError
  alias Sidereon.GNSS.Attitude.GnssAttitudeLaw
  alias Sidereon.GNSS.Attitude.GnssBlock
  alias Sidereon.GNSS.Attitude.GnssBlockError
  alias Sidereon.GNSS.Attitude.NominalYaw
  alias Sidereon.GNSS.Time
  alias Sidereon.Iers2010EarthOrientationProvider, as: Iers
  alias Sidereon.Iers2010EarthOrientationProvider.FrameTransformError
  alias Sidereon.Iers2010EarthOrientationProvider.Iers2010EopSample
  alias Sidereon.Test.CoreGolden

  setup do
    %{golden: CoreGolden.load("celestial_geometry.json")}
  end

  test "GCRS Sun and Moon positions and mean-of-date rotations", %{golden: golden} do
    date = ~U[2020-06-25 00:00:00Z]

    for {key, result} <- [
          {"sun_moon_gcrs", Bodies.sun_moon_gcrs(0.2)},
          {"sun_moon_gcrs_at", Bodies.sun_moon_gcrs_at(date)},
          {"sun_moon_gcrs_at_tdb_seconds", Bodies.sun_moon_gcrs_at_tdb_seconds(16_000_000.0)}
        ] do
      [sun, moon] = Enum.map(golden[key], &CoreGolden.tuple3/1)
      assert result === {:ok, {sun, moon}}
    end

    assert Coordinates.gcrs_to_mean_of_date_matrix(date) ===
             {:ok, Enum.map(golden["gcrs_to_mean_of_date_matrix"], &CoreGolden.tuple3/1)}

    assert Coordinates.mean_of_date_to_gcrs_matrix(date) ===
             {:ok, Enum.map(golden["mean_of_date_to_gcrs_matrix"], &CoreGolden.tuple3/1)}

    detail = %{field: "civil datetime", reason: "invalid_civil_date"}

    assert {:error, %SunMoonError{kind: :invalid_input, detail: ^detail}} =
             Bodies.sun_moon_gcrs_at({{2020, 13, 25}, {0, 0, 0, 0}})

    for transform <- [&Coordinates.gcrs_to_mean_of_date_matrix/1, &Coordinates.mean_of_date_to_gcrs_matrix/1] do
      assert {:error, %FrameTransformError{kind: :invalid_input, detail: ^detail}} =
               transform.({{2020, 13, 25}, {0, 0, 0}})
    end

    assert {:error, %SunMoonError{kind: :invalid_input, detail: %{field: "sun[0]", reason: "not finite"}}} =
             Bodies.sun_moon_gcrs(1.0e308)
  end

  test "TT and TDB relations at a resolved epoch", %{golden: golden} do
    epoch = 16_000_000.0
    assert Time.tdb_minus_tt_seconds(epoch) === CoreGolden.f(golden["tdb_minus_tt_seconds"])
    assert Time.tt_from_tdb_j2000_seconds(epoch) === CoreGolden.f(golden["tt_from_tdb_j2000_seconds"])
    assert Time.tdb_from_tt_j2000_seconds(epoch) === CoreGolden.f(golden["tdb_from_tt_j2000_seconds"])
  end

  test "nominal yaw and Sun-fixed axes preserve the geocentric frame", %{golden: golden} do
    [position, velocity, sun] = Enum.map(~w(position velocity sun), &CoreGolden.tuple3(golden[&1]))
    yaw = golden["yaw"]
    dyb = golden["dyb"]

    expected_yaw = %NominalYaw{
      yaw_rad: CoreGolden.f(yaw["yaw_rad"]),
      beta_rad: CoreGolden.f(yaw["beta_rad"]),
      body_x: CoreGolden.tuple3(yaw["body_x"]),
      body_y: CoreGolden.tuple3(yaw["body_y"]),
      body_z: CoreGolden.tuple3(yaw["body_z"])
    }

    expected_dyb = %DybAxes{
      d: CoreGolden.tuple3(dyb["d"]),
      y: CoreGolden.tuple3(dyb["y"]),
      b: CoreGolden.tuple3(dyb["b"])
    }

    assert Attitude.nominal_yaw(position, velocity, sun) === {:ok, expected_yaw}
    assert Attitude.dyb_axes(position, sun) === {:ok, expected_dyb}

    sample = %AttitudeSample{position_m: position, velocity_m_s: velocity, sun_position_m: sun}
    assert sample === struct!(AttitudeSample, Map.from_struct(sample))
    refute sample == %{sample | position_m: {0.0, 0.0, 0.0}}

    attitude = %GnssAttitude{
      mode: :nominal,
      yaw_rad: expected_yaw.yaw_rad,
      nominal_yaw_rad: expected_yaw.yaw_rad,
      beta_rad: expected_yaw.beta_rad,
      orbit_angle_rad: 0.0,
      body_x: expected_yaw.body_x,
      body_y: expected_yaw.body_y,
      body_z: expected_yaw.body_z,
      dyb: expected_dyb
    }

    assert attitude === struct!(GnssAttitude, Map.from_struct(attitude))
    refute attitude == %{attitude | yaw_rad: 1.0}
  end

  test "GNSS block names, defaults, and typed refusals" do
    assert {:ok, :gps_iir} = GnssBlock.from_igs_name("  BLOCK IIR-A ")
    assert "BLOCK IIR-B" == GnssBlock.igs_name(:gps_iir)
    assert "G" == GnssBlock.system(:gps_iir)
    assert GnssBlock.to_string(:gps_iir) == "BLOCK IIR-B"
    assert GnssBlock.compare(:gps_iia, :gps_iir) == :lt
    assert BeidouManufacturer.compare(:secm, :cast) == :gt
    assert BeidouOrbitClass.compare(:meo, :meo) == :eq
    assert {:ok, {:beidou3_meo, nil}} = GnssBlock.from_constellation_block_type(:beidou, "BDS-3", :meo)

    assert {:ok, {:gps_iir, %{yaw_rate_rad_s: 0.003490658503988659}}} = GnssAttitudeLaw.for_block(:gps_iir)
    assert Attitude.gps_iir_default_yaw_rate_rad_s() === 0.003490658503988659

    assert {:ok, {:cosine_turn, %CosineTurnParameters{start_angle: :colinearity}}} =
             GnssAttitudeLaw.for_block(:galileo_foc)

    assert %CosineTurnParameters{start_angle: :orbit_angle} = Attitude.beidou3_cast_meo_turn()
    assert %CosineTurnParameters{start_angle: :orbit_angle} = Attitude.beidou3_cast_igso_turn()
    assert %CosineTurnParameters{start_angle: :colinearity} = Attitude.galileo_foc_turn()
    assert Attitude.gps_iia_default_yaw_rate_rad_s(0) == nil

    assert {:error, %GnssBlockError{kind: :unknown, detail: %{name: "Unregistered"}}} =
             GnssBlock.from_igs_name("Unregistered")

    assert {:error, %GnssBlockError{kind: :unsupported, detail: %{name: "GLONASS-K1"}}} =
             GnssBlock.from_igs_name("GLONASS-K1")

    assert {:error, %GnssBlockError{kind: :beidou_orbit_class_required, detail: %{block_type: "BDS-3"}}} =
             GnssBlock.from_constellation_block_type(:beidou, "BDS-3")

    assert {:error, %GnssAttitudeError{kind: :no_default_yaw_rate, detail: %{prn: nil}}} =
             GnssAttitudeLaw.for_block(:gps_iia)
  end

  test "single-state attitude geometry returns failure details" do
    assert {:error, %GnssAttitudeError{kind: :zero_length, detail: %{field: "position_m"}}} =
             Attitude.dyb_axes({0.0, 0.0, 0.0}, {0.0, 1.0, 0.0})

    assert {:error, %GnssAttitudeError{kind: :non_finite, detail: %{field: "position_m"}}} =
             Attitude.dyb_axes({1.0e308, 1.0e308, 0.0}, {0.0, 1.0, 0.0})

    assert {:error, %GnssAttitudeError{kind: :degenerate_geometry, detail: %{t_s: nil}}} =
             Attitude.dyb_axes({1.0, 0.0, 0.0}, {2.0, 0.0, 0.0})
  end

  test "combined occultation, conical gradients and eclipse refusals", %{golden: golden} do
    [position, sun, moon] = Enum.map(~w(position sun moon), &CoreGolden.tuple3(golden[&1]))
    [fraction, gradient] = golden["shadow_model_moon_gradient"]

    assert Eclipse.shadow_fraction_with_model_moon_and_gradient(position, sun, moon, :wgs84_oblate) ===
             {:ok, {CoreGolden.f(fraction), CoreGolden.tuple3(gradient)}}

    assert Eclipse.moon_shadow_fraction(position, sun, moon) === {:ok, 0.0}
    assert Eclipse.shadow_fraction_with_moon(position, sun, moon) === {:ok, 0.0}
    assert Eclipse.shadow_fraction_with_model_and_moon(position, sun, moon, :wgs84_oblate) === {:ok, 0.0}
    assert Eclipse.status_with_moon(position, sun, moon) == {:ok, :sunlit}
    assert Eclipse.status_with_model_and_moon(position, sun, moon, :wgs84_oblate) == {:ok, :sunlit}
    assert Eclipse.shadow_fraction_with_gradient(position, sun) === {:ok, {0.0, {0.0, 0.0, 0.0}}}

    assert Eclipse.shadow_fraction_with_model_and_gradient(position, sun, :wgs84_oblate) ===
             {:ok, {0.0, {0.0, 0.0, 0.0}}}

    assert Eclipse.iau_2015_solar_radius_km() === 695_700.0

    assert {:error, %ShadowGradientError{kind: :eclipse, detail: %{field: "sun_pos", reason: "zero vector"}}} =
             Eclipse.shadow_fraction_with_gradient(position, {0.0, 0.0, 0.0})

    assert {:error, %ShadowGradientError{kind: :numerical_failure, detail: detail} = error} =
             Eclipse.shadow_fraction_with_gradient({-1.5e6, 0.0, 0.0}, {1.5e8, 0.0, 0.0})

    assert detail === %{}
    assert to_string(error) === "shadow fraction gradient is not finite"

    assert {:error, %EclipseError{kind: :invalid_input, detail: detail}} =
             Eclipse.shadow_fraction_with_moon(position, sun, {0.0, 0.0, 0.0})

    assert detail === %{field: "moon_pos", reason: "zero vector"}

    assert {:error, %EclipseError{kind: :invalid_earth_shadow_model, detail: %{model: :invalid}}} =
             Eclipse.shadow_fraction_with_model_and_moon(position, sun, moon, :invalid)
  end

  test "daily Earth orientation resolves the quaternion and rotation-rate matrices", %{golden: golden} do
    sample = %Iers2010EopSample{
      mjd_utc: 59_025,
      xp_arcsec: 0.1,
      yp_arcsec: 0.15,
      ut1_minus_utc_s: -0.21,
      lod_s: 0.001,
      dx_arcsec: 0.0001,
      dy_arcsec: -0.0002
    }

    next = %{sample | mjd_utc: 59_026}
    assert {:ok, provider} = Iers.new([sample, next])
    assert {:ok, same_provider} = Iers.new([sample, next])
    assert Iers.equal?(provider, same_provider)
    refute Iers.equal?(provider, Iers.with_validity(provider, :permissive))
    assert {:ok, orientation} = Iers.orientation_at_utc_mjd(provider, 59_025, 12_345.5)

    values = golden["eop"]
    assert orientation.iers2010_quaternion === List.to_tuple(CoreGolden.f(values["quaternion"]))

    assert orientation.earth_rotation_vector_itrf_rad_s ===
             CoreGolden.tuple3(values["earth_rotation_vector_itrf_rad_s"])

    assert orientation.gcrf_to_itrf_matrix === Enum.map(values["rotation"], &CoreGolden.tuple3/1)
    assert orientation.itrf_to_gcrf_matrix === Enum.map(values["inverse_rotation"], &CoreGolden.tuple3/1)
    assert orientation.gcrf_to_itrf_rotation_rate_matrix === Enum.map(values["rotation_rate"], &CoreGolden.tuple3/1)

    assert orientation.itrf_to_gcrf_rotation_rate_matrix ===
             Enum.map(values["inverse_rotation_rate"], &CoreGolden.tuple3/1)

    assert orientation.ut1_degraded == nil

    assert {:ok, at_tdb} = Iers.orientation_at_tdb_seconds(provider, CoreGolden.f(golden["iers_tdb_epoch"]))
    assert at_tdb.iers2010_quaternion === List.to_tuple(CoreGolden.f(golden["iers_at_tdb_quaternion"]))

    assert {:error,
            %FrameTransformError{
              kind: :invalid_input,
              detail: %{field: "samples", reason: "MJDs must be strictly increasing"}
            }} =
             Iers.new([next, sample])

    assert {:error,
            %FrameTransformError{
              kind: :invalid_input,
              detail: %{field: "seconds_in_day", reason: "outside the UTC day"}
            }} =
             Iers.orientation_at_utc_mjd(provider, 59_025, 86_401.0)

    assert {:error, %FrameTransformError{kind: :ut1_outside_coverage, detail: %{reason: :before_coverage}}} =
             Iers.orientation_at_utc_mjd(provider, 59_024, 0.0)
  end
end
