defmodule MultiGNSSSeqMeasurement do
  @moduledoc false

  # Multi-GNSS sequential filter measurement (multignss-seq-spec.md):
  # the sequential fix-and-hold filter on the Wettzell WTZR/WTZZ co-located
  # static pair with GPS + Galileo + BeiDou fixed and GLONASS float-only
  # (:float_only_systems), the multi-system SD gauge constraint (always on for a
  # 4-system arc), and the additive :ar_arming_sigma_m convergence gate swept
  # across a pre-registered threshold list (nil headline). Runs with the Elixir
  # reference kernel. Emits the Amendment 1 fixed-population verdict against the
  # multi-GNSS RTKLIB oracle. See multignss-seq-measurement-2026-06.md.
  #
  # Usage (from the repo root):
  #   ORBIS_BUILD=1 mix run \
  #     test/fixtures/rtk/generators/multignss_seq_measurement_2026_06.exs

  alias Orbis.GNSS.RINEX.Observations
  alias Orbis.GNSS.RTK
  alias Orbis.GNSS.SP3

  @c_m_s 299_792_458.0
  @gps_l1_hz 1_575_420_000.0
  @gps_l1_wavelength_m @c_m_s / @gps_l1_hz
  @bds_b1i_hz 1_561_098_000.0
  @glonass_g1_hz 1_602_000_000.0
  @glonass_g1_step_hz 562_500.0

  @multignss_l1_codes %{
    "G" => [{"C1C", "L1C"}],
    "R" => [{"C1C", "L1C"}],
    "E" => [{"C1C", "L1C"}, {"C1X", "L1X"}],
    "C" => [{"C2I", "L2I"}]
  }

  @wtzr_marker {4_075_580.3111, 931_854.0543, 4_801_568.2808}
  @wtzz_marker {4_075_579.1913, 931_853.3696, 4_801_569.1897}

  @oracle "wtzr_wtzz_multignss_static_rtklib_oracle.json"
  @default_results "/tmp/multignss-seq-measurement-2026-06-results.json"

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

    oracle = load_json!(Path.join(rtk_dir, @oracle))
    reference = oracle["reference"]

    sp3 =
      SP3.load!(Path.join(repo, "test/fixtures/sp3/COD0MGXFIN_20201770000_01D_05M_ORB.SP3"))

    base_obs =
      Observations.load!(
        Path.join(repo, "test/fixtures/obs/WTZR00DEU_R_20201770000_01D_30S_MO_120epoch.rnx")
      )

    rover_obs =
      Observations.load!(
        Path.join(repo, "test/fixtures/obs/WTZZ00DEU_R_20201770000_01D_30S_MO_120epoch.rnx")
      )

    base_arp = arp_position(@wtzr_marker, antenna_height_m(base_obs))
    rover_arp = arp_position(@wtzz_marker, antenna_height_m(rover_obs))
    truth_baseline = sub3(rover_arp, base_arp)
    glonass_slots = Observations.glonass_slots(base_obs)

    IO.puts("building multi-GNSS L1 epochs")

    epochs =
      real_multignss_l1_rtk_epochs(
        sp3,
        base_obs,
        rover_obs,
        reference["epochs"],
        ["G", "R", "E", "C"]
      )

    IO.puts("#{length(epochs)} epochs")

    wavelength_map = multignss_wavelength_map(epochs, glonass_slots)
    base_opts = filter_opts(wavelength_map)

    thresholds = [nil, 0.10, 0.05, 0.047]

    cells =
      Enum.map(thresholds, fn t ->
        arm_id = if t == nil, do: "none", else: "arm_#{:erlang.float_to_binary(t, decimals: 3)}"
        label = if t == nil, do: "no arming (default)", else: "arm <= #{t} m"
        cell_opts = if t == nil, do: base_opts, else: base_opts ++ [ar_arming_sigma_m: t]
        {arm_id, label, cell_opts}
      end)

    floor_m = 2.0 * reference["mean_truth_error_m"]

    results =
      Enum.map(cells, fn {id, label, cell_opts} ->
        IO.puts("running cell (#{id}): #{label}")
        run_cell(id, label, base_arp, epochs, cell_opts, truth_baseline)
      end)

    {oracle_min_sats, oracle_max_sats} =
      oracle["per_epoch"] |> Enum.map(& &1["satellites"]) |> Enum.min_max()

    payload = %{
      "oracle" => @oracle,
      "oracle_mean_truth_error_m" => reference["mean_truth_error_m"],
      "oracle_final_truth_error_m" => reference["final_truth_error_m"],
      "oracle_fixed_epochs" => reference["fixed_epochs"],
      "oracle_first_fixed_index" => reference["first_fixed_index"],
      "oracle_sat_range" => [oracle_min_sats, oracle_max_sats],
      "credibility_floor_m" => floor_m,
      "min_fixed_n" => 20,
      "epochs" => length(epochs),
      "float_only_systems" => ["R"],
      "filter_kernel" => "elixir",
      "cells" => results
    }

    File.write!(results_path, Jason.encode!(payload, pretty: true))
    IO.puts("results written to #{results_path}")

    IO.puts(
      "oracle median #{format_m(reference["mean_truth_error_m"])}, floor #{format_m(floor_m)}"
    )

    Enum.each(results, fn cell ->
      summary = cell["summary"]
      verdict = verdict(summary, floor_m)

      IO.puts(
        "(#{cell["id"]}) #{cell["label"]}: continuous #{cell["continuous_status"]}, " <>
          "first fix #{inspect(cell["first_fixed_index"])}, " <>
          "fixed #{summary["fixed_n"]}/#{summary["n"]}, " <>
          "fixed median #{format_m(summary["fixed_median_error_m"])}, " <>
          "final #{format_m(summary["final_error_m"])}, " <>
          "per-system fixed #{inspect(cell["per_system_fixed"])}, " <>
          "glonass_fixed #{cell["glonass_fixed"]}, VERDICT #{verdict}"
      )
    end)
  end

  defp verdict(summary, floor_m) do
    cond do
      summary["fixed_n"] < 20 -> "UNDERPOWERED (fixed_n #{summary["fixed_n"]} < 20)"
      summary["fixed_median_error_m"] > floor_m -> "FAIL-by-floor"
      true -> "PASS"
    end
  end

  defp run_cell(id, label, base_ecef, epochs, opts, truth_baseline) do
    case RTK.solve_filter_baseline_epochs(base_ecef, epochs, opts) do
      {:ok, sol} ->
        rows = filter_solution_rows(sol.epochs, truth_baseline)

        glonass_fixed =
          Enum.any?(sol.epochs, fn e ->
            Enum.any?(e.fixed_ambiguities, &String.starts_with?(&1, "R"))
          end) or
            Enum.any?(Map.keys(sol.fixed_ambiguities_cycles), &String.starts_with?(&1, "R"))

        %{
          "id" => id,
          "label" => label,
          "filter_kernel" => Atom.to_string(sol.metadata.filter_kernel),
          "continuous_status" => "solved",
          "segment_count" => 1,
          "dropped_epoch_count" => 0,
          "first_fixed_index" => sol.metadata.first_fixed_index,
          "fixed_epoch_count" => sol.metadata.fixed_epoch_count,
          "reference_satellites" => sol.metadata.reference_satellites,
          "float_only_systems" => sol.metadata.float_only_systems,
          "glonass_fixed" => glonass_fixed,
          "per_system_fixed" => per_system_fixed(sol),
          "final_error_m" => position_error(sol.baseline_m, truth_baseline),
          "summary" => summarize_rows(rows),
          "rows" => rows
        }

      {:error, reason} ->
        %{
          "id" => id,
          "label" => label,
          "filter_kernel" => "elixir",
          "continuous_status" => "error",
          "continuous_error_reason" => inspect(reason),
          "first_fixed_index" => nil,
          "fixed_epoch_count" => 0,
          "glonass_fixed" => nil,
          "per_system_fixed" => %{},
          "final_error_m" => nil,
          "summary" => summarize_rows([]),
          "rows" => []
        }
    end
  end

  defp per_system_fixed(sol) do
    sol.fixed_ambiguities_cycles
    |> Map.keys()
    |> Enum.group_by(&String.first/1)
    |> Map.new(fn {sys, ids} -> {sys, length(ids)} end)
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

  defp summarize_rows(rows) do
    errors = Enum.map(rows, & &1["error_m"])
    fixed = Enum.filter(rows, &(&1["integer_status"] == "fixed"))
    float = Enum.reject(rows, &(&1["integer_status"] == "fixed"))

    %{
      "n" => length(rows),
      "median_error_m" => percentile(errors, 0.50),
      "p95_error_m" => percentile(errors, 0.95),
      "final_error_m" => rows |> List.last() |> last_error(),
      "fixed_n" => length(fixed),
      "float_n" => length(float),
      "fixed_median_error_m" => fixed |> Enum.map(& &1["error_m"]) |> percentile(0.50),
      "fixed_p95_error_m" => fixed |> Enum.map(& &1["error_m"]) |> percentile(0.95),
      "float_median_error_m" => float |> Enum.map(& &1["error_m"]) |> percentile(0.50)
    }
  end

  defp last_error(nil), do: nil
  defp last_error(row), do: row["error_m"]

  defp percentile([], _p), do: nil

  defp percentile(values, p) do
    sorted = Enum.sort(values)
    idx = floor((length(sorted) - 1) * p)
    Enum.at(sorted, idx)
  end

  defp filter_opts(wavelength_map) do
    [
      initial_baseline_m: {0.0, 0.0, 0.0},
      max_iterations: 10,
      on_cycle_slip: :split_arc,
      elevation_mask_deg: 10.0,
      stochastic_model: :rtklib,
      code_sigma_m: 0.3,
      phase_sigma_m: 0.003,
      ambiguity_wavelength_m: wavelength_map,
      integer_candidate_limit: 200_000,
      float_only_systems: ["R"],
      filter_kernel: :elixir
    ]
  end

  defp format_m(nil), do: "n/a"

  defp format_m(value) when is_number(value),
    do: :erlang.float_to_binary(value * 1.0, decimals: 6) <> "m"

  # ---- epoch builders (ported from gnss_rtk_real_arc_test.exs) ----

  defp real_multignss_l1_rtk_epochs(sp3, base_obs, rover_obs, count, systems) do
    glonass_slots = Observations.glonass_slots(base_obs)
    rover_by_epoch = Map.new(Observations.epochs(rover_obs), &{&1.epoch, &1})

    base_obs
    |> Observations.epochs()
    |> Enum.take(count)
    |> Enum.flat_map(fn base_entry ->
      case Map.fetch(rover_by_epoch, base_entry.epoch) do
        {:ok, rover_entry} ->
          base_values = multignss_l1_values(base_obs, base_entry.index, systems, glonass_slots)
          rover_values = multignss_l1_values(rover_obs, rover_entry.index, systems, glonass_slots)

          common =
            base_values
            |> Map.keys()
            |> MapSet.new()
            |> MapSet.intersection(rover_values |> Map.keys() |> MapSet.new())
            |> MapSet.to_list()
            |> Enum.sort()

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

  defp multignss_l1_values(obs, index, systems, glonass_slots) do
    codes =
      @multignss_l1_codes
      |> Map.take(systems)
      |> Map.new(fn {system, pairs} ->
        {system, Enum.flat_map(pairs, fn {code, phase} -> [code, phase] end)}
      end)

    {:ok, by_sat} = Observations.values(obs, index, codes: codes)

    by_sat
    |> Enum.flat_map(fn {sat, values} ->
      values_by_code = Map.new(values, &{&1.code, &1})
      pairs = Map.get(@multignss_l1_codes, String.first(sat), [])

      with {:ok, wavelength_m} <- multignss_wavelength_m(sat, glonass_slots),
           {:ok, {code_m, phase}} <- first_complete_code_phase_pair(values_by_code, pairs) do
        [
          {sat,
           %{
             satellite_id: sat,
             code_m: code_m,
             phase_m: phase.value * wavelength_m,
             lli: phase.lli
           }}
        ]
      else
        _ -> []
      end
    end)
    |> Map.new()
  end

  defp first_complete_code_phase_pair(_values_by_code, []), do: :error

  defp first_complete_code_phase_pair(values_by_code, [{code, phase} | rest]) do
    with %{value: code_m} when is_number(code_m) <- values_by_code[code],
         %{value: phase_cycles} = phase_obs when is_number(phase_cycles) <- values_by_code[phase] do
      {:ok, {code_m, phase_obs}}
    else
      _ -> first_complete_code_phase_pair(values_by_code, rest)
    end
  end

  defp multignss_wavelength_m("G" <> _, _slots), do: {:ok, @gps_l1_wavelength_m}
  defp multignss_wavelength_m("E" <> _, _slots), do: {:ok, @gps_l1_wavelength_m}
  defp multignss_wavelength_m("C" <> _, _slots), do: {:ok, @c_m_s / @bds_b1i_hz}

  defp multignss_wavelength_m("R" <> _ = sat, glonass_slots) do
    with {:ok, k} <- Map.fetch(glonass_slots, sat) do
      {:ok, @c_m_s / (@glonass_g1_hz + k * @glonass_g1_step_hz)}
    end
  end

  defp multignss_wavelength_map(epochs, glonass_slots) do
    epochs
    |> Enum.flat_map(&Map.keys(&1.satellite_positions_m))
    |> Enum.uniq()
    |> Map.new(fn sat ->
      {:ok, wavelength_m} = multignss_wavelength_m(sat, glonass_slots)
      {sat, wavelength_m}
    end)
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
      with %{code_m: code_m} when is_number(code_m) <- Map.get(values, sat),
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

  defp antenna_height_m(obs) do
    {height_m, +0.0, +0.0} = Observations.antenna_delta_hen(obs)
    height_m
  end

  defp arp_position(marker, antenna_h_m),
    do: add3(marker, scale3(marker, antenna_h_m / norm3(marker)))

  defp add3({ax, ay, az}, {bx, by, bz}), do: {ax + bx, ay + by, az + bz}
  defp scale3({x, y, z}, s), do: {x * s, y * s, z * s}
  defp norm3({x, y, z}), do: :math.sqrt(x * x + y * y + z * z)

  defp load_json!(path), do: path |> File.read!() |> Jason.decode!()

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

MultiGNSSSeqMeasurement.main(System.argv())
