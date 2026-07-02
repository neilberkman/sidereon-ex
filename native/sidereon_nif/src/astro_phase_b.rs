use rustler::{Encoder, Env, Error, NifResult, ResourceArc, Term};
use sidereon_core::astro::anomaly;
use sidereon_core::astro::elements::{ClassicalElements, OrbitType};
use sidereon_core::astro::equinoctial::{
    coe2eq, coe2mee, eq2coe, eq2mee, eq2rv, mee2coe, mee2eq, mee2rv, rv2eq, rv2mee,
    EquinoctialElements, ModifiedEquinoctialElements, RetrogradeFactor,
};
use sidereon_core::astro::relative;
use sidereon_core::astro::state::CartesianState;
use sidereon_core::ephemeris::{self, EphemerisSampleStatus};
use sidereon_core::terrain::{DtedInterpolation, DtedLookupOptions, DtedTerrain, DtedTile};
use sidereon_core::GnssSatelliteId;

use crate::broadcast::BroadcastResource;
use crate::errors;
use crate::sp3::Sp3Resource;

type Vec3 = (f64, f64, f64);
type Mat3Term = ((f64, f64, f64), (f64, f64, f64), (f64, f64, f64));
type Mat6Term = (
    (f64, f64, f64, f64, f64, f64),
    (f64, f64, f64, f64, f64, f64),
    (f64, f64, f64, f64, f64, f64),
    (f64, f64, f64, f64, f64, f64),
    (f64, f64, f64, f64, f64, f64),
    (f64, f64, f64, f64, f64, f64),
);

mod atoms {
    rustler::atoms! {
        ok,
        error,
        invalid_input
    }
}

#[derive(Debug, Clone, rustler::NifMap)]
struct ClassicalTerm {
    p: f64,
    a: f64,
    ecc: f64,
    incl: f64,
    raan: Option<f64>,
    argp: Option<f64>,
    nu: Option<f64>,
    arglat: Option<f64>,
    truelon: Option<f64>,
    lonper: Option<f64>,
    orbit_type: String,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct KeplerSolutionTerm {
    anomaly: f64,
    iterations: i64,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct EquinoctialTerm {
    a: f64,
    h: f64,
    k: f64,
    p: f64,
    q: f64,
    lambda: f64,
    retrograde: String,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct ModifiedEquinoctialTerm {
    p: f64,
    f: f64,
    g: f64,
    h: f64,
    k: f64,
    l: f64,
    retrograde: String,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct CartesianStateTerm {
    epoch_tdb_seconds: f64,
    position_km: Vec3,
    velocity_km_s: Vec3,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct EphemerisSampleRowTerm {
    satellite_id: String,
    epoch_j2000_s: f64,
    status: String,
    position_ecef_m: Option<Vec3>,
    clock_s: Option<f64>,
}

pub struct DtedTerrainResource {
    terrain: std::sync::Mutex<DtedTerrain>,
}

pub struct DtedTileResource {
    tile: DtedTile,
}

#[rustler::resource_impl]
impl rustler::Resource for DtedTerrainResource {}

#[rustler::resource_impl]
impl rustler::Resource for DtedTileResource {}

fn finite(value: f64) -> Option<f64> {
    value.is_finite().then_some(value)
}

fn orbit_type_name(orbit_type: OrbitType) -> &'static str {
    match orbit_type {
        OrbitType::EllipticalInclined => "elliptical_inclined",
        OrbitType::EllipticalEquatorial => "elliptical_equatorial",
        OrbitType::CircularInclined => "circular_inclined",
        OrbitType::CircularEquatorial => "circular_equatorial",
    }
}

fn orbit_type_from_name(name: &str) -> Option<OrbitType> {
    Some(match name {
        "elliptical_inclined" => OrbitType::EllipticalInclined,
        "elliptical_equatorial" => OrbitType::EllipticalEquatorial,
        "circular_inclined" => OrbitType::CircularInclined,
        "circular_equatorial" => OrbitType::CircularEquatorial,
        _ => return None,
    })
}

fn classical_from_term(term: ClassicalTerm) -> NifResult<ClassicalElements> {
    let orbit_type = orbit_type_from_name(&term.orbit_type)
        .ok_or_else(|| Error::Term(Box::new("unknown orbit_type")))?;
    Ok(ClassicalElements {
        p: term.p,
        a: term.a,
        ecc: term.ecc,
        incl: term.incl,
        raan: term.raan.unwrap_or(0.0),
        argp: term.argp.unwrap_or(0.0),
        nu: term.nu.unwrap_or(0.0),
        arglat: term.arglat.unwrap_or(0.0),
        truelon: term.truelon.unwrap_or(0.0),
        lonper: term.lonper.unwrap_or(0.0),
        orbit_type,
    })
}

fn classical_to_term(coe: ClassicalElements) -> ClassicalTerm {
    ClassicalTerm {
        p: coe.p,
        a: coe.a,
        ecc: coe.ecc,
        incl: coe.incl,
        raan: finite(coe.raan),
        argp: finite(coe.argp),
        nu: finite(coe.nu),
        arglat: finite(coe.arglat),
        truelon: finite(coe.truelon),
        lonper: finite(coe.lonper),
        orbit_type: orbit_type_name(coe.orbit_type).to_string(),
    }
}

fn factor_from_name(name: &str) -> NifResult<RetrogradeFactor> {
    Ok(match name {
        "prograde" => RetrogradeFactor::Prograde,
        "retrograde" => RetrogradeFactor::Retrograde,
        _ => return Err(Error::Term(Box::new("unknown retrograde factor"))),
    })
}

fn factor_name(factor: RetrogradeFactor) -> String {
    match factor {
        RetrogradeFactor::Prograde => "prograde",
        RetrogradeFactor::Retrograde => "retrograde",
    }
    .to_string()
}

fn eq_from_term(term: EquinoctialTerm) -> NifResult<EquinoctialElements> {
    Ok(EquinoctialElements {
        a: term.a,
        h: term.h,
        k: term.k,
        p: term.p,
        q: term.q,
        lambda: term.lambda,
        retrograde: factor_from_name(&term.retrograde)?,
    })
}

fn eq_to_term(eq: EquinoctialElements) -> EquinoctialTerm {
    EquinoctialTerm {
        a: eq.a,
        h: eq.h,
        k: eq.k,
        p: eq.p,
        q: eq.q,
        lambda: eq.lambda,
        retrograde: factor_name(eq.retrograde),
    }
}

fn mee_from_term(term: ModifiedEquinoctialTerm) -> NifResult<ModifiedEquinoctialElements> {
    Ok(ModifiedEquinoctialElements {
        p: term.p,
        f: term.f,
        g: term.g,
        h: term.h,
        k: term.k,
        l: term.l,
        retrograde: factor_from_name(&term.retrograde)?,
    })
}

fn mee_to_term(mee: ModifiedEquinoctialElements) -> ModifiedEquinoctialTerm {
    ModifiedEquinoctialTerm {
        p: mee.p,
        f: mee.f,
        g: mee.g,
        h: mee.h,
        k: mee.k,
        l: mee.l,
        retrograde: factor_name(mee.retrograde),
    }
}

fn state_from_term(term: CartesianStateTerm) -> CartesianState {
    CartesianState::new(
        term.epoch_tdb_seconds,
        [term.position_km.0, term.position_km.1, term.position_km.2],
        [
            term.velocity_km_s.0,
            term.velocity_km_s.1,
            term.velocity_km_s.2,
        ],
    )
}

fn state_to_term(state: CartesianState) -> CartesianStateTerm {
    let p = state.position_array();
    let v = state.velocity_array();
    CartesianStateTerm {
        epoch_tdb_seconds: state.epoch_tdb_seconds,
        position_km: (p[0], p[1], p[2]),
        velocity_km_s: (v[0], v[1], v[2]),
    }
}

fn vec3(tuple: Vec3) -> [f64; 3] {
    [tuple.0, tuple.1, tuple.2]
}

fn tuple3(array: [f64; 3]) -> Vec3 {
    (array[0], array[1], array[2])
}

fn mat3(matrix: [[f64; 3]; 3]) -> Mat3Term {
    (
        (matrix[0][0], matrix[0][1], matrix[0][2]),
        (matrix[1][0], matrix[1][1], matrix[1][2]),
        (matrix[2][0], matrix[2][1], matrix[2][2]),
    )
}

fn mat6(matrix: [[f64; 6]; 6]) -> Mat6Term {
    (
        (
            matrix[0][0],
            matrix[0][1],
            matrix[0][2],
            matrix[0][3],
            matrix[0][4],
            matrix[0][5],
        ),
        (
            matrix[1][0],
            matrix[1][1],
            matrix[1][2],
            matrix[1][3],
            matrix[1][4],
            matrix[1][5],
        ),
        (
            matrix[2][0],
            matrix[2][1],
            matrix[2][2],
            matrix[2][3],
            matrix[2][4],
            matrix[2][5],
        ),
        (
            matrix[3][0],
            matrix[3][1],
            matrix[3][2],
            matrix[3][3],
            matrix[3][4],
            matrix[3][5],
        ),
        (
            matrix[4][0],
            matrix[4][1],
            matrix[4][2],
            matrix[4][3],
            matrix[4][4],
            matrix[4][5],
        ),
        (
            matrix[5][0],
            matrix[5][1],
            matrix[5][2],
            matrix[5][3],
            matrix[5][4],
            matrix[5][5],
        ),
    )
}

fn sat_id(token: &str) -> NifResult<GnssSatelliteId> {
    if token.len() < 2 {
        return Err(Error::Term(Box::new("invalid satellite id")));
    }
    let (system, prn) = token.split_at(1);
    let system = crate::sp3::system_from_letter(system)?;
    let prn: u8 = prn
        .parse()
        .map_err(|_| Error::Term(Box::new("invalid satellite prn")))?;
    GnssSatelliteId::new(system, prn).map_err(errors::invalid_input)
}

fn sample_row(row: ephemeris::EphemerisSampleRow) -> EphemerisSampleRowTerm {
    let status = match row.status {
        EphemerisSampleStatus::Valid => "valid",
        EphemerisSampleStatus::Gap => "gap",
    }
    .to_string();
    EphemerisSampleRowTerm {
        satellite_id: row.sat.to_string(),
        epoch_j2000_s: row.epoch_j2000_s,
        status,
        position_ecef_m: row.position_ecef_m.map(tuple3),
        clock_s: row.clock_s,
    }
}

fn encode_float_result<'a>(env: Env<'a>, result: Result<f64, anomaly::AnomalyError>) -> Term<'a> {
    match result {
        Ok(value) => (atoms::ok(), value).encode(env),
        Err(_) => (atoms::error(), atoms::invalid_input()).encode(env),
    }
}

#[rustler::nif]
fn anomaly_mean_to_eccentric<'a>(env: Env<'a>, mean_anom: f64, ecc: f64) -> Term<'a> {
    encode_float_result(env, anomaly::mean_to_eccentric(mean_anom, ecc))
}

#[rustler::nif]
fn anomaly_eccentric_to_mean<'a>(env: Env<'a>, ecc_anom: f64, ecc: f64) -> Term<'a> {
    encode_float_result(env, anomaly::eccentric_to_mean(ecc_anom, ecc))
}

#[rustler::nif]
fn anomaly_eccentric_to_true<'a>(env: Env<'a>, ecc_anom: f64, ecc: f64) -> Term<'a> {
    encode_float_result(env, anomaly::eccentric_to_true(ecc_anom, ecc))
}

#[rustler::nif]
fn anomaly_true_to_eccentric<'a>(env: Env<'a>, true_anom: f64, ecc: f64) -> Term<'a> {
    encode_float_result(env, anomaly::true_to_eccentric(true_anom, ecc))
}

#[rustler::nif]
fn anomaly_mean_to_true<'a>(env: Env<'a>, mean_anom: f64, ecc: f64) -> Term<'a> {
    encode_float_result(env, anomaly::mean_to_true(mean_anom, ecc))
}

#[rustler::nif]
fn anomaly_true_to_mean<'a>(env: Env<'a>, true_anom: f64, ecc: f64) -> Term<'a> {
    encode_float_result(env, anomaly::true_to_mean(true_anom, ecc))
}

#[rustler::nif]
fn anomaly_solve_kepler<'a>(env: Env<'a>, mean_anom: f64, ecc: f64) -> Term<'a> {
    match anomaly::solve_kepler(mean_anom, ecc) {
        Ok(solution) => (
            atoms::ok(),
            KeplerSolutionTerm {
                anomaly: solution.anomaly,
                iterations: solution.iterations as i64,
            },
        )
            .encode(env),
        Err(_) => (atoms::error(), atoms::invalid_input()).encode(env),
    }
}

#[rustler::nif]
fn anomaly_propagate_kepler<'a>(
    env: Env<'a>,
    elements: ClassicalTerm,
    mu: f64,
    dt: f64,
) -> NifResult<Term<'a>> {
    let elements = classical_from_term(elements)?;
    Ok(match anomaly::propagate_kepler(&elements, mu, dt) {
        Ok(out) => (atoms::ok(), classical_to_term(out)).encode(env),
        Err(_) => (atoms::error(), atoms::invalid_input()).encode(env),
    })
}

#[rustler::nif]
fn equinoctial_coe2eq<'a>(env: Env<'a>, coe: ClassicalTerm, factor: String) -> NifResult<Term<'a>> {
    let coe = classical_from_term(coe)?;
    let factor = factor_from_name(&factor)?;
    Ok(match coe2eq(&coe, factor) {
        Ok(eq) => (atoms::ok(), eq_to_term(eq)).encode(env),
        Err(_) => (atoms::error(), atoms::invalid_input()).encode(env),
    })
}

#[rustler::nif]
fn equinoctial_eq2coe<'a>(env: Env<'a>, eq: EquinoctialTerm) -> NifResult<Term<'a>> {
    let eq = eq_from_term(eq)?;
    Ok(match eq2coe(&eq) {
        Ok(coe) => (atoms::ok(), classical_to_term(coe)).encode(env),
        Err(_) => (atoms::error(), atoms::invalid_input()).encode(env),
    })
}

#[rustler::nif]
fn equinoctial_coe2mee<'a>(
    env: Env<'a>,
    coe: ClassicalTerm,
    factor: String,
) -> NifResult<Term<'a>> {
    let coe = classical_from_term(coe)?;
    let factor = factor_from_name(&factor)?;
    Ok(match coe2mee(&coe, factor) {
        Ok(mee) => (atoms::ok(), mee_to_term(mee)).encode(env),
        Err(_) => (atoms::error(), atoms::invalid_input()).encode(env),
    })
}

#[rustler::nif]
fn equinoctial_mee2coe<'a>(env: Env<'a>, mee: ModifiedEquinoctialTerm) -> NifResult<Term<'a>> {
    let mee = mee_from_term(mee)?;
    Ok(match mee2coe(&mee) {
        Ok(coe) => (atoms::ok(), classical_to_term(coe)).encode(env),
        Err(_) => (atoms::error(), atoms::invalid_input()).encode(env),
    })
}

#[rustler::nif]
fn equinoctial_rv2eq<'a>(
    env: Env<'a>,
    r: Vec3,
    v: Vec3,
    mu: f64,
    factor: String,
) -> NifResult<Term<'a>> {
    let factor = factor_from_name(&factor)?;
    Ok(match rv2eq(vec3(r), vec3(v), mu, factor) {
        Ok(eq) => (atoms::ok(), eq_to_term(eq)).encode(env),
        Err(_) => (atoms::error(), atoms::invalid_input()).encode(env),
    })
}

#[rustler::nif]
fn equinoctial_eq2rv(eq: EquinoctialTerm, mu: f64) -> NifResult<(Vec3, Vec3)> {
    let eq = eq_from_term(eq)?;
    let (r, v) = eq2rv(&eq, mu).map_err(errors::invalid_input)?;
    Ok((tuple3(r), tuple3(v)))
}

#[rustler::nif]
fn equinoctial_rv2mee<'a>(
    env: Env<'a>,
    r: Vec3,
    v: Vec3,
    mu: f64,
    factor: String,
) -> NifResult<Term<'a>> {
    let factor = factor_from_name(&factor)?;
    Ok(match rv2mee(vec3(r), vec3(v), mu, factor) {
        Ok(mee) => (atoms::ok(), mee_to_term(mee)).encode(env),
        Err(_) => (atoms::error(), atoms::invalid_input()).encode(env),
    })
}

#[rustler::nif]
fn equinoctial_mee2rv(mee: ModifiedEquinoctialTerm, mu: f64) -> NifResult<(Vec3, Vec3)> {
    let mee = mee_from_term(mee)?;
    let (r, v) = mee2rv(&mee, mu).map_err(errors::invalid_input)?;
    Ok((tuple3(r), tuple3(v)))
}

#[rustler::nif]
fn equinoctial_eq2mee<'a>(env: Env<'a>, eq: EquinoctialTerm) -> NifResult<Term<'a>> {
    let eq = eq_from_term(eq)?;
    Ok(match eq2mee(&eq) {
        Ok(mee) => (atoms::ok(), mee_to_term(mee)).encode(env),
        Err(_) => (atoms::error(), atoms::invalid_input()).encode(env),
    })
}

#[rustler::nif]
fn equinoctial_mee2eq<'a>(env: Env<'a>, mee: ModifiedEquinoctialTerm) -> NifResult<Term<'a>> {
    let mee = mee_from_term(mee)?;
    Ok(match mee2eq(&mee) {
        Ok(eq) => (atoms::ok(), eq_to_term(eq)).encode(env),
        Err(_) => (atoms::error(), atoms::invalid_input()).encode(env),
    })
}

#[rustler::nif]
fn relative_rotation(frame: String, chief: CartesianStateTerm) -> NifResult<Mat3Term> {
    let chief = state_from_term(chief);
    let matrix = match frame.as_str() {
        "rsw" => relative::rsw_to_inertial_rotation(&chief),
        "rtn" => relative::rtn_to_inertial_rotation(&chief),
        "ric" => relative::ric_to_inertial_rotation(&chief),
        "lvlh" => relative::lvlh_to_inertial_rotation(&chief),
        _ => return Err(Error::Term(Box::new("unknown relative frame"))),
    }
    .map_err(errors::invalid_input)?;
    Ok(mat3(matrix))
}

#[rustler::nif]
fn relative_state<'a>(
    env: Env<'a>,
    chief: CartesianStateTerm,
    deputy: CartesianStateTerm,
) -> NifResult<Term<'a>> {
    let chief = state_from_term(chief);
    let deputy = state_from_term(deputy);
    Ok(match relative::relative_state(&chief, &deputy) {
        Ok(state) => (atoms::ok(), state_to_term(state)).encode(env),
        Err(_) => (atoms::error(), atoms::invalid_input()).encode(env),
    })
}

#[rustler::nif]
fn relative_absolute_from_relative<'a>(
    env: Env<'a>,
    chief: CartesianStateTerm,
    rel: CartesianStateTerm,
) -> NifResult<Term<'a>> {
    let chief = state_from_term(chief);
    let rel = state_from_term(rel);
    Ok(match relative::absolute_from_relative(&chief, &rel) {
        Ok(state) => (atoms::ok(), state_to_term(state)).encode(env),
        Err(_) => (atoms::error(), atoms::invalid_input()).encode(env),
    })
}

#[rustler::nif]
fn relative_cw_stm(n: f64, dt: f64) -> NifResult<Mat6Term> {
    relative::cw_stm(n, dt)
        .map(mat6)
        .map_err(errors::invalid_input)
}

#[rustler::nif]
fn relative_cw_propagate<'a>(
    env: Env<'a>,
    rel_state: CartesianStateTerm,
    n: f64,
    dt: f64,
) -> NifResult<Term<'a>> {
    let rel_state = state_from_term(rel_state);
    Ok(match relative::cw_propagate(&rel_state, n, dt) {
        Ok(state) => (atoms::ok(), state_to_term(state)).encode(env),
        Err(_) => (atoms::error(), atoms::invalid_input()).encode(env),
    })
}

#[rustler::nif]
fn relative_mean_motion_circular(radius_km: f64) -> NifResult<f64> {
    relative::mean_motion_circular(radius_km).map_err(errors::invalid_input)
}

#[rustler::nif]
fn relative_mean_motion_from_state(chief: CartesianStateTerm) -> NifResult<f64> {
    let chief = state_from_term(chief);
    relative::mean_motion_from_state(&chief).map_err(errors::invalid_input)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn ephemeris_sample_sp3(
    handle: ResourceArc<Sp3Resource>,
    satellites: Vec<String>,
    start_j2000_s: f64,
    stop_j2000_s: f64,
    step_s: f64,
) -> NifResult<Vec<EphemerisSampleRowTerm>> {
    let sats: Vec<GnssSatelliteId> = satellites
        .iter()
        .map(|sat| sat_id(sat))
        .collect::<NifResult<_>>()?;
    let rows = ephemeris::sample(&handle.sp3, &sats, start_j2000_s, stop_j2000_s, step_s)
        .map_err(errors::invalid_input)?;
    Ok(rows.into_iter().map(sample_row).collect())
}

#[rustler::nif(schedule = "DirtyCpu")]
fn ephemeris_sample_broadcast(
    handle: ResourceArc<BroadcastResource>,
    satellites: Vec<String>,
    start_j2000_s: f64,
    stop_j2000_s: f64,
    step_s: f64,
) -> NifResult<Vec<EphemerisSampleRowTerm>> {
    let sats: Vec<GnssSatelliteId> = satellites
        .iter()
        .map(|sat| sat_id(sat))
        .collect::<NifResult<_>>()?;
    let rows = ephemeris::sample(&handle.store, &sats, start_j2000_s, stop_j2000_s, step_s)
        .map_err(errors::invalid_input)?;
    Ok(rows.into_iter().map(sample_row).collect())
}

#[rustler::nif(schedule = "DirtyCpu")]
fn terrain_dted_new(root: String) -> ResourceArc<DtedTerrainResource> {
    ResourceArc::new(DtedTerrainResource {
        terrain: std::sync::Mutex::new(DtedTerrain::new(root)),
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn terrain_dted_height<'a>(
    env: Env<'a>,
    handle: ResourceArc<DtedTerrainResource>,
    longitude_deg: f64,
    latitude_deg: f64,
    interpolation: String,
) -> NifResult<Term<'a>> {
    let interpolation = match interpolation.as_str() {
        "nearest_posting" => DtedInterpolation::NearestPosting,
        "bilinear" => DtedInterpolation::Bilinear,
        _ => return Err(Error::Term(Box::new("unknown DTED interpolation"))),
    };
    let mut terrain = handle
        .terrain
        .lock()
        .map_err(|_| Error::Term(Box::new("terrain lock poisoned")))?;
    Ok(
        match terrain.height_m_with_options(
            longitude_deg,
            latitude_deg,
            DtedLookupOptions { interpolation },
        ) {
            Ok(height) => (atoms::ok(), height).encode(env),
            Err(_) => (atoms::error(), atoms::invalid_input()).encode(env),
        },
    )
}

#[rustler::nif(schedule = "DirtyCpu")]
fn terrain_dted_tile_load(path: String) -> NifResult<ResourceArc<DtedTileResource>> {
    let tile = DtedTile::from_path(path).map_err(|e| Error::Term(Box::new(e)))?;
    Ok(ResourceArc::new(DtedTileResource { tile }))
}

#[rustler::nif]
fn terrain_dted_tile_elevation<'a>(
    env: Env<'a>,
    handle: ResourceArc<DtedTileResource>,
    longitude_deg: f64,
    latitude_deg: f64,
) -> Term<'a> {
    match handle.tile.get_elevation(longitude_deg, latitude_deg) {
        Ok(height) => (atoms::ok(), height as i64).encode(env),
        Err(_) => (atoms::error(), atoms::invalid_input()).encode(env),
    }
}
