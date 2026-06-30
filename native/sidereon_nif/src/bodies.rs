//! Rustler boundary for ground-observer Sun/Moon geometry.
//!
//! Pure glue over `sidereon_core::astro::bodies`: it decodes a ground station
//! (geodetic degrees / km altitude) and UTC datetime tuples, calls the crate's
//! observe/rise-set helpers, and encodes the look-angle, illumination, and
//! event results. The ephemeris, topocentric reduction, phase-angle geometry,
//! and event refinement all live in the core; no astronomy lives here.

use rustler::{Encoder, Env, Term};
use sidereon_core::astro::bodies::observe::{moon_az_el, moon_illumination, sun_az_el, BodyAzEl};
use sidereon_core::astro::bodies::rise_set::{
    find_moon_elevation_crossings, find_moon_transits, MoonElevationCrossing,
    MoonElevationCrossingKind, MoonElevationOptions, MoonTransit, MoonTransitKind,
};
use sidereon_core::astro::frames::transforms::GeodeticStationKm;
use sidereon_core::astro::passes::UtcInstant;

type DateTuple = (i32, i32, i32);
type TimeTuple = (i32, i32, i32, i32);
type AzElTerm = (f64, f64, f64);
// (unix_microseconds, kind_atom, elevation_deg)
type EventTerm<'a> = (i64, Term<'a>, f64);

mod atoms {
    rustler::atoms! {
        ok,
        error,
        invalid_input,
        rising,
        setting,
        upper,
        lower
    }
}

fn station(lat_deg: f64, lon_deg: f64, alt_km: f64) -> GeodeticStationKm {
    GeodeticStationKm {
        latitude_deg: lat_deg,
        longitude_deg: lon_deg,
        altitude_km: alt_km,
    }
}

/// Decode an Elixir `{{y,m,d},{h,min,s,us}}` UTC datetime into a [`UtcInstant`].
fn instant(datetime: Term) -> Option<UtcInstant> {
    let ((year, month, day), (hour, minute, second, microsecond)): (DateTuple, TimeTuple) =
        datetime.decode().ok()?;
    UtcInstant::from_utc(year, month, day, hour, minute, second, microsecond)
}

fn az_el_term(body: BodyAzEl) -> AzElTerm {
    (body.azimuth_deg, body.elevation_deg, body.range_km)
}

#[rustler::nif]
fn bodies_sun_az_el<'a>(
    env: Env<'a>,
    lat_deg: f64,
    lon_deg: f64,
    alt_km: f64,
    datetime: Term<'a>,
) -> Term<'a> {
    let Some(time) = instant(datetime) else {
        return (atoms::error(), atoms::invalid_input()).encode(env);
    };
    match sun_az_el(&station(lat_deg, lon_deg, alt_km), time) {
        Ok(body) => (atoms::ok(), az_el_term(body)).encode(env),
        Err(_) => (atoms::error(), atoms::invalid_input()).encode(env),
    }
}

#[rustler::nif]
fn bodies_moon_az_el<'a>(
    env: Env<'a>,
    lat_deg: f64,
    lon_deg: f64,
    alt_km: f64,
    datetime: Term<'a>,
) -> Term<'a> {
    let Some(time) = instant(datetime) else {
        return (atoms::error(), atoms::invalid_input()).encode(env);
    };
    match moon_az_el(&station(lat_deg, lon_deg, alt_km), time) {
        Ok(body) => (atoms::ok(), az_el_term(body)).encode(env),
        Err(_) => (atoms::error(), atoms::invalid_input()).encode(env),
    }
}

#[rustler::nif]
fn bodies_moon_illumination<'a>(
    env: Env<'a>,
    lat_deg: f64,
    lon_deg: f64,
    alt_km: f64,
    datetime: Term<'a>,
) -> Term<'a> {
    let Some(time) = instant(datetime) else {
        return (atoms::error(), atoms::invalid_input()).encode(env);
    };
    match moon_illumination(&station(lat_deg, lon_deg, alt_km), time) {
        Ok(illum) => (
            atoms::ok(),
            (illum.illuminated_fraction, illum.phase_angle_deg),
        )
            .encode(env),
        Err(_) => (atoms::error(), atoms::invalid_input()).encode(env),
    }
}

#[rustler::nif]
fn bodies_moon_elevation_deg<'a>(
    env: Env<'a>,
    lat_deg: f64,
    lon_deg: f64,
    alt_km: f64,
    datetime: Term<'a>,
) -> Term<'a> {
    let Some(time) = instant(datetime) else {
        return (atoms::error(), atoms::invalid_input()).encode(env);
    };
    // Route through `moon_az_el` (not the core `moon_elevation_deg`, which
    // `expect`s and would panic across the NIF on an invalid-but-finite station)
    // so a bad station surfaces as a typed `{:error, :invalid_input}`.
    match moon_az_el(&station(lat_deg, lon_deg, alt_km), time) {
        Ok(body) => (atoms::ok(), body.elevation_deg).encode(env),
        Err(_) => (atoms::error(), atoms::invalid_input()).encode(env),
    }
}

fn crossing_term<'a>(env: Env<'a>, crossing: MoonElevationCrossing) -> EventTerm<'a> {
    let kind = match crossing.kind {
        MoonElevationCrossingKind::Rising => atoms::rising().encode(env),
        MoonElevationCrossingKind::Setting => atoms::setting().encode(env),
    };
    (
        crossing.time.unix_microseconds(),
        kind,
        crossing.elevation_deg,
    )
}

fn transit_term<'a>(env: Env<'a>, transit: MoonTransit) -> EventTerm<'a> {
    let kind = match transit.kind {
        MoonTransitKind::Upper => atoms::upper().encode(env),
        MoonTransitKind::Lower => atoms::lower().encode(env),
    };
    (transit.time.unix_microseconds(), kind, transit.elevation_deg)
}

#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
fn bodies_find_moon_elevation_crossings<'a>(
    env: Env<'a>,
    lat_deg: f64,
    lon_deg: f64,
    alt_km: f64,
    start_datetime: Term<'a>,
    end_datetime: Term<'a>,
    elevation_threshold_deg: f64,
    step_seconds: f64,
    time_tolerance_seconds: f64,
) -> Term<'a> {
    let (Some(start), Some(end)) = (instant(start_datetime), instant(end_datetime)) else {
        return (atoms::error(), atoms::invalid_input()).encode(env);
    };
    let options = MoonElevationOptions {
        elevation_threshold_deg,
        step_seconds,
        time_tolerance_seconds,
    };
    match find_moon_elevation_crossings(&station(lat_deg, lon_deg, alt_km), start, end, options) {
        Ok(crossings) => {
            let rows: Vec<EventTerm> = crossings
                .into_iter()
                .map(|crossing| crossing_term(env, crossing))
                .collect();
            (atoms::ok(), rows).encode(env)
        }
        Err(_) => (atoms::error(), atoms::invalid_input()).encode(env),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
fn bodies_find_moon_transits<'a>(
    env: Env<'a>,
    lat_deg: f64,
    lon_deg: f64,
    alt_km: f64,
    start_datetime: Term<'a>,
    end_datetime: Term<'a>,
    step_seconds: f64,
    time_tolerance_seconds: f64,
) -> Term<'a> {
    let (Some(start), Some(end)) = (instant(start_datetime), instant(end_datetime)) else {
        return (atoms::error(), atoms::invalid_input()).encode(env);
    };
    match find_moon_transits(
        &station(lat_deg, lon_deg, alt_km),
        start,
        end,
        step_seconds,
        time_tolerance_seconds,
    ) {
        Ok(transits) => {
            let rows: Vec<EventTerm> = transits
                .into_iter()
                .map(|transit| transit_term(env, transit))
                .collect();
            (atoms::ok(), rows).encode(env)
        }
        Err(_) => (atoms::error(), atoms::invalid_input()).encode(env),
    }
}
