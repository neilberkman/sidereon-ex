//! Rustler boundary for stateful GNSS/INS fusion filters.
//!
//! This module owns an opaque `InertialFilter` resource and marshals public
//! Elixir maps into core filter state, IMU samples, loose fixes, tight raw GNSS
//! epochs, time-sync configuration, and versioned state bytes. All fusion
//! numerics remain in `sidereon_core::fusion` and `sidereon_core::inertial`.

use std::sync::Mutex;

use rustler::{Binary, Encoder, Env, OwnedBinary, ResourceArc, Term};
use sidereon_core::fusion::ekf::{
    EkfCorrectionReport, EkfUpdateOptions, InnovationGate, InnovationGateReport,
};
use sidereon_core::fusion::loose::{
    FusionUpdate, GnssFixMeasurement, IggIiiMeasurementReweighting, InertialFilter,
    InertialFilterConfig, LooseCouplingConfig, YangPredictionAdaptiveFactor,
};
use sidereon_core::fusion::smoother::{
    smooth_fusion_rts as core_smooth_fusion_rts, FusionRtsEpoch, FusionRtsHistory,
    FusionRtsHistoryBuilder, SmoothedFusionEpoch, SmoothedFusionTrajectory,
};
use sidereon_core::fusion::state::{
    ErrorStateLayout, FusionError, FusionFilterKind, InsFilterState,
};
use sidereon_core::fusion::tight::{
    TightCarrierPhaseObservation, TightClockState, TightCouplingConfig, TightFilterSnapshot,
    TightGnssEpoch, TightGnssObservation, TightRangeRateObservation,
};
use sidereon_core::fusion::timesync::{
    InertialFilterSnapshot, TimeSyncHistoryConfig, TimeSyncHistoryStatus, TimeSyncUpdate,
};
use sidereon_core::fusion::ukf::{UkfUpdateOptions, UnscentedTransformOptions};
use sidereon_core::fusion::{
    velocity_match_outage, GnssFixStatus, GnssFixStatusWeighting, NonHolonomicConstraintConfig,
    StationaryDetectorConfig, StationaryUpdateConfig, VelocityMatchState,
    VelocityMatchedTrajectory, VelocityMatchingConfig,
};
use sidereon_core::inertial::{
    ConingCorrection, ImuBias, ImuCalibration, ImuErrorModel, ImuGrade, ImuSample, ImuSpec,
    MechanizationConfig, NavState,
};
use sidereon_core::GnssSatelliteId;

use crate::broadcast::BroadcastResource;
use crate::sp3::Sp3Resource;

mod atoms {
    rustler::atoms! {
        ok,
        error,
        invalid_input,
        dimension_mismatch,
        singular_innovation,
        non_positive_semidefinite,
        non_positive_definite,
        nominal_state,
        poisoned_resource,
        codec
    }
}

type Vec3Term = Vec<f64>;
type MatrixTerm = Vec<Vec<f64>>;

struct FusionFilterResource {
    filter: Mutex<InertialFilter>,
}

#[rustler::resource_impl]
impl rustler::Resource for FusionFilterResource {}

struct FusionRtsHistoryBuilderResource {
    builder: Mutex<FusionRtsHistoryBuilder>,
}

#[rustler::resource_impl]
impl rustler::Resource for FusionRtsHistoryBuilderResource {}

struct FusionRtsHistoryResource {
    history: FusionRtsHistory,
}

#[rustler::resource_impl]
impl rustler::Resource for FusionRtsHistoryResource {}

struct SmoothedFusionTrajectoryResource {
    trajectory: SmoothedFusionTrajectory,
}

#[rustler::resource_impl]
impl rustler::Resource for SmoothedFusionTrajectoryResource {}

/// Return one built-in core IMU preset.
#[rustler::nif]
fn fusion_imu_spec_preset<'a>(env: Env<'a>, grade: String) -> Term<'a> {
    let grade = match grade.as_str() {
        "mems" => ImuGrade::Mems,
        "tactical" => ImuGrade::Tactical,
        "navigation" => ImuGrade::Navigation,
        _ => {
            return fusion_error(
                env,
                FusionError::InvalidInput {
                    field: "grade",
                    reason: "must be mems, tactical, or navigation",
                },
            )
        }
    };

    (atoms::ok(), encode_imu_spec(ImuSpec::preset(grade))).encode(env)
}

#[derive(Debug, Clone, rustler::NifMap)]
struct NavStateTerm {
    t_j2000_s: f64,
    position_ecef_m: Vec3Term,
    velocity_ecef_mps: Vec3Term,
    attitude_body_to_ecef: MatrixTerm,
    accel_bias_mps2: Vec3Term,
    gyro_bias_rps: Vec3Term,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct FilterStateTerm {
    nominal: NavStateTerm,
    layout: String,
    covariance: Option<MatrixTerm>,
    covariance_diagonal: Option<Vec<f64>>,
    accel_scale_factor: Vec3Term,
    gyro_scale_factor: Vec3Term,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct ImuSpecTerm {
    accel_vrw_mps_sqrt_s: f64,
    gyro_arw_rad_sqrt_s: f64,
    accel_bias_instab_mps2: f64,
    gyro_bias_instab_rps: f64,
    accel_bias_tau_s: Option<f64>,
    gyro_bias_tau_s: Option<f64>,
    accel_scale_instab_ppm: Option<f64>,
    gyro_scale_instab_ppm: Option<f64>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct ImuBiasTerm {
    accel_mps2: Vec3Term,
    gyro_rps: Vec3Term,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct ImuCalibrationTerm {
    accel_scale_misalignment: MatrixTerm,
    gyro_scale_misalignment: MatrixTerm,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct ImuModelTerm {
    bias: ImuBiasTerm,
    calibration: ImuCalibrationTerm,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct MechanizationTerm {
    coning_correction: String,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct InnovationGateTerm {
    threshold_sigma: f64,
    min_rows: u64,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct EkfOptionsTerm {
    innovation_gate: Option<InnovationGateTerm>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct IggIiiMeasurementReweightingTerm {
    k0_sigma: f64,
    k1_sigma: f64,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct YangPredictionAdaptiveFactorTerm {
    threshold: f64,
    outlier_gate_probability: f64,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct FixStatusWeightingTerm {
    single_sigma_multiplier: f64,
    float_sigma_multiplier: f64,
    fixed_sigma_multiplier: f64,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct StationaryDetectorTerm {
    window_len: u64,
    max_specific_force_norm_error_mps2: f64,
    max_body_rate_wrt_ecef_norm_rps: f64,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct StationaryUpdateTerm {
    detector: StationaryDetectorTerm,
    zero_velocity_sigma_mps: f64,
    zero_angular_rate_sigma_rps: f64,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct NonHolonomicTerm {
    lateral_velocity_sigma_mps: f64,
    vertical_velocity_sigma_mps: f64,
    min_speed_mps: f64,
    max_body_rate_wrt_ecef_norm_rps: f64,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct VelocityMatchingConfigTerm {
    max_outage_duration_s: f64,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct VelocityMatchStateTerm {
    t_j2000_s: f64,
    position_ecef_m: Vec3Term,
    velocity_ecef_mps: Vec3Term,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct LooseConfigTerm {
    lever_arm_body_m: Vec3Term,
    update_options: EkfOptionsTerm,
    fix_status_weighting: FixStatusWeightingTerm,
    measurement_reweighting: Option<IggIiiMeasurementReweightingTerm>,
    prediction_adaptation: Option<YangPredictionAdaptiveFactorTerm>,
    stationary_updates: Option<StationaryUpdateTerm>,
    non_holonomic: Option<NonHolonomicTerm>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct TightConfigTerm {
    lever_arm_body_m: Vec3Term,
    light_time: bool,
    sagnac: bool,
    initial_clock_bias_variance_m2: f64,
    initial_clock_drift_variance_m2_s2: f64,
    clock_bias_random_walk_m2_s: f64,
    clock_drift_random_walk_m2_s3: f64,
    update_options: EkfOptionsTerm,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct UkfOptionsTerm {
    alpha: f64,
    beta: f64,
    kappa: f64,
    innovation_gate: Option<InnovationGateTerm>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct FilterConfigTerm {
    imu_spec: ImuSpecTerm,
    filter_kind: String,
    imu_model: ImuModelTerm,
    imu_to_body_dcm: MatrixTerm,
    mechanization: MechanizationTerm,
    loose: LooseConfigTerm,
    tight: TightConfigTerm,
    ukf_update_options: UkfOptionsTerm,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct ImuSampleTerm {
    t_j2000_s: f64,
    kind: String,
    specific_force_mps2: Vec3Term,
    angular_rate_rps: Vec3Term,
    delta_velocity_mps: Vec3Term,
    delta_theta_rad: Vec3Term,
    dt_s: f64,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct LooseMeasurementTerm {
    t_j2000_s: f64,
    position_ecef_m: Vec3Term,
    velocity_ecef_mps: Option<Vec3Term>,
    covariance: MatrixTerm,
    satellites_used: u64,
    solution_valid: bool,
    fix_status: String,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct TightRangeRateTerm {
    measured_range_rate_m_s: f64,
    sigma_m_s: f64,
    satellite_clock_drift_m_s: f64,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct TightCarrierPhaseTerm {
    phase_range_m: f64,
    sigma_m: f64,
    float_ambiguity_m: f64,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct TightObservationTerm {
    satellite_id: String,
    pseudorange_m: f64,
    pseudorange_sigma_m: f64,
    range_rate: Option<TightRangeRateTerm>,
    carrier_phase: Option<TightCarrierPhaseTerm>,
    ionosphere_delay_m: f64,
    troposphere_delay_m: f64,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct TightEpochTerm {
    t_j2000_s: f64,
    observations: Vec<TightObservationTerm>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct TimeSyncConfigTerm {
    imu_capacity: u64,
    checkpoint_capacity: u64,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct NavStateOut {
    t_j2000_s: f64,
    position_ecef_m: Vec<f64>,
    velocity_ecef_mps: Vec<f64>,
    attitude_body_to_ecef: Vec<Vec<f64>>,
    accel_bias_mps2: Vec<f64>,
    gyro_bias_rps: Vec<f64>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct FilterStateOut {
    nominal: NavStateOut,
    layout: String,
    error_state: Vec<f64>,
    covariance: Vec<Vec<f64>>,
    accel_scale_factor: Vec<f64>,
    gyro_scale_factor: Vec<f64>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct TightFilterSnapshotOut {
    clock_bias_m: f64,
    clock_drift_m_s: f64,
    augmented_covariance: Vec<Vec<f64>>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct InertialFilterSnapshotOut {
    state: FilterStateOut,
    last_body_rate_wrt_ecef_rps: Vec<f64>,
    tight: TightFilterSnapshotOut,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct FusionRtsEpochOut {
    t_j2000_s: f64,
    predicted: InertialFilterSnapshotOut,
    updated: InertialFilterSnapshotOut,
    transition_from_previous: Option<Vec<Vec<f64>>>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct SmoothedFusionEpochOut {
    t_j2000_s: f64,
    snapshot: InertialFilterSnapshotOut,
    error_state_correction: Vec<f64>,
    covariance: Vec<Vec<f64>>,
    rts_gain_to_next: Option<Vec<Vec<f64>>>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct GateReportOut {
    threshold_sigma: f64,
    min_rows: u64,
    input_rows: u64,
    accepted_rows: u64,
    rejected_rows: u64,
    max_abs_normalized_innovation: Option<f64>,
    max_rejected_abs_normalized_innovation: Option<f64>,
    coasted: bool,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct EkfReportOut {
    applied: bool,
    normalized_innovation_squared: f64,
    accepted_rows: u64,
    rejected_rows: u64,
    innovation_gate: Option<GateReportOut>,
    innovation_covariance: Vec<Vec<f64>>,
    kalman_gain: Vec<Vec<f64>>,
    dx: Vec<f64>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct FusionUpdateOut {
    applied: bool,
    nis: f64,
    rows: u64,
    accepted_rows: u64,
    rejected_rows: u64,
    ekf: EkfReportOut,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct TimeSyncUpdateOut {
    update: FusionUpdateOut,
    late_measurement: bool,
    replayed_imu_segments: u64,
    restored_checkpoint_epoch_j2000_s: f64,
    current_epoch_j2000_s: f64,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct TimeSyncStatusOut {
    imu_capacity: u64,
    imu_len: u64,
    checkpoint_capacity: u64,
    checkpoint_len: u64,
    oldest_imu_epoch_j2000_s: Option<f64>,
    newest_imu_epoch_j2000_s: Option<f64>,
    oldest_checkpoint_epoch_j2000_s: Option<f64>,
    newest_checkpoint_epoch_j2000_s: Option<f64>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct TightClockStateOut {
    bias_m: f64,
    drift_m_s: f64,
    covariance: Vec<Vec<f64>>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct VelocityMatchedTrajectoryOut {
    states: Vec<VelocityMatchStateTerm>,
    endpoint_position_correction_ecef_m: Vec<f64>,
    endpoint_velocity_correction_ecef_mps: Vec<f64>,
}

/// Build an opaque stateful inertial fusion filter.
#[rustler::nif(schedule = "DirtyCpu")]
fn fusion_new<'a>(env: Env<'a>, state: FilterStateTerm, config: FilterConfigTerm) -> Term<'a> {
    let state = match decode_filter_state(state) {
        Ok(state) => state,
        Err(error) => return fusion_error(env, error),
    };
    let config = match decode_config(config) {
        Ok(config) => config,
        Err(error) => return fusion_error(env, error),
    };
    match InertialFilter::with_config(state, config) {
        Ok(filter) => (
            atoms::ok(),
            ResourceArc::new(FusionFilterResource {
                filter: Mutex::new(filter),
            }),
        )
            .encode(env),
        Err(error) => fusion_error(env, error),
    }
}

/// Restore a stateful filter from versioned fusion state bytes.
#[rustler::nif(schedule = "DirtyCpu")]
fn fusion_from_state_bytes<'a>(
    env: Env<'a>,
    bytes: Binary<'a>,
    config: FilterConfigTerm,
) -> Term<'a> {
    let config = match decode_config(config) {
        Ok(config) => config,
        Err(error) => return fusion_error(env, error),
    };
    let snapshot =
        match sidereon_core::fusion::timesync::InertialFilterSnapshot::decode_fusion_state(
            bytes.as_slice(),
        ) {
            Ok(snapshot) => snapshot,
            Err(error) => return codec_error(env, error),
        };
    let mut filter = match InertialFilter::with_config(snapshot.state.clone(), config) {
        Ok(filter) => filter,
        Err(error) => return fusion_error(env, error),
    };
    if let Err(error) = filter.restore_encoded_state(bytes.as_slice()) {
        return codec_error(env, error);
    }
    (
        atoms::ok(),
        ResourceArc::new(FusionFilterResource {
            filter: Mutex::new(filter),
        }),
    )
        .encode(env)
}

/// Return the current closed-loop filter state.
#[rustler::nif(schedule = "DirtyCpu")]
fn fusion_state<'a>(env: Env<'a>, handle: ResourceArc<FusionFilterResource>) -> Term<'a> {
    with_filter(env, handle, |filter| {
        Ok((atoms::ok(), encode_state(filter.state())).encode(env))
    })
}

/// Propagate the filter by one IMU sample.
#[rustler::nif(schedule = "DirtyCpu")]
fn fusion_propagate<'a>(
    env: Env<'a>,
    handle: ResourceArc<FusionFilterResource>,
    sample: ImuSampleTerm,
) -> Term<'a> {
    let sample = match decode_imu_sample(sample) {
        Ok(sample) => sample,
        Err(error) => return fusion_error(env, error),
    };
    with_filter(env, handle, |filter| match filter.propagate(sample) {
        Ok(state) => Ok((atoms::ok(), encode_state(state)).encode(env)),
        Err(error) => Ok(fusion_error(env, error)),
    })
}

/// Propagate the filter and record the transition for RTS smoothing.
#[rustler::nif(schedule = "DirtyCpu")]
fn fusion_propagate_recorded<'a>(
    env: Env<'a>,
    handle: ResourceArc<FusionFilterResource>,
    sample: ImuSampleTerm,
    history: ResourceArc<FusionRtsHistoryBuilderResource>,
) -> Term<'a> {
    let sample = match decode_imu_sample(sample) {
        Ok(sample) => sample,
        Err(error) => return fusion_error(env, error),
    };
    let mut filter = match handle.filter.lock() {
        Ok(filter) => filter,
        Err(_) => return (atoms::error(), atoms::poisoned_resource()).encode(env),
    };
    let mut history = match history.builder.lock() {
        Ok(history) => history,
        Err(_) => return (atoms::error(), atoms::poisoned_resource()).encode(env),
    };
    match filter.propagate_recorded(sample, &mut history) {
        Ok(state) => (atoms::ok(), encode_state(state)).encode(env),
        Err(error) => fusion_error(env, error),
    }
}

/// Apply one loose GNSS position or position-velocity update.
#[rustler::nif(schedule = "DirtyCpu")]
fn fusion_update_loose<'a>(
    env: Env<'a>,
    handle: ResourceArc<FusionFilterResource>,
    measurement: LooseMeasurementTerm,
) -> Term<'a> {
    let measurement = match decode_loose_measurement(measurement) {
        Ok(measurement) => measurement,
        Err(error) => return fusion_error(env, error),
    };
    with_filter(env, handle, |filter| {
        match filter.update_loose(&measurement) {
            Ok(update) => Ok((atoms::ok(), encode_update(update)).encode(env)),
            Err(error) => Ok(fusion_error(env, error)),
        }
    })
}

/// Apply one loose GNSS update and record before/after checkpoints.
#[rustler::nif(schedule = "DirtyCpu")]
fn fusion_update_loose_recorded<'a>(
    env: Env<'a>,
    handle: ResourceArc<FusionFilterResource>,
    measurement: LooseMeasurementTerm,
    history: ResourceArc<FusionRtsHistoryBuilderResource>,
) -> Term<'a> {
    let measurement = match decode_loose_measurement(measurement) {
        Ok(measurement) => measurement,
        Err(error) => return fusion_error(env, error),
    };
    let mut filter = match handle.filter.lock() {
        Ok(filter) => filter,
        Err(_) => return (atoms::error(), atoms::poisoned_resource()).encode(env),
    };
    let mut history = match history.builder.lock() {
        Ok(history) => history,
        Err(_) => return (atoms::error(), atoms::poisoned_resource()).encode(env),
    };
    match filter.update_loose_recorded(&measurement, &mut history) {
        Ok(update) => (atoms::ok(), encode_update(update)).encode(env),
        Err(error) => fusion_error(env, error),
    }
}

/// Apply configured stationary ZUPT/ZARU constraints when the detector fires.
#[rustler::nif(schedule = "DirtyCpu")]
fn fusion_update_stationary<'a>(
    env: Env<'a>,
    handle: ResourceArc<FusionFilterResource>,
) -> Term<'a> {
    with_filter(env, handle, |filter| match filter.update_stationary() {
        Ok(update) => Ok((atoms::ok(), update.map(encode_update)).encode(env)),
        Err(error) => Ok(fusion_error(env, error)),
    })
}

/// Apply configured stationary constraints and record checkpoints when applied.
#[rustler::nif(schedule = "DirtyCpu")]
fn fusion_update_stationary_recorded<'a>(
    env: Env<'a>,
    handle: ResourceArc<FusionFilterResource>,
    history: ResourceArc<FusionRtsHistoryBuilderResource>,
) -> Term<'a> {
    let mut filter = match handle.filter.lock() {
        Ok(filter) => filter,
        Err(_) => return (atoms::error(), atoms::poisoned_resource()).encode(env),
    };
    let mut history = match history.builder.lock() {
        Ok(history) => history,
        Err(_) => return (atoms::error(), atoms::poisoned_resource()).encode(env),
    };
    match filter.update_stationary_recorded(&mut history) {
        Ok(update) => (atoms::ok(), update.map(encode_update)).encode(env),
        Err(error) => fusion_error(env, error),
    }
}

/// Apply configured non-holonomic vehicle constraints when motion gates pass.
#[rustler::nif(schedule = "DirtyCpu")]
fn fusion_update_non_holonomic<'a>(
    env: Env<'a>,
    handle: ResourceArc<FusionFilterResource>,
) -> Term<'a> {
    with_filter(env, handle, |filter| match filter.update_non_holonomic() {
        Ok(update) => Ok((atoms::ok(), update.map(encode_update)).encode(env)),
        Err(error) => Ok(fusion_error(env, error)),
    })
}

/// Apply configured non-holonomic constraints and record when applied.
#[rustler::nif(schedule = "DirtyCpu")]
fn fusion_update_non_holonomic_recorded<'a>(
    env: Env<'a>,
    handle: ResourceArc<FusionFilterResource>,
    history: ResourceArc<FusionRtsHistoryBuilderResource>,
) -> Term<'a> {
    let mut filter = match handle.filter.lock() {
        Ok(filter) => filter,
        Err(_) => return (atoms::error(), atoms::poisoned_resource()).encode(env),
    };
    let mut history = match history.builder.lock() {
        Ok(history) => history,
        Err(_) => return (atoms::error(), atoms::poisoned_resource()).encode(env),
    };
    match filter.update_non_holonomic_recorded(&mut history) {
        Ok(update) => (atoms::ok(), update.map(encode_update)).encode(env),
        Err(error) => fusion_error(env, error),
    }
}

/// Apply one time-synchronized loose GNSS update.
#[rustler::nif(schedule = "DirtyCpu")]
fn fusion_update_loose_time_sync<'a>(
    env: Env<'a>,
    handle: ResourceArc<FusionFilterResource>,
    measurement: LooseMeasurementTerm,
) -> Term<'a> {
    let measurement = match decode_loose_measurement(measurement) {
        Ok(measurement) => measurement,
        Err(error) => return fusion_error(env, error),
    };
    with_filter(env, handle, |filter| {
        match filter.update_loose_time_sync(&measurement) {
            Ok(update) => Ok((atoms::ok(), encode_time_sync_update(update)).encode(env)),
            Err(error) => Ok(fusion_error(env, error)),
        }
    })
}

/// Apply one tight GNSS update using an SP3 ephemeris resource.
#[rustler::nif(schedule = "DirtyCpu")]
fn fusion_update_tight_sp3<'a>(
    env: Env<'a>,
    handle: ResourceArc<FusionFilterResource>,
    source: ResourceArc<Sp3Resource>,
    epoch: TightEpochTerm,
) -> Term<'a> {
    let epoch = match decode_tight_epoch(epoch) {
        Ok(epoch) => epoch,
        Err(error) => return fusion_error(env, error),
    };
    with_filter(env, handle, |filter| {
        match filter.update_tight(&source.sp3, &epoch) {
            Ok(update) => Ok((atoms::ok(), encode_update(update)).encode(env)),
            Err(error) => Ok(fusion_error(env, error)),
        }
    })
}

/// Apply one tight GNSS update using a broadcast ephemeris resource.
#[rustler::nif(schedule = "DirtyCpu")]
fn fusion_update_tight_broadcast<'a>(
    env: Env<'a>,
    handle: ResourceArc<FusionFilterResource>,
    source: ResourceArc<BroadcastResource>,
    epoch: TightEpochTerm,
) -> Term<'a> {
    let epoch = match decode_tight_epoch(epoch) {
        Ok(epoch) => epoch,
        Err(error) => return fusion_error(env, error),
    };
    with_filter(env, handle, |filter| {
        match filter.update_tight(&source.store, &epoch) {
            Ok(update) => Ok((atoms::ok(), encode_update(update)).encode(env)),
            Err(error) => Ok(fusion_error(env, error)),
        }
    })
}

/// Apply and record one tight GNSS update using an SP3 ephemeris resource.
#[rustler::nif(schedule = "DirtyCpu")]
fn fusion_update_tight_recorded_sp3<'a>(
    env: Env<'a>,
    handle: ResourceArc<FusionFilterResource>,
    source: ResourceArc<Sp3Resource>,
    epoch: TightEpochTerm,
    history: ResourceArc<FusionRtsHistoryBuilderResource>,
) -> Term<'a> {
    let epoch = match decode_tight_epoch(epoch) {
        Ok(epoch) => epoch,
        Err(error) => return fusion_error(env, error),
    };
    let mut filter = match handle.filter.lock() {
        Ok(filter) => filter,
        Err(_) => return (atoms::error(), atoms::poisoned_resource()).encode(env),
    };
    let mut history = match history.builder.lock() {
        Ok(history) => history,
        Err(_) => return (atoms::error(), atoms::poisoned_resource()).encode(env),
    };
    match filter.update_tight_recorded(&source.sp3, &epoch, &mut history) {
        Ok(update) => (atoms::ok(), encode_update(update)).encode(env),
        Err(error) => fusion_error(env, error),
    }
}

/// Apply and record one tight GNSS update using a broadcast ephemeris resource.
#[rustler::nif(schedule = "DirtyCpu")]
fn fusion_update_tight_recorded_broadcast<'a>(
    env: Env<'a>,
    handle: ResourceArc<FusionFilterResource>,
    source: ResourceArc<BroadcastResource>,
    epoch: TightEpochTerm,
    history: ResourceArc<FusionRtsHistoryBuilderResource>,
) -> Term<'a> {
    let epoch = match decode_tight_epoch(epoch) {
        Ok(epoch) => epoch,
        Err(error) => return fusion_error(env, error),
    };
    let mut filter = match handle.filter.lock() {
        Ok(filter) => filter,
        Err(_) => return (atoms::error(), atoms::poisoned_resource()).encode(env),
    };
    let mut history = match history.builder.lock() {
        Ok(history) => history,
        Err(_) => return (atoms::error(), atoms::poisoned_resource()).encode(env),
    };
    match filter.update_tight_recorded(&source.store, &epoch, &mut history) {
        Ok(update) => (atoms::ok(), encode_update(update)).encode(env),
        Err(error) => fusion_error(env, error),
    }
}

/// Apply one time-synchronized tight GNSS update using an SP3 ephemeris resource.
#[rustler::nif(schedule = "DirtyCpu")]
fn fusion_update_tight_time_sync_sp3<'a>(
    env: Env<'a>,
    handle: ResourceArc<FusionFilterResource>,
    source: ResourceArc<Sp3Resource>,
    epoch: TightEpochTerm,
) -> Term<'a> {
    let epoch = match decode_tight_epoch(epoch) {
        Ok(epoch) => epoch,
        Err(error) => return fusion_error(env, error),
    };
    with_filter(env, handle, |filter| {
        match filter.update_tight_time_sync(&source.sp3, &epoch) {
            Ok(update) => Ok((atoms::ok(), encode_time_sync_update(update)).encode(env)),
            Err(error) => Ok(fusion_error(env, error)),
        }
    })
}

/// Apply one time-synchronized tight GNSS update using a broadcast ephemeris resource.
#[rustler::nif(schedule = "DirtyCpu")]
fn fusion_update_tight_time_sync_broadcast<'a>(
    env: Env<'a>,
    handle: ResourceArc<FusionFilterResource>,
    source: ResourceArc<BroadcastResource>,
    epoch: TightEpochTerm,
) -> Term<'a> {
    let epoch = match decode_tight_epoch(epoch) {
        Ok(epoch) => epoch,
        Err(error) => return fusion_error(env, error),
    };
    with_filter(env, handle, |filter| {
        match filter.update_tight_time_sync(&source.store, &epoch) {
            Ok(update) => Ok((atoms::ok(), encode_time_sync_update(update)).encode(env)),
            Err(error) => Ok(fusion_error(env, error)),
        }
    })
}

/// Configure retained history capacities for time synchronization.
#[rustler::nif(schedule = "DirtyCpu")]
fn fusion_configure_time_sync<'a>(
    env: Env<'a>,
    handle: ResourceArc<FusionFilterResource>,
    config: TimeSyncConfigTerm,
) -> Term<'a> {
    let config = TimeSyncHistoryConfig::new(
        config.imu_capacity as usize,
        config.checkpoint_capacity as usize,
    );
    with_filter(env, handle, |filter| {
        match filter.configure_time_sync_history(config) {
            Ok(()) => Ok((
                atoms::ok(),
                encode_time_sync_status(filter.time_sync_history_status()),
            )
                .encode(env)),
            Err(error) => Ok(fusion_error(env, error)),
        }
    })
}

/// Return retained-history status for time synchronization.
#[rustler::nif(schedule = "DirtyCpu")]
fn fusion_time_sync_status<'a>(
    env: Env<'a>,
    handle: ResourceArc<FusionFilterResource>,
) -> Term<'a> {
    with_filter(env, handle, |filter| {
        Ok((
            atoms::ok(),
            encode_time_sync_status(filter.time_sync_history_status()),
        )
            .encode(env))
    })
}

/// Return the tight receiver-clock state.
#[rustler::nif(schedule = "DirtyCpu")]
fn fusion_tight_clock_state<'a>(
    env: Env<'a>,
    handle: ResourceArc<FusionFilterResource>,
) -> Term<'a> {
    with_filter(env, handle, |filter| match filter.tight_clock_state() {
        Ok(clock) => Ok((atoms::ok(), encode_clock(clock)).encode(env)),
        Err(error) => Ok(fusion_error(env, error)),
    })
}

/// Encode the current fusion state and retained time-sync history as bytes.
#[rustler::nif(schedule = "DirtyCpu")]
fn fusion_encode_state<'a>(env: Env<'a>, handle: ResourceArc<FusionFilterResource>) -> Term<'a> {
    with_filter(env, handle, |filter| match encode_filter_state(filter) {
        Ok(bytes) => Ok((atoms::ok(), bytes_to_binary(env, &bytes)).encode(env)),
        Err(error) => Ok(codec_error(env, error)),
    })
}

/// Restore the current filter from versioned fusion state bytes.
#[rustler::nif(schedule = "DirtyCpu")]
fn fusion_restore_state<'a>(
    env: Env<'a>,
    handle: ResourceArc<FusionFilterResource>,
    bytes: Binary<'a>,
) -> Term<'a> {
    with_filter(env, handle, |filter| {
        match filter.restore_encoded_state(bytes.as_slice()) {
            Ok(()) => Ok((atoms::ok(), encode_state(filter.state())).encode(env)),
            Err(error) => Ok(codec_error(env, error)),
        }
    })
}

/// Create an empty fusion RTS history builder.
#[rustler::nif]
fn fusion_rts_history_builder_new() -> ResourceArc<FusionRtsHistoryBuilderResource> {
    ResourceArc::new(FusionRtsHistoryBuilderResource {
        builder: Mutex::new(FusionRtsHistoryBuilder::empty()),
    })
}

/// Create a fusion RTS history builder from the filter's current checkpoint.
#[rustler::nif(schedule = "DirtyCpu")]
fn fusion_rts_history_builder_from_filter<'a>(
    env: Env<'a>,
    handle: ResourceArc<FusionFilterResource>,
) -> Term<'a> {
    match handle.filter.lock() {
        Ok(filter) => match FusionRtsHistoryBuilder::from_filter(&filter) {
            Ok(builder) => (
                atoms::ok(),
                ResourceArc::new(FusionRtsHistoryBuilderResource {
                    builder: Mutex::new(builder),
                }),
            )
                .encode(env),
            Err(error) => fusion_error(env, error),
        },
        Err(_) => (atoms::error(), atoms::poisoned_resource()).encode(env),
    }
}

/// Finish a fusion RTS history builder.
#[rustler::nif(schedule = "DirtyCpu")]
fn fusion_rts_history_builder_finish<'a>(
    env: Env<'a>,
    builder: ResourceArc<FusionRtsHistoryBuilderResource>,
) -> Term<'a> {
    match builder.builder.lock() {
        Ok(builder) => match builder.clone().finish() {
            Ok(history) => (
                atoms::ok(),
                ResourceArc::new(FusionRtsHistoryResource { history }),
            )
                .encode(env),
            Err(error) => fusion_error(env, error),
        },
        Err(_) => (atoms::error(), atoms::poisoned_resource()).encode(env),
    }
}

#[rustler::nif]
fn fusion_rts_history_epoch_count(handle: ResourceArc<FusionRtsHistoryResource>) -> u64 {
    handle.history.epochs.len() as u64
}

#[rustler::nif]
fn fusion_rts_history_epochs(
    handle: ResourceArc<FusionRtsHistoryResource>,
) -> Vec<FusionRtsEpochOut> {
    handle.history.epochs.iter().map(encode_rts_epoch).collect()
}

/// Smooth a finished fusion RTS history.
#[rustler::nif(schedule = "DirtyCpu")]
fn fusion_smooth_rts<'a>(env: Env<'a>, history: ResourceArc<FusionRtsHistoryResource>) -> Term<'a> {
    match core_smooth_fusion_rts(&history.history) {
        Ok(trajectory) => (
            atoms::ok(),
            ResourceArc::new(SmoothedFusionTrajectoryResource { trajectory }),
        )
            .encode(env),
        Err(error) => fusion_error(env, error),
    }
}

#[rustler::nif]
fn fusion_smoothed_trajectory_epoch_count(
    handle: ResourceArc<SmoothedFusionTrajectoryResource>,
) -> u64 {
    handle.trajectory.epochs.len() as u64
}

#[rustler::nif]
fn fusion_smoothed_trajectory_epochs(
    handle: ResourceArc<SmoothedFusionTrajectoryResource>,
) -> Vec<SmoothedFusionEpochOut> {
    handle
        .trajectory
        .epochs
        .iter()
        .map(encode_smoothed_epoch)
        .collect()
}

/// Blend a first good GNSS position/velocity fix back over an outage span.
#[rustler::nif(schedule = "DirtyCpu")]
fn fusion_velocity_match_outage<'a>(
    env: Env<'a>,
    states: Vec<VelocityMatchStateTerm>,
    first_good_fix: LooseMeasurementTerm,
    config: VelocityMatchingConfigTerm,
) -> Term<'a> {
    let states = match states
        .into_iter()
        .map(decode_velocity_match_state)
        .collect::<Result<Vec<_>, _>>()
    {
        Ok(states) => states,
        Err(error) => return fusion_error(env, error),
    };
    let first_good_fix = match decode_loose_measurement(first_good_fix) {
        Ok(measurement) => measurement,
        Err(error) => return fusion_error(env, error),
    };
    let config = VelocityMatchingConfig::new(config.max_outage_duration_s);

    match velocity_match_outage(&states, &first_good_fix, config) {
        Ok(matched) => (atoms::ok(), encode_velocity_matched_trajectory(matched)).encode(env),
        Err(error) => fusion_error(env, error),
    }
}

fn with_filter<'a, F>(env: Env<'a>, handle: ResourceArc<FusionFilterResource>, f: F) -> Term<'a>
where
    F: FnOnce(&mut InertialFilter) -> Result<Term<'a>, ()>,
{
    match handle.filter.lock() {
        Ok(mut filter) => f(&mut filter)
            .unwrap_or_else(|()| (atoms::error(), atoms::poisoned_resource()).encode(env)),
        Err(_) => (atoms::error(), atoms::poisoned_resource()).encode(env),
    }
}

fn decode_filter_state(term: FilterStateTerm) -> Result<InsFilterState, FusionError> {
    let layout = decode_layout(&term.layout)?;
    let nominal = decode_nav_state(term.nominal)?;
    let mut state = match (term.covariance, term.covariance_diagonal) {
        (Some(covariance), _) => InsFilterState::new(nominal, layout, covariance)?,
        (None, Some(diagonal)) => InsFilterState::from_diagonal(nominal, layout, &diagonal)?,
        (None, None) => {
            return Err(FusionError::InvalidInput {
                field: "covariance",
                reason: "covariance or covariance_diagonal is required",
            })
        }
    };
    state.accel_scale_factor = vec3(term.accel_scale_factor, "accel_scale_factor")?;
    state.gyro_scale_factor = vec3(term.gyro_scale_factor, "gyro_scale_factor")?;
    state.validate()?;
    Ok(state)
}

fn decode_nav_state(term: NavStateTerm) -> Result<NavState, FusionError> {
    let state = NavState::new(
        term.t_j2000_s,
        vec3(term.position_ecef_m, "position_ecef_m")?,
        vec3(term.velocity_ecef_mps, "velocity_ecef_mps")?,
        mat3(term.attitude_body_to_ecef, "attitude_body_to_ecef")?,
    )
    .map_err(FusionError::from)?;
    state
        .with_biases(
            vec3(term.accel_bias_mps2, "accel_bias_mps2")?,
            vec3(term.gyro_bias_rps, "gyro_bias_rps")?,
        )
        .map_err(FusionError::from)
}

fn decode_config(term: FilterConfigTerm) -> Result<InertialFilterConfig, FusionError> {
    let mut config = InertialFilterConfig::new(decode_imu_spec(term.imu_spec)?)?;
    config.filter_kind = decode_filter_kind(&term.filter_kind)?;
    config.imu_model = decode_imu_model(term.imu_model)?;
    config.imu_to_body_dcm = mat3(term.imu_to_body_dcm, "imu_to_body_dcm")?;
    config.mechanization = decode_mechanization(term.mechanization)?;
    let mut loose = LooseCouplingConfig::default();
    loose.lever_arm_body_m = vec3(term.loose.lever_arm_body_m, "loose.lever_arm_body_m")?;
    loose.update_options = decode_ekf_options(term.loose.update_options)?;
    loose.fix_status_weighting = decode_fix_status_weighting(term.loose.fix_status_weighting);
    loose.measurement_reweighting = term
        .loose
        .measurement_reweighting
        .map(decode_igg_iii_reweighting);
    loose.prediction_adaptation = term
        .loose
        .prediction_adaptation
        .map(decode_yang_prediction_adaptive_factor);
    loose.stationary_updates = term.loose.stationary_updates.map(decode_stationary_update);
    loose.non_holonomic = term.loose.non_holonomic.map(decode_non_holonomic);
    config.loose = loose;

    let mut tight = TightCouplingConfig::default();
    tight.lever_arm_body_m = vec3(term.tight.lever_arm_body_m, "tight.lever_arm_body_m")?;
    tight.light_time = term.tight.light_time;
    tight.sagnac = term.tight.sagnac;
    tight.initial_clock_bias_variance_m2 = term.tight.initial_clock_bias_variance_m2;
    tight.initial_clock_drift_variance_m2_s2 = term.tight.initial_clock_drift_variance_m2_s2;
    tight.clock_bias_random_walk_m2_s = term.tight.clock_bias_random_walk_m2_s;
    tight.clock_drift_random_walk_m2_s3 = term.tight.clock_drift_random_walk_m2_s3;
    tight.update_options = decode_ekf_options(term.tight.update_options)?;
    config.tight = tight;
    config.ukf_update_options = decode_ukf_options(term.ukf_update_options)?;
    config.validate()?;
    Ok(config)
}

fn decode_imu_spec(term: ImuSpecTerm) -> Result<ImuSpec, FusionError> {
    let spec = ImuSpec::datasheet(
        term.accel_vrw_mps_sqrt_s,
        term.gyro_arw_rad_sqrt_s,
        term.accel_bias_instab_mps2,
        term.gyro_bias_instab_rps,
        term.accel_bias_tau_s.unwrap_or(f64::INFINITY),
        term.gyro_bias_tau_s.unwrap_or(f64::INFINITY),
        term.accel_scale_instab_ppm,
        term.gyro_scale_instab_ppm,
    );
    spec.validate().map_err(FusionError::from)?;
    Ok(spec)
}

fn decode_imu_model(term: ImuModelTerm) -> Result<ImuErrorModel, FusionError> {
    let model = ImuErrorModel {
        bias: ImuBias {
            accel_mps2: vec3(term.bias.accel_mps2, "imu_model.bias.accel_mps2")?,
            gyro_rps: vec3(term.bias.gyro_rps, "imu_model.bias.gyro_rps")?,
        },
        calibration: ImuCalibration {
            accel_scale_misalignment: mat3(
                term.calibration.accel_scale_misalignment,
                "imu_model.calibration.accel_scale_misalignment",
            )?,
            gyro_scale_misalignment: mat3(
                term.calibration.gyro_scale_misalignment,
                "imu_model.calibration.gyro_scale_misalignment",
            )?,
        },
    };
    model.bias.validate().map_err(FusionError::from)?;
    model.calibration.validate().map_err(FusionError::from)?;
    Ok(model)
}

fn decode_mechanization(term: MechanizationTerm) -> Result<MechanizationConfig, FusionError> {
    match term.coning_correction.as_str() {
        "off" => {
            let mut config = MechanizationConfig::default();
            config.coning_correction = ConingCorrection::Off;
            Ok(config)
        }
        _ => Err(FusionError::InvalidInput {
            field: "mechanization.coning_correction",
            reason: "must be off",
        }),
    }
}

fn decode_ekf_options(term: EkfOptionsTerm) -> Result<EkfUpdateOptions, FusionError> {
    let mut options = EkfUpdateOptions::default();
    options.innovation_gate = term.innovation_gate.map(|gate| InnovationGate {
        threshold_sigma: gate.threshold_sigma,
        min_rows: gate.min_rows as usize,
    });
    Ok(options)
}

fn decode_igg_iii_reweighting(
    term: IggIiiMeasurementReweightingTerm,
) -> IggIiiMeasurementReweighting {
    IggIiiMeasurementReweighting {
        k0_sigma: term.k0_sigma,
        k1_sigma: term.k1_sigma,
    }
}

fn decode_yang_prediction_adaptive_factor(
    term: YangPredictionAdaptiveFactorTerm,
) -> YangPredictionAdaptiveFactor {
    YangPredictionAdaptiveFactor {
        threshold: term.threshold,
        outlier_gate_probability: term.outlier_gate_probability,
    }
}

fn decode_fix_status_weighting(term: FixStatusWeightingTerm) -> GnssFixStatusWeighting {
    GnssFixStatusWeighting {
        single_sigma_multiplier: term.single_sigma_multiplier,
        float_sigma_multiplier: term.float_sigma_multiplier,
        fixed_sigma_multiplier: term.fixed_sigma_multiplier,
    }
}

fn decode_stationary_update(term: StationaryUpdateTerm) -> StationaryUpdateConfig {
    let detector = StationaryDetectorConfig::new(
        term.detector.window_len as usize,
        term.detector.max_specific_force_norm_error_mps2,
        term.detector.max_body_rate_wrt_ecef_norm_rps,
    );
    StationaryUpdateConfig::new(
        detector,
        term.zero_velocity_sigma_mps,
        term.zero_angular_rate_sigma_rps,
    )
}

fn decode_non_holonomic(term: NonHolonomicTerm) -> NonHolonomicConstraintConfig {
    NonHolonomicConstraintConfig::new(
        term.lateral_velocity_sigma_mps,
        term.vertical_velocity_sigma_mps,
        term.min_speed_mps,
        term.max_body_rate_wrt_ecef_norm_rps,
    )
}

fn decode_ukf_options(term: UkfOptionsTerm) -> Result<UkfUpdateOptions, FusionError> {
    let mut transform = UnscentedTransformOptions::default();
    transform.alpha = term.alpha;
    transform.beta = term.beta;
    transform.kappa = term.kappa;

    let mut options = UkfUpdateOptions::default();
    options.transform = transform;
    options.innovation_gate = term.innovation_gate.map(|gate| InnovationGate {
        threshold_sigma: gate.threshold_sigma,
        min_rows: gate.min_rows as usize,
    });
    Ok(options)
}

fn decode_imu_sample(term: ImuSampleTerm) -> Result<ImuSample, FusionError> {
    match term.kind.as_str() {
        "rate" => Ok(ImuSample::rate(
            term.t_j2000_s,
            vec3(term.specific_force_mps2, "specific_force_mps2")?,
            vec3(term.angular_rate_rps, "angular_rate_rps")?,
        )),
        "increment" => Ok(ImuSample::increment(
            term.t_j2000_s,
            vec3(term.delta_velocity_mps, "delta_velocity_mps")?,
            vec3(term.delta_theta_rad, "delta_theta_rad")?,
            term.dt_s,
        )),
        _ => Err(FusionError::InvalidInput {
            field: "imu_sample.kind",
            reason: "must be rate or increment",
        }),
    }
}

fn decode_loose_measurement(term: LooseMeasurementTerm) -> Result<GnssFixMeasurement, FusionError> {
    let measurement = GnssFixMeasurement {
        t_j2000_s: term.t_j2000_s,
        position_ecef_m: vec3(term.position_ecef_m, "position_ecef_m")?,
        velocity_ecef_mps: term
            .velocity_ecef_mps
            .map(|v| vec3(v, "velocity_ecef_mps"))
            .transpose()?,
        covariance: term.covariance,
        satellites_used: term.satellites_used as usize,
        solution_valid: term.solution_valid,
        fix_status: decode_fix_status(&term.fix_status)?,
    };
    measurement.validate()?;
    Ok(measurement)
}

fn decode_fix_status(label: &str) -> Result<GnssFixStatus, FusionError> {
    match label {
        "single" => Ok(GnssFixStatus::Single),
        "float" => Ok(GnssFixStatus::Float),
        "fixed" => Ok(GnssFixStatus::Fixed),
        _ => Err(FusionError::InvalidInput {
            field: "fix_status",
            reason: "must be single, float, or fixed",
        }),
    }
}

fn decode_velocity_match_state(
    term: VelocityMatchStateTerm,
) -> Result<VelocityMatchState, FusionError> {
    VelocityMatchState::new(
        term.t_j2000_s,
        vec3(term.position_ecef_m, "position_ecef_m")?,
        vec3(term.velocity_ecef_mps, "velocity_ecef_mps")?,
    )
}

fn decode_tight_epoch(term: TightEpochTerm) -> Result<TightGnssEpoch, FusionError> {
    let observations = term
        .observations
        .into_iter()
        .map(decode_tight_observation)
        .collect::<Result<Vec<_>, _>>()?;
    TightGnssEpoch::new(term.t_j2000_s, observations)
}

fn decode_tight_observation(
    term: TightObservationTerm,
) -> Result<TightGnssObservation, FusionError> {
    let satellite_id =
        term.satellite_id
            .parse::<GnssSatelliteId>()
            .map_err(|_| FusionError::InvalidInput {
                field: "satellite_id",
                reason: "invalid GNSS satellite token",
            })?;
    let observation = TightGnssObservation {
        satellite_id,
        pseudorange_m: term.pseudorange_m,
        pseudorange_sigma_m: term.pseudorange_sigma_m,
        range_rate: term.range_rate.map(|range_rate| TightRangeRateObservation {
            measured_range_rate_m_s: range_rate.measured_range_rate_m_s,
            sigma_m_s: range_rate.sigma_m_s,
            satellite_clock_drift_m_s: range_rate.satellite_clock_drift_m_s,
        }),
        carrier_phase: term
            .carrier_phase
            .map(|carrier_phase| TightCarrierPhaseObservation {
                phase_range_m: carrier_phase.phase_range_m,
                sigma_m: carrier_phase.sigma_m,
                float_ambiguity_m: carrier_phase.float_ambiguity_m,
            }),
        ionosphere_delay_m: term.ionosphere_delay_m,
        troposphere_delay_m: term.troposphere_delay_m,
    };
    observation.validate()?;
    Ok(observation)
}

fn decode_layout(label: &str) -> Result<ErrorStateLayout, FusionError> {
    match label {
        "fifteen" => Ok(ErrorStateLayout::Fifteen),
        "twenty_one" => Ok(ErrorStateLayout::TwentyOne),
        _ => Err(FusionError::InvalidInput {
            field: "layout",
            reason: "must be fifteen or twenty_one",
        }),
    }
}

fn decode_filter_kind(label: &str) -> Result<FusionFilterKind, FusionError> {
    match label {
        "ekf" => Ok(FusionFilterKind::Ekf),
        "ukf" => Ok(FusionFilterKind::Ukf),
        _ => Err(FusionError::InvalidInput {
            field: "filter_kind",
            reason: "must be ekf or ukf",
        }),
    }
}

fn vec3(values: Vec<f64>, field: &'static str) -> Result<[f64; 3], FusionError> {
    if values.len() != 3 {
        return Err(FusionError::DimensionMismatch {
            field,
            expected: 3,
            actual: values.len(),
        });
    }
    Ok([values[0], values[1], values[2]])
}

fn mat3(values: MatrixTerm, field: &'static str) -> Result<[[f64; 3]; 3], FusionError> {
    if values.len() != 3 {
        return Err(FusionError::DimensionMismatch {
            field,
            expected: 3,
            actual: values.len(),
        });
    }
    Ok([
        vec3(values[0].clone(), field)?,
        vec3(values[1].clone(), field)?,
        vec3(values[2].clone(), field)?,
    ])
}

fn encode_imu_spec(spec: ImuSpec) -> ImuSpecTerm {
    ImuSpecTerm {
        accel_vrw_mps_sqrt_s: spec.accel_vrw_mps_sqrt_s,
        gyro_arw_rad_sqrt_s: spec.gyro_arw_rad_sqrt_s,
        accel_bias_instab_mps2: spec.accel_bias_instab_mps2,
        gyro_bias_instab_rps: spec.gyro_bias_instab_rps,
        accel_bias_tau_s: Some(spec.accel_bias_tau_s),
        gyro_bias_tau_s: Some(spec.gyro_bias_tau_s),
        accel_scale_instab_ppm: spec.accel_scale_instab_ppm,
        gyro_scale_instab_ppm: spec.gyro_scale_instab_ppm,
    }
}

fn encode_filter_state(
    filter: &InertialFilter,
) -> Result<Vec<u8>, sidereon_core::fusion::serial::FusionStateCodecError> {
    let mut state = filter.serializable_state()?;
    dedupe_same_epoch_checkpoints(&mut state.time_sync.checkpoints);
    state.encode_versioned()
}

fn dedupe_same_epoch_checkpoints(
    checkpoints: &mut Vec<sidereon_core::fusion::serial::SerializableStoredCheckpoint>,
) {
    let mut deduped: Vec<sidereon_core::fusion::serial::SerializableStoredCheckpoint> =
        Vec::with_capacity(checkpoints.len());
    for checkpoint in std::mem::take(checkpoints) {
        if let Some(last) = deduped.last_mut() {
            if last.t_j2000_s.bits == checkpoint.t_j2000_s.bits {
                *last = checkpoint;
                continue;
            }
        }
        deduped.push(checkpoint);
    }
    *checkpoints = deduped;
}

fn encode_state(state: &InsFilterState) -> FilterStateOut {
    FilterStateOut {
        nominal: NavStateOut {
            t_j2000_s: state.nominal.t_j2000_s,
            position_ecef_m: state.nominal.position_ecef_m.to_vec(),
            velocity_ecef_mps: state.nominal.velocity_ecef_mps.to_vec(),
            attitude_body_to_ecef: state
                .nominal
                .attitude_body_to_ecef
                .iter()
                .map(|row| row.to_vec())
                .collect(),
            accel_bias_mps2: state.nominal.accel_bias_mps2.to_vec(),
            gyro_bias_rps: state.nominal.gyro_bias_rps.to_vec(),
        },
        layout: match state.layout() {
            ErrorStateLayout::Fifteen => "fifteen",
            ErrorStateLayout::TwentyOne => "twenty_one",
        }
        .to_string(),
        error_state: state.error_state.as_slice().to_vec(),
        covariance: state.covariance.clone(),
        accel_scale_factor: state.accel_scale_factor.to_vec(),
        gyro_scale_factor: state.gyro_scale_factor.to_vec(),
    }
}

fn encode_tight_snapshot(snapshot: &TightFilterSnapshot) -> TightFilterSnapshotOut {
    TightFilterSnapshotOut {
        clock_bias_m: snapshot.clock_bias_m,
        clock_drift_m_s: snapshot.clock_drift_m_s,
        augmented_covariance: snapshot.augmented_covariance.clone(),
    }
}

fn encode_snapshot(snapshot: &InertialFilterSnapshot) -> InertialFilterSnapshotOut {
    InertialFilterSnapshotOut {
        state: encode_state(&snapshot.state),
        last_body_rate_wrt_ecef_rps: snapshot.last_body_rate_wrt_ecef_rps.to_vec(),
        tight: encode_tight_snapshot(&snapshot.tight),
    }
}

fn encode_rts_epoch(epoch: &FusionRtsEpoch) -> FusionRtsEpochOut {
    FusionRtsEpochOut {
        t_j2000_s: epoch.t_j2000_s,
        predicted: encode_snapshot(&epoch.predicted),
        updated: encode_snapshot(&epoch.updated),
        transition_from_previous: epoch.transition_from_previous.clone(),
    }
}

fn encode_smoothed_epoch(epoch: &SmoothedFusionEpoch) -> SmoothedFusionEpochOut {
    SmoothedFusionEpochOut {
        t_j2000_s: epoch.t_j2000_s,
        snapshot: encode_snapshot(&epoch.snapshot),
        error_state_correction: epoch.error_state_correction.clone(),
        covariance: epoch.covariance.clone(),
        rts_gain_to_next: epoch.rts_gain_to_next.clone(),
    }
}

fn encode_update(update: FusionUpdate) -> FusionUpdateOut {
    FusionUpdateOut {
        applied: update.applied,
        nis: update.nis,
        rows: update.rows as u64,
        accepted_rows: update.accepted_rows as u64,
        rejected_rows: update.rejected_rows as u64,
        ekf: encode_ekf_report(update.ekf),
    }
}

fn encode_ekf_report(report: EkfCorrectionReport) -> EkfReportOut {
    EkfReportOut {
        applied: report.applied,
        normalized_innovation_squared: report.normalized_innovation_squared,
        accepted_rows: report.accepted_rows as u64,
        rejected_rows: report.rejected_rows as u64,
        innovation_gate: report.innovation_gate.map(encode_gate_report),
        innovation_covariance: report.innovation_covariance,
        kalman_gain: report.kalman_gain,
        dx: report.dx,
    }
}

fn encode_gate_report(report: InnovationGateReport) -> GateReportOut {
    GateReportOut {
        threshold_sigma: report.threshold_sigma,
        min_rows: report.min_rows as u64,
        input_rows: report.input_rows as u64,
        accepted_rows: report.accepted_rows as u64,
        rejected_rows: report.rejected_rows as u64,
        max_abs_normalized_innovation: report.max_abs_normalized_innovation,
        max_rejected_abs_normalized_innovation: report.max_rejected_abs_normalized_innovation,
        coasted: report.coasted,
    }
}

fn encode_time_sync_update(update: TimeSyncUpdate) -> TimeSyncUpdateOut {
    TimeSyncUpdateOut {
        update: encode_update(update.update),
        late_measurement: update.late_measurement,
        replayed_imu_segments: update.replayed_imu_segments as u64,
        restored_checkpoint_epoch_j2000_s: update.restored_checkpoint_epoch_j2000_s,
        current_epoch_j2000_s: update.current_epoch_j2000_s,
    }
}

fn encode_time_sync_status(status: TimeSyncHistoryStatus) -> TimeSyncStatusOut {
    TimeSyncStatusOut {
        imu_capacity: status.imu_capacity as u64,
        imu_len: status.imu_len as u64,
        checkpoint_capacity: status.checkpoint_capacity as u64,
        checkpoint_len: status.checkpoint_len as u64,
        oldest_imu_epoch_j2000_s: status.oldest_imu_epoch_j2000_s,
        newest_imu_epoch_j2000_s: status.newest_imu_epoch_j2000_s,
        oldest_checkpoint_epoch_j2000_s: status.oldest_checkpoint_epoch_j2000_s,
        newest_checkpoint_epoch_j2000_s: status.newest_checkpoint_epoch_j2000_s,
    }
}

fn encode_velocity_matched_trajectory(
    value: VelocityMatchedTrajectory,
) -> VelocityMatchedTrajectoryOut {
    VelocityMatchedTrajectoryOut {
        states: value
            .states
            .into_iter()
            .map(|state| VelocityMatchStateTerm {
                t_j2000_s: state.t_j2000_s,
                position_ecef_m: state.position_ecef_m.to_vec(),
                velocity_ecef_mps: state.velocity_ecef_mps.to_vec(),
            })
            .collect(),
        endpoint_position_correction_ecef_m: value.endpoint_position_correction_ecef_m.to_vec(),
        endpoint_velocity_correction_ecef_mps: value.endpoint_velocity_correction_ecef_mps.to_vec(),
    }
}

fn encode_clock(clock: TightClockState) -> TightClockStateOut {
    TightClockStateOut {
        bias_m: clock.bias_m,
        drift_m_s: clock.drift_m_s,
        covariance: clock.covariance.iter().map(|row| row.to_vec()).collect(),
    }
}

fn fusion_error<'a>(env: Env<'a>, error: FusionError) -> Term<'a> {
    let reason = match error {
        FusionError::InvalidInput { field, reason } => {
            (atoms::invalid_input(), field, reason).encode(env)
        }
        FusionError::DimensionMismatch {
            field,
            expected,
            actual,
        } => (
            atoms::dimension_mismatch(),
            field,
            expected as u64,
            actual as u64,
        )
            .encode(env),
        FusionError::SingularInnovation => atoms::singular_innovation().encode(env),
        FusionError::NonPositiveSemidefinite { field } => {
            (atoms::non_positive_semidefinite(), field).encode(env)
        }
        FusionError::NonPositiveDefinite { field } => {
            (atoms::non_positive_definite(), field).encode(env)
        }
        FusionError::NominalState => atoms::nominal_state().encode(env),
    };
    (atoms::error(), reason).encode(env)
}

fn codec_error<'a>(
    env: Env<'a>,
    error: sidereon_core::fusion::serial::FusionStateCodecError,
) -> Term<'a> {
    (atoms::error(), (atoms::codec(), error.to_string())).encode(env)
}

fn bytes_to_binary<'a>(env: Env<'a>, bytes: &[u8]) -> Term<'a> {
    let mut binary = OwnedBinary::new(bytes.len()).expect("allocate fusion state binary");
    binary.as_mut_slice().copy_from_slice(bytes);
    binary.release(env).encode(env)
}
