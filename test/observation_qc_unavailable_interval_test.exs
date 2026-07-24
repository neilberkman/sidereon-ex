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
    assert [%{severity: "info", repairable: true}] = unavailable

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
