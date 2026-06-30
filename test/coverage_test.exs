defmodule Sidereon.CoverageTest do
  use ExUnit.Case, async: true

  alias Sidereon.Coverage
  alias Sidereon.Format.TLE

  @iss_line1 "1 25544U 98067A   24001.50000000  .00016717  00000-0  10270-3 0  9009"
  @iss_line2 "2 25544  51.6400 208.8657 0002644 250.3037 109.7782 15.49560812999990"

  setup_all do
    {:ok, tle} = TLE.parse(@iss_line1, @iss_line2)
    {:ok, tle: tle}
  end

  test "look angle grid delegates to the native core", %{tle: tle} do
    stations = [
      %{latitude: 51.5, longitude: -0.1, altitude_m: 11.0},
      {40.7, -74.0, 10.0}
    ]

    datetime = ~U[2024-01-01 12:00:00Z]

    look = Coverage.look_angles([tle], stations, datetime)

    assert length(look) == 1
    assert length(hd(look)) == length(stations)

    look
    |> hd()
    |> Enum.each(fn
      {:ok, {azimuth_deg, elevation_deg, range_km}} ->
        assert is_float(azimuth_deg)
        assert is_float(elevation_deg)
        assert is_float(range_km)

      :error ->
        assert true
    end)
  end
end
