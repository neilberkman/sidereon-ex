defmodule Sidereon.GNSS.ConstellationTest do
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.Constellation
  alias Sidereon.GNSS.Constellation.Record
  alias Sidereon.GNSS.SP3

  @fixtures Path.join(__DIR__, "fixtures/gnss_constellation")

  @sp3 """
  #cP2020  6 24  0  0  0.00000000       1 ORBIT IGS14 FIT  TST
  ## 2111 432000.00000000   900.00000000 59024 0.0000000000000
  +    2   G03G32  0  0  0  0  0  0  0  0  0  0  0  0  0  0  0
  ++         0  0  0  0  0  0  0  0  0  0  0  0  0  0  0  0  0
  %c G  cc GPS ccc cccc cccc cccc cccc ccccc ccccc ccccc ccccc
  %c cc cc ccc ccc cccc cccc cccc cccc ccccc ccccc ccccc ccccc
  %f  1.2500000  1.025000000  0.00000000000  0.000000000000000
  %f  0.0000000  0.000000000  0.00000000000  0.000000000000000
  %i    0    0    0    0      0      0      0      0         0
  %i    0    0    0    0      0      0      0      0         0
  /* TEST SP3-c FIXTURE
  *  2020  6 24  0  0  0.00000000
  PG03  15000.000000 -20000.000000   5000.000000    123.456789
  PG32  -1234.567890   2345.678901  -3456.789012    100.000000
  EOF
  """

  defp celestrak_omms do
    celestrak_json() |> Jason.decode!()
  end

  defp celestrak_json do
    @fixtures
    |> Path.join("gps_ops_sample.json")
    |> File.read!()
  end

  defp full_celestrak_json do
    celestrak_omms()
    |> Enum.map(&full_omm/1)
    |> Jason.encode!()
  end

  defp full_omm(omm) do
    Map.merge(
      %{
        "OBJECT_ID" => "2026-001A",
        "EPOCH" => "2026-06-01T00:00:00.000000",
        "MEAN_MOTION" => 2.00563771,
        "ECCENTRICITY" => 0.0102442,
        "INCLINATION" => 55.9944,
        "RA_OF_ASC_NODE" => 98.6138,
        "ARG_OF_PERICENTER" => 56.9091,
        "MEAN_ANOMALY" => 304.0464,
        "EPHEMERIS_TYPE" => 0,
        "CLASSIFICATION_TYPE" => "U",
        "ELEMENT_SET_NO" => 999,
        "REV_AT_EPOCH" => 21_193,
        "BSTAR" => 0.0,
        "MEAN_MOTION_DOT" => -1.2e-7,
        "MEAN_MOTION_DDOT" => 0.0
      },
      omm
    )
  end

  defp navcen_html do
    @fixtures
    |> Path.join("navcen_gps_sample.html")
    |> File.read!()
  end

  defp merged_records do
    {:ok, records} = Constellation.from_celestrak_omm(:gps, celestrak_omms())
    {:ok, statuses} = Constellation.parse_navcen_html(navcen_html())
    Constellation.merge_navcen(records, statuses)
  end

  defp galileo_omm, do: %{"OBJECT_NAME" => "GSAT0210 (GALILEO 13)", "NORAD_CAT_ID" => 41_859}

  defp glonass_omm, do: %{"OBJECT_NAME" => "COSMOS 2456 (730)", "NORAD_CAT_ID" => 36_111}

  defp beidou_omm, do: %{"OBJECT_NAME" => "BEIDOU-3 M1 (C19)", "NORAD_CAT_ID" => 43_001}

  defp qzss_omm, do: %{"OBJECT_NAME" => "QZS-2 (QZSS/PRN 194)", "NORAD_CAT_ID" => 42_738}

  defp record(prn, opts \\ []) do
    %Record{
      system: Keyword.get(opts, :system, :gps),
      prn: prn,
      svn: Keyword.get(opts, :svn, prn + 60),
      norad_id: Keyword.get(opts, :norad_id, 40_000 + prn),
      sp3_id: Keyword.get(opts, :sp3_id, "G" <> String.pad_leading(Integer.to_string(prn), 2, "0")),
      active?: Keyword.get(opts, :active?, true),
      usable?: Keyword.get(opts, :usable?, true),
      source: Keyword.get(opts, :source, %{})
    }
  end

  describe "from_celestrak_omm/2: GPS" do
    test "accepts the canonical raw JSON feed input" do
      assert {:ok, records} = Constellation.from_celestrak_json(full_celestrak_json(), :gps)
      assert Enum.map(records, & &1.sp3_id) == ["G03", "G05", "G13", "G19"]

      assert {:ok, root_records} = Sidereon.from_celestrak_json(full_celestrak_json(), :gps)
      assert Enum.map(root_records, & &1.prn) == [3, 5, 13, 19]
    end

    test "normalizes GPS PRN/NORAD records from gps-ops OMM JSON" do
      assert {:ok, records} = Constellation.from_celestrak_omm(:gps, celestrak_omms())
      assert Enum.map(records, & &1.prn) == [3, 5, 13, 19]

      prn3 = Enum.find(records, &(&1.prn == 3))
      assert %Record{} = prn3
      assert prn3.system == :gps
      assert prn3.svn == nil
      assert prn3.norad_id == 40_294
      assert prn3.sp3_id == "G03"
      assert prn3.active?
      assert prn3.usable?
      assert prn3.fdma_channel == nil
      assert prn3.source.celestrak.group == "gps-ops"
      assert prn3.source.celestrak.block_type == "IIF"
      assert prn3.source.navcen == nil
    end

    test "rejects a gps-ops record without a PRN in OBJECT_NAME" do
      bad = [%{"OBJECT_NAME" => "GPS WITHOUT PRN", "NORAD_CAT_ID" => 1}]

      assert {:error, {:bad_celestrak_record, {:missing_prn, "GPS WITHOUT PRN"}, omm}} =
               Constellation.from_celestrak_omm(:gps, bad)

      assert omm["OBJECT_NAME"] == "GPS WITHOUT PRN"
    end

    test "a record missing NORAD_CAT_ID aborts with a tagged error" do
      bad = [%{"OBJECT_NAME" => "GPS BIIF-8  (PRN 03)"}]

      assert {:error, {:bad_celestrak_record, {:missing_field, "NORAD_CAT_ID"}, _}} =
               Constellation.from_celestrak_omm(:gps, bad)
    end

    test "rejects a non-list input" do
      assert {:error, {:invalid_input, {:not_a_list, :nope}}} =
               Constellation.from_celestrak_omm(:gps, :nope)
    end
  end

  describe "from_celestrak_omm/2: multi-system (the 4-constellation gain)" do
    test "resolves a Galileo GSAT build id to its SVID/PRN" do
      assert {:ok, [rec]} = Constellation.from_celestrak_omm(:galileo, [galileo_omm()])
      assert rec.system == :galileo
      assert rec.prn == 1
      assert rec.sp3_id == "E01"
      assert rec.fdma_channel == nil
    end

    test "resolves a GLONASS number to its slot and FDMA channel" do
      assert {:ok, [rec]} = Constellation.from_celestrak_omm(:glonass, [glonass_omm()])
      assert rec.system == :glonass
      assert rec.prn == 1
      assert rec.sp3_id == "R01"
      # GLONASS is FDMA: slot 1 carries channel k = 1.
      assert rec.fdma_channel == 1
    end

    test "resolves a BeiDou inline PRN" do
      assert {:ok, [rec]} = Constellation.from_celestrak_omm(:beidou, [beidou_omm()])
      assert rec.system == :beidou
      assert rec.prn == 19
      assert rec.sp3_id == "C19"
      assert rec.fdma_channel == nil
    end

    test "resolves a QZSS broadcast PRN to its RINEX slot" do
      assert {:ok, [rec]} = Constellation.from_celestrak_omm(:qzss, [qzss_omm()])
      assert rec.system == :qzss
      assert rec.prn == 2
      assert rec.sp3_id == "J02"
    end

    test "a five-system catalog sorts by {system, prn} and carries every system" do
      records =
        [
          elem(Constellation.from_celestrak_omm(:gps, celestrak_omms()), 1),
          elem(Constellation.from_celestrak_omm(:glonass, [glonass_omm()]), 1),
          elem(Constellation.from_celestrak_omm(:galileo, [galileo_omm()]), 1),
          elem(Constellation.from_celestrak_omm(:beidou, [beidou_omm()]), 1),
          elem(Constellation.from_celestrak_omm(:qzss, [qzss_omm()]), 1)
        ]
        |> List.flatten()

      systems = records |> Enum.map(& &1.system) |> Enum.uniq() |> Enum.sort()
      assert systems == [:beidou, :galileo, :glonass, :gps, :qzss]

      # to_csv sorts by {system, prn}; the SP3 ids order by RINEX letter.
      # Core orders by the GnssSystem enum (G, R, E, C, J), then PRN.
      ids = records |> Constellation.to_csv() |> String.split("\n", trim: true) |> tl()
      sp3_ids = Enum.map(ids, &(&1 |> String.split(",") |> List.last()))
      assert sp3_ids == ["G03", "G05", "G13", "G19", "R01", "E01", "C19", "J02"]
    end
  end

  describe "from_celestrak_omm_lenient/2" do
    test "accepts raw JSON through both lenient public entry points" do
      json = Jason.encode!(Enum.map(celestrak_omms() ++ [galileo_omm()], &full_omm/1))

      assert {:ok, %Constellation.Catalog{} = catalog} =
               Constellation.from_celestrak_omm_lenient(json, :gps)

      assert Enum.map(catalog.records, & &1.sp3_id) == ["G03", "G05", "G13", "G19"]
      assert Enum.map(catalog.skipped, & &1.object_name) == ["GSAT0210 (GALILEO 13)"]

      assert {:ok, alias_catalog} = Sidereon.from_celestrak_json_lenient(json, :gps)
      assert Enum.map(alias_catalog.records, & &1.prn) == [3, 5, 13, 19]
    end

    test "keeps resolvable records and collects unresolvable entries by identity" do
      feed =
        celestrak_omms() ++
          [galileo_omm(), %{"OBJECT_NAME" => "GPS WITHOUT PRN", "NORAD_CAT_ID" => 7}]

      assert {:ok, %Constellation.Catalog{} = catalog} =
               Constellation.from_celestrak_omm_lenient(:gps, feed)

      assert Enum.map(catalog.records, & &1.prn) == [3, 5, 13, 19]

      assert catalog.skipped == [
               %Constellation.SkippedOmm{object_name: "GSAT0210 (GALILEO 13)", norad_id: 41_859},
               %Constellation.SkippedOmm{object_name: "GPS WITHOUT PRN", norad_id: 7}
             ]
    end

    test "filters a combined feed down to one constellation" do
      feed = [galileo_omm(), glonass_omm(), beidou_omm(), qzss_omm()]

      assert {:ok, %Constellation.Catalog{records: [rec], skipped: skipped}} =
               Constellation.from_celestrak_omm_lenient(:beidou, feed)

      assert rec.sp3_id == "C19"
      assert length(skipped) == 3
    end

    test "returns an empty catalog for an empty feed" do
      assert {:ok, %Constellation.Catalog{records: [], skipped: []}} =
               Constellation.from_celestrak_omm_lenient(:gps, [])
    end

    test "leniency covers identity only: a malformed record still aborts" do
      feed = [%{"OBJECT_NAME" => "GPS BIIF-8  (PRN 03)"}]

      assert {:error, {:bad_celestrak_record, {:missing_field, "NORAD_CAT_ID"}, _}} =
               Constellation.from_celestrak_omm_lenient(:gps, feed)
    end
  end

  describe "scalar identity lookups" do
    test "glonass_fdma_channel/1 maps operational slots and antipodal pairs" do
      assert Constellation.glonass_fdma_channel(1) == 1
      assert Constellation.glonass_fdma_channel(2) == -4
      assert Constellation.glonass_fdma_channel(13) == -2
      assert Constellation.glonass_fdma_channel(24) == 2
      assert Constellation.glonass_fdma_channel(1) == Constellation.glonass_fdma_channel(5)
      assert Constellation.glonass_fdma_channel(0) == nil
      assert Constellation.glonass_fdma_channel(25) == nil
    end

    test "galileo_prn_for_gsat/1 resolves the published GSAT->SVID table" do
      assert Constellation.galileo_prn_for_gsat(210) == 1
      assert Constellation.galileo_prn_for_gsat(101) == 11
      assert Constellation.galileo_prn_for_gsat(999) == nil
    end

    test "glonass_slot_for_number/1 resolves the constellation table" do
      assert Constellation.glonass_slot_for_number(730) == 1
      assert Constellation.glonass_slot_for_number(99) == nil
    end

    test "sp3_id/2 renders the canonical RINEX token per system" do
      assert Constellation.sp3_id(:gps, 7) == "G07"
      assert Constellation.sp3_id(:galileo, 7) == "E07"
      assert Constellation.sp3_id(:glonass, 13) == "R13"
      assert Constellation.sp3_id(:beidou, 19) == "C19"
      assert Constellation.sp3_id(:qzss, 2) == "J02"
    end
  end

  describe "parse_navcen_html/1 and merge_navcen/2" do
    test "parses SVN and active NANU status rows" do
      assert {:ok, statuses} = Constellation.parse_navcen_html(navcen_html())
      assert Enum.map(statuses, &{&1.prn, &1.svn}) == [{3, 69}, {5, 50}, {13, 43}, {19, 59}]

      prn19 = Enum.find(statuses, &(&1.prn == 19))
      assert prn19.active_nanu?
      refute prn19.usable?
      assert prn19.nanu_type == "UNUSABLE"
    end

    test "reports a tagged error for HTML without GPS rows" do
      assert {:error, {:bad_navcen_html, _}} = Constellation.parse_navcen_html("<html></html>")
    end

    test "overlays NAVCEN SVN and usability on CelesTrak identity records" do
      records = merged_records()

      assert Enum.map(records, &{&1.prn, &1.svn, &1.usable?}) == [
               {3, 69, true},
               {5, 50, true},
               {13, nil, true},
               {19, 59, false}
             ]

      prn3 = Enum.find(records, &(&1.prn == 3))
      assert prn3.norad_id == 40_294
      assert prn3.source.navcen.nanu_type == "FCSTSUMM"

      prn13 = Enum.find(records, &(&1.prn == 13))
      assert prn13.norad_id == 68_791
      assert prn13.source.celestrak.block_type == "III"
      assert prn13.source.navcen_conflict.svn == 43
      assert prn13.source.navcen_conflict.block_type == "IIR"
      assert prn13.source.navcen == nil
    end
  end

  describe "CSV export" do
    test "exports the compact mapping CSV with active=false for unusable rows" do
      assert Constellation.to_csv(merged_records()) ==
               """
               prn,norad_cat_id,active,sp3_id
               3,40294,true,G03
               5,35752,true,G05
               13,68791,true,G13
               19,28190,false,G19
               """
    end

    test "the :booleans option renders Python-style True/False (default stays lowercase)" do
      titled = Constellation.to_csv(merged_records(), booleans: :title)
      assert titled =~ "3,40294,True,G03"
      assert titled =~ "19,28190,False,G19"

      assert Constellation.to_csv(merged_records()) =~ "3,40294,true,G03"
      assert Constellation.to_csv(merged_records(), booleans: :lower) =~ "19,28190,false,G19"
    end
  end

  describe "validation" do
    test "reports duplicate PRNs/NORAD ids and inactive/unusable PRNs keyed by {system, prn}" do
      records = [
        record(3, source: %{}),
        record(3, active?: false, source: %{})
      ]

      report = Constellation.validate(records)
      assert report.duplicate_prns == [{:gps, 3}]
      assert report.duplicate_norad_ids == [40_003]
      assert report.inactive_unusable_prns == [{:gps, 3}]
      refute Constellation.valid?(report)
    end

    test "does not flag a same-PRN record across two systems as a duplicate" do
      records = [
        record(1, system: :gps, sp3_id: "G01", norad_id: 40_001),
        record(1, system: :galileo, sp3_id: "E01", norad_id: 50_001)
      ]

      report = Constellation.validate(records)
      assert report.duplicate_prns == []
      assert Constellation.valid?(report)
    end

    test "compares active usable catalog ids against a loaded SP3 product" do
      {:ok, sp3} = SP3.parse(@sp3)
      assert SP3.satellite_ids(sp3) == ["G03", "G32"]

      report = Constellation.validate_sp3(merged_records(), sp3)
      assert report.missing_sp3_ids == ["G05", "G13"]
      assert report.extra_sp3_ids == ["G32"]
      assert report.inactive_unusable_prns == [{:gps, 19}]
      refute Constellation.valid?(report)
    end

    test "accepts a plain SP3 id list for validation" do
      report = Constellation.validate_sp3(merged_records(), ["G03", "G05", "G13"])
      assert report.missing_sp3_ids == []
      assert report.extra_sp3_ids == []
      assert report.inactive_unusable_prns == [{:gps, 19}]
    end

    test "validate_sp3!/2 is a build-time gate: :ok when clean, raises on a stale-active PRN" do
      clean = [
        record(3, sp3_id: "G03", source: %{}),
        record(5, sp3_id: "G05", source: %{})
      ]

      assert :ok = Constellation.validate_sp3!(clean, ["G03", "G05"])

      assert_raise ArgumentError, ~r/missing_sp3_ids.*G05/, fn ->
        Constellation.validate_sp3!(clean, ["G03"])
      end
    end
  end

  describe "diff/2" do
    test "reports no changes for identical catalog snapshots" do
      previous = [record(3), record(5)]
      diff = Constellation.diff(previous, Enum.reverse(previous))

      assert diff.added == []
      assert diff.removed == []
      refute Constellation.changed?(diff)
    end

    test "reports added/removed records sorted by system and PRN" do
      diff = Constellation.diff([record(3)], [record(9), record(3), record(5)])
      assert Enum.map(diff.added, & &1.prn) == [5, 9]
      assert diff.removed == []
      assert Constellation.changed?(diff)
    end

    test "reports a NORAD reassignment and status flips on a held PRN" do
      diff = Constellation.diff([record(13, norad_id: 28_190)], [record(13, norad_id: 68_791)])
      assert diff.norad_reassigned == [%{system: :gps, prn: 13, from: 28_190, to: 68_791}]
      assert Constellation.changed?(diff)

      flip = Constellation.diff([record(19, active?: true)], [record(19, active?: false)])
      assert flip.activity_changed == [%{system: :gps, prn: 19, from: true, to: false}]
    end

    test "reports an FDMA channel change on a held GLONASS slot" do
      previous = [%{record(8, system: :glonass, sp3_id: "R08") | fdma_channel: 6}]
      current = [%{record(8, system: :glonass, sp3_id: "R08") | fdma_channel: -4}]

      diff = Constellation.diff(previous, current)
      assert diff.fdma_channel_changed == [%{system: :glonass, prn: 8, from: 6, to: -4}]
    end

    test "diffs across systems independently" do
      diff =
        Constellation.diff([record(1, system: :gps, sp3_id: "G01")], [
          record(1, system: :galileo, sp3_id: "E01")
        ])

      assert Enum.map(diff.added, &{&1.system, &1.prn}) == [{:galileo, 1}]
      assert Enum.map(diff.removed, &{&1.system, &1.prn}) == [{:gps, 1}]
    end

    test "raises a clear ArgumentError for non-list inputs" do
      assert_raise ArgumentError, ~r/expects two record lists/, fn ->
        Constellation.diff(record(3), [record(3)])
      end
    end
  end
end
