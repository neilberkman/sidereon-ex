use crate::errors::{encode_result, Refusal};
use crate::vector_tuple;
use rustler::{Binary, Encoder, Env, NifMap, NifUnitEnum, ResourceArc, Term};
use sidereon_core::astro::de::{DeBody, DeEphemeris, DeError, DeState};

pub(crate) struct DeResource(pub std::sync::Arc<DeEphemeris>);

#[rustler::resource_impl]
impl rustler::Resource for DeResource {}

#[derive(NifUnitEnum)]
enum Body {
    Sun,
    Mercury,
    Venus,
    EarthMoon,
    Earth,
    Moon,
    Mars,
    Jupiter,
    Saturn,
    Uranus,
    Neptune,
    Pluto,
    SolarSystem,
}

impl From<Body> for DeBody {
    fn from(body: Body) -> Self {
        match body {
            Body::Sun => Self::Sun,
            Body::Mercury => Self::Mercury,
            Body::Venus => Self::Venus,
            Body::EarthMoon => Self::EarthMoon,
            Body::Earth => Self::Earth,
            Body::Moon => Self::Moon,
            Body::Mars => Self::Mars,
            Body::Jupiter => Self::Jupiter,
            Body::Saturn => Self::Saturn,
            Body::Uranus => Self::Uranus,
            Body::Neptune => Self::Neptune,
            Body::Pluto => Self::Pluto,
            Body::SolarSystem => Self::SolarSystem,
        }
    }
}

#[derive(NifMap)]
struct IoDetail {
    message: String,
    raw_os_error: Option<i32>,
}

#[derive(NifMap)]
#[rustler(encode)]
struct InvalidFileDetail {
    reason: &'static str,
}

#[derive(NifMap)]
struct OutsideCoverageDetail {
    epoch_tdb_seconds: f64,
}

#[derive(NifMap)]
struct InvalidBodyDetail<'a> {
    body: Term<'a>,
}

rustler::atoms! {
    io,
    invalid_file,
    non_finite_epoch,
    outside_coverage,
    non_finite_state,
    invalid_body,
    unknown,
}

fn de_error(env: Env<'_>, error: DeError) -> Refusal<'_> {
    let (kind, detail) = match &error {
        DeError::Io(source) => (
            io(),
            IoDetail {
                message: source.to_string(),
                raw_os_error: source.raw_os_error(),
            }
            .encode(env),
        ),
        DeError::InvalidFile(reason) => (invalid_file(), InvalidFileDetail { reason }.encode(env)),
        DeError::NonFiniteEpoch => (non_finite_epoch(), Term::map_new(env)),
        DeError::OutsideCoverage { epoch_tdb_seconds } => (
            outside_coverage(),
            OutsideCoverageDetail {
                epoch_tdb_seconds: *epoch_tdb_seconds,
            }
            .encode(env),
        ),
        DeError::NonFiniteState => (non_finite_state(), Term::map_new(env)),
        _ => (unknown(), Term::map_new(env)),
    };
    Refusal {
        kind,
        detail,
        message: error.to_string(),
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn de_load<'a>(env: Env<'a>, path: String) -> Term<'a> {
    encode_result(
        env,
        DeEphemeris::load(path)
            .map(std::sync::Arc::new)
            .map(DeResource)
            .map(ResourceArc::new)
            .map_err(|error| de_error(env, error)),
    )
}

#[rustler::nif(schedule = "DirtyCpu")]
fn de_from_bytes<'a>(env: Env<'a>, bytes: Binary<'a>) -> Term<'a> {
    encode_result(
        env,
        DeEphemeris::from_bytes(bytes.as_slice())
            .map(std::sync::Arc::new)
            .map(DeResource)
            .map(ResourceArc::new)
            .map_err(|error| de_error(env, error)),
    )
}

#[rustler::nif]
fn de_gm_m3_s2<'a>(env: Env<'a>, ephemeris: ResourceArc<DeResource>, body: Term<'a>) -> Term<'a> {
    let value = body
        .decode::<Body>()
        .map(|body| ephemeris.0.gm_m3_s2(body.into()))
        .map_err(|_| Refusal {
            kind: invalid_body(),
            detail: InvalidBodyDetail { body }.encode(env),
            message: "Invalid DE body".into(),
        });
    encode_result(env, value)
}

#[derive(NifMap)]
struct State {
    position_m: crate::Vec3,
    velocity_m_s: crate::Vec3,
}

impl From<DeState> for State {
    fn from(state: DeState) -> Self {
        Self {
            position_m: vector_tuple(state.position_m),
            velocity_m_s: vector_tuple(state.velocity_m_s),
        }
    }
}

#[rustler::nif]
fn de_sun_moon_at_tdb_seconds(
    env: Env<'_>,
    ephemeris: ResourceArc<DeResource>,
    epoch: f64,
) -> Term<'_> {
    encode_result(
        env,
        ephemeris
            .0
            .sun_moon_at_tdb_seconds(epoch)
            .map(|states| (State::from(states.sun), State::from(states.moon)))
            .map_err(|error| de_error(env, error)),
    )
}

#[rustler::nif]
fn de_sun_moon_positions_at_tdb_seconds(
    env: Env<'_>,
    ephemeris: ResourceArc<DeResource>,
    epoch: f64,
) -> Term<'_> {
    encode_result(
        env,
        ephemeris
            .0
            .sun_moon_positions_at_tdb_seconds(epoch)
            .map(|positions| (vector_tuple(positions.sun), vector_tuple(positions.moon)))
            .map_err(|error| de_error(env, error)),
    )
}

#[rustler::nif]
fn de_version(ephemeris: ResourceArc<DeResource>) -> u32 {
    ephemeris.0.version()
}

#[rustler::nif]
fn de_record_size(ephemeris: ResourceArc<DeResource>) -> usize {
    ephemeris.0.record_size()
}

#[rustler::nif]
fn de_coverage_tdb_seconds(ephemeris: ResourceArc<DeResource>) -> (f64, f64) {
    ephemeris.0.coverage_tdb_seconds()
}

#[rustler::nif]
fn de_constants(env: Env<'_>, ephemeris: ResourceArc<DeResource>) -> rustler::NifResult<Term<'_>> {
    let entries: Vec<_> = ephemeris.0.constants().iter().collect();
    Term::map_from_pairs(env, &entries)
}

#[rustler::nif]
fn de_astronomical_unit_m(ephemeris: ResourceArc<DeResource>) -> f64 {
    ephemeris.0.astronomical_unit_m()
}

#[rustler::nif]
fn de_earth_moon_mass_ratio(ephemeris: ResourceArc<DeResource>) -> f64 {
    ephemeris.0.earth_moon_mass_ratio()
}
