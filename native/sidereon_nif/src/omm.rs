//! Rustler boundary for CCSDS OMM KVN, XML, and JSON reader/writer.
//!
//! Pure glue over `sidereon_core::astro::omm`: decode raw text or normalized
//! fields, forward to the crate codecs, and encode the same field shape back to
//! Elixir. No OMM grammar, XML traversal, JSON handling, or number formatting
//! lives here.

use rustler::{Encoder, Env, Term};
use sidereon_core::astro::omm::{self as core_omm, Omm, OmmEpoch};

mod atoms {
    rustler::atoms! {
        ok,
        error
    }
}

#[derive(Debug, Clone, rustler::NifMap)]
struct OmmEpochFields {
    year: i32,
    month: i64,
    day: i64,
    hour: i64,
    minute: i64,
    second: i64,
    microsecond: i64,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct OmmFields {
    ccsds_omm_vers: String,
    creation_date: Option<String>,
    originator: Option<String>,
    object_name: Option<String>,
    object_id: Option<String>,
    center_name: Option<String>,
    ref_frame: Option<String>,
    time_system: Option<String>,
    mean_element_theory: Option<String>,
    epoch: OmmEpochFields,
    mean_motion: f64,
    eccentricity: f64,
    inclination_deg: f64,
    ra_of_asc_node_deg: f64,
    arg_of_pericenter_deg: f64,
    mean_anomaly_deg: f64,
    ephemeris_type: i64,
    classification_type: String,
    norad_cat_id: i64,
    element_set_no: i64,
    rev_at_epoch: i64,
    bstar: f64,
    mean_motion_dot: f64,
    mean_motion_ddot: f64,
}

impl From<OmmEpoch> for OmmEpochFields {
    fn from(epoch: OmmEpoch) -> Self {
        Self {
            year: epoch.year,
            month: epoch.month as i64,
            day: epoch.day as i64,
            hour: epoch.hour as i64,
            minute: epoch.minute as i64,
            second: epoch.second as i64,
            microsecond: epoch.microsecond as i64,
        }
    }
}

impl From<Omm> for OmmFields {
    fn from(omm: Omm) -> Self {
        Self {
            ccsds_omm_vers: omm.ccsds_omm_vers,
            creation_date: omm.creation_date,
            originator: omm.originator,
            object_name: omm.object_name,
            object_id: omm.object_id,
            center_name: omm.center_name,
            ref_frame: omm.ref_frame,
            time_system: omm.time_system,
            mean_element_theory: omm.mean_element_theory,
            epoch: omm.epoch.into(),
            mean_motion: omm.mean_motion,
            eccentricity: omm.eccentricity,
            inclination_deg: omm.inclination_deg,
            ra_of_asc_node_deg: omm.ra_of_asc_node_deg,
            arg_of_pericenter_deg: omm.arg_of_pericenter_deg,
            mean_anomaly_deg: omm.mean_anomaly_deg,
            ephemeris_type: omm.ephemeris_type as i64,
            classification_type: omm.classification_type,
            norad_cat_id: omm.norad_cat_id as i64,
            element_set_no: omm.element_set_no as i64,
            rev_at_epoch: omm.rev_at_epoch,
            bstar: omm.bstar,
            mean_motion_dot: omm.mean_motion_dot,
            mean_motion_ddot: omm.mean_motion_ddot,
        }
    }
}

impl TryFrom<OmmEpochFields> for OmmEpoch {
    type Error = String;

    fn try_from(epoch: OmmEpochFields) -> Result<Self, Self::Error> {
        Ok(Self {
            year: epoch.year,
            month: u32_field(epoch.month, "epoch.month")?,
            day: u32_field(epoch.day, "epoch.day")?,
            hour: u32_field(epoch.hour, "epoch.hour")?,
            minute: u32_field(epoch.minute, "epoch.minute")?,
            second: u32_field(epoch.second, "epoch.second")?,
            microsecond: u32_field(epoch.microsecond, "epoch.microsecond")?,
        })
    }
}

impl TryFrom<OmmFields> for Omm {
    type Error = String;

    fn try_from(fields: OmmFields) -> Result<Self, Self::Error> {
        Ok(Self {
            ccsds_omm_vers: fields.ccsds_omm_vers,
            creation_date: fields.creation_date,
            originator: fields.originator,
            object_name: fields.object_name,
            object_id: fields.object_id,
            center_name: fields.center_name,
            ref_frame: fields.ref_frame,
            time_system: fields.time_system,
            mean_element_theory: fields.mean_element_theory,
            epoch: fields.epoch.try_into()?,
            mean_motion: finite(fields.mean_motion, "mean_motion")?,
            eccentricity: finite(fields.eccentricity, "eccentricity")?,
            inclination_deg: finite(fields.inclination_deg, "inclination_deg")?,
            ra_of_asc_node_deg: finite(fields.ra_of_asc_node_deg, "ra_of_asc_node_deg")?,
            arg_of_pericenter_deg: finite(fields.arg_of_pericenter_deg, "arg_of_pericenter_deg")?,
            mean_anomaly_deg: finite(fields.mean_anomaly_deg, "mean_anomaly_deg")?,
            ephemeris_type: i32_field(fields.ephemeris_type, "ephemeris_type")?,
            classification_type: fields.classification_type,
            norad_cat_id: u32_field(fields.norad_cat_id, "norad_cat_id")?,
            element_set_no: i32_field(fields.element_set_no, "element_set_no")?,
            rev_at_epoch: fields.rev_at_epoch,
            bstar: finite(fields.bstar, "bstar")?,
            mean_motion_dot: finite(fields.mean_motion_dot, "mean_motion_dot")?,
            mean_motion_ddot: finite(fields.mean_motion_ddot, "mean_motion_ddot")?,
        })
    }
}

fn u32_field(value: i64, name: &'static str) -> Result<u32, String> {
    u32::try_from(value).map_err(|_| format!("{name} is out of range for u32: {value}"))
}

fn i32_field(value: i64, name: &'static str) -> Result<i32, String> {
    i32::try_from(value).map_err(|_| format!("{name} is out of range for i32: {value}"))
}

fn finite(value: f64, name: &'static str) -> Result<f64, String> {
    if value.is_finite() {
        Ok(value)
    } else {
        Err(format!("{name} must be finite"))
    }
}

fn parse_result<'a>(env: Env<'a>, result: Result<Omm, core_omm::OmmError>) -> Term<'a> {
    match result {
        Ok(parsed) => (atoms::ok(), OmmFields::from(parsed)).encode(env),
        Err(e) => (atoms::error(), e.to_string()).encode(env),
    }
}

fn encode_result<'a, F>(env: Env<'a>, fields: OmmFields, encode: F) -> Term<'a>
where
    F: FnOnce(&Omm) -> String,
{
    match Omm::try_from(fields) {
        Ok(omm) => (atoms::ok(), encode(&omm)).encode(env),
        Err(reason) => (atoms::error(), reason).encode(env),
    }
}

/// Parse CCSDS OMM KVN text.
#[rustler::nif(schedule = "DirtyCpu")]
fn omm_parse_kvn<'a>(env: Env<'a>, text: String) -> Term<'a> {
    parse_result(env, core_omm::parse_kvn(&text))
}

/// Parse CCSDS OMM XML text.
#[rustler::nif(schedule = "DirtyCpu")]
fn omm_parse_xml<'a>(env: Env<'a>, text: String) -> Term<'a> {
    parse_result(env, core_omm::parse_xml(&text))
}

/// Parse CCSDS/CelesTrak OMM JSON text.
#[rustler::nif(schedule = "DirtyCpu")]
fn omm_parse_json<'a>(env: Env<'a>, text: String) -> Term<'a> {
    parse_result(env, core_omm::parse_json(&text))
}

/// Encode normalized OMM fields as CCSDS OMM KVN text.
#[rustler::nif]
fn omm_encode_kvn<'a>(env: Env<'a>, fields: OmmFields) -> Term<'a> {
    encode_result(env, fields, core_omm::encode_kvn)
}

/// Encode normalized OMM fields as CCSDS OMM XML text.
#[rustler::nif]
fn omm_encode_xml<'a>(env: Env<'a>, fields: OmmFields) -> Term<'a> {
    encode_result(env, fields, core_omm::encode_xml)
}

/// Encode normalized OMM fields as CCSDS/CelesTrak OMM JSON text.
#[rustler::nif]
fn omm_encode_json<'a>(env: Env<'a>, fields: OmmFields) -> Term<'a> {
    encode_result(env, fields, core_omm::encode_json)
}
