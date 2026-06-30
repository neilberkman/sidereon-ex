//! Gauss angles-only IOD marshaling.
//!
//! Thin wrapper over `sidereon_core::astro::iod::gauss_angles`. All numeric
//! logic lives in the core engine; this layer only groups scalar arguments into
//! the arrays the core entry point expects.

use rustler::NifResult;
use sidereon_core::astro::iod::gauss_angles;

type Vec3 = (f64, f64, f64);

#[allow(clippy::too_many_arguments)]
pub(crate) fn gauss_impl(
    decl1: f64,
    decl2: f64,
    decl3: f64,
    rtasc1: f64,
    rtasc2: f64,
    rtasc3: f64,
    jd1: f64,
    jdf1: f64,
    jd2: f64,
    jdf2: f64,
    jd3: f64,
    jdf3: f64,
    rseci1: Vec3,
    rseci2: Vec3,
    rseci3: Vec3,
) -> NifResult<(Vec3, Vec3)> {
    let decl = [decl1, decl2, decl3];
    let rtasc = [rtasc1, rtasc2, rtasc3];
    let jd = [jd1, jd2, jd3];
    let jdf = [jdf1, jdf2, jdf3];
    let rseci = [
        [rseci1.0, rseci1.1, rseci1.2],
        [rseci2.0, rseci2.1, rseci2.2],
        [rseci3.0, rseci3.1, rseci3.2],
    ];

    match gauss_angles(&decl, &rtasc, &jd, &jdf, &rseci) {
        Ok((r2, v2)) => Ok(((r2[0], r2[1], r2[2]), (v2[0], v2[1], v2[2]))),
        Err(_) => Ok(((0.0, 0.0, 0.0), (0.0, 0.0, 0.0))),
    }
}
