defmodule Sidereon.GNSS.RTKRealArcTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias Sidereon.GNSS.Antex
  alias Sidereon.GNSS.RINEX.Observations
  alias Sidereon.GNSS.RTK
  alias Sidereon.GNSS.SP3

  @sp3_path Path.join(__DIR__, "fixtures/sp3/GBM0MGXRAP_20201770000_01D_05M_ORB_120epoch.sp3")
  @cod_sp3_path Path.join(__DIR__, "fixtures/sp3/COD0MGXFIN_20201770000_01D_05M_ORB.SP3")
  @wtzr_obs_path Path.join(
                   __DIR__,
                   "fixtures/obs/WTZR00DEU_R_20201770000_01D_30S_MO_120epoch.rnx"
                 )
  @wtzz_obs_path Path.join(
                   __DIR__,
                   "fixtures/obs/WTZZ00DEU_R_20201770000_01D_30S_MO_120epoch.rnx"
                 )
  @rtklib_multignss_oracle_path Path.join(
                                  __DIR__,
                                  "fixtures/rtk/wtzr_wtzz_multignss_static_rtklib_oracle.json"
                                )
  @pasa_scoa_l1_oracle_path Path.join(
                              __DIR__,
                              "fixtures/rtk/pasa_scoa_2026_120_l1_static_fixhold_rtklib_oracle.json"
                            )
  @c_m_s 299_792_458.0
  @gps_l1_hz 1_575_420_000.0
  @gps_l2_hz 1_227_600_000.0
  @gps_l1_wavelength_m @c_m_s / @gps_l1_hz
  # BeiDou B1I; Galileo E1 shares the GPS L1 carrier frequency.
  @bds_b1i_hz 1_561_098_000.0
  # GLONASS G1 FDMA: f = 1602 MHz + k * 562.5 kHz, slot k from the RINEX header.
  @glonass_g1_hz 1_602_000_000.0
  @glonass_g1_step_hz 562_500.0

  # L1-band code/phase observation pairs per system, in preference order. WTZR
  # tracks Galileo E1 as 1C while WTZZ tracks it as 1X; both are the same E1
  # carrier, so the builder takes the first complete pair per receiver.
  @multignss_l1_codes %{
    "G" => [{"C1C", "L1C"}],
    "R" => [{"C1C", "L1C"}],
    "E" => [{"C1C", "L1C"}, {"C1X", "L1X"}],
    "C" => [{"C2I", "L2I"}]
  }

  @wtzr_marker {4_075_580.3111, 931_854.0543, 4_801_568.2808}

  @tag timeout: 180_000
  test "real co-located Wettzell batch RTK bindings return core-owned result shapes" do
    sp3 = SP3.load!(@sp3_path)
    base_obs = Observations.load!(@wtzr_obs_path)
    rover_obs = Observations.load!(@wtzz_obs_path)

    base_arp = arp_position(@wtzr_marker, antenna_height_m(base_obs))
    epochs = real_gps_l1_rtk_epochs(sp3, base_obs, rover_obs, 120)

    assert length(epochs) == 120

    opts = [
      initial_baseline_m: {0.0, 0.0, 0.0},
      max_iterations: 10,
      on_cycle_slip: :split_arc,
      elevation_weighting: true,
      code_sigma_m: 2.0,
      phase_sigma_m: 0.01,
      ambiguity_wavelength_m: @gps_l1_wavelength_m,
      integer_candidate_limit: 200_000
    ]

    float_opts = Keyword.drop(opts, [:ambiguity_wavelength_m, :integer_candidate_limit])

    assert {:ok, float} = RTK.solve_float_baseline_epochs(base_arp, epochs, float_opts)

    assert float.metadata.n_epochs == 120
    assert float.metadata.measurement_covariance.elevation_weighting
    assert length(float.metadata.split_cycle_slip_arcs) == 4
    assert float.metadata.dropped_sats == []
    assert %{x_m: x, y_m: y, z_m: z} = float.baseline_m
    assert is_number(x) and is_number(y) and is_number(z)

    assert {:ok, fixed} = RTK.solve_fixed_baseline_epochs(base_arp, epochs, opts)

    assert fixed.metadata.integer_method == :lambda
    assert fixed.metadata.integer_candidates > 0
    assert %{x_m: x, y_m: y, z_m: z} = fixed.baseline_m
    assert is_number(x) and is_number(y) and is_number(z)

    assert {:ok, partial_fixed} =
             RTK.solve_fixed_baseline_epochs(
               base_arp,
               epochs,
               Keyword.merge(opts,
                 partial_ambiguity_resolution: true,
                 partial_min_ambiguities: 4
               )
             )

    assert partial_fixed.metadata.partial_ambiguity_resolution
    assert partial_fixed.metadata.partial_fixed
    assert is_map(partial_fixed.fixed_ambiguities_cycles)

    dual_epochs = real_gps_l1_l2_rtk_epochs(sp3, base_obs, rover_obs, 120)
    assert length(dual_epochs) == 120

    assert {:ok, wide_lane_fixed} =
             RTK.solve_widelane_fixed_baseline_epochs(base_arp, dual_epochs,
               initial_baseline_m: {0.0, 0.0, 0.0},
               max_iterations: 10,
               on_cycle_slip: :drop_satellite,
               elevation_weighting: true,
               code_sigma_m: 2.0,
               phase_sigma_m: 0.01,
               integer_candidate_limit: 200_000
             )

    assert wide_lane_fixed.wide_lane_ambiguities_cycles != nil
    assert wide_lane_fixed.metadata.integer_method == :widelane_narrowlane_lambda
    assert %{x_m: x, y_m: y, z_m: z} = wide_lane_fixed.baseline_m
    assert is_number(x) and is_number(y) and is_number(z)
  end

  # Canonical-vs-reference clustering bound (meters). Canonical RTK and the
  # RTKLIB-faithful reference share the double-difference measurement physics and
  # differ only in the linear solve (the owned Cholesky square-root-information
  # factorization vs the reference first-tie Gaussian elimination), so on the same
  # arc they cluster within the f64 roundoff floor of two factorizations of one
  # SPD system. Mirrors the crate's named CANONICAL_VS_REFERENCE_RTK_TOL_M = 1e-9 m
  # bar (the crate observes ~7e-14 m); beyond this band is a bug, not a band to
  # widen.
  @canonical_vs_reference_rtk_bound_m 1.0e-9

  @tag timeout: 180_000
  test "canonical strategy is selectable on the static RTK baseline and clusters within the named band" do
    sp3 = SP3.load!(@sp3_path)
    base_obs = Observations.load!(@wtzr_obs_path)
    rover_obs = Observations.load!(@wtzz_obs_path)
    base_arp = arp_position(@wtzr_marker, antenna_height_m(base_obs))
    epochs = real_gps_l1_rtk_epochs(sp3, base_obs, rover_obs, 30)

    float_opts = [
      initial_baseline_m: {0.0, 0.0, 0.0},
      max_iterations: 10,
      on_cycle_slip: :split_arc,
      elevation_weighting: true,
      code_sigma_m: 2.0,
      phase_sigma_m: 0.01
    ]

    # The default selection equals an explicit :reference selection, bit-for-bit:
    # canonical selection does not disturb the reference-faithful default.
    assert {:ok, default} = RTK.solve_float_baseline_epochs(base_arp, epochs, float_opts)

    assert {:ok, reference} =
             RTK.solve_float_baseline_epochs(
               base_arp,
               epochs,
               float_opts ++ [strategy: :reference]
             )

    assert default.baseline_m == reference.baseline_m

    # Canonical is selectable and deterministic (a second solve reproduces it).
    assert {:ok, canonical} =
             RTK.solve_float_baseline_epochs(
               base_arp,
               epochs,
               float_opts ++ [strategy: :canonical]
             )

    assert {:ok, canonical_again} =
             RTK.solve_float_baseline_epochs(
               base_arp,
               epochs,
               float_opts ++ [strategy: :canonical]
             )

    assert canonical.baseline_m == canonical_again.baseline_m

    # Bounded tolerance: canonical clusters within the named band of the reference.
    assert_in_delta canonical.baseline_m.x_m,
                    reference.baseline_m.x_m,
                    @canonical_vs_reference_rtk_bound_m

    assert_in_delta canonical.baseline_m.y_m,
                    reference.baseline_m.y_m,
                    @canonical_vs_reference_rtk_bound_m

    assert_in_delta canonical.baseline_m.z_m,
                    reference.baseline_m.z_m,
                    @canonical_vs_reference_rtk_bound_m

    # An unknown strategy is refused before the solve.
    assert RTK.solve_float_baseline_epochs(base_arp, epochs, float_opts ++ [strategy: :bogus]) ==
             {:error, {:invalid_option, :strategy}}
  end

  @tag timeout: 180_000
  test "two-epoch RTK real-arc binding returns fixed Rust filter output" do
    sp3 = SP3.load!(@cod_sp3_path)
    base_obs = Observations.load!(@wtzr_obs_path)
    rover_obs = Observations.load!(@wtzz_obs_path)
    base_arp = arp_position(@wtzr_marker, antenna_height_m(base_obs))

    epochs =
      sp3
      |> real_gps_l1_rtk_epochs(base_obs, rover_obs, 2)

    assert length(epochs) == 2

    assert {:ok, solution} =
             RTK.solve_filter_baseline_epochs(base_arp, epochs,
               initial_baseline_m: {0.0, 0.0, 0.0},
               max_iterations: 10,
               on_cycle_slip: :split_arc,
               elevation_mask_deg: 10.0,
               stochastic_model: :rtklib,
               code_sigma_m: 0.3,
               phase_sigma_m: 0.003,
               ambiguity_wavelength_m: @gps_l1_wavelength_m,
               integer_candidate_limit: 200_000
             )

    assert solution.metadata.n_epochs == 2
    assert solution.metadata.filter_kernel == :rust
    assert solution.metadata.measurement_covariance.stochastic_model == :rtklib
    assert solution.metadata.elevation_mask_deg == 10.0
    assert length(solution.epochs) == 2
    assert Enum.any?(solution.epochs, &(&1.integer_status == :fixed))
    assert %{x_m: x, y_m: y, z_m: z} = solution.baseline_m
    assert is_number(x) and is_number(y) and is_number(z)
  end

  @tag timeout: 180_000
  test "PASA/SCOA IGS20 receiver antenna corrections binding returns public filter shape" do
    oracle = @pasa_scoa_l1_oracle_path |> File.read!() |> Jason.decode!()
    repo = Path.expand("..", __DIR__)
    truth = oracle["truth"]
    inputs = oracle["inputs"]

    base_ecef = ecef_json_to_tuple(truth["base_station"]["marker_ecef_m"])
    sp3 = SP3.load!(Path.join(repo, inputs["sp3"]))
    base_obs = Observations.load!(Path.join(repo, inputs["base_obs"]))
    rover_obs = Observations.load!(Path.join(repo, inputs["rover_obs"]))
    initial_baseline = sub3(Observations.approx_position(rover_obs), base_ecef)

    corrections =
      receiver_antenna_corrections(
        Path.join(repo, inputs["antex"]),
        truth["base_station"]["antenna"],
        truth["rover_station"]["antenna"]
      )

    epochs = real_gps_l1_rtk_epochs(sp3, base_obs, rover_obs, oracle["reference"]["epochs"])
    assert length(epochs) == oracle["reference"]["epochs"]

    opts = [
      initial_baseline_m: initial_baseline,
      max_iterations: 10,
      on_cycle_slip: :split_arc,
      elevation_mask_deg: 10.0,
      stochastic_model: :rtklib,
      code_sigma_m: 0.3,
      phase_sigma_m: 0.003,
      ambiguity_wavelength_m: @gps_l1_wavelength_m,
      integer_ratio_threshold: 3.0,
      integer_candidate_limit: 200_000,
      receiver_antenna_corrections: corrections
    ]

    assert {:ok, solution} =
             RTK.solve_filter_baseline_epochs(base_ecef, epochs, opts ++ [filter_kernel: :rust])

    assert solution.metadata.n_epochs == oracle["reference"]["epochs"]
    assert solution.metadata.filter_kernel == :rust
    assert solution.metadata.measurement_covariance.stochastic_model == :rtklib
    assert solution.metadata.elevation_mask_deg == 10.0
    assert length(solution.epochs) == oracle["reference"]["epochs"]
    assert %{x_m: x, y_m: y, z_m: z} = solution.baseline_m
    assert is_number(x) and is_number(y) and is_number(z)
  end

  @tag timeout: 600_000
  test "multi-GNSS static RTK filter binding returns float-only metadata" do
    oracle = @rtklib_multignss_oracle_path |> File.read!() |> Jason.decode!()

    sp3 = SP3.load!(@cod_sp3_path)
    base_obs = Observations.load!(@wtzr_obs_path)
    rover_obs = Observations.load!(@wtzz_obs_path)
    base_arp = arp_position(@wtzr_marker, antenna_height_m(base_obs))
    glonass_slots = Observations.glonass_slots(base_obs)

    epochs =
      real_multignss_l1_rtk_epochs(
        sp3,
        base_obs,
        rover_obs,
        oracle["reference"]["epochs"],
        ["G", "R", "E", "C"]
      )

    assert length(epochs) == oracle["reference"]["epochs"]

    opts = [
      initial_baseline_m: {0.0, 0.0, 0.0},
      max_iterations: 10,
      on_cycle_slip: :split_arc,
      elevation_mask_deg: 10.0,
      stochastic_model: :rtklib,
      code_sigma_m: 0.3,
      phase_sigma_m: 0.003,
      ambiguity_wavelength_m: multignss_wavelength_map(epochs, glonass_slots),
      integer_candidate_limit: 200_000,
      float_only_systems: ["R"]
    ]

    assert {:ok, sol} =
             RTK.solve_filter_baseline_epochs(base_arp, epochs, opts ++ [filter_kernel: :rust])

    assert %{"G" => "G" <> _, "R" => "R" <> _, "E" => "E" <> _, "C" => "C" <> _} =
             sol.metadata.reference_satellites

    assert sol.metadata.float_only_systems == ["R"]
    assert sol.metadata.filter_kernel == :rust
    assert sol.metadata.n_epochs == oracle["reference"]["epochs"]
    assert length(sol.epochs) == oracle["reference"]["epochs"]

    for epoch <- sol.epochs do
      refute Enum.any?(epoch.fixed_ambiguities, &String.starts_with?(&1, "R"))
    end

    refute Enum.any?(Map.keys(sol.fixed_ambiguities_cycles), &String.starts_with?(&1, "R"))
    assert %{x_m: x, y_m: y, z_m: z} = sol.baseline_m
    assert is_number(x) and is_number(y) and is_number(z)
  end

  defp real_gps_l1_rtk_epochs(sp3, base_obs, rover_obs, count),
    do: real_multignss_l1_rtk_epochs(sp3, base_obs, rover_obs, count, ["G"])

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

          rover_values =
            multignss_l1_values(rover_obs, rover_entry.index, systems, glonass_slots)

          common =
            base_values
            |> Map.keys()
            |> MapSet.new()
            |> MapSet.intersection(rover_values |> Map.keys() |> MapSet.new())
            |> MapSet.to_list()
            |> Enum.sort()

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
    |> assert_receiver_position_maps()
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
         %{value: phase_cycles} = phase_obs when is_number(phase_cycles) <-
           values_by_code[phase] do
      {:ok, {code_m, phase_obs}}
    else
      _ -> first_complete_code_phase_pair(values_by_code, rest)
    end
  end

  defp multignss_wavelength_m("G" <> _, _slots), do: {:ok, @gps_l1_wavelength_m}
  defp multignss_wavelength_m("E" <> _, _slots), do: {:ok, @gps_l1_wavelength_m}
  defp multignss_wavelength_m("C" <> _, _slots), do: {:ok, @c_m_s / @bds_b1i_hz}

  defp multignss_wavelength_m("R" <> _ = sat, glonass_slots) do
    # A GLONASS satellite without a slot record has no known FDMA channel, so
    # its carrier wavelength is unknown; the builder drops it.
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

          common =
            base_values
            |> Map.keys()
            |> MapSet.new()
            |> MapSet.intersection(rover_values |> Map.keys() |> MapSet.new())
            |> MapSet.to_list()
            |> Enum.sort()

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
           {:ok, %{x_m: x, y_m: y, z_m: z}} <-
             SP3.position(sp3, sat, transmit_epoch, extrapolate: true) do
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

  defp assert_receiver_position_maps(epochs) do
    # The solve path should use receiver-specific transmit-time maps when tests
    # provide them. Keep this as a light fixture sanity check instead of a
    # numeric assertion about the baseline.
    assert Enum.all?(epochs, &Map.has_key?(&1, :base_satellite_positions_m))
    assert Enum.all?(epochs, &Map.has_key?(&1, :rover_satellite_positions_m))
    epochs
  end

  defp naive_datetime({{year, month, day}, {hour, minute, second}}) do
    whole_second = trunc(second)
    microsecond = round((second - whole_second) * 1_000_000)

    NaiveDateTime.new!(
      Date.new!(year, month, day),
      Time.new!(hour, minute, whole_second, {microsecond, 6})
    )
  end

  defp arp_position(marker, antenna_h_m),
    do: add3(marker, scale3(marker, antenna_h_m / norm3(marker)))

  defp antenna_height_m(obs) do
    assert {height_m, east_m, north_m} = Observations.antenna_delta_hen(obs)
    assert east_m == 0.0
    assert north_m == 0.0
    height_m
  end

  defp add3({ax, ay, az}, {bx, by, bz}), do: {ax + bx, ay + by, az + bz}
  defp sub3({ax, ay, az}, {bx, by, bz}), do: {ax - bx, ay - by, az - bz}
  defp scale3({x, y, z}, s), do: {x * s, y * s, z * s}
  defp norm3({x, y, z}), do: :math.sqrt(x * x + y * y + z * z)

  defp ecef_json_to_tuple(%{"x" => x, "y" => y, "z" => z}), do: {x, y, z}

  defp receiver_antenna_corrections(antex_path, base_name, rover_name) do
    antex = Antex.load!(antex_path)
    base = Antex.antenna(antex, base_name) || raise "ANTEX missing #{inspect(base_name)}"
    rover = Antex.antenna(antex, rover_name) || raise "ANTEX missing #{inspect(rover_name)}"

    %{
      base: %{antenna: base, frequency: "G01"},
      rover: %{antenna: rover, frequency: "G01"}
    }
  end
end
