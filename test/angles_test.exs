defmodule Sidereon.AnglesTest do
  use ExUnit.Case

  describe "sun_angle/2" do
    test "satellite on the sunlit side has sun angle > 90 degrees (Sun opposite nadir)" do
      # Satellite at 400 km altitude on the +x axis
      sat_pos = {6778.0, 0.0, 0.0}
      # Sun roughly in the +x direction (same side as satellite, behind it)
      # Nadir is -x, Sun direction from sat is +x => angle ~180
      sun_pos = {149_597_870.0, 0.0, 0.0}

      angle = Sidereon.Angles.sun_angle(sat_pos, sun_pos)
      assert angle > 90.0
    end

    test "satellite in shadow has sun angle < 90 degrees (Sun toward nadir)" do
      # Satellite at 400 km altitude on the +x axis
      # Sun on the opposite side of Earth (-x direction)
      # Nadir is -x, Sun direction from sat is also -x => angle ~0
      sat_pos = {6778.0, 0.0, 0.0}
      sun_pos = {-149_597_870.0, 0.0, 0.0}

      angle = Sidereon.Angles.sun_angle(sat_pos, sun_pos)
      assert angle < 90.0
    end

    test "sun directly at nadir direction gives angle near 0" do
      # Satellite on +x axis, Sun also on +x but closer to Earth
      # Nadir is toward Earth center (-x from satellite), Sun is past Earth in -x
      sat_pos = {6778.0, 0.0, 0.0}
      # Sun behind Earth (nadir direction from satellite perspective)
      sun_pos = {-149_597_870.0, 0.0, 0.0}

      angle = Sidereon.Angles.sun_angle(sat_pos, sun_pos)
      # Sun is roughly in the nadir direction, so angle should be near 0
      assert_in_delta angle, 0.0, 1.0
    end

    test "sun directly opposite nadir gives angle near 180" do
      # Satellite on +x axis, Sun also on +x far away (zenith direction)
      sat_pos = {6778.0, 0.0, 0.0}
      sun_pos = {149_597_870.0, 0.0, 0.0}

      angle = Sidereon.Angles.sun_angle(sat_pos, sun_pos)
      # Sun is roughly in the zenith direction (opposite nadir), so angle ~ 180
      assert_in_delta angle, 180.0, 1.0
    end
  end

  describe "moon_angle/2" do
    test "moon angle is between 0 and 180 degrees" do
      sat_pos = {6778.0, 0.0, 0.0}
      # Moon at roughly 384,400 km in a different direction
      moon_pos = {200_000.0, 300_000.0, 50_000.0}

      angle = Sidereon.Angles.moon_angle(sat_pos, moon_pos)
      assert angle >= 0.0
      assert angle <= 180.0
    end

    test "moon along nadir gives angle near 0" do
      sat_pos = {6778.0, 0.0, 0.0}
      # Moon behind Earth (in -x direction = nadir direction from satellite)
      moon_pos = {-384_400.0, 0.0, 0.0}

      angle = Sidereon.Angles.moon_angle(sat_pos, moon_pos)
      assert_in_delta angle, 0.0, 1.0
    end
  end

  describe "sun_elevation/2" do
    test "sun above local horizontal gives positive elevation" do
      # Satellite on +x axis
      sat_pos = {6778.0, 0.0, 0.0}
      # Sun in the zenith direction (away from Earth) = positive elevation
      sun_pos = {149_597_870.0, 0.0, 0.0}

      elevation = Sidereon.Angles.sun_elevation(sat_pos, sun_pos)
      assert elevation > 0.0
    end

    test "sun below local horizontal gives negative elevation" do
      # Satellite on +x axis
      sat_pos = {6778.0, 0.0, 0.0}
      # Sun behind Earth (-x direction) = below horizontal from satellite
      sun_pos = {-149_597_870.0, 0.0, 0.0}

      elevation = Sidereon.Angles.sun_elevation(sat_pos, sun_pos)
      assert elevation < 0.0
    end

    test "sun perpendicular to radial gives elevation near 0" do
      # Satellite on +x axis
      sat_pos = {6778.0, 0.0, 0.0}
      # Sun perpendicular in +y direction
      sun_pos = {0.0, 149_597_870.0, 0.0}

      elevation = Sidereon.Angles.sun_elevation(sat_pos, sun_pos)
      # The Sun direction from satellite is nearly pure +y, which is
      # perpendicular to the radial (+x) direction, so elevation ~ 0
      assert_in_delta elevation, 0.0, 1.0
    end
  end

  describe "phase_angle/3" do
    test "phase angle is between 0 and 180 degrees" do
      sat_pos = {6778.0, 0.0, 0.0}
      sun_pos = {149_597_870.0, 1_000_000.0, 0.0}
      observer_pos = {0.0, 6378.0, 0.0}

      angle = Sidereon.Angles.phase_angle(sat_pos, sun_pos, observer_pos)
      assert angle >= 0.0
      assert angle <= 180.0
    end

    test "observer and sun on same side gives small phase angle" do
      # Satellite on +x axis
      sat_pos = {6778.0, 0.0, 0.0}
      # Sun far in the -x direction (toward Earth from satellite perspective)
      sun_pos = {-149_597_870.0, 0.0, 0.0}
      # Observer on Earth surface at origin-ish (also in -x direction from satellite)
      observer_pos = {-6378.0, 0.0, 0.0}

      angle = Sidereon.Angles.phase_angle(sat_pos, sun_pos, observer_pos)
      # Both Sun and observer are roughly in the -x direction from the satellite
      assert angle < 10.0
    end
  end

  describe "earth_angular_radius/1" do
    test "from ISS altitude (~400 km) should be about 70 degrees" do
      # ISS at ~400 km altitude => distance from center ~ 6778 km
      sat_pos = {6778.0, 0.0, 0.0}

      angle = Sidereon.Angles.earth_angular_radius(sat_pos)
      # asin(6378.137 / 6778) ≈ 70.2 degrees
      assert_in_delta angle, 70.2, 1.0
    end

    test "from GEO altitude (~35786 km) should be about 8.7 degrees" do
      # GEO satellite at ~42164 km from Earth center
      sat_pos = {42_164.0, 0.0, 0.0}

      angle = Sidereon.Angles.earth_angular_radius(sat_pos)
      # asin(6378.137 / 42164) ≈ 8.7 degrees
      assert_in_delta angle, 8.7, 0.5
    end

    test "angular radius decreases with altitude" do
      iss_pos = {6778.0, 0.0, 0.0}
      geo_pos = {42_164.0, 0.0, 0.0}

      iss_angle = Sidereon.Angles.earth_angular_radius(iss_pos)
      geo_angle = Sidereon.Angles.earth_angular_radius(geo_pos)

      assert iss_angle > geo_angle
    end
  end

  describe "delegates in Sidereon module" do
    test "Sidereon.sun_angle/2 delegates correctly" do
      sat_pos = {6778.0, 0.0, 0.0}
      sun_pos = {149_597_870.0, 0.0, 0.0}

      assert Sidereon.sun_angle(sat_pos, sun_pos) ==
               Sidereon.Angles.sun_angle(sat_pos, sun_pos)
    end

    test "Sidereon.moon_angle/2 delegates correctly" do
      sat_pos = {6778.0, 0.0, 0.0}
      moon_pos = {200_000.0, 300_000.0, 50_000.0}

      assert Sidereon.moon_angle(sat_pos, moon_pos) ==
               Sidereon.Angles.moon_angle(sat_pos, moon_pos)
    end
  end
end
