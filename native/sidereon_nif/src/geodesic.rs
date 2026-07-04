//! Rustler boundary for WGS84 Karney geodesic direct and inverse solves.
//!
//! This module is glue only: it decodes scalar degree/metre inputs, forwards to
//! `sidereon_core::geodesic`, and preserves the core invalid-input detail as a
//! small map for the Elixir error struct.

use rustler::{Encoder, Env, Term};
use sidereon_core::GeodesicError;
use sidereon_core::{
    geodesic_direct as core_geodesic_direct, geodesic_inverse as core_geodesic_inverse,
};

mod atoms {
    rustler::atoms! {
        ok,
        error
    }
}

#[derive(Debug, Clone, rustler::NifMap)]
struct GeodesicErrorTerm {
    field: String,
    reason: String,
}

fn error_term(error: GeodesicError) -> GeodesicErrorTerm {
    match error {
        GeodesicError::InvalidInput { field, reason } => GeodesicErrorTerm {
            field: field.to_string(),
            reason: reason.to_string(),
        },
    }
}

fn encode_result<'a>(env: Env<'a>, result: Result<(f64, f64, f64), GeodesicError>) -> Term<'a> {
    match result {
        Ok(values) => (atoms::ok(), values).encode(env),
        Err(error) => (atoms::error(), error_term(error)).encode(env),
    }
}

/// Solve the WGS84 inverse geodesic problem.
#[rustler::nif]
fn geodesic_inverse<'a>(
    env: Env<'a>,
    lat1_deg: f64,
    lon1_deg: f64,
    lat2_deg: f64,
    lon2_deg: f64,
) -> Term<'a> {
    encode_result(
        env,
        core_geodesic_inverse(lat1_deg, lon1_deg, lat2_deg, lon2_deg),
    )
}

/// Solve the WGS84 direct geodesic problem.
#[rustler::nif]
fn geodesic_direct<'a>(
    env: Env<'a>,
    lat1_deg: f64,
    lon1_deg: f64,
    azi1_deg: f64,
    s12_m: f64,
) -> Term<'a> {
    encode_result(
        env,
        core_geodesic_direct(lat1_deg, lon1_deg, azi1_deg, s12_m),
    )
}
