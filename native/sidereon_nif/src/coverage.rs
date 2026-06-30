use crate::passes::instant_from_datetime_tuple;
use crate::propagation::elements_from_map;
use rustler::{Encoder, Env, NifResult, Term};
use sidereon_core::astro::coverage as core_coverage;
use sidereon_core::astro::passes::GroundStation;
use sidereon_core::astro::sgp4::{OpsMode, Satellite};

mod atoms {
    rustler::atoms! {
        ok,
        error
    }
}

type StationTerm = (f64, f64, f64);

fn satellites_from_maps<'a>(env: Env<'a>, tle_maps: Vec<Term<'a>>) -> NifResult<Vec<Satellite>> {
    let mut satellites = Vec::with_capacity(tle_maps.len());
    for tle_map in tle_maps {
        let elements = elements_from_map(env, tle_map)?;
        if let Ok(satellite) = Satellite::from_elements_with_opsmode(&elements, OpsMode::Afspc) {
            satellites.push(satellite);
        }
    }
    Ok(satellites)
}

fn ground_stations(stations: Vec<StationTerm>) -> Vec<GroundStation> {
    stations
        .into_iter()
        .map(|(latitude_deg, longitude_deg, altitude_m)| GroundStation {
            latitude_deg,
            longitude_deg,
            altitude_m,
        })
        .collect()
}

#[rustler::nif(schedule = "DirtyCpu")]
fn coverage_look_angles<'a>(
    env: Env<'a>,
    tle_maps: Vec<Term<'a>>,
    stations: Vec<StationTerm>,
    datetime: Term<'a>,
) -> NifResult<Vec<Vec<Term<'a>>>> {
    let satellites = satellites_from_maps(env, tle_maps)?;
    let stations = ground_stations(stations);
    let datetime = instant_from_datetime_tuple(datetime)?;

    Ok(
        core_coverage::look_angles_batch(&satellites, &stations, datetime)
            .into_iter()
            .map(|row| {
                row.into_iter()
                    .map(|cell| match cell {
                        Ok(look) => (
                            atoms::ok(),
                            (look.azimuth_deg, look.elevation_deg, look.range_km),
                        )
                            .encode(env),
                        Err(_err) => atoms::error().encode(env),
                    })
                    .collect()
            })
            .collect(),
    )
}
