//! Neutral-atmosphere density marshaling.
//!
//! Thin wrapper over `sidereon_core::astro::atmosphere`. All numeric logic lives
//! in the core engine; this layer only assembles the input struct and unpacks
//! the result.

use rustler::NifResult;
use sidereon_core::astro::atmosphere::{local_solar_time, nrlmsise00, NrlmsiseInput};

/// NIF entry point for atmosphere_density.
///
/// Arguments: lat_deg, lon_deg, alt_km, year, doy, sec, f107, f107a, ap.
/// Returns: {density_kg_m3, temperature_K}.
#[allow(clippy::too_many_arguments)]
pub(crate) fn atmosphere_density_impl(
    lat_deg: f64,
    lon_deg: f64,
    alt_km: f64,
    year: i32,
    doy: i32,
    sec: f64,
    f107: f64,
    f107a: f64,
    ap: f64,
) -> NifResult<(f64, f64)> {
    let lst = local_solar_time(sec, lon_deg);

    let input = NrlmsiseInput {
        year,
        doy,
        sec,
        alt: alt_km,
        g_lat: lat_deg,
        g_long: lon_deg,
        lst,
        f107a,
        f107,
        ap,
        ap_array: None,
    };

    let output = nrlmsise00(&input).map_err(crate::errors::atmosphere)?;
    Ok((output.density(), output.temperature_alt()))
}
