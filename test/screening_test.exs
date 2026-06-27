defmodule Sidereon.ScreeningTest do
  use ExUnit.Case, async: true

  alias Sidereon.Screening

  @cov [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]]

  describe "screen_catalog/2" do
    test "finds candidate pairs within threshold" do
      objs = [
        %{
          id: "A",
          r: {7000.0, 0.0, 0.0},
          v: {0.0, 7.5, 0.0},
          cov: @cov,
          hard_body_radius_km: 0.01
        },
        %{
          id: "B",
          r: {7000.1, 0.0, 0.0},
          v: {0.0, -7.5, 0.0},
          cov: @cov,
          hard_body_radius_km: 0.01
        },
        %{
          id: "C",
          r: {8000.0, 0.0, 0.0},
          v: {0.0, 7.5, 0.0},
          cov: @cov,
          hard_body_radius_km: 0.01
        }
      ]

      results = Screening.screen_catalog(objs, miss_threshold_km: 1.0)

      # Only A-B pair should be found
      assert length(results) == 1
      [res] = results
      assert res.candidate.id1 == "A"
      assert res.candidate.id2 == "B"
      assert res.collision.pc > 0.0
    end

    test "sorts results by Pc" do
      objs = [
        %{
          id: "A",
          r: {7000.0, 0.0, 0.0},
          v: {0.0, 7.5, 0.0},
          cov: @cov,
          hard_body_radius_km: 0.01
        },
        %{
          id: "B",
          r: {7000.01, 0.0, 0.0},
          v: {0.0, -7.5, 0.0},
          cov: @cov,
          hard_body_radius_km: 0.01
        },
        %{
          id: "C",
          r: {7000.1, 0.0, 0.0},
          v: {0.0, -7.55, 0.0},
          cov: @cov,
          hard_body_radius_km: 0.01
        }
      ]

      results = Screening.screen_catalog(objs, miss_threshold_km: 1.0)

      # Pairs A-B and A-C found (B-C is also within threshold)
      assert length(results) == 3
      # A-B has higher Pc than A-C because miss distance is smaller
      [res1, res2, res3] = results
      assert res1.collision.pc > res2.collision.pc
      assert res2.collision.pc > res3.collision.pc
    end

    test "handles degenerate encounters without crashing" do
      objs = [
        %{
          id: "A",
          r: {7000.0, 0.0, 0.0},
          v: {0.0, 7.5, 0.0},
          cov: @cov,
          hard_body_radius_km: 0.01
        },
        %{
          id: "B",
          r: {7000.1, 0.0, 0.0},
          v: {0.0, 7.5, 0.0},
          cov: @cov,
          hard_body_radius_km: 0.01
        }
      ]

      # This should return an error for zero relative velocity but not crash
      results = Screening.screen_catalog(objs, miss_threshold_km: 1.0)
      assert length(results) == 1
      [res] = results
      assert res.error == "zero relative velocity"
    end
  end
end
