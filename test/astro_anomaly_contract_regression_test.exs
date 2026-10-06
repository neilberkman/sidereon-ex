defmodule Sidereon.Astro.AnomalyContractRegressionTest do
  use ExUnit.Case, async: true

  alias Sidereon.Astro.Anomaly
  alias Sidereon.Astro.Equinoctial
  alias Sidereon.OrbitalElements

  @undefined_angles [:raan, :argp, :nu, :arglat, :lonper]

  test "undefined classical angles remain nil across shared native conversions" do
    assert {:ok, before} = OrbitalElements.rv2coe({1.0, 0.0, 0.0}, {0.0, 1.0, 0.0}, 1.0)
    assert before.orbit_type == :circular_equatorial
    assert Enum.all?(@undefined_angles, &(Map.fetch!(before, &1) == nil))

    assert {:ok, propagated} = Anomaly.propagate_kepler(before, 0.0, 1.0)
    assert Enum.all?(@undefined_angles, &(Map.fetch!(propagated, &1) == nil))
    assert propagated.truelon == before.truelon

    # The same classical-element decoder feeds both equinoctial families.
    assert {:ok, equinoctial} = Equinoctial.coe2eq(before)
    assert {:ok, modified} = Equinoctial.coe2mee(before)
    assert is_float(equinoctial.lambda)
    assert is_float(modified.l)
  end
end
