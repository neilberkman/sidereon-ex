//! Rustler boundary for GNSS receiver velocity solves.
//!
//! This module decodes loaded ephemeris handles, observation terms, epoch
//! scalars, and receiver position, then calls `sidereon_core::velocity`.
//! No least-squares row construction or Doppler algebra lives at this boundary.

use rustler::{Encoder, Env, NifResult, ResourceArc, Term};
use sidereon_core::observables::j2000_seconds_from_split;
use sidereon_core::velocity::{
    doppler_to_range_rate, range_rate_to_doppler, solve, VelocityError, VelocityObservable,
    VelocityObservation, VelocitySolution, VelocitySolveOptions,
};
use sidereon_core::{GnssSatelliteId, GnssSystem};

use crate::broadcast::BroadcastResource;
use crate::sp3::Sp3Resource;

type Vec3 = (f64, f64, f64);
type ObservationTerm = (String, u8, f64, f64, f64);

mod atoms {
    rustler::atoms! {
        ok,
        error,
        no_observations,
        too_few_satellites,
        singular_geometry,
        duplicate_observation,
        invalid_carrier,
        invalid_observable,
        invalid_epoch,
        invalid_input,
        invalid_observation,
        invalid_receiver_state
    }
}

#[rustler::nif]
pub fn velocity_doppler_to_range_rate(doppler_hz: f64, carrier_hz: f64) -> NifResult<f64> {
    doppler_to_range_rate(doppler_hz, carrier_hz).map_err(crate::errors::invalid_input)
}

#[rustler::nif]
pub fn velocity_range_rate_to_doppler(range_rate_m_s: f64, carrier_hz: f64) -> NifResult<f64> {
    range_rate_to_doppler(range_rate_m_s, carrier_hz).map_err(crate::errors::invalid_input)
}

#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
pub fn sp3_velocity_solve<'a>(
    env: Env<'a>,
    handle: ResourceArc<Sp3Resource>,
    observations: Vec<ObservationTerm>,
    jd_whole: f64,
    jd_fraction: f64,
    receiver_ecef_m: Vec3,
    observable: String,
    light_time: bool,
    sagnac: bool,
) -> Term<'a> {
    let t_rx_j2000_s = match j2000_seconds_from_split(jd_whole, jd_fraction) {
        Ok(t) => t,
        Err(_) => return (atoms::error(), atoms::invalid_epoch()).encode(env),
    };
    let result = decode_observable(&observable).map(|observable| {
        solve(
            &handle.sp3,
            &decode_observations(observations),
            vec3_to_array(receiver_ecef_m),
            t_rx_j2000_s,
            VelocitySolveOptions {
                observable,
                light_time,
                sagnac,
            },
        )
    });
    encode_nested_result(env, result)
}

#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
pub fn broadcast_velocity_solve<'a>(
    env: Env<'a>,
    handle: ResourceArc<BroadcastResource>,
    observations: Vec<ObservationTerm>,
    t_rx_j2000_s: f64,
    receiver_ecef_m: Vec3,
    observable: String,
    light_time: bool,
    sagnac: bool,
) -> Term<'a> {
    let result = decode_observable(&observable).map(|observable| {
        solve(
            &handle.store,
            &decode_observations(observations),
            vec3_to_array(receiver_ecef_m),
            t_rx_j2000_s,
            VelocitySolveOptions {
                observable,
                light_time,
                sagnac,
            },
        )
    });
    encode_nested_result(env, result)
}

fn decode_observable(value: &str) -> Result<VelocityObservable, ()> {
    match value {
        "range_rate" => Ok(VelocityObservable::RangeRate),
        "doppler" => Ok(VelocityObservable::Doppler),
        _ => Err(()),
    }
}

fn decode_observations(observations: Vec<ObservationTerm>) -> Vec<VelocityObservation> {
    observations
        .into_iter()
        .filter_map(
            |(system_letter, prn, value, carrier_hz, sat_clock_drift_s_s)| {
                sat_from_parts(&system_letter, prn).map(|satellite_id| VelocityObservation {
                    satellite_id,
                    value,
                    carrier_hz,
                    sat_clock_drift_s_s,
                })
            },
        )
        .collect()
}

fn sat_from_parts(system_letter: &str, prn: u8) -> Option<GnssSatelliteId> {
    let letter = system_letter.chars().next()?;
    let system = GnssSystem::from_letter(letter)?;
    GnssSatelliteId::new(system, prn).ok()
}

fn vec3_to_array(vec: Vec3) -> [f64; 3] {
    [vec.0, vec.1, vec.2]
}

fn array_to_vec3(array: [f64; 3]) -> Vec3 {
    (array[0], array[1], array[2])
}

fn encode_nested_result<'a>(
    env: Env<'a>,
    result: Result<Result<VelocitySolution, VelocityError>, ()>,
) -> Term<'a> {
    match result {
        Ok(Ok(solution)) => encode_solution(env, &solution),
        Ok(Err(error)) => encode_error(env, error),
        Err(()) => (atoms::error(), atoms::invalid_observable()).encode(env),
    }
}

fn encode_solution<'a>(env: Env<'a>, solution: &VelocitySolution) -> Term<'a> {
    let residuals: Vec<(String, f64)> = solution
        .residuals_m_s
        .iter()
        .map(|(sat, residual)| (sat.to_string(), *residual))
        .collect();
    let used_sats: Vec<String> = solution.used_sats.iter().map(ToString::to_string).collect();
    (
        atoms::ok(),
        (
            array_to_vec3(solution.velocity_m_s),
            solution.speed_m_s,
            solution.clock_drift_s_s,
            residuals,
            used_sats,
        ),
    )
        .encode(env)
}

fn encode_error<'a>(env: Env<'a>, error: VelocityError) -> Term<'a> {
    let reason = match error {
        VelocityError::NoObservations => atoms::no_observations().encode(env),
        VelocityError::TooFewSatellites { used, required } => {
            (atoms::too_few_satellites(), used as u64, required as u64).encode(env)
        }
        VelocityError::SingularGeometry => atoms::singular_geometry().encode(env),
        VelocityError::DuplicateObservation { satellite_id } => {
            (atoms::duplicate_observation(), satellite_id.to_string()).encode(env)
        }
        VelocityError::InvalidCarrier { satellite_id } => {
            (atoms::invalid_carrier(), satellite_id.to_string()).encode(env)
        }
        VelocityError::InvalidInput { .. } => atoms::invalid_input().encode(env),
        VelocityError::InvalidObservation { satellite_id } => {
            (atoms::invalid_observation(), satellite_id.to_string()).encode(env)
        }
        VelocityError::InvalidReceiverState => atoms::invalid_receiver_state().encode(env),
    };
    (atoms::error(), reason).encode(env)
}
