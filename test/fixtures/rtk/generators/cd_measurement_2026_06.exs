defmodule CDMeasurement202606 do
  @moduledoc false

  alias Orbis.GNSS.RINEX.Observations
  alias Orbis.GNSS.RTK
  alias Orbis.GNSS.SP3

  @c_m_s 299_792_458.0
  @gps_l1_hz 1_575_420_000.0
  @gps_l2_hz 1_227_600_000.0
  @gps_l1_wavelength_m @c_m_s / @gps_l1_hz
  @gps_l2_wavelength_m @c_m_s / @gps_l2_hz
  @earth_radius_m 6_378_137.0
  @elmask_deg 15.0
  @min_fixed_n 20
  @default_batch_prefix_step 4
  @default_results "/tmp/cd-measurement-2026-06-results.json"

  @oracles %{
    l1: "pasa_scoa_2026_120_l1_static_fixhold_rtklib_oracle.json",
    l1l2: "pasa_scoa_2026_120_l1l2_static_rtklib_oracle.json"
  }

  @option_notes [
    {"filter_kernel", "rust default",
     "The shipped sequential kernel is measured; no solver or library code is changed."},
    {"initial_baseline_m", "RINEX rover APPROX POSITION XYZ minus propagated SCOA ARP",
     "This keeps the seed independent of oracle truth while staying in the static-filter convergence basin."},
    {"elevation_mask_deg", "15.0",
     "Matches the Phase 1 RTKLIB C+D oracle configs (`pos1-elmask = 15`)."},
    {"stochastic_model", "rtklib",
     "Matches the real-arc RTK tests and RTKLIB-style phase/code weighting."},
    {"code_sigma_m", "0.3", "RTKLIB config uses `errphase = 0.003` and L1 `eratio = 100`."},
    {"phase_sigma_m", "0.003", "Matches the RTKLIB oracle phase scale."},
    {"integer_ratio_threshold", "3.0", "Matches the pre-registered oracle AR bar."},
    {"integer_candidate_limit", "200000", "Matches the real-arc RTK tests."},
    {"l1_on_cycle_slip", "split_arc",
     "Matches the established sequential real-arc harness behavior for carried ambiguity arcs."},
    {"l1l2_batch_on_cycle_slip", "drop_satellite",
     "Matches the existing wide-lane/narrow-lane real-arc batch test path; the shipped batch solver does not accept split-arc synthetic IDs with mixed ambiguity wavelengths."},
    {"process_noise_baseline_sigma_m", "0.0 default",
     "Static baseline cell; no kinematic time update is introduced."}
  ]

  def main(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [results: :string, report: :string, batch_prefix_step: :integer],
        aliases: [r: :results]
      )

    if invalid != [] do
      raise ArgumentError, "invalid arguments: #{inspect(invalid)}"
    end

    generator_dir = __DIR__
    rtk_dir = Path.expand("..", generator_dir)
    fixtures_dir = Path.expand("../..", generator_dir)
    repo = Path.expand("../../../..", generator_dir)

    results_path = Keyword.get(opts, :results, @default_results)

    report_path =
      Keyword.get(opts, :report, Path.join(generator_dir, "cd-measurement-2026-06.md"))

    batch_prefix_step = Keyword.get(opts, :batch_prefix_step, @default_batch_prefix_step)

    l1_oracle = load_json!(Path.join(rtk_dir, @oracles.l1))
    l1l2_oracle = load_json!(Path.join(rtk_dir, @oracles.l1l2))
    truth = l1_oracle["truth"]
    inputs = l1_oracle["inputs"]

    require_same_inputs!(inputs, l1l2_oracle["inputs"])

    base_ecef = ecef_map_to_tuple(truth["base_station"]["marker_ecef_m"])
    rover_truth = ecef_map_to_tuple(truth["rover_station"]["marker_ecef_m"])
    truth_baseline = sub3(rover_truth, base_ecef)

    sp3 = SP3.load!(Path.join(repo, inputs["sp3"]))
    base_obs = Observations.load!(Path.join(repo, inputs["base_obs"]))
    rover_obs = Observations.load!(Path.join(repo, inputs["rover_obs"]))

    initial_baseline = sub3(Observations.approx_position(rover_obs), base_ecef)

    IO.puts("building GPS L1 epochs")
    l1_epochs = real_gps_l1_rtk_epochs(sp3, base_obs, rover_obs, l1_oracle["reference"]["epochs"])
    IO.puts("building GPS L1/L2 epochs")

    l1l2_epochs =
      real_gps_l1_l2_rtk_epochs(sp3, base_obs, rover_obs, l1l2_oracle["reference"]["epochs"])

    l1_opts = l1_filter_opts(initial_baseline)
    l1l2_opts = l1l2_batch_opts(initial_baseline)

    IO.puts("running L1 sequential filter")
    l1_cell = measure_l1_filter(base_ecef, truth_baseline, l1_epochs, l1_oracle, l1_opts)

    IO.puts("running L1/L2 full-arc batch solve")

    batch_full =
      measure_l1l2_full_batch(base_ecef, truth_baseline, l1l2_epochs, l1l2_oracle, l1l2_opts)

    IO.puts("running L1/L2 prefix batch distribution")

    batch_prefix =
      measure_l1l2_prefix_batch(
        base_ecef,
        truth_baseline,
        l1l2_epochs,
        l1l2_oracle,
        l1l2_opts,
        batch_prefix_step
      )

    IO.puts("computing term ledger")

    ledger =
      term_ledger(
        fixtures_dir,
        base_ecef,
        rover_truth,
        l1_epochs,
        l1l2_epochs,
        l1_cell,
        truth
      )

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
        "clk" => inputs["clk"],
        "antex" => inputs["antex"],
        "l1_oracle" => Path.join("test/fixtures/rtk", @oracles.l1),
        "l1l2_oracle" => Path.join("test/fixtures/rtk", @oracles.l1l2)
      },
      "truth" => %{
        "source" => truth["source"],
        "base_ecef_m" => tuple3_json(base_ecef),
        "rover_ecef_m" => tuple3_json(rover_truth),
        "baseline_ecef_m" => tuple3_json(truth_baseline),
        "baseline_length_km" => truth["baseline_length_km"],
        "baseline_enu_m" => truth["antenna_baseline_enu_m"]
      },
      "epoch_build" => %{
        "l1_epochs" => length(l1_epochs),
        "l1l2_epochs" => length(l1l2_epochs),
        "sp3_positions" =>
          "per-receiver transmit-time positions from receiver pseudorange, as in test/gnss_rtk_real_arc_test.exs"
      },
      "options" => option_notes_json(),
      "cells" => %{
        "l1_static_filter" => l1_cell,
        "l1l2_static_batch_full" => batch_full,
        "l1l2_static_batch_prefix" => batch_prefix
      },
      "ledger" => ledger,
      "capability_order" => capability_order(ledger, l1_cell)
    }

    File.write!(results_path, Jason.encode!(result, pretty: true))
    File.write!(report_path, report_markdown(result))

    IO.puts("wrote #{results_path}")
    IO.puts("wrote #{report_path}")
  end

  defp load_json!(path), do: path |> File.read!() |> Jason.decode!()

  defp require_same_inputs!(inputs, other_inputs) do
    for key <- ["rover_obs", "base_obs", "sp3", "clk", "antex"] do
      if inputs[key] != other_inputs[key] do
        raise "oracle input mismatch for #{key}: #{inputs[key]} != #{other_inputs[key]}"
      end
    end
  end

  defp l1_filter_opts(initial_baseline) do
    [
      initial_baseline_m: initial_baseline,
      max_iterations: 10,
      on_cycle_slip: :split_arc,
      elevation_mask_deg: @elmask_deg,
      stochastic_model: :rtklib,
      code_sigma_m: 0.3,
      phase_sigma_m: 0.003,
      ambiguity_wavelength_m: @gps_l1_wavelength_m,
      integer_ratio_threshold: 3.0,
      integer_candidate_limit: 200_000
    ]
  end

  defp l1l2_batch_opts(initial_baseline) do
    [
      initial_baseline_m: initial_baseline,
      max_iterations: 10,
      on_cycle_slip: :drop_satellite,
      elevation_mask_deg: @elmask_deg,
      stochastic_model: :rtklib,
      code_sigma_m: 0.3,
      phase_sigma_m: 0.003,
      integer_ratio_threshold: 3.0,
      integer_candidate_limit: 200_000
    ]
  end

  defp measure_l1_filter(base_ecef, truth_baseline, epochs, oracle, opts) do
    oracle_summary = oracle_summary(oracle)

    case RTK.solve_filter_baseline_epochs(base_ecef, epochs, opts) do
      {:ok, sol} ->
        rows = filter_solution_rows(sol.epochs, truth_baseline)
        summary = summarize_rows(rows)

        %{
          "label" => "l1_static_filter",
          "description" => "GPS L1 sequential static filter, stock Rust kernel default.",
          "reference_satellites" => stringify_map(sol.metadata.reference_satellites),
          "metadata" => %{
            "filter_kernel" => Atom.to_string(sol.metadata.filter_kernel),
            "continuous_status" => "solved",
            "first_fixed_index" => sol.metadata.first_fixed_index,
            "fixed_epoch_count" => sol.metadata.fixed_epoch_count,
            "n_epochs" => sol.metadata.n_epochs,
            "solved_epoch_count" => length(rows),
            "dropped_epoch_count" => 0,
            "segment_count" => 1,
            "segments" => [
              %{
                "start_index" => 0,
                "end_index" => max(length(rows) - 1, 0),
                "solved_epochs" => length(rows)
              }
            ],
            "dropped_epochs" => []
          },
          "summary" => summary,
          "oracle" => oracle_summary,
          "orbis_vs_oracle_gap_m" => measured_gap(summary, oracle_summary),
          "invariant" => refusal_invariant(rows, oracle_summary),
          "per_epoch" => rows
        }

      {:error, reason} ->
        {rows, segments, dropped} =
          solve_filter_segments(base_ecef, truth_baseline, epochs, opts)

        rows = Enum.sort_by(rows, & &1["index"])
        summary = summarize_rows(rows)
        reference_satellite = highest_average_reference(epochs, base_ecef)

        %{
          "label" => "l1_static_filter",
          "description" =>
            "GPS L1 sequential static filter, stock Rust kernel default. The full continuous arc errors; the reported distribution uses reset sub-arcs with identical solver options.",
          "reference_satellites" => %{"G" => reference_satellite},
          "metadata" => %{
            "filter_kernel" => "rust default",
            "continuous_status" => "error",
            "continuous_error_reason" => inspect(reason),
            "first_fixed_index" => first_fixed_index(rows),
            "fixed_epoch_count" => summary["fixed_n"],
            "n_epochs" => length(epochs),
            "solved_epoch_count" => length(rows),
            "dropped_epoch_count" => length(dropped),
            "segment_count" => length(segments),
            "segments" => segments,
            "dropped_epochs" => dropped
          },
          "summary" => summary,
          "oracle" => oracle_summary,
          "orbis_vs_oracle_gap_m" => measured_gap(summary, oracle_summary),
          "invariant" => refusal_invariant(rows, oracle_summary),
          "per_epoch" => rows
        }
    end
  end

  defp filter_solution_rows(solution_epochs, truth_baseline, offset \\ 0) do
    Enum.map(solution_epochs, fn epoch ->
      error = position_error(epoch.baseline_m, truth_baseline)

      %{
        "index" => offset + epoch.index,
        "time" => NaiveDateTime.to_iso8601(epoch.epoch),
        "integer_status" => Atom.to_string(epoch.integer_status),
        "integer_ratio" => epoch.integer_ratio,
        "error_m" => error,
        "baseline_ecef_m" => ecef_solution_json(epoch.baseline_m),
        "satellites" => residual_satellite_count(epoch)
      }
    end)
  end

  defp solve_filter_segments(base_ecef, truth_baseline, epochs, opts) do
    {rows, segments, dropped} = solve_filter_segments(base_ecef, truth_baseline, epochs, opts, 0)

    {
      Enum.sort_by(rows, & &1["index"]),
      Enum.sort_by(segments, & &1["start_index"]),
      Enum.sort_by(dropped, & &1["index"])
    }
  end

  defp solve_filter_segments(_base_ecef, _truth_baseline, [], _opts, _offset), do: {[], [], []}

  defp solve_filter_segments(base_ecef, truth_baseline, epochs, opts, offset) do
    case RTK.solve_filter_baseline_epochs(base_ecef, epochs, opts) do
      {:ok, sol} ->
        rows = filter_solution_rows(sol.epochs, truth_baseline, offset)

        {
          rows,
          [
            %{
              "start_index" => offset,
              "end_index" => offset + length(epochs) - 1,
              "solved_epochs" => length(rows)
            }
          ],
          []
        }

      {:error, reason} ->
        split_or_drop_filter_segment(base_ecef, truth_baseline, epochs, opts, offset, reason)
    end
  end

  defp split_or_drop_filter_segment(_base_ecef, _truth_baseline, [epoch], _opts, offset, reason) do
    {
      [],
      [],
      [
        %{
          "index" => offset,
          "time" => NaiveDateTime.to_iso8601(epoch.epoch),
          "reason" => inspect(reason)
        }
      ]
    }
  end

  defp split_or_drop_filter_segment(base_ecef, truth_baseline, epochs, opts, offset, reason) do
    len = length(epochs)

    case singular_epoch_index(reason, len) do
      {:drop, local_index} ->
        left = Enum.take(epochs, local_index)
        right = Enum.drop(epochs, local_index + 1)
        dropped_epoch = Enum.at(epochs, local_index)

        {left_rows, left_segments, left_dropped} =
          solve_filter_segments(base_ecef, truth_baseline, left, opts, offset)

        {right_rows, right_segments, right_dropped} =
          solve_filter_segments(
            base_ecef,
            truth_baseline,
            right,
            opts,
            offset + local_index + 1
          )

        {
          left_rows ++ right_rows,
          left_segments ++ right_segments,
          [
            %{
              "index" => offset + local_index,
              "time" => NaiveDateTime.to_iso8601(dropped_epoch.epoch),
              "reason" => inspect(reason)
            }
            | left_dropped ++ right_dropped
          ]
        }

      :bisect ->
        split_at = div(len, 2)
        left = Enum.take(epochs, split_at)
        right = Enum.drop(epochs, split_at)

        {left_rows, left_segments, left_dropped} =
          solve_filter_segments(base_ecef, truth_baseline, left, opts, offset)

        {right_rows, right_segments, right_dropped} =
          solve_filter_segments(base_ecef, truth_baseline, right, opts, offset + split_at)

        {
          left_rows ++ right_rows,
          left_segments ++ right_segments,
          left_dropped ++ right_dropped
        }
    end
  end

  defp singular_epoch_index({:singular_geometry, metadata}, len) when is_list(metadata) do
    case Keyword.get(metadata, :epoch_index) do
      index when is_integer(index) and index >= 0 and index < len -> {:drop, index}
      _ -> :bisect
    end
  end

  defp singular_epoch_index(_reason, _len), do: :bisect

  defp first_fixed_index(rows) do
    case Enum.find(rows, &(&1["integer_status"] == "fixed")) do
      nil -> nil
      row -> row["index"]
    end
  end

  defp measure_l1l2_full_batch(base_ecef, truth_baseline, epochs, oracle, opts) do
    result = RTK.solve_widelane_fixed_baseline_epochs(base_ecef, epochs, opts)
    oracle_summary = oracle_summary(oracle)

    case result do
      {:ok, sol} ->
        error = position_error(sol.baseline_m, truth_baseline)
        status = Atom.to_string(sol.metadata.integer_status)

        %{
          "label" => "l1l2_static_batch_full",
          "description" => "Full 2 h GPS L1/L2 wide-lane/narrow-lane batch solve.",
          "status" => "solved",
          "integer_status" => status,
          "integer_ratio" => sol.metadata.integer_ratio,
          "reference_satellite_id" => primary_reference_satellite(sol.metadata),
          "reference_satellites" => stringify_map(Map.get(sol.metadata, :reference_satellites)),
          "wide_lane_fixed" => sol.metadata.wide_lane_fixed,
          "error_m" => error,
          "baseline_ecef_m" => ecef_solution_json(sol.baseline_m),
          "oracle" => oracle_summary,
          "orbis_vs_oracle_gap_m" => %{
            "final" => max(error - oracle_summary["final_error_m"], 0.0),
            "mean" => max(error - oracle_summary["mean_error_m"], 0.0)
          }
        }

      {:error, reason} ->
        %{
          "label" => "l1l2_static_batch_full",
          "description" => "Full 2 h GPS L1/L2 wide-lane/narrow-lane batch solve.",
          "status" => "error",
          "error_reason" => inspect(reason),
          "oracle" => oracle_summary
        }
    end
  end

  defp measure_l1l2_prefix_batch(base_ecef, truth_baseline, epochs, oracle, opts, step) do
    min_prefix = 4
    oracle_summary = oracle_summary(oracle)
    step = max(step, 1)

    prefix_sizes =
      min_prefix
      |> Range.new(length(epochs), step)
      |> Enum.to_list()
      |> then(&Enum.uniq(&1 ++ [length(epochs)]))

    prefixes =
      Enum.map(prefix_sizes, fn n ->
        case RTK.solve_widelane_fixed_baseline_epochs(base_ecef, Enum.take(epochs, n), opts) do
          {:ok, sol} ->
            %{
              "prefix_epochs" => n,
              "status" => "solved",
              "integer_status" => Atom.to_string(sol.metadata.integer_status),
              "integer_ratio" => sol.metadata.integer_ratio,
              "error_m" => position_error(sol.baseline_m, truth_baseline),
              "reference_satellite_id" => primary_reference_satellite(sol.metadata),
              "reference_satellites" =>
                stringify_map(Map.get(sol.metadata, :reference_satellites))
            }

          {:error, reason} ->
            %{
              "prefix_epochs" => n,
              "status" => "error",
              "error_reason" => inspect(reason)
            }
        end
      end)

    solved_rows = Enum.filter(prefixes, &(&1["status"] == "solved"))

    %{
      "label" => "l1l2_static_batch_prefix",
      "description" =>
        "Growing-prefix GPS L1/L2 batch solve distribution. Each row solves a static batch over epochs 1..n.",
      "prefix_step" => step,
      "summary" => summarize_rows(solved_rows),
      "oracle" => oracle_summary,
      "orbis_vs_oracle_gap_m" => measured_gap(summarize_rows(solved_rows), oracle_summary),
      "invariant" => refusal_invariant(solved_rows, oracle_summary),
      "prefixes" => prefixes
    }
  end

  defp term_ledger(fixtures_dir, base_ecef, rover_ecef, l1_epochs, l1l2_epochs, l1_cell, truth) do
    base_ant = truth["base_station"]["antenna"]
    rover_ant = truth["rover_station"]["antenna"]
    antex_path = Path.join(fixtures_dir, "antex/igs20_pasa_scoa_gps.atx")

    tides_path =
      "/Users/neil/xuku/astrodynamics/crates/astrodynamics-gnss/tests/fixtures/tides/tides_dehant_golden.json"

    antenna =
      antenna_ledger(
        antex_path,
        base_ant,
        rover_ant,
        base_ecef,
        rover_ecef,
        l1_epochs,
        l1_cell["reference_satellites"]["G"]
      )

    tide = solid_tide_bound(tides_path, base_ecef, rover_ecef)
    iono = ionosphere_ledger(base_ecef, l1l2_epochs)

    terms = [
      %{
        "term" => "receiver antenna PCO/PCV differential",
        "predicted_m" => antenna["p95_abs_dd_m"],
        "predicted_label" => "p95 absolute DD correction",
        "evidence_source" => "test/fixtures/antex/igs20_pasa_scoa_gps.atx",
        "details" => antenna
      },
      %{
        "term" => "solid earth tide differential",
        "predicted_m" => tide["conservative_bound_m"],
        "predicted_label" => "conservative differential bound",
        "evidence_source" =>
          "astrodynamics-gnss tests/fixtures/tides/tides_dehant_golden.json plus leading degree-2 gradient bound",
        "details" => tide
      },
      %{
        "term" => "residual double-difference ionosphere",
        "predicted_m" => iono["p95_l1_iono_m"],
        "predicted_label" => "p95 absolute DD L1 iono variation from phase geometry-free",
        "evidence_source" => "vendored PASA/SCOA RINEX L1/L2 observations",
        "details" => iono
      }
    ]

    predicted_sum = Enum.reduce(terms, 0.0, &(&1["predicted_m"] + &2))
    measured_gap = l1_cell["orbis_vs_oracle_gap_m"]["median"]

    %{
      "terms" => terms,
      "predicted_sum_m" => predicted_sum,
      "measured_l1_median_gap_m" => measured_gap,
      "sum_to_gap_ratio" => if(measured_gap > 0.0, do: predicted_sum / measured_gap)
    }
  end

  defp antenna_ledger(path, base_ant, rover_ant, base_ecef, rover_ecef, epochs, reference_sat) do
    receiver = parse_antex_receivers!(path, [base_ant, rover_ant])
    base_cal = Map.fetch!(receiver, base_ant)
    rover_cal = Map.fetch!(receiver, rover_ant)

    values =
      epochs
      |> Enum.flat_map(fn epoch ->
        sats =
          epoch.satellite_positions_m
          |> Map.keys()
          |> Enum.filter(fn sat ->
            sat != reference_sat and Map.has_key?(epoch.satellite_positions_m, reference_sat)
          end)

        Enum.flat_map(sats, fn sat ->
          with {:ok, sat_base} <- Map.fetch(epoch.base_satellite_positions_m, sat),
               {:ok, ref_base} <- Map.fetch(epoch.base_satellite_positions_m, reference_sat),
               {:ok, sat_rover} <- Map.fetch(epoch.rover_satellite_positions_m, sat),
               {:ok, ref_rover} <- Map.fetch(epoch.rover_satellite_positions_m, reference_sat),
               true <- elevation_deg(base_ecef, sat_base) >= @elmask_deg,
               true <- elevation_deg(base_ecef, ref_base) >= @elmask_deg do
            base_sat = antenna_correction_m(base_cal, base_ecef, sat_base)
            base_ref = antenna_correction_m(base_cal, base_ecef, ref_base)
            rover_sat = antenna_correction_m(rover_cal, rover_ecef, sat_rover)
            rover_ref = antenna_correction_m(rover_cal, rover_ecef, ref_rover)

            dd = rover_sat - base_sat - (rover_ref - base_ref)

            [
              %{
                "epoch" => NaiveDateTime.to_iso8601(epoch.epoch),
                "satellite" => sat,
                "dd_m" => dd
              }
            ]
          else
            _ -> []
          end
        end)
      end)

    abs_values = Enum.map(values, &abs(&1["dd_m"]))

    %{
      "base_antenna" => base_ant,
      "rover_antenna" => rover_ant,
      "reference_satellite" => reference_sat,
      "samples" => length(values),
      "median_abs_dd_m" => percentile(abs_values, 0.50),
      "p95_abs_dd_m" => percentile(abs_values, 0.95),
      "max_abs_dd_m" => Enum.max(abs_values, fn -> nil end),
      "pcv_grid" =>
        "GPS G01 azimuth/elevation grid with PCO in ANTEX NORTH/EAST/UP; values converted from mm to m"
    }
  end

  defp solid_tide_bound(tides_path, base_ecef, rover_ecef) do
    cases =
      if File.exists?(tides_path) do
        tides_path |> File.read!() |> Jason.decode!() |> Map.fetch!("cases")
      else
        []
      end

    case_norms =
      Enum.map(cases, fn row ->
        row["expected"]["dxtide_m"]["values"] |> list3_to_tuple() |> norm3()
      end)

    max_case_norm = Enum.max(case_norms, fn -> nil end)
    baseline = position_error(rover_ecef, base_ecef)

    conservative_site_amplitude_m = 0.45
    gradient_bound = 3.0 * conservative_site_amplitude_m * baseline / @earth_radius_m

    %{
      "method" =>
        "Full DEHANTTIDEINEL evaluation is not implemented in this repository; this bounds the differential from the leading degree-2 displacement gradient over the station separation.",
      "dehant_fixture" => tides_path,
      "dehant_case_max_norm_m" => max_case_norm,
      "baseline_length_m" => baseline,
      "site_amplitude_envelope_m" => conservative_site_amplitude_m,
      "conservative_bound_m" => gradient_bound
    }
  end

  defp ionosphere_ledger(base_ecef, epochs) do
    gamma = :math.pow(@gps_l1_hz / @gps_l2_hz, 2)
    scale = gamma - 1.0
    reference_sat = highest_average_reference(epochs, base_ecef)

    by_sat =
      epochs
      |> Enum.flat_map(fn epoch ->
        sats =
          epoch.satellite_positions_m
          |> Map.keys()
          |> Enum.filter(
            &(&1 != reference_sat and Map.has_key?(epoch.satellite_positions_m, reference_sat))
          )

        Enum.flat_map(sats, fn sat ->
          with {:ok, base_sat} <- find_dual_obs(epoch.base_observations, sat),
               {:ok, rover_sat} <- find_dual_obs(epoch.rover_observations, sat),
               {:ok, base_ref} <- find_dual_obs(epoch.base_observations, reference_sat),
               {:ok, rover_ref} <- find_dual_obs(epoch.rover_observations, reference_sat),
               true <-
                 elevation_deg(base_ecef, Map.fetch!(epoch.base_satellite_positions_m, sat)) >=
                   @elmask_deg,
               true <-
                 elevation_deg(
                   base_ecef,
                   Map.fetch!(epoch.base_satellite_positions_m, reference_sat)
                 ) >= @elmask_deg do
            phase_dd =
              gf_phase_m(rover_sat) - gf_phase_m(base_sat) -
                (gf_phase_m(rover_ref) - gf_phase_m(base_ref))

            code_dd =
              gf_code_m(rover_sat) - gf_code_m(base_sat) -
                (gf_code_m(rover_ref) - gf_code_m(base_ref))

            [%{sat: sat, phase_dd: phase_dd, code_dd: code_dd}]
          else
            _ -> []
          end
        end)
      end)
      |> Enum.group_by(& &1.sat)

    phase_l1 =
      by_sat
      |> Enum.flat_map(fn {_sat, rows} ->
        med = rows |> Enum.map(& &1.phase_dd) |> percentile(0.50)
        Enum.map(rows, &abs((&1.phase_dd - med) / scale))
      end)

    code_l1 =
      by_sat
      |> Enum.flat_map(fn {_sat, rows} ->
        rows |> Enum.map(&abs(&1.code_dd / scale))
      end)

    %{
      "reference_satellite" => reference_sat,
      "dd_arcs" => map_size(by_sat),
      "phase_samples" => length(phase_l1),
      "median_l1_iono_m" => percentile(phase_l1, 0.50),
      "p95_l1_iono_m" => percentile(phase_l1, 0.95),
      "max_l1_iono_m" => Enum.max(phase_l1, fn -> nil end),
      "code_geometry_free_p95_l1_iono_m" => percentile(code_l1, 0.95),
      "method" =>
        "Carrier L1-L2 double differences are grouped by satellite and median-demeaned to remove constant ambiguities, then divided by (f1/f2)^2 - 1 to estimate residual L1 ionosphere."
    }
  end

  defp real_gps_l1_rtk_epochs(sp3, base_obs, rover_obs, count) do
    rover_by_epoch = Map.new(Observations.epochs(rover_obs), &{&1.epoch, &1})

    base_obs
    |> Observations.epochs()
    |> Enum.take(count)
    |> Enum.flat_map(fn base_entry ->
      case Map.fetch(rover_by_epoch, base_entry.epoch) do
        {:ok, rover_entry} ->
          base_values = gps_l1_values(base_obs, base_entry.index)
          rover_values = gps_l1_values(rover_obs, rover_entry.index)
          common = common_sats(base_values, rover_values)
          epoch = naive_datetime(base_entry.epoch)
          positions = satellite_positions(sp3, epoch, common)

          base_positions =
            transmit_time_satellite_positions(sp3, epoch, base_values, common, :code_m)

          rover_positions =
            transmit_time_satellite_positions(sp3, epoch, rover_values, common, :code_m)

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

  defp gps_l1_values(obs, index) do
    {:ok, by_sat} = Observations.values(obs, index, codes: %{"G" => ["C1C", "L1C"]})

    by_sat
    |> Enum.flat_map(fn {sat, values} ->
      values_by_code = Map.new(values, &{&1.code, &1})

      with %{value: c1} when is_number(c1) <- values_by_code["C1C"],
           %{value: l1} = phase1 when is_number(l1) <- values_by_code["L1C"] do
        [
          {sat,
           %{
             satellite_id: sat,
             code_m: c1,
             phase_m: l1 * @gps_l1_wavelength_m,
             lli: phase1.lli
           }}
        ]
      else
        _ -> []
      end
    end)
    |> Map.new()
  end

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

          base_positions =
            transmit_time_satellite_positions(sp3, epoch, base_values, common, :p1_m)

          rover_positions =
            transmit_time_satellite_positions(sp3, epoch, rover_values, common, :p1_m)

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
    sats
    |> Enum.reduce(%{}, fn sat, acc ->
      case SP3.position(sp3, sat, epoch) do
        {:ok, %{x_m: x, y_m: y, z_m: z}} -> Map.put(acc, sat, {x, y, z})
        {:error, _reason} -> acc
      end
    end)
  end

  defp transmit_time_satellite_positions(sp3, receive_epoch, values, sats, code_key) do
    sats
    |> Enum.reduce(%{}, fn sat, acc ->
      with %{^code_key => code_m} when is_number(code_m) <- Map.get(values, sat),
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

  defp parse_antex_receivers!(path, targets) do
    target_set = MapSet.new(targets)

    path
    |> File.read!()
    |> String.split("\n", trim: false)
    |> parse_antex_blocks(target_set, %{}, nil, nil)
  end

  defp parse_antex_blocks([], _targets, acc, _current, _freq), do: acc

  defp parse_antex_blocks([line | rest], targets, acc, current, freq) do
    label = antex_label(line)

    cond do
      label == "TYPE / SERIAL NO" ->
        antenna = line |> String.slice(0, 20) |> String.trim()

        current =
          if MapSet.member?(targets, antenna) do
            %{name: antenna, dazi: 0.0, zenith: {0.0, 90.0, 5.0}, freqs: %{}}
          end

        parse_antex_blocks(rest, targets, acc, current, nil)

      current && label == "DAZI" ->
        parse_antex_blocks(rest, targets, acc, %{current | dazi: parse_first_float(line)}, freq)

      current && label == "ZEN1 / ZEN2 / DZEN" ->
        [z1, z2, dz | _] = parse_floats(line)
        parse_antex_blocks(rest, targets, acc, %{current | zenith: {z1, z2, dz}}, freq)

      current && label == "START OF FREQUENCY" ->
        frequency = line |> String.slice(3, 3) |> String.trim()
        parse_antex_blocks(rest, targets, acc, current, frequency)

      current && freq == "G01" && label == "NORTH / EAST / UP" ->
        [north, east, up | _] = parse_floats(line)
        cal = Map.get(current.freqs, freq, %{pco_neu_m: nil, noazi_mm: [], az_rows_mm: %{}})
        cal = %{cal | pco_neu_m: {north / 1000.0, east / 1000.0, up / 1000.0}}
        current = put_in(current.freqs[freq], cal)
        parse_antex_blocks(rest, targets, acc, current, freq)

      current && freq == "G01" && String.trim_leading(line) |> String.starts_with?("NOAZI") ->
        [_noazi | values] = String.split(line)
        cal = Map.fetch!(current.freqs, freq)
        cal = %{cal | noazi_mm: Enum.map(values, &String.to_float/1)}
        current = put_in(current.freqs[freq], cal)
        parse_antex_blocks(rest, targets, acc, current, freq)

      current && freq == "G01" && label == "" && String.trim(line) != "" ->
        [az | values] = parse_floats(line)
        cal = Map.fetch!(current.freqs, freq)
        cal = %{cal | az_rows_mm: Map.put(cal.az_rows_mm, az, values)}
        current = put_in(current.freqs[freq], cal)
        parse_antex_blocks(rest, targets, acc, current, freq)

      current && label == "END OF FREQUENCY" ->
        parse_antex_blocks(rest, targets, acc, current, nil)

      current && label == "END OF ANTENNA" ->
        acc = Map.put(acc, current.name, Map.fetch!(current.freqs, "G01"))
        parse_antex_blocks(rest, targets, acc, nil, nil)

      true ->
        parse_antex_blocks(rest, targets, acc, current, freq)
    end
  end

  defp antex_label(line) do
    line
    |> String.pad_trailing(80)
    |> String.slice(60, 20)
    |> String.trim()
  end

  defp parse_first_float(line), do: line |> parse_floats() |> hd()

  defp parse_floats(line) do
    line
    |> String.slice(0, 60)
    |> String.split()
    |> Enum.map(&String.to_float/1)
  end

  defp antenna_correction_m(cal, station, sat_pos) do
    {az_deg, el_deg} = az_el_deg(station, sat_pos)
    zen_deg = 90.0 - el_deg
    {north, east, up} = cal.pco_neu_m
    az = deg2rad(az_deg)
    el = deg2rad(el_deg)
    los_n = :math.cos(el) * :math.cos(az)
    los_e = :math.cos(el) * :math.sin(az)
    los_u = :math.sin(el)
    pco = north * los_n + east * los_e + up * los_u
    pco + pcv_m(cal, az_deg, zen_deg)
  end

  defp pcv_m(%{az_rows_mm: rows, noazi_mm: noazi, pco_neu_m: _} = cal, az_deg, zen_deg) do
    cond do
      map_size(rows) > 0 ->
        {z1, z2, dz} = {0.0, 90.0, 5.0}
        z = clamp(zen_deg, z1, z2)
        az = rem_float(az_deg, 360.0)
        a0 = :math.floor(az / cal_dazi(cal)) * cal_dazi(cal)
        a1 = if a0 + cal_dazi(cal) > 360.0, do: 0.0, else: a0 + cal_dazi(cal)
        row0 = Map.get(rows, a0) || Map.get(rows, 0.0)
        row1 = Map.get(rows, a1) || row0
        v0 = interp_zenith(row0, z, dz)
        v1 = interp_zenith(row1, z, dz)
        t = if a1 == a0, do: 0.0, else: (az - a0) / cal_dazi(cal)
        ((1.0 - t) * v0 + t * v1) / 1000.0

      noazi != [] ->
        interp_zenith(noazi, clamp(zen_deg, 0.0, 90.0), 5.0) / 1000.0

      true ->
        0.0
    end
  end

  defp cal_dazi(%{az_rows_mm: rows}) do
    rows
    |> Map.keys()
    |> Enum.sort()
    |> case do
      [a, b | _] -> b - a
      _ -> 5.0
    end
  end

  defp interp_zenith(values, zen_deg, dz) do
    idx = zen_deg / dz
    i0 = floor(idx)
    i1 = min(i0 + 1, length(values) - 1)
    t = idx - i0
    v0 = Enum.at(values, i0)
    v1 = Enum.at(values, i1)
    (1.0 - t) * v0 + t * v1
  end

  defp highest_average_reference(epochs, base) do
    common =
      epochs
      |> Enum.map(&(&1.satellite_positions_m |> Map.keys() |> MapSet.new()))
      |> Enum.reduce(fn set, acc -> MapSet.intersection(acc, set) end)
      |> MapSet.to_list()

    common
    |> Enum.map(fn sat ->
      score =
        epochs
        |> Enum.map(fn epoch ->
          elevation_sin(base, Map.fetch!(epoch.satellite_positions_m, sat))
        end)
        |> average()

      {sat, score}
    end)
    |> Enum.sort_by(fn {sat, score} -> {-score, sat} end)
    |> hd()
    |> elem(0)
  end

  defp find_dual_obs(observations, sat) do
    case Enum.find(observations, &(&1.satellite_id == sat)) do
      nil -> :error
      obs -> {:ok, obs}
    end
  end

  defp gf_phase_m(obs),
    do: obs.phi1_cyc * @gps_l1_wavelength_m - obs.phi2_cyc * @gps_l2_wavelength_m

  defp gf_code_m(obs), do: obs.p2_m - obs.p1_m

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

    q_counts =
      rows
      |> Enum.group_by(& &1["q"])
      |> Map.new(fn {q, values} -> {to_string(q), length(values)} end)

    %{
      "label" => oracle["reference"]["label"],
      "epochs" => oracle["reference"]["epochs"],
      "fixed_epochs" => oracle["reference"]["fixed_epochs"],
      "fix_rate" => oracle["reference"]["fix_rate"],
      "first_fixed_index" => oracle["reference"]["first_fixed_index"],
      "final_status" => oracle["reference"]["final_status"],
      "q_counts" => q_counts,
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

  defp capability_order(ledger, l1_cell) do
    terms =
      ledger["terms"]
      |> Enum.sort_by(&(-&1["predicted_m"]))
      |> Enum.map(fn term ->
        %{
          "capability" => capability_name(term["term"]),
          "term" => term["term"],
          "predicted_m" => term["predicted_m"]
        }
      end)

    [
      %{
        "capability" => "measurement-model sanity before promotion",
        "reason" =>
          "The measured L1 median gap is #{fmt_m(l1_cell["orbis_vs_oracle_gap_m"]["median"])}; the summed ledger terms are #{fmt_m(ledger["predicted_sum_m"])}."
      }
      | terms
    ]
  end

  defp capability_name("receiver antenna PCO/PCV differential"), do: "C-PCO/PCV application"
  defp capability_name("solid earth tide differential"), do: "C-solid-tides station displacement"
  defp capability_name("residual double-difference ionosphere"), do: "D-iono handling"

  defp report_markdown(result) do
    l1 = result["cells"]["l1_static_filter"]
    batch = result["cells"]["l1l2_static_batch_full"]
    prefix = result["cells"]["l1l2_static_batch_prefix"]
    ledger = result["ledger"]

    """
    # C+D Phase 2 measurement pass, June 2026

    Generated by `mix run test/fixtures/rtk/generators/cd_measurement_2026_06.exs`.
    Per-epoch JSON was emitted to `#{result["results_path"]}`.
    Source commit at generation: `#{result["source_commit"]}`.

    This is the Phase 2 measurement pass from `cd-campaign-spec.md`. The RTK solver and library code were not changed.

    ## Inputs and epoch construction

    - Rover observations: `#{result["inputs"]["rover_obs"]}`.
    - Base observations: `#{result["inputs"]["base_obs"]}`.
    - Precise product: `#{result["inputs"]["sp3"]}`; the companion clock fixture remains the RTKLIB oracle input but the shipped Orbis RTK epoch builder uses SP3 positions only.
    - Oracles: `#{result["inputs"]["l1_oracle"]}` and `#{result["inputs"]["l1l2_oracle"]}`.
    - Truth: EPN C2385 ITRF2020 propagated to `#{result["truth"]["source"]["observation_midpoint_gpst"]}`; base and rover ARP equal marker coordinates for this pair.
    - Satellite positions: per-receiver transmit-time SP3 positions from each receiver's code pseudorange, matching the established real-arc harness.
    - Constellation: GPS only, matching the IGS final SP3/CLK product and RTKLIB `pos1-navsys = 1`.

    ## Options

    | Option | Value | Reason |
    |---|---:|---|
    #{option_rows(result["options"])}

    ## Distributions vs propagated truth

    | Cell | Epochs | Fixed | Median m | p95 m | Final m | RTKLIB mean m | RTKLIB final m | Gap median/final m |
    |---|---:|---:|---:|---:|---:|---:|---:|---:|
    #{distribution_row("L1 static filter", l1["summary"], l1["oracle"], l1["orbis_vs_oracle_gap_m"])}
    #{distribution_row("L1/L2 batch prefixes", prefix["summary"], prefix["oracle"], prefix["orbis_vs_oracle_gap_m"])}
    #{batch_distribution_row("L1/L2 full batch", batch)}

    The L1/L2 prefix row is a growing-window batch diagnostic, not a sequential filter mode. The full-batch row is the actual second cell requested by the brief; it has one final static estimate rather than per-epoch carried-state estimates.
    Prefix diagnostics use a #{prefix["prefix_step"]}-epoch stride and always include the full #{result["epoch_build"]["l1l2_epochs"]}-epoch arc.

    #{l1_filter_status_note(l1)}

    ## Refusal-invariant verdict

    | Cell | Verdict | Fixed n | Float n | Fixed median m | Float median m | Fixed p95 m | Float p95 m | Floor m |
    |---|---|---:|---:|---:|---:|---:|---:|---:|
    #{invariant_row("L1 static filter", l1["invariant"])}
    #{invariant_row("L1/L2 batch prefixes", prefix["invariant"])}

    The credibility floor is `2x` the RTKLIB oracle mean truth error for the same arc, per Amendment 1 as restated in the Phase 2 brief.

    ## Term ledger

    | Term | Predicted magnitude | Evidence source |
    |---|---:|---|
    #{ledger_rows(ledger["terms"])}

    Summed predicted terms: #{fmt_m(ledger["predicted_sum_m"])}. Measured L1 median Orbis-vs-oracle gap: #{fmt_m(ledger["measured_l1_median_gap_m"])}. Ratio: #{fmt_ratio(ledger["sum_to_gap_ratio"])}.

    Solid earth tide note: a full DEHANTTIDEINEL evaluation is not implemented in this repo. The ledger therefore uses a conservative differential bound from the leading degree-2 gradient over the 21.836 km baseline, backed by the vendored DEHANTTIDEINEL oracle-case provenance.

    ## Capability ordering implied

    | Order | Capability | Basis |
    |---:|---|---|
    #{capability_rows(result["capability_order"])}
    """
  end

  defp option_rows(rows) do
    Enum.map_join(rows, "\n", fn row ->
      "| `#{row["option"]}` | `#{row["value"]}` | #{row["reason"]} |"
    end)
  end

  defp distribution_row(label, summary, oracle, gap) do
    "| #{label} | #{summary["n"]} | #{summary["fixed_n"]} | #{fmt(summary["median_error_m"])} | #{fmt(summary["p95_error_m"])} | #{fmt(summary["final_error_m"])} | #{fmt(oracle["mean_error_m"])} | #{fmt(oracle["final_error_m"])} | #{fmt(gap["median"])}/#{fmt(gap["final"])} |"
  end

  defp batch_distribution_row(label, %{"status" => "solved"} = batch) do
    oracle = batch["oracle"]
    gap = batch["orbis_vs_oracle_gap_m"]

    "| #{label} | 1 | #{if(batch["integer_status"] == "fixed", do: 1, else: 0)} | #{fmt(batch["error_m"])} | #{fmt(batch["error_m"])} | #{fmt(batch["error_m"])} | #{fmt(oracle["mean_error_m"])} | #{fmt(oracle["final_error_m"])} | #{fmt(gap["mean"])}/#{fmt(gap["final"])} |"
  end

  defp batch_distribution_row(label, batch) do
    "| #{label} | 0 | 0 |  |  |  | #{fmt(batch["oracle"]["mean_error_m"])} | #{fmt(batch["oracle"]["final_error_m"])} | error: `#{batch["error_reason"]}` |"
  end

  defp l1_filter_status_note(%{"metadata" => %{"continuous_status" => "solved"}} = l1) do
    metadata = l1["metadata"]

    "L1 continuous filter status: `solved` over #{metadata["solved_epoch_count"]} epochs."
  end

  defp l1_filter_status_note(%{"metadata" => metadata}) do
    "L1 continuous filter status: `error` (`#{metadata["continuous_error_reason"]}`). The L1 distribution above uses reset sub-arcs with identical solver options; #{metadata["solved_epoch_count"]} epochs solved, #{metadata["dropped_epoch_count"]} epochs were dropped, across #{metadata["segment_count"]} solved sub-arcs."
  end

  defp invariant_row(label, inv) do
    "| #{label} | #{inv["verdict"]} | #{inv["fixed_n"]} | #{inv["float_n"]} | #{fmt(inv["fixed_median_error_m"])} | #{fmt(inv["float_median_error_m"])} | #{fmt(inv["fixed_p95_error_m"])} | #{fmt(inv["float_p95_error_m"])} | #{fmt(inv["credibility_floor_m"])} |"
  end

  defp ledger_rows(terms) do
    Enum.map_join(terms, "\n", fn term ->
      "| #{term["term"]} | #{fmt_m(term["predicted_m"])} (#{term["predicted_label"]}) | #{term["evidence_source"]} |"
    end)
  end

  defp capability_rows(rows) do
    rows
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {row, idx} ->
      basis = row["reason"] || "#{row["term"]}: #{fmt_m(row["predicted_m"])}"
      "| #{idx} | #{row["capability"]} | #{basis} |"
    end)
  end

  defp option_notes_json do
    Enum.map(@option_notes, fn {option, value, reason} ->
      %{"option" => option, "value" => value, "reason" => reason}
    end)
  end

  defp git_commit(repo) do
    case System.cmd("git", ["rev-parse", "HEAD"], cd: repo, stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      {_message, _status} -> "unknown"
    end
  end

  defp residual_satellite_count(epoch) do
    epoch.residuals_m
    |> Enum.flat_map(&[&1.satellite_id, &1.reference_satellite_id])
    |> Enum.uniq()
    |> length()
  end

  defp primary_reference_satellite(metadata) do
    Map.get(metadata, :reference_satellite_id) ||
      metadata
      |> Map.get(:reference_satellites, %{})
      |> Map.get("G")
  end

  defp stringify_map(nil), do: %{}
  defp stringify_map(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp ecef_solution_json(%{x_m: x, y_m: y, z_m: z}), do: %{"x" => x, "y" => y, "z" => z}

  defp ecef_map_to_tuple(%{"x" => x, "y" => y, "z" => z}), do: {x, y, z}
  defp list3_to_tuple([x, y, z]), do: {x, y, z}
  defp enu_map_to_tuple(%{"east" => east, "north" => north, "up" => up}), do: {east, north, up}
  defp tuple3_json({x, y, z}), do: %{"x" => x, "y" => y, "z" => z}

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
      (x - truth_x) * (x - truth_x) +
        (y - truth_y) * (y - truth_y) +
        (z - truth_z) * (z - truth_z)
    )
  end

  defp sub3({ax, ay, az}, {bx, by, bz}), do: {ax - bx, ay - by, az - bz}
  defp scale3({x, y, z}, s), do: {x * s, y * s, z * s}
  defp dot3({ax, ay, az}, {bx, by, bz}), do: ax * bx + ay * by + az * bz
  defp norm3({x, y, z}), do: :math.sqrt(x * x + y * y + z * z)
  defp unit3(v), do: scale3(v, 1.0 / norm3(v))

  defp average(values), do: Enum.sum(values) / length(values)

  defp elevation_sin(station, sat_pos), do: dot3(unit3(sub3(sat_pos, station)), unit3(station))

  defp elevation_deg(station, sat_pos),
    do: :math.asin(elevation_sin(station, sat_pos)) |> rad2deg()

  defp az_el_deg(station, sat_pos) do
    {east, north, up} = enu_basis(station)
    los = unit3(sub3(sat_pos, station))
    e = dot3(los, east)
    n = dot3(los, north)
    u = dot3(los, up)
    az = :math.atan2(e, n) |> rad2deg() |> rem_float(360.0)
    el = :math.asin(u) |> rad2deg()
    {az, el}
  end

  defp enu_basis({x, y, z}) do
    lon = :math.atan2(y, x)
    hyp = :math.sqrt(x * x + y * y)
    lat = :math.atan2(z, hyp)

    east = {-:math.sin(lon), :math.cos(lon), 0.0}
    north = {-:math.sin(lat) * :math.cos(lon), -:math.sin(lat) * :math.sin(lon), :math.cos(lat)}
    up = {:math.cos(lat) * :math.cos(lon), :math.cos(lat) * :math.sin(lon), :math.sin(lat)}
    {east, north, up}
  end

  defp deg2rad(deg), do: deg * :math.pi() / 180.0
  defp rad2deg(rad), do: rad * 180.0 / :math.pi()

  defp rem_float(value, modulo) do
    result = value - :math.floor(value / modulo) * modulo
    if result < 0.0, do: result + modulo, else: result
  end

  defp clamp(value, min_value, max_value), do: min(max(value, min_value), max_value)

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
end

CDMeasurement202606.main(System.argv())
