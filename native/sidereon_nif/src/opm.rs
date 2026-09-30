//! Rustler boundary for the CCSDS OPM KVN and XML reader/writer.
//!
//! Pure glue over `sidereon_core::astro::opm`: decode the raw KVN/XML text or the
//! normalized field map, forward to the crate codec, and encode the unchanged
//! Sidereon result shapes. No grammar, unit handling, or number formatting lives
//! here. Date/time fields cross as raw strings; the Elixir binding owns any
//! resolution to its native `DateTime`. The optional true/mean anomaly crosses as
//! an `anomaly_kind` tag (`"TRUE"`/`"MEAN"`) plus an `anomaly_deg` value. Failure
//! categories cross as atoms.

use crate::ndm_errors::{opm_error_term, InputRefusal};
use rustler::{Encoder, Env, Term};
use sidereon_core::astro::opm::{
    self as core_opm, Opm, OpmAnomaly, OpmCovariance, OpmError, OpmKeplerian, OpmManeuver,
    OpmMetadata, OpmSpacecraft, OpmState, OpmUserDefined,
};

mod atoms {
    rustler::atoms! {
        ok,
        error,
    }
}

const ANOMALY_TRUE: &str = "TRUE";
const ANOMALY_MEAN: &str = "MEAN";

#[derive(Debug, Clone, rustler::NifMap)]
struct OpmMetadataFields {
    comments: Vec<String>,
    object_name: String,
    object_id: String,
    center_name: String,
    ref_frame: String,
    ref_frame_epoch: Option<String>,
    time_system: String,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct OpmStateFields {
    comments: Vec<String>,
    epoch: String,
    position_km: (f64, f64, f64),
    velocity_km_s: (f64, f64, f64),
}

#[derive(Debug, Clone, rustler::NifMap)]
struct OpmKeplerianFields {
    comments: Vec<String>,
    semi_major_axis_km: f64,
    eccentricity: f64,
    inclination_deg: f64,
    ra_of_asc_node_deg: f64,
    arg_of_pericenter_deg: f64,
    anomaly_kind: String,
    anomaly_deg: f64,
    gm_km3_s2: f64,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct OpmSpacecraftFields {
    comments: Vec<String>,
    mass_kg: Option<f64>,
    solar_rad_area_m2: Option<f64>,
    solar_rad_coeff: Option<f64>,
    drag_area_m2: Option<f64>,
    drag_coeff: Option<f64>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct OpmCovarianceFields {
    comments: Vec<String>,
    cov_ref_frame: Option<String>,
    lower_triangle: Vec<f64>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct OpmManeuverFields {
    comments: Vec<String>,
    epoch_ignition: String,
    duration_s: f64,
    delta_mass_kg: f64,
    ref_frame: String,
    dv_km_s: (f64, f64, f64),
}

#[derive(Debug, Clone, rustler::NifMap)]
struct OpmUserDefinedFields {
    parameter: String,
    value: String,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct OpmFields {
    ccsds_opm_vers: String,
    comments: Vec<String>,
    classification: Option<String>,
    creation_date: Option<String>,
    originator: Option<String>,
    message_id: Option<String>,
    metadata: OpmMetadataFields,
    state: OpmStateFields,
    keplerian: Option<OpmKeplerianFields>,
    spacecraft: Option<OpmSpacecraftFields>,
    covariance: Option<OpmCovarianceFields>,
    maneuvers: Vec<OpmManeuverFields>,
    user_defined: Vec<OpmUserDefinedFields>,
    user_defined_comments: Vec<String>,
}

fn vec3((x, y, z): (f64, f64, f64)) -> [f64; 3] {
    [x, y, z]
}

fn tuple3(v: [f64; 3]) -> (f64, f64, f64) {
    (v[0], v[1], v[2])
}

impl From<OpmMetadata> for OpmMetadataFields {
    fn from(m: OpmMetadata) -> Self {
        Self {
            comments: m.comments,
            object_name: m.object_name,
            object_id: m.object_id,
            center_name: m.center_name,
            ref_frame: m.ref_frame,
            ref_frame_epoch: m.ref_frame_epoch,
            time_system: m.time_system,
        }
    }
}

impl From<OpmMetadataFields> for OpmMetadata {
    fn from(f: OpmMetadataFields) -> Self {
        Self {
            comments: f.comments,
            object_name: f.object_name,
            object_id: f.object_id,
            center_name: f.center_name,
            ref_frame: f.ref_frame,
            ref_frame_epoch: f.ref_frame_epoch,
            time_system: f.time_system,
        }
    }
}

impl From<OpmState> for OpmStateFields {
    fn from(s: OpmState) -> Self {
        Self {
            comments: s.comments,
            epoch: s.epoch,
            position_km: tuple3(s.position_km),
            velocity_km_s: tuple3(s.velocity_km_s),
        }
    }
}

impl From<OpmStateFields> for OpmState {
    fn from(f: OpmStateFields) -> Self {
        Self {
            comments: f.comments,
            epoch: f.epoch,
            position_km: vec3(f.position_km),
            velocity_km_s: vec3(f.velocity_km_s),
        }
    }
}

impl From<OpmKeplerian> for OpmKeplerianFields {
    fn from(k: OpmKeplerian) -> Self {
        let (anomaly_kind, anomaly_deg) = match k.anomaly {
            OpmAnomaly::True(v) => (ANOMALY_TRUE.to_string(), v),
            OpmAnomaly::Mean(v) => (ANOMALY_MEAN.to_string(), v),
        };
        Self {
            comments: k.comments,
            semi_major_axis_km: k.semi_major_axis_km,
            eccentricity: k.eccentricity,
            inclination_deg: k.inclination_deg,
            ra_of_asc_node_deg: k.ra_of_asc_node_deg,
            arg_of_pericenter_deg: k.arg_of_pericenter_deg,
            anomaly_kind,
            anomaly_deg,
            gm_km3_s2: k.gm_km3_s2,
        }
    }
}

/// Rebuild the anomaly enum from the `anomaly_kind` tag. Any tag other than the
/// mean marker is treated as a true anomaly, matching the CCSDS default where the
/// `TRUE_ANOMALY` keyword is the canonical form.
fn anomaly_from_fields(kind: &str, deg: f64) -> OpmAnomaly {
    if kind.eq_ignore_ascii_case(ANOMALY_MEAN) {
        OpmAnomaly::Mean(deg)
    } else {
        OpmAnomaly::True(deg)
    }
}

impl From<OpmKeplerianFields> for OpmKeplerian {
    fn from(f: OpmKeplerianFields) -> Self {
        let anomaly = anomaly_from_fields(&f.anomaly_kind, f.anomaly_deg);
        Self {
            comments: f.comments,
            semi_major_axis_km: f.semi_major_axis_km,
            eccentricity: f.eccentricity,
            inclination_deg: f.inclination_deg,
            ra_of_asc_node_deg: f.ra_of_asc_node_deg,
            arg_of_pericenter_deg: f.arg_of_pericenter_deg,
            anomaly,
            gm_km3_s2: f.gm_km3_s2,
        }
    }
}

impl From<OpmSpacecraft> for OpmSpacecraftFields {
    fn from(s: OpmSpacecraft) -> Self {
        Self {
            comments: s.comments,
            mass_kg: s.mass_kg,
            solar_rad_area_m2: s.solar_rad_area_m2,
            solar_rad_coeff: s.solar_rad_coeff,
            drag_area_m2: s.drag_area_m2,
            drag_coeff: s.drag_coeff,
        }
    }
}

impl From<OpmSpacecraftFields> for OpmSpacecraft {
    fn from(f: OpmSpacecraftFields) -> Self {
        Self {
            comments: f.comments,
            mass_kg: f.mass_kg,
            solar_rad_area_m2: f.solar_rad_area_m2,
            solar_rad_coeff: f.solar_rad_coeff,
            drag_area_m2: f.drag_area_m2,
            drag_coeff: f.drag_coeff,
        }
    }
}

impl From<OpmCovariance> for OpmCovarianceFields {
    fn from(c: OpmCovariance) -> Self {
        Self {
            comments: c.comments,
            cov_ref_frame: c.cov_ref_frame,
            lower_triangle: c.lower_triangle.to_vec(),
        }
    }
}

impl TryFrom<OpmCovarianceFields> for OpmCovariance {
    type Error = InputRefusal;

    /// The 21 lower-triangle values, exactly as given; any other count is
    /// refused rather than padded or cut.
    fn try_from(f: OpmCovarianceFields) -> Result<Self, InputRefusal> {
        Ok(Self {
            comments: f.comments,
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

impl From<OpmManeuver> for OpmManeuverFields {
    fn from(m: OpmManeuver) -> Self {
        Self {
            comments: m.comments,
            epoch_ignition: m.epoch_ignition,
            duration_s: m.duration_s,
            delta_mass_kg: m.delta_mass_kg,
            ref_frame: m.ref_frame,
            dv_km_s: tuple3(m.dv_km_s),
        }
    }
}

impl From<OpmManeuverFields> for OpmManeuver {
    fn from(f: OpmManeuverFields) -> Self {
        Self {
            comments: f.comments,
            epoch_ignition: f.epoch_ignition,
            duration_s: f.duration_s,
            delta_mass_kg: f.delta_mass_kg,
            ref_frame: f.ref_frame,
            dv_km_s: vec3(f.dv_km_s),
        }
    }
}

impl From<Opm> for OpmFields {
    fn from(o: Opm) -> Self {
        Self {
            ccsds_opm_vers: o.ccsds_opm_vers,
            comments: o.comments,
            classification: o.classification,
            creation_date: o.creation_date,
            originator: o.originator,
            message_id: o.message_id,
            metadata: o.metadata.into(),
            state: o.state.into(),
            keplerian: o.keplerian.map(Into::into),
            spacecraft: o.spacecraft.map(Into::into),
            covariance: o.covariance.map(Into::into),
            maneuvers: o.maneuvers.into_iter().map(Into::into).collect(),
            user_defined: o
                .user_defined
                .into_iter()
                .map(|p| OpmUserDefinedFields {
                    parameter: p.parameter,
                    value: p.value,
                })
                .collect(),
            user_defined_comments: o.user_defined_comments,
        }
    }
}

impl TryFrom<OpmFields> for Opm {
    type Error = InputRefusal;

    fn try_from(f: OpmFields) -> Result<Self, InputRefusal> {
        Ok(Self {
            ccsds_opm_vers: f.ccsds_opm_vers,
            comments: f.comments,
            classification: f.classification,
            creation_date: f.creation_date,
            originator: f.originator,
            message_id: f.message_id,
            metadata: f.metadata.into(),
            state: f.state.into(),
            keplerian: f.keplerian.map(Into::into),
            spacecraft: f.spacecraft.map(Into::into),
            covariance: f.covariance.map(OpmCovariance::try_from).transpose()?,
            maneuvers: f.maneuvers.into_iter().map(Into::into).collect(),
            user_defined: f
                .user_defined
                .into_iter()
                .map(|p| OpmUserDefined {
                    parameter: p.parameter,
                    value: p.value,
                })
                .collect(),
            user_defined_comments: f.user_defined_comments,
        })
    }
}

fn parse_result<'a>(env: Env<'a>, result: Result<Opm, OpmError>) -> Term<'a> {
    match result {
        Ok(parsed) => (atoms::ok(), OpmFields::from(parsed)).encode(env),
        Err(e) => (atoms::error(), opm_error_term(env, &e)).encode(env),
    }
}

/// Parse a CCSDS OPM in KVN encoding.
#[rustler::nif(schedule = "DirtyCpu")]
fn opm_parse_kvn<'a>(env: Env<'a>, text: String) -> Term<'a> {
    parse_result(env, core_opm::parse_kvn(&text))
}

/// Parse a CCSDS OPM in XML encoding.
#[rustler::nif(schedule = "DirtyCpu")]
fn opm_parse_xml<'a>(env: Env<'a>, text: String) -> Term<'a> {
    parse_result(env, core_opm::parse_xml(&text))
}

/// `{:ok, text}`; `{:error, {:invalid_length, :"covariance.lower_triangle",
/// 21, got}}` for a covariance that does not hold exactly 21 lower-triangle
/// values, or `{:error, reason}` with the typed term for a message the writer
/// refuses.
fn encode_result<'a>(
    env: Env<'a>,
    fields: OpmFields,
    encode: fn(&Opm) -> Result<String, OpmError>,
) -> Term<'a> {
    let opm = match Opm::try_from(fields) {
        Ok(opm) => opm,
        Err(refusal) => return (atoms::error(), refusal.term(env)).encode(env),
    };
    match encode(&opm) {
        Ok(text) => (atoms::ok(), text).encode(env),
        Err(e) => (atoms::error(), opm_error_term(env, &e)).encode(env),
    }
}

/// Serialize normalized OPM fields as CCSDS OPM KVN text.
#[rustler::nif(schedule = "DirtyCpu")]
fn opm_encode_kvn<'a>(env: Env<'a>, fields: OpmFields) -> Term<'a> {
    encode_result(env, fields, core_opm::encode_kvn)
}

/// Serialize normalized OPM fields as CCSDS OPM XML text.
#[rustler::nif(schedule = "DirtyCpu")]
fn opm_encode_xml<'a>(env: Env<'a>, fields: OpmFields) -> Term<'a> {
    encode_result(env, fields, core_opm::encode_xml)
}
