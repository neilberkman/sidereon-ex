defmodule Sidereon.PublicTidesBodiesTest do
  use ExUnit.Case, async: true

  @station {4_075_578.385, 931_852.890, 4_801_570.154}
  @epoch_us DateTime.to_unix(~U[2026-05-13 00:00:00Z], :microsecond)

  test "public Sun/Moon vector helpers return one vector per epoch" do
    assert {:ok, eci} = Sidereon.sun_moon_eci([@epoch_us])
    assert {:ok, ecef} = Sidereon.sun_moon_ecef([@epoch_us])

    assert [sun_eci] = eci.sun
    assert [moon_eci] = eci.moon
    assert [sun_ecef] = ecef.sun
    assert [moon_ecef] = ecef.moon

    assert finite_vec3?(sun_eci)
    assert finite_vec3?(moon_eci)
    assert finite_vec3?(sun_ecef)
    assert finite_vec3?(moon_ecef)
    assert norm(sun_eci) > norm(moon_eci)
    assert norm(sun_ecef) > norm(moon_ecef)
  end

  test "public station tide helpers delegate to core kernels" do
    assert {:ok, %{sun: [sun], moon: [moon]}} = Sidereon.sun_moon_ecef([@epoch_us])

    assert {:ok, solid} =
             Sidereon.solid_earth_tide(@station, 2026, 5, 13, 0.0, sun, moon)

    assert finite_vec3?(solid)
    assert norm(solid) < 1.0

    assert {:ok, pole} =
             Sidereon.solid_earth_pole_tide(@station, 2026, 5, 13, 0.0, 0.05, -0.12)

    assert finite_vec3?(pole)
    assert norm(pole) < 0.1

    zeros = for _ <- 1..3, do: List.duplicate(0.0, 11)

    assert {:ok, ocean} =
             Sidereon.ocean_tide_loading(@station, 2026, 5, 13, 0.0, zeros, zeros)

    assert finite_vec3?(ocean)
    assert norm(ocean) == 0.0
  end

  defp finite_vec3?({x, y, z}), do: finite_number?(x) and finite_number?(y) and finite_number?(z)

  defp finite_number?(value) when is_float(value), do: value - value == 0.0
  defp finite_number?(value) when is_integer(value), do: true
  defp finite_number?(_value), do: false

  defp norm({x, y, z}), do: :math.sqrt(x * x + y * y + z * z)
end
