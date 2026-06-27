//! Pure Rustler glue for the Sun/Moon ephemeris and solid-earth-tide kernels.
//!
//! No domain formula lives here: the analytic Sun/Moon positions are computed by
//! `sidereon_core::astro::bodies::sun_moon_ecef` and the tidal displacement by
//! `sidereon_core::tides::solid_earth_tide`. These entry points decode the
//! Elixir terms, build the crate `TimeScales`, call the crate functions, and
//! encode the results back.

use rustler::{NifResult, Term};

use sidereon_core::astro::bodies::sun_moon_ecef;
use sidereon_core::astro::time::scales::TimeScales;
use sidereon_core::tides::solid_earth_tide;

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
