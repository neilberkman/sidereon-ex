defmodule Sidereon.TestSupport.IntegerLeastSquaresTest do
  use ExUnit.Case, async: true

  alias Sidereon.TestSupport.IntegerLeastSquares
  alias Sidereon.TestSupport.LinearAlgebra

  test "bounded search can choose a non-rounded optimum and report the runner-up" do
    float_cycles = %{"A" => 0.49, "B" => -0.49}

    covariance = [
      [1.0, 0.9],
      [0.9, 1.0]
    ]

    opts = %{radius_cycles: 1, ratio_threshold: 3.0, candidate_limit: 100}

    assert {:ok, fixed, meta} = IntegerLeastSquares.bounded_search(float_cycles, covariance, opts)
    assert fixed != coordinate_round(float_cycles)
    assert {fixed, meta.integer_best_score} == enumerated_best(float_cycles, covariance, 1)
    assert meta.integer_status == :not_fixed
    assert meta.ambiguity_search.order == ["A", "B"]
  end

  test "a missing runner-up candidate cannot pass the ratio test" do
    float_cycles = %{"A" => 0.2}
    covariance = [[0.0001]]
    opts = %{radius_cycles: 0, ratio_threshold: 3.0, candidate_limit: 100}

    assert {:ok, %{"A" => 0}, meta} =
             IntegerLeastSquares.bounded_search(float_cycles, covariance, opts)

    assert meta.integer_second_best_score == nil
    assert meta.integer_ratio == 0.0
    assert meta.integer_status == :not_fixed
  end

  describe "malformed-dimension inputs are rejected (no panic, no silent submatrix)" do
    @opts %{radius_cycles: 1, ratio_threshold: 3.0, candidate_limit: 100}

    test "undersized covariance" do
      # 2 ambiguities, 1x1 covariance: must not panic / return :nif_panicked.
      f = %{"A" => 0.1, "B" => 0.2}
      assert {:error, {:invalid_dimensions, 2, 1}} = IntegerLeastSquares.search(f, [[1.0]], @opts)

      assert {:error, {:invalid_dimensions, 2, 1}} =
               IntegerLeastSquares.bounded_search(f, [[1.0]], @opts)
    end

    test "oversized covariance" do
      # 1 ambiguity, 2x2 covariance: must not silently use a submatrix.
      f = %{"A" => 0.1}
      cov = [[1.0, 0.0], [0.0, 1.0]]
      assert {:error, {:invalid_dimensions, 1, 2}} = IntegerLeastSquares.search(f, cov, @opts)

      assert {:error, {:invalid_dimensions, 1, 2}} =
               IntegerLeastSquares.bounded_search(f, cov, @opts)
    end

    test "ragged covariance (square count, wrong row width)" do
      f = %{"A" => 0.1, "B" => 0.2}
      cov = [[1.0, 0.0], [0.0]]
      assert {:error, {:invalid_dimensions, 2, 1}} = IntegerLeastSquares.search(f, cov, @opts)

      assert {:error, {:invalid_dimensions, 2, 1}} =
               IntegerLeastSquares.bounded_search(f, cov, @opts)
    end

    test "non-list covariance row" do
      f = %{"A" => 0.1, "B" => 0.2}
      cov = [[1.0, 0.0], :bad_row]

      assert {:error, {:invalid_dimensions, 2, :non_list}} =
               IntegerLeastSquares.search(f, cov, @opts)

      assert {:error, {:invalid_dimensions, 2, :non_list}} =
               IntegerLeastSquares.bounded_search(f, cov, @opts)
    end

    test "empty input" do
      assert {:error, {:invalid_dimensions, 0, 0}} = IntegerLeastSquares.search(%{}, [], @opts)

      assert {:error, {:invalid_dimensions, 0, 0}} =
               IntegerLeastSquares.bounded_search(%{}, [], @opts)
    end
  end

  defp coordinate_round(float_cycles) do
    Map.new(float_cycles, fn {id, value} -> {id, round(value)} end)
  end

  defp enumerated_best(float_cycles, covariance, radius) do
    ids = float_cycles |> Map.keys() |> Enum.sort()
    floats = Enum.map(ids, &Map.fetch!(float_cycles, &1))
    rounded = Enum.map(floats, &round/1)
    {:ok, q_inv} = LinearAlgebra.invert_matrix(covariance)

    candidates =
      for a <- (Enum.at(rounded, 0) - radius)..(Enum.at(rounded, 0) + radius),
          b <- (Enum.at(rounded, 1) - radius)..(Enum.at(rounded, 1) + radius) do
        cycles = [a, b]
        score = quadratic_score(floats, cycles, q_inv)
        {score, Map.new(Enum.zip(ids, cycles))}
      end

    {score, fixed} =
      Enum.min_by(candidates, fn {score, fixed} ->
        {score, Enum.map(ids, &Map.fetch!(fixed, &1))}
      end)

    {fixed, score}
  end

  defp quadratic_score(float_cycles, fixed_cycles, q_inv) do
    deltas =
      fixed_cycles
      |> Enum.zip(float_cycles)
      |> Enum.map(fn {z, a} -> a - z end)

    Enum.reduce(0..1, 0.0, fn i, acc ->
      Enum.reduce(0..1, acc, fn j, inner ->
        inner + Enum.at(deltas, i) * (q_inv |> Enum.at(i) |> Enum.at(j)) * Enum.at(deltas, j)
      end)
    end)
  end
end
