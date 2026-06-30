//! Rustler boundary for batched SGP4 propagation.
//!
//! Pure glue over `sidereon_core::astro::sgp4::{propagate_batch,
//! propagate_batch_parallel}`: it decodes a list of element-set maps and a shared
//! list of minutes-since-epoch times, initializes one [`Satellite`] per element
//! set (opsmode-preserving), and forwards to the core batch kernels. No SGP4 math
//! lives here. The per-satellite `Result` from the core is preserved: each
//! satellite's arc crosses as `{:ok, [{pos, vel}, ...]}` or `{:error, reason}`,
//! so one bad satellite never collapses the batch.

use crate::propagation::{elements_from_map, opsmode_from_term};
use rustler::{Encoder, Env, NifResult, Term};
use sidereon_core::astro::sgp4::{
    propagate_batch, propagate_batch_parallel, Error as Sgp4Error, MinutesSinceEpoch, Prediction,
    Satellite,
};

mod atoms {
    rustler::atoms! {
        ok,
        error
    }
}

type Vec3 = (f64, f64, f64);

fn encode_arc<'a>(env: Env<'a>, arc: Result<Vec<Prediction>, Sgp4Error>) -> Term<'a> {
    match arc {
        Ok(states) => {
            let states: Vec<(Vec3, Vec3)> = states
                .into_iter()
                .map(|p| {
                    (
                        (p.position[0], p.position[1], p.position[2]),
                        (p.velocity[0], p.velocity[1], p.velocity[2]),
                    )
                })
                .collect();
            (atoms::ok(), states).encode(env)
        }
        Err(e) => (atoms::error(), e.to_string()).encode(env),
    }
}

/// Initialize the satellites shared by both batch entry points. A single bad
/// element set aborts the whole batch with `{:error, index, reason}` so the caller
/// can pinpoint which input failed initialization.
fn satellites_from_maps<'a>(
    env: Env<'a>,
    tle_maps: Vec<Term<'a>>,
    opsmode: Term<'a>,
) -> Result<Vec<Satellite>, Term<'a>> {
    let opsmode = opsmode_from_term(env, opsmode)
        .map_err(|_| (atoms::error(), "invalid opsmode").encode(env))?;
    let mut satellites = Vec::with_capacity(tle_maps.len());
    for (index, tle_map) in tle_maps.into_iter().enumerate() {
        let elements = elements_from_map(env, tle_map)
            .map_err(|_| (atoms::error(), index as u64, "invalid elements").encode(env))?;
        let satellite = Satellite::from_elements_with_opsmode(&elements, opsmode)
            .map_err(|e| (atoms::error(), index as u64, e.to_string()).encode(env))?;
        satellites.push(satellite);
    }
    Ok(satellites)
}

fn batch_impl<'a>(
    env: Env<'a>,
    tle_maps: Vec<Term<'a>>,
    times_minutes: Vec<f64>,
    opsmode: Term<'a>,
    parallel: bool,
) -> NifResult<Term<'a>> {
    let satellites = match satellites_from_maps(env, tle_maps, opsmode) {
        Ok(satellites) => satellites,
        Err(error_term) => return Ok(error_term),
    };
    let times: Vec<MinutesSinceEpoch> = times_minutes.into_iter().map(MinutesSinceEpoch).collect();

    let arcs = if parallel {
        propagate_batch_parallel(&satellites, &times)
    } else {
        propagate_batch(&satellites, &times)
    };

    let encoded: Vec<Term<'a>> = arcs.into_iter().map(|arc| encode_arc(env, arc)).collect();
    Ok((atoms::ok(), encoded).encode(env))
}

/// Serial batch SGP4: propagate every satellite across the shared time list.
#[rustler::nif(schedule = "DirtyCpu")]
fn sgp4_propagate_batch<'a>(
    env: Env<'a>,
    tle_maps: Vec<Term<'a>>,
    times_minutes: Vec<f64>,
    opsmode: Term<'a>,
) -> NifResult<Term<'a>> {
    batch_impl(env, tle_maps, times_minutes, opsmode, false)
}

/// Data-parallel batch SGP4: identical results to [`sgp4_propagate_batch`], fanned
/// across a rayon thread pool.
#[rustler::nif(schedule = "DirtyCpu")]
fn sgp4_propagate_batch_parallel<'a>(
    env: Env<'a>,
    tle_maps: Vec<Term<'a>>,
    times_minutes: Vec<f64>,
    opsmode: Term<'a>,
) -> NifResult<Term<'a>> {
    batch_impl(env, tle_maps, times_minutes, opsmode, true)
}
