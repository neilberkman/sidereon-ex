defmodule Sidereon.BodiesTest do
  use ExUnit.Case, async: true

  alias Sidereon.Bodies

  # Royal Observatory, Greenwich (WGS84), altitude ~46 m.
  @greenwich {51.4769, 0.0, 0.046}
  @time ~U[2024-06-20 12:00:00Z]

  describe "sun_az_el/2" do
    test "returns a topocentric look angle with an astronomical-unit range" do
      assert {:ok, %{azimuth_deg: az, elevation_deg: el, range_km: range}} =
               Bodies.sun_az_el(@greenwich, @time)

      assert az >= 0.0 and az < 360.0
      assert el >= -90.0 and el <= 90.0
      # ~1 AU; well within a loose band around 1.5e8 km.
      assert range > 1.4e8 and range < 1.6e8
      # Near local solar noon at Greenwich the Sun is high and roughly south.
      assert el > 50.0
    end

    test "accepts a station map and a datetime tuple" do
      station = %{latitude_deg: 51.4769, longitude_deg: 0.0, altitude_km: 0.046}
      assert {:ok, _} = Bodies.sun_az_el(station, {{2024, 6, 20}, {12, 0, 0, 0}})
    end
  end

  describe "moon_az_el/2 and illumination" do
    test "returns a topocentric look angle with a lunar-distance range" do
      assert {:ok, %{azimuth_deg: az, elevation_deg: el, range_km: range}} =
               Bodies.moon_az_el(@greenwich, @time)

      assert az >= 0.0 and az < 360.0
      assert el >= -90.0 and el <= 90.0
      # Topocentric lunar distance, roughly 356,000 - 407,000 km.
      assert range > 3.4e5 and range < 4.1e5
    end

    test "moon_illumination returns a fraction in [0, 1] and a phase angle in [0, 180]" do
      assert {:ok, %{illuminated_fraction: k, phase_angle_deg: phase}} =
               Bodies.moon_illumination(@greenwich, @time)

      assert k >= 0.0 and k <= 1.0
      assert phase >= 0.0 and phase <= 180.0
    end

    test "moon_elevation_deg agrees with moon_az_el elevation" do
      assert {:ok, %{elevation_deg: el}} = Bodies.moon_az_el(@greenwich, @time)
      assert {:ok, el2} = Bodies.moon_elevation_deg(@greenwich, @time)
      assert_in_delta el, el2, 1.0e-9
    end

    test "moon_elevation_deg on an out-of-range station is a typed error, not a raise" do
      # Latitude 200 deg is finite but outside [-90, 90]; the reroute through
      # moon_az_el must surface this as a tuple instead of panicking in the NIF.
      bad_station = {200.0, 0.0, 0.046}
      assert {:error, _reason} = Bodies.moon_elevation_deg(bad_station, @time)
    end
  end

  describe "moon events over a window" do
    @start ~U[2024-06-20 00:00:00Z]
    @stop ~U[2024-06-21 00:00:00Z]

    test "find_moon_elevation_crossings returns refined rise/set events" do
      assert {:ok, crossings} =
               Bodies.find_moon_elevation_crossings(@greenwich, @start, @stop)

      assert is_list(crossings)

      for %{time: time, kind: kind, elevation_deg: el} <- crossings do
        assert %DateTime{} = time
        assert kind in [:rising, :setting]
        assert is_float(el)
      end
    end

    test "find_moon_transits returns at least one culmination per day" do
      assert {:ok, transits} = Bodies.find_moon_transits(@greenwich, @start, @stop)
      assert transits != []

      for %{time: time, kind: kind} <- transits do
        assert %DateTime{} = time
        assert kind in [:upper, :lower]
      end
    end
  end
end
