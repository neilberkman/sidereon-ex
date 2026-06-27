defmodule Sidereon.RFTest do
  use ExUnit.Case

  describe "fspl/2" do
    test "LEO satellite at 1200 km, L-band" do
      # Globalstar-like: 1616 MHz, ~1200 km slant range
      # Verified: 32.45 + 20*log10(1616) + 20*log10(1200) = 158.20
      fspl = Sidereon.RF.fspl(1200.0, 1616.0)
      assert_in_delta fspl, 158.20, 0.01
    end

    test "GEO satellite at 36000 km, Ku-band" do
      # Typical GEO downlink: 12 GHz, ~36000 km
      fspl = Sidereon.RF.fspl(36000.0, 12000.0)
      assert_in_delta fspl, 205.16, 0.01
    end

    test "scales with distance squared" do
      # Doubling distance adds 6 dB
      fspl1 = Sidereon.RF.fspl(1000.0, 1000.0)
      fspl2 = Sidereon.RF.fspl(2000.0, 1000.0)
      assert_in_delta fspl2 - fspl1, 6.02, 0.01
    end

    test "scales with frequency squared" do
      # Doubling frequency adds 6 dB
      fspl1 = Sidereon.RF.fspl(1000.0, 1000.0)
      fspl2 = Sidereon.RF.fspl(1000.0, 2000.0)
      assert_in_delta fspl2 - fspl1, 6.02, 0.01
    end
  end

  describe "eirp/2" do
    test "typical IoT tracker" do
      # 27 dBm tx power, 3 dBi antenna = 0 dBW EIRP
      assert Sidereon.RF.eirp(27.0, 3.0) == 0.0
    end

    test "1W into 0 dBi antenna" do
      # 30 dBm + 0 dBi - 30 = 0 dBW
      assert Sidereon.RF.eirp(30.0, 0.0) == 0.0
    end
  end

  describe "link_margin/1" do
    test "positive margin means link closes" do
      margin =
        Sidereon.RF.link_margin(%{
          eirp_dbw: 0.0,
          fspl_db: 165.0,
          receiver_gt_dbk: -12.0,
          other_losses_db: 3.0,
          required_cn0_dbhz: 35.0
        })

      assert margin > 0
    end

    test "increasing distance reduces margin" do
      base = %{
        eirp_dbw: 0.0,
        receiver_gt_dbk: -12.0,
        other_losses_db: 3.0,
        required_cn0_dbhz: 35.0
      }

      margin_close =
        Sidereon.RF.link_margin(Map.put(base, :fspl_db, Sidereon.RF.fspl(800.0, 1616.0)))

      margin_far =
        Sidereon.RF.link_margin(Map.put(base, :fspl_db, Sidereon.RF.fspl(2000.0, 1616.0)))

      assert margin_close > margin_far
    end
  end

  describe "integration: geometry + RF" do
    test "ISS link budget from ground station" do
      # Parse ISS TLE from fixture
      body = File.read!(Path.join(__DIR__, "fixtures/celestrak/iss.tle"))
      lines = body |> String.trim() |> String.split("\n") |> Enum.map(&String.trim/1)
      l1 = Enum.find(lines, &String.starts_with?(&1, "1 "))
      l2 = Enum.find(lines, &String.starts_with?(&1, "2 "))
      {:ok, elements} = Sidereon.Format.TLE.parse(l1, l2)

      # Propagate to epoch
      {:ok, teme} = Sidereon.propagate(elements, elements.epoch)

      # Get look angles from NYC
      station = %{latitude: 40.7128, longitude: -74.006, altitude_m: 10.0}
      gcrs = Sidereon.Coordinates.teme_to_gcrs(teme, elements.epoch)
      look = Sidereon.Coordinates.to_topocentric(gcrs, elements.epoch, station)

      # Compute FSPL at UHF (437 MHz, typical amateur sat)
      fspl = Sidereon.RF.fspl(look.range_km, 437.0)

      # FSPL should be in reasonable range for LEO
      assert fspl > 140.0 and fspl < 175.0
    end
  end
end
