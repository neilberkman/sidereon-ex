defmodule Sidereon.GNSS.DataTest do
  use ExUnit.Case, async: false

  alias Sidereon.GNSS.Data
  alias Sidereon.Terrain

  @postings 3601
  @dted_len 25_981_042
  @synthetic_dt2_sha256 "e118d926f69b4889d8c3b888098cb18f128669f1db40871f501c2160d87fa687"

  setup do
    root = Path.join(System.tmp_dir!(), "sidereon-data-test-#{System.unique_integer([:positive])}")
    File.rm_rf!(root)
    File.mkdir_p!(root)

    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "catalog derivation is delegated through the core NIF" do
    assert "esa" in Data.centers()
    assert "sp3" in Data.content_types()
    assert "s3.amazonaws.com" in Data.allowed_hosts()

    assert {:ok, product} = Data.mgex_sp3(:esa, ~D[2020-06-24])
    assert {:ok, "ESA0MGNFIN_20201760000_01D_05M_ORB.SP3"} = Data.canonical_filename(product)

    assert {:ok, "https://s3.amazonaws.com/elevation-tiles-prod/skadi/N36/N36W107.hgt.gz"} =
             Data.skadi_archive_url(36, -107)

    assert {:ok, "n30_w100/n36_w107_1arc_v3.dt2"} = Data.dted_cache_relpath(36, -107)
  end

  test "verified cache hit and offline hit return with no network", %{root: root} do
    {:ok, product} = Data.mgex_sp3(:esa, ~D[2020-06-24])
    {:ok, filename} = Data.canonical_filename(product)
    path = Path.join(root, filename)
    write_verified!(path, "cached-sp3")

    parent = self()

    http_client = fn _url, _opts ->
      send(parent, :network_called)
      {:ok, 500, ""}
    end

    assert {:ok, ^path} = Data.fetch(product, cache_dir: root, http_client: http_client)
    refute_received :network_called

    assert {:ok, ^path} = Data.fetch(product, cache_dir: root, offline: true, http_client: http_client)
    refute_received :network_called
  end

  test "offline miss and offline checksum failure are typed", %{root: root} do
    {:ok, product} = Data.mgex_sp3(:esa, ~D[2020-06-24])
    assert {:error, :offline_cache_miss} = Data.fetch(product, cache_dir: root, offline: true)

    {:ok, filename} = Data.canonical_filename(product)
    path = Path.join(root, filename)
    write_verified!(path, "old")
    File.write!(path, "corrupt")

    assert {:error, {:checksum_mismatch, _expected, _got}} =
             Data.fetch(product, cache_dir: root, offline: true)
  end

  test "stale GNSS cache redownloads online and caller checksum pins data", %{root: root} do
    {:ok, product} = Data.mgex_sp3(:esa, ~D[2020-06-24])
    {:ok, filename} = Data.canonical_filename(product)
    path = Path.join(root, filename)
    write_verified!(path, "old")
    File.write!(path, "corrupt")

    body = :zlib.gzip("fresh")
    http_client = fn _url, _opts -> {:ok, 200, body} end

    assert {:ok, ^path} = Data.fetch(product, cache_dir: root, http_client: http_client)
    assert File.read!(path) == "fresh"

    wrong = String.duplicate("0", 64)

    assert {:error, {:checksum_mismatch, ^wrong, _got}} =
             Data.fetch(product, cache_dir: root, sha256: wrong, http_client: http_client)
  end

  test "CLK and NAV use the generic fetch path", %{root: root} do
    body = :zlib.gzip("product")
    http_client = fn _url, _opts -> {:ok, 200, body} end

    {:ok, clk} = Data.mgex_clk(:gfz, ~D[2020-06-24])
    assert {:ok, clk_path} = Data.fetch(clk, cache_dir: root, http_client: http_client)
    assert File.read!(clk_path) == "product"

    {:ok, nav} = Data.mgex_nav(:igs, ~D[2020-06-25])
    assert {:ok, nav_path} = Data.fetch(nav, cache_dir: root, http_client: http_client)
    assert File.read!(nav_path) == "product"
  end

  test "redirect and compressed size cap are typed", %{root: root} do
    {:ok, product} = Data.mgex_sp3(:esa, ~D[2020-06-24])

    redirect = fn _url, _opts -> {:ok, 302, ""} end
    assert {:error, {:redirect_not_allowed, 302, _url}} = Data.fetch(product, cache_dir: root, http_client: redirect)

    oversized = fn _url, _opts -> {:ok, 200, "abcd"} end

    assert {:error, {:download_size_exceeded, 3}} =
             Data.fetch(product, cache_dir: root, http_client: oversized, max_compressed_bytes: 3)
  end

  test "terrain 404 writes an authoritative no-coverage marker", %{root: root} do
    http_client = fn _url, _opts -> {:ok, 404, ""} end

    assert {:ok, {:no_coverage, tile_id}} =
             Data.fetch_dted(0.25, -160.25, cache_dir: root, http_client: http_client)

    assert tile_id == "N00W161"

    parent = self()

    deny = fn _url, _opts ->
      send(parent, :network_called)
      {:ok, 500, ""}
    end

    assert {:ok, {:no_coverage, ^tile_id}} =
             Data.fetch_dted(0.25, -160.25, cache_dir: root, offline: true, http_client: deny)

    refute_received :network_called

    assert {:error, {:no_coverage, ^tile_id}} =
             Data.fetch_dted(0.25, -160.25, cache_dir: root, offline: true, strict: true, http_client: deny)

    assert {:error, :offline_cache_miss} = Data.fetch_dted(1.25, -160.25, cache_dir: root, offline: true)
  end

  test "terrain conversion is byte-stable and readable by DtedTerrain", %{root: root} do
    hgt = synthetic_hgt()
    hgt_gz = :zlib.gzip(hgt)
    http_client = fn _url, _opts -> {:ok, 200, hgt_gz} end

    assert {:ok, path} = Data.fetch_dted(36.5, -106.5, cache_dir: root, http_client: http_client)
    assert byte_size(File.read!(path)) == @dted_len
    assert sha256(File.read!(path)) == @synthetic_dt2_sha256

    assert {:ok, tile} = Terrain.load_tile(path)
    assert {:ok, 1234} = Terrain.tile_elevation(tile, -107.0 + 200 / 3600, 36.0 + 100 / 3600)
    assert {:ok, 0} = Terrain.tile_elevation(tile, -107.0 + 2345 / 3600, 36.0 + 1234 / 3600)
    assert {:ok, -415} = Terrain.tile_elevation(tile, -107.0 + 3000 / 3600, 36.0 + 2000 / 3600)

    assert {:ok, terrain} = Terrain.dted(root)

    assert {:ok, 8848.0} =
             Terrain.height(terrain, -107.0 + 3600 / 3600, 36.0 + 3600 / 3600, interpolation: :nearest_posting)
  end

  test "terrain wrong-length HGT is a decompress error", %{root: root} do
    http_client = fn _url, _opts -> {:ok, 200, :zlib.gzip("bad")} end

    assert {:error, {:decompress, {:bad_hgt_length, _expected, 3}}} =
             Data.fetch_dted(36.5, -106.5, cache_dir: root, http_client: http_client)
  end

  test "cross-readable terrain cache uses the core relative path", %{root: root} do
    hgt = synthetic_hgt()
    {:ok, dt2} = Sidereon.NIF.data_hgt_to_dted(36, -107, hgt)
    {:ok, relpath} = Data.dted_cache_relpath(36, -107)
    path = Path.join(root, relpath)
    write_verified!(path, dt2, %{"sha256_dt2" => sha256(dt2)})

    assert {:ok, ^path} = Data.fetch_dted(36.5, -106.5, cache_dir: root, offline: true)
  end

  test "terrain tile-list prefetch partitions cached no-coverage and invalid tiles", %{root: root} do
    {:ok, relpath} = Data.dted_cache_relpath(36, -107)
    cached_path = Path.join(root, relpath)
    write_verified!(cached_path, "not-a-real-dted")

    http_client = fn _url, _opts -> {:ok, 404, ""} end

    assert {:ok, report} =
             Data.prefetch_dted_tiles(["N36W107", {36, -106}, "bad"], cache_dir: root, http_client: http_client)

    assert report.cached == [cached_path]
    assert report.no_coverage == ["N36W106"]
    assert [{"bad", {:invalid_tile_id, "bad"}}] = report.errors
  end

  test "bbox rejects reversed regions" do
    assert {:error, {:invalid_bbox, bbox}} = Data.prefetch_dted_bbox({2.0, 0.0, 1.0, 1.0})
    assert bbox == {2.0, 0.0, 1.0, 1.0}
  end

  defp write_verified!(path, data, extra \\ %{}) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, data)

    provenance =
      Map.merge(
        %{
          "sha256_data" => sha256(data),
          "size_data" => byte_size(data),
          "source_url" => "test",
          "protocol" => "https",
          "compression" => "none"
        },
        extra
      )

    File.write!(path <> ".provenance.json", Jason.encode!(provenance))
  end

  defp synthetic_hgt do
    :binary.copy(<<0, 0>>, @postings * @postings)
    |> put_hgt_posting(100, 200, 1234)
    |> put_hgt_posting(1234, 2345, -32_768)
    |> put_hgt_posting(2000, 3000, -415)
    |> put_hgt_posting(3600, 3600, 8848)
  end

  defp put_hgt_posting(hgt, lat_posting, lon_posting, value) do
    row = @postings - 1 - lat_posting
    offset = 2 * (row * @postings + lon_posting)
    <<prefix::binary-size(^offset), _old::binary-size(2), suffix::binary>> = hgt
    prefix <> <<value::signed-big-16>> <> suffix
  end

  defp sha256(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
end
