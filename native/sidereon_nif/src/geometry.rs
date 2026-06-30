//! Rustler boundary for GNSS geometry diagnostics.
//!
//! This module is Rustler glue over `sidereon-core::geometry`: it decodes
//! the loaded SP3 handle, receiver coordinates, epoch/window options, and
//! API-level filters; the visibility, DOP selection, sampled series, and pass
//! construction live in the crate.

use crate::sp3::Sp3Resource;
use rustler::{Encoder, Env, Term};
use sidereon_core::astro::math::linear::invert_4x4_cofactor;
use sidereon_core::geometry::{
    dop, dop_at_epoch, dop_series, passes, visibility_series, visible, DopError, DopOptions,
    DopWeighting, LineOfSight, VisibilityOptions, Wgs84Geodetic,
};
use sidereon_core::observables::j2000_seconds_from_split;
use sidereon_core::{GnssSatelliteId, GnssSystem};
use std::collections::BTreeSet;

type LosTerm = (f64, f64, f64);
type DopRowTerm = (LosTerm, f64);
type Vec4 = (f64, f64, f64, f64);
type Matrix4 = (Vec4, Vec4, Vec4, Vec4);
type Vec3 = (f64, f64, f64);
type DopScalars = (f64, f64, f64, f64, f64);
type VisibleTerm = (String, f64, f64);
type DopSeriesTerm = (u64, DopScalars, Vec<String>);
type VisibilitySeriesTerm = (u64, u64);
type PassTerm = (String, u64, u64, f64, u64);

mod atoms {
    rustler::atoms! {
        ok,
        error,
        singular,
        too_few_satellites,
        singular_geometry,
        invalid_geometry_input,
        invalid_receiver,
        invalid_epoch
    }
}

#[rustler::nif]
pub fn geometry_dop<'a>(
    env: Env<'a>,
    rows: Vec<DopRowTerm>,
    receiver_lat_rad: f64,
    receiver_lon_rad: f64,
) -> Term<'a> {
    let los: Vec<LineOfSight> = rows
        .iter()
        .map(|((x, y, z), _)| LineOfSight::new(*x, *y, *z))
        .collect();
    let weights: Vec<f64> = rows.iter().map(|(_, weight)| *weight).collect();
    let Ok(receiver) = Wgs84Geodetic::new(receiver_lat_rad, receiver_lon_rad, 0.0) else {
        return (atoms::error(), atoms::invalid_receiver()).encode(env);
    };

    match dop(&los, &weights, receiver) {
        Ok(d) => (atoms::ok(), (d.gdop, d.pdop, d.hdop, d.vdop, d.tdop)).encode(env),
        Err(DopError::TooFewSatellites) => {
            (atoms::error(), atoms::too_few_satellites()).encode(env)
        }
        Err(DopError::Singular) => (atoms::error(), atoms::singular_geometry()).encode(env),
        Err(DopError::InvalidInput { .. }) => {
            (atoms::error(), atoms::invalid_geometry_input()).encode(env)
        }
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn sp3_geometry_visible(
    handle: rustler::ResourceArc<Sp3Resource>,
    receiver_ecef_m: Vec3,
    jd_whole: f64,
    jd_fraction: f64,
    elevation_mask_deg: f64,
    systems: Vec<String>,
) -> Vec<VisibleTerm> {
    let options = VisibilityOptions {
        elevation_mask_deg,
        systems: system_filter(systems),
    };
    let Ok(t_rx_j2000_s) = j2000_seconds_from_split(jd_whole, jd_fraction) else {
        return Vec::new();
    };
    let Ok(rows) = visible(
        &handle.sp3,
        handle.sp3.satellites(),
        vec3_to_array(receiver_ecef_m),
        t_rx_j2000_s,
        &options,
    ) else {
        return Vec::new();
    };
    rows.into_iter()
        .map(|row| {
            (
                row.satellite.to_string(),
                row.elevation_deg,
                row.azimuth_deg,
            )
        })
        .collect()
}

#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
pub fn sp3_geometry_dop<'a>(
    env: Env<'a>,
    handle: rustler::ResourceArc<Sp3Resource>,
    receiver_ecef_m: Vec3,
    jd_whole: f64,
    jd_fraction: f64,
    elevation_mask_deg: f64,
    systems: Vec<String>,
    weighting: String,
    light_time: bool,
    use_explicit_satellites: bool,
    satellites: Vec<String>,
) -> Term<'a> {
    let Some(weighting) = dop_weighting(&weighting) else {
        return (atoms::error(), "invalid_weighting").encode(env);
    };
    let options = DopOptions {
        visibility: VisibilityOptions {
            elevation_mask_deg,
            systems: system_filter(systems),
        },
        weighting,
        light_time,
    };
    let explicit_satellites = parse_satellite_tokens(satellites);
    let explicit = use_explicit_satellites.then_some(explicit_satellites.as_slice());
    let Ok(t_rx_j2000_s) = j2000_seconds_from_split(jd_whole, jd_fraction) else {
        return (atoms::error(), atoms::invalid_epoch()).encode(env);
    };

    match dop_at_epoch(
        &handle.sp3,
        handle.sp3.satellites(),
        explicit,
        vec3_to_array(receiver_ecef_m),
        t_rx_j2000_s,
        &options,
    ) {
        Ok(result) => (
            atoms::ok(),
            (dop_scalars(result.dop), sat_strings(&result.satellites)),
        )
            .encode(env),
        Err(DopError::TooFewSatellites) => {
            (atoms::error(), atoms::too_few_satellites()).encode(env)
        }
        Err(DopError::Singular) => (atoms::error(), atoms::singular_geometry()).encode(env),
        Err(DopError::InvalidInput { .. }) => {
            (atoms::error(), atoms::invalid_geometry_input()).encode(env)
        }
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
pub fn sp3_geometry_dop_series(
    handle: rustler::ResourceArc<Sp3Resource>,
    receiver_ecef_m: Vec3,
    start_jd_whole: f64,
    start_jd_fraction: f64,
    end_jd_whole: f64,
    end_jd_fraction: f64,
    step_seconds: u64,
    elevation_mask_deg: f64,
    systems: Vec<String>,
    weighting: String,
    light_time: bool,
    use_explicit_satellites: bool,
    satellites: Vec<String>,
) -> Vec<DopSeriesTerm> {
    let Some(weighting) = dop_weighting(&weighting) else {
        return Vec::new();
    };
    let options = DopOptions {
        visibility: VisibilityOptions {
            elevation_mask_deg,
            systems: system_filter(systems),
        },
        weighting,
        light_time,
    };
    let explicit_satellites = parse_satellite_tokens(satellites);
    let explicit = use_explicit_satellites.then_some(explicit_satellites.as_slice());
    let (Ok(window_start), Ok(window_end)) = (
        j2000_seconds_from_split(start_jd_whole, start_jd_fraction),
        j2000_seconds_from_split(end_jd_whole, end_jd_fraction),
    ) else {
        return Vec::new();
    };
    let window = (window_start, window_end);

    let Ok(points) = dop_series(
        &handle.sp3,
        handle.sp3.satellites(),
        explicit,
        vec3_to_array(receiver_ecef_m),
        window,
        step_seconds,
        &options,
    ) else {
        return Vec::new();
    };
    points
        .into_iter()
        .map(|sample| {
            (
                sample.step_index as u64,
                dop_scalars(sample.geometry.dop),
                sat_strings(&sample.geometry.satellites),
            )
        })
        .collect()
}

#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
pub fn sp3_geometry_visibility_series(
    handle: rustler::ResourceArc<Sp3Resource>,
    receiver_ecef_m: Vec3,
    start_jd_whole: f64,
    start_jd_fraction: f64,
    end_jd_whole: f64,
    end_jd_fraction: f64,
    step_seconds: u64,
    elevation_mask_deg: f64,
    systems: Vec<String>,
) -> Vec<VisibilitySeriesTerm> {
    let options = VisibilityOptions {
        elevation_mask_deg,
        systems: system_filter(systems),
    };
    let (Ok(window_start), Ok(window_end)) = (
        j2000_seconds_from_split(start_jd_whole, start_jd_fraction),
        j2000_seconds_from_split(end_jd_whole, end_jd_fraction),
    ) else {
        return Vec::new();
    };
    let window = (window_start, window_end);

    let Ok(points) = visibility_series(
        &handle.sp3,
        handle.sp3.satellites(),
        vec3_to_array(receiver_ecef_m),
        window,
        step_seconds,
        &options,
    ) else {
        return Vec::new();
    };
    points
        .into_iter()
        .map(|sample| (sample.step_index as u64, sample.n_visible as u64))
        .collect()
}

#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
pub fn sp3_geometry_passes(
    handle: rustler::ResourceArc<Sp3Resource>,
    receiver_ecef_m: Vec3,
    start_jd_whole: f64,
    start_jd_fraction: f64,
    end_jd_whole: f64,
    end_jd_fraction: f64,
    step_seconds: u64,
    elevation_mask_deg: f64,
    systems: Vec<String>,
) -> Vec<PassTerm> {
    let options = VisibilityOptions {
        elevation_mask_deg,
        systems: system_filter(systems),
    };
    let (Ok(window_start), Ok(window_end)) = (
        j2000_seconds_from_split(start_jd_whole, start_jd_fraction),
        j2000_seconds_from_split(end_jd_whole, end_jd_fraction),
    ) else {
        return Vec::new();
    };
    let window = (window_start, window_end);

    let Ok(found) = passes(
        &handle.sp3,
        handle.sp3.satellites(),
        vec3_to_array(receiver_ecef_m),
        window,
        step_seconds,
        &options,
    ) else {
        return Vec::new();
    };
    found
        .into_iter()
        .map(|pass| {
            (
                pass.satellite.to_string(),
                pass.rise_step_index as u64,
                pass.set_step_index as u64,
                pass.peak_elevation_deg,
                pass.peak_step_index as u64,
            )
        })
        .collect()
}

#[rustler::nif]
pub fn geometry_inv4<'a>(env: Env<'a>, matrix: Matrix4) -> Term<'a> {
    let matrix = matrix4_to_array(matrix);
    match invert_4x4_cofactor(&matrix) {
        Some(inv) => (atoms::ok(), array_to_matrix4(inv)).encode(env),
        None => atoms::singular().encode(env),
    }
}

fn matrix4_to_array(matrix: Matrix4) -> [[f64; 4]; 4] {
    [
        vec4_to_array(matrix.0),
        vec4_to_array(matrix.1),
        vec4_to_array(matrix.2),
        vec4_to_array(matrix.3),
    ]
}

fn vec4_to_array(vec: Vec4) -> [f64; 4] {
    [vec.0, vec.1, vec.2, vec.3]
}

fn array_to_matrix4(matrix: [[f64; 4]; 4]) -> Matrix4 {
    (
        array_to_vec4(matrix[0]),
        array_to_vec4(matrix[1]),
        array_to_vec4(matrix[2]),
        array_to_vec4(matrix[3]),
    )
}

fn array_to_vec4(vec: [f64; 4]) -> Vec4 {
    (vec[0], vec[1], vec[2], vec[3])
}

fn vec3_to_array(vec: Vec3) -> [f64; 3] {
    [vec.0, vec.1, vec.2]
}

fn system_filter(systems: Vec<String>) -> Option<BTreeSet<GnssSystem>> {
    if systems.is_empty() {
        None
    } else {
        Some(
            systems
                .iter()
                .filter_map(|system| strict_system_letter(system))
                .collect(),
        )
    }
}

fn strict_system_letter(system: &str) -> Option<GnssSystem> {
    let mut chars = system.chars();
    let letter = chars.next()?;
    if chars.next().is_some() {
        return None;
    }
    GnssSystem::from_letter(letter)
}

fn parse_satellite_tokens(tokens: Vec<String>) -> Vec<GnssSatelliteId> {
    tokens
        .iter()
        .filter_map(|token| parse_satellite_token(token))
        .collect()
}

fn parse_satellite_token(token: &str) -> Option<GnssSatelliteId> {
    let mut chars = token.chars();
    let letter = chars.next()?;
    let system = GnssSystem::from_letter(letter)?;
    let prn: u16 = chars.as_str().parse().ok()?;
    let prn = u8::try_from(prn).ok()?;
    GnssSatelliteId::new(system, prn).ok()
}

fn dop_weighting(weighting: &str) -> Option<DopWeighting> {
    match weighting {
        "unit" => Some(DopWeighting::Unit),
        "elevation" => Some(DopWeighting::Elevation),
        _ => None,
    }
}

fn dop_scalars(dop: sidereon_core::geometry::Dop) -> DopScalars {
    (dop.gdop, dop.pdop, dop.hdop, dop.vdop, dop.tdop)
}

fn sat_strings(satellites: &[GnssSatelliteId]) -> Vec<String> {
    satellites.iter().map(ToString::to_string).collect()
}
