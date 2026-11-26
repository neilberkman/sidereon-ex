//! Rustler boundary for the core conical eclipse-shadow geometry.
//!
//! Pure glue: decode the satellite/Sun vectors, call the relocated
//! `sidereon_core::astro::events::eclipse` functions, encode the result. No shadow
//! formula lives here. The core now rejects degenerate input, surfaced here as
//! the shared `:invalid_input` atom.

use crate::errors::{self, encode_result, Refusal};
use rustler::{Atom, Encoder, Env, NifMap, NifResult, Term};
use sidereon_core::astro::events::eclipse::ShadowGradientError;
use sidereon_core::astro::events::eclipse::{self, EarthShadowModel, EclipseStatus};

mod atoms {
    rustler::atoms! {
        sunlit,
        penumbra,
        umbra
    }
}

type Vec3 = (f64, f64, f64);

pub(crate) fn model_from_string(value: String) -> NifResult<EarthShadowModel> {
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

#[derive(NifMap)]
#[rustler(encode)]
struct EclipseInput {
    field: &'static str,
    reason: &'static str,
}

rustler::atoms! { invalid_input, eclipse, numerical_failure, invalid_earth_shadow_model }

fn input_detail(error: &eclipse::EclipseError) -> EclipseInput {
    let eclipse::EclipseError::InvalidInput { field, reason } = *error;
    EclipseInput { field, reason }
}

fn input_error<'a>(env: Env<'a>, error: eclipse::EclipseError) -> Refusal<'a> {
    Refusal {
        kind: invalid_input(),
        detail: input_detail(&error).encode(env),
        message: error.to_string(),
    }
}

fn gradient_error(env: Env<'_>, error: ShadowGradientError) -> Refusal<'_> {
    let (kind, detail) = match &error {
        ShadowGradientError::Eclipse(error) => (eclipse(), input_detail(error).encode(env)),
        ShadowGradientError::NumericalFailure => (numerical_failure(), Term::map_new(env)),
        _ => (invalid_input(), Term::map_new(env)),
    };
    Refusal {
        kind,
        detail,
        message: error.to_string(),
    }
}

#[derive(NifMap)]
struct ModelDetail<'a> {
    model: Term<'a>,
}

fn decode_model<'a>(env: Env<'a>, value: Term<'a>) -> Result<EarthShadowModel, Refusal<'a>> {
    let name = value.atom_to_string().or_else(|_| value.decode::<String>());
    name.and_then(model_from_string).map_err(|_| Refusal {
        kind: invalid_earth_shadow_model(),
        detail: ModelDetail { model: value }.encode(env),
        message: "Invalid Earth shadow model".into(),
    })
}

#[rustler::nif]
fn eclipse_moon_shadow_fraction<'a>(
    env: Env<'a>,
    satellite: Vec3,
    sun: Vec3,
    moon: Vec3,
) -> Term<'a> {
    encode_result(
        env,
        eclipse::moon_shadow_fraction(satellite.into(), sun.into(), moon.into())
            .map_err(|error| input_error(env, error)),
    )
}

#[rustler::nif]
fn eclipse_shadow_fraction_with_moon<'a>(
    env: Env<'a>,
    satellite: Vec3,
    sun: Vec3,
    moon: Vec3,
) -> Term<'a> {
    encode_result(
        env,
        eclipse::shadow_fraction_with_moon(satellite.into(), sun.into(), moon.into())
            .map_err(|error| input_error(env, error)),
    )
}

#[rustler::nif]
fn eclipse_shadow_fraction_with_model_and_moon<'a>(
    env: Env<'a>,
    satellite: Vec3,
    sun: Vec3,
    moon: Vec3,
    model: Term<'a>,
) -> Term<'a> {
    let model = match decode_model(env, model) {
        Ok(model) => model,
        Err(error) => return encode_result(env, Err::<(), _>(error)),
    };
    encode_result(
        env,
        eclipse::shadow_fraction_with_model_and_moon(
            satellite.into(),
            sun.into(),
            moon.into(),
            model,
        )
        .map_err(|error| input_error(env, error)),
    )
}

#[rustler::nif]
fn eclipse_status_with_moon<'a>(env: Env<'a>, satellite: Vec3, sun: Vec3, moon: Vec3) -> Term<'a> {
    encode_result(
        env,
        eclipse::status_with_moon(satellite.into(), sun.into(), moon.into())
            .map(|status| status_atom(status).expect("known eclipse status"))
            .map_err(|error| input_error(env, error)),
    )
}

#[rustler::nif]
fn eclipse_status_with_model_and_moon<'a>(
    env: Env<'a>,
    satellite: Vec3,
    sun: Vec3,
    moon: Vec3,
    model: Term<'a>,
) -> Term<'a> {
    let model = match decode_model(env, model) {
        Ok(model) => model,
        Err(error) => return encode_result(env, Err::<(), _>(error)),
    };
    encode_result(
        env,
        eclipse::status_with_model_and_moon(satellite.into(), sun.into(), moon.into(), model)
            .map(|status| status_atom(status).expect("known eclipse status"))
            .map_err(|error| input_error(env, error)),
    )
}

#[rustler::nif]
fn eclipse_shadow_fraction_with_gradient<'a>(env: Env<'a>, satellite: Vec3, sun: Vec3) -> Term<'a> {
    encode_result(
        env,
        eclipse::shadow_fraction_with_gradient(satellite.into(), sun.into())
            .map(|(fraction, gradient)| (fraction, crate::vector_tuple(gradient)))
            .map_err(|error| gradient_error(env, error)),
    )
}

#[rustler::nif]
fn eclipse_shadow_fraction_with_model_and_gradient<'a>(
    env: Env<'a>,
    satellite: Vec3,
    sun: Vec3,
    model: Term<'a>,
) -> Term<'a> {
    let model = match decode_model(env, model) {
        Ok(model) => model,
        Err(error) => return encode_result(env, Err::<(), _>(error)),
    };
    encode_result(
        env,
        eclipse::shadow_fraction_with_model_and_gradient(satellite.into(), sun.into(), model)
            .map(|(fraction, gradient)| (fraction, crate::vector_tuple(gradient)))
            .map_err(|error| gradient_error(env, error)),
    )
}

#[rustler::nif]
fn eclipse_shadow_fraction_with_model_moon_and_gradient<'a>(
    env: Env<'a>,
    satellite: Vec3,
    sun: Vec3,
    moon: Vec3,
    model: Term<'a>,
) -> Term<'a> {
    let model = match decode_model(env, model) {
        Ok(model) => model,
        Err(error) => return encode_result(env, Err::<(), _>(error)),
    };
    encode_result(
        env,
        eclipse::shadow_fraction_with_model_moon_and_gradient(
            satellite.into(),
            sun.into(),
            moon.into(),
            model,
        )
        .map(|(fraction, gradient)| (fraction, crate::vector_tuple(gradient)))
        .map_err(|error| gradient_error(env, error)),
    )
}
