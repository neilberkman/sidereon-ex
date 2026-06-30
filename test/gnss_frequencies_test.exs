defmodule Sidereon.GNSS.FrequenciesTest do
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.Frequencies
  alias Sidereon.GNSS.RINEX.Observations

  @c 299_792_458.0

  @fixed_frequencies [
    {"G", :l1, 1_575_420_000.0},
    {"G", :l2, 1_227_600_000.0},
    {"G", :l5, 1_176_450_000.0},
    {"E", :e1, 1_575_420_000.0},
    {"E", :e5a, 1_176_450_000.0},
    {"E", :e6, 1_278_750_000.0},
    {"E", :e5b, 1_207_140_000.0},
    {"E", :e5, 1_191_795_000.0},
    {"C", :b1c, 1_575_420_000.0},
    {"C", :b1i, 1_561_098_000.0},
    {"C", :b2a, 1_176_450_000.0},
    {"C", :b3i, 1_268_520_000.0},
    {"C", :b2b, 1_207_140_000.0},
    {"C", :b2, 1_191_795_000.0}
  ]

  describe "fixed carrier frequencies" do
    test "carrier_frequency_hz/2 exposes the core fixed-frequency table" do
      for {system, band, expected_hz} <- @fixed_frequencies do
        assert {:ok, ^expected_hz} = Frequencies.carrier_frequency_hz(system, band)
      end
    end

    test "wavelength_m/2 uses the speed of light over carrier frequency" do
      for {system, band, frequency_hz} <- @fixed_frequencies do
        assert {:ok, wavelength_m} = Frequencies.wavelength_m(system, band)
        assert wavelength_m == @c / frequency_hz
      end
    end

    test "unknown fixed carrier combinations are tagged errors" do
      assert {:error, {:unknown_band, "G", :e1}} =
               Frequencies.carrier_frequency_hz("G", :e1)

      assert {:error, {:unknown_band, "R", :g1}} =
               Frequencies.carrier_frequency_hz("R", :g1)

      assert {:error, {:unknown_system, "X"}} =
               Frequencies.carrier_frequency_hz("X", :l1)
    end
  end

  describe "default pairs" do
    test "default_pair/1 matches the Python/core ionosphere-free defaults" do
      assert {:ok, {:l1, :l2}} = Frequencies.default_pair("G")
      assert {:ok, {:e1, :e5a}} = Frequencies.default_pair("E")
      assert {:ok, {:b1i, :b3i}} = Frequencies.default_pair("C")
      assert {:error, {:no_default_pair, "R"}} = Frequencies.default_pair("R")
      assert {:error, {:unknown_system, "X"}} = Frequencies.default_pair("X")
    end
  end

  describe "RINEX observation bands" do
    test "rinex_band_frequency_hz/3 matches the existing observation-band lookup" do
      cases = [
        {"G", "1", nil},
        {"G", "2", nil},
        {"G", "5", nil},
        {"E", "5", nil},
        {"E", "6", nil},
        {"E", "7", nil},
        {"E", "8", nil},
        {"C", "1", nil},
        {"C", "2", nil},
        {"C", "6", nil},
        {"C", "7", nil},
        {"C", "8", nil},
        {"R", "1", 1},
        {"R", "2", 1}
      ]

      for {system, band, channel} <- cases do
        expected = Observations.band_frequency_hz(system, band, channel)
        assert {:ok, ^expected} = Frequencies.rinex_band_frequency_hz(system, band, channel)
      end
    end

    test "rinex_band_wavelength_m/3 covers GLONASS FDMA channels" do
      assert {:ok, wavelength_m} = Frequencies.rinex_band_wavelength_m("R", "1", -7)
      assert wavelength_m == @c / (1_602_000_000.0 - 7.0 * 562_500.0)
    end

    test "RINEX band errors are tagged" do
      assert {:error, {:missing_glonass_channel, "R", "1"}} =
               Frequencies.rinex_band_frequency_hz("R", "1", nil)

      assert {:error, {:unknown_band, "G", "12"}} =
               Frequencies.rinex_band_frequency_hz("G", "12", nil)

      assert {:error, {:unknown_band, "G", "9"}} =
               Frequencies.rinex_band_wavelength_m("G", "9", nil)

      assert {:error, {:invalid_channel, 200}} =
               Frequencies.rinex_band_frequency_hz("R", "1", 200)
    end
  end
end
