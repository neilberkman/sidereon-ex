//! Rustler boundary for the `sidereon-core` observational-geometry primitives.
//!
//! Pure glue over `sidereon_core::astro::observation`: it decodes the scalar and
//! vector inputs, forwards them to the crate kernels, and encodes the results
//! back. No sub-point, terminator, parallactic-angle, phase-law, or IAU rotation
//! math lives here. Angles cross the boundary in degrees and vectors as `{x, y,
//! z}` tuples, exactly as the crate's documented boundary units. A degenerate or
//! out-of-domain input surfaces as a raised `:invalid_input` atom.

use crate::errors;
use rustler::NifResult;
use sidereon_core::astro::observation::{
    parallactic_angle_deg, satellite_visual_magnitude, sub_observer_point, sub_solar_point,
    terminator_latitude_deg, SurfacePoint,
};

type Vec3 = (f64, f64, f64);

/// Sub-solar point `{latitude_deg, longitude_deg}` for an Earth-fixed Sun vector.
#[rustler::nif]
fn observation_sub_solar_point(sun_ecef: Vec3) -> NifResult<(f64, f64)> {
    let point = sub_solar_point([sun_ecef.0, sun_ecef.1, sun_ecef.2])
        .map_err(errors::invalid_input)?;
    Ok((point.latitude_deg, point.longitude_deg))
}

/// Day-night terminator latitude (degrees) at a query longitude, given the
/// sub-solar point.
#[rustler::nif]
fn observation_terminator_latitude_deg(
    sub_solar_latitude_deg: f64,
    sub_solar_longitude_deg: f64,
    longitude_deg: f64,
) -> NifResult<f64> {
    terminator_latitude_deg(
        SurfacePoint {
            latitude_deg: sub_solar_latitude_deg,
            longitude_deg: sub_solar_longitude_deg,
        },
        longitude_deg,
    )
    .map_err(errors::invalid_input)
}

/// Parallactic angle (degrees) of a target at a station.
#[rustler::nif]
fn observation_parallactic_angle_deg(
    observer_latitude_deg: f64,
    hour_angle_deg: f64,
    declination_deg: f64,
) -> NifResult<f64> {
    parallactic_angle_deg(observer_latitude_deg, hour_angle_deg, declination_deg)
        .map_err(errors::invalid_input)
}

/// Apparent visual magnitude of a sunlit body from the diffuse-sphere phase law.
#[rustler::nif]
fn observation_satellite_visual_magnitude(
    range_km: f64,
    phase_angle_deg: f64,
    standard_magnitude: f64,
    reference_range_km: f64,
) -> NifResult<f64> {
    satellite_visual_magnitude(
        range_km,
        phase_angle_deg,
        standard_magnitude,
        reference_range_km,
    )
    .map_err(errors::invalid_input)
}

/// Sub-observer point `{latitude_deg, longitude_deg}` (planetary central
/// meridian) for an inertial observer vector and an IAU body orientation.
#[rustler::nif]
fn observation_sub_observer_point(
    observer_from_body: Vec3,
    pole_ra_deg: f64,
    pole_dec_deg: f64,
    prime_meridian_deg: f64,
) -> NifResult<(f64, f64)> {
    let point = sub_observer_point(
        [
            observer_from_body.0,
            observer_from_body.1,
            observer_from_body.2,
        ],
        pole_ra_deg,
        pole_dec_deg,
        prime_meridian_deg,
    )
    .map_err(errors::invalid_input)?;
    Ok((point.latitude_deg, point.longitude_deg))
}
