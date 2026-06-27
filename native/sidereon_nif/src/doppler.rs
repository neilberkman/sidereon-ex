//! Doppler shift computation for satellite-ground links.
//!
//! Given a satellite's GCRS position and velocity plus a ground station,
//! computes the range rate (radial velocity) and the resulting Doppler ratio.

use rustler::{NifResult, Term};

use sidereon_core::astro::constants::{models::pz90::OMEGA_E_RAD_S, units::M_PER_KM};
use sidereon_core::astro::frames::transforms::{
    gcrs_to_itrs_matrix, geodetic_to_itrs, mat3_vec3_mul,
};
use sidereon_core::astro::time::scales::TimeScales;
use sidereon_core::constants::C_M_S;

type DateTuple = (i32, i32, i32);
type TimeTuple = (i32, i32, i32, i32);

/// Decode an Elixir `{{y,m,d},{h,min,s,us}}` datetime tuple into its
/// components. Pure term decode (glue); no domain formula.
fn parse_datetime_tuple(term: Term) -> NifResult<(i32, i32, i32, i32, i32, i32, i32)> {
    let (date, time): (DateTuple, TimeTuple) = term.decode()?;
    Ok((date.0, date.1, date.2, time.0, time.1, time.2, time.3))
}

/// Speed of light in km/s.
const C_KM_S: f64 = C_M_S / M_PER_KM;

/// Earth rotation rate in rad/s, preserving the NIF's existing model value.
const OMEGA_EARTH: f64 = OMEGA_E_RAD_S;

/// Compute Doppler shift parameters for a satellite-ground link.
///
/// Returns (range_rate_km_s, doppler_ratio).
///
/// The range rate is the time derivative of the distance between the
/// satellite and the ground station. Positive means the satellite is
/// approaching (distance decreasing), negative means receding.
///
/// The doppler_ratio is -range_rate / c, so a positive ratio corresponds
/// to a frequency increase (approaching satellite).
#[allow(clippy::too_many_arguments)]
pub(crate) fn doppler_compute_impl(
    sat_x: f64,
    sat_y: f64,
    sat_z: f64,
    sat_vx: f64,
    sat_vy: f64,
    sat_vz: f64,
    station_lat_deg: f64,
    station_lon_deg: f64,
    station_alt_km: f64,
    datetime_tuple: Term,
) -> NifResult<(f64, f64)> {
    let (year, month, day, hour, minute, second, microsecond) =
        parse_datetime_tuple(datetime_tuple)?;
    let second_with_micro = second as f64 + microsecond as f64 / 1_000_000.0;
    let ts = TimeScales::from_utc(year, month, day, hour, minute, second_with_micro)
        .map_err(crate::errors::invalid_input)?;

    let (range_rate, doppler_ratio) = doppler_compute(
        sat_x,
        sat_y,
        sat_z,
        sat_vx,
        sat_vy,
        sat_vz,
        station_lat_deg,
        station_lon_deg,
        station_alt_km,
        &ts,
    )?;

    Ok((range_rate, doppler_ratio))
}

/// Core Doppler computation.
#[allow(clippy::too_many_arguments)]
fn doppler_compute(
    sat_x: f64,
    sat_y: f64,
    sat_z: f64,
    sat_vx: f64,
    sat_vy: f64,
    sat_vz: f64,
    station_lat_deg: f64,
    station_lon_deg: f64,
    station_alt_km: f64,
    ts: &TimeScales,
) -> NifResult<(f64, f64)> {
    // Get GCRS->ITRS rotation matrix
    let r_mat = gcrs_to_itrs_matrix(ts).map_err(crate::errors::invalid_input)?;

    // Rotate satellite position GCRS -> ITRS
    let pos_gcrs = [sat_x, sat_y, sat_z];
    let pos_itrs = mat3_vec3_mul(&r_mat, &pos_gcrs).map_err(crate::errors::invalid_input)?;

    // Rotate satellite velocity GCRS -> ITRS (kinematic part)
    let vel_gcrs = [sat_vx, sat_vy, sat_vz];
    let vel_itrs_rot = mat3_vec3_mul(&r_mat, &vel_gcrs).map_err(crate::errors::invalid_input)?;

    // Add the transport term: omega_cross x (R * r_gcrs)
    // omega_cross = [0, 0, omega_earth]
    // omega x r = [-omega * ry, omega * rx, 0]
    let transport_x = -OMEGA_EARTH * pos_itrs[1];
    let transport_y = OMEGA_EARTH * pos_itrs[0];
    let transport_z = 0.0;

    let vel_itrs = [
        vel_itrs_rot[0] + transport_x,
        vel_itrs_rot[1] + transport_y,
        vel_itrs_rot[2] + transport_z,
    ];

    // Ground station geodetic -> ITRS/ECEF
    let (stn_x, stn_y, stn_z) = geodetic_to_itrs(station_lat_deg, station_lon_deg, station_alt_km)
        .map_err(crate::errors::invalid_input)?;

    // Range vector: satellite - station
    let range_vec = [
        pos_itrs[0] - stn_x,
        pos_itrs[1] - stn_y,
        pos_itrs[2] - stn_z,
    ];

    // Range magnitude
    let range_mag =
        (range_vec[0] * range_vec[0] + range_vec[1] * range_vec[1] + range_vec[2] * range_vec[2])
            .sqrt();

    // Range unit vector
    let range_unit = [
        range_vec[0] / range_mag,
        range_vec[1] / range_mag,
        range_vec[2] / range_mag,
    ];

    // Range rate = dot(range_unit, sat_velocity_itrs)
    let range_rate =
        range_unit[0] * vel_itrs[0] + range_unit[1] * vel_itrs[1] + range_unit[2] * vel_itrs[2];

    // Doppler ratio: -range_rate / c
    // Positive range_rate means satellite is moving away (distance increasing),
    // so Doppler shift is negative (frequency decreases).
    // The convention: doppler_ratio = -range_rate / c
    let doppler_ratio = -range_rate / C_KM_S;

    Ok((range_rate, doppler_ratio))
}
