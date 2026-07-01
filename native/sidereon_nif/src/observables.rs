//! Rustler boundary for GNSS observable prediction.
//!
//! Pure glue over `sidereon_core::observables`: decode the already-loaded
//! SP3/broadcast resource handle, satellite token pieces, receive epoch, and
//! receiver ECEF; call the crate's predictor; encode the result for Elixir.

use crate::broadcast::BroadcastResource;
use crate::precise_samples::SampleSourceResource;
use crate::sp3::Sp3Resource;
use rustler::{Encoder, Env, Error, NifResult, ResourceArc, Term};
use sidereon_core::observables::{
    j2000_seconds_from_split, predict, predict_batch, predict_ranges as core_predict_ranges,
    ObservablesError, PredictOptions, PredictedObservables, PredictRequest, RangePrediction,
    RangePredictionRequest,
};
use sidereon_core::{GnssSatelliteId, GnssSystem};

type Vec3 = (f64, f64, f64);
/// One batch request from Elixir: `{system_letter, prn, jd_whole, jd_fraction,
/// receiver_ecef_m}`. The receive epoch is split Julian-date, matching the
/// single-shot `sp3_observables` boundary.
type BatchRequestTerm = (String, u8, f64, f64, Vec3);

mod atoms {
    rustler::atoms! {
        ok,
        error,
        no_ephemeris,
        invalid_input,
        prediction_missing
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

/// Predict observables for many `{satellite, epoch, receiver}` requests against
/// one loaded SP3 product in a single boundary crossing. Element `i` of the
/// returned list is the per-request `{:ok, _}` / `{:error, _}` for `requests[i]`.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn sp3_predict_batch<'a>(
    env: Env<'a>,
    handle: ResourceArc<Sp3Resource>,
    requests: Vec<BatchRequestTerm>,
    carrier_hz: f64,
    light_time: bool,
    sagnac: bool,
) -> Term<'a> {
    let options = PredictOptions {
        carrier_hz,
        light_time,
        sagnac,
    };
    // Resolve every request's satellite/epoch up front so a malformed request is
    // reported in place (preserving index alignment) without entering the core.
    let mut prepared: Vec<Result<PredictRequest, PredictFailure>> =
        Vec::with_capacity(requests.len());
    for (system_letter, prn, jd_whole, jd_fraction, receiver_ecef_m) in requests {
        let resolved = sat_from_parts(&system_letter, prn).and_then(|sat| {
            let t_rx_j2000_s =
                j2000_seconds_from_split(jd_whole, jd_fraction).map_err(PredictFailure::from)?;
            Ok((sat, vec3_to_array(receiver_ecef_m), t_rx_j2000_s))
        });
        prepared.push(resolved);
    }

    // The valid requests are predicted as a batch in the core; the invalid ones
    // are stitched back into their original slots.
    let valid: Vec<PredictRequest> = prepared.iter().filter_map(|r| r.clone().ok()).collect();
    let mut predicted = predict_batch(&handle.sp3, &valid, options).into_iter();

    let rows: Vec<Term> = prepared
        .into_iter()
        .map(|prep| match prep {
            // A valid request consumes the next core prediction. A short result
            // stream (fewer predictions than valid requests) is a core-contract
            // breach, not a request fault; report this slot as a typed error
            // rather than panic across the NIF boundary.
            Ok(_) => match predicted.next() {
                Some(result) => encode_result(env, result.map_err(PredictFailure::from)),
                None => (atoms::error(), atoms::prediction_missing()).encode(env),
            },
            Err(failure) => encode_result(env, Err(failure)),
        })
        .collect();

    rows.encode(env)
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
        Err(failure) => (atoms::error(), failure_reason(env, failure)).encode(env),
    }
}

/// The error reason term for a prediction failure (without the `:error` tag):
/// a typed atom for the recognized failure classes, or the crate's message for
/// an ephemeris error passed through verbatim.
fn failure_reason(env: Env<'_>, failure: PredictFailure) -> Term<'_> {
    match failure {
        PredictFailure::NoEphemeris => atoms::no_ephemeris().encode(env),
        PredictFailure::InvalidInput => atoms::invalid_input().encode(env),
        PredictFailure::Reason(reason) => reason.encode(env),
    }
}

/// One batch range request from Elixir: `{system_letter, prn, receiver_ecef_m,
/// t_rx_j2000_s}`. The receive epoch is seconds since J2000 in the source's own
/// time scale, matching the core [`RangePredictionRequest`].
type RangeRequestTerm = (String, u8, Vec3, f64);
/// One batch range result: `{geometric_range_m, sat_clock_s, transmit_time_j2000_s,
/// sat_pos_ecef_m}`. The clock is `nil` when the source carries no clock estimate.
type RangeResultTerm = (f64, Option<f64>, f64, Vec3);

fn range_to_tuple(prediction: &RangePrediction) -> RangeResultTerm {
    (
        prediction.geometric_range_m,
        prediction.sat_clock_s,
        prediction.transmit_time_j2000_s,
        array_to_vec3(prediction.sat_pos_ecef_m),
    )
}

/// Predict geometric ranges for many `{satellite, receiver, epoch}` requests
/// against one loaded precise-ephemeris source in a single boundary crossing.
///
/// `source` accepts either an SP3 handle or a sample-built source handle; both
/// implement the core `ObservableEphemerisSource` trait, so the batch drives the
/// identical transmit-time geometry regardless of how the source was built.
/// Returns `{:ok, [result]}` on success, or the first request's `{:error, _}`
/// (the core range batch aborts on the first failing request). Dirty-CPU: the
/// request list is unbounded relative to the 1 ms NIF budget.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn predict_ranges_batch<'a>(
    env: Env<'a>,
    source: Term<'a>,
    requests: Vec<RangeRequestTerm>,
    light_time: bool,
    sagnac: bool,
) -> NifResult<Term<'a>> {
    // Resolve every request's satellite up front so a malformed token is
    // reported without entering the core.
    let mut resolved = Vec::with_capacity(requests.len());
    for (system_letter, prn, receiver_ecef_m, t_rx_j2000_s) in requests {
        let sat = match sat_from_parts(&system_letter, prn) {
            Ok(sat) => sat,
            Err(failure) => return Ok((atoms::error(), failure_reason(env, failure)).encode(env)),
        };
        resolved.push(RangePredictionRequest {
            sat,
            receiver_ecef_m: vec3_to_array(receiver_ecef_m),
            t_rx_j2000_s,
        });
    }

    let options = PredictOptions {
        carrier_hz: 0.0,
        light_time,
        sagnac,
    };
    let mut out = vec![
        RangePrediction {
            geometric_range_m: 0.0,
            sat_clock_s: None,
            transmit_time_j2000_s: 0.0,
            sat_pos_ecef_m: [0.0; 3],
        };
        resolved.len()
    ];

    // The source is one of the two precise-ephemeris resource handles; dispatch
    // on whichever the term decodes as.
    let result = if let Ok(handle) = source.decode::<ResourceArc<Sp3Resource>>() {
        core_predict_ranges(&handle.sp3, &resolved, options, &mut out)
    } else if let Ok(handle) = source.decode::<ResourceArc<SampleSourceResource>>() {
        core_predict_ranges(&handle.source, &resolved, options, &mut out)
    } else {
        return Err(Error::Term(Box::new(
            "expected an SP3 or precise-sample source handle",
        )));
    };

    Ok(match result {
        Ok(()) => {
            let rows: Vec<RangeResultTerm> = out.iter().map(range_to_tuple).collect();
            (atoms::ok(), rows).encode(env)
        }
        Err(err) => (atoms::error(), failure_reason(env, PredictFailure::from(err))).encode(env),
    })
}
