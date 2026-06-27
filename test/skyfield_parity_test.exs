defmodule Sidereon.SkyfieldParityTest do
  @moduledoc """
  Bit-exact (0 ULP) parity test against Skyfield's TEME → GCRS transformation.

  Tagged :skyfield_parity — skipped by default. Run with:
    mix test --include skyfield_parity
  """
  use ExUnit.Case

  @moduletag :skyfield_parity

  @teme_state %{
    position: {3700.211211203995390, 2015.912218120605530, 5309.513078070447591},
    velocity: {-3.398428894395407, 6.869656830559572, -0.239850181126689}
  }

  # Authoritative Skyfield reference captured via float.hex():
  # px: 0x1.d0bd9193713e1p+11  py: 0x1.f41a3b2073733p+10  pz: 0x1.4b6ffad1289d1p+12
  # vx: -0x1.af690723d6cb1p+1  vy: 0x1.b88e06212f969p+2   vz: -0x1.de8575471eaf0p-3
  @expected_position {3717.924020501305, 2000.4098588111344, 5302.998734625479}
  @expected_velocity {-3.3703926968570035, 6.883668453605744, -0.23365298865595419}

  test "direct reference case matches Skyfield at 0 ULP" do
    result = Sidereon.teme_to_gcrs(@teme_state, {{2018, 7, 4}, {0, 0, 0}}, skyfield_compat: true)

    for i <- 0..2 do
      actual_p = elem(result.position, i)
      expected_p = elem(@expected_position, i)
      ulp_p = ulp_distance(actual_p, expected_p)

      assert ulp_p == 0,
             "position[#{i}]: expected 0 ULP, got #{ulp_p} " <>
               "(actual=#{float_hex(actual_p)} expected=#{float_hex(expected_p)})"

      actual_v = elem(result.velocity, i)
      expected_v = elem(@expected_velocity, i)
      ulp_v = ulp_distance(actual_v, expected_v)

      assert ulp_v == 0,
             "velocity[#{i}]: expected 0 ULP, got #{ulp_v} " <>
               "(actual=#{float_hex(actual_v)} expected=#{float_hex(expected_v)})"
    end
  end

  defp ulp_distance(a, b) do
    <<ia::signed-integer-64>> = <<a::float-64>>
    <<ib::signed-integer-64>> = <<b::float-64>>
    abs(ia - ib)
  end

  defp float_hex(val) do
    <<sign::1, exp::11, mantissa::52>> = <<val::float-64>>
    sign_str = if sign == 1, do: "-", else: ""
    biased_exp = exp - 1023
    hex_m = String.downcase(String.pad_leading(Integer.to_string(mantissa, 16), 13, "0"))
    "#{sign_str}0x1.#{hex_m}p#{if biased_exp >= 0, do: "+", else: ""}#{biased_exp}"
  end
end
