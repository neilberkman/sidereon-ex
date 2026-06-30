use rustler::{Atom, Encoder, Env, NifResult, Term};
use sidereon_core::astro::conjunction::PcMethod;
use sidereon_core::astro::sgp4::JulianDate;
use sidereon_core::astro::tca::{
    find_tca_candidates_between_tles, find_tca_conjunctions_between_tles,
    screen_tca_candidates_from_tle_catalog_parallel, screen_tca_conjunctions_from_tle_catalog_parallel,
    TcaCandidate, TcaConjunction, TcaFinderOptions, TcaPcOptions, TcaScreeningConjunctionHit,
    TcaScreeningHit, TcaTle, TcaWindow,
};

type Vec3 = (f64, f64, f64);
type CandidateTerm = (f64, f64, f64, f64, f64, Vec3, Vec3);
type ConjunctionTerm = (CandidateTerm, f64, f64, f64, f64, f64);
type ScreeningHitTerm = (u64, CandidateTerm);
type ScreeningConjunctionHitTerm = (u64, ConjunctionTerm);

mod atoms {
    rustler::atoms! {
        ok,
        error,
        equal_area,
        numerical,
        alfano_2005,
        foster_equal_area,
        foster_numerical
    }
}

fn tuple3(v: [f64; 3]) -> Vec3 {
    (v[0], v[1], v[2])
}

fn finder_options(coarse_step_seconds: f64, time_tolerance_seconds: f64) -> TcaFinderOptions {
    TcaFinderOptions {
        coarse_step_seconds,
        time_tolerance_seconds,
    }
}

fn tca_window(start_whole: f64, start_fraction: f64, end_whole: f64, end_fraction: f64) -> TcaWindow {
    TcaWindow::new(
        JulianDate(start_whole, start_fraction),
        JulianDate(end_whole, end_fraction),
    )
}

fn method_from_atom(method: Atom) -> NifResult<PcMethod> {
    if method == atoms::equal_area() || method == atoms::foster_equal_area() {
        Ok(PcMethod::FosterEqualArea)
    } else if method == atoms::numerical() || method == atoms::foster_numerical() {
        Ok(PcMethod::FosterNumerical)
    } else if method == atoms::alfano_2005() {
        Ok(PcMethod::Alfano2005)
    } else {
        Err(rustler::Error::BadArg)
    }
}

fn mat3(rows: Option<Vec<Vec<f64>>>) -> NifResult<Option<[[f64; 3]; 3]>> {
    let Some(rows) = rows else {
        return Ok(None);
    };
    if rows.len() != 3 || rows.iter().any(|row| row.len() != 3) {
        return Err(rustler::Error::BadArg);
    }
    Ok(Some([
        [rows[0][0], rows[0][1], rows[0][2]],
        [rows[1][0], rows[1][1], rows[1][2]],
        [rows[2][0], rows[2][1], rows[2][2]],
    ]))
}

fn pc_options(
    hard_body_radius_km: f64,
    method: Atom,
    primary_covariance_km2: Option<Vec<Vec<f64>>>,
    secondary_covariance_km2: Option<Vec<Vec<f64>>>,
) -> NifResult<TcaPcOptions> {
    let method = method_from_atom(method)?;
    match (mat3(primary_covariance_km2)?, mat3(secondary_covariance_km2)?) {
        (Some(primary), Some(secondary)) => Ok(TcaPcOptions::with_covariances(
            hard_body_radius_km,
            method,
            primary,
            secondary,
        )),
        _ => Ok(TcaPcOptions::with_default_covariance(
            hard_body_radius_km,
            method,
        )),
    }
}

fn candidate_term(candidate: TcaCandidate) -> CandidateTerm {
    (
        candidate.tca_time.0,
        candidate.tca_time.1,
        candidate.tca_time.0 + candidate.tca_time.1,
        candidate.tca_seconds_since_window_start,
        candidate.miss_distance_km,
        tuple3(candidate.relative_position_km),
        tuple3(candidate.relative_velocity_km_s),
    )
}

fn conjunction_term(conjunction: TcaConjunction) -> ConjunctionTerm {
    let pc = conjunction.collision_probability;
    (
        candidate_term(conjunction.candidate),
        pc.pc,
        pc.miss_km,
        pc.relative_speed_km_s,
        pc.sigma_x_km,
        pc.sigma_z_km,
    )
}

fn encode_result<'a, T: Encoder>(
    env: Env<'a>,
    result: Result<T, sidereon_core::astro::tca::TcaError>,
) -> Term<'a> {
    match result {
        Ok(value) => (atoms::ok(), value).encode(env),
        Err(error) => (atoms::error(), error.to_string()).encode(env),
    }
}

#[allow(clippy::too_many_arguments)]
pub(crate) fn find_tca_candidates_impl<'a>(
    env: Env<'a>,
    primary_line1: String,
    primary_line2: String,
    secondary_line1: String,
    secondary_line2: String,
    start_whole: f64,
    start_fraction: f64,
    end_whole: f64,
    end_fraction: f64,
    coarse_step_seconds: f64,
    time_tolerance_seconds: f64,
) -> NifResult<Term<'a>> {
    let primary = TcaTle::new(&primary_line1, &primary_line2);
    let secondary = TcaTle::new(&secondary_line1, &secondary_line2);
    let window = tca_window(start_whole, start_fraction, end_whole, end_fraction);
    let options = finder_options(coarse_step_seconds, time_tolerance_seconds);
    let result =
        find_tca_candidates_between_tles(primary, secondary, window, options).map(|candidates| {
            candidates
                .into_iter()
                .map(candidate_term)
                .collect::<Vec<_>>()
        });
    Ok(encode_result(env, result))
}

#[allow(clippy::too_many_arguments)]
pub(crate) fn find_tca_conjunctions_impl<'a>(
    env: Env<'a>,
    primary_line1: String,
    primary_line2: String,
    secondary_line1: String,
    secondary_line2: String,
    start_whole: f64,
    start_fraction: f64,
    end_whole: f64,
    end_fraction: f64,
    hard_body_radius_km: f64,
    method: Atom,
    primary_covariance_km2: Option<Vec<Vec<f64>>>,
    secondary_covariance_km2: Option<Vec<Vec<f64>>>,
    coarse_step_seconds: f64,
    time_tolerance_seconds: f64,
) -> NifResult<Term<'a>> {
    let primary = TcaTle::new(&primary_line1, &primary_line2);
    let secondary = TcaTle::new(&secondary_line1, &secondary_line2);
    let window = tca_window(start_whole, start_fraction, end_whole, end_fraction);
    let options = finder_options(coarse_step_seconds, time_tolerance_seconds);
    let pc = pc_options(
        hard_body_radius_km,
        method,
        primary_covariance_km2,
        secondary_covariance_km2,
    )?;
    let result =
        find_tca_conjunctions_between_tles(primary, secondary, window, options, pc).map(
            |conjunctions| {
                conjunctions
                    .into_iter()
                    .map(conjunction_term)
                    .collect::<Vec<_>>()
            },
        );
    Ok(encode_result(env, result))
}

#[allow(clippy::too_many_arguments)]
pub(crate) fn screen_tca_candidates_impl<'a>(
    env: Env<'a>,
    primary_line1: String,
    primary_line2: String,
    secondaries: Vec<(String, String)>,
    start_whole: f64,
    start_fraction: f64,
    end_whole: f64,
    end_fraction: f64,
    miss_distance_threshold_km: f64,
    coarse_step_seconds: f64,
    time_tolerance_seconds: f64,
) -> NifResult<Term<'a>> {
    let primary = TcaTle::new(&primary_line1, &primary_line2);
    let secondary_tles = secondaries
        .iter()
        .map(|(line1, line2)| TcaTle::new(line1, line2))
        .collect::<Vec<_>>();
    let window = tca_window(start_whole, start_fraction, end_whole, end_fraction);
    let options = finder_options(coarse_step_seconds, time_tolerance_seconds);
    let result = screen_tca_candidates_from_tle_catalog_parallel(
        primary,
        &secondary_tles,
        window,
        miss_distance_threshold_km,
        options,
    )
    .map(|hits| {
        hits.into_iter()
            .map(
                |TcaScreeningHit {
                     secondary_index,
                     candidate,
                 }| {
                    (secondary_index as u64, candidate_term(candidate))
                },
            )
            .collect::<Vec<ScreeningHitTerm>>()
    });
    Ok(encode_result(env, result))
}

#[allow(clippy::too_many_arguments)]
pub(crate) fn screen_tca_conjunctions_impl<'a>(
    env: Env<'a>,
    primary_line1: String,
    primary_line2: String,
    secondaries: Vec<(String, String)>,
    start_whole: f64,
    start_fraction: f64,
    end_whole: f64,
    end_fraction: f64,
    miss_distance_threshold_km: f64,
    hard_body_radius_km: f64,
    method: Atom,
    primary_covariance_km2: Option<Vec<Vec<f64>>>,
    secondary_covariance_km2: Option<Vec<Vec<f64>>>,
    coarse_step_seconds: f64,
    time_tolerance_seconds: f64,
) -> NifResult<Term<'a>> {
    let primary = TcaTle::new(&primary_line1, &primary_line2);
    let secondary_tles = secondaries
        .iter()
        .map(|(line1, line2)| TcaTle::new(line1, line2))
        .collect::<Vec<_>>();
    let window = tca_window(start_whole, start_fraction, end_whole, end_fraction);
    let options = finder_options(coarse_step_seconds, time_tolerance_seconds);
    let pc = pc_options(
        hard_body_radius_km,
        method,
        primary_covariance_km2,
        secondary_covariance_km2,
    )?;
    let result = screen_tca_conjunctions_from_tle_catalog_parallel(
        primary,
        &secondary_tles,
        window,
        miss_distance_threshold_km,
        options,
        pc,
    )
    .map(|hits| {
        hits.into_iter()
            .map(
                |TcaScreeningConjunctionHit {
                     secondary_index,
                     conjunction,
                 }| {
                    (secondary_index as u64, conjunction_term(conjunction))
                },
            )
            .collect::<Vec<ScreeningConjunctionHitTerm>>()
    });
    Ok(encode_result(env, result))
}
