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
use sidereon_core::terrain::{
    DtedInterpolation, DtedLookupOptions, DtedTerrain, DtedTile, DtedTileError,
};
use sidereon_core::GnssSatelliteId;

use crate::broadcast::BroadcastResource;
use crate::errors;
use crate::sp3::Sp3Resource;
use crate::spp::atom_from;

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
        // Core uses non-finite angle values as the sentinel for orbital angles
        // that are undefined for circular and/or equatorial orbit classes.
        // Preserve Elixir's nil values across every classical-element call so
        // classical_to_term can map the untouched sentinels back to nil.
        raan: term.raan.unwrap_or(f64::NAN),
        argp: term.argp.unwrap_or(f64::NAN),
        nu: term.nu.unwrap_or(f64::NAN),
        arglat: term.arglat.unwrap_or(f64::NAN),
        truelon: term.truelon.unwrap_or(f64::NAN),
        lonper: term.lonper.unwrap_or(f64::NAN),
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
    let mut lookup_options = DtedLookupOptions::default();
    lookup_options.interpolation = interpolation;
    Ok(dted_height_term(
        env,
        terrain.height_m_with_options(longitude_deg, latitude_deg, lookup_options),
    ))
}

/// A DTED terrain lookup result: `{:ok, height_m}`, the typed reason for an
/// unknown elevation, a tile on another horizontal datum or a missing tile, or
/// `{:error, :invalid_input}` for a query the lookup refuses.
fn dted_height_term<'a>(env: Env<'a>, result: sidereon_core::Result<f64>) -> Term<'a> {
    match result {
        Ok(height) => (atoms::ok(), height).encode(env),
        Err(error) => match crate::terrain_store::terrain_lookup_error_term(env, &error) {
            Some(reason) => (atoms::error(), reason).encode(env),
            None => (atoms::error(), atoms::invalid_input()).encode(env),
        },
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn terrain_dted_height_batch<'a>(
    env: Env<'a>,
    handle: ResourceArc<DtedTerrainResource>,
    points: Vec<(f64, f64)>,
    interpolation: String,
) -> NifResult<Vec<Term<'a>>> {
    let interpolation = match interpolation.as_str() {
        "nearest_posting" => DtedInterpolation::NearestPosting,
        "bilinear" => DtedInterpolation::Bilinear,
        _ => return Err(Error::Term(Box::new("unknown DTED interpolation"))),
    };
    let mut terrain = handle
        .terrain
        .lock()
        .map_err(|_| Error::Term(Box::new("terrain lock poisoned")))?;
    let mut lookup_options = DtedLookupOptions::default();
    lookup_options.interpolation = interpolation;
    Ok(terrain
        .height_batch(&points, lookup_options)
        .into_iter()
        .map(|result| dted_height_term(env, result))
        .collect())
}

/// Load one DTED tile: `{:ok, resource}` or `{:error, reason}` with the typed
/// [`DtedTileError`] reason.
#[rustler::nif(schedule = "DirtyCpu")]
fn terrain_dted_tile_load<'a>(env: Env<'a>, path: String) -> Term<'a> {
    match DtedTile::from_path(path) {
        Ok(tile) => (atoms::ok(), ResourceArc::new(DtedTileResource { tile })).encode(env),
        Err(error) => (atoms::error(), dted_tile_error_term(env, &error)).encode(env),
    }
}

#[rustler::nif]
fn terrain_dted_tile_elevation<'a>(
    env: Env<'a>,
    handle: ResourceArc<DtedTileResource>,
    longitude_deg: f64,
    latitude_deg: f64,
) -> Term<'a> {
    match handle.tile.get_elevation(longitude_deg, latitude_deg) {
        Ok(height) => (atoms::ok(), i64::from(height)).encode(env),
        Err(error) => (atoms::error(), dted_tile_error_term(env, &error)).encode(env),
    }
}

/// The horizontal datum the tile's DSI record states.
#[rustler::nif]
fn terrain_dted_tile_horizontal_datum<'a>(
    env: Env<'a>,
    handle: ResourceArc<DtedTileResource>,
) -> Term<'a> {
    crate::terrain_store::horizontal_datum_term(env, handle.tile.horizontal_datum())
}

/// A [`DtedTileError`] as `{tag, fields}`: a bare tag for a variant with no
/// fields, the text for the two message variants, and a tuple of the fields in
/// declaration order otherwise.
pub(crate) fn dted_tile_error_term<'a>(env: Env<'a>, error: &DtedTileError) -> Term<'a> {
    let tag = |name: &str| atom_from(env, name);
    match error {
        DtedTileError::Io { path, message } => {
            (tag("io"), (path.as_str(), message.as_str())).encode(env)
        }
        DtedTileError::TooShort { path } => (tag("too_short"), path.as_str()).encode(env),
        DtedTileError::MissingUhl1 { path } => (tag("missing_uhl1"), path.as_str()).encode(env),
        DtedTileError::InvalidEncoding(message) => {
            (tag("invalid_encoding"), message.as_str()).encode(env)
        }
        DtedTileError::InvalidField(message) => {
            (tag("invalid_field"), message.as_str()).encode(env)
        }
        DtedTileError::InvalidDimensions {
            path,
            lon_count,
            lat_count,
        } => (
            tag("invalid_dimensions"),
            (path.as_str(), *lon_count, *lat_count),
        )
            .encode(env),
        DtedTileError::Truncated {
            path,
            actual,
            expected,
        } => (tag("truncated"), (path.as_str(), *actual, *expected)).encode(env),
        DtedTileError::Outside {
            longitude,
            latitude,
            origin_longitude,
            origin_latitude,
        } => (
            tag("outside"),
            (*longitude, *latitude, *origin_longitude, *origin_latitude),
        )
            .encode(env),
        DtedTileError::PostingIndexOutOfBounds {
            longitude_index,
            latitude_index,
        } => (
            tag("posting_index_out_of_bounds"),
            (*longitude_index, *latitude_index),
        )
            .encode(env),
        DtedTileError::MissingDataSentinel { longitude_index } => {
            (tag("missing_data_sentinel"), *longitude_index).encode(env)
        }
        DtedTileError::Checksum {
            longitude_index,
            checksum,
            sum,
        } => (tag("checksum"), (*longitude_index, *checksum, *sum)).encode(env),
        DtedTileError::EmptyCoordinate => tag("empty_coordinate"),
        DtedTileError::InvalidHemisphere { hemisphere } => {
            (tag("invalid_hemisphere"), hemisphere.to_string()).encode(env)
        }
        DtedTileError::NegativePostingIndex { index } => {
            (tag("negative_posting_index"), *index).encode(env)
        }
        DtedTileError::CoordinateOutOfRange { field, text } => {
            (tag("coordinate_out_of_range"), (*field, text.as_str())).encode(env)
        }
        DtedTileError::WrongHemisphere {
            field,
            hemisphere,
            expected,
        } => (
            tag("wrong_hemisphere"),
            (*field, hemisphere.to_string(), *expected),
        )
            .encode(env),
        DtedTileError::OriginNotWholeDegree { field, text } => {
            (tag("origin_not_whole_degree"), (*field, text.as_str())).encode(env)
        }
        DtedTileError::IntervalCountMismatch {
            field,
            interval_tenths_arcsec,
            count,
        } => (
            tag("interval_count_mismatch"),
            (*field, *interval_tenths_arcsec, *count),
        )
            .encode(env),
        DtedTileError::ProfileLongitudeCountMismatch {
            longitude_index,
            declared,
        } => (
            tag("profile_longitude_count_mismatch"),
            (*longitude_index, *declared),
        )
            .encode(env),
        DtedTileError::UnsupportedPartialProfile {
            longitude_index,
            first_latitude_index,
        } => (
            tag("unsupported_partial_profile"),
            (*longitude_index, *first_latitude_index),
        )
            .encode(env),
        DtedTileError::NullPosting {
            longitude_index,
            latitude_index,
        } => (tag("null_posting"), (*longitude_index, *latitude_index)).encode(env),
        other => (tag("other"), other.to_string()).encode(env),
    }
}
