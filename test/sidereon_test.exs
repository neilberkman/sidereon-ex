defmodule SidereonTest do
  use ExUnit.Case

  test "teme_to_gcrs returns position and velocity" do
    teme = %{
      position: {3700.211211203995390, 2015.912218120605530, 5309.513078070447591},
      velocity: {-3.398428894395407, 6.869656830559572, -0.239850181126689}
    }

    gcrs = Sidereon.teme_to_gcrs(teme, {{2018, 7, 4}, {0, 0, 0}})

    assert is_tuple(gcrs.position)
    assert is_tuple(gcrs.velocity)
    assert tuple_size(gcrs.position) == 3

    # Smoke check: magnitude preserved by rotation
    teme_mag =
      :math.sqrt(
        elem(teme.position, 0) ** 2 + elem(teme.position, 1) ** 2 + elem(teme.position, 2) ** 2
      )

    gcrs_mag =
      :math.sqrt(
        elem(gcrs.position, 0) ** 2 + elem(gcrs.position, 1) ** 2 + elem(gcrs.position, 2) ** 2
      )

    assert_in_delta teme_mag, gcrs_mag, 0.01
  end
end
