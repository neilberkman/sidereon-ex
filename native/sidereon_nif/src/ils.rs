//! Rustler boundary for the bounded integer-least-squares kernel.
//!
//! Pure glue: decodes the ordered float ambiguities + covariance + search
//! options, calls `sidereon_core::ils::bounded_ils_search`, and encodes the
//! result back. Elixir callers own any id<->order mapping and public metadata
//! shaping.

use rustler::{Encoder, Env, NifResult, Term};
use sidereon_core::ils::{bounded_ils_search, lambda_ils_search, IlsError};

mod atoms {
    rustler::atoms! {
        ok,
        error,
        infinity,
        singular_geometry,
        no_integer_candidates,
        too_many_integer_candidates,
        invalid_dimensions,
        non_finite_input,
        invalid_input,
        search_limit_exceeded
    }
}

/// Run a bounded ILS search over ordered float ambiguities + their covariance.
///
/// Returns `{fixed, fixed_status, ratio, best_score, second_best_score,
/// candidates_evaluated, covariance, covariance_inverse}` where `ratio` is the
/// atom `:infinity` for a zero-best-score-with-runner-up, `second_best_score` is
/// `nil` when there is no runner-up, and the two matrices are the symmetrized
/// covariance and its inverse. Dirty-CPU: the lattice search over a multi-epoch
/// arc (and the partial-AR subset sweep) is unbounded relative to the 1 ms NIF
/// budget.
#[rustler::nif(schedule = "DirtyCpu")]
fn ils_search<'a>(
    env: Env<'a>,
    float_cycles: Vec<f64>,
    covariance: Vec<Vec<f64>>,
    radius: i64,
    candidate_limit: usize,
    ratio_threshold: f64,
) -> NifResult<Term<'a>> {
    encode_ils(
        env,
        bounded_ils_search(
            &float_cycles,
            &covariance,
            radius,
            candidate_limit,
            ratio_threshold,
        ),
    )
}

/// Correct integer least squares via the LAMBDA method (RTKLIB `lambda()` port).
///
/// Same `{:ok, {...}}` / `{:error, ...}` shape as [`ils_search`], but solves any
/// positive-definite covariance correctly (no search box, no `radius`/
/// `candidate_limit`). The only failure is a degenerate (non-PD) covariance,
/// reported as `{:error, :singular_geometry}`.
#[rustler::nif(schedule = "DirtyCpu")]
fn ils_lambda_search<'a>(
    env: Env<'a>,
    float_cycles: Vec<f64>,
    covariance: Vec<Vec<f64>>,
    ratio_threshold: f64,
) -> NifResult<Term<'a>> {
    encode_ils(
        env,
        lambda_ils_search(&float_cycles, &covariance, ratio_threshold),
    )
}

/// Encode an `IlsResult`/`IlsError` into the shared Elixir result shape.
fn encode_ils<'a>(
    env: Env<'a>,
    result: Result<sidereon_core::ils::IlsResult, IlsError>,
) -> NifResult<Term<'a>> {
    match result {
        Ok(r) => {
            let ratio_term: Term<'a> = if r.ratio.is_infinite() {
                atoms::infinity().encode(env)
            } else {
                r.ratio.encode(env)
            };

            let second_term: Term<'a> = match r.second_best_score {
                Some(s) => s.encode(env),
                None => rustler::types::atom::nil().encode(env),
            };

            let result = (
                r.fixed,
                r.fixed_status,
                ratio_term,
                r.best_score,
                second_term,
                r.candidates_evaluated,
                (r.covariance, r.covariance_inverse),
            );
            Ok((atoms::ok(), result).encode(env))
        }

        // Map onto the reference Elixir error tuples so the contract is preserved.
        Err(IlsError::Singular) => Ok((atoms::error(), atoms::singular_geometry()).encode(env)),

        Err(IlsError::NoCandidates(n)) => {
            Ok((atoms::error(), (atoms::no_integer_candidates(), n)).encode(env))
        }

        Err(IlsError::TooManyCandidates { evaluated, limit }) => Ok((
            atoms::error(),
            (atoms::too_many_integer_candidates(), evaluated, limit),
        )
            .encode(env)),

        Err(IlsError::InvalidDimensions { n, rows }) => {
            Ok((atoms::error(), (atoms::invalid_dimensions(), n, rows)).encode(env))
        }

        Err(IlsError::NonFinite) => Ok((atoms::error(), atoms::non_finite_input()).encode(env)),

        Err(IlsError::InvalidInput { .. }) => {
            Ok((atoms::error(), atoms::invalid_input()).encode(env))
        }

        Err(IlsError::SearchLimitExceeded) => {
            Ok((atoms::error(), atoms::search_limit_exceeded()).encode(env))
        }
    }
}
