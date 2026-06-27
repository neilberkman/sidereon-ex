defmodule Mix.Tasks.Gnss.BroadcastDiff do
  @shortdoc "Compare a broadcast nav product against a precise SP3 over a window"

  @moduledoc """
  Report broadcast-ephemeris accuracy: the orbit and clock differences between a
  RINEX broadcast navigation product and a precise SP3 product, per satellite and
  overall (3D plus radial / along-track / cross-track RMS and max). This is the
  command-line front end for `Sidereon.GNSS.BroadcastComparison`.

      mix gnss.broadcast_diff --nav BRDC.rnx --sp3 igs.sp3 \\
        --from 2020-06-25T00:15:00 --to 2020-06-25T05:45:00

  Options:

    * `--nav` (required) - path to the RINEX broadcast navigation file.
    * `--sp3` (required) - path to the precise SP3 product for the same day.
    * `--from` / `--to` (required) - ISO 8601 naive datetimes in GPST bounding
      the comparison window.
    * `--step` - sample step in seconds (default `300`).
    * `--system` - constellation letter to compare, e.g. `G`, `E`, `C` (default
      `G`).

  Expected GPS LNAV agreement with IGS precise products is ~1-2 m orbit RMS; a result far
  outside that band points to a parse/eval defect. The broadcast models follow
  IS-GPS-200 (GPS LNAV), the Galileo OS-SIS-ICD, and the BeiDou BDS-SIS-ICD.
  """

  use Mix.Task

  alias Sidereon.GNSS.Broadcast
  alias Sidereon.GNSS.BroadcastComparison
  alias Sidereon.GNSS.SP3

  @switches [
    nav: :string,
    sp3: :string,
    from: :string,
    to: :string,
    step: :integer,
    system: :string
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, strict: @switches)

    nav_path = required(opts, :nav)
    sp3_path = required(opts, :sp3)
    from = opts |> required(:from) |> NaiveDateTime.from_iso8601!()
    to = opts |> required(:to) |> NaiveDateTime.from_iso8601!()
    step_s = Keyword.get(opts, :step, 300)
    system = Keyword.get(opts, :system, "G")

    # The orbit/clock evaluation runs in the NIF, so the application (and its
    # native library) must be started before loading either product.
    Mix.Task.run("app.start")

    broadcast = Broadcast.load!(nav_path)
    sp3 = SP3.load!(sp3_path)

    sat_ids =
      sp3 |> SP3.satellite_ids() |> Enum.filter(&String.starts_with?(&1, system)) |> Enum.sort()

    report =
      BroadcastComparison.compare(broadcast, sp3, sat_ids, %{from: from, to: to, step_s: step_s})

    print_report(report, system, from, to, step_s)
  end

  defp required(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> value
      :error -> Mix.raise("missing required --#{key} option (see `mix help gnss.broadcast_diff`)")
    end
  end

  defp print_report(report, system, from, to, step_s) do
    Mix.shell().info("broadcast-vs-precise #{system}  #{from} .. #{to}  step #{step_s}s\n")

    Mix.shell().info(
      "  sat   n   orbit_rms  orbit_max   radial   along    cross    clock_rms  clock_rms(datum-free)"
    )

    report.per_satellite
    |> Enum.sort_by(fn {sat, _stats} -> sat end)
    |> Enum.each(fn {sat, s} -> Mix.shell().info("  #{sat}  #{row(s)}") end)

    Mix.shell().info("  ---")
    Mix.shell().info("  ALL  #{row(report.overall)}")

    if report.missing != [] do
      Mix.shell().info("\n  skipped (no valid ephemeris) cells: #{inspect(report.missing)}")
    end
  end

  defp row(s) do
    [
      pad(s.count, 4),
      meters(s.orbit_3d_rms_m, 9),
      meters(s.orbit_3d_max_m, 10),
      meters(s.radial_rms_m, 8),
      meters(s.along_rms_m, 8),
      meters(s.cross_rms_m, 8),
      meters(s.clock_rms_m, 10),
      meters(s.clock_datum_removed_rms_m, 21)
    ]
    |> Enum.join("  ")
  end

  defp meters(nil, width), do: pad("-", width)
  defp meters(value, width) when is_float(value), do: pad("#{Float.round(value, 3)} m", width)

  defp pad(value, width), do: value |> to_string() |> String.pad_leading(width)
end
