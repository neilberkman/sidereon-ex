defmodule Sidereon.LambertTest do
  @moduledoc """
  Lambert binding parity against the published Vallado reference case.
  """
  use ExUnit.Case

  test "Battin short-way high-energy case matches Vallado" do
    earth_radius_km = 6378.1363
    r1 = {2.5 * earth_radius_km, 0.0, 0.0}
    r2 = {1.9151111 * earth_radius_km, 1.6069690 * earth_radius_km, 0.0}
    v1 = {0.0, 4.999792554221911, 0.0}

    {departure, arrival} = Sidereon.Lambert.solve(r1, r2, v1, 0, 1, 1, 92_854.234)

    assert_relative(departure, {-0.8696153795282852, 6.3351545812502374, 0.0}, "departure")
    assert_relative(arrival, {-3.405994961791248, 5.41198791828363, 0.0}, "arrival")
  end

  defp assert_relative(actual, expected, label) do
    for axis <- 0..2 do
      got = elem(actual, axis)
      want = elem(expected, axis)
      scale = max(abs(want), 1.0)

      assert abs(got - want) <= 1.0e-12 * scale,
             "#{label}[#{axis}]: got #{got}, expected #{want}"
    end
  end
end
