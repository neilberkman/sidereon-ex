defmodule Sidereon.CovarianceLeastSquaresTest do
  use ExUnit.Case, async: true

  alias Sidereon.Covariance

  describe "normal_covariance/2" do
    test "constant-fit covariance is variance_scale / m" do
      # J is a column of ones (a constant fit over 4 observations), so
      # (J^T J)^-1 = 1/4 and the covariance scales it by variance_scale.
      jac = [[1.0], [1.0], [1.0], [1.0]]
      assert {:ok, [[c]]} = Covariance.normal_covariance(jac, 2.0)
      assert_in_delta c, 0.5, 1.0e-12
    end

    test "a rank-deficient Jacobian is rejected" do
      jac = [[1.0, 2.0], [2.0, 4.0], [3.0, 6.0]]
      assert {:error, :singular_jacobian} = Covariance.normal_covariance(jac, 1.0)
    end

    test "fewer rows than columns is invalid input" do
      assert {:error, :invalid_input} = Covariance.normal_covariance([[1.0, 0.0]], 1.0)
    end

    test "a ragged Jacobian is invalid input, not a raise" do
      assert {:error, :invalid_input} = Covariance.normal_covariance([[1.0, 2.0], [3.0]], 1.0)
    end
  end

  describe "hessian_trace/1" do
    test "sum of squared column norms" do
      jac = [[1.0, 0.0], [0.0, 2.0], [2.0, 1.0]]
      # col0: 1 + 0 + 4 = 5; col1: 0 + 4 + 1 = 5; trace = 10.
      assert_in_delta Covariance.hessian_trace(jac), 10.0, 1.0e-12
    end
  end

  describe "covariance_from_jacobian/2" do
    test "scales the cofactor by the post-fit reduced chi-square" do
      # m = 4, n = 1, cost = 6 -> s_sq = 2*6/(4-1) = 4; cov = s_sq * (1/4) = 1.
      jac = [[1.0], [1.0], [1.0], [1.0]]
      assert {:ok, [[c]]} = Covariance.covariance_from_jacobian(jac, 6.0)
      assert_in_delta c, 1.0, 1.0e-12
    end

    test "non-positive redundancy (m <= n) is invalid input" do
      # m = n = 1: no redundancy, so the reduced chi-square is undefined.
      assert {:error, :invalid_input} =
               Covariance.covariance_from_jacobian([[1.0]], 1.0)
    end

    test "a ragged Jacobian is invalid input, not a raise" do
      assert {:error, :invalid_input} =
               Covariance.covariance_from_jacobian([[1.0, 2.0], [3.0]], 1.0)
    end
  end

  describe "error_ellipse_2x2/2" do
    test "axis-aligned diagonal block gives the expected semi-axes and orientation" do
      cov = [[4.0, 0.0], [0.0, 1.0]]
      assert {:ok, ellipse} = Covariance.error_ellipse_2x2(cov, 0.5)
      # chi_square_scale = -2 ln(1 - 0.5) = 2 ln 2.
      assert_in_delta ellipse.chi_square_scale, 2.0 * :math.log(2.0), 1.0e-12
      # semi-axes = sqrt(lambda * scale); ratio is sqrt(4 / 1) = 2.
      assert_in_delta ellipse.semi_major / ellipse.semi_minor, 2.0, 1.0e-9
      assert_in_delta ellipse.orientation_rad, 0.0, 1.0e-12
      assert ellipse.confidence == 0.5
    end

    test "a non-positive-semidefinite block is rejected" do
      assert {:error, :invalid_input} =
               Covariance.error_ellipse_2x2([[1.0, 0.0], [0.0, -1.0]], 0.95)
    end

    test "a non-2x2 block is invalid input, not a raise" do
      assert {:error, :invalid_input} =
               Covariance.error_ellipse_2x2([[1.0, 0.0, 0.0], [0.0, 1.0, 0.0]], 0.95)
    end
  end
end
