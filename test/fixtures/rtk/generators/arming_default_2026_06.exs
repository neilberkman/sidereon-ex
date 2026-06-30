defmodule ArmingDefault do
  @moduledoc false

  # Arming gate default-on decision (arming-default-spec.md): measure a
  # wavelength-tied :ar_arming_sigma_m candidate default against the clean arcs
  # (Wettzell static + kinematic GPS L1) and re-confirm the PASA/SCOA L1
  # protection arc. The decision rule: flip the default only if no clean arc
  # regresses AND the PASA/SCOA wrong-fix protection is retained. All cells use
  # filter_kernel: :elixir (Elixir reference only).
  #
  # Usage (from the repo root):
  #   ORBIS_BUILD=1 mix run test/fixtures/rtk/generators/arming_default_2026_06.exs

  alias Sidereon.GNSS.RINEX.Observations
  alias Sidereon.GNSS.RTK
  alias Sidereon.GNSS.SP3

  @c_m_s 299_792_458.0
  @gps_l1_hz 1_575_420_000.0
  @gps_l1_wavelength_m @c_m_s / @gps_l1_hz

  # Candidate wavelength-tied default thresholds, plus the always-armed
  # baseline (nil). Quarter and half wavelength bracket the task's named band;
  # 0.10 is the ar-commitment sweep upper sanity point.
  @quarter_wl @gps_l1_wavelength_m / 4.0
  @half_wl @gps_l1_wavelength_m / 2.0
  @thresholds [nil, @quarter_wl, @half_wl, 0.10]

  @default_results "/tmp/arming-default-results.json"

  # Wettzell fixtures (mirror gnss_rtk_real_arc_test.exs constants).
  @cod_sp3 "test/fixtures/sp3/COD0MGXFIN_20201770000_01D_05M_ORB.SP3"
  @wtzr_obs "test/fixtures/obs/WTZR00DEU_R_20201770000_01D_30S_MO_120epoch.rnx"
  @wtzz_obs "test/fixtures/obs/WTZZ00DEU_R_20201770000_01D_30S_MO_120epoch.rnx"
  @wtzr_marker {4_075_580.3111, 931_854.0543, 4_801_568.2808}
  @wtzz_marker {4_075_579.1913, 931_853.3696, 4_801_569.1897}
  @wtzr_precise_oracle "test/fixtures/rtk/wtzr_wtzz_rtklib_precise_oracle.json"
  @wtzr_kinematic_oracle "test/fixtures/rtk/wtzr_wtzz_kinematic_gps_rtklib_oracle.json"

  # PASA/SCOA L1 fixture (the protection arc).
  @pasa_scoa_oracle "test/fixtures/rtk/pasa_scoa_2026_120_l1_static_fixhold_rtklib_oracle.json"
  @pasa_scoa_elmask_deg 15.0

  def main(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args, strict: [results: :string], aliases: [r: :results])

    if invalid != [], do: raise(ArgumentError, "invalid arguments: #{inspect(invalid)}")

    repo = Path.expand("../../../..", __DIR__)
    results_path = Keyword.get(opts, :results, @default_results)

    wettzell = wettzell_inputs(repo)
    pasa_scoa = pasa_scoa_inputs(repo)

    static_cells =
      run_arc(
        "wettzell_static",
        wettzell.epochs,
        wettzell.base_arp,
        wettzell.truth_baseline,
        wettzell_static_opts(),
        @thresholds
      )

    kinematic_cells =
      run_arc(
        "wettzell_kinematic",
        wettzell.epochs,
        wettzell.base_arp,
        wettzell.truth_baseline,
        wettzell_static_opts() ++ [process_noise_baseline_sigma_m: 30.0],
        @thresholds
      )

    pasa_scoa_cells =
      run_arc(
        "pasa_scoa_l1",
        pasa_scoa.epochs,
        pasa_scoa.base_ecef,
        pasa_scoa.truth_baseline,
        pasa_scoa_opts(pasa_scoa.initial_baseline),
        @thresholds
      )

    pasa_scoa_floor_m = 2.0 * pasa_scoa.oracle_mean_truth_error_m

    payload = %{
      "gps_l1_wavelength_m" => @gps_l1_wavelength_m,
      "quarter_wavelength_m" => @quarter_wl,
      "half_wavelength_m" => @half_wl,
      "pasa_scoa_credibility_floor_m" => pasa_scoa_floor_m,
      "pasa_scoa_oracle_mean_truth_error_m" => pasa_scoa.oracle_mean_truth_error_m,
      "wettzell_static_oracle" => wettzell.static_oracle_ref,
      "wettzell_kinematic_oracle" => wettzell.kinematic_oracle_ref,
      "arcs" => %{
        "wettzell_static" => static_cells,
        "wettzell_kinematic" => kinematic_cells,
        "pasa_scoa_l1" => pasa_scoa_cells
      }
    }

    File.write!(results_path, Jason.encode!(payload, pretty: true))
    IO.puts("results written to #{results_path}\n")

    print_arc("WETTZELL STATIC (clean, must not regress)", static_cells, nil)
    print_arc("WETTZELL KINEMATIC (clean, must not regress)", kinematic_cells, nil)
    print_arc("PASA/SCOA L1 (protection arc)", pasa_scoa_cells, pasa_scoa_floor_m)
  end

  defp run_arc(arc_id, epochs, base_ecef, truth_baseline, base_opts, thresholds) do
    Enum.map(thresholds, fn t ->
      opts = if t == nil, do: base_opts, else: base_opts ++ [ar_arming_sigma_m: t]
      label = if t == nil, do: "none (current default)", else: "arm <= #{fmt(t)}"
      IO.puts("running #{arc_id} (#{label})")

      case RTK.solve_filter_baseline_epochs(base_ecef, epochs, opts) do
        {:ok, sol} ->
          rows =
            Enum.map(sol.epochs, fn epoch ->
              %{
                "index" => epoch.index,
                "integer_status" => Atom.to_string(epoch.integer_status),
                "error_m" => position_error(epoch.baseline_m, truth_baseline)
              }
            end)

          fixed = Enum.filter(rows, &(&1["integer_status"] == "fixed"))

          %{
            "threshold_m" => t,
            "label" => label,
            "status" => "solved",
            "first_fixed_index" => sol.metadata.first_fixed_index,
            "fixed_n" => length(fixed),
            "n" => length(rows),
            "fixed_median_error_m" => fixed |> Enum.map(& &1["error_m"]) |> percentile(0.50),
            "final_error_m" => position_error(sol.baseline_m, truth_baseline)
          }

        {:error, reason} ->
          %{
            "threshold_m" => t,
            "label" => label,
            "status" => "error",
            "error_reason" => inspect(reason),
            "first_fixed_index" => nil,
            "fixed_n" => 0,
            "n" => 0,
            "fixed_median_error_m" => nil,
            "final_error_m" => nil
          }
      end
    end)
  end

  defp print_arc(title, cells, floor_m) do
    IO.puts("\n## #{title}")
    IO.puts("threshold_m | first_fix | fixed_n | fixed_median | final | status")

    Enum.each(cells, fn c ->
      verdict =
        cond do
          floor_m == nil -> ""
          c["status"] != "solved" -> "  ERROR"
          c["fixed_n"] < 20 -> "  underpowered(n<20)"
          c["fixed_median_error_m"] > floor_m -> "  FAIL-by-floor"
          true -> "  PASS"
        end

      IO.puts(
        "#{fmt_thr(c["threshold_m"])} | #{c["first_fixed_index"]} | #{c["fixed_n"]}/#{c["n"]} | " <>
          "#{fmt(c["fixed_median_error_m"])} | #{fmt(c["final_error_m"])} | #{c["status"]}#{verdict}"
      )
    end)
  end

  defp wettzell_static_opts do
    [
      initial_baseline_m: {0.0, 0.0, 0.0},
      max_iterations: 10,
      on_cycle_slip: :split_arc,
      elevation_mask_deg: 10.0,
      stochastic_model: :rtklib,
      code_sigma_m: 0.3,
      phase_sigma_m: 0.003,
      ambiguity_wavelength_m: @gps_l1_wavelength_m,
      integer_candidate_limit: 200_000,
      filter_kernel: :elixir
    ]
  end

  defp pasa_scoa_opts(initial_baseline) do
    [
      initial_baseline_m: initial_baseline,
      max_iterations: 10,
      on_cycle_slip: :split_arc,
      elevation_mask_deg: @pasa_scoa_elmask_deg,
      stochastic_model: :rtklib,
      code_sigma_m: 0.3,
      phase_sigma_m: 0.003,
      ambiguity_wavelength_m: @gps_l1_wavelength_m,
      integer_ratio_threshold: 3.0,
      integer_candidate_limit: 200_000,
      filter_kernel: :elixir
    ]
  end

  defp wettzell_inputs(repo) do
    sp3 = SP3.load!(Path.join(repo, @cod_sp3))
    base_obs = Observations.load!(Path.join(repo, @wtzr_obs))
    rover_obs = Observations.load!(Path.join(repo, @wtzz_obs))
    base_arp = arp_position(@wtzr_marker, antenna_height_m(base_obs))
    rover_arp = arp_position(@wtzz_marker, antenna_height_m(rover_obs))
    truth_baseline = sub3(rover_arp, base_arp)

    static_oracle = load_json!(Path.join(repo, @wtzr_precise_oracle))
    kinematic_oracle = load_json!(Path.join(repo, @wtzr_kinematic_oracle))
    count = static_oracle["reference"]["epochs"]

    IO.puts("building Wettzell GPS L1 epochs")
    epochs = real_gps_l1_rtk_epochs(sp3, base_obs, rover_obs, count)
    IO.puts("#{length(epochs)} Wettzell epochs")

    %{
      epochs: epochs,
      base_arp: base_arp,
      truth_baseline: truth_baseline,
      static_oracle_ref: static_oracle["reference"],
      kinematic_oracle_ref: kinematic_oracle["reference"]
    }
  end

  defp pasa_scoa_inputs(repo) do
    oracle = load_json!(Path.join(repo, @pasa_scoa_oracle))
    truth = oracle["truth"]
    inputs = oracle["inputs"]

    base_ecef = ecef_map_to_tuple(truth["base_station"]["marker_ecef_m"])
    rover_truth = ecef_map_to_tuple(truth["rover_station"]["marker_ecef_m"])
    truth_baseline = sub3(rover_truth, base_ecef)

    sp3 = SP3.load!(Path.join(repo, inputs["sp3"]))
    base_obs = Observations.load!(Path.join(repo, inputs["base_obs"]))
    rover_obs = Observations.load!(Path.join(repo, inputs["rover_obs"]))
    initial_baseline = sub3(Observations.approx_position(rover_obs), base_ecef)

    IO.puts("building PASA/SCOA GPS L1 epochs")
    epochs = real_gps_l1_rtk_epochs(sp3, base_obs, rover_obs, oracle["reference"]["epochs"])
    IO.puts("#{length(epochs)} PASA/SCOA epochs")

    %{
      epochs: epochs,
      base_ecef: base_ecef,
      truth_baseline: truth_baseline,
      initial_baseline: initial_baseline,
      oracle_mean_truth_error_m: oracle["reference"]["mean_truth_error_m"]
    }
  end

  # --- shared epoch builder (same as ar_sweep_2026_06.exs) ---

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
    Enum.reduce(sats, %{}, fn sat, acc ->
      case SP3.position(sp3, sat, epoch) do
        {:ok, %{x_m: x, y_m: y, z_m: z}} -> Map.put(acc, sat, {x, y, z})
        {:error, _reason} -> acc
      end
    end)
  end

  defp transmit_time_satellite_positions(sp3, receive_epoch, values, sats, code_key) do
    Enum.reduce(sats, %{}, fn sat, acc ->
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

  defp arp_position(marker, antenna_h_m), do: add3(marker, scale3(marker, antenna_h_m / norm3(marker)))

  defp antenna_height_m(obs) do
    {height_m, _east_m, _north_m} = Observations.antenna_delta_hen(obs)
    height_m
  end

  defp add3({ax, ay, az}, {bx, by, bz}), do: {ax + bx, ay + by, az + bz}
  defp scale3({x, y, z}, s), do: {x * s, y * s, z * s}
  defp norm3({x, y, z}), do: :math.sqrt(x * x + y * y + z * z)

  defp load_json!(path), do: path |> File.read!() |> Jason.decode!()

  defp ecef_map_to_tuple(%{"x" => x, "y" => y, "z" => z}), do: {x, y, z}

  defp position_error(%{x_m: x, y_m: y, z_m: z}, truth), do: position_error({x, y, z}, truth)

  defp position_error({x, y, z}, {truth_x, truth_y, truth_z}) do
    :math.sqrt(
      (x - truth_x) * (x - truth_x) +
        (y - truth_y) * (y - truth_y) +
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

  defp fmt(nil), do: "n/a"

  defp fmt(value) when is_number(value), do: :erlang.float_to_binary(value * 1.0, decimals: 5) <> "m"

  defp fmt_thr(nil), do: "none      "
  defp fmt_thr(value), do: :erlang.float_to_binary(value * 1.0, decimals: 5)
end

ArmingDefault.main(System.argv())
