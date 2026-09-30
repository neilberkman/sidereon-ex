use crate::passes::instant_from_datetime_tuple;
use crate::propagation::elements_from_map;
use rustler::{Atom, Encoder, Env, NifResult, Term};
use sidereon_core::astro::coverage as core_coverage;
use sidereon_core::astro::passes::{GroundStation, LookAngleError};
use sidereon_core::astro::sgp4::{Error as Sgp4Error, OpsMode, Satellite, Sgp4InputErrorKind};

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
        let satellite = Satellite::from_elements_with_opsmode(&elements, OpsMode::Afspc)
            .map_err(|error| sgp4_rustler_error(env, &error, None))?;
        satellites.push(satellite);
    }
    Ok(satellites)
}

fn atom(env: Env<'_>, name: &str) -> Atom {
    Atom::from_str(env, name).expect("coverage error atom names are fixed core identifiers")
}

fn sgp4_kind_name(kind: Sgp4InputErrorKind) -> &'static str {
    match kind {
        Sgp4InputErrorKind::NonFinite => "non_finite",
        Sgp4InputErrorKind::NotPositive => "not_positive",
        Sgp4InputErrorKind::Negative => "negative",
        Sgp4InputErrorKind::OutOfRange => "out_of_range",
        Sgp4InputErrorKind::Missing => "missing",
        Sgp4InputErrorKind::FloatParse => "float_parse",
        Sgp4InputErrorKind::IntParse => "int_parse",
        Sgp4InputErrorKind::InvalidCivilDate => "invalid_civil_date",
        Sgp4InputErrorKind::InvalidCivilTime => "invalid_civil_time",
    }
}

/// Raise the same complete SGP4 variant tuple as the typed detail mapper.
/// When `satellite_index` is present, prefix the tuple so a whole-call failure
/// cannot erase which input row failed (including grids with zero stations).
fn sgp4_rustler_error(
    env: Env<'_>,
    error: &Sgp4Error,
    satellite_index: Option<usize>,
) -> rustler::Error {
    let tag = |name| atom(env, name);
    match (satellite_index, error) {
        (None, Sgp4Error::InvalidInput { field, kind }) => rustler::Error::RaiseTerm(Box::new((
            tag("invalid_input"),
            tag(&field.to_ascii_lowercase()),
            tag(sgp4_kind_name(*kind)),
        ))),
        (Some(index), Sgp4Error::InvalidInput { field, kind }) => {
            rustler::Error::RaiseTerm(Box::new((
                tag("satellite_initialization"),
                index,
                (
                    tag("invalid_input"),
                    tag(&field.to_ascii_lowercase()),
                    tag(sgp4_kind_name(*kind)),
                ),
            )))
        }
        (None, Sgp4Error::NonFiniteOutput { field }) => rustler::Error::RaiseTerm(Box::new((
            tag("non_finite_output"),
            tag(&field.to_ascii_lowercase()),
        ))),
        (Some(index), Sgp4Error::NonFiniteOutput { field }) => {
            rustler::Error::RaiseTerm(Box::new((
                tag("satellite_initialization"),
                index,
                (tag("non_finite_output"), tag(&field.to_ascii_lowercase())),
            )))
        }
        (None, Sgp4Error::InvalidTle(message)) => {
            rustler::Error::RaiseTerm(Box::new((tag("invalid_tle"), message.clone())))
        }
        (Some(index), Sgp4Error::InvalidTle(message)) => rustler::Error::RaiseTerm(Box::new((
            tag("satellite_initialization"),
            index,
            (tag("invalid_tle"), message.clone()),
        ))),
        (None, Sgp4Error::Sgp4 { code }) => {
            rustler::Error::RaiseTerm(Box::new((tag("sgp4"), *code)))
        }
        (Some(index), Sgp4Error::Sgp4 { code }) => rustler::Error::RaiseTerm(Box::new((
            tag("satellite_initialization"),
            index,
            (tag("sgp4"), *code),
        ))),
        (None, Sgp4Error::ResonanceStepBudget { budget }) => {
            rustler::Error::RaiseTerm(Box::new((tag("resonance_step_budget"), *budget)))
        }
        (Some(index), Sgp4Error::ResonanceStepBudget { budget }) => {
            rustler::Error::RaiseTerm(Box::new((
                tag("satellite_initialization"),
                index,
                (tag("resonance_step_budget"), *budget),
            )))
        }
    }
}

pub(crate) fn look_angle_error_term<'a>(env: Env<'a>, error: &LookAngleError) -> Term<'a> {
    use sidereon_core::astro::frames::transforms::FrameTransformError as F;
    match error {
        LookAngleError::InvalidInput { field, reason } => {
            (crate::spp::atom_from(env, "invalid_input"), field, reason).encode(env)
        }
        LookAngleError::Init(source) => (
            crate::spp::atom_from(env, "init"),
            crate::ndm_errors::sgp4_error_term(env, source),
        )
            .encode(env),
        LookAngleError::Propagate(source) => (
            crate::spp::atom_from(env, "propagate"),
            crate::ndm_errors::sgp4_error_term(env, source),
        )
            .encode(env),
        LookAngleError::FrameTransform(source) => {
            let cause = match source {
                F::InvalidInput { field, reason } => {
                    (crate::spp::atom_from(env, "invalid_input"), field, reason).encode(env)
                }
                F::Ut1OutsideCoverage { reason } => (
                    crate::spp::atom_from(env, "ut1_outside_coverage"),
                    crate::spp::atom_from(
                        env,
                        match reason {
                            sidereon_core::astro::time::DegradeReason::BeforeCoverage => {
                                "before_coverage"
                            }
                            sidereon_core::astro::time::DegradeReason::AfterCoverage => {
                                "after_coverage"
                            }
                        },
                    ),
                )
                    .encode(env),
            };
            (crate::spp::atom_from(env, "frame_transform"), cause).encode(env)
        }
    }
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

/// Detailed additive variant that retains one row per input satellite and
/// returns complete typed errors for failed SGP4 initialization or cells.
#[rustler::nif(schedule = "DirtyCpu")]
fn coverage_look_angles_detailed<'a>(
    env: Env<'a>,
    tle_maps: Vec<Term<'a>>,
    stations: Vec<StationTerm>,
    datetime: Term<'a>,
) -> NifResult<Vec<Vec<Term<'a>>>> {
    let mut satellite_results = Vec::with_capacity(tle_maps.len());
    let mut satellites = Vec::with_capacity(tle_maps.len());
    for tle_map in tle_maps {
        let elements = elements_from_map(env, tle_map)?;
        match Satellite::from_elements_with_opsmode(&elements, OpsMode::Afspc) {
            Ok(satellite) => {
                satellites.push(satellite);
                satellite_results.push(Ok(()));
            }
            Err(error) => satellite_results.push(Err(error)),
        }
    }
    let stations = ground_stations(stations);
    if stations.is_empty() {
        if let Some((index, Err(error))) = satellite_results
            .iter()
            .enumerate()
            .find(|(_, result)| result.is_err())
        {
            return Err(sgp4_rustler_error(env, error, Some(index)));
        }
    }
    let datetime = instant_from_datetime_tuple(datetime)?;
    let successful_rows = core_coverage::look_angles_batch(&satellites, &stations, datetime);
    let mut successful_rows = successful_rows.into_iter();
    let mut rows = Vec::with_capacity(satellite_results.len());
    for satellite_result in satellite_results {
        let row = match satellite_result {
            Ok(()) => successful_rows
                .next()
                .ok_or_else(|| rustler::Error::Term(Box::new("coverage row count mismatch")))?
                .into_iter()
                .map(|cell| match cell {
                    Ok(look) => (
                        atoms::ok(),
                        (look.azimuth_deg, look.elevation_deg, look.range_km),
                    )
                        .encode(env),
                    Err(error) => (atoms::error(), look_angle_error_term(env, &error)).encode(env),
                })
                .collect(),
            Err(error) => (0..stations.len())
                .map(|_| {
                    (
                        atoms::error(),
                        look_angle_error_term(env, &LookAngleError::Init(error.clone())),
                    )
                        .encode(env)
                })
                .collect(),
        };
        rows.push(row);
    }
    Ok(rows)
}
