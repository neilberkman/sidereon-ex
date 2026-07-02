use rustler::{Encoder, Env, Error, NifResult, ResourceArc, Term};
use sidereon_core::astro::almanac::{
    lunar_solar_eclipses, meridian_transits, moon_phases, planetary_events, seasons,
    CulminationKind, EclipseKind, EphemerisSource, MoonPhaseKind, Planet, PlanetaryEventKind,
    SeasonKind, TransitBody,
};
use sidereon_core::astro::bodies::observe::{
    observe, observe_spk_body, Ecliptic, Equatorial, Horizontal, Observation, ObserveOptions,
    Refraction, Target,
};
use sidereon_core::astro::frames::transforms::{GeodeticStationKm, PolarMotion};
use sidereon_core::astro::passes::UtcInstant;

use crate::ephemeris::SpkResource;
use crate::errors;

type DateTuple = (i32, i32, i32);
type TimeTuple = (i32, i32, i32, i32);
type Vec3 = (f64, f64, f64);

mod atoms {
    rustler::atoms! {
        ok,
        error,
        invalid_input
    }
}

#[derive(Debug, Clone, rustler::NifMap)]
struct ObserveOptionsTerm {
    polar_motion: Option<(f64, f64)>,
    refraction: Option<(f64, f64)>,
    deflection: bool,
    aberration: bool,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct EquatorialTerm {
    right_ascension_deg: f64,
    right_ascension_hours: f64,
    declination_deg: f64,
    distance_km: f64,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct HorizontalTerm {
    azimuth_deg: f64,
    elevation_deg: f64,
    range_km: f64,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct EclipticTerm {
    longitude_deg: f64,
    latitude_deg: f64,
    distance_km: f64,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct ObservationTerm {
    astrometric: EquatorialTerm,
    apparent_icrs: EquatorialTerm,
    apparent: EquatorialTerm,
    horizontal: HorizontalTerm,
    hour_angle_deg: f64,
    hour_angle_hours: f64,
    ecliptic: EclipticTerm,
    reduced: bool,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct TimeKindTerm {
    unix_microseconds: i64,
    kind: String,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct PlanetaryTerm {
    unix_microseconds: i64,
    planet: String,
    kind: String,
    elongation_deg: f64,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct TransitTerm {
    unix_microseconds: i64,
    kind: String,
    altitude_deg: f64,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct EclipseTerm {
    maximum_unix_microseconds: i64,
    kind: String,
    magnitude: f64,
    moon_latitude_deg: f64,
    gamma: f64,
    uncertain: bool,
}

fn station(lat_deg: f64, lon_deg: f64, alt_km: f64) -> GeodeticStationKm {
    GeodeticStationKm {
        latitude_deg: lat_deg,
        longitude_deg: lon_deg,
        altitude_km: alt_km,
    }
}

fn instant(datetime: Term) -> NifResult<UtcInstant> {
    let ((year, month, day), (hour, minute, second, microsecond)): (DateTuple, TimeTuple) =
        datetime.decode()?;
    UtcInstant::from_utc(year, month, day, hour, minute, second, microsecond)
        .ok_or_else(|| Error::Term(Box::new("invalid UTC datetime")))
}

fn observe_options(term: Term<'_>) -> NifResult<ObserveOptions> {
    let decoded: ObserveOptionsTerm = term.decode()?;
    Ok(ObserveOptions {
        polar_motion: decoded
            .polar_motion
            .map(|(xp, yp)| PolarMotion::from_radians(xp, yp))
            .transpose()
            .map_err(errors::invalid_input)?,
        refraction: decoded
            .refraction
            .map(|(pressure_mbar, temperature_c)| Refraction {
                pressure_mbar,
                temperature_c,
            }),
        deflection: decoded.deflection,
        aberration: decoded.aberration,
    })
}

fn equatorial_term(value: Equatorial) -> EquatorialTerm {
    EquatorialTerm {
        right_ascension_deg: value.right_ascension_deg,
        right_ascension_hours: value.right_ascension_hours,
        declination_deg: value.declination_deg,
        distance_km: value.distance_km,
    }
}

fn horizontal_term(value: Horizontal) -> HorizontalTerm {
    HorizontalTerm {
        azimuth_deg: value.azimuth_deg,
        elevation_deg: value.elevation_deg,
        range_km: value.range_km,
    }
}

fn ecliptic_term(value: Ecliptic) -> EclipticTerm {
    EclipticTerm {
        longitude_deg: value.longitude_deg,
        latitude_deg: value.latitude_deg,
        distance_km: value.distance_km,
    }
}

fn observation_term(value: Observation) -> ObservationTerm {
    ObservationTerm {
        astrometric: equatorial_term(value.astrometric),
        apparent_icrs: equatorial_term(value.apparent_icrs),
        apparent: equatorial_term(value.apparent),
        horizontal: horizontal_term(value.horizontal),
        hour_angle_deg: value.hour_angle_deg,
        hour_angle_hours: value.hour_angle_hours,
        ecliptic: ecliptic_term(value.ecliptic),
        reduced: value.reduced,
    }
}

fn target_label(target: &str) -> NifResult<Target<'_>> {
    Ok(match target {
        "sun" => Target::Sun,
        "moon" => Target::Moon,
        _ => return Err(Error::Term(Box::new("unknown observe target"))),
    })
}

fn planet(value: &str) -> NifResult<Planet> {
    Ok(match value {
        "mercury" => Planet::Mercury,
        "venus" => Planet::Venus,
        "mars" => Planet::Mars,
        "jupiter" => Planet::Jupiter,
        "saturn" => Planet::Saturn,
        "uranus" => Planet::Uranus,
        "neptune" => Planet::Neptune,
        _ => return Err(Error::Term(Box::new("unknown planet"))),
    })
}

fn planet_label(value: Planet) -> &'static str {
    match value {
        Planet::Mercury => "mercury",
        Planet::Venus => "venus",
        Planet::Mars => "mars",
        Planet::Jupiter => "jupiter",
        Planet::Saturn => "saturn",
        Planet::Uranus => "uranus",
        Planet::Neptune => "neptune",
        _ => "unknown",
    }
}

fn planetary_kind(value: &str) -> NifResult<PlanetaryEventKind> {
    Ok(match value {
        "conjunction" => PlanetaryEventKind::Conjunction,
        "opposition" => PlanetaryEventKind::Opposition,
        _ => return Err(Error::Term(Box::new("unknown planetary event kind"))),
    })
}

fn planetary_kind_label(value: PlanetaryEventKind) -> &'static str {
    match value {
        PlanetaryEventKind::Conjunction => "conjunction",
        PlanetaryEventKind::Opposition => "opposition",
        _ => "unknown",
    }
}

fn transit_body(value: &str) -> NifResult<TransitBody> {
    Ok(match value {
        "sun" => TransitBody::Sun,
        "moon" => TransitBody::Moon,
        "mercury" => TransitBody::Planet(Planet::Mercury),
        "venus" => TransitBody::Planet(Planet::Venus),
        "mars" => TransitBody::Planet(Planet::Mars),
        "jupiter" => TransitBody::Planet(Planet::Jupiter),
        "saturn" => TransitBody::Planet(Planet::Saturn),
        "uranus" => TransitBody::Planet(Planet::Uranus),
        "neptune" => TransitBody::Planet(Planet::Neptune),
        _ => return Err(Error::Term(Box::new("unknown transit body"))),
    })
}

fn season_label(value: SeasonKind) -> &'static str {
    match value {
        SeasonKind::MarchEquinox => "march_equinox",
        SeasonKind::JuneSolstice => "june_solstice",
        SeasonKind::SeptemberEquinox => "september_equinox",
        SeasonKind::DecemberSolstice => "december_solstice",
        _ => "unknown",
    }
}

fn moon_phase_label(value: MoonPhaseKind) -> &'static str {
    match value {
        MoonPhaseKind::New => "new",
        MoonPhaseKind::FirstQuarter => "first_quarter",
        MoonPhaseKind::Full => "full",
        MoonPhaseKind::LastQuarter => "last_quarter",
        _ => "unknown",
    }
}

fn culmination_label(value: CulminationKind) -> &'static str {
    match value {
        CulminationKind::Upper => "upper",
        CulminationKind::Lower => "lower",
        _ => "unknown",
    }
}

fn eclipse_label(value: EclipseKind) -> &'static str {
    match value {
        EclipseKind::LunarPenumbral => "lunar_penumbral",
        EclipseKind::LunarPartial => "lunar_partial",
        EclipseKind::LunarTotal => "lunar_total",
        EclipseKind::SolarPartial => "solar_partial",
        EclipseKind::SolarAnnular => "solar_annular",
        EclipseKind::SolarTotal => "solar_total",
        EclipseKind::SolarHybrid => "solar_hybrid",
        _ => "unknown",
    }
}

fn encode_error<'a, E: std::fmt::Display>(env: Env<'a>, error: E) -> Term<'a> {
    (atoms::error(), error.to_string()).encode(env)
}

#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
fn observe_analytic<'a>(
    env: Env<'a>,
    lat_deg: f64,
    lon_deg: f64,
    alt_km: f64,
    datetime: Term<'a>,
    target: String,
    options: Term<'a>,
) -> NifResult<Term<'a>> {
    let time = instant(datetime)?;
    let options = observe_options(options)?;
    Ok(
        match observe(
            &station(lat_deg, lon_deg, alt_km),
            time,
            target_label(&target)?,
            options,
        ) {
            Ok(obs) => (atoms::ok(), observation_term(obs)).encode(env),
            Err(error) => encode_error(env, error),
        },
    )
}

#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
fn observe_spk_body_full<'a>(
    env: Env<'a>,
    handle: ResourceArc<SpkResource>,
    lat_deg: f64,
    lon_deg: f64,
    alt_km: f64,
    datetime: Term<'a>,
    naif_id: i32,
    options: Term<'a>,
) -> NifResult<Term<'a>> {
    let time = instant(datetime)?;
    let options = observe_options(options)?;
    let site = station(lat_deg, lon_deg, alt_km);
    Ok(
        match observe(
            &site,
            time,
            Target::Spk {
                kernel: &handle.spk,
                naif_id,
            },
            options,
        ) {
            Ok(obs) => (atoms::ok(), observation_term(obs)).encode(env),
            Err(error) => encode_error(env, error),
        },
    )
}

#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
fn observe_spk_body_default<'a>(
    env: Env<'a>,
    handle: ResourceArc<SpkResource>,
    lat_deg: f64,
    lon_deg: f64,
    alt_km: f64,
    datetime: Term<'a>,
    naif_id: i32,
) -> NifResult<Term<'a>> {
    let time = instant(datetime)?;
    Ok(
        match observe_spk_body(
            &station(lat_deg, lon_deg, alt_km),
            time,
            &handle.spk,
            naif_id,
        ) {
            Ok(obs) => (atoms::ok(), observation_term(obs)).encode(env),
            Err(error) => encode_error(env, error),
        },
    )
}

#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
fn observe_barycentric_state<'a>(
    env: Env<'a>,
    handle: ResourceArc<SpkResource>,
    lat_deg: f64,
    lon_deg: f64,
    alt_km: f64,
    datetime: Term<'a>,
    position_km: Vec3,
    velocity_km_s: Vec3,
    options: Term<'a>,
) -> NifResult<Term<'a>> {
    let time = instant(datetime)?;
    let options = observe_options(options)?;
    Ok(
        match observe(
            &station(lat_deg, lon_deg, alt_km),
            time,
            Target::BarycentricState {
                kernel: &handle.spk,
                position_km: [position_km.0, position_km.1, position_km.2],
                velocity_km_s: [velocity_km_s.0, velocity_km_s.1, velocity_km_s.2],
            },
            options,
        ) {
            Ok(obs) => (atoms::ok(), observation_term(obs)).encode(env),
            Err(error) => encode_error(env, error),
        },
    )
}

fn source_analytic() -> EphemerisSource<'static> {
    EphemerisSource::Analytic
}

fn source_spk(handle: &SpkResource) -> EphemerisSource<'_> {
    EphemerisSource::Spk(&handle.spk)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn almanac_seasons_analytic<'a>(
    env: Env<'a>,
    start: Term<'a>,
    end: Term<'a>,
    step_seconds: f64,
    time_tolerance_seconds: f64,
) -> NifResult<Term<'a>> {
    almanac_seasons_impl(
        env,
        source_analytic(),
        start,
        end,
        step_seconds,
        time_tolerance_seconds,
    )
}

#[rustler::nif(schedule = "DirtyCpu")]
fn almanac_seasons_spk<'a>(
    env: Env<'a>,
    handle: ResourceArc<SpkResource>,
    start: Term<'a>,
    end: Term<'a>,
    step_seconds: f64,
    time_tolerance_seconds: f64,
) -> NifResult<Term<'a>> {
    almanac_seasons_impl(
        env,
        source_spk(&handle),
        start,
        end,
        step_seconds,
        time_tolerance_seconds,
    )
}

fn almanac_seasons_impl<'a>(
    env: Env<'a>,
    source: EphemerisSource<'_>,
    start: Term<'a>,
    end: Term<'a>,
    step_seconds: f64,
    time_tolerance_seconds: f64,
) -> NifResult<Term<'a>> {
    let start = instant(start)?;
    let end = instant(end)?;
    Ok(
        match seasons(source, start, end, step_seconds, time_tolerance_seconds) {
            Ok(events) => {
                let rows: Vec<TimeKindTerm> = events
                    .into_iter()
                    .map(|event| TimeKindTerm {
                        unix_microseconds: event.time.unix_microseconds(),
                        kind: season_label(event.kind).to_string(),
                    })
                    .collect();
                (atoms::ok(), rows).encode(env)
            }
            Err(error) => encode_error(env, error),
        },
    )
}

#[rustler::nif(schedule = "DirtyCpu")]
fn almanac_moon_phases_analytic<'a>(
    env: Env<'a>,
    start: Term<'a>,
    end: Term<'a>,
    step_seconds: f64,
    time_tolerance_seconds: f64,
) -> NifResult<Term<'a>> {
    almanac_moon_phases_impl(
        env,
        source_analytic(),
        start,
        end,
        step_seconds,
        time_tolerance_seconds,
    )
}

#[rustler::nif(schedule = "DirtyCpu")]
fn almanac_moon_phases_spk<'a>(
    env: Env<'a>,
    handle: ResourceArc<SpkResource>,
    start: Term<'a>,
    end: Term<'a>,
    step_seconds: f64,
    time_tolerance_seconds: f64,
) -> NifResult<Term<'a>> {
    almanac_moon_phases_impl(
        env,
        source_spk(&handle),
        start,
        end,
        step_seconds,
        time_tolerance_seconds,
    )
}

fn almanac_moon_phases_impl<'a>(
    env: Env<'a>,
    source: EphemerisSource<'_>,
    start: Term<'a>,
    end: Term<'a>,
    step_seconds: f64,
    time_tolerance_seconds: f64,
) -> NifResult<Term<'a>> {
    let start = instant(start)?;
    let end = instant(end)?;
    Ok(
        match moon_phases(source, start, end, step_seconds, time_tolerance_seconds) {
            Ok(events) => {
                let rows: Vec<TimeKindTerm> = events
                    .into_iter()
                    .map(|event| TimeKindTerm {
                        unix_microseconds: event.time.unix_microseconds(),
                        kind: moon_phase_label(event.kind).to_string(),
                    })
                    .collect();
                (atoms::ok(), rows).encode(env)
            }
            Err(error) => encode_error(env, error),
        },
    )
}

#[rustler::nif(schedule = "DirtyCpu")]
fn almanac_planetary_events_spk<'a>(
    env: Env<'a>,
    handle: ResourceArc<SpkResource>,
    planet_name: String,
    kind_name: String,
    start: Term<'a>,
    end: Term<'a>,
    step_seconds: f64,
    time_tolerance_seconds: f64,
) -> NifResult<Term<'a>> {
    let start = instant(start)?;
    let end = instant(end)?;
    let planet = planet(&planet_name)?;
    let kind = planetary_kind(&kind_name)?;
    Ok(
        match planetary_events(
            source_spk(&handle),
            planet,
            kind,
            start,
            end,
            step_seconds,
            time_tolerance_seconds,
        ) {
            Ok(events) => {
                let rows: Vec<PlanetaryTerm> = events
                    .into_iter()
                    .map(|event| PlanetaryTerm {
                        unix_microseconds: event.time.unix_microseconds(),
                        planet: planet_label(event.planet).to_string(),
                        kind: planetary_kind_label(event.kind).to_string(),
                        elongation_deg: event.elongation_deg,
                    })
                    .collect();
                (atoms::ok(), rows).encode(env)
            }
            Err(error) => encode_error(env, error),
        },
    )
}

#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
fn almanac_meridian_transits_analytic<'a>(
    env: Env<'a>,
    body: String,
    lat_deg: f64,
    lon_deg: f64,
    alt_km: f64,
    start: Term<'a>,
    end: Term<'a>,
    step_seconds: f64,
    time_tolerance_seconds: f64,
) -> NifResult<Term<'a>> {
    almanac_meridian_transits_impl(
        env,
        source_analytic(),
        body,
        lat_deg,
        lon_deg,
        alt_km,
        start,
        end,
        step_seconds,
        time_tolerance_seconds,
    )
}

#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
fn almanac_meridian_transits_spk<'a>(
    env: Env<'a>,
    handle: ResourceArc<SpkResource>,
    body: String,
    lat_deg: f64,
    lon_deg: f64,
    alt_km: f64,
    start: Term<'a>,
    end: Term<'a>,
    step_seconds: f64,
    time_tolerance_seconds: f64,
) -> NifResult<Term<'a>> {
    almanac_meridian_transits_impl(
        env,
        source_spk(&handle),
        body,
        lat_deg,
        lon_deg,
        alt_km,
        start,
        end,
        step_seconds,
        time_tolerance_seconds,
    )
}

#[allow(clippy::too_many_arguments)]
fn almanac_meridian_transits_impl<'a>(
    env: Env<'a>,
    source: EphemerisSource<'_>,
    body: String,
    lat_deg: f64,
    lon_deg: f64,
    alt_km: f64,
    start: Term<'a>,
    end: Term<'a>,
    step_seconds: f64,
    time_tolerance_seconds: f64,
) -> NifResult<Term<'a>> {
    let start = instant(start)?;
    let end = instant(end)?;
    Ok(
        match meridian_transits(
            source,
            transit_body(&body)?,
            &station(lat_deg, lon_deg, alt_km),
            start,
            end,
            step_seconds,
            time_tolerance_seconds,
        ) {
            Ok(events) => {
                let rows: Vec<TransitTerm> = events
                    .into_iter()
                    .map(|event| TransitTerm {
                        unix_microseconds: event.time.unix_microseconds(),
                        kind: culmination_label(event.kind).to_string(),
                        altitude_deg: event.altitude_deg,
                    })
                    .collect();
                (atoms::ok(), rows).encode(env)
            }
            Err(error) => encode_error(env, error),
        },
    )
}

#[rustler::nif(schedule = "DirtyCpu")]
fn almanac_lunar_solar_eclipses_analytic<'a>(
    env: Env<'a>,
    start: Term<'a>,
    end: Term<'a>,
    step_seconds: f64,
    time_tolerance_seconds: f64,
) -> NifResult<Term<'a>> {
    almanac_lunar_solar_eclipses_impl(
        env,
        source_analytic(),
        start,
        end,
        step_seconds,
        time_tolerance_seconds,
    )
}

#[rustler::nif(schedule = "DirtyCpu")]
fn almanac_lunar_solar_eclipses_spk<'a>(
    env: Env<'a>,
    handle: ResourceArc<SpkResource>,
    start: Term<'a>,
    end: Term<'a>,
    step_seconds: f64,
    time_tolerance_seconds: f64,
) -> NifResult<Term<'a>> {
    almanac_lunar_solar_eclipses_impl(
        env,
        source_spk(&handle),
        start,
        end,
        step_seconds,
        time_tolerance_seconds,
    )
}

fn almanac_lunar_solar_eclipses_impl<'a>(
    env: Env<'a>,
    source: EphemerisSource<'_>,
    start: Term<'a>,
    end: Term<'a>,
    step_seconds: f64,
    time_tolerance_seconds: f64,
) -> NifResult<Term<'a>> {
    let start = instant(start)?;
    let end = instant(end)?;
    Ok(
        match lunar_solar_eclipses(source, start, end, step_seconds, time_tolerance_seconds) {
            Ok(events) => {
                let rows: Vec<EclipseTerm> = events
                    .into_iter()
                    .map(|event| EclipseTerm {
                        maximum_unix_microseconds: event.time_maximum.unix_microseconds(),
                        kind: eclipse_label(event.kind).to_string(),
                        magnitude: event.magnitude,
                        moon_latitude_deg: event.moon_latitude_deg,
                        gamma: event.gamma,
                        uncertain: event.uncertain,
                    })
                    .collect();
                (atoms::ok(), rows).encode(env)
            }
            Err(error) => encode_error(env, error),
        },
    )
}
