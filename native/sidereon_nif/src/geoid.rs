//! Rustler boundary for the `sidereon-core` geoid undulation model.
//!
//! Pure glue over `sidereon_core::geoid`: the free functions forward the
//! built-in-grid lookups, and a loaded [`GeoidGrid`] is held as a Rustler
//! resource handle so a vendor model is parsed once and queried per call. No
//! bilinear interpolation, grid parsing, or height arithmetic lives here. Angles
//! cross the boundary in radians, the crate's native query unit; undulation and
//! heights are in metres.

use rustler::{Binary, Encoder, Env, ResourceArc, Term};
use sidereon_core::geoid::{
    egm96_ellipsoidal_height_m, egm96_orthometric_height_m, egm96_undulation,
    egm96_undulations_deg as core_egm96_undulations_deg,
    egm96_undulations_rad as core_egm96_undulations_rad, ellipsoidal_height_m, geoid_undulation,
    geoid_undulations_deg as core_geoid_undulations_deg,
    geoid_undulations_rad as core_geoid_undulations_rad, orthometric_height_m, Egm2008GridSpacing,
    Egm2008RasterWindow, GeoidGrid, ProjVgridshiftArithmetic, ProjVgridshiftError,
};

mod atoms {
    rustler::atoms! {
        ok,
        error,
        non_finite_coordinate,
        coordinate_outside_grid,
        latitude,
        longitude
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

/// Batch built-in coarse-grid geoid undulation lookup, with positions in radians.
#[rustler::nif(schedule = "DirtyCpu")]
fn geoid_undulations_rad(points_rad: Vec<(f64, f64)>) -> Vec<f64> {
    core_geoid_undulations_rad(&points_rad)
}

/// Batch built-in coarse-grid geoid undulation lookup, with positions in degrees.
#[rustler::nif(schedule = "DirtyCpu")]
fn geoid_undulations_deg(points_deg: Vec<(f64, f64)>) -> Vec<f64> {
    core_geoid_undulations_deg(&points_deg)
}

/// Geoid undulation `N` (metres) at a geodetic position in radians, from the
/// embedded genuine EGM96 1-degree global grid (metre-class, ~0.4 m RMS).
#[rustler::nif]
fn egm96_undulation_rad(lat_rad: f64, lon_rad: f64) -> f64 {
    egm96_undulation(lat_rad, lon_rad)
}

/// Batch EGM96 1-degree undulation lookup, with positions in radians.
#[rustler::nif(schedule = "DirtyCpu")]
fn egm96_undulations_rad(points_rad: Vec<(f64, f64)>) -> Vec<f64> {
    core_egm96_undulations_rad(&points_rad)
}

/// Batch EGM96 1-degree undulation lookup, with positions in degrees.
#[rustler::nif(schedule = "DirtyCpu")]
fn egm96_undulations_deg(points_deg: Vec<(f64, f64)>) -> Vec<f64> {
    core_egm96_undulations_deg(&points_deg)
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

/// Parse a full EGM96 WW15MGH.DAC byte buffer into a loaded-grid handle.
#[rustler::nif(schedule = "DirtyCpu")]
fn geoid_grid_from_egm96_dac<'a>(env: Env<'a>, bytes: Binary<'a>) -> Term<'a> {
    match GeoidGrid::from_egm96_dac(bytes.as_slice()) {
        Ok(grid) => (atoms::ok(), ResourceArc::new(GeoidGridResource { grid })).encode(env),
        Err(error) => (atoms::error(), error.to_string()).encode(env),
    }
}

/// Parse PROJ's public EGM96 15-arcminute GTX grid into a loaded-grid handle.
#[rustler::nif(schedule = "DirtyCpu")]
fn geoid_grid_from_proj_egm96_gtx<'a>(env: Env<'a>, bytes: Binary<'a>) -> Term<'a> {
    match GeoidGrid::from_proj_egm96_gtx(bytes.as_slice()) {
        Ok(grid) => (atoms::ok(), ResourceArc::new(GeoidGridResource { grid })).encode(env),
        Err(error) => (atoms::error(), error.to_string()).encode(env),
    }
}

fn proj_vgridshift_arithmetic(value: &str) -> Result<ProjVgridshiftArithmetic, String> {
    match value {
        "separate-multiply-add" => Ok(ProjVgridshiftArithmetic::SeparateMultiplyAdd),
        "fused-multiply-add" => Ok(ProjVgridshiftArithmetic::FusedMultiplyAdd),
        other => Err(format!("unsupported PROJ vertical-grid arithmetic {other}")),
    }
}

fn proj_vgridshift_error<'a>(env: Env<'a>, error: ProjVgridshiftError) -> Term<'a> {
    let (kind, field) = match error {
        ProjVgridshiftError::NonFiniteCoordinate { field } => {
            (atoms::non_finite_coordinate(), field)
        }
        ProjVgridshiftError::CoordinateOutsideGrid { field } => {
            (atoms::coordinate_outside_grid(), field)
        }
    };
    let field = match field {
        "latitude" => atoms::latitude(),
        "longitude" => atoms::longitude(),
        _ => unreachable!("core PROJ vertical-grid coordinate field is closed"),
    };
    (kind, field).encode(env)
}

fn egm2008_spacing(value: String) -> Result<Egm2008GridSpacing, String> {
    match value.trim().to_ascii_lowercase().replace('_', "-").as_str() {
        "1" | "1m" | "1-min" | "1-minute" | "one-minute" => Ok(Egm2008GridSpacing::OneMinute),
        "2.5" | "2.5m" | "2.5-min" | "2.5-minute" | "two-point-five-minute" => {
            Ok(Egm2008GridSpacing::TwoPointFiveMinute)
        }
        other => Err(format!("unsupported EGM2008 spacing {other}")),
    }
}

/// Parse a full NGA EGM2008 raster into a loaded-grid handle.
#[rustler::nif(schedule = "DirtyCpu")]
fn geoid_grid_from_egm2008_raster<'a>(
    env: Env<'a>,
    bytes: Binary<'a>,
    spacing: String,
) -> Term<'a> {
    match egm2008_spacing(spacing).and_then(|spacing| {
        GeoidGrid::from_egm2008_raster(bytes.as_slice(), spacing).map_err(|e| e.to_string())
    }) {
        Ok(grid) => (atoms::ok(), ResourceArc::new(GeoidGridResource { grid })).encode(env),
        Err(error) => (atoms::error(), error).encode(env),
    }
}

/// Parse a full or cropped NGA EGM2008 raster window into a loaded-grid handle.
#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
fn geoid_grid_from_egm2008_raster_window<'a>(
    env: Env<'a>,
    bytes: Binary<'a>,
    spacing: String,
    lat_min_deg: f64,
    lon_min_deg: f64,
    n_lat: usize,
    n_lon: usize,
) -> Term<'a> {
    let result = egm2008_spacing(spacing).and_then(|spacing| {
        Egm2008RasterWindow::new(spacing, lat_min_deg, lon_min_deg, n_lat, n_lon)
            .map_err(|e| e.to_string())
            .and_then(|window| {
                GeoidGrid::from_egm2008_raster_window(bytes.as_slice(), window)
                    .map_err(|e| e.to_string())
            })
    });
    match result {
        Ok(grid) => (atoms::ok(), ResourceArc::new(GeoidGridResource { grid })).encode(env),
        Err(error) => (atoms::error(), error).encode(env),
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

/// PROJ 9.3.0 vertical-grid interpolation for a loaded EGM96 GTX grid.
#[rustler::nif]
fn geoid_grid_undulation_proj_rad<'a>(
    env: Env<'a>,
    handle: ResourceArc<GeoidGridResource>,
    lat_rad: f64,
    lon_rad: f64,
    arithmetic: String,
) -> Term<'a> {
    match proj_vgridshift_arithmetic(&arithmetic) {
        Ok(arithmetic) => match handle
            .grid
            .undulation_proj_rad(lat_rad, lon_rad, arithmetic)
        {
            Ok(value) => (atoms::ok(), value).encode(env),
            Err(error) => (atoms::error(), proj_vgridshift_error(env, error)).encode(env),
        },
        Err(error) => (atoms::error(), error).encode(env),
    }
}

/// Batch undulation lookup from a loaded grid, with positions in degrees.
#[rustler::nif(schedule = "DirtyCpu")]
fn geoid_grid_undulations_deg(
    handle: ResourceArc<GeoidGridResource>,
    points_deg: Vec<(f64, f64)>,
) -> Vec<f64> {
    handle.grid.undulations_deg(&points_deg)
}

/// Batch undulation lookup from a loaded grid, with positions in radians.
#[rustler::nif(schedule = "DirtyCpu")]
fn geoid_grid_undulations_rad(
    handle: ResourceArc<GeoidGridResource>,
    points_rad: Vec<(f64, f64)>,
) -> Vec<f64> {
    handle.grid.undulations_rad(&points_rad)
}

/// Loaded-grid orthometric height conversion, with position in degrees.
#[rustler::nif]
fn geoid_grid_orthometric_height_deg(
    handle: ResourceArc<GeoidGridResource>,
    ellipsoidal_height_m: f64,
    lat_deg: f64,
    lon_deg: f64,
) -> f64 {
    handle
        .grid
        .orthometric_height_deg(ellipsoidal_height_m, lat_deg, lon_deg)
}

/// Loaded-grid ellipsoidal height conversion, with position in degrees.
#[rustler::nif]
fn geoid_grid_ellipsoidal_height_deg(
    handle: ResourceArc<GeoidGridResource>,
    orthometric_height_m: f64,
    lat_deg: f64,
    lon_deg: f64,
) -> f64 {
    handle
        .grid
        .ellipsoidal_height_deg(orthometric_height_m, lat_deg, lon_deg)
}

/// Loaded-grid orthometric height conversion, with position in radians.
#[rustler::nif]
fn geoid_grid_orthometric_height_rad(
    handle: ResourceArc<GeoidGridResource>,
    ellipsoidal_height_m: f64,
    lat_rad: f64,
    lon_rad: f64,
) -> f64 {
    handle
        .grid
        .orthometric_height_rad(ellipsoidal_height_m, lat_rad, lon_rad)
}

/// Loaded-grid ellipsoidal height conversion, with position in radians.
#[rustler::nif]
fn geoid_grid_ellipsoidal_height_rad(
    handle: ResourceArc<GeoidGridResource>,
    orthometric_height_m: f64,
    lat_rad: f64,
    lon_rad: f64,
) -> f64 {
    handle
        .grid
        .ellipsoidal_height_rad(orthometric_height_m, lat_rad, lon_rad)
}
