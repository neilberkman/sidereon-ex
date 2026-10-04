defmodule Sidereon.TerrainTypedErrorsTest do
  use ExUnit.Case, async: true

  alias Sidereon.Geoid
  alias Sidereon.Terrain
  alias Sidereon.Terrain.MmapTerrain
  alias Sidereon.Terrain.MmapTerrain.{DtedTileListEntry, TerrainDatumError, TerrainStoreError}

  @dted_fixture Path.join(__DIR__, "fixtures/dted/tiles/n36_w107_1arc_v3.dt2")
  @misplaced_fixture Path.join(__DIR__, "fixtures/dted/tiles/n36_w106_1arc_v3.dt2")

  test "DTED builder retains the store path and nested tile parser payload" do
    path = temp_path("n36_w106_1arc_v3.dt2")
    File.write!(path, :binary.copy(<<0>>, 4_000))
    on_exit(fn -> File.rm(path) end)

    entry = DtedTileListEntry.from_indices(36, -106, path)

    assert {:error,
            %TerrainStoreError{
              kind: :tile,
              path: ^path,
              error: {:missing_uhl1, %{path: ^path}},
              message: message
            }} = MmapTerrain.dted_tile_list_to_mmap_store([entry])

    assert message =~ path

    valid_entry = DtedTileListEntry.from_indices(36, -107, @dted_fixture)
    assert {:ok, bytes} = MmapTerrain.dted_tile_list_to_mmap_store([valid_entry])
    assert is_binary(bytes)
  end

  test "lookup keeps malformed, misplaced, and invalid-input error fields" do
    short_root = temp_path("short-tile")
    File.mkdir_p!(short_root)
    short_path = Path.join(short_root, "n36_w107_1arc_v3.dt2")
    File.write!(short_path, "short")
    on_exit(fn -> File.rm_rf(short_root) end)

    assert {:ok, short_terrain} = Terrain.dted(short_root)

    assert {:error,
            {:terrain_tile,
             %{
               lat_index: 36,
               lon_index: -107,
               error: {:too_short, %{path: ^short_path}}
             }}} = Terrain.height(short_terrain, -106.5, 36.5)

    misplaced_root = temp_path("misplaced-tile")
    File.mkdir_p!(misplaced_root)
    misplaced_path = Path.join(misplaced_root, "n36_w107_1arc_v3.dt2")
    File.cp!(@misplaced_fixture, misplaced_path)
    on_exit(fn -> File.rm_rf(misplaced_root) end)

    assert {:ok, misplaced_terrain} = Terrain.dted(misplaced_root)

    assert {:error,
            {:terrain_tile_origin,
             %{
               path: ^misplaced_path,
               lat_index: 36,
               lon_index: -107,
               origin_latitude: 36,
               origin_longitude: -106
             }}} = Terrain.height(misplaced_terrain, -106.5, 36.5)

    valid_root = temp_path("valid-tile")
    File.mkdir_p!(valid_root)
    valid_path = Path.join(valid_root, "n36_w107_1arc_v3.dt2")
    File.cp!(@dted_fixture, valid_path)
    on_exit(fn -> File.rm_rf(valid_root) end)

    assert {:ok, valid_terrain} = Terrain.dted(valid_root)
    assert {:error, {:invalid_input, %{message: message}}} = Terrain.height(valid_terrain, -106.5, 90.1)
    assert message == "latitude_deg must be within [-90, 90]"
    assert {:ok, height} = Terrain.height(valid_terrain, -106.5, 36.5)
    assert is_float(height)
  end

  test "empty DAC reports a typed geoid parse error and valid DAC loads" do
    assert {:error,
            %TerrainDatumError{
              kind: :geoid,
              reason: %Geoid.GridError{kind: :parse, reason: reason} = retained
            }} = MmapTerrain.Egm96FifteenMinuteGeoid.from_ww15mgh_dac_bytes(<<>>)

    assert reason ==
             "EGM96 WW15MGH.DAC must be 2076480 bytes (721 x 1440 big-endian int16), got 0"

    dac = :binary.copy(<<0, 1>>, 721 * 1_440)
    assert {:ok, _geoid} = MmapTerrain.Egm96FifteenMinuteGeoid.from_ww15mgh_dac_bytes(dac)
    assert retained.kind == :parse
    assert retained.reason == reason
  end

  defp temp_path(name) do
    Path.join(System.tmp_dir!(), "sidereon-terrain-errors-#{System.unique_integer([:positive])}-#{name}")
  end
end
