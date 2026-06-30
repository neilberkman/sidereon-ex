defmodule Sidereon.ObservationTest do
  use ExUnit.Case, async: true

  alias Sidereon.Observation

  @au_km 149_597_870.7

  test "sub_solar_point reads the solar declination and meridian" do
    delta = 23.44 * :math.pi() / 180.0
    sun = {@au_km * :math.cos(delta), 0.0, @au_km * :math.sin(delta)}
    assert {:ok, %{latitude_deg: lat, longitude_deg: lon}} = Observation.sub_solar_point(sun)
    assert_in_delta lat, 23.44, 1.0e-9
    assert_in_delta lon, 0.0, 1.0e-9
  end

  test "sub_solar_point rejects a zero vector" do
    assert {:error, _reason} = Observation.sub_solar_point({0.0, 0.0, 0.0})
  end

  test "terminator_latitude_deg matches the polar circle at solstice" do
    sub_solar = %{latitude_deg: 23.44, longitude_deg: 0.0}
    assert {:ok, noon} = Observation.terminator_latitude_deg(sub_solar, 0.0)
    assert_in_delta noon, -66.56, 1.0e-9
    assert {:ok, quad} = Observation.terminator_latitude_deg(sub_solar, 90.0)
    assert_in_delta quad, 0.0, 1.0e-9
  end

  test "parallactic_angle_deg is zero on the meridian and a known value off it" do
    assert {:ok, on_meridian} = Observation.parallactic_angle_deg(45.0, 0.0, 10.0)
    assert_in_delta on_meridian, 0.0, 1.0e-12
    assert {:ok, q} = Observation.parallactic_angle_deg(45.0, 45.0, 0.0)
    assert_in_delta q, 35.264389682754654, 1.0e-9
  end

  test "satellite_visual_magnitude tracks the distance term" do
    assert {:ok, base} = Observation.satellite_visual_magnitude(1000.0, 0.0, 0.0, 1000.0)
    assert_in_delta base, 0.0, 1.0e-12
    assert {:ok, farther} = Observation.satellite_visual_magnitude(2000.0, 0.0, 0.0, 1000.0)
    assert_in_delta farther, 1.505149978319906, 1.0e-9
  end

  test "satellite_visual_magnitude rejects a non-positive range" do
    assert {:error, _reason} = Observation.satellite_visual_magnitude(0.0, 0.0, 0.0, 1000.0)
  end

  test "sub_observer_point reads the IAU Mars central meridian" do
    assert {:ok, %{latitude_deg: lat, longitude_deg: lon}} =
             Observation.sub_observer_point({1.0, 0.0, 0.0}, 317.68, 52.89, 176.0)

    assert_in_delta lat, 26.494542592970532, 1.0e-9
    assert_in_delta lon, 142.78801976413246, 1.0e-9
  end

  test "sub_observer_point rejects a zero vector" do
    assert {:error, _reason} = Observation.sub_observer_point({0.0, 0.0, 0.0}, 0.0, 90.0, 0.0)
  end
end
