defmodule Sidereon.GNSS.PrecisePositioningVelocityTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Sidereon.GNSS.PrecisePositioning
  alias Sidereon.GNSS.PrecisePositioning.VelocitySolveError
  alias Sidereon.NIF

  @receiver {0.0, 0.0, 0.0}
  @truth_velocity {3.0, -2.0, 0.5}
  @truth_clock_drift 0.25
  @satellite_positions [
    {20_200_000.0, 0.0, 0.0},
    {0.0, 21_100_000.0, 0.0},
    {0.0, 0.0, 22_300_000.0},
    {-20_900_000.0, 19_700_000.0, 21_500_000.0},
    {18_600_000.0, -20_400_000.0, 23_100_000.0}
  ]

  test "default factories and stationary state preserve every core field by value" do
    assert PrecisePositioning.velocity_config() == %{minimum_observations: 4, robust: nil}
    assert PrecisePositioning.vmf_site_max_samples() == 8
    assert PrecisePositioning.vmf_site_single_sample_clamp_days() == 0.25
    assert PrecisePositioning.ppp_auto_init_strategy() == :reference

    assert PrecisePositioning.velocity_robust_config() == %{
             huber_k: 1.345,
             scale_floor_m_s: 0.05,
             max_outer: 2,
             outer_tol_m_s: 1.0e-6
           }

    assert PrecisePositioning.stationary_velocity_state({1, 2, 3}) == %{
             position_m: {1.0, 2.0, 3.0},
             velocity_m_s: {0.0, 0.0, 0.0},
             clock_drift_m_s: 0.0
           }
  end

  test "solves the independent exact range-rate geometry" do
    assert {:ok, solution} =
             PrecisePositioning.solve_velocity_least_squares(observations(), @receiver)

    assert vector_error(solution.velocity_m_s, @truth_velocity) < 1.0e-9
    assert abs(solution.clock_drift_m_s - @truth_clock_drift) < 1.0e-9
    assert solution.residual_rms_m_s < 1.0e-9
    assert solution.used_sats == ["G01", "G02", "G03", "G04", "G05"]
    assert solution.downweighted_sats == []
    assert solution.robust_iterations == 0
    assert solution.robust_scale_m_s == nil

    robust_config = %{PrecisePositioning.velocity_config() | robust: PrecisePositioning.velocity_robust_config()}

    assert {:ok, robust_solution} =
             PrecisePositioning.solve_velocity_least_squares(observations(), @receiver, robust_config)

    assert vector_error(robust_solution.velocity_m_s, @truth_velocity) < 1.0e-9
    assert robust_solution.robust_iterations == 1
    assert robust_solution.robust_scale_m_s == 0.05
  end

  test "range-rate predictions are structurally comparable values" do
    [observation, other | _] = observations()
    receiver = PrecisePositioning.stationary_velocity_state(@receiver)

    assert {:ok, first} = PrecisePositioning.predict_range_rate_m_s(observation, receiver)
    assert {:ok, equal} = PrecisePositioning.predict_range_rate_m_s(observation, receiver)
    assert {:ok, unequal} = PrecisePositioning.predict_range_rate_m_s(other, receiver)

    assert first == equal
    refute first == unequal
    assert first.los_unit == {1.0, 0.0, 0.0}
    assert first.range_rate_m_s == 0.0
  end

  test "refuses too few observations and malformed config with exact details" do
    assert {:error,
            %VelocitySolveError{
              kind: :too_few_observations,
              required: 4,
              actual: 3
            } = error} =
             PrecisePositioning.solve_velocity_least_squares(
               Enum.take(observations(), 3),
               @receiver
             )

    assert to_string(error) == "too few velocity observations: required 4, got 3"
    assert error == %{error | message: error.message}
    refute error == %{error | actual: 2}

    assert {:error, {:invalid_input, :velocity_config}} =
             PrecisePositioning.solve_velocity_least_squares(observations(), @receiver, %{})

    assert {:error, {:invalid_input, :velocity_observation}} =
             PrecisePositioning.solve_velocity_least_squares([%{}], @receiver)

    [first | rest] = observations()

    assert {:error,
            %VelocitySolveError{
              kind: :invalid_input,
              field: "velocity observation sigma_m_s",
              reason: "not positive"
            } = invalid} =
             PrecisePositioning.solve_velocity_least_squares(
               [%{first | sigma_m_s: 0.0} | rest],
               @receiver
             )

    assert to_string(invalid) ==
             "invalid velocity input velocity observation sigma_m_s: not positive"

    assert {:error, {:invalid_input, "satellite_id"}} =
             NIF.precise_positioning_solve_velocity_least_squares(
               [{"not-a-satellite", {1.0, 0.0, 0.0}, {0.0, 0.0, 0.0}, 0.0, 1.0, 0.0}],
               @receiver,
               {4, nil}
             )
  end

  defp observations do
    @satellite_positions
    |> Enum.with_index(1)
    |> Enum.map(fn {position, prn} ->
      los = unit(position)

      %{
        satellite_id: "G#{String.pad_leading(Integer.to_string(prn), 2, "0")}",
        satellite_position_m: position,
        satellite_velocity_m_s: {0.0, 0.0, 0.0},
        measured_range_rate_m_s: @truth_clock_drift - dot(los, @truth_velocity),
        sigma_m_s: 0.1,
        satellite_clock_drift_m_s: 0.0
      }
    end)
  end

  defp unit({x, y, z}) do
    norm = :math.sqrt(x * x + y * y + z * z)
    {x / norm, y / norm, z / norm}
  end

  defp dot({ax, ay, az}, {bx, by, bz}), do: ax * bx + ay * by + az * bz

  defp vector_error({ax, ay, az}, {bx, by, bz}) do
    :math.sqrt((ax - bx) ** 2 + (ay - by) ** 2 + (az - bz) ** 2)
  end
end
