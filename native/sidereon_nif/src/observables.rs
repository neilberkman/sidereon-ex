//! Rustler boundary for GNSS observable prediction.
//!
//! Pure glue over `sidereon_core::observables`: decode the already-loaded
//! SP3/broadcast resource handle, satellite token pieces, receive epoch, and
//! receiver ECEF; call the crate's predictor; encode the result for Elixir.

use crate::broadcast::BroadcastResource;
use crate::iono::IonexResource;
use crate::observable_states::{MappedPreciseInterpolantResource, PreciseInterpolantResource};
use crate::precise_samples::SampleSourceResource;
use crate::sp3::Sp3Resource;
use rustler::{Encoder, Env, Error, NifResult, ResourceArc, Term};
use sidereon_core::atmosphere::ionosphere::{IonoModel, KlobucharParams};
use sidereon_core::atmosphere::troposphere::{MappingModel, Met};
use sidereon_core::observables::{
    emission_media_batch_at_j2000_s, j2000_seconds_from_split, predict, predict_batch,
    predict_ranges as core_predict_ranges, EmissionMediaBatch, EmissionMediaBatchOptions,
    EmissionMediaStatus, ObservableEphemerisSource, ObservableIonosphereCorrection,
    ObservableMediaOptions, ObservableTroposphereCorrection, ObservablesError, PredictOptions,
    PredictRequest, PredictedObservables, RangePrediction, RangePredictionRequest,
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
        prediction_missing,
        valid,
        gap,
        below_elevation_cutoff
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
        let mut options = PredictOptions::default();
        options.carrier_hz = carrier_hz;
        options.light_time = light_time;
        options.sagnac = sagnac;
        predict(
            &handle.sp3,
            sat,
            vec3_to_array(receiver_ecef_m),
            t_rx_j2000_s,
            options,
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
        let mut options = PredictOptions::default();
        options.carrier_hz = carrier_hz;
        options.light_time = light_time;
        options.sagnac = sagnac;
        predict(
            &handle.store,
            sat,
            vec3_to_array(receiver_ecef_m),
            t_rx_j2000_s,
            options,
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
    let mut options = PredictOptions::default();
    options.carrier_hz = carrier_hz;
    options.light_time = light_time;
    options.sagnac = sagnac;
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
            ObservablesError::InvalidInput { .. } | ObservablesError::Media(_) => {
                Self::InvalidInput
            }
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
type EmissionRequestTerm = (String, u8, f64);
type Coeff4 = (f64, f64, f64, f64);
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
/// `source` accepts an SP3 handle, a sample-built source handle, or a cached
/// interpolant handle; all implement the core `ObservableEphemerisSource` trait,
/// so the batch drives the identical transmit-time geometry regardless of how
/// the source was built.
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
        resolved.push(RangePredictionRequest::new(
            sat,
            vec3_to_array(receiver_ecef_m),
            t_rx_j2000_s,
        ));
    }

    let mut options = PredictOptions::default();
    options.carrier_hz = 0.0;
    options.light_time = light_time;
    options.sagnac = sagnac;
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
    } else if let Ok(handle) = source.decode::<ResourceArc<PreciseInterpolantResource>>() {
        core_predict_ranges(&handle.interpolant, &resolved, options, &mut out)
    } else if let Ok(handle) = source.decode::<ResourceArc<MappedPreciseInterpolantResource>>() {
        core_predict_ranges(&*handle.read(), &resolved, options, &mut out)
    } else {
        return Err(Error::Term(Box::new(
            "expected an SP3, precise-sample, or precise-interpolant source handle",
        )));
    };

    Ok(match result {
        Ok(()) => {
            let rows: Vec<RangeResultTerm> = out.iter().map(range_to_tuple).collect();
            (atoms::ok(), rows).encode(env)
        }
        Err(err) => (
            atoms::error(),
            failure_reason(env, PredictFailure::from(err)),
        )
            .encode(env),
    })
}

/// Predict emission-epoch state plus media corrections for many satellites.
#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
pub fn emission_media_batch<'a>(
    env: Env<'a>,
    source: Term<'a>,
    requests: Vec<EmissionRequestTerm>,
    receiver_ecef_m: Vec3,
    carrier_hz: f64,
    troposphere: Term<'a>,
    ionosphere: Term<'a>,
    min_elevation_rad: Term<'a>,
) -> NifResult<Term<'a>> {
    let mut satellites = Vec::with_capacity(requests.len());
    let mut epochs = Vec::with_capacity(requests.len());
    for (system_letter, prn, emission_epoch_j2000_s) in requests {
        match sat_from_parts(&system_letter, prn) {
            Ok(sat) => {
                satellites.push(sat);
                epochs.push(emission_epoch_j2000_s);
            }
            Err(failure) => return Ok((atoms::error(), failure_reason(env, failure)).encode(env)),
        }
    }

    let troposphere = decode_troposphere(troposphere)?;
    let min_elevation_rad = decode_optional_f64(min_elevation_rad)?;
    let receiver = vec3_to_array(receiver_ecef_m);

    if is_nil(ionosphere) {
        let mut media = ObservableMediaOptions::default();
        media.troposphere = troposphere;
        media.ionosphere = None;
        let mut options = EmissionMediaBatchOptions::default();
        options.carrier_hz = carrier_hz;
        options.media = media;
        options.min_elevation_rad = min_elevation_rad;
        return call_emission_media(env, source, &satellites, &epochs, receiver, options);
    }

    if let Ok((tag, alpha, beta)) = ionosphere.decode::<(String, Coeff4, Coeff4)>() {
        if tag != "klobuchar" {
            return Err(Error::Term(Box::new("unknown ionosphere media option")));
        }
        let model = IonoModel::Klobuchar(KlobucharParams {
            alpha: [alpha.0, alpha.1, alpha.2, alpha.3],
            beta: [beta.0, beta.1, beta.2, beta.3],
        });
        let mut media = ObservableMediaOptions::default();
        media.troposphere = troposphere;
        media.ionosphere = Some(ObservableIonosphereCorrection::Broadcast(model));
        let mut options = EmissionMediaBatchOptions::default();
        options.carrier_hz = carrier_hz;
        options.media = media;
        options.min_elevation_rad = min_elevation_rad;
        return call_emission_media(env, source, &satellites, &epochs, receiver, options);
    }

    if let Ok((tag, ionex)) = ionosphere.decode::<(String, ResourceArc<IonexResource>)>() {
        if tag != "ionex" {
            return Err(Error::Term(Box::new("unknown ionosphere media option")));
        }
        let mut media = ObservableMediaOptions::default();
        media.troposphere = troposphere;
        media.ionosphere = Some(ObservableIonosphereCorrection::Ionex(&ionex.ionex));
        let mut options = EmissionMediaBatchOptions::default();
        options.carrier_hz = carrier_hz;
        options.media = media;
        options.min_elevation_rad = min_elevation_rad;
        return call_emission_media(env, source, &satellites, &epochs, receiver, options);
    }

    Err(Error::Term(Box::new("unknown ionosphere media option")))
}

fn call_emission_media<'a>(
    env: Env<'a>,
    source: Term<'a>,
    satellites: &[GnssSatelliteId],
    epochs: &[f64],
    receiver_ecef_m: [f64; 3],
    options: EmissionMediaBatchOptions<'_>,
) -> NifResult<Term<'a>> {
    let result = with_precise_source(source, |source| {
        emission_media_batch_at_j2000_s(source, satellites, epochs, receiver_ecef_m, options)
    })?;
    Ok(match result {
        Ok(batch) => (atoms::ok(), encode_emission_media_batch(env, &batch)).encode(env),
        Err(error) => (
            atoms::error(),
            failure_reason(env, PredictFailure::from(error)),
        )
            .encode(env),
    })
}

fn with_precise_source<'a, F, R>(source: Term<'a>, f: F) -> NifResult<R>
where
    F: FnOnce(&dyn ObservableEphemerisSource) -> R,
{
    if let Ok(handle) = source.decode::<ResourceArc<Sp3Resource>>() {
        Ok(f(&handle.sp3))
    } else if let Ok(handle) = source.decode::<ResourceArc<SampleSourceResource>>() {
        Ok(f(&handle.source))
    } else if let Ok(handle) = source.decode::<ResourceArc<PreciseInterpolantResource>>() {
        Ok(f(&handle.interpolant))
    } else if let Ok(handle) = source.decode::<ResourceArc<MappedPreciseInterpolantResource>>() {
        Ok(f(&*handle.read()))
    } else {
        Err(Error::Term(Box::new(
            "expected an SP3, precise-sample, or precise-interpolant source handle",
        )))
    }
}

fn decode_troposphere(term: Term<'_>) -> NifResult<Option<ObservableTroposphereCorrection>> {
    if is_nil(term) {
        return Ok(None);
    }
    let (pressure_hpa, temperature_k, relative_humidity): (f64, f64, f64) = term.decode()?;
    Ok(Some(ObservableTroposphereCorrection {
        met: Met::new(pressure_hpa, temperature_k, relative_humidity)
            .map_err(crate::errors::invalid_input)?,
        mapping: MappingModel::Niell,
    }))
}

fn decode_optional_f64(term: Term<'_>) -> NifResult<Option<f64>> {
    if is_nil(term) {
        Ok(None)
    } else {
        Ok(Some(term.decode::<f64>()?))
    }
}

fn is_nil(term: Term<'_>) -> bool {
    term.is_atom()
        && term
            .atom_to_string()
            .map(|name| name == "nil")
            .unwrap_or(false)
}

fn encode_emission_media_batch<'a>(env: Env<'a>, batch: &EmissionMediaBatch) -> Term<'a> {
    let positions: Vec<Term<'a>> = batch
        .positions_ecef_m
        .iter()
        .map(|position| match position {
            Some(position) => array_to_vec3(*position).encode(env),
            None => rustler::types::atom::nil().encode(env),
        })
        .collect();
    let statuses: Vec<Term<'a>> = batch
        .statuses
        .iter()
        .map(|status| emission_status_atom(*status).encode(env))
        .collect();
    let element_errors: Vec<Term<'a>> = batch
        .element_errors
        .iter()
        .map(|error| match error {
            Some(error) => failure_reason(env, PredictFailure::from(error.clone())),
            None => rustler::types::atom::nil().encode(env),
        })
        .collect();
    (
        positions,
        batch.clocks_s.clone(),
        batch.ionosphere_slant_delays_m.clone(),
        batch.troposphere_delays_m.clone(),
        statuses,
        element_errors,
    )
        .encode(env)
}

fn emission_status_atom(status: EmissionMediaStatus) -> rustler::Atom {
    match status {
        EmissionMediaStatus::Valid => atoms::valid(),
        EmissionMediaStatus::Gap => atoms::gap(),
        EmissionMediaStatus::BelowElevationCutoff => atoms::below_elevation_cutoff(),
        EmissionMediaStatus::Error => atoms::error(),
    }
}
