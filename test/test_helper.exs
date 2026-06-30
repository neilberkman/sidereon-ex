# Verification-fixture vocabulary convention:
#   :skyfield_parity == bucket (a): hex-captured Skyfield/ERFA 0-ULP references,
#     excluded by default (run with --include skyfield_parity).
#   Generated reference-fixture (golden) tests are bucket (b): they load a
#     committed parity/generator *_golden.json and run by default (hermetic, fast).
#   Known-truth round-trip tests are bucket (c): self-synthesized truth, no tag.
#   :local_data == large/licensed local corpora and toolchains, excluded by default.
ExUnit.start(exclude: [:skyfield_parity, :spk_file, :celestrak, :network, :local_data])

defmodule Sidereon.TestHelpers do
  @moduledoc false

  def ulp_distance(a, b) do
    <<ia::signed-integer-64>> = <<a::float-64>>
    <<ib::signed-integer-64>> = <<b::float-64>>
    abs(ia - ib)
  end

  def assert_ulp(actual, expected, max_ulp, label) do
    ulp = ulp_distance(actual, expected)

    ExUnit.Assertions.assert(
      ulp <= max_ulp,
      "#{label}: expected <= #{max_ulp} ULP, got #{ulp}"
    )
  end

  def hex_to_float(hex_string) do
    {neg, rest} =
      case hex_string do
        "-0x" <> r -> {true, r}
        "0x" <> r -> {false, r}
      end

    [mantissa_str, exp_str] = String.split(rest, "p")
    [int_part, frac_part] = String.split(mantissa_str, ".")
    exp = String.to_integer(exp_str)

    full_hex = int_part <> frac_part
    mantissa_int = String.to_integer(full_hex, 16)
    frac_bits = String.length(frac_part) * 4

    value = mantissa_int * :math.pow(2.0, exp - frac_bits)
    if neg, do: -value, else: value
  end
end
