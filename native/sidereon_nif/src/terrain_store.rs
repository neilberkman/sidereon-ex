//! Rustler boundary for the memory-mappable terrain store.
//!
//! The core owns DTED conversion, store parsing, datum conversion, and lookup
//! numerics. This module keeps parsed stores and optional 15-minute EGM96 grids
//! behind read-only resource handles. Terrain coordinates cross the boundary as
//! `(longitude_deg, latitude_deg)` pairs, matching the core terrain API.

use std::sync::{RwLock, RwLockReadGuard, RwLockWriteGuard};

use rustler::{Binary, Encoder, Env, Error, NifResult, OwnedBinary, ResourceArc, Term};
use sidereon_core::terrain::{DtedInterpolation, DtedLookupOptions};
use sidereon_core::terrain_store::{
    dted_tree_to_mmap_store, terrain_store_checksum64, write_dted_tree_to_mmap_store,
    Egm96FifteenMinuteGeoid, EllipsoidalHeightM, MmapTerrain, OrthometricHeightM,
    TerrainDatumError, TerrainGeoidModel, TerrainStoreError, TerrainStoreTileIndex, VerticalDatum,
};
use sidereon_core::DigestProvenance;

mod atoms {
    rustler::atoms! {
        ok,
        error,
        invalid_input,
        egm96_msl_orthometric,
        io,
        parse,
        unsupported_version,
        unsupported_datum,
        duplicate_tile,
        tile_id_mismatch,
        checksum,
        attested_checksum_mismatch,
        verified,
        attested,
        terrain,
        geoid,
        missing_egm96_dac
    }
}

/// Parsed memory-mappable terrain store held across calls.
pub struct MmapTerrainResource {
    terrain: RwLock<MmapTerrain<'static>>,
}

impl MmapTerrainResource {
    fn new(terrain: MmapTerrain<'static>) -> Self {
        Self {
            terrain: RwLock::new(terrain),
        }
    }

    fn read(&self) -> RwLockReadGuard<'_, MmapTerrain<'static>> {
        self.terrain.read().expect("terrain resource lock poisoned")
    }

    fn write(&self) -> RwLockWriteGuard<'_, MmapTerrain<'static>> {
        self.terrain
            .write()
            .expect("terrain resource lock poisoned")
    }
}

/// Loaded EGM96 15-minute geoid grid for explicit datum conversion.
pub struct Egm96FifteenMinuteGeoidResource {
    geoid: Egm96FifteenMinuteGeoid,
}

#[rustler::resource_impl]
impl rustler::Resource for MmapTerrainResource {}

#[rustler::resource_impl]
impl rustler::Resource for Egm96FifteenMinuteGeoidResource {}

#[derive(Debug, Clone, rustler::NifMap)]
struct TerrainStoreTileIndexTerm {
    lat_index: i32,
    lon_index: i32,
    min_longitude_deg: f64,
    min_latitude_deg: f64,
    max_longitude_deg: f64,
    max_latitude_deg: f64,
    lon_count: u32,
    lat_count: u32,
    data_offset: u64,
    data_len: u64,
    checksum64: u64,
    vertical_datum: String,
}

fn bytes_to_binary<'a>(env: Env<'a>, bytes: &[u8]) -> Term<'a> {
    let mut binary = OwnedBinary::new(bytes.len()).expect("allocate terrain store binary");
    binary.as_mut_slice().copy_from_slice(bytes);
    binary.release(env).encode(env)
}

fn interpolation_from_str(interpolation: &str) -> NifResult<DtedInterpolation> {
    match interpolation {
        "nearest_posting" => Ok(DtedInterpolation::NearestPosting),
        "bilinear" => Ok(DtedInterpolation::Bilinear),
        _ => Err(Error::Term(Box::new("unknown terrain interpolation"))),
    }
}

fn lookup_options(interpolation: String) -> NifResult<DtedLookupOptions> {
    Ok(DtedLookupOptions {
        interpolation: interpolation_from_str(&interpolation)?,
    })
}

fn vertical_datum_name(datum: VerticalDatum) -> &'static str {
    match datum {
        VerticalDatum::Egm96MslOrthometric => "egm96_msl_orthometric",
    }
}

fn vertical_datum_atom(datum: VerticalDatum) -> rustler::Atom {
    match datum {
        VerticalDatum::Egm96MslOrthometric => atoms::egm96_msl_orthometric(),
    }
}

fn tile_index_term(index: TerrainStoreTileIndex) -> TerrainStoreTileIndexTerm {
    TerrainStoreTileIndexTerm {
        lat_index: index.lat_index,
        lon_index: index.lon_index,
        min_longitude_deg: index.min_longitude_deg,
        min_latitude_deg: index.min_latitude_deg,
        max_longitude_deg: index.max_longitude_deg,
        max_latitude_deg: index.max_latitude_deg,
        lon_count: index.lon_count,
        lat_count: index.lat_count,
        data_offset: index.data_offset,
        data_len: index.data_len,
        checksum64: index.checksum64,
        vertical_datum: vertical_datum_name(index.vertical_datum).to_string(),
    }
}

fn mmap_from_bytes_term<'a>(env: Env<'a>, bytes: &[u8]) -> Term<'a> {
    match MmapTerrain::from_vec(bytes.to_vec()) {
        Ok(terrain) => (
            atoms::ok(),
            ResourceArc::new(MmapTerrainResource::new(terrain)),
        )
            .encode(env),
        Err(error) => (atoms::error(), store_error_term(env, error)).encode(env),
    }
}

fn store_error_term<'a>(env: Env<'a>, error: TerrainStoreError) -> Term<'a> {
    match error {
        TerrainStoreError::Io { path, message } => {
            (atoms::io(), path.display().to_string(), message).encode(env)
        }
        TerrainStoreError::Parse { reason } => (atoms::parse(), reason).encode(env),
        TerrainStoreError::UnsupportedVersion { version } => {
            (atoms::unsupported_version(), version).encode(env)
        }
        TerrainStoreError::UnsupportedDatum { tag } => {
            (atoms::unsupported_datum(), tag).encode(env)
        }
        TerrainStoreError::TileIdMismatch {
            ref path,
            ref expected,
            ref found,
        } => (
            atoms::tile_id_mismatch(),
            path.display().to_string(),
            format!("expected tile {expected:?}, parsed {found:?}"),
        )
            .encode(env),
        TerrainStoreError::DuplicateTile {
            lat_index,
            lon_index,
        } => (atoms::duplicate_tile(), lat_index, lon_index).encode(env),
        TerrainStoreError::Checksum {
            lat_index,
            lon_index,
            expected,
            found,
        } => (atoms::checksum(), lat_index, lon_index, expected, found).encode(env),
        TerrainStoreError::AttestedChecksumMismatch { expected, found } => {
            (atoms::attested_checksum_mismatch(), expected, found).encode(env)
        }
    }
}

fn digest_provenance_atom(provenance: DigestProvenance) -> rustler::Atom {
    match provenance {
        DigestProvenance::Verified => atoms::verified(),
        DigestProvenance::Attested => atoms::attested(),
    }
}

fn datum_error_term<'a>(env: Env<'a>, error: TerrainDatumError) -> Term<'a> {
    match error {
        TerrainDatumError::Terrain(error) => (atoms::terrain(), error.to_string()).encode(env),
        TerrainDatumError::Geoid(error) => (atoms::geoid(), error.to_string()).encode(env),
        TerrainDatumError::Io { path, message } => {
            (atoms::io(), path.display().to_string(), message).encode(env)
        }
        TerrainDatumError::MissingEgm96Dac { path, remediation } => (
            atoms::missing_egm96_dac(),
            path.display().to_string(),
            remediation,
        )
            .encode(env),
    }
}

fn terrain_result_term<'a>(env: Env<'a>, result: sidereon_core::Result<f64>) -> Term<'a> {
    match result {
        Ok(height) => (atoms::ok(), height).encode(env),
        Err(error) => (atoms::error(), error.to_string()).encode(env),
    }
}

fn orthometric_result_term<'a>(
    env: Env<'a>,
    result: sidereon_core::Result<OrthometricHeightM>,
) -> Term<'a> {
    match result {
        Ok(height) => (atoms::ok(), height.metres()).encode(env),
        Err(error) => (atoms::error(), error.to_string()).encode(env),
    }
}

fn ellipsoidal_result_term<'a>(
    env: Env<'a>,
    result: Result<EllipsoidalHeightM, TerrainDatumError>,
) -> Term<'a> {
    match result {
        Ok(height) => (atoms::ok(), height.metres()).encode(env),
        Err(error) => (atoms::error(), datum_error_term(env, error)).encode(env),
    }
}

fn ellipsoidal_with_model<'a>(
    env: Env<'a>,
    handle: ResourceArc<MmapTerrainResource>,
    longitude_deg: f64,
    latitude_deg: f64,
    options: DtedLookupOptions,
    model: String,
    geoid: Option<ResourceArc<Egm96FifteenMinuteGeoidResource>>,
) -> Term<'a> {
    let result = match model.as_str() {
        "egm96_one_degree" => handle.read().ellipsoidal_height_m_with_model(
            longitude_deg,
            latitude_deg,
            options,
            TerrainGeoidModel::Egm96OneDegree,
        ),
        "egm96_fifteen_minute" => match geoid {
            Some(geoid) => handle.read().ellipsoidal_height_m_with_model(
                longitude_deg,
                latitude_deg,
                options,
                TerrainGeoidModel::Egm96FifteenMinute(&geoid.geoid),
            ),
            None => {
                return (atoms::error(), atoms::invalid_input()).encode(env);
            }
        },
        _ => {
            return (atoms::error(), atoms::invalid_input()).encode(env);
        }
    };
    ellipsoidal_result_term(env, result)
}

fn orthometric_to_ellipsoidal_with_model<'a>(
    env: Env<'a>,
    height: OrthometricHeightM,
    latitude: f64,
    longitude: f64,
    model: String,
    geoid: Option<ResourceArc<Egm96FifteenMinuteGeoidResource>>,
    radians: bool,
) -> Term<'a> {
    let result = match model.as_str() {
        "egm96_one_degree" if radians => {
            height.to_ellipsoidal_height_rad(latitude, longitude, TerrainGeoidModel::Egm96OneDegree)
        }
        "egm96_one_degree" => {
            height.to_ellipsoidal_height_deg(latitude, longitude, TerrainGeoidModel::Egm96OneDegree)
        }
        "egm96_fifteen_minute" => match geoid {
            Some(geoid) if radians => height.to_ellipsoidal_height_rad(
                latitude,
                longitude,
                TerrainGeoidModel::Egm96FifteenMinute(&geoid.geoid),
            ),
            Some(geoid) => height.to_ellipsoidal_height_deg(
                latitude,
                longitude,
                TerrainGeoidModel::Egm96FifteenMinute(&geoid.geoid),
            ),
            None => {
                return (atoms::error(), atoms::invalid_input()).encode(env);
            }
        },
        _ => {
            return (atoms::error(), atoms::invalid_input()).encode(env);
        }
    };
    ellipsoidal_result_term(env, result)
}

/// Convert a DTED tile tree into canonical terrain store bytes.
#[rustler::nif(schedule = "DirtyCpu")]
fn terrain_store_dted_tree_to_mmap_store<'a>(env: Env<'a>, root: String) -> Term<'a> {
    match dted_tree_to_mmap_store(root) {
        Ok(bytes) => (atoms::ok(), bytes_to_binary(env, &bytes)).encode(env),
        Err(error) => (atoms::error(), store_error_term(env, error)).encode(env),
    }
}

/// Convert a DTED tile tree and write canonical terrain store bytes to disk.
#[rustler::nif(schedule = "DirtyCpu")]
fn terrain_store_write_dted_tree_to_mmap_store<'a>(
    env: Env<'a>,
    root: String,
    out_path: String,
) -> Term<'a> {
    match write_dted_tree_to_mmap_store(root, out_path) {
        Ok(()) => atoms::ok().encode(env),
        Err(error) => (atoms::error(), store_error_term(env, error)).encode(env),
    }
}

/// Return the store-byte FNV-1a checksum.
#[rustler::nif(schedule = "DirtyCpu")]
fn terrain_store_checksum64_bytes(bytes: Binary<'_>) -> u64 {
    terrain_store_checksum64(bytes.as_slice())
}

/// Parse an in-memory terrain store byte span into a read-only handle.
#[rustler::nif(schedule = "DirtyCpu")]
fn terrain_store_mmap_from_bytes<'a>(env: Env<'a>, bytes: Binary<'a>) -> Term<'a> {
    mmap_from_bytes_term(env, bytes.as_slice())
}

/// Parse an owned terrain store byte vector into a read-only handle.
#[rustler::nif(schedule = "DirtyCpu")]
fn terrain_store_mmap_from_vec<'a>(env: Env<'a>, bytes: Binary<'a>) -> Term<'a> {
    mmap_from_bytes_term(env, bytes.as_slice())
}

/// Read and parse a terrain store file into a read-only handle.
#[rustler::nif(schedule = "DirtyCpu")]
fn terrain_store_mmap_from_path<'a>(env: Env<'a>, path: String) -> Term<'a> {
    match MmapTerrain::from_path(path) {
        Ok(terrain) => (
            atoms::ok(),
            ResourceArc::new(MmapTerrainResource::new(terrain)),
        )
            .encode(env),
        Err(error) => (atoms::error(), store_error_term(env, error)).encode(env),
    }
}

/// Open a terrain store using a caller-attested full-store checksum.
#[rustler::nif(schedule = "DirtyCpu")]
fn terrain_store_mmap_from_path_attested<'a>(
    env: Env<'a>,
    path: String,
    claimed_checksum64: u64,
) -> Term<'a> {
    match MmapTerrain::from_path_attested(path, claimed_checksum64) {
        Ok(terrain) => (
            atoms::ok(),
            ResourceArc::new(MmapTerrainResource::new(terrain)),
        )
            .encode(env),
        Err(error) => (atoms::error(), store_error_term(env, error)).encode(env),
    }
}

/// Return bilinear orthometric terrain height as metres.
#[rustler::nif]
fn terrain_store_height_m<'a>(
    env: Env<'a>,
    handle: ResourceArc<MmapTerrainResource>,
    longitude_deg: f64,
    latitude_deg: f64,
) -> Term<'a> {
    terrain_result_term(
        env,
        handle
            .read()
            .orthometric_height_m_with_options(
                longitude_deg,
                latitude_deg,
                DtedLookupOptions {
                    interpolation: DtedInterpolation::Bilinear,
                },
            )
            .map(OrthometricHeightM::metres),
    )
}

/// Return orthometric terrain height as metres with explicit lookup options.
#[rustler::nif]
fn terrain_store_height_m_with_options<'a>(
    env: Env<'a>,
    handle: ResourceArc<MmapTerrainResource>,
    longitude_deg: f64,
    latitude_deg: f64,
    interpolation: String,
) -> Term<'a> {
    match lookup_options(interpolation) {
        Ok(options) => terrain_result_term(
            env,
            handle
                .read()
                .orthometric_height_m_with_options(longitude_deg, latitude_deg, options)
                .map(OrthometricHeightM::metres),
        ),
        Err(_) => (atoms::error(), atoms::invalid_input()).encode(env),
    }
}

/// Return bilinear typed orthometric terrain height as metres.
#[rustler::nif]
fn terrain_store_orthometric_height_m<'a>(
    env: Env<'a>,
    handle: ResourceArc<MmapTerrainResource>,
    longitude_deg: f64,
    latitude_deg: f64,
) -> Term<'a> {
    orthometric_result_term(
        env,
        handle.read().orthometric_height_m_with_options(
            longitude_deg,
            latitude_deg,
            DtedLookupOptions {
                interpolation: DtedInterpolation::Bilinear,
            },
        ),
    )
}

/// Return typed orthometric terrain height as metres with explicit options.
#[rustler::nif]
fn terrain_store_orthometric_height_m_with_options<'a>(
    env: Env<'a>,
    handle: ResourceArc<MmapTerrainResource>,
    longitude_deg: f64,
    latitude_deg: f64,
    interpolation: String,
) -> Term<'a> {
    match lookup_options(interpolation) {
        Ok(options) => orthometric_result_term(
            env,
            handle
                .read()
                .orthometric_height_m_with_options(longitude_deg, latitude_deg, options),
        ),
        Err(_) => (atoms::error(), atoms::invalid_input()).encode(env),
    }
}

/// Return per-point orthometric heights as metres.
#[rustler::nif(schedule = "DirtyCpu")]
fn terrain_store_height_batch<'a>(
    env: Env<'a>,
    handle: ResourceArc<MmapTerrainResource>,
    points: Vec<(f64, f64)>,
    interpolation: String,
) -> Vec<Term<'a>> {
    match lookup_options(interpolation) {
        Ok(options) => handle
            .read()
            .orthometric_height_batch(&points, options)
            .into_iter()
            .map(|result| terrain_result_term(env, result.map(OrthometricHeightM::metres)))
            .collect(),
        Err(_) => points
            .iter()
            .map(|_| (atoms::error(), atoms::invalid_input()).encode(env))
            .collect(),
    }
}

/// Return per-point typed orthometric heights as metres.
#[rustler::nif(schedule = "DirtyCpu")]
fn terrain_store_orthometric_height_batch<'a>(
    env: Env<'a>,
    handle: ResourceArc<MmapTerrainResource>,
    points: Vec<(f64, f64)>,
    interpolation: String,
) -> Vec<Term<'a>> {
    match lookup_options(interpolation) {
        Ok(options) => handle
            .read()
            .orthometric_height_batch(&points, options)
            .into_iter()
            .map(|result| orthometric_result_term(env, result))
            .collect(),
        Err(_) => points
            .iter()
            .map(|_| (atoms::error(), atoms::invalid_input()).encode(env))
            .collect(),
    }
}

/// Return ellipsoidal terrain height using the embedded EGM96 1-degree grid.
#[rustler::nif]
fn terrain_store_ellipsoidal_height_m<'a>(
    env: Env<'a>,
    handle: ResourceArc<MmapTerrainResource>,
    longitude_deg: f64,
    latitude_deg: f64,
) -> Term<'a> {
    ellipsoidal_result_term(
        env,
        handle.read().ellipsoidal_height_m_with_options(
            longitude_deg,
            latitude_deg,
            DtedLookupOptions {
                interpolation: DtedInterpolation::Bilinear,
            },
        ),
    )
}

/// Return ellipsoidal terrain height with explicit lookup options.
#[rustler::nif]
fn terrain_store_ellipsoidal_height_m_with_options<'a>(
    env: Env<'a>,
    handle: ResourceArc<MmapTerrainResource>,
    longitude_deg: f64,
    latitude_deg: f64,
    interpolation: String,
) -> Term<'a> {
    match lookup_options(interpolation) {
        Ok(options) => ellipsoidal_result_term(
            env,
            handle
                .read()
                .ellipsoidal_height_m_with_options(longitude_deg, latitude_deg, options),
        ),
        Err(_) => (atoms::error(), atoms::invalid_input()).encode(env),
    }
}

/// Return ellipsoidal terrain height with an explicit geoid tier.
#[rustler::nif]
fn terrain_store_ellipsoidal_height_m_with_model<'a>(
    env: Env<'a>,
    handle: ResourceArc<MmapTerrainResource>,
    longitude_deg: f64,
    latitude_deg: f64,
    interpolation: String,
    model: String,
    geoid: Option<ResourceArc<Egm96FifteenMinuteGeoidResource>>,
) -> Term<'a> {
    match lookup_options(interpolation) {
        Ok(options) => ellipsoidal_with_model(
            env,
            handle,
            longitude_deg,
            latitude_deg,
            options,
            model,
            geoid,
        ),
        Err(_) => (atoms::error(), atoms::invalid_input()).encode(env),
    }
}

/// Borrow the parsed tile index records.
#[rustler::nif]
fn terrain_store_tile_index(
    handle: ResourceArc<MmapTerrainResource>,
) -> Vec<TerrainStoreTileIndexTerm> {
    handle
        .read()
        .tile_index()
        .iter()
        .copied()
        .map(tile_index_term)
        .collect()
}

/// Return the store's file-level vertical datum.
#[rustler::nif]
fn terrain_store_vertical_datum(handle: ResourceArc<MmapTerrainResource>) -> rustler::Atom {
    vertical_datum_atom(handle.read().vertical_datum())
}

/// Return who computed the checksum carried by this terrain handle.
#[rustler::nif]
fn terrain_store_digest_provenance(handle: ResourceArc<MmapTerrainResource>) -> rustler::Atom {
    digest_provenance_atom(handle.read().digest_provenance())
}

/// Return the parsed store byte checksum.
#[rustler::nif(schedule = "DirtyCpu")]
fn terrain_store_mmap_checksum64(handle: ResourceArc<MmapTerrainResource>) -> u64 {
    handle.read().checksum64()
}

/// Verify tile payloads and any caller-attested full-store checksum.
#[rustler::nif(schedule = "DirtyCpu")]
fn terrain_store_mmap_verify<'a>(
    env: Env<'a>,
    handle: ResourceArc<MmapTerrainResource>,
) -> Term<'a> {
    match handle.write().verify() {
        Ok(()) => atoms::ok().encode(env),
        Err(error) => (atoms::error(), store_error_term(env, error)).encode(env),
    }
}

/// Re-serialize the parsed terrain store into canonical bytes.
#[rustler::nif(schedule = "DirtyCpu")]
fn terrain_store_to_bytes<'a>(env: Env<'a>, handle: ResourceArc<MmapTerrainResource>) -> Term<'a> {
    bytes_to_binary(env, &handle.read().to_bytes())
}

/// Load an EGM96 15-minute geoid grid from bytes.
#[rustler::nif(schedule = "DirtyCpu")]
fn terrain_store_egm96_fifteen_minute_geoid_from_bytes<'a>(
    env: Env<'a>,
    bytes: Binary<'a>,
) -> Term<'a> {
    match Egm96FifteenMinuteGeoid::from_ww15mgh_dac_bytes(bytes.as_slice()) {
        Ok(geoid) => (
            atoms::ok(),
            ResourceArc::new(Egm96FifteenMinuteGeoidResource { geoid }),
        )
            .encode(env),
        Err(error) => (atoms::error(), datum_error_term(env, error)).encode(env),
    }
}

/// Load an EGM96 15-minute geoid grid from a WW15MGH.DAC path.
#[rustler::nif(schedule = "DirtyCpu")]
fn terrain_store_egm96_fifteen_minute_geoid_from_path<'a>(env: Env<'a>, path: String) -> Term<'a> {
    match Egm96FifteenMinuteGeoid::from_ww15mgh_dac_path(path) {
        Ok(geoid) => (
            atoms::ok(),
            ResourceArc::new(Egm96FifteenMinuteGeoidResource { geoid }),
        )
            .encode(env),
        Err(error) => (atoms::error(), datum_error_term(env, error)).encode(env),
    }
}

/// Convert orthometric height to ellipsoidal height with degree coordinates.
#[rustler::nif]
fn terrain_store_orthometric_to_ellipsoidal_height_deg<'a>(
    env: Env<'a>,
    orthometric_height_m: f64,
    latitude_deg: f64,
    longitude_deg: f64,
    model: String,
    geoid: Option<ResourceArc<Egm96FifteenMinuteGeoidResource>>,
) -> Term<'a> {
    orthometric_to_ellipsoidal_with_model(
        env,
        OrthometricHeightM::new(orthometric_height_m),
        latitude_deg,
        longitude_deg,
        model,
        geoid,
        false,
    )
}

/// Convert orthometric height to ellipsoidal height with radian coordinates.
#[rustler::nif]
fn terrain_store_orthometric_to_ellipsoidal_height_rad<'a>(
    env: Env<'a>,
    orthometric_height_m: f64,
    latitude_rad: f64,
    longitude_rad: f64,
    model: String,
    geoid: Option<ResourceArc<Egm96FifteenMinuteGeoidResource>>,
) -> Term<'a> {
    orthometric_to_ellipsoidal_with_model(
        env,
        OrthometricHeightM::new(orthometric_height_m),
        latitude_rad,
        longitude_rad,
        model,
        geoid,
        true,
    )
}
