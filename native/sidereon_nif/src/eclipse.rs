//! Rustler boundary for the core conical eclipse-shadow geometry.
//!
//! Pure glue: decode the satellite/Sun vectors, call the relocated
//! `sidereon_core::astro::events::eclipse` functions, encode the result. No shadow
//! formula lives here. The core now rejects degenerate input, surfaced here as
//! the shared `:invalid_input` atom.

use crate::errors;
use rustler::{Atom, NifResult};
use sidereon_core::astro::events::eclipse::{self, EarthShadowModel, EclipseStatus};

mod atoms {
    rustler::atoms! {
        sunlit,
        penumbra,
        umbra
    }
}

type Vec3 = (f64, f64, f64);

fn model_from_string(value: String) -> NifResult<EarthShadowModel> {
    match value.trim().to_ascii_lowercase().replace('-', "_").as_str() {
        "spherical" | "sphere" => Ok(EarthShadowModel::Spherical),
        "wgs84_oblate" | "oblate" | "wgs84" => Ok(EarthShadowModel::Wgs84Oblate),
        _ => Err(rustler::Error::BadArg),
    }
}

pub(crate) fn shadow_fraction_impl(sat: Vec3, sun: Vec3) -> NifResult<f64> {
    eclipse::shadow_fraction([sat.0, sat.1, sat.2], [sun.0, sun.1, sun.2])
        .map_err(errors::invalid_input)
}

pub(crate) fn status_impl(sat: Vec3, sun: Vec3) -> NifResult<Atom> {
    let status = eclipse::status([sat.0, sat.1, sat.2], [sun.0, sun.1, sun.2])
        .map_err(errors::invalid_input)?;
    status_atom(status)
}

fn status_atom(status: EclipseStatus) -> NifResult<Atom> {
    Ok(match status {
        EclipseStatus::Sunlit => atoms::sunlit(),
        EclipseStatus::Penumbra => atoms::penumbra(),
        EclipseStatus::Umbra => atoms::umbra(),
    })
}

pub(crate) fn shadow_fraction_with_model_impl(
    sat: Vec3,
    sun: Vec3,
    model: String,
) -> NifResult<f64> {
    eclipse::shadow_fraction_with_model(
        [sat.0, sat.1, sat.2],
        [sun.0, sun.1, sun.2],
        model_from_string(model)?,
    )
    .map_err(errors::invalid_input)
}

pub(crate) fn status_with_model_impl(sat: Vec3, sun: Vec3, model: String) -> NifResult<Atom> {
    let status = eclipse::status_with_model(
        [sat.0, sat.1, sat.2],
        [sun.0, sun.1, sun.2],
        model_from_string(model)?,
    )
    .map_err(errors::invalid_input)?;
    status_atom(status)
}
