//! Rustler boundary for GNSS/astronomical time-scale offsets.
//!
//! Pure glue over `sidereon_core::astro::time`: it maps a time-scale
//! abbreviation onto the core [`TimeScale`], calls the relocated offset
//! functions, and encodes `{:ok, seconds}` / `{:error, reason}`. The offset
//! algebra (atomic constants, leap-second resolution) lives in the crate.

use rustler::{Encoder, Env, Term};
use sidereon_core::astro::time::civil;
use sidereon_core::astro::time::model::{Instant, TimeScale};
use sidereon_core::astro::time::scales::{
    find_leap_seconds, julian_day_number, leap_second_table, ut1_coverage,
};
use sidereon_core::astro::time::{timescale_offset_at_s, timescale_offset_s, TimeOffsetError};

mod atoms {
    rustler::atoms! {
        ok,
        error,
        unknown_time_scale,
        epoch_required,
        unsupported,
        non_finite_epoch,
        invalid_instant
    }
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
fn civil_day_of_year(
    year: i32,
    month: i32,
    day: i32,
    hour: i32,
    minute: i32,
    second: f64,
) -> f64 {
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
