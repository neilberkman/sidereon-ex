//! Rustler boundary for high-level TLE look-angle prediction.
//!
//! The propagation and topocentric geometry live in `sidereon_core::astro::passes`;
//! this module only decodes Sidereon terms and maps errors to the existing public
//! shape.

use crate::passes::instant_from_datetime_tuple;
use crate::propagation::elements_from_map;
use rustler::{Encoder, Env, NifResult, Term};
use sidereon_core::astro::passes::{look_angle, GroundStation, LookAngleError};

pub(crate) fn tle_look_angle_impl<'a>(
    env: Env<'a>,
    tle_map: Term<'a>,
    station_latitude_deg: f64,
    station_longitude_deg: f64,
    station_altitude_m: f64,
    datetime: Term<'a>,
) -> NifResult<Term<'a>> {
    let ok = rustler::types::atom::Atom::from_str(env, "ok")?;
    let error = rustler::types::atom::Atom::from_str(env, "error")?;

    let elements = elements_from_map(env, tle_map)?;
    let instant = instant_from_datetime_tuple(datetime)?;
    let station = GroundStation {
        latitude_deg: station_latitude_deg,
        longitude_deg: station_longitude_deg,
        altitude_m: station_altitude_m,
    };

    match look_angle(&elements, station, instant) {
        Ok(look) => Ok((ok, (look.azimuth_deg, look.elevation_deg, look.range_km)).encode(env)),
        Err(LookAngleError::Init(err)) => Ok((error, format!("SGP4 init: {err}")).encode(env)),
        Err(LookAngleError::Propagate(err)) => {
            Ok((error, format!("SGP4 propagate: {err}")).encode(env))
        }
        Err(LookAngleError::InvalidInput { .. }) => {
            let reason = rustler::types::atom::Atom::from_str(env, "invalid_input")?;
            Ok((error, reason).encode(env))
        }
        Err(LookAngleError::FrameTransform(_)) => {
            let reason = rustler::types::atom::Atom::from_str(env, "frame_transform_failed")?;
            Ok((error, reason).encode(env))
        }
    }
}
