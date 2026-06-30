defmodule Sidereon.GNSS.GeometryDopConventionTest do
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.Geometry

  # Four unit line-of-sight directions with a spread that yields a well-posed
  # geometry, plus unit weights.
  @rows [
    {{0.0, 0.0, 1.0}, 1.0},
    {{0.6, 0.0, 0.8}, 1.0},
    {{-0.6, 0.0, 0.8}, 1.0},
    {{0.0, 0.6, 0.8}, 1.0}
  ]

  @lat_45 :math.pi() / 4.0

  test "both conventions succeed and agree on GDOP/PDOP/TDOP" do
    assert {:ok, geodetic} = Geometry.dop_with_convention(@rows, @lat_45, 0.0, :geodetic_normal)
    assert {:ok, geocentric} = Geometry.dop_with_convention(@rows, @lat_45, 0.0, :geocentric_radial)

    # GDOP/PDOP/TDOP are rotation invariant, identical between conventions.
    assert_in_delta geodetic.gdop, geocentric.gdop, 1.0e-12
    assert_in_delta geodetic.pdop, geocentric.pdop, 1.0e-12
    assert_in_delta geodetic.tdop, geocentric.tdop, 1.0e-12

    # Only the horizontal/vertical split changes (by a small amount off the
    # equator); all scalars stay finite and positive.
    for dop <- [geodetic, geocentric], scalar <- [dop.gdop, dop.pdop, dop.hdop, dop.vdop, dop.tdop] do
      assert is_float(scalar) and scalar > 0.0
    end
  end

  test "at the equator the two conventions coincide" do
    assert {:ok, geodetic} = Geometry.dop_with_convention(@rows, 0.0, 0.0, :geodetic_normal)
    assert {:ok, geocentric} = Geometry.dop_with_convention(@rows, 0.0, 0.0, :geocentric_radial)
    assert_in_delta geodetic.hdop, geocentric.hdop, 1.0e-9
    assert_in_delta geodetic.vdop, geocentric.vdop, 1.0e-9
  end

  test "defaults to the geodetic-normal convention" do
    assert {:ok, default} = Geometry.dop_with_convention(@rows, @lat_45, 0.0)
    assert {:ok, explicit} = Geometry.dop_with_convention(@rows, @lat_45, 0.0, :geodetic_normal)
    assert default == explicit
  end

  test "fewer than four satellites is a typed error" do
    rows = Enum.take(@rows, 3)
    assert {:error, :too_few_satellites} = Geometry.dop_with_convention(rows, @lat_45, 0.0)
  end
end
