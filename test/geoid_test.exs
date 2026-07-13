defmodule Sidereon.GeoidTest do
  use ExUnit.Case, async: true

  alias Sidereon.Geoid

  setup_all do
    header =
      <<-90.0::float-big-64, -180.0::float-big-64, 0.25::float-big-64, 0.25::float-big-64, 721::signed-big-32,
        1440::signed-big-32>>

    bytes = header <> :binary.copy(<<0.0::float-big-32>>, 721 * 1440)
    bytes = put_gtx_sample(bytes, 360, 720, 1.0)
    bytes = put_gtx_sample(bytes, 360, 721, 2.0)
    bytes = put_gtx_sample(bytes, 361, 720, 4.0)
    bytes = put_gtx_sample(bytes, 361, 721, 8.0)
    assert {:ok, grid} = Geoid.from_proj_egm96_gtx(bytes)
    %{proj_gtx_bytes: bytes, proj_grid: grid}
  end

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
    assert {:ok, alias_grid} = Geoid.from_text(text)
    assert_in_delta Geoid.grid_undulation_deg(grid, 10.0, 20.0), 1.0, 1.0e-12
    assert_in_delta Geoid.grid_undulation_deg(alias_grid, 10.0, 20.0), 1.0, 1.0e-12
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

  test "PROJ EGM96 GTX loader rejects a truncated grid", %{proj_gtx_bytes: bytes} do
    assert {:error, reason} = Geoid.load_proj_egm96_gtx(binary_part(bytes, 0, byte_size(bytes) - 4))
    assert reason =~ "egm96_15.gtx"
  end

  test "PROJ vertical-grid query requires an explicit arithmetic mode", %{proj_grid: grid} do
    deg_to_rad = 0.017453292519943296
    lat_rad = 0.1875 * deg_to_rad
    lon_rad = 0.0625 * deg_to_rad

    assert {:ok, separate} =
             Geoid.grid_undulation_proj_rad(grid, lat_rad, lon_rad, :separate_multiply_add)

    assert {:ok, fused} = Geoid.grid_undulation_proj_rad(grid, lat_rad, lon_rad, :fused_multiply_add)
    assert_in_delta separate, 4.0625, 1.0e-12
    assert_in_delta fused, 4.0625, 1.0e-12
  end

  test "PROJ vertical-grid query returns typed coordinate errors", %{proj_grid: grid} do
    assert {:error, %Geoid.ProjVgridshiftError{kind: :coordinate_outside_grid, field: :latitude}} =
             Geoid.grid_undulation_proj_rad(grid, :math.pi(), 0.0, :fused_multiply_add)
  end

  defp put_gtx_sample(bytes, row, column, value) do
    offset = 40 + (row * 1440 + column) * 4
    <<prefix::binary-size(^offset), _old::binary-size(4), suffix::binary>> = bytes
    prefix <> <<value::float-big-32>> <> suffix
  end
end
