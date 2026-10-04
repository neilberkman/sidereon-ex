defmodule Sidereon.GNSS.SP3MergePerEpochProvenanceTest do
  # Per-epoch merge provenance: which contributor supplied each cell, where
  # selection changed, and what each contributor covered. The sources are the
  # core's own provenance fixtures, built as text here, so every expectation is
  # a property of an input this file states.
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.SP3

  # G01 at the given `{minute_field, x_km}` epochs of 2020-06-25 00:mm, with Y
  # and Z fixed.
  defp sp3(first_minute, records) do
    seconds_of_week = if first_minute == " 0", do: "432000.00000000", else: "432900.00000000"

    header = [
      "#cP2020  6 25  0 #{first_minute}  0.00000000       #{length(records)} ORBIT IGS14 FIT  TST",
      "## 2111 #{seconds_of_week}   900.00000000 59025 0.0000000000000",
      "+    1   G01  0  0  0  0  0  0  0  0  0  0  0  0  0  0  0  0",
      "++         0  0  0  0  0  0  0  0  0  0  0  0  0  0  0  0  0",
      "%c G  cc GPS ccc cccc cccc cccc cccc ccccc ccccc ccccc ccccc",
      "%c cc cc ccc ccc cccc cccc cccc cccc ccccc ccccc ccccc ccccc",
      "%f  1.2500000  1.025000000  0.00000000000  0.000000000000000",
      "%f  0.0000000  0.000000000  0.00000000000  0.000000000000000",
      "%i    0    0    0    0      0      0      0      0         0",
      "%i    0    0    0    0      0      0      0      0         0",
      "/* TEST SP3-c FIXTURE"
    ]

    lines =
      Enum.flat_map(records, fn {minute, x_km} ->
        x_field = String.pad_leading(:erlang.float_to_binary(x_km, decimals: 6), 14)

        [
          "*  2020  6 25  0 #{minute}  0.00000000",
          "PG01#{x_field} -20000.000000   5000.000000    100.000000"
        ]
      end)

    {:ok, product} = SP3.parse(Enum.join(header ++ lines ++ ["EOF", ""], "\n"))
    product
  end

  # G01 at 00:00 and 00:15.
  defp source([x0, x1]), do: sp3(" 0", [{" 0", x0}, {"15", x1}])
  # G01 at 00:00 only.
  defp early_source(x0), do: sp3(" 0", [{" 0", x0}])
  # G01 at 00:15 only.
  defp late_source(x1), do: sp3("15", [{"15", x1}])

  defp precedence(provenance), do: [combine: :precedence, min_agree: 1, provenance: provenance]

  defp selected_source(%{kind: :combined}), do: nil
  defp selected_source(%{source: source}), do: source

  defp changes(provenance), do: Enum.reject(provenance.transitions, &is_nil(&1.from_source))

  test "provenance is nil unless requested" do
    assert {:ok, _merged, report} = SP3.merge([source([15_000.0, 15_100.0])], precedence(nil))
    assert report.provenance == nil
  end

  test "a single-contributor merge records it for every epoch with no mid-arc transition" do
    assert {:ok, _merged, %{provenance: provenance}} =
             SP3.merge([source([15_000.0, 15_100.0])], precedence(:full))

    assert provenance.mode == :full
    assert length(provenance.cells) == 2
    assert Enum.all?(provenance.cells, &(&1.satellite == "G01" and selected_source(&1.position) == 0))

    # The arc's opening entry is a transition from no source; there is no
    # further change.
    assert [%{from_source: nil, to_source: 0}] = provenance.transitions

    assert [
             %{
               source: 0,
               cells_contributed: 2,
               cells_selected: 2,
               cells_absent: 0,
               first_epoch: %{},
               last_epoch: %{}
             }
           ] = provenance.coverage
  end

  test "a forced precedence switch records one transition naming both sides" do
    # Source 0 carries only the first epoch and source 1 only the second, so
    # under cell precedence the supplier changes at the second epoch.
    assert {:ok, _merged, %{provenance: provenance}} =
             SP3.merge([early_source(15_000.0), late_source(15_100.0)], precedence(:full))

    assert Enum.map(provenance.cells, &selected_source(&1.position)) == [0, 1]
    assert [%{from_source: 0, to_source: 1, reason: :sole_availability}] = changes(provenance)

    assert [
             %{cells_contributed: 1, cells_absent: 1},
             %{cells_contributed: 1, cells_absent: 1}
           ] = provenance.coverage
  end

  test "outlier rejection is recorded as its own reason" do
    # Source 0 leaves the other two at the second epoch and the guard rejects
    # it while it is still present.
    assert {:ok, _merged, report} =
             SP3.merge(
               [source([15_000.0, 25_000.0]), source([15_000.0, 15_100.0]), source([15_000.0, 15_100.0])],
               combine: :precedence,
               min_agree: 2,
               position_tolerance_m: 1.0,
               outlier_reject: [position_tolerance_m: 1.0, clock_tolerance_s: 1.0e-6],
               provenance: :full
             )

    assert Enum.map(report.provenance.cells, &selected_source(&1.position)) == [0, 1]
    assert [%{reason: :outlier_rejection}] = changes(report.provenance)
    assert report.position_outliers != []
  end

  test "a combined cell names no single supplier" do
    assert {:ok, _merged, %{provenance: provenance}} =
             SP3.merge([source([15_000.0, 15_100.0]), source([15_000.0, 15_100.0])], provenance: :full)

    assert Enum.all?(provenance.cells, &(&1.position == %{kind: :combined, rule: :mean, members: [0, 1]}))
    assert Enum.all?(provenance.coverage, &(&1.cells_selected == 0 and &1.cells_contributed == 2))
  end

  test "summary and full modes agree on every transition and coverage they both describe" do
    assert {:ok, _merged, %{provenance: full}} =
             SP3.merge([source([15_000.0, 15_100.0]), late_source(15_100.0)], precedence(:full))

    assert {:ok, _merged, %{provenance: summary}} =
             SP3.merge([source([15_000.0, 15_100.0]), late_source(15_100.0)], precedence(:summary))

    assert full.mode == :full
    assert summary.mode == :summary
    assert full.transitions == summary.transitions
    assert full.coverage == summary.coverage
    assert summary.cells == []
    assert full.cells != []
  end

  test "a negative residual tolerance is refused before any check runs" do
    product = source([15_000.0, 15_100.0])

    assert {:error, {:continuity_options, %{field: :residual_tolerance_m, reason: :negative, value: -1.0}}} =
             SP3.check_continuity(product, residual_tolerance_m: -1.0)

    assert {:error,
            {:invalid_verify_continuity,
             {:continuity_options, %{field: :residual_tolerance_m, reason: :negative, value: -1.0}}}} =
             SP3.merge([product], verify_continuity: [residual_tolerance_m: -1.0])
  end

  test "an unknown provenance mode is refused" do
    assert {:error, {:invalid_merge_policy, :provenance}} =
             SP3.merge([source([15_000.0, 15_100.0])], provenance: :all)
  end
end
