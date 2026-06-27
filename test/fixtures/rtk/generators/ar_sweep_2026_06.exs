defmodule ARSweep do
  @moduledoc false

  # AR commitment discipline sweep (ar-commitment-spec.md, mechanism 1):
  # the sequential fix-and-hold filter commits integers at epoch 18 while the
  # baseline posterior is still above the L1 half-wavelength boundary, locking
  # wrong values. This sweeps the `:ar_arming_sigma_m` convergence arming gate
  # across thresholds, under two hold regimes (the shipped 1e-4 default, whose
  # continuous arc still hits the epoch-124 singularity and reports on reset
  # sub-arcs, and the interim 1e-3 soft hold, whose continuous arc solves and
  # isolates the arming effect), on the vendored PASA/SCOA L1 arc with the
  # Elixir reference kernel. See ar-commitment-measurement-2026-06.md.
  #
  # Usage (from the repo root):
  #   ORBIS_BUILD=1 mix run test/fixtures/rtk/generators/ar_sweep_2026_06.exs

  alias Orbis.GNSS.RINEX.Observations
  alias Orbis.GNSS.RTK
  alias Orbis.GNSS.SP3

  @c_m_s 299_792_458.0
  @gps_l1_hz 1_575_420_000.0
  @gps_l1_wavelength_m @c_m_s / @gps_l1_hz
  @elmask_deg 15.0
  @frequency "G01"
  @default_results "/tmp/ar-sweep-results.json"

  @l1_oracle "pasa_scoa_2026_120_l1_static_fixhold_rtklib_oracle.json"

  def main(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args, strict: [results: :string], aliases: [r: :results])

    if invalid != [] do
      raise ArgumentError, "invalid arguments: #{inspect(invalid)}"
    end

    generator_dir = __DIR__
    rtk_dir = Path.expand("..", generator_dir)
    repo = Path.expand("../../../..", generator_dir)

    results_path = Keyword.get(opts, :results, @default_results)

    oracle = load_json!(Path.join(rtk_dir, @l1_oracle))
    truth = oracle["truth"]
    inputs = oracle["inputs"]

    base_ecef = ecef_map_to_tuple(truth["base_station"]["marker_ecef_m"])
    rover_truth = ecef_map_to_tuple(truth["rover_station"]["marker_ecef_m"])
    truth_baseline = sub3(rover_truth, base_ecef)

    sp3 = SP3.load!(Path.join(repo, inputs["sp3"]))
    base_obs = Observations.load!(Path.join(repo, inputs["base_obs"]))
    rover_obs = Observations.load!(Path.join(repo, inputs["rover_obs"]))

    initial_baseline = sub3(Observations.approx_position(rover_obs), base_ecef)

    IO.puts("building GPS L1 epochs")
    epochs = real_gps_l1_rtk_epochs(sp3, base_obs, rover_obs, oracle["reference"]["epochs"])
    IO.puts("#{length(epochs)} epochs")

    base_opts = filter_opts(initial_baseline)

    thresholds = [nil, 0.10, 0.08, 0.06, 0.05, 0.04, 0.03, 0.02]

    # Two hold regimes: the shipped default (continuous arc errors at epoch 124,
    # so the harness reports on reset sub-arcs) and the interim soft hold
    # (continuous arc solves, isolating the arming effect).
    holds = [{"hold1e-4", 1.0e-4}, {"hold1e-3", 1.0e-3}]

    cells =
      for {hold_id, hold_sigma} <- holds, t <- thresholds do
        hold_opts = base_opts ++ [hold_sigma_m: hold_sigma]
        arm_id = if t == nil, do: "none", else: "arm_#{:erlang.float_to_binary(t, decimals: 3)}"
        label = if t == nil, do: "no arming", else: "arm <= #{t} m"
        opts = if t == nil, do: hold_opts, else: hold_opts ++ [ar_arming_sigma_m: t]
        {"#{hold_id}/#{arm_id}", "#{hold_id}, #{label}", opts}
      end

    results =
      Enum.map(cells, fn {id, label, cell_opts} ->
        IO.puts("running cell (#{id}): #{label}")
        run_cell(id, label, base_ecef, epochs, cell_opts, truth_baseline)
      end)

    floor_m = 2.0 * oracle["reference"]["mean_truth_error_m"]

    payload = %{
      "oracle" => @l1_oracle,
      "oracle_mean_truth_error_m" => oracle["reference"]["mean_truth_error_m"],
      "oracle_final_truth_error_m" => oracle["reference"]["final_truth_error_m"],
      "credibility_floor_m" => floor_m,
      "min_fixed_n" => 20,
      "epochs" => length(epochs),
      "antennas" => %{
        "base" => truth["base_station"]["antenna"],
        "rover" => truth["rover_station"]["antenna"],
        "frequency" => @frequency
      },
      "cells" => results
    }

    File.write!(results_path, Jason.encode!(payload, pretty: true))
    IO.puts("results written to #{results_path}")

    Enum.each(results, fn cell ->
      summary = cell["summary"]

      verdict =
        cond do
          summary["fixed_n"] < 20 -> "FAIL-by-n (fixed_n #{summary["fixed_n"]} < 20)"
          summary["fixed_median_error_m"] > floor_m -> "FAIL-by-floor"
          true -> "PASS"
        end

      IO.puts(
        "(#{cell["id"]}) #{cell["label"]}: fixed #{summary["fixed_n"]}/#{summary["n"]}, " <>
          "fixed median #{format_m(summary["fixed_median_error_m"])}, " <>
          "float median #{format_m(summary["float_median_error_m"])}, " <>
          "final #{format_m(summary["final_error_m"])}, invariant #{verdict}"
      )
    end)
  end

  defp run_cell(id, label, base_ecef, epochs, opts, truth_baseline) do
    case RTK.solve_filter_baseline_epochs(base_ecef, epochs, opts) do
      {:ok, sol} ->
        rows = filter_solution_rows(sol.epochs, truth_baseline)

        %{
          "id" => id,
          "label" => label,
          "filter_kernel" => Atom.to_string(sol.metadata.filter_kernel),
          "continuous_status" => "solved",
          "first_fixed_index" => sol.metadata.first_fixed_index,
          "fixed_epoch_count" => sol.metadata.fixed_epoch_count,
          "final_error_m" => position_error(sol.baseline_m, truth_baseline),
          "dropped_epoch_count" => 0,
          "segment_count" => 1,
          "summary" => summarize_rows(rows),
          "rows" => rows
        }

      {:error, reason} ->
        # Same reset-sub-arc reporting as the Phase 2 harness: the continuous
        # arc errors (epoch-124 hold-weight cancellation), so the distribution
        # comes from solved sub-arcs with identical options.
        {rows, segments, dropped} =
          solve_filter_segments(base_ecef, truth_baseline, epochs, opts)

        rows = Enum.sort_by(rows, & &1["index"])
        summary = summarize_rows(rows)

        %{
          "id" => id,
          "label" => label,
          "filter_kernel" => "elixir",
          "continuous_status" => "error",
          "continuous_error_reason" => inspect(reason),
          "first_fixed_index" => first_fixed_index(rows),
          "fixed_epoch_count" => summary["fixed_n"],
          "final_error_m" => summary["final_error_m"],
          "dropped_epoch_count" => length(dropped),
          "segment_count" => length(segments),
          "dropped_epochs" => dropped,
          "summary" => summary,
          "rows" => rows
        }
    end
  end

  defp filter_solution_rows(solution_epochs, truth_baseline, offset \\ 0) do
    Enum.map(solution_epochs, fn epoch ->
      %{
        "index" => offset + epoch.index,
        "integer_status" => Atom.to_string(epoch.integer_status),
        "error_m" => position_error(epoch.baseline_m, truth_baseline)
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

  defp split_or_drop_filter_segment(_base_ecef, _truth_baseline, [_epoch], _opts, offset, reason) do
    {[], [], [%{"index" => offset, "reason" => inspect(reason)}]}
  end

  defp split_or_drop_filter_segment(base_ecef, truth_baseline, epochs, opts, offset, reason) do
    len = length(epochs)

    case singular_epoch_index(reason, len) do
      {:drop, local_index} ->
        left = Enum.take(epochs, local_index)
        right = Enum.drop(epochs, local_index + 1)

        {left_rows, left_segments, left_dropped} =
          solve_filter_segments(base_ecef, truth_baseline, left, opts, offset)

        {right_rows, right_segments, right_dropped} =
          solve_filter_segments(base_ecef, truth_baseline, right, opts, offset + local_index + 1)

        {
          left_rows ++ right_rows,
          left_segments ++ right_segments,
          [
            %{"index" => offset + local_index, "reason" => inspect(reason)}
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

  defp percentile([], _p), do: nil

  defp percentile(values, p) do
    sorted = Enum.sort(values)
    idx = floor((length(sorted) - 1) * p)
    Enum.at(sorted, idx)
  end

  defp filter_opts(initial_baseline) do
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
      integer_candidate_limit: 200_000,
      filter_kernel: :elixir
    ]
  end

  defp format_m(nil), do: "n/a"

  defp format_m(value) when is_number(value),
    do: :erlang.float_to_binary(value * 1.0, decimals: 4) <> "m"

  defp format_ratio(nil), do: "n/a"
  defp format_ratio("infinity"), do: "infinity"
  defp format_ratio(value), do: :erlang.float_to_binary(value * 1.0, decimals: 2)

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

  defp naive_datetime({{year, month, day}, {hour, minute, second}}) do
    whole_second = trunc(second)
    microsecond = round((second - whole_second) * 1_000_000)

    NaiveDateTime.new!(
      Date.new!(year, month, day),
      Time.new!(hour, minute, whole_second, {microsecond, 6})
    )
  end

  defp load_json!(path), do: path |> File.read!() |> Jason.decode!()

  defp ecef_map_to_tuple(%{"x" => x, "y" => y, "z" => z}), do: {x, y, z}

  defp ecef_to_json(%{x_m: x, y_m: y, z_m: z}), do: %{"x" => x, "y" => y, "z" => z}

  defp position_error(%{x_m: x, y_m: y, z_m: z}, truth), do: position_error({x, y, z}, truth)

  defp position_error({x, y, z}, {truth_x, truth_y, truth_z}) do
    :math.sqrt(
      (x - truth_x) * (x - truth_x) +
        (y - truth_y) * (y - truth_y) +
        (z - truth_z) * (z - truth_z)
    )
  end

  defp sub3({ax, ay, az}, {bx, by, bz}), do: {ax - bx, ay - by, az - bz}
end

ARSweep.main(System.argv())
