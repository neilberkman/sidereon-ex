//! Rustler boundary for no-IMU track filtering and RTS smoothing.

use std::sync::Mutex;

use rustler::{Encoder, Env, ResourceArc, Term};
use sidereon_core::estimation::primitives::NisGate;
use sidereon_core::estimation::{
    smooth_track_rts as core_smooth_track_rts, SmoothedTrack, SmoothedTrackEpoch,
    TrackCoordinateFrame, TrackError, TrackFilter, TrackFilterConfig, TrackGatedUpdate,
    TrackInnovation, TrackPrediction, TrackRtsEpoch, TrackRtsHistory, TrackRtsHistoryBuilder,
    TrackState, TrackUpdate,
};

pub(crate) struct TrackFilterResource {
    filter: Mutex<TrackFilter>,
}

#[rustler::resource_impl]
impl rustler::Resource for TrackFilterResource {}

pub(crate) struct TrackRtsHistoryBuilderResource {
    builder: Mutex<TrackRtsHistoryBuilder>,
}

#[rustler::resource_impl]
impl rustler::Resource for TrackRtsHistoryBuilderResource {}

pub(crate) struct TrackRtsHistoryResource {
    history: TrackRtsHistory,
}

#[rustler::resource_impl]
impl rustler::Resource for TrackRtsHistoryResource {}

pub(crate) struct SmoothedTrackResource {
    track: SmoothedTrack,
}

#[rustler::resource_impl]
impl rustler::Resource for SmoothedTrackResource {}

#[derive(Debug, Clone, rustler::NifMap)]
struct TrackFilterConfigTerm {
    frame: String,
    initial_t_s: f64,
    initial_position_m: Vec<f64>,
    initial_velocity_m_s: Vec<f64>,
    initial_covariance: Vec<Vec<f64>>,
    acceleration_variance_spectral_density_m2_s3: f64,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct TrackFilterFromPositionTerm {
    frame: String,
    initial_t_s: f64,
    initial_position_m: Vec<f64>,
    position_covariance_m2: Vec<Vec<f64>>,
    initial_velocity_variance_m2_s2: f64,
    acceleration_variance_spectral_density_m2_s3: f64,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct TrackFilterConfigOut {
    frame: String,
    initial_t_s: f64,
    initial_position_m: Vec<f64>,
    initial_velocity_m_s: Vec<f64>,
    initial_covariance: Vec<Vec<f64>>,
    acceleration_variance_spectral_density_m2_s3: f64,
    dimension: usize,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct TrackStateOut {
    frame: String,
    t_s: f64,
    position_m: Vec<f64>,
    velocity_m_s: Vec<f64>,
    covariance: Vec<Vec<f64>>,
    state_vector: Vec<f64>,
    position_covariance_m2: Vec<Vec<f64>>,
    dimension: usize,
    state_dimension: usize,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct TrackPredictionOut {
    dt_s: f64,
    transition: Vec<Vec<f64>>,
    process_noise: Vec<Vec<f64>>,
    predicted: TrackStateOut,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct TrackInnovationOut {
    innovation: Vec<f64>,
    innovation_covariance: Vec<Vec<f64>>,
    nis: f64,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct NisGateOut {
    nis: f64,
    threshold: f64,
    in_gate: bool,
    dof: usize,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct TrackUpdateOut {
    predicted: TrackStateOut,
    updated: TrackStateOut,
    innovation: TrackInnovationOut,
    kalman_gain: Vec<Vec<f64>>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct TrackGatedUpdateOut {
    gate: NisGateOut,
    update: Option<TrackUpdateOut>,
    state: TrackStateOut,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct TrackRtsEpochOut {
    t_s: f64,
    predicted: TrackStateOut,
    updated: TrackStateOut,
    transition_from_previous: Option<Vec<Vec<f64>>>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct SmoothedTrackEpochOut {
    t_s: f64,
    state: TrackStateOut,
    rts_gain_to_next: Option<Vec<Vec<f64>>>,
}

mod atoms {
    rustler::atoms! {
        ok,
        error,
        invalid_input,
        dimension_mismatch,
        non_positive_semidefinite,
        non_positive_definite,
        poisoned_resource
    }
}

#[rustler::nif]
fn track_filter_config_new<'a>(env: Env<'a>, config: TrackFilterConfigTerm) -> Term<'a> {
    encode_track_result(env, config_from_term(config), |config| config_out(&config))
}

#[rustler::nif]
fn track_filter_config_from_position<'a>(
    env: Env<'a>,
    config: TrackFilterFromPositionTerm,
) -> Term<'a> {
    encode_track_result(env, config_from_position_term(config), |config| {
        config_out(&config)
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn track_filter_new<'a>(env: Env<'a>, config: TrackFilterConfigTerm) -> Term<'a> {
    let config = match config_from_term(config) {
        Ok(config) => config,
        Err(error) => return track_error(env, error),
    };
    encode_track_result(env, TrackFilter::new(config), |filter| {
        ResourceArc::new(TrackFilterResource {
            filter: Mutex::new(filter),
        })
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn track_filter_state<'a>(env: Env<'a>, handle: ResourceArc<TrackFilterResource>) -> Term<'a> {
    match handle.filter.lock() {
        Ok(filter) => (atoms::ok(), state_out(filter.state())).encode(env),
        Err(_) => poisoned_resource(env),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn track_filter_dimension<'a>(env: Env<'a>, handle: ResourceArc<TrackFilterResource>) -> Term<'a> {
    match handle.filter.lock() {
        Ok(filter) => (atoms::ok(), filter.dimension()).encode(env),
        Err(_) => poisoned_resource(env),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn track_filter_acceleration_variance_spectral_density_m2_s3<'a>(
    env: Env<'a>,
    handle: ResourceArc<TrackFilterResource>,
) -> Term<'a> {
    match handle.filter.lock() {
        Ok(filter) => (
            atoms::ok(),
            filter.acceleration_variance_spectral_density_m2_s3(),
        )
            .encode(env),
        Err(_) => poisoned_resource(env),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn track_filter_predict<'a>(
    env: Env<'a>,
    handle: ResourceArc<TrackFilterResource>,
    dt_s: f64,
) -> Term<'a> {
    match handle.filter.lock() {
        Ok(mut filter) => encode_track_result(env, filter.predict(dt_s), |prediction| {
            prediction_out(&prediction)
        }),
        Err(_) => poisoned_resource(env),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn track_filter_predict_recorded<'a>(
    env: Env<'a>,
    handle: ResourceArc<TrackFilterResource>,
    dt_s: f64,
    history: ResourceArc<TrackRtsHistoryBuilderResource>,
) -> Term<'a> {
    let mut filter = match handle.filter.lock() {
        Ok(filter) => filter,
        Err(_) => return poisoned_resource(env),
    };
    let mut history = match history.builder.lock() {
        Ok(history) => history,
        Err(_) => return poisoned_resource(env),
    };
    encode_track_result(
        env,
        filter.predict_recorded(dt_s, &mut history),
        |prediction| prediction_out(&prediction),
    )
}

#[rustler::nif(schedule = "DirtyCpu")]
fn track_filter_position_innovation<'a>(
    env: Env<'a>,
    handle: ResourceArc<TrackFilterResource>,
    position_m: Vec<f64>,
    covariance_m2: Vec<Vec<f64>>,
) -> Term<'a> {
    match handle.filter.lock() {
        Ok(filter) => encode_track_result(
            env,
            filter.position_innovation(&position_m, &covariance_m2),
            |innovation| innovation_out(&innovation),
        ),
        Err(_) => poisoned_resource(env),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn track_filter_state_innovation<'a>(
    env: Env<'a>,
    handle: ResourceArc<TrackFilterResource>,
    state: Vec<f64>,
    covariance: Vec<Vec<f64>>,
) -> Term<'a> {
    match handle.filter.lock() {
        Ok(filter) => encode_track_result(
            env,
            filter.state_innovation(&state, &covariance),
            |innovation| innovation_out(&innovation),
        ),
        Err(_) => poisoned_resource(env),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn track_filter_update_position<'a>(
    env: Env<'a>,
    handle: ResourceArc<TrackFilterResource>,
    position_m: Vec<f64>,
    covariance_m2: Vec<Vec<f64>>,
) -> Term<'a> {
    match handle.filter.lock() {
        Ok(mut filter) => encode_track_result(
            env,
            filter.update_position(&position_m, &covariance_m2),
            |update| update_out(&update),
        ),
        Err(_) => poisoned_resource(env),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn track_filter_update_state<'a>(
    env: Env<'a>,
    handle: ResourceArc<TrackFilterResource>,
    state: Vec<f64>,
    covariance: Vec<Vec<f64>>,
) -> Term<'a> {
    match handle.filter.lock() {
        Ok(mut filter) => {
            encode_track_result(env, filter.update_state(&state, &covariance), |update| {
                update_out(&update)
            })
        }
        Err(_) => poisoned_resource(env),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn track_filter_update_position_gated<'a>(
    env: Env<'a>,
    handle: ResourceArc<TrackFilterResource>,
    position_m: Vec<f64>,
    covariance_m2: Vec<Vec<f64>>,
    confidence: f64,
) -> Term<'a> {
    match handle.filter.lock() {
        Ok(mut filter) => encode_track_result(
            env,
            filter.update_position_gated(&position_m, &covariance_m2, confidence),
            |update| gated_update_out(&update),
        ),
        Err(_) => poisoned_resource(env),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn track_filter_update_position_recorded<'a>(
    env: Env<'a>,
    handle: ResourceArc<TrackFilterResource>,
    position_m: Vec<f64>,
    covariance_m2: Vec<Vec<f64>>,
    history: ResourceArc<TrackRtsHistoryBuilderResource>,
) -> Term<'a> {
    let mut filter = match handle.filter.lock() {
        Ok(filter) => filter,
        Err(_) => return poisoned_resource(env),
    };
    let mut history = match history.builder.lock() {
        Ok(history) => history,
        Err(_) => return poisoned_resource(env),
    };
    encode_track_result(
        env,
        filter.update_position_recorded(&position_m, &covariance_m2, &mut history),
        |update| update_out(&update),
    )
}

#[rustler::nif(schedule = "DirtyCpu")]
fn track_filter_update_position_gated_recorded<'a>(
    env: Env<'a>,
    handle: ResourceArc<TrackFilterResource>,
    position_m: Vec<f64>,
    covariance_m2: Vec<Vec<f64>>,
    confidence: f64,
    history: ResourceArc<TrackRtsHistoryBuilderResource>,
) -> Term<'a> {
    let mut filter = match handle.filter.lock() {
        Ok(filter) => filter,
        Err(_) => return poisoned_resource(env),
    };
    let mut history = match history.builder.lock() {
        Ok(history) => history,
        Err(_) => return poisoned_resource(env),
    };
    encode_track_result(
        env,
        filter.update_position_gated_recorded(
            &position_m,
            &covariance_m2,
            confidence,
            &mut history,
        ),
        |update| gated_update_out(&update),
    )
}

#[rustler::nif(schedule = "DirtyCpu")]
fn track_filter_record_prediction_only<'a>(
    env: Env<'a>,
    handle: ResourceArc<TrackFilterResource>,
    history: ResourceArc<TrackRtsHistoryBuilderResource>,
) -> Term<'a> {
    let filter = match handle.filter.lock() {
        Ok(filter) => filter,
        Err(_) => return poisoned_resource(env),
    };
    let mut history = match history.builder.lock() {
        Ok(history) => history,
        Err(_) => return poisoned_resource(env),
    };
    encode_track_result(env, filter.record_prediction_only(&mut history), |_| {
        atoms::ok()
    })
}

#[rustler::nif]
fn track_rts_history_builder_new() -> ResourceArc<TrackRtsHistoryBuilderResource> {
    ResourceArc::new(TrackRtsHistoryBuilderResource {
        builder: Mutex::new(TrackRtsHistoryBuilder::empty()),
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn track_rts_history_builder_from_filter<'a>(
    env: Env<'a>,
    filter: ResourceArc<TrackFilterResource>,
) -> Term<'a> {
    match filter.filter.lock() {
        Ok(filter) => encode_track_result(
            env,
            TrackRtsHistoryBuilder::from_filter(&filter),
            |builder| {
                ResourceArc::new(TrackRtsHistoryBuilderResource {
                    builder: Mutex::new(builder),
                })
            },
        ),
        Err(_) => poisoned_resource(env),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn track_rts_history_builder_finish<'a>(
    env: Env<'a>,
    builder: ResourceArc<TrackRtsHistoryBuilderResource>,
) -> Term<'a> {
    match builder.builder.lock() {
        Ok(builder) => encode_track_result(env, builder.clone().finish(), |history| {
            ResourceArc::new(TrackRtsHistoryResource { history })
        }),
        Err(_) => poisoned_resource(env),
    }
}

#[rustler::nif]
fn track_rts_history_epoch_count(handle: ResourceArc<TrackRtsHistoryResource>) -> usize {
    handle.history.epochs.len()
}

#[rustler::nif]
fn track_rts_history_epochs(handle: ResourceArc<TrackRtsHistoryResource>) -> Vec<TrackRtsEpochOut> {
    handle.history.epochs.iter().map(epoch_out).collect()
}

#[rustler::nif(schedule = "DirtyCpu")]
fn track_smooth_rts<'a>(env: Env<'a>, history: ResourceArc<TrackRtsHistoryResource>) -> Term<'a> {
    encode_track_result(env, core_smooth_track_rts(&history.history), |track| {
        ResourceArc::new(SmoothedTrackResource { track })
    })
}

#[rustler::nif]
fn track_smoothed_epoch_count(handle: ResourceArc<SmoothedTrackResource>) -> usize {
    handle.track.epochs.len()
}

#[rustler::nif]
fn track_smoothed_epochs(handle: ResourceArc<SmoothedTrackResource>) -> Vec<SmoothedTrackEpochOut> {
    handle.track.epochs.iter().map(smoothed_epoch_out).collect()
}

fn config_from_term(config: TrackFilterConfigTerm) -> Result<TrackFilterConfig, TrackError> {
    TrackFilterConfig::from_position_velocity(
        frame_from_label(&config.frame)?,
        config.initial_t_s,
        config.initial_position_m,
        config.initial_velocity_m_s,
        config.initial_covariance,
        config.acceleration_variance_spectral_density_m2_s3,
    )
}

fn config_from_position_term(
    config: TrackFilterFromPositionTerm,
) -> Result<TrackFilterConfig, TrackError> {
    TrackFilterConfig::from_position(
        frame_from_label(&config.frame)?,
        config.initial_t_s,
        config.initial_position_m,
        config.position_covariance_m2,
        config.initial_velocity_variance_m2_s2,
        config.acceleration_variance_spectral_density_m2_s3,
    )
}

fn frame_from_label(label: &str) -> Result<TrackCoordinateFrame, TrackError> {
    match label.trim() {
        "ecef" | "ECEF" => Ok(TrackCoordinateFrame::Ecef),
        "enu" | "ENU" => Ok(TrackCoordinateFrame::Enu),
        "caller_defined_cartesian" | "callerDefinedCartesian" | "CALLER_DEFINED_CARTESIAN" => {
            Ok(TrackCoordinateFrame::CallerDefinedCartesian)
        }
        _ => Err(TrackError::InvalidInput {
            field: "frame",
            reason: "expected ecef, enu, or caller_defined_cartesian",
        }),
    }
}

fn frame_label(frame: TrackCoordinateFrame) -> String {
    match frame {
        TrackCoordinateFrame::Ecef => "ecef",
        TrackCoordinateFrame::Enu => "enu",
        TrackCoordinateFrame::CallerDefinedCartesian => "caller_defined_cartesian",
    }
    .to_string()
}

fn config_out(config: &TrackFilterConfig) -> TrackFilterConfigOut {
    TrackFilterConfigOut {
        frame: frame_label(config.frame),
        initial_t_s: config.initial_t_s,
        initial_position_m: config.initial_position_m.clone(),
        initial_velocity_m_s: config.initial_velocity_m_s.clone(),
        initial_covariance: config.initial_covariance.clone(),
        acceleration_variance_spectral_density_m2_s3: config
            .acceleration_variance_spectral_density_m2_s3,
        dimension: config.dimension(),
    }
}

fn state_out(state: &TrackState) -> TrackStateOut {
    TrackStateOut {
        frame: frame_label(state.frame),
        t_s: state.t_s,
        position_m: state.position_m.clone(),
        velocity_m_s: state.velocity_m_s.clone(),
        covariance: state.covariance.clone(),
        state_vector: state.state_vector(),
        position_covariance_m2: state.position_covariance_m2(),
        dimension: state.dimension(),
        state_dimension: state.state_dimension(),
    }
}

fn prediction_out(prediction: &TrackPrediction) -> TrackPredictionOut {
    TrackPredictionOut {
        dt_s: prediction.dt_s,
        transition: prediction.transition.clone(),
        process_noise: prediction.process_noise.clone(),
        predicted: state_out(&prediction.predicted),
    }
}

fn innovation_out(innovation: &TrackInnovation) -> TrackInnovationOut {
    TrackInnovationOut {
        innovation: innovation.innovation.clone(),
        innovation_covariance: innovation.innovation_covariance.clone(),
        nis: innovation.nis,
    }
}

fn gate_out(gate: NisGate) -> NisGateOut {
    NisGateOut {
        nis: gate.nis,
        threshold: gate.threshold,
        in_gate: gate.in_gate,
        dof: gate.dof,
    }
}

fn update_out(update: &TrackUpdate) -> TrackUpdateOut {
    TrackUpdateOut {
        predicted: state_out(&update.predicted),
        updated: state_out(&update.updated),
        innovation: innovation_out(&update.innovation),
        kalman_gain: update.kalman_gain.clone(),
    }
}

fn gated_update_out(update: &TrackGatedUpdate) -> TrackGatedUpdateOut {
    TrackGatedUpdateOut {
        gate: gate_out(update.gate),
        update: update.update.as_ref().map(update_out),
        state: state_out(&update.state),
    }
}

fn epoch_out(epoch: &TrackRtsEpoch) -> TrackRtsEpochOut {
    TrackRtsEpochOut {
        t_s: epoch.t_s,
        predicted: state_out(&epoch.predicted),
        updated: state_out(&epoch.updated),
        transition_from_previous: epoch.transition_from_previous.clone(),
    }
}

fn smoothed_epoch_out(epoch: &SmoothedTrackEpoch) -> SmoothedTrackEpochOut {
    SmoothedTrackEpochOut {
        t_s: epoch.t_s,
        state: state_out(&epoch.state),
        rts_gain_to_next: epoch.rts_gain_to_next.clone(),
    }
}

fn encode_track_result<'a, T, U, F>(
    env: Env<'a>,
    result: Result<T, TrackError>,
    mapper: F,
) -> Term<'a>
where
    U: Encoder,
    F: FnOnce(T) -> U,
{
    match result {
        Ok(value) => (atoms::ok(), mapper(value)).encode(env),
        Err(error) => track_error(env, error),
    }
}

fn track_error<'a>(env: Env<'a>, error: TrackError) -> Term<'a> {
    match error {
        TrackError::InvalidInput { field, reason } => {
            (atoms::error(), (atoms::invalid_input(), field, reason)).encode(env)
        }
        TrackError::DimensionMismatch {
            field,
            expected,
            actual,
        } => (
            atoms::error(),
            (atoms::dimension_mismatch(), field, expected, actual),
        )
            .encode(env),
        TrackError::NonPositiveSemidefinite { field } => {
            (atoms::error(), (atoms::non_positive_semidefinite(), field)).encode(env)
        }
        TrackError::NonPositiveDefinite { field } => {
            (atoms::error(), (atoms::non_positive_definite(), field)).encode(env)
        }
    }
}

fn poisoned_resource<'a>(env: Env<'a>) -> Term<'a> {
    (atoms::error(), atoms::poisoned_resource()).encode(env)
}
