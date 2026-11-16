defmodule Sidereon.GNSS.PrecisePositioning.RAIM do
  @moduledoc "Snapshot RAIM residual tests and protection levels for precise positioning."
  alias Sidereon.GNSS.PrecisePositioning
  alias Sidereon.NIF

  defmodule Error do
    @moduledoc """
    A PPP RAIM refusal. `:unsupported_noncentrality` means the required bias
    exceeds the core limit; `:unsupported_dof` means residual degrees of freedom
    exceed its supported limit, with `:dof` and `:max` holding those values;
    `:numerical_protection_level` means the
    noncentral CDF could not be evaluated numerically.
    """
    @enforce_keys [:kind, :message]
    defstruct [:kind, :field, :reason, :message, :dof, :max]

    defimpl String.Chars, for: __MODULE__ do
      def to_string(error), do: error.message
    end
  end

  @doc "Return the core default RAIM configuration."
  def config do
    {pfa, pmd, sigma, threshold} = NIF.pp_raim_config_default()

    %{
      false_alarm_probability: pfa,
      missed_detection_probability: pmd,
      measurement_sigma_m: sigma,
      chi_square_threshold: threshold
    }
  end

  @doc "Run the global PPP RAIM test."
  def global_test(residuals, n_states, config \\ config()),
    do: call(&NIF.pp_raim_global/3, [residual_terms(residuals), n_states, config_term(config)])

  @doc "Run global RAIM with snapshot geometry and identification."
  def global_test_with_geometry(residuals, geometry, config \\ config()),
    do: call(&NIF.pp_raim_global_geometry/3, [residual_terms(residuals), geometry_terms(geometry), config_term(config)])

  @doc "Compute standardized per-satellite residual statistics."
  def per_satellite_statistics(residuals, geometry, config \\ config()) do
    case NIF.pp_raim_statistics(residual_terms(residuals), geometry_terms(geometry), config_term(config)) do
      {:ok, {rows, fault}} -> {:ok, %{statistics: Enum.map(rows, &decode_statistic/1), most_likely_fault: fault}}
      {:error, detail} -> {:error, decode_error(detail)}
    end
  end

  @doc "Compute Brown snapshot-RAIM fault protection levels; positive redundancy is required."
  def protection_levels(geometry, receiver, config \\ config()) do
    case NIF.pp_raim_protection(geometry_terms(geometry), receiver, config_term(config)) do
      {:ok, {hpl, vpl}} -> {:ok, %{hpl_m: hpl, vpl_m: vpl}}
      {:error, detail} -> {:error, decode_error(detail)}
    end
  end

  @doc "Compute weighted Brown snapshot-RAIM fault protection levels. Weights are inverse standard deviations."
  def protection_levels_with_weights(geometry, weights, receiver, config \\ config()) do
    protection_call(&NIF.pp_raim_protection_weighted/4, geometry, weights, receiver, config)
  end

  @doc "Compute weighted fault-free accuracy bounds; these are not fault protection levels."
  def fault_free_accuracy_bounds(geometry, weights, receiver, config \\ config()) do
    protection_call(&NIF.pp_raim_fault_free_accuracy/4, geometry, weights, receiver, config)
  end

  defp protection_call(fun, geometry, weights, receiver, config) do
    case fun.(geometry_terms(geometry), weights, receiver, config_term(config)) do
      {:ok, {hpl, vpl}} -> {:ok, %{hpl_m: hpl, vpl_m: vpl}}
      {:error, detail} -> {:error, decode_error(detail)}
    end
  end

  @doc "Run PPP FDE for one SP3-backed float epoch; `:untested` means there is no residual redundancy."
  def fde_float_epoch(sp3, observations, epoch, opts \\ [], config \\ config()) do
    solve_epoch(:fde_float_epoch, sp3, observations, epoch, opts, config)
  end

  @doc "Solve one SP3-backed float epoch with RAIM/FDE."
  def solve_float_epoch_with_raim(sp3, observations, epoch, opts \\ [], config \\ config()) do
    solve_epoch(:solve_float_epoch_with_raim, sp3, observations, epoch, opts, config)
  end

  defp solve_epoch(kind, sp3, observations, epoch, opts, config) do
    case PrecisePositioning.__raim_float_epoch__(kind, sp3, observations, epoch, opts, config_term(config)) do
      {:ok, result} -> {:ok, %{result | raim: decode_result(result.raim)}}
      {:error, {:raim, detail}} -> {:error, decode_error(detail)}
      error -> error
    end
  end

  defp call(fun, args) do
    case apply(fun, args) do
      {:ok, value} -> {:ok, decode_result(value)}
      {:error, detail} -> {:error, decode_error(detail)}
    end
  end

  defp decode_result({status, detected, statistic, threshold, redundancy, satellites, {fault, hpl, vpl}}),
    do: %{
      status: status_atom(status),
      detected: detected,
      test_statistic: statistic,
      threshold: threshold,
      redundancy: redundancy,
      satellite_statistics: Enum.map(satellites, &decode_statistic/1),
      most_likely_fault: fault,
      hpl_m: hpl,
      vpl_m: vpl
    }

  defp decode_statistic({sat, code, phase, statistic, code_testable, phase_testable}),
    do: %{
      satellite_id: sat,
      code: code,
      phase: phase,
      statistic: statistic,
      code_testable: code_testable,
      phase_testable: phase_testable
    }

  defp residual_terms(rows),
    do:
      Enum.map(rows, fn r ->
        {r.epoch_index, r.satellite_id, r.ambiguity_id, r.code_m / 1, r.phase_m / 1,
         {r.code_weight / 1, r.phase_weight / 1}}
      end)

  defp geometry_terms(rows), do: Enum.map(rows, fn r -> {r.satellite_id, r.line_of_sight} end)

  defp config_term(c),
    do:
      {c.false_alarm_probability / 1, c.missed_detection_probability / 1, c.measurement_sigma_m / 1,
       Map.get(c, :chi_square_threshold)}

  defp status_atom("passed"), do: :passed
  defp status_atom("fault_detected"), do: :fault_detected
  defp status_atom("not_enough_redundancy"), do: :not_enough_redundancy
  defp status_atom(status) when is_atom(status), do: status

  defp decode_error({kind, field, reason, message, limits}) do
    {dof, max} = limits || {nil, nil}
    %Error{kind: raim_kind(kind), field: field, reason: reason, message: message, dof: dof, max: max}
  end

  defp decode_error({kind, field, reason, message}),
    do: %Error{kind: raim_kind(kind), field: field, reason: reason, message: message}

  defp decode_error(message) when is_binary(message), do: %Error{kind: :invalid_input, message: message}
  defp raim_kind(kind) when is_atom(kind), do: kind
  defp raim_kind("invalid_config"), do: :invalid_config
  defp raim_kind("invalid_residual"), do: :invalid_residual
  defp raim_kind("invalid_geometry"), do: :invalid_geometry
  defp raim_kind("dop"), do: :dop
  defp raim_kind("numerical_protection_level"), do: :numerical_protection_level
  defp raim_kind("unsupported_noncentrality"), do: :unsupported_noncentrality
  defp raim_kind("unsupported_dof"), do: :unsupported_dof
  defp raim_kind("singular_geometry"), do: :singular_geometry
end
