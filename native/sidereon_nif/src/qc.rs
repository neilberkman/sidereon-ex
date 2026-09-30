//! Rustler boundary for GNSS quality-control primitives.
//!
//! This module is glue over `sidereon_core::quality`: decode Sidereon terms,
//! call the crate's pseudorange weighting, RAIM, and FDE functions, and encode
//! the public result maps.

use std::collections::BTreeMap;

use rustler::types::atom;
use rustler::{Encoder, Env, Error, NifResult, ResourceArc, Term};
use sidereon_core::positioning::{EphemerisSource, KlobucharCoeffs, RobustConfig, SppError};
use sidereon_core::quality::{
    self, FdeError, FdeOptions, FdeSppError, FdeSppOptions, FdeUnresolvedReason,
    PseudorangeVarianceModel, PseudorangeVarianceOptions, QualityError, RaimInput, RaimOptions,
    RaimResult, RaimWeights, RangeChiSquareTest, RangeFdeOptions, RangeFdeResult, RangeFdeRow,
    RangeMeasurementDiagnostic, SolutionValidationError, SolutionValidationOptions, WeightEntry,
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

#[derive(Debug, Clone, rustler::NifMap)]
struct RangeFdeRowTerm {
    id: String,
    residual_m: f64,
    design_row: Vec<f64>,
    weight: f64,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct RangeChiSquareTestFields {
    weighted_sum_squares: f64,
    dof: i64,
    threshold: Option<f64>,
    testable: bool,
    fault_detected: bool,
}

impl From<RangeChiSquareTest> for RangeChiSquareTestFields {
    fn from(test: RangeChiSquareTest) -> Self {
        Self {
            weighted_sum_squares: test.weighted_sum_squares,
            dof: test.dof as i64,
            threshold: test.threshold,
            testable: test.testable,
            fault_detected: test.fault_detected,
        }
    }
}

#[derive(Debug, Clone, rustler::NifMap)]
struct RangeMeasurementDiagnosticFields {
    id: String,
    excluded: bool,
    post_fit_residual_m: f64,
    normalized_residual: f64,
}

impl From<RangeMeasurementDiagnostic> for RangeMeasurementDiagnosticFields {
    fn from(diagnostic: RangeMeasurementDiagnostic) -> Self {
        Self {
            id: diagnostic.id,
            excluded: diagnostic.excluded,
            post_fit_residual_m: diagnostic.post_fit_residual_m,
            normalized_residual: diagnostic.normalized_residual,
        }
    }
}

#[derive(Debug, Clone, rustler::NifMap)]
struct RangeFdeResultFields {
    state_correction: Vec<f64>,
    state_covariance: Vec<Vec<f64>>,
    global_test: RangeChiSquareTestFields,
    excluded: Vec<String>,
    diagnostics: Vec<RangeMeasurementDiagnosticFields>,
    iterations: i64,
}

impl From<RangeFdeResult> for RangeFdeResultFields {
    fn from(result: RangeFdeResult) -> Self {
        Self {
            state_correction: result.state_correction,
            state_covariance: result.state_covariance,
            global_test: result.global_test.into(),
            excluded: result.excluded,
            diagnostics: result.diagnostics.into_iter().map(Into::into).collect(),
            iterations: result.iterations as i64,
        }
    }
}

#[derive(Debug, Clone, rustler::NifMap)]
struct RaimResultFields {
    fault_detected: bool,
    test_statistic: f64,
    threshold: Option<f64>,
    worst_sat: Option<String>,
    reduced_chi_square: Option<f64>,
    normalized_residuals: Vec<(String, f64)>,
    rms_m: f64,
    dof: i64,
    testable: bool,
}

impl RaimResultFields {
    fn from_core(result: RaimResult, residuals_m: &[f64]) -> Self {
        let reduced_chi_square =
            (result.dof > 0).then_some(result.test_statistic / result.dof as f64);
        let rms_m = residual_rms_m(residuals_m);
        Self {
            fault_detected: result.fault_detected,
            test_statistic: result.test_statistic,
            threshold: result.threshold,
            worst_sat: result.worst_sat,
            reduced_chi_square,
            normalized_residuals: result.normalized_residuals.into_iter().collect(),
            rms_m,
            dof: result.dof as i64,
            testable: result.testable,
        }
    }
}

mod atoms {
    rustler::atoms! {
        ok,
        error,
        nil,
        selection_unsettled,
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
        degenerate_geometry,
        rank_deficient,
        implausible_position,
        no_convergence,
        invalid_parameter,
        invalid_reliability_parameter,
        invalid_system_count,
        invalid_residuals,
        invalid_design,
        invalid_input,
        invalid_options,
        missing_variances,
        invalid_variance
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
        // Let core preserve probability-first validation for inputs where
        // both p and dof are invalid; zero is its typed invalid-dof sentinel.
        quality::chi2_inv(p, 0)
    };
    encode_quality_float(env, result)
}

/// Keeps the established Elixir positional call contract intact.
#[rustler::nif]
#[allow(clippy::too_many_arguments)]
fn qc_raim<'a>(
    env: Env<'a>,
    used_sats: Vec<String>,
    residuals_m: Vec<f64>,
    variances_m2: Option<Vec<f64>>,
    p_fa: f64,
    weights_mode: Term<'a>,
    weights: Vec<(String, f64)>,
    n_systems: Term<'a>,
) -> NifResult<Term<'a>> {
    let mut options = RaimOptions::default();
    options.p_fa = p_fa;
    options.weights = raim_weights(weights_mode, weights)?;
    options.n_systems = decode_optional_isize(n_systems)?;
    let input = RaimInput {
        used_sats,
        residuals_m,
        variances_m2,
    };
    Ok(match quality::raim(&input, &options) {
        Ok(result) => {
            let reduced_chi_square =
                (result.dof > 0).then_some(result.test_statistic / result.dof as f64);
            let rms_m = residual_rms_m(&input.residuals_m);
            (
                atoms::ok(),
                RaimResultFields {
                    fault_detected: result.fault_detected,
                    test_statistic: result.test_statistic,
                    threshold: result.threshold,
                    worst_sat: result.worst_sat,
                    reduced_chi_square,
                    normalized_residuals: result.normalized_residuals.into_iter().collect(),
                    rms_m,
                    dof: result.dof as i64,
                    testable: result.testable,
                },
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
    weights_mode: Term<'a>,
    weights: Vec<(String, f64)>,
    n_systems: Term<'a>,
    max_exclusions: u64,
    max_exclusion_rms_m: Term<'a>,
    max_pdop: Term<'a>,
    pseudorange_code: Term<'a>,
    qzss_clock: Term<'a>,
    troposphere_model: Term<'a>,
) -> NifResult<Term<'a>> {
    let max_exclusion_rms_m = decode_exclusion_rms_cap(max_exclusion_rms_m)?;
    let pseudorange_code = crate::spp::decode_pseudorange_code(pseudorange_code)?;
    let models = crate::spp::decode_models(qzss_clock, troposphere_model)?;
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
    inputs.pseudorange_code = pseudorange_code;
    crate::spp::set_models(&mut inputs, models.0, models.1);
    let weights = raim_weights(weights_mode, weights)?;

    encode_fde_result(
        env,
        &handle.sp3,
        inputs,
        with_geodetic,
        p_fa,
        weights,
        n_systems,
        max_exclusions,
        max_exclusion_rms_m,
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
    weights_mode: Term<'a>,
    weights: Vec<(String, f64)>,
    n_systems: Term<'a>,
    max_exclusions: u64,
    max_exclusion_rms_m: Term<'a>,
    max_pdop: Term<'a>,
    pseudorange_code: Term<'a>,
    qzss_clock: Term<'a>,
    troposphere_model: Term<'a>,
) -> NifResult<Term<'a>> {
    let max_exclusion_rms_m = decode_exclusion_rms_cap(max_exclusion_rms_m)?;
    let pseudorange_code = crate::spp::decode_pseudorange_code(pseudorange_code)?;
    let models = crate::spp::decode_models(qzss_clock, troposphere_model)?;
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
    inputs.pseudorange_code = pseudorange_code;
    crate::spp::set_models(&mut inputs, models.0, models.1);

    if let Some(bds) = handle.store.iono_corrections().beidou {
        inputs.beidou_klobuchar = Some(KlobucharCoeffs {
            alpha: bds.alpha,
            beta: bds.beta,
        });
    }
    let weights = raim_weights(weights_mode, weights)?;

    encode_fde_result(
        env,
        &handle.store,
        inputs,
        with_geodetic,
        p_fa,
        weights,
        n_systems,
        max_exclusions,
        max_exclusion_rms_m,
        max_pdop,
    )
}

#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
fn qc_robust_fde_sp3<'a>(
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
    weights_mode: Term<'a>,
    weights: Vec<(String, f64)>,
    n_systems: Term<'a>,
    max_exclusions: u64,
    max_exclusion_rms_m: Term<'a>,
    max_pdop: Term<'a>,
    pseudorange_code: Term<'a>,
    qzss_clock: Term<'a>,
    troposphere_model: Term<'a>,
) -> NifResult<Term<'a>> {
    let max_exclusion_rms_m = decode_exclusion_rms_cap(max_exclusion_rms_m)?;
    let pseudorange_code = crate::spp::decode_pseudorange_code(pseudorange_code)?;
    let models = crate::spp::decode_models(qzss_clock, troposphere_model)?;
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
    inputs.pseudorange_code = pseudorange_code;
    crate::spp::set_models(&mut inputs, models.0, models.1);
    let weights = raim_weights(weights_mode, weights)?;

    encode_robust_fde_result(
        env,
        &handle.sp3,
        inputs,
        with_geodetic,
        p_fa,
        weights,
        n_systems,
        max_exclusions,
        max_exclusion_rms_m,
        max_pdop,
    )
}

#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
fn qc_robust_fde_broadcast<'a>(
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
    weights_mode: Term<'a>,
    weights: Vec<(String, f64)>,
    n_systems: Term<'a>,
    max_exclusions: u64,
    max_exclusion_rms_m: Term<'a>,
    max_pdop: Term<'a>,
    pseudorange_code: Term<'a>,
    qzss_clock: Term<'a>,
    troposphere_model: Term<'a>,
) -> NifResult<Term<'a>> {
    let max_exclusion_rms_m = decode_exclusion_rms_cap(max_exclusion_rms_m)?;
    let pseudorange_code = crate::spp::decode_pseudorange_code(pseudorange_code)?;
    let models = crate::spp::decode_models(qzss_clock, troposphere_model)?;
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
    inputs.pseudorange_code = pseudorange_code;
    crate::spp::set_models(&mut inputs, models.0, models.1);

    if let Some(bds) = handle.store.iono_corrections().beidou {
        inputs.beidou_klobuchar = Some(KlobucharCoeffs {
            alpha: bds.alpha,
            beta: bds.beta,
        });
    }
    let weights = raim_weights(weights_mode, weights)?;

    encode_robust_fde_result(
        env,
        &handle.store,
        inputs,
        with_geodetic,
        p_fa,
        weights,
        n_systems,
        max_exclusions,
        max_exclusion_rms_m,
        max_pdop,
    )
}

/// Standalone range RAIM/FDE over a caller-supplied linearized measurement set.
///
/// Pure glue over `sidereon_core::quality::raim_fde_design`: decode the rows and
/// options, run the protected weighted-least-squares solve with the global
/// chi-square test and leave-one-out exclusion loop, and re-shape the unchanged
/// public result. No numerics live here.
#[rustler::nif(schedule = "DirtyCpu")]
fn qc_raim_fde_design<'a>(
    env: Env<'a>,
    rows: Vec<RangeFdeRowTerm>,
    p_fa: f64,
    max_exclusions: u64,
    min_redundancy: u64,
    max_exclusion_rms_m: Term<'a>,
) -> NifResult<Term<'a>> {
    let max_exclusion_rms_m = decode_exclusion_rms_cap(max_exclusion_rms_m)?;
    let rows: Vec<RangeFdeRow> = rows
        .into_iter()
        .map(|row| RangeFdeRow {
            id: row.id,
            residual_m: row.residual_m,
            design_row: row.design_row,
            weight: row.weight,
        })
        .collect();
    let mut options = RangeFdeOptions::default();
    options.p_fa = p_fa;
    options.max_exclusions = usize::try_from(max_exclusions)
        .map_err(|_| Error::Term(Box::new("max_exclusions exceeds platform range")))?;
    options.min_redundancy = usize::try_from(min_redundancy)
        .map_err(|_| Error::Term(Box::new("min_redundancy exceeds platform range")))?;
    options.max_exclusion_rms_m = max_exclusion_rms_m;
    Ok(match quality::raim_fde_design(&rows, &options) {
        Ok(result) => (atoms::ok(), RangeFdeResultFields::from(result)).encode(env),
        Err(error) => (atoms::error(), quality_error_atom(error)).encode(env),
    })
}

#[allow(clippy::too_many_arguments)]
fn encode_fde_result<'a>(
    env: Env<'a>,
    eph: &dyn EphemerisSource,
    inputs: sidereon_core::positioning::SolveInputs,
    with_geodetic: bool,
    p_fa: f64,
    weights: RaimWeights,
    n_systems: Term<'a>,
    max_exclusions: u64,
    max_exclusion_rms_m: f64,
    max_pdop: Term<'a>,
) -> NifResult<Term<'a>> {
    let mut validation = SolutionValidationOptions::default();
    validation.max_pdop = decode_optional_f64(max_pdop)?;

    let mut raim = RaimOptions::default();
    raim.p_fa = p_fa;
    raim.weights = weights;
    raim.n_systems = decode_optional_isize(n_systems)?;

    let max_exclusions = usize::try_from(max_exclusions)
        .map_err(|_| Error::Term(Box::new("max_exclusions exceeds platform range")))?;
    let mut fde = FdeOptions::new(raim, max_exclusions);
    fde.max_exclusion_rms_m = max_exclusion_rms_m;
    let options = FdeSppOptions::new(fde, validation);

    let result = quality::fde_spp(eph, &inputs, with_geodetic, &options);

    encode_fde_result_term(env, result)
}

#[allow(clippy::too_many_arguments)]
fn encode_robust_fde_result<'a>(
    env: Env<'a>,
    eph: &dyn EphemerisSource,
    inputs: sidereon_core::positioning::SolveInputs,
    with_geodetic: bool,
    p_fa: f64,
    weights: RaimWeights,
    n_systems: Term<'a>,
    max_exclusions: u64,
    max_exclusion_rms_m: f64,
    max_pdop: Term<'a>,
) -> NifResult<Term<'a>> {
    let mut validation = SolutionValidationOptions::default();
    validation.max_pdop = decode_optional_f64(max_pdop)?;

    let mut raim = RaimOptions::default();
    raim.p_fa = p_fa;
    raim.weights = weights;
    raim.n_systems = decode_optional_isize(n_systems)?;

    let max_exclusions = usize::try_from(max_exclusions)
        .map_err(|_| Error::Term(Box::new("max_exclusions exceeds platform range")))?;
    let mut fde = FdeOptions::new(raim, max_exclusions);
    fde.max_exclusion_rms_m = max_exclusion_rms_m;
    let options = FdeSppOptions::new(fde, validation);

    let result = quality::spp_robust_fde_driver(
        eph,
        &inputs,
        with_geodetic,
        RobustConfig::default(),
        &options,
    );

    encode_fde_result_term(env, result)
}

fn encode_fde_result_term<'a>(
    env: Env<'a>,
    result: Result<
        sidereon_core::quality::FdeResult<sidereon_core::positioning::ReceiverSolution>,
        FdeError<sidereon_core::positioning::ReceiverSolution, FdeSppError>,
    >,
) -> NifResult<Term<'a>> {
    Ok(match result {
        Ok(result) => {
            let solution = crate::spp::encode_solution(env, &result.solution);
            let raim = RaimResultFields::from_core(result.raim, &result.solution.residuals_m);
            let excluded: Vec<(String, Term<'a>)> = result
                .excluded
                .into_iter()
                .map(|sat| (sat, atoms::raim_excluded().encode(env)))
                .collect();
            (
                atoms::ok(),
                (solution, excluded, result.iterations as i64, raim),
            )
                .encode(env)
        }
        Err(error) => encode_fde_error(env, error),
    })
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
    let mut options = PseudorangeVarianceOptions::default();
    options.a_m = a_m;
    options.b_m = b_m;
    options.model = model;
    options.cn0_dbhz = decode_optional_f64(cn0)?;
    options.cn0_scale_m2 = cn0_scale_m2;
    Ok(options)
}

fn decode_weight_entries(entries: Vec<WeightEntryTerm>) -> Vec<WeightEntry> {
    entries
        .into_iter()
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

fn decode_exclusion_rms_cap(term: Term<'_>) -> NifResult<f64> {
    if term.is_atom() && term.atom_to_string().unwrap_or_default() == "infinity" {
        Ok(f64::INFINITY)
    } else {
        term.decode::<f64>()
    }
}

fn decode_optional_isize(term: Term<'_>) -> NifResult<Option<isize>> {
    if term.is_atom() && term.atom_to_string().unwrap_or_default() == "nil" {
        Ok(None)
    } else {
        let value = term.decode::<i64>()?;
        let value = isize::try_from(value)
            .map_err(|_| Error::Term(Box::new("n_systems exceeds platform range")))?;
        Ok(Some(value))
    }
}

fn raim_weights(mode: Term<'_>, weights: Vec<(String, f64)>) -> NifResult<RaimWeights> {
    let mode = mode
        .atom_to_string()
        .map_err(|_| Error::Term(Box::new("RAIM weights mode must be an atom")))?;
    match mode.as_str() {
        "solution" => Ok(RaimWeights::Solution),
        "unit" => Ok(RaimWeights::Unit),
        "satellite" => Ok(RaimWeights::BySatellite(
            weights.into_iter().collect::<BTreeMap<_, _>>(),
        )),
        _ => Err(Error::Term(Box::new(
            "RAIM weights mode must be :solution, :unit, or :satellite",
        ))),
    }
}

fn residual_rms_m(residuals_m: &[f64]) -> f64 {
    if residuals_m.is_empty() {
        return 0.0;
    }
    let sum_squares = residuals_m
        .iter()
        .map(|residual| residual * residual)
        .sum::<f64>();
    (sum_squares / residuals_m.len() as f64).sqrt()
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
        QualityError::InvalidReliabilityParameter => atoms::invalid_reliability_parameter(),
        QualityError::InvalidProbability => atoms::invalid_probability(),
        QualityError::InvalidSystemCount => atoms::invalid_system_count(),
        QualityError::InvalidDof => atoms::invalid_dof(),
        QualityError::InvalidWeight => atoms::invalid_weight(),
        QualityError::InvalidResiduals => atoms::invalid_residuals(),
        QualityError::InvalidDesign => atoms::invalid_design(),
        QualityError::SingularGeometry => atoms::singular_geometry(),
        QualityError::MissingVariances => atoms::missing_variances(),
        QualityError::InvalidVariance => atoms::invalid_variance(),
    }
}

fn encode_fde_error<'a>(
    env: Env<'a>,
    error: FdeError<sidereon_core::positioning::ReceiverSolution, FdeSppError>,
) -> Term<'a> {
    match error {
        FdeError::FaultUnresolved(unresolved) => {
            let unresolved = *unresolved;
            let reason = unresolved_reason_name(unresolved.reason);
            let solution = crate::spp::encode_solution(env, &unresolved.solution);
            let excluded: Vec<(String, Term<'a>)> = unresolved
                .excluded
                .iter()
                .cloned()
                .map(|sat| (sat, atoms::raim_excluded().encode(env)))
                .collect();
            let iterations = excluded.len() as i64;
            let raim =
                RaimResultFields::from_core(unresolved.raim, &unresolved.solution.residuals_m);
            (
                atoms::error(),
                (
                    atoms::fault_unresolved(),
                    (reason, solution, excluded, iterations, raim),
                ),
            )
                .encode(env)
        }
        FdeError::Solve(FdeSppError::Spp(error)) => encode_spp_public_error(env, &error),
        FdeError::Solve(FdeSppError::Validation(error)) => {
            encode_validation_public_error(env, error)
        }
        FdeError::Raim(error) => (atoms::error(), quality_error_atom(error)).encode(env),
    }
}

fn unresolved_reason_name(reason: FdeUnresolvedReason) -> String {
    match reason {
        FdeUnresolvedReason::ExclusionBudgetExhausted => "exclusion_budget_exhausted".to_string(),
        FdeUnresolvedReason::NoAdmissibleExclusion => "no_admissible_exclusion".to_string(),
        other => snake_case(&format!("{other:?}")),
    }
}

#[cfg(test)]
mod fde_mapping_tests {
    use super::{unresolved_reason_name, FdeUnresolvedReason};

    #[test]
    fn unresolved_reasons_keep_their_public_names() {
        assert_eq!(
            unresolved_reason_name(FdeUnresolvedReason::ExclusionBudgetExhausted),
            "exclusion_budget_exhausted"
        );
        assert_eq!(
            unresolved_reason_name(FdeUnresolvedReason::NoAdmissibleExclusion),
            "no_admissible_exclusion"
        );
    }
}

fn snake_case(name: &str) -> String {
    let mut out = String::with_capacity(name.len() + 4);
    for (index, c) in name.chars().enumerate() {
        if c.is_ascii_uppercase() {
            if index > 0 {
                out.push('_');
            }
            out.push(c.to_ascii_lowercase());
        } else {
            out.push(c);
        }
    }
    out
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
        SppError::SelectionUnsettled { passes } => (
            atoms::error(),
            (atoms::selection_unsettled(), *passes as i64),
        )
            .encode(env),
        SppError::Ut1OutsideCoverage(reason) => (
            atoms::error(),
            crate::errors::ut1_outside_coverage_term(env, *reason),
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
