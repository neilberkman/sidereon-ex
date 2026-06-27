defmodule Sidereon.CoordinatesTest do
  use ExUnit.Case

  # ISS TLE (epoch 2024-01-01 near)
  @iss_line1 "1 25544U 98067A   24001.50000000  .00016717  00000-0  10270-3 0  9009"
  @iss_line2 "2 25544  51.6400 208.8657 0002644 250.3037 109.7782 15.49560812999990"

  # Known TEME state for testing (from SidereonTest)
  @teme_state %{
    position: {3700.211211203995390, 2015.912218120605530, 5309.513078070447591},
    velocity: {-3.398428894395407, 6.869656830559572, -0.239850181126689}
  }

  @datetime {{2018, 7, 4}, {0, 0, 0}}

  describe "gcrs_to_itrs/2" do
    test "returns a position tuple" do
      gcrs = Sidereon.Coordinates.teme_to_gcrs(@teme_state, @datetime)
      itrs = Sidereon.Coordinates.gcrs_to_itrs(gcrs, @datetime)

      assert is_tuple(itrs)
      assert tuple_size(itrs) == 3

      {ix, iy, iz} = itrs
      assert is_float(ix)
      assert is_float(iy)
      assert is_float(iz)
    end

    test "preserves position magnitude (rotation only)" do
      gcrs = Sidereon.Coordinates.teme_to_gcrs(@teme_state, @datetime)
      itrs = Sidereon.Coordinates.gcrs_to_itrs(gcrs, @datetime)

      {gx, gy, gz} = gcrs.position
      gcrs_mag = :math.sqrt(gx * gx + gy * gy + gz * gz)

      {ix, iy, iz} = itrs
      itrs_mag = :math.sqrt(ix * ix + iy * iy + iz * iz)

      assert_in_delta gcrs_mag, itrs_mag, 0.001
    end

    test "accepts DateTime struct" do
      gcrs = Sidereon.Coordinates.teme_to_gcrs(@teme_state, @datetime)
      dt = ~U[2018-07-04 00:00:00Z]
      itrs = Sidereon.Coordinates.gcrs_to_itrs(gcrs, dt)

      assert is_tuple(itrs)
      assert tuple_size(itrs) == 3
    end
  end

  describe "itrs_to_gcrs/2" do
    test "inverts gcrs_to_itrs/2 for an exact record time" do
      gcrs = Sidereon.Coordinates.teme_to_gcrs(@teme_state, @datetime)
      itrs = Sidereon.Coordinates.gcrs_to_itrs(gcrs, @datetime)
      back = Sidereon.Coordinates.itrs_to_gcrs(itrs, @datetime)

      {gx, gy, gz} = gcrs.position
      {bx, by, bz} = back

      assert_in_delta bx, gx, 1.0e-9
      assert_in_delta by, gy, 1.0e-9
      assert_in_delta bz, gz, 1.0e-9
    end

    test "accepts DateTime struct" do
      dt = ~U[2018-07-04 00:00:00Z]
      gcrs = Sidereon.Coordinates.teme_to_gcrs(@teme_state, dt)
      itrs = Sidereon.Coordinates.gcrs_to_itrs(gcrs, dt)

      assert {_x, _y, _z} = Sidereon.Coordinates.itrs_to_gcrs(itrs, dt)
    end
  end

  describe "to_geodetic/1" do
    test "converts a known ECEF position to geodetic" do
      # Point on the equator at 0 longitude, on the surface
      # WGS84 a = 6378.137 km
      itrs = {6378.137, 0.0, 0.0}
      geo = Sidereon.Coordinates.to_geodetic(itrs)

      assert_in_delta geo.latitude, 0.0, 0.001
      assert_in_delta geo.longitude, 0.0, 0.001
      assert_in_delta geo.altitude_km, 0.0, 0.001
    end

    test "North Pole" do
      # North pole: x=0, y=0, z=b (semi-minor axis ~6356.752 km)
      itrs = {0.0, 0.0, 6356.752314245179}
      geo = Sidereon.Coordinates.to_geodetic(itrs)

      assert_in_delta geo.latitude, 90.0, 0.001
      assert_in_delta geo.altitude_km, 0.0, 0.01
    end

    test "satellite altitude is reasonable for LEO" do
      gcrs = Sidereon.Coordinates.teme_to_gcrs(@teme_state, @datetime)
      itrs = Sidereon.Coordinates.gcrs_to_itrs(gcrs, @datetime)
      geo = Sidereon.Coordinates.to_geodetic(itrs)

      # LEO satellite should be at roughly 200-2000 km altitude
      assert geo.altitude_km > 100
      assert geo.altitude_km < 2000

      # Latitude should be within inclination bounds (ISS ~51.6 deg)
      assert geo.latitude > -60
      assert geo.latitude < 60
    end
  end

  describe "geodetic_to_itrs/1" do
    test "inverts to_geodetic/1 for a propagated ITRS position" do
      gcrs = Sidereon.Coordinates.teme_to_gcrs(@teme_state, @datetime)
      itrs = Sidereon.Coordinates.gcrs_to_itrs(gcrs, @datetime)
      geodetic = Sidereon.Coordinates.to_geodetic(itrs)
      back = Sidereon.Coordinates.geodetic_to_itrs(geodetic)

      {ix, iy, iz} = itrs
      {bx, by, bz} = back

      assert_in_delta bx, ix, 1.0e-6
      assert_in_delta by, iy, 1.0e-6
      assert_in_delta bz, iz, 1.0e-6
    end

    test "accepts tuple and map inputs" do
      from_tuple = Sidereon.Coordinates.geodetic_to_itrs({51.5, -0.1, 0.011})

      from_map =
        Sidereon.Coordinates.geodetic_to_itrs(%{
          latitude: 51.5,
          longitude: -0.1,
          altitude_km: 0.011
        })

      assert from_tuple == from_map
    end
  end

  describe "to_topocentric/3" do
    test "computes az/el/range from a ground station" do
      gcrs = Sidereon.Coordinates.teme_to_gcrs(@teme_state, @datetime)

      station = %{latitude: 40.0, longitude: -74.0, altitude_m: 0.0}
      result = Sidereon.Coordinates.to_topocentric(gcrs, @datetime, station)

      assert is_float(result.azimuth)
      assert is_float(result.elevation)
      assert is_float(result.range_km)

      # Azimuth should be 0-360
      assert result.azimuth >= 0.0
      assert result.azimuth < 360.0

      # Elevation should be -90 to 90
      assert result.elevation >= -90.0
      assert result.elevation <= 90.0

      # Range should be positive and reasonable for LEO
      assert result.range_km > 0
      assert result.range_km < 20_000
    end

    test "satellite directly overhead has elevation near 90" do
      # Get the sub-satellite point and use that as the station
      gcrs = Sidereon.Coordinates.teme_to_gcrs(@teme_state, @datetime)
      itrs = Sidereon.Coordinates.gcrs_to_itrs(gcrs, @datetime)
      geo = Sidereon.Coordinates.to_geodetic(itrs)

      station = %{latitude: geo.latitude, longitude: geo.longitude, altitude_m: 0.0}
      result = Sidereon.Coordinates.to_topocentric(gcrs, @datetime, station)

      # Should be very close to 90 degrees elevation
      assert_in_delta result.elevation, 90.0, 1.0

      # Range should be approximately the altitude
      assert_in_delta result.range_km, geo.altitude_km, 5.0
    end
  end

  describe "Sidereon.geodetic/2 (high-level)" do
    test "returns geodetic coordinates from a TLE" do
      {:ok, tle} = Sidereon.parse_tle(@iss_line1, @iss_line2)
      dt = ~U[2024-01-01 12:00:00Z]

      {:ok, geo} = Sidereon.geodetic(tle, dt)

      assert is_float(geo.latitude)
      assert is_float(geo.longitude)
      assert is_float(geo.altitude_km)

      # ISS altitude is roughly 400 km
      assert geo.altitude_km > 300
      assert geo.altitude_km < 500

      # ISS inclination is 51.6 deg, so latitude should be bounded
      assert geo.latitude > -55
      assert geo.latitude < 55
    end
  end

  describe "Sidereon.look_angle/3 (high-level)" do
    test "returns look angle from a ground station to a satellite" do
      {:ok, tle} = Sidereon.parse_tle(@iss_line1, @iss_line2)
      dt = ~U[2024-01-01 12:00:00Z]

      station = %{latitude: 51.5, longitude: -0.1, altitude_m: 11.0}
      {:ok, look} = Sidereon.look_angle(tle, dt, station)

      assert is_float(look.azimuth)
      assert is_float(look.elevation)
      assert is_float(look.range_km)

      assert look.azimuth >= 0.0
      assert look.azimuth < 360.0
      assert look.range_km > 0
    end
  end
end
