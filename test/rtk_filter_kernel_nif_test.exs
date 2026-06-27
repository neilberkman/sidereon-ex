defmodule Sidereon.RTKFilterKernelNIFTest do
  use ExUnit.Case, async: false

  alias Sidereon.NIF

  test "updates one RTK filter epoch and carries held ambiguities" do
    lambda = 299_792_458.0 / 1_575_420_000.0
    base = {4_075_580.0, 931_854.0, 4_801_568.0}
    truth = {1.2, -0.85, 0.91}
    rover = add3(base, truth)

    sats = [
      {"G01", {15_000_000.0, 7_000_000.0, 21_000_000.0}, 0},
      {"G02", {-12_000_000.0, 18_000_000.0, 19_000_000.0}, 3},
      {"G03", {20_000_000.0, -10_000_000.0, 17_000_000.0}, -7},
      {"G04", {-19_000_000.0, -13_000_000.0, 20_000_000.0}, 12},
      {"G05", {9_000_000.0, 22_000_000.0, 16_000_000.0}, -4}
    ]

    [reference | nonref] =
      Enum.map(sats, fn {id, pos, cycles} ->
        sat_term(id, pos, base, rover, cycles, lambda)
      end)

    epoch = {[reference], nonref, nil, 0.0}

    state =
      {{3, [{"G", "G01"}], [], 10_000.0, 0}, {-30.0, 25.0, -10.0}, [],
       prior_information(10_000.0), [], []}

    model = {0.3, 0.003, "simple", false, false}
    wavelengths = for {id, _pos, _cycles} <- tl(sats), do: {id, lambda}
    offsets = for {id, _pos, _cycles} <- tl(sats), do: {id, 0.0}
    opts = {1.0, 1.0e-3, 1.0e-6, 10, 0.0, 3.0, {"constant_position", [], 0.0, 8, nil, true}}

    bad_reference_state =
      {{3, [{"G", "G99"}], [], 10_000.0, 0}, {-30.0, 25.0, -10.0}, [],
       prior_information(10_000.0), [], []}

    assert {:error, {:reference_changed, "G", "G99", "G01"}} =
             NIF.rtk_filter_update_epoch(
               bad_reference_state,
               epoch,
               base,
               model,
               wavelengths,
               offsets,
               opts,
               nil
             )

    assert {:error, {:missing_wavelength, "G02"}} =
             NIF.rtk_filter_update_epoch(state, epoch, base, model, [], offsets, opts, nil)

    assert {:ok,
            {next_state, reported_baseline, _reported_ambiguities, ratio, true,
             ["G02", "G03", "G04", "G05"], fixed_ids, search_meta, nil, residuals}} =
             NIF.rtk_filter_update_epoch(
               state,
               epoch,
               base,
               model,
               wavelengths,
               offsets,
               opts,
               nil
             )

    assert ratio >= 3.0
    assert fixed_ids == ["G02", "G03", "G04", "G05"]
    assert length(residuals) == 4

    assert {"fixed", "lambda", _, _, _, 2, {["G02", "G03", "G04", "G05"], _, _, _}, _, _} =
             search_meta

    # The reported (ambiguity-conditioned) baseline tracks truth on the fixing epoch.
    assert distance(reported_baseline, truth) < 1.0e-3

    assert {{3, [{"G", "G01"}], ["G01", "G02", "G03", "G04", "G05"], 10_000.0, 1}, baseline, _, _,
            cycles, metres} = next_state

    assert distance(baseline, truth) < 1.0e-3
    assert cycles == [{"G02", 3}, {"G03", -7}, {"G04", 12}, {"G05", -4}]

    assert Enum.all?(metres, fn {id, metres} ->
             expected = sats |> Enum.find(fn {sat, _pos, _cycles} -> sat == id end) |> elem(2)
             abs(metres - expected * lambda) < 1.0e-9
           end)

    assert {:ok,
            {second_state, _second_reported, _second_reported_ambiguities, second_ratio, true, [],
             ^fixed_ids, nil, nil, second_residuals}} =
             NIF.rtk_filter_update_epoch(
               next_state,
               epoch,
               base,
               model,
               wavelengths,
               offsets,
               opts,
               nil
             )

    assert second_ratio == 0.0
    assert length(second_residuals) == 4

    assert {{3, [{"G", "G01"}], ["G01", "G02", "G03", "G04", "G05"], 10_000.0, 2}, _baseline, _,
            _, ^cycles, _metres} = second_state
  end

  test "updates a batch of RTK filter epochs in one NIF call" do
    lambda = 299_792_458.0 / 1_575_420_000.0
    base = {4_075_580.0, 931_854.0, 4_801_568.0}
    truth = {1.2, -0.85, 0.91}
    rover = add3(base, truth)

    sats = [
      {"G01", {15_000_000.0, 7_000_000.0, 21_000_000.0}, 0},
      {"G02", {-12_000_000.0, 18_000_000.0, 19_000_000.0}, 3},
      {"G03", {20_000_000.0, -10_000_000.0, 17_000_000.0}, -7},
      {"G04", {-19_000_000.0, -13_000_000.0, 20_000_000.0}, 12},
      {"G05", {9_000_000.0, 22_000_000.0, 16_000_000.0}, -4}
    ]

    [reference | nonref] =
      Enum.map(sats, fn {id, pos, cycles} ->
        sat_term(id, pos, base, rover, cycles, lambda)
      end)

    epoch = {[reference], nonref, nil, 0.0}

    state =
      {{3, [{"G", "G01"}], [], 10_000.0, 0}, {-30.0, 25.0, -10.0}, [],
       prior_information(10_000.0), [], []}

    model = {0.3, 0.003, "simple", false, false}
    wavelengths = for {id, _pos, _cycles} <- tl(sats), do: {id, lambda}
    offsets = for {id, _pos, _cycles} <- tl(sats), do: {id, 0.0}
    opts = {1.0, 1.0e-3, 1.0e-6, 10, 0.0, 3.0, {"constant_position", [], 0.0, 8, nil, true}}

    assert {:ok,
            [
              {first_state, first_reported, _first_reported_ambiguities, first_ratio, true,
               ["G02", "G03", "G04", "G05"], first_fixed_ids, first_search_meta, nil,
               first_residuals},
              {second_state, _second_reported, _second_reported_ambiguities, second_ratio, true,
               [], second_fixed_ids, nil, nil, second_residuals}
            ]} =
             NIF.rtk_filter_update_epochs(
               state,
               [epoch, epoch],
               base,
               model,
               wavelengths,
               offsets,
               opts,
               nil
             )

    assert first_ratio >= 3.0
    assert first_fixed_ids == ["G02", "G03", "G04", "G05"]
    assert length(first_residuals) == 4
    assert length(second_residuals) == 4

    assert {"fixed", "lambda", _, _, _, 2, {["G02", "G03", "G04", "G05"], _, _, _}, _, _} =
             first_search_meta

    assert distance(first_reported, truth) < 1.0e-3
    assert second_ratio == 0.0
    assert second_fixed_ids == first_fixed_ids

    assert {{3, [{"G", "G01"}], ["G01", "G02", "G03", "G04", "G05"], 10_000.0, 1}, first_baseline,
            _, _, cycles, _metres} = first_state

    assert distance(first_baseline, truth) < 1.0e-3
    assert cycles == [{"G02", 3}, {"G03", -7}, {"G04", 12}, {"G05", -4}]

    assert {{3, [{"G", "G01"}], ["G01", "G02", "G03", "G04", "G05"], 10_000.0, 2},
            second_baseline, _, _, ^cycles, _metres} = second_state

    assert distance(second_baseline, truth) < 1.0e-3
  end

  defp sat_term(id, pos, base, rover, cycles, lambda) do
    {
      {id, id},
      {
        range(pos, base),
        range(pos, base),
        range(pos, rover),
        range(pos, rover) + cycles * lambda
      },
      {pos, pos, pos}
    }
  end

  defp prior_information(sigma) do
    w = 1.0 / (sigma * sigma)
    [w, 0.0, 0.0, 0.0, w, 0.0, 0.0, 0.0, w]
  end

  defp add3({ax, ay, az}, {bx, by, bz}), do: {ax + bx, ay + by, az + bz}

  defp distance(a, b) do
    {dx, dy, dz} = sub3(a, b)
    :math.sqrt(dx * dx + dy * dy + dz * dz)
  end

  defp range({sx, sy, sz}, {rx, ry, rz}) do
    :math.sqrt((sx - rx) * (sx - rx) + (sy - ry) * (sy - ry) + (sz - rz) * (sz - rz))
  end

  defp sub3({ax, ay, az}, {bx, by, bz}), do: {ax - bx, ay - by, az - bz}
end
