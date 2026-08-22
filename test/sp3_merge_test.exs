defmodule Sidereon.GNSS.SP3MergeTest do
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.SP3

  @daily_sp3 Path.join(__DIR__, "fixtures/sp3/GBM_BDS_C21_C08_trim.sp3")

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

  defp shifted_daily_product_with_x_offset(offset_km) do
    shifted =
      @daily_sp3
      |> File.read!()
      |> String.replace("2020  6 25", "2020  6 26")
      |> String.replace("2111 345600.00000000", "2111 432000.00000000")
      |> String.replace("59025 0.0000000000000", "59026 0.0000000000000")
      |> String.split("\n", trim: false)
      |> Enum.map_join("\n", fn
        <<"P", satellite::binary-size(3), x_field::binary-size(14), rest::binary>> ->
          x_km = x_field |> String.trim() |> String.to_float()
          "P" <> satellite <> fmt(x_km + offset_km) <> rest

        line ->
          line
      end)

    {:ok, product} = SP3.parse(shifted)
    {:ok, writer_derived} = product |> SP3.to_sp3_string() |> SP3.parse()
    writer_derived
  end

  describe "merge/2" do
    test "union coverage: merged product covers a satellite a center is missing" do
      a =
        sp3_records([
          {"G01", [15_000.0, -20_000.0, 5000.0], 100.0},
          {"G02", [16_000.0, -21_000.0, 6000.0], 200.0},
          {"G03", [17_000.0, -22_000.0, 7000.0], 300.0}
        ])

      b =
        sp3_records([
          {"G01", [15_000.0, -20_000.0, 5000.0], 100.0},
          {"G02", [16_000.0, -21_000.0, 6000.0], 200.0}
        ])

      assert {:ok, merged, report} = SP3.merge([a, b])

      ids = SP3.satellite_ids(merged)
      assert "G03" in ids, "merged output must cover G03 from the center that has it"
      assert Enum.sort(ids) == ["G01", "G02", "G03"]

      assert report.quarantined == []
      assert report.clock_outliers == []
      # G03 had a single source (index 0) -> carried through, recorded.
      assert [%{satellite: "G03", sources: [0]}] = report.single_source
    end

    test "reports consensus agreement metrics for a multi-source merge (B2)" do
      # Two centers that agree within tolerance but not exactly: G01 differs by
      # 0.1 m in X and ~2 ns in clock, G02 is identical. The combined product is
      # the mean, and the agreement table quantifies the per-cell dispersion.
      a =
        sp3_records([
          {"G01", [15_000.0000, -20_000.0, 5000.0], 100.000},
          {"G02", [16_000.0000, -21_000.0, 6000.0], 200.000}
        ])

      b =
        sp3_records([
          {"G01", [15_000.0001, -20_000.0, 5000.0], 100.002},
          {"G02", [16_000.0000, -21_000.0, 6000.0], 200.000}
        ])

      assert {:ok, _merged, report} = SP3.merge([a, b])

      agreement = report.agreement
      assert is_map(agreement)

      # Whole-product aggregates: both cells have a two-source consensus, so the
      # position dispersion is non-nil and physically small (the 0.1 m G01 split
      # pooled with the exact G02 cell).
      assert agreement.position_rms_m > 0.0
      assert agreement.position_rms_m < 0.5
      assert agreement.position_max_m >= agreement.position_rms_m
      assert agreement.clock_rms_s > 0.0

      # One per-cell entry per accepted cell, each with a two-member consensus.
      assert length(agreement.cells) == 2
      assert Enum.all?(agreement.cells, &(&1.position_members == 2))

      g01 = Enum.find(agreement.cells, &(&1.satellite == "G01"))
      g02 = Enum.find(agreement.cells, &(&1.satellite == "G02"))
      # G01's members sit 0.1 m apart, so each is 0.05 m from the mean.
      assert_in_delta g01.position_rms_m, 0.05, 1.0e-3
      # G02 is identical across centers: zero dispersion.
      assert g02.position_rms_m == 0.0

      # Per-epoch aggregate over the single fixture epoch, multi-source cells.
      assert [epoch] = agreement.epochs
      assert epoch.satellites == 2
      assert epoch.position_rms_m > 0.0
    end

    test "quarantines a satellite all centers disagree on" do
      # Three centers, mutually beyond the default 0.5 m tolerance on G01.
      a = sp3_records([{"G01", [15_000.000, -20_000.0, 5000.0], 100.0}])
      b = sp3_records([{"G01", [15_000.010, -20_000.0, 5000.0], 100.0}])
      c = sp3_records([{"G01", [15_000.020, -20_000.0, 5000.0], 100.0}])

      assert {:ok, merged, report} = SP3.merge([a, b, c])

      refute "G01" in SP3.satellite_ids(merged),
             "no consensus -> G01 omitted, not averaged across disagreeing centers"

      assert [%{satellite: "G01"}] = report.quarantined
    end

    test "rejects an outlier and combines the agreeing centers" do
      # A and B agree on G01; C is 10 m off in X.
      a = sp3_records([{"G01", [15_000.000, -20_000.0, 5000.0], 100.0}])
      b = sp3_records([{"G01", [15_000.000, -20_000.0, 5000.0], 100.0}])
      c = sp3_records([{"G01", [15_000.010, -20_000.0, 5000.0], 100.0}])

      assert {:ok, merged, report} = SP3.merge([a, b, c])

      assert "G01" in SP3.satellite_ids(merged)
      assert [%{satellite: "G01", sources: [2]}] = report.position_outliers
      assert report.quarantined == []
    end

    test "guarded precedence replaces a corrupt preferred center" do
      preferred = sp3_records([{"G01", [16_000.0, -20_000.0, 5000.0], nil}])
      agreeing_a = sp3_records([{"G01", [15_000.0, -20_000.0, 5000.0], nil}])
      agreeing_b = sp3_records([{"G01", [15_000.0002, -20_000.0, 5000.0], nil}])

      assert {:ok, merged, report} =
               SP3.merge([preferred, agreeing_a, agreeing_b],
                 combine: :precedence,
                 min_agree: 1,
                 outlier_reject: [position_m: 0.5, clock_ns: 5.0]
               )

      assert {:ok, state} = SP3.state(merged, "G01", 0)
      assert state.x_m == 15_000_000.0
      assert [%{satellite: "G01", sources: [0]}] = report.position_outliers
    end

    test "rejects differently labeled frames unless reconciliation is explicitly enabled" do
      {:ok, a} = SP3.parse(sp3_bytes([{"G01", [15_000.0, -20_000.0, 5000.0], 100.0}], "IGS20"))
      {:ok, b} = SP3.parse(sp3_bytes([{"G01", [15_000.0, -20_000.0, 5000.0], 100.0}], "IGc20"))

      assert {:error, reason} = SP3.merge([a, b])
      assert to_string(reason) =~ "mismatched coordinate systems"
    end

    test "still rejects a genuine cross-datum pair (IGS14 vs IGS20)" do
      {:ok, a} = SP3.parse(sp3_bytes([{"G01", [15_000.0, -20_000.0, 5000.0], 100.0}], "IGS14"))
      {:ok, b} = SP3.parse(sp3_bytes([{"G01", [15_000.0, -20_000.0, 5000.0], 100.0}], "IGS20"))

      assert {:error, _} = SP3.merge([a, b])
    end

    test "asserted frame equivalence merges and reports no math" do
      {:ok, a} = SP3.parse(sp3_bytes([{"G01", [15_000.0, -20_000.0, 5000.0], 100.0}], "IGS14"))
      {:ok, b} = SP3.parse(sp3_bytes([{"G02", [16_000.0, -21_000.0, 6000.0], 200.0}], "ITRF2"))

      assert {:ok, merged, report} =
               SP3.merge([a, b],
                 asserted_frame_label_sets: [["IGS14", "ITRF2"]],
                 min_agree: 1
               )

      assert Enum.sort(SP3.satellite_ids(merged)) == ["G01", "G02"]

      assert [
               %{
                 method: :asserted_equivalence,
                 source_index: 1,
                 source_label: "ITRF2",
                 target_label: "IGS14",
                 asserted_label_set: ["IGS14", "ITRF2"],
                 parameters: nil,
                 rates: nil,
                 records_affected: 1
               }
             ] = report.frame_reconciliations
    end

    test "Helmert frame reconciliation reports published table values" do
      {:ok, a} = SP3.parse(sp3_bytes([{"G01", [14_000.0, -19_000.0, 4000.0], 100.0}], "IGS14"))
      {:ok, b} = SP3.parse(sp3_bytes([{"G02", [15_000.0, -20_000.0, 5000.0], 200.0}], "IGS20"))

      assert {:ok, merged, report} = SP3.merge([a, b], helmert: true, min_agree: 1)
      assert {:ok, state} = SP3.state(merged, "G02", 0)
      assert_in_delta state.x_m, 14_999_999.992_3, 1.0e-6
      assert_in_delta state.y_m, -19_999_999.993_048_087, 1.0e-6
      assert_in_delta state.z_m, 5_000_000.000_396_175, 1.0e-6

      assert [
               %{
                 method: :helmert,
                 source_frame: "ITRF2020",
                 target_frame: "ITRF2014",
                 catalog_source_frame: "ITRF2020",
                 catalog_target_frame: "ITRF2014",
                 catalog_inverse: false,
                 records_affected: 1
               } = reconciliation
             ] = report.frame_reconciliations

      assert reconciliation.parameters.translation_mm == [-1.4, -0.9, 1.4]
      assert reconciliation.parameters.scale_ppb == -0.42
      assert reconciliation.rates.translation_mm_per_year == [0.0, -0.1, 0.2]
    end

    test "accepts commensurate mixed epoch intervals and rejects non-divisible ones" do
      {:ok, a} =
        SP3.parse(sp3_bytes([{"G01", [15_000.0, -20_000.0, 5000.0], 100.0}], "IGS14", 900.0))

      {:ok, b} =
        SP3.parse(sp3_bytes([{"G01", [15_000.0, -20_000.0, 5000.0], 100.0}], "IGS14", 300.0))

      # 15-min + 5-min uses the finest union cadence, not interpolation.
      assert {:ok, _merged, _report} = SP3.merge([a, b], min_agree: 1)

      # A finer target is valid: a coarse input contributes only its real cells.
      assert {:ok, _merged, _report} = SP3.merge([a], epoch_interval_s: 300.0)

      # A non-divisible cadence (900 vs 400) is still rejected.
      {:ok, d} =
        SP3.parse(sp3_bytes([{"G01", [15_000.0, -20_000.0, 5000.0], 100.0}], "IGS14", 400.0))

      assert {:error, reason} = SP3.merge([a, d])
      assert to_string(reason) =~ "mismatched epoch intervals"
    end

    test "filters the merged product to requested constellations" do
      multi =
        sp3_records([
          {"G01", [15_000.0, -20_000.0, 5000.0], 100.0},
          {"E01", [21_000.0, -1000.0, 13_000.0], 120.0}
        ])

      assert {:ok, merged, _report} = SP3.merge([multi], systems: [:gps])
      assert SP3.satellite_ids(merged) == ["G01"]

      assert {:error, {:unsupported_system, :bad}} = SP3.merge([multi], systems: [:bad])
    end

    test "window verdict mapping follows the product-derived stencil at a daily seam" do
      first = SP3.load!(@daily_sp3)
      second = shifted_daily_product_with_x_offset(3_000.0)
      seam = first |> SP3.epochs_j2000_seconds() |> List.last()

      assert {:ok, merged, report} =
               SP3.merge([first, second],
                 combine: :precedence,
                 min_agree: 1,
                 verify_continuity: [orbit_class: :meo_gnss, residual_tolerance_m: nil]
               )

      assert %{attested?: false, defects: [_ | _], splices: [_ | _]} = report.continuity
      assert {:ok, %{before_s: 1_500.0, after_s: 1_500.0}} = SP3.stencil_extent(merged)

      inside_one_day = {seam - 18.0 * 3_600.0, seam - 6.0 * 3_600.0}

      assert {:ok,
              %{
                decision: :accept,
                accepted: true,
                influencing_defects: [],
                influencing_splices: [],
                all_defects: [_ | _],
                all_splices: [_ | _]
              }} =
               SP3.merge_continuity_verdict(report, merged, elem(inside_one_day, 0), elem(inside_one_day, 1))

      assert {:ok,
              %{
                decision: :refuse,
                accepted: false,
                influencing_defects: [_ | _],
                influencing_splices: [%{from_sources: [0], to_sources: [1], crosses_contributors: true} | _]
              }} = SP3.merge_continuity_verdict(report, merged, seam - 600.0, seam + 600.0)

      assert {:ok, %{decision: :refuse, accepted: false}} =
               SP3.merge_continuity_verdict(report, merged, seam - 7_200.0, seam - 1_500.0)

      assert {:ok, %{decision: :accept, accepted: true}} =
               SP3.merge_continuity_verdict(report, merged, seam - 7_200.0, seam - 1_500.001)

      assert {:ok, %{decision: :refuse, influencing_splices: [], all_splices: []}} =
               SP3.continuity_verdict(merged, seam - 600.0, seam + 600.0,
                 orbit_class: :meo_gnss,
                 residual_tolerance_m: nil
               )
    end

    test "merge verdict preserves nil when continuity verification was not requested" do
      first = SP3.load!(@daily_sp3)
      [from_j2000_s | _] = SP3.epochs_j2000_seconds(first)
      assert {:ok, merged, report} = SP3.merge([first], min_agree: 1)
      assert report.continuity == nil

      assert {:ok, nil} =
               SP3.merge_continuity_verdict(report, merged, from_j2000_s, from_j2000_s + 300.0)
    end
  end

  describe "clock_reference_offset/3 and align_clock_reference/3" do
    defp shifted_pair do
      pos = [
        {"G01", [15_000.0, -20_000.0, 5000.0]},
        {"G02", [16_000.0, -21_000.0, 6000.0]},
        {"G03", [17_000.0, -22_000.0, 7000.0]}
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
