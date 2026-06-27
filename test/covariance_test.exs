defmodule Sidereon.CovarianceTest do
  use ExUnit.Case, async: true

  alias Sidereon.Covariance

  describe "extract_pos_cov/1" do
    test "extracts 3x3 matrix from RTN lower triangle" do
      lt = [1.0, 2.0, 3.0, 4.0, 5.0, 6.0]
      {:ok, m} = Covariance.extract_pos_cov(lt)

      assert m == [
               [1.0, 2.0, 4.0],
               [2.0, 3.0, 5.0],
               [4.0, 5.0, 6.0]
             ]
    end

    test "returns error for invalid length" do
      assert {:error, _} = Covariance.extract_pos_cov([1.0, 2.0])
    end
  end

  describe "rtn_to_eci/3" do
    test "transforms RTN covariance to ECI" do
      r = {7000.0, 0.0, 0.0}
      v = {0.0, 7.5, 0.0}
      # RTN: R along X, T along Y, N along Z
      cov_rtn = [
        [1.0, 0.0, 0.0],
        [0.0, 2.0, 0.0],
        [0.0, 0.0, 3.0]
      ]

      {:ok, cov_eci} = Covariance.rtn_to_eci(cov_rtn, r, v)
      # In this case RTN aligns with ECI
      assert_in_delta Enum.at(Enum.at(cov_eci, 0), 0), 1.0, 1.0e-9
      assert_in_delta Enum.at(Enum.at(cov_eci, 1), 1), 2.0, 1.0e-9
      assert_in_delta Enum.at(Enum.at(cov_eci, 2), 2), 3.0, 1.0e-9
    end

    test "returns error for parallel r and v" do
      r = {7000.0, 0.0, 0.0}
      v = {1.0, 0.0, 0.0}
      cov = [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]]
      assert {:error, "position and velocity are parallel"} == Covariance.rtn_to_eci(cov, r, v)
    end
  end

  describe "positive_semidefinite?/1" do
    test "returns true for identity" do
      assert Covariance.positive_semidefinite?([
               [1.0, 0.0, 0.0],
               [0.0, 1.0, 0.0],
               [0.0, 0.0, 1.0]
             ])
    end

    test "returns false for negative diagonal" do
      refute Covariance.positive_semidefinite?([
               [-1.0, 0.0, 0.0],
               [0.0, 1.0, 0.0],
               [0.0, 0.0, 1.0]
             ])
    end
  end
end
