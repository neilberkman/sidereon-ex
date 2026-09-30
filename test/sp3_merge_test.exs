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

  defp fixed(value, decimals, width), do: String.pad_leading(:erlang.float_to_binary(value, decimals: decimals), width)

  defp padded(integer, width), do: String.pad_leading(Integer.to_string(integer), width)

  # Six GPS satellites on circular trajectories on a 300 s grid from 2020-06-25
  # 00:00, the core's merge-coverage fixture: `first` and `count` pick the
  # epochs, in 300 s steps from 00:00.
  defp coverage_sp3(first, count) do
    epoch_fields = fn index -> "2020  6 25 #{padded(div(index, 12), 2)}#{padded(rem(index, 12) * 5, 3)}  0.00000000" end

    header = [
      "#cP#{epoch_fields.(first)}     #{padded(count, 3)} ORBIT IGS14 FIT  TST",
      "## 2111 #{fixed(345_600.0 + first * 300, 8, 14)}   300.00000000 59025 #{fixed(first * 300 / 86_400, 13, 0)}",
      "+    6   G01G02G03G04G05G06  0  0  0  0  0  0  0  0  0  0  0",
      "++         0  0  0  0  0  0  0  0  0  0  0  0  0  0  0  0  0",
      "%c G  cc GPS ccc cccc cccc cccc cccc ccccc ccccc ccccc ccccc",
      "%c cc cc ccc ccc cccc cccc cccc cccc ccccc ccccc ccccc ccccc",
      "%f  1.2500000  1.025000000  0.00000000000  0.000000000000000",
      "%f  0.0000000  0.000000000  0.00000000000  0.000000000000000",
      "%i    0    0    0    0      0      0      0      0         0",
      "%i    0    0    0    0      0      0      0      0         0",
      "/* SYNTHETIC SP3 COVERAGE FIXTURE"
    ]

    records =
      Enum.flat_map(first..(first + count - 1)//1, fn index ->
        seconds = index * 300.0

        ["*  " <> epoch_fields.(index)] ++
          Enum.map(1..6, fn prn ->
            angle = seconds * 2.0 * :math.pi() / 43_200.0 + prn * 0.3

            "PG0#{prn}" <>
              Enum.map_join(
                [
                  26_560.0 * :math.cos(angle),
                  26_560.0 * :math.sin(angle) * 0.6,
                  26_560.0 * :math.sin(angle) * 0.8,
                  10.0 + prn
                ],
                &fixed(&1, 6, 14)
              )
          end)
      end)

    {:ok, sp3} = SP3.parse(Enum.join(header ++ records ++ ["EOF", ""], "\n"))
    sp3
  end

  defp coverage_precedence(scope),
    do: [combine: :precedence, precedence_scope: scope, min_agree: 1, position_tolerance_m: 5.0]

  # A report epoch as seconds since J2000 in its own scale, whole days first,
  # then the day fraction, as the core's split conversion forms them. For the
  # whole-second epochs of these fixtures the result is the exact second the
  # SP3 epoch axis holds.
  defp merge_epoch_j2000_s(%{jd_whole: jd_whole, jd_fraction: jd_fraction}),
    do: (jd_whole - 2_451_545.0) * 86_400.0 + jd_fraction * 86_400.0

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
    {:ok, text} = SP3.to_sp3_string(product)
    {:ok, writer_derived} = SP3.parse(text)
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

    test "a mean-combined merge finer than the record columns is refused by the writer, by name" do
      # G01's X differs by 1 mm between the centers, well within tolerance, so
      # the mean combine holds 15000.0000005 km, which an F14.6 kilometer column
      # cannot state. The merge itself succeeds; writing it is refused naming
      # the cell rather than rounded half a millimeter away.
      a =
        sp3_records([
          {"G01", [15_000.000000, -20_000.0, 5000.0], 100.0},
          {"G02", [16_000.0, -21_000.0, 6000.0], 200.0}
        ])

      b =
        sp3_records([
          {"G01", [15_000.000001, -20_000.0, 5000.0], 100.0},
          {"G02", [16_000.0, -21_000.0, 6000.0], 200.0}
        ])

      assert {:ok, merged, _report} = SP3.merge([a, b])
      assert Enum.sort(SP3.satellite_ids(merged)) == ["G01", "G02"]

      assert {:error, {:record_value_not_representable, fields}} = SP3.to_sp3_string(merged)
      assert %{field: "position x", satellite: "G01", epoch_index: 0} = fields
      assert_in_delta fields.stored, 15_000_000.0005, 1.0e-6
      assert {:error, {:record_value_not_representable, ^fields}} = SP3.to_iodata(merged)
    end

    test "quarantines a position all centers disagree on and keeps the clock" do
      # Three centers, mutually beyond the default 0.5 m tolerance on G01.
      a = sp3_records([{"G01", [15_000.000, -20_000.0, 5000.0], 100.0}])
      b = sp3_records([{"G01", [15_000.010, -20_000.0, 5000.0], 100.0}])
      c = sp3_records([{"G01", [15_000.020, -20_000.0, 5000.0], 100.0}])

      assert {:ok, merged, report} = SP3.merge([a, b, c])

      # No position consensus: the position is omitted, not averaged across the
      # disagreeing centers.
      assert {:error, {:unknown_satellite, "G01"}} = SP3.state(merged, "G01", 0)
      assert {:ok, []} = SP3.states_at(merged, 0)
      assert [%{satellite: "G01", sources: [0, 1, 2]}] = report.quarantined

      # The clock is a separate channel. One satellite is fewer than the default
      # `clock_min_common` of 5, so only the first center's clock is on the
      # common datum; G01 stays in the product as that clock-only record.
      assert SP3.satellite_ids(merged) == ["G01"]
      assert [%{satellite: "G01", sources: [0]}] = report.single_source

      assert [cell] = report.agreement.cells
      assert %{satellite: "G01", position_members: 0, position_rms_m: nil, position_max_m: nil, clock_members: 1} = cell
    end

    test "omits a satellite with no agreed position and no clock" do
      # G01 as above but with no clock anywhere; G02 agrees so the product is not
      # empty.
      a = sp3_records([{"G01", [15_000.000, -20_000.0, 5000.0], nil}, {"G02", [16_000.0, -21_000.0, 6000.0], nil}])
      b = sp3_records([{"G01", [15_000.010, -20_000.0, 5000.0], nil}, {"G02", [16_000.0, -21_000.0, 6000.0], nil}])
      c = sp3_records([{"G01", [15_000.020, -20_000.0, 5000.0], nil}, {"G02", [16_000.0, -21_000.0, 6000.0], nil}])

      assert {:ok, merged, report} = SP3.merge([a, b, c])

      assert SP3.satellite_ids(merged) == ["G02"]
      assert {:error, {:unknown_satellite, "G01"}} = SP3.state(merged, "G01", 0)
      assert [%{satellite: "G01", sources: [0, 1, 2]}] = report.quarantined
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

    test "accepts mixed epoch intervals on the greatest common grid" do
      {:ok, a} =
        SP3.parse(sp3_bytes([{"G01", [15_000.0, -20_000.0, 5000.0], 100.0}], "IGS14", 900.0))

      {:ok, b} =
        SP3.parse(sp3_bytes([{"G01", [15_000.0, -20_000.0, 5000.0], 100.0}], "IGS14", 300.0))

      # 15-min + 5-min uses the finest union cadence, not interpolation.
      assert {:ok, _merged, _report} = SP3.merge([a, b], min_agree: 1)

      # A finer target is valid: a coarse input contributes only its real cells.
      assert {:ok, _merged, _report} = SP3.merge([a], epoch_interval_s: 300.0)

      # 900 s and 400 s inputs merge on their 100 s greatest common grid, which
      # holds every input epoch; the core no longer refuses them.
      {:ok, d} =
        SP3.parse(sp3_bytes([{"G01", [15_000.0, -20_000.0, 5000.0], 100.0}], "IGS14", 400.0))

      assert {:ok, merged, _report} = SP3.merge([a, d], min_agree: 1)
      assert SP3.epochs_j2000_seconds(merged) == SP3.epochs_j2000_seconds(a)
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

    test "window verdict mapping follows the selected interpolation nodes at a daily seam" do
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
      assert {:ok, %{before_s: 3_300.0, after_s: 3_300.0}} = SP3.stencil_extent(merged)

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
               SP3.merge_continuity_verdict(report, elem(inside_one_day, 0), elem(inside_one_day, 1))

      assert {:ok,
              %{
                decision: :refuse,
                accepted: false,
                influencing_defects: [_ | _],
                influencing_splices: [%{from_sources: [0], to_sources: [1], crosses_contributors: true} | _]
              }} = SP3.merge_continuity_verdict(report, seam - 600.0, seam + 600.0)

      # A merge verdict reads the nodes the window's interpolations select, as
      # RTKLIB pephpos selects them: the last node strictly before the query and
      # five either side of it. A window ending on the node five before the seam
      # reaches the node before the seam; any later end reaches the seam record,
      # a pair end of the violation. The stencil extent no longer decides a merge
      # verdict, so a window ending at it is accepted.
      assert {:ok, %{decision: :accept, accepted: true}} =
               SP3.merge_continuity_verdict(report, seam - 7_200.0, seam - 3_300.0)

      assert {:ok, %{decision: :accept, accepted: true}} =
               SP3.merge_continuity_verdict(report, seam - 7_200.0, seam - 1_500.0)

      assert {:ok, %{decision: :refuse, accepted: false}} =
               SP3.merge_continuity_verdict(report, seam - 7_200.0, seam - 1_499.999)

      # The nodes those verdicts read: the window ending five nodes before the
      # seam reaches the node before it, and any later end reaches the seam
      # record. They are the merged product's own node selection.
      for satellite <- ["C08", "C21"] do
        assert {:ok, miss} = SP3.merge_continuity_selected_nodes(report, satellite, seam - 7_200.0, seam - 1_500.0)
        assert List.last(miss) == seam - 300.0

        assert {:ok, reach} =
                 SP3.merge_continuity_selected_nodes(report, satellite, seam - 7_200.0, seam - 1_499.999)

        assert List.last(reach) == seam
        assert reach == Enum.sort(reach)
        assert {:ok, ^reach} = SP3.selected_nodes(merged, satellite, seam - 7_200.0, seam - 1_499.999)
      end

      assert {:ok, %{decision: :refuse, influencing_splices: [], all_splices: []}} =
               SP3.continuity_verdict(merged, seam - 600.0, seam + 600.0,
                 orbit_class: :meo_gnss,
                 residual_tolerance_m: nil
               )
    end

    test "the merge continuity report names each splice's cells, contributors and measurements" do
      first = SP3.load!(@daily_sp3)
      second = shifted_daily_product_with_x_offset(3_000.0)
      seam = first |> SP3.epochs_j2000_seconds() |> List.last()

      assert {:ok, _merged, report} =
               SP3.merge([first, second],
                 combine: :precedence,
                 min_agree: 1,
                 verify_continuity: [orbit_class: :meo_gnss, residual_tolerance_m: nil]
               )

      # With the residual check off, the speed gate alone finds the seam pair
      # of each satellite, the last record of the first day (source 0) and the
      # first of the shifted day (source 1), 300 s apart.
      assert %{splices: [_ | _] = splices, violations: violations} = report.continuity
      assert violations == splices

      for splice <- splices do
        defect = splice.defect
        assert defect.kind == :speed_bound
        assert {defect.from_j2000_s, defect.to_j2000_s} == {seam, seam + 300.0}
        assert defect.interval_s == 300.0
        assert defect.implied_speed_m_s == defect.displacement_m / defect.interval_s
        assert {defect.magnitude, defect.bound} == {defect.implied_speed_m_s, defect.bound_m_s}
        assert defect.implied_speed_m_s > defect.bound_m_s
        refute Map.has_key?(defect, :node_epochs_j2000_s)

        assert splice.sources == [0, 1]

        assert splice.cells == [
                 %{epoch_j2000_s: seam, role: :pair_end, selection: %{kind: :single_source, source: 0}},
                 %{epoch_j2000_s: seam + 300.0, role: :pair_end, selection: %{kind: :single_source, source: 1}}
               ]
      end
    end

    test "the report lists input epochs off an explicit target grid and what it did not write" do
      first = SP3.load!(@daily_sp3)
      epochs = SP3.epochs_j2000_seconds(first)
      assert length(epochs) == 288

      # A 600 s target over a 300 s product holds every other input epoch.
      assert {:ok, merged, report} = SP3.merge([first], min_agree: 1, epoch_interval_s: 600.0)
      assert length(SP3.epochs_j2000_seconds(merged)) == 144

      assert length(report.dropped_input_epochs) == 144

      assert Enum.all?(report.dropped_input_epochs, fn dropped ->
               dropped.source == 0 and rem(dropped.epoch_index, 2) == 1 and
                 dropped.reason == :off_target_grid and is_binary(dropped.epoch.time_scale)
             end)

      assert report.omitted_epochs == []
      assert report.arc_withheld == []
      # One source is its own clock datum, so no clock of it is left out.
      assert report.clock_omissions == []
    end

    test "satellite-arc precedence omits empty epochs and reports withheld cells and clocks" do
      # Source A carries epochs 0-71 and source B epochs 60-83. A owns every
      # satellite arc, so B's twelve epochs past A's end hold no cell: they are
      # not written, and the report lists each of them, each withheld position
      # and each of B's clocks there, whose datum offset to A is not observable
      # past the overlap and is never extrapolated.
      a = coverage_sp3(0, 72)
      b = coverage_sp3(60, 24)
      b_axis = SP3.epochs_j2000_seconds(b)

      assert {:ok, merged, report} = SP3.merge([a, b], coverage_precedence(:satellite_arc))

      assert SP3.epochs_j2000_seconds(merged) == SP3.epochs_j2000_seconds(a)
      omitted = Enum.map(report.omitted_epochs, &merge_epoch_j2000_s/1)
      assert omitted == Enum.drop(b_axis, 12)

      assert length(report.arc_withheld) == 6 * 12

      assert Enum.all?(report.arc_withheld, fn flag ->
               flag.sources == [1] and merge_epoch_j2000_s(flag.epoch) in omitted
             end)

      assert length(report.clock_omissions) == 6 * 12

      assert Enum.all?(report.clock_omissions, fn omission ->
               omission.reason == :datum_not_observable and omission.source == 1 and
                 omission.preferred == nil and omission.cell_has_clock == false and
                 merge_epoch_j2000_s(omission.epoch) in omitted
             end)

      assert report.dropped_input_epochs == []
    end

    test "cell precedence writes positions past the overlap and names each clock it left out" do
      a = coverage_sp3(0, 72)
      b = coverage_sp3(60, 24)
      past = b |> SP3.epochs_j2000_seconds() |> Enum.drop(12)

      assert {:ok, merged, report} = SP3.merge([a, b], coverage_precedence(:cell))

      assert length(SP3.epochs_j2000_seconds(merged)) == 84
      assert report.omitted_epochs == []
      assert report.arc_withheld == []

      # B's positions fill epochs 72-83; its clocks there are not written.
      assert length(report.clock_omissions) == 6 * 12

      assert Enum.all?(report.clock_omissions, fn omission ->
               omission.reason == :datum_not_observable and omission.source == 1 and
                 omission.cell_has_clock == false and merge_epoch_j2000_s(omission.epoch) in past
             end)
    end

    test "an explicit fractional target interval merges on its grid and lists the input epochs off it" do
      # 450.5 s is a whole number of the 10 ns ticks an SP3 interval states.
      # Anchored at 00:00, its grid meets the 300 s input grid again only after
      # 270,300 s, so every input epoch after the first is off it.
      a = coverage_sp3(0, 72)
      axis = SP3.epochs_j2000_seconds(a)

      assert {:ok, merged, report} = SP3.merge([a], min_agree: 1, epoch_interval_s: 450.5)
      assert SP3.epochs_j2000_seconds(merged) == [hd(axis)]

      assert Enum.map(report.dropped_input_epochs, &{&1.source, &1.epoch_index, &1.reason}) ==
               Enum.map(1..71, &{0, &1, :off_target_grid})

      assert Enum.map(report.dropped_input_epochs, &merge_epoch_j2000_s(&1.epoch)) == tl(axis)

      # The core refuses a target no whole number of ticks states.
      assert {:error, %{kind: "sp3_epoch_interval", field: "target_epoch_interval_s"} = reason} =
               SP3.merge([coverage_sp3(0, 2)], min_agree: 1, epoch_interval_s: 1.0e-9)

      assert is_binary(reason.value)
    end

    test "merge verdict preserves nil when continuity verification was not requested" do
      first = SP3.load!(@daily_sp3)
      [from_j2000_s | _] = SP3.epochs_j2000_seconds(first)
      assert {:ok, _merged, report} = SP3.merge([first], min_agree: 1)
      assert report.continuity == nil

      assert {:ok, nil} =
               SP3.merge_continuity_verdict(report, from_j2000_s, from_j2000_s + 300.0)

      assert {:ok, nil} =
               SP3.merge_continuity_selected_nodes(report, "C21", from_j2000_s, from_j2000_s + 300.0)
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
