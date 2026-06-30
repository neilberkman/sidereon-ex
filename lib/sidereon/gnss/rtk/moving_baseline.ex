defmodule Sidereon.GNSS.RTK.MovingBaseline do
  @moduledoc """
  Moving-baseline RTK: both receivers move each epoch (RTKLIB "moving-base").

  Standard relative RTK positions a moving rover against a base whose ECEF
  coordinates are fixed for the whole arc. The double-difference cancellation, the
  iterated float baseline least squares, and the LAMBDA integer fix are all
  unchanged when the base also moves, so the only difference is that the base ECEF
  position is supplied **per epoch** (typically the base receiver's own navigation
  fix). This module is a thin primitive over
  `sidereon_core::rtk_filter::moving_baseline`: it marshals already-prepared
  double-difference epochs into the core solvers and decodes the per-epoch
  baseline, its length, and the integer-fix verdict.

  This is a traceable primitive, not the high-level `Sidereon.GNSS.RTK` API: the
  caller supplies the reference/non-reference satellite measurements and the
  ambiguity set directly, so no reference selection or cycle-slip preparation
  happens here.

  ## Epoch shape

      %{
        base_position_m: {x, y, z},
        references: [sat_meas],          # one reference per constellation
        nonref: [sat_meas],
        velocity_mps: {x, y, z} | nil,   # optional
        dt_s: 0.0,                        # optional
        ambiguity_ids: ["G02", ...],
        ambiguity_satellites: %{"G02" => "G02", ...},
        wavelengths_m: %{"G02" => 0.19, ...},
        offsets_m: %{"G02" => 0.0, ...},   # optional, default 0 per id
        float_only_systems: []             # optional
      }

  where each `sat_meas` is

      %{
        sat: "G01", sd_ambiguity_id: "G01",
        base_code_m: _, base_phase_m: _, rover_code_m: _, rover_phase_m: _,
        base_tx_pos: {x, y, z}, rover_tx_pos: {x, y, z}, pos: {x, y, z}
      }

  ## Options

      %{
        model: %{code_sigma_m: 0.3, phase_sigma_m: 0.003,
                 stochastic_model: :simple, elevation_weighting: false, sagnac: false},
        float: %{position_tol_m: 1.0e-4, ambiguity_tol_m: 1.0e-4, max_iterations: 10},
        fixed: %{position_tol_m: 1.0e-4, ambiguity_tol_m: 1.0e-4, max_iterations: 10,
                 ratio_threshold: 3.0, partial_ambiguity_resolution: false,
                 partial_min_ambiguities: 4},
        initial_baseline_m: {0.0, 0.0, 0.0},
        warm_start: true
      }
  """

  alias Sidereon.NIF

  @type vec3 :: {number(), number(), number()}
  @type solution :: %{
          base_position_m: vec3(),
          baseline_m: vec3(),
          baseline_length_m: float(),
          status: :fixed | :float,
          float: map(),
          fixed: map()
        }

  @doc """
  Solve a sequence of moving-baseline epochs, each against its own base position.

  With `warm_start: true` each solved baseline seeds the next epoch's float
  linearization point. Returns `{:ok, [solution]}` or
  `{:error, {epoch_index, reason}}` for the first failing epoch.
  """
  @spec solve_epochs([map()], map()) :: {:ok, [solution()]} | {:error, term()}
  def solve_epochs(epochs, opts) when is_list(epochs) do
    {model, float_opts, fixed_opts, initial_baseline, warm_start} = opts_terms(opts)

    case NIF.rtk_solve_moving_baseline(
           Enum.map(epochs, &epoch_term/1),
           {model, float_opts, fixed_opts, initial_baseline, warm_start},
           nil
         ) do
      {:ok, solutions} -> {:ok, Enum.map(solutions, &decode_solution/1)}
      {:error, epoch_index, reason} -> {:error, {epoch_index, reason}}
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  # --- term builders -------------------------------------------------------

  defp opts_terms(opts) do
    model = opts |> Map.fetch!(:model) |> model_term()
    float = opts |> Map.fetch!(:float) |> float_opts_term()
    fixed = opts |> Map.fetch!(:fixed) |> fixed_opts_term()
    initial_baseline = floats3(Map.get(opts, :initial_baseline_m, {0.0, 0.0, 0.0}))
    warm_start = Map.get(opts, :warm_start, true)
    {model, float, fixed, initial_baseline, warm_start}
  end

  defp model_term(model) do
    {
      model.code_sigma_m / 1.0,
      model.phase_sigma_m / 1.0,
      Atom.to_string(Map.get(model, :stochastic_model, :simple)),
      Map.get(model, :elevation_weighting, false),
      Map.get(model, :sagnac, false)
    }
  end

  defp float_opts_term(float) do
    {
      float.position_tol_m / 1.0,
      float.ambiguity_tol_m / 1.0,
      float.max_iterations
    }
  end

  defp fixed_opts_term(fixed) do
    {
      fixed.position_tol_m / 1.0,
      fixed.ambiguity_tol_m / 1.0,
      fixed.max_iterations,
      fixed.ratio_threshold / 1.0,
      Map.get(fixed, :partial_ambiguity_resolution, false),
      Map.get(fixed, :partial_min_ambiguities, 0)
    }
  end

  defp epoch_term(epoch) do
    references = Enum.map(Map.fetch!(epoch, :references), &sat_term/1)
    nonref = Enum.map(Map.fetch!(epoch, :nonref), &sat_term/1)
    velocity = epoch |> Map.get(:velocity_mps) |> maybe_floats3()
    dt_s = Map.get(epoch, :dt_s, 0.0) / 1.0

    ids = Map.fetch!(epoch, :ambiguity_ids)
    satellites = epoch |> Map.fetch!(:ambiguity_satellites) |> Enum.sort_by(&pair_key/1) |> to_pairs()
    wavelengths = epoch |> Map.fetch!(:wavelengths_m) |> sorted_float_pairs()
    offsets = epoch |> Map.get(:offsets_m, %{}) |> sorted_float_pairs()
    float_only = Map.get(epoch, :float_only_systems, [])

    {
      floats3(Map.fetch!(epoch, :base_position_m)),
      {references, nonref, velocity, dt_s},
      {ids, satellites, wavelengths, offsets, float_only}
    }
  end

  defp sat_term(sat) do
    {
      {sat.sat, sat.sd_ambiguity_id},
      {sat.base_code_m / 1.0, sat.base_phase_m / 1.0, sat.rover_code_m / 1.0, sat.rover_phase_m / 1.0},
      {floats3(sat.base_tx_pos), floats3(sat.rover_tx_pos), floats3(sat.pos)}
    }
  end

  defp to_pairs(list) when is_list(list), do: Enum.map(list, fn {k, v} -> {k, v} end)

  defp pair_key({k, _v}), do: k

  defp sorted_float_pairs(map) do
    map
    |> Enum.map(fn {k, v} -> {k, v / 1.0} end)
    |> Enum.sort_by(&pair_key/1)
  end

  # --- solution decode -----------------------------------------------------

  defp decode_solution({base, baseline, length, status, float_term, fixed_term}) do
    %{
      base_position_m: base,
      baseline_m: baseline,
      baseline_length_m: length,
      status: status_atom(status),
      float: decode_float(float_term),
      fixed: decode_fixed(fixed_term)
    }
  end

  defp status_atom("fixed"), do: :fixed
  defp status_atom("float"), do: :float

  defp decode_float(
         {baseline, ambiguities_m, _cov, _cov_inv, _residuals,
          {iterations, converged?, status, code_rms_m, phase_rms_m, weighted_rms_m, n_observations}}
       ) do
    %{
      baseline_m: baseline,
      ambiguities_m: ambiguities_m,
      iterations: iterations,
      converged: converged?,
      status: status,
      code_rms_m: code_rms_m,
      phase_rms_m: phase_rms_m,
      weighted_rms_m: weighted_rms_m,
      n_observations: n_observations
    }
  end

  defp decode_fixed(
         {baseline, _free_ambiguities_m, fixed_cycles, fixed_m, _residuals,
          {iterations, converged?, status, code_rms_m, phase_rms_m, weighted_rms_m, n_observations},
          {integer_status, _method, integer_ratio, _best, _second, _candidates, _search, _offsets, _partial}}
       ) do
    %{
      baseline_m: baseline,
      fixed_ambiguities_cycles: fixed_cycles,
      fixed_ambiguities_m: fixed_m,
      integer_status: integer_status,
      integer_ratio: integer_ratio,
      iterations: iterations,
      converged: converged?,
      status: status,
      code_rms_m: code_rms_m,
      phase_rms_m: phase_rms_m,
      weighted_rms_m: weighted_rms_m,
      n_observations: n_observations
    }
  end

  defp floats3({x, y, z}), do: {x * 1.0, y * 1.0, z * 1.0}

  defp maybe_floats3(nil), do: nil
  defp maybe_floats3(vec), do: floats3(vec)
end
