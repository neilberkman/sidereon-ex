//! Rustler boundary for code-differential GNSS correction helpers.
//!
//! The DGNSS modeling lives in `sidereon-core`; this module only decodes terms,
//! calls the crate driver, and encodes public-compatible results for Sidereon.
//! The combined corrections -> apply -> SPP -> baseline workflow is the single
//! `sidereon_core::dgnss::solve_position` driver, not reassembled here.

use std::collections::BTreeMap;

use rustler::types::atom;
use rustler::types::tuple::make_tuple;
use rustler::{Encoder, Env, NifResult, ResourceArc, Term};
use sidereon_core::dgnss::{
    apply_corrections, pseudorange_corrections, solve_position, CodeObservation, DgnssError,
    PositionSolution,
};

use crate::spp::{atom_from, build_solve_inputs, encode_solution_body, spp_error_term};
use crate::sp3::Sp3Resource;

type Vec3 = (f64, f64, f64);

// Inert atmosphere model for the DGNSS solve: the differential already removed
// the common ionosphere/troposphere delays, so `solve_position` forces the
// corrected-observation solve to `Corrections::NONE`. These coefficients and the
// surface meteorology are therefore never read; standard finite values keep the
// crate's input validation satisfied without affecting the result.
const KLOBUCHAR_NONE: (f64, f64, f64, f64) = (0.0, 0.0, 0.0, 0.0);
const STANDARD_PRESSURE_HPA: f64 = 1013.25;
const STANDARD_TEMPERATURE_K: f64 = 288.15;
const STANDARD_RELATIVE_HUMIDITY: f64 = 0.5;

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
#[allow(clippy::type_complexity)]
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

/// Run the full code-differential rover solve through the single core driver:
/// compute the base pseudorange corrections, apply them to the rover
/// observations, solve the corrected-observation SPP, and derive the baseline.
/// No part of that workflow is reassembled on the Elixir side.
///
/// The receive-epoch scalars and the initial guess are forwarded verbatim into
/// the crate; the atmosphere model is inert because the differential already
/// removed the common delays (see [`KLOBUCHAR_NONE`]). The success term mirrors
/// the SPP solution body so `Sidereon.GNSS.Positioning.Decode` decodes it
/// unchanged, paired with the baseline vector, baseline length, and dropped
/// rover satellites.
#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
pub fn dgnss_position<'a>(
    env: Env<'a>,
    handle: ResourceArc<Sp3Resource>,
    base_position_m: Vec3,
    base_observations: Vec<(String, f64)>,
    rover_observations: Vec<(String, f64)>,
    t_rx_j2000_s: f64,
    t_rx_second_of_day_s: f64,
    day_of_year: f64,
    initial_guess: (f64, f64, f64, f64),
    with_geodetic: bool,
) -> NifResult<Term<'a>> {
    // `solve_position` overrides the observations (with the corrected rover set)
    // and the corrections (forced to NONE), so the empty observation list and the
    // disabled atmosphere here are placeholders the driver replaces.
    let inputs = build_solve_inputs(
        Vec::new(),
        t_rx_j2000_s,
        t_rx_second_of_day_s,
        day_of_year,
        initial_guess,
        false,
        false,
        KLOBUCHAR_NONE,
        KLOBUCHAR_NONE,
        STANDARD_PRESSURE_HPA,
        STANDARD_TEMPERATURE_K,
        STANDARD_RELATIVE_HUMIDITY,
        None,
    )?;

    let base = code_observations(base_observations);
    let rover = code_observations(rover_observations);

    match solve_position(
        &handle.sp3,
        vec3_to_array(base_position_m),
        &base,
        &rover,
        inputs,
        with_geodetic,
    ) {
        Ok(solution) => Ok(encode_position_solution(env, &solution)),
        Err(DgnssError::Spp(error)) => Ok(spp_error_term(env, &error)),
        Err(DgnssError::InvalidInput { .. }) => {
            Ok((atom::error(), atom_from(env, "invalid_input")).encode(env))
        }
    }
}

/// Encode a [`PositionSolution`] as `{:ok, {solution_body, baseline_vector,
/// baseline_m, dropped_sats}}`. The solution body reuses the SPP encoder so the
/// Elixir decoder is shared.
fn encode_position_solution<'a>(env: Env<'a>, solution: &PositionSolution) -> Term<'a> {
    let body = encode_solution_body(env, &solution.solution);
    let baseline_vector = (
        solution.baseline_vector_m[0],
        solution.baseline_vector_m[1],
        solution.baseline_vector_m[2],
    )
        .encode(env);
    let baseline_m = solution.baseline_m.encode(env);
    let dropped = solution.dropped_sats.encode(env);
    let payload = make_tuple(env, &[body, baseline_vector, baseline_m, dropped]);
    (atom::ok(), payload).encode(env)
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
