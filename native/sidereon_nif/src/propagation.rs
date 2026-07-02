//! SGP4 orbit propagation via the in-house `sidereon_core::astro::sgp4` module
//! (pure-Rust port of Vallado SGP4, bit-exact to non-FMA Vallado at 0 ULP).

use crate::errors;
use rustler::{Encoder, Env, NifResult, Term};
use sidereon_core::astro::forces::DragParameters;
use sidereon_core::astro::propagator::{
    propagate_states, IntegratorOptions, PropagationConfig, PropagationForceModel,
};
use sidereon_core::astro::sgp4::{ElementSet, JulianDate, OpsMode, Satellite};
use sidereon_core::astro::time::civil;
use sidereon_core::astro::tle::TleElements;

type DateTuple = (i32, i32, i32);
type TimeTuple = (i32, i32, i32, i32);
struct DatetimeComponents {
    year: i32,
    month: i32,
    day: i32,
    hour: i32,
    minute: i32,
    second: i32,
    microsecond: i32,
}

fn parse_datetime_tuple(term: Term) -> NifResult<DatetimeComponents> {
    let ((y, m, d), (h, min, s, us)): (DateTuple, TimeTuple) = term.decode()?;
    Ok(DatetimeComponents {
        year: y,
        month: m,
        day: d,
        hour: h,
        minute: min,
        second: s,
        microsecond: us,
    })
}

pub(crate) fn get_map_val<'a, T: rustler::Decoder<'a>>(
    env: Env<'a>,
    map: Term<'a>,
    key: &str,
) -> NifResult<T> {
    let atom = rustler::types::atom::Atom::from_str(env, key)?;
    let val = map.map_get(atom.to_term(env))?;
    val.decode()
}

/// Decode the SGP4 [`OpsMode`] selector the Elixir side threads through the
/// pass/visibility/look-angle NIFs as the atom `:afspc` or `:improved`.
///
/// The whole point is that a satellite's passes, visibility, and look angle are
/// built with the *same* opsmode, so the propagation underneath them is
/// consistent rather than silently forced to AFSPC by an element-set helper.
pub(crate) fn opsmode_from_term<'a>(env: Env<'a>, term: Term<'a>) -> NifResult<OpsMode> {
    let atom: rustler::Atom = term.decode()?;
    if atom == rustler::types::atom::Atom::from_str(env, "improved")? {
        Ok(OpsMode::Improved)
    } else if atom == rustler::types::atom::Atom::from_str(env, "afspc")? {
        Ok(OpsMode::Afspc)
    } else {
        Err(rustler::Error::BadArg)
    }
}

pub(crate) fn elements_from_map<'a>(env: Env<'a>, tle_map: Term<'a>) -> NifResult<ElementSet> {
    // The Elixir side carries the SGP4 mean elements plus the full four-digit
    // epoch year and fractional day (it derives the year from its own datetime,
    // so no two-digit-year pivot is reconstructed here). The core moved the
    // TLE-to-IR mapping (and the exact Vallado days2mdhms/jday epoch math) behind
    // `TleElements::to_element_set`, so build that public IR and convert through
    // the single canonical path.
    let elements = TleElements {
        catalog_number: String::new(),
        classification: String::new(),
        international_designator: String::new(),
        epoch_year: get_map_val(env, tle_map, "epoch_year")?,
        epoch_day_of_year: get_map_val(env, tle_map, "epochdays")?,
        mean_motion_dot: get_map_val(env, tle_map, "mean_motion_dot")?,
        mean_motion_double_dot: get_map_val(env, tle_map, "mean_motion_double_dot")?,
        bstar: get_map_val(env, tle_map, "bstar")?,
        ephemeris_type: 0,
        elset_number: 0,
        inclination_deg: get_map_val(env, tle_map, "inclination_deg")?,
        raan_deg: get_map_val(env, tle_map, "raan_deg")?,
        eccentricity: get_map_val(env, tle_map, "eccentricity")?,
        arg_perigee_deg: get_map_val(env, tle_map, "arg_perigee_deg")?,
        mean_anomaly_deg: get_map_val(env, tle_map, "mean_anomaly_deg")?,
        mean_motion: get_map_val(env, tle_map, "mean_motion")?,
        rev_number: 0,
    };

    elements.to_element_set().map_err(errors::invalid_input)
}

pub(crate) fn propagate_with_elements_impl<'a>(
    env: Env<'a>,
    tle_map: Term<'a>,
    datetime_tuple: Term<'a>,
) -> NifResult<Term<'a>> {
    let ok = rustler::types::atom::Atom::from_str(env, "ok")?;
    let error = rustler::types::atom::Atom::from_str(env, "error")?;

    let elements = elements_from_map(env, tle_map)?;

    let dt = parse_datetime_tuple(datetime_tuple)?;

    // AFSPC opsmode: matches the historical sidereon behavior (which used the
    // third-party sgp4 crate's `_afspc_compatibility_mode` functions). The
    // Skyfield reference values stored in oracle tests were calibrated to
    // AFSPC, so we preserve that mode for compatibility.
    let satellite = match Satellite::from_elements_with_opsmode(&elements, OpsMode::Afspc) {
        Ok(s) => s,
        Err(e) => return Ok((error, format!("SGP4 init: {e}")).encode(env)),
    };

    // Compute the target Julian Date from the supplied UTC components and let
    // Satellite::propagate_jd subtract the satrec's *cached* exact epoch
    // internally. This avoids any precision drift that would otherwise come
    // from computing the epoch JD a second time on this side.
    let target_jd = match utc_components_to_jd_split(&dt) {
        Some(jd) => jd,
        None => return Ok((error, "invalid datetime").encode(env)),
    };

    match satellite.propagate_jd(target_jd) {
        Ok(pred) => {
            let pos = (pred.position[0], pred.position[1], pred.position[2]);
            let vel = (pred.velocity[0], pred.velocity[1], pred.velocity[2]);
            Ok((ok, (pos, vel)).encode(env))
        }
        Err(e) => Ok((error, format!("SGP4 propagate: {e}")).encode(env)),
    }
}

/// Adaptive Dormand-Prince 5(4) numerical propagation of a raw ECI Cartesian
/// state over a relative span `dt_seconds`. Marshals the public options into
/// the core driver and returns `{:ok, {{rx, ry, rz}, {vx, vy, vz}}}` or
/// `{:error, atom}`.
pub(crate) fn propagate_dp54_impl(
    env: Env<'_>,
    position_km: (f64, f64, f64),
    velocity_km_s: (f64, f64, f64),
    dt_seconds: f64,
    forces: Vec<String>,
    abs_tol: f64,
    rel_tol: f64,
) -> NifResult<Term<'_>> {
    propagate_dp54_impl_with_drag(
        env,
        position_km,
        velocity_km_s,
        dt_seconds,
        forces,
        abs_tol,
        rel_tol,
        None,
    )
}

#[allow(clippy::too_many_arguments)]
pub(crate) fn propagate_dp54_impl_with_drag(
    env: Env<'_>,
    position_km: (f64, f64, f64),
    velocity_km_s: (f64, f64, f64),
    dt_seconds: f64,
    forces: Vec<String>,
    abs_tol: f64,
    rel_tol: f64,
    drag: Option<DragParameters>,
) -> NifResult<Term<'_>> {
    let ok = rustler::types::atom::Atom::from_str(env, "ok")?;
    let error = rustler::types::atom::Atom::from_str(env, "error")?;

    let mut config = PropagationConfig::new(
        0.0,
        [position_km.0, position_km.1, position_km.2],
        [velocity_km_s.0, velocity_km_s.1, velocity_km_s.2],
    );
    config.force_model = if forces.iter().any(|f| f == "j2") {
        PropagationForceModel::TwoBodyJ2
    } else {
        PropagationForceModel::TwoBody
    };
    config.options = IntegratorOptions {
        abs_tol,
        rel_tol,
        ..config.options
    };
    config.drag = drag;

    match propagate_states(&config, &[dt_seconds]) {
        Ok(states) => {
            let state = states[0];
            let pos = state.position_array();
            let vel = state.velocity_array();
            let r = (pos[0], pos[1], pos[2]);
            let v = (vel[0], vel[1], vel[2]);
            Ok((ok, (r, v)).encode(env))
        }
        Err(_) => {
            let reason = rustler::types::atom::Atom::from_str(env, "propagation_failed")?;
            Ok((error, reason).encode(env))
        }
    }
}

/// Build a split-form Julian date `(jd_whole, jd_fraction)` from a UTC calendar
/// tuple. Returns `None` for an out-of-range month/day.
///
/// The calendar arithmetic delegates to [`civil::split_julian_date`] (the single
/// core civil-time conversion); only the input range guard and the microsecond
/// fold into fractional seconds remain on this side.
fn utc_components_to_jd_split(dt: &DatetimeComponents) -> Option<JulianDate> {
    if dt.month < 1 || dt.month > 12 || dt.day < 1 || dt.day > 31 {
        return None;
    }
    let second = dt.second as f64 + dt.microsecond as f64 / 1_000_000.0;
    let (jd_whole, jd_fraction) =
        civil::split_julian_date(dt.year, dt.month, dt.day, dt.hour, dt.minute, second);
    Some(JulianDate(jd_whole, jd_fraction))
}
