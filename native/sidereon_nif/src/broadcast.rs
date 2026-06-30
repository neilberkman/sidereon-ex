//! Rustler boundary for the `sidereon-core` broadcast-navigation product.
//!
//! Pure glue: `broadcast_parse/1` decodes RINEX navigation text, calls
//! [`BroadcastEphemeris::from_nav`], and returns a resource handle holding the
//! parsed records. `broadcast_position/4` evaluates one satellite's orbit and
//! clock at an instant via the crate's [`EphemerisSource`] contract; the
//! single-point-positioning solve consumes the same handle via
//! `spp::spp_solve_broadcast/15`. No parsing grammar or orbit math lives here.

use rustler::{Encoder, Env, Error, NifResult, ResourceArc, Term};
use sidereon_core::ephemeris::{BroadcastEphemeris, EphemerisSource};
use sidereon_core::rinex::nav::{encode_nav, parse_leap_seconds, KlobucharAlphaBeta, NavMessage};
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
        NavMessage::GalileoInav => "galileo_inav",
        NavMessage::GalileoFnav => "galileo_fnav",
        NavMessage::BeidouD1 => "beidou_d1",
        NavMessage::BeidouD2 => "beidou_d2",
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
            let elements = record.elements;
            let clock = record.clock;
            (
                record.satellite_id.to_string(),
                nav_message_label(record.message),
                record.week,
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
                ],
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
/// that onto each system's own time — BDT for BeiDou, UTC-referenced for GLONASS
/// — internally). Returns `{x_m, y_m, z_m, clock_s}` — ECEF meters and the
/// satellite clock offset in seconds — or the atom `nil` when the product has no
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
