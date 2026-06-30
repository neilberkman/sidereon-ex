//! Rustler boundary for residual-distribution diagnostics.
//!
//! Pure glue over `sidereon_core::quality::normality`: it forwards a residual
//! list and the convention flags, calls the crate's moment and normality-test
//! functions, and encodes the scalar/struct results. The moment definitions,
//! Jarque-Bera, and the Shapiro-Wilk AS R94 port all live in the core; no
//! statistics live here.

use rustler::{Encoder, Env, Term};
use sidereon_core::quality::normality::{
    jarque_bera, kurtosis, moments, shapiro_wilk, skewness, NormalityError,
};

mod atoms {
    rustler::atoms! {
        ok,
        error,
        non_finite,
        insufficient_data,
        zero_variance,
        zero_range
    }
}

fn error_atom(err: NormalityError) -> rustler::types::atom::Atom {
    match err {
        NormalityError::NonFinite => atoms::non_finite(),
        NormalityError::InsufficientData { .. } => atoms::insufficient_data(),
        NormalityError::ZeroVariance => atoms::zero_variance(),
        NormalityError::ZeroRange => atoms::zero_range(),
    }
}

fn encode_scalar(env: Env<'_>, result: Result<f64, NormalityError>) -> Term<'_> {
    match result {
        Ok(value) => (atoms::ok(), value).encode(env),
        Err(err) => (atoms::error(), error_atom(err)).encode(env),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn normality_skewness(env: Env<'_>, x: Vec<f64>, bias: bool) -> Term<'_> {
    encode_scalar(env, skewness(&x, bias))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn normality_kurtosis(env: Env<'_>, x: Vec<f64>, fisher: bool, bias: bool) -> Term<'_> {
    encode_scalar(env, kurtosis(&x, fisher, bias))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn normality_moments(env: Env<'_>, x: Vec<f64>, fisher: bool, bias: bool) -> Term<'_> {
    match moments(&x, fisher, bias) {
        Ok(stats) => (
            atoms::ok(),
            (stats.mean, stats.variance, stats.skewness, stats.kurtosis_excess),
        )
            .encode(env),
        Err(err) => (atoms::error(), error_atom(err)).encode(env),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn normality_jarque_bera(env: Env<'_>, x: Vec<f64>) -> Term<'_> {
    match jarque_bera(&x) {
        Ok(jb) => (atoms::ok(), (jb.statistic, jb.p_value)).encode(env),
        Err(err) => (atoms::error(), error_atom(err)).encode(env),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn normality_shapiro_wilk(env: Env<'_>, x: Vec<f64>) -> Term<'_> {
    match shapiro_wilk(&x) {
        Ok(sw) => (atoms::ok(), (sw.w, sw.p_value)).encode(env),
        Err(err) => (atoms::error(), error_atom(err)).encode(env),
    }
}
