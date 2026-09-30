//! Rustler boundary for the `sidereon-core` tropospheric delay model.
//!
//! This module is **pure glue**: it decodes Erlang terms, calls the
//! `sidereon_core::atmosphere::troposphere` public APIs, and encodes the results back. No
//! Saastamoinen zenith formula and no Niell mapping numerics live here; those
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
//! Angles arrive in degrees at the boundary; the NIF converts them to the core's
//! radians. The epoch is a split Julian date used for the Niell seasonal
//! day-of-year term.

use rustler::{Error as RustlerError, NifMap, NifResult};
use sidereon_core::astro::time::model::{Instant, JulianDateSplit, TimeModelError, TimeScale};
use sidereon_core::atmosphere::troposphere::{
    tropo_mapping, tropo_slant, tropo_zenith, MappingModel, Met, TropoModel,
};
use sidereon_core::{FrameValueError, Wgs84Geodetic};

mod atoms {
    rustler::atoms! {
        invalid_input,
        below_mapping_elevation,
        above_mapping_elevation,
        outside_mapping_height
    }
}

#[derive(NifMap)]
struct CoreErrorDetailTerm {
    family: String,
    kind: String,
    message: String,
    field: Option<String>,
    reason: Option<String>,
    debug: Option<String>,
}

fn core_error_detail(error: sidereon_core::Error) -> RustlerError {
    let debug = format!("{error:?}");
    let (kind, message) = match error {
        sidereon_core::Error::InvalidInput(message) => ("INVALID_INPUT", message),
        other => ("CORE_ERROR", other.to_string()),
    };
    RustlerError::Term(Box::new((
        atoms::invalid_input(),
        CoreErrorDetailTerm {
            family: "CoreError".to_owned(),
            kind: kind.to_owned(),
            message,
            field: None,
            reason: None,
            debug: Some(debug),
        },
    )))
}

fn frame_value_error_detail(error: FrameValueError) -> RustlerError {
    let message = error.to_string();
    match error {
        FrameValueError::InvalidInput { field, reason } => RustlerError::Term(Box::new((
            atoms::invalid_input(),
            CoreErrorDetailTerm {
                family: "FrameValueError".to_owned(),
                kind: "FRAME_VALUE_INVALID_INPUT".to_owned(),
                message,
                field: Some(field.to_owned()),
                reason: Some(reason.to_owned()),
                debug: None,
            },
        ))),
    }
}

pub(crate) fn time_model_error_detail(error: TimeModelError) -> RustlerError {
    let message = error.to_string();
    match error {
        TimeModelError::InvalidInput { field, reason } => RustlerError::Term(Box::new((
            atoms::invalid_input(),
            CoreErrorDetailTerm {
                family: "TimeModelError".to_owned(),
                kind: "TIME_MODEL_INVALID_INPUT".to_owned(),
                message,
                field: Some(field.to_owned()),
                reason: Some(reason.to_owned()),
                debug: None,
            },
        ))),
    }
}

fn mapping_error(error: sidereon_core::Error) -> rustler::Error {
    let message = error.to_string();
    let atom = if message.contains("elevation_rad below mapping validity") {
        atoms::below_mapping_elevation()
    } else if message.contains("elevation_rad above mapping validity") {
        atoms::above_mapping_elevation()
    } else if message.contains("receiver.height_m outside mapping validity") {
        atoms::outside_mapping_height()
    } else {
        atoms::invalid_input()
    };
    rustler::Error::Term(Box::new(atom))
}

/// Zenith hydrostatic and wet tropospheric delays (positive meters).
///
/// The receiver geodetic latitude and ellipsoidal height set the zenith
/// hydrostatic delay's gravity correction; pressure, temperature, and humidity
/// drive the Saastamoinen formulas. Returns `{dry_m, wet_m}`.
#[rustler::nif]
fn tropo_zenith_delay(
    lat_deg: f64,
    height_m: f64,
    pressure_hpa: f64,
    temperature_k: f64,
    relative_humidity: f64,
) -> NifResult<(f64, f64)> {
    let receiver = Wgs84Geodetic::new(lat_deg.to_radians(), 0.0, height_m)
        .map_err(crate::errors::invalid_input)?;
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
    elevation_deg: f64,
    lat_deg: f64,
    height_m: f64,
    jd_whole: f64,
    jd_fraction: f64,
) -> NifResult<(f64, f64)> {
    let receiver = Wgs84Geodetic::new(lat_deg.to_radians(), 0.0, height_m)
        .map_err(crate::errors::invalid_input)?;
    let epoch = Instant::from_julian_date(
        TimeScale::Gpst,
        JulianDateSplit::new(jd_whole, jd_fraction).map_err(crate::errors::invalid_input)?,
    );
    let m = tropo_mapping(
        MappingModel::Niell,
        elevation_deg.to_radians(),
        receiver,
        epoch,
    )
    .map_err(mapping_error)?;
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
    elevation_deg: f64,
    lat_deg: f64,
    lon_deg: f64,
    height_m: f64,
    pressure_hpa: f64,
    temperature_k: f64,
    relative_humidity: f64,
    jd_whole: f64,
    jd_fraction: f64,
) -> NifResult<f64> {
    let receiver = Wgs84Geodetic::new(lat_deg.to_radians(), lon_deg.to_radians(), height_m)
        .map_err(crate::errors::invalid_input)?;
    let met = Met::new(pressure_hpa, temperature_k, relative_humidity)
        .map_err(crate::errors::invalid_input)?;
    let epoch = Instant::from_julian_date(
        TimeScale::Gpst,
        JulianDateSplit::new(jd_whole, jd_fraction).map_err(crate::errors::invalid_input)?,
    );
    tropo_slant(elevation_deg.to_radians(), receiver, met, epoch)
        .map_err(crate::errors::invalid_input)
}

/// Detailed sibling of `tropo_zenith_delay`; legacy NIF errors remain atoms.
#[rustler::nif]
fn tropo_zenith_delay_detailed(
    lat_deg: f64,
    height_m: f64,
    pressure_hpa: f64,
    temperature_k: f64,
    relative_humidity: f64,
) -> NifResult<(f64, f64)> {
    let receiver = Wgs84Geodetic::new(lat_deg.to_radians(), 0.0, height_m)
        .map_err(frame_value_error_detail)?;
    let met =
        Met::new(pressure_hpa, temperature_k, relative_humidity).map_err(core_error_detail)?;
    let z = tropo_zenith(TropoModel::Saastamoinen, receiver, met).map_err(core_error_detail)?;
    Ok((z.dry_m, z.wet_m))
}

/// Detailed sibling of `tropo_mapping_factors` with the core refusal attached.
#[rustler::nif]
fn tropo_mapping_factors_detailed(
    elevation_deg: f64,
    lat_deg: f64,
    height_m: f64,
    jd_whole: f64,
    jd_fraction: f64,
) -> NifResult<(f64, f64)> {
    let receiver = Wgs84Geodetic::new(lat_deg.to_radians(), 0.0, height_m)
        .map_err(frame_value_error_detail)?;
    let epoch = Instant::from_julian_date(
        TimeScale::Gpst,
        JulianDateSplit::new(jd_whole, jd_fraction).map_err(time_model_error_detail)?,
    );
    let factors = tropo_mapping(
        MappingModel::Niell,
        elevation_deg.to_radians(),
        receiver,
        epoch,
    )
    .map_err(core_error_detail)?;
    Ok((factors.dry, factors.wet))
}

/// Detailed sibling of `tropo_slant_delay` with the core refusal attached.
#[rustler::nif]
#[allow(clippy::too_many_arguments)]
fn tropo_slant_delay_detailed(
    elevation_deg: f64,
    lat_deg: f64,
    lon_deg: f64,
    height_m: f64,
    pressure_hpa: f64,
    temperature_k: f64,
    relative_humidity: f64,
    jd_whole: f64,
    jd_fraction: f64,
) -> NifResult<f64> {
    let receiver = Wgs84Geodetic::new(lat_deg.to_radians(), lon_deg.to_radians(), height_m)
        .map_err(frame_value_error_detail)?;
    let met =
        Met::new(pressure_hpa, temperature_k, relative_humidity).map_err(core_error_detail)?;
    let epoch = Instant::from_julian_date(
        TimeScale::Gpst,
        JulianDateSplit::new(jd_whole, jd_fraction).map_err(time_model_error_detail)?,
    );
    tropo_slant(elevation_deg.to_radians(), receiver, met, epoch).map_err(core_error_detail)
}
