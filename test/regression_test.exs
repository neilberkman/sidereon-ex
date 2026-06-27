defmodule Sidereon.RegressionTest do
  @moduledoc """
  Regression tests for bugs found during code review.
  """
  use ExUnit.Case

  describe "OMM timezone handling" do
    test "offset timestamp converts to UTC" do
      omm = %{
        "EPOCH" => "2026-04-05T13:16:46+05:00",
        "NORAD_CAT_ID" => 1,
        "INCLINATION" => 0.0,
        "RA_OF_ASC_NODE" => 0.0,
        "ECCENTRICITY" => 0.0,
        "ARG_OF_PERICENTER" => 0.0,
        "MEAN_ANOMALY" => 0.0,
        "MEAN_MOTION" => 1.0
      }

      {:ok, el} = Sidereon.Format.OMM.parse(omm)
      # +05:00 means 13:16 local = 08:16 UTC
      assert el.epoch.hour == 8
      assert el.epoch.minute == 16
    end

    test "Z timestamp parses as UTC" do
      omm = %{
        "EPOCH" => "2026-04-05T13:16:46Z",
        "NORAD_CAT_ID" => 1,
        "INCLINATION" => 0.0,
        "RA_OF_ASC_NODE" => 0.0,
        "ECCENTRICITY" => 0.0,
        "ARG_OF_PERICENTER" => 0.0,
        "MEAN_ANOMALY" => 0.0,
        "MEAN_MOTION" => 1.0
      }

      {:ok, el} = Sidereon.Format.OMM.parse(omm)
      assert el.epoch.hour == 13
    end

    test "bare timestamp treated as UTC" do
      omm = %{
        "EPOCH" => "2026-04-05T13:16:46.804800",
        "NORAD_CAT_ID" => 1,
        "INCLINATION" => 0.0,
        "RA_OF_ASC_NODE" => 0.0,
        "ECCENTRICITY" => 0.0,
        "ARG_OF_PERICENTER" => 0.0,
        "MEAN_ANOMALY" => 0.0,
        "MEAN_MOTION" => 1.0
      }

      {:ok, el} = Sidereon.Format.OMM.parse(omm)
      assert el.epoch.hour == 13
    end
  end

  describe "SGP4 malformed elements" do
    test "nil epoch returns error" do
      el = struct(Sidereon.Elements, epoch: nil, catalog_number: "0")

      assert {:error, {:missing_field, :epoch}} =
               Sidereon.SGP4.propagate(el, ~U[2024-01-01 00:00:00Z])
    end

    test "nil catalog_number returns error" do
      el = struct(Sidereon.Elements, epoch: ~U[2024-01-01 00:00:00Z], catalog_number: nil)

      assert {:error, {:missing_field, :catalog_number}} =
               Sidereon.SGP4.propagate(el, ~U[2024-01-01 00:00:00Z])
    end

    test "empty struct returns error, not crash" do
      el = struct(Sidereon.Elements)

      assert {:error, {:missing_field, :epoch}} =
               Sidereon.SGP4.propagate(el, ~U[2024-01-01 00:00:00Z])
    end

    test "missing NIF element fields return tagged errors instead of zero-filling" do
      for field <- [
            :bstar,
            :mean_motion_dot,
            :mean_motion_double_dot,
            :eccentricity,
            :arg_perigee_deg,
            :inclination_deg,
            :mean_anomaly_deg,
            :mean_motion,
            :raan_deg
          ] do
        assert {:error, {:missing_field, ^field}} =
                 valid_sgp4_elements()
                 |> Map.put(field, nil)
                 |> Sidereon.SGP4.to_nif_elements_map()
      end
    end

    test "invalid NIF element fields return tagged errors" do
      assert {:error, {:invalid_field, :mean_motion, "15.0"}} =
               valid_sgp4_elements()
               |> Map.put(:mean_motion, "15.0")
               |> Sidereon.SGP4.to_nif_elements_map()

      assert {:error, {:invalid_field, :catalog_number, "  "}} =
               valid_sgp4_elements()
               |> Map.put(:catalog_number, "  ")
               |> Sidereon.SGP4.to_nif_elements_map()
    end

    test "integer numeric fields are normalized for the NIF" do
      assert {:ok, elements_map} =
               valid_sgp4_elements()
               |> Map.put(:bstar, 0)
               |> Sidereon.SGP4.to_nif_elements_map()

      assert elements_map.bstar == 0.0
    end
  end

  describe "TLE encode malformed elements" do
    test "returns tagged errors for identity fields instead of fabricating defaults" do
      assert Sidereon.Format.TLE.encode(%{valid_tle_elements() | catalog_number: nil}) ==
               {:error, {:missing_field, :catalog_number}}

      assert Sidereon.Format.TLE.encode(%{valid_tle_elements() | elset_number: nil}) ==
               {:error, {:missing_field, :elset_number}}

      assert Sidereon.Format.TLE.encode(%{valid_tle_elements() | rev_number: nil}) ==
               {:error, {:missing_field, :rev_number}}
    end

    test "returns tagged errors on bounded field overflows" do
      assert Sidereon.Format.TLE.encode(%{valid_tle_elements() | catalog_number: "123456"}) ==
               {:error, {:invalid_field, :catalog_number, "123456"}}

      assert Sidereon.Format.TLE.encode(%{valid_tle_elements() | rev_number: 100_000}) ==
               {:error, {:invalid_field, :rev_number, 100_000}}

      assert Sidereon.Format.TLE.encode(%{valid_tle_elements() | elset_number: 10_000}) ==
               {:error, {:invalid_field, :elset_number, 10_000}}
    end

    test "encode! raises on malformed fields" do
      assert_raise ArgumentError, ~r/catalog_number/, fn ->
        Sidereon.Format.TLE.encode!(%{valid_tle_elements() | catalog_number: "123456"})
      end
    end
  end

  describe "TLE parse catalog_number trimming" do
    test "low NORAD IDs are trimmed" do
      {:ok, el} =
        Sidereon.Format.TLE.parse(
          "1 00005U 58002B   00179.78495062  .00000023  00000-0  28098-4 0  4753",
          "2 00005  34.2682 348.7242 1859667 331.7664  19.3264 10.82419157413667"
        )

      assert el.catalog_number == "00005"
    end
  end

  describe "Passes.predict step_seconds guard" do
    test "returns error on step_seconds: 0" do
      {:ok, el} =
        Sidereon.Format.TLE.parse(
          "1 25544U 98067A   18184.80969102  .00001614  00000-0  31745-4 0  9993",
          "2 25544  51.6414 295.8524 0003435 262.6267 204.2868 15.54005638121106"
        )

      station = %{latitude: 51.5074, longitude: -0.1278, altitude_m: 11.0}

      assert {:error, {:invalid_option, :step_seconds}} =
               Sidereon.Passes.predict(
                 el,
                 station,
                 ~U[2024-12-19 00:00:00Z],
                 ~U[2024-12-19 12:00:00Z],
                 step_seconds: 0
               )
    end
  end

  defp valid_sgp4_elements do
    %Sidereon.Elements{
      catalog_number: "25544",
      classification: "U",
      international_designator: "98067A",
      epoch: ~U[2024-01-01 00:00:00Z],
      mean_motion_dot: 0.0,
      mean_motion_double_dot: 0.0,
      bstar: 0.0,
      ephemeris_type: 0,
      elset_number: 999,
      inclination_deg: 51.6414,
      raan_deg: 295.8524,
      eccentricity: 0.0003435,
      arg_perigee_deg: 262.6267,
      mean_anomaly_deg: 204.2868,
      mean_motion: 15.54005638,
      rev_number: 12110
    }
  end

  defp valid_tle_elements do
    {:ok, el} =
      Sidereon.Format.TLE.parse(
        "1 25544U 98067A   18184.80969102  .00001614  00000-0  31745-4 0  9993",
        "2 25544  51.6414 295.8524 0003435 262.6267 204.2868 15.54005638121106"
      )

    el
  end
end
