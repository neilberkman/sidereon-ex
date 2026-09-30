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

  test "detailed cells retain indexed invalid station diagnostics", %{tle: tle} do
    stations = [{51.5, -0.1, 11.0}, {91.0, 0.0, 0.0}]
    datetime = ~U[2024-01-01 12:00:00Z]

    rows = Coverage.look_angles_detailed([tle], stations, datetime)
    assert length(rows) == 1
    assert length(hd(rows)) == 2
    assert {:error, {:invalid_input, "ground_station.latitude_deg", "out of range"}} = Enum.at(hd(rows), 1)
  end

  test "detailed cells retain the strict UT1 refusal", %{tle: tle} do
    rows = Coverage.look_angles_detailed([tle], [{51.5, -0.1, 11.0}], ~U[1900-01-01 00:00:00Z])
    assert [[{:error, {:frame_transform, {:ut1_outside_coverage, :before_coverage}}}]] = rows
  end

  test "invalid satellite initialization preserves detailed row and refuses legacy grid", %{tle: tle} do
    invalid = %{tle | epoch_jd: %{jd_whole: 1.0e99, jd_fraction: 0.0}}
    stations = [{51.5, -0.1, 11.0}, {40.7, -74.0, 10.0}]
    datetime = ~U[2024-01-01 12:00:00Z]

    rows = Coverage.look_angles_detailed([tle, invalid], stations, datetime)
    assert length(rows) == 2
    assert length(Enum.at(rows, 1)) == length(stations)

    assert Enum.all?(Enum.at(rows, 1), fn
             {:error, {:init, {:invalid_input, :"element.epoch", :out_of_range}}} -> true
             _ -> false
           end)

    error = assert_raise ErlangError, fn -> Coverage.look_angles([tle, invalid], stations, datetime) end
    assert error.original == {:invalid_input, :"element.epoch", :out_of_range}
  end

  test "failed initialization with no stations remains observable", %{tle: tle} do
    invalid = %{tle | epoch_jd: %{jd_whole: 1.0e99, jd_fraction: 0.0}}

    error =
      assert_raise ErlangError, fn ->
        Coverage.look_angles_detailed([tle, invalid], [], ~U[2024-01-01 12:00:00Z])
      end

    assert error.original == {:satellite_initialization, 1, {:invalid_input, :"element.epoch", :out_of_range}}
  end
end
