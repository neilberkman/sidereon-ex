defmodule Sidereon.GNSS.TroposphereTest do
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.Troposphere

  # Standard sea-level surface meteorology used by the troposphere reference
  # fixtures: 1013.25 hPa, 288.15 K, 50% relative humidity.
  @met %{pressure_hpa: 1013.25, temperature_k: 288.15, relative_humidity: 0.5}

  # Day-of-year 28.0 (the fixtures' seasonal argument) is Jan 28 00:00:00 of a
  # non-leap year.
  @epoch {{2021, 1, 28}, {0, 0, 0}}

  describe "zenith_delay/3" do
    test "matches the reference fixture sea-level zenith delays bit-for-bit (0 ULP)" do
      assert {:ok, %{dry_m: dry_m, wet_m: wet_m}} =
               Troposphere.zenith_delay(45.0, 0.0, @met)

      assert dry_m == 2.3069675999999997
      assert wet_m == 0.08601004964012601
    end
  end

  describe "mapping/4" do
    test "is unity at the zenith" do
      assert {:ok, %{dry: dry, wet: wet}} =
               Troposphere.mapping(90.0, 45.0, 0.0, @epoch)

      assert dry == 1.0
      assert wet == 1.0
    end

    test "grows toward lower elevation" do
      {:ok, %{dry: dry90}} = Troposphere.mapping(90.0, 45.0, 0.0, @epoch)
      {:ok, %{dry: dry30}} = Troposphere.mapping(30.0, 45.0, 0.0, @epoch)
      {:ok, %{dry: dry10}} = Troposphere.mapping(10.0, 45.0, 0.0, @epoch)

      assert dry30 > dry90
      assert dry10 > dry30
    end
  end

  describe "slant_delay/6" do
    test "at the zenith equals the reference fixture slant value bit-for-bit (0 ULP)" do
      # Niell mapping is unity at 90 deg, so the slant delay is the sum of the
      # zenith delays; this is the 'zenith_midlat' troposphere reference fixture.
      assert {:ok, slant_m} =
               Troposphere.slant_delay(90.0, 45.0, 10.0, 0.0, @met, @epoch)

      assert slant_m == 2.392977649640126
    end

    test "is zero at and below the horizon" do
      assert {:ok, horizon} = Troposphere.slant_delay(0.0, 45.0, 10.0, 0.0, @met, @epoch)
      assert horizon == 0.0
      assert {:ok, below} = Troposphere.slant_delay(-5.0, 45.0, 10.0, 0.0, @met, @epoch)
      assert below == 0.0
    end

    test "grows as elevation drops" do
      {:ok, s90} = Troposphere.slant_delay(90.0, 45.0, 10.0, 0.0, @met, @epoch)
      {:ok, s30} = Troposphere.slant_delay(30.0, 45.0, 10.0, 0.0, @met, @epoch)
      {:ok, s10} = Troposphere.slant_delay(10.0, 45.0, 10.0, 0.0, @met, @epoch)

      assert s30 > s90
      assert s10 > s30
    end

    test "rejects malformed meteorology" do
      assert {:error, :bad_meteorology} =
               Troposphere.slant_delay(30.0, 45.0, 10.0, 0.0, %{pressure_hpa: 1000.0}, @epoch)
    end
  end
end
