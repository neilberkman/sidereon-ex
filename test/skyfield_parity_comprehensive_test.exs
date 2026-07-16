defmodule Sidereon.SkyfieldParityComprehensiveTest do
  @moduledoc """
  Independent Skyfield 1.49 references for the public coordinate chain.

  Exact frame transforms are covered in `Sidereon.SkyfieldParityTest`; these
  checks preserve the historical geodetic and topocentric oracle coverage.
  """
  use ExUnit.Case

  @moduletag :skyfield_parity

  @teme_position {3700.2112112039954, 2015.9122181206055, 5309.513078070448}
  @teme_velocity {-3.398428894395407, 6.869656830559572, -0.239850181126689}
  @epoch {{2018, 7, 4}, {0, 0, 0}}
  @geodetic %{
    latitude: 51.739711343471704,
    longitude: 106.623334208117,
    altitude_km: 413.384228395398
  }
  @topocentric %{
    azimuth: 359.609693032262,
    elevation: -41.916558921757,
    range_km: 9130.479407113899
  }

  test "coordinate chain matches the Skyfield geodetic reference" do
    gcrs = skyfield_gcrs()
    itrs = Sidereon.Coordinates.gcrs_to_itrs(gcrs, @epoch, skyfield_compat: true)
    geodetic = Sidereon.Coordinates.to_geodetic(itrs)

    assert_in_delta geodetic.latitude, @geodetic.latitude, 1.0e-8
    assert_in_delta geodetic.longitude, @geodetic.longitude, 1.0e-8
    assert_in_delta geodetic.altitude_km, @geodetic.altitude_km, 1.0e-9
  end

  test "coordinate chain matches the Skyfield topocentric reference" do
    station = %{latitude: 40.7128, longitude: -74.0060, altitude_m: 10.0}

    topocentric =
      Sidereon.Coordinates.to_topocentric(
        skyfield_gcrs(),
        @epoch,
        station,
        skyfield_compat: true
      )

    assert_in_delta topocentric.azimuth, @topocentric.azimuth, 1.0e-6
    assert_in_delta topocentric.elevation, @topocentric.elevation, 1.0e-6
    assert_in_delta topocentric.range_km, @topocentric.range_km, 1.0e-6
  end

  defp skyfield_gcrs do
    Sidereon.Coordinates.teme_to_gcrs(
      %{position: @teme_position, velocity: @teme_velocity},
      @epoch,
      skyfield_compat: true
    )
  end
end
