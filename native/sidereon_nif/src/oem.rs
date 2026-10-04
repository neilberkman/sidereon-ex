//! Rustler boundary for the CCSDS OEM KVN and XML reader/writer.
//!
//! Pure glue over `sidereon_core::astro::oem`: decode the raw KVN/XML text or the
//! normalized field map, forward to the crate codec, and encode the unchanged
//! Sidereon result shapes. No grammar, unit handling, or number formatting lives
//! here. Date/time fields cross as raw strings; the Elixir binding owns any
//! resolution to its native `DateTime`. Failure categories cross as atoms.

use crate::ndm_errors::{oem_error_term, oem_state_line_error_term, InputRefusal};
use rustler::{Encoder, Env, Term};
use sidereon_core::astro::oem::{
    self as core_oem, Oem, OemComment, OemCovariance, OemError, OemMetadata, OemSegment,
    OemSkippedState, OemState, OemStateLineError,
};

mod atoms {
    rustler::atoms! {
        ok,
        error,
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

/// One covariance block exchanged with the Elixir binding: the 21
/// lower-triangle values exactly as read.
#[derive(Debug, Clone, rustler::NifMap)]
struct OemCovarianceFields {
    epoch: String,
    cov_ref_frame: Option<String>,
    lower_triangle: Vec<f64>,
}

/// A comment among a segment's state lines or covariance matrices, with the
/// number of items of its list that precede it.
#[derive(Debug, Clone, rustler::NifMap)]
struct OemCommentFields {
    position: u64,
    text: String,
}

/// Segment metadata exchanged with the Elixir binding.
#[derive(Debug, Clone, rustler::NifMap)]
struct OemMetadataFields {
    comments: Vec<String>,
    object_name: String,
    object_id: String,
    center_name: String,
    ref_frame: String,
    ref_frame_epoch: Option<String>,
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
    data_comments: Vec<OemCommentFields>,
    states: Vec<OemStateFields>,
    covariance_comments: Vec<OemCommentFields>,
    covariances: Vec<OemCovarianceFields>,
}

/// Why a KVN ephemeris data line was skipped: `{:item_count, n}` or
/// `{:invalid_field, item, kind}`.
#[derive(Debug, Clone)]
struct SkipReason(OemStateLineError);

impl Encoder for SkipReason {
    fn encode<'a>(&self, env: Env<'a>) -> Term<'a> {
        oem_state_line_error_term(env, &self.0)
    }
}

/// A skip reason is reader output only; the encode NIFs take
/// `OemInputFields`, which carries no skipped lines, so none is ever decoded.
impl<'a> rustler::Decoder<'a> for SkipReason {
    fn decode(_term: Term<'a>) -> rustler::NifResult<Self> {
        Err(rustler::Error::BadArg)
    }
}

/// A KVN ephemeris data line the reader skipped.
#[derive(Debug, Clone, rustler::NifMap)]
struct OemSkippedStateFields {
    line: u64,
    segment: u64,
    text: String,
    reason: SkipReason,
}

impl From<OemSkippedState> for OemSkippedStateFields {
    fn from(s: OemSkippedState) -> Self {
        Self {
            line: s.line as u64,
            segment: s.segment as u64,
            text: s.text,
            reason: SkipReason(s.reason),
        }
    }
}

/// Normalized OEM fields sent to the Elixir binding, mirroring
/// `%Sidereon.CCSDS.OEM{}`.
#[derive(Debug, Clone, rustler::NifMap)]
struct OemFields {
    ccsds_oem_vers: String,
    comments: Vec<String>,
    classification: Option<String>,
    creation_date: Option<String>,
    originator: Option<String>,
    message_id: Option<String>,
    segments: Vec<OemSegmentFields>,
    skipped_states: Vec<OemSkippedStateFields>,
}

/// OEM fields received from the Elixir binding. The skipped lines a reader
/// reported are not written by either encoder, so they are not read back.
#[derive(Debug, Clone, rustler::NifMap)]
struct OemInputFields {
    ccsds_oem_vers: String,
    comments: Vec<String>,
    classification: Option<String>,
    creation_date: Option<String>,
    originator: Option<String>,
    message_id: Option<String>,
    segments: Vec<OemSegmentFields>,
}

fn vec3((x, y, z): (f64, f64, f64)) -> [f64; 3] {
    [x, y, z]
}

fn tuple3(v: [f64; 3]) -> (f64, f64, f64) {
    (v[0], v[1], v[2])
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
            lower_triangle: c.lower_triangle.to_vec(),
        }
    }
}

impl TryFrom<OemCovarianceFields> for OemCovariance {
    type Error = InputRefusal;

    /// The 21 lower-triangle values, exactly as given; any other count is
    /// refused rather than padded or cut.
    fn try_from(f: OemCovarianceFields) -> Result<Self, InputRefusal> {
        Ok(Self {
            epoch: f.epoch,
            cov_ref_frame: f.cov_ref_frame,
            lower_triangle: f.lower_triangle.try_into().map_err(|v: Vec<f64>| {
                InputRefusal::Length {
                    group: "covariance.lower_triangle",
                    expected: 21,
                    got: v.len(),
                }
            })?,
        })
    }
}

impl From<OemComment> for OemCommentFields {
    fn from(c: OemComment) -> Self {
        Self {
            position: c.position as u64,
            text: c.text,
        }
    }
}

impl TryFrom<OemCommentFields> for OemComment {
    type Error = InputRefusal;

    fn try_from(f: OemCommentFields) -> Result<Self, InputRefusal> {
        Ok(Self {
            position: usize::try_from(f.position).map_err(|_| InputRefusal::OutOfRange {
                field: "comment.position",
            })?,
            text: f.text,
        })
    }
}

impl From<OemMetadata> for OemMetadataFields {
    fn from(m: OemMetadata) -> Self {
        Self {
            comments: m.comments,
            object_name: m.object_name,
            object_id: m.object_id,
            center_name: m.center_name,
            ref_frame: m.ref_frame,
            ref_frame_epoch: m.ref_frame_epoch,
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
            comments: f.comments,
            object_name: f.object_name,
            object_id: f.object_id,
            center_name: f.center_name,
            ref_frame: f.ref_frame,
            ref_frame_epoch: f.ref_frame_epoch,
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
            data_comments: s.data_comments.into_iter().map(Into::into).collect(),
            states: s.states.into_iter().map(Into::into).collect(),
            covariance_comments: s.covariance_comments.into_iter().map(Into::into).collect(),
            covariances: s.covariances.into_iter().map(Into::into).collect(),
        }
    }
}

impl TryFrom<OemSegmentFields> for OemSegment {
    type Error = InputRefusal;

    fn try_from(f: OemSegmentFields) -> Result<Self, InputRefusal> {
        Ok(Self {
            metadata: f.metadata.into(),
            data_comments: f
                .data_comments
                .into_iter()
                .map(OemComment::try_from)
                .collect::<Result<_, _>>()?,
            states: f.states.into_iter().map(Into::into).collect(),
            covariance_comments: f
                .covariance_comments
                .into_iter()
                .map(OemComment::try_from)
                .collect::<Result<_, _>>()?,
            covariances: f
                .covariances
                .into_iter()
                .map(OemCovariance::try_from)
                .collect::<Result<_, _>>()?,
        })
    }
}

impl From<Oem> for OemFields {
    fn from(o: Oem) -> Self {
        Self {
            ccsds_oem_vers: o.ccsds_oem_vers,
            comments: o.comments,
            classification: o.classification,
            creation_date: o.creation_date,
            originator: o.originator,
            message_id: o.message_id,
            segments: o.segments.into_iter().map(Into::into).collect(),
            skipped_states: o.skipped_states.into_iter().map(Into::into).collect(),
        }
    }
}

impl TryFrom<OemInputFields> for Oem {
    type Error = InputRefusal;

    fn try_from(f: OemInputFields) -> Result<Self, InputRefusal> {
        Ok(Self {
            ccsds_oem_vers: f.ccsds_oem_vers,
            comments: f.comments,
            classification: f.classification,
            creation_date: f.creation_date,
            originator: f.originator,
            message_id: f.message_id,
            segments: f
                .segments
                .into_iter()
                .map(OemSegment::try_from)
                .collect::<Result<_, _>>()?,
            skipped_states: Vec::new(),
        })
    }
}

fn parse_result<'a>(env: Env<'a>, result: Result<Oem, OemError>) -> Term<'a> {
    match result {
        Ok(parsed) => (atoms::ok(), OemFields::from(parsed)).encode(env),
        Err(e) => (atoms::error(), oem_error_term(env, &e)).encode(env),
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

/// `{:ok, text}`; `{:error, {:invalid_length, :"covariance.lower_triangle",
/// 21, got}}` for a covariance without exactly 21 lower-triangle values,
/// `{:error, {:invalid_field, :"comment.position", :out_of_range}}` for a
/// comment position no index holds, or `{:error, reason}` with the typed term
/// for a message the writer refuses.
fn encode_result<'a>(
    env: Env<'a>,
    fields: OemInputFields,
    encode: fn(&Oem) -> Result<String, OemError>,
) -> Term<'a> {
    let oem = match Oem::try_from(fields) {
        Ok(oem) => oem,
        Err(refusal) => return (atoms::error(), refusal.term(env)).encode(env),
    };
    match encode(&oem) {
        Ok(text) => (atoms::ok(), text).encode(env),
        Err(e) => (atoms::error(), oem_error_term(env, &e)).encode(env),
    }
}

/// Serialize normalized OEM fields as CCSDS OEM KVN text.
#[rustler::nif(schedule = "DirtyCpu")]
fn oem_encode_kvn<'a>(env: Env<'a>, fields: OemInputFields) -> Term<'a> {
    encode_result(env, fields, core_oem::encode_kvn)
}

/// Serialize normalized OEM fields as CCSDS OEM XML text.
#[rustler::nif(schedule = "DirtyCpu")]
fn oem_encode_xml<'a>(env: Env<'a>, fields: OemInputFields) -> Term<'a> {
    encode_result(env, fields, core_oem::encode_xml)
}
