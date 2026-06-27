defmodule Sidereon.GNSS.ConstellationTest do
  # Not async: the live-fetch error test toggles app env to disable CelesTrak
  # HTTP calls.
  use ExUnit.Case, async: false

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
    @fixtures
    |> Path.join("gps_ops_sample.json")
    |> File.read!()
    |> Jason.decode!()
  end

  defp navcen_html do
    @fixtures
    |> Path.join("navcen_gps_sample.html")
    |> File.read!()
  end

  defp merged_records do
    {:ok, records} = Constellation.from_celestrak_omm(celestrak_omms())
    {:ok, statuses} = Constellation.parse_navcen_html(navcen_html())
    Constellation.merge_navcen(records, statuses)
  end

  defp record(prn, opts \\ []) do
    %Record{
      system: Keyword.get(opts, :system, :gps),
      prn: prn,
      svn: Keyword.get(opts, :svn, prn + 60),
      norad_id: Keyword.get(opts, :norad_id, 40_000 + prn),
      sp3_id:
        Keyword.get(opts, :sp3_id, "G" <> String.pad_leading(Integer.to_string(prn), 2, "0")),
      active?: Keyword.get(opts, :active?, true),
      usable?: Keyword.get(opts, :usable?, true),
      source: Keyword.get(opts, :source, %{})
    }
  end

  describe "fetch_gps/1" do
    test "surfaces the typed CelesTrak dependency error" do
      Application.put_env(:sidereon, :celestrak_req_available, false)
      on_exit(fn -> Application.delete_env(:sidereon, :celestrak_req_available) end)

      assert {:error, :req_not_available} = Constellation.fetch_gps()
    end
  end

  describe "from_celestrak_omm/1" do
    test "normalizes GPS PRN/NORAD records from gps-ops OMM JSON" do
      assert {:ok, records} = Constellation.from_celestrak_omm(celestrak_omms())
      assert Enum.map(records, & &1.prn) == [3, 5, 13, 19]

      prn3 = Enum.find(records, &(&1.prn == 3))
      assert %Record{} = prn3
      assert prn3.system == :gps
      assert prn3.svn == nil
      assert prn3.norad_id == 40294
      assert prn3.sp3_id == "G03"
      assert prn3.active?
      assert prn3.usable?
      assert prn3.source.celestrak.group == "gps-ops"
      assert prn3.source.celestrak.block_type == "IIF"
    end

    test "rejects a gps-ops record without a PRN in OBJECT_NAME" do
      bad = [%{"OBJECT_NAME" => "GPS WITHOUT PRN", "NORAD_CAT_ID" => 1}]

      assert {:error, {:bad_celestrak_record, {:missing_prn, "GPS WITHOUT PRN"}, _}} =
               Constellation.from_celestrak_omm(bad)
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
      assert prn19.source.navcen.active_nanu?
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
      assert prn3.norad_id == 40294
      assert prn3.source.navcen.nanu_type == "FCSTSUMM"

      prn13 = Enum.find(records, &(&1.prn == 13))
      assert prn13.norad_id == 68791
      assert prn13.source.celestrak.block_type == "III"
      assert prn13.source.navcen_conflict.svn == 43
      assert prn13.source.navcen_conflict.block_type == "IIR"
      refute Map.has_key?(prn13.source, :navcen)
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
    test "reports duplicate PRNs, duplicate NORAD ids, and inactive/unusable PRNs" do
      records = [
        %Record{
          system: :gps,
          prn: 3,
          svn: 69,
          norad_id: 40294,
          sp3_id: "G03",
          active?: true,
          usable?: true,
          source: %{}
        },
        %Record{
          system: :gps,
          prn: 3,
          svn: 70,
          norad_id: 40294,
          sp3_id: "G03",
          active?: false,
          usable?: true,
          source: %{}
        }
      ]

      report = Constellation.validate(records)
      assert report.duplicate_prns == [3]
      assert report.duplicate_norad_ids == [40294]
      assert report.inactive_unusable_prns == [3]
      refute Constellation.valid?(report)
    end

    test "compares active usable catalog ids against a loaded SP3 product" do
      {:ok, sp3} = SP3.parse(@sp3)
      assert SP3.satellite_ids(sp3) == ["G03", "G32"]

      report = Constellation.validate_sp3(merged_records(), sp3)
      assert report.missing_sp3_ids == ["G05", "G13"]
      assert report.extra_sp3_ids == ["G32"]
      assert report.inactive_unusable_prns == [19]
      refute Constellation.valid?(report)
    end

    test "accepts a plain SP3 id list for validation" do
      report = Constellation.validate_sp3(merged_records(), ["G03", "G05", "G13"])
      assert report.missing_sp3_ids == []
      assert report.extra_sp3_ids == []
      assert report.inactive_unusable_prns == [19]
    end

    test "validate_sp3!/2 is a build-time gate: :ok when clean, raises on a stale-active PRN" do
      clean = [
        %Record{
          system: :gps,
          prn: 3,
          svn: 69,
          norad_id: 40_294,
          sp3_id: "G03",
          active?: true,
          usable?: true,
          source: %{}
        },
        %Record{
          system: :gps,
          prn: 5,
          svn: 50,
          norad_id: 35_752,
          sp3_id: "G05",
          active?: true,
          usable?: true,
          source: %{}
        }
      ]

      assert :ok = Constellation.validate_sp3!(clean, ["G03", "G05"])

      # G05 is active+usable but absent from the product — a stale-active sat.
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
      assert diff.norad_reassigned == []
      assert diff.sp3_id_changed == []
      assert diff.svn_changed == []
      assert diff.activity_changed == []
      assert diff.usability_changed == []
      refute Constellation.changed?(diff)
    end

    test "reports added records sorted by system and PRN" do
      diff = Constellation.diff([record(3)], [record(9), record(3), record(5)])

      assert Enum.map(diff.added, & &1.prn) == [5, 9]
      assert diff.removed == []
      assert Constellation.changed?(diff)
    end

    test "reports removed records sorted by system and PRN" do
      diff = Constellation.diff([record(9), record(3), record(5)], [record(3)])

      assert Enum.map(diff.removed, & &1.prn) == [5, 9]
      assert diff.added == []
      assert Constellation.changed?(diff)
    end

    test "reports a NORAD reassignment on a held PRN" do
      diff = Constellation.diff([record(13, norad_id: 28_190)], [record(13, norad_id: 68_791)])

      assert diff.norad_reassigned == [%{system: :gps, prn: 13, from: 28_190, to: 68_791}]
      assert diff.added == []
      assert diff.removed == []
      assert Constellation.changed?(diff)
    end

    test "reports active status flips" do
      diff = Constellation.diff([record(19, active?: true)], [record(19, active?: false)])

      assert diff.activity_changed == [%{system: :gps, prn: 19, from: true, to: false}]
      assert diff.usability_changed == []
      assert Constellation.changed?(diff)
    end

    test "reports SVN, SP3 id, and usability changes on common keys" do
      previous = [record(3, svn: 69, sp3_id: "G03", usable?: true)]
      current = [record(3, svn: 70, sp3_id: "G33", usable?: false)]

      diff = Constellation.diff(previous, current)

      assert diff.svn_changed == [%{system: :gps, prn: 3, from: 69, to: 70}]
      assert diff.sp3_id_changed == [%{system: :gps, prn: 3, from: "G03", to: "G33"}]
      assert diff.usability_changed == [%{system: :gps, prn: 3, from: true, to: false}]
    end

    test "raises a clear ArgumentError for non-list inputs" do
      assert_raise ArgumentError, ~r/expects two record lists/, fn ->
        Constellation.diff(record(3), [record(3)])
      end
    end
  end

  describe "health_timeline/2" do
    test "builds half-open health intervals and transition diffs" do
      healthy = record(3, usable?: true)
      unhealthy = record(3, usable?: false)

      assert {:ok, timeline} =
               Constellation.health_timeline([
                 {~N[2026-06-09 00:00:00], [healthy]},
                 {~N[2026-06-09 01:00:00], [unhealthy]}
               ])

      assert Enum.map(timeline.intervals, &{&1.prn, &1.state, &1.from, &1.to}) == [
               {3, :healthy, ~N[2026-06-09 00:00:00], ~N[2026-06-09 01:00:00]},
               {3, :unhealthy, ~N[2026-06-09 01:00:00], nil}
             ]

      assert [%{epoch: ~N[2026-06-09 01:00:00], diff: diff}] = timeline.changes

      assert diff.usability_changed == [
               %{system: :gps, prn: 3, from: true, to: false}
             ]

      assert [%{health_changed: [%{system: :gps, prn: 3, from: :healthy, to: :unhealthy}]}] =
               timeline.changes

      refute timeline.stale?
    end

    test "supports explicit health_state source metadata for degraded records" do
      healthy = record(5, source: %{health_state: :healthy})
      degraded = record(5, source: %{health_state: :degraded})

      assert Constellation.health_state(degraded) == :degraded

      assert {:ok, timeline} =
               Constellation.health_timeline([
                 %{epoch: ~N[2026-06-09 00:00:00], records: [healthy]},
                 %{epoch: ~N[2026-06-09 00:15:00], records: [degraded]}
               ])

      assert Enum.map(timeline.intervals, & &1.state) == [:healthy, :degraded]

      assert [
               %{
                 diff: diff,
                 health_changed: [%{system: :gps, prn: 5, from: :healthy, to: :degraded}]
               }
             ] = timeline.changes

      refute Constellation.changed?(diff)
    end

    test "marks a timeline stale when as_of exceeds the configured threshold" do
      assert {:ok, timeline} =
               Constellation.health_timeline(
                 [
                   {~N[2026-06-09 00:00:00], [record(3)]}
                 ],
                 as_of: ~N[2026-06-10 01:00:00],
                 stale_after_s: 86_400
               )

      assert timeline.stale?
      assert timeline.latest_epoch == ~N[2026-06-09 00:00:00]
      assert [%{to: ~N[2026-06-10 01:00:00]}] = timeline.intervals
    end

    test "serializes to a versioned map with string keys and ISO8601 epochs" do
      assert {:ok, timeline} =
               Constellation.health_timeline([
                 {~N[2026-06-09 00:00:00],
                  [record(3, source: %{navcen: %{nanu_type: "UNUSABLE"}})]}
               ])

      map = Constellation.health_timeline_to_map(timeline)

      assert map["version"] == 1
      assert map["latest_epoch"] == "2026-06-09T00:00:00"

      assert [%{"state" => "healthy", "source" => %{"navcen" => %{"nanu_type" => "UNUSABLE"}}}] =
               map["intervals"]

      assert map["changes"] == []
    end

    test "rejects malformed snapshots and stale thresholds" do
      assert {:error, :invalid_records} =
               Constellation.health_timeline([{~N[2026-06-09 00:00:00], [:bad]}])

      assert {:error, {:invalid_stale_after_s, 0}} =
               Constellation.health_timeline([{~N[2026-06-09 00:00:00], [record(3)]}],
                 stale_after_s: 0
               )

      assert {:error, {:duplicate_snapshot_epoch, ~N[2026-06-09 00:00:00]}} =
               Constellation.health_timeline([
                 {~N[2026-06-09 00:00:00], [record(3)]},
                 {~N[2026-06-09 00:00:00], [record(4)]}
               ])

      assert {:error, {:invalid_as_of, ~N[2026-06-08 23:00:00], ~N[2026-06-09 00:00:00]}} =
               Constellation.health_timeline([{~N[2026-06-09 00:00:00], [record(3)]}],
                 as_of: ~N[2026-06-08 23:00:00]
               )

      assert_raise ArgumentError, ~r/expects a snapshot list/, fn ->
        Constellation.health_timeline(:bad)
      end
    end
  end
end
