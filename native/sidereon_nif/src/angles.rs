//! Rustler boundary for the core satellite angular-geometry formulas.
//!
//! Pure glue: decode the GCRS position vectors, call the relocated
//! `sidereon_core::astro::angles` functions, return the resulting degrees. No angle
//! formula lives here. The core now rejects degenerate (zero-length) vectors, so
//! each binding forwards that failure as the shared `:invalid_input` atom.

use crate::errors;
use rustler::NifResult;
use sidereon_core::astro::angles;

type Vec3 = (f64, f64, f64);

pub(crate) fn sun_angle_impl(sat: Vec3, sun: Vec3) -> NifResult<f64> {
    angles::sun_angle([sat.0, sat.1, sat.2], [sun.0, sun.1, sun.2]).map_err(errors::invalid_input)
}

pub(crate) fn moon_angle_impl(sat: Vec3, moon: Vec3) -> NifResult<f64> {
    angles::moon_angle([sat.0, sat.1, sat.2], [moon.0, moon.1, moon.2])
        .map_err(errors::invalid_input)
}

pub(crate) fn sun_elevation_impl(sat: Vec3, sun: Vec3) -> NifResult<f64> {
    angles::sun_elevation([sat.0, sat.1, sat.2], [sun.0, sun.1, sun.2])
        .map_err(errors::invalid_input)
}

pub(crate) fn phase_angle_impl(sat: Vec3, sun: Vec3, observer: Vec3) -> NifResult<f64> {
    angles::phase_angle(
        [sat.0, sat.1, sat.2],
        [sun.0, sun.1, sun.2],
        [observer.0, observer.1, observer.2],
    )
    .map_err(errors::invalid_input)
}

pub(crate) fn earth_angular_radius_impl(sat: Vec3) -> NifResult<f64> {
    angles::earth_angular_radius([sat.0, sat.1, sat.2]).map_err(errors::invalid_input)
}
