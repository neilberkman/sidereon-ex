//! Rustler boundary for RTK double-difference construction.
//!
//! The double-difference reference selection, pairing, dropped-satellite
//! accounting, and ambiguity-id algebra live in `sidereon_core::rtk`.
//! This module only decodes normalized Sidereon terms and encodes public tags.

use rustler::{Encoder, Env, Term};
use sidereon_core::rtk::{
    baseline_reference_satellites, double_differences, BaselineReferenceEpoch,
    BaselineReferenceSelection, DoubleDifferenceError, Observation, ReferenceReport,
    ReferenceSelection,
};
use std::collections::BTreeMap;

type ObservationTerm = (String, String, f64, f64);
type ReferenceTerm = (String, String, Vec<(String, String)>);
type Vec3 = (f64, f64, f64);
type BaselineReferenceEpochTerm = (Vec<String>, Vec<(String, Vec3)>);

mod atoms {
    rustler::atoms! {
        ok,
        error,
        duplicate_observation,
        too_few_common_satellites,
        no_common_reference_satellite,
        reference_satellite_missing,
        reference_satellite_single_system,
        reference_satellite_missing_system,
        invalid_option,
        reference_satellite_id,
        invalid_input,
        missing_satellite_position
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn rtk_double_differences<'a>(
    env: Env<'a>,
    base_observations: Vec<ObservationTerm>,
    rover_observations: Vec<ObservationTerm>,
    reference: ReferenceTerm,
) -> Term<'a> {
    let Some(reference) = decode_reference(reference) else {
        return (
            atoms::error(),
            (atoms::invalid_option(), atoms::reference_satellite_id()),
        )
            .encode(env);
    };
    let base = decode_observations(base_observations);
    let rover = decode_observations(rover_observations);

    match double_differences(&base, &rover, reference) {
        Ok(result) => {
            let reference = encode_reference_report(result.reference_satellite_id);
            let double_differences = result
                .double_differences
                .into_iter()
                .map(|dd| {
                    (
                        dd.satellite_id,
                        dd.reference_satellite_id,
                        dd.ambiguity_id,
                        dd.code_m,
                        dd.phase_m,
                    )
                })
                .collect::<Vec<_>>();
            (
                atoms::ok(),
                (reference, double_differences, result.dropped_sats),
            )
                .encode(env)
        }
        Err(err) => (atoms::error(), encode_error(env, err)).encode(env),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn rtk_baseline_reference_satellites<'a>(
    env: Env<'a>,
    base_m: Vec3,
    epochs: Vec<BaselineReferenceEpochTerm>,
    reference: ReferenceTerm,
) -> Term<'a> {
    let Some(reference) = decode_baseline_reference(reference) else {
        return (
            atoms::error(),
            (atoms::invalid_option(), atoms::reference_satellite_id()),
        )
            .encode(env);
    };

    match baseline_reference_satellites(vec3(base_m), &decode_baseline_epochs(epochs), reference) {
        Ok(refs) => (atoms::ok(), refs.into_iter().collect::<Vec<_>>()).encode(env),
        Err(err) => (atoms::error(), encode_error(env, err)).encode(env),
    }
}

fn decode_observations(observations: Vec<ObservationTerm>) -> Vec<Observation> {
    observations
        .into_iter()
        .map(
            |(satellite_id, ambiguity_id, code_m, phase_m)| Observation {
                satellite_id,
                ambiguity_id,
                code_m,
                phase_m,
            },
        )
        .collect()
}

fn decode_baseline_epochs(epochs: Vec<BaselineReferenceEpochTerm>) -> Vec<BaselineReferenceEpoch> {
    epochs
        .into_iter()
        .map(
            |(available_satellite_ids, positions)| BaselineReferenceEpoch {
                available_satellite_ids,
                satellite_positions_m: positions
                    .into_iter()
                    .map(|(sat, pos)| (sat, vec3(pos)))
                    .collect(),
            },
        )
        .collect()
}

fn decode_reference(reference: ReferenceTerm) -> Option<ReferenceSelection> {
    let (mode, satellite_id, refs) = reference;
    match mode.as_str() {
        "auto" => Some(ReferenceSelection::Auto),
        "satellite" => Some(ReferenceSelection::Satellite(satellite_id)),
        "per_system" => Some(ReferenceSelection::PerSystem(
            refs.into_iter().collect::<BTreeMap<_, _>>(),
        )),
        _ => None,
    }
}

fn decode_baseline_reference(reference: ReferenceTerm) -> Option<BaselineReferenceSelection> {
    let (mode, satellite_id, refs) = reference;
    match mode.as_str() {
        "auto" => Some(BaselineReferenceSelection::Auto),
        "satellite" => Some(BaselineReferenceSelection::Satellite(satellite_id)),
        "per_system" => Some(BaselineReferenceSelection::PerSystem(
            refs.into_iter().collect::<BTreeMap<_, _>>(),
        )),
        _ => None,
    }
}

fn encode_reference_report(report: ReferenceReport) -> ReferenceTerm {
    match report {
        ReferenceReport::Satellite(satellite_id) => {
            ("satellite".to_string(), satellite_id, Vec::new())
        }
        ReferenceReport::PerSystem(refs) => (
            "per_system".to_string(),
            String::new(),
            refs.into_iter().collect(),
        ),
    }
}

fn encode_error<'a>(env: Env<'a>, err: DoubleDifferenceError) -> Term<'a> {
    match err {
        DoubleDifferenceError::InvalidInput { .. } => atoms::invalid_input().encode(env),
        DoubleDifferenceError::MissingSatellitePosition(sat) => {
            (atoms::missing_satellite_position(), sat).encode(env)
        }
        DoubleDifferenceError::DuplicateObservation(sat) => {
            (atoms::duplicate_observation(), sat).encode(env)
        }
        DoubleDifferenceError::TooFewCommonSatellites { count, minimum } => (
            atoms::too_few_common_satellites(),
            count as u64,
            minimum as u64,
        )
            .encode(env),
        DoubleDifferenceError::NoCommonReferenceSatellite(system) => {
            (atoms::no_common_reference_satellite(), system).encode(env)
        }
        DoubleDifferenceError::ReferenceSatelliteMissing(sat) => {
            (atoms::reference_satellite_missing(), sat).encode(env)
        }
        DoubleDifferenceError::ReferenceSatelliteSingleSystem(sat) => {
            (atoms::reference_satellite_single_system(), sat).encode(env)
        }
        DoubleDifferenceError::ReferenceSatelliteMissingSystem(system) => {
            (atoms::reference_satellite_missing_system(), system).encode(env)
        }
        DoubleDifferenceError::InvalidReferenceOption => {
            (atoms::invalid_option(), atoms::reference_satellite_id()).encode(env)
        }
    }
}

fn vec3(v: Vec3) -> [f64; 3] {
    [v.0, v.1, v.2]
}
