defmodule Sidereon.GNSS.AntexPublicPcvSampleFieldsTest do
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.Antex
  alias Sidereon.GNSS.Antex.{Frequency, FrequencyRms}

  defp rec(content, label), do: String.pad_trailing(content, 60) <> label

  test "public parser retains every NOAZI and azimuth sample field in data and RMS" do
    text =
      [
        rec("     1.4            M", "ANTEX VERSION / SYST"),
        rec("A", "PCV TYPE / REFANT"),
        rec("", "END OF HEADER"),
        rec("", "START OF ANTENNA"),
        rec(String.pad_trailing("TESTANT", 20) <> "SERIAL-1", "TYPE / SERIAL NO"),
        rec("     90.0", "DAZI"),
        rec("     0.0  10.0   5.0", "ZEN1 / ZEN2 / DZEN"),
        rec("     1", "# OF FREQUENCIES"),
        rec("G01", "START OF FREQUENCY"),
        rec("      1.00      2.00      3.00", "NORTH / EAST / UP"),
        "   NOAZI    1.00    2.00    3.00",
        "    90.0    4.00    5.00    6.00",
        rec("G01", "END OF FREQUENCY"),
        rec("G01", "START OF FREQ RMS"),
        rec("      0.10      0.20      0.30", "NORTH / EAST / UP"),
        "   NOAZI    0.01    0.02    0.03",
        "    90.0    0.04    0.05    0.06",
        rec("G01", "END OF FREQ RMS"),
        rec("", "END OF ANTENNA")
      ]
      |> Enum.join("\n")
      |> Kernel.<>("\n")

    assert {:ok, antex} = Antex.parse(text)

    assert [%{frequency: "G01", pco_m: {0.001, 0.002, 0.003}} = frequency] =
             antex.blocks |> hd() |> Map.fetch!(:frequencies)

    assert %Frequency{rms: %FrequencyRms{pco_m: {0.0001, 0.0002, 0.0003}}} = frequency

    assert frequency.pcv_samples == [
             %{grid: :noazi, azimuth_deg: nil, zenith_deg: 0.0, value_m: 0.001},
             %{grid: :noazi, azimuth_deg: nil, zenith_deg: 5.0, value_m: 0.002},
             %{grid: :noazi, azimuth_deg: nil, zenith_deg: 10.0, value_m: 0.003},
             %{grid: :azi, azimuth_deg: 90.0, zenith_deg: 0.0, value_m: 0.004},
             %{grid: :azi, azimuth_deg: 90.0, zenith_deg: 5.0, value_m: 0.005},
             %{grid: :azi, azimuth_deg: 90.0, zenith_deg: 10.0, value_m: 0.006}
           ]

    assert frequency.rms.pcv_samples == [
             %{grid: :noazi, azimuth_deg: nil, zenith_deg: 0.0, value_m: 0.00001},
             %{grid: :noazi, azimuth_deg: nil, zenith_deg: 5.0, value_m: 0.00002},
             %{grid: :noazi, azimuth_deg: nil, zenith_deg: 10.0, value_m: 0.00003},
             %{grid: :azi, azimuth_deg: 90.0, zenith_deg: 0.0, value_m: 0.00004},
             %{grid: :azi, azimuth_deg: 90.0, zenith_deg: 5.0, value_m: 0.00005},
             %{grid: :azi, azimuth_deg: 90.0, zenith_deg: 10.0, value_m: 0.00006}
           ]

    assert {:ok, encoded} = Antex.encode(antex)
    assert {:ok, reparsed} = Antex.parse(encoded)
    assert reparsed.header == antex.header
    assert reparsed.blocks == antex.blocks
    assert Antex.encode(reparsed) == {:ok, encoded}
  end
end
