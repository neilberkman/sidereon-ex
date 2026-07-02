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

#[rustler::nif]
fn angles_angular_separation(a: Vec3, b: Vec3) -> NifResult<f64> {
    angles::angular_separation([a.0, a.1, a.2], [b.0, b.1, b.2]).map_err(errors::invalid_input)
}

#[rustler::nif]
fn angles_angular_separation_coords(
    lon_lat_a_deg: (f64, f64),
    lon_lat_b_deg: (f64, f64),
) -> NifResult<f64> {
    angles::angular_separation_coords(lon_lat_a_deg, lon_lat_b_deg).map_err(errors::invalid_input)
}

#[rustler::nif]
fn angles_position_angle(lon_lat_a_deg: (f64, f64), lon_lat_b_deg: (f64, f64)) -> NifResult<f64> {
    angles::position_angle(lon_lat_a_deg, lon_lat_b_deg).map_err(errors::invalid_input)
}

#[rustler::nif]
fn angles_beta_angle(orbit_normal: Vec3, sun: Vec3) -> NifResult<f64> {
    angles::beta_angle(
        [orbit_normal.0, orbit_normal.1, orbit_normal.2],
        [sun.0, sun.1, sun.2],
    )
    .map_err(errors::invalid_input)
}

#[rustler::nif]
fn angles_beta_angle_from_state(r: Vec3, v: Vec3, sun: Vec3) -> NifResult<f64> {
    angles::beta_angle_from_state([r.0, r.1, r.2], [v.0, v.1, v.2], [sun.0, sun.1, sun.2])
        .map_err(errors::invalid_input)
}
