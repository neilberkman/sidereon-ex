//! Pure Rustler glue for the Sun/Moon ephemeris and solid-earth-tide kernels.
//!
//! No domain formula lives here: the analytic Sun/Moon positions are computed by
//! `sidereon_core::astro::bodies::sun_moon_ecef` and the tidal displacement by
//! `sidereon_core::tides::solid_earth_tide`. These entry points decode the
//! Elixir terms, build the crate `TimeScales`, call the crate functions, and
//! encode the results back.

use chrono::{DateTime, Datelike, Timelike, Utc};
use rustler::{Error, NifResult, Term};

use sidereon_core::astro::bodies::{sun_moon_ecef, sun_moon_eci_at};
use sidereon_core::astro::time::scales::TimeScales;
use sidereon_core::tides::{ocean_tide_loading, solid_earth_pole_tide, solid_earth_tide, OceanLoadingBlq};

type DateTuple = (i32, i32, i32);
type TimeTuple = (i32, i32, i32, i32);
type Vec3 = (f64, f64, f64);

fn parse_datetime_tuple(term: Term) -> NifResult<(i32, i32, i32, i32, i32, i32, i32)> {
    let (date, time): (DateTuple, TimeTuple) = term.decode()?;
    Ok((date.0, date.1, date.2, time.0, time.1, time.2, time.3))
}

/// Geocentric Sun and Moon positions in ECEF (m) for a UTC instant.
/// Returns `({sun_x, sun_y, sun_z}, {moon_x, moon_y, moon_z})`.
pub(crate) fn sun_moon_ecef_impl(datetime_tuple: Term) -> NifResult<(Vec3, Vec3)> {
    let (year, month, day, hour, minute, second, microsecond) =
        parse_datetime_tuple(datetime_tuple)?;
    let second_with_micro = second as f64 + microsecond as f64 / 1_000_000.0;
    let ts = TimeScales::from_utc(year, month, day, hour, minute, second_with_micro)
        .map_err(crate::errors::invalid_input)?;
    let sm = sun_moon_ecef(&ts).map_err(crate::errors::invalid_input)?;
    Ok((
        (sm.sun[0], sm.sun[1], sm.sun[2]),
        (sm.moon[0], sm.moon[1], sm.moon[2]),
    ))
}

/// Batch geocentric Sun and Moon positions in ECI (m) for UTC Unix microseconds.
pub(crate) fn sun_moon_eci_batch_impl(epochs_unix_us: Vec<i64>) -> NifResult<(Vec<Vec3>, Vec<Vec3>)> {
    sun_moon_batch(epochs_unix_us, |ts| sun_moon_eci_at(ts).map_err(crate::errors::invalid_input))
}

/// Batch geocentric Sun and Moon positions in ECEF (m) for UTC Unix microseconds.
pub(crate) fn sun_moon_ecef_batch_impl(epochs_unix_us: Vec<i64>) -> NifResult<(Vec<Vec3>, Vec<Vec3>)> {
    sun_moon_batch(epochs_unix_us, |ts| sun_moon_ecef(ts).map_err(crate::errors::invalid_input))
}

fn sun_moon_batch<F>(epochs_unix_us: Vec<i64>, mut f: F) -> NifResult<(Vec<Vec3>, Vec<Vec3>)>
where
    F: FnMut(&TimeScales) -> NifResult<sidereon_core::astro::bodies::SunMoon>,
{
    if epochs_unix_us.is_empty() {
        return Err(Error::Term(Box::new("empty epochs")));
    }

    let mut sun = Vec::with_capacity(epochs_unix_us.len());
    let mut moon = Vec::with_capacity(epochs_unix_us.len());

    for epoch_us in epochs_unix_us {
        let ts = time_scales_from_unix_micros(epoch_us)?;
        let sm = f(&ts)?;
        sun.push((sm.sun[0], sm.sun[1], sm.sun[2]));
        moon.push((sm.moon[0], sm.moon[1], sm.moon[2]));
    }

    Ok((sun, moon))
}

fn time_scales_from_unix_micros(epoch_us: i64) -> NifResult<TimeScales> {
    let seconds = epoch_us.div_euclid(1_000_000);
    let micros = epoch_us.rem_euclid(1_000_000) as u32;
    let dt = DateTime::<Utc>::from_timestamp(seconds, micros * 1_000)
        .ok_or_else(|| Error::Term(Box::new("invalid Unix microsecond epoch")))?;
    TimeScales::from_utc(
        dt.year(),
        dt.month() as i32,
        dt.day() as i32,
        dt.hour() as i32,
        dt.minute() as i32,
        dt.second() as f64 + f64::from(dt.timestamp_subsec_micros()) / 1_000_000.0,
    )
    .map_err(crate::errors::invalid_input)
}

/// Solid-earth tide station displacement (m, ECEF), IERS DEHANTTIDEINEL derived
/// kernel. Sun and Moon geocentric positions are supplied by the caller (m).
#[allow(clippy::too_many_arguments)]
pub(crate) fn solid_earth_tide_impl(
    sta_x: f64,
    sta_y: f64,
    sta_z: f64,
    year: i32,
    month: i32,
    day: i32,
    fhr: f64,
    sun: Vec3,
    moon: Vec3,
) -> NifResult<Vec3> {
    let xsta = [sta_x, sta_y, sta_z];
    let xsun = [sun.0, sun.1, sun.2];
    let xmon = [moon.0, moon.1, moon.2];
    let d = solid_earth_tide(&xsta, year, month, day, fhr, &xsun, &xmon)
        .map_err(crate::errors::invalid_input)?;
    Ok((d[0], d[1], d[2]))
}

/// Solid-earth pole tide station displacement (m, ECEF).
#[allow(clippy::too_many_arguments)]
pub(crate) fn solid_earth_pole_tide_impl(
    sta_x: f64,
    sta_y: f64,
    sta_z: f64,
    year: i32,
    month: i32,
    day: i32,
    fhr: f64,
    xp_arcsec: f64,
    yp_arcsec: f64,
) -> NifResult<Vec3> {
    let xsta = [sta_x, sta_y, sta_z];
    let d = solid_earth_pole_tide(&xsta, year, month, day, fhr, xp_arcsec, yp_arcsec)
        .map_err(crate::errors::invalid_input)?;
    Ok((d[0], d[1], d[2]))
}

/// Ocean tide loading station displacement (m, ECEF).
#[allow(clippy::too_many_arguments)]
pub(crate) fn ocean_tide_loading_impl(
    sta_x: f64,
    sta_y: f64,
    sta_z: f64,
    year: i32,
    month: i32,
    day: i32,
    fhr: f64,
    amplitude_m: Vec<Vec<f64>>,
    phase_deg: Vec<Vec<f64>>,
) -> NifResult<Vec3> {
    let blq = ocean_loading_blq(amplitude_m, phase_deg)?;
    let xsta = [sta_x, sta_y, sta_z];
    let d = ocean_tide_loading(&xsta, year, month, day, fhr, &blq)
        .map_err(crate::errors::invalid_input)?;
    Ok((d[0], d[1], d[2]))
}

fn ocean_loading_blq(
    amplitude_m: Vec<Vec<f64>>,
    phase_deg: Vec<Vec<f64>>,
) -> NifResult<OceanLoadingBlq> {
    Ok(OceanLoadingBlq {
        amplitude_m: fixed_3x11(amplitude_m, "ocean loading amplitude")?,
        phase_deg: fixed_3x11(phase_deg, "ocean loading phase")?,
    })
}

fn fixed_3x11(rows: Vec<Vec<f64>>, field: &'static str) -> NifResult<[[f64; 11]; 3]> {
    if rows.len() != 3 || rows.iter().any(|row| row.len() != 11) {
        return Err(Error::Term(Box::new(format!("{field} must be 3x11"))));
    }

    let mut out = [[0.0_f64; 11]; 3];
    for (i, row) in rows.into_iter().enumerate() {
        for (j, value) in row.into_iter().enumerate() {
            out[i][j] = value;
        }
    }
    Ok(out)
}
