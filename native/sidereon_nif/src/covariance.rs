//! Rustler boundary for the core position-covariance modeling.
//!
//! Pure glue: decode the 3x3 covariance and orbit state, call the relocated
//! `sidereon_core::astro::covariance` functions, encode the result. No RTN frame or
//! PSD formula lives here; structural input validation stays Elixir-side.

use rustler::{Encoder, Env, NifResult, Term};
use sidereon_core::astro::covariance;

mod atoms {
    rustler::atoms! {
        ok,
        error
    }
}

type Vec3 = (f64, f64, f64);

fn to_array3(v: Vec3) -> [f64; 3] {
    [v.0, v.1, v.2]
}

/// Decode a list-of-lists covariance into a fixed 3x3 array. The Elixir caller
/// only forwards matrices it has already structurally validated, so a wrong
/// shape here is a programming error (`BadArg`).
fn to_mat3(rows: &[Vec<f64>]) -> NifResult<[[f64; 3]; 3]> {
    if rows.len() != 3 || rows.iter().any(|r| r.len() != 3) {
        return Err(rustler::Error::BadArg);
    }
    Ok([
        [rows[0][0], rows[0][1], rows[0][2]],
        [rows[1][0], rows[1][1], rows[1][2]],
        [rows[2][0], rows[2][1], rows[2][2]],
    ])
}

fn mat3_to_rows(m: [[f64; 3]; 3]) -> Vec<Vec<f64>> {
    m.iter().map(|row| row.to_vec()).collect()
}

pub(crate) fn rtn_to_eci_impl<'a>(
    env: Env<'a>,
    cov_rtn: Vec<Vec<f64>>,
    r: Vec3,
    v: Vec3,
) -> NifResult<Term<'a>> {
    let cov = to_mat3(&cov_rtn)?;
    match covariance::rtn_to_eci(&cov, to_array3(r), to_array3(v)) {
        Ok(eci) => Ok((atoms::ok(), mat3_to_rows(eci)).encode(env)),
        Err(e) => Ok((atoms::error(), e.message()).encode(env)),
    }
}

pub(crate) fn positive_semidefinite_impl(m: Vec<Vec<f64>>) -> NifResult<bool> {
    Ok(covariance::positive_semidefinite(&to_mat3(&m)?))
}

pub(crate) fn symmetric_impl(m: Vec<Vec<f64>>) -> NifResult<bool> {
    Ok(covariance::symmetric(&to_mat3(&m)?))
}
