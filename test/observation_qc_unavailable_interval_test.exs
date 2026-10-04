defmodule Sidereon.ObservationQcUnavailableIntervalTest do
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.QC
  alias Sidereon.GNSS.RINEX.Observations

  @fixture Path.join([
             "test",
             "fixtures",
             "obs",
             "ESBC00DNK_R_20201770000_01D_30S_MO_trim.rnx"
           ])

  defp label(line) do
    line
    |> String.pad_trailing(80)
    |> String.slice(60, 20)
    |> String.trim()
  end

  defp with_interval(text, interval_s) when is_number(interval_s) do
    with_interval(text, :erlang.float_to_binary(interval_s, decimals: 3))
  end

  defp with_interval(text, interval_token) when is_binary(interval_token) do
    replacement =
      interval_token
      |> String.pad_leading(10)
      |> String.pad_trailing(60)
      |> Kernel.<>("INTERVAL")

    text
    |> String.split("\n", trim: false)
    |> Enum.map_join("\n", fn line ->
      if label(line) == "INTERVAL", do: replacement, else: line
    end)
  end

  defp header_only(text) do
    lines = String.split(text, "\n", trim: false)
    end_index = Enum.find_index(lines, &(label(&1) == "END OF HEADER"))

    lines
    |> Enum.take(end_index + 1)
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  test "signed zero source INTERVAL is unavailable, inferred, and repaired on request" do
    text = @fixture |> File.read!() |> with_interval(0.0)
    {:ok, obs} = Observations.parse(text)

    {:ok, lint} = QC.lint_obs_text(text)
    unavailable = Enum.filter(lint.findings, &(&1.code == "OBS-H19"))

    assert [
             %{
               kind: "ObsIntervalUnavailable",
               details: :obs_interval_unavailable,
               severity: "info",
               repairable: true,
               at: %{field: "INTERVAL"}
             }
           ] = unavailable

    {:ok, report} = QC.observation_report(obs)
    assert report.interval_s == 30.0
    assert report.interval_source == "inferred"
    assert Enum.count(report.lint_findings, &(&1.code == "OBS-H19")) == 1
    assert report.notes == []

    assert {:error, :invalid_interval} = QC.observation_report(obs, interval_s: 0.0)

    {:ok, preserved} = QC.repair_obs_text(text)
    refute Enum.any?(preserved.actions, &(&1.id == "A6"))
    assert Enum.any?(preserved.remaining.findings, &(&1.code == "OBS-H19"))
    assert Enum.any?(String.split(preserved.rinex, "\n"), &(label(&1) == "INTERVAL"))

    {:ok, repair} = QC.repair_obs_text(text, set_interval: true)
    assert Enum.any?(repair.actions, &(&1.id == "A6"))
    refute Enum.any?(repair.remaining.findings, &(&1.code == "OBS-H19"))

    {:ok, repaired_obs} = Observations.parse(repair.rinex)
    {:ok, repaired_report} = QC.observation_report(repaired_obs)
    assert repaired_report.interval_s == 30.0
    assert repaired_report.interval_source == "header"

    negative_zero_text = @fixture |> File.read!() |> with_interval(-0.0)
    {:ok, negative_zero_lint} = QC.lint_obs_text(negative_zero_text)

    assert [%{severity: "info"}] =
             Enum.filter(negative_zero_lint.findings, &(&1.code == "OBS-H19"))
  end

  test "public QC detail retains an event epoch flag" do
    text =
      [
        "     3.05           OBSERVATION DATA    G (GPS)         RINEX VERSION / TYPE",
        "G    1 C1C                                                  SYS / # / OBS TYPES",
        "                                                            END OF HEADER",
        "> 2020 01 01 00 00  0.0000000  4  0"
      ]
      |> Enum.join("\n")

    {:ok, report} = QC.lint_obs_text(text)

    assert [
             %{
               kind: "ObsEventEpoch",
               details: {:obs_event_epoch, %{flag: 4}},
               code: "OBS-B07",
               at: %{epoch_index: 0}
             }
           ] = Enum.filter(report.findings, &(&1.code == "OBS-B07"))
  end

  test "public QC fixture exposes GLONASS slot and unretained-header details" do
    text = File.read!(Path.join("test/fixtures/obs", "algo0010_2015001_v1_trim.rnx"))
    {:ok, report} = QC.lint_obs_text(text)

    assert [
             %{
               kind: "ObsUnretainedHeader",
               details: {:obs_unretained_header, %{label: "WAVELENGTH FACT L1/2"}},
               code: "OBS-H90",
               at: %{field: "header"}
             }
           ] = Enum.filter(report.findings, &(&1.kind == "ObsUnretainedHeader"))

    expected_satellites = ~w(R05 R06 R07 R09 R15 R16 R17 R24)

    assert Enum.map(Enum.filter(report.findings, &(&1.kind == "ObsGlonassSlotIssue")), fn finding ->
             {finding.at.satellite, finding.details}
           end) ==
             Enum.map(expected_satellites, fn satellite ->
               {satellite, {:obs_glonass_slot_issue, %{satellite: satellite, issue: "missing slot"}}}
             end)
  end

  test "public QC reports exact out-of-order epoch details" do
    text =
      [
        "     3.05           OBSERVATION DATA    G (GPS)         RINEX VERSION / TYPE",
        "G    1 C1C                                                  SYS / # / OBS TYPES",
        "                                                            END OF HEADER",
        "> 2020 01 01 00 01  0.0000000  0  1",
        "G01       20000000.000",
        "> 2020 01 01 00 00  0.0000000  0  1",
        "G01       20000000.000"
      ]
      |> Enum.join("\n")

    {:ok, report} = QC.lint_obs_text(text)

    assert [finding] = Enum.filter(report.findings, &(&1.kind == "ObsEpochOrder"))
    assert finding.code == "OBS-B01"
    assert finding.at.epoch_index == 1

    assert finding.details ==
             {:obs_epoch_order,
              %{
                current: {{2020, 1, 1}, {0, 0, 0.0}},
                previous: {{2020, 1, 1}, {0, 1, 0.0}}
              }}
  end

  test "public QC preserves both epoch times and canonical time-scale labels" do
    header = fn body, label -> String.pad_trailing(body, 60) <> label end

    text =
      [
        header.(
          "     3.05           OBSERVATION DATA    G (GPS)",
          "RINEX VERSION / TYPE"
        ),
        header.("G    1 C1C", "SYS / # / OBS TYPES"),
        header.(
          "  2020    01    01    00    00    0.0000000     UTC",
          "TIME OF FIRST OBS"
        ),
        header.(
          "  2020    01    01    00    00   30.0000000     GPS",
          "TIME OF LAST OBS"
        ),
        header.("", "END OF HEADER"),
        "> 2020 01 01 00 00  0.0000000  0  1",
        "G01       20000000.000",
        "> 2020 01 01 00 00 30.0000000  0  1",
        "G01       20000001.000"
      ]
      |> Enum.join("\n")

    {:ok, report} = QC.lint_obs_text(text)

    assert [
             %{
               kind: "ObsTimeOfLastMismatch",
               details:
                 {:obs_time_of_last_mismatch,
                  %{
                    declared: {{2020, 1, 1}, {0, 0, 30.0}},
                    declared_scale: "GPST",
                    observed: {{2020, 1, 1}, {0, 0, 30.0}},
                    observed_scale: "UTC"
                  }}
             }
           ] = Enum.filter(report.findings, &(&1.code == "OBS-H08"))
  end

  test "public navigation QC exposes exact implausible-record values" do
    text = File.read!(Path.join("test/fixtures/nav", "BRDC00IGS_R_20201770000_01D_GEC.rnx"))
    {:ok, report} = QC.lint_nav_text(text)

    finding =
      Enum.find(report.findings, fn finding ->
        finding.kind == "NavImplausibleRecord" and
          finding.details ==
            {:nav_implausible_record, %{field: "eccentricity", satellite: "E14", value: 0.1668279268779}}
      end)

    assert finding
    assert finding.code == "NAV-B04"
    assert finding.severity == "warning"
    assert finding.spec_ref == "RINEX QC policy"
    refute finding.repairable
    assert finding.at.epoch_index != nil
  end

  test "zero source INTERVAL is unresolved and removed only when requested" do
    text = @fixture |> File.read!() |> with_interval(0.0) |> header_only()
    {:ok, obs} = Observations.parse(text)

    {:ok, report} = QC.observation_report(obs)
    assert report.interval_s == nil
    assert report.interval_source == "unresolved"
    assert Enum.map(report.notes, & &1.kind) == ["interval_unresolved"]
    assert Enum.count(report.lint_findings, &(&1.code == "OBS-H19")) == 1

    {:ok, preserved} = QC.repair_obs_text(text)
    refute Enum.any?(preserved.actions, &(&1.id == "A6"))
    assert Enum.any?(String.split(preserved.rinex, "\n"), &(label(&1) == "INTERVAL"))

    {:ok, repair} = QC.repair_obs_text(text, set_interval: true)
    assert Enum.any?(repair.actions, &(&1.id == "A6"))
    refute Enum.any?(repair.remaining.findings, &(&1.code == "OBS-H19"))
    refute Enum.any?(String.split(repair.rinex, "\n"), &(label(&1) == "INTERVAL"))
  end

  test "a negative source INTERVAL is invalid metadata" do
    text = @fixture |> File.read!() |> with_interval(-30.0)
    {:ok, obs} = Observations.parse(text)

    {:ok, lint} = QC.lint_obs_text(text)
    invalid = Enum.filter(lint.findings, &(&1.code == "OBS-H20"))
    assert [%{severity: "error", repairable: true}] = invalid

    {:ok, report} = QC.observation_report(obs)
    assert report.interval_s == 30.0
    assert report.interval_source == "inferred"
    assert Enum.count(report.lint_findings, &(&1.code == "OBS-H20")) == 1

    {:ok, preserved} = QC.repair_obs_text(text)
    refute Enum.any?(preserved.actions, &(&1.id == "A6"))
    assert Enum.any?(preserved.remaining.findings, &(&1.code == "OBS-H20"))

    {:ok, repair} = QC.repair_obs_text(text, set_interval: true)
    assert Enum.any?(repair.actions, &(&1.id == "A6"))
    refute Enum.any?(repair.remaining.findings, &(&1.code == "OBS-H20"))

    {:ok, repaired_obs} = Observations.parse(repair.rinex)
    {:ok, repaired_report} = QC.observation_report(repaired_obs)
    assert repaired_report.interval_s == 30.0
    assert repaired_report.interval_source == "header"
  end
end
