defmodule Sidereon.GNSS.RinexNavFrequencyParityTest do
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.Broadcast

  alias Sidereon.GNSS.Broadcast.{
    DetailedRecord,
    GlonassParse,
    GlonassRecord,
    RinexNavParse,
    SkippedGlonass,
    SkippedNavBlock
  }

  alias Sidereon.GNSS.Frequencies

  @mixed_nav_path Path.join(__DIR__, "fixtures/nav/ESBC00DNK_R_20201770000_01D_MN.rnx")
  @glonass_nav_path Path.join(__DIR__, "fixtures/nav/BRDC00WRD_R_20201770000_01D_GREC.rnx")

  describe "raw RINEX NAV record-list routes" do
    test "returns pre-filter supported records in file order" do
      {:ok, records} = Broadcast.parse_rinex_nav_records(File.read!(@mixed_nav_path))

      assert length(records) == 2216
      assert Enum.all?(records, &match?(%DetailedRecord{}, &1))
      assert Enum.count(records, &(&1.message == :galileo_fnav)) == 781

      assert %DetailedRecord{satellite_id: "C05", message: :beidou_d2} = hd(records)
    end

    test "encodes an arbitrary caller-owned record list" do
      {:ok, records} = Broadcast.parse_rinex_nav_records(File.read!(@mixed_nav_path))
      selected = [hd(records), Enum.find(records, &(&1.message == :galileo_fnav))]

      assert {:ok, encoded} = Broadcast.encode_rinex_nav(selected)
      assert is_binary(encoded)
      assert {:ok, ^selected} = Broadcast.parse_rinex_nav_records(encoded)
    end

    test "lenient parsing reports malformed body blocks" do
      text = corrupt_first_record(File.read!(@mixed_nav_path))

      assert {:error, "bad/missing af0 field in record for C05"} =
               Broadcast.parse_rinex_nav_records(text)

      assert {:ok,
              %RinexNavParse{
                records: records,
                skipped: [%SkippedNavBlock{satellite: "C05", message: message}]
              }} = Broadcast.parse_rinex_nav_lenient(text)

      assert length(records) == 2215
      assert message == "bad/missing af0 field in record for C05"
    end
  end

  describe "raw GLONASS RINEX NAV records" do
    test "keeps unhealthy records that the broadcast handle filters" do
      text = File.read!(@glonass_nav_path)
      {:ok, raw_records} = Broadcast.parse_rinex_glonass_records(text)

      assert length(raw_records) == 1152
      assert Enum.count(raw_records, &(&1.sv_health != 0.0)) == 48
      assert Enum.all?(raw_records, &match?(%GlonassRecord{}, &1))

      assert %GlonassRecord{satellite_id: "R26", sv_health: 4.0, freq_channel: -6} =
               Enum.find(raw_records, &(&1.sv_health != 0.0))

      handle = Broadcast.load!(@glonass_nav_path)
      assert Broadcast.glonass_record_count(handle) == 1104
    end

    test "lenient parsing reports unrepresentable slots and keeps record order" do
      text = glonass_records_with_extended_slot(File.read!(@glonass_nav_path))

      assert {:ok,
              %GlonassParse{
                records: [%GlonassRecord{satellite_id: "R01"}, %GlonassRecord{satellite_id: "R02"}],
                skipped: [%SkippedGlonass{token: "R28"}]
              }} = Broadcast.parse_rinex_glonass_lenient(text)
    end
  end

  describe "RINEX observation-code/version policy" do
    test "resolves version-sensitive BeiDou observation codes" do
      assert {:ok, 1_561_098_000.0} =
               Frequencies.rinex_observation_frequency_hz("C", "C1I", 3.02)

      assert {:ok, 1_575_420_000.0} =
               Frequencies.rinex_observation_frequency_hz("C", "C1I", 3.03)

      assert {:ok, wavelength_m} =
               Frequencies.rinex_observation_wavelength_m("C", "C1I", 3.02)

      assert wavelength_m == 299_792_458.0 / 1_561_098_000.0
    end

    test "resolves full GLONASS codes with an FDMA channel" do
      assert {:ok, 1_598_062_500.0} =
               Frequencies.rinex_observation_frequency_hz("R", "C1C", 3.04, -7)

      assert {:error, {:missing_glonass_channel, "R", "C1C"}} =
               Frequencies.rinex_observation_frequency_hz("R", "C1C", 3.04)
    end

    test "preserves direct-code errors" do
      assert {:error, {:unknown_observation_code, "G", "C9Z", 3.04}} =
               Frequencies.rinex_observation_frequency_hz("G", "C9Z", 3.04)

      assert {:error, {:invalid_channel, 200}} =
               Frequencies.rinex_observation_wavelength_m("R", "C1C", 3.04, 200)
    end
  end

  defp corrupt_first_record(text) do
    lines = String.split(text, "\n", trim: false)
    index = Enum.find_index(lines, &String.starts_with?(&1, "C05"))
    line = Enum.at(lines, index)
    bad_clock_bias = String.pad_trailing("not-a-number", 19)
    replacement = binary_part(line, 0, 23) <> bad_clock_bias <> binary_part(line, 42, byte_size(line) - 42)

    lines
    |> List.replace_at(index, replacement)
    |> Enum.join("\n")
  end

  defp glonass_records_with_extended_slot(text) do
    lines = String.split(text, "\n", trim: false)
    header_end = Enum.find_index(lines, &String.contains?(&1, "END OF HEADER"))
    header = Enum.take(lines, header_end + 1)
    r01 = glonass_block(lines, "R01")
    r02 = glonass_block(lines, "R02")
    [first | rest] = r01
    r28 = ["R28" <> binary_part(first, 3, byte_size(first) - 3) | rest]

    Enum.join(header ++ r01 ++ r02 ++ r28, "\n")
  end

  defp glonass_block(lines, prefix) do
    start = Enum.find_index(lines, &String.starts_with?(&1, prefix))
    Enum.slice(lines, start, 4)
  end
end
