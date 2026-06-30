defmodule Sidereon.CollisionTest do
  @moduledoc """
  Collision probability tests.

  Reference: NASA CARA Analysis Tools (Omitron test case).
  """
  use ExUnit.Case

  # NASA CARA Omitron test case — states in ECI km/km/s, covariances in km²
  @omitron_params %{
    r1: {378.39559, 4305.721887, 5752.767554},
    v1: {2.360800244, 5.580331936, -4.322349039},
    cov1: [
      [44.5757544811362, 81.6751751052616, -67.8687662707124],
      [81.6751751052616, 158.453402956163, -128.616921644857],
      [-67.8687662707124, -128.616921644858, 105.490542562701]
    ],
    r2: {374.5180598, 4307.560983, 5751.130418},
    v2: {-5.388125081, -3.946827739, 3.322820358},
    cov2: [
      [2.31067077720423, 1.69905293875632, -1.4170164577661],
      [1.69905293875632, 1.24957388457206, -1.04174164279599],
      [-1.4170164577661, -1.04174164279599, 0.869260558223714]
    ],
    hard_body_radius_km: 0.020
  }

  describe "probability/2 - methods" do
    test "Omitron test case: equal-area Pc matches CARA reference" do
      {:ok, result} = Sidereon.Collision.probability(@omitron_params, method: :equal_area)

      # CARA reference: equal-area square Pc = 2.70601573490111e-05
      assert_in_delta result.pc, 2.70601573490111e-05, 1.0e-09
      assert result.method == :foster_2d_equal_area
    end

    test "Omitron test case: numerical Pc is close to equal-area" do
      {:ok, res_ea} = Sidereon.Collision.probability(@omitron_params, method: :equal_area)
      {:ok, res_num} = Sidereon.Collision.probability(@omitron_params, method: :numerical)

      # They should be very close for this geometry
      assert_in_delta res_num.pc, res_ea.pc, res_ea.pc * 0.01
      assert res_num.method == :foster_2d_numerical
    end

    test "Omitron test case: Alfano 2005 matches the Foster methods" do
      {:ok, res_ea} = Sidereon.Collision.probability(@omitron_params, method: :equal_area)
      {:ok, res_num} = Sidereon.Collision.probability(@omitron_params, method: :numerical)
      {:ok, res_alf} = Sidereon.Collision.probability(@omitron_params, method: :alfano_2005)

      # Alfano is an independent derivation — it should match the Foster
      # methods within ~1% for this well-conditioned geometry.
      assert_in_delta res_alf.pc, res_ea.pc, res_ea.pc * 0.01
      assert_in_delta res_alf.pc, res_num.pc, res_num.pc * 0.01
      assert res_alf.method == :alfano_2005
      assert res_alf.pc > 0.0
    end

    test "Alfano 2005 respects HBR monotonicity" do
      {:ok, small} =
        Sidereon.Collision.probability(
          Map.put(@omitron_params, :hard_body_radius_km, 0.010),
          method: :alfano_2005
        )

      {:ok, large} =
        Sidereon.Collision.probability(
          Map.put(@omitron_params, :hard_body_radius_km, 0.040),
          method: :alfano_2005
        )

      assert large.pc > small.pc
    end

    test "unsupported method returns error" do
      assert {:error, "unsupported method: no_such_method"} =
               Sidereon.Collision.probability(@omitron_params, method: :no_such_method)
    end
  end

  describe "probability/2 - symmetry" do
    test "swapping objects gives same result" do
      params1 = @omitron_params

      params2 = %{
        r1: params1.r2,
        v1: params1.v2,
        cov1: params1.cov2,
        r2: params1.r1,
        v2: params1.v1,
        cov2: params1.cov1,
        hard_body_radius_km: params1.hard_body_radius_km
      }

      {:ok, res1} = Sidereon.Collision.probability(params1)
      {:ok, res2} = Sidereon.Collision.probability(params2)

      assert_in_delta res1.pc, res2.pc, 1.0e-15
    end
  end

  describe "probability/2 - monotonicity" do
    test "larger HBR increases Pc" do
      {:ok, small} =
        Sidereon.Collision.probability(Map.put(@omitron_params, :hard_body_radius_km, 0.010))

      {:ok, large} =
        Sidereon.Collision.probability(Map.put(@omitron_params, :hard_body_radius_km, 0.040))

      assert large.pc > small.pc
    end

    test "larger miss distance decreases Pc" do
      p1 = @omitron_params
      p2 = %{p1 | r2: {elem(p1.r2, 0) + 1000.0, elem(p1.r2, 1), elem(p1.r2, 2)}}

      {:ok, res1} = Sidereon.Collision.probability(p1)
      {:ok, res2} = Sidereon.Collision.probability(p2)

      assert res2.pc < res1.pc
    end
  end

  describe "probability/2 - error handling" do
    test "zero relative velocity returns error" do
      assert {:error, "zero relative velocity"} =
               Sidereon.Collision.probability(%{
                 r1: {7000.0, 0.0, 0.0},
                 v1: {0.0, 7.5, 0.0},
                 cov1: [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]],
                 r2: {7000.01, 0.0, 0.0},
                 v2: {0.0, 7.5, 0.0},
                 cov2: [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]],
                 hard_body_radius_km: 0.015
               })
    end
  end
end
