defmodule Sidereon.GeoidTest do
  use ExUnit.Case, async: true

  alias Sidereon.Geoid

  test "built-in grid returns documented node undulations (radians)" do
    assert_in_delta Geoid.undulation(0.0, 0.0), 17.0, 1.0e-12
    assert_in_delta Geoid.undulation(0.0, 90.0 * :math.pi() / 180.0), -60.0, 1.0e-12
  end

  test "orthometric and ellipsoidal height conversions invert each other" do
    assert_in_delta Geoid.orthometric_height_m(117.0, 0.0, 0.0), 100.0, 1.0e-12
    assert_in_delta Geoid.ellipsoidal_height_m(100.0, 0.0, 0.0), 117.0, 1.0e-12
  end

  test "load_grid parses a text grid and interpolates" do
    text = """
    # coarse 2x3 regional grid
    # lat_min lon_min dlat dlon n_lat n_lon
    10.0 20.0 5.0 5.0 2 3
      1.0  2.0  3.0
      4.0  5.0  6.0
    """

    assert {:ok, grid} = Geoid.load_grid(text)
    assert_in_delta Geoid.grid_undulation_deg(grid, 10.0, 20.0), 1.0, 1.0e-12
    assert_in_delta Geoid.grid_undulation_deg(grid, 15.0, 30.0), 6.0, 1.0e-12
    # Cell center of the lower-left cell -> mean of its four corners.
    center = Geoid.grid_undulation_deg(grid, 12.5, 22.5)
    assert_in_delta center, (1.0 + 2.0 + 4.0 + 5.0) / 4.0, 1.0e-12
  end

  test "grid built from explicit samples bilinearly interpolates" do
    assert {:ok, grid} = Geoid.grid(0.0, 0.0, 10.0, 10.0, 2, 2, [1.0, 3.0, 5.0, 11.0])
    center = Geoid.grid_undulation_deg(grid, 5.0, 5.0)
    assert_in_delta center, (1.0 + 3.0 + 5.0 + 11.0) / 4.0, 1.0e-12
    assert_in_delta Geoid.grid_undulation_rad(grid, 0.0, 0.0), 1.0, 1.0e-12
  end

  test "load_grid rejects short data" do
    assert {:error, _reason} = Geoid.load_grid("0.0 0.0 1.0 1.0 2 2\n1.0 2.0 3.0\n")
  end
end
