defmodule Sidereon.GeoidEgm96Test do
  use ExUnit.Case, async: true

  alias Sidereon.Geoid

  @deg :math.pi() / 180.0

  test "egm96 undulation is a finite metre-class value" do
    n = Geoid.egm96_undulation(0.0, 0.0)
    assert is_float(n)
    # The geoid undulation stays within roughly +/- 110 m worldwide.
    assert abs(n) < 120.0
  end

  test "egm96 orthometric and ellipsoidal conversions invert each other" do
    lat = 45.0 * @deg
    lon = 10.0 * @deg
    h = 250.0
    ortho = Geoid.egm96_orthometric_height_m(h, lat, lon)
    assert_in_delta Geoid.egm96_ellipsoidal_height_m(ortho, lat, lon), h, 1.0e-9
    # H = h - N by construction.
    assert_in_delta h - ortho, Geoid.egm96_undulation(lat, lon), 1.0e-12
  end

  test "the genuine egm96 model differs from the coarse built-in grid" do
    lat = 30.0 * @deg
    lon = 200.0 * @deg
    refute_in_delta Geoid.egm96_undulation(lat, lon), Geoid.undulation(lat, lon), 1.0e-6
  end
end
