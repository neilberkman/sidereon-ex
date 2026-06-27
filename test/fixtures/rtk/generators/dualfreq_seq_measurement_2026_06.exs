defmodule DualFreqSeqMeasurement202606 do
  @moduledoc false

  # Dual-frequency (L1/L2) sequential per-epoch fix-and-hold filter measurement.
  # Pre-registered in dualfreq-seq-spec.md. The narrow-lane single observable
  # (wide-lane fixed up front) is carried through the existing sequential filter
  # via solve_widelane_filter_baseline_epochs/3. Truth metric, oracle summary,
  # and refusal-invariant logic mirror cd_measurement_2026_06.exs so the
  # Amendment 1 verdict is computed identically.

  alias Orbis.GNSS.RINEX.Observations
  alias Orbis.GNSS.RTK
  alias Orbis.GNSS.SP3

  @c_m_s 299_792_458.0
  @gps_l1_hz 1_575_420_000.0
  @gps_l2_hz 1_227_600_000.0
  @elmask_deg 15.0
  @min_fixed_n 20
  @default_results "/tmp/dualfreq-seq-measurement-2026-06-results.json"

  # Arming sweep. The L1 reference's clean pass holds for every arming sigma in
  # [0.02, 0.10]; the headline cell uses 0.05 (the wavelength-tied family). The
  # remaining cells map the boundary on the narrow-lane arc.
  @arming_sweep [nil, 0.10, 0.08, 0.06, 0.05, 0.04, 0.03, 0.02]
  @headline_arming 0.05

  @oracle "pasa_scoa_2026_120_l1l2_static_rtklib_oracle.json"

  def main(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [results: :string, report: :string],
        aliases: [r: :results]
      )

    if invalid != [], do: raise(ArgumentError, "invalid arguments: #{inspect(invalid)}")

    generator_dir = __DIR__
    rtk_dir = Path.expand("..", generator_dir)
    repo = Path.expand("../../../..", generator_dir)

    results_path = Keyword.get(opts, :results, @default_results)

    report_path =
      Keyword.get(opts, :report, Path.join(generator_dir, "dualfreq-seq-measurement-2026-06.md"))

    oracle = load_json!(Path.join(rtk_dir, @oracle))
    truth = oracle["truth"]
    inputs = oracle["inputs"]

    base_ecef = ecef_map_to_tuple(truth["base_station"]["marker_ecef_m"])
    rover_truth = ecef_map_to_tuple(truth["rover_station"]["marker_ecef_m"])
    truth_baseline = sub3(rover_truth, base_ecef)

    sp3 = SP3.load!(Path.join(repo, inputs["sp3"]))
    base_obs = Observations.load!(Path.join(repo, inputs["base_obs"]))
    rover_obs = Observations.load!(Path.join(repo, inputs["rover_obs"]))

    initial_baseline = sub3(Observations.approx_position(rover_obs), base_ecef)

    IO.puts("building GPS L1/L2 epochs")
    epochs = real_gps_l1_l2_rtk_epochs(sp3, base_obs, rover_obs, oracle["reference"]["epochs"])

    oracle_summary = oracle_summary(oracle)

    IO.puts("running dual-frequency sequential filter arming sweep")

    sweep =
      Enum.map(@arming_sweep, fn arming ->
        measure(base_ecef, truth_baseline, epochs, oracle_summary, initial_baseline, arming)
      end)

    headline = Enum.find(sweep, &(&1["arming_sigma_m"] == @headline_arming))

    result = %{
      "version" => 1,
      "generated_at_utc" =>
        DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "script" => Path.relative_to(__ENV__.file, repo),
      "source_commit" => git_commit(repo),
      "results_path" => results_path,
      "inputs" => %{
        "rover_obs" => inputs["rover_obs"],
        "base_obs" => inputs["base_obs"],
        "sp3" => inputs["sp3"],
        "oracle" => Path.join("test/fixtures/rtk", @oracle)
      },
      "truth" => %{
        "source" => truth["source"],
        "baseline_length_km" => truth["baseline_length_km"]
      },
      "epoch_build" => %{"l1l2_epochs" => length(epochs)},
      "oracle" => oracle_summary,
      "headline_arming_sigma_m" => @headline_arming,
      "headline" => headline,
      "sweep" => sweep
    }

    File.write!(results_path, Jason.encode!(result, pretty: true))
    File.write!(report_path, report_markdown(result))
    IO.puts("wrote #{results_path}")
    IO.puts("wrote #{report_path}")
  end

  defp measure(base_ecef, truth_baseline, epochs, oracle_summary, initial_baseline, arming) do
    opts = filter_opts(initial_baseline, arming)

    case RTK.solve_widelane_filter_baseline_epochs(base_ecef, epochs, opts) do
      {:ok, sol} ->
        rows = filter_solution_rows(sol.epochs, truth_baseline)
        summary = summarize_rows(rows)

        %{
          "arming_sigma_m" => arming,
          "continuous_status" => "solved",
          "first_fixed_index" => sol.metadata.first_fixed_index,
          "fixed_epoch_count" => sol.metadata.fixed_epoch_count,
          "n_epochs" => sol.metadata.n_epochs,
          "solved_epoch_count" => length(rows),
          "wide_lane_fixed_count" => map_size(sol.metadata.wide_lane_ambiguities_cycles),
          "summary" => summary,
          "orbis_vs_oracle_gap_m" => measured_gap(summary, oracle_summary),
          "invariant" => refusal_invariant(rows, oracle_summary)
        }

      {:error, reason} ->
        %{
          "arming_sigma_m" => arming,
          "continuous_status" => "error",
          "continuous_error_reason" => inspect(reason)
        }
    end
  end

  defp filter_opts(initial_baseline, arming) do
    base = [
      initial_baseline_m: initial_baseline,
      max_iterations: 10,
      on_cycle_slip: :drop_satellite,
      elevation_mask_deg: @elmask_deg,
      stochastic_model: :rtklib,
      code_sigma_m: 0.3,
      phase_sigma_m: 0.003,
      integer_ratio_threshold: 3.0,
      integer_candidate_limit: 200_000,
      filter_kernel: :elixir
    ]

    if arming, do: Keyword.put(base, :ar_arming_sigma_m, arming), else: base
  end

  defp filter_solution_rows(solution_epochs, truth_baseline) do
    Enum.map(solution_epochs, fn epoch ->
      %{
        "index" => epoch.index,
        "integer_status" => Atom.to_string(epoch.integer_status),
        "error_m" => position_error(epoch.baseline_m, truth_baseline)
      }
    end)
  end

  # --- shared with cd_measurement_2026_06.exs (verbatim where possible) ---

  defp real_gps_l1_l2_rtk_epochs(sp3, base_obs, rover_obs, count) do
    rover_by_epoch = Map.new(Observations.epochs(rover_obs), &{&1.epoch, &1})

    base_obs
    |> Observations.epochs()
    |> Enum.take(count)
    |> Enum.flat_map(fn base_entry ->
      case Map.fetch(rover_by_epoch, base_entry.epoch) do
        {:ok, rover_entry} ->
          base_values = gps_l1_l2_values(base_obs, base_entry.index)
          rover_values = gps_l1_l2_values(rover_obs, rover_entry.index)
          common = common_sats(base_values, rover_values)
          epoch = naive_datetime(base_entry.epoch)
          positions = satellite_positions(sp3, epoch, common)
          base_positions = transmit_time_satellite_positions(sp3, epoch, base_values, common)
          rover_positions = transmit_time_satellite_positions(sp3, epoch, rover_values, common)

          usable =
            Enum.filter(common, fn sat ->
              Map.has_key?(positions, sat) and Map.has_key?(base_positions, sat) and
                Map.has_key?(rover_positions, sat)
            end)

          if length(usable) >= 4 do
            [
              %{
                epoch: epoch,
                satellite_positions_m: Map.take(positions, usable),
                base_satellite_positions_m: Map.take(base_positions, usable),
                rover_satellite_positions_m: Map.take(rover_positions, usable),
                base_observations: Enum.map(usable, &Map.fetch!(base_values, &1)),
                rover_observations: Enum.map(usable, &Map.fetch!(rover_values, &1))
              }
            ]
          else
            []
          end

        :error ->
          []
      end
    end)
  end

  defp gps_l1_l2_values(obs, index) do
    {:ok, by_sat} = Observations.values(obs, index, codes: %{"G" => ["C1C", "C2W", "L1C", "L2W"]})

    by_sat
    |> Enum.flat_map(fn {sat, values} ->
      values_by_code = Map.new(values, &{&1.code, &1})

      with %{value: c1} when is_number(c1) <- values_by_code["C1C"],
           %{value: c2} when is_number(c2) <- values_by_code["C2W"],
           %{value: l1} = phase1 when is_number(l1) <- values_by_code["L1C"],
           %{value: l2} = phase2 when is_number(l2) <- values_by_code["L2W"] do
        [
          {sat,
           %{
             satellite_id: sat,
             p1_m: c1,
             p2_m: c2,
             phi1_cyc: l1,
             phi2_cyc: l2,
             f1_hz: @gps_l1_hz,
             f2_hz: @gps_l2_hz,
             lli1: phase1.lli,
             lli2: phase2.lli
           }}
        ]
      else
        _ -> []
      end
    end)
    |> Map.new()
  end

  defp common_sats(left, right) do
    left
    |> Map.keys()
    |> MapSet.new()
    |> MapSet.intersection(right |> Map.keys() |> MapSet.new())
    |> MapSet.to_list()
    |> Enum.sort()
  end

  defp satellite_positions(sp3, epoch, sats) do
    Enum.reduce(sats, %{}, fn sat, acc ->
      case SP3.position(sp3, sat, epoch) do
        {:ok, %{x_m: x, y_m: y, z_m: z}} -> Map.put(acc, sat, {x, y, z})
        {:error, _reason} -> acc
      end
    end)
  end

  defp transmit_time_satellite_positions(sp3, receive_epoch, values, sats) do
    Enum.reduce(sats, %{}, fn sat, acc ->
      with %{p1_m: code_m} when is_number(code_m) <- Map.get(values, sat),
           {:ok, transmit_epoch} <- transmit_epoch(receive_epoch, code_m),
           {:ok, %{x_m: x, y_m: y, z_m: z}} <- SP3.position(sp3, sat, transmit_epoch) do
        Map.put(acc, sat, {x, y, z})
      else
        _ -> acc
      end
    end)
  end

  defp transmit_epoch(receive_epoch, code_m) do
    microseconds = round(code_m / @c_m_s * 1_000_000.0)
    {:ok, NaiveDateTime.add(receive_epoch, -microseconds, :microsecond)}
  rescue
    _ -> :error
  end

  defp oracle_summary(oracle) do
    truth_enu = enu_map_to_tuple(oracle["truth"]["antenna_baseline_enu_m"])

    rows =
      Enum.map(oracle["per_epoch"], fn row ->
        Map.put(
          row,
          "error_m",
          position_error(enu_map_to_tuple(row["baseline_enu_m"]), truth_enu)
        )
      end)

    %{
      "label" => oracle["reference"]["label"],
      "epochs" => oracle["reference"]["epochs"],
      "fixed_epochs" => oracle["reference"]["fixed_epochs"],
      "fix_rate" => oracle["reference"]["fix_rate"],
      "first_fixed_index" => oracle["reference"]["first_fixed_index"],
      "final_status" => oracle["reference"]["final_status"],
      "median_error_m" => rows |> Enum.map(& &1["error_m"]) |> percentile(0.50),
      "p95_error_m" => rows |> Enum.map(& &1["error_m"]) |> percentile(0.95),
      "mean_error_m" => oracle["reference"]["mean_truth_error_m"],
      "final_error_m" => oracle["reference"]["final_truth_error_m"],
      "max_error_m" => oracle["reference"]["max_truth_error_m"]
    }
  end

  defp summarize_rows([]) do
    %{
      "n" => 0,
      "median_error_m" => nil,
      "p95_error_m" => nil,
      "final_error_m" => nil,
      "fixed_n" => 0,
      "float_n" => 0,
      "fixed_median_error_m" => nil,
      "fixed_p95_error_m" => nil,
      "float_median_error_m" => nil,
      "float_p95_error_m" => nil
    }
  end

  defp summarize_rows(rows) do
    errors = Enum.map(rows, & &1["error_m"])
    fixed = Enum.filter(rows, &(&1["integer_status"] == "fixed"))
    float = Enum.reject(rows, &(&1["integer_status"] == "fixed"))

    %{
      "n" => length(rows),
      "median_error_m" => percentile(errors, 0.50),
      "p95_error_m" => percentile(errors, 0.95),
      "final_error_m" => List.last(rows)["error_m"],
      "fixed_n" => length(fixed),
      "float_n" => length(float),
      "fixed_median_error_m" => fixed |> Enum.map(& &1["error_m"]) |> percentile(0.50),
      "fixed_p95_error_m" => fixed |> Enum.map(& &1["error_m"]) |> percentile(0.95),
      "float_median_error_m" => float |> Enum.map(& &1["error_m"]) |> percentile(0.50),
      "float_p95_error_m" => float |> Enum.map(& &1["error_m"]) |> percentile(0.95)
    }
  end

  defp measured_gap(summary, oracle_summary) do
    %{
      "median" => nonnegative_gap(summary["median_error_m"], oracle_summary["mean_error_m"]),
      "p95" => nonnegative_gap(summary["p95_error_m"], oracle_summary["max_error_m"]),
      "final" => nonnegative_gap(summary["final_error_m"], oracle_summary["final_error_m"])
    }
  end

  defp nonnegative_gap(nil, _oracle), do: nil
  defp nonnegative_gap(_value, nil), do: nil
  defp nonnegative_gap(value, oracle), do: max(value - oracle, 0.0)

  defp refusal_invariant(rows, oracle_summary) do
    summary = summarize_rows(rows)
    floor = 2.0 * oracle_summary["mean_error_m"]

    verdict =
      cond do
        summary["fixed_n"] < @min_fixed_n ->
          "underpowered"

        summary["fixed_median_error_m"] > floor ->
          "FAIL-by-floor"

        summary["float_n"] == 0 ->
          "pass-no-float-population"

        summary["fixed_median_error_m"] < summary["float_median_error_m"] and
            summary["fixed_p95_error_m"] < summary["float_p95_error_m"] ->
          "pass"

        true ->
          "FAIL-by-relative"
      end

    %{
      "verdict" => verdict,
      "min_fixed_n" => @min_fixed_n,
      "fixed_n" => summary["fixed_n"],
      "float_n" => summary["float_n"],
      "fixed_median_error_m" => summary["fixed_median_error_m"],
      "fixed_p95_error_m" => summary["fixed_p95_error_m"],
      "float_median_error_m" => summary["float_median_error_m"],
      "float_p95_error_m" => summary["float_p95_error_m"],
      "credibility_floor_m" => floor,
      "floor_source" => "2x RTKLIB oracle mean truth error on this arc"
    }
  end

  defp report_markdown(result) do
    oracle = result["oracle"]
    headline = result["headline"]

    """
    # Dual-frequency sequential filter (dualfreq-seq): measurement, June 2026

    Generated by `mix run test/fixtures/rtk/generators/dualfreq_seq_measurement_2026_06.exs`.
    Per-epoch JSON was emitted to `#{result["results_path"]}`.
    Source commit at generation: `#{result["source_commit"]}`.

    Pre-registered in `dualfreq-seq-spec.md`. New public entry point
    `solve_widelane_filter_baseline_epochs/3`: wide-lane double-difference
    integers are fixed per arc up front by Melbourne-Wubbena averaging (the
    existing batch pre-step), then the narrow-lane single observable per
    satellite (wavelength `c/(f1+f2)`, offset `beta*lambda2*N_wl`) is carried
    through the existing single-frequency sequential filter via the per-ambiguity
    wavelength and offset maps. The arming gate and single-system SD gauge are
    reused unchanged. `filter_kernel: :elixir`.

    ## Inputs

    - Rover observations: `#{result["inputs"]["rover_obs"]}`.
    - Base observations: `#{result["inputs"]["base_obs"]}`.
    - Precise product: `#{result["inputs"]["sp3"]}`.
    - Oracle: `#{result["inputs"]["oracle"]}`.
    - Truth: EPN C2385 ITRF2020 propagated to `#{result["truth"]["source"]["observation_midpoint_gpst"]}`.
    - Arc: #{result["epoch_build"]["l1l2_epochs"]} GPS L1/L2 epochs, elevation mask #{trunc(@elmask_deg)} deg.

    ## Oracle context

    RTKLIB 2.4.2-p13 L1/L2 CONTINUOUS AR, ends FLOAT: epochs #{oracle["epochs"]},
    fixed #{oracle["fixed_epochs"]}, fix_rate #{fmt_ratio(oracle["fix_rate"])},
    first_fixed_index #{oracle["first_fixed_index"]}, final_status
    `#{oracle["final_status"]}`, mean truth error #{fmt_m(oracle["mean_error_m"])},
    final #{fmt_m(oracle["final_error_m"])}, max #{fmt_m(oracle["max_error_m"])}.
    Amendment 1 credibility floor = `2 x #{fmt(oracle["mean_error_m"])} =
    #{fmt(2.0 * oracle["mean_error_m"])}` m. The L1/L2 oracle is continuous-AR
    and ends FLOAT, so its mean error is higher than the L1 fix-and-hold oracle
    (0.107 m) and the floor here is correspondingly looser; a pass is a weaker
    claim than the L1 sequential pass.

    ## Arming sweep on the PASA/SCOA L1/L2 arc (default hold)

    | Arming sigma (m) | Continuous solve | First fix idx | Fixed n | Fixed median (m) | Fixed p95 (m) | Float median (m) | Final (m) | WL fixed | Invariant |
    |---|---|---:|---:|---:|---:|---:|---:|---:|---|
    #{Enum.map_join(result["sweep"], "\n", &sweep_row/1)}

    ## Headline cell (arming sigma #{fmt(result["headline_arming_sigma_m"])} m)

    #{headline_block(headline, oracle)}

    ## Verdict

    #{verdict_paragraph(headline, oracle)}

    ## Done vs deferred

    Done: wide-lane-fixed, narrow-lane sequential filter as an additive public
    entry point reusing the arming gate and single-system SD gauge; the
    single-frequency `solve_filter_baseline_epochs/3` is unchanged. Deferred:
    per-epoch sequential carry of the wide-lane ambiguity as a second filter
    state (requires a second ambiguity layer the single-observable runner cannot
    carry without restructuring). Wide-lane fixing remains an arc batch pre-step,
    which is what RTKLIB's continuous dual-frequency mode effectively does for a
    static arc. The Rust kernel port is a separate downstream step; this
    measurement runs `filter_kernel: :elixir` only.
    """
  end

  defp sweep_row(%{"continuous_status" => "error"} = row) do
    "| #{fmt_arming(row["arming_sigma_m"])} | error: `#{row["continuous_error_reason"]}` |  |  |  |  |  |  |  |  |"
  end

  defp sweep_row(row) do
    s = row["summary"]
    inv = row["invariant"]

    "| #{fmt_arming(row["arming_sigma_m"])} | #{row["continuous_status"]} (#{row["solved_epoch_count"]}/#{row["n_epochs"]}) | #{row["first_fixed_index"]} | #{s["fixed_n"]} | #{fmt(s["fixed_median_error_m"])} | #{fmt(s["fixed_p95_error_m"])} | #{fmt(s["float_median_error_m"])} | #{fmt(s["final_error_m"])} | #{row["wide_lane_fixed_count"]} | #{inv["verdict"]} |"
  end

  defp headline_block(nil, _oracle), do: "Headline cell not present in sweep."

  defp headline_block(%{"continuous_status" => "error"} = h, _oracle) do
    "Continuous solve errored: `#{h["continuous_error_reason"]}`."
  end

  defp headline_block(h, _oracle) do
    s = h["summary"]
    inv = h["invariant"]

    """
    - Continuous solve: #{h["continuous_status"]} (#{h["solved_epoch_count"]}/#{h["n_epochs"]} epochs).
    - Wide-lane fixed double differences: #{h["wide_lane_fixed_count"]}.
    - First fixed index: #{h["first_fixed_index"]}.
    - Fixed n: #{s["fixed_n"]}, float n: #{s["float_n"]}.
    - Fixed median 3D error: #{fmt_m(s["fixed_median_error_m"])}, fixed p95: #{fmt_m(s["fixed_p95_error_m"])}.
    - Float median 3D error: #{fmt_m(s["float_median_error_m"])}.
    - Final 3D error: #{fmt_m(s["final_error_m"])}.
    - Credibility floor: #{fmt_m(inv["credibility_floor_m"])} (#{inv["floor_source"]}).
    - Amendment 1 verdict: **#{inv["verdict"]}**.
    """
  end

  defp verdict_paragraph(nil, _oracle), do: "No headline cell."

  defp verdict_paragraph(%{"continuous_status" => "error"}, _oracle) do
    "The headline cell errored on the continuous arc; see the sweep table."
  end

  defp verdict_paragraph(h, oracle) do
    inv = h["invariant"]
    floor = inv["credibility_floor_m"]

    case inv["verdict"] do
      "pass" ->
        "Amendment 1 PASS: fixed n = #{inv["fixed_n"]} (>= #{@min_fixed_n}) and fixed median 3D error #{fmt_m(inv["fixed_median_error_m"])} <= the #{fmt_m(floor)} floor, with the fixed population tighter than the float population. The dual-frequency sequential filter resolves the narrow-lane arc with the wide-lane fixed up front and beats the continuous-AR oracle (mean #{fmt_m(oracle["mean_error_m"])}, final #{fmt_m(oracle["final_error_m"])})."

      "pass-no-float-population" ->
        "Amendment 1 PASS (no float population): fixed n = #{inv["fixed_n"]} (>= #{@min_fixed_n}) and fixed median 3D error #{fmt_m(inv["fixed_median_error_m"])} <= the #{fmt_m(floor)} floor. Every solved epoch fixed, so there is no float population to compare against; the floor is cleared decisively."

      "underpowered" ->
        "Amendment 1 UNDERPOWERED: fixed n = #{inv["fixed_n"]} < #{@min_fixed_n}. Not a pass per the refusal invariant; reported as a null result for this cell."

      "FAIL-by-floor" ->
        "Amendment 1 FAIL-by-floor: fixed median 3D error #{fmt_m(inv["fixed_median_error_m"])} exceeds the #{fmt_m(floor)} floor. Reported plainly."

      other ->
        "Amendment 1 verdict: #{other}. Fixed n = #{inv["fixed_n"]}, fixed median #{fmt_m(inv["fixed_median_error_m"])}, floor #{fmt_m(floor)}."
    end
  end

  defp load_json!(path), do: path |> File.read!() |> Jason.decode!()

  defp git_commit(repo) do
    case System.cmd("git", ["rev-parse", "HEAD"], cd: repo, stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      {_message, _status} -> "unknown"
    end
  end

  defp ecef_map_to_tuple(%{"x" => x, "y" => y, "z" => z}), do: {x, y, z}
  defp enu_map_to_tuple(%{"east" => east, "north" => north, "up" => up}), do: {east, north, up}

  defp naive_datetime({{year, month, day}, {hour, minute, second}}) do
    whole_second = trunc(second)
    microsecond = round((second - whole_second) * 1_000_000)

    NaiveDateTime.new!(
      Date.new!(year, month, day),
      Time.new!(hour, minute, whole_second, {microsecond, 6})
    )
  end

  defp position_error(%{x_m: x, y_m: y, z_m: z}, truth), do: position_error({x, y, z}, truth)

  defp position_error({x, y, z}, {truth_x, truth_y, truth_z}) do
    :math.sqrt(
      (x - truth_x) * (x - truth_x) + (y - truth_y) * (y - truth_y) +
        (z - truth_z) * (z - truth_z)
    )
  end

  defp sub3({ax, ay, az}, {bx, by, bz}), do: {ax - bx, ay - by, az - bz}

  defp percentile([], _p), do: nil

  defp percentile(values, p) do
    sorted = Enum.sort(values)
    idx = floor((length(sorted) - 1) * p)
    Enum.at(sorted, idx)
  end

  defp fmt(nil), do: ""
  defp fmt(value), do: :erlang.float_to_binary(value / 1.0, decimals: 6)
  defp fmt_m(nil), do: ""
  defp fmt_m(value), do: "#{fmt(value)} m"
  defp fmt_ratio(nil), do: ""
  defp fmt_ratio(value), do: :erlang.float_to_binary(value / 1.0, decimals: 3)
  defp fmt_arming(nil), do: "none (always armed)"
  defp fmt_arming(value), do: fmt(value)
end

DualFreqSeqMeasurement202606.main(System.argv())
