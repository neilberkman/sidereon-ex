defmodule Sidereon.GNSS.PreciseRealArcTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias Sidereon.GNSS.IonosphereFree
  alias Sidereon.GNSS.PrecisePositioning
  alias Sidereon.GNSS.RINEX.Observations
  alias Sidereon.GNSS.SP3

  @sp3_path Path.join(__DIR__, "fixtures/sp3/GBM0MGXRAP_20201770000_01D_05M_ORB_120epoch.sp3")
  @obs_path Path.join(__DIR__, "fixtures/obs/ESBC00DNK_R_20201770000_01D_30S_MO_120epoch.rnx")

  @tag timeout: 420_000
  test "real multi-epoch PPP binding returns the public solution shape" do
    sp3 = SP3.load!(@sp3_path)
    obs = Observations.load!(@obs_path)
    {x0, y0, z0} = Observations.approx_position(obs)
    epoch_observations = real_gps_iono_free_arc(obs, 12)

    assert {:ok, solution} =
             PrecisePositioning.solve_float_epochs(sp3, epoch_observations,
               initial_guess: {x0 + 100.0, y0 - 100.0, z0 + 100.0, 0.0},
               max_iterations: 8,
               troposphere: true
             )

    assert %{x_m: x, y_m: y, z_m: z} = solution.position
    assert is_number(x)
    assert is_number(y)
    assert is_number(z)
    assert solution.metadata.n_epochs == 12
    assert solution.metadata.n_observations > 0
    assert solution.metadata.troposphere_applied
    assert solution.metadata.ztd_estimated == false
    assert length(solution.epochs) == 12
    refute Enum.empty?(solution.residuals_m)
    assert Enum.all?(solution.used_sats, &is_binary/1)
  end

  @tag timeout: 420_000
  test "real wide-lane fixed PPP binding decodes split-arc metadata" do
    sp3 = SP3.load!(@sp3_path)
    obs = Observations.load!(@obs_path)
    {x0, y0, z0} = Observations.approx_position(obs)
    dual_epoch_observations = real_gps_dual_frequency_arc(obs, 30)

    assert {:ok, fixed} =
             PrecisePositioning.solve_widelane_fixed_epochs(sp3, dual_epoch_observations,
               initial_guess: {x0 + 100.0, y0 - 100.0, z0 + 100.0, 0.0},
               max_iterations: 5,
               troposphere: true,
               on_cycle_slip: :split_arc,
               wide_lane_tolerance_cycles: 2.0,
               integer_candidate_limit: 2_000_000
             )

    assert %{x_m: x, y_m: y, z_m: z} = fixed.position
    assert is_number(x)
    assert is_number(y)
    assert is_number(z)
    assert fixed.metadata.integer_method == :widelane_narrowlane_lambda
    assert fixed.metadata.wide_lane_fixed
    assert fixed.metadata.integer_candidates >= 1
    assert is_map(fixed.fixed_ambiguities_cycles)
    assert is_map(fixed.wide_lane_ambiguities_cycles)
    assert is_list(fixed.metadata.split_cycle_slip_arcs)
    refute Enum.empty?(fixed.metadata.split_cycle_slip_arcs)
  end

  defp real_gps_iono_free_arc(obs, count) do
    {:ok, f1} = IonosphereFree.frequency("G", :l1)
    {:ok, f2} = IonosphereFree.frequency("G", :l2)

    obs
    |> Observations.epochs()
    |> Enum.take(count)
    |> Enum.map(fn entry ->
      rows = epoch_rows(obs, entry.index, f1, f2)

      if length(rows) < 6 do
        raise "fixture epoch #{inspect(entry.epoch)} has only #{length(rows)} complete GPS L1/L2 code+phase rows"
      end

      %{epoch: naive_datetime(entry.epoch), observations: rows}
    end)
  end

  defp real_gps_dual_frequency_arc(obs, count) do
    {:ok, f1} = IonosphereFree.frequency("G", :l1)
    {:ok, f2} = IonosphereFree.frequency("G", :l2)

    obs
    |> Observations.epochs()
    |> Enum.take(count)
    |> Enum.map(fn entry ->
      rows = dual_epoch_rows(obs, entry.index, f1, f2)

      if length(rows) < 6 do
        raise "fixture epoch #{inspect(entry.epoch)} has only #{length(rows)} complete GPS L1/L2 code+phase rows"
      end

      %{epoch: naive_datetime(entry.epoch), observations: rows}
    end)
  end

  defp epoch_rows(obs, index, f1, f2) do
    {:ok, by_sat} =
      Observations.values(obs, index, codes: %{"G" => ["C1C", "C2W", "L1C", "L2W"]})

    by_sat
    |> Enum.flat_map(fn {sat, values} ->
      values_by_code = Map.new(values, &{&1.code, &1.value})

      with c1 when is_number(c1) <- values_by_code["C1C"],
           c2 when is_number(c2) <- values_by_code["C2W"],
           l1 when is_number(l1) <- values_by_code["L1C"],
           l2 when is_number(l2) <- values_by_code["L2W"],
           {:ok, code_m} <- IonosphereFree.iono_free(c1, c2, f1, f2),
           {:ok, phase_m} <- IonosphereFree.iono_free_phase_cycles(l1, l2, f1, f2) do
        [%{satellite_id: sat, code_m: code_m, phase_m: phase_m}]
      else
        _ -> []
      end
    end)
    |> Enum.sort_by(& &1.satellite_id)
  end

  defp dual_epoch_rows(obs, index, f1, f2) do
    {:ok, by_sat} =
      Observations.values(obs, index, codes: %{"G" => ["C1C", "C2W", "L1C", "L2W"]})

    by_sat
    |> Enum.flat_map(fn {sat, values} ->
      values_by_code = Map.new(values, &{&1.code, &1.value})

      with c1 when is_number(c1) <- values_by_code["C1C"],
           c2 when is_number(c2) <- values_by_code["C2W"],
           l1 when is_number(l1) <- values_by_code["L1C"],
           l2 when is_number(l2) <- values_by_code["L2W"] do
        [
          %{
            satellite_id: sat,
            p1_m: c1,
            p2_m: c2,
            phi1_cyc: l1,
            phi2_cyc: l2,
            f1_hz: f1,
            f2_hz: f2
          }
        ]
      else
        _ -> []
      end
    end)
    |> Enum.sort_by(& &1.satellite_id)
  end

  defp naive_datetime({{year, month, day}, {hour, minute, second}}) do
    whole_second = trunc(second)
    microsecond = round((second - whole_second) * 1_000_000)

    NaiveDateTime.new!(
      Date.new!(year, month, day),
      Time.new!(hour, minute, whole_second, {microsecond, 6})
    )
  end
end
