//! Rustler boundary for Allan-family clock-stability estimators.
//!
//! The estimator numerics live in `sidereon_core::clock_stability`. This module
//! decodes tagged sample series and option terms, calls the core functions, and
//! encodes the result curves. Numeric samples cross as ordinary list terms.

use crate::rinex_obs::RinexObsResource;
use rustler::{Encoder, Env, Error, NifResult, ResourceArc, Term};
use sidereon_core::clock_stability::{
    allan_deviation, allan_deviation_power_law_slope, compute_allan_deviations,
    fit_power_law_noise, hadamard_deviation, modified_adev,
    modified_allan_deviation_power_law_slope, overlapping_adev, receiver_clock_phase_deviations,
    time_deviation, AllanDeviationCurves, AllanError, AllanEstimator, AllanEstimatorSet,
    AllanInput, AllanOptions, AllanResult, AllanSeries, GapPolicy, PowerLawNoiseError,
    PowerLawNoiseFit, PowerLawNoiseOptions, PowerLawNoiseRegion, PowerLawNoiseType, PowerLawOctave,
    PowerLawOctaveDominance, PowerLawOctaveFlag, TauGrid,
};

mod atoms {
    rustler::atoms! {
        ok,
        error,
        empty_series,
        invalid_tau0,
        no_estimators,
        empty_tau_grid,
        invalid_averaging_factor,
        too_few_samples,
        non_finite_sample,
        gap,
        non_finite_tau,
        non_finite_deviation,
        invalid_options,
        invalid_curve
    }
}

#[derive(Debug, Clone, rustler::NifMap)]
struct AllanResultTerm {
    tau_s: Vec<f64>,
    deviation: Vec<f64>,
    n: Vec<i64>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct AllanCurvesTerm {
    adev: Option<AllanResultTerm>,
    overlapping_adev: Option<AllanResultTerm>,
    mdev: Option<AllanResultTerm>,
    hdev: Option<AllanResultTerm>,
    tdev: Option<AllanResultTerm>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct PowerLawOctaveTerm {
    tau_start_s: f64,
    tau_end_s: f64,
    point_count: i64,
    adev_slope: Option<f64>,
    mdev_slope: Option<f64>,
    slope_scatter: Option<f64>,
    dominance: String,
    noise_type: Option<String>,
    flag: Option<String>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct PowerLawRegionTerm {
    noise_type: String,
    tau_start_s: f64,
    tau_end_s: f64,
    octave_count: i64,
    point_count: i64,
    mean_slope: f64,
    coefficient: f64,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct PowerLawFitTerm {
    dominant_per_octave: Vec<PowerLawOctaveTerm>,
    coefficients: Vec<f64>,
    regions: Vec<PowerLawRegionTerm>,
}

type PowerLawOptionsTerm = (usize, f64, f64, f64, f64);

enum SeriesOwned {
    Values(Vec<f64>),
    Gapped(Vec<Option<f64>>),
}

impl SeriesOwned {
    fn as_series(&self, kind: &str) -> NifResult<AllanSeries<'_>> {
        match (kind, self) {
            ("phase_seconds", Self::Values(values)) => Ok(AllanSeries::PhaseSeconds(values)),
            ("fractional_frequency", Self::Values(values)) => {
                Ok(AllanSeries::FractionalFrequency(values))
            }
            ("phase_seconds_with_gaps", Self::Gapped(values)) => {
                Ok(AllanSeries::PhaseSecondsWithGaps(values))
            }
            ("fractional_frequency_with_gaps", Self::Gapped(values)) => {
                Ok(AllanSeries::FractionalFrequencyWithGaps(values))
            }
            _ => Err(Error::Term(Box::new("unknown Allan series kind"))),
        }
    }
}

fn series_owned(kind: &str, samples: Vec<Option<f64>>) -> NifResult<SeriesOwned> {
    match kind {
        "phase_seconds" | "fractional_frequency" => {
            let mut values = Vec::with_capacity(samples.len());
            for value in samples {
                values.push(value.ok_or_else(|| Error::Term(Box::new("unexpected gap")))?);
            }
            Ok(SeriesOwned::Values(values))
        }
        "phase_seconds_with_gaps" | "fractional_frequency_with_gaps" => {
            Ok(SeriesOwned::Gapped(samples))
        }
        _ => Err(Error::Term(Box::new("unknown Allan series kind"))),
    }
}

fn tau_grid(kind: &str, factors: Vec<usize>) -> NifResult<TauGrid> {
    match kind {
        "octave" => Ok(TauGrid::Octave),
        "all" => Ok(TauGrid::All),
        "explicit" => Ok(TauGrid::Explicit(factors)),
        _ => Err(Error::Term(Box::new("unknown Allan tau grid"))),
    }
}

fn gap_policy(kind: &str) -> NifResult<GapPolicy> {
    match kind {
        "reject" => Ok(GapPolicy::Reject),
        "omit_terms" => Ok(GapPolicy::OmitTerms),
        _ => Err(Error::Term(Box::new("unknown Allan gap policy"))),
    }
}

fn estimator_set(
    (adev, overlapping_adev, mdev, hdev, tdev): (bool, bool, bool, bool, bool),
) -> AllanEstimatorSet {
    AllanEstimatorSet {
        adev,
        overlapping_adev,
        mdev,
        hdev,
        tdev,
    }
}

fn result_term(result: AllanResult) -> AllanResultTerm {
    AllanResultTerm {
        tau_s: result.tau_s,
        deviation: result.deviation,
        n: result.n.into_iter().map(|value| value as i64).collect(),
    }
}

fn result_from_term(term: AllanResultTerm) -> NifResult<AllanResult> {
    if term.n.iter().any(|value| *value < 0) {
        return Err(Error::Term(Box::new("negative Allan term count")));
    }
    Ok(AllanResult {
        tau_s: term.tau_s,
        deviation: term.deviation,
        n: term.n.into_iter().map(|value| value as usize).collect(),
    })
}

fn curves_term(curves: AllanDeviationCurves) -> AllanCurvesTerm {
    AllanCurvesTerm {
        adev: curves.adev.map(result_term),
        overlapping_adev: curves.overlapping_adev.map(result_term),
        mdev: curves.mdev.map(result_term),
        hdev: curves.hdev.map(result_term),
        tdev: curves.tdev.map(result_term),
    }
}

fn error_atom(error: AllanError) -> rustler::Atom {
    match error {
        AllanError::EmptySeries => atoms::empty_series(),
        AllanError::InvalidTau0 { .. } => atoms::invalid_tau0(),
        AllanError::NoEstimators => atoms::no_estimators(),
        AllanError::EmptyTauGrid => atoms::empty_tau_grid(),
        AllanError::InvalidAveragingFactor { .. } => atoms::invalid_averaging_factor(),
        AllanError::TooFewSamples { .. } => atoms::too_few_samples(),
        AllanError::NonFiniteSample { .. } => atoms::non_finite_sample(),
        AllanError::Gap { .. } => atoms::gap(),
        AllanError::NonFiniteTau { .. } => atoms::non_finite_tau(),
        AllanError::NonFiniteDeviation { .. } => atoms::non_finite_deviation(),
    }
}

fn estimator(kind: &str) -> NifResult<AllanEstimator> {
    match kind {
        "adev" => Ok(AllanEstimator::Adev),
        "overlapping_adev" => Ok(AllanEstimator::OverlappingAdev),
        "mdev" => Ok(AllanEstimator::Mdev),
        "hdev" => Ok(AllanEstimator::Hdev),
        "tdev" => Ok(AllanEstimator::Tdev),
        _ => Err(Error::Term(Box::new("unknown Allan estimator"))),
    }
}

fn noise_type(kind: &str) -> NifResult<PowerLawNoiseType> {
    match kind {
        "random_walk_fm" => Ok(PowerLawNoiseType::RandomWalkFM),
        "flicker_fm" => Ok(PowerLawNoiseType::FlickerFM),
        "white_fm" => Ok(PowerLawNoiseType::WhiteFM),
        "flicker_pm" => Ok(PowerLawNoiseType::FlickerPM),
        "white_pm" => Ok(PowerLawNoiseType::WhitePM),
        _ => Err(Error::Term(Box::new("unknown power-law noise type"))),
    }
}

fn noise_type_string(value: PowerLawNoiseType) -> String {
    match value {
        PowerLawNoiseType::RandomWalkFM => "random_walk_fm",
        PowerLawNoiseType::FlickerFM => "flicker_fm",
        PowerLawNoiseType::WhiteFM => "white_fm",
        PowerLawNoiseType::FlickerPM => "flicker_pm",
        PowerLawNoiseType::WhitePM => "white_pm",
    }
    .to_string()
}

fn flag_string(value: PowerLawOctaveFlag) -> String {
    match value {
        PowerLawOctaveFlag::UnderSampled => "under_sampled",
        PowerLawOctaveFlag::DegenerateDeviation => "degenerate_deviation",
        PowerLawOctaveFlag::MissingModifiedAllan => "missing_modified_allan",
    }
    .to_string()
}

fn power_law_options(
    (
        min_points_per_octave,
        slope_tolerance,
        scatter_tolerance,
        basic_tau_s,
        measurement_bandwidth_hz,
    ): PowerLawOptionsTerm,
) -> PowerLawNoiseOptions {
    let mut options = PowerLawNoiseOptions::new(basic_tau_s, measurement_bandwidth_hz);
    options.min_points_per_octave = min_points_per_octave;
    options.slope_tolerance = slope_tolerance;
    options.scatter_tolerance = scatter_tolerance;
    options
}

fn power_law_error_atom(error: PowerLawNoiseError) -> rustler::Atom {
    match error {
        PowerLawNoiseError::InvalidOptions { .. } => atoms::invalid_options(),
        PowerLawNoiseError::InvalidCurve { .. } => atoms::invalid_curve(),
    }
}

fn octave_term(value: PowerLawOctave) -> PowerLawOctaveTerm {
    let (dominance, noise_type, flag) = match value.dominance {
        PowerLawOctaveDominance::Dominant(noise_type) => (
            "dominant".to_string(),
            Some(noise_type_string(noise_type)),
            None,
        ),
        PowerLawOctaveDominance::Ambiguous => ("ambiguous".to_string(), None, None),
        PowerLawOctaveDominance::Flagged(flag) => {
            ("flagged".to_string(), None, Some(flag_string(flag)))
        }
    };
    PowerLawOctaveTerm {
        tau_start_s: value.tau_start_s,
        tau_end_s: value.tau_end_s,
        point_count: value.point_count as i64,
        adev_slope: value.adev_slope,
        mdev_slope: value.mdev_slope,
        slope_scatter: value.slope_scatter,
        dominance,
        noise_type,
        flag,
    }
}

fn region_term(value: PowerLawNoiseRegion) -> PowerLawRegionTerm {
    PowerLawRegionTerm {
        noise_type: noise_type_string(value.noise_type),
        tau_start_s: value.tau_start_s,
        tau_end_s: value.tau_end_s,
        octave_count: value.octave_count as i64,
        point_count: value.point_count as i64,
        mean_slope: value.mean_slope,
        coefficient: value.coefficient,
    }
}

fn fit_term(value: PowerLawNoiseFit) -> PowerLawFitTerm {
    PowerLawFitTerm {
        dominant_per_octave: value
            .dominant_per_octave
            .into_iter()
            .map(octave_term)
            .collect(),
        coefficients: value.coefficients.into_iter().collect(),
        regions: value.regions.into_iter().map(region_term).collect(),
    }
}

fn compute_one(
    estimator_kind: &str,
    series: AllanSeries<'_>,
    tau0_s: f64,
    averaging_factors: &[usize],
) -> Result<AllanResult, AllanError> {
    match estimator(estimator_kind).map_err(|_| AllanError::NoEstimators)? {
        AllanEstimator::Adev => allan_deviation(series, tau0_s, averaging_factors),
        AllanEstimator::OverlappingAdev => overlapping_adev(series, tau0_s, averaging_factors),
        AllanEstimator::Mdev => modified_adev(series, tau0_s, averaging_factors),
        AllanEstimator::Hdev => hadamard_deviation(series, tau0_s, averaging_factors),
        AllanEstimator::Tdev => time_deviation(series, tau0_s, averaging_factors),
    }
}

/// Compute one explicit Allan-family estimator curve.
#[rustler::nif(schedule = "DirtyCpu")]
fn clock_allan_estimator<'a>(
    env: Env<'a>,
    estimator_kind: String,
    series_kind: String,
    samples: Vec<Option<f64>>,
    tau0_s: f64,
    averaging_factors: Vec<usize>,
) -> NifResult<Term<'a>> {
    let storage = series_owned(&series_kind, samples)?;
    let series = storage.as_series(&series_kind)?;
    Ok(
        match compute_one(&estimator_kind, series, tau0_s, &averaging_factors) {
            Ok(result) => (atoms::ok(), result_term(result)).encode(env),
            Err(error) => (atoms::error(), error_atom(error)).encode(env),
        },
    )
}

/// Compute a configured set of Allan-family curves.
#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
fn clock_compute_allan_deviations<'a>(
    env: Env<'a>,
    series_kind: String,
    samples: Vec<Option<f64>>,
    tau0_s: f64,
    estimators: (bool, bool, bool, bool, bool),
    tau_grid_kind: String,
    tau_grid_factors: Vec<usize>,
    gap_policy_kind: String,
) -> NifResult<Term<'a>> {
    let storage = series_owned(&series_kind, samples)?;
    let series = storage.as_series(&series_kind)?;
    let mut allan_options = AllanOptions::default();
    allan_options.estimators = estimator_set(estimators);
    allan_options.tau_grid = tau_grid(&tau_grid_kind, tau_grid_factors)?;
    allan_options.gap_policy = gap_policy(&gap_policy_kind)?;
    let input = AllanInput {
        series,
        tau0_s,
        options: allan_options,
    };
    Ok(match compute_allan_deviations(&input) {
        Ok(curves) => (atoms::ok(), curves_term(curves)).encode(env),
        Err(error) => (atoms::error(), error_atom(error)).encode(env),
    })
}

/// Extract RINEX receiver-clock offsets as phase deviations in seconds.
#[rustler::nif(schedule = "DirtyCpu")]
fn clock_receiver_phase_deviations(handle: ResourceArc<RinexObsResource>) -> Vec<Option<f64>> {
    receiver_clock_phase_deviations(&handle.obs)
}

/// Return the exact log-log slope for a power-law noise type.
#[rustler::nif]
fn clock_power_law_slope(noise_type_kind: String, estimator_kind: String) -> NifResult<f64> {
    let noise_type = noise_type(&noise_type_kind)?;
    match estimator_kind.as_str() {
        "adev" | "overlapping_adev" => Ok(allan_deviation_power_law_slope(noise_type)),
        "mdev" => Ok(modified_allan_deviation_power_law_slope(noise_type)),
        _ => Err(Error::Term(Box::new("unknown power-law slope estimator"))),
    }
}

/// Identify power-law clock noise from supplied ADEV and MDEV curves.
#[rustler::nif(schedule = "DirtyCpu")]
fn clock_fit_power_law_noise<'a>(
    env: Env<'a>,
    adev: AllanResultTerm,
    mdev: AllanResultTerm,
    opts: PowerLawOptionsTerm,
) -> NifResult<Term<'a>> {
    let adev = result_from_term(adev)?;
    let mdev = result_from_term(mdev)?;
    Ok(
        match fit_power_law_noise(&adev, &mdev, power_law_options(opts)) {
            Ok(fit) => (atoms::ok(), fit_term(fit)).encode(env),
            Err(error) => (atoms::error(), power_law_error_atom(error)).encode(env),
        },
    )
}
