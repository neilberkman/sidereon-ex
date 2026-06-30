//! Rustler boundary for RINEX clock products.
//!
//! This module is glue only: it decodes Erlang terms, calls the
//! `sidereon-core` RINEX clock parser/interpolator, and encodes the public
//! Sidereon series shape back to Elixir.

use rustler::{Encoder, Env, NifResult, Term};
use sidereon_core::rinex::clock::{ClockEpoch, RinexClock};

mod atoms {
    rustler::atoms! {
        ok,
        error,
        no_clock
    }
}

/// Parse RINEX clock text into `[{"G05", [{gps_seconds, bias_s}, ...]}, ...]`.
#[rustler::nif(schedule = "DirtyCpu")]
fn rinex_clock_parse<'a>(env: Env<'a>, text: String) -> Term<'a> {
    match RinexClock::parse(&text) {
        Ok(clock) => (atoms::ok(), clock.series_rows()).encode(env),
        Err(err) => (atoms::error(), err.to_string()).encode(env),
    }
}

/// Parse RINEX clock text while skipping malformed and non-`AS` rows.
#[rustler::nif(schedule = "DirtyCpu")]
fn rinex_clock_parse_lossy<'a>(env: Env<'a>, text: String) -> Term<'a> {
    let clock = RinexClock::parse_lossy(&text);
    (atoms::ok(), clock.series_rows()).encode(env)
}

/// Serialize RINEX clock rows into RINEX clock text.
#[rustler::nif(schedule = "DirtyCpu")]
fn rinex_clock_to_string<'a>(
    env: Env<'a>,
    series: Vec<(String, Vec<(f64, f64)>)>,
) -> Term<'a> {
    match RinexClock::from_series_rows(series) {
        Ok(clock) => (atoms::ok(), clock.to_rinex_string()).encode(env),
        Err(err) => (atoms::error(), err.to_string()).encode(env),
    }
}

/// Interpolate one satellite clock from the public series row shape.
#[rustler::nif]
fn rinex_clock_clock_s<'a>(
    env: Env<'a>,
    series: Vec<(String, Vec<(f64, f64)>)>,
    satellite_id: String,
    datetime_tuple: Term<'a>,
) -> NifResult<Term<'a>> {
    let Some((year, month, day, hour, minute, second)) = decode_datetime(datetime_tuple)? else {
        return Ok((atoms::error(), atoms::no_clock()).encode(env));
    };

    let clock = RinexClock::from_series_rows(series).map_err(crate::errors::invalid_input)?;
    let epoch = ClockEpoch {
        year,
        month,
        day,
        hour,
        minute,
        second,
    };
    match clock
        .clock_s(&satellite_id, epoch)
        .map_err(crate::errors::invalid_input)?
    {
        Some(bias_s) => Ok((atoms::ok(), bias_s).encode(env)),
        None => Ok((atoms::error(), atoms::no_clock()).encode(env)),
    }
}

#[allow(clippy::type_complexity)]
fn decode_datetime(term: Term) -> NifResult<Option<(i32, u8, u8, u8, u8, f64)>> {
    #[allow(clippy::type_complexity)]
    let ((year, month, day), (hour, minute, second, microsecond)): (
        (i32, i32, i32),
        (i32, i32, i32, i32),
    ) = term.decode()?;

    let Ok(month) = u8::try_from(month) else {
        return Ok(None);
    };
    let Ok(day) = u8::try_from(day) else {
        return Ok(None);
    };
    let Ok(hour) = u8::try_from(hour) else {
        return Ok(None);
    };
    let Ok(minute) = u8::try_from(minute) else {
        return Ok(None);
    };
    if second < 0 || microsecond < 0 {
        return Ok(None);
    }

    let second = second as f64 + microsecond as f64 / 1_000_000.0;
    Ok(Some((year, month, day, hour, minute, second)))
}
