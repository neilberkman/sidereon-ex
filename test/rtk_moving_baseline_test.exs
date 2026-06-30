defmodule Sidereon.GNSS.RTK.MovingBaselineTest do
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.RTK.MovingBaseline

  # The exact synthetic five-satellite geometry the sidereon-core moving-baseline
  # golden uses: well-spread satellites with fixed integer ambiguities.
  @c_m_s 299_792_458.0
  @f_l1_hz 1_575_420_000.0

  # {id, {x, y, z}, integer cycles}
  @sats [
    {"G01", {15_000_000.0, 7_000_000.0, 21_000_000.0}, 0},
    {"G02", {-12_000_000.0, 18_000_000.0, 19_000_000.0}, 4},
    {"G03", {20_000_000.0, -10_000_000.0, 17_000_000.0}, -7},
    {"G04", {-19_000_000.0, -13_000_000.0, 20_000_000.0}, 9},
    {"G05", {9_000_000.0, 22_000_000.0, 16_000_000.0}, -3}
  ]

  defp lambda, do: @c_m_s / @f_l1_hz

  defp range_m({sx, sy, sz}, {rx, ry, rz}) do
    dx = sx - rx
    dy = sy - ry
    dz = sz - rz
    :math.sqrt(dx * dx + dy * dy + dz * dz)
  end

  defp add3({ax, ay, az}, {bx, by, bz}), do: {ax + bx, ay + by, az + bz}

  defp sat_meas({id, pos, cycles}, base, rover) do
    %{
      sat: id,
      sd_ambiguity_id: id,
      base_code_m: range_m(pos, base),
      base_phase_m: range_m(pos, base),
      rover_code_m: range_m(pos, rover),
      rover_phase_m: range_m(pos, rover) + cycles * lambda(),
      base_tx_pos: pos,
      rover_tx_pos: pos,
      pos: pos
    }
  end

  defp synth_epoch(base, baseline) do
    rover = add3(base, baseline)
    [reference | nonref] = @sats
    ids = Enum.map(nonref, fn {id, _pos, _c} -> id end)

    %{
      base_position_m: base,
      references: [sat_meas(reference, base, rover)],
      nonref: Enum.map(nonref, &sat_meas(&1, base, rover)),
      ambiguity_ids: ids,
      ambiguity_satellites: Map.new(ids, &{&1, &1}),
      wavelengths_m: Map.new(ids, &{&1, lambda()}),
      offsets_m: Map.new(ids, &{&1, 0.0}),
      float_only_systems: []
    }
  end

  defp opts do
    %{
      model: %{
        code_sigma_m: 0.3,
        phase_sigma_m: 0.003,
        stochastic_model: :simple,
        elevation_weighting: false,
        sagnac: false
      },
      float: %{position_tol_m: 1.0e-3, ambiguity_tol_m: 1.0e-6, max_iterations: 10},
      fixed: %{
        position_tol_m: 1.0e-3,
        ambiguity_tol_m: 1.0e-6,
        max_iterations: 10,
        ratio_threshold: 3.0,
        partial_ambiguity_resolution: false,
        partial_min_ambiguities: 4
      },
      initial_baseline_m: {-30.0, 25.0, -10.0},
      warm_start: true
    }
  end

  @bases [
    {4_075_580.0, 931_854.0, 4_801_568.0},
    {4_075_585.0, 931_860.0, 4_801_572.0},
    {4_075_590.0, 931_867.0, 4_801_575.0}
  ]
  @truth {1.2, -0.85, 0.91}

  test "solve_epochs recovers the fixed baseline per epoch as the base moves" do
    epochs = Enum.map(@bases, &synth_epoch(&1, @truth))
    assert {:ok, solutions} = MovingBaseline.solve_epochs(epochs, opts())
    assert length(solutions) == 3

    {tx, ty, tz} = @truth

    for {solution, base} <- Enum.zip(solutions, @bases) do
      assert solution.status == :fixed
      assert solution.base_position_m == base
      {bx, by, bz} = solution.baseline_m
      assert_in_delta bx, tx, 1.0e-6
      assert_in_delta by, ty, 1.0e-6
      assert_in_delta bz, tz, 1.0e-6

      truth_len = :math.sqrt(tx * tx + ty * ty + tz * tz)
      assert_in_delta solution.baseline_length_m, truth_len, 1.0e-6
    end
  end
end
