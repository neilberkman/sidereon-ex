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
use rustler::{Encoder, Env, Error, NifMap, NifResult, ResourceArc, Term};
use sidereon_core::atmosphere::ionosphere::{IonoModel, KlobucharParams};
use sidereon_core::atmosphere::troposphere::{MappingModel, Met};
use sidereon_core::observables::{
    emission_media_batch_at_j2000_s, j2000_seconds_from_split, predict, predict_batch,
    predict_ranges as core_predict_ranges, pseudorange_transmit_epoch_j2000_s,
    pseudorange_transmit_geometry, EmissionMediaBatch, EmissionMediaBatchOptions,
    EmissionMediaStatus, ObservableEphemerisSource, ObservableIonosphereCorrection,
    ObservableMediaOptions, ObservableTroposphereCorrection, ObservablesError,
    ObservablesInputErrorKind, PredictOptions, PredictRequest, PredictedObservables,
    RangePrediction, RangePredictionRequest,
};
use sidereon_core::positioning::ClockRelativity;
use sidereon_core::{Error as CoreError, GnssSatelliteId, GnssSystem};

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
        below_elevation_cutoff,
        not_applicable,
        unavailable
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
        .map(|obs| with_clock_terms(&handle.sp3, sat, obs))
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
        .map(|obs| with_clock_terms(&handle.store, sat, obs))
        .map_err(PredictFailure::from)
    });
    encode_result(env, result)
}

/// Detailed sibling for `sp3_observables`; legacy return terms remain unchanged.
#[rustler::nif]
#[allow(clippy::too_many_arguments)]
pub fn sp3_observables_detailed<'a>(
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
        .map(|obs| with_clock_terms(&handle.sp3, sat, obs))
        .map_err(PredictFailure::from)
    });
    encode_detailed_result(env, result)
}

/// Detailed sibling for `broadcast_observables`; legacy return terms stay unchanged.
#[rustler::nif]
#[allow(clippy::too_many_arguments)]
pub fn broadcast_observables_detailed<'a>(
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
        .map(|obs| with_clock_terms(&handle.store, sat, obs))
        .map_err(PredictFailure::from)
    });
    encode_detailed_result(env, result)
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
    let mut predicted = predict_batch(&handle.sp3, &valid, options)
        .into_iter()
        .zip(valid.iter())
        .map(|(result, request)| result.map(|obs| with_clock_terms(&handle.sp3, request.0, obs)));

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

/// Detailed sibling for the index-aligned SP3 prediction batch.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn sp3_predict_batch_detailed<'a>(
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
    let mut prepared: Vec<Result<PredictRequest, PredictFailure>> =
        Vec::with_capacity(requests.len());
    for (system_letter, prn, jd_whole, jd_fraction, receiver_ecef_m) in requests {
        prepared.push(sat_from_parts(&system_letter, prn).and_then(|sat| {
            let t_rx_j2000_s =
                j2000_seconds_from_split(jd_whole, jd_fraction).map_err(PredictFailure::from)?;
            Ok((sat, vec3_to_array(receiver_ecef_m), t_rx_j2000_s))
        }));
    }
    let valid: Vec<PredictRequest> = prepared.iter().filter_map(|row| row.clone().ok()).collect();
    let mut predicted = predict_batch(&handle.sp3, &valid, options)
        .into_iter()
        .zip(valid.iter())
        .map(|(result, request)| result.map(|obs| with_clock_terms(&handle.sp3, request.0, obs)));
    let rows: Vec<Term> = prepared
        .into_iter()
        .map(|prep| match prep {
            Ok(_) => match predicted.next() {
                Some(result) => encode_detailed_result(env, result.map_err(PredictFailure::from)),
                None => encode_detailed_result(
                    env,
                    Err(PredictFailure::Reason(
                        "core prediction result was missing for a valid request".to_owned(),
                    )),
                ),
            },
            Err(failure) => encode_detailed_result(env, Err(failure)),
        })
        .collect();
    rows.encode(env)
}

#[derive(Debug, Clone)]
enum PredictFailure {
    InvalidInput,
    Reason(String),
    Observables(ObservablesError),
}

impl From<ObservablesError> for PredictFailure {
    fn from(value: ObservablesError) -> Self {
        Self::Observables(value)
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

/// A prediction with the two clock terms a single-frequency positioning model
/// applies to the source's satellite clock at the transmit epoch: the
/// relativistic term a product clock leaves to the user, and the broadcast
/// group delay.
struct PredictionWithClockTerms {
    obs: PredictedObservables,
    clock_relativity: ClockRelativity,
    single_frequency_group_delay_s: Option<f64>,
}

fn with_clock_terms<S: ObservableEphemerisSource>(
    source: &S,
    sat: GnssSatelliteId,
    obs: PredictedObservables,
) -> PredictionWithClockTerms {
    let t_tx = obs.transmit_time_j2000_s;
    PredictionWithClockTerms {
        clock_relativity: source.clock_relativity_s(sat, t_tx),
        single_frequency_group_delay_s: source.single_frequency_group_delay_s(sat, t_tx),
        obs,
    }
}

fn clock_relativity_term<'a>(env: Env<'a>, relativity: ClockRelativity) -> Term<'a> {
    match relativity {
        ClockRelativity::NotApplicable => atoms::not_applicable().encode(env),
        ClockRelativity::Term(seconds) => seconds.encode(env),
        ClockRelativity::Unavailable => atoms::unavailable().encode(env),
    }
}

fn encode_result<'a>(
    env: Env<'a>,
    result: Result<PredictionWithClockTerms, PredictFailure>,
) -> Term<'a> {
    match result {
        Ok(prediction) => encode_prediction(env, prediction),
        Err(failure) => (atoms::error(), failure_reason(env, failure)).encode(env),
    }
}

fn encode_prediction<'a>(env: Env<'a>, prediction: PredictionWithClockTerms) -> Term<'a> {
    let PredictionWithClockTerms {
        obs,
        clock_relativity,
        single_frequency_group_delay_s,
    } = prediction;
    {
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
            clock_relativity_term(env, clock_relativity),
            single_frequency_group_delay_s.encode(env),
        ];
        let vectors = vec![
            array_to_vec3(obs.los_unit).encode(env),
            array_to_vec3(obs.sat_pos_ecef_m).encode(env),
            array_to_vec3(obs.sat_velocity_m_s).encode(env),
        ];
        (atoms::ok(), (scalars, vectors)).encode(env)
    }
}

#[derive(NifMap)]
struct IonexMissingNodesDetailTerm {
    map_number: usize,
    lat_index: usize,
    lon_index: usize,
    lon_index_next: usize,
    missing: Vec<bool>,
}

#[derive(NifMap)]
struct CoreCauseDetailTerm {
    family: String,
    kind: String,
    message: String,
    satellite: Option<String>,
    nodes: Option<usize>,
    required: Option<usize>,
    input_message: Option<String>,
    coverage_reason: Option<String>,
    earlier_missing_nodes: Option<IonexMissingNodesDetailTerm>,
    later_missing_nodes: Option<IonexMissingNodesDetailTerm>,
    refusal_kind: Option<String>,
    map_number: Option<usize>,
    latitude_index: Option<usize>,
    longitude_index: Option<usize>,
    mapping_function_declaration: Option<String>,
    mapping_function_kind: Option<String>,
    mapping_function_code: Option<String>,
}

#[derive(NifMap)]
struct PredictionErrorDetailTerm {
    family: String,
    kind: String,
    message: String,
    field: Option<String>,
    reason: Option<String>,
    input_kind: Option<String>,
    cause: Option<CoreCauseDetailTerm>,
}

fn observables_input_kind_label(kind: ObservablesInputErrorKind) -> &'static str {
    match kind {
        ObservablesInputErrorKind::NonFinite => "NonFinite",
        ObservablesInputErrorKind::NotPositive => "NotPositive",
        ObservablesInputErrorKind::Negative => "Negative",
        ObservablesInputErrorKind::OutOfRange => "OutOfRange",
        ObservablesInputErrorKind::Missing => "Missing",
        ObservablesInputErrorKind::FloatParse => "FloatParse",
        ObservablesInputErrorKind::IntParse => "IntParse",
        ObservablesInputErrorKind::InvalidCivilDate => "InvalidCivilDate",
        ObservablesInputErrorKind::InvalidCivilTime => "InvalidCivilTime",
    }
}

fn ionex_missing_nodes_detail(
    nodes: sidereon_core::atmosphere::IonexMissingNodes,
) -> IonexMissingNodesDetailTerm {
    IonexMissingNodesDetailTerm {
        map_number: nodes.map_number,
        lat_index: nodes.lat_index,
        lon_index: nodes.lon_index,
        lon_index_next: nodes.lon_index_next,
        missing: nodes.missing.to_vec(),
    }
}

fn core_cause_detail(error: &CoreError) -> CoreCauseDetailTerm {
    use sidereon_core::atmosphere::{IonexCoverageError as Coverage, IonexSlantRefusal as Refusal};
    let mut detail = CoreCauseDetailTerm {
        family: "CoreError".to_owned(),
        kind: "UNMAPPED_CORE_ERROR".to_owned(),
        message: error.to_string(),
        satellite: None,
        nodes: None,
        required: None,
        input_message: None,
        coverage_reason: None,
        earlier_missing_nodes: None,
        later_missing_nodes: None,
        refusal_kind: None,
        map_number: None,
        latitude_index: None,
        longitude_index: None,
        mapping_function_declaration: None,
        mapping_function_kind: None,
        mapping_function_code: None,
    };
    match error {
        CoreError::UnknownSatellite(satellite) => {
            detail.kind = "UNKNOWN_SATELLITE".to_owned();
            detail.satellite = Some(satellite.to_string());
        }
        CoreError::EpochOutOfRange => detail.kind = "EPOCH_OUT_OF_RANGE".to_owned(),
        CoreError::InsufficientPreciseNodes {
            sat,
            nodes,
            required,
        } => {
            detail.kind = "INSUFFICIENT_PRECISE_NODES".to_owned();
            detail.satellite = Some(sat.to_string());
            detail.nodes = Some(*nodes);
            detail.required = Some(*required);
        }
        CoreError::InvalidInput(message) => {
            detail.kind = "INVALID_INPUT".to_owned();
            detail.input_message = Some(message.clone());
        }
        CoreError::IonexOutOfCoverage(reason) => {
            detail.kind = "IONEX_OUT_OF_COVERAGE".to_owned();
            detail.coverage_reason = Some(
                match reason {
                    Coverage::EpochBeforeFirstMap => "EpochBeforeFirstMap",
                    Coverage::EpochAfterLastMap => "EpochAfterLastMap",
                    Coverage::LatitudeOutOfRange => "LatitudeOutOfRange",
                    Coverage::LongitudeOutOfRange => "LongitudeOutOfRange",
                }
                .to_owned(),
            );
        }
        CoreError::IonexNodesNotAvailable(gap) => {
            detail.kind = "IONEX_NODES_NOT_AVAILABLE".to_owned();
            detail.earlier_missing_nodes = gap.earlier.map(ionex_missing_nodes_detail);
            detail.later_missing_nodes = gap.later.map(ionex_missing_nodes_detail);
        }
        CoreError::IonexSlantUnavailable(refusal) => {
            detail.kind = "IONEX_SLANT_UNAVAILABLE".to_owned();
            match refusal {
                Refusal::VaryingHeights {
                    map_number,
                    lat_index,
                    lon_index,
                } => {
                    detail.refusal_kind = Some("VaryingHeights".to_owned());
                    detail.map_number = Some(*map_number);
                    detail.latitude_index = Some(*lat_index);
                    detail.longitude_index = Some(*lon_index);
                }
                Refusal::HeightNotAvailable {
                    map_number,
                    lat_index,
                    lon_index,
                } => {
                    detail.refusal_kind = Some("HeightNotAvailable".to_owned());
                    detail.map_number = Some(*map_number);
                    detail.latitude_index = Some(*lat_index);
                    detail.longitude_index = Some(*lon_index);
                }
                Refusal::MappingFunction(declaration) => {
                    detail.refusal_kind = Some("MappingFunction".to_owned());
                    match declaration {
                        sidereon_core::atmosphere::IonexMappingDeclaration::Declared(function) => {
                            detail.mapping_function_declaration = Some("Declared".to_owned());
                            detail.mapping_function_kind = Some(
                                match function {
                                    sidereon_core::atmosphere::IonexMappingFunction::NoMapping => {
                                        "NoMapping"
                                    }
                                    sidereon_core::atmosphere::IonexMappingFunction::CosZ => "CosZ",
                                    sidereon_core::atmosphere::IonexMappingFunction::QFactor => {
                                        "QFactor"
                                    }
                                    sidereon_core::atmosphere::IonexMappingFunction::Other(_) => {
                                        "Other"
                                    }
                                }
                                .to_owned(),
                            );
                            detail.mapping_function_code = Some(function.code().to_owned());
                        }
                        sidereon_core::atmosphere::IonexMappingDeclaration::Absent => {
                            detail.mapping_function_declaration = Some("Absent".to_owned());
                            detail.mapping_function_kind = None;
                        }
                    }
                }
                other => {
                    // `IonexSlantRefusal` is non-exhaustive. Preserve the core
                    // message without inventing a variant label.
                    detail.kind = "IONEX_SLANT_UNAVAILABLE_OTHER".to_owned();
                    detail.input_message = Some(other.to_string());
                }
            }
        }
        _ => {}
    }
    detail
}

fn detailed_failure_term<'a>(env: Env<'a>, failure: PredictFailure) -> Term<'a> {
    let detail = match failure {
        PredictFailure::Observables(ObservablesError::InvalidInput { field, kind }) => {
            PredictionErrorDetailTerm {
                family: "ObservablesError".to_owned(),
                kind: "INVALID_INPUT".to_owned(),
                message: format!("invalid observable input {field}: {kind}"),
                field: Some(field.to_owned()),
                reason: Some(kind.to_string()),
                input_kind: Some(observables_input_kind_label(kind).to_owned()),
                cause: None,
            }
        }
        PredictFailure::Observables(ObservablesError::NoEphemeris) => PredictionErrorDetailTerm {
            family: "ObservablesError".to_owned(),
            kind: "NO_EPHEMERIS".to_owned(),
            message: "no ephemeris".to_owned(),
            field: None,
            reason: None,
            input_kind: None,
            cause: None,
        },
        PredictFailure::Observables(ObservablesError::Media(error)) => PredictionErrorDetailTerm {
            family: "ObservablesError".to_owned(),
            kind: "MEDIA".to_owned(),
            message: error.to_string(),
            field: None,
            reason: None,
            input_kind: None,
            cause: Some(core_cause_detail(&error)),
        },
        PredictFailure::Observables(ObservablesError::Ephemeris(error)) => {
            PredictionErrorDetailTerm {
                family: "ObservablesError".to_owned(),
                kind: "EPHEMERIS".to_owned(),
                message: error.to_string(),
                field: None,
                reason: None,
                input_kind: None,
                cause: Some(core_cause_detail(&error)),
            }
        }
        PredictFailure::InvalidInput => PredictionErrorDetailTerm {
            family: "PredictionInputError".to_owned(),
            kind: "INVALID_SATELLITE".to_owned(),
            message: "satellite system and PRN do not identify a valid satellite".to_owned(),
            field: Some("satellite".to_owned()),
            reason: Some("invalid identifier".to_owned()),
            input_kind: None,
            cause: None,
        },
        PredictFailure::Reason(message) => PredictionErrorDetailTerm {
            family: "PredictionError".to_owned(),
            kind: "INPUT_OR_CORE_FAILURE".to_owned(),
            message,
            field: None,
            reason: None,
            input_kind: None,
            cause: None,
        },
    };
    detail.encode(env)
}

pub(crate) fn detailed_observables_error_term<'a>(
    env: Env<'a>,
    error: &ObservablesError,
) -> Term<'a> {
    detailed_failure_term(env, PredictFailure::Observables(error.clone()))
}

fn encode_detailed_result<'a>(
    env: Env<'a>,
    result: Result<PredictionWithClockTerms, PredictFailure>,
) -> Term<'a> {
    match result {
        Ok(prediction) => encode_prediction(env, prediction),
        Err(failure) => (atoms::error(), detailed_failure_term(env, failure)).encode(env),
    }
}

/// The error reason term for a prediction failure (without the `:error` tag):
/// a typed atom for the recognized failure classes, or the crate's message for
/// an ephemeris error passed through verbatim.
fn failure_reason(env: Env<'_>, failure: PredictFailure) -> Term<'_> {
    match failure {
        PredictFailure::InvalidInput => atoms::invalid_input().encode(env),
        PredictFailure::Reason(reason) => reason.encode(env),
        PredictFailure::Observables(ObservablesError::NoEphemeris) => {
            atoms::no_ephemeris().encode(env)
        }
        PredictFailure::Observables(
            ObservablesError::InvalidInput { .. } | ObservablesError::Media(_),
        ) => atoms::invalid_input().encode(env),
        PredictFailure::Observables(ObservablesError::Ephemeris(error)) => {
            error.to_string().encode(env)
        }
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

/// The transmit-time geometry of a pseudorange, placed as the positioning
/// models place it (RTKLIB `satposs`): the transmission epoch is the reception
/// time tag less the pseudorange over `c`, less the satellite clock read there,
/// and the geometry is the source's state at that epoch with the `geodist`
/// range. The two clock terms a single-frequency model applies at that epoch
/// come with it.
///
/// Returns `{:ok, {scalars, vectors}}` with `scalars` =
/// `[transmit_time_j2000_s, signal_flight_time_s, transmit_offset_us,
/// sat_clock_s, geometric_range_m, elevation_deg, azimuth_deg,
/// sat_clock_relativity, single_frequency_group_delay_s]` and `vectors` =
/// `[sat_pos_ecef_m, los_unit]`, or `{:error, reason}`.
#[rustler::nif]
#[allow(clippy::too_many_arguments)]
pub fn observables_pseudorange_transmit_geometry<'a>(
    env: Env<'a>,
    source: Term<'a>,
    system_letter: String,
    prn: u8,
    receiver_ecef_m: Vec3,
    t_rx_j2000_s: f64,
    pseudorange_m: f64,
    sagnac: bool,
) -> NifResult<Term<'a>> {
    let sat = match sat_from_parts(&system_letter, prn) {
        Ok(sat) => sat,
        Err(failure) => return Ok((atoms::error(), failure_reason(env, failure)).encode(env)),
    };
    let receiver = vec3_to_array(receiver_ecef_m);
    let result = if let Ok(handle) = source.decode::<ResourceArc<Sp3Resource>>() {
        placed_geometry(
            env,
            &handle.sp3,
            sat,
            receiver,
            t_rx_j2000_s,
            pseudorange_m,
            sagnac,
        )
    } else if let Ok(handle) = source.decode::<ResourceArc<BroadcastResource>>() {
        placed_geometry(
            env,
            &handle.store,
            sat,
            receiver,
            t_rx_j2000_s,
            pseudorange_m,
            sagnac,
        )
    } else if let Ok(handle) = source.decode::<ResourceArc<SampleSourceResource>>() {
        placed_geometry(
            env,
            &handle.source,
            sat,
            receiver,
            t_rx_j2000_s,
            pseudorange_m,
            sagnac,
        )
    } else if let Ok(handle) = source.decode::<ResourceArc<PreciseInterpolantResource>>() {
        placed_geometry(
            env,
            &handle.interpolant,
            sat,
            receiver,
            t_rx_j2000_s,
            pseudorange_m,
            sagnac,
        )
    } else if let Ok(handle) = source.decode::<ResourceArc<MappedPreciseInterpolantResource>>() {
        placed_geometry(
            env,
            &*handle.read(),
            sat,
            receiver,
            t_rx_j2000_s,
            pseudorange_m,
            sagnac,
        )
    } else {
        return Err(Error::Term(Box::new(
            "expected an SP3, broadcast, precise-sample, or precise-interpolant source handle",
        )));
    };
    Ok(result)
}

fn placed_geometry<'a, S: ObservableEphemerisSource>(
    env: Env<'a>,
    source: &S,
    sat: GnssSatelliteId,
    receiver_ecef_m: [f64; 3],
    t_rx_j2000_s: f64,
    pseudorange_m: f64,
    sagnac: bool,
) -> Term<'a> {
    let placed = pseudorange_transmit_epoch_j2000_s(source, sat, t_rx_j2000_s, pseudorange_m)
        .and_then(|t_tx| {
            pseudorange_transmit_geometry(source, sat, receiver_ecef_m, t_rx_j2000_s, t_tx, sagnac)
        });
    match placed {
        Ok(geometry) => {
            let t_tx = geometry.transmit_time_j2000_s;
            let scalars = vec![
                t_tx.encode(env),
                geometry.signal_flight_time_s.encode(env),
                geometry.transmit_offset_us.encode(env),
                geometry.sat_clock_s.encode(env),
                geometry.geometric_range_m.encode(env),
                geometry.elevation_deg.encode(env),
                geometry.azimuth_deg.encode(env),
                clock_relativity_term(env, source.clock_relativity_s(sat, t_tx)),
                source.single_frequency_group_delay_s(sat, t_tx).encode(env),
            ];
            let vectors = vec![
                array_to_vec3(geometry.sat_pos_ecef_m).encode(env),
                array_to_vec3(geometry.los_unit).encode(env),
            ];
            (atoms::ok(), (scalars, vectors)).encode(env)
        }
        Err(error) => (
            atoms::error(),
            failure_reason(env, PredictFailure::from(error)),
        )
            .encode(env),
    }
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
    emission_media_batch_impl(
        env,
        source,
        requests,
        receiver_ecef_m,
        carrier_hz,
        troposphere,
        ionosphere,
        min_elevation_rad,
        false,
    )
}

#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
pub fn emission_media_batch_detailed<'a>(
    env: Env<'a>,
    source: Term<'a>,
    requests: Vec<EmissionRequestTerm>,
    receiver_ecef_m: Vec3,
    carrier_hz: f64,
    troposphere: Term<'a>,
    ionosphere: Term<'a>,
    min_elevation_rad: Term<'a>,
) -> NifResult<Term<'a>> {
    emission_media_batch_impl(
        env,
        source,
        requests,
        receiver_ecef_m,
        carrier_hz,
        troposphere,
        ionosphere,
        min_elevation_rad,
        true,
    )
}

#[allow(clippy::too_many_arguments)]
fn emission_media_batch_impl<'a>(
    env: Env<'a>,
    source: Term<'a>,
    requests: Vec<EmissionRequestTerm>,
    receiver_ecef_m: Vec3,
    carrier_hz: f64,
    troposphere: Term<'a>,
    ionosphere: Term<'a>,
    min_elevation_rad: Term<'a>,
    detailed: bool,
) -> NifResult<Term<'a>> {
    let mut satellites = Vec::with_capacity(requests.len());
    let mut epochs = Vec::with_capacity(requests.len());
    for (system_letter, prn, emission_epoch_j2000_s) in requests {
        match sat_from_parts(&system_letter, prn) {
            Ok(sat) => {
                satellites.push(sat);
                epochs.push(emission_epoch_j2000_s);
            }
            Err(failure) => {
                let reason = if detailed {
                    detailed_failure_term(env, failure)
                } else {
                    failure_reason(env, failure)
                };
                return Ok((atoms::error(), reason).encode(env));
            }
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
        return call_emission_media(
            env,
            source,
            &satellites,
            &epochs,
            receiver,
            options,
            detailed,
        );
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
        return call_emission_media(
            env,
            source,
            &satellites,
            &epochs,
            receiver,
            options,
            detailed,
        );
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
        return call_emission_media(
            env,
            source,
            &satellites,
            &epochs,
            receiver,
            options,
            detailed,
        );
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
    detailed: bool,
) -> NifResult<Term<'a>> {
    let result = with_precise_source(source, |source| {
        emission_media_batch_at_j2000_s(source, satellites, epochs, receiver_ecef_m, options)
    })?;
    Ok(match result {
        Ok(batch) => (
            atoms::ok(),
            encode_emission_media_batch(env, &batch, detailed),
        )
            .encode(env),
        Err(error) => {
            let failure = PredictFailure::from(error);
            let reason = if detailed {
                detailed_failure_term(env, failure)
            } else {
                failure_reason(env, failure)
            };
            (atoms::error(), reason).encode(env)
        }
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

fn encode_emission_media_batch<'a>(
    env: Env<'a>,
    batch: &EmissionMediaBatch,
    detailed: bool,
) -> Term<'a> {
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
            Some(error) if detailed => {
                detailed_failure_term(env, PredictFailure::from(error.clone()))
            }
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
