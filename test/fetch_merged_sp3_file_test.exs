defmodule Sidereon.GNSS.FetchMergedSP3FileTest do
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.Data
  alias Sidereon.GNSS.Data.Cache
  alias Sidereon.GNSS.SP3

  # Mirror the sp3_merge_test.exs fixture helpers: build a single-epoch SP3-c
  # buffer from explicit {sat_token, [x_km, y_km, z_km], clock_us | nil} records
  # and seed it as a cached product so the fetch path resolves offline.
  defp sp3_bytes(records, coordinate_system \\ "IGS14") do
    n = length(records)

    sats =
      Enum.map_join(records, "", fn {sat, _, _} -> sat end) <>
        String.duplicate("  0", 17 - n)

    header = [
      "#cP2020  6 24  0  0  0.00000000       1 ORBIT #{coordinate_system} FIT  TST",
      "## 2111 432000.00000000   900.00000000 59024 0.0000000000000",
      "+   #{String.pad_leading(Integer.to_string(n), 2)}   #{sats}",
      "++         0  0  0  0  0  0  0  0  0  0  0  0  0  0  0  0  0",
      "%c G  cc GPS ccc cccc cccc cccc cccc ccccc ccccc ccccc ccccc",
      "%c cc cc ccc ccc cccc cccc cccc cccc ccccc ccccc ccccc ccccc",
      "%f  1.2500000  1.025000000  0.00000000000  0.000000000000000",
      "%f  0.0000000  0.000000000  0.00000000000  0.000000000000000",
      "%i    0    0    0    0      0      0      0      0         0",
      "%i    0    0    0    0      0      0      0      0         0",
      "/* TEST SP3-c FIXTURE",
      "*  2020  6 24  0  0  0.00000000"
    ]

    recs =
      Enum.map(records, fn {sat, [x, y, z], clk} ->
        c = clk || 999_999.999999
        "P" <> sat <> fmt(x) <> fmt(y) <> fmt(z) <> fmt(c)
      end)

    Enum.join(header ++ recs ++ ["EOF", ""], "\n")
  end

  defp fmt(v), do: :io_lib.format(~c"~14.6f", [v]) |> IO.iodata_to_binary()

  defp seed(cache_dir, product, bytes) do
    {:ok, filename} = Data.Product.canonical_filename(product)
    {:ok, path} = Cache.path_for(cache_dir, filename)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
    path
  end

  describe "Data.fetch_merged_sp3_file/4" do
    setup do
      cache_dir =
        Path.join(
          System.tmp_dir!(),
          "sidereon_fetch_merged_sp3_file_#{System.unique_integer([:positive])}"
        )

      out_dir =
        Path.join(
          System.tmp_dir!(),
          "sidereon_fetch_merged_sp3_file_out_#{System.unique_integer([:positive])}"
        )

      on_exit(fn ->
        File.rm_rf(cache_dir)
        File.rm_rf(out_dir)
      end)

      {:ok, cache_dir: cache_dir, out_dir: out_dir}
    end

    test "fetches, merges, and writes a file that loads back covering the union", %{
      cache_dir: cache_dir,
      out_dir: out_dir
    } do
      igs = Data.ops_ultra_sp3(:igs_ult, ~D[2024-09-03], issue: "0600")
      gfz = Data.ops_ultra_sp3(:gfz_ult, ~D[2024-09-03], issue: "0600")

      seed(
        cache_dir,
        igs,
        sp3_bytes([
          {"G01", [15000.0, -20000.0, 5000.0], 100.0},
          {"G03", [17000.0, -22000.0, 7000.0], 300.0}
        ])
      )

      seed(
        cache_dir,
        gfz,
        sp3_bytes([
          {"G01", [15000.0, -20000.0, 5000.0], 100.0},
          {"G02", [16000.0, -21000.0, 6000.0], 200.0}
        ])
      )

      path = Path.join(out_dir, "merged_current_day.sp3")

      assert {:ok, ^path, report} =
               Data.fetch_merged_sp3_file(~D[2024-09-03], [:igs_ult, :gfz_ult], path,
                 issue: "0600",
                 offline: true,
                 cache_dir: cache_dir
               )

      assert File.exists?(path)

      # The written file is a standard SP3 that loads back covering the union
      # — exactly what the Observables / Positioning layers consume.
      assert {:ok, loaded} = SP3.load(path)
      assert Enum.sort(SP3.satellite_ids(loaded)) == ["G01", "G02", "G03"]

      assert Enum.map(report.contributors, & &1.center) == [:igs_ult, :gfz_ult]
      assert report.source_count == 2
      refute report.single_product?
    end

    test "gzip option writes a gzipped file that loads back", %{
      cache_dir: cache_dir,
      out_dir: out_dir
    } do
      gfz = Data.ops_ultra_sp3(:gfz_ult, ~D[2024-09-03], issue: "0600")

      seed(
        cache_dir,
        gfz,
        sp3_bytes([{"G02", [16000.0, -21000.0, 6000.0], 200.0}])
      )

      path = Path.join(out_dir, "merged_current_day.sp3.gz")

      assert {:ok, ^path, report} =
               Data.fetch_merged_sp3_file(~D[2024-09-03], [:gfz_ult], path,
                 issue: "0600",
                 offline: true,
                 cache_dir: cache_dir,
                 gzip: true
               )

      assert report.single_product?

      # gzip magic header (0x1f 0x8b) — the file is actually compressed.
      assert <<0x1F, 0x8B, _rest::binary>> = File.read!(path)

      bytes = path |> File.read!() |> :zlib.gunzip()
      assert {:ok, loaded} = SP3.parse(bytes)
      assert SP3.satellite_ids(loaded) == ["G02"]
    end

    test "propagates a no-products error and writes nothing", %{
      cache_dir: cache_dir,
      out_dir: out_dir
    } do
      path = Path.join(out_dir, "should_not_exist.sp3")

      assert {:error, {:no_products, reasons}} =
               Data.fetch_merged_sp3_file(~D[2024-09-03], [:igs_ult, :gfz_ult], path,
                 issue: "0600",
                 offline: true,
                 cache_dir: cache_dir
               )

      assert Enum.map(reasons, & &1.center) == [:igs_ult, :gfz_ult]
      assert Enum.all?(reasons, &(&1.reason == :offline_miss))
      refute File.exists?(path)
    end
  end

  # Live gate: hits real archives and persists a merged current-day product.
  # Excluded by default; run with `mix test --include network`.
  describe "Data.fetch_merged_sp3_file/4 (network)" do
    @describetag :network

    test "fetches and writes a real merged current-day ultra product" do
      cache_dir =
        Path.join(System.tmp_dir!(), "sidereon_fmsf_net_#{System.unique_integer([:positive])}")

      out_dir =
        Path.join(
          System.tmp_dir!(),
          "sidereon_fmsf_net_out_#{System.unique_integer([:positive])}"
        )

      on_exit(fn ->
        File.rm_rf(cache_dir)
        File.rm_rf(out_dir)
      end)

      path = Path.join(out_dir, "merged_today.sp3")
      target = NaiveDateTime.utc_now()

      assert {:ok, ^path, report} =
               Data.fetch_merged_sp3_file(target, [:igs_ult, :esa_ult], path,
                 cache_dir: cache_dir
               )

      assert File.exists?(path)
      assert {:ok, loaded} = SP3.load(path)
      refute SP3.satellite_ids(loaded) == []
      assert report.source_count >= 1
    end
  end
end
