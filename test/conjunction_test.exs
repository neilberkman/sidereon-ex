defmodule Sidereon.ConjunctionTest do
  @moduledoc """
  Conjunction assessment tests.
  """
  use ExUnit.Case

  setup_all do
    {:ok, iss} =
      Sidereon.Format.TLE.parse(
        "1 25544U 98067A   18184.80969102  .00001614  00000-0  31745-4 0  9993",
        "2 25544  51.6414 295.8524 0003435 262.6267 204.2868 15.54005638121106"
      )

    {:ok, debris} =
      Sidereon.Format.TLE.parse(
        "1 43115U 18004E   18184.93592192  .00002627  00000-0  42316-4 0  9996",
        "2 43115  51.6381 296.5429 0001844 127.5881 232.5326 15.56879558 25072"
      )

    {:ok, iridium} =
      Sidereon.Format.TLE.parse(
        "1 24946U 97051C   09040.78448243 +.00000153 +00000-0 +47668-4 0  9994",
        "2 24946 086.3994 121.7028 0002288 085.1644 274.9812 14.34219863597336"
      )

    {:ok, cosmos} =
      Sidereon.Format.TLE.parse(
        "1 22675U 93036A   09040.49834364 -.00000001  00000-0  95251-5 0  9996",
        "2 22675 074.0355 019.4646 0016027 098.7014 261.5952 14.31135643817415"
      )

    %{iss: iss, debris: debris, iridium: iridium, cosmos: cosmos}
  end

  test "ISS vs debris finds periodic close approaches", %{iss: iss, debris: debris} do
    results =
      Sidereon.Conjunction.find(iss, debris,
        end_min: 1440.0,
        step_min: 1.0,
        threshold_km: 10000.0
      )

    assert is_list(results)
    assert length(results) > 5

    for {t, d} <- results do
      assert t >= 0.0
      assert d > 0.0
      assert d < 10000.0
    end

    # Approaches should be roughly periodic (~92 min for ISS)
    if length(results) >= 2 do
      [{t1, _}, {t2, _} | _] = results
      period = t2 - t1
      assert period > 80.0 and period < 100.0
    end
  end

  test "returns empty list for tight threshold", %{iss: iss, debris: debris} do
    results =
      Sidereon.Conjunction.find(iss, debris,
        end_min: 1440.0,
        step_min: 1.0,
        threshold_km: 10.0
      )

    assert results == []
  end

  test "returns error when end_min is missing", %{iss: iss, debris: debris} do
    assert {:error, {:missing_option, :end_min}} =
             Sidereon.Conjunction.find(iss, debris, step_min: 1.0)
  end

  test "returns error for invalid options", %{iss: iss, debris: debris} do
    assert {:error, {:invalid_option, :step_min}} =
             Sidereon.Conjunction.find(iss, debris,
               end_min: 1440.0,
               step_min: 0.0
             )

    assert {:error, {:invalid_option, :threshold_km}} =
             Sidereon.Conjunction.find(iss, debris,
               end_min: 1440.0,
               threshold_km: -1.0
             )
  end

  test "returns error when an element cannot be encoded", %{iss: iss, debris: debris} do
    bad_iss = %{iss | catalog_number: "123456"}

    assert {:error, {:invalid_tle, :primary, {:invalid_field, :catalog_number, "123456"}}} =
             Sidereon.Conjunction.find(bad_iss, debris,
               end_min: 1440.0,
               step_min: 1.0
             )
  end

  describe "Iridium 33 / Cosmos 2251 collision (2009-02-10)" do
    test "finds closest approach near known collision time", %{
      iridium: iridium,
      cosmos: cosmos
    } do
      results =
        Sidereon.Conjunction.find(iridium, cosmos,
          end_min: 2880.0,
          step_min: 1.0,
          threshold_km: 50.0
        )

      refute Enum.empty?(results)

      {tca, min_dist} = Enum.min_by(results, fn {_t, d} -> d end)
      tca_hours = tca / 60.0

      # Known collision: ~22.1 hours from Iridium epoch
      assert_in_delta tca_hours,
                      22.1,
                      1.0,
                      "TCA #{Float.round(tca_hours, 2)}h not near expected 22.1h"

      # SGP4 can't predict exact 0, but should be < 10 km
      assert min_dist < 10.0,
             "Miss distance #{Float.round(min_dist, 2)} km exceeds 10 km"
    end
  end
end
