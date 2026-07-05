defmodule Sidereon.GNSSScenarioTest do
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.Scenario

  describe "deterministic scenario simulator parity" do
    test "returns identical bytes and core-pinned arrays for the same seed" do
      assert {:ok, bytes1, fingerprint1} = Scenario.simulate_bytes(scenario())
      assert {:ok, bytes2, fingerprint2} = Scenario.simulate_bytes(scenario())

      assert bytes1 == bytes2
      assert fingerprint1 == fingerprint2
      assert fingerprint1 == 14_477_122_350_862_481_408

      decoded = Jason.decode!(bytes1)
      observations = decoded["observations"]
      truth = decoded["truth_terms"]
      receiver = decoded["receiver_truth"]

      assert decoded["schema_version"] == 1
      assert decoded["engine_version"] == "0.17.0:scenario-observables-v1"
      assert observations["epoch_offsets"] == [0, 1, 2]
      assert observations["epoch_index"] == [0, 1]

      assert_close_list(observations["pseudorange_m"], [19_950_610.11293578, 19_953_170.84944195], 1.0e-8)
      assert_close_list(observations["doppler_hz"], [-438.22961996703225, -458.8850866917381], 1.0e-12)

      assert_close_list(truth["geometric_range_m"], observations["pseudorange_m"], 0.0)
      assert_close_list(truth["doppler_satellite_motion_hz"], observations["doppler_hz"], 0.0)

      assert Enum.map(receiver, & &1["position_ecef_m"]) == [
               [6_378_137.0, 0.0, 0.0],
               [6_378_137.0, 0.0, 0.0]
             ]
    end

    test "returns decoded observable and truth arrays" do
      assert {:ok, result} = Scenario.simulate(scenario())

      assert result.determinism_fingerprint == 14_477_122_350_862_481_408
      assert result.observations.satellite_id == [%{prn: 1, system: "Gps"}, %{prn: 1, system: "Gps"}]
      assert_close_list(result.truth_terms.thermal_noise_m, [0.0, 0.0], 0.0)
    end

    test "accepts string-keyed scenario maps" do
      string_keyed = scenario() |> Jason.encode!() |> Jason.decode!()

      assert {:ok, bytes, 14_477_122_350_862_481_408} = Scenario.simulate_bytes(string_keyed)
      decoded = Jason.decode!(bytes)

      assert_close_list(decoded["observations"]["pseudorange_m"], [19_950_610.11293578, 19_953_170.84944195], 1.0e-8)
    end

    test "accepts schema string kinds for external product maps" do
      scenario = %{
        scenario()
        | constellation: %{
            kind: :external_products,
            source: %{kind: "sp3", product_id: "fixture", content_digest: "sha256:fixture"},
            satellites: ["G01"]
          }
      }

      assert {:error, :external_source_required} = Scenario.simulate_bytes(scenario)
    end
  end

  defp scenario do
    %{
      seed: 12_345,
      epochs: %{start_j2000_s: 646_229_000.0, count: 2, cadence_s: 30.0},
      receiver: %{
        kind: :static_geodetic,
        position: %{lat_deg: 0.0, lon_deg: 0.0, height_m: 0.0}
      },
      constellation: %{
        kind: :synthetic_keplerian,
        satellites: [
          %{
            satellite_id: "G01",
            semi_major_axis_m: 26_560_000.0,
            eccentricity: 0.01,
            inclination_deg: 55.0,
            raan_deg: 0.0,
            arg_perigee_deg: 0.0,
            mean_anomaly_deg: 5.0,
            epoch_j2000_s: 646_229_000.0
          }
        ]
      },
      signals: [%{system: :gps}],
      error_budget: %{elevation_mask_deg: -90.0}
    }
  end

  defp assert_close_list(actual, expected, tolerance) do
    if tolerance == 0.0 do
      assert actual == expected
    else
      actual
      |> Enum.zip(expected)
      |> Enum.each(fn {actual_value, expected_value} ->
        assert_in_delta actual_value, expected_value, tolerance
      end)
    end
  end
end
