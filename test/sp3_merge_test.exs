defmodule Sidereon.GNSS.SP3MergeTest do
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.Data
  alias Sidereon.GNSS.Data.Cache
  alias Sidereon.GNSS.SP3

  # Build a single-epoch SP3-c buffer from explicit
  # `{satellite_token, [x_km, y_km, z_km], clock_us | nil}` records, so each test
  # controls which satellites a "center" reports and where. Mirrors the crate's
  # `sp3_records` test helper.
  defp sp3_bytes(records, coordinate_system \\ "IGS14", interval_s \\ 900.0) do
    n = length(records)

    sats =
      Enum.map_join(records, "", fn {sat, _, _} -> sat end) <>
        String.duplicate("  0", 17 - n)

    header = [
      "#cP2020  6 24  0  0  0.00000000       1 ORBIT #{coordinate_system} FIT  TST",
      "## 2111 432000.00000000 #{interval(interval_s)} 59024 0.0000000000000",
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

  defp sp3_records(records) do
    {:ok, sp3} = SP3.parse(sp3_bytes(records))
    sp3
  end

  defp fmt(v), do: :io_lib.format(~c"~14.6f", [v]) |> IO.iodata_to_binary()
  defp interval(v), do: :io_lib.format(~c"~14.8f", [v]) |> IO.iodata_to_binary()

  defp seed(cache_dir, product, bytes) do
    {:ok, filename} = Data.Product.canonical_filename(product)
    {:ok, path} = Cache.path_for(cache_dir, filename)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
    path
  end

  describe "merge/2" do
    test "union coverage: merged product covers a satellite a center is missing" do
      a =
        sp3_records([
          {"G01", [15000.0, -20000.0, 5000.0], 100.0},
          {"G02", [16000.0, -21000.0, 6000.0], 200.0},
          {"G03", [17000.0, -22000.0, 7000.0], 300.0}
        ])

      b =
        sp3_records([
          {"G01", [15000.0, -20000.0, 5000.0], 100.0},
          {"G02", [16000.0, -21000.0, 6000.0], 200.0}
        ])

      assert {:ok, merged, report} = SP3.merge([a, b])

      ids = SP3.satellite_ids(merged)
      assert "G03" in ids, "merged output must cover G03 from the center that has it"
      assert Enum.sort(ids) == ["G01", "G02", "G03"]

      assert report.quarantined == []
      # G03 had a single source (index 0) -> carried through, recorded.
      assert [%{satellite: "G03", sources: [0]}] = report.single_source
    end

    test "ultra-rapid products loaded through the fetch cache compose with merge" do
      cache_dir =
        Path.join(
          System.tmp_dir!(),
          "sidereon_sp3_ultra_merge_#{System.unique_integer([:positive])}"
        )

      on_exit(fn -> File.rm_rf(cache_dir) end)

      igs = Data.ops_ultra_sp3(:igs_ult, ~D[2024-09-03], issue: "0600")
      gfz = Data.ops_ultra_sp3(:gfz_ult, ~D[2024-09-03], issue: "0600")

      seed(
        cache_dir,
        igs,
        sp3_bytes([
          {"G01", [15000.0, -20000.0, 5000.0], 100.0},
          {"G02", [16000.0, -21000.0, 6000.0], 200.0},
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

      assert {:ok, a} = Data.sp3(igs, offline: true, cache_dir: cache_dir)
      assert {:ok, b} = Data.sp3(gfz, offline: true, cache_dir: cache_dir)
      assert {:ok, merged, report} = SP3.merge([a, b])

      assert Enum.sort(SP3.satellite_ids(merged)) == ["G01", "G02", "G03"]
      assert [%{satellite: "G03", sources: [0]}] = report.single_source
    end

    test "quarantines a satellite all centers disagree on" do
      # Three centers, mutually beyond the default 0.5 m tolerance on G01.
      a = sp3_records([{"G01", [15000.000, -20000.0, 5000.0], 100.0}])
      b = sp3_records([{"G01", [15000.010, -20000.0, 5000.0], 100.0}])
      c = sp3_records([{"G01", [15000.020, -20000.0, 5000.0], 100.0}])

      assert {:ok, merged, report} = SP3.merge([a, b, c])

      refute "G01" in SP3.satellite_ids(merged),
             "no consensus -> G01 omitted, not averaged across disagreeing centers"

      assert [%{satellite: "G01"}] = report.quarantined
    end

    test "rejects an outlier and combines the agreeing centers" do
      # A and B agree on G01; C is 10 m off in X.
      a = sp3_records([{"G01", [15000.000, -20000.0, 5000.0], 100.0}])
      b = sp3_records([{"G01", [15000.000, -20000.0, 5000.0], 100.0}])
      c = sp3_records([{"G01", [15000.010, -20000.0, 5000.0], 100.0}])

      assert {:ok, merged, report} = SP3.merge([a, b, c])

      assert "G01" in SP3.satellite_ids(merged)
      assert [%{satellite: "G01", sources: [2]}] = report.position_outliers
      assert report.quarantined == []
    end

    test "rejects differently labeled frames unless an exact transform is applied" do
      {:ok, a} = SP3.parse(sp3_bytes([{"G01", [15000.0, -20000.0, 5000.0], 100.0}], "IGS20"))
      {:ok, b} = SP3.parse(sp3_bytes([{"G01", [15000.0, -20000.0, 5000.0], 100.0}], "IGc20"))

      assert {:error, reason} = SP3.merge([a, b])
      assert to_string(reason) =~ "mismatched coordinate systems"
    end

    test "still rejects a genuine cross-datum pair (IGS14 vs IGS20)" do
      {:ok, a} = SP3.parse(sp3_bytes([{"G01", [15000.0, -20000.0, 5000.0], 100.0}], "IGS14"))
      {:ok, b} = SP3.parse(sp3_bytes([{"G01", [15000.0, -20000.0, 5000.0], 100.0}], "IGS20"))

      assert {:error, _} = SP3.merge([a, b])
    end

    test "decimates mixed epoch intervals onto a common grid, rejecting non-divisible ones" do
      {:ok, a} =
        SP3.parse(sp3_bytes([{"G01", [15000.0, -20000.0, 5000.0], 100.0}], "IGS14", 900.0))

      {:ok, b} =
        SP3.parse(sp3_bytes([{"G01", [15000.0, -20000.0, 5000.0], 100.0}], "IGS14", 300.0))

      # 15-min + 5-min is now decimated onto the 900 s common grid, not rejected.
      assert {:ok, _merged, _report} = SP3.merge([a, b], min_agree: 1)

      # A target finer than an input is unsatisfiable (no upsampling/interpolation).
      assert {:error, reason} = SP3.merge([a], epoch_interval_s: 300.0)
      assert to_string(reason) =~ "mismatched epoch intervals"

      # A non-divisible cadence (900 vs 400) is still rejected.
      {:ok, d} =
        SP3.parse(sp3_bytes([{"G01", [15000.0, -20000.0, 5000.0], 100.0}], "IGS14", 400.0))

      assert {:error, reason} = SP3.merge([a, d])
      assert to_string(reason) =~ "mismatched epoch intervals"
    end

    test "filters the merged product to requested constellations" do
      multi =
        sp3_records([
          {"G01", [15000.0, -20000.0, 5000.0], 100.0},
          {"E01", [21000.0, -1000.0, 13000.0], 120.0}
        ])

      assert {:ok, merged, _report} = SP3.merge([multi], systems: [:gps])
      assert SP3.satellite_ids(merged) == ["G01"]

      assert {:error, {:unsupported_system, :bad}} = SP3.merge([multi], systems: [:bad])
    end
  end

  describe "Data.fetch_merged_sp3/3" do
    setup do
      cache_dir =
        Path.join(
          System.tmp_dir!(),
          "sidereon_fetch_merged_sp3_#{System.unique_integer([:positive])}"
        )

      on_exit(fn -> File.rm_rf(cache_dir) end)
      {:ok, cache_dir: cache_dir}
    end

    test "all centers present: merges union coverage and reports contributors", %{
      cache_dir: cache_dir
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

      assert {:ok, merged, report} =
               Data.fetch_merged_sp3(~D[2024-09-03], [:igs_ult, :gfz_ult],
                 issue: "0600",
                 offline: true,
                 cache_dir: cache_dir
               )

      assert Enum.sort(SP3.satellite_ids(merged)) == ["G01", "G02", "G03"]
      assert Enum.map(report.contributors, & &1.center) == [:igs_ult, :gfz_ult]
      assert report.absent == []
      assert report.source_count == 2
      refute report.single_product?
    end

    test "missing center is skipped and recorded while merge proceeds", %{cache_dir: cache_dir} do
      igs = Data.ops_ultra_sp3(:igs_ult, ~D[2024-09-03], issue: "0600")
      gfz = Data.ops_ultra_sp3(:gfz_ult, ~D[2024-09-03], issue: "0600")

      seed(cache_dir, igs, sp3_bytes([{"G01", [15000.0, -20000.0, 5000.0], 100.0}]))
      seed(cache_dir, gfz, sp3_bytes([{"G02", [16000.0, -21000.0, 6000.0], 200.0}]))

      assert {:ok, merged, report} =
               Data.fetch_merged_sp3(~D[2024-09-03], [:igs_ult, :gfz_ult, :esa_ult],
                 issue: "0600",
                 offline: true,
                 cache_dir: cache_dir
               )

      assert Enum.sort(SP3.satellite_ids(merged)) == ["G01", "G02"]
      assert Enum.map(report.contributors, & &1.center) == [:igs_ult, :gfz_ult]

      assert [
               %{
                 center: :esa_ult,
                 filename: "ESA0OPSULT_20242470600_02D_15M_ORB.SP3",
                 reason: :offline_miss
               }
             ] = report.absent
    end

    test "only one center available returns a single-source result", %{cache_dir: cache_dir} do
      gfz = Data.ops_ultra_sp3(:gfz_ult, ~D[2024-09-03], issue: "0600")
      seed(cache_dir, gfz, sp3_bytes([{"G02", [16000.0, -21000.0, 6000.0], 200.0}]))

      assert {:ok, sp3, report} =
               Data.fetch_merged_sp3(~D[2024-09-03], [:igs_ult, :gfz_ult],
                 issue: "0600",
                 offline: true,
                 cache_dir: cache_dir
               )

      assert SP3.satellite_ids(sp3) == ["G02"]
      assert Enum.map(report.contributors, & &1.center) == [:gfz_ult]
      assert [%{center: :igs_ult, reason: :offline_miss}] = report.absent
      assert report.source_count == 1
      assert report.single_product?
      refute report.merged?
    end

    test "zero products available returns per-center reasons", %{cache_dir: cache_dir} do
      assert {:error, {:no_products, reasons}} =
               Data.fetch_merged_sp3(~D[2024-09-03], [:igs_ult, :gfz_ult],
                 issue: "0600",
                 offline: true,
                 cache_dir: cache_dir
               )

      assert Enum.map(reasons, & &1.center) == [:igs_ult, :gfz_ult]

      assert Enum.map(reasons, & &1.filename) == [
               "IGS0OPSULT_20242470600_02D_15M_ORB.SP3",
               "GFZ0OPSULT_20242470600_02D_05M_ORB.SP3"
             ]

      assert Enum.all?(reasons, &(&1.reason == :offline_miss))
    end

    test "timestamp ultra target falls back to an earlier cached issue", %{cache_dir: cache_dir} do
      gfz_0600 = Data.ops_ultra_sp3(:gfz_ult, ~D[2024-09-03], issue: "0600")
      seed(cache_dir, gfz_0600, sp3_bytes([{"G02", [16000.0, -21000.0, 6000.0], 200.0}]))

      assert {:ok, sp3, report} =
               Data.fetch_merged_sp3(~N[2024-09-03 13:00:00], [:gfz_ult],
                 offline: true,
                 cache_dir: cache_dir
               )

      assert SP3.satellite_ids(sp3) == ["G02"]
      assert [%{center: :gfz_ult, issue: "0600", attempts: attempts}] = report.contributors

      assert [%{reason: :offline_miss, filename: "GFZ0OPSULT_20242471200_02D_05M_ORB.SP3"}] =
               attempts
    end

    test "incompatible source frames surface a tagged reason, not a raw merge error", %{
      cache_dir: cache_dir
    } do
      igs = Data.ops_ultra_sp3(:igs_ult, ~D[2024-09-03], issue: "0600")
      gfz = Data.ops_ultra_sp3(:gfz_ult, ~D[2024-09-03], issue: "0600")

      # Two fetchable centers, but on different coordinate-system realizations,
      # which the merge refuses rather than mixing frames.
      seed(cache_dir, igs, sp3_bytes([{"G01", [15000.0, -20000.0, 5000.0], 100.0}], "IGS14"))
      seed(cache_dir, gfz, sp3_bytes([{"G01", [15000.0, -20000.0, 5000.0], 100.0}], "IGS20"))

      assert {:error, {:incompatible_sources, info}} =
               Data.fetch_merged_sp3(~D[2024-09-03], [:igs_ult, :gfz_ult],
                 issue: "0600",
                 offline: true,
                 cache_dir: cache_dir
               )

      assert info.centers == [:igs_ult, :gfz_ult]
      assert info.reason != nil
    end

    test "merges mixed source cadence by decimating onto the common grid", %{
      cache_dir: cache_dir
    } do
      igs = Data.ops_ultra_sp3(:igs_ult, ~D[2024-09-03], issue: "0600")
      gfz = Data.ops_ultra_sp3(:gfz_ult, ~D[2024-09-03], issue: "0600")

      # IGS ultra at 15 min, GFZ ultra at 5 min.
      seed(
        cache_dir,
        igs,
        sp3_bytes([{"G01", [15000.0, -20000.0, 5000.0], 100.0}], "IGS14", 900.0)
      )

      seed(
        cache_dir,
        gfz,
        sp3_bytes([{"G01", [15000.0, -20000.0, 5000.0], 100.0}], "IGS14", 300.0)
      )

      # The mixed-cadence ultra-rapid set now consensus-merges onto the requested
      # 15-min grid (GFZ decimated) instead of returning :incompatible_sources.
      assert {:ok, %SP3{}, _provenance} =
               Data.fetch_merged_sp3(~D[2024-09-03], [:igs_ult, :gfz_ult],
                 issue: "0600",
                 combine: :precedence,
                 min_agree: 1,
                 systems: [:gps],
                 offline: true,
                 cache_dir: cache_dir,
                 epoch_interval_s: 900.0
               )
    end
  end

  describe "clock_reference_offset/3 and align_clock_reference/3" do
    defp shifted_pair do
      pos = [
        {"G01", [15000.0, -20000.0, 5000.0]},
        {"G02", [16000.0, -21000.0, 6000.0]},
        {"G03", [17000.0, -22000.0, 7000.0]}
      ]

      a = sp3_records(Enum.map(pos, fn {s, p} -> {s, p, 100.0} end))
      # `b`'s clocks all run +50 us (= 5e-5 s) ahead of `a`'s.
      b = sp3_records(Enum.map(pos, fn {s, p} -> {s, p, 150.0} end))
      {a, b}
    end

    test "clock_reference_offset recovers a uniform datum shift" do
      {a, b} = shifted_pair()

      assert [offset] = SP3.clock_reference_offset(a, b, min_common: 3)
      assert offset.satellites == 3
      assert_in_delta offset.offset_s, 5.0e-5, 1.0e-12
    end

    test "align_clock_reference removes the datum (residual offset ~ 0)" do
      {a, b} = shifted_pair()

      assert {:ok, aligned} = SP3.align_clock_reference(a, b, min_common: 3)
      assert [residual] = SP3.clock_reference_offset(a, aligned, min_common: 3)
      assert_in_delta residual.offset_s, 0.0, 1.0e-12
    end
  end
end
