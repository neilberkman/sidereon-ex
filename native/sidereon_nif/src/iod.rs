//! Initial-orbit-determination marshaling (Gibbs / Herrick-Gibbs).
//!
//! Thin wrapper over `sidereon_core::astro::iod`. All numeric logic lives in the
//! core engine; this layer only converts tuples to arrays.

use rustler::{Encoder, Env, Term};
use sidereon_core::astro::iod::{gibbs, hgibbs, IodError};

type Vec3 = (f64, f64, f64);

mod atoms {
    rustler::atoms! {
        ok,
        error,
        iod_error,
        determinant_too_small,
        orbit_not_possible,
        zero_vector,
        collinear_vectors,
        not_coplanar,
        invalid_time_geometry,
        no_positive_root,
        root_solve_failed,
        non_finite_value,
    }
}

pub(crate) fn error_term<'a>(env: Env<'a>, error: IodError) -> Term<'a> {
    use IodError as E;
    let kind = match error {
        E::DeterminantTooSmall => atoms::determinant_too_small(),
        E::OrbitNotPossible => atoms::orbit_not_possible(),
        E::ZeroVector => atoms::zero_vector(),
        E::CollinearVectors => atoms::collinear_vectors(),
        E::NotCoplanar => atoms::not_coplanar(),
        E::InvalidTimeGeometry => atoms::invalid_time_geometry(),
        E::NoPositiveRoot => atoms::no_positive_root(),
        E::RootSolveFailed => atoms::root_solve_failed(),
        E::NonFiniteValue => atoms::non_finite_value(),
    };
    (atoms::iod_error(), kind, error.to_string()).encode(env)
}

pub(crate) fn encode_result<'a, T: Encoder>(env: Env<'a>, result: Result<T, IodError>) -> Term<'a> {
    match result {
        Ok(value) => (atoms::ok(), value).encode(env),
        Err(error) => (atoms::error(), error_term(env, error)).encode(env),
    }
}

pub(crate) fn gibbs_impl(r1: Vec3, r2: Vec3, r3: Vec3) -> Result<(Vec3, f64, f64, f64), IodError> {
    let r1a = [r1.0, r1.1, r1.2];
    let r2a = [r2.0, r2.1, r2.2];
    let r3a = [r3.0, r3.1, r3.2];

    gibbs(&r1a, &r2a, &r3a)
        .map(|(v2, theta12, theta23, copa)| ((v2[0], v2[1], v2[2]), theta12, theta23, copa))
}

pub(crate) fn hgibbs_impl(
    r1: Vec3,
    r2: Vec3,
    r3: Vec3,
    jd1: f64,
    jd2: f64,
    jd3: f64,
) -> Result<(Vec3, f64, f64, f64), IodError> {
    let r1a = [r1.0, r1.1, r1.2];
    let r2a = [r2.0, r2.1, r2.2];
    let r3a = [r3.0, r3.1, r3.2];

    hgibbs(&r1a, &r2a, &r3a, jd1, jd2, jd3)
        .map(|(v2, theta12, theta23, copa)| ((v2[0], v2[1], v2[2]), theta12, theta23, copa))
}
