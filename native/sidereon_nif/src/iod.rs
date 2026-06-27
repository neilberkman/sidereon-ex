//! Initial-orbit-determination marshaling (Gibbs / Herrick-Gibbs).
//!
//! Thin wrapper over `sidereon_core::astro::iod`. All numeric logic lives in the
//! core engine; this layer only converts tuples to arrays.

use rustler::NifResult;
use sidereon_core::astro::iod::{gibbs, hgibbs};

type Vec3 = (f64, f64, f64);

pub(crate) fn gibbs_impl(r1: Vec3, r2: Vec3, r3: Vec3) -> NifResult<(Vec3, f64, f64, f64)> {
    let r1a = [r1.0, r1.1, r1.2];
    let r2a = [r2.0, r2.1, r2.2];
    let r3a = [r3.0, r3.1, r3.2];

    match gibbs(&r1a, &r2a, &r3a) {
        Ok((v2, theta12, theta23, copa)) => Ok(((v2[0], v2[1], v2[2]), theta12, theta23, copa)),
        Err(_) => Ok(((0.0, 0.0, 0.0), 0.0, 0.0, 0.0)),
    }
}

pub(crate) fn hgibbs_impl(
    r1: Vec3,
    r2: Vec3,
    r3: Vec3,
    jd1: f64,
    jd2: f64,
    jd3: f64,
) -> NifResult<(Vec3, f64, f64, f64)> {
    let r1a = [r1.0, r1.1, r1.2];
    let r2a = [r2.0, r2.1, r2.2];
    let r3a = [r3.0, r3.1, r3.2];

    match hgibbs(&r1a, &r2a, &r3a, jd1, jd2, jd3) {
        Ok((v2, theta12, theta23, copa)) => Ok(((v2[0], v2[1], v2[2]), theta12, theta23, copa)),
        Err(_) => Ok(((0.0, 0.0, 0.0), 0.0, 0.0, 0.0)),
    }
}
