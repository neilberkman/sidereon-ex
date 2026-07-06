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

defmodule Sidereon.Estimation.TrackState do
  @moduledoc """
  Track state and covariance over `[position, velocity]`.
  """

  @enforce_keys [
    :frame,
    :t_s,
    :position_m,
    :velocity_m_s,
    :covariance,
    :state_vector,
    :position_covariance_m2,
    :dimension,
    :state_dimension
  ]
  defstruct [
    :frame,
    :t_s,
    :position_m,
    :velocity_m_s,
    :covariance,
    :state_vector,
    :position_covariance_m2,
    :dimension,
    :state_dimension
  ]

  @type frame :: :ecef | :enu | :caller_defined_cartesian
  @type t :: %__MODULE__{
          frame: frame(),
          t_s: float(),
          position_m: [float()],
          velocity_m_s: [float()],
          covariance: [[float()]],
          state_vector: [float()],
          position_covariance_m2: [[float()]],
          dimension: pos_integer(),
          state_dimension: pos_integer()
        }
end

defmodule Sidereon.Estimation.TrackPrediction do
  @moduledoc """
  Result of one constant-velocity track prediction.
  """

  alias Sidereon.Estimation.TrackState

  @enforce_keys [:dt_s, :transition, :process_noise, :predicted]
  defstruct [:dt_s, :transition, :process_noise, :predicted]

  @type t :: %__MODULE__{
          dt_s: float(),
          transition: [[float()]],
          process_noise: [[float()]],
          predicted: TrackState.t()
        }
end

defmodule Sidereon.Estimation.TrackInnovation do
  @moduledoc """
  Measurement residual, residual covariance, and NIS for a track update.
  """

  @enforce_keys [:innovation, :innovation_covariance, :nis]
  defstruct [:innovation, :innovation_covariance, :nis]

  @type t :: %__MODULE__{
          innovation: [float()],
          innovation_covariance: [[float()]],
          nis: float()
        }
end

defmodule Sidereon.Estimation.TrackUpdate do
  @moduledoc """
  Applied track update with predicted and updated states.
  """

  alias Sidereon.Estimation.TrackInnovation
  alias Sidereon.Estimation.TrackState

  @enforce_keys [:predicted, :updated, :innovation, :kalman_gain]
  defstruct [:predicted, :updated, :innovation, :kalman_gain]

  @type t :: %__MODULE__{
          predicted: TrackState.t(),
          updated: TrackState.t(),
          innovation: TrackInnovation.t(),
          kalman_gain: [[float()]]
        }
end

defmodule Sidereon.Estimation.TrackGatedUpdate do
  @moduledoc """
  NIS-gated track update result.
  """

  alias Sidereon.Estimation.NisGate
  alias Sidereon.Estimation.TrackState
  alias Sidereon.Estimation.TrackUpdate

  @enforce_keys [:gate, :update, :state]
  defstruct [:gate, :update, :state]

  @type t :: %__MODULE__{
          gate: NisGate.t(),
          update: TrackUpdate.t() | nil,
          state: TrackState.t()
        }
end

defmodule Sidereon.Estimation.TrackRtsEpoch do
  @moduledoc """
  One recorded forward-filter epoch for RTS smoothing.
  """

  alias Sidereon.Estimation.TrackState

  @enforce_keys [:t_s, :predicted, :updated, :transition_from_previous]
  defstruct [:t_s, :predicted, :updated, :transition_from_previous]

  @type t :: %__MODULE__{
          t_s: float(),
          predicted: TrackState.t(),
          updated: TrackState.t(),
          transition_from_previous: [[float()]] | nil
        }
end

defmodule Sidereon.Estimation.SmoothedTrackEpoch do
  @moduledoc """
  One fixed-interval smoothed track epoch.
  """

  alias Sidereon.Estimation.TrackState

  @enforce_keys [:t_s, :state, :rts_gain_to_next]
  defstruct [:t_s, :state, :rts_gain_to_next]

  @type t :: %__MODULE__{
          t_s: float(),
          state: TrackState.t(),
          rts_gain_to_next: [[float()]] | nil
        }
end

defmodule Sidereon.Estimation.TrackFilterConfig do
  @moduledoc """
  Configuration for a no-IMU constant-velocity track filter.

  ## Example

      alias Sidereon.Estimation.{TrackFilter, TrackFilterConfig}

      {:ok, config} =
        TrackFilterConfig.from_position(
          :ecef,
          0.0,
          [1.0, 2.0, 3.0],
          [[25.0, 0.0, 0.0], [0.0, 25.0, 0.0], [0.0, 0.0, 25.0]],
          100.0,
          0.05
        )

      {:ok, filter} = TrackFilter.new(config)
      {:ok, _prediction} = TrackFilter.predict(filter, 1.0)
      {:ok, update} =
        TrackFilter.update_position(
          filter,
          [1.5, 2.0, 3.0],
          [[9.0, 0.0, 0.0], [0.0, 9.0, 0.0], [0.0, 0.0, 9.0]]
        )

      update.updated.position_m
  """

  alias Sidereon.Estimation.TrackState
  alias Sidereon.Estimation.TrackTerms
  alias Sidereon.NIF

  @enforce_keys [
    :frame,
    :initial_t_s,
    :initial_position_m,
    :initial_velocity_m_s,
    :initial_covariance,
    :acceleration_variance_spectral_density_m2_s3,
    :dimension
  ]
  defstruct [
    :frame,
    :initial_t_s,
    :initial_position_m,
    :initial_velocity_m_s,
    :initial_covariance,
    :acceleration_variance_spectral_density_m2_s3,
    :dimension
  ]

  @type t :: %__MODULE__{
          frame: TrackState.frame(),
          initial_t_s: float(),
          initial_position_m: [float()],
          initial_velocity_m_s: [float()],
          initial_covariance: [[float()]],
          acceleration_variance_spectral_density_m2_s3: float(),
          dimension: pos_integer()
        }

  @doc """
  Build a config from position, velocity, full covariance, and acceleration PSD.
  """
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(opts) do
    case NIF.track_filter_config_new(TrackTerms.config_term(opts)) do
      {:ok, config} -> {:ok, TrackTerms.config_from_map(config)}
      {:error, _reason} = err -> err
    end
  rescue
    e in [ArgumentError, ArithmeticError, KeyError] -> {:error, e}
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Build a config from position, velocity, full covariance, and acceleration PSD.
  """
  @spec new(
          TrackState.frame(),
          number(),
          [number()] | tuple(),
          [number()] | tuple(),
          [[number()]],
          number()
        ) :: {:ok, t()} | {:error, term()}
  def new(frame, initial_t_s, initial_position_m, initial_velocity_m_s, initial_covariance, q_m2_s3) do
    new(%{
      frame: frame,
      initial_t_s: initial_t_s,
      initial_position_m: initial_position_m,
      initial_velocity_m_s: initial_velocity_m_s,
      initial_covariance: initial_covariance,
      acceleration_variance_spectral_density_m2_s3: q_m2_s3
    })
  end

  @doc """
  Build a config from a position fix and uncertain zero initial velocity.
  """
  @spec from_position(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def from_position(opts) do
    case NIF.track_filter_config_from_position(TrackTerms.position_config_term(opts)) do
      {:ok, config} -> {:ok, TrackTerms.config_from_map(config)}
      {:error, _reason} = err -> err
    end
  rescue
    e in [ArgumentError, ArithmeticError, KeyError] -> {:error, e}
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Build a config from a position fix and uncertain zero initial velocity.
  """
  @spec from_position(
          TrackState.frame(),
          number(),
          [number()] | tuple(),
          [[number()]],
          number(),
          number()
        ) :: {:ok, t()} | {:error, term()}
  def from_position(frame, initial_t_s, initial_position_m, position_covariance_m2, velocity_variance_m2_s2, q_m2_s3) do
    from_position(%{
      frame: frame,
      initial_t_s: initial_t_s,
      initial_position_m: initial_position_m,
      position_covariance_m2: position_covariance_m2,
      initial_velocity_variance_m2_s2: velocity_variance_m2_s2,
      acceleration_variance_spectral_density_m2_s3: q_m2_s3
    })
  end
end

defmodule Sidereon.Estimation.TrackFilter do
  @moduledoc """
  Stateful no-IMU constant-velocity track filter.

  The native handle is mutated by prediction and update calls. Each call returns
  the corresponding state, innovation, update, or gating report as Elixir
  structs.
  """

  alias Sidereon.Estimation.TrackFilterConfig
  alias Sidereon.Estimation.TrackGatedUpdate
  alias Sidereon.Estimation.TrackInnovation
  alias Sidereon.Estimation.TrackPrediction
  alias Sidereon.Estimation.TrackRtsHistoryBuilder
  alias Sidereon.Estimation.TrackState
  alias Sidereon.Estimation.TrackTerms
  alias Sidereon.Estimation.TrackUpdate
  alias Sidereon.NIF

  @enforce_keys [:handle]
  defstruct [:handle]

  @type t :: %__MODULE__{handle: reference()}

  @doc """
  Build a stateful track filter from a validated config.
  """
  @spec new(TrackFilterConfig.t()) :: {:ok, t()} | {:error, term()}
  def new(%TrackFilterConfig{} = config) do
    case NIF.track_filter_new(TrackTerms.config_term(config)) do
      {:ok, handle} when is_reference(handle) -> {:ok, %__MODULE__{handle: handle}}
      {:error, _reason} = err -> err
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Build a filter from a position fix and uncertain zero initial velocity.
  """
  @spec from_position(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def from_position(opts) do
    with {:ok, config} <- TrackFilterConfig.from_position(opts) do
      new(config)
    end
  end

  @doc """
  Return the current filter state.
  """
  @spec state(t()) :: {:ok, TrackState.t()} | {:error, term()}
  def state(%__MODULE__{handle: handle}) do
    case NIF.track_filter_state(handle) do
      {:ok, state} -> {:ok, TrackTerms.state_from_map(state)}
      {:error, _reason} = err -> err
    end
  end

  @doc """
  Return the position dimension.
  """
  @spec dimension(t()) :: {:ok, pos_integer()} | {:error, term()}
  def dimension(%__MODULE__{handle: handle}), do: NIF.track_filter_dimension(handle)

  @doc """
  Return the white acceleration variance spectral density in `m^2 / s^3`.
  """
  @spec acceleration_variance_spectral_density_m2_s3(t()) :: {:ok, float()} | {:error, term()}
  def acceleration_variance_spectral_density_m2_s3(%__MODULE__{handle: handle}) do
    NIF.track_filter_acceleration_variance_spectral_density_m2_s3(handle)
  end

  @doc """
  Predict the filter forward by `dt_s`.
  """
  @spec predict(t(), number()) :: {:ok, TrackPrediction.t()} | {:error, term()}
  def predict(%__MODULE__{handle: handle}, dt_s) do
    case NIF.track_filter_predict(handle, dt_s / 1.0) do
      {:ok, prediction} -> {:ok, TrackTerms.prediction_from_map(prediction)}
      {:error, _reason} = err -> err
    end
  end

  @doc """
  Predict forward and record the interval for RTS smoothing.
  """
  @spec predict_recorded(t(), number(), TrackRtsHistoryBuilder.t()) ::
          {:ok, TrackPrediction.t()} | {:error, term()}
  def predict_recorded(%__MODULE__{handle: handle}, dt_s, %TrackRtsHistoryBuilder{handle: history}) do
    case NIF.track_filter_predict_recorded(handle, dt_s / 1.0, history) do
      {:ok, prediction} -> {:ok, TrackTerms.prediction_from_map(prediction)}
      {:error, _reason} = err -> err
    end
  end

  @doc """
  Compute the position-only innovation without applying the observation.
  """
  @spec position_innovation(t(), [number()] | tuple(), [[number()]]) ::
          {:ok, TrackInnovation.t()} | {:error, term()}
  def position_innovation(%__MODULE__{handle: handle}, position_m, covariance_m2) do
    case NIF.track_filter_position_innovation(handle, TrackTerms.vector(position_m), TrackTerms.matrix(covariance_m2)) do
      {:ok, innovation} -> {:ok, TrackTerms.innovation_from_map(innovation)}
      {:error, _reason} = err -> err
    end
  end

  @doc """
  Compute the full state innovation without applying the observation.
  """
  @spec state_innovation(t(), [number()] | tuple(), [[number()]]) ::
          {:ok, TrackInnovation.t()} | {:error, term()}
  def state_innovation(%__MODULE__{handle: handle}, state, covariance) do
    case NIF.track_filter_state_innovation(handle, TrackTerms.vector(state), TrackTerms.matrix(covariance)) do
      {:ok, innovation} -> {:ok, TrackTerms.innovation_from_map(innovation)}
      {:error, _reason} = err -> err
    end
  end

  @doc """
  Apply a position-only observation with covariance weighting.
  """
  @spec update_position(t(), [number()] | tuple(), [[number()]]) ::
          {:ok, TrackUpdate.t()} | {:error, term()}
  def update_position(%__MODULE__{handle: handle}, position_m, covariance_m2) do
    case NIF.track_filter_update_position(handle, TrackTerms.vector(position_m), TrackTerms.matrix(covariance_m2)) do
      {:ok, update} -> {:ok, TrackTerms.update_from_map(update)}
      {:error, _reason} = err -> err
    end
  end

  @doc """
  Apply a position-and-velocity observation with covariance weighting.
  """
  @spec update_state(t(), [number()] | tuple(), [[number()]]) ::
          {:ok, TrackUpdate.t()} | {:error, term()}
  def update_state(%__MODULE__{handle: handle}, state, covariance) do
    case NIF.track_filter_update_state(handle, TrackTerms.vector(state), TrackTerms.matrix(covariance)) do
      {:ok, update} -> {:ok, TrackTerms.update_from_map(update)}
      {:error, _reason} = err -> err
    end
  end

  @doc """
  Apply a position-only observation only when it passes the NIS gate.
  """
  @spec update_position_gated(t(), [number()] | tuple(), [[number()]], number()) ::
          {:ok, TrackGatedUpdate.t()} | {:error, term()}
  def update_position_gated(%__MODULE__{handle: handle}, position_m, covariance_m2, confidence) do
    case NIF.track_filter_update_position_gated(
           handle,
           TrackTerms.vector(position_m),
           TrackTerms.matrix(covariance_m2),
           confidence / 1.0
         ) do
      {:ok, update} -> {:ok, TrackTerms.gated_update_from_map(update)}
      {:error, _reason} = err -> err
    end
  end

  @doc """
  Apply a position-only update and record the epoch for RTS smoothing.
  """
  @spec update_position_recorded(t(), [number()] | tuple(), [[number()]], TrackRtsHistoryBuilder.t()) ::
          {:ok, TrackUpdate.t()} | {:error, term()}
  def update_position_recorded(%__MODULE__{handle: handle}, position_m, covariance_m2, %TrackRtsHistoryBuilder{
        handle: history
      }) do
    case NIF.track_filter_update_position_recorded(
           handle,
           TrackTerms.vector(position_m),
           TrackTerms.matrix(covariance_m2),
           history
         ) do
      {:ok, update} -> {:ok, TrackTerms.update_from_map(update)}
      {:error, _reason} = err -> err
    end
  end

  @doc """
  Apply a gated position-only update and record accepted or rejected epochs.
  """
  @spec update_position_gated_recorded(t(), [number()] | tuple(), [[number()]], number(), TrackRtsHistoryBuilder.t()) ::
          {:ok, TrackGatedUpdate.t()} | {:error, term()}
  def update_position_gated_recorded(
        %__MODULE__{handle: handle},
        position_m,
        covariance_m2,
        confidence,
        %TrackRtsHistoryBuilder{handle: history}
      ) do
    case NIF.track_filter_update_position_gated_recorded(
           handle,
           TrackTerms.vector(position_m),
           TrackTerms.matrix(covariance_m2),
           confidence / 1.0,
           history
         ) do
      {:ok, update} -> {:ok, TrackTerms.gated_update_from_map(update)}
      {:error, _reason} = err -> err
    end
  end

  @doc """
  Record the current predicted state as an epoch without a measurement update.
  """
  @spec record_prediction_only(t(), TrackRtsHistoryBuilder.t()) :: :ok | {:error, term()}
  def record_prediction_only(%__MODULE__{handle: handle}, %TrackRtsHistoryBuilder{handle: history}) do
    case NIF.track_filter_record_prediction_only(handle, history) do
      {:ok, :ok} -> :ok
      {:error, _reason} = err -> err
    end
  end
end

defmodule Sidereon.Estimation.TrackRtsHistoryBuilder do
  @moduledoc """
  Builder for a forward track-filter pass that can be RTS-smoothed.
  """

  alias Sidereon.Estimation.TrackFilter
  alias Sidereon.Estimation.TrackRtsHistory
  alias Sidereon.NIF

  @enforce_keys [:handle]
  defstruct [:handle]

  @type t :: %__MODULE__{handle: reference()}

  @doc """
  Start an empty history builder.
  """
  @spec new() :: t()
  def new, do: %__MODULE__{handle: NIF.track_rts_history_builder_new()}

  @doc """
  Start a history builder from the current filter state.
  """
  @spec from_filter(TrackFilter.t()) :: {:ok, t()} | {:error, term()}
  def from_filter(%TrackFilter{handle: handle}) do
    case NIF.track_rts_history_builder_from_filter(handle) do
      {:ok, history} when is_reference(history) -> {:ok, %__MODULE__{handle: history}}
      {:error, _reason} = err -> err
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Finish the builder and return a smoothing-ready history.
  """
  @spec finish(t()) :: {:ok, TrackRtsHistory.t()} | {:error, term()}
  def finish(%__MODULE__{handle: handle}) do
    case NIF.track_rts_history_builder_finish(handle) do
      {:ok, history} when is_reference(history) -> {:ok, struct(TrackRtsHistory, handle: history)}
      {:error, _reason} = err -> err
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end
end

defmodule Sidereon.Estimation.TrackRtsHistory do
  @moduledoc """
  Recorded forward-filter history accepted by the RTS smoother.
  """

  alias Sidereon.Estimation.TrackRtsEpoch
  alias Sidereon.Estimation.TrackTerms
  alias Sidereon.NIF

  @enforce_keys [:handle]
  defstruct [:handle]

  @type t :: %__MODULE__{handle: reference()}

  @doc """
  Return the number of recorded epochs.
  """
  @spec epoch_count(t()) :: non_neg_integer()
  def epoch_count(%__MODULE__{handle: handle}), do: NIF.track_rts_history_epoch_count(handle)

  @doc """
  Return recorded epochs as Elixir structs.
  """
  @spec epochs(t()) :: [TrackRtsEpoch.t()]
  def epochs(%__MODULE__{handle: handle}) do
    handle
    |> NIF.track_rts_history_epochs()
    |> Enum.map(&TrackTerms.rts_epoch_from_map/1)
  end
end

defmodule Sidereon.Estimation.SmoothedTrack do
  @moduledoc """
  Fixed-interval RTS-smoothed track.
  """

  alias Sidereon.Estimation.SmoothedTrackEpoch
  alias Sidereon.Estimation.TrackTerms
  alias Sidereon.NIF

  @enforce_keys [:handle]
  defstruct [:handle]

  @type t :: %__MODULE__{handle: reference()}

  @doc """
  Return the number of smoothed epochs.
  """
  @spec epoch_count(t()) :: non_neg_integer()
  def epoch_count(%__MODULE__{handle: handle}), do: NIF.track_smoothed_epoch_count(handle)

  @doc """
  Return smoothed epochs as Elixir structs.
  """
  @spec epochs(t()) :: [SmoothedTrackEpoch.t()]
  def epochs(%__MODULE__{handle: handle}) do
    handle
    |> NIF.track_smoothed_epochs()
    |> Enum.map(&TrackTerms.smoothed_epoch_from_map/1)
  end
end

defmodule Sidereon.Estimation.TrackTerms do
  @moduledoc false

  alias Sidereon.Estimation.NisGate
  alias Sidereon.Estimation.SmoothedTrackEpoch
  alias Sidereon.Estimation.TrackFilterConfig
  alias Sidereon.Estimation.TrackGatedUpdate
  alias Sidereon.Estimation.TrackInnovation
  alias Sidereon.Estimation.TrackPrediction
  alias Sidereon.Estimation.TrackRtsEpoch
  alias Sidereon.Estimation.TrackState
  alias Sidereon.Estimation.TrackUpdate

  def config_from_map(map) do
    struct(TrackFilterConfig, %{
      frame: frame_atom(map.frame),
      initial_t_s: map.initial_t_s,
      initial_position_m: map.initial_position_m,
      initial_velocity_m_s: map.initial_velocity_m_s,
      initial_covariance: map.initial_covariance,
      acceleration_variance_spectral_density_m2_s3: map.acceleration_variance_spectral_density_m2_s3,
      dimension: map.dimension
    })
  end

  def config_term(%TrackFilterConfig{} = config) do
    %{
      frame: frame_label(config.frame),
      initial_t_s: config.initial_t_s / 1.0,
      initial_position_m: vector(config.initial_position_m),
      initial_velocity_m_s: vector(config.initial_velocity_m_s),
      initial_covariance: matrix(config.initial_covariance),
      acceleration_variance_spectral_density_m2_s3: config.acceleration_variance_spectral_density_m2_s3 / 1.0
    }
  end

  def config_term(opts) do
    %{
      frame: frame_label(field!(opts, :frame)),
      initial_t_s: field!(opts, :initial_t_s) / 1.0,
      initial_position_m: vector(field!(opts, :initial_position_m)),
      initial_velocity_m_s: vector(field!(opts, :initial_velocity_m_s)),
      initial_covariance: matrix(field!(opts, :initial_covariance)),
      acceleration_variance_spectral_density_m2_s3: field!(opts, :acceleration_variance_spectral_density_m2_s3) / 1.0
    }
  end

  def position_config_term(opts) do
    %{
      frame: frame_label(field!(opts, :frame)),
      initial_t_s: field!(opts, :initial_t_s) / 1.0,
      initial_position_m: vector(field!(opts, :initial_position_m)),
      position_covariance_m2: matrix(field!(opts, :position_covariance_m2)),
      initial_velocity_variance_m2_s2: field!(opts, :initial_velocity_variance_m2_s2) / 1.0,
      acceleration_variance_spectral_density_m2_s3: field!(opts, :acceleration_variance_spectral_density_m2_s3) / 1.0
    }
  end

  def state_from_map(map) do
    %TrackState{
      frame: frame_atom(map.frame),
      t_s: map.t_s,
      position_m: map.position_m,
      velocity_m_s: map.velocity_m_s,
      covariance: map.covariance,
      state_vector: map.state_vector,
      position_covariance_m2: map.position_covariance_m2,
      dimension: map.dimension,
      state_dimension: map.state_dimension
    }
  end

  def prediction_from_map(map) do
    %TrackPrediction{
      dt_s: map.dt_s,
      transition: map.transition,
      process_noise: map.process_noise,
      predicted: state_from_map(map.predicted)
    }
  end

  def innovation_from_map(map) do
    %TrackInnovation{
      innovation: map.innovation,
      innovation_covariance: map.innovation_covariance,
      nis: map.nis
    }
  end

  def update_from_map(map) do
    %TrackUpdate{
      predicted: state_from_map(map.predicted),
      updated: state_from_map(map.updated),
      innovation: innovation_from_map(map.innovation),
      kalman_gain: map.kalman_gain
    }
  end

  def gated_update_from_map(map) do
    %TrackGatedUpdate{
      gate: gate_from_map(map.gate),
      update: maybe_update(map.update),
      state: state_from_map(map.state)
    }
  end

  def rts_epoch_from_map(map) do
    %TrackRtsEpoch{
      t_s: map.t_s,
      predicted: state_from_map(map.predicted),
      updated: state_from_map(map.updated),
      transition_from_previous: map.transition_from_previous
    }
  end

  def smoothed_epoch_from_map(map) do
    %SmoothedTrackEpoch{
      t_s: map.t_s,
      state: state_from_map(map.state),
      rts_gain_to_next: map.rts_gain_to_next
    }
  end

  def vector(values) when is_tuple(values), do: values |> Tuple.to_list() |> vector()
  def vector(values) when is_list(values), do: Enum.map(values, &(&1 / 1.0))

  def matrix(rows) when is_list(rows), do: Enum.map(rows, &vector/1)

  def frame_label(:ecef), do: "ecef"
  def frame_label(:enu), do: "enu"
  def frame_label(:caller_defined_cartesian), do: "caller_defined_cartesian"
  def frame_label(value) when is_binary(value), do: value

  def frame_atom(:ecef), do: :ecef
  def frame_atom(:enu), do: :enu
  def frame_atom(:caller_defined_cartesian), do: :caller_defined_cartesian

  def frame_atom(value) when is_binary(value) do
    value
    |> String.replace("-", "_")
    |> String.replace("callerDefinedCartesian", "caller_defined_cartesian")
    |> case do
      "ecef" -> :ecef
      "enu" -> :enu
      "caller_defined_cartesian" -> :caller_defined_cartesian
      other -> raise ArgumentError, "invalid track frame #{inspect(other)}"
    end
  end

  defp gate_from_map(map) do
    %NisGate{nis: map.nis, threshold: map.threshold, in_gate: map.in_gate, dof: map.dof}
  end

  defp maybe_update(nil), do: nil
  defp maybe_update(map), do: update_from_map(map)

  defp field!(opts, key) when is_map(opts) do
    Map.fetch!(opts, key)
  end

  defp field!(opts, key) when is_list(opts) do
    Keyword.fetch!(opts, key)
  end
end

defmodule Sidereon.Estimation do
  @moduledoc """
  Scalar estimation and detection primitives.

  These functions delegate to `sidereon-core` estimation primitives. Inputs are
  plain scalar values; state units follow the caller's level unit and the
  supplied `dt`. Innovation variance is in squared measurement units, NIS gates
  use chi-square degrees of freedom, and CA-CFAR functions use the exponential
  cell-averaging model.
  """

  alias Sidereon.Estimation.AlphaBetaGains
  alias Sidereon.Estimation.AlphaBetaState
  alias Sidereon.Estimation.AlphaBetaStep
  alias Sidereon.Estimation.NisGate
  alias Sidereon.Estimation.ScalarKalmanGains
  alias Sidereon.Estimation.SmoothedTrack
  alias Sidereon.Estimation.TrackRtsHistory
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

  @doc """
  Apply a fixed-interval RTS smoother to a recorded no-IMU track history.
  """
  @spec smooth_track_rts(TrackRtsHistory.t()) :: {:ok, SmoothedTrack.t()} | {:error, term()}
  def smooth_track_rts(%TrackRtsHistory{handle: handle}) do
    case NIF.track_smooth_rts(handle) do
      {:ok, smoothed} when is_reference(smoothed) -> {:ok, %SmoothedTrack{handle: smoothed}}
      {:error, _reason} = err -> err
    end
  rescue
    e in ErlangError -> {:error, e.original}
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
