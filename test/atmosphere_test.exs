defmodule Sidereon.AtmosphereTest do
  use ExUnit.Case

  describe "density/3" do
    test "returns density and temperature at ISS altitude" do
      position = %{latitude: 0.0, longitude: 0.0, altitude_km: 400.0}
      datetime = ~U[2024-06-20 12:00:00Z]

      {:ok, result} = Sidereon.Atmosphere.density(position, datetime)

      assert is_float(result.density)
      assert is_float(result.temperature)

      # ISS altitude density should be in the range ~1e-13 to ~1e-10 kg/m^3
      assert result.density > 1.0e-14,
             "density too low: #{:erlang.float_to_binary(result.density, decimals: 3)}"

      assert result.density < 1.0e-9,
             "density too high: #{:erlang.float_to_binary(result.density, decimals: 3)}"

      # Temperature at 400 km should be between 500 K and 2000 K
      assert result.temperature > 500.0
      assert result.temperature < 2000.0
    end

    test "sea level density is approximately 1.225 kg/m^3" do
      position = %{latitude: 45.0, longitude: 0.0, altitude_km: 0.0}
      datetime = ~U[2024-06-20 12:00:00Z]

      {:ok, result} = Sidereon.Atmosphere.density(position, datetime)

      assert_in_delta result.density, 1.225, 0.4
      assert_in_delta result.temperature, 288.15, 10.0
    end

    test "density decreases with altitude" do
      datetime = ~U[2024-06-20 12:00:00Z]

      {:ok, r0} =
        Sidereon.Atmosphere.density(%{latitude: 0.0, longitude: 0.0, altitude_km: 0.0}, datetime)

      {:ok, r200} =
        Sidereon.Atmosphere.density(
          %{latitude: 0.0, longitude: 0.0, altitude_km: 200.0},
          datetime
        )

      {:ok, r400} =
        Sidereon.Atmosphere.density(
          %{latitude: 0.0, longitude: 0.0, altitude_km: 400.0},
          datetime
        )

      {:ok, r800} =
        Sidereon.Atmosphere.density(
          %{latitude: 0.0, longitude: 0.0, altitude_km: 800.0},
          datetime
        )

      assert r0.density > r200.density
      assert r200.density > r400.density
      assert r400.density > r800.density
    end

    test "higher solar activity increases thermospheric density" do
      position = %{latitude: 0.0, longitude: 0.0, altitude_km: 400.0}
      datetime = ~U[2024-06-20 12:00:00Z]

      {:ok, low} = Sidereon.Atmosphere.density(position, datetime, f107: 70.0, f107a: 70.0)
      {:ok, high} = Sidereon.Atmosphere.density(position, datetime, f107: 250.0, f107a: 250.0)

      assert high.density > low.density
    end

    test "accepts tuple datetime format" do
      position = %{latitude: 0.0, longitude: 0.0, altitude_km: 400.0}
      datetime = {{2024, 6, 20}, {12, 0, 0}}

      {:ok, result} = Sidereon.Atmosphere.density(position, datetime)

      assert is_float(result.density)
      assert result.density > 0.0
    end

    test "works with custom geomagnetic index" do
      position = %{latitude: 0.0, longitude: 0.0, altitude_km: 400.0}
      datetime = ~U[2024-06-20 12:00:00Z]

      {:ok, quiet} = Sidereon.Atmosphere.density(position, datetime, ap: 4.0)
      {:ok, storm} = Sidereon.Atmosphere.density(position, datetime, ap: 100.0)

      # Geomagnetic storms increase thermospheric density
      assert storm.density > quiet.density
    end

    test "returns tagged errors for malformed position fields" do
      datetime = ~U[2024-06-20 12:00:00Z]

      assert {:error, {:missing_field, :altitude_km}} =
               Sidereon.Atmosphere.density(%{latitude: 0.0, longitude: 0.0}, datetime)

      assert {:error, {:invalid_field, :latitude, "0"}} =
               Sidereon.Atmosphere.density(
                 %{latitude: "0", longitude: 0.0, altitude_km: 400.0},
                 datetime
               )
    end

    test "returns tagged errors for malformed options and datetime" do
      position = %{latitude: 0.0, longitude: 0.0, altitude_km: 400.0}

      assert {:error, {:invalid_option, :f107}} =
               Sidereon.Atmosphere.density(position, ~U[2024-06-20 12:00:00Z], f107: "high")

      assert {:error, {:invalid_datetime, {{2024, 2, 30}, {12, 0, 0}}}} =
               Sidereon.Atmosphere.density(position, {{2024, 2, 30}, {12, 0, 0}})
    end

    test "rejects out-of-domain altitude" do
      datetime = ~U[2024-06-20 12:00:00Z]

      assert {:error, {:invalid_field, :altitude_km, -10.0}} =
               Sidereon.Atmosphere.density(
                 %{latitude: 0.0, longitude: 0.0, altitude_km: -10.0},
                 datetime
               )

      assert {:error, {:invalid_field, :altitude_km, 5000.0}} =
               Sidereon.Atmosphere.density(
                 %{latitude: 0.0, longitude: 0.0, altitude_km: 5000.0},
                 datetime
               )
    end

    test "accepts altitude domain boundaries" do
      datetime = ~U[2024-06-20 12:00:00Z]

      assert {:ok, _} =
               Sidereon.Atmosphere.density(
                 %{latitude: 0.0, longitude: 0.0, altitude_km: 0.0},
                 datetime
               )

      assert {:ok, _} =
               Sidereon.Atmosphere.density(
                 %{latitude: 0.0, longitude: 0.0, altitude_km: 1000.0},
                 datetime
               )
    end

    test "rejects negative solar and geomagnetic indices" do
      position = %{latitude: 0.0, longitude: 0.0, altitude_km: 400.0}
      datetime = ~U[2024-06-20 12:00:00Z]

      assert {:error, {:invalid_option, :f107}} =
               Sidereon.Atmosphere.density(position, datetime, f107: -1.0)

      assert {:error, {:invalid_option, :ap}} =
               Sidereon.Atmosphere.density(position, datetime, ap: -5.0)
    end
  end
end
