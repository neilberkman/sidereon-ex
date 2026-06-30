defmodule Sidereon.LeastSquaresTest do
  use ExUnit.Case, async: true

  alias Sidereon.LeastSquares
  alias Sidereon.LeastSquares.{DropOneReport, Result}

  # The bit-exact-vs-SciPy parity backend (host LAPACK / numpy BLAS) is pinned to
  # Linux x86_64 and additionally needs the LAPACK path env var; the structural
  # solves on the in-crate nalgebra backend run everywhere.
  @linux_x86 :os.type() == {:unix, :linux} and
               :erlang.system_info(:system_architecture)
               |> List.to_string()
               |> String.contains?("x86_64")

  @lapack_parity_skip (cond do
                         not @linux_x86 ->
                           "bit-exact LAPACK parity is pinned to Linux x86_64"

                         System.get_env("TRUST_REGION_LEAST_SQUARES_LAPACK_PATH") == nil ->
                           "set TRUST_REGION_LEAST_SQUARES_LAPACK_PATH for the LAPACK parity backend"

                         true ->
                           false
                       end)

  describe "linear least squares" do
    test "recovers the exact solution of an overdetermined consistent system" do
      # rows [1, t] so x = [intercept, slope]; data lies exactly on y = 4 + 2 t.
      a = [[1.0, 1.0], [1.0, 2.0], [1.0, 3.0]]
      b = [6.0, 8.0, 10.0]

      assert {:ok, %Result{x: [intercept, slope], cost: cost, success: true} = result} =
               LeastSquares.least_squares(%{kind: :linear, a: a, b: b})

      assert_in_delta intercept, 4.0, 1.0e-9
      assert_in_delta slope, 2.0, 1.0e-9
      assert_in_delta cost, 0.0, 1.0e-12
      assert length(result.jacobian) == 3
      assert Enum.all?(result.jacobian, &(length(&1) == 2))
    end
  end

  describe "polynomial fit" do
    test "recovers a degree-2 polynomial's coefficients" do
      t = [-2.0, -1.0, 0.0, 1.0, 2.0, 3.0]
      # y = 1 + 2 t + 3 t^2, coefficients lowest-order first.
      y = Enum.map(t, fn ti -> 1.0 + 2.0 * ti + 3.0 * ti * ti end)

      assert {:ok, %Result{x: [c0, c1, c2]}} =
               LeastSquares.least_squares(%{kind: :polynomial, degree: 2, t: t, y: y})

      assert_in_delta c0, 1.0, 1.0e-7
      assert_in_delta c1, 2.0, 1.0e-7
      assert_in_delta c2, 3.0, 1.0e-7
    end
  end

  describe "exponential fit" do
    test "recovers [amp, rate, offset]" do
      t = [0.0, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0]
      # y = 2 exp(0.5 t) + 1.
      y = Enum.map(t, fn ti -> 2.0 * :math.exp(0.5 * ti) + 1.0 end)

      assert {:ok, %Result{x: [amp, rate, offset]}} =
               LeastSquares.least_squares(%{kind: :exponential, t: t, y: y},
                 x0: [1.5, 0.4, 0.5]
               )

      assert_in_delta amp, 2.0, 1.0e-4
      assert_in_delta rate, 0.5, 1.0e-4
      assert_in_delta offset, 1.0, 1.0e-4
    end
  end

  describe "options and error mapping" do
    test "a robust loss is accepted and still recovers a clean fit" do
      a = [[1.0, 1.0], [1.0, 2.0], [1.0, 3.0], [1.0, 4.0]]
      b = [3.0, 5.0, 7.0, 9.0]

      assert {:ok, %Result{x: [intercept, slope]}} =
               LeastSquares.least_squares(%{kind: :linear, a: a, b: b},
                 loss: :soft_l1,
                 f_scale: 1.0
               )

      assert_in_delta intercept, 1.0, 1.0e-6
      assert_in_delta slope, 2.0, 1.0e-6
    end

    test "an underdetermined system (m < n) surfaces a typed error" do
      a = [[1.0, 2.0, 3.0]]
      b = [1.0]

      assert {:error, :insufficient_rows} =
               LeastSquares.least_squares(%{kind: :linear, a: a, b: b})
    end

    test "an unknown loss is rejected before the NIF" do
      a = [[1.0, 1.0], [1.0, 2.0], [1.0, 3.0]]
      b = [6.0, 8.0, 10.0]
      assert {:error, :invalid_loss} = LeastSquares.least_squares(%{kind: :linear, a: a, b: b}, loss: :bogus)
    end
  end

  describe "leave-one-out (drop-one) RAIM/FDE" do
    test "flags the row whose removal moves the optimum cost the most" do
      # A clean line y = 2 t with one corrupted sample at t = 3.
      t = [0.0, 1.0, 2.0, 3.0, 4.0, 5.0]
      y = [0.0, 2.0, 4.0, 99.0, 8.0, 10.0]

      assert {:ok, %DropOneReport{base: base, drops: drops, cost_delta: cost_delta}} =
               LeastSquares.least_squares_drop_one(%{kind: :polynomial, degree: 1, t: t, y: y})

      assert %Result{} = base
      assert length(drops) == length(t)
      assert length(cost_delta) == length(t)

      # Dropping the outlier (index 3) reduces the cost the most (most negative
      # delta), so it is the argmin of cost_delta.
      worst = Enum.find_index(cost_delta, &(&1 == Enum.min(cost_delta)))
      assert worst == 3
    end
  end

  describe "LAPACK backend availability" do
    @describetag skip:
                   if(System.get_env("TRUST_REGION_LEAST_SQUARES_LAPACK_PATH") == nil,
                     do: false,
                     else: "LAPACK path is configured, so the backend probe succeeds"
                   )

    test "the lapack backend without a configured LAPACK path is a typed error" do
      t = [-2.0, -1.0, 0.0, 1.0, 2.0, 3.0]
      y = Enum.map(t, fn ti -> 1.0 + 2.0 * ti + 3.0 * ti * ti end)

      assert {:error, :lapack_unavailable} =
               LeastSquares.least_squares(%{kind: :polynomial, degree: 2, t: t, y: y}, backend: :lapack)
    end

    test "the drop-one lapack backend without a configured LAPACK path is a typed error" do
      t = [-2.0, -1.0, 0.0, 1.0, 2.0, 3.0]
      y = Enum.map(t, fn ti -> 1.0 + 2.0 * ti + 3.0 * ti * ti end)

      assert {:error, :lapack_unavailable} =
               LeastSquares.least_squares_drop_one(%{kind: :polynomial, degree: 2, t: t, y: y},
                 backend: :lapack
               )
    end
  end

  describe "LAPACK parity backend (Linux x86_64, env-gated)" do
    @tag skip: @lapack_parity_skip
    test "the bit-exact backend recovers the analytic optimum SciPy returns" do
      t = [-2.0, -1.0, 0.0, 1.0, 2.0, 3.0]
      y = Enum.map(t, fn ti -> 1.0 + 2.0 * ti + 3.0 * ti * ti end)

      assert {:ok, %Result{x: [c0, c1, c2]}} =
               LeastSquares.least_squares(%{kind: :polynomial, degree: 2, t: t, y: y},
                 backend: :lapack
               )

      # The fit is exactly solvable, so the host-LAPACK trajectory lands on the
      # same machine-precision optimum SciPy's least_squares reports.
      assert_in_delta c0, 1.0, 1.0e-12
      assert_in_delta c1, 2.0, 1.0e-12
      assert_in_delta c2, 3.0, 1.0e-12
    end
  end
end
