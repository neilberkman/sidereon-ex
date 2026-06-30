//! Rustler boundary for the generic data-driven trust-region least-squares
//! engine.
//!
//! Pure glue over `trust_region_least_squares`: it selects a built-in residual
//! kind, fills a [`DataProblem`] field-by-field from the decoded Elixir terms,
//! and runs the whole trust-region iteration in Rust via
//! [`solve_data_problem`] (or the leave-one-out
//! [`solve_data_problem_drop_one`]). The residual and Jacobian are evaluated
//! entirely inside the crate, so a solve pays one boundary crossing in and one
//! out, never one per function evaluation. No solver math lives here.
//!
//! The default backend is the in-crate nalgebra thin SVD (works everywhere).
//! Passing `backend = "lapack"` injects the host-LAPACK backend
//! ([`LapackSvd::from_env`]) for bit-for-bit SciPy parity; that path needs the
//! `TRUST_REGION_LEAST_SQUARES_LAPACK_PATH` env var pointed at a host
//! LAPACK/numpy BLAS and is only exercised by the Linux-x86_64 parity tests.

use rustler::{Encoder, Env, Term};
use trust_region_least_squares::data::{
    solve_data_problem, solve_data_problem_with, BuiltinResidual, DataProblem,
};
use trust_region_least_squares::batch::{solve_data_problem_drop_one, solve_data_problem_drop_one_with};
use trust_region_least_squares::hostlapack::LapackSvd;
use trust_region_least_squares::loss::Loss;
use trust_region_least_squares::trf::{ThinSvd, TrfError, TrfResult, XScale};

mod atoms {
    rustler::atoms! {
        ok,
        error,
        // residual kinds
        // backends
        // typed solver errors
        empty_residual,
        empty_parameters,
        non_finite_parameters,
        non_finite_initial_residual,
        insufficient_rows,
        size_overflow,
        degree_overflow,
        invalid_max_nfev,
        invalid_f_scale,
        invalid_x_scale_length,
        invalid_x_scale_value,
        invalid_jacobian_length,
        invalid_residual_length,
        invalid_slice_length,
        invalid_svd_output,
        svd_backend_error,
        unknown_residual_kind,
        unknown_loss,
        unknown_backend,
        unknown_x_scale,
        lapack_unavailable
    }
}

/// Construct the host-LAPACK SVD backend and prove it is actually usable.
///
/// `LapackSvd::from_env` only stashes the configuration; the real work (resolving
/// `TRUST_REGION_LEAST_SQUARES_LAPACK_PATH`, the `dlopen`, and the symbol lookup)
/// happens lazily on the first decomposition. A missing/invalid path or a failed
/// dynamic load is a runtime configuration condition, not a panic: probe it here
/// with a trivial 1x1 SVD and surface `:lapack_unavailable` so the libloading
/// path can never unwind across the NIF boundary. Once the probe succeeds, any
/// later SVD failure is a genuine numerical error reported as `:svd_backend_error`.
fn lapack_backend() -> Result<LapackSvd, rustler::types::atom::Atom> {
    let backend = LapackSvd::from_env();
    match backend.svd(&[1.0], 1, 1) {
        Ok(_) => Ok(backend),
        Err(_) => Err(atoms::lapack_unavailable()),
    }
}

/// A single [`TrfResult`] encoded as the nested tuple the Elixir layer decodes
/// (rustler's tuple `Encoder` does not reach 12-arity, so the twelve fields are
/// split into two 6-tuples). The Jacobian is returned as a flat row-major list
/// together with `(m, n)` so the binding can reshape it; reshaping here would
/// copy the buffer twice.
type ResultTuple = (
    (
        Vec<f64>, // x
        f64,      // cost
        Vec<f64>, // fun (residuals)
        Vec<f64>, // jac (row-major, m*n)
        usize,    // m (residual rows)
        usize,    // n (parameters)
    ),
    (
        Vec<f64>, // grad
        f64,      // optimality
        usize,    // nfev
        usize,    // njev
        i32,      // status
        bool,     // success
    ),
);

fn result_tuple(result: &TrfResult) -> ResultTuple {
    let n = result.x.len();
    let m = result.fun.len();
    (
        (
            result.x.clone(),
            result.cost,
            result.fun.clone(),
            result.jac.clone(),
            m,
            n,
        ),
        (
            result.grad.clone(),
            result.optimality,
            result.nfev,
            result.njev,
            result.status,
            result.success(),
        ),
    )
}

/// Build a [`BuiltinResidual`] from the decoded kind discriminant and data
/// arrays. Only the arrays relevant to the selected kind are consulted; the
/// crate's own `validate` is the authoritative shape gate at solve time.
#[allow(clippy::too_many_arguments)]
fn builtin_residual(
    kind: &str,
    a: Vec<f64>,
    b: Vec<f64>,
    m: usize,
    n: usize,
    t: Vec<f64>,
    y: Vec<f64>,
    degree: usize,
) -> Option<BuiltinResidual> {
    match kind {
        "linear" => Some(BuiltinResidual::Linear { a, b, m, n }),
        "polynomial" => Some(BuiltinResidual::Polynomial { degree, t, y }),
        "exponential" => Some(BuiltinResidual::Exponential { t, y }),
        _ => None,
    }
}

fn loss_from_str(loss: &str) -> Option<Loss> {
    Some(match loss {
        "linear" => Loss::Linear,
        "soft_l1" => Loss::SoftL1,
        "huber" => Loss::Huber,
        "cauchy" => Loss::Cauchy,
        "arctan" => Loss::Arctan,
        _ => return None,
    })
}

fn x_scale_from(kind: &str, values: Vec<f64>) -> Option<XScale> {
    Some(match kind {
        "unit" => XScale::Unit,
        "jac" => XScale::Jac,
        "values" => XScale::Values(values),
        _ => return None,
    })
}

/// Assemble a fully specified [`DataProblem`] or report which discriminant the
/// caller passed wrong, as a typed atom.
#[allow(clippy::too_many_arguments)]
fn build_problem(
    kind: String,
    a: Vec<f64>,
    b: Vec<f64>,
    m: usize,
    n: usize,
    t: Vec<f64>,
    y: Vec<f64>,
    degree: usize,
    x0: Vec<f64>,
    loss: String,
    f_scale: f64,
    x_scale_kind: String,
    x_scale_values: Vec<f64>,
    max_nfev: i64,
    ftol: f64,
    xtol: f64,
    gtol: f64,
) -> Result<DataProblem, rustler::types::atom::Atom> {
    let Some(residual) = builtin_residual(&kind, a, b, m, n, t, y, degree) else {
        return Err(atoms::unknown_residual_kind());
    };
    let Some(loss) = loss_from_str(&loss) else {
        return Err(atoms::unknown_loss());
    };
    let Some(x_scale) = x_scale_from(&x_scale_kind, x_scale_values) else {
        return Err(atoms::unknown_x_scale());
    };
    let mut problem = DataProblem::new(residual, x0);
    problem.loss = loss;
    problem.f_scale = f_scale;
    problem.x_scale = x_scale;
    // A negative budget marks "use the SciPy default (100 * n)".
    problem.max_nfev = (max_nfev >= 0).then_some(max_nfev as usize);
    problem.ftol = ftol;
    problem.xtol = xtol;
    problem.gtol = gtol;
    Ok(problem)
}

fn trf_error_atom(err: &TrfError) -> rustler::types::atom::Atom {
    match err {
        TrfError::EmptyResidual => atoms::empty_residual(),
        TrfError::EmptyParameters => atoms::empty_parameters(),
        TrfError::NonFiniteParameters => atoms::non_finite_parameters(),
        TrfError::NonFiniteInitialResidual => atoms::non_finite_initial_residual(),
        TrfError::InsufficientRows { .. } => atoms::insufficient_rows(),
        TrfError::SizeOverflow { .. } => atoms::size_overflow(),
        TrfError::DegreeOverflow { .. } => atoms::degree_overflow(),
        TrfError::InvalidMaxNfev => atoms::invalid_max_nfev(),
        TrfError::InvalidFScale { .. } => atoms::invalid_f_scale(),
        TrfError::InvalidXScaleLength { .. } => atoms::invalid_x_scale_length(),
        TrfError::InvalidXScaleValue { .. } => atoms::invalid_x_scale_value(),
        TrfError::InvalidJacobianLength { .. } => atoms::invalid_jacobian_length(),
        TrfError::InvalidResidualLength { .. } => atoms::invalid_residual_length(),
        TrfError::InvalidSliceLength { .. } => atoms::invalid_slice_length(),
        TrfError::InvalidSvdOutput(_) => atoms::invalid_svd_output(),
        TrfError::Svd(_) => atoms::svd_backend_error(),
    }
}

/// Solve a generic data-driven least-squares problem entirely in Rust.
#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
pub fn trls_solve<'a>(
    env: Env<'a>,
    kind: String,
    a: Vec<f64>,
    b: Vec<f64>,
    m: usize,
    n: usize,
    t: Vec<f64>,
    y: Vec<f64>,
    degree: usize,
    x0: Vec<f64>,
    loss: String,
    f_scale: f64,
    x_scale_kind: String,
    x_scale_values: Vec<f64>,
    max_nfev: i64,
    ftol: f64,
    xtol: f64,
    gtol: f64,
    backend: String,
) -> Term<'a> {
    let problem = match build_problem(
        kind, a, b, m, n, t, y, degree, x0, loss, f_scale, x_scale_kind, x_scale_values, max_nfev,
        ftol, xtol, gtol,
    ) {
        Ok(problem) => problem,
        Err(atom) => return (atoms::error(), atom).encode(env),
    };

    let solved = match backend.as_str() {
        "native" => solve_data_problem(&problem),
        "lapack" => match lapack_backend() {
            Ok(lapack) => solve_data_problem_with(&problem, &lapack),
            Err(atom) => return (atoms::error(), atom).encode(env),
        },
        _ => return (atoms::error(), atoms::unknown_backend()).encode(env),
    };

    match solved {
        Ok(result) => (atoms::ok(), result_tuple(&result)).encode(env),
        Err(err) => (atoms::error(), trf_error_atom(&err)).encode(env),
    }
}

/// Leave-one-out sweep: the base solve plus one re-solve per masked residual
/// row (RAIM/FDE), with the per-row cost deltas.
#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
pub fn trls_solve_drop_one<'a>(
    env: Env<'a>,
    kind: String,
    a: Vec<f64>,
    b: Vec<f64>,
    m: usize,
    n: usize,
    t: Vec<f64>,
    y: Vec<f64>,
    degree: usize,
    x0: Vec<f64>,
    loss: String,
    f_scale: f64,
    x_scale_kind: String,
    x_scale_values: Vec<f64>,
    max_nfev: i64,
    ftol: f64,
    xtol: f64,
    gtol: f64,
    backend: String,
) -> Term<'a> {
    let problem = match build_problem(
        kind, a, b, m, n, t, y, degree, x0, loss, f_scale, x_scale_kind, x_scale_values, max_nfev,
        ftol, xtol, gtol,
    ) {
        Ok(problem) => problem,
        Err(atom) => return (atoms::error(), atom).encode(env),
    };

    let solved = match backend.as_str() {
        "native" => solve_data_problem_drop_one(&problem),
        "lapack" => match lapack_backend() {
            Ok(lapack) => solve_data_problem_drop_one_with(&problem, &lapack),
            Err(atom) => return (atoms::error(), atom).encode(env),
        },
        _ => return (atoms::error(), atoms::unknown_backend()).encode(env),
    };

    match solved {
        Ok(report) => {
            let base = result_tuple(&report.base);
            let drops: Vec<ResultTuple> = report.drops.iter().map(result_tuple).collect();
            (atoms::ok(), (base, drops, report.cost_delta)).encode(env)
        }
        Err(err) => (atoms::error(), trf_error_atom(&err)).encode(env),
    }
}
