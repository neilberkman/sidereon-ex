defmodule Sidereon.LambertTest do
  @moduledoc """
  Lambert problem solver tests.

  Reference values from Vallado's "Fundamentals of Astrodynamics" (2022)
  via the valladopy Python implementation. The Battin solver is iterative,
  so we use relative tolerance (1e-12) matching Vallado's test suite.
  """
  use ExUnit.Case

  # Vallado constants: RE = 6378.1363 km, MU = 398600.4415 km^3/s^2
  @re 6378.1363

  # Standard test inputs (Vallado Lambert examples)
  @r1 {2.5 * @re, 0.0, 0.0}
  @r2 {1.9151111 * @re, 1.6069690 * @re, 0.0}
  @v1 {0.0, 4.999792554221911, 0.0}
  @nrev 1
  @dtsec 92854.234

  # dm: 0=short, 1=long; de: 0=low, 1=high

  describe "Battin method (Algorithm 61)" do
    test "short way, high energy" do
      {v1t, v2t} = Sidereon.Lambert.solve(@r1, @r2, @v1, 0, 1, @nrev, @dtsec)

      assert_close(elem(v1t, 0), -0.8696153795282852, "v1t_x")
      assert_close(elem(v1t, 1), 6.3351545812502374, "v1t_y")
      assert_close(elem(v1t, 2), 0.0, "v1t_z")
      assert_close(elem(v2t, 0), -3.405994961791248, "v2t_x")
      assert_close(elem(v2t, 1), 5.41198791828363, "v2t_y")
      assert_close(elem(v2t, 2), 0.0, "v2t_z")
    end

    test "short way, low energy" do
      {v1t, v2t} = Sidereon.Lambert.solve(@r1, @r2, @v1, 0, 0, @nrev, @dtsec)

      assert_close(elem(v1t, 0), 5.832522716212579, "v1t_x")
      assert_close(elem(v1t, 1), 1.4319944881331306, "v1t_y")
      assert_close(elem(v2t, 0), -5.388439978490882, "v2t_x")
      assert_close(elem(v2t, 1), -2.652101898141935, "v2t_y")
    end

    test "long way, high energy" do
      {v1t, v2t} = Sidereon.Lambert.solve(@r1, @r2, @v1, 1, 1, @nrev, @dtsec)

      assert_close(elem(v1t, 0), -6.241103309400493, "v1t_x")
      assert_close(elem(v1t, 1), -1.351339299630816, "v1t_y")
      assert_close(elem(v2t, 0), 5.649586715490154, "v2t_x")
      assert_close(elem(v2t, 1), 2.976517897853268, "v2t_y")
    end

    test "long way, low energy" do
      {v1t, v2t} = Sidereon.Lambert.solve(@r1, @r2, @v1, 1, 0, @nrev, @dtsec)

      assert_close(elem(v1t, 0), 0.641119158614630, "v1t_x")
      assert_close(elem(v1t, 1), -5.957501823796459, "v1t_y")
      assert_close(elem(v2t, 0), 3.338282702263070, "v2t_x")
      assert_close(elem(v2t, 1), -4.975814585231199, "v2t_y")
    end
  end

  # Vallado uses 1e-12 relative tolerance for iterative solvers
  defp assert_close(actual, expected, label) when expected == 0.0 do
    assert abs(actual) < 1.0e-10, "#{label}: expected ~0, got #{actual}"
  end

  defp assert_close(actual, expected, label) do
    rel_err = abs((actual - expected) / expected)

    assert rel_err < 1.0e-12,
           "#{label}: relative error #{:erlang.float_to_binary(rel_err, decimals: 3)} exceeds 1e-12\n" <>
             "  got:      #{actual}\n  expected: #{expected}"
  end
end
