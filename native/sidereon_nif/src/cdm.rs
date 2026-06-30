//! Rustler boundary for the CCSDS CDM KVN and XML reader/writer.
//!
//! Pure glue over `sidereon_core::astro::cdm`: decode the raw KVN/XML text or the
//! normalized field map, forward to the crate codec, and encode the unchanged
//! Sidereon result shapes. No grammar, unit stripping, or number parsing lives here.
//! Date/time fields cross as raw strings; the Elixir binding resolves them to/from
//! its native `DateTime`.

use rustler::{Encoder, Env, NifResult, Term};
use sidereon_core::astro::cdm::{self, CdmKvn, CdmObject};

mod atoms {
    rustler::atoms! {
        ok,
        error
    }
}

/// One object block exchanged with the Elixir binding. Mirrors
/// `%Sidereon.CCSDS.CDM.ObjectData{}` with the state as a nested `{r, v}` tuple,
/// the RTN position covariance as a six-element list, and the optional RTN
/// velocity covariance (the 15 lower-triangle rows completing the 6x6 matrix) as
/// a list of 15 floats or `nil`. Every CCSDS metadata field the core carries is
/// crossed verbatim as a string.
#[derive(Debug, Clone, rustler::NifMap)]
struct ObjectFields {
    object_designator: Option<String>,
    catalog_name: Option<String>,
    object_name: Option<String>,
    international_designator: Option<String>,
    object_type: Option<String>,
    operator_contact_position: Option<String>,
    operator_organization: Option<String>,
    operator_phone: Option<String>,
    operator_email: Option<String>,
    ephemeris_name: Option<String>,
    covariance_method: Option<String>,
    maneuverable: Option<String>,
    orbit_center: Option<String>,
    ref_frame: Option<String>,
    gravity_model: Option<String>,
    atmospheric_model: Option<String>,
    n_body_perturbations: Option<String>,
    solar_rad_pressure: Option<String>,
    earth_tides: Option<String>,
    intrack_thrust: Option<String>,
    state: ((f64, f64, f64), (f64, f64, f64)),
    covariance_rtn: Vec<f64>,
    velocity_covariance_rtn: Option<Vec<f64>>,
}

/// Normalized CDM fields exchanged with the Elixir binding. Mirrors the
/// `%Sidereon.CCSDS.CDM{}` numeric/string content with `creation_date` / `tca` left
/// as the raw textual values for the host to resolve.
#[derive(Debug, Clone, rustler::NifMap)]
struct CdmFields {
    creation_date: Option<String>,
    originator: Option<String>,
    message_id: Option<String>,
    tca: Option<String>,
    miss_distance_m: Option<f64>,
    relative_speed_m_s: Option<f64>,
    collision_probability: Option<f64>,
    collision_probability_method: Option<String>,
    hard_body_radius_m: Option<f64>,
    object1: ObjectFields,
    object2: ObjectFields,
}

impl From<CdmObject> for ObjectFields {
    fn from(o: CdmObject) -> Self {
        Self {
            object_designator: o.object_designator,
            catalog_name: o.catalog_name,
            object_name: o.object_name,
            international_designator: o.international_designator,
            object_type: o.object_type,
            operator_contact_position: o.operator_contact_position,
            operator_organization: o.operator_organization,
            operator_phone: o.operator_phone,
            operator_email: o.operator_email,
            ephemeris_name: o.ephemeris_name,
            covariance_method: o.covariance_method,
            maneuverable: o.maneuverable,
            orbit_center: o.orbit_center,
            ref_frame: o.ref_frame,
            gravity_model: o.gravity_model,
            atmospheric_model: o.atmospheric_model,
            n_body_perturbations: o.n_body_perturbations,
            solar_rad_pressure: o.solar_rad_pressure,
            earth_tides: o.earth_tides,
            intrack_thrust: o.intrack_thrust,
            state: o.state,
            covariance_rtn: o.covariance_rtn.to_vec(),
            velocity_covariance_rtn: o.velocity_covariance_rtn.map(|v| v.to_vec()),
        }
    }
}

impl From<ObjectFields> for CdmObject {
    fn from(f: ObjectFields) -> Self {
        Self {
            object_designator: f.object_designator,
            catalog_name: f.catalog_name,
            object_name: f.object_name,
            international_designator: f.international_designator,
            object_type: f.object_type,
            operator_contact_position: f.operator_contact_position,
            operator_organization: f.operator_organization,
            operator_phone: f.operator_phone,
            operator_email: f.operator_email,
            ephemeris_name: f.ephemeris_name,
            covariance_method: f.covariance_method,
            maneuverable: f.maneuverable,
            orbit_center: f.orbit_center,
            ref_frame: f.ref_frame,
            gravity_model: f.gravity_model,
            atmospheric_model: f.atmospheric_model,
            n_body_perturbations: f.n_body_perturbations,
            solar_rad_pressure: f.solar_rad_pressure,
            earth_tides: f.earth_tides,
            intrack_thrust: f.intrack_thrust,
            state: f.state,
            covariance_rtn: to_covariance(&f.covariance_rtn),
            velocity_covariance_rtn: f
                .velocity_covariance_rtn
                .as_deref()
                .map(to_velocity_covariance),
        }
    }
}

impl From<CdmKvn> for CdmFields {
    fn from(c: CdmKvn) -> Self {
        Self {
            creation_date: c.creation_date,
            originator: c.originator,
            message_id: c.message_id,
            tca: c.tca,
            miss_distance_m: c.miss_distance_m,
            relative_speed_m_s: c.relative_speed_m_s,
            collision_probability: c.collision_probability,
            collision_probability_method: c.collision_probability_method,
            hard_body_radius_m: c.hard_body_radius_m,
            object1: c.object1.into(),
            object2: c.object2.into(),
        }
    }
}

impl From<CdmFields> for CdmKvn {
    fn from(f: CdmFields) -> Self {
        Self {
            creation_date: f.creation_date,
            originator: f.originator,
            message_id: f.message_id,
            tca: f.tca,
            miss_distance_m: f.miss_distance_m,
            relative_speed_m_s: f.relative_speed_m_s,
            collision_probability: f.collision_probability,
            collision_probability_method: f.collision_probability_method,
            hard_body_radius_m: f.hard_body_radius_m,
            object1: f.object1.into(),
            object2: f.object2.into(),
        }
    }
}

/// Copy the six RTN covariance components, leaving any missing slot at zero.
fn to_covariance(values: &[f64]) -> [f64; 6] {
    let mut out = [0.0_f64; 6];
    for (slot, value) in out.iter_mut().zip(values) {
        *slot = *value;
    }
    out
}

/// Copy the 15 RTN velocity-covariance components, leaving any missing slot at
/// zero. The core emits the full block when present, so a faithful caller passes
/// 15 values.
fn to_velocity_covariance(values: &[f64]) -> [f64; 15] {
    let mut out = [0.0_f64; 15];
    for (slot, value) in out.iter_mut().zip(values) {
        *slot = *value;
    }
    out
}

/// Returns `{:ok, fields}` with date/time fields as raw strings, or
/// `{:error, reason}` for a structurally invalid message.
#[rustler::nif]
fn cdm_parse_kvn<'a>(env: Env<'a>, text: String) -> Term<'a> {
    match cdm::parse_kvn(&text) {
        Ok(parsed) => (atoms::ok(), CdmFields::from(parsed)).encode(env),
        Err(e) => (atoms::error(), e.to_string()).encode(env),
    }
}

#[rustler::nif]
fn cdm_encode_kvn(fields: CdmFields) -> NifResult<String> {
    cdm::encode_kvn(&fields.into()).map_err(crate::errors::invalid_input)
}

/// Returns `{:ok, fields}` with date/time fields as raw strings, or
/// `{:error, reason}` for a structurally invalid message.
#[rustler::nif]
fn cdm_parse_xml<'a>(env: Env<'a>, text: String) -> Term<'a> {
    match cdm::parse_xml(&text) {
        Ok(parsed) => (atoms::ok(), CdmFields::from(parsed)).encode(env),
        Err(e) => (atoms::error(), e.to_string()).encode(env),
    }
}

#[rustler::nif]
fn cdm_encode_xml(fields: CdmFields) -> NifResult<String> {
    cdm::encode_xml(&fields.into()).map_err(crate::errors::invalid_input)
}
