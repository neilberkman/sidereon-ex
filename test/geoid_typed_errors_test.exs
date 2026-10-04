defmodule Sidereon.GeoidTypedErrorsTest do
  use ExUnit.Case, async: true

  alias Sidereon.Geoid

  test "direct grid constructors retain typed dimensions and spacing errors" do
    assert {:error, %Geoid.GridError{kind: :invalid_dimensions, expected: 4, found: 3} = dimensions} =
             Geoid.grid(0.0, 0.0, 1.0, 1.0, 2, 2, [1.0, 2.0, 3.0])

    assert dimensions.expected == 4
    assert dimensions.found == 3

    assert {:error, %Geoid.GridError{kind: :invalid_spacing, field: "dlat"} = spacing} =
             Geoid.grid(0.0, 0.0, 0.0, 1.0, 2, 2, [1.0, 2.0, 3.0, 4.0])

    assert spacing.field == "dlat"
  end

  test "direct DAC loading retains the core parse reason" do
    assert {:error,
            %Geoid.GridError{
              kind: :parse,
              reason: "EGM96 WW15MGH.DAC must be 2076480 bytes (721 x 1440 big-endian int16), got 0"
            } = retained} = Geoid.load_egm96_dac(<<>>)

    assert retained.kind == :parse
  end

  test "a valid direct grid remains usable after a later typed refusal" do
    assert {:ok, grid} = Geoid.grid(0.0, 0.0, 1.0, 1.0, 2, 2, [1.0, 2.0, 3.0, 4.0])

    assert {:error, %Geoid.GridError{kind: :invalid_dimensions}} =
             Geoid.grid(0.0, 0.0, 1.0, 1.0, 2, 2, [1.0, 2.0, 3.0])

    assert Geoid.grid_undulation_deg(grid, 0.0, 0.0) == 1.0
  end

  test "unsupported EGM2008 spacing remains a binding-validation string" do
    assert {:error, "unsupported EGM2008 spacing unknown-grid"} =
             Geoid.load_egm2008_raster(<<>>, "unknown-grid")
  end
end
