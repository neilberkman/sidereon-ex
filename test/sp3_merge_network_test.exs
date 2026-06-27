defmodule Sidereon.GNSS.SP3MergeNetworkTest do
  # Live smoke test for `Sidereon.GNSS.Data.fetch_merged_sp3/3` against the REAL
  # public HTTPS ultra-rapid archives.
  #
  # Tagged `:network` so it is EXCLUDED by default — see test/test_helper.exs:
  #   ExUnit.start(exclude: [:skyfield_parity, :spk_file, :celestrak, :network])
  # Run it explicitly with:
  #   mix test test/sp3_merge_network_test.exs --include network
  #
  # Not async: it reaches out over HTTPS and writes into a private cache dir.
  use ExUnit.Case, async: false

  alias Sidereon.GNSS.Data
  alias Sidereon.GNSS.SP3

  @centers [:igs_ult, :esa_ult]

  setup do
    # A fresh, unique cache dir per test, removed afterwards. Never the user
    # cache — a live download must not pollute the developer's real cache.
    cache_dir =
      Path.join(
        System.tmp_dir!(),
        "sidereon_fetch_merged_sp3_net_#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(cache_dir) end)
    {:ok, cache_dir: cache_dir}
  end

  describe "fetch_merged_sp3/3 against the real HTTPS ultra-rapid archives" do
    @tag :network
    @tag timeout: 300_000
    test "fetches, merges, and reports across the live multi-center ultra products",
         %{cache_dir: cache_dir} do
      # WHY DateTime.utc_now/0 rather than a fixed date:
      #
      # Ultra-rapid products are the only GNSS products that cover the CURRENT
      # day, and the GSSC archive only retains a rolling recent window of issues.
      # A hard-coded "recent" date would silently rot — within days/weeks the
      # named issue ages out of the archive and the test degrades to the
      # all-absent path, asserting nothing about merge. Using "now" keeps the
      # target inside the live retention window in perpetuity.
      #
      # Robustness near the publication frontier is handled by the library, not
      # by us picking a magic hour: with a NaiveDateTime/DateTime target and no
      # :available_issues opt, fetch_merged_sp3 expands each center to the
      # catalog's issue candidates at-or-before "now" (newest first) and tries
      # them in turn, including the PREVIOUS day's late issues. So even in the
      # first UTC hours — before today's 0000 issue has landed — it falls back to
      # yesterday's newest published issue. We therefore do NOT special-case the
      # clock; "now" is the most robust single choice.
      target = DateTime.utc_now()

      result =
        Data.fetch_merged_sp3(target, @centers,
          cache_dir: cache_dir,
          # Keep a slow/empty HTTPS center from hanging the whole sweep forever.
          retries: 2,
          backoff_ms: 500
        )

      case result do
        {:ok, merged, report} ->
          assert_ok_report(merged, report)

        {:error, {:incompatible_sources, info}} ->
          # THE KEY UNKNOWN, OBSERVED LIVE.
          #
          # If this branch trips it means two+ real centers downloaded fine but
          # their SP3 headers disagree on coordinate_system (or time scale), and
          # the merge refused to mix frames rather than silently averaging across
          # realizations. This is exactly the question the task poses: do the
          # real centers' coordinate_system headers agree?
          #
          # We do NOT hard-fail here — this is a legitimate, informative outcome
          # of the live archive — but we surface everything so a human reading
          # the run can see WHICH centers and WHY they were judged incompatible.
          assert is_list(info.centers)
          assert length(info.centers) >= 2
          assert info.reason != nil

          flunk_informative(
            ":incompatible_sources tripped with real multi-center data — the " <>
              "centers' SP3 frame headers (coordinate_system / time scale) do " <>
              "NOT agree:\n" <>
              "  centers: #{inspect(info.centers)}\n" <>
              "  reason:  #{inspect(info.reason)}\n" <>
              "If this is expected (e.g. an IGS14 vs IGS20 realization split " <>
              "during a frame transition), the merge correctly refused to mix " <>
              "frames; pass a coordinate-system filter / pin a single " <>
              "realization to combine them."
          )

        {:error, {:no_products, reasons}} ->
          # No center yielded a product. With a live archive this should be rare
          # (it usually means a transient outage or that EVERY center is at
          # the publication frontier), but it is not a logic failure — make it
          # loud and informative rather than a bare assertion crash.
          assert is_list(reasons)
          assert Enum.map(reasons, & &1.center) == @centers

          flunk_informative(
            "No ultra-rapid product was retrievable from ANY requested " <>
              "center for #{inspect(target)} — likely a transient archive " <>
              "outage or every center sitting at the publication frontier.\n" <>
              "Per-center reasons:\n" <> format_reasons(reasons)
          )
      end
    end
  end

  # --- success-path assertions ------------------------------------------------

  defp assert_ok_report(merged, report) do
    # Returned an SP3 with at least one contributor.
    assert %SP3{} = merged

    # Report fields required by the task.
    assert Map.has_key?(report, :contributors)
    assert Map.has_key?(report, :absent)
    assert Map.has_key?(report, :source_count)
    assert Map.has_key?(report, :single_product?)

    contributors = report.contributors
    assert is_list(contributors)
    assert length(contributors) >= 1, "a successful merge must have >= 1 contributor"

    # source_count and single_product? are internally consistent with the
    # contributor list.
    assert report.source_count == length(contributors)
    assert report.single_product? == (report.source_count == 1)

    # Every contributor/absent center is one we actually asked for, and each
    # center appears at most once across the two lists (a center is either a
    # contributor or absent, never both).
    contributor_centers = Enum.map(contributors, & &1.center)
    absent_centers = Enum.map(report.absent, & &1.center)

    assert Enum.all?(contributor_centers, &(&1 in @centers))
    assert Enum.all?(absent_centers, &(&1 in @centers))
    assert contributor_centers -- @centers == []
    assert MapSet.disjoint?(MapSet.new(contributor_centers), MapSet.new(absent_centers))

    # The union of contributors + absent covers exactly the requested centers:
    # the sweep accounted for every center one way or the other.
    assert MapSet.new(contributor_centers ++ absent_centers) == MapSet.new(@centers)

    # The merged product carries real satellites (ultra-rapid GPS at minimum).
    ids = SP3.satellite_ids(merged)
    assert is_list(ids)
    assert ids != [], "the merged ultra product should expose at least one satellite"

    # Informational: print what the live archive actually gave us this run, so a
    # human can see whether all requested centers' coordinate frames agreed (i.e. the
    # multi-center merge actually exercised, NOT just a single-product fallthrough).
    IO.puts("""
    [fetch_merged_sp3 live] contributors=#{inspect(contributor_centers)} \
    absent=#{inspect(absent_centers)} source_count=#{report.source_count} \
    single_product?=#{report.single_product?} sats=#{length(ids)}\
    """)

    if report.absent != [], do: IO.puts(format_reasons(report.absent))

    if report.source_count >= 2 do
      # Multi-center merge actually exercised — the real centers' frames AGREED
      # (otherwise we'd be in the :incompatible_sources branch). This is the
      # positive answer to the key unknown for this particular run.
      IO.puts(
        "[fetch_merged_sp3 live] #{report.source_count} centers merged cleanly: " <>
          "their SP3 coordinate_system / time-scale headers AGREED."
      )
    else
      # Only one center contributed this run; the cross-center frame-agreement
      # question wasn't exercised. Not a failure — partial availability is
      # explicitly tolerated — but we note it so a green run isn't mistaken for
      # a multi-center compatibility check.
      IO.puts(
        "[fetch_merged_sp3 live] only one center contributed — multi-center " <>
          "frame agreement NOT exercised this run (partial availability)."
      )
    end
  end

  # --- helpers ----------------------------------------------------------------

  defp format_reasons(reasons) do
    Enum.map_join(reasons, "\n", fn r ->
      "  - #{inspect(r.center)}: #{inspect(Map.get(r, :reason))} " <>
        "(#{inspect(Map.get(r, :filename))})"
    end)
  end

  defp flunk_informative(message), do: flunk(message)
end
