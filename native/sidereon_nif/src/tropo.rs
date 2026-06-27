//! Rustler boundary for the `sidereon-core` tropospheric delay model.
//!
//! This module is **pure glue**: it decodes Erlang terms, calls the
//! `sidereon_core::atmosphere::troposphere` public APIs, and encodes the results back. No
//! Saastamoinen zenith formula and no Niell mapping numerics live here — those
//! are the crate's responsibility. This is the neutral-atmosphere signal delay
//! and is distinct from `Sidereon.Atmosphere` (NRLMSISE-00 mass density).
//!
//! - `tropo_zenith/5` returns the hydrostatic and wet zenith delays from
//!   supplied surface meteorology.
//! - `tropo_mapping/6` returns the Niell hydrostatic and wet mapping factors at
//!   an elevation.
//! - `tropo_slant/8` composes the zenith delays and the mapping into the full
//!   line-of-sight delay.
//!
//! Angles arrive in radians at the boundary (the Elixir wrapper converts its
//! degree inputs); the epoch is a split Julian date used for the Niell seasonal
//! day-of-year term.

use rustler::NifResult;
use sidereon_core::astro::time::model::{Instant, JulianDateSplit, TimeScale};
use sidereon_core::atmosphere::troposphere::{
    tropo_mapping, tropo_slant, tropo_zenith, MappingModel, Met, TropoModel,
};
use sidereon_core::Wgs84Geodetic;

/// Zenith hydrostatic and wet tropospheric delays (positive meters).
///
/// The receiver geodetic latitude and ellipsoidal height set the zenith
/// hydrostatic delay's gravity correction; pressure, temperature, and humidity
/// drive the Saastamoinen formulas. Returns `{dry_m, wet_m}`.
#[rustler::nif]
fn tropo_zenith_delay(
    lat_rad: f64,
    height_m: f64,
    pressure_hpa: f64,
    temperature_k: f64,
    relative_humidity: f64,
) -> NifResult<(f64, f64)> {
    let receiver =
        Wgs84Geodetic::new(lat_rad, 0.0, height_m).map_err(crate::errors::invalid_input)?;
    let met = Met::new(pressure_hpa, temperature_k, relative_humidity)
        .map_err(crate::errors::invalid_input)?;
    let z = tropo_zenith(TropoModel::Saastamoinen, receiver, met)
        .map_err(crate::errors::invalid_input)?;
    Ok((z.dry_m, z.wet_m))
}

/// Niell hydrostatic and wet mapping factors at an elevation (dimensionless).
///
/// The mapping depends on the elevation, the receiver geodetic latitude and
/// ellipsoidal height, and the fractional day-of-year taken from the epoch.
/// Returns `{dry, wet}`.
#[rustler::nif]
fn tropo_mapping_factors(
    elevation_rad: f64,
    lat_rad: f64,
    height_m: f64,
    jd_whole: f64,
    jd_fraction: f64,
) -> NifResult<(f64, f64)> {
    let receiver =
        Wgs84Geodetic::new(lat_rad, 0.0, height_m).map_err(crate::errors::invalid_input)?;
    let epoch = Instant::from_julian_date(
        TimeScale::Gpst,
        JulianDateSplit::new(jd_whole, jd_fraction).map_err(crate::errors::invalid_input)?,
    );
    let m = tropo_mapping(MappingModel::Niell, elevation_rad, receiver, epoch)
        .map_err(crate::errors::invalid_input)?;
    Ok((m.dry, m.wet))
}

/// Full slant tropospheric delay (positive meters).
///
/// Composes the Saastamoinen zenith delays with the Niell mapping. The receiver
/// geodetic latitude, longitude, and ellipsoidal height come from the first
/// three arguments; pressure, temperature, and humidity follow; the epoch sets
/// the seasonal day-of-year.
#[rustler::nif]
#[allow(clippy::too_many_arguments)]
fn tropo_slant_delay(
    elevation_rad: f64,
    lat_rad: f64,
    lon_rad: f64,
    height_m: f64,
    pressure_hpa: f64,
    temperature_k: f64,
    relative_humidity: f64,
    jd_whole: f64,
    jd_fraction: f64,
) -> NifResult<f64> {
    let receiver =
        Wgs84Geodetic::new(lat_rad, lon_rad, height_m).map_err(crate::errors::invalid_input)?;
    let met = Met::new(pressure_hpa, temperature_k, relative_humidity)
        .map_err(crate::errors::invalid_input)?;
    let epoch = Instant::from_julian_date(
        TimeScale::Gpst,
        JulianDateSplit::new(jd_whole, jd_fraction).map_err(crate::errors::invalid_input)?,
    );
    Ok(tropo_slant(elevation_rad, receiver, met, epoch).map_err(crate::errors::invalid_input)?)
}
