//! Rustler boundary for scalar estimation and detection primitives.
//!
//! The numerical work is delegated to `sidereon-core::estimation`; this file
//! only translates tuple terms and stable error reasons.

use rustler::{Encoder, Env, Term};
use sidereon_core::estimation::{
    alpha_beta_apply_measurement, alpha_beta_filter_step, alpha_beta_predict,
    alpha_beta_steady_state_gains, cfar_ca_false_alarm_probability, cfar_ca_multiplier_from_pfa,
    cfar_ca_pfa_from_multiplier, cfar_ca_threshold, ewma_update, ewma_update_power_of_two,
    kalman_cv_steady_state_gains, mad_spread, nis_expected_value, nis_gate_test,
    nis_gate_threshold, nis_statistic, normalized_innovation, AlphaBetaGains, AlphaBetaState,
    PrimitiveError,
};

type StateTerm = (f64, f64);
type GainsTerm = (f64, f64);

mod atoms {
    rustler::atoms! {
        ok,
        error,
        invalid_input
    }
}

#[rustler::nif]
pub fn estimation_mad_gaussian_consistency() -> f64 {
    sidereon_core::estimation::MAD_GAUSSIAN_CONSISTENCY
}

#[rustler::nif]
pub fn estimation_alpha_beta_steady_state_gains<'a>(env: Env<'a>, tracking_index: f64) -> Term<'a> {
    encode_result(
        env,
        alpha_beta_steady_state_gains(tracking_index),
        |gains| (gains.alpha, gains.beta),
    )
}

#[rustler::nif]
pub fn estimation_alpha_beta_predict<'a>(env: Env<'a>, state: StateTerm, dt: f64) -> Term<'a> {
    encode_result(
        env,
        alpha_beta_predict(state_from_tuple(state), dt),
        state_to_tuple,
    )
}

#[rustler::nif]
pub fn estimation_alpha_beta_apply_measurement<'a>(
    env: Env<'a>,
    predicted: StateTerm,
    measurement: f64,
    dt: f64,
    gains: GainsTerm,
) -> Term<'a> {
    encode_result(
        env,
        alpha_beta_apply_measurement(
            state_from_tuple(predicted),
            measurement,
            dt,
            gains_from_tuple(gains),
        ),
        state_to_tuple,
    )
}

#[rustler::nif]
pub fn estimation_alpha_beta_filter_step<'a>(
    env: Env<'a>,
    state: StateTerm,
    measurement: f64,
    dt: f64,
    gains: GainsTerm,
) -> Term<'a> {
    encode_result(
        env,
        alpha_beta_filter_step(
            state_from_tuple(state),
            measurement,
            dt,
            gains_from_tuple(gains),
        ),
        |step| {
            (
                state_to_tuple(step.predicted),
                state_to_tuple(step.updated),
                step.innovation,
            )
        },
    )
}

#[rustler::nif]
pub fn estimation_kalman_cv_steady_state_gains<'a>(
    env: Env<'a>,
    tracking_index: f64,
    dt: f64,
    measurement_variance: f64,
) -> Term<'a> {
    encode_result(
        env,
        kalman_cv_steady_state_gains(tracking_index, dt, measurement_variance),
        |gains| (gains.position_gain, gains.rate_gain),
    )
}

#[rustler::nif]
pub fn estimation_normalized_innovation<'a>(
    env: Env<'a>,
    innovation: f64,
    innovation_variance: f64,
) -> Term<'a> {
    encode_result(
        env,
        normalized_innovation(innovation, innovation_variance),
        identity,
    )
}

#[rustler::nif]
pub fn estimation_nis<'a>(env: Env<'a>, innovation: f64, innovation_variance: f64) -> Term<'a> {
    encode_result(
        env,
        nis_statistic(innovation, innovation_variance),
        identity,
    )
}

#[rustler::nif]
pub fn estimation_nis_expected_value<'a>(env: Env<'a>, dof: usize) -> Term<'a> {
    encode_result(env, nis_expected_value(dof), identity)
}

#[rustler::nif]
pub fn estimation_nis_gate_threshold<'a>(env: Env<'a>, dof: usize, confidence: f64) -> Term<'a> {
    encode_result(env, nis_gate_threshold(dof, confidence), identity)
}

#[rustler::nif]
pub fn estimation_nis_gate<'a>(
    env: Env<'a>,
    innovation: f64,
    innovation_variance: f64,
    dof: usize,
    confidence: f64,
) -> Term<'a> {
    encode_result(
        env,
        nis_gate_test(innovation, innovation_variance, dof, confidence),
        |gate| (gate.nis, gate.threshold, gate.in_gate, gate.dof),
    )
}

#[rustler::nif]
pub fn estimation_mad<'a>(env: Env<'a>, values: Vec<f64>, scale_floor: f64) -> Term<'a> {
    encode_result(env, mad_spread(&values, scale_floor), identity)
}

#[rustler::nif]
pub fn estimation_ewma<'a>(env: Env<'a>, previous: f64, sample: f64, alpha: f64) -> Term<'a> {
    encode_result(env, ewma_update(previous, sample, alpha), identity)
}

#[rustler::nif]
pub fn estimation_ewma_power_of_two<'a>(
    env: Env<'a>,
    previous: f64,
    sample: f64,
    shift: u32,
) -> Term<'a> {
    encode_result(
        env,
        ewma_update_power_of_two(previous, sample, shift),
        identity,
    )
}

#[rustler::nif]
pub fn estimation_cfar_ca_multiplier_from_pfa<'a>(
    env: Env<'a>,
    searched_cells: usize,
    false_alarm_probability: f64,
) -> Term<'a> {
    encode_result(
        env,
        cfar_ca_multiplier_from_pfa(searched_cells, false_alarm_probability),
        identity,
    )
}

#[rustler::nif]
pub fn estimation_cfar_ca_pfa_from_multiplier<'a>(
    env: Env<'a>,
    searched_cells: usize,
    multiplier: f64,
) -> Term<'a> {
    encode_result(
        env,
        cfar_ca_pfa_from_multiplier(searched_cells, multiplier),
        identity,
    )
}

#[rustler::nif]
pub fn estimation_cfar_ca_threshold<'a>(
    env: Env<'a>,
    searched_cells: usize,
    false_alarm_probability: f64,
    noise_level: f64,
) -> Term<'a> {
    encode_result(
        env,
        cfar_ca_threshold(searched_cells, false_alarm_probability, noise_level),
        identity,
    )
}

#[rustler::nif]
pub fn estimation_cfar_ca_false_alarm_probability<'a>(
    env: Env<'a>,
    searched_cells: usize,
    threshold: f64,
    noise_level: f64,
) -> Term<'a> {
    encode_result(
        env,
        cfar_ca_false_alarm_probability(searched_cells, threshold, noise_level),
        identity,
    )
}

fn encode_result<'a, T, U, F>(
    env: Env<'a>,
    result: Result<T, PrimitiveError>,
    mapper: F,
) -> Term<'a>
where
    U: Encoder,
    F: FnOnce(T) -> U,
{
    match result {
        Ok(value) => (atoms::ok(), mapper(value)).encode(env),
        Err(error) => (atoms::error(), primitive_error_reason(error)).encode(env),
    }
}

fn primitive_error_reason(error: PrimitiveError) -> (rustler::Atom, String, String) {
    match error {
        PrimitiveError::InvalidInput { field, reason } => (
            atoms::invalid_input(),
            field.to_string(),
            reason.to_string(),
        ),
    }
}

fn state_from_tuple((level, rate): StateTerm) -> AlphaBetaState {
    AlphaBetaState { level, rate }
}

fn state_to_tuple(state: AlphaBetaState) -> StateTerm {
    (state.level, state.rate)
}

fn gains_from_tuple((alpha, beta): GainsTerm) -> AlphaBetaGains {
    AlphaBetaGains { alpha, beta }
}

fn identity(value: f64) -> f64 {
    value
}
