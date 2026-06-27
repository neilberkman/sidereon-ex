//! Rustler boundary for code-differential GNSS correction helpers.
//!
//! The DGNSS correction and pairing rules live in `sidereon-core`; this
//! module only decodes terms, calls the crate, and encodes public-compatible
//! lists for Sidereon.

use std::collections::BTreeMap;

use rustler::{NifResult, ResourceArc};
use sidereon_core::dgnss::{apply_corrections, pseudorange_corrections, CodeObservation};

use crate::sp3::Sp3Resource;

type Vec3 = (f64, f64, f64);

#[rustler::nif(schedule = "DirtyCpu")]
pub fn dgnss_corrections(
    handle: ResourceArc<Sp3Resource>,
    base_position_m: Vec3,
    base_observations: Vec<(String, f64)>,
    t_rx_j2000_s: f64,
) -> NifResult<Vec<(String, f64)>> {
    let observations = code_observations(base_observations);
    let corrections = pseudorange_corrections(
        &handle.sp3,
        vec3_to_array(base_position_m),
        &observations,
        t_rx_j2000_s,
    )
    .map_err(crate::errors::invalid_input)?;
    Ok(corrections.into_iter().collect())
}

#[rustler::nif]
pub fn dgnss_apply(
    rover_observations: Vec<(String, f64)>,
    corrections: Vec<(String, f64)>,
) -> NifResult<(Vec<(String, f64)>, Vec<String>)> {
    let rover = code_observations(rover_observations);
    let corrections: BTreeMap<String, f64> = corrections.into_iter().collect();
    let applied = apply_corrections(&rover, &corrections).map_err(crate::errors::invalid_input)?;
    Ok((
        applied
            .corrected
            .into_iter()
            .map(|obs| (obs.satellite_id, obs.pseudorange_m))
            .collect(),
        applied.dropped,
    ))
}

fn code_observations(observations: Vec<(String, f64)>) -> Vec<CodeObservation> {
    observations
        .into_iter()
        .map(|(satellite_id, pseudorange_m)| CodeObservation::new(satellite_id, pseudorange_m))
        .collect()
}

fn vec3_to_array(vec: Vec3) -> [f64; 3] {
    [vec.0, vec.1, vec.2]
}
