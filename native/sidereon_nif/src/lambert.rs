//! Lambert solver marshaling.
//!
//! Thin wrapper over `sidereon_core::astro::lambert`. All numeric logic lives in
//! the core engine; this layer only converts tuples to arrays and enum codes.

use rustler::NifResult;
use sidereon_core::astro::lambert::{battin, DirectionOfEnergy, DirectionOfMotion};

type Vec3 = (f64, f64, f64);

pub(crate) fn lambert_battin_impl(
    r1: Vec3,
    r2: Vec3,
    v1: Vec3,
    dm: i32,
    de: i32,
    nrev: i32,
    dtsec: f64,
) -> NifResult<(Vec3, Vec3)> {
    let r1a = [r1.0, r1.1, r1.2];
    let r2a = [r2.0, r2.1, r2.2];
    let v1a = [v1.0, v1.1, v1.2];

    let dm = if dm == 0 {
        DirectionOfMotion::Short
    } else {
        DirectionOfMotion::Long
    };
    let de = if de == 0 {
        DirectionOfEnergy::Low
    } else {
        DirectionOfEnergy::High
    };

    match battin(&r1a, &r2a, &v1a, dm, de, nrev, dtsec) {
        Ok((v1t, v2t)) => Ok(((v1t[0], v1t[1], v1t[2]), (v2t[0], v2t[1], v2t[2]))),
        Err(_) => Ok(((0.0, 0.0, 0.0), (0.0, 0.0, 0.0))),
    }
}
