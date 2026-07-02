use rustler::{Encoder, Env, Error, NifResult, Term};
use sidereon_core::astro::forces::r#trait::ForceModel;
use sidereon_core::astro::forces::{DragParameters, SpaceWeather};
use sidereon_core::astro::propagator::decay::{estimate_decay, DecayConfig};
use sidereon_core::astro::propagator::{
    IntegratorOptions, PropagationContext, PropagationForceModel,
};
use sidereon_core::astro::state::CartesianState;

use crate::errors;

type Vec3 = (f64, f64, f64);

mod atoms {
    rustler::atoms! {
        ok,
        error,
        invalid_input,
        no_decay_within_horizon,
        scan_budget_exhausted,
        propagation_failed
    }
}

#[derive(Debug, Clone, rustler::NifMap)]
pub(crate) struct DragParametersTerm {
    bc_factor_m2_kg: f64,
    f107: f64,
    f107a: f64,
    ap: f64,
    cutoff_altitude_km: f64,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct SpaceWeatherTerm {
    f107: f64,
    f107a: f64,
    ap: f64,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct CartesianStateTerm {
    epoch_tdb_seconds: f64,
    position_km: Vec3,
    velocity_km_s: Vec3,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct DecayEstimateTerm {
    time_to_decay_s: f64,
    reentry_state: CartesianStateTerm,
    reentry_altitude_km: f64,
}

pub(crate) fn decode_drag_parameters(term: Term<'_>) -> NifResult<DragParameters> {
    let decoded: DragParametersTerm = term.decode()?;
    DragParameters::from_bc_factor_m2_kg(
        decoded.bc_factor_m2_kg,
        SpaceWeather {
            f107: decoded.f107,
            f107a: decoded.f107a,
            ap: decoded.ap,
        },
        decoded.cutoff_altitude_km,
    )
    .map_err(errors::invalid_input)
}

fn params_to_term(params: DragParameters) -> DragParametersTerm {
    let sw = params.space_weather();
    DragParametersTerm {
        bc_factor_m2_kg: params.bc_factor_m2_kg(),
        f107: sw.f107,
        f107a: sw.f107a,
        ap: sw.ap,
        cutoff_altitude_km: params.cutoff_altitude_km(),
    }
}

fn decode_space_weather(term: SpaceWeatherTerm) -> SpaceWeather {
    SpaceWeather {
        f107: term.f107,
        f107a: term.f107a,
        ap: term.ap,
    }
}

fn state_from_term(term: CartesianStateTerm) -> CartesianState {
    CartesianState::new(
        term.epoch_tdb_seconds,
        [term.position_km.0, term.position_km.1, term.position_km.2],
        [
            term.velocity_km_s.0,
            term.velocity_km_s.1,
            term.velocity_km_s.2,
        ],
    )
}

fn state_to_term(state: CartesianState) -> CartesianStateTerm {
    let position = state.position_array();
    let velocity = state.velocity_array();
    CartesianStateTerm {
        epoch_tdb_seconds: state.epoch_tdb_seconds,
        position_km: (position[0], position[1], position[2]),
        velocity_km_s: (velocity[0], velocity[1], velocity[2]),
    }
}

fn force_model(name: &str) -> NifResult<PropagationForceModel> {
    Ok(match name {
        "twobody" => PropagationForceModel::TwoBody,
        "j2" => PropagationForceModel::TwoBodyJ2,
        _ => return Err(Error::Term(Box::new("unknown force model"))),
    })
}

#[rustler::nif]
fn drag_space_weather_default() -> SpaceWeatherTerm {
    let sw = SpaceWeather::default();
    SpaceWeatherTerm {
        f107: sw.f107,
        f107a: sw.f107a,
        ap: sw.ap,
    }
}

#[rustler::nif]
fn drag_parameters_from_area_mass<'a>(
    env: Env<'a>,
    cd: f64,
    area_m2: f64,
    mass_kg: f64,
    space_weather: SpaceWeatherTerm,
    cutoff_altitude_km: f64,
) -> Term<'a> {
    match DragParameters::from_area_mass(
        cd,
        area_m2,
        mass_kg,
        decode_space_weather(space_weather),
        cutoff_altitude_km,
    ) {
        Ok(params) => (atoms::ok(), params_to_term(params)).encode(env),
        Err(_) => (atoms::error(), atoms::invalid_input()).encode(env),
    }
}

#[rustler::nif]
fn drag_parameters_from_bc_factor<'a>(
    env: Env<'a>,
    bc_factor_m2_kg: f64,
    space_weather: SpaceWeatherTerm,
    cutoff_altitude_km: f64,
) -> Term<'a> {
    match DragParameters::from_bc_factor_m2_kg(
        bc_factor_m2_kg,
        decode_space_weather(space_weather),
        cutoff_altitude_km,
    ) {
        Ok(params) => (atoms::ok(), params_to_term(params)).encode(env),
        Err(_) => (atoms::error(), atoms::invalid_input()).encode(env),
    }
}

#[rustler::nif]
fn drag_parameters_from_ballistic_coefficient<'a>(
    env: Env<'a>,
    bc_kg_m2: f64,
    space_weather: SpaceWeatherTerm,
    cutoff_altitude_km: f64,
) -> Term<'a> {
    match DragParameters::from_ballistic_coefficient(
        bc_kg_m2,
        decode_space_weather(space_weather),
        cutoff_altitude_km,
    ) {
        Ok(params) => (atoms::ok(), params_to_term(params)).encode(env),
        Err(_) => (atoms::error(), atoms::invalid_input()).encode(env),
    }
}

#[rustler::nif]
fn drag_force_acceleration<'a>(
    env: Env<'a>,
    params: Term<'a>,
    state: CartesianStateTerm,
) -> NifResult<Term<'a>> {
    let force = decode_drag_parameters(params)?.to_force();
    let state = state_from_term(state);
    Ok(
        match force.acceleration(&state, &PropagationContext::default()) {
            Ok(a) => (atoms::ok(), (a.x, a.y, a.z)).encode(env),
            Err(_) => (atoms::error(), atoms::invalid_input()).encode(env),
        },
    )
}

#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
fn drag_estimate_decay<'a>(
    env: Env<'a>,
    state: CartesianStateTerm,
    params: Term<'a>,
    force_model_name: String,
    abs_tol: f64,
    rel_tol: f64,
    reentry_altitude_km: f64,
    scan_step_s: f64,
    crossing_tolerance_s: f64,
    max_duration_s: f64,
    max_scan_samples: u32,
) -> NifResult<Term<'a>> {
    let mut config = DecayConfig::new(decode_drag_parameters(params)?)
        .with_force_model(force_model(&force_model_name)?)
        .with_options(IntegratorOptions {
            abs_tol,
            rel_tol,
            ..IntegratorOptions::default()
        })
        .with_reentry_altitude_km(reentry_altitude_km)
        .with_scan_step_s(scan_step_s)
        .with_crossing_tolerance_s(crossing_tolerance_s)
        .with_max_duration_s(max_duration_s)
        .with_max_scan_samples(max_scan_samples);
    config.mu_km3_s2 = None;

    Ok(match estimate_decay(state_from_term(state), &config) {
        Ok(estimate) => (
            atoms::ok(),
            DecayEstimateTerm {
                time_to_decay_s: estimate.time_to_decay_s,
                reentry_state: state_to_term(estimate.reentry_state),
                reentry_altitude_km: estimate.reentry_altitude_km,
            },
        )
            .encode(env),
        Err(error) => match error {
            sidereon_core::astro::propagator::decay::DecayError::NoDecayWithinHorizon {
                horizon_s,
            } => (
                atoms::error(),
                (atoms::no_decay_within_horizon(), horizon_s),
            )
                .encode(env),
            sidereon_core::astro::propagator::decay::DecayError::ScanBudgetExhausted {
                scanned_s,
                samples,
            } => (
                atoms::error(),
                (atoms::scan_budget_exhausted(), scanned_s, samples),
            )
                .encode(env),
            sidereon_core::astro::propagator::decay::DecayError::Propagation(_) => {
                (atoms::error(), atoms::propagation_failed()).encode(env)
            }
            sidereon_core::astro::propagator::decay::DecayError::InvalidConfig(_) => {
                (atoms::error(), atoms::invalid_input()).encode(env)
            }
        },
    })
}
