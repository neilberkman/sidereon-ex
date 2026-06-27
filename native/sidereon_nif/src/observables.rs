//! Rustler boundary for GNSS observable prediction.
//!
//! Pure glue over `sidereon_core::observables`: decode the already-loaded
//! SP3/broadcast resource handle, satellite token pieces, receive epoch, and
//! receiver ECEF; call the crate's predictor; encode the result for Elixir.

use crate::broadcast::BroadcastResource;
use crate::sp3::Sp3Resource;
use rustler::{Encoder, Env, ResourceArc, Term};
use sidereon_core::observables::{
    j2000_seconds_from_split, predict, ObservablesError, PredictOptions, PredictedObservables,
};
use sidereon_core::{GnssSatelliteId, GnssSystem};

type Vec3 = (f64, f64, f64);

mod atoms {
    rustler::atoms! {
        ok,
        error,
        no_ephemeris,
        invalid_input
    }
}

#[rustler::nif]
#[allow(clippy::too_many_arguments)]
pub fn sp3_observables<'a>(
    env: Env<'a>,
    handle: ResourceArc<Sp3Resource>,
    system_letter: String,
    prn: u8,
    jd_whole: f64,
    jd_fraction: f64,
    receiver_ecef_m: Vec3,
    carrier_hz: f64,
    light_time: bool,
    sagnac: bool,
) -> Term<'a> {
    let result = sat_from_parts(&system_letter, prn).and_then(|sat| {
        let t_rx_j2000_s =
            j2000_seconds_from_split(jd_whole, jd_fraction).map_err(PredictFailure::from)?;
        predict(
            &handle.sp3,
            sat,
            vec3_to_array(receiver_ecef_m),
            t_rx_j2000_s,
            PredictOptions {
                carrier_hz,
                light_time,
                sagnac,
            },
        )
        .map_err(PredictFailure::from)
    });
    encode_result(env, result)
}

#[rustler::nif]
#[allow(clippy::too_many_arguments)]
pub fn broadcast_observables<'a>(
    env: Env<'a>,
    handle: ResourceArc<BroadcastResource>,
    system_letter: String,
    prn: u8,
    t_rx_j2000_s: f64,
    receiver_ecef_m: Vec3,
    carrier_hz: f64,
    light_time: bool,
    sagnac: bool,
) -> Term<'a> {
    let result = sat_from_parts(&system_letter, prn).and_then(|sat| {
        predict(
            &handle.store,
            sat,
            vec3_to_array(receiver_ecef_m),
            t_rx_j2000_s,
            PredictOptions {
                carrier_hz,
                light_time,
                sagnac,
            },
        )
        .map_err(PredictFailure::from)
    });
    encode_result(env, result)
}

#[derive(Debug, Clone)]
enum PredictFailure {
    NoEphemeris,
    InvalidInput,
    Reason(String),
}

impl From<ObservablesError> for PredictFailure {
    fn from(value: ObservablesError) -> Self {
        match value {
            ObservablesError::NoEphemeris => Self::NoEphemeris,
            ObservablesError::InvalidInput { .. } => Self::InvalidInput,
            ObservablesError::Ephemeris(err) => Self::Reason(err.to_string()),
        }
    }
}

fn sat_from_parts(system_letter: &str, prn: u8) -> Result<GnssSatelliteId, PredictFailure> {
    let Some(letter) = system_letter.chars().next() else {
        return Err(PredictFailure::Reason(
            "empty GNSS system letter".to_string(),
        ));
    };
    let Some(system) = GnssSystem::from_letter(letter) else {
        return Err(PredictFailure::Reason(format!(
            "unknown GNSS system letter {system_letter:?}"
        )));
    };
    GnssSatelliteId::new(system, prn).map_err(|_| PredictFailure::InvalidInput)
}

fn vec3_to_array(vec: Vec3) -> [f64; 3] {
    [vec.0, vec.1, vec.2]
}

fn array_to_vec3(array: [f64; 3]) -> Vec3 {
    (array[0], array[1], array[2])
}

fn encode_result<'a>(
    env: Env<'a>,
    result: Result<PredictedObservables, PredictFailure>,
) -> Term<'a> {
    match result {
        Ok(obs) => {
            let clock = match obs.sat_clock_s {
                Some(clock_s) => clock_s.encode(env),
                None => rustler::types::atom::nil().encode(env),
            };
            let scalars = vec![
                obs.geometric_range_m.encode(env),
                obs.range_rate_m_s.encode(env),
                obs.doppler_hz.encode(env),
                clock,
                obs.elevation_deg.encode(env),
                obs.azimuth_deg.encode(env),
                obs.transmit_offset_us.encode(env),
                obs.transmit_time_j2000_s.encode(env),
            ];
            let vectors = vec![
                array_to_vec3(obs.los_unit).encode(env),
                array_to_vec3(obs.sat_pos_ecef_m).encode(env),
                array_to_vec3(obs.sat_velocity_m_s).encode(env),
            ];
            (atoms::ok(), (scalars, vectors)).encode(env)
        }
        Err(PredictFailure::NoEphemeris) => (atoms::error(), atoms::no_ephemeris()).encode(env),
        Err(PredictFailure::InvalidInput) => (atoms::error(), atoms::invalid_input()).encode(env),
        Err(PredictFailure::Reason(reason)) => (atoms::error(), reason).encode(env),
    }
}
