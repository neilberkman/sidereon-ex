defmodule Sidereon.GNSS.RINEX.ObservationsContractTest do
  @moduledoc """
  The RINEX observation contract the binding exposes: untimed event epochs,
  event header records in effect from their epoch, cycle slips, the full header,
  phase-shift correction status, the fallible writer, the version 2 downgrade
  and its changes, the leap-second time system, and observation QC over events.

  The synthetic products below are classified synthetic: each is built line by
  line in the fixed columns RINEX lays out, for the case it names, and several
  restate products the core's own tests read.
  """
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.QC
  alias Sidereon.GNSS.RINEX.Observations
  alias Sidereon.GNSS.RINEX.Observations.DowngradeChange
  alias Sidereon.GNSS.RINEX.Observations.Epoch
  alias Sidereon.GNSS.RINEX.Observations.Header
  alias Sidereon.GNSS.RINEX.Observations.LeapSeconds
  alias Sidereon.GNSS.RINEX.Observations.PhaseRow
  alias Sidereon.GNSS.RINEX.Observations.PhaseShift

  @rnx_path Path.join(__DIR__, "fixtures/obs/ESBC00DNK_R_20201770000_01D_30S_MO_trim.rnx")

  # GPS L1: 1575.42 MHz.
  @l1_wavelength_m 299_792_458.0 / 1_575_420_000.0

  defp header_line(body, label), do: String.pad_trailing(body, 60) <> label

  defp text(lines), do: Enum.join(lines, "\n") <> "\n"

  # A version 3 event line whose epoch fields are blank: 30 blank columns after
  # `>`, then the flag and the record count.
  defp blank_event_line(flag, count), do: ">" <> String.duplicate(" ", 30) <> "#{flag}  #{count}"

  defp parse!(lines) do
    {:ok, obs} = lines |> text() |> Observations.parse()
    obs
  end

  defp untimed_event_product do
    parse!([
      header_line("     3.05           OBSERVATION DATA    M (MIXED)", "RINEX VERSION / TYPE"),
      header_line("G    1 C1C", "SYS / # / OBS TYPES"),
      header_line("", "END OF HEADER"),
      "> 2020 01 01 00 00  0.0000000  0  1",
      "G01  20000000.000",
      blank_event_line(4, 1),
      header_line("a comment after a blank event", "COMMENT"),
      "> 2020 01 01 00 00 30.0000000  0  1",
      "G01  20000100.000"
    ])
  end

  # A timed flag 4 event carrying a phase shift and a marker name, which take
  # effect for the epochs after it.
  defp event_header_lines do
    [
      header_line("     3.05           OBSERVATION DATA    M (MIXED)", "RINEX VERSION / TYPE"),
      header_line("G    1 L1C", "SYS / # / OBS TYPES"),
      header_line("G L1C  0.25000", "SYS / PHASE SHIFT"),
      header_line("", "END OF HEADER"),
      "> 2020 01 01 00 00  0.0000000  0  1",
      "G01 110000000.000",
      "> 2020 01 01 00 00 15.0000000  4  2",
      header_line("G L1C  0.50000", "SYS / PHASE SHIFT"),
      header_line("SITE2", "MARKER NAME"),
      "> 2020 01 01 00 00 30.0000000  0  1",
      "G01 110000100.000"
    ]
  end

  # RINEX 3.02 BeiDou B1I, labelled band 1 in that version, with a flag 6 cycle
  # slip record.
  defp beidou_b1i_302_lines do
    [
      "     3.02           OBSERVATION DATA    C                   RINEX VERSION / TYPE",
      "C    2 C1I L1I                                              SYS / # / OBS TYPES",
      "                                                            END OF HEADER",
      "> 2020 06 24 00 00  0.0000000  0  1",
      "C01  22000000.000 7        10.00015",
      "> 2020 06 24 00 00 30.0000000  6  1",
      "C01                       100.000  "
    ]
  end

  defp leap_product(version, record) do
    parse!([
      "     #{version}           OBSERVATION DATA    C                   RINEX VERSION / TYPE",
      "C    1 C2I                                                  SYS / # / OBS TYPES",
      header_line(record, "LEAP SECONDS"),
      "                                                            END OF HEADER",
      "> 2020 06 24 00 00  0.0000000  0  1",
      "C01  22000000.000  "
    ])
  end

  # One block gives G01's L1W two corrections, G02's L1W one, and a record naming
  # only the constellation declares every other GPS code's alignment unknown.
  defp phase_shift_product do
    parse!([
      header_line("     3.05           OBSERVATION DATA    M (MIXED)", "RINEX VERSION / TYPE"),
      header_line("G    2 L1W L2W", "SYS / # / OBS TYPES"),
      header_line("G L1W  0.25000  01 G01", "SYS / PHASE SHIFT"),
      header_line("G L1W  0.50000  02 G02 G01", "SYS / PHASE SHIFT"),
      header_line("G", "SYS / PHASE SHIFT"),
      header_line("", "END OF HEADER"),
      "> 2020 01 01 00 00  0.0000000  0  2",
      "G01" <> " 110000000.000" <> "  " <> "  85000000.000",
      "G02" <> " 120000000.000" <> "  " <> "  95000000.000"
    ])
  end

  describe "untimed event epochs" do
    test "an event with blank epoch fields keeps its place with no time made up" do
      obs = untimed_event_product()

      assert [first, event, last] = Observations.epochs(obs)
      assert %Epoch{index: 0, flag: 0, sat_count: 1} = first
      assert first.epoch == {{2020, 1, 1}, {0, 0, 0.0}}

      assert %Epoch{
               index: 1,
               epoch: nil,
               flag: 4,
               declared_record_count: 1,
               sat_count: 0,
               cycle_slip_count: 0,
               epoch_picoseconds: nil,
               rcv_clock_offset_s: nil
             } = event

      assert event.special_records == [header_line("a comment after a blank event", "COMMENT")]
      assert %Epoch{index: 2, epoch: {{2020, 1, 1}, {0, 0, 30.0}}, flag: 0} = last

      assert {:ok, %{}} == Observations.values(obs, 1)
      assert {:ok, %{}} == Observations.phases(obs, 1)

      assert {:ok, [{"G01", 20_000_100.0}]} ==
               Observations.pseudoranges(obs, {{2020, 1, 1}, {0, 0, 30.0}}, codes: %{"G" => ["C1C"]})
    end

    test "the untimed event writes back and reads back as the same epochs" do
      obs = untimed_event_product()

      assert {:ok, written} = Observations.to_rinex_string(obs)
      assert {:ok, reparsed} = Observations.parse(written)
      assert Observations.epochs(reparsed) == Observations.epochs(obs)
      assert Observations.header(reparsed) == Observations.header(obs)
    end
  end

  describe "event header records in effect" do
    test "a phase shift and marker an event declares apply from the event on" do
      obs = parse!(event_header_lines())

      assert [_, %Epoch{index: 1, flag: 4, epoch: {{2020, 1, 1}, {0, 0, 15.0}}} = event, _] =
               Observations.epochs(obs)

      assert event.special_records == [
               header_line("G L1C  0.50000", "SYS / PHASE SHIFT"),
               header_line("SITE2", "MARKER NAME")
             ]

      assert %Header{marker_name: nil} = Observations.header(obs)
      assert {:ok, %Header{marker_name: nil}} = Observations.header_at(obs, 0)
      assert {:ok, %Header{marker_name: "SITE2"}} = Observations.header_at(obs, 2)
      assert {:error, :epoch_out_of_range} = Observations.header_at(obs, 3)
      assert {:error, :epoch_out_of_range} = Observations.header_at(obs, -1)

      assert {:ok, [{0, %Header{marker_name: nil}}, {1, %Header{marker_name: "SITE2"}}]} =
               Observations.header_segments(obs)

      {:ok, %{"G01" => [before]}} = Observations.phases(obs, 0)
      {:ok, %{"G01" => [later]}} = Observations.phases(obs, 2)

      assert %PhaseRow{code: "L1C", phase_shift: :available, phase_shift_cycles: 0.25} = before
      assert before.value_cycles == 110_000_000.0

      assert %PhaseRow{code: "L1C", phase_shift: :available, phase_shift_cycles: 0.5} = later
      assert later.value_cycles == 110_000_100.0
    end

    test "observation QC reads the event's header records and notes nothing unread" do
      obs = parse!(event_header_lines())

      assert {:ok, report} = QC.observation_report(obs)
      assert report.event_records == 1
      assert report.observation_epochs == 2
      refute Enum.any?(report.notes, &(&1.kind == "event_header_records_unread"))

      assert {:ok, lint} = QC.lint_obs(obs)
      refute Enum.any?(lint.findings, &(&1.code == "OBS-B10"))
    end

    test "repair writes the product back with the event's records, as RINEX and as CRINEX" do
      input = text(event_header_lines())
      assert {:ok, repair} = QC.repair_obs_text(input)

      assert {:ok, from_rinex} = Observations.parse(repair.rinex)
      assert {:ok, from_crinex} = Observations.parse_crinex(repair.crinex)

      original = parse!(event_header_lines())

      assert Enum.map(Observations.epochs(from_rinex), & &1.special_records) ==
               Enum.map(Observations.epochs(original), & &1.special_records)

      assert Observations.epochs(from_crinex) == Observations.epochs(from_rinex)
    end

    test "repair refuses text that does not read, naming the core's error kind" do
      assert {:error, {:parse, message}} = QC.repair_obs_text("not a rinex file\n")
      assert is_binary(message)
    end
  end

  describe "cycle slips" do
    test "a flag 6 epoch's slips are read apart from observations" do
      obs = parse!(beidou_b1i_302_lines())

      assert [
               %Epoch{index: 0, flag: 0, sat_count: 1, cycle_slip_count: 0},
               %Epoch{index: 1, flag: 6, sat_count: 0, cycle_slip_count: 1, epoch: {{2020, 6, 24}, {0, 0, 30.0}}}
             ] = Observations.epochs(obs)

      assert {:ok, %{}} == Observations.values(obs, 1)
      assert {:ok, %{}} == Observations.cycle_slips(obs, 0)

      assert {:ok, %{"C01" => [c1i, l1i]}} = Observations.cycle_slips(obs, 1)
      assert %{code: "C1I", value: nil, lli: nil, ssi: nil} = c1i
      assert %{code: "L1I", kind: :carrier_phase, value: 100.0, lli: nil, ssi: nil} = l1i

      # A time names the observation epoch for observations and the slip epoch
      # for slips; the slip record is never taken for a measurement.
      slip_time = {{2020, 6, 24}, {0, 0, 30.0}}
      assert {:error, :unknown_epoch} = Observations.values(obs, slip_time)
      assert Observations.cycle_slips(obs, slip_time) == Observations.cycle_slips(obs, 1)

      assert {:ok, %{"C01" => [c1i_obs, l1i_obs]}} = Observations.values(obs, 0)
      assert %{code: "C1I", value: 22_000_000.0, lli: nil, ssi: 7} = c1i_obs
      assert %{code: "L1I", value: 10.0, lli: 1, ssi: 5} = l1i_obs
    end

    test "an unknown constellation key is refused rather than dropped" do
      obs = parse!(beidou_b1i_302_lines())

      assert {:error, {:unknown_system, "X"}} = Observations.values(obs, 0, codes: %{"X" => []})
      assert {:error, {:unknown_system, "X"}} = Observations.cycle_slips(obs, 1, codes: %{"X" => []})
      assert {:error, :epoch_out_of_range} = Observations.values(obs, 2)
      assert {:error, :epoch_out_of_range} = Observations.values(obs, -1)
    end
  end

  describe "downgrade_to_rinex2/2" do
    test "returns the version 2 product with every change it made" do
      obs = parse!(beidou_b1i_302_lines())

      assert {:ok, %{value: %Observations{} = v2, changes: changes}} = Observations.downgrade_to_rinex2(obs, 2.11)
      assert Enum.all?(changes, &match?(%DowngradeChange{}, &1))

      assert changes |> Enum.map(&{&1.tag, &1.system, &1.from_code, &1.to_code}) |> Enum.sort() == [
               {:code_renamed, "C", "C1I", "C2I"},
               {:code_renamed, "C", "L1I", "L2I"}
             ]

      assert %Header{version: 2.11} = Observations.header(v2)
      assert Observations.observation_codes(v2)["C"] == ["C2I", "L2I"]
      assert {:ok, %{"C01" => [%{value: nil}, %{code: "L2I", value: 100.0}]}} = Observations.cycle_slips(v2, 1)

      # The source product is not changed.
      assert Observations.observation_codes(obs)["C"] == ["C1I", "L1I"]

      assert {:ok, written} = Observations.to_rinex_string(v2)
      assert written |> String.split("\n") |> hd() |> String.starts_with?("     2.11")
      assert {:ok, reparsed} = Observations.parse(written)
      assert Observations.epochs(reparsed) == Observations.epochs(v2)
    end

    test "refuses a version that is not 2 and a version that is not a number" do
      obs = parse!(beidou_b1i_302_lines())

      assert {:error, {:not_version_two, %{version: 3.0}}} = Observations.downgrade_to_rinex2(obs, 3.0)
      assert {:error, {:invalid_version, "2.11"}} = Observations.downgrade_to_rinex2(obs, "2.11")
    end

    test "refuses a carrier version 2 cannot name, with the variant's fields" do
      obs =
        parse!([
          "     3.05           OBSERVATION DATA    C                   RINEX VERSION / TYPE",
          "C    2 C1P L1P                                              SYS / # / OBS TYPES",
          "                                                            END OF HEADER",
          "> 2020 06 24 00 00  0.0000000  0  1",
          "C01  22000000.000          10.000  "
        ])

      assert {:ok, _text} = Observations.to_rinex_string(obs)

      for version <- [2.11, 2.12] do
        assert {:error, {:observable_not_representable, %{system: "C", code: "C1P", version: ^version}}} =
                 Observations.downgrade_to_rinex2(obs, version)
      end

      assert Observations.observation_codes(obs)["C"] == ["C1P", "L1P"]
    end
  end

  describe "LEAP SECONDS time system" do
    test "the raw identifier is kept, written back and refused where a version cannot state it" do
      obs = leap_product("3.04", "     4        1000     6BDS")

      assert %Header{leap_seconds: leap} = Observations.header(obs)
      assert leap == %LeapSeconds{current: 4, delta_future: nil, week: 1000, day: 6, time_system: "BDS"}

      assert {:ok, written} = Observations.to_rinex_string(obs)
      line = written |> String.split("\n") |> Enum.find(&String.ends_with?(&1, "LEAP SECONDS"))
      assert String.slice(line, 24, 3) == "BDS"
      assert {:ok, reparsed} = Observations.parse(written)
      assert Observations.header(reparsed).leap_seconds == leap

      assert {:error, {:leap_seconds_time_system_not_in_version, %{time_system: "BDS", version: 2.11}}} =
               Observations.downgrade_to_rinex2(obs, 2.11)
    end

    test "a blank identifier and an explicit GPS are different statements" do
      blank = leap_product("3.05", "    18        2300     1")
      gps = leap_product("3.05", "    18        2300     1GPS")

      assert %LeapSeconds{current: 18, week: 2300, day: 1, time_system: nil} = Observations.header(blank).leap_seconds
      assert %LeapSeconds{current: 18, week: 2300, day: 1, time_system: "GPS"} = Observations.header(gps).leap_seconds
    end
  end

  describe "SYS / PHASE SHIFT correction status" do
    test "every phase row is kept, with the correction or why there is none" do
      obs = phase_shift_product()

      # One block gives G01 L1W two corrections: the contradiction is kept and
      # counted, and no record is dropped.
      assert Observations.skipped_records(obs) == 1

      assert [
               %PhaseShift{system: "G", code: "L1W", correction_cycles: 0.25, satellites: ["G01"]},
               %PhaseShift{system: "G", code: "L1W", correction_cycles: 0.5, satellites: ["G02", "G01"]},
               %PhaseShift{system: "G", code: nil, correction_cycles: nil, satellites: []}
             ] = Observations.phase_shifts(obs)

      assert {:ok, %{"G01" => [g01_l1, g01_l2], "G02" => [g02_l1, g02_l2]}} = Observations.phases(obs, 0)

      assert %PhaseRow{
               code: "L1W",
               phase_shift: :ambiguous,
               phase_shift_cycles: nil,
               phase_shift_corrections: [0.25, 0.5],
               value_cycles: 110_000_000.0
             } = g01_l1

      assert_in_delta g01_l1.value_m, 110_000_000.0 * @l1_wavelength_m, 1.0e-6

      # The constellation-only record declares the alignment of every code no
      # other record covers unknown.
      assert %PhaseRow{
               code: "L2W",
               phase_shift: :unknown,
               phase_shift_cycles: nil,
               phase_shift_corrections: [],
               value_cycles: 85_000_000.0
             } = g01_l2

      assert %PhaseRow{code: "L1W", phase_shift: :available, phase_shift_cycles: 0.5, phase_shift_corrections: []} =
               g02_l1

      # The correction is reported beside the phase, which is the recorded one.
      assert g02_l1.value_cycles == 120_000_000.0
      assert_in_delta g02_l1.value_m, 120_000_000.0 * @l1_wavelength_m, 1.0e-6

      assert %PhaseRow{code: "L2W", phase_shift: :unknown, phase_shift_cycles: nil, value_cycles: 95_000_000.0} = g02_l2
    end

    test "the records and their status survive a write and a read" do
      obs = phase_shift_product()

      assert {:ok, written} = Observations.to_rinex_string(obs)
      assert {:ok, reparsed} = Observations.parse(written)
      assert Observations.phase_shifts(reparsed) == Observations.phase_shifts(obs)
      assert Observations.phases(reparsed, 0) == Observations.phases(obs, 0)
    end
  end

  describe "header/1 on a committed fixture" do
    test "reads every record the fixture's header carries, nil where it carries none" do
      obs = Observations.load!(@rnx_path)
      header = Observations.header(obs)

      assert %Header{
               version: 3.05,
               marker_name: "ESBC00DNK",
               marker_number: "10118M001",
               marker_type: "GEODETIC",
               observer: "SDFE",
               agency: "SDFE",
               receiver: %{number: "3047937", receiver_type: "SEPT POLARX5", version: "5.2.0"},
               interval_s: 30.0,
               signal_strength_unit: "DBHZ",
               n_satellites: 0,
               rinex2_types: [],
               rinex2_system: nil,
               glonass_cod_phs_bis: nil,
               leap_seconds: nil,
               scale_factors: [],
               time_of_last_obs: {{{2020, 6, 25}, {23, 59, 30.0}}, "GPST"}
             } = header

      assert header.time_of_first_obs == {{{2020, 6, 25}, {0, 0, 0.0}}, "GPST"}

      assert header.program_run_by_date.program == "sbf2rin-13.4.5"
      assert header.approx_position_m == Observations.approx_position(obs)
      assert header.obs_codes == Observations.observation_codes(obs)
      assert header.declared_obs_codes == header.obs_codes
      assert header.glonass_slots == Observations.glonass_slots(obs)
      assert header.phase_shifts == Observations.phase_shifts(obs)
      assert header.prn_obs_counts == %{}

      assert {:ok, [{0, ^header}]} = Observations.header_segments(obs)
      assert {:ok, ^header} = Observations.header_at(obs, 0)
      assert Observations.skipped_records(obs) == 0
    end
  end
end
