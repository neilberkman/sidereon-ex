defmodule CDPhase3aTruthGate202606 do
  @moduledoc false

  # Phase 3a truth gate: does applying receiver antenna corrections (PCO/PCV
  # from the vendored IGS20 ANTEX, via `:receiver_antenna_corrections`) move
  # the PASA/SCOA L1 batch solutions toward truth, and does the fixed solve
  # fix more correctly with corrections than without?
  #
  # Four cells, all on the full vendored arc, stock solver (no library code
  # is modified):
  #   (a) batch float   without corrections
  #   (b) batch float   with    corrections
  #   (c) batch fixed   without corrections
  #   (d) batch fixed   with    corrections
  #
  # Usage (from the repo root):
  #   ORBIS_BUILD=1 mix run test/fixtures/rtk/generators/cd_phase3a_truth_gate_2026_06.exs

  alias Orbis.GNSS.Antex
  alias Orbis.GNSS.RINEX.Observations
  alias Orbis.GNSS.RTK
  alias Orbis.GNSS.SP3

  @c_m_s 299_792_458.0
  @gps_l1_hz 1_575_420_000.0
  @gps_l1_wavelength_m @c_m_s / @gps_l1_hz
  @elmask_deg 15.0
  @frequency "G01"
  @default_results "/tmp/cd-phase3a-truth-gate-results.json"

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

    corrections =
      receiver_antenna_corrections(
        Path.join(repo, inputs["antex"]),
        truth["base_station"]["antenna"],
        truth["rover_station"]["antenna"]
      )

    float_opts = float_opts(initial_baseline)
    fixed_opts = fixed_opts(initial_baseline)

    cells = [
      {"a", "batch float, no corrections", :float, float_opts},
      {"b", "batch float, with corrections", :float,
       float_opts ++ [receiver_antenna_corrections: corrections]},
      {"c", "batch fixed, no corrections", :fixed, fixed_opts},
      {"d", "batch fixed, with corrections", :fixed,
       fixed_opts ++ [receiver_antenna_corrections: corrections]}
    ]

    results =
      Enum.map(cells, fn {id, label, kind, cell_opts} ->
        IO.puts("running cell (#{id}): #{label}")
        run_cell(id, label, kind, base_ecef, epochs, cell_opts, truth_baseline)
      end)

    payload = %{
      "oracle" => @l1_oracle,
      "oracle_mean_truth_error_m" => oracle["reference"]["mean_truth_error_m"],
      "oracle_final_truth_error_m" => oracle["reference"]["final_truth_error_m"],
      "credibility_floor_m" => 2.0 * oracle["reference"]["mean_truth_error_m"],
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
      IO.puts(
        "(#{cell["id"]}) #{cell["label"]}: error #{format_m(cell["error_m"])}" <>
          fixed_suffix(cell)
      )
    end)
  end

  defp run_cell(id, label, :float, base_ecef, epochs, opts, truth_baseline) do
    {:ok, sol} = RTK.solve_float_baseline_epochs(base_ecef, epochs, opts)

    %{
      "id" => id,
      "label" => label,
      "kind" => "float",
      "error_m" => position_error(sol.baseline_m, truth_baseline),
      "baseline_m" => ecef_to_json(sol.baseline_m),
      "used_sats" => length(sol.used_sats)
    }
  end

  defp run_cell(id, label, :fixed, base_ecef, epochs, opts, truth_baseline) do
    {:ok, sol} = RTK.solve_fixed_baseline_epochs(base_ecef, epochs, opts)

    %{
      "id" => id,
      "label" => label,
      "kind" => "fixed",
      "error_m" => position_error(sol.baseline_m, truth_baseline),
      "baseline_m" => ecef_to_json(sol.baseline_m),
      "used_sats" => length(sol.used_sats),
      "integer_status" => to_string(sol.metadata.integer_status),
      "integer_ratio" => json_ratio(sol.metadata.integer_ratio),
      "fixed_ambiguity_count" => map_size(sol.fixed_ambiguities_cycles),
      "fixed_ambiguities_cycles" => sol.fixed_ambiguities_cycles,
      "float_error_m" => position_error(sol.float_solution.baseline_m, truth_baseline)
    }
  end

  defp receiver_antenna_corrections(antex_path, base_name, rover_name) do
    antex = Antex.load!(antex_path)

    base = Antex.antenna(antex, base_name) || raise "ANTEX missing #{inspect(base_name)}"
    rover = Antex.antenna(antex, rover_name) || raise "ANTEX missing #{inspect(rover_name)}"

    %{
      base: %{antenna: base, frequency: @frequency},
      rover: %{antenna: rover, frequency: @frequency}
    }
  end

  defp float_opts(initial_baseline) do
    [
      initial_baseline_m: initial_baseline,
      max_iterations: 10,
      on_cycle_slip: :split_arc,
      elevation_mask_deg: @elmask_deg,
      stochastic_model: :rtklib,
      code_sigma_m: 0.3,
      phase_sigma_m: 0.003
    ]
  end

  defp fixed_opts(initial_baseline) do
    float_opts(initial_baseline) ++
      [
        ambiguity_wavelength_m: @gps_l1_wavelength_m,
        integer_ratio_threshold: 3.0,
        integer_candidate_limit: 200_000
      ]
  end

  defp fixed_suffix(%{"kind" => "fixed"} = cell) do
    " (#{cell["integer_status"]}, ratio #{format_ratio(cell["integer_ratio"])}, " <>
      "#{cell["fixed_ambiguity_count"]} ambiguities, float #{format_m(cell["float_error_m"])})"
  end

  defp fixed_suffix(_cell), do: ""

  defp json_ratio(:infinity), do: "infinity"
  defp json_ratio(ratio), do: ratio

  defp format_m(value), do: :erlang.float_to_binary(value * 1.0, decimals: 4) <> "m"
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

CDPhase3aTruthGate202606.main(System.argv())
