defmodule Sidereon.GNSS.QC do
  @moduledoc """
  Measurement-quality control for single-point positioning.

  The numerical modeling and FDE orchestration live in the
  `sidereon-core` Rust core. This module keeps the Elixir API shape,
  normalizes options and epochs for the NIF, maps errors, and decodes the
  unchanged public result maps.
  """

  alias Sidereon.Constants
  alias Sidereon.GNSS.Broadcast
  alias Sidereon.GNSS.Positioning
  alias Sidereon.GNSS.Positioning.Decode
  alias Sidereon.GNSS.Positioning.Solution
  alias Sidereon.GNSS.SP3
  alias Sidereon.GNSS.Time
  alias Sidereon.NIF

  @default_a 0.3
  @default_b 0.3
  @default_p_fa 1.0e-3

  @default_initial_guess {0.0, 0.0, 0.0, 0.0}
  @default_alpha {0.0, 0.0, 0.0, 0.0}
  @default_beta {0.0, 0.0, 0.0, 0.0}
  # Standard-atmosphere surface meteorology fallback, sourced from the single
  # binding home `Sidereon.Constants` (mirrors
  # `sidereon_core::positioning::SurfaceMet::default()`, drift-tested against
  # `Sidereon.NIF.core_defaults/0`) so it cannot diverge from the core.
  @default_pressure_hpa Constants.surface_met_pressure_hpa()
  @default_temperature_k Constants.surface_met_temperature_k()
  @default_relative_humidity Constants.surface_met_relative_humidity()

  @typedoc "A `{satellite_id, elevation_deg}` or `{satellite_id, elevation_deg, cn0_dbhz}` entry."
  @type weight_entry ::
          {String.t(), number()} | {String.t(), number(), number()}

  @typedoc """
  The result of `raim/2`.
  """
  @type raim_result :: %{
          fault_detected?: boolean(),
          test_statistic: float(),
          threshold: float() | nil,
          dof: integer(),
          testable?: boolean(),
          normalized_residuals: %{String.t() => float()},
          worst_sat: String.t() | nil
        }

  @doc """
  Pseudorange measurement variance (m^2) from satellite elevation.

  Returns a float, `{:error, :invalid_elevation}` for elevations at or below the
  horizon, or `{:error, :missing_cn0}` when `model: :elevation_cn0` is selected
  without `:cn0`.
  """
  @spec pseudorange_variance(number(), keyword()) ::
          float() | {:error, :invalid_elevation | :missing_cn0}
  def pseudorange_variance(elevation_deg, opts \\ [])

  def pseudorange_variance(elevation_deg, _opts) when elevation_deg <= 0, do: {:error, :invalid_elevation}

  def pseudorange_variance(elevation_deg, opts) do
    {a, b, model, cn0, scale} = variance_args(opts)

    case NIF.qc_pseudorange_variance(elevation_deg / 1.0, a, b, model, cn0, scale) do
      {:ok, value} -> value
      {:error, :invalid_elevation} -> {:error, :invalid_elevation}
      {:error, :missing_cn0} -> {:error, :missing_cn0}
    end
  end

  @doc """
  Build a `satellite => sigma_m` map for a list of weight entries.
  """
  @spec sigmas([weight_entry()], keyword()) :: %{String.t() => float()}
  def sigmas(entries, opts \\ []) when is_list(entries) do
    {a, b, model, cn0, scale} = variance_args(opts)

    entries
    |> Enum.map(&encode_weight_entry/1)
    |> NIF.qc_sigmas(a, b, model, cn0, scale)
    |> Map.new()
  end

  @doc """
  Build a `satellite => inverse_variance_weight` map for a list of weight entries.
  """
  @spec weight_vector([weight_entry()], keyword()) :: %{String.t() => float()}
  def weight_vector(entries, opts \\ []) when is_list(entries) do
    {a, b, model, cn0, scale} = variance_args(opts)

    entries
    |> Enum.map(&encode_weight_entry/1)
    |> NIF.qc_weight_vector(a, b, model, cn0, scale)
    |> Map.new()
  end

  @doc """
  Residual-based RAIM: a chi-square goodness-of-fit test on a positioning solution.
  """
  @spec raim(Solution.t(), keyword()) :: raim_result()
  def raim(%Solution{} = solution, opts \\ []) do
    p_fa = Keyword.get(opts, :p_fa, @default_p_fa)
    weights_opt = Keyword.get(opts, :weights, :unit)

    validate_p_fa!(p_fa)
    validate_weights!(weights_opt)

    unit_weights? = weights_opt == :unit
    weights = if unit_weights?, do: [], else: string_weight_pairs(weights_opt)
    n_systems = n_systems_arg(Keyword.get(opts, :n_systems))

    case NIF.qc_raim(
           solution.used_sats,
           solution.residuals_m,
           p_fa / 1.0,
           unit_weights?,
           weights,
           n_systems
         ) do
      {:ok, result} -> decode_raim_result(result)
      {:error, :invalid_probability} -> raise_chi2_error!(1.0 - p_fa, nil)
      {:error, :invalid_weight} -> raise_weights_error!(weights_opt)
    end
  end

  @doc """
  Standalone range RAIM/FDE over a caller-supplied linearized measurement set,
  independent of any full positioning solve.

  Each row of `rows` is a map describing one linearized range measurement:

    * `:id` - stable measurement identifier (e.g. a satellite token `"G01"`)
    * `:residual_m` - observed-minus-computed range residual, metres
    * `:design_row` - the measurement's row of the design matrix (a list of the
      partials of the predicted range with respect to each estimated state
      parameter); every row must carry the same length
    * `:weight` - inverse-variance weight `1 / sigma^2`, strictly positive

  Options:

    * `:p_fa` - false-alarm probability for the global chi-square test
      (default `#{@default_p_fa}`)
    * `:max_exclusions` - maximum measurements the exclusion loop may remove
      (default: the row count)
    * `:min_redundancy` - minimum redundancy an exclusion must leave behind
      (default `1`)

  Returns `{:ok, result}` where `result` carries the protected
  `:state_correction`, `:state_covariance`, the `:global_test` chi-square map,
  the `:excluded` ids, per-measurement `:diagnostics`, and the exclusion
  `:iterations`; or `{:error, reason}` for a malformed or rank-deficient input.
  """
  @spec raim_fde_design([map()], keyword()) :: {:ok, map()} | {:error, term()}
  def raim_fde_design(rows, opts \\ []) when is_list(rows) do
    p_fa = Keyword.get(opts, :p_fa, @default_p_fa)
    max_exclusions = Keyword.get(opts, :max_exclusions, length(rows))
    min_redundancy = Keyword.get(opts, :min_redundancy, 1)

    case NIF.qc_raim_fde_design(
           Enum.map(rows, &normalize_fde_row/1),
           p_fa / 1.0,
           max_exclusions,
           min_redundancy
         ) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Fault detection and exclusion: solve, run RAIM, exclude the worst satellite,
  and repeat until the measurement set is self-consistent or the exclusion
  budget is exhausted.

  Malformed FDE options are returned as tagged errors, including
  `{:invalid_option, :p_fa}`, `{:invalid_option, :weights}`, and
  `{:invalid_option, :max_iterations}`.
  """
  @spec fde(term(), [Positioning.observation()], Positioning.epoch(), keyword()) ::
          {:ok,
           %{
             solution: Solution.t(),
             excluded: [{String.t(), :raim_excluded}],
             iterations: non_neg_integer()
           }}
          | {:error, {:fault_unresolved, float()}}
          | {:error, term()}
  def fde(source, observations, epoch, opts \\ [])

  def fde(%SP3{handle: handle}, observations, epoch, opts) when is_list(observations) do
    fde_impl(:sp3, handle, observations, epoch, opts)
  end

  def fde(%Broadcast{handle: handle}, observations, epoch, opts) when is_list(observations) do
    fde_impl(:broadcast, handle, observations, epoch, opts)
  end

  @doc """
  Chi-square inverse CDF (quantile).
  """
  @spec chi2_inv(float(), pos_integer()) :: float()
  def chi2_inv(p, k) when is_number(p) and p > 0.0 and p < 1.0 and is_integer(k) and k >= 1 do
    case NIF.qc_chi2_inv(p / 1.0, k) do
      {:ok, value} -> value
      {:error, _reason} -> raise_chi2_error!(p, k)
    end
  end

  def chi2_inv(p, k), do: raise_chi2_error!(p, k)

  defp variance_args(opts) do
    a = Keyword.get(opts, :a, @default_a) / 1.0
    b = Keyword.get(opts, :b, @default_b) / 1.0

    model =
      case Keyword.get(opts, :model, :elevation) do
        :elevation -> "elevation"
        :elevation_cn0 -> "elevation_cn0"
      end

    cn0 =
      case Keyword.get(opts, :cn0) do
        nil -> nil
        value -> value / 1.0
      end

    scale = Keyword.get(opts, :cn0_scale, 1.0) / 1.0
    {a, b, model, cn0, scale}
  end

  defp encode_weight_entry({sat, el}) do
    %{satellite_id: sat, elevation_deg: el / 1.0, cn0: nil}
  end

  defp encode_weight_entry({sat, el, cn0}) do
    %{satellite_id: sat, elevation_deg: el / 1.0, cn0: cn0 / 1.0}
  end

  defp decode_raim_result({fault_detected?, test_statistic, threshold, dof, testable?, normalized, worst_sat}) do
    %{
      fault_detected?: fault_detected?,
      test_statistic: test_statistic,
      threshold: threshold,
      dof: dof,
      testable?: testable?,
      normalized_residuals: Map.new(normalized),
      worst_sat: worst_sat
    }
  end

  defp validate_p_fa!(p) do
    case validate_p_fa(p) do
      :ok ->
        :ok

      {:error, {:invalid_option, :p_fa}} ->
        raise ArgumentError,
              "raim :p_fa must be a number strictly between 0 and 1, got: #{inspect(p)}"
    end
  end

  defp validate_p_fa(p) when is_number(p) and p > 0.0 and p < 1.0 and 1.0 - p < 1.0, do: :ok

  defp validate_p_fa(_p), do: {:error, {:invalid_option, :p_fa}}

  defp validate_weights!(weights) do
    case validate_weights(weights) do
      :ok ->
        :ok

      {:error, {:invalid_option, :weights}} when is_map(weights) ->
        raise_weights_error!(weights)

      {:error, {:invalid_option, :weights}} ->
        raise ArgumentError,
              "raim :weights must be :unit or a %{sat => weight} map, got: #{inspect(weights)}"
    end
  end

  defp validate_weights(:unit), do: :ok

  defp validate_weights(weights) when is_map(weights) do
    if Enum.all?(weights, fn {sat, w} -> is_binary(sat) and is_number(w) and w > 0.0 end) do
      :ok
    else
      {:error, {:invalid_option, :weights}}
    end
  end

  defp validate_weights(_other), do: {:error, {:invalid_option, :weights}}

  defp raise_weights_error!(weights) do
    raise ArgumentError, "raim :weights must all be positive numbers, got: #{inspect(weights)}"
  end

  defp raise_chi2_error!(p, k) do
    raise ArgumentError,
          "chi2_inv probability must be strictly between 0 and 1 and dof must be a positive integer, got p=#{inspect(p)}, dof=#{inspect(k)}"
  end

  defp string_weight_pairs(weights) do
    for {sat, weight} <- weights, is_binary(sat), do: {sat, weight / 1.0}
  end

  defp n_systems_arg(nil), do: nil
  defp n_systems_arg(false), do: nil
  defp n_systems_arg(value), do: value

  defp normalize_fde_row(%{id: id, residual_m: residual_m, design_row: design_row, weight: weight})
       when is_binary(id) and is_list(design_row) do
    %{
      id: id,
      residual_m: residual_m / 1.0,
      design_row: Enum.map(design_row, &(&1 / 1.0)),
      weight: weight / 1.0
    }
  end

  defp fde_impl(source, handle, observations, epoch, opts) do
    huber? = Keyword.get(opts, :huber, false)

    cond do
      huber? == true ->
        {:error, {:incompatible_options, [:robust, :huber]}}

      not is_boolean(huber?) ->
        {:error, {:invalid_option, :huber}}

      true ->
        run_core_fde(source, handle, observations, epoch, opts)
    end
  end

  defp run_core_fde(source, handle, observations, epoch, opts) do
    p_fa = Keyword.get(opts, :p_fa, @default_p_fa)
    weights_opt = Keyword.get(opts, :weights, :unit)

    with :ok <- validate_p_fa(p_fa),
         :ok <- validate_weights(weights_opt),
         :ok <- validate_max_pdop(Keyword.get(opts, :max_pdop)),
         {:ok, max_iterations} <- max_iterations_arg(observations, opts),
         {:ok, args} <- fde_common_args(observations, epoch, opts) do
      unit_weights? = weights_opt == :unit
      weights = if unit_weights?, do: [], else: string_weight_pairs(weights_opt)
      n_systems = n_systems_arg(Keyword.get(opts, :n_systems))
      max_pdop = Keyword.get(opts, :max_pdop)

      nif_fun =
        case source do
          :sp3 -> :qc_fde_sp3
          :broadcast -> :qc_fde_broadcast
        end

      result =
        apply(
          NIF,
          nif_fun,
          [handle | args] ++
            [p_fa / 1.0, unit_weights?, weights, n_systems, max_iterations, max_pdop]
        )

      decode_fde_result(result)
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  defp validate_max_pdop(nil), do: :ok
  defp validate_max_pdop(value) when is_number(value) and value > 0.0, do: :ok
  defp validate_max_pdop(_value), do: {:error, {:invalid_option, :max_pdop}}

  defp fde_common_args(observations, epoch, opts) do
    with {:ok, t_rx_j2000_s} <- Time.epoch_to_j2000_seconds_fractional(epoch) do
      sod = Time.second_of_day(epoch)
      doy = Time.day_of_year(epoch)

      obs = Enum.map(observations, fn {sat, pr} -> {sat, pr / 1.0} end)

      {:ok,
       [
         obs,
         t_rx_j2000_s,
         sod,
         doy,
         to_tuple4(Keyword.get(opts, :initial_guess, @default_initial_guess)),
         Keyword.get(opts, :ionosphere, false),
         Keyword.get(opts, :troposphere, false),
         to_tuple4(Keyword.get(opts, :klobuchar_alpha, @default_alpha)),
         to_tuple4(Keyword.get(opts, :klobuchar_beta, @default_beta)),
         Keyword.get(opts, :pressure_hpa, @default_pressure_hpa) / 1.0,
         Keyword.get(opts, :temperature_k, @default_temperature_k) / 1.0,
         Keyword.get(opts, :relative_humidity, @default_relative_humidity) / 1.0,
         Keyword.get(opts, :with_geodetic, true)
       ]}
    end
  end

  defp max_iterations_arg(observations, opts) do
    case Keyword.get(opts, :max_iterations, max(length(observations) - 4, 0)) do
      n when is_integer(n) and n >= 0 -> {:ok, n}
      _other -> {:error, {:invalid_option, :max_iterations}}
    end
  end

  defp decode_fde_result({:ok, {solution_raw, excluded, iterations}}) do
    case Decode.decode(solution_raw) do
      {:ok, solution} -> {:ok, %{solution: solution, excluded: excluded, iterations: iterations}}
      {:error, _reason} = error -> error
    end
  end

  defp decode_fde_result({:error, :invalid_probability}), do: {:error, {:invalid_option, :p_fa}}

  defp decode_fde_result({:error, :invalid_weight}), do: {:error, {:invalid_option, :weights}}
  defp decode_fde_result({:error, reason}), do: {:error, reason}

  defp to_tuple4({_a, _b, _c, _d} = t), do: t

  defp to_tuple4([a, b, c, d]), do: {a / 1.0, b / 1.0, c / 1.0, d / 1.0}
end
