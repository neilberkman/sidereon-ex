defmodule Sidereon.GNSS.DataTest do
  use ExUnit.Case, async: false

  alias Sidereon.GNSS.Data
  alias Sidereon.GNSS.SP3
  alias Sidereon.Terrain
  alias Sidereon.TestSupport.ExactSp3Fixture

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

  test "legacy fetch bounds the complete gzip member sequence before cache publication", %{root: root} do
    {:ok, product} = Data.mgex_sp3(:esa, ~D[2020-06-24])
    {:ok, filename} = Data.canonical_filename(product)
    content = "first member" <> "second member"
    archive = :zlib.gzip("first member") <> :zlib.gzip(<<>>) <> :zlib.gzip("second member")
    http_client = fn _url, _opts -> {:ok, 200, archive} end

    assert {:error, {:decompress, {:decompressed_size_exceeded, limit}}} =
             Data.fetch(product,
               cache_dir: root,
               http_client: http_client,
               max_decompressed_bytes: byte_size(content) - 1
             )

    assert limit == byte_size(content) - 1
    refute File.exists?(Path.join(root, filename))

    truncated = binary_part(archive, 0, byte_size(archive) - 1)

    assert {:error, {:decompress, :data_error}} =
             Data.fetch(product,
               cache_dir: root,
               http_client: fn _url, _opts -> {:ok, 200, truncated} end,
               max_decompressed_bytes: byte_size(content)
             )

    refute File.exists?(Path.join(root, filename))

    assert {:ok, path} =
             Data.fetch(product,
               cache_dir: root,
               http_client: http_client,
               max_decompressed_bytes: byte_size(content)
             )

    assert File.read!(path) == content
  end

  test "CODE ultra-rapid candidates exclude the moving latest snapshot", %{root: root} do
    parent = self()

    http_client = fn url, _opts ->
      send(parent, {:url, url})

      if String.ends_with?(url, "/COD0OPSULT_20261950000_01D_05M_ORB.SP3"),
        do: {:ok, 200, sp3_body(15_000.0, ~D[2026-07-14], 86_400, "AIUB")},
        else: flunk("uncataloged CODE candidate requested: #{url}")
    end

    assert {:ok, merged, report} =
             Data.fetch_merged_sp3(~D[2026-07-14], [:cod_ult],
               issue: "0000",
               cache_dir: root,
               http_client: http_client
             )

    assert %SP3{} = merged
    assert report.single_product
    assert report.merged
    assert report.requested_centers == ["cod_ult"]
    assert report.input_identity_schema_version == 1
    assert String.starts_with?(report.stable_input_identity, "sidereon-sp3-merge-input-v1:")

    assert [
             %Data.Contributor{
               pattern: "primary_01D_05M",
               filename: "COD0OPSULT_20261950000_01D_05M_ORB.SP3",
               artifact_identity: %Data.ArtifactIdentity{} = artifact,
               acquisition: %Data.AcquisitionFacts{cache_hit: false, attempts: attempts}
             }
           ] =
             report.contributors

    assert artifact.requested_identity == Map.put(artifact.resolved_identity, :format_version, nil)
    assert artifact.product_sha256 =~ ~r/^[0-9a-f]{64}$/
    assert artifact.archive_sha256 =~ ~r/^[0-9a-f]{64}$/
    assert attempts == []

    assert {:ok, _cached, cached_report} =
             Data.fetch_merged_sp3(~D[2026-07-14], [:cod_ult],
               issue: "0000",
               cache_dir: root,
               offline: true,
               http_client: fn _url, _opts -> flunk("cache hit contacted the network") end
             )

    assert cached_report.stable_input_identity == report.stable_input_identity

    assert [%Data.Contributor{acquisition: %Data.AcquisitionFacts{cache_hit: true}}] =
             cached_report.contributors

    output = Path.join(root, "merged.SP3")

    assert {:ok, ^output, file_report} =
             Data.fetch_merged_sp3_file_with_report(~D[2026-07-14], [:cod_ult], output,
               issue: "0000",
               cache_dir: root,
               offline: true
             )

    assert file_report.stable_input_identity == report.stable_input_identity

    assert_received {:url,
                     "https://www.aiub.unibe.ch/download/CODE/" <>
                       "COD0OPSULT_20261950000_01D_05M_ORB.SP3"}

    refute_received {:url, "https://www.aiub.unibe.ch/download/CODE/COD0OPSULT.SP3"}
  end

  test "GFZ cataloged cadence overlap falls back after ordinary absence", %{root: root} do
    parent = self()
    product = sp3_body(15_000.0, ~D[2021-05-14], 172_800, "GFZ")

    http_client = fn url, _opts ->
      send(parent, {:url, url})

      if String.contains?(url, "_02D_15M_ORB.SP3.gz"),
        do: {:ok, 404, ""},
        else: {:ok, 200, :zlib.gzip(product)}
    end

    assert {:ok, _merged, report} =
             Data.fetch_merged_sp3(~D[2021-05-15], [:gfz_ult],
               issue: "0000",
               cache_dir: root,
               http_client: http_client
             )

    assert [
             %Data.Contributor{
               pattern: "alternate_02D_05M",
               acquisition: %Data.AcquisitionFacts{attempts: [attempt]}
             }
           ] = report.contributors

    assert attempt.error_type == :product_not_published
    assert_received {:url, primary}
    assert String.contains?(primary, "_02D_15M_ORB.SP3.gz")
    assert_received {:url, alternate}
    assert String.contains?(alternate, "_02D_05M_ORB.SP3.gz")
  end

  test "integrity failure on the GFZ overlap alternate is terminal", %{root: root} do
    wrong_span = sp3_body(15_000.0, ~D[2021-05-14], 86_400, "GFZ")

    http_client = fn url, _opts ->
      if String.contains?(url, "_02D_15M_ORB.SP3.gz"),
        do: {:ok, 404, ""},
        else: {:ok, 200, :zlib.gzip(wrong_span)}
    end

    assert {:error, {:product_validation_failed, {:exact_sp3_validation_failed, "SP3 span mismatch:" <> _detail}}} =
             Data.fetch_merged_sp3(~D[2021-05-15], [:gfz_ult],
               issue: "0000",
               cache_dir: root,
               http_client: http_client
             )

    assert Path.wildcard(Path.join(root, "**/*.provenance.json")) == []
  end

  test "all variants absent does not prevent another center from contributing", %{root: root} do
    body = :zlib.gzip(sp3_body(15_000.0, ~D[2026-07-12], 172_800, "ESOC"))

    http_client = fn url, _opts ->
      if String.contains?(url, "navigation-office.esa.int") and
           String.contains?(url, "_02D_05M_ORB.SP3.gz"),
         do: {:ok, 200, body},
         else: {:ok, 404, ""}
    end

    assert {:ok, _merged, report} =
             Data.fetch_merged_sp3(~D[2026-07-12], [:cod_ult, :igs_ult, :esa_ult],
               issue: "0000",
               cache_dir: root,
               http_client: http_client
             )

    assert [%Data.Contributor{center: "esa_ult", pattern: "primary_02D_05M"}] =
             report.contributors

    assert [
             %Data.AbsentCenter{
               center: "cod_ult",
               reason: "candidate_not_found",
               pattern: "primary_01D_05M",
               url:
                 "https://www.aiub.unibe.ch/download/CODE/" <>
                   "COD0OPSULT_20261930000_01D_05M_ORB.SP3",
               http_status: 404
             },
             %Data.AbsentCenter{center: "igs_ult", reason: "candidate_not_found"}
           ] = report.absent

    assert report.requested_centers == ["cod_ult", "igs_ult", "esa_ult"]
    persisted = Data.merge_report_to_map(report)
    assert :ok = Data.verify_merge_report(persisted)
    assert :ok = persisted |> Jason.encode!() |> Jason.decode!() |> Data.verify_merge_report()

    [cod_absent, igs_absent] = persisted.absent

    invalid_partitions = [
      %{persisted | absent: [cod_absent]},
      %{persisted | absent: [cod_absent, igs_absent, %{cod_absent | center: "gfz_ult"}]},
      %{persisted | absent: Enum.reverse(persisted.absent)},
      %{persisted | absent: [cod_absent, cod_absent]}
    ]

    Enum.each(invalid_partitions, fn invalid ->
      assert {:error, _reason} = Data.verify_merge_report(invalid)
    end)
  end

  test "a center outside its verified catalog era is absent without hiding configuration failures", %{root: root} do
    parent = self()
    date = ~D[2022-11-26]
    body = :zlib.gzip(sp3_body(15_000.0, date, 86_400, "ESOC"))

    http_client = fn url, _opts ->
      send(parent, {:url, url})
      {:ok, 200, body}
    end

    assert {:ok, _merged, report} =
             Data.fetch_merged_sp3(date, [:esa, :cod],
               cache_dir: root,
               http_client: http_client
             )

    assert [%Data.Contributor{center: "esa"}] = report.contributors

    assert [%Data.AbsentCenter{center: "cod", reason: "catalog_unavailable"}] =
             report.absent

    assert report.requested_centers == ["esa", "cod"]
    assert_received {:url, esa_url}
    assert String.contains?(esa_url, "navigation-office.esa.int")
    refute_received {:url, _other_url}

    assert {:error, {:unsupported_product, "cod_prd1/sp3"}} =
             Data.fetch_merged_sp3(date, [:esa, :cod_prd1],
               cache_dir: Path.join(root, "invalid-center-product"),
               http_client: fn _url, _opts -> {:ok, 200, body} end
             )
  end

  test "fetch_merged_sp3 forwards merge policy options", %{root: root} do
    corrupt = sp3_body(16_000.0, ~D[2026-07-12], 86_400, "AIUB")
    agreeing_a = sp3_body(15_000.0, ~D[2026-07-12], 172_800, "ESOC")
    agreeing_b = sp3_body(15_000.0002, ~D[2026-07-12], 172_800, "GFZ")

    http_client = fn url, _opts ->
      cond do
        String.contains?(url, "www.aiub.unibe.ch") -> {:ok, 200, corrupt}
        String.contains?(url, "navigation-office.esa.int") -> {:ok, 200, :zlib.gzip(agreeing_a)}
        String.contains?(url, "isdc-data.gfz.de") -> {:ok, 200, :zlib.gzip(agreeing_b)}
      end
    end

    merge_opts = [
      combine: :precedence,
      min_agree: 1,
      precedence_scope: :cell,
      outlier_reject: [position_m: 0.5, clock_ns: 5.0]
    ]

    assert {:ok, fetched, fetch_report} =
             Data.fetch_merged_sp3(
               ~D[2026-07-12],
               [:cod_ult, :esa_ult, :gfz_ult],
               merge_opts ++ [issue: "0000", cache_dir: root, http_client: http_client]
             )

    assert length(fetch_report.contributors) == 3
    assert fetch_report.requested_centers == ["cod_ult", "esa_ult", "gfz_ult"]

    assert fetch_report.contributors
           |> Enum.map(& &1.artifact_identity.requested_identity.analysis_center)
           |> Enum.sort() == ["cod_ult", "esa_ult", "gfz_ult"]

    assert fetch_report.contributors
           |> Enum.map(& &1.artifact_identity.product_sha256)
           |> Enum.uniq()
           |> length() == 3

    assert :ok = Data.verify_merge_report(fetch_report)

    persisted = Data.merge_report_to_map(fetch_report)
    assert :ok = persisted |> Jason.encode!() |> Jason.decode!() |> Data.verify_merge_report()

    invalid_requested_centers = [
      %{persisted | requested_centers: ["cod_ult", "esa_ult"]},
      %{persisted | requested_centers: ["cod_ult", "esa_ult", "gfz_ult", "igs_ult"]},
      %{persisted | requested_centers: Enum.reverse(persisted.requested_centers)},
      %{persisted | requested_centers: ["cod_ult", "esa_ult", "gfz_ult", "gfz_ult"]}
    ]

    Enum.each(invalid_requested_centers, fn invalid ->
      assert {:error, _reason} = Data.verify_merge_report(invalid)
    end)

    sources = Enum.map([corrupt, agreeing_a, agreeing_b], fn bytes -> elem(SP3.parse(bytes), 1) end)
    assert {:ok, direct, direct_report} = SP3.merge(sources, merge_opts)
    assert {:ok, fetched_state} = SP3.state(fetched, "G01", 0)
    assert {:ok, direct_state} = SP3.state(direct, "G01", 0)
    assert fetched_state.x_m == direct_state.x_m
    assert fetched_state.x_m == 15_000_000.0
    assert fetch_report.merge_report.position_outliers == direct_report.position_outliers
  end

  test "redirect and compressed size cap are typed", %{root: root} do
    {:ok, product} = Data.mgex_sp3(:esa, ~D[2020-06-24])

    redirect = fn _url, _opts -> {:ok, 302, ""} end
    assert {:error, {:redirect_not_allowed, 302, _url}} = Data.fetch(product, cache_dir: root, http_client: redirect)

    oversized = fn _url, _opts -> {:ok, 200, "abcd"} end

    assert {:error, {:download_size_exceeded, 3}} =
             Data.fetch(product, cache_dir: root, http_client: oversized, max_compressed_bytes: 3)
  end

  test "AIUB download follows only the validated public HTTPS redirect chain", %{root: root} do
    {:ok, product} = Data.mgex_sp3(:cod_ult, ~D[2026-07-14], issue: "0000")

    source =
      "https://www.aiub.unibe.ch/download/CODE/" <>
        "COD0OPSULT_20261950000_01D_05M_ORB.SP3"

    download =
      "https://download.aiub.unibe.ch/CODE/" <>
        "COD0OPSULT_20261950000_01D_05M_ORB.SP3"

    target =
      "https://zhw-b.s3.cloud.switch.ch/aiub/CODE/" <>
        "COD0OPSULT_20261950000_01D_05M_ORB.SP3"

    parent = self()

    http_client = fn url, _opts ->
      send(parent, {:redirect_url, url})

      case url do
        ^source -> {:ok, 302, [{"location", download}], ""}
        ^download -> {:ok, %{status: 301, headers: %{"location" => [target]}, body: ""}}
        ^target -> {:ok, 200, sp3_body(15_000.0)}
      end
    end

    assert {:ok, path} = Data.fetch(product, cache_dir: root, http_client: http_client)
    assert {:ok, sp3} = SP3.load(path)
    assert SP3.epoch_count(sp3) == 1
    assert_received {:redirect_url, ^source}
    assert_received {:redirect_url, ^download}
    assert_received {:redirect_url, ^target}
  end

  test "AIUB download rejects an unrelated redirect target", %{root: root} do
    {:ok, product} = Data.mgex_sp3(:cod_ult, ~D[2026-07-14], issue: "0000")
    http_client = fn _url, _opts -> {:ok, 302, [{"location", "https://example.com/product.sp3"}], ""} end

    assert {:error, {:redirect_not_allowed, 302, url}} =
             Data.fetch(product, cache_dir: root, http_client: http_client)

    assert url =~ "https://www.aiub.unibe.ch/download/CODE/"
  end

  @tag :network
  test "live CODE ultra-rapid day 195 downloads and parses", %{root: root} do
    {:ok, product} = Data.mgex_sp3(:cod_ult, ~D[2026-07-14], issue: "0000")
    assert {:ok, path} = Data.fetch(product, cache_dir: root)
    assert File.stat!(path).size == 1_473_962
    assert "#dP" <> _ = File.read!(path)
    assert {:ok, sp3} = SP3.load(path)
    assert SP3.epoch_count(sp3) == 289
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

  defp sp3_body(x_km, date \\ ~D[2026-07-12], duration_s \\ 0, agency \\ "TST") do
    ExactSp3Fixture.build(date,
      x_km: x_km,
      span_s: duration_s,
      coverage: :inclusive,
      agency: agency
    )
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
