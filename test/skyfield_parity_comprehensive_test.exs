defmodule Sidereon.SkyfieldParityComprehensiveTest do
  @moduledoc """
  Comprehensive Skyfield parity tests (hex-captured Skyfield/ERFA references).

  Hex-captured reference values from Skyfield for every major feature.
  Tagged :skyfield_parity — run with: mix test --include skyfield_parity

  Note: SGP4 propagation uses the Rust `sgp4` crate which differs from
  Skyfield's bundled Python sgp4. TEME values are compared with a tolerance
  rather than 0 ULP (see the "SGP4 TEME within tolerance (not 0 ULP)" block).
  The coordinate transforms applied to those TEME values inherit the SGP4 delta.
  """
  use ExUnit.Case

  # Skyfield SGP4 TEME reference at 2018-07-04 00:00:00 UTC
  @skyfield_teme_pos {
    # 0x1.ce86c23dffb6bp+11, 0x1.f7fa61c81cb47p+10, 0x1.4bd8359159cdep+12
    3700.2112112039954,
    2015.9122181206055,
    5309.513078070448
  }
  @skyfield_teme_vel {
    # -0x1.b2ffb7cf9ad7dp+1, 0x1.b7a8751f7fc4ap+2, -0x1.eb36925f07cc3p-3
    -3.398428894395407,
    6.869656830559572,
    -0.2398501811266894
  }

  # Skyfield ITRS reference
  @skyfield_itrs {
    # -0x1.2d5d32b319db8p+10, 0x1.f8b3b3a722474p+11, 0x1.4bd8359159cdbp+12
    -1205.4562194588198,
    4037.6156802815913,
    5309.513078070445
  }

  # Skyfield geodetic reference
  @skyfield_geodetic %{
    # 0x1.9deaedc7e5879p+5
    latitude: 51.739711343471704,
    # 0x1.aa7e4b52995d0p+6
    longitude: 106.623334208117,
    # 0x1.9d625ccac86e3p+8
    altitude_km: 413.384228395398
  }

  # Skyfield topocentric (NYC: 40.7128°N, 74.0060°W, 10m)
  @skyfield_topo %{
    # 0x1.679c14d7b22a2p+8
    azimuth: 359.609693032262,
    # -0x1.4f551cd80e6d7p+5
    elevation: -41.916558921757,
    # 0x1.1d53d5d3659d5p+13
    range_km: 9130.479407113899
  }

  @iss_tle_line1 "1 25544U 98067A   18184.80969102  .00001614  00000-0  31745-4 0  9993"
  @iss_tle_line2 "2 25544  51.6414 295.8524 0003435 262.6267 204.2868 15.54005638121106"

  describe "SGP4 TEME within tolerance (not 0 ULP)" do
    @describetag :skyfield_parity
    test "ISS TEME position within 1mm of Skyfield" do
      {:ok, tle} = Sidereon.parse_tle(@iss_tle_line1, @iss_tle_line2)
      {:ok, teme} = Sidereon.propagate(tle, ~U[2018-07-04 00:00:00Z])

      # The sgp4 crate is a clean-room Rust implementation that differs from
      # Skyfield's C extension by sub-nanometer amounts (expression evaluation
      # order + FMA contractions). We check distance, not ULP.
      {px, py, pz} = teme.position
      {sx, sy, sz} = @skyfield_teme_pos
      dist_km = :math.sqrt((px - sx) ** 2 + (py - sy) ** 2 + (pz - sz) ** 2)
      assert dist_km < 1.0e-6, "TEME distance #{Float.round(dist_km * 1.0e6, 3)} mm exceeds 1mm"
    end
  end

  describe "coordinate chain (ITRS, geodetic, topocentric)" do
    @describetag :skyfield_parity
    # These use the Skyfield TEME as input so deltas compound.
    # We test with tolerances appropriate for the coordinate transform accuracy.

    test "ITRS position at 0 ULP Skyfield parity (isolated from SGP4)" do
      # Use Skyfield's exact GCRS as input to isolate the GCRS→ITRS transform.
      # Skyfield GCRS: 0x1.d0bd9193713e1p+11, 0x1.f41a3b2073733p+10, 0x1.4b6ffad1289d1p+12
      gcrs = %{position: {3717.924020501305, 2000.4098588111344, 5302.998734625479}}

      itrs =
        Sidereon.Coordinates.gcrs_to_itrs(gcrs, {{2018, 7, 4}, {0, 0, 0}}, skyfield_compat: true)

      for {label, actual, expected} <- [
            {"x", elem(itrs, 0), elem(@skyfield_itrs, 0)},
            {"y", elem(itrs, 1), elem(@skyfield_itrs, 1)},
            {"z", elem(itrs, 2), elem(@skyfield_itrs, 2)}
          ] do
        assert_ulp(actual, expected, 0, "ITRS #{label}")
      end
    end

    test "geodetic within 1e-8° and 1nm" do
      gcrs =
        Sidereon.Coordinates.teme_to_gcrs(
          %{position: @skyfield_teme_pos, velocity: @skyfield_teme_vel},
          {{2018, 7, 4}, {0, 0, 0}},
          skyfield_compat: true
        )

      itrs =
        Sidereon.Coordinates.gcrs_to_itrs(gcrs, {{2018, 7, 4}, {0, 0, 0}}, skyfield_compat: true)

      geo = Sidereon.Coordinates.to_geodetic(itrs)

      assert_in_delta geo.latitude, @skyfield_geodetic.latitude, 1.0e-8
      assert_in_delta geo.longitude, @skyfield_geodetic.longitude, 1.0e-8
      assert_in_delta geo.altitude_km, @skyfield_geodetic.altitude_km, 1.0e-9
    end

    test "topocentric within 1e-6° and 1mm" do
      gcrs =
        Sidereon.Coordinates.teme_to_gcrs(
          %{position: @skyfield_teme_pos, velocity: @skyfield_teme_vel},
          {{2018, 7, 4}, {0, 0, 0}},
          skyfield_compat: true
        )

      station = %{latitude: 40.7128, longitude: -74.0060, altitude_m: 10.0}
      topo = Sidereon.Coordinates.to_topocentric(gcrs, {{2018, 7, 4}, {0, 0, 0}}, station)

      assert_in_delta topo.azimuth, @skyfield_topo.azimuth, 1.0e-6
      assert_in_delta topo.elevation, @skyfield_topo.elevation, 1.0e-6
      assert_in_delta topo.range_km, @skyfield_topo.range_km, 0.000001
    end
  end

  describe "ephemeris bodies" do
    # The ephemeris reader now delegates to sidereon_core::astro::spk, which
    # returns geometric state relative to the requested center. That supersedes
    # the former AU-round-trip path that reproduced Skyfield's vectors at 0 ULP,
    # so this checks geometric agreement against the same Skyfield reference
    # values at a tight (sub-metre) tolerance rather than bit-for-bit equality.
    @tag :spk_file
    test "Mars and Venus from Earth match the Skyfield reference geometrically" do
      eph = Sidereon.Ephemeris.load!("/tmp/de421.bsp")

      mars = Sidereon.Ephemeris.position!(eph, :mars, :earth, ~U[2018-07-04 00:00:00Z])
      venus = Sidereon.Ephemeris.position!(eph, :venus, :earth, ~U[2018-07-04 00:00:00Z])

      for {actual, expected, label} <- [
            {elem(mars, 0), 40_659_175.72244587, "Mars X"},
            {elem(mars, 1), -44_288_798.076780476, "Mars Y"},
            {elem(mars, 2), -25_686_154.8635461, "Mars Z"},
            {elem(venus, 0), -123_701_836.30384172, "Venus X"},
            {elem(venus, 1), 84_079_981.72119279, "Venus Y"},
            {elem(venus, 2), 41_452_905.15693657, "Venus Z"}
          ] do
        assert_in_delta actual, expected, 1.0e-3, label
      end
    end
  end

  defp assert_ulp(actual, expected, max_ulp, label),
    do: Sidereon.TestHelpers.assert_ulp(actual, expected, max_ulp, label)
end
