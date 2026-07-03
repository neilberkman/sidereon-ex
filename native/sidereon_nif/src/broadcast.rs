//! Rustler boundary for the `sidereon-core` broadcast-navigation product.
//!
//! Pure glue: `broadcast_parse/1` decodes RINEX navigation text, calls
//! [`BroadcastEphemeris::from_nav`], and returns a resource handle holding the
//! parsed records. `broadcast_position/4` evaluates one satellite's orbit and
//! clock at an instant via the crate's [`EphemerisSource`] contract; the
//! single-point-positioning solve consumes the same handle via
//! `spp::spp_solve_broadcast/15`. No parsing grammar or orbit math lives here.

use rustler::{Encoder, Env, Error, NifResult, ResourceArc, Term};
use sidereon_core::astro::time::model::{GnssWeekTow, TimeScale};
use sidereon_core::ephemeris::{BroadcastEphemeris, BroadcastIssue, EphemerisSource};
use sidereon_core::rinex::nav::{
    cnav_ura_ned_m, cnav_ura_nominal_m, encode_nav, parse_leap_seconds, BroadcastGroupDelays,
    CnavParameters, CnavSignal, KlobucharAlphaBeta, NavMessage, NavMessagePreference,
};
use sidereon_core::{GnssSatelliteId, GnssSystem};

/// Resource handle holding a parsed broadcast-navigation product across calls.
pub struct BroadcastResource {
    pub store: BroadcastEphemeris,
    pub leap_seconds: Option<f64>,
}

type Vec3Tuple = (f64, f64, f64);
type ElementsList = Vec<f64>;
type ClockTuple = (f64, f64, f64, f64);
type RecordMetaTuple = (f64, f64, f64, Option<f64>);
type BroadcastRecordTuple = (
    String,
    &'static str,
    u32,
    ElementsList,
    ClockTuple,
    RecordMetaTuple,
);
type GlonassMetaTuple = (f64, f64, f64, i32);
type GlonassRecordTuple = (
    String,
    f64,
    Vec3Tuple,
    Vec3Tuple,
    Vec3Tuple,
    GlonassMetaTuple,
);
type KlobucharTuple = (Vec<f64>, Vec<f64>);

#[derive(Debug, Clone, rustler::NifMap)]
struct WeekTowTerm {
    system: String,
    week: u32,
    tow_s: f64,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct IssueTerm {
    issue: u32,
    message: String,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct GroupDelaysTerm {
    gps_tgd_s: Option<f64>,
    galileo_bgd_e5a_e1_s: Option<f64>,
    galileo_bgd_e5b_e1_s: Option<f64>,
    beidou_tgd1_s: Option<f64>,
    beidou_tgd2_s: Option<f64>,
    cnav_isc_l1ca_s: Option<f64>,
    cnav_isc_l2c_s: Option<f64>,
    cnav_isc_l5i5_s: Option<f64>,
    cnav_isc_l5q5_s: Option<f64>,
    cnav_isc_l1cd_s: Option<f64>,
    cnav_isc_l1cp_s: Option<f64>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct CnavTerm {
    adot_m_s: f64,
    delta_n0_dot_rad_s2: f64,
    top: WeekTowTerm,
    ura_ed_index: i64,
    ura_ed_nominal_m: Option<f64>,
    ura_ned0_index: i64,
    ura_ned0_nominal_m: Option<f64>,
    ura_ned1_index: i64,
    ura_ned2_index: i64,
    transmission_time_sow: f64,
    flags: Option<u32>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct CnavCorrectionsTerm {
    l1ca_s: Option<f64>,
    l2c_s: Option<f64>,
    l5i5_s: Option<f64>,
    l5q5_s: Option<f64>,
    l1cp_s: Option<f64>,
    l1cd_s: Option<f64>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct BroadcastRecordDetailTerm {
    satellite_id: String,
    message: String,
    issue_of_data: IssueTerm,
    week: u32,
    toe: WeekTowTerm,
    toc: WeekTowTerm,
    elements: ElementsList,
    clock: ClockTuple,
    group_delays: GroupDelaysTerm,
    cnav: Option<CnavTerm>,
    cnav_corrections: CnavCorrectionsTerm,
    group_delay_s: f64,
    sv_health: f64,
    sv_accuracy_m: f64,
    fit_interval_s: Option<f64>,
}

#[rustler::resource_impl]
impl rustler::Resource for BroadcastResource {}

/// Map a GNSS single-letter system identifier (e.g. `"G"`) onto the crate's
/// [`GnssSystem`]. Pure identifier translation; mirrors `sp3::system_from_letter`.
fn system_from_letter(letter: &str) -> NifResult<GnssSystem> {
    let c = letter
        .chars()
        .next()
        .ok_or_else(|| Error::Term(Box::new("empty GNSS system letter")))?;
    GnssSystem::from_letter(c)
        .ok_or_else(|| Error::Term(Box::new(format!("unknown GNSS system letter {letter:?}"))))
}

fn nav_message_label(message: NavMessage) -> &'static str {
    match message {
        NavMessage::GpsLnav => "gps_lnav",
        NavMessage::GpsCnav => "gps_cnav",
        NavMessage::GpsCnav2 => "gps_cnav2",
        NavMessage::QzssCnav => "qzss_cnav",
        NavMessage::QzssCnav2 => "qzss_cnav2",
        NavMessage::GalileoInav => "galileo_inav",
        NavMessage::GalileoFnav => "galileo_fnav",
        NavMessage::BeidouD1 => "beidou_d1",
        NavMessage::BeidouD2 => "beidou_d2",
    }
}

fn nav_message_preference_label(preference: NavMessagePreference) -> &'static str {
    match preference {
        NavMessagePreference::PreferLegacy => "legacy",
        NavMessagePreference::PreferModern => "modern",
    }
}

fn nav_message_preference(label: &str) -> NifResult<NavMessagePreference> {
    match label {
        "legacy" => Ok(NavMessagePreference::PreferLegacy),
        "modern" => Ok(NavMessagePreference::PreferModern),
        _ => Err(Error::Term(Box::new(
            "invalid broadcast message preference",
        ))),
    }
}

fn time_scale_label(scale: TimeScale) -> String {
    scale.abbrev().to_string()
}

fn week_tow_term(time: GnssWeekTow) -> WeekTowTerm {
    WeekTowTerm {
        system: time_scale_label(time.system),
        week: time.week,
        tow_s: time.tow_s,
    }
}

fn issue_term(issue: BroadcastIssue) -> IssueTerm {
    IssueTerm {
        issue: issue.issue,
        message: nav_message_label(issue.message).to_string(),
    }
}

fn group_delays_term(delays: BroadcastGroupDelays) -> GroupDelaysTerm {
    GroupDelaysTerm {
        gps_tgd_s: delays.gps_tgd_s,
        galileo_bgd_e5a_e1_s: delays.galileo_bgd_e5a_e1_s,
        galileo_bgd_e5b_e1_s: delays.galileo_bgd_e5b_e1_s,
        beidou_tgd1_s: delays.beidou_tgd1_s,
        beidou_tgd2_s: delays.beidou_tgd2_s,
        cnav_isc_l1ca_s: delays.cnav_isc_l1ca_s,
        cnav_isc_l2c_s: delays.cnav_isc_l2c_s,
        cnav_isc_l5i5_s: delays.cnav_isc_l5i5_s,
        cnav_isc_l5q5_s: delays.cnav_isc_l5q5_s,
        cnav_isc_l1cd_s: delays.cnav_isc_l1cd_s,
        cnav_isc_l1cp_s: delays.cnav_isc_l1cp_s,
    }
}

fn cnav_term(cnav: CnavParameters) -> CnavTerm {
    CnavTerm {
        adot_m_s: cnav.adot_m_s,
        delta_n0_dot_rad_s2: cnav.delta_n0_dot_rad_s2,
        top: week_tow_term(cnav.top),
        ura_ed_index: i64::from(cnav.ura_ed_index),
        ura_ed_nominal_m: cnav_ura_nominal_m(cnav.ura_ed_index),
        ura_ned0_index: i64::from(cnav.ura_ned0_index),
        ura_ned0_nominal_m: cnav_ura_nominal_m(cnav.ura_ned0_index),
        ura_ned1_index: i64::from(cnav.ura_ned1_index),
        ura_ned2_index: i64::from(cnav.ura_ned2_index),
        transmission_time_sow: cnav.transmission_time_sow,
        flags: cnav.flags,
    }
}

fn cnav_corrections_term(delays: BroadcastGroupDelays) -> CnavCorrectionsTerm {
    CnavCorrectionsTerm {
        l1ca_s: delays.cnav_single_frequency_correction_s(CnavSignal::L1Ca),
        l2c_s: delays.cnav_single_frequency_correction_s(CnavSignal::L2C),
        l5i5_s: delays.cnav_single_frequency_correction_s(CnavSignal::L5I5),
        l5q5_s: delays.cnav_single_frequency_correction_s(CnavSignal::L5Q5),
        l1cp_s: delays.cnav_single_frequency_correction_s(CnavSignal::L1Cp),
        l1cd_s: delays.cnav_single_frequency_correction_s(CnavSignal::L1Cd),
    }
}

fn elements_list(record: &sidereon_core::ephemeris::BroadcastRecord) -> ElementsList {
    let elements = record.elements;
    vec![
        elements.sqrt_a,
        elements.e,
        elements.m0,
        elements.delta_n,
        elements.omega0,
        elements.i0,
        elements.omega,
        elements.omega_dot,
        elements.idot,
        elements.cuc,
        elements.cus,
        elements.crc,
        elements.crs,
        elements.cic,
        elements.cis,
        elements.toe_sow,
    ]
}

fn clock_tuple(record: &sidereon_core::ephemeris::BroadcastRecord) -> ClockTuple {
    let clock = record.clock;
    (clock.af0, clock.af1, clock.af2, clock.toc_sow)
}

fn record_detail_term(
    record: &sidereon_core::ephemeris::BroadcastRecord,
) -> BroadcastRecordDetailTerm {
    BroadcastRecordDetailTerm {
        satellite_id: record.satellite_id.to_string(),
        message: nav_message_label(record.message).to_string(),
        issue_of_data: issue_term(record.issue_of_data),
        week: record.week,
        toe: week_tow_term(record.toe),
        toc: week_tow_term(record.toc),
        elements: elements_list(record),
        clock: clock_tuple(record),
        group_delays: group_delays_term(record.group_delays),
        cnav: record.cnav.map(cnav_term),
        cnav_corrections: cnav_corrections_term(record.group_delays),
        group_delay_s: record.broadcast_clock_group_delay_s(),
        sv_health: record.sv_health,
        sv_accuracy_m: record.sv_accuracy_m,
        fit_interval_s: record.fit_interval_s,
    }
}

fn alpha_beta_tuple(coeffs: KlobucharAlphaBeta) -> KlobucharTuple {
    (coeffs.alpha.to_vec(), coeffs.beta.to_vec())
}

/// Parse RINEX 3.x/4.xx navigation text into a broadcast-ephemeris resource handle.
///
/// Dirty-CPU: parsing a full daily multi-GNSS file is unbounded relative to the
/// 1 ms NIF budget. On a malformed file returns the parser's error as a term.
#[rustler::nif(schedule = "DirtyCpu")]
fn broadcast_parse(text: String) -> NifResult<ResourceArc<BroadcastResource>> {
    let store =
        BroadcastEphemeris::from_nav(&text).map_err(|e| Error::Term(Box::new(e.to_string())))?;
    let leap_seconds = parse_leap_seconds(&text).map_err(crate::errors::invalid_input)?;
    Ok(ResourceArc::new(BroadcastResource {
        store,
        leap_seconds,
    }))
}

/// Parse RINEX navigation text and choose the GPS/QZSS mixed-store preference.
#[rustler::nif(schedule = "DirtyCpu")]
fn broadcast_parse_with_preference(
    text: String,
    message_preference: String,
) -> NifResult<ResourceArc<BroadcastResource>> {
    let preference = nav_message_preference(&message_preference)?;
    let mut store =
        BroadcastEphemeris::from_nav(&text).map_err(|e| Error::Term(Box::new(e.to_string())))?;
    store.set_message_preference(preference);
    let leap_seconds = parse_leap_seconds(&text).map_err(crate::errors::invalid_input)?;
    Ok(ResourceArc::new(BroadcastResource {
        store,
        leap_seconds,
    }))
}

/// Number of usable GPS, Galileo, and BeiDou records held by the parsed product.
#[rustler::nif]
fn broadcast_record_count(handle: ResourceArc<BroadcastResource>) -> u64 {
    handle.store.records().len() as u64
}

/// Serialize the held GPS/Galileo/BeiDou broadcast records to RINEX 3
/// navigation text. Pure delegation to `rinex::nav::encode_nav` over the records
/// the store already holds; re-parsing the output reconstructs the same records.
/// No serialization grammar lives here.
#[rustler::nif(schedule = "DirtyCpu")]
fn broadcast_encode_nav(handle: ResourceArc<BroadcastResource>) -> String {
    encode_nav(handle.store.records())
}

/// Number of healthy GLONASS state-vector records held by the parsed product.
#[rustler::nif]
fn broadcast_glonass_record_count(handle: ResourceArc<BroadcastResource>) -> u64 {
    handle.store.glonass_records().len() as u64
}

/// Usable GPS, Galileo, and BeiDou broadcast records in file order.
#[rustler::nif]
fn broadcast_records(handle: ResourceArc<BroadcastResource>) -> Vec<BroadcastRecordTuple> {
    handle
        .store
        .records()
        .iter()
        .map(|record| {
            let clock = record.clock;
            (
                record.satellite_id.to_string(),
                nav_message_label(record.message),
                record.week,
                elements_list(record),
                (clock.af0, clock.af1, clock.af2, clock.toc_sow),
                (
                    record.broadcast_clock_group_delay_s(),
                    record.sv_health,
                    record.sv_accuracy_m,
                    record.fit_interval_s,
                ),
            )
        })
        .collect()
}

/// Usable GPS, Galileo, BeiDou, and CNAV-family broadcast records with every
/// core field the binding exposes.
#[rustler::nif]
fn broadcast_records_detailed(
    handle: ResourceArc<BroadcastResource>,
) -> Vec<BroadcastRecordDetailTerm> {
    handle
        .store
        .records()
        .iter()
        .map(record_detail_term)
        .collect()
}

/// The GPS/QZSS legacy-vs-CNAV selection preference active on this handle.
#[rustler::nif]
fn broadcast_message_preference(handle: ResourceArc<BroadcastResource>) -> &'static str {
    nav_message_preference_label(handle.store.message_preference())
}

/// Healthy GLONASS state-vector broadcast records in file order.
#[rustler::nif]
fn broadcast_glonass_records(handle: ResourceArc<BroadcastResource>) -> Vec<GlonassRecordTuple> {
    handle
        .store
        .glonass_records()
        .iter()
        .map(|record| {
            (
                record.satellite_id.to_string(),
                record.toe_utc_j2000_s,
                (record.pos_m[0], record.pos_m[1], record.pos_m[2]),
                (record.vel_m_s[0], record.vel_m_s[1], record.vel_m_s[2]),
                (record.acc_m_s2[0], record.acc_m_s2[1], record.acc_m_s2[2]),
                (
                    record.clk_bias,
                    record.gamma_n,
                    record.sv_health,
                    record.freq_channel,
                ),
            )
        })
        .collect()
}

/// Broadcast ionosphere coefficients parsed from the NAV header.
#[rustler::nif]
fn broadcast_iono_corrections(
    handle: ResourceArc<BroadcastResource>,
) -> (Option<KlobucharTuple>, Option<KlobucharTuple>) {
    let iono = handle.store.iono_corrections();
    (
        iono.gps.map(alpha_beta_tuple),
        iono.beidou.map(alpha_beta_tuple),
    )
}

/// Nominal CNAV URA meters for a URA ED/NED0 index.
#[rustler::nif]
fn broadcast_cnav_ura_nominal(index: i64) -> Option<f64> {
    i8::try_from(index).ok().and_then(cnav_ura_nominal_m)
}

/// Time-dependent CNAV URA_NED bound in meters at the supplied week/TOW.
#[rustler::nif]
fn broadcast_cnav_ura_ned(cnav: CnavTerm, system: String, week: u32, tow_s: f64) -> Option<f64> {
    let scale = match system.as_str() {
        "GPST" => TimeScale::Gpst,
        "GST" => TimeScale::Gst,
        "BDT" => TimeScale::Bdt,
        "QZSST" => TimeScale::Qzsst,
        _ => return None,
    };
    let params = CnavParameters {
        adot_m_s: cnav.adot_m_s,
        delta_n0_dot_rad_s2: cnav.delta_n0_dot_rad_s2,
        top: GnssWeekTow {
            system: scale,
            week: cnav.top.week,
            tow_s: cnav.top.tow_s,
        },
        ura_ed_index: i8::try_from(cnav.ura_ed_index).ok()?,
        ura_ned0_index: i8::try_from(cnav.ura_ned0_index).ok()?,
        ura_ned1_index: u8::try_from(cnav.ura_ned1_index).ok()?,
        ura_ned2_index: u8::try_from(cnav.ura_ned2_index).ok()?,
        transmission_time_sow: cnav.transmission_time_sow,
        flags: cnav.flags,
    };
    cnav_ura_ned_m(
        &params,
        GnssWeekTow {
            system: scale,
            week,
            tow_s,
        },
    )
}

/// GPS minus UTC leap seconds from the NAV header, if present.
#[rustler::nif]
fn broadcast_leap_seconds(handle: ResourceArc<BroadcastResource>) -> Option<f64> {
    handle.leap_seconds
}

/// Evaluate `sat`'s broadcast orbit and clock at `t_j2000_s` against a loaded
/// handle.
///
/// `t_j2000_s` is the query instant as a continuous second-of-J2000 in the
/// GPST-aligned scale the crate's [`EphemerisSource`] contract expects (it maps
/// that onto each system's own time: BDT for BeiDou, UTC-referenced for GLONASS
/// internally). Returns `{x_m, y_m, z_m, clock_s}`: ECEF meters and the
/// satellite clock offset in seconds, or the atom `nil` when the product has no
/// usable ephemeris for that satellite at that instant (the crate returns
/// `None`). The miss is encoded as an atom rather than a tuple of NaNs, which the
/// BEAM cannot represent. Pure glue over
/// [`EphemerisSource::position_clock_at_j2000_s`]; no orbit math or file I/O
/// lives here.
#[rustler::nif]
fn broadcast_position<'a>(
    env: Env<'a>,
    handle: ResourceArc<BroadcastResource>,
    system_letter: String,
    prn: u8,
    t_j2000_s: f64,
) -> NifResult<Term<'a>> {
    let system = system_from_letter(&system_letter)?;
    let sat = GnssSatelliteId::new(system, prn).map_err(crate::errors::invalid_input)?;

    match handle.store.position_clock_at_j2000_s(sat, t_j2000_s) {
        Some(([x_m, y_m, z_m], clock_s)) => Ok((x_m, y_m, z_m, clock_s).encode(env)),
        None => Ok(rustler::types::atom::nil().encode(env)),
    }
}
