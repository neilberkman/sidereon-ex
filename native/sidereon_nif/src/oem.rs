//! Rustler boundary for the CCSDS OEM KVN and XML reader/writer.
//!
//! Pure glue over `sidereon_core::astro::oem`: decode the raw KVN/XML text or the
//! normalized field map, forward to the crate codec, and encode the unchanged
//! Sidereon result shapes. No grammar, unit handling, or number formatting lives
//! here. Date/time fields cross as raw strings; the Elixir binding owns any
//! resolution to its native `DateTime`. Failure categories cross as atoms.

use rustler::{Encoder, Env, Term};
use sidereon_core::astro::covariance::{Covariance6, Mat6};
use sidereon_core::astro::oem::{
    self as core_oem, Oem, OemCovariance, OemError, OemMetadata, OemSegment, OemState,
};

mod atoms {
    rustler::atoms! {
        ok,
        error,
        missing_field,
        invalid_field,
        malformed
    }
}

/// One Cartesian state sample exchanged with the Elixir binding. Mirrors
/// `%Sidereon.CCSDS.OEM.State{}` with position/velocity as `{x, y, z}` tuples and
/// an optional acceleration tuple.
#[derive(Debug, Clone, rustler::NifMap)]
struct OemStateFields {
    epoch: String,
    position_km: (f64, f64, f64),
    velocity_km_s: (f64, f64, f64),
    acceleration_km_s2: Option<(f64, f64, f64)>,
}

/// One covariance block exchanged with the Elixir binding. The 6x6 matrix is a
/// row-major list of six six-element rows.
#[derive(Debug, Clone, rustler::NifMap)]
struct OemCovarianceFields {
    epoch: String,
    cov_ref_frame: Option<String>,
    matrix: Vec<Vec<f64>>,
}

/// Segment metadata exchanged with the Elixir binding.
#[derive(Debug, Clone, rustler::NifMap)]
struct OemMetadataFields {
    object_name: String,
    object_id: String,
    center_name: String,
    ref_frame: String,
    time_system: String,
    start_time: String,
    stop_time: String,
    useable_start_time: Option<String>,
    useable_stop_time: Option<String>,
    interpolation: Option<String>,
    interpolation_degree: Option<i64>,
}

/// One metadata/data segment exchanged with the Elixir binding.
#[derive(Debug, Clone, rustler::NifMap)]
struct OemSegmentFields {
    metadata: OemMetadataFields,
    states: Vec<OemStateFields>,
    covariances: Vec<OemCovarianceFields>,
}

/// Normalized OEM fields exchanged with the Elixir binding, mirroring
/// `%Sidereon.CCSDS.OEM{}`.
#[derive(Debug, Clone, rustler::NifMap)]
struct OemFields {
    ccsds_oem_vers: String,
    creation_date: Option<String>,
    originator: Option<String>,
    segments: Vec<OemSegmentFields>,
    skipped_states: i64,
}

fn vec3((x, y, z): (f64, f64, f64)) -> [f64; 3] {
    [x, y, z]
}

fn tuple3(v: [f64; 3]) -> (f64, f64, f64) {
    (v[0], v[1], v[2])
}

fn matrix_rows(matrix: &Mat6) -> Vec<Vec<f64>> {
    matrix.iter().map(|row| row.to_vec()).collect()
}

/// Rebuild a 6x6 covariance from the row-major list. Missing or short rows leave
/// the remaining cells at zero; the round-trip carries trusted parsed data, so
/// the matrix is wrapped without re-validation.
fn covariance_from_rows(rows: &[Vec<f64>]) -> Covariance6 {
    let mut matrix: Mat6 = [[0.0_f64; 6]; 6];
    for (out_row, in_row) in matrix.iter_mut().zip(rows) {
        for (slot, value) in out_row.iter_mut().zip(in_row) {
            *slot = *value;
        }
    }
    Covariance6::from_matrix_unchecked(matrix)
}

impl From<OemState> for OemStateFields {
    fn from(s: OemState) -> Self {
        Self {
            epoch: s.epoch,
            position_km: tuple3(s.position_km),
            velocity_km_s: tuple3(s.velocity_km_s),
            acceleration_km_s2: s.acceleration_km_s2.map(tuple3),
        }
    }
}

impl From<OemStateFields> for OemState {
    fn from(f: OemStateFields) -> Self {
        Self {
            epoch: f.epoch,
            position_km: vec3(f.position_km),
            velocity_km_s: vec3(f.velocity_km_s),
            acceleration_km_s2: f.acceleration_km_s2.map(vec3),
        }
    }
}

impl From<OemCovariance> for OemCovarianceFields {
    fn from(c: OemCovariance) -> Self {
        Self {
            epoch: c.epoch,
            cov_ref_frame: c.cov_ref_frame,
            matrix: matrix_rows(c.matrix.as_matrix()),
        }
    }
}

impl From<OemCovarianceFields> for OemCovariance {
    fn from(f: OemCovarianceFields) -> Self {
        Self {
            epoch: f.epoch,
            cov_ref_frame: f.cov_ref_frame,
            matrix: covariance_from_rows(&f.matrix),
        }
    }
}

impl From<OemMetadata> for OemMetadataFields {
    fn from(m: OemMetadata) -> Self {
        Self {
            object_name: m.object_name,
            object_id: m.object_id,
            center_name: m.center_name,
            ref_frame: m.ref_frame,
            time_system: m.time_system,
            start_time: m.start_time,
            stop_time: m.stop_time,
            useable_start_time: m.useable_start_time,
            useable_stop_time: m.useable_stop_time,
            interpolation: m.interpolation,
            interpolation_degree: m.interpolation_degree.map(|d| d as i64),
        }
    }
}

impl From<OemMetadataFields> for OemMetadata {
    fn from(f: OemMetadataFields) -> Self {
        Self {
            object_name: f.object_name,
            object_id: f.object_id,
            center_name: f.center_name,
            ref_frame: f.ref_frame,
            time_system: f.time_system,
            start_time: f.start_time,
            stop_time: f.stop_time,
            useable_start_time: f.useable_start_time,
            useable_stop_time: f.useable_stop_time,
            interpolation: f.interpolation,
            interpolation_degree: f.interpolation_degree.map(|d| d as u32),
        }
    }
}

impl From<OemSegment> for OemSegmentFields {
    fn from(s: OemSegment) -> Self {
        Self {
            metadata: s.metadata.into(),
            states: s.states.into_iter().map(Into::into).collect(),
            covariances: s.covariances.into_iter().map(Into::into).collect(),
        }
    }
}

impl From<OemSegmentFields> for OemSegment {
    fn from(f: OemSegmentFields) -> Self {
        Self {
            metadata: f.metadata.into(),
            states: f.states.into_iter().map(Into::into).collect(),
            covariances: f.covariances.into_iter().map(Into::into).collect(),
        }
    }
}

impl From<Oem> for OemFields {
    fn from(o: Oem) -> Self {
        Self {
            ccsds_oem_vers: o.ccsds_oem_vers,
            creation_date: o.creation_date,
            originator: o.originator,
            segments: o.segments.into_iter().map(Into::into).collect(),
            skipped_states: o.skipped_states as i64,
        }
    }
}

impl From<OemFields> for Oem {
    fn from(f: OemFields) -> Self {
        Self {
            ccsds_oem_vers: f.ccsds_oem_vers,
            creation_date: f.creation_date,
            originator: f.originator,
            segments: f.segments.into_iter().map(Into::into).collect(),
            skipped_states: f.skipped_states.max(0) as usize,
        }
    }
}

/// Map a core OEM failure to its category atom, so the Elixir caller sees a
/// `{:error, atom}` reason rather than a leaked Rust string.
fn error_atom(error: &OemError) -> rustler::Atom {
    match error {
        OemError::MissingField(_) => atoms::missing_field(),
        OemError::InvalidField { .. } => atoms::invalid_field(),
        OemError::Field(_) => atoms::malformed(),
    }
}

fn parse_result<'a>(env: Env<'a>, result: Result<Oem, OemError>) -> Term<'a> {
    match result {
        Ok(parsed) => (atoms::ok(), OemFields::from(parsed)).encode(env),
        Err(e) => (atoms::error(), error_atom(&e)).encode(env),
    }
}

/// Parse a CCSDS OEM in KVN encoding.
#[rustler::nif(schedule = "DirtyCpu")]
fn oem_parse_kvn<'a>(env: Env<'a>, text: String) -> Term<'a> {
    parse_result(env, core_oem::parse_kvn(&text))
}

/// Parse a CCSDS OEM in XML encoding.
#[rustler::nif(schedule = "DirtyCpu")]
fn oem_parse_xml<'a>(env: Env<'a>, text: String) -> Term<'a> {
    parse_result(env, core_oem::parse_xml(&text))
}

/// Serialize normalized OEM fields as CCSDS OEM KVN text.
#[rustler::nif(schedule = "DirtyCpu")]
fn oem_encode_kvn(fields: OemFields) -> String {
    core_oem::encode_kvn(&fields.into())
}

/// Serialize normalized OEM fields as CCSDS OEM XML text.
#[rustler::nif(schedule = "DirtyCpu")]
fn oem_encode_xml(fields: OemFields) -> String {
    core_oem::encode_xml(&fields.into())
}
