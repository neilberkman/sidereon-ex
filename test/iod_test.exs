defmodule Sidereon.IODTest do
  @moduledoc """
  Initial-orbit-determination parity against the published Vallado examples.
  """
  use ExUnit.Case

  import Sidereon.TestHelpers, only: [assert_ulp: 4]

  test "Gibbs Example 7-3 velocity matches Vallado at zero ULP" do
    r1 = {0.0, 0.0, 6378.1363}
    r2 = {0.0, -4464.696, -5102.509}
    r3 = {0.0, 5740.323, 3189.068}

    {v2, theta12, theta23, copa} = Sidereon.IOD.gibbs(r1, r2, r3)

    assert_ulp(elem(v2, 0), 0.0, 0, "v2_x")
    assert_ulp(elem(v2, 1), 5.5311472050176125, 0, "v2_y")
    assert_ulp(elem(v2, 2), -5.191806413494606, 0, "v2_z")
    assert_ulp(theta12 * 180.0 / :math.pi(), 138.81407085944375, 2, "theta12")
    assert_ulp(theta23 * 180.0 / :math.pi(), 160.24053069723146, 2, "theta23")
    assert_ulp(copa, 0.0, 0, "copa")
  end

  test "Herrick-Gibbs Example 7-4 velocity matches Vallado at zero ULP" do
    r1 = {3419.85564, 6019.82602, 2784.60022}
    r2 = {2935.91195, 6326.18324, 2660.59584}
    r3 = {2434.95202, 6597.38674, 2521.52311}
    jd1 = 0.0
    jd2 = (60.0 + 16.48) / 86_400.0
    jd3 = (120.0 + 33.04) / 86_400.0

    {v2, theta12, theta23, _copa} = Sidereon.IOD.hgibbs(r1, r2, r3, jd1, jd2, jd3)

    assert_ulp(elem(v2, 0), -6.441557227511062, 0, "v2_x")
    assert_ulp(elem(v2, 1), 3.777559606719521, 0, "v2_y")
    assert_ulp(elem(v2, 2), -1.7205675602414345, 0, "v2_z")
    assert_ulp(theta12 * 180.0 / :math.pi(), 4.499996147374992, 2, "theta12")
    assert_ulp(theta23 * 180.0 / :math.pi(), 4.499998402168982, 2, "theta23")
  end

  test "Gauss angles-only Example 7-2 matches Vallado" do
    radians = fn degrees -> degrees * :math.pi() / 180.0 end

    {r2, v2} =
      Sidereon.IOD.gauss(
        radians.(18.667717),
        radians.(35.664741),
        radians.(36.996583),
        radians.(0.939913),
        radians.(45.025748),
        radians.(67.886655),
        2_456_159.5,
        0.4864351851851852,
        2_456_159.5,
        0.49199074074074073,
        2_456_159.5,
        0.4947685185185185,
        {4054.881, 2748.195, 4074.237},
        {3956.224, 2888.232, 4074.364},
        {3905.073, 2956.935, 4074.430}
      )

    assert_relative(r2, {6313.378130210396, 5247.50563344895, 6467.707164431651}, "position")
    assert_relative(v2, {-4.185488280436629, 4.7884929168898145, 1.721714659663034}, "velocity")
  end

  defp assert_relative(actual, expected, label) do
    for axis <- 0..2 do
      got = elem(actual, axis)
      want = elem(expected, axis)
      relative_error = abs((got - want) / want)

      assert relative_error < 1.0e-12,
             "#{label}[#{axis}]: relative error #{relative_error} exceeds 1e-12"
    end
  end
end
