defmodule Sidereon.SourceLocalizationTest do
  use ExUnit.Case, async: true

  alias Sidereon.GeometryQuality
  alias Sidereon.SourceLocalization

  defp arrivals(sensors, source, origin, speed) do
    Enum.map(sensors, fn sensor ->
      sensor_speed = sensor.propagation_speed_m_s || speed
      origin + distance(source, sensor.position_m) / sensor_speed
    end)
  end

  defp distance(a, b) do
    a
    |> Enum.zip(b)
    |> Enum.map(fn {x, y} -> (x - y) * (x - y) end)
    |> Enum.sum()
    |> :math.sqrt()
  end

  defp assert_vec_close(actual, expected, tol) do
    actual
    |> Enum.zip(expected)
    |> Enum.each(fn {a, e} -> assert_in_delta a, e, tol end)
  end

  test "closed-form seed and ToA solve recover a clean 3D source" do
    sensors = [
      SourceLocalization.sensor([0.0, 0.0, 0.0]),
      SourceLocalization.sensor([1200.0, 0.0, 0.0]),
      SourceLocalization.sensor([0.0, 900.0, 0.0]),
      SourceLocalization.sensor([0.0, 0.0, 700.0]),
      SourceLocalization.sensor([1100.0, 800.0, 600.0])
    ]

    source = [320.0, 260.0, 180.0]
    origin = 12.5
    speed = 343.0
    times = arrivals(sensors, source, origin, speed)

    assert {:ok, seed} = SourceLocalization.closed_form_initial_guess(sensors, times, speed)
    assert_vec_close(seed.position_m, source, 1.0e-8)
    assert_in_delta seed.origin_time_s, origin, 1.0e-10
    assert seed.residual_rms_s < 1.0e-11

    assert {:ok, solution} =
             SourceLocalization.locate_source(sensors, times, speed, timing_sigma_s: 0.001)

    assert_vec_close(solution.position_m, source, 1.0e-7)
    assert_in_delta solution.origin_time_s, origin, 1.0e-10
    assert solution.covariance != nil
    assert Enum.all?(solution.residuals, &(abs(&1.residual_s) < 1.0e-10))
    assert %GeometryQuality{} = solution.geometry_quality
  end

  test "closed-form seed recovers a clean 2D ToA source and the deprecated alias agrees" do
    sensors = [
      SourceLocalization.sensor([0.0, 0.0]),
      SourceLocalization.sensor([1000.0, 0.0]),
      SourceLocalization.sensor([0.0, 800.0]),
      SourceLocalization.sensor([900.0, 900.0])
    ]

    source = [300.0, 260.0]
    origin = 4.0
    speed = 340.0
    times = arrivals(sensors, source, origin, speed)

    assert {:ok, seed} = SourceLocalization.closed_form_initial_guess(sensors, times, speed)
    assert_vec_close(seed.position_m, source, 1.0e-8)
    assert_in_delta seed.origin_time_s, origin, 1.0e-10

    assert :erlang.apply(SourceLocalization, :chan_ho_initial_guess, [sensors, times, speed, :toa]) == {:ok, seed}
  end

  test "source solution surfaces nominal geometry quality for a balanced fixture" do
    sensors = [
      SourceLocalization.sensor([0.0, 0.0, 0.0]),
      SourceLocalization.sensor([2.0, 0.0, 0.0]),
      SourceLocalization.sensor([0.0, 2.0, 0.0]),
      SourceLocalization.sensor([0.0, 0.0, 2.0]),
      SourceLocalization.sensor([2.0, 2.0, 2.0])
    ]

    source = [0.4, 0.6, 0.5]
    origin = 1.25
    speed = 1.0
    times = arrivals(sensors, source, origin, speed)

    assert {:ok, solution} = SourceLocalization.locate_source(sensors, times, speed)

    assert {:ok, solution_without_influence} =
             SourceLocalization.locate_source(sensors, times, speed, include_influence: false)

    assert solution_without_influence.per_sensor_influence == []
    assert solution_without_influence.position_m === solution.position_m
    assert solution_without_influence.origin_time_s === solution.origin_time_s

    assert %GeometryQuality{
             tier: :nominal,
             redundancy: 1,
             rank: 4,
             raim_checkable: true,
             covariance_validated: true
           } = solution.geometry_quality
  end

  test "rank-deficient source DOP geometry returns a typed singular error" do
    sensors = [
      SourceLocalization.sensor([0.0, 0.0]),
      SourceLocalization.sensor([100.0, 0.0]),
      SourceLocalization.sensor([200.0, 0.0]),
      SourceLocalization.sensor([300.0, 0.0])
    ]

    assert SourceLocalization.source_dop(sensors, [50.0, 0.0], 300.0) == {:error, {:geometry, :singular}}
  end

  test "TDOA solve, source DOP, and CRLB match the analytic references" do
    sensors = [
      SourceLocalization.sensor([0.0, 0.0]),
      SourceLocalization.sensor([1000.0, 0.0]),
      SourceLocalization.sensor([0.0, 800.0]),
      SourceLocalization.sensor([900.0, 900.0])
    ]

    source = [300.0, 260.0]
    origin = 4.0
    speed = 340.0
    times = arrivals(sensors, source, origin, speed)

    assert {:ok, solution} =
             SourceLocalization.locate_source(sensors, times, speed,
               mode: {:tdoa, 0},
               timing_sigma_s: 0.001
             )

    assert_vec_close(solution.position_m, source, 1.0e-7)
    assert_in_delta solution.origin_time_s, origin, 1.0e-9
    assert length(solution.residuals) == length(sensors) - 1

    square_sensors = [
      SourceLocalization.sensor([100.0, 0.0]),
      SourceLocalization.sensor([-100.0, 0.0]),
      SourceLocalization.sensor([0.0, 100.0]),
      SourceLocalization.sensor([0.0, -100.0])
    ]

    assert {:ok, dop} = SourceLocalization.source_dop(square_sensors, [0.0, 0.0], 10.0)
    assert_in_delta dop.pdop, 10.0, 1.0e-12
    assert_in_delta dop.hdop, 10.0, 1.0e-12
    assert dop.vdop == 0.0
    assert_in_delta dop.tdop, 0.5, 1.0e-12
    assert_in_delta dop.gdop, :math.sqrt(100.25), 1.0e-12

    assert {:ok, crlb} = SourceLocalization.source_crlb(square_sensors, [0.0, 0.0], 10.0, 0.01)
    [[c00, _], [_, c11]] = crlb.covariance.position_m2
    assert_in_delta c00, 0.005, 1.0e-15
    assert_in_delta c11, 0.005, 1.0e-15
    assert_in_delta crlb.covariance.origin_time_s2, 0.000025, 1.0e-18
  end
end
