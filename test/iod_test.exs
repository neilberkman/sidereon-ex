defmodule Sidereon.IODTest do
  @moduledoc """
  Initial Orbit Determination tests.

  Reference values from Vallado's "Fundamentals of Astrodynamics" (2022)
  via the valladopy Python implementation.
  """
  use ExUnit.Case

  import Sidereon.TestHelpers, only: [assert_ulp: 4]

  # Vallado constants: RE = 6378.1363 km, MU = 398600.4415 km^3/s^2

  describe "Gibbs method (Algorithm 54)" do
    test "Example 7-3: coplanar position vectors" do
      # Three coplanar position vectors in ECI (km)
      r1 = {0.0, 0.0, 6378.1363}
      r2 = {0.0, -4464.696, -5102.509}
      r3 = {0.0, 5740.323, 3189.068}

      {v2, theta12, theta23, copa} = Sidereon.IOD.gibbs(r1, r2, r3)

      # Velocity at r2 (km/s)
      # Reference: valladopy gibbs() -> [0, 5.5311472050176125, -5.191806413494606]
      assert_ulp(elem(v2, 0), 0.0, 0, "v2_x")
      assert_ulp(elem(v2, 1), 5.5311472050176125, 0, "v2_y")
      assert_ulp(elem(v2, 2), -5.191806413494606, 0, "v2_z")

      # Angles between position vectors (degrees)
      assert_ulp(theta12 * 180 / :math.pi(), 138.81407085944375, 2, "theta12")
      assert_ulp(theta23 * 180 / :math.pi(), 160.24053069723146, 2, "theta23")

      # Coplanarity angle (should be 0 for coplanar vectors)
      assert_ulp(copa, 0.0, 0, "copa")
    end
  end

  describe "Herrick-Gibbs method (Algorithm 55)" do
    test "Example 7-4: closely-spaced observations" do
      r1 = {3419.85564, 6019.82602, 2784.60022}
      r2 = {2935.91195, 6326.18324, 2660.59584}
      r3 = {2434.95202, 6597.38674, 2521.52311}

      # Times as Julian day fractions (seconds from arbitrary epoch / 86400)
      jd1 = 0.0
      jd2 = (60.0 + 16.48) / 86400.0
      jd3 = (120.0 + 33.04) / 86400.0

      {v2, theta12, theta23, _copa} = Sidereon.IOD.hgibbs(r1, r2, r3, jd1, jd2, jd3)

      # Velocity at r2 (km/s)
      # Reference: valladopy hgibbs() -> [-6.441557227511062, 3.777559606719521, -1.7205675602414345]
      assert_ulp(elem(v2, 0), -6.441557227511062, 0, "v2_x")
      assert_ulp(elem(v2, 1), 3.777559606719521, 0, "v2_y")
      assert_ulp(elem(v2, 2), -1.7205675602414345, 0, "v2_z")

      # Angles (degrees)
      assert_ulp(theta12 * 180 / :math.pi(), 4.499996147374992, 2, "theta12")
      assert_ulp(theta23 * 180 / :math.pi(), 4.499998402168982, 2, "theta23")
    end
  end

  describe "Gauss angles-only method (Algorithm 52)" do
    test "Example 7-2: three optical sightings" do
      pi = :math.pi()
      deg2rad = fn d -> d * pi / 180.0 end

      # Three angular observations (RA, Dec in radians)
      # Site ECI positions (km)
      # Julian dates (split as whole + fraction)
      {r2, v2} =
        Sidereon.IOD.gauss(
          deg2rad.(18.667717),
          deg2rad.(35.664741),
          deg2rad.(36.996583),
          deg2rad.(0.939913),
          deg2rad.(45.025748),
          deg2rad.(67.886655),
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

      # Reference: valladopy gauss()
      # Gauss involves polynomial root finding + Halley iteration,
      # so we use 1e-12 relative tolerance (matching Vallado's test suite).
      assert_rel(elem(r2, 0), 6313.378130210396, "r2_x")
      assert_rel(elem(r2, 1), 5247.50563344895, "r2_y")
      assert_rel(elem(r2, 2), 6467.707164431651, "r2_z")
      assert_rel(elem(v2, 0), -4.185488280436629, "v2_x")
      assert_rel(elem(v2, 1), 4.7884929168898145, "v2_y")
      assert_rel(elem(v2, 2), 1.721714659663034, "v2_z")
    end
  end

  defp assert_rel(actual, expected, label) do
    rel = abs((actual - expected) / expected)

    assert rel < 1.0e-12,
           "#{label}: relative error #{:erlang.float_to_binary(rel, decimals: 3)} exceeds 1e-12"
  end
end
