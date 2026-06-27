defmodule Sidereon.TestSupport.LambdaIlsBindingTest do
  use ExUnit.Case, async: true

  alias Sidereon.TestSupport.IntegerLeastSquares, as: ILS

  @opts %{radius_cycles: 1, candidate_limit: 200_000, ratio_threshold: 3.0}

  test "search/3 calls the LAMBDA NIF and decodes public metadata" do
    floats = %{"A00" => 0.3, "A01" => -0.4, "A02" => 1.2}

    covariance = [
      [0.5, 0.1, 0.05],
      [0.1, 0.5, 0.1],
      [0.05, 0.1, 0.5]
    ]

    assert {:ok, fixed, meta} = ILS.search(floats, covariance, @opts)

    assert fixed == %{"A00" => 0, "A01" => 0, "A02" => 1}
    assert meta.integer_method == :lambda
    assert meta.integer_status == :not_fixed
    assert is_float(meta.integer_best_score)
    assert is_float(meta.integer_second_best_score)
    assert is_float(meta.integer_ratio)
    assert meta.integer_candidates == 2

    assert meta.ambiguity_search.order == ["A00", "A01", "A02"]
    assert meta.ambiguity_search.float_cycles == floats
    assert length(meta.ambiguity_search.covariance_cycles) == 3
    assert length(meta.ambiguity_search.covariance_inverse_cycles) == 3
  end
end
