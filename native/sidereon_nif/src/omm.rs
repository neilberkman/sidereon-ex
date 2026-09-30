//! Rustler boundary for CCSDS OMM KVN, XML, and JSON reader/writer.
//!
//! Pure glue over `sidereon_core::astro::omm`: decode raw text or normalized
//! fields, forward to the crate codecs, and encode the same field shape back to
//! Elixir. No OMM grammar, XML traversal, JSON handling, or number formatting
//! lives here.

use crate::ndm_errors::{omm_error_term, InputRefusal};
use rustler::{Encoder, Env, Term};
use sidereon_core::astro::omm::{
    self as core_omm, Omm, OmmArray, OmmComments, OmmCovariance, OmmEpoch, OmmSpacecraft,
    OmmUserDefined,
};

mod atoms {
    rustler::atoms! {
        ok,
        error,
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
    femtosecond: Option<i64>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct OmmSpacecraftFields {
    comments: Vec<String>,
    mass_kg: Option<f64>,
    solar_rad_area_m2: Option<f64>,
    solar_rad_coeff: Option<f64>,
    drag_area_m2: Option<f64>,
    drag_coeff: Option<f64>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct OmmCovarianceFields {
    comments: Vec<String>,
    cov_ref_frame: Option<String>,
    lower_triangle: Vec<f64>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct OmmUserDefinedFields {
    parameter: String,
    value: String,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct OmmCommentsFields {
    header: Vec<String>,
    metadata: Vec<String>,
    mean_elements: Vec<String>,
    tle_parameters: Vec<String>,
    user_defined: Vec<String>,
}

#[derive(Debug, Clone, rustler::NifMap)]
pub(crate) struct OmmFields {
    ccsds_omm_vers: Option<String>,
    classification: Option<String>,
    creation_date: Option<String>,
    originator: Option<String>,
    message_id: Option<String>,
    object_name: Option<String>,
    object_id: Option<String>,
    center_name: Option<String>,
    ref_frame: Option<String>,
    ref_frame_epoch: Option<String>,
    time_system: Option<String>,
    mean_element_theory: Option<String>,
    epoch: OmmEpochFields,
    mean_motion: Option<f64>,
    semi_major_axis_km: Option<f64>,
    eccentricity: f64,
    inclination_deg: f64,
    ra_of_asc_node_deg: f64,
    arg_of_pericenter_deg: f64,
    mean_anomaly_deg: f64,
    gm_km3_s2: Option<f64>,
    spacecraft: Option<OmmSpacecraftFields>,
    ephemeris_type: Option<i64>,
    classification_type: Option<String>,
    norad_cat_id: Option<i64>,
    element_set_no: Option<i64>,
    rev_at_epoch: Option<i64>,
    bstar: Option<f64>,
    bterm_m2_kg: Option<f64>,
    mean_motion_dot: Option<f64>,
    mean_motion_ddot: Option<f64>,
    agom_m2_kg: Option<f64>,
    covariance: Option<OmmCovarianceFields>,
    user_defined: Vec<OmmUserDefinedFields>,
    comments: OmmCommentsFields,
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
            femtosecond: Some(epoch.femtosecond as i64),
        }
    }
}

impl From<Omm> for OmmFields {
    fn from(omm: Omm) -> Self {
        Self {
            ccsds_omm_vers: omm.ccsds_omm_vers,
            classification: omm.classification,
            creation_date: omm.creation_date,
            originator: omm.originator,
            message_id: omm.message_id,
            object_name: omm.object_name,
            object_id: omm.object_id,
            center_name: omm.center_name,
            ref_frame: omm.ref_frame,
            ref_frame_epoch: omm.ref_frame_epoch,
            time_system: omm.time_system,
            mean_element_theory: omm.mean_element_theory,
            epoch: omm.epoch.into(),
            mean_motion: omm.mean_motion,
            semi_major_axis_km: omm.semi_major_axis_km,
            eccentricity: omm.eccentricity,
            inclination_deg: omm.inclination_deg,
            ra_of_asc_node_deg: omm.ra_of_asc_node_deg,
            arg_of_pericenter_deg: omm.arg_of_pericenter_deg,
            mean_anomaly_deg: omm.mean_anomaly_deg,
            gm_km3_s2: omm.gm_km3_s2,
            spacecraft: omm.spacecraft.map(|sc| OmmSpacecraftFields {
                comments: sc.comments,
                mass_kg: sc.mass_kg,
                solar_rad_area_m2: sc.solar_rad_area_m2,
                solar_rad_coeff: sc.solar_rad_coeff,
                drag_area_m2: sc.drag_area_m2,
                drag_coeff: sc.drag_coeff,
            }),
            ephemeris_type: omm.ephemeris_type.map(i64::from),
            classification_type: omm.classification_type,
            norad_cat_id: omm.norad_cat_id.map(i64::from),
            element_set_no: omm.element_set_no.map(i64::from),
            rev_at_epoch: omm.rev_at_epoch,
            bstar: omm.bstar,
            bterm_m2_kg: omm.bterm_m2_kg,
            mean_motion_dot: omm.mean_motion_dot,
            mean_motion_ddot: omm.mean_motion_ddot,
            agom_m2_kg: omm.agom_m2_kg,
            covariance: omm.covariance.map(|cov| OmmCovarianceFields {
                comments: cov.comments,
                cov_ref_frame: cov.cov_ref_frame,
                lower_triangle: cov.lower_triangle.to_vec(),
            }),
            user_defined: omm
                .user_defined
                .into_iter()
                .map(|p| OmmUserDefinedFields {
                    parameter: p.parameter,
                    value: p.value,
                })
                .collect(),
            comments: OmmCommentsFields {
                header: omm.comments.header,
                metadata: omm.comments.metadata,
                mean_elements: omm.comments.mean_elements,
                tle_parameters: omm.comments.tle_parameters,
                user_defined: omm.comments.user_defined,
            },
        }
    }
}

impl TryFrom<OmmEpochFields> for OmmEpoch {
    type Error = InputRefusal;

    fn try_from(epoch: OmmEpochFields) -> Result<Self, Self::Error> {
        Ok(Self {
            year: epoch.year,
            month: u32_field(epoch.month, "epoch.month")?,
            day: u32_field(epoch.day, "epoch.day")?,
            hour: u32_field(epoch.hour, "epoch.hour")?,
            minute: u32_field(epoch.minute, "epoch.minute")?,
            second: u32_field(epoch.second, "epoch.second")?,
            microsecond: u32_field(epoch.microsecond, "epoch.microsecond")?,
            femtosecond: u32_field(epoch.femtosecond.unwrap_or(0), "epoch.femtosecond")?,
        })
    }
}

impl TryFrom<OmmFields> for Omm {
    type Error = InputRefusal;

    fn try_from(fields: OmmFields) -> Result<Self, Self::Error> {
        let spacecraft = match fields.spacecraft {
            Some(sc) => Some(OmmSpacecraft {
                comments: sc.comments,
                mass_kg: optional_finite(sc.mass_kg, "spacecraft.mass_kg")?,
                solar_rad_area_m2: optional_finite(
                    sc.solar_rad_area_m2,
                    "spacecraft.solar_rad_area_m2",
                )?,
                solar_rad_coeff: optional_finite(sc.solar_rad_coeff, "spacecraft.solar_rad_coeff")?,
                drag_area_m2: optional_finite(sc.drag_area_m2, "spacecraft.drag_area_m2")?,
                drag_coeff: optional_finite(sc.drag_coeff, "spacecraft.drag_coeff")?,
            }),
            None => None,
        };
        let covariance = match fields.covariance {
            Some(cov) => {
                let values: [f64; 21] =
                    cov.lower_triangle
                        .try_into()
                        .map_err(|v: Vec<f64>| InputRefusal::Length {
                            group: "covariance.lower_triangle",
                            expected: 21,
                            got: v.len(),
                        })?;
                for value in values {
                    finite(value, "covariance.lower_triangle")?;
                }
                Some(OmmCovariance {
                    comments: cov.comments,
                    cov_ref_frame: cov.cov_ref_frame,
                    lower_triangle: values,
                })
            }
            None => None,
        };
        Ok(Self {
            ccsds_omm_vers: fields.ccsds_omm_vers,
            classification: fields.classification,
            creation_date: fields.creation_date,
            originator: fields.originator,
            message_id: fields.message_id,
            object_name: fields.object_name,
            object_id: fields.object_id,
            center_name: fields.center_name,
            ref_frame: fields.ref_frame,
            ref_frame_epoch: fields.ref_frame_epoch,
            time_system: fields.time_system,
            mean_element_theory: fields.mean_element_theory,
            epoch: fields.epoch.try_into()?,
            mean_motion: optional_finite(fields.mean_motion, "mean_motion")?,
            semi_major_axis_km: optional_finite(fields.semi_major_axis_km, "semi_major_axis_km")?,
            eccentricity: finite(fields.eccentricity, "eccentricity")?,
            inclination_deg: finite(fields.inclination_deg, "inclination_deg")?,
            ra_of_asc_node_deg: finite(fields.ra_of_asc_node_deg, "ra_of_asc_node_deg")?,
            arg_of_pericenter_deg: finite(fields.arg_of_pericenter_deg, "arg_of_pericenter_deg")?,
            mean_anomaly_deg: finite(fields.mean_anomaly_deg, "mean_anomaly_deg")?,
            gm_km3_s2: optional_finite(fields.gm_km3_s2, "gm_km3_s2")?,
            spacecraft,
            ephemeris_type: fields
                .ephemeris_type
                .map(|v| i32_field(v, "ephemeris_type"))
                .transpose()?,
            classification_type: fields.classification_type,
            norad_cat_id: fields
                .norad_cat_id
                .map(|v| u32_field(v, "norad_cat_id"))
                .transpose()?,
            element_set_no: fields
                .element_set_no
                .map(|v| i32_field(v, "element_set_no"))
                .transpose()?,
            rev_at_epoch: fields.rev_at_epoch,
            bstar: optional_finite(fields.bstar, "bstar")?,
            bterm_m2_kg: optional_finite(fields.bterm_m2_kg, "bterm_m2_kg")?,
            mean_motion_dot: optional_finite(fields.mean_motion_dot, "mean_motion_dot")?,
            mean_motion_ddot: optional_finite(fields.mean_motion_ddot, "mean_motion_ddot")?,
            agom_m2_kg: optional_finite(fields.agom_m2_kg, "agom_m2_kg")?,
            covariance,
            user_defined: fields
                .user_defined
                .into_iter()
                .map(|p| OmmUserDefined {
                    parameter: p.parameter,
                    value: p.value,
                })
                .collect(),
            comments: OmmComments {
                header: fields.comments.header,
                metadata: fields.comments.metadata,
                mean_elements: fields.comments.mean_elements,
                tle_parameters: fields.comments.tle_parameters,
                user_defined: fields.comments.user_defined,
            },
            exact_sgp4_epoch: None,
            quantize_tle_derived_fields: true,
        })
    }
}

fn u32_field(value: i64, name: &'static str) -> Result<u32, InputRefusal> {
    u32::try_from(value).map_err(|_| InputRefusal::OutOfRange { field: name })
}

fn i32_field(value: i64, name: &'static str) -> Result<i32, InputRefusal> {
    i32::try_from(value).map_err(|_| InputRefusal::OutOfRange { field: name })
}

fn optional_finite(value: Option<f64>, name: &'static str) -> Result<Option<f64>, InputRefusal> {
    value.map(|v| finite(v, name)).transpose()
}

fn finite(value: f64, name: &'static str) -> Result<f64, InputRefusal> {
    if value.is_finite() {
        Ok(value)
    } else {
        Err(InputRefusal::NonFinite { field: name })
    }
}

fn parse_result<'a>(env: Env<'a>, result: Result<Omm, core_omm::OmmError>) -> Term<'a> {
    match result {
        Ok(parsed) => (atoms::ok(), OmmFields::from(parsed)).encode(env),
        Err(e) => (atoms::error(), omm_error_term(env, &e)).encode(env),
    }
}

fn encode_result<'a, F>(env: Env<'a>, fields: OmmFields, encode: F) -> Term<'a>
where
    F: FnOnce(&Omm) -> Result<String, core_omm::OmmError>,
{
    match Omm::try_from(fields) {
        Ok(omm) => match encode(&omm) {
            Ok(text) => (atoms::ok(), text).encode(env),
            Err(e) => (atoms::error(), omm_error_term(env, &e)).encode(env),
        },
        Err(reason) => (atoms::error(), reason.term(env)).encode(env),
    }
}

/// `{:ok, omms, skipped}`, where each skipped entry is `{index, reason}` with
/// the zero-based position of the record the reader could not read.
fn array_result<'a>(env: Env<'a>, result: Result<OmmArray, core_omm::OmmError>) -> Term<'a> {
    match result {
        Ok(array) => {
            let omms: Vec<OmmFields> = array.omms.into_iter().map(OmmFields::from).collect();
            let skipped: Vec<Term<'a>> = array
                .skipped
                .iter()
                .map(|record| {
                    (record.index as u64, omm_error_term(env, &record.reason)).encode(env)
                })
                .collect();
            (atoms::ok(), omms, skipped).encode(env)
        }
        Err(e) => (atoms::error(), omm_error_term(env, &e)).encode(env),
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

/// Parse every OMM of a CCSDS OMM XML document or NDM combined instantiation.
#[rustler::nif(schedule = "DirtyCpu")]
fn omm_parse_xml_all<'a>(env: Env<'a>, text: String) -> Term<'a> {
    array_result(env, core_omm::parse_xml_all(&text))
}

/// Parse CCSDS/CelesTrak OMM JSON text holding one record.
#[rustler::nif(schedule = "DirtyCpu")]
fn omm_parse_json<'a>(env: Env<'a>, text: String) -> Term<'a> {
    parse_result(env, core_omm::parse_json(&text))
}

/// Parse a CelesTrak/Space-Track GP JSON array of OMM records.
#[rustler::nif(schedule = "DirtyCpu")]
fn omm_parse_json_array<'a>(env: Env<'a>, text: String) -> Term<'a> {
    array_result(env, core_omm::parse_json_array(&text))
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

/// Encode normalized OMM fields as GP JSON, leaving out the comments GP JSON
/// cannot carry.
#[rustler::nif]
fn omm_encode_json_discarding_comments<'a>(env: Env<'a>, fields: OmmFields) -> Term<'a> {
    encode_result(env, fields, core_omm::encode_json_discarding_comments)
}

/// The SGP4 element set `Omm::to_element_set` forms from an OMM, as the core
/// forms it: the epoch as its split Julian date (femtoseconds and a UTC leap
/// second included), B* and the second mean-motion derivative quantized as the
/// TLE writes them, and the catalog number `nil` when the OMM states none.
#[derive(Debug, Clone, rustler::NifMap)]
struct ElementSetFields {
    epoch_jd: (f64, f64),
    bstar: f64,
    mean_motion_dot: Option<f64>,
    mean_motion_double_dot: Option<f64>,
    eccentricity: f64,
    argument_of_perigee_deg: f64,
    inclination_deg: f64,
    mean_anomaly_deg: f64,
    mean_motion_rev_per_day: f64,
    right_ascension_deg: f64,
    catalog_number: Option<u32>,
    omm_epoch_days: Option<f64>,
}

/// The SGP4 element set of normalized OMM fields, through
/// `Omm::to_element_set`.
#[rustler::nif]
fn omm_to_element_set<'a>(env: Env<'a>, fields: OmmFields) -> Term<'a> {
    let omm = match Omm::try_from(fields) {
        Ok(omm) => omm,
        Err(reason) => return (atoms::error(), reason.term(env)).encode(env),
    };
    match omm.to_element_set() {
        Ok(set) => (
            atoms::ok(),
            ElementSetFields {
                epoch_jd: (set.epoch.0, set.epoch.1),
                bstar: set.bstar,
                mean_motion_dot: set.mean_motion_dot,
                mean_motion_double_dot: set.mean_motion_double_dot,
                eccentricity: set.eccentricity,
                argument_of_perigee_deg: set.argument_of_perigee_deg,
                inclination_deg: set.inclination_deg,
                mean_anomaly_deg: set.mean_anomaly_deg,
                mean_motion_rev_per_day: set.mean_motion_rev_per_day,
                right_ascension_deg: set.right_ascension_deg,
                catalog_number: set.catalog_number,
                omm_epoch_days: set.omm_epoch_days,
            },
        )
            .encode(env),
        Err(error) => (atoms::error(), omm_error_term(env, &error)).encode(env),
    }
}
