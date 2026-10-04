defmodule Sidereon.DtedTileErrorDetailsTest do
  use ExUnit.Case, async: true

  alias Sidereon.Terrain

  @fixture Path.join(__DIR__, "fixtures/dted/tiles/n36_w107_1arc_v3.dt2")
  @offset 3428
  @block_length 22

  test "public tile loading retains deterministic parser tags and fields" do
    fixture = File.read!(@fixture)
    root = temp_path("parse")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    cases = [
      {"short", binary_part(fixture, 0, 5), fn path -> {:too_short, %{path: path}} end},
      {"missing-uhl", replace(fixture, 0, "NOPE"), fn path -> {:missing_uhl1, %{path: path}} end},
      {"bad-encoding", replace(fixture, 4, <<255>>),
       fn _ -> {:invalid_encoding, "invalid utf-8 sequence of 1 bytes from index 0"} end},
      {"bad-field", replace(fixture, 47, "abcd"), fn _ -> {:invalid_field, "invalid digit found in string"} end},
      {"bad-dimensions", replace(fixture, 47, "0001"),
       fn path -> {:invalid_dimensions, %{path: path, lon_count: 1, lat_count: 5}} end},
      {"truncated", binary_part(fixture, 0, @offset),
       fn path -> {:truncated, %{path: path, actual: 3428, expected: 3538}} end},
      {"bad-hemisphere", replace(fixture, 4, "1070000X"), fn _ -> {:invalid_hemisphere, %{hemisphere: "X"}} end},
      {"out-of-range", replace(fixture, 4, "9990000W"),
       fn _ -> {:coordinate_out_of_range, %{field: "longitude of origin", text: "9990000W"}} end},
      {"wrong-hemisphere", replace(fixture, 4, "1060000N"),
       fn _ -> {:wrong_hemisphere, %{field: "longitude of origin", hemisphere: "N", expected: "E or W"}} end},
      {"fractional-origin", replace(fixture, 4, "1073000W"),
       fn _ -> {:origin_not_whole_degree, %{field: "longitude of origin", text: "1073000W"}} end},
      {"interval-mismatch", replace(fixture, 20, "8999"),
       fn _ ->
         {:interval_count_mismatch, %{field: "longitude data interval", interval_tenths_arcsec: 8999, count: 5}}
       end}
    ]

    for {name, bytes, expected} <- cases do
      path = Path.join(root, "n36_w107_#{name}.dt2")
      File.write!(path, bytes)
      assert {:error, actual} = Terrain.load_tile(path)
      assert actual == expected.(path), "#{name}: #{inspect(actual)} != #{inspect(expected.(path))}"
    end

    missing_path = Path.join(root, "n36_w107_missing.dt2")
    assert {:error, {:io, %{path: ^missing_path, message: message}}} = Terrain.load_tile(missing_path)
    assert message =~ "No such file"
  end

  test "public tile elevation retains profile, checksum, extent, null fields and success" do
    fixture = File.read!(@fixture)
    root = temp_path("lookup")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    cases = [
      {"outside", fixture, -105.5, 36.5,
       {:outside, %{longitude: -105.5, latitude: 36.5, origin_longitude: -107.0, origin_latitude: 36.0}}},
      {"sentinel", replace(fixture, @offset, <<0>>), -107.0, 36.0, {:missing_data_sentinel, %{longitude_index: 0}}},
      {"checksum", replace(fixture, @offset + 18, <<0, 0, 3, 193>>), -107.0, 36.0,
       {:checksum, %{longitude_index: 0, checksum: 961, sum: 960}}},
      {"profile-count", replace_and_rechecksum(fixture, @offset + 4, <<0, 1>>), -107.0, 36.0,
       {:profile_longitude_count_mismatch, %{longitude_index: 0, declared: 1}}},
      {"partial-profile", replace_and_rechecksum(fixture, @offset + 6, <<0, 1>>), -107.0, 36.0,
       {:unsupported_partial_profile, %{longitude_index: 0, first_latitude_index: 1}}},
      {"null-posting", replace_and_rechecksum(fixture, @offset + 8, <<255, 255>>), -107.0, 36.0,
       {:null_posting, %{longitude_index: 0, latitude_index: 0}}}
    ]

    for {name, bytes, longitude, latitude, expected} <- cases do
      path = Path.join(root, "n36_w107_#{name}.dt2")
      File.write!(path, bytes)
      assert {:ok, tile} = Terrain.load_tile(path)
      assert {:error, actual} = Terrain.tile_elevation(tile, longitude, latitude)
      assert actual == expected, name
    end

    assert {:ok, tile} = Terrain.load_tile(@fixture)
    assert {:ok, -20} = Terrain.tile_elevation(tile, -107.0, 36.0)
  end

  defp replace(binary, offset, replacement) do
    prefix = binary_part(binary, 0, offset)
    suffix_offset = offset + byte_size(replacement)
    suffix = binary_part(binary, suffix_offset, byte_size(binary) - suffix_offset)
    prefix <> replacement <> suffix
  end

  defp replace_and_rechecksum(binary, offset, replacement) do
    updated = replace(binary, offset, replacement)
    block = binary_part(updated, @offset, @block_length)
    checksum = block |> binary_part(0, @block_length - 4) |> :binary.bin_to_list() |> Enum.sum()
    replace(updated, @offset + @block_length - 4, <<checksum::signed-big-32>>)
  end

  defp temp_path(name) do
    Path.join(System.tmp_dir!(), "sidereon-dted-details-#{System.unique_integer([:positive])}-#{name}")
  end
end
