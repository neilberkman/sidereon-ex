//! Rustler boundary for the `sidereon-core` classical orbital element transforms.
//!
//! Pure glue over `sidereon_core::astro::elements`: it decodes the Cartesian
//! state (or the classical element set) and the gravitational parameter, forwards
//! to [`rv2coe`] / [`coe2rv`], and encodes the result back. No two-body geometry,
//! special-case node handling, or Kepler math lives here. Position is in km,
//! velocity in km/s, `mu` in km^3/s^2; angles cross the boundary in radians, the
//! crate's native element units. A degenerate or non-finite input surfaces as a
//! raised `:invalid_input` atom.

use crate::errors;
use rustler::{Encoder, Env, NifResult, Term};
use sidereon_core::astro::elements::{coe2rv, rv2coe, ClassicalElements, OrbitType};

mod atoms {
    rustler::atoms! {
        ok,
        error,
        invalid_input
    }
}

type Vec3 = (f64, f64, f64);

/// The classical element set exchanged with the Elixir binding, mirroring
/// `%Sidereon.OrbitalElements{}`. Distances are km, angles radians; `orbit_type`
/// crosses as a lower-snake-case string.
/// The classical element set exchanged with the Elixir binding. The orientation
/// angles that are undefined for a degenerate orbit are emitted by the core as
/// `NaN`; since Erlang floats cannot carry `NaN`, they cross as `nil`
/// (`Option<f64>`), and the `orbit_type` tag names which angle is meaningful.
#[derive(Debug, Clone, rustler::NifMap)]
struct ClassicalElementsFields {
    p: f64,
    a: f64,
    ecc: f64,
    incl: f64,
    raan: Option<f64>,
    argp: Option<f64>,
    nu: Option<f64>,
    arglat: Option<f64>,
    truelon: Option<f64>,
    lonper: Option<f64>,
    orbit_type: String,
}

/// Map a possibly-`NaN` angle to `Some(finite)` / `None`.
fn finite(value: f64) -> Option<f64> {
    if value.is_finite() {
        Some(value)
    } else {
        None
    }
}

fn orbit_type_name(orbit_type: OrbitType) -> &'static str {
    match orbit_type {
        OrbitType::EllipticalInclined => "elliptical_inclined",
        OrbitType::EllipticalEquatorial => "elliptical_equatorial",
        OrbitType::CircularInclined => "circular_inclined",
        OrbitType::CircularEquatorial => "circular_equatorial",
    }
}

/// Map the orbit-type tag the Elixir side carries back onto the core enum so
/// `coe2rv` reads the angle that is meaningful for a degenerate geometry.
fn orbit_type_from_name(name: &str) -> Option<OrbitType> {
    Some(match name {
        "elliptical_inclined" => OrbitType::EllipticalInclined,
        "elliptical_equatorial" => OrbitType::EllipticalEquatorial,
        "circular_inclined" => OrbitType::CircularInclined,
        "circular_equatorial" => OrbitType::CircularEquatorial,
        _ => return None,
    })
}

impl From<ClassicalElements> for ClassicalElementsFields {
    fn from(c: ClassicalElements) -> Self {
        Self {
            p: c.p,
            a: c.a,
            ecc: c.ecc,
            incl: c.incl,
            raan: finite(c.raan),
            argp: finite(c.argp),
            nu: finite(c.nu),
            arglat: finite(c.arglat),
            truelon: finite(c.truelon),
            lonper: finite(c.lonper),
            orbit_type: orbit_type_name(c.orbit_type).to_string(),
        }
    }
}

/// Classical orbital elements from a Cartesian state. Returns the element-set
/// map; the `orbit_type` tag tells the caller which angle (`arglat`/`truelon`/
/// `lonper`) carries the meaningful value for a degenerate geometry.
#[rustler::nif]
fn elements_rv2coe<'a>(env: Env<'a>, r: Vec3, v: Vec3, mu: f64) -> Term<'a> {
    match rv2coe([r.0, r.1, r.2], [v.0, v.1, v.2], mu) {
        Ok(coe) => (atoms::ok(), ClassicalElementsFields::from(coe)).encode(env),
        Err(_) => (atoms::error(), atoms::invalid_input()).encode(env),
    }
}

/// Cartesian position (km) and velocity (km/s) from a classical element set.
///
/// `orbit_type` selects which auxiliary angle (`arglat`/`truelon`/`lonper`) the
/// core reads for a degenerate orbit, so it is threaded through unchanged. The
/// semi-major axis `a` is not consumed by `coe2rv` and is not required on input.
#[rustler::nif]
#[allow(clippy::too_many_arguments)]
fn elements_coe2rv(
    p: f64,
    ecc: f64,
    incl: f64,
    raan: f64,
    argp: f64,
    nu: f64,
    arglat: f64,
    truelon: f64,
    lonper: f64,
    orbit_type: String,
    mu: f64,
) -> NifResult<(Vec3, Vec3)> {
    let orbit_type = orbit_type_from_name(&orbit_type)
        .ok_or_else(|| rustler::Error::Term(Box::new("unknown orbit_type")))?;
    let coe = ClassicalElements {
        p,
        a: 0.0,
        ecc,
        incl,
        raan,
        argp,
        nu,
        arglat,
        truelon,
        lonper,
        orbit_type,
    };
    let (r, v) = coe2rv(&coe, mu).map_err(errors::invalid_input)?;
    Ok(((r[0], r[1], r[2]), (v[0], v[1], v[2])))
}
