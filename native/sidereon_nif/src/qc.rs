//! Rustler boundary for GNSS quality-control primitives.
//!
//! This module is glue over `sidereon_core::quality`: decode Sidereon terms,
//! call the crate's pseudorange weighting, RAIM, and FDE functions, and encode
//! the unchanged public result shapes.

use std::collections::BTreeMap;

use rustler::types::atom;
use rustler::{Encoder, Env, Error, NifResult, ResourceArc, Term};
use sidereon_core::positioning::{solve, EphemerisSource, KlobucharCoeffs, SppError};
use sidereon_core::quality::{
    self, FdeError, FdeOptions, PseudorangeVarianceModel, PseudorangeVarianceOptions, QualityError,
    RaimInput, RaimOptions, RaimWeights, SolutionValidationError, SolutionValidationOptions,
    WeightEntry,
};

use crate::broadcast::BroadcastResource;
use crate::sp3::Sp3Resource;

type Tuple4 = (f64, f64, f64, f64);

#[derive(Debug, Clone, rustler::NifMap)]
struct WeightEntryTerm {
    satellite_id: String,
    elevation_deg: f64,
    cn0: Option<f64>,
}

mod atoms {
    rustler::atoms! {
        ok,
        error,
        nil,
        invalid_elevation,
        missing_cn0,
        invalid_probability,
        invalid_dof,
        invalid_weight,
        invalid_model,
        fault_unresolved,
        raim_excluded,
        too_few_satellites,
        singular_geometry,
        duplicate_observation,
        ephemeris_lost,
        ionosphere_unsupported,
        degenerate_geometry,
        rank_deficient,
        implausible_position,
        no_convergence,
        invalid_parameter,
        invalid_system_count,
        invalid_residuals,
        invalid_input,
        invalid_options
    }
}

#[rustler::nif]
fn qc_pseudorange_variance<'a>(
    env: Env<'a>,
    elevation_deg: f64,
    a_m: f64,
    b_m: f64,
    model: String,
    cn0: Term<'a>,
    cn0_scale_m2: f64,
) -> NifResult<Term<'a>> {
    let options = variance_options(a_m, b_m, &model, cn0, cn0_scale_m2)?;
    Ok(encode_quality_float(
        env,
        quality::pseudorange_variance(elevation_deg, options),
    ))
}

#[rustler::nif]
fn qc_sigmas(
    entries: Vec<WeightEntryTerm>,
    a_m: f64,
    b_m: f64,
    model: String,
    cn0: Term<'_>,
    cn0_scale_m2: f64,
) -> NifResult<Vec<(String, f64)>> {
    let options = variance_options(a_m, b_m, &model, cn0, cn0_scale_m2)?;
    Ok(quality::sigmas(&decode_weight_entries(entries), options)
        .into_iter()
        .collect())
}

#[rustler::nif]
fn qc_weight_vector(
    entries: Vec<WeightEntryTerm>,
    a_m: f64,
    b_m: f64,
    model: String,
    cn0: Term<'_>,
    cn0_scale_m2: f64,
) -> NifResult<Vec<(String, f64)>> {
    let options = variance_options(a_m, b_m, &model, cn0, cn0_scale_m2)?;
    Ok(
        quality::weight_vector(&decode_weight_entries(entries), options)
            .into_iter()
            .collect(),
    )
}

#[rustler::nif]
fn qc_chi2_inv<'a>(env: Env<'a>, p: f64, dof: i64) -> Term<'a> {
    let result = if dof >= 1 {
        quality::chi2_inv(p, dof as usize)
    } else {
        Err(QualityError::InvalidDof)
    };
    encode_quality_float(env, result)
}

#[rustler::nif]
fn qc_raim<'a>(
    env: Env<'a>,
    used_sats: Vec<String>,
    residuals_m: Vec<f64>,
    p_fa: f64,
    unit_weights: bool,
    weights: Vec<(String, f64)>,
    n_systems: Term<'a>,
) -> NifResult<Term<'a>> {
    let options = RaimOptions {
        p_fa,
        weights: raim_weights(unit_weights, weights),
        n_systems: decode_optional_isize(n_systems)?,
    };
    let input = RaimInput {
        used_sats,
        residuals_m,
    };
    Ok(match quality::raim(&input, &options) {
        Ok(result) => {
            let threshold = match result.threshold {
                Some(value) => value.encode(env),
                None => atoms::nil().encode(env),
            };
            let worst = match result.worst_sat {
                Some(sat) => sat.encode(env),
                None => atoms::nil().encode(env),
            };
            let normalized: Vec<(String, f64)> = result.normalized_residuals.into_iter().collect();
            (
                atoms::ok(),
                (
                    result.fault_detected,
                    result.test_statistic,
                    threshold,
                    result.dof as i64,
                    result.testable,
                    normalized,
                    worst,
                ),
            )
                .encode(env)
        }
        Err(error) => (atoms::error(), quality_error_atom(error)).encode(env),
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
fn qc_fde_sp3<'a>(
    env: Env<'a>,
    handle: ResourceArc<Sp3Resource>,
    observations: Vec<(String, f64)>,
    t_rx_j2000_s: f64,
    t_rx_second_of_day_s: f64,
    day_of_year: f64,
    initial_guess: Tuple4,
    apply_iono: bool,
    apply_tropo: bool,
    alpha: Tuple4,
    beta: Tuple4,
    pressure_hpa: f64,
    temperature_k: f64,
    relative_humidity: f64,
    with_geodetic: bool,
    p_fa: f64,
    unit_weights: bool,
    weights: Vec<(String, f64)>,
    n_systems: Term<'a>,
    max_iterations: u64,
    max_pdop: Term<'a>,
) -> NifResult<Term<'a>> {
    let inputs = crate::spp::build_solve_inputs(
        observations,
        t_rx_j2000_s,
        t_rx_second_of_day_s,
        day_of_year,
        initial_guess,
        apply_iono,
        apply_tropo,
        alpha,
        beta,
        pressure_hpa,
        temperature_k,
        relative_humidity,
        None,
    )?;

    encode_fde_result(
        env,
        &handle.sp3,
        inputs,
        with_geodetic,
        p_fa,
        unit_weights,
        weights,
        n_systems,
        max_iterations,
        max_pdop,
    )
}

#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
fn qc_fde_broadcast<'a>(
    env: Env<'a>,
    handle: ResourceArc<BroadcastResource>,
    observations: Vec<(String, f64)>,
    t_rx_j2000_s: f64,
    t_rx_second_of_day_s: f64,
    day_of_year: f64,
    initial_guess: Tuple4,
    apply_iono: bool,
    apply_tropo: bool,
    alpha: Tuple4,
    beta: Tuple4,
    pressure_hpa: f64,
    temperature_k: f64,
    relative_humidity: f64,
    with_geodetic: bool,
    p_fa: f64,
    unit_weights: bool,
    weights: Vec<(String, f64)>,
    n_systems: Term<'a>,
    max_iterations: u64,
    max_pdop: Term<'a>,
) -> NifResult<Term<'a>> {
    let mut inputs = crate::spp::build_solve_inputs(
        observations,
        t_rx_j2000_s,
        t_rx_second_of_day_s,
        day_of_year,
        initial_guess,
        apply_iono,
        apply_tropo,
        alpha,
        beta,
        pressure_hpa,
        temperature_k,
        relative_humidity,
        None,
    )?;

    if let Some(bds) = handle.store.iono_corrections().beidou {
        inputs.beidou_klobuchar = Some(KlobucharCoeffs {
            alpha: bds.alpha,
            beta: bds.beta,
        });
    }

    encode_fde_result(
        env,
        &handle.store,
        inputs,
        with_geodetic,
        p_fa,
        unit_weights,
        weights,
        n_systems,
        max_iterations,
        max_pdop,
    )
}

#[allow(clippy::too_many_arguments)]
fn encode_fde_result<'a>(
    env: Env<'a>,
    eph: &dyn EphemerisSource,
    inputs: sidereon_core::positioning::SolveInputs,
    with_geodetic: bool,
    p_fa: f64,
    unit_weights: bool,
    weights: Vec<(String, f64)>,
    n_systems: Term<'a>,
    max_iterations: u64,
    max_pdop: Term<'a>,
) -> NifResult<Term<'a>> {
    let validation = SolutionValidationOptions {
        max_pdop: decode_optional_f64(max_pdop)?,
        ..Default::default()
    };
    let options = FdeOptions {
        raim: RaimOptions {
            p_fa,
            weights: raim_weights(unit_weights, weights),
            n_systems: decode_optional_isize(n_systems)?,
        },
        max_iterations: max_iterations as usize,
    };

    let observations = inputs.observations.clone();
    let result = quality::fde(&observations, &options, |remaining| {
        let mut next_inputs = inputs.clone();
        next_inputs.observations = remaining.to_vec();
        let solution = solve(eph, &next_inputs, with_geodetic).map_err(QcSolveError::Spp)?;
        quality::validate_receiver_solution(&solution, validation)
            .map_err(QcSolveError::Validation)?;
        Ok(solution)
    });

    Ok(match result {
        Ok(result) => {
            let solution = crate::spp::encode_solution(env, &result.solution);
            let excluded: Vec<(String, Term<'a>)> = result
                .excluded
                .into_iter()
                .map(|sat| (sat, atoms::raim_excluded().encode(env)))
                .collect();
            (atoms::ok(), (solution, excluded, result.iterations as i64)).encode(env)
        }
        Err(error) => encode_fde_error(env, error),
    })
}

#[derive(Debug)]
enum QcSolveError {
    Spp(SppError),
    Validation(SolutionValidationError),
}

fn variance_options<'a>(
    a_m: f64,
    b_m: f64,
    model: &str,
    cn0: Term<'a>,
    cn0_scale_m2: f64,
) -> NifResult<PseudorangeVarianceOptions> {
    let model = match model {
        "elevation" => PseudorangeVarianceModel::Elevation,
        "elevation_cn0" => PseudorangeVarianceModel::ElevationCn0,
        _ => return Err(Error::Term(Box::new("invalid QC variance model"))),
    };
    Ok(PseudorangeVarianceOptions {
        a_m,
        b_m,
        model,
        cn0_dbhz: decode_optional_f64(cn0)?,
        cn0_scale_m2,
    })
}

fn decode_weight_entries(entries: Vec<WeightEntryTerm>) -> Vec<WeightEntry> {
    // The Sidereon public sigmas/weight_vector contract drops entries at or
    // below the horizon. The hardened core variance now accepts the full
    // [-90, 90] elevation range, so enforce the non-positive-elevation drop
    // here to keep rejected entries out of the returned maps.
    entries
        .into_iter()
        .filter(|entry| entry.elevation_deg > 0.0)
        .map(|entry| WeightEntry {
            satellite_id: entry.satellite_id,
            elevation_deg: entry.elevation_deg,
            cn0_dbhz: entry.cn0,
        })
        .collect()
}

fn decode_optional_f64(term: Term<'_>) -> NifResult<Option<f64>> {
    if term.is_atom() && term.atom_to_string().unwrap_or_default() == "nil" {
        Ok(None)
    } else {
        term.decode::<f64>().map(Some)
    }
}

fn decode_optional_isize(term: Term<'_>) -> NifResult<Option<isize>> {
    if term.is_atom() && term.atom_to_string().unwrap_or_default() == "nil" {
        Ok(None)
    } else {
        let value = term.decode::<i64>()?;
        Ok(Some(value as isize))
    }
}

fn raim_weights(unit_weights: bool, weights: Vec<(String, f64)>) -> RaimWeights {
    if unit_weights {
        RaimWeights::Unit
    } else {
        RaimWeights::BySatellite(weights.into_iter().collect::<BTreeMap<_, _>>())
    }
}

fn encode_quality_float<'a>(env: Env<'a>, result: Result<f64, QualityError>) -> Term<'a> {
    match result {
        Ok(value) => (atoms::ok(), value).encode(env),
        Err(error) => (atoms::error(), quality_error_atom(error)).encode(env),
    }
}

fn quality_error_atom(error: QualityError) -> atom::Atom {
    match error {
        QualityError::InvalidElevation => atoms::invalid_elevation(),
        QualityError::MissingCn0 => atoms::missing_cn0(),
        QualityError::InvalidParameter => atoms::invalid_parameter(),
        QualityError::InvalidProbability => atoms::invalid_probability(),
        QualityError::InvalidSystemCount => atoms::invalid_system_count(),
        QualityError::InvalidDof => atoms::invalid_dof(),
        QualityError::InvalidWeight => atoms::invalid_weight(),
        QualityError::InvalidResiduals => atoms::invalid_residuals(),
    }
}

fn encode_fde_error<'a>(env: Env<'a>, error: FdeError<QcSolveError>) -> Term<'a> {
    match error {
        FdeError::FaultUnresolved(statistic) => {
            (atoms::error(), (atoms::fault_unresolved(), statistic)).encode(env)
        }
        FdeError::Solve(QcSolveError::Spp(error)) => encode_spp_public_error(env, &error),
        FdeError::Solve(QcSolveError::Validation(error)) => {
            encode_validation_public_error(env, error)
        }
        FdeError::Raim(error) => (atoms::error(), quality_error_atom(error)).encode(env),
    }
}

fn encode_spp_public_error<'a>(env: Env<'a>, error: &SppError) -> Term<'a> {
    match error {
        SppError::InvalidInput { field, .. } => {
            (atoms::error(), (atoms::invalid_input(), field.to_string())).encode(env)
        }
        SppError::TooFewSatellites { used, required } => (
            atoms::error(),
            (atoms::too_few_satellites(), *used as i64, *required as i64),
        )
            .encode(env),
        SppError::Singular(_) => (atoms::error(), atoms::singular_geometry()).encode(env),
        SppError::DuplicateObservation { satellite } => (
            atoms::error(),
            (atoms::duplicate_observation(), satellite.to_string()),
        )
            .encode(env),
        SppError::EphemerisLost { satellite } => (
            atoms::error(),
            (atoms::ephemeris_lost(), satellite.to_string()),
        )
            .encode(env),
        SppError::IonosphereUnsupported { satellite } => (
            atoms::error(),
            (atoms::ionosphere_unsupported(), satellite.to_string()),
        )
            .encode(env),
    }
}

fn encode_validation_public_error<'a>(env: Env<'a>, error: SolutionValidationError) -> Term<'a> {
    match error {
        SolutionValidationError::InvalidOptions { field, .. } => (
            atoms::error(),
            (atoms::invalid_options(), field.to_string()),
        )
            .encode(env),
        SolutionValidationError::InvalidResiduals => {
            (atoms::error(), atoms::invalid_residuals()).encode(env)
        }
        SolutionValidationError::DegenerateGeometryRankDeficient => (
            atoms::error(),
            (atoms::degenerate_geometry(), atoms::rank_deficient()),
        )
            .encode(env),
        SolutionValidationError::DegenerateGeometryPdop(pdop) => {
            (atoms::error(), (atoms::degenerate_geometry(), pdop)).encode(env)
        }
        SolutionValidationError::ImplausiblePosition(radius_m) => {
            (atoms::error(), (atoms::implausible_position(), radius_m)).encode(env)
        }
        SolutionValidationError::NoConvergence(rms_m) => {
            (atoms::error(), (atoms::no_convergence(), rms_m)).encode(env)
        }
    }
}
