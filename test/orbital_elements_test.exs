defmodule Sidereon.OrbitalElementsTest do
  use ExUnit.Case, async: true

  alias Sidereon.OrbitalElements

  # Vallado "Fundamentals of Astrodynamics" example 2-5 Cartesian state (km, km/s).
  @r {6524.834, 6862.875, 6448.296}
  @v {4.901327, 5.533756, -1.976341}

  test "rv2coe returns classical elements for an inclined elliptical orbit" do
    assert {:ok, coe} = OrbitalElements.rv2coe(@r, @v)
    assert coe.orbit_type == :elliptical_inclined
    # Eccentricity and inclination from the Vallado worked example.
    assert_in_delta coe.ecc, 0.832853, 1.0e-5
    assert_in_delta coe.incl, 1.5336056, 1.0e-6
  end

  test "coe2rv inverts rv2coe (round-trip to the original state)" do
    assert {:ok, coe} = OrbitalElements.rv2coe(@r, @v)

    assert {:ok, %{position_km: {rx, ry, rz}, velocity_km_s: {vx, vy, vz}}} =
             OrbitalElements.coe2rv(coe)

    {ox, oy, oz} = @r
    {ovx, ovy, ovz} = @v
    assert_in_delta rx, ox, 1.0e-6
    assert_in_delta ry, oy, 1.0e-6
    assert_in_delta rz, oz, 1.0e-6
    assert_in_delta vx, ovx, 1.0e-9
    assert_in_delta vy, ovy, 1.0e-9
    assert_in_delta vz, ovz, 1.0e-9
  end

  test "rv2coe rejects a degenerate (zero-position) state" do
    assert {:error, _reason} = OrbitalElements.rv2coe({0.0, 0.0, 0.0}, @v)
  end

  test "coe2rv rejects a non-positive gravitational parameter" do
    assert {:ok, coe} = OrbitalElements.rv2coe(@r, @v)
    assert {:error, _reason} = OrbitalElements.coe2rv(coe, -1.0)
  end
end
