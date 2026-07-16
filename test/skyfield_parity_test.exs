defmodule Sidereon.SkyfieldParityTest do
  @moduledoc """
  Independent, bit-exact frame-transform parity against Skyfield 1.49.

  The constants were captured from Skyfield with `float.hex()` and were not
  emitted by Sidereon.
  """
  use ExUnit.Case

  @moduletag :skyfield_parity

  @teme_state %{
    position: {3700.2112112039954, 2015.9122181206055, 5309.513078070448},
    velocity: {-3.398428894395407, 6.869656830559572, -0.239850181126689}
  }
  @gcrs_position {3717.924020501305, 2000.4098588111344, 5302.998734625479}
  @gcrs_velocity {-3.3703926968570035, 6.883668453605744, -0.23365298865595419}
  @itrs_position {-1205.4562194588198, 4037.6156802815913, 5309.513078070445}
  @epoch {{2018, 7, 4}, {0, 0, 0}}

  test "TEME to GCRS matches Skyfield 1.49 at zero ULP" do
    result = Sidereon.teme_to_gcrs(@teme_state, @epoch, skyfield_compat: true)

    assert_tuple_bits(result.position, @gcrs_position, "GCRS position")
    assert_tuple_bits(result.velocity, @gcrs_velocity, "GCRS velocity")
  end

  test "GCRS to ITRS matches Skyfield 1.49 at zero ULP" do
    result =
      Sidereon.Coordinates.gcrs_to_itrs(
        %{position: @gcrs_position},
        @epoch,
        skyfield_compat: true
      )

    assert_tuple_bits(result, @itrs_position, "ITRS position")
  end

  defp assert_tuple_bits(actual, expected, label) do
    for axis <- 0..2 do
      Sidereon.TestHelpers.assert_ulp(
        elem(actual, axis),
        elem(expected, axis),
        0,
        "#{label}[#{axis}]"
      )
    end
  end
end
