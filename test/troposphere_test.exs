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

  test "detailed siblings preserve core refusals and legacy success behavior" do
    assert {:ok, legacy} = Troposphere.zenith_delay(45.0, 0.0, @met)
    assert {:ok, detailed} = Troposphere.zenith_delay_detailed(45.0, 0.0, @met)
    assert detailed == legacy

    invalid_met = %{pressure_hpa: -1.0, temperature_k: 288.15, relative_humidity: 0.5}
    assert {:error, :invalid_input} = Troposphere.zenith_delay(45.0, 0.0, invalid_met)

    assert {:error, :invalid_input} =
             Troposphere.slant_delay(30.0, 45.0, 10.0, 0.0, invalid_met, @epoch)

    assert {:error, {:invalid_input, %{kind: "INVALID_INPUT", message: message}}} =
             Troposphere.zenith_delay_detailed(
               45.0,
               0.0,
               %{pressure_hpa: -1.0, temperature_k: 288.15, relative_humidity: 0.5}
             )

    assert is_binary(message) and message != ""

    assert {:error, {:invalid_input, %{kind: "INVALID_INPUT", message: slant_message}}} =
             Troposphere.slant_delay_detailed(
               30.0,
               45.0,
               10.0,
               0.0,
               %{pressure_hpa: -1.0, temperature_k: 288.15, relative_humidity: 0.5},
               @epoch
             )

    assert is_binary(slant_message) and slant_message != ""

    assert {:error, :below_mapping_elevation} =
             Troposphere.mapping(1.0, 45.0, 0.0, @epoch)

    assert {:error, {:invalid_input, %{kind: "INVALID_INPUT", message: mapping_message}}} =
             Troposphere.mapping_detailed(1.0, 45.0, 0.0, @epoch)

    assert is_binary(mapping_message) and mapping_message != ""

    assert {:error,
            {:invalid_input,
             %{
               family: "TimeModelError",
               kind: "TIME_MODEL_INVALID_INPUT",
               message: split_message,
               field: "fraction",
               reason: "must be within one residual day"
             }}} =
             Sidereon.NIF.tropo_mapping_factors_detailed(45.0, 45.0, 0.0, 2_451_545.0, 1.5)

    assert is_binary(split_message) and split_message != ""

    assert {:error,
            {:invalid_input,
             %{
               family: "FrameValueError",
               kind: "FRAME_VALUE_INVALID_INPUT",
               field: "lat_rad",
               reason: "must be in [-pi/2, pi/2]"
             }}} = Troposphere.zenith_delay_detailed(100.0, 0.0, @met)

    assert {:error,
            {:invalid_input,
             %{
               family: "TimeModelError",
               kind: "TIME_MODEL_INVALID_INPUT",
               field: "fraction",
               reason: "must be within one residual day"
             }}} =
             Sidereon.NIF.tropo_mapping_factors_detailed(45.0, 45.0, 0.0, 2_451_545.0, 1.5)

    assert {:ok, legacy_slant} =
             Troposphere.slant_delay(90.0, 45.0, 10.0, 0.0, @met, @epoch)

    assert {:ok, detailed_slant} =
             Troposphere.slant_delay_detailed(90.0, 45.0, 10.0, 0.0, @met, @epoch)

    assert detailed_slant == legacy_slant
  end
end
