//! Rustler boundary for SP3/sample-backed precise orbit fitting.

use rustler::{Encoder, Env, NifResult, ResourceArc, Term};
use sidereon_core::geometry_quality::{GeometryQuality, ObservabilityTier};
use sidereon_core::orbit_determination::{
    fit_all_sp3_ecef_precise_orbits, fit_precise_ephemeris_sample_orbit,
    fit_sp3_ecef_precise_orbit, fit_sp3_ecef_precise_orbits, fit_sp3_precise_orbit,
    OrbitFitCovariance, OrbitFitError, OrbitFitOptions, OrbitFitReport, OrbitFitSolution,
    OrbitResidualLedger, OrbitResidualStats,
};
use sidereon_core::{GnssSatelliteId, TdbEarthOrientationProvider};

use crate::precise_samples::{decode_sample, SampleTerm};
use crate::sp3::{system_from_letter, Sp3Resource};

mod atoms {
    rustler::atoms! {
        ok,
        error,
        empty_selection,
        invalid_option,
        too_few_samples,
        non_monotonic_epochs,
        mixed_timescales,
        invalid_epoch,
        invalid_observation,
        frame,
        propagation,
        least_squares,
        singular_geometry,
        did_not_converge,
        rtn_frame
    }
}

type Vec3 = (f64, f64, f64);
type OptionsTerm = (Vec<String>, f64, f64, usize, usize);
type SatelliteTerm = (String, u8);

#[derive(Debug, Clone, rustler::NifMap)]
struct GeometryQualityTerm {
    tier: String,
    redundancy: i64,
    rank: i64,
    condition_number: f64,
    gdop: f64,
    raim_checkable: bool,
    covariance_validated: bool,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct StateTerm {
    epoch_tdb_seconds: f64,
    position_km: Vec3,
    velocity_km_s: Vec3,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct OrbitFitCovarianceTerm {
    kind: String,
    matrix: Option<Vec<Vec<f64>>>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct OrbitFitSolutionTerm {
    satellite: String,
    initial_state: StateTerm,
    covariance: OrbitFitCovarianceTerm,
    geometry_quality: GeometryQualityTerm,
    seed_rms_3d_m: f64,
    fit_rms_3d_m: f64,
    iterations: i64,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct OrbitResidualStatsTerm {
    radial_rms_m: f64,
    along_rms_m: f64,
    cross_rms_m: f64,
    rms_3d_m: f64,
    n: i64,
    low_sample_count: bool,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct OrbitArcSpanTerm {
    time_scale: String,
    start_j2000_s: f64,
    end_j2000_s: f64,
    duration_s: f64,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct OrbitResidualLedgerTerm {
    per_sat: Vec<(String, OrbitResidualStatsTerm)>,
    per_constellation: Vec<(String, OrbitResidualStatsTerm)>,
    arc_span: OrbitArcSpanTerm,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct OrbitFitReportTerm {
    fits: Vec<OrbitFitSolutionTerm>,
    ledger: OrbitResidualLedgerTerm,
}

fn vec3(value: [f64; 3]) -> Vec3 {
    (value[0], value[1], value[2])
}

fn options(
    (forces, abs_tol, rel_tol, max_nfev, min_ledger_samples): OptionsTerm,
) -> NifResult<OrbitFitOptions> {
    let force_model = crate::propagation::force_model_kind(&forces)?;
    let mut options = OrbitFitOptions::default();
    options.force_model = force_model;
    options.propagation_context =
        crate::propagation::propagation_context_for_force_model(force_model);
    options.min_ledger_samples = min_ledger_samples;
    options.integrator_options.abs_tol = abs_tol;
    options.integrator_options.rel_tol = rel_tol;
    options.solver_options.max_nfev = max_nfev;
    Ok(options)
}

fn satellite(system_letter: String, prn: u8) -> NifResult<GnssSatelliteId> {
    let system = system_from_letter(&system_letter)?;
    GnssSatelliteId::new(system, prn).map_err(crate::errors::invalid_input)
}

fn satellites(terms: Vec<SatelliteTerm>) -> NifResult<Vec<GnssSatelliteId>> {
    terms
        .into_iter()
        .map(|(system_letter, prn)| satellite(system_letter, prn))
        .collect()
}

fn geometry_quality(value: GeometryQuality) -> GeometryQualityTerm {
    let tier = match value.tier {
        ObservabilityTier::RankDeficient => "rank_deficient",
        ObservabilityTier::ZeroRedundancy => "zero_redundancy",
        ObservabilityTier::Weak => "weak",
        ObservabilityTier::Nominal => "nominal",
    };
    GeometryQualityTerm {
        tier: tier.to_string(),
        redundancy: value.redundancy as i64,
        rank: value.rank as i64,
        condition_number: value.condition_number,
        gdop: value.gdop,
        raim_checkable: value.raim_checkable,
        covariance_validated: value.covariance_validated,
    }
}

fn covariance(value: OrbitFitCovariance) -> OrbitFitCovarianceTerm {
    match value {
        OrbitFitCovariance::Estimated { matrix } => OrbitFitCovarianceTerm {
            kind: "estimated".to_string(),
            matrix: Some(matrix.iter().map(|row| row.to_vec()).collect()),
        },
        OrbitFitCovariance::Unbounded => OrbitFitCovarianceTerm {
            kind: "unbounded".to_string(),
            matrix: None,
        },
    }
}

fn solution(value: OrbitFitSolution) -> OrbitFitSolutionTerm {
    OrbitFitSolutionTerm {
        satellite: value.satellite.to_string(),
        initial_state: StateTerm {
            epoch_tdb_seconds: value.initial_state.epoch_tdb_seconds,
            position_km: vec3(value.initial_state.position_array()),
            velocity_km_s: vec3(value.initial_state.velocity_array()),
        },
        covariance: covariance(value.covariance),
        geometry_quality: geometry_quality(value.geometry_quality),
        seed_rms_3d_m: value.seed_rms_3d_m,
        fit_rms_3d_m: value.fit_rms_3d_m,
        iterations: value.iterations as i64,
    }
}

fn residual_stats(value: OrbitResidualStats) -> OrbitResidualStatsTerm {
    OrbitResidualStatsTerm {
        radial_rms_m: value.radial_rms_m,
        along_rms_m: value.along_rms_m,
        cross_rms_m: value.cross_rms_m,
        rms_3d_m: value.rms_3d_m,
        n: value.n as i64,
        low_sample_count: value.low_sample_count,
    }
}

fn ledger(value: OrbitResidualLedger) -> OrbitResidualLedgerTerm {
    OrbitResidualLedgerTerm {
        per_sat: value
            .per_sat
            .into_iter()
            .map(|(sat, stats)| (sat.to_string(), residual_stats(stats)))
            .collect(),
        per_constellation: value
            .per_constellation
            .into_iter()
            .map(|(system, stats)| (system.letter().to_string(), residual_stats(stats)))
            .collect(),
        arc_span: OrbitArcSpanTerm {
            time_scale: value.arc_span.time_scale.abbrev().to_string(),
            start_j2000_s: value.arc_span.start_j2000_s,
            end_j2000_s: value.arc_span.end_j2000_s,
            duration_s: value.arc_span.duration_s,
        },
    }
}

fn report(value: OrbitFitReport) -> OrbitFitReportTerm {
    OrbitFitReportTerm {
        fits: value.fits.into_values().map(solution).collect(),
        ledger: ledger(value.ledger),
    }
}

fn error_atom(error: OrbitFitError) -> rustler::Atom {
    match error {
        OrbitFitError::EmptySelection => atoms::empty_selection(),
        OrbitFitError::InvalidOption { .. } => atoms::invalid_option(),
        OrbitFitError::TooFewSamples { .. } => atoms::too_few_samples(),
        OrbitFitError::NonMonotonicEpochs { .. } => atoms::non_monotonic_epochs(),
        OrbitFitError::MixedTimeScales => atoms::mixed_timescales(),
        OrbitFitError::InvalidEpoch { .. } => atoms::invalid_epoch(),
        OrbitFitError::InvalidObservation { .. } => atoms::invalid_observation(),
        OrbitFitError::Frame { .. } => atoms::frame(),
        OrbitFitError::Propagation { .. } => atoms::propagation(),
        OrbitFitError::LeastSquares { .. } => atoms::least_squares(),
        OrbitFitError::SingularGeometry { .. } => atoms::singular_geometry(),
        OrbitFitError::DidNotConverge { .. } => atoms::did_not_converge(),
        OrbitFitError::RtnFrame { .. } => atoms::rtn_frame(),
    }
}

fn encode_report<'a>(env: Env<'a>, result: Result<OrbitFitReport, OrbitFitError>) -> Term<'a> {
    match result {
        Ok(value) => (atoms::ok(), report(value)).encode(env),
        Err(error) => (atoms::error(), error_atom(error)).encode(env),
    }
}

/// Fit one satellite from a parsed SP3 product.
#[rustler::nif(schedule = "DirtyCpu")]
fn orbit_fit_sp3_precise_orbit<'a>(
    env: Env<'a>,
    handle: ResourceArc<Sp3Resource>,
    system_letter: String,
    prn: u8,
    opts: OptionsTerm,
) -> NifResult<Term<'a>> {
    let sat = satellite(system_letter, prn)?;
    let opts = options(opts)?;
    Ok(encode_report(
        env,
        fit_sp3_precise_orbit(&handle.sp3, sat, &opts),
    ))
}

/// Fit one satellite from a parsed ECEF SP3 product.
#[rustler::nif(schedule = "DirtyCpu")]
fn orbit_fit_sp3_ecef_precise_orbit<'a>(
    env: Env<'a>,
    handle: ResourceArc<Sp3Resource>,
    system_letter: String,
    prn: u8,
    opts: OptionsTerm,
) -> NifResult<Term<'a>> {
    let sat = satellite(system_letter, prn)?;
    let opts = options(opts)?;
    let provider = TdbEarthOrientationProvider::default();
    Ok(encode_report(
        env,
        fit_sp3_ecef_precise_orbit(&handle.sp3, sat, &provider, &opts),
    ))
}

/// Fit selected satellites from a parsed ECEF SP3 product.
#[rustler::nif(schedule = "DirtyCpu")]
fn orbit_fit_sp3_ecef_precise_orbits<'a>(
    env: Env<'a>,
    handle: ResourceArc<Sp3Resource>,
    satellite_terms: Vec<SatelliteTerm>,
    opts: OptionsTerm,
) -> NifResult<Term<'a>> {
    let satellites = satellites(satellite_terms)?;
    let opts = options(opts)?;
    let provider = TdbEarthOrientationProvider::default();
    Ok(encode_report(
        env,
        fit_sp3_ecef_precise_orbits(&handle.sp3, &satellites, &provider, &opts),
    ))
}

/// Fit every satellite in a parsed ECEF SP3 product.
#[rustler::nif(schedule = "DirtyCpu")]
fn orbit_fit_all_sp3_ecef_precise_orbits<'a>(
    env: Env<'a>,
    handle: ResourceArc<Sp3Resource>,
    opts: OptionsTerm,
) -> NifResult<Term<'a>> {
    let opts = options(opts)?;
    let provider = TdbEarthOrientationProvider::default();
    Ok(encode_report(
        env,
        fit_all_sp3_ecef_precise_orbits(&handle.sp3, &provider, &opts),
    ))
}

/// Fit one satellite from precise ephemeris sample terms.
#[rustler::nif(schedule = "DirtyCpu")]
fn orbit_fit_precise_ephemeris_sample_orbit<'a>(
    env: Env<'a>,
    sample_terms: Vec<SampleTerm>,
    system_letter: String,
    prn: u8,
    opts: OptionsTerm,
) -> NifResult<Term<'a>> {
    let samples = sample_terms
        .into_iter()
        .map(decode_sample)
        .collect::<NifResult<Vec<_>>>()?;
    let sat = satellite(system_letter, prn)?;
    let opts = options(opts)?;
    Ok(encode_report(
        env,
        fit_precise_ephemeris_sample_orbit(&samples, sat, &opts),
    ))
}
