//! Rustler boundary for the `sidereon-core` geoid undulation model.
//!
//! Pure glue over `sidereon_core::geoid`: the free functions forward the
//! built-in-grid lookups, and a loaded [`GeoidGrid`] is held as a Rustler
//! resource handle so a vendor model is parsed once and queried per call. No
//! bilinear interpolation, grid parsing, or height arithmetic lives here. Angles
//! cross the boundary in radians, the crate's native query unit; undulation and
//! heights are in metres.

use rustler::{Encoder, Env, ResourceArc, Term};
use sidereon_core::geoid::{
    egm96_ellipsoidal_height_m, egm96_orthometric_height_m, egm96_undulation, ellipsoidal_height_m,
    geoid_undulation, orthometric_height_m, GeoidGrid,
};

mod atoms {
    rustler::atoms! {
        ok,
        error
    }
}

/// Resource handle holding a parsed geoid grid across NIF calls.
///
/// The parsed [`GeoidGrid`] is read-only after construction, so the handle is
/// shared (`ResourceArc`) and queried immutably. The BEAM GC drops it when the
/// last Elixir reference is collected.
pub struct GeoidGridResource {
    pub grid: GeoidGrid,
}

#[rustler::resource_impl]
impl rustler::Resource for GeoidGridResource {}

/// Built-in coarse-grid geoid undulation `N` (metres) at a geodetic position in
/// radians.
#[rustler::nif]
fn geoid_undulation_rad(lat_rad: f64, lon_rad: f64) -> f64 {
    geoid_undulation(lat_rad, lon_rad)
}

/// Orthometric height `H = h - N` (metres) from an ellipsoidal height, using the
/// built-in grid.
#[rustler::nif]
fn geoid_orthometric_height_m(ellipsoidal_height: f64, lat_rad: f64, lon_rad: f64) -> f64 {
    orthometric_height_m(ellipsoidal_height, lat_rad, lon_rad)
}

/// Ellipsoidal height `h = H + N` (metres) from an orthometric height, using the
/// built-in grid.
#[rustler::nif]
fn geoid_ellipsoidal_height_m(orthometric_height: f64, lat_rad: f64, lon_rad: f64) -> f64 {
    ellipsoidal_height_m(orthometric_height, lat_rad, lon_rad)
}

/// Geoid undulation `N` (metres) at a geodetic position in radians, from the
/// embedded genuine EGM96 1-degree global grid (metre-class, ~0.4 m RMS).
#[rustler::nif]
fn egm96_undulation_rad(lat_rad: f64, lon_rad: f64) -> f64 {
    egm96_undulation(lat_rad, lon_rad)
}

/// Orthometric height `H = h - N` (metres) from an ellipsoidal height, using the
/// embedded genuine EGM96 1-degree model. Position in radians.
#[rustler::nif]
fn egm96_orthometric_height(ellipsoidal_height: f64, lat_rad: f64, lon_rad: f64) -> f64 {
    egm96_orthometric_height_m(ellipsoidal_height, lat_rad, lon_rad)
}

/// Ellipsoidal height `h = H + N` (metres) from an orthometric height, using the
/// embedded genuine EGM96 1-degree model. Position in radians.
#[rustler::nif]
fn egm96_ellipsoidal_height(orthometric_height: f64, lat_rad: f64, lon_rad: f64) -> f64 {
    egm96_ellipsoidal_height_m(orthometric_height, lat_rad, lon_rad)
}

/// Parse a geoid grid in the crate's documented text format into a handle.
///
/// Dirty-CPU: a full vendor grid is unbounded relative to the 1 ms NIF budget.
#[rustler::nif(schedule = "DirtyCpu")]
fn geoid_grid_from_text<'a>(env: Env<'a>, text: String) -> Term<'a> {
    match GeoidGrid::from_text(&text) {
        Ok(grid) => (atoms::ok(), ResourceArc::new(GeoidGridResource { grid })).encode(env),
        Err(error) => (atoms::error(), error.to_string()).encode(env),
    }
}

/// Build a geoid grid from its origin, spacing, dimensions, and row-major samples
/// (metres). The samples cross as a flat list of `n_lat * n_lon` floats.
#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
fn geoid_grid_new<'a>(
    env: Env<'a>,
    lat_min_deg: f64,
    lon_min_deg: f64,
    dlat_deg: f64,
    dlon_deg: f64,
    n_lat: usize,
    n_lon: usize,
    values_m: Vec<f64>,
) -> Term<'a> {
    match GeoidGrid::new(
        lat_min_deg,
        lon_min_deg,
        dlat_deg,
        dlon_deg,
        n_lat,
        n_lon,
        values_m,
    ) {
        Ok(grid) => (atoms::ok(), ResourceArc::new(GeoidGridResource { grid })).encode(env),
        Err(error) => (atoms::error(), error.to_string()).encode(env),
    }
}

/// Bilinearly interpolated undulation `N` (metres) at a geodetic position in
/// degrees, from a loaded grid handle.
#[rustler::nif]
fn geoid_grid_undulation_deg(
    handle: ResourceArc<GeoidGridResource>,
    lat_deg: f64,
    lon_deg: f64,
) -> f64 {
    handle.grid.undulation_deg(lat_deg, lon_deg)
}

/// Bilinearly interpolated undulation `N` (metres) at a geodetic position in
/// radians, from a loaded grid handle.
#[rustler::nif]
fn geoid_grid_undulation_rad(
    handle: ResourceArc<GeoidGridResource>,
    lat_rad: f64,
    lon_rad: f64,
) -> f64 {
    handle.grid.undulation_rad(lat_rad, lon_rad)
}
