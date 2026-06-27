defmodule Sidereon.GNSS.DataTest do
  # Not async: several tests exercise the app-config knobs (`:gnss_data_offline`,
  # `:gnss_data_req_available`) by setting global application env, which must not
  # race other tests.
  use ExUnit.Case, async: false

  alias Sidereon.GNSS.Data
  alias Sidereon.GNSS.Data.Cache

  @gz_fixture Path.join(__DIR__, "fixtures/gnss_data/GBM0MGXRAP_20201760000_01D_05M_ORB.SP3.gz")
  @nav_fixture Path.join(__DIR__, "fixtures/nav/ESBC00DNK_R_20201770000_01D_MN.rnx")
  @obs_crx_fixture Path.join(__DIR__, "fixtures/obs/ESBC00DNK_R_20201770000_01D_30S_MO_trim.crx")

  setup do
    # A fresh, unique cache dir per test, removed afterwards. Never the user cache.
    cache_dir =
      Path.join(System.tmp_dir!(), "sidereon_gnss_cache_#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(cache_dir) end)
    {:ok, cache_dir: cache_dir}
  end

  # The decompressed SP3 bytes the committed .gz fixture expands to.
  defp sp3_bytes, do: :zlib.gunzip(File.read!(@gz_fixture))

  # Seed `cache_dir` with `bytes` under the canonical name of `product`.
  defp seed(cache_dir, product, bytes) do
    {:ok, filename} = Data.Product.canonical_filename(product)
    {:ok, path} = Cache.path_for(cache_dir, filename)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
    path
  end

  describe "gunzip/2 (decompression)" do
    test "expands the committed .gz fixture to the expected SP3 header" do
      compressed = File.read!(@gz_fixture)
      assert {:ok, decompressed} = Cache.gunzip(compressed)
      assert String.starts_with?(decompressed, "#cP2020")
      assert decompressed =~ "PG01  15000.000000"
    end

    test "rejects corrupt gzip data" do
      assert {:error, {:decompress_failed, _}} = Cache.gunzip(<<0, 1, 2, 3, 4, 5>>)
    end

    test "enforces the gzip-bomb size cap" do
      compressed = File.read!(@gz_fixture)
      # The fixture expands to ~944 bytes; cap at 100 to trip the guard.
      assert {:error, {:decompress_size_exceeded, 100, got}} = Cache.gunzip(compressed, 100)
      assert got > 100
    end

    test "aborts a real gzip bomb without materializing its full expansion" do
      # 256 MiB of zeros compresses to a tiny buffer but would dwarf a small cap.
      bomb = :zlib.gzip(:binary.copy(<<0>>, 256 * 1024 * 1024))
      cap = 1_000_000

      # Measure the peak memory the inflate uses: a streaming guard must stay
      # bounded near the cap, not balloon to the full 256 MiB expansion.
      before = :erlang.memory(:total)
      assert {:error, {:decompress_size_exceeded, ^cap, got}} = Cache.gunzip(bomb, cap)
      peak = :erlang.memory(:total) - before

      # We aborted as soon as we crossed the cap, so the reported size is just
      # over it (not the full 256 MiB), and we never allocated the remainder.
      assert got > cap
      assert got < 16 * 1024 * 1024
      assert peak < 64 * 1024 * 1024
    end
  end

  describe "fetch/2 offline cache hits" do
    test "returns a cached file without network", %{cache_dir: cache_dir} do
      product = Data.mgex_sp3(:esa, ~D[2020-06-24])
      seeded = seed(cache_dir, product, sp3_bytes())

      assert {:ok, ^seeded} = Data.fetch(product, offline: true, cache_dir: cache_dir)
    end

    test "verifies a known checksum on a cache hit", %{cache_dir: cache_dir} do
      product = Data.mgex_sp3(:esa, ~D[2020-06-24])
      bytes = sp3_bytes()
      seed(cache_dir, product, bytes)
      sha = Cache.sha256(bytes)

      assert {:ok, _path} =
               Data.fetch(product, offline: true, cache_dir: cache_dir, sha256: sha)
    end

    test "rejects a cache hit whose checksum does not match", %{cache_dir: cache_dir} do
      product = Data.mgex_sp3(:esa, ~D[2020-06-24])
      seed(cache_dir, product, sp3_bytes())
      wrong = String.duplicate("0", 64)

      assert {:error, {:checksum_mismatch, ^wrong, _got}} =
               Data.fetch(product, offline: true, cache_dir: cache_dir, sha256: wrong)
    end
  end

  describe "fetch/2 offline misses and errors" do
    test "returns an offline_miss when the file is absent", %{cache_dir: cache_dir} do
      product = Data.mgex_sp3(:esa, ~D[2020-06-24])

      assert {:error, {:offline_miss, "ESA0MGNFIN_20201760000_01D_05M_ORB.SP3"}} =
               Data.fetch(product, offline: true, cache_dir: cache_dir)
    end

    test "returns an offline_miss for a resolved ultra-rapid issue", %{cache_dir: cache_dir} do
      product =
        Data.ops_ultra_sp3(:igs_ult, ~N[2024-09-03 13:00:00],
          available_issues: [{~D[2024-09-03], "0600"}]
        )

      assert {:error, {:offline_miss, "IGS0OPSULT_20242470600_02D_15M_ORB.SP3"}} =
               Data.fetch(product, offline: true, cache_dir: cache_dir)
    end

    test "an unsupported product is rejected before any network", %{cache_dir: cache_dir} do
      # Construct a Product struct directly to bypass the validating builder.
      bad = %Data.Product{center: :nope, content: :sp3, date: ~D[2020-06-24], sample: "05M"}

      assert {:error, {:unsupported_product, {:center, :nope}}} =
               Data.fetch(bad, offline: true, cache_dir: cache_dir)
    end

    test "returns an offline_miss for a rapid IONEX product", %{cache_dir: cache_dir} do
      product = Data.rapid_ionex(~D[2026-06-13])

      assert {:error, {:offline_miss, "COD0OPSRAP_20261640000_01D_01H_GIM.INX"}} =
               Data.fetch(product, offline: true, cache_dir: cache_dir)
    end

    test "fetch_ionex offline-miss exhausts every candidate day", %{cache_dir: cache_dir} do
      # No candidate seeded: the rapid walk tries doy 165/164/163 and the last
      # offline miss is surfaced (the oldest candidate, doy 163).
      assert {:error, {:offline_miss, "COD0OPSRAP_20261630000_01D_01H_GIM.INX"}} =
               Data.fetch_ionex(:cod_rap, ~D[2026-06-14], offline: true, cache_dir: cache_dir)
    end

    test "respects app-config offline mode", %{cache_dir: cache_dir} do
      Application.put_env(:sidereon, :gnss_data_offline, true)
      on_exit(fn -> Application.delete_env(:sidereon, :gnss_data_offline) end)

      product = Data.mgex_sp3(:esa, ~D[2020-06-24])
      assert {:error, {:offline_miss, _}} = Data.fetch(product, cache_dir: cache_dir)
    end

    test "a corrupt cache hit is terminal offline but self-heals online", %{cache_dir: cache_dir} do
      product = Data.mgex_sp3(:gfz, ~D[2020-06-24], sample: "15M")
      seed(cache_dir, product, "corrupt bytes that do not match the digest")
      sha = Cache.sha256(sp3_bytes())

      # Offline: a mismatch is terminal (nothing better to offer).
      assert {:error, {:checksum_mismatch, ^sha, _got}} =
               Data.fetch(product, offline: true, cache_dir: cache_dir, sha256: sha)

      # Online: the poisoned entry is discarded and a fresh download is
      # attempted. We disable HTTPS so the re-download stops at
      # :req_not_available rather than hitting the network — proving fetch did
      # NOT terminate on the stale checksum_mismatch.
      Application.put_env(:sidereon, :gnss_data_req_available, false)
      on_exit(fn -> Application.delete_env(:sidereon, :gnss_data_req_available) end)

      assert {:error, :req_not_available} =
               Data.fetch(product,
                 cache_dir: cache_dir,
                 sha256: sha,
                 retries: 1,
                 backoff_ms: 0
               )
    end
  end

  describe "convenience loaders (offline)" do
    test "sp3/2 returns a queryable SP3 handle", %{cache_dir: cache_dir} do
      product = Data.mgex_sp3(:esa, ~D[2020-06-24])
      seed(cache_dir, product, sp3_bytes())

      assert {:ok, %Sidereon.GNSS.SP3{} = sp3} =
               Data.sp3(product, offline: true, cache_dir: cache_dir)

      assert {:ok, state} = Sidereon.GNSS.SP3.position(sp3, "G01", ~N[2020-06-24 00:00:00])
      assert_in_delta state.x_m, 15_000_000.0, 1.0e-3
    end

    test "broadcast/2 returns a Broadcast handle", %{cache_dir: cache_dir} do
      # :igs resolves to the real merged-nav name BRDC00WRD_R_20201770000_01D_MN.rnx.
      product = Data.mgex_nav(:igs, ~D[2020-06-25])

      assert {:ok, "BRDC00WRD_R_20201770000_01D_MN.rnx"} =
               Data.Product.canonical_filename(product)

      seed(cache_dir, product, File.read!(@nav_fixture))

      assert {:ok, %Sidereon.GNSS.Broadcast{}} =
               Data.broadcast(product, offline: true, cache_dir: cache_dir)
    end

    test "an offline miss propagates through sp3/2", %{cache_dir: cache_dir} do
      product = Data.mgex_sp3(:esa, ~D[2020-06-24])

      assert {:error, {:offline_miss, _}} =
               Data.sp3(product, offline: true, cache_dir: cache_dir)
    end

    test "rapid_ionex/2 and predicted_ionex/3 resolve canonical CODE GIM names" do
      assert {:ok, "COD0OPSRAP_20261640000_01D_01H_GIM.INX"} =
               Data.Product.canonical_filename(Data.rapid_ionex(~D[2026-06-13]))

      # 1-day-ahead targets the given day; 2-day-ahead targets the day after.
      assert {:ok, "COD0OPSPRD_20261650000_01D_01H_GIM.INX"} =
               Data.Product.canonical_filename(Data.predicted_ionex(:cod_prd1, ~D[2026-06-14]))

      assert {:ok, "COD0OPSPRD_20261660000_01D_01H_GIM.INX"} =
               Data.Product.canonical_filename(Data.predicted_ionex(:cod_prd2, ~D[2026-06-14]))
    end

    test "fetch_ionex/3 returns a cached rapid GIM from a fallback day offline", %{
      cache_dir: cache_dir
    } do
      # Today's (doy 165) rapid map has not landed; seed the prior day (doy 164)
      # so the newest-first candidate walk falls back to it without network.
      product = Data.rapid_ionex(~D[2026-06-13])
      seeded = seed(cache_dir, product, "IONEX VERSION / TYPE\n")

      assert {:ok, ^seeded} =
               Data.fetch_ionex(:cod_rap, ~D[2026-06-14], offline: true, cache_dir: cache_dir)
    end

    test "fetch_ionex/3 resolves a 1-day predicted GIM for the current UTC day offline", %{
      cache_dir: cache_dir
    } do
      # The 1-day predicted map for a UTC day exists before that day starts, so
      # the current-day candidate is the first one tried and resolves directly.
      product = Data.predicted_ionex(:cod_prd1, ~D[2026-06-14])
      seeded = seed(cache_dir, product, "IONEX VERSION / TYPE\n")

      assert {:ok, ^seeded} =
               Data.fetch_ionex(:cod_prd1, ~D[2026-06-14], offline: true, cache_dir: cache_dir)
    end

    test "station_obs/3 resolves the canonical RINEX-3 observation name" do
      product = Data.station_obs("ESBC00DNK", ~D[2020-06-25])
      assert product.content == :obs
      assert product.station == "ESBC00DNK"

      assert {:ok, "ESBC00DNK_R_20201770000_01D_30S_MO.crx"} =
               Data.Product.canonical_filename(product)

      assert {:ok,
              "https://igs.bkg.bund.de/root_ftp/IGS/obs/2020/177/" <>
                "ESBC00DNK_R_20201770000_01D_30S_MO.crx.gz"} =
               Data.Product.archive_url(product)
    end

    test "observations/2 returns a Observations handle from a cached CRINEX", %{
      cache_dir: cache_dir
    } do
      # The cache holds the (gunzipped) CRINEX text exactly as fetch/2 commits it.
      product = Data.station_obs("ESBC00DNK", ~D[2020-06-25])
      seed(cache_dir, product, File.read!(@obs_crx_fixture))

      assert {:ok, %Sidereon.GNSS.RINEX.Observations{} = obs} =
               Data.observations(product, offline: true, cache_dir: cache_dir)

      {x, _y, _z} = Sidereon.GNSS.RINEX.Observations.approx_position(obs)
      assert_in_delta x, 3_582_105.291, 1.0e-3
    end

    test "an offline miss propagates through observations/2", %{cache_dir: cache_dir} do
      product = Data.station_obs("ESBC00DNK", ~D[2020-06-25])

      assert {:error, {:offline_miss, _}} =
               Data.observations(product, offline: true, cache_dir: cache_dir)
    end
  end

  describe "path-traversal safety" do
    test "rejects a cache filename containing a path separator", %{cache_dir: cache_dir} do
      assert {:error, {:unsafe_cache_name, _}} = Cache.path_for(cache_dir, "../escape")
      assert {:error, {:unsafe_cache_name, _}} = Cache.path_for(cache_dir, "a/b")
      assert {:error, {:unsafe_cache_name, _}} = Cache.path_for(cache_dir, "/etc/passwd")
    end

    test "accepts a valid canonical name" do
      assert {:ok, path} = Cache.path_for("/tmp/cache", "GBM0MGXRAP_20201760000_01D_05M_ORB.SP3")
      assert path == "/tmp/cache/GBM0MGXRAP_20201760000_01D_05M_ORB.SP3"
    end
  end

  describe "atomic commit + provenance" do
    test "commit writes the file and a provenance sidecar", %{cache_dir: cache_dir} do
      product = Data.mgex_sp3(:esa, ~D[2020-06-24])
      {:ok, filename} = Data.Product.canonical_filename(product)
      {:ok, path} = Cache.path_for(cache_dir, filename)

      bytes = sp3_bytes()

      provenance = %{
        "source_url" => "https://example/test",
        "sha256_decompressed" => Cache.sha256(bytes),
        "size_decompressed" => byte_size(bytes)
      }

      assert {:ok, ^path} = Cache.commit(path, bytes, provenance)
      assert File.read!(path) == bytes

      assert {:ok, decoded} = Cache.read_provenance(path)
      assert decoded["sha256_decompressed"] == Cache.sha256(bytes)
      # No leftover temp files in the cache directory.
      assert Enum.all?(File.ls!(cache_dir), &(not String.starts_with?(&1, ".tmp-")))
    end

    test "commit reports an unwritable cache directory" do
      # A path under a regular file (not a directory) cannot be created.
      blocker =
        Path.join(System.tmp_dir!(), "sidereon_blocker_#{System.unique_integer([:positive])}")

      File.write!(blocker, "x")
      on_exit(fn -> File.rm(blocker) end)

      target = Path.join([blocker, "sub", "FILE"])
      assert {:error, {:cache_dir_not_writable, _}} = Cache.commit(target, "data", %{})
    end
  end

  describe "default cache integrity (no caller checksum)" do
    test "a default cache hit is verified against the provenance sidecar and self-heals online",
         %{cache_dir: cache_dir} do
      product = Data.mgex_sp3(:gfz, ~D[2020-06-24], sample: "15M")
      {:ok, filename} = Data.Product.canonical_filename(product)
      {:ok, path} = Cache.path_for(cache_dir, filename)
      good = sp3_bytes()

      # A committed file always carries its decompressed hash in the sidecar.
      assert {:ok, ^path} =
               Cache.commit(path, good, %{"sha256_decompressed" => Cache.sha256(good)})

      # A clean default (no :sha256) hit is returned with no network.
      assert {:ok, ^path} = Data.fetch(product, offline: true, cache_dir: cache_dir)

      # Corrupt the cached file but leave the sidecar: the stored hash no longer
      # matches the bytes, and the default hit must NOT trust it.
      File.write!(path, "corrupted after caching")

      # Offline: the sidecar mismatch is detected and is terminal.
      assert {:error, {:checksum_mismatch, _, _}} =
               Data.fetch(product, offline: true, cache_dir: cache_dir)

      # Online: the poisoned entry is discarded and a fresh download attempted.
      # HTTPS disabled so it stops at :req_not_available — proving fetch did
      # NOT serve the corrupt cached bytes.
      Application.put_env(:sidereon, :gnss_data_req_available, false)
      on_exit(fn -> Application.delete_env(:sidereon, :gnss_data_req_available) end)

      assert {:error, :req_not_available} =
               Data.fetch(product, cache_dir: cache_dir, retries: 1, backoff_ms: 0)
    end

    test "an unverifiable cache hit (no sidecar) is served offline but refreshed online",
         %{cache_dir: cache_dir} do
      product = Data.mgex_sp3(:gfz, ~D[2020-06-24], sample: "15M")
      # seed/3 writes the product file but no provenance sidecar.
      path = seed(cache_dir, product, sp3_bytes())

      # Offline: nothing better to offer, so the unprovenanced file is returned.
      assert {:ok, ^path} = Data.fetch(product, offline: true, cache_dir: cache_dir)

      # Online: treated as a miss and re-downloaded rather than silently trusted
      # (HTTPS disabled -> stops at :req_not_available).
      Application.put_env(:sidereon, :gnss_data_req_available, false)
      on_exit(fn -> Application.delete_env(:sidereon, :gnss_data_req_available) end)

      assert {:error, :req_not_available} =
               Data.fetch(product, cache_dir: cache_dir, retries: 1, backoff_ms: 0)
    end
  end

  describe "HTTPS availability" do
    test "fetch surfaces :req_not_available for an HTTPS center when HTTPS is disabled",
         %{cache_dir: cache_dir} do
      Application.put_env(:sidereon, :gnss_data_req_available, false)
      on_exit(fn -> Application.delete_env(:sidereon, :gnss_data_req_available) end)

      product = Data.mgex_sp3(:gfz, ~D[2020-06-24], sample: "15M")

      # offline:false + cache miss + HTTPS disabled -> :req_not_available.
      assert {:error, :req_not_available} =
               Data.fetch(product,
                 cache_dir: cache_dir,
                 retries: 1,
                 backoff_ms: 0
               )
    end
  end

  describe "real network fetch" do
    @tag :network
    test "downloads, decompresses, caches, and loads a real GFZ SP3", %{cache_dir: cache_dir} do
      # GFZ's operational rapid SP3 for 2020-06-24, served over HTTPS:
      # https://isdc-data.gfz.de/gnss/products/rapid/w2111/GFZ0OPSRAP_20201760000_01D_15M_ORB.SP3.gz
      product = Data.mgex_sp3(:gfz, ~D[2020-06-24], sample: "15M")

      assert {:ok, path} = Data.fetch(product, cache_dir: cache_dir)
      assert File.exists?(path)
      assert {:ok, _prov} = Cache.read_provenance(path)

      # A second fetch is served from the cache with no network.
      assert {:ok, ^path} = Data.fetch(product, offline: true, cache_dir: cache_dir)

      assert {:ok, %Sidereon.GNSS.SP3{} = sp3} = Sidereon.GNSS.SP3.load(path)
      assert {:ok, _state} = Sidereon.GNSS.SP3.position(sp3, "G01", ~N[2020-06-24 00:00:00])
    end

    @tag :network
    test "downloads a real ESA MGEX SP3 over HTTPS", %{cache_dir: cache_dir} do
      # ESA's MGEX final orbit for 2020-06-24:
      # https://navigation-office.esa.int/products/gnss-products/2111/ESA0MGNFIN_20201760000_01D_05M_ORB.SP3.gz
      product = Data.mgex_sp3(:esa, ~D[2020-06-24])

      assert {:ok, path} = Data.fetch(product, cache_dir: cache_dir)
      assert File.exists?(path)
      assert {:ok, %Sidereon.GNSS.SP3{}} = Sidereon.GNSS.SP3.load(path)
    end

    @tag :network
    test "downloads a real CODE MGEX SP3 over AIUB HTTP", %{cache_dir: cache_dir} do
      # CODE MGEX final orbit for 2024-06-24:
      # http://ftp.aiub.unibe.ch/CODE_MGEX/CODE/2024/COD0MGXFIN_20241760000_01D_05M_ORB.SP3.gz
      product = Data.mgex_sp3(:cod, ~D[2024-06-24])

      assert {:ok, path} = Data.fetch(product, cache_dir: cache_dir)
      assert File.exists?(path)
      assert {:ok, %Sidereon.GNSS.SP3{}} = Sidereon.GNSS.SP3.load(path)
    end

    @tag :network
    test "downloads a real CODE MGEX clock over AIUB HTTP", %{cache_dir: cache_dir} do
      # CODE MGEX final clock for 2024-06-24:
      # http://ftp.aiub.unibe.ch/CODE_MGEX/CODE/2024/COD0MGXFIN_20241760000_01D_30S_CLK.CLK.gz
      product = Data.mgex_clk(:cod, ~D[2024-06-24])

      assert {:ok, path} = Data.fetch(product, cache_dir: cache_dir)
      assert File.exists?(path)
      assert File.read!(path) =~ "RINEX VERSION / TYPE"
    end

    @tag :network
    test "downloads a real CODE IONEX over AIUB HTTP", %{cache_dir: cache_dir} do
      # CODE final GIM for 2024-06-24:
      # http://ftp.aiub.unibe.ch/CODE/2024/COD0OPSFIN_20241760000_01D_01H_GIM.INX.gz
      product = Data.mgex_ionex(:cod, ~D[2024-06-24])

      assert {:ok, path} = Data.fetch(product, cache_dir: cache_dir)
      assert File.exists?(path)
      assert File.read!(path) =~ "IONEX VERSION / TYPE"
    end

    @tag :network
    test "downloads a real CODE rapid IONEX over AIUB HTTP", %{cache_dir: cache_dir} do
      # The CODE rapid GIM lands a day or two late, so a recent past day is used.
      # fetch_ionex walks candidate days newest first through the ordinary
      # fetch/2 path (the same surface as the final IONEX above).
      assert {:ok, path} =
               Data.fetch_ionex(:cod_rap, Date.utc_today() |> Date.add(-1), cache_dir: cache_dir)

      assert File.exists?(path)
      assert File.read!(path) =~ "IONEX VERSION / TYPE"
    end

    @tag :network
    test "downloads a real CODE 1-day predicted IONEX for a current UTC day over AIUB HTTP",
         %{cache_dir: cache_dir} do
      # The 1-day predicted map for a UTC day is published before that day starts,
      # so the current UTC day resolves through the same fetch path.
      assert {:ok, path} =
               Data.fetch_ionex(:cod_prd1, Date.utc_today(), cache_dir: cache_dir)

      assert File.exists?(path)
      assert File.read!(path) =~ "IONEX VERSION / TYPE"
    end

    @tag :network
    test "downloads a recent uncompressed CODE ultra SP3 over AIUB HTTP", %{
      cache_dir: cache_dir
    } do
      # AIUB keeps CODE ultra products in the CODE root and publishes them
      # uncompressed. Yesterday is used because the current UTC day can be ahead
      # of publication.
      product = Data.ops_ultra_sp3(:cod_ult, Date.utc_today() |> Date.add(-1), issue: "0000")

      assert {:ok, path} = Data.fetch(product, cache_dir: cache_dir)
      assert File.exists?(path)
      assert {:ok, %Sidereon.GNSS.SP3{}} = Sidereon.GNSS.SP3.load(path)
    end

    @tag :network
    test "downloads the real merged broadcast navigation file over HTTPS", %{cache_dir: cache_dir} do
      # IGS merged multi-GNSS broadcast nav for 2020-06-25:
      # https://igs.bkg.bund.de/root_ftp/IGS/BRDC/2020/177/BRDC00WRD_R_20201770000_01D_MN.rnx.gz
      product = Data.mgex_nav(:igs, ~D[2020-06-25])

      assert {:ok, path} = Data.fetch(product, cache_dir: cache_dir)
      assert File.exists?(path)
      assert {:ok, %Sidereon.GNSS.Broadcast{}} = Sidereon.GNSS.Broadcast.load(path)
    end

    @tag :network
    test "downloads a real daily station observation file over HTTPS", %{cache_dir: cache_dir} do
      # A daily 30 s RINEX-3 observation file on the BKG IGS archive:
      # https://igs.bkg.bund.de/root_ftp/IGS/obs/2020/177/WTZR00DEU_R_20201770000_01D_30S_MO.crx.gz
      product = Data.station_obs("WTZR00DEU", ~D[2020-06-25])

      assert {:ok, %Sidereon.GNSS.RINEX.Observations{} = obs} =
               Data.observations(product, cache_dir: cache_dir)

      assert is_tuple(Sidereon.GNSS.RINEX.Observations.approx_position(obs)) or
               is_nil(Sidereon.GNSS.RINEX.Observations.approx_position(obs))
    end
  end
end
