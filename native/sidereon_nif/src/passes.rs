//! Rustler boundary for TLE pass prediction.
//!
//! The pass search itself lives in `sidereon_core::astro::passes`; this module only
//! decodes Sidereon terms and encodes unix-microsecond pass rows.

use crate::propagation::{elements_from_map, get_map_val};
use rustler::{Env, Error, NifResult, Term};
use sidereon_core::astro::passes::{
    predict_passes, visible_from_constellation, ConstellationMember, GroundStation,
    PassPredictionOptions, UtcInstant,
};

type DateTuple = (i32, i32, i32);
type TimeTuple = (i32, i32, i32, i32);
type PassTerm = (i64, i64, f64, i64);
type Vec3 = (f64, f64, f64);
type VisibleTerm = (String, f64, f64, f64, Vec3);

#[allow(clippy::too_many_arguments)]
pub(crate) fn predict_passes_impl<'a>(
    env: Env<'a>,
    tle_map: Term<'a>,
    station_latitude_deg: f64,
    station_longitude_deg: f64,
    station_altitude_m: f64,
    start_datetime: Term<'a>,
    end_datetime: Term<'a>,
    min_elevation_deg: f64,
    step_seconds: i64,
) -> NifResult<Vec<PassTerm>> {
    let elements = elements_from_map(env, tle_map)?;
    let start_time = instant_from_datetime_tuple(start_datetime)?;
    let end_time = instant_from_datetime_tuple(end_datetime)?;
    let station = GroundStation {
        latitude_deg: station_latitude_deg,
        longitude_deg: station_longitude_deg,
        altitude_m: station_altitude_m,
    };
    let options = PassPredictionOptions {
        min_elevation_deg,
        step_seconds,
    };

    Ok(
        predict_passes(&elements, station, start_time, end_time, options)
            .map_err(crate::errors::invalid_input)?
            .into_iter()
            .map(|pass| {
                (
                    pass.rise.unix_microseconds(),
                    pass.set.unix_microseconds(),
                    pass.max_elevation_deg,
                    pass.max_elevation_time.unix_microseconds(),
                )
            })
            .collect(),
    )
}

pub(crate) fn instant_from_datetime_tuple(datetime: Term) -> NifResult<UtcInstant> {
    let ((year, month, day), (hour, minute, second, microsecond)): (DateTuple, TimeTuple) =
        datetime.decode()?;
    UtcInstant::from_utc(year, month, day, hour, minute, second, microsecond).ok_or(Error::BadArg)
}

#[allow(clippy::too_many_arguments)]
pub(crate) fn constellation_visible_impl<'a>(
    env: Env<'a>,
    tle_maps: Vec<Term<'a>>,
    station_latitude_deg: f64,
    station_longitude_deg: f64,
    station_altitude_m: f64,
    datetime: Term<'a>,
    min_elevation_deg: f64,
) -> NifResult<Vec<VisibleTerm>> {
    let instant = instant_from_datetime_tuple(datetime)?;
    let station = GroundStation {
        latitude_deg: station_latitude_deg,
        longitude_deg: station_longitude_deg,
        altitude_m: station_altitude_m,
    };

    let mut members = Vec::with_capacity(tle_maps.len());
    for tle_map in tle_maps {
        members.push(ConstellationMember {
            catalog_number: get_map_val(env, tle_map, "catalog_number")?,
            elements: elements_from_map(env, tle_map)?,
        });
    }

    Ok(
        visible_from_constellation(&members, station, instant, min_elevation_deg)
            .map_err(crate::errors::invalid_input)?
            .into_iter()
            .map(|sat| {
                (
                    sat.catalog_number,
                    sat.elevation_deg,
                    sat.azimuth_deg,
                    sat.range_km,
                    (sat.position_km[0], sat.position_km[1], sat.position_km[2]),
                )
            })
            .collect(),
    )
}
