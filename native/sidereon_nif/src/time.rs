//! Rustler boundary for GNSS/astronomical time-scale offsets.
//!
//! Pure glue over `sidereon_core::astro::time`: it maps a time-scale
//! abbreviation onto the core [`TimeScale`], calls the relocated offset
//! functions, and encodes `{:ok, seconds}` / `{:error, reason}`. The offset
//! algebra (atomic constants, leap-second resolution) lives in the crate.

use rustler::{Encoder, Env, ResourceArc, Term};
use sidereon_core::astro::time::civil;
use sidereon_core::astro::time::model::{Instant, TimeScale};
use sidereon_core::astro::time::scales::{
    find_leap_seconds, gps_utc_offset_s as core_gps_utc_offset_s, julian_day_number,
    leap_second_table, tai_utc_offset_s as core_tai_utc_offset_s, ut1_coverage,
};
use sidereon_core::astro::time::{timescale_offset_at_s, timescale_offset_s, TimeOffsetError};
use sidereon_core::astro::time::{ExactEpoch, ExactEpochQuery};

mod atoms {
    rustler::atoms! {
        ok,
        error,
        unknown_time_scale,
        epoch_required,
        unsupported,
        non_finite_epoch,
        invalid_instant,
        invalid_exact_epoch,
        less,
        equal,
        greater
    }
}

pub struct ExactEpochResource {
    pub epoch: ExactEpoch,
}

#[rustler::resource_impl]
impl rustler::Resource for ExactEpochResource {}

pub struct ExactEpochQueryResource {
    pub query: ExactEpochQuery,
}

#[rustler::resource_impl]
impl rustler::Resource for ExactEpochQueryResource {}

fn encode_exact_epoch<'a>(env: Env<'a>, epoch: ExactEpoch) -> Term<'a> {
    (atoms::ok(), ResourceArc::new(ExactEpochResource { epoch })).encode(env)
}

fn encode_exact_query<'a>(env: Env<'a>, query: ExactEpochQuery) -> Term<'a> {
    (
        atoms::ok(),
        ResourceArc::new(ExactEpochQueryResource { query }),
    )
        .encode(env)
}

#[rustler::nif]
fn exact_epoch_from_civil<'a>(
    env: Env<'a>,
    year: i32,
    month: i32,
    day: i32,
    hour: i32,
    minute: i32,
    second: f64,
) -> Term<'a> {
    match ExactEpoch::from_civil(year, month, day, hour, minute, second) {
        Some(epoch) => encode_exact_epoch(env, epoch),
        None => (atoms::error(), atoms::invalid_exact_epoch()).encode(env),
    }
}

#[rustler::nif]
fn exact_epoch_new<'a>(env: Env<'a>, seconds: i64, attoseconds: u64) -> Term<'a> {
    match ExactEpoch::new(seconds, attoseconds) {
        Some(epoch) => encode_exact_epoch(env, epoch),
        None => (atoms::error(), atoms::invalid_exact_epoch()).encode(env),
    }
}

#[rustler::nif]
fn exact_epoch_from_j2000_seconds<'a>(env: Env<'a>, seconds: f64) -> Term<'a> {
    match ExactEpoch::from_j2000_seconds(seconds) {
        Some(epoch) => encode_exact_epoch(env, epoch),
        None => (atoms::error(), atoms::invalid_exact_epoch()).encode(env),
    }
}

#[rustler::nif]
fn exact_epoch_fields(
    handle: rustler::ResourceArc<ExactEpochResource>,
) -> (i64, u64, (i64, u16), f64) {
    let epoch = handle.epoch;
    (
        epoch.whole_seconds(),
        epoch.attoseconds(),
        epoch.sub_attosecond(),
        epoch.j2000_seconds(),
    )
}

#[rustler::nif]
fn exact_epoch_seconds_since(
    later: rustler::ResourceArc<ExactEpochResource>,
    earlier: rustler::ResourceArc<ExactEpochResource>,
) -> f64 {
    later.epoch.seconds_since(earlier.epoch)
}

#[rustler::nif]
fn exact_epoch_checked_add_seconds<'a>(
    env: Env<'a>,
    handle: rustler::ResourceArc<ExactEpochResource>,
    seconds: f64,
) -> Term<'a> {
    match handle.epoch.checked_add_seconds(seconds) {
        Some(epoch) => encode_exact_epoch(env, epoch),
        None => (atoms::error(), atoms::invalid_exact_epoch()).encode(env),
    }
}

#[rustler::nif]
fn exact_epoch_checked_sub_seconds<'a>(
    env: Env<'a>,
    handle: rustler::ResourceArc<ExactEpochResource>,
    seconds: f64,
) -> Term<'a> {
    match handle.epoch.checked_sub_seconds(seconds) {
        Some(epoch) => encode_exact_epoch(env, epoch),
        None => (atoms::error(), atoms::invalid_exact_epoch()).encode(env),
    }
}

#[rustler::nif]
fn exact_epoch_split_julian_date(handle: rustler::ResourceArc<ExactEpochResource>) -> (f64, f64) {
    handle.epoch.split_julian_date()
}

#[rustler::nif]
fn exact_epoch_compare(
    later: rustler::ResourceArc<ExactEpochResource>,
    earlier: rustler::ResourceArc<ExactEpochResource>,
) -> rustler::Atom {
    match later.epoch.cmp(&earlier.epoch) {
        std::cmp::Ordering::Less => atoms::less(),
        std::cmp::Ordering::Equal => atoms::equal(),
        std::cmp::Ordering::Greater => atoms::greater(),
    }
}

#[rustler::nif]
fn exact_epoch_query(
    handle: rustler::ResourceArc<ExactEpochResource>,
) -> rustler::ResourceArc<ExactEpochQueryResource> {
    rustler::ResourceArc::new(ExactEpochQueryResource {
        query: handle.epoch.query(),
    })
}

#[rustler::nif]
fn exact_epoch_query_from_binary_j2000_seconds<'a>(env: Env<'a>, seconds: f64) -> Term<'a> {
    match ExactEpoch::from_binary_j2000_seconds(seconds) {
        Some(query) => encode_exact_query(env, query),
        None => (atoms::error(), atoms::invalid_exact_epoch()).encode(env),
    }
}

#[rustler::nif]
fn exact_epoch_query_epoch(
    handle: rustler::ResourceArc<ExactEpochQueryResource>,
) -> rustler::ResourceArc<ExactEpochResource> {
    rustler::ResourceArc::new(ExactEpochResource {
        epoch: handle.query.epoch(),
    })
}

#[rustler::nif]
fn exact_epoch_query_add_binary_seconds<'a>(
    env: Env<'a>,
    handle: rustler::ResourceArc<ExactEpochQueryResource>,
    seconds: f64,
) -> Term<'a> {
    match handle.query.clone().checked_add_binary_seconds(seconds) {
        Some(query) => encode_exact_query(env, query),
        None => (atoms::error(), atoms::invalid_exact_epoch()).encode(env),
    }
}

#[rustler::nif]
fn exact_epoch_query_sub_binary_seconds<'a>(
    env: Env<'a>,
    handle: rustler::ResourceArc<ExactEpochQueryResource>,
    seconds: f64,
) -> Term<'a> {
    match handle.query.clone().checked_sub_binary_seconds(seconds) {
        Some(query) => encode_exact_query(env, query),
        None => (atoms::error(), atoms::invalid_exact_epoch()).encode(env),
    }
}

#[rustler::nif]
fn exact_epoch_query_seconds_since(
    query: rustler::ResourceArc<ExactEpochQueryResource>,
    earlier: rustler::ResourceArc<ExactEpochResource>,
) -> f64 {
    query.query.seconds_since(earlier.epoch)
}

#[rustler::nif]
fn exact_epoch_query_seconds_since_query(
    query: rustler::ResourceArc<ExactEpochQueryResource>,
    earlier: rustler::ResourceArc<ExactEpochQueryResource>,
) -> f64 {
    query.query.seconds_since_query(&earlier.query)
}

#[rustler::nif]
fn exact_epoch_query_equal(
    left: rustler::ResourceArc<ExactEpochQueryResource>,
    right: rustler::ResourceArc<ExactEpochQueryResource>,
) -> bool {
    left.query == right.query
}

#[rustler::nif]
fn exact_epoch_query_j2000_seconds(handle: rustler::ResourceArc<ExactEpochQueryResource>) -> f64 {
    handle.query.j2000_seconds()
}

/// Map a time-scale abbreviation onto the core [`TimeScale`]. Covers every
/// scale the core knows, including the new GLONASST/QZSST GNSS scales.
fn scale_from_abbrev(abbrev: &str) -> Option<TimeScale> {
    Some(match abbrev {
        "UTC" => TimeScale::Utc,
        "TAI" => TimeScale::Tai,
        "TT" => TimeScale::Tt,
        "TDB" => TimeScale::Tdb,
        "GPST" => TimeScale::Gpst,
        "GST" => TimeScale::Gst,
        "BDT" => TimeScale::Bdt,
        "GLONASST" => TimeScale::Glonasst,
        "QZSST" => TimeScale::Qzsst,
        _ => return None,
    })
}

fn encode_offset_error<'a>(env: Env<'a>, err: TimeOffsetError) -> Term<'a> {
    let reason = match err {
        TimeOffsetError::EpochRequired(scale) => {
            (atoms::epoch_required(), scale.to_string()).encode(env)
        }
        TimeOffsetError::Unsupported(scale) => {
            (atoms::unsupported(), scale.to_string()).encode(env)
        }
        TimeOffsetError::NonFiniteEpoch(scale) => {
            (atoms::non_finite_epoch(), scale.to_string()).encode(env)
        }
    };
    (atoms::error(), reason).encode(env)
}

/// Fixed inter-system offset `to - from` in seconds for atomic scales. Errors
/// for the UTC-based scales (UTC/GLONASST), whose offset is epoch-dependent (use
/// [`timescale_offset_at`]), and for TDB.
#[rustler::nif]
fn timescale_offset<'a>(env: Env<'a>, from: String, to: String) -> Term<'a> {
    let (Some(from), Some(to)) = (scale_from_abbrev(&from), scale_from_abbrev(&to)) else {
        return (atoms::error(), atoms::unknown_time_scale()).encode(env);
    };
    match timescale_offset_s(from, to) {
        Ok(seconds) => (atoms::ok(), seconds).encode(env),
        Err(err) => encode_offset_error(env, err),
    }
}

/// Leap-aware inter-system offset `to - from` in seconds at `utc_jd` (UTC
/// Julian date). `utc_jd` only matters when a scale is UTC-based.
#[rustler::nif]
fn timescale_offset_at<'a>(env: Env<'a>, from: String, to: String, utc_jd: f64) -> Term<'a> {
    let (Some(from), Some(to)) = (scale_from_abbrev(&from), scale_from_abbrev(&to)) else {
        return (atoms::error(), atoms::unknown_time_scale()).encode(env);
    };
    match timescale_offset_at_s(from, to, utc_jd) {
        Ok(seconds) => (atoms::ok(), seconds).encode(env),
        Err(err) => encode_offset_error(env, err),
    }
}

#[rustler::nif]
fn leap_seconds(year: i32, month: i32, day: i32) -> f64 {
    leap_seconds_for_date(year, month, day)
}

fn leap_seconds_for_date(year: i32, month: i32, day: i32) -> f64 {
    let jd_utc_midnight = julian_day_number(year, month, day) as f64 - 0.5;
    find_leap_seconds(jd_utc_midnight)
}

/// GPS - UTC (the GNSS leap-second offset broadcast in the nav message, 18 s
/// from 2017) at UTC midnight on the given date.
#[rustler::nif]
fn gps_utc_offset_s(year: i32, month: i32, day: i32) -> f64 {
    core_gps_utc_offset_s(jd_utc_midnight(year, month, day))
}

/// TAI - UTC (the IERS Bulletin C quantity, 37 s from 2017) at UTC midnight on
/// the given date.
#[rustler::nif]
fn tai_utc_offset_s(year: i32, month: i32, day: i32) -> f64 {
    core_tai_utc_offset_s(jd_utc_midnight(year, month, day))
}

fn jd_utc_midnight(year: i32, month: i32, day: i32) -> f64 {
    julian_day_number(year, month, day) as f64 - 0.5
}

#[rustler::nif]
fn leap_seconds_batch(dates: Vec<(i32, i32, i32)>) -> Vec<f64> {
    dates
        .into_iter()
        .map(|(year, month, day)| leap_seconds_for_date(year, month, day))
        .collect()
}

#[rustler::nif]
fn leap_second_table_info() -> (String, i32, i32, u64) {
    let table = leap_second_table();
    (
        table.source.to_string(),
        table.first_mjd,
        table.last_mjd,
        table.entries as u64,
    )
}

#[rustler::nif]
fn ut1_coverage_info() -> (String, i32, i32, f64, f64, u64) {
    let prov = ut1_coverage();
    (
        prov.source.to_string(),
        prov.first_mjd,
        prov.last_mjd,
        prov.first_jd_tt,
        prov.last_jd_tt,
        prov.entries as u64,
    )
}

// ── civil-calendar conversions ────────────────────────────────────────────────
//
// Pure glue over `sidereon_core::astro::time::civil`: the binding marshals its
// `NaiveDateTime` / tuple epoch into civil `(year, month, day, hour, minute,
// second)` fields and these forward to the single core conversion. No calendar
// arithmetic lives on the Elixir side anymore.

/// Split Julian date `{jd_whole, fraction}` for a civil instant. Delegates to
/// [`civil::split_julian_date`].
#[rustler::nif]
fn civil_split_julian_date(
    year: i32,
    month: i32,
    day: i32,
    hour: i32,
    minute: i32,
    second: f64,
) -> (f64, f64) {
    civil::split_julian_date(year, month, day, hour, minute, second)
}

/// Continuous seconds since the J2000 epoch for a civil instant. Delegates to
/// [`civil::j2000_seconds`].
#[rustler::nif]
fn civil_j2000_seconds(
    year: i32,
    month: i32,
    day: i32,
    hour: i32,
    minute: i32,
    second: f64,
) -> f64 {
    civil::j2000_seconds(year, month, day, hour, minute, second)
}

/// Second-of-day in `[0, 86400)` from the clock fields. Delegates to
/// [`civil::second_of_day`].
#[rustler::nif]
fn civil_second_of_day(hour: i32, minute: i32, second: f64) -> f64 {
    civil::second_of_day(hour, minute, second)
}

/// Fractional day-of-year for a civil instant. Delegates to
/// [`civil::day_of_year`].
#[rustler::nif]
fn civil_day_of_year(year: i32, month: i32, day: i32, hour: i32, minute: i32, second: f64) -> f64 {
    civil::day_of_year(year, month, day, hour, minute, second)
}

/// Validated UTC instant from civil fields, returned as the split Julian date
/// `{:ok, {jd_whole, fraction}}`.
///
/// Delegates to [`Instant::from_utc_civil`], the entry the ionosphere/troposphere
/// dispatchers build their `epoch` argument from. Unlike the raw
/// [`civil_split_julian_date`] split, this path runs the core's
/// `JulianDateSplit::new` guard, so an out-of-day clock field is rejected as
/// `{:error, :invalid_instant}` rather than producing an out-of-range fraction.
#[rustler::nif]
fn civil_utc_instant_split<'a>(
    env: Env<'a>,
    year: i32,
    month: i32,
    day: i32,
    hour: i32,
    minute: i32,
    second: f64,
) -> Term<'a> {
    match Instant::from_utc_civil(year, month, day, hour, minute, second)
        .ok()
        .and_then(|instant| instant.julian_date())
    {
        Some(split) => (atoms::ok(), (split.jd_whole, split.fraction)).encode(env),
        None => (atoms::error(), atoms::invalid_instant()).encode(env),
    }
}

/// Typed sibling for callers that need the core TimeModelError fields.
#[rustler::nif]
fn civil_utc_instant_split_detailed<'a>(
    env: Env<'a>,
    year: i32,
    month: i32,
    day: i32,
    hour: i32,
    minute: i32,
    second: f64,
) -> Result<Term<'a>, rustler::Error> {
    let instant = Instant::from_utc_civil(year, month, day, hour, minute, second)
        .map_err(crate::tropo::time_model_error_detail)?;
    let split = instant
        .julian_date()
        .ok_or_else(|| rustler::Error::Term(Box::new(atoms::invalid_instant())))?;
    Ok((atoms::ok(), (split.jd_whole, split.fraction)).encode(env))
}
