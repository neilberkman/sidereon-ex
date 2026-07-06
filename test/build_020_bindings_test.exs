defmodule Sidereon.Build020BindingsTest do
  use ExUnit.Case, async: true

  alias Sidereon.ErrorMetrics
  alias Sidereon.ErrorMetrics.ErrorEllipse
  alias Sidereon.ErrorMetrics.PercentileRadius
  alias Sidereon.ErrorMetrics.PositionCovariance
  alias Sidereon.ErrorMetrics.PositionErrorMetrics

  @sigma 3.25

  test "circular covariance matches analytic error metrics" do
    covariance = diagonal(3, @sigma * @sigma)
    expected_cep = :math.sqrt(2.0 * :math.log(2.0)) * @sigma
    expected_r95 = :math.sqrt(-2.0 * :math.log(1.0 - 0.95)) * @sigma
    expected_drms = :math.sqrt(2.0) * @sigma

    assert {:ok, %PositionErrorMetrics{} = metrics} = ErrorMetrics.from_enu_covariance(covariance)

    assert_in_delta metrics.cep_m.radius_m, expected_cep, 1.0e-12
    assert_in_delta metrics.r95_m.radius_m, expected_r95, 1.0e-12
    assert_in_delta metrics.drms_m, expected_drms, 1.0e-12
    assert_in_delta metrics.two_drms_m, 2.0 * expected_drms, 1.0e-12

    assert {:ok, %ErrorEllipse{} = ellipse} = ErrorMetrics.error_ellipse_from_enu_covariance(covariance)
    assert_in_delta ellipse.semi_major_m, @sigma, 1.0e-12
    assert_in_delta ellipse.semi_minor_m, @sigma, 1.0e-12
    assert_in_delta ellipse.orientation_rad, 0.0, 1.0e-12

    assert {:ok, %PercentileRadius{} = horizontal} = ErrorMetrics.horizontal_radius_at(covariance, 0.95)
    assert horizontal.approx_valid == metrics.r95_m.approx_valid
    assert_in_delta horizontal.radius_m, metrics.r95_m.radius_m, 1.0e-12

    assert {:ok, %PercentileRadius{} = spherical} = ErrorMetrics.spherical_radius_at(covariance, 0.5)
    assert_in_delta spherical.radius_m, metrics.sep_m.radius_m, 1.0e-12

    assert {:ok, vertical} = ErrorMetrics.vertical_radius_at(@sigma * @sigma, 0.5)
    assert_in_delta vertical, 0.6744897501960817 * @sigma, 1.0e-12
  end

  test "elongated covariance matches closed-form ellipse axes" do
    covariance = [
      [9.0, 2.0, 0.0],
      [2.0, 4.0, 0.0],
      [0.0, 0.0, 1.44]
    ]

    trace = 13.0
    delta = :math.sqrt((9.0 - 4.0) * (9.0 - 4.0) + 4.0 * 2.0 * 2.0)
    major_lambda = 0.5 * (trace + delta)
    minor_lambda = 0.5 * (trace - delta)

    assert {:ok, %ErrorEllipse{} = ellipse} = ErrorMetrics.error_ellipse_from_enu_covariance(covariance)
    assert_in_delta ellipse.semi_major_m, :math.sqrt(major_lambda), 1.0e-12
    assert_in_delta ellipse.semi_minor_m, :math.sqrt(minor_lambda), 1.0e-12
    assert_in_delta ellipse.orientation_rad, 0.5 * :math.atan2(4.0, 5.0), 1.0e-12

    assert {:ok, %PositionErrorMetrics{} = metrics} = ErrorMetrics.from_enu_covariance(covariance)
    assert metrics.cep_m.approx_valid

    relative_error =
      abs(metrics.cep_m.approx_m - metrics.cep_m.radius_m) / metrics.cep_m.radius_m

    assert relative_error < 0.03
  end

  test "ENU, ECEF, position covariance, and kinematic inputs agree" do
    enu_m2 = [
      [5.0, 0.25, 0.1],
      [0.25, 2.0, -0.2],
      [0.1, -0.2, 1.25]
    ]

    ecef_m2 = [
      [1.25, 0.1, -0.2],
      [0.1, 5.0, 0.25],
      [-0.2, 0.25, 2.0]
    ]

    assert {:ok, from_enu} = ErrorMetrics.from_enu_covariance(enu_m2)
    assert {:ok, from_ecef} = ErrorMetrics.from_ecef_covariance(ecef_m2, {0.0, 0.0, 0.0})

    assert_metrics_close(from_ecef, from_enu)

    covariance = %PositionCovariance{ecef_m2: ecef_m2, enu_m2: enu_m2}
    assert {:ok, from_position_covariance} = ErrorMetrics.from_position_covariance(covariance)
    assert_metrics_close(from_position_covariance, from_enu)

    solution = %{
      position_m: {6_378_137.0, 0.0, 0.0},
      position_covariance_m2: ecef_m2
    }

    assert {:ok, from_kinematic} = ErrorMetrics.from_kinematic_solution(solution)
    assert_metrics_close(from_kinematic, from_enu)
  end

  defp assert_metrics_close(left, right) do
    assert_in_delta left.cep_m.radius_m, right.cep_m.radius_m, 1.0e-12
    assert_in_delta left.r95_m.radius_m, right.r95_m.radius_m, 1.0e-12
    assert_in_delta left.drms_m, right.drms_m, 1.0e-12
    assert_in_delta left.sep_m.radius_m, right.sep_m.radius_m, 1.0e-12
  end

  defp diagonal(size, value) do
    for row <- 0..(size - 1) do
      for col <- 0..(size - 1) do
        if row == col, do: value, else: 0.0
      end
    end
  end
end
