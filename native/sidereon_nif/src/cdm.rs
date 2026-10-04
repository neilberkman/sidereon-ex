//! Rustler boundary for the CCSDS CDM KVN and XML reader/writer.
//!
//! Pure glue over `sidereon_core::astro::cdm`: decode the raw KVN/XML text or the
//! normalized field map, forward to the crate codec, and encode the unchanged
//! Sidereon result shapes. No grammar, unit stripping, or number parsing lives here.
//! Date/time fields cross as raw strings; the Elixir binding resolves them to/from
//! its native `DateTime`.

use rustler::{Encoder, Env, Term};
use sidereon_core::astro::cdm::{
    self, CdmAdditionalParameters, CdmKvn, CdmObject, CdmOdParameters,
};

use crate::ndm_errors::{cdm_error_term, InputRefusal};

mod atoms {
    rustler::atoms! {
        ok,
        error
    }
}

type Triple = (Option<f64>, Option<f64>, Option<f64>);

fn triple(v: [Option<f64>; 3]) -> Triple {
    (v[0], v[1], v[2])
}

fn array3((a, b, c): Triple) -> [Option<f64>; 3] {
    [a, b, c]
}

/// OD parameters of one object (CCSDS 508.0-B-1 table 3-4).
#[derive(Debug, Clone, rustler::NifMap)]
struct OdParametersFields {
    comments: Vec<String>,
    time_lastob_start: Option<String>,
    time_lastob_end: Option<String>,
    recommended_od_span_d: Option<f64>,
    actual_od_span_d: Option<f64>,
    obs_available: Option<u64>,
    obs_used: Option<u64>,
    tracks_available: Option<u64>,
    tracks_used: Option<u64>,
    residuals_accepted_pct: Option<f64>,
    weighted_rms: Option<f64>,
}

/// Additional parameters of one object (CCSDS 508.0-B-1 table 3-4).
#[derive(Debug, Clone, rustler::NifMap)]
struct AdditionalParametersFields {
    comments: Vec<String>,
    area_pc_m2: Option<f64>,
    area_drg_m2: Option<f64>,
    area_srp_m2: Option<f64>,
    mass_kg: Option<f64>,
    cd_area_over_mass_m2_kg: Option<f64>,
    cr_area_over_mass_m2_kg: Option<f64>,
    thrust_acceleration_m_s2: Option<f64>,
    sedr_w_kg: Option<f64>,
}

/// One object block exchanged with the Elixir binding. Mirrors
/// `%Sidereon.CCSDS.CDM.ObjectData{}` with the state as a nested `{r, v}` tuple
/// and each row group of the RTN covariance as a list: the six position terms,
/// the 15 velocity terms, and the 7, 8 and 9 terms of rows 7 to 9 (drag, SRP
/// and thrust), each `nil` when the message gives none of it. Every CCSDS
/// metadata field the core carries is crossed verbatim as a string.
#[derive(Debug, Clone, rustler::NifMap)]
struct ObjectFields {
    metadata_comments: Vec<String>,
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
    od_parameters: OdParametersFields,
    additional_parameters: AdditionalParametersFields,
    state_comments: Vec<String>,
    state: ((f64, f64, f64), (f64, f64, f64)),
    covariance_comments: Vec<String>,
    covariance_rtn: Vec<f64>,
    velocity_covariance_rtn: Option<Vec<f64>>,
    drag_covariance_rtn: Option<Vec<f64>>,
    srp_covariance_rtn: Option<Vec<f64>>,
    thrust_covariance_rtn: Option<Vec<f64>>,
}

/// Normalized CDM fields exchanged with the Elixir binding. Mirrors the
/// `%Sidereon.CCSDS.CDM{}` numeric/string content with `creation_date` / `tca` left
/// as the raw textual values for the host to resolve.
#[derive(Debug, Clone, rustler::NifMap)]
struct CdmFields {
    ccsds_cdm_vers: Option<String>,
    comments: Vec<String>,
    creation_date: Option<String>,
    originator: Option<String>,
    message_for: Option<String>,
    message_id: Option<String>,
    relative_comments: Vec<String>,
    tca: Option<String>,
    miss_distance_m: Option<f64>,
    relative_speed_m_s: Option<f64>,
    relative_position_rtn_m: Triple,
    relative_velocity_rtn_m_s: Triple,
    start_screen_period: Option<String>,
    stop_screen_period: Option<String>,
    screen_volume_frame: Option<String>,
    screen_volume_shape: Option<String>,
    screen_volume_m: Triple,
    screen_entry_time: Option<String>,
    screen_exit_time: Option<String>,
    collision_probability: Option<f64>,
    collision_probability_method: Option<String>,
    hard_body_radius_m: Option<f64>,
    object1: ObjectFields,
    object2: ObjectFields,
}

impl From<CdmOdParameters> for OdParametersFields {
    fn from(p: CdmOdParameters) -> Self {
        Self {
            comments: p.comments,
            time_lastob_start: p.time_lastob_start,
            time_lastob_end: p.time_lastob_end,
            recommended_od_span_d: p.recommended_od_span_d,
            actual_od_span_d: p.actual_od_span_d,
            obs_available: p.obs_available,
            obs_used: p.obs_used,
            tracks_available: p.tracks_available,
            tracks_used: p.tracks_used,
            residuals_accepted_pct: p.residuals_accepted_pct,
            weighted_rms: p.weighted_rms,
        }
    }
}

impl From<OdParametersFields> for CdmOdParameters {
    fn from(p: OdParametersFields) -> Self {
        Self {
            comments: p.comments,
            time_lastob_start: p.time_lastob_start,
            time_lastob_end: p.time_lastob_end,
            recommended_od_span_d: p.recommended_od_span_d,
            actual_od_span_d: p.actual_od_span_d,
            obs_available: p.obs_available,
            obs_used: p.obs_used,
            tracks_available: p.tracks_available,
            tracks_used: p.tracks_used,
            residuals_accepted_pct: p.residuals_accepted_pct,
            weighted_rms: p.weighted_rms,
        }
    }
}

impl From<CdmAdditionalParameters> for AdditionalParametersFields {
    fn from(p: CdmAdditionalParameters) -> Self {
        Self {
            comments: p.comments,
            area_pc_m2: p.area_pc_m2,
            area_drg_m2: p.area_drg_m2,
            area_srp_m2: p.area_srp_m2,
            mass_kg: p.mass_kg,
            cd_area_over_mass_m2_kg: p.cd_area_over_mass_m2_kg,
            cr_area_over_mass_m2_kg: p.cr_area_over_mass_m2_kg,
            thrust_acceleration_m_s2: p.thrust_acceleration_m_s2,
            sedr_w_kg: p.sedr_w_kg,
        }
    }
}

impl From<AdditionalParametersFields> for CdmAdditionalParameters {
    fn from(p: AdditionalParametersFields) -> Self {
        Self {
            comments: p.comments,
            area_pc_m2: p.area_pc_m2,
            area_drg_m2: p.area_drg_m2,
            area_srp_m2: p.area_srp_m2,
            mass_kg: p.mass_kg,
            cd_area_over_mass_m2_kg: p.cd_area_over_mass_m2_kg,
            cr_area_over_mass_m2_kg: p.cr_area_over_mass_m2_kg,
            thrust_acceleration_m_s2: p.thrust_acceleration_m_s2,
            sedr_w_kg: p.sedr_w_kg,
        }
    }
}

impl From<CdmObject> for ObjectFields {
    fn from(o: CdmObject) -> Self {
        Self {
            metadata_comments: o.metadata_comments,
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
            od_parameters: o.od_parameters.into(),
            additional_parameters: o.additional_parameters.into(),
            state_comments: o.state_comments,
            state: o.state,
            covariance_comments: o.covariance_comments,
            covariance_rtn: o.covariance_rtn.to_vec(),
            velocity_covariance_rtn: o.velocity_covariance_rtn.map(|v| v.to_vec()),
            drag_covariance_rtn: o.drag_covariance_rtn.map(|v| v.to_vec()),
            srp_covariance_rtn: o.srp_covariance_rtn.map(|v| v.to_vec()),
            thrust_covariance_rtn: o.thrust_covariance_rtn.map(|v| v.to_vec()),
        }
    }
}

/// A covariance row group of exactly `N` values; any other count is refused
/// naming the group, rather than padded with zeros or cut.
fn exact<const N: usize>(values: Vec<f64>, group: &'static str) -> Result<[f64; N], InputRefusal> {
    let got = values.len();
    values.try_into().map_err(|_| InputRefusal::Length {
        group,
        expected: N,
        got,
    })
}

fn optional_exact<const N: usize>(
    values: Option<Vec<f64>>,
    group: &'static str,
) -> Result<Option<[f64; N]>, InputRefusal> {
    values.map(|v| exact::<N>(v, group)).transpose()
}

impl TryFrom<ObjectFields> for CdmObject {
    type Error = InputRefusal;

    fn try_from(f: ObjectFields) -> Result<Self, InputRefusal> {
        Ok(Self {
            metadata_comments: f.metadata_comments,
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
            od_parameters: f.od_parameters.into(),
            additional_parameters: f.additional_parameters.into(),
            state_comments: f.state_comments,
            state: f.state,
            covariance_comments: f.covariance_comments,
            covariance_rtn: exact::<6>(f.covariance_rtn, "covariance_rtn")?,
            velocity_covariance_rtn: optional_exact::<15>(
                f.velocity_covariance_rtn,
                "velocity_covariance_rtn",
            )?,
            drag_covariance_rtn: optional_exact::<7>(f.drag_covariance_rtn, "drag_covariance_rtn")?,
            srp_covariance_rtn: optional_exact::<8>(f.srp_covariance_rtn, "srp_covariance_rtn")?,
            thrust_covariance_rtn: optional_exact::<9>(
                f.thrust_covariance_rtn,
                "thrust_covariance_rtn",
            )?,
        })
    }
}

impl From<CdmKvn> for CdmFields {
    fn from(c: CdmKvn) -> Self {
        Self {
            ccsds_cdm_vers: c.ccsds_cdm_vers,
            comments: c.comments,
            creation_date: c.creation_date,
            originator: c.originator,
            message_for: c.message_for,
            message_id: c.message_id,
            relative_comments: c.relative_comments,
            tca: c.tca,
            miss_distance_m: c.miss_distance_m,
            relative_speed_m_s: c.relative_speed_m_s,
            relative_position_rtn_m: triple(c.relative_position_rtn_m),
            relative_velocity_rtn_m_s: triple(c.relative_velocity_rtn_m_s),
            start_screen_period: c.start_screen_period,
            stop_screen_period: c.stop_screen_period,
            screen_volume_frame: c.screen_volume_frame,
            screen_volume_shape: c.screen_volume_shape,
            screen_volume_m: triple(c.screen_volume_m),
            screen_entry_time: c.screen_entry_time,
            screen_exit_time: c.screen_exit_time,
            collision_probability: c.collision_probability,
            collision_probability_method: c.collision_probability_method,
            hard_body_radius_m: c.hard_body_radius_m,
            object1: c.object1.into(),
            object2: c.object2.into(),
        }
    }
}

impl TryFrom<CdmFields> for CdmKvn {
    type Error = InputRefusal;

    fn try_from(f: CdmFields) -> Result<Self, InputRefusal> {
        Ok(Self {
            ccsds_cdm_vers: f.ccsds_cdm_vers,
            comments: f.comments,
            creation_date: f.creation_date,
            originator: f.originator,
            message_for: f.message_for,
            message_id: f.message_id,
            relative_comments: f.relative_comments,
            tca: f.tca,
            miss_distance_m: f.miss_distance_m,
            relative_speed_m_s: f.relative_speed_m_s,
            relative_position_rtn_m: array3(f.relative_position_rtn_m),
            relative_velocity_rtn_m_s: array3(f.relative_velocity_rtn_m_s),
            start_screen_period: f.start_screen_period,
            stop_screen_period: f.stop_screen_period,
            screen_volume_frame: f.screen_volume_frame,
            screen_volume_shape: f.screen_volume_shape,
            screen_volume_m: array3(f.screen_volume_m),
            screen_entry_time: f.screen_entry_time,
            screen_exit_time: f.screen_exit_time,
            collision_probability: f.collision_probability,
            collision_probability_method: f.collision_probability_method,
            hard_body_radius_m: f.hard_body_radius_m,
            object1: f.object1.try_into()?,
            object2: f.object2.try_into()?,
        })
    }
}

fn parse_result<'a>(env: Env<'a>, result: Result<CdmKvn, cdm::CdmError>) -> Term<'a> {
    match result {
        Ok(parsed) => (atoms::ok(), CdmFields::from(parsed)).encode(env),
        Err(e) => (atoms::error(), cdm_error_term(env, &e)).encode(env),
    }
}

/// `{:ok, text}`; `{:error, {:invalid_length, group, expected, got}}` for a
/// covariance row group of the wrong length, or `{:error, reason}` with the
/// typed term for a message the writer refuses.
fn encode_result<'a>(
    env: Env<'a>,
    fields: CdmFields,
    encode: fn(&CdmKvn) -> Result<String, cdm::CdmError>,
) -> Term<'a> {
    let cdm = match CdmKvn::try_from(fields) {
        Ok(cdm) => cdm,
        Err(refusal) => return (atoms::error(), refusal.term(env)).encode(env),
    };
    match encode(&cdm) {
        Ok(text) => (atoms::ok(), text).encode(env),
        Err(e) => (atoms::error(), cdm_error_term(env, &e)).encode(env),
    }
}

/// Returns `{:ok, fields}` with date/time fields as raw strings, or
/// `{:error, reason}` for a structurally invalid message.
#[rustler::nif]
fn cdm_parse_kvn<'a>(env: Env<'a>, text: String) -> Term<'a> {
    parse_result(env, cdm::parse_kvn(&text))
}

#[rustler::nif]
fn cdm_encode_kvn<'a>(env: Env<'a>, fields: CdmFields) -> Term<'a> {
    encode_result(env, fields, cdm::encode_kvn)
}

/// Returns `{:ok, fields}` with date/time fields as raw strings, or
/// `{:error, reason}` for a structurally invalid message.
#[rustler::nif]
fn cdm_parse_xml<'a>(env: Env<'a>, text: String) -> Term<'a> {
    parse_result(env, cdm::parse_xml(&text))
}

#[rustler::nif]
fn cdm_encode_xml<'a>(env: Env<'a>, fields: CdmFields) -> Term<'a> {
    encode_result(env, fields, cdm::encode_xml)
}
