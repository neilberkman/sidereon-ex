defmodule Sidereon.GNSS.Fusion do
  @moduledoc """
  Stateful GNSS/INS fusion filters.

  The filter is an opaque native resource. Calls mutate the native filter and
  return snapshots, update reports, or versioned state bytes.
  """

  alias Sidereon.GNSS.Broadcast
  alias Sidereon.GNSS.Fusion
  alias Sidereon.GNSS.SP3
  alias Sidereon.NIF

  defmodule Filter do
    @moduledoc """
    Opaque native GNSS/INS fusion filter handle.
    """

    @enforce_keys [:handle]
    defstruct [:handle]

    @typedoc "Stateful fusion filter resource."
    @type t :: %__MODULE__{handle: reference()}
  end

  defmodule ImuSample do
    @moduledoc """
    IMU rate or increment sample accepted by the fusion propagator.
    """

    @enforce_keys [:t_j2000_s, :kind]
    defstruct [
      :t_j2000_s,
      :kind,
      :specific_force_mps2,
      :angular_rate_rps,
      :delta_velocity_mps,
      :delta_theta_rad,
      :dt_s
    ]

    @type t :: %__MODULE__{
            t_j2000_s: number(),
            kind: :rate | :increment,
            specific_force_mps2: Fusion.vec3() | nil,
            angular_rate_rps: Fusion.vec3() | nil,
            delta_velocity_mps: Fusion.vec3() | nil,
            delta_theta_rad: Fusion.vec3() | nil,
            dt_s: number() | nil
          }

    @doc """
    Build an IMU rate sample.
    """
    @spec rate(number(), Fusion.vec3(), Fusion.vec3()) :: t()
    def rate(t_j2000_s, specific_force_mps2, angular_rate_rps) do
      %__MODULE__{
        t_j2000_s: t_j2000_s,
        kind: :rate,
        specific_force_mps2: specific_force_mps2,
        angular_rate_rps: angular_rate_rps
      }
    end

    @doc """
    Build an IMU increment sample.
    """
    @spec increment(number(), Fusion.vec3(), Fusion.vec3(), number()) :: t()
    def increment(t_j2000_s, delta_velocity_mps, delta_theta_rad, dt_s) do
      %__MODULE__{
        t_j2000_s: t_j2000_s,
        kind: :increment,
        delta_velocity_mps: delta_velocity_mps,
        delta_theta_rad: delta_theta_rad,
        dt_s: dt_s
      }
    end
  end

  defmodule GnssFixMeasurement do
    @moduledoc """
    GNSS PVT measurement used by loose-coupled fusion updates.
    """

    @enforce_keys [:t_j2000_s, :position_ecef_m, :covariance]
    defstruct [
      :t_j2000_s,
      :position_ecef_m,
      :velocity_ecef_mps,
      :covariance,
      satellites_used: 4,
      solution_valid: true,
      fix_status: :single
    ]

    @type t :: %__MODULE__{
            t_j2000_s: number(),
            position_ecef_m: Fusion.vec3(),
            velocity_ecef_mps: Fusion.vec3() | nil,
            covariance: [[number()]],
            satellites_used: non_neg_integer(),
            solution_valid: boolean(),
            fix_status: :single | :float | :fixed | String.t()
          }

    @doc """
    Build a position-only GNSS fix measurement.
    """
    @spec position(number(), Fusion.vec3(), [[number()]], non_neg_integer(), keyword()) :: t()
    def position(t_j2000_s, position_ecef_m, position_covariance_m2, satellites_used, opts \\ []) do
      %__MODULE__{
        t_j2000_s: t_j2000_s,
        position_ecef_m: position_ecef_m,
        covariance: position_covariance_m2,
        satellites_used: satellites_used,
        solution_valid: Keyword.get(opts, :solution_valid, true),
        fix_status: Keyword.get(opts, :fix_status, :single)
      }
    end

    @doc """
    Build a position-velocity GNSS fix measurement.
    """
    @spec position_velocity(
            number(),
            Fusion.vec3(),
            Fusion.vec3(),
            [[number()]],
            non_neg_integer(),
            keyword()
          ) :: t()
    def position_velocity(t_j2000_s, position_ecef_m, velocity_ecef_mps, covariance, satellites_used, opts \\ []) do
      %__MODULE__{
        t_j2000_s: t_j2000_s,
        position_ecef_m: position_ecef_m,
        velocity_ecef_mps: velocity_ecef_mps,
        covariance: covariance,
        satellites_used: satellites_used,
        solution_valid: Keyword.get(opts, :solution_valid, true),
        fix_status: Keyword.get(opts, :fix_status, :single)
      }
    end

    @doc """
    Return the measurement with a different GNSS fix status.
    """
    @spec with_fix_status(t(), :single | :float | :fixed | String.t()) :: t()
    def with_fix_status(%__MODULE__{} = measurement, fix_status), do: %{measurement | fix_status: fix_status}
  end

  defmodule TightRangeRateObservation do
    @moduledoc """
    Doppler-derived range-rate row for one satellite in a tight update.
    """

    @enforce_keys [:measured_range_rate_m_s, :sigma_m_s]
    defstruct [:measured_range_rate_m_s, :sigma_m_s, satellite_clock_drift_m_s: 0.0]

    @type t :: %__MODULE__{
            measured_range_rate_m_s: number(),
            sigma_m_s: number(),
            satellite_clock_drift_m_s: number()
          }

    @doc """
    Build a tight range-rate observation row.
    """
    @spec new(number(), number(), number()) :: t()
    def new(measured_range_rate_m_s, sigma_m_s, satellite_clock_drift_m_s \\ 0.0) do
      %__MODULE__{
        measured_range_rate_m_s: measured_range_rate_m_s,
        sigma_m_s: sigma_m_s,
        satellite_clock_drift_m_s: satellite_clock_drift_m_s
      }
    end
  end

  defmodule TightCarrierPhaseObservation do
    @moduledoc """
    Carrier-phase range row with a caller-supplied float ambiguity.
    """

    @enforce_keys [:phase_range_m, :sigma_m, :float_ambiguity_m]
    defstruct [:phase_range_m, :sigma_m, :float_ambiguity_m]

    @type t :: %__MODULE__{
            phase_range_m: number(),
            sigma_m: number(),
            float_ambiguity_m: number()
          }

    @doc """
    Build a tight carrier-phase observation row.
    """
    @spec new(number(), number(), number()) :: t()
    def new(phase_range_m, sigma_m, float_ambiguity_m) do
      %__MODULE__{phase_range_m: phase_range_m, sigma_m: sigma_m, float_ambiguity_m: float_ambiguity_m}
    end
  end

  defmodule TightGnssObservation do
    @moduledoc """
    Raw GNSS observation for one satellite in a tight update.
    """

    @enforce_keys [:satellite_id, :pseudorange_m, :pseudorange_sigma_m]
    defstruct [
      :satellite_id,
      :pseudorange_m,
      :pseudorange_sigma_m,
      :range_rate,
      :carrier_phase,
      ionosphere_delay_m: 0.0,
      troposphere_delay_m: 0.0
    ]

    @type t :: %__MODULE__{
            satellite_id: String.t(),
            pseudorange_m: number(),
            pseudorange_sigma_m: number(),
            range_rate: TightRangeRateObservation.t() | map() | nil,
            carrier_phase: TightCarrierPhaseObservation.t() | map() | nil,
            ionosphere_delay_m: number(),
            troposphere_delay_m: number()
          }

    @doc """
    Build a tight GNSS observation.
    """
    @spec new(String.t(), number(), number(), keyword()) :: t()
    def new(satellite_id, pseudorange_m, pseudorange_sigma_m, opts \\ []) do
      %__MODULE__{
        satellite_id: satellite_id,
        pseudorange_m: pseudorange_m,
        pseudorange_sigma_m: pseudorange_sigma_m,
        range_rate: Keyword.get(opts, :range_rate),
        carrier_phase: Keyword.get(opts, :carrier_phase),
        ionosphere_delay_m: Keyword.get(opts, :ionosphere_delay_m, 0.0),
        troposphere_delay_m: Keyword.get(opts, :troposphere_delay_m, 0.0)
      }
    end
  end

  defmodule TightGnssEpoch do
    @moduledoc """
    One receiver epoch of raw GNSS observations for a tight update.
    """

    @enforce_keys [:t_j2000_s, :observations]
    defstruct [:t_j2000_s, :observations]

    @type t :: %__MODULE__{
            t_j2000_s: number(),
            observations: [TightGnssObservation.t() | map()]
          }

    @doc """
    Build a tight GNSS observation epoch.
    """
    @spec new(number(), [TightGnssObservation.t() | map()]) :: t()
    def new(t_j2000_s, observations), do: %__MODULE__{t_j2000_s: t_j2000_s, observations: observations}

    @doc """
    Return the number of observations in the epoch.
    """
    @spec observation_count(t()) :: non_neg_integer()
    def observation_count(%__MODULE__{observations: observations}), do: length(observations)
  end

  defmodule TimeSyncHistoryConfig do
    @moduledoc """
    Retained-history limits for bounded-latency time synchronization.
    """

    defstruct imu_capacity: 256, checkpoint_capacity: 64

    @type t :: %__MODULE__{
            imu_capacity: pos_integer(),
            checkpoint_capacity: pos_integer()
          }

    @doc """
    Build time-sync retained-history limits.
    """
    @spec new(pos_integer(), pos_integer()) :: t()
    def new(imu_capacity \\ 256, checkpoint_capacity \\ 64) do
      %__MODULE__{imu_capacity: imu_capacity, checkpoint_capacity: checkpoint_capacity}
    end
  end

  defmodule VelocityMatchState do
    @moduledoc """
    One position and velocity sample used by outage velocity matching.
    """

    @enforce_keys [:t_j2000_s, :position_ecef_m, :velocity_ecef_mps]
    defstruct [:t_j2000_s, :position_ecef_m, :velocity_ecef_mps]

    @type t :: %__MODULE__{
            t_j2000_s: number(),
            position_ecef_m: Fusion.vec3(),
            velocity_ecef_mps: Fusion.vec3()
          }

    @doc """
    Build a velocity-match outage state.
    """
    @spec new(number(), Fusion.vec3(), Fusion.vec3()) :: t()
    def new(t_j2000_s, position_ecef_m, velocity_ecef_mps) do
      %__MODULE__{t_j2000_s: t_j2000_s, position_ecef_m: position_ecef_m, velocity_ecef_mps: velocity_ecef_mps}
    end
  end

  defmodule VelocityMatchingConfig do
    @moduledoc """
    Endpoint velocity matching settings for one GNSS outage.
    """

    @enforce_keys [:max_outage_duration_s]
    defstruct [:max_outage_duration_s]

    @type t :: %__MODULE__{max_outage_duration_s: number()}

    @doc """
    Build velocity-matching settings.
    """
    @spec new(number()) :: t()
    def new(max_outage_duration_s), do: %__MODULE__{max_outage_duration_s: max_outage_duration_s}
  end

  defmodule FusionRtsEpoch do
    @moduledoc """
    One recorded GNSS/INS fusion epoch for RTS smoothing.
    """

    @enforce_keys [:t_j2000_s, :predicted, :updated, :transition_from_previous]
    defstruct [:t_j2000_s, :predicted, :updated, :transition_from_previous]

    @type t :: %__MODULE__{
            t_j2000_s: float(),
            predicted: map(),
            updated: map(),
            transition_from_previous: [[float()]] | nil
          }
  end

  defmodule FusionRtsHistory do
    @moduledoc """
    Recorded forward-pass history accepted by the fusion RTS smoother.
    """

    alias Sidereon.GNSS.Fusion.FusionRtsEpoch
    alias Sidereon.NIF

    @enforce_keys [:handle]
    defstruct [:handle]

    @type t :: %__MODULE__{handle: reference()}

    @doc """
    Return the number of recorded epochs.
    """
    @spec epoch_count(t()) :: non_neg_integer()
    def epoch_count(%__MODULE__{handle: handle}), do: NIF.fusion_rts_history_epoch_count(handle)

    @doc """
    Return recorded epochs as structs.
    """
    @spec epochs(t()) :: [FusionRtsEpoch.t()]
    def epochs(%__MODULE__{handle: handle}) do
      handle
      |> NIF.fusion_rts_history_epochs()
      |> Enum.map(&struct(FusionRtsEpoch, &1))
    end
  end

  defmodule FusionRtsHistoryBuilder do
    @moduledoc """
    Builder for a recorded GNSS/INS fusion forward pass.
    """

    alias Sidereon.GNSS.Fusion.Filter
    alias Sidereon.GNSS.Fusion.FusionRtsHistory
    alias Sidereon.NIF

    @enforce_keys [:handle]
    defstruct [:handle]

    @type t :: %__MODULE__{handle: reference()}

    @doc """
    Start an empty recorded history builder.
    """
    @spec new() :: t()
    def new, do: %__MODULE__{handle: NIF.fusion_rts_history_builder_new()}

    @doc """
    Start a recorded history from the filter's current checkpoint.
    """
    @spec from_filter(Filter.t()) :: {:ok, t()} | {:error, term()}
    def from_filter(%Filter{handle: handle}) do
      case NIF.fusion_rts_history_builder_from_filter(handle) do
        {:ok, history} when is_reference(history) -> {:ok, %__MODULE__{handle: history}}
        {:error, _reason} = err -> err
      end
    end

    @doc """
    Finish the builder and return a smoothing-ready history.
    """
    @spec finish(t()) :: {:ok, FusionRtsHistory.t()} | {:error, term()}
    def finish(%__MODULE__{handle: handle}) do
      case NIF.fusion_rts_history_builder_finish(handle) do
        {:ok, history} when is_reference(history) -> {:ok, %FusionRtsHistory{handle: history}}
        {:error, _reason} = err -> err
      end
    end
  end

  defmodule SmoothedFusionEpoch do
    @moduledoc """
    One fixed-interval smoothed GNSS/INS fusion epoch.
    """

    @enforce_keys [:t_j2000_s, :snapshot, :error_state_correction, :covariance, :rts_gain_to_next]
    defstruct [:t_j2000_s, :snapshot, :error_state_correction, :covariance, :rts_gain_to_next]

    @type t :: %__MODULE__{
            t_j2000_s: float(),
            snapshot: map(),
            error_state_correction: [float()],
            covariance: [[float()]],
            rts_gain_to_next: [[float()]] | nil
          }
  end

  defmodule SmoothedFusionTrajectory do
    @moduledoc """
    Fixed-interval RTS-smoothed GNSS/INS fusion trajectory.
    """

    alias Sidereon.GNSS.Fusion.SmoothedFusionEpoch
    alias Sidereon.NIF

    @enforce_keys [:handle]
    defstruct [:handle]

    @type t :: %__MODULE__{handle: reference()}

    @doc """
    Return the number of smoothed epochs.
    """
    @spec epoch_count(t()) :: non_neg_integer()
    def epoch_count(%__MODULE__{handle: handle}), do: NIF.fusion_smoothed_trajectory_epoch_count(handle)

    @doc """
    Return smoothed epochs as structs.
    """
    @spec epochs(t()) :: [SmoothedFusionEpoch.t()]
    def epochs(%__MODULE__{handle: handle}) do
      handle
      |> NIF.fusion_smoothed_trajectory_epochs()
      |> Enum.map(&struct(SmoothedFusionEpoch, &1))
    end
  end

  @typedoc "Three-vector in ECEF or body axes, depending on field name."
  @type vec3 :: {number(), number(), number()} | [number()]

  @typedoc "Three-by-three row-major matrix."
  @type mat3 :: [vec3()]

  @typedoc "Initial closed-loop INS state and covariance."
  @type filter_state :: map()

  @typedoc "IMU specification map accepted by `filter_config/2`."
  @type imu_spec :: map() | :mems | :tactical | :navigation

  @typedoc "Fusion filter configuration map."
  @type filter_config :: map()

  @typedoc "IMU sample accepted by `propagate/2`."
  @type imu_sample :: ImuSample.t() | map()

  @typedoc "Loose GNSS position or position-velocity fix."
  @type loose_measurement :: GnssFixMeasurement.t() | map()

  @typedoc "Tight GNSS raw-observation epoch."
  @type tight_epoch :: TightGnssEpoch.t() | map()

  @typedoc "One position and velocity sample used by outage velocity matching."
  @type velocity_match_state :: VelocityMatchState.t() | map()

  @doc """
  Return a strapdown mechanization config.

  The current core surface exposes `:off` coning correction.
  """
  @spec strapdown_config(keyword() | map()) :: map()
  def strapdown_config(opts \\ []) do
    %{coning_correction: field(opts, :coning_correction, :off)}
  end

  @doc """
  Return an IMU stochastic specification.

  Presets are `:mems`, `:tactical`, and `:navigation`. A map is passed through
  after numeric normalization.
  """
  @spec imu_spec(imu_spec()) :: map()
  def imu_spec(grade) when grade in [:mems, :tactical, :navigation] do
    case NIF.fusion_imu_spec_preset(Atom.to_string(grade)) do
      {:ok, spec} -> spec
      {:error, reason} -> raise ArgumentError, "invalid IMU preset #{inspect(grade)}: #{inspect(reason)}"
    end
  end

  def imu_spec(spec) when is_map(spec) or is_list(spec) do
    %{
      accel_vrw_mps_sqrt_s: field!(spec, :accel_vrw_mps_sqrt_s) / 1.0,
      gyro_arw_rad_sqrt_s: field!(spec, :gyro_arw_rad_sqrt_s) / 1.0,
      accel_bias_instab_mps2: field!(spec, :accel_bias_instab_mps2) / 1.0,
      gyro_bias_instab_rps: field!(spec, :gyro_bias_instab_rps) / 1.0,
      accel_bias_tau_s: tau_float(field!(spec, :accel_bias_tau_s)),
      gyro_bias_tau_s: tau_float(field!(spec, :gyro_bias_tau_s)),
      accel_scale_instab_ppm: optional_float(field(spec, :accel_scale_instab_ppm, nil)),
      gyro_scale_instab_ppm: optional_float(field(spec, :gyro_scale_instab_ppm, nil))
    }
  end

  @doc """
  Build a fusion filter config from an IMU spec and options.

  Options include `:filter_kind` (`:ekf` or `:ukf`), `:mechanization`,
  `:loose`, `:tight`, `:imu_model`, `:imu_to_body_dcm`, and
  `:ukf_update_options`. Loose config may include `:fix_status_weighting`,
  `:measurement_reweighting`, `:prediction_adaptation`, `:stationary_updates`,
  and `:non_holonomic`.
  """
  @spec filter_config(imu_spec(), keyword() | map()) :: filter_config()
  def filter_config(spec \\ :mems, opts \\ []) do
    %{
      imu_spec: imu_spec(spec),
      filter_kind: field(opts, :filter_kind, :ekf),
      imu_model: normalize_imu_model(field(opts, :imu_model, %{})),
      imu_to_body_dcm: mat3(field(opts, :imu_to_body_dcm, identity3())),
      mechanization: strapdown_config(field(opts, :mechanization, %{})),
      loose: normalize_loose_config(field(opts, :loose, %{})),
      tight: normalize_tight_config(field(opts, :tight, %{})),
      ukf_update_options: normalize_ukf_options(field(opts, :ukf_update_options, %{}))
    }
  end

  @doc """
  Return per-fix-status sigma multipliers for loose GNSS updates.
  """
  @spec gnss_fix_status_weighting(keyword() | map()) :: map()
  def gnss_fix_status_weighting(opts \\ []) do
    %{
      single_sigma_multiplier: field(opts, :single_sigma_multiplier, 1.0) / 1.0,
      float_sigma_multiplier: field(opts, :float_sigma_multiplier, 1.0) / 1.0,
      fixed_sigma_multiplier: field(opts, :fixed_sigma_multiplier, 1.0) / 1.0
    }
  end

  @doc """
  Return windowed IMU thresholds for stationary update detection.
  """
  @spec stationary_detector_config(keyword() | map()) :: map()
  def stationary_detector_config(opts) do
    %{
      window_len: field!(opts, :window_len),
      max_specific_force_norm_error_mps2: field!(opts, :max_specific_force_norm_error_mps2) / 1.0,
      max_body_rate_wrt_ecef_norm_rps: field!(opts, :max_body_rate_wrt_ecef_norm_rps) / 1.0
    }
  end

  @doc """
  Return zero-velocity and zero-angular-rate stationary update settings.
  """
  @spec stationary_update_config(keyword() | map()) :: map()
  def stationary_update_config(opts) do
    %{
      detector: stationary_detector_config(field!(opts, :detector)),
      zero_velocity_sigma_mps: field!(opts, :zero_velocity_sigma_mps) / 1.0,
      zero_angular_rate_sigma_rps: field!(opts, :zero_angular_rate_sigma_rps) / 1.0
    }
  end

  @doc """
  Return wheeled-vehicle lateral and vertical velocity constraint settings.
  """
  @spec non_holonomic_constraint_config(keyword() | map()) :: map()
  def non_holonomic_constraint_config(opts) do
    %{
      lateral_velocity_sigma_mps: field!(opts, :lateral_velocity_sigma_mps) / 1.0,
      vertical_velocity_sigma_mps: field!(opts, :vertical_velocity_sigma_mps) / 1.0,
      min_speed_mps: field!(opts, :min_speed_mps) / 1.0,
      max_body_rate_wrt_ecef_norm_rps: field!(opts, :max_body_rate_wrt_ecef_norm_rps) / 1.0
    }
  end

  @doc """
  Return endpoint velocity matching settings for one GNSS outage.
  """
  @spec velocity_matching_config(keyword() | map()) :: map()
  def velocity_matching_config(opts) do
    %{max_outage_duration_s: field!(opts, :max_outage_duration_s) / 1.0}
  end

  @doc """
  Return standard IGG-III measurement reweighting settings for loose updates.
  """
  @spec igg_iii_measurement_reweighting(keyword() | map()) :: map()
  def igg_iii_measurement_reweighting(opts \\ []) do
    %{k0_sigma: field(opts, :k0_sigma, 2.0) / 1.0, k1_sigma: field(opts, :k1_sigma, 5.0) / 1.0}
  end

  @doc """
  Return standard Yang predicted-covariance adaptation settings for loose updates.
  """
  @spec yang_prediction_adaptive_factor(keyword() | map()) :: map()
  def yang_prediction_adaptive_factor(opts \\ []) do
    %{
      threshold: field(opts, :threshold, 1.0) / 1.0,
      outlier_gate_probability: field(opts, :outlier_gate_probability, 0.99) / 1.0
    }
  end

  @doc """
  Build a new stateful filter.
  """
  @spec new(filter_state(), filter_config()) :: {:ok, Filter.t()} | {:error, term()}
  def new(state, config \\ filter_config()) do
    case NIF.fusion_new(state_term(state), config_term(config)) do
      {:ok, handle} when is_reference(handle) -> {:ok, %Filter{handle: handle}}
      {:error, _reason} = err -> err
    end
  end

  @doc """
  Alias for `new/2` matching the Python `InertialFilter.with_config` constructor.
  """
  @spec with_config(filter_state(), filter_config()) :: {:ok, Filter.t()} | {:error, term()}
  def with_config(state, config), do: new(state, config)

  @doc """
  Restore a new stateful filter from versioned fusion state bytes.
  """
  @spec from_state_bytes(binary(), filter_config()) :: {:ok, Filter.t()} | {:error, term()}
  def from_state_bytes(bytes, config \\ filter_config()) when is_binary(bytes) do
    case NIF.fusion_from_state_bytes(bytes, config_term(config)) do
      {:ok, handle} when is_reference(handle) -> {:ok, %Filter{handle: handle}}
      {:error, _reason} = err -> err
    end
  end

  @doc """
  Alias for `from_state_bytes/2` matching Python's encoded-state constructor.
  """
  @spec from_encoded_state(binary(), filter_config()) :: {:ok, Filter.t()} | {:error, term()}
  def from_encoded_state(bytes, config), do: from_state_bytes(bytes, config)

  @doc """
  Return the current closed-loop filter state.
  """
  @spec state(Filter.t()) :: {:ok, map()} | {:error, term()}
  def state(%Filter{handle: handle}), do: NIF.fusion_state(handle)

  @doc """
  Propagate the filter by one IMU sample.
  """
  @spec propagate(Filter.t(), imu_sample()) :: {:ok, map()} | {:error, term()}
  def propagate(%Filter{handle: handle}, sample), do: NIF.fusion_propagate(handle, imu_sample_term(sample))

  @doc """
  Propagate the filter by one IMU sample and record the transition for RTS smoothing.
  """
  @spec propagate_recorded(Filter.t(), imu_sample(), FusionRtsHistoryBuilder.t()) :: {:ok, map()} | {:error, term()}
  def propagate_recorded(%Filter{handle: handle}, sample, %FusionRtsHistoryBuilder{handle: history}) do
    NIF.fusion_propagate_recorded(handle, imu_sample_term(sample), history)
  end

  @doc """
  Apply a loose GNSS position or position-velocity fix at the current filter epoch.
  """
  @spec update_loose(Filter.t(), loose_measurement()) :: {:ok, map()} | {:error, term()}
  def update_loose(%Filter{handle: handle}, measurement) do
    NIF.fusion_update_loose(handle, loose_measurement_term(measurement))
  end

  @doc """
  Apply a loose GNSS fix and record before/after checkpoints for RTS smoothing.
  """
  @spec update_loose_recorded(Filter.t(), loose_measurement(), FusionRtsHistoryBuilder.t()) ::
          {:ok, map()} | {:error, term()}
  def update_loose_recorded(%Filter{handle: handle}, measurement, %FusionRtsHistoryBuilder{handle: history}) do
    NIF.fusion_update_loose_recorded(handle, loose_measurement_term(measurement), history)
  end

  @doc """
  Apply configured stationary zero-velocity and zero-angular-rate constraints.
  """
  @spec update_stationary(Filter.t()) :: {:ok, map() | nil} | {:error, term()}
  def update_stationary(%Filter{handle: handle}), do: NIF.fusion_update_stationary(handle)

  @doc """
  Apply configured stationary constraints and record checkpoints when applied.
  """
  @spec update_stationary_recorded(Filter.t(), FusionRtsHistoryBuilder.t()) ::
          {:ok, map() | nil} | {:error, term()}
  def update_stationary_recorded(%Filter{handle: handle}, %FusionRtsHistoryBuilder{handle: history}) do
    NIF.fusion_update_stationary_recorded(handle, history)
  end

  @doc """
  Apply configured non-holonomic vehicle constraints.
  """
  @spec update_non_holonomic(Filter.t()) :: {:ok, map() | nil} | {:error, term()}
  def update_non_holonomic(%Filter{handle: handle}), do: NIF.fusion_update_non_holonomic(handle)

  @doc """
  Apply configured non-holonomic constraints and record checkpoints when applied.
  """
  @spec update_non_holonomic_recorded(Filter.t(), FusionRtsHistoryBuilder.t()) ::
          {:ok, map() | nil} | {:error, term()}
  def update_non_holonomic_recorded(%Filter{handle: handle}, %FusionRtsHistoryBuilder{handle: history}) do
    NIF.fusion_update_non_holonomic_recorded(handle, history)
  end

  @doc """
  Apply a time-synchronized loose GNSS fix, replaying retained history if needed.
  """
  @spec update_loose_time_sync(Filter.t(), loose_measurement()) :: {:ok, map()} | {:error, term()}
  def update_loose_time_sync(%Filter{handle: handle}, measurement) do
    NIF.fusion_update_loose_time_sync(handle, loose_measurement_term(measurement))
  end

  @doc """
  Apply a tight raw GNSS epoch at the current filter epoch.

  The ephemeris source must be an existing SP3 or broadcast resource.
  """
  @spec update_tight(Filter.t(), SP3.t() | Broadcast.t(), tight_epoch()) :: {:ok, map()} | {:error, term()}
  def update_tight(%Filter{handle: handle}, %SP3{handle: source}, epoch) do
    NIF.fusion_update_tight_sp3(handle, source, tight_epoch_term(epoch))
  end

  def update_tight(%Filter{handle: handle}, %Broadcast{handle: source}, epoch) do
    NIF.fusion_update_tight_broadcast(handle, source, tight_epoch_term(epoch))
  end

  @doc """
  Apply a tight raw GNSS epoch and record before/after checkpoints for RTS smoothing.
  """
  @spec update_tight_recorded(Filter.t(), SP3.t() | Broadcast.t(), tight_epoch(), FusionRtsHistoryBuilder.t()) ::
          {:ok, map()} | {:error, term()}
  def update_tight_recorded(%Filter{handle: handle}, %SP3{handle: source}, epoch, %FusionRtsHistoryBuilder{
        handle: history
      }) do
    NIF.fusion_update_tight_recorded_sp3(handle, source, tight_epoch_term(epoch), history)
  end

  def update_tight_recorded(%Filter{handle: handle}, %Broadcast{handle: source}, epoch, %FusionRtsHistoryBuilder{
        handle: history
      }) do
    NIF.fusion_update_tight_recorded_broadcast(handle, source, tight_epoch_term(epoch), history)
  end

  @doc """
  Apply a time-synchronized tight raw GNSS epoch.
  """
  @spec update_tight_time_sync(Filter.t(), SP3.t() | Broadcast.t(), tight_epoch()) ::
          {:ok, map()} | {:error, term()}
  def update_tight_time_sync(%Filter{handle: handle}, %SP3{handle: source}, epoch) do
    NIF.fusion_update_tight_time_sync_sp3(handle, source, tight_epoch_term(epoch))
  end

  def update_tight_time_sync(%Filter{handle: handle}, %Broadcast{handle: source}, epoch) do
    NIF.fusion_update_tight_time_sync_broadcast(handle, source, tight_epoch_term(epoch))
  end

  @doc """
  Configure retained IMU samples and GNSS checkpoints for time synchronization.
  """
  @spec configure_time_sync(Filter.t(), keyword() | map()) :: {:ok, map()} | {:error, term()}
  def configure_time_sync(%Filter{handle: handle}, opts) do
    config = %{
      imu_capacity: field(opts, :imu_capacity, 256),
      checkpoint_capacity: field(opts, :checkpoint_capacity, 64)
    }

    NIF.fusion_configure_time_sync(handle, config)
  end

  @doc """
  Alias for `configure_time_sync/2` matching Python's retained-history name.
  """
  @spec configure_time_sync_history(Filter.t(), TimeSyncHistoryConfig.t() | keyword() | map()) ::
          {:ok, map()} | {:error, term()}
  def configure_time_sync_history(filter, config), do: configure_time_sync(filter, config)

  @doc """
  Return retained-history occupancy for time synchronization.
  """
  @spec time_sync_status(Filter.t()) :: {:ok, map()} | {:error, term()}
  def time_sync_status(%Filter{handle: handle}), do: NIF.fusion_time_sync_status(handle)

  @doc """
  Alias for `time_sync_status/1` matching Python's retained-history name.
  """
  @spec time_sync_history_status(Filter.t()) :: {:ok, map()} | {:error, term()}
  def time_sync_history_status(filter), do: time_sync_status(filter)

  @doc """
  Return the tight receiver-clock state.
  """
  @spec tight_clock_state(Filter.t()) :: {:ok, map()} | {:error, term()}
  def tight_clock_state(%Filter{handle: handle}), do: NIF.fusion_tight_clock_state(handle)

  @doc """
  Encode the current filter state and retained time-sync history as bytes.
  """
  @spec encode_state(Filter.t()) :: {:ok, binary()} | {:error, term()}
  def encode_state(%Filter{handle: handle}), do: NIF.fusion_encode_state(handle)

  @doc """
  Restore an existing filter from bytes produced by `encode_state/1`.
  """
  @spec restore_state(Filter.t(), binary()) :: {:ok, map()} | {:error, term()}
  def restore_state(%Filter{handle: handle}, bytes) when is_binary(bytes) do
    NIF.fusion_restore_state(handle, bytes)
  end

  @doc """
  Alias for `restore_state/2` matching Python's encoded-state restore method.
  """
  @spec restore_encoded_state(Filter.t(), binary()) :: {:ok, map()} | {:error, term()}
  def restore_encoded_state(filter, bytes), do: restore_state(filter, bytes)

  @doc """
  Apply fixed-interval RTS smoothing to recorded GNSS/INS fusion history.
  """
  @spec smooth_fusion_rts(FusionRtsHistory.t()) :: {:ok, SmoothedFusionTrajectory.t()} | {:error, term()}
  def smooth_fusion_rts(%FusionRtsHistory{handle: handle}) do
    case NIF.fusion_smooth_rts(handle) do
      {:ok, smoothed} when is_reference(smoothed) -> {:ok, %SmoothedFusionTrajectory{handle: smoothed}}
      {:error, _reason} = err -> err
    end
  end

  @doc """
  Blend a first good post-outage position/velocity fix back over an outage span.
  """
  @spec velocity_match_outage([velocity_match_state()], loose_measurement(), keyword() | map()) ::
          {:ok, map()} | {:error, term()}
  def velocity_match_outage(states, first_good_fix, config) when is_list(states) do
    NIF.fusion_velocity_match_outage(
      Enum.map(states, &velocity_match_state_term/1),
      loose_measurement_term(first_good_fix),
      velocity_matching_config(config)
    )
  end

  defp state_term(state) do
    nominal = field(state, :nominal, state)

    %{
      nominal: %{
        t_j2000_s: field!(nominal, :t_j2000_s) / 1.0,
        position_ecef_m: vec3(field!(nominal, :position_ecef_m)),
        velocity_ecef_mps: vec3(field!(nominal, :velocity_ecef_mps)),
        attitude_body_to_ecef: mat3(field(nominal, :attitude_body_to_ecef, identity3())),
        accel_bias_mps2: vec3(field(nominal, :accel_bias_mps2, {0.0, 0.0, 0.0})),
        gyro_bias_rps: vec3(field(nominal, :gyro_bias_rps, {0.0, 0.0, 0.0}))
      },
      layout: state |> field(:layout, :fifteen) |> label(),
      covariance: optional_matrix(field(state, :covariance, nil)),
      covariance_diagonal: optional_vector(field(state, :covariance_diagonal, nil)),
      accel_scale_factor: vec3(field(state, :accel_scale_factor, {0.0, 0.0, 0.0})),
      gyro_scale_factor: vec3(field(state, :gyro_scale_factor, {0.0, 0.0, 0.0}))
    }
  end

  defp config_term(config) do
    config =
      if has_field?(config, :imu_model) and has_field?(config, :imu_to_body_dcm) and has_field?(config, :loose) and
           has_field?(config, :tight) do
        config
      else
        filter_config(field(config, :imu_spec, :mems), config)
      end

    %{
      imu_spec: imu_spec_term(config.imu_spec),
      filter_kind: label(config.filter_kind),
      imu_model: imu_model_term(config.imu_model),
      imu_to_body_dcm: mat3(config.imu_to_body_dcm),
      mechanization: %{coning_correction: label(config.mechanization.coning_correction)},
      loose: loose_config_term(config.loose),
      tight: tight_config_term(config.tight),
      ukf_update_options: ukf_options_term(config.ukf_update_options)
    }
  end

  defp imu_spec_term(spec) do
    %{
      accel_vrw_mps_sqrt_s: spec.accel_vrw_mps_sqrt_s / 1.0,
      gyro_arw_rad_sqrt_s: spec.gyro_arw_rad_sqrt_s / 1.0,
      accel_bias_instab_mps2: spec.accel_bias_instab_mps2 / 1.0,
      gyro_bias_instab_rps: spec.gyro_bias_instab_rps / 1.0,
      accel_bias_tau_s: tau_float(spec.accel_bias_tau_s),
      gyro_bias_tau_s: tau_float(spec.gyro_bias_tau_s),
      accel_scale_instab_ppm: optional_float(spec.accel_scale_instab_ppm),
      gyro_scale_instab_ppm: optional_float(spec.gyro_scale_instab_ppm)
    }
  end

  defp normalize_imu_model(model) do
    %{
      bias: %{
        accel_mps2: vec3(field(model, :accel_mps2, field(model, :accel_bias_mps2, {0.0, 0.0, 0.0}))),
        gyro_rps: vec3(field(model, :gyro_rps, field(model, :gyro_bias_rps, {0.0, 0.0, 0.0})))
      },
      calibration: %{
        accel_scale_misalignment: mat3(field(model, :accel_scale_misalignment, zero3())),
        gyro_scale_misalignment: mat3(field(model, :gyro_scale_misalignment, zero3()))
      }
    }
  end

  defp imu_model_term(model) do
    %{
      bias: %{accel_mps2: vec3(model.bias.accel_mps2), gyro_rps: vec3(model.bias.gyro_rps)},
      calibration: %{
        accel_scale_misalignment: mat3(model.calibration.accel_scale_misalignment),
        gyro_scale_misalignment: mat3(model.calibration.gyro_scale_misalignment)
      }
    }
  end

  defp normalize_loose_config(config) do
    %{
      lever_arm_body_m: vec3(field(config, :lever_arm_body_m, {0.0, 0.0, 0.0})),
      update_options: normalize_ekf_options(field(config, :update_options, %{})),
      fix_status_weighting: normalize_fix_status_weighting(field(config, :fix_status_weighting, %{})),
      measurement_reweighting: normalize_igg_iii(field(config, :measurement_reweighting, nil)),
      prediction_adaptation: normalize_yang(field(config, :prediction_adaptation, nil)),
      stationary_updates: normalize_stationary_update(field(config, :stationary_updates, nil)),
      non_holonomic: normalize_non_holonomic(field(config, :non_holonomic, nil))
    }
  end

  defp normalize_tight_config(config) do
    %{
      lever_arm_body_m: vec3(field(config, :lever_arm_body_m, {0.0, 0.0, 0.0})),
      light_time: field(config, :light_time, true),
      sagnac: field(config, :sagnac, true),
      initial_clock_bias_variance_m2: field(config, :initial_clock_bias_variance_m2, 1.0e12) / 1.0,
      initial_clock_drift_variance_m2_s2: field(config, :initial_clock_drift_variance_m2_s2, 1.0e6) / 1.0,
      clock_bias_random_walk_m2_s: field(config, :clock_bias_random_walk_m2_s, 1.0) / 1.0,
      clock_drift_random_walk_m2_s3: field(config, :clock_drift_random_walk_m2_s3, 1.0e-2) / 1.0,
      update_options: normalize_ekf_options(field(config, :update_options, %{}))
    }
  end

  defp normalize_ekf_options(options) do
    %{
      innovation_gate:
        case field(options, :innovation_gate, nil) do
          nil -> nil
          gate -> %{threshold_sigma: field!(gate, :threshold_sigma) / 1.0, min_rows: field(gate, :min_rows, 1)}
        end
    }
  end

  defp normalize_ukf_options(options) do
    %{
      alpha: field(options, :alpha, 0.5) / 1.0,
      beta: field(options, :beta, 2.0) / 1.0,
      kappa: field(options, :kappa, 0.0) / 1.0,
      innovation_gate: normalize_ekf_options(options).innovation_gate
    }
  end

  defp loose_config_term(config) do
    %{
      lever_arm_body_m: vec3(config.lever_arm_body_m),
      update_options: ekf_options_term(config.update_options),
      fix_status_weighting: fix_status_weighting_term(config.fix_status_weighting),
      measurement_reweighting: optional_igg_iii(config.measurement_reweighting),
      prediction_adaptation: optional_yang(config.prediction_adaptation),
      stationary_updates: optional_stationary_update(config.stationary_updates),
      non_holonomic: optional_non_holonomic(config.non_holonomic)
    }
  end

  defp tight_config_term(config) do
    %{
      lever_arm_body_m: vec3(config.lever_arm_body_m),
      light_time: config.light_time,
      sagnac: config.sagnac,
      initial_clock_bias_variance_m2: config.initial_clock_bias_variance_m2 / 1.0,
      initial_clock_drift_variance_m2_s2: config.initial_clock_drift_variance_m2_s2 / 1.0,
      clock_bias_random_walk_m2_s: config.clock_bias_random_walk_m2_s / 1.0,
      clock_drift_random_walk_m2_s3: config.clock_drift_random_walk_m2_s3 / 1.0,
      update_options: ekf_options_term(config.update_options)
    }
  end

  defp ekf_options_term(options) do
    %{innovation_gate: options.innovation_gate}
  end

  defp ukf_options_term(options) do
    %{
      alpha: options.alpha / 1.0,
      beta: options.beta / 1.0,
      kappa: options.kappa / 1.0,
      innovation_gate: options.innovation_gate
    }
  end

  defp normalize_igg_iii(nil), do: nil
  defp normalize_igg_iii(:standard), do: igg_iii_measurement_reweighting()
  defp normalize_igg_iii(config), do: igg_iii_measurement_reweighting(config)

  defp normalize_yang(nil), do: nil
  defp normalize_yang(:standard), do: yang_prediction_adaptive_factor()
  defp normalize_yang(config), do: yang_prediction_adaptive_factor(config)

  defp normalize_fix_status_weighting(config), do: gnss_fix_status_weighting(config)

  defp normalize_stationary_update(nil), do: nil
  defp normalize_stationary_update(config), do: stationary_update_config(config)

  defp normalize_non_holonomic(nil), do: nil
  defp normalize_non_holonomic(config), do: non_holonomic_constraint_config(config)

  defp fix_status_weighting_term(config) do
    %{
      single_sigma_multiplier: config.single_sigma_multiplier / 1.0,
      float_sigma_multiplier: config.float_sigma_multiplier / 1.0,
      fixed_sigma_multiplier: config.fixed_sigma_multiplier / 1.0
    }
  end

  defp optional_igg_iii(nil), do: nil

  defp optional_igg_iii(config) do
    %{k0_sigma: config.k0_sigma / 1.0, k1_sigma: config.k1_sigma / 1.0}
  end

  defp optional_yang(nil), do: nil

  defp optional_yang(config) do
    %{
      threshold: config.threshold / 1.0,
      outlier_gate_probability: config.outlier_gate_probability / 1.0
    }
  end

  defp optional_stationary_update(nil), do: nil

  defp optional_stationary_update(config) do
    %{
      detector: %{
        window_len: config.detector.window_len,
        max_specific_force_norm_error_mps2: config.detector.max_specific_force_norm_error_mps2 / 1.0,
        max_body_rate_wrt_ecef_norm_rps: config.detector.max_body_rate_wrt_ecef_norm_rps / 1.0
      },
      zero_velocity_sigma_mps: config.zero_velocity_sigma_mps / 1.0,
      zero_angular_rate_sigma_rps: config.zero_angular_rate_sigma_rps / 1.0
    }
  end

  defp optional_non_holonomic(nil), do: nil

  defp optional_non_holonomic(config) do
    %{
      lateral_velocity_sigma_mps: config.lateral_velocity_sigma_mps / 1.0,
      vertical_velocity_sigma_mps: config.vertical_velocity_sigma_mps / 1.0,
      min_speed_mps: config.min_speed_mps / 1.0,
      max_body_rate_wrt_ecef_norm_rps: config.max_body_rate_wrt_ecef_norm_rps / 1.0
    }
  end

  defp imu_sample_term(sample) do
    kind = field!(sample, :kind)

    %{
      t_j2000_s: field!(sample, :t_j2000_s) / 1.0,
      kind: label(kind),
      specific_force_mps2: vec3(field(sample, :specific_force_mps2, {0.0, 0.0, 0.0})),
      angular_rate_rps: vec3(field(sample, :angular_rate_rps, {0.0, 0.0, 0.0})),
      delta_velocity_mps: vec3(field(sample, :delta_velocity_mps, {0.0, 0.0, 0.0})),
      delta_theta_rad: vec3(field(sample, :delta_theta_rad, {0.0, 0.0, 0.0})),
      dt_s: field(sample, :dt_s, 0.0) / 1.0
    }
  end

  defp loose_measurement_term(measurement) do
    %{
      t_j2000_s: field!(measurement, :t_j2000_s) / 1.0,
      position_ecef_m: vec3(field!(measurement, :position_ecef_m)),
      velocity_ecef_mps: optional_vec3(field(measurement, :velocity_ecef_mps, nil)),
      covariance: matrix(field!(measurement, :covariance)),
      satellites_used: field(measurement, :satellites_used, 4),
      solution_valid: field(measurement, :solution_valid, true),
      fix_status: measurement |> field(:fix_status, :single) |> label()
    }
  end

  defp velocity_match_state_term(state) do
    %{
      t_j2000_s: field!(state, :t_j2000_s) / 1.0,
      position_ecef_m: vec3(field!(state, :position_ecef_m)),
      velocity_ecef_mps: vec3(field!(state, :velocity_ecef_mps))
    }
  end

  defp tight_epoch_term(epoch) do
    %{
      t_j2000_s: field!(epoch, :t_j2000_s) / 1.0,
      observations: Enum.map(field!(epoch, :observations), &tight_observation_term/1)
    }
  end

  defp tight_observation_term(observation) do
    %{
      satellite_id: field!(observation, :satellite_id),
      pseudorange_m: field!(observation, :pseudorange_m) / 1.0,
      pseudorange_sigma_m: field!(observation, :pseudorange_sigma_m) / 1.0,
      range_rate: optional_range_rate(field(observation, :range_rate, nil)),
      carrier_phase: optional_carrier_phase(field(observation, :carrier_phase, nil)),
      ionosphere_delay_m: field(observation, :ionosphere_delay_m, 0.0) / 1.0,
      troposphere_delay_m: field(observation, :troposphere_delay_m, 0.0) / 1.0
    }
  end

  defp optional_range_rate(nil), do: nil

  defp optional_range_rate(range_rate) do
    %{
      measured_range_rate_m_s: field!(range_rate, :measured_range_rate_m_s) / 1.0,
      sigma_m_s: field!(range_rate, :sigma_m_s) / 1.0,
      satellite_clock_drift_m_s: field(range_rate, :satellite_clock_drift_m_s, 0.0) / 1.0
    }
  end

  defp optional_carrier_phase(nil), do: nil

  defp optional_carrier_phase(carrier_phase) do
    %{
      phase_range_m: field!(carrier_phase, :phase_range_m) / 1.0,
      sigma_m: field!(carrier_phase, :sigma_m) / 1.0,
      float_ambiguity_m: field(carrier_phase, :float_ambiguity_m, 0.0) / 1.0
    }
  end

  defp optional_float(nil), do: nil
  defp optional_float(value), do: value / 1.0
  defp tau_float(nil), do: nil
  defp tau_float(:infinity), do: nil
  defp tau_float("infinity"), do: nil
  defp tau_float(value), do: value / 1.0
  defp optional_vec3(nil), do: nil
  defp optional_vec3(value), do: vec3(value)
  defp optional_vector(nil), do: nil
  defp optional_vector(value), do: Enum.map(value, &(&1 / 1.0))
  defp optional_matrix(nil), do: nil
  defp optional_matrix(value), do: matrix(value)

  defp vec3({x, y, z}), do: [x / 1.0, y / 1.0, z / 1.0]
  defp vec3([x, y, z]), do: [x / 1.0, y / 1.0, z / 1.0]

  defp mat3(value), do: matrix(value)
  defp matrix(value), do: Enum.map(value, &row/1)
  defp row(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> row()
  defp row(list) when is_list(list), do: Enum.map(list, &(&1 / 1.0))

  defp identity3, do: [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]]
  defp zero3, do: [[0.0, 0.0, 0.0], [0.0, 0.0, 0.0], [0.0, 0.0, 0.0]]
  defp label(value) when is_atom(value), do: Atom.to_string(value)
  defp label(value) when is_binary(value), do: value

  defp has_field?(map, key), do: match?({:ok, _value}, fetch(map, key))

  defp field!(map, key) do
    case fetch(map, key) do
      {:ok, value} -> value
      :error -> raise KeyError, key: key, term: map
    end
  end

  defp field(map, key, default) do
    case fetch(map, key) do
      {:ok, value} -> value
      :error -> default
    end
  end

  defp fetch(map, key) when is_map(map) do
    Map.fetch(map, key)
    |> case do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(map, Atom.to_string(key))
    end
  end

  defp fetch(keyword, key) when is_list(keyword), do: Keyword.fetch(keyword, key)
end
