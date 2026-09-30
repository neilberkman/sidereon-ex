defmodule Sidereon.GNSS.AntexContractTest do
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.Antex
  alias Sidereon.GNSS.Antex.{Antenna, Calibration, Epoch, Frequency, FrequencyRms, OuterComment, PcvTypeRecord}
  alias Sidereon.GNSS.Antex.{Version, ZenithGrid}

  @atx_path Path.join(__DIR__, "fixtures/ppp/igs20_zim2_gps.atx")

  defp rec(content, label), do: String.pad_trailing(content, 60) <> label

  defp field(text, width), do: String.pad_trailing(text, width)

  # A relative file with a blank reference antenna, one receiver block with a
  # comment before its `TYPE / SERIAL NO`, no `DAZI`, no zenith grid and two
  # different sections under one label, a comment between blocks, and one
  # satellite block with a method record, validity seconds stated with an
  # exponent, an RMS section and a `# OF FREQUENCIES` count the sections do not
  # match.
  defp synthetic do
    [
      rec("     1.4            M", "ANTEX VERSION / SYST"),
      rec("R", "PCV TYPE / REFANT"),
      rec("synthetic header", "COMMENT"),
      rec("", "END OF HEADER"),
      rec("", "START OF ANTENNA"),
      rec("leading note", "COMMENT"),
      rec(field("TEST ANT", 20) <> "12345", "TYPE / SERIAL NO"),
      rec("inner note", "COMMENT"),
      rec("   G01", "START OF FREQUENCY"),
      rec("      1.00      2.00      3.00", "NORTH / EAST / UP"),
      rec("   G01", "END OF FREQUENCY"),
      rec("   G01", "START OF FREQUENCY"),
      rec("      1.00      2.00      4.00", "NORTH / EAST / UP"),
      rec("   G01", "END OF FREQUENCY"),
      rec("", "END OF ANTENNA"),
      rec("between blocks", "COMMENT"),
      rec("", "START OF ANTENNA"),
      rec(field("BLOCK TEST", 20) <> "G99", "TYPE / SERIAL NO"),
      rec(field("ROBOT", 20) <> field("TEST AGENCY", 20) <> "     5    01-JAN-20", "METH / BY / # / DATE"),
      rec("     0.0", "DAZI"),
      rec("     0.0  10.0   5.0", "ZEN1 / ZEN2 / DZEN"),
      rec("     2", "# OF FREQUENCIES"),
      rec("  2020     1     1     0     0 1.2345678E-9", "VALID FROM"),
      rec("  2020    12    31    23    59   59.9999999", "VALID UNTIL"),
      rec("   G01", "START OF FREQUENCY"),
      rec("      0.00      0.00   1000.00", "NORTH / EAST / UP"),
      "   NOAZI    1.00    2.00    3.00",
      rec("   G01", "END OF FREQUENCY"),
      rec("   G01", "START OF FREQ RMS"),
      rec("      0.10      0.20      0.30", "NORTH / EAST / UP"),
      "   NOAZI    0.01    0.02    0.03",
      rec("   G01", "END OF FREQ RMS"),
      rec("", "END OF ANTENNA")
    ]
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  describe "a parsed IGS file" do
    setup do
      {:ok, antex} = Antex.load(@atx_path)
      %{antex: antex}
    end

    test "keeps the header records", %{antex: antex} do
      assert antex.header.version == %Version{version: 1.4, system: "M"}

      assert antex.header.pcv_type == %PcvTypeRecord{
               pcv_type: :absolute,
               reference_antenna_type: "",
               reference_antenna_serial: "",
               reference_antenna: nil
             }

      assert antex.header.end_of_header
      assert length(antex.header.comments) == 545
      assert hd(antex.header.comments) == String.duplicate("#", 59)
      assert antex.outer_comments == []
      assert Antex.skipped_records(antex) == 0
    end

    test "keeps every block in file order with its records", %{antex: antex} do
      assert length(antex.blocks) == 117
      [first, second | _] = antex.blocks

      assert %Antenna{
               kind: :satellite,
               type: "BLOCK IIA",
               serial: "G01",
               dazi_deg: +0.0,
               zenith_grid: %ZenithGrid{start_deg: +0.0, end_deg: 17.0, step_deg: 1.0},
               has_frequency_count: true,
               sinex_code: "IGS20_2417",
               leading_comments: [],
               comments: []
             } = first

      assert first.calibrations == [%Calibration{method: "", agency: "", antennas_calibrated: 0, date: "29-JAN-17"}]
      assert Enum.map(first.frequencies, & &1.frequency) == ["G01", "G02"]
      assert Enum.all?(first.frequencies, &is_nil(&1.rms))

      # `59.9999999` is kept to the seventh decimal, not rounded into the next
      # minute or cut to a microsecond.
      assert first.valid_from == epoch({1992, 11, 22}, {0, 0, 0}, {0, 0})
      assert first.valid_until == epoch({2008, 10, 16}, {23, 59, 59}, {9_999_999, 7})
      assert Epoch.to_naive_datetime(first.valid_until) == {:error, :sub_microsecond_fraction}
      assert Epoch.to_naive_datetime(first.valid_from) == {:ok, ~N[1992-11-22 00:00:00.000000]}

      assert second.valid_from == epoch({2008, 10, 23}, {0, 0, 0}, {0, 0})
    end

    test "keeps each validity interval of one id and the latest in the id view", %{antex: antex} do
      id = "BLOCK IIR-M         G04                 G049      2009-014A"
      intervals = Antex.antenna_intervals(antex, id)

      assert length(intervals) == 3
      assert Antex.antenna(antex, id) == List.last(intervals)
      assert Map.new(antex.blocks, &{&1.id, &1}) == antex.antennas
    end

    test "selects a satellite block by its exact validity bound", %{antex: antex} do
      [first | _] = antex.blocks

      assert Antex.satellite_antenna(antex, "G01", first.valid_until) == first
      assert Antex.satellite_antenna(antex, "G01", ~N[2008-10-16 23:59:59.999999]) == first

      # 59.99999995 is past the bound and before the next block starts.
      past = epoch({2008, 10, 16}, {23, 59, 59}, {99_999_995, 8})
      assert Antex.satellite_antenna(antex, "G01", past) == nil
      assert Antex.satellite_antenna(antex, "G01", ~N[2008-10-20 00:00:00]) == nil

      assert Antex.antenna_at(antex, first.id, first.valid_from) == first
      assert Antex.antenna_at(antex, first.id, past) == nil

      leap_label = epoch({2008, 10, 16}, {23, 59, 60}, {0, 0})
      assert Antex.satellite_antenna(antex, "G01", leap_label) == {:error, :invalid_datetime}
    end

    test "restates every retained record through the writer", %{antex: antex} do
      assert {:ok, text} = Antex.encode(antex)
      assert {:ok, reparsed} = Antex.parse(text)

      assert reparsed.header == antex.header
      assert reparsed.outer_comments == antex.outer_comments
      assert reparsed.blocks == antex.blocks
      assert Antex.encode(reparsed) == {:ok, text}
    end
  end

  describe "a synthetic file" do
    setup do
      {:ok, antex} = Antex.parse(synthetic())
      [receiver, satellite] = antex.blocks
      %{antex: antex, receiver: receiver, satellite: satellite}
    end

    test "reads relative values and their default reference antenna", %{antex: antex} do
      assert antex.header.pcv_type == %PcvTypeRecord{
               pcv_type: :relative,
               reference_antenna_type: "",
               reference_antenna_serial: "",
               reference_antenna: "AOAD/M_T"
             }

      assert antex.header.comments == ["synthetic header"]
      assert antex.outer_comments == [%OuterComment{blocks_before: 1, text: "between blocks"}]

      # The satellite block's `# OF FREQUENCIES` says 2 over one section.
      assert Antex.skipped_records(antex) == 1
    end

    test "keeps absent records absent and comments in their places", %{receiver: receiver} do
      assert %Antenna{
               id: "TEST ANT            12345",
               kind: :receiver,
               type: "TEST ANT",
               serial: "12345",
               dazi_deg: nil,
               zenith_grid: nil,
               has_frequency_count: false,
               sinex_code: nil,
               valid_from: nil,
               valid_until: nil,
               calibrations: [],
               leading_comments: ["leading note"],
               comments: ["inner note"]
             } = receiver

      assert Enum.map(receiver.frequencies, & &1.frequency) == ["G01", "G01"]
    end

    test "refuses a label whose sections differ", %{receiver: receiver} do
      ambiguous = {:error, {:ambiguous_frequency, %{antenna_id: receiver.id, frequency: "G01", sections: 2}}}

      assert Antex.pco(receiver, "G01") == ambiguous
      assert Antex.frequency(receiver, " G01 ") == ambiguous
      assert Antex.pcv(receiver, "G01", 0.0) == ambiguous

      assert Antex.pco(receiver, "G02") ==
               {:error, {:unknown_frequency, %{antenna_id: receiver.id, frequency: "G02"}}}

      # Identical sections under one label answer.
      [first, _second] = receiver.frequencies
      same = %{receiver | frequencies: [first, first]}
      assert Antex.pco(same, "G01") == {:ok, {1.0 * 1.0e-3, 2.0 * 1.0e-3, 3.0 * 1.0e-3}}
      assert Antex.frequency(same, "G01") == {:ok, first}
    end

    test "keeps the method record, exact validity seconds and the RMS section", %{satellite: satellite} do
      assert satellite.kind == :satellite
      calibration = %Calibration{method: "ROBOT", agency: "TEST AGENCY", antennas_calibrated: 5, date: "01-JAN-20"}
      assert satellite.calibrations == [calibration]
      assert satellite.dazi_deg == +0.0
      assert satellite.zenith_grid == %ZenithGrid{start_deg: +0.0, end_deg: 10.0, step_deg: 5.0}
      assert satellite.has_frequency_count

      # `1.2345678E-9` seconds is 0.0000000012345678, kept whole.
      assert satellite.valid_from == epoch({2020, 1, 1}, {0, 0, 0}, {12_345_678, 16})
      assert satellite.valid_until == epoch({2020, 12, 31}, {23, 59, 59}, {9_999_999, 7})

      assert [%Frequency{frequency: "G01", rms: %FrequencyRms{} = rms} = frequency] = satellite.frequencies
      assert frequency.pco_m == {0.0 * 1.0e-3, 0.0 * 1.0e-3, 1000.0 * 1.0e-3}
      assert Enum.map(frequency.pcv_samples, & &1.zenith_deg) == [+0.0, 5.0, 10.0]
      assert rms.pco_m == {0.1 * 1.0e-3, 0.2 * 1.0e-3, 0.3 * 1.0e-3}
      assert Enum.map(rms.pcv_samples, & &1.value_m) == [0.01 * 1.0e-3, 0.02 * 1.0e-3, 0.03 * 1.0e-3]

      assert {:ok, value_m} = Antex.pcv(satellite, "G01", 5.0)
      assert_in_delta value_m, 2.0 * 1.0e-3, 1.0e-15
    end

    test "selects by a validity bound finer than a nanosecond", %{antex: antex, satellite: satellite} do
      assert Antex.satellite_antenna(antex, "G99", satellite.valid_from) == satellite

      before = epoch({2020, 1, 1}, {0, 0, 0}, {12_345_677, 16})
      assert Antex.satellite_antenna(antex, "G99", before) == nil
      assert Antex.antenna_at(antex, satellite.id, before) == nil
      assert Antex.antenna_at(antex, satellite.id, ~N[2020-06-01 12:00:00]) == satellite
    end

    test "names a lookup argument the boundary cannot carry", %{satellite: satellite} do
      assert Antex.pcv(satellite, "G01", Integer.pow(10, 400)) ==
               {:error, {:value_out_of_range, :zenith_deg, Integer.pow(10, 400)}}

      assert Antex.pcv(satellite, "G01", 5.0, :north) == {:error, {:invalid_double, :azimuth_deg, :north}}
    end
  end

  describe "refusals" do
    test "a validity second of 60 is refused by field" do
      text =
        synthetic()
        |> String.replace("  2020    12    31    23    59   59.9999999", "  2020    12    31    23    59   60.0000000")

      assert {:error, {:invalid_field, %{antenna_id: "BLOCK TEST          G99", record: "VALID UNTIL"}}} =
               Antex.parse(text)
    end
  end

  defp epoch({year, month, day}, {hour, minute, second}, {digits, scale}) do
    %Epoch{
      year: year,
      month: month,
      day: day,
      hour: hour,
      minute: minute,
      second: second,
      fraction_digits: digits,
      fraction_scale: scale
    }
  end
end
