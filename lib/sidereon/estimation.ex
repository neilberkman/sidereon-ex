defmodule Sidereon.Estimation.AlphaBetaState do
  @moduledoc """
  State of a scalar alpha-beta level and rate estimator.

  `:level` is the estimated scalar value and `:rate` is its time derivative in
  level units per second when `dt` is in seconds.
  """

  @enforce_keys [:level, :rate]
  defstruct [:level, :rate]

  @type t :: %__MODULE__{level: float(), rate: float()}
end

defmodule Sidereon.Estimation.AlphaBetaGains do
  @moduledoc """
  Alpha-beta gain set for one scalar channel.

  `:alpha` updates level directly. `:beta` updates rate as
  `beta * innovation / dt`.
  """

  @enforce_keys [:alpha, :beta]
  defstruct [:alpha, :beta]

  @type t :: %__MODULE__{alpha: float(), beta: float()}
end

defmodule Sidereon.Estimation.AlphaBetaStep do
  @moduledoc """
  Result of one alpha-beta predict and update step.

  `:predicted` is the prior projected by `dt`, `:updated` is the posterior after
  the measurement, and `:innovation` is `measurement - predicted.level`.
  """

  alias Sidereon.Estimation.AlphaBetaState

  @enforce_keys [:predicted, :updated, :innovation]
  defstruct [:predicted, :updated, :innovation]

  @type t :: %__MODULE__{
          predicted: AlphaBetaState.t(),
          updated: AlphaBetaState.t(),
          innovation: float()
        }
end

defmodule Sidereon.Estimation.ScalarKalmanGains do
  @moduledoc """
  Steady-state gains for a scalar constant-velocity Kalman filter.

  `:position_gain` is the measurement gain on the level state. `:rate_gain` has
  inverse-time units and satisfies `rate_gain * dt == beta` for the equivalent
  alpha-beta filter.
  """

  @enforce_keys [:position_gain, :rate_gain]
  defstruct [:position_gain, :rate_gain]

  @type t :: %__MODULE__{position_gain: float(), rate_gain: float()}
end

defmodule Sidereon.Estimation.NisGate do
  @moduledoc """
  Normalized innovation squared gate result.

  `:nis` is the statistic, `:threshold` is the chi-square threshold for the
  requested confidence and degrees of freedom, and `:in_gate` is true when
  `nis <= threshold`.
  """

  @enforce_keys [:nis, :threshold, :in_gate, :dof]
  defstruct [:nis, :threshold, :in_gate, :dof]

  @type t :: %__MODULE__{
          nis: float(),
          threshold: float(),
          in_gate: boolean(),
          dof: pos_integer()
        }
end

defmodule Sidereon.Estimation do
  @moduledoc """
  Scalar estimation and detection primitives.

  These functions delegate to `sidereon-core` 0.13 estimation primitives. Inputs
  are plain scalar values; state units follow the caller's level unit and the
  supplied `dt`. Innovation variance is in squared measurement units, NIS gates
  use chi-square degrees of freedom, and CA-CFAR functions use the exponential
  cell-averaging model.
  """

  alias Sidereon.Estimation.AlphaBetaGains
  alias Sidereon.Estimation.AlphaBetaState
  alias Sidereon.Estimation.AlphaBetaStep
  alias Sidereon.Estimation.NisGate
  alias Sidereon.Estimation.ScalarKalmanGains
  alias Sidereon.NIF

  @type primitive_error :: {:invalid_input, String.t(), String.t()}

  @doc """
  MAD Gaussian consistency factor `1 / Phi^-1(3/4)`.
  """
  @spec mad_gaussian_consistency() :: float()
  def mad_gaussian_consistency, do: NIF.estimation_mad_gaussian_consistency()

  @doc """
  Compute steady-state alpha-beta gains from a positive tracking index.
  """
  @spec alpha_beta_steady_state_gains(number()) :: {:ok, AlphaBetaGains.t()} | {:error, primitive_error()}
  def alpha_beta_steady_state_gains(tracking_index) do
    case NIF.estimation_alpha_beta_steady_state_gains(tracking_index / 1.0) do
      {:ok, tuple} -> {:ok, gains_from_tuple(tuple)}
      {:error, _} = err -> err
    end
  end

  @doc """
  Project an alpha-beta state by `dt` without applying a measurement.
  """
  @spec alpha_beta_predict(AlphaBetaState.t() | map(), number()) ::
          {:ok, AlphaBetaState.t()} | {:error, primitive_error() | :invalid_state}
  def alpha_beta_predict(state, dt) do
    with {:ok, tuple} <- state_tuple(state) do
      case NIF.estimation_alpha_beta_predict(tuple, dt / 1.0) do
        {:ok, state_tuple} -> {:ok, state_from_tuple(state_tuple)}
        {:error, _} = err -> err
      end
    end
  end

  @doc """
  Apply one scalar measurement to a predicted alpha-beta state.
  """
  @spec alpha_beta_apply_measurement(AlphaBetaState.t() | map(), number(), number(), AlphaBetaGains.t() | map()) ::
          {:ok, AlphaBetaState.t()} | {:error, primitive_error() | :invalid_state | :invalid_gains}
  def alpha_beta_apply_measurement(predicted, measurement, dt, gains) do
    with {:ok, state_tuple} <- state_tuple(predicted),
         {:ok, gains_tuple} <- gains_tuple(gains) do
      case NIF.estimation_alpha_beta_apply_measurement(state_tuple, measurement / 1.0, dt / 1.0, gains_tuple) do
        {:ok, updated_tuple} -> {:ok, state_from_tuple(updated_tuple)}
        {:error, _} = err -> err
      end
    end
  end

  @doc """
  Run one alpha-beta predict and measurement update step.
  """
  @spec alpha_beta_filter_step(AlphaBetaState.t() | map(), number(), number(), AlphaBetaGains.t() | map()) ::
          {:ok, AlphaBetaStep.t()} | {:error, primitive_error() | :invalid_state | :invalid_gains}
  def alpha_beta_filter_step(state, measurement, dt, gains) do
    with {:ok, state_tuple} <- state_tuple(state),
         {:ok, gains_tuple} <- gains_tuple(gains) do
      case NIF.estimation_alpha_beta_filter_step(state_tuple, measurement / 1.0, dt / 1.0, gains_tuple) do
        {:ok, {predicted, updated, innovation}} ->
          {:ok,
           %AlphaBetaStep{
             predicted: state_from_tuple(predicted),
             updated: state_from_tuple(updated),
             innovation: innovation
           }}

        {:error, _} = err ->
          err
      end
    end
  end

  @doc """
  Compute steady-state gains for the scalar constant-velocity Kalman model.

  `dt` is the sample interval in seconds and `measurement_variance` is in
  squared measurement units.
  """
  @spec kalman_cv_steady_state_gains(number(), number(), number()) ::
          {:ok, ScalarKalmanGains.t()} | {:error, primitive_error()}
  def kalman_cv_steady_state_gains(tracking_index, dt, measurement_variance) do
    case NIF.estimation_kalman_cv_steady_state_gains(
           tracking_index / 1.0,
           dt / 1.0,
           measurement_variance / 1.0
         ) do
      {:ok, {position_gain, rate_gain}} ->
        {:ok, %ScalarKalmanGains{position_gain: position_gain, rate_gain: rate_gain}}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Scalar normalized innovation `innovation / sqrt(innovation_variance)`.
  """
  @spec normalized_innovation(number(), number()) :: {:ok, float()} | {:error, primitive_error()}
  def normalized_innovation(innovation, innovation_variance) do
    NIF.estimation_normalized_innovation(innovation / 1.0, innovation_variance / 1.0)
  end

  @doc """
  Normalized innovation squared statistic.
  """
  @spec nis(number(), number()) :: {:ok, float()} | {:error, primitive_error()}
  def nis(innovation, innovation_variance) do
    NIF.estimation_nis(innovation / 1.0, innovation_variance / 1.0)
  end

  @doc """
  Expected NIS value for a positive number of degrees of freedom.
  """
  @spec nis_expected_value(pos_integer()) :: {:ok, float()} | {:error, primitive_error()}
  def nis_expected_value(dof), do: NIF.estimation_nis_expected_value(dof)

  @doc """
  Chi-square gate threshold for `dof` and confidence in `(0, 1)`.
  """
  @spec nis_gate_threshold(pos_integer(), number()) :: {:ok, float()} | {:error, primitive_error()}
  def nis_gate_threshold(dof, confidence), do: NIF.estimation_nis_gate_threshold(dof, confidence / 1.0)

  @doc """
  Test a scalar innovation against a chi-square NIS gate.
  """
  @spec nis_gate(number(), number(), pos_integer(), number()) :: {:ok, NisGate.t()} | {:error, primitive_error()}
  def nis_gate(innovation, innovation_variance, dof, confidence) do
    case NIF.estimation_nis_gate(innovation / 1.0, innovation_variance / 1.0, dof, confidence / 1.0) do
      {:ok, {nis, threshold, in_gate, dof}} ->
        {:ok, %NisGate{nis: nis, threshold: threshold, in_gate: in_gate, dof: dof}}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Median absolute deviation spread estimate with Gaussian consistency scaling.

  `scale_floor` is a non-negative lower bound on the returned spread.
  """
  @spec mad([number()], number()) :: {:ok, float()} | {:error, primitive_error()}
  def mad(values, scale_floor \\ 0.0) when is_list(values) do
    NIF.estimation_mad(Enum.map(values, &(&1 / 1.0)), scale_floor / 1.0)
  end

  @doc """
  Exponentially weighted moving average update.

  `alpha` must be in `[0, 1]`.
  """
  @spec ewma(number(), number(), number()) :: {:ok, float()} | {:error, primitive_error()}
  def ewma(previous, sample, alpha) do
    NIF.estimation_ewma(previous / 1.0, sample / 1.0, alpha / 1.0)
  end

  @doc """
  EWMA update with `alpha = 1 / 2^shift`.
  """
  @spec ewma_power_of_two(number(), number(), non_neg_integer()) :: {:ok, float()} | {:error, primitive_error()}
  def ewma_power_of_two(previous, sample, shift) do
    NIF.estimation_ewma_power_of_two(previous / 1.0, sample / 1.0, shift)
  end

  @doc """
  CA-CFAR threshold multiplier from searched-cell count and target false-alarm probability.
  """
  @spec cfar_ca_multiplier_from_pfa(pos_integer(), number()) :: {:ok, float()} | {:error, primitive_error()}
  def cfar_ca_multiplier_from_pfa(searched_cells, false_alarm_probability) do
    NIF.estimation_cfar_ca_multiplier_from_pfa(searched_cells, false_alarm_probability / 1.0)
  end

  @doc """
  CA-CFAR false-alarm probability from searched-cell count and multiplier.
  """
  @spec cfar_ca_pfa_from_multiplier(pos_integer(), number()) :: {:ok, float()} | {:error, primitive_error()}
  def cfar_ca_pfa_from_multiplier(searched_cells, multiplier) do
    NIF.estimation_cfar_ca_pfa_from_multiplier(searched_cells, multiplier / 1.0)
  end

  @doc """
  CA-CFAR absolute threshold from searched cells, target false-alarm probability, and noise level.
  """
  @spec cfar_ca_threshold(pos_integer(), number(), number()) :: {:ok, float()} | {:error, primitive_error()}
  def cfar_ca_threshold(searched_cells, false_alarm_probability, noise_level) do
    NIF.estimation_cfar_ca_threshold(searched_cells, false_alarm_probability / 1.0, noise_level / 1.0)
  end

  @doc """
  CA-CFAR false-alarm probability from absolute threshold and noise level.
  """
  @spec cfar_ca_false_alarm_probability(pos_integer(), number(), number()) ::
          {:ok, float()} | {:error, primitive_error()}
  def cfar_ca_false_alarm_probability(searched_cells, threshold, noise_level) do
    NIF.estimation_cfar_ca_false_alarm_probability(searched_cells, threshold / 1.0, noise_level / 1.0)
  end

  defp state_tuple(%AlphaBetaState{level: level, rate: rate}) when is_number(level) and is_number(rate) do
    {:ok, {level / 1.0, rate / 1.0}}
  end

  defp state_tuple(%{level: level, rate: rate}) when is_number(level) and is_number(rate) do
    {:ok, {level / 1.0, rate / 1.0}}
  end

  defp state_tuple(_state), do: {:error, :invalid_state}

  defp gains_tuple(%AlphaBetaGains{alpha: alpha, beta: beta}) when is_number(alpha) and is_number(beta) do
    {:ok, {alpha / 1.0, beta / 1.0}}
  end

  defp gains_tuple(%{alpha: alpha, beta: beta}) when is_number(alpha) and is_number(beta) do
    {:ok, {alpha / 1.0, beta / 1.0}}
  end

  defp gains_tuple(_gains), do: {:error, :invalid_gains}

  defp state_from_tuple({level, rate}), do: %AlphaBetaState{level: level, rate: rate}

  defp gains_from_tuple({alpha, beta}), do: %AlphaBetaGains{alpha: alpha, beta: beta}
end
