defmodule Sidereon.PublicTidesBodiesTest do
  use ExUnit.Case, async: true

  alias Sidereon.Tides.StationDisplacement
  alias Sidereon.Tides.StationTideConstants
  alias Sidereon.Tides.TideSystem

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

    assert {:ok, ^solid} =
             Sidereon.solid_earth_tide(@station, 2026, 5, 13, 0.0, sun, moon, constants: :conventions)

    assert {:ok, routine} =
             Sidereon.solid_earth_tide(@station, 2026, 5, 13, 0.0, sun, moon, constants: :iers_routine)

    assert finite_vec3?(routine)
    assert routine != solid

    assert {:error, {:invalid_option, :constants}} =
             Sidereon.solid_earth_tide(@station, 2026, 5, 13, 0.0, sun, moon, constants: :other)

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

  test "station displacement exposes components, constants, and UT1 validity" do
    position = %{position_ecef_m: @station}
    epoch = %{year: 2026, month: 5, day: 13, hour: 0, minute: 0, second: 0.0}

    assert {:ok, conventions} =
             Sidereon.Tides.station_tide_displacement(position, epoch,
               solid_earth_tide_constants: StationTideConstants.conventions()
             )

    assert conventions.valid
    assert is_nil(conventions.degraded)
    assert length(conventions.ecef_m) == 3
    assert length(conventions.solid_earth_tide_ecef_m) == 3

    assert {:ok, routine} =
             Sidereon.Tides.station_displacement_with_validity(position, epoch, :strict,
               solid_earth_tide_constants: :iers_routine
             )

    assert routine.valid
    assert length(routine.ecef_m) == 3
  end

  test "station displacement batch preserves row-local typed tide refusals" do
    position = %{position_ecef_m: @station}
    valid_epoch = %{year: 2026, month: 5, day: 13, hour: 0, minute: 0, second: 0.0}
    invalid_epoch = %{valid_epoch | month: 13}

    assert {:ok, [valid, error]} =
             Sidereon.Tides.station_displacement_batch(position, [valid_epoch, invalid_epoch])

    assert %StationDisplacement{valid: true} = valid
    # Core validates the civil date and time as one field.
    assert {:error, {:station_tide, %{variant: "invalid_input", field: "civil datetime", kind: "invalid_civil_date"}}} =
             error
  end

  test "station displacement batch preserves permissive UT1 degradation per row" do
    position = %{position_ecef_m: @station}
    covered_epoch = %{year: 2026, month: 5, day: 13, hour: 0, minute: 0, second: 0.0}
    future_epoch = %{year: 2035, month: 1, day: 1, hour: 0, minute: 0, second: 0.0}

    assert {:ok, [covered, degraded]} =
             Sidereon.Tides.station_displacement_batch_with_validity(
               position,
               [covered_epoch, future_epoch],
               :permissive
             )

    assert %StationDisplacement{valid: true, degraded: nil} = covered
    assert %StationDisplacement{valid: false, degraded: :after_coverage} = degraded
  end

  test "tide-system values are stable public selectors" do
    assert Sidereon.Tides.tide_system(TideSystem.zero_tide()) == :zero_tide
    assert TideSystem.tide_free() == :tide_free
    assert TideSystem.mean_tide() == :mean_tide
  end

  defp finite_vec3?({x, y, z}), do: finite_number?(x) and finite_number?(y) and finite_number?(z)

  defp finite_number?(value) when is_float(value), do: value - value == 0.0
  defp finite_number?(value) when is_integer(value), do: true
  defp finite_number?(_value), do: false

  defp norm({x, y, z}), do: :math.sqrt(x * x + y * y + z * z)
end
