defmodule Sidereon.DopplerTest do
  use ExUnit.Case

  # ISS TLE (epoch 2024-01-01 near)
  @iss_line1 "1 25544U 98067A   24001.50000000  .00016717  00000-0  10270-3 0  9009"
  @iss_line2 "2 25544  51.6400 208.8657 0002644 250.3037 109.7782 15.49560812999990"

  @freq_437mhz 437.0e6

  # Known TEME state for testing
  @teme_state %{
    position: {3700.211211203995390, 2015.912218120605530, 5309.513078070447591},
    velocity: {-3.398428894395407, 6.869656830559572, -0.239850181126689}
  }

  @datetime {{2018, 7, 4}, {0, 0, 0}}

  describe "Sidereon.Doppler.shift/4" do
    test "returns expected keys" do
      gcrs = Sidereon.Coordinates.teme_to_gcrs(@teme_state, @datetime)
      station = %{latitude: 40.0, longitude: -74.0, altitude_m: 0.0}

      result = Sidereon.Doppler.shift(gcrs, @datetime, station, @freq_437mhz)

      assert is_float(result.range_rate_km_s)
      assert is_float(result.doppler_hz)
      assert is_float(result.doppler_ratio)
    end

    test "ISS range rate is within physical bounds (max ~7 km/s)" do
      gcrs = Sidereon.Coordinates.teme_to_gcrs(@teme_state, @datetime)
      station = %{latitude: 40.0, longitude: -74.0, altitude_m: 0.0}

      result = Sidereon.Doppler.shift(gcrs, @datetime, station, @freq_437mhz)

      assert abs(result.range_rate_km_s) <= 8.0
    end

    test "Doppler shift at 437 MHz is within expected range (~10 kHz)" do
      gcrs = Sidereon.Coordinates.teme_to_gcrs(@teme_state, @datetime)
      station = %{latitude: 40.0, longitude: -74.0, altitude_m: 0.0}

      result = Sidereon.Doppler.shift(gcrs, @datetime, station, @freq_437mhz)

      # For LEO, Doppler shift at 437 MHz is typically <=~10 kHz
      assert abs(result.doppler_hz) <= 12_000.0
    end

    test "satellite approaching gives positive Doppler" do
      # Use the ISS TLE and propagate to a known time. Place two stations
      # on either side of the sub-satellite point along latitude. The station
      # that the satellite is approaching should show positive doppler_hz
      # (negative range_rate), the other should show the opposite.
      {:ok, tle} = Sidereon.parse_tle(@iss_line1, @iss_line2)
      dt = ~U[2024-01-01 12:00:00Z]
      {:ok, teme} = Sidereon.SGP4.propagate(tle, dt)
      gcrs = Sidereon.Coordinates.teme_to_gcrs(teme, dt)
      itrs = Sidereon.Coordinates.gcrs_to_itrs(gcrs, dt)
      geo = Sidereon.Coordinates.to_geodetic(itrs)

      # Check Doppler to stations on either side
      station_north = %{latitude: geo.latitude + 20.0, longitude: geo.longitude, altitude_m: 0.0}
      station_south = %{latitude: geo.latitude - 20.0, longitude: geo.longitude, altitude_m: 0.0}

      result_north = Sidereon.Doppler.shift(gcrs, dt, station_north, @freq_437mhz)
      result_south = Sidereon.Doppler.shift(gcrs, dt, station_south, @freq_437mhz)

      # One station should show approaching (positive Doppler), the other receding
      # We just verify their signs are opposite
      assert result_north.doppler_hz * result_south.doppler_hz < 0,
             "Expected opposite Doppler signs: north=#{result_north.doppler_hz}, south=#{result_south.doppler_hz}"

      # The approaching station should have positive Doppler (negative range_rate)
      approaching = if result_north.doppler_hz > 0, do: result_north, else: result_south
      receding = if result_north.doppler_hz > 0, do: result_south, else: result_north

      assert approaching.range_rate_km_s < 0
      assert approaching.doppler_hz > 0

      assert receding.range_rate_km_s > 0
      assert receding.doppler_hz < 0
    end

    test "satellite receding gives negative Doppler" do
      # Construct a scenario where the satellite is clearly receding:
      # place the station behind the satellite's velocity direction.
      # Use ISS and place station far behind (opposite to velocity direction).
      {:ok, tle} = Sidereon.parse_tle(@iss_line1, @iss_line2)
      dt = ~U[2024-01-01 12:00:00Z]
      {:ok, teme} = Sidereon.SGP4.propagate(tle, dt)
      gcrs = Sidereon.Coordinates.teme_to_gcrs(teme, dt)
      itrs = Sidereon.Coordinates.gcrs_to_itrs(gcrs, dt)
      geo = Sidereon.Coordinates.to_geodetic(itrs)

      # Place two stations on opposite sides along longitude (E/W)
      station_east = %{latitude: geo.latitude, longitude: geo.longitude + 20.0, altitude_m: 0.0}
      station_west = %{latitude: geo.latitude, longitude: geo.longitude - 20.0, altitude_m: 0.0}

      result_east = Sidereon.Doppler.shift(gcrs, dt, station_east, @freq_437mhz)
      result_west = Sidereon.Doppler.shift(gcrs, dt, station_west, @freq_437mhz)

      # They should have different Doppler signs or magnitudes
      # (the satellite moves predominantly in one direction)
      receding =
        if result_east.range_rate_km_s > result_west.range_rate_km_s,
          do: result_east,
          else: result_west

      # The receding station should have positive range_rate and negative Doppler
      assert receding.range_rate_km_s > 0
      assert receding.doppler_hz < 0
    end

    test "accepts DateTime struct" do
      gcrs = Sidereon.Coordinates.teme_to_gcrs(@teme_state, @datetime)
      dt = ~U[2018-07-04 00:00:00Z]
      station = %{latitude: 40.0, longitude: -74.0, altitude_m: 0.0}

      result = Sidereon.Doppler.shift(gcrs, dt, station, @freq_437mhz)

      assert is_float(result.range_rate_km_s)
      assert is_float(result.doppler_hz)
      assert is_float(result.doppler_ratio)
    end
  end

  describe "Sidereon.doppler/4 (high-level)" do
    test "returns Doppler shift from a TLE" do
      {:ok, tle} = Sidereon.parse_tle(@iss_line1, @iss_line2)
      dt = ~U[2024-01-01 12:00:00Z]
      station = %{latitude: 51.5, longitude: -0.1, altitude_m: 11.0}

      {:ok, result} = Sidereon.doppler(tle, dt, station, @freq_437mhz)

      assert is_float(result.range_rate_km_s)
      assert is_float(result.doppler_hz)
      assert is_float(result.doppler_ratio)

      # Range rate should be physically reasonable
      assert abs(result.range_rate_km_s) <= 8.0

      # Doppler at 437 MHz should be within ~10 kHz
      assert abs(result.doppler_hz) <= 12_000.0
    end
  end
end
