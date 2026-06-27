defmodule Sidereon.TestSupport.LinearAlgebraTest do
  use ExUnit.Case, async: true

  alias Sidereon.TestSupport.LinearAlgebra

  test "correlated_normal_equations accumulates non-diagonal measurement covariance" do
    rows = [
      %{h: [1.0, 0.0], y: 10.0},
      %{h: [0.0, 1.0], y: 20.0}
    ]

    block = %{
      rows: rows,
      inverse_covariance: [
        [2.0, -1.0],
        [-1.0, 2.0]
      ]
    }

    assert LinearAlgebra.correlated_normal_equations([block], 2) ==
             {
               [
                 [2.0, -1.0],
                 [-1.0, 2.0]
               ],
               [0.0, 30.0]
             }
  end
end
