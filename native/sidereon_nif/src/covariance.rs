//! Rustler boundary for the core position-covariance modeling.
//!
//! Pure glue: decode the 3x3 covariance and orbit state, call the relocated
//! `sidereon_core::astro::covariance` functions, encode the result. No RTN frame or
//! PSD formula lives here; structural input validation stays Elixir-side.

use nalgebra::DMatrix;
use rustler::{Encoder, Env, NifResult, Term};
use sidereon_core::astro::covariance;
use sidereon_core::astro::math::least_squares::{
    covariance_from_jacobian, hessian_trace, normal_covariance, SolveError,
};
use sidereon_core::geometry::{error_ellipse_2x2, DopError, ErrorEllipse2};

mod atoms {
    rustler::atoms! {
        ok,
        error,
        singular_jacobian,
        invalid_input,
        too_few_satellites,
        singular_geometry
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

// --- Jacobian-derived geometry: covariance, Hessian trace, error ellipse -----

/// Build a dense `DMatrix` from a list-of-rows, or `None` for a ragged matrix.
/// The Jacobian-derived NIFs decode user input directly (no Elixir-side shape
/// gate), so each caller maps `None` to its own contract: a typed
/// `{:error, :invalid_input}` for the result-tuple functions.
fn to_dmatrix(rows: &[Vec<f64>]) -> Option<DMatrix<f64>> {
    let m = rows.len();
    if m == 0 {
        return Some(DMatrix::zeros(0, 0));
    }
    let n = rows[0].len();
    if rows.iter().any(|row| row.len() != n) {
        return None;
    }
    // `from_row_iterator` consumes values in row-major order.
    Some(DMatrix::from_row_iterator(
        m,
        n,
        rows.iter().flat_map(|row| row.iter().copied()),
    ))
}

fn dmatrix_to_rows(matrix: &DMatrix<f64>) -> Vec<Vec<f64>> {
    (0..matrix.nrows())
        .map(|i| (0..matrix.ncols()).map(|j| matrix[(i, j)]).collect())
        .collect()
}

fn solve_error_atom(err: SolveError) -> rustler::types::atom::Atom {
    match err {
        SolveError::SingularJacobian => atoms::singular_jacobian(),
        SolveError::InvalidInput { .. } => atoms::invalid_input(),
    }
}

fn encode_covariance(env: Env<'_>, result: Result<DMatrix<f64>, SolveError>) -> Term<'_> {
    match result {
        Ok(cov) => (atoms::ok(), dmatrix_to_rows(&cov)).encode(env),
        Err(err) => (atoms::error(), solve_error_atom(err)).encode(env),
    }
}

/// Parameter covariance `variance_scale * (J^T J)^-1` from a design (Jacobian)
/// matrix, via the SVD of `J`.
pub(crate) fn normal_covariance_impl(
    env: Env<'_>,
    jacobian: Vec<Vec<f64>>,
    variance_scale: f64,
) -> NifResult<Term<'_>> {
    let Some(jac) = to_dmatrix(&jacobian) else {
        return Ok((atoms::error(), atoms::invalid_input()).encode(env));
    };
    Ok(encode_covariance(env, normal_covariance(&jac, variance_scale)))
}

/// Trace of the Gauss-Newton Hessian approximation `J^T J` (sum of squared
/// column norms of the Jacobian).
pub(crate) fn hessian_trace_impl(jacobian: Vec<Vec<f64>>) -> NifResult<f64> {
    // This accessor's contract is a bare `float()` with no error channel, so a
    // ragged matrix (a caller programming error) stays a raised `BadArg`.
    let jac = to_dmatrix(&jacobian).ok_or(rustler::Error::BadArg)?;
    Ok(hessian_trace(&jac))
}

/// Fitted parameter covariance directly from the design (Jacobian) matrix and
/// the post-fit cost: `(J^T J)^-1` scaled by the reduced chi-square
/// `2 * cost / (m - n)`, with the redundancy taken from the Jacobian's own shape
/// (`m = nrows`, `n = ncols`). Delegates straight to the core
/// `covariance_from_jacobian`, with no fabricated residual / parameter vectors.
pub(crate) fn covariance_from_jacobian_impl(
    env: Env<'_>,
    jacobian: Vec<Vec<f64>>,
    cost: f64,
) -> NifResult<Term<'_>> {
    let Some(jacobian) = to_dmatrix(&jacobian) else {
        return Ok((atoms::error(), atoms::invalid_input()).encode(env));
    };
    Ok(encode_covariance(
        env,
        covariance_from_jacobian(&jacobian, cost),
    ))
}

/// Confidence ellipse from an arbitrary 2x2 covariance block. Returns the
/// `{confidence, chi_square_scale, semi_major, semi_minor, orientation_rad}`
/// tuple.
pub(crate) fn error_ellipse_2x2_impl(
    env: Env<'_>,
    covariance_2x2: Vec<Vec<f64>>,
    confidence: f64,
) -> NifResult<Term<'_>> {
    // The Elixir caller forwards the block unchecked, so a non-2x2 shape is user
    // input: report the documented `{:error, :invalid_input}` tuple, not a raise.
    if covariance_2x2.len() != 2 || covariance_2x2.iter().any(|row| row.len() != 2) {
        return Ok((atoms::error(), atoms::invalid_input()).encode(env));
    }
    let cov = [
        [covariance_2x2[0][0], covariance_2x2[0][1]],
        [covariance_2x2[1][0], covariance_2x2[1][1]],
    ];
    let term = match error_ellipse_2x2(cov, confidence) {
        Ok(ErrorEllipse2 {
            confidence,
            chi_square_scale,
            semi_major,
            semi_minor,
            orientation_rad,
        }) => (
            atoms::ok(),
            (
                confidence,
                chi_square_scale,
                semi_major,
                semi_minor,
                orientation_rad,
            ),
        )
            .encode(env),
        Err(DopError::TooFewSatellites) => {
            (atoms::error(), atoms::too_few_satellites()).encode(env)
        }
        Err(DopError::Singular) => (atoms::error(), atoms::singular_geometry()).encode(env),
        Err(DopError::InvalidInput { .. }) => (atoms::error(), atoms::invalid_input()).encode(env),
    };
    Ok(term)
}
