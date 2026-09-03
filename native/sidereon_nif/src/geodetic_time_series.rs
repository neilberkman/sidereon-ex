//! Rustler boundary for geodetic position time-series estimators.

use rustler::{Encoder, Env, Error, NifResult, Term};
use sidereon_core::frame::Wgs84Geodetic;
use sidereon_core::geodetic_time_series::{
    detect_steps, fit_trajectory, network_field, velocity_midas, GeodeticTimeSeriesError, Loss,
    MidasComponentStats, MidasOptions, MotionField, NetworkFrame, NetworkStation, PositionFrame,
    PositionSample, PositionSeries, StepCandidate, StepDetectionOptions, TimeSeriesQuality,
    Trajectory, TrajectoryComponent, TrajectoryFitOptions, TrajectoryModel, TrajectoryTerm,
    Velocity,
};
use sidereon_core::geometry_quality::{GeometryQuality, ObservabilityTier};

mod atoms {
    rustler::atoms! {
        ok,
        error,
        invalid_input,
        too_few_samples,
        insufficient_pairs,
        singular_trajectory,
        did_not_converge,
        solver
    }
}

type Vec3 = (f64, f64, f64);
type GeodeticTerm = (f64, f64, f64);
type SampleTerm = (f64, Vec3, Option<Vec<Vec<f64>>>);
type FrameTerm = (String, Option<GeodeticTerm>);
type MidasOptionsTerm = (f64, f64, usize);
type TrajectoryModelTerm = (Option<f64>, bool, bool, Vec<f64>);
type TrajectoryFitOptionsTerm = (String, f64, Option<usize>);
type StepOptionsTerm = (f64, f64, f64, usize, f64, MidasOptionsTerm);
type NetworkFrameTerm = (GeodeticTerm, bool);
type NetworkStationTerm = (String, GeodeticTerm, FrameTerm, Vec<SampleTerm>);

#[derive(Debug, Clone, rustler::NifMap)]
struct MidasComponentStatsTerm {
    pair_count: i64,
    retained_pair_count: i64,
    slope_sigma_m_per_yr: f64,
    effective_pair_count: f64,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct VelocityTerm {
    rate_enu_m_per_yr: Vec3,
    sigma_enu_m_per_yr: Vec3,
    covariance_enu_m2_per_yr2: Vec<Vec<f64>>,
    component_stats: Vec<MidasComponentStatsTerm>,
    sample_count: i64,
    span_years: f64,
    quality: String,
}

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
struct TrajectoryComponentTerm {
    position_m: f64,
    velocity_m_per_yr: f64,
    annual_sin_m: Option<f64>,
    annual_cos_m: Option<f64>,
    semiannual_sin_m: Option<f64>,
    semiannual_cos_m: Option<f64>,
    offsets_m: Vec<f64>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct TrajectoryTermOut {
    reference_epoch_year: f64,
    terms: Vec<(String, Option<i64>, Option<f64>)>,
    components: Vec<TrajectoryComponentTerm>,
    parameter_covariance: Vec<Vec<f64>>,
    residual_rms_enu_m: Vec3,
    geometry_quality: GeometryQualityTerm,
    status: i32,
    nfev: i64,
    njev: i64,
    cost: f64,
    optimality: f64,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct StepCandidateTerm {
    epoch_year: f64,
    offset_enu_m: Vec3,
    score: f64,
    before_count: i64,
    after_count: i64,
    heuristic: String,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct StationMotionTerm {
    id: String,
    rate_enu_m_per_yr: Vec3,
    raw_rate_enu_m_per_yr: Vec3,
    sigma_enu_m_per_yr: Vec3,
    local_velocity: VelocityTerm,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct MotionFieldTerm {
    origin: GeodeticTerm,
    remove_common_mode: bool,
    stations: Vec<StationMotionTerm>,
    common_mode_enu_m_per_yr: Vec3,
}

struct StationOwned {
    id: String,
    reference: Wgs84Geodetic,
    frame: PositionFrame,
    samples: Vec<PositionSample>,
}

fn vec3(value: [f64; 3]) -> Vec3 {
    (value[0], value[1], value[2])
}

fn matrix3(rows: Vec<Vec<f64>>) -> NifResult<[[f64; 3]; 3]> {
    if rows.len() != 3 || rows.iter().any(|row| row.len() != 3) {
        return Err(Error::Term(Box::new("matrix must be 3x3")));
    }
    Ok([
        [rows[0][0], rows[0][1], rows[0][2]],
        [rows[1][0], rows[1][1], rows[1][2]],
        [rows[2][0], rows[2][1], rows[2][2]],
    ])
}

fn matrix3_vec(matrix: [[f64; 3]; 3]) -> Vec<Vec<f64>> {
    matrix
        .into_iter()
        .map(|row| row.into_iter().collect())
        .collect()
}

fn geodetic((lat_rad, lon_rad, height_m): GeodeticTerm) -> NifResult<Wgs84Geodetic> {
    Wgs84Geodetic::new(lat_rad, lon_rad, height_m).map_err(crate::errors::invalid_input)
}

fn frame((kind, reference): FrameTerm) -> NifResult<PositionFrame> {
    match kind.as_str() {
        "enu" => Ok(PositionFrame::Enu),
        "ecef" => Ok(PositionFrame::Ecef {
            reference: geodetic(
                reference
                    .ok_or_else(|| Error::Term(Box::new("ecef frame requires a reference")))?,
            )?,
        }),
        _ => Err(Error::Term(Box::new("unknown position frame"))),
    }
}

fn sample((epoch_year, (x, y, z), covariance): SampleTerm) -> NifResult<PositionSample> {
    Ok(PositionSample {
        epoch_year,
        position_m: [x, y, z],
        covariance_m2: covariance.map(matrix3).transpose()?,
    })
}

fn samples(values: Vec<SampleTerm>) -> NifResult<Vec<PositionSample>> {
    values.into_iter().map(sample).collect()
}

fn midas_options(
    (dominant_period_years, period_tolerance_years, min_pairs): MidasOptionsTerm,
) -> MidasOptions {
    let mut options = MidasOptions::default();
    options.dominant_period_years = dominant_period_years;
    options.period_tolerance_years = period_tolerance_years;
    options.min_pairs = min_pairs;
    options
}

fn trajectory_model(
    (reference_epoch_year, include_annual, include_semiannual, offset_epochs_year): TrajectoryModelTerm,
) -> TrajectoryModel {
    TrajectoryModel {
        reference_epoch_year,
        include_annual,
        include_semiannual,
        offset_epochs_year,
    }
}

fn loss(kind: &str) -> NifResult<Loss> {
    match kind {
        "linear" => Ok(Loss::Linear),
        "soft_l1" => Ok(Loss::SoftL1),
        "huber" => Ok(Loss::Huber),
        "cauchy" => Ok(Loss::Cauchy),
        "arctan" => Ok(Loss::Arctan),
        _ => Err(Error::Term(Box::new("unknown trajectory loss"))),
    }
}

fn fit_options(
    (loss_kind, f_scale_m, max_nfev): TrajectoryFitOptionsTerm,
) -> NifResult<TrajectoryFitOptions> {
    let mut options = TrajectoryFitOptions::default();
    options.loss = loss(&loss_kind)?;
    options.f_scale_m = f_scale_m;
    options.max_nfev = max_nfev;
    Ok(options)
}

fn step_options(
    (
        window_years,
        score_threshold,
        min_offset_m,
        min_samples_each_side,
        min_separation_years,
        midas,
    ): StepOptionsTerm,
) -> StepDetectionOptions {
    let mut options = StepDetectionOptions::default();
    options.window_years = window_years;
    options.score_threshold = score_threshold;
    options.min_offset_m = min_offset_m;
    options.min_samples_each_side = min_samples_each_side;
    options.min_separation_years = min_separation_years;
    options.midas = midas_options(midas);
    options
}

fn network_frame(
    ((lat_rad, lon_rad, height_m), remove_common_mode): NetworkFrameTerm,
) -> NifResult<NetworkFrame> {
    Ok(NetworkFrame {
        origin: geodetic((lat_rad, lon_rad, height_m))?,
        remove_common_mode,
    })
}

fn quality(value: TimeSeriesQuality) -> String {
    match value {
        TimeSeriesQuality::Nominal => "nominal",
        TimeSeriesQuality::ShortSpan => "short_span",
    }
    .to_string()
}

fn component_stats(value: MidasComponentStats) -> MidasComponentStatsTerm {
    MidasComponentStatsTerm {
        pair_count: value.pair_count as i64,
        retained_pair_count: value.retained_pair_count as i64,
        slope_sigma_m_per_yr: value.slope_sigma_m_per_yr,
        effective_pair_count: value.effective_pair_count,
    }
}

fn velocity_term(value: Velocity) -> VelocityTerm {
    VelocityTerm {
        rate_enu_m_per_yr: vec3(value.rate_enu_m_per_yr),
        sigma_enu_m_per_yr: vec3(value.sigma_enu_m_per_yr),
        covariance_enu_m2_per_yr2: matrix3_vec(value.covariance_enu_m2_per_yr2),
        component_stats: value
            .component_stats
            .into_iter()
            .map(component_stats)
            .collect(),
        sample_count: value.sample_count as i64,
        span_years: value.span_years,
        quality: quality(value.quality),
    }
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

fn trajectory_component(value: TrajectoryComponent) -> TrajectoryComponentTerm {
    TrajectoryComponentTerm {
        position_m: value.position_m,
        velocity_m_per_yr: value.velocity_m_per_yr,
        annual_sin_m: value.annual_sin_m,
        annual_cos_m: value.annual_cos_m,
        semiannual_sin_m: value.semiannual_sin_m,
        semiannual_cos_m: value.semiannual_cos_m,
        offsets_m: value.offsets_m,
    }
}

fn trajectory_term(value: TrajectoryTerm) -> (String, Option<i64>, Option<f64>) {
    match value {
        TrajectoryTerm::Position => ("position".to_string(), None, None),
        TrajectoryTerm::Velocity => ("velocity".to_string(), None, None),
        TrajectoryTerm::AnnualSin => ("annual_sin".to_string(), None, None),
        TrajectoryTerm::AnnualCos => ("annual_cos".to_string(), None, None),
        TrajectoryTerm::SemiannualSin => ("semiannual_sin".to_string(), None, None),
        TrajectoryTerm::SemiannualCos => ("semiannual_cos".to_string(), None, None),
        TrajectoryTerm::Offset { index, epoch_year } => {
            ("offset".to_string(), Some(index as i64), Some(epoch_year))
        }
    }
}

fn trajectory_term_out(value: Trajectory) -> TrajectoryTermOut {
    TrajectoryTermOut {
        reference_epoch_year: value.reference_epoch_year,
        terms: value.terms.into_iter().map(trajectory_term).collect(),
        components: value
            .components
            .into_iter()
            .map(trajectory_component)
            .collect(),
        parameter_covariance: value.parameter_covariance,
        residual_rms_enu_m: vec3(value.residual_rms_enu_m),
        geometry_quality: geometry_quality(value.geometry_quality),
        status: value.status,
        nfev: value.nfev as i64,
        njev: value.njev as i64,
        cost: value.cost,
        optimality: value.optimality,
    }
}

fn step_candidate(value: StepCandidate) -> StepCandidateTerm {
    StepCandidateTerm {
        epoch_year: value.epoch_year,
        offset_enu_m: vec3(value.offset_enu_m),
        score: value.score,
        before_count: value.before_count as i64,
        after_count: value.after_count as i64,
        heuristic: "detrended_sliding_median".to_string(),
    }
}

fn station_owned(
    (id, reference, series_frame, series_samples): NetworkStationTerm,
) -> NifResult<StationOwned> {
    Ok(StationOwned {
        id,
        reference: geodetic(reference)?,
        frame: frame(series_frame)?,
        samples: samples(series_samples)?,
    })
}

fn station_motion(value: sidereon_core::geodetic_time_series::StationMotion) -> StationMotionTerm {
    StationMotionTerm {
        id: value.id,
        rate_enu_m_per_yr: vec3(value.rate_enu_m_per_yr),
        raw_rate_enu_m_per_yr: vec3(value.raw_rate_enu_m_per_yr),
        sigma_enu_m_per_yr: vec3(value.sigma_enu_m_per_yr),
        local_velocity: velocity_term(value.local_velocity),
    }
}

fn motion_field(value: MotionField) -> MotionFieldTerm {
    MotionFieldTerm {
        origin: (
            value.frame.origin.lat_rad,
            value.frame.origin.lon_rad,
            value.frame.origin.height_m,
        ),
        remove_common_mode: value.frame.remove_common_mode,
        stations: value.stations.into_iter().map(station_motion).collect(),
        common_mode_enu_m_per_yr: vec3(value.common_mode_enu_m_per_yr),
    }
}

fn error_atom(error: GeodeticTimeSeriesError) -> rustler::Atom {
    match error {
        GeodeticTimeSeriesError::InvalidInput { .. } => atoms::invalid_input(),
        GeodeticTimeSeriesError::TooFewSamples { .. } => atoms::too_few_samples(),
        GeodeticTimeSeriesError::InsufficientPairs { .. } => atoms::insufficient_pairs(),
        GeodeticTimeSeriesError::SingularTrajectory => atoms::singular_trajectory(),
        GeodeticTimeSeriesError::DidNotConverge { .. } => atoms::did_not_converge(),
        GeodeticTimeSeriesError::Solver(_) => atoms::solver(),
    }
}

fn encode_result<'a, T: Encoder>(
    env: Env<'a>,
    result: Result<T, GeodeticTimeSeriesError>,
) -> Term<'a> {
    match result {
        Ok(value) => (atoms::ok(), value).encode(env),
        Err(error) => (atoms::error(), error_atom(error)).encode(env),
    }
}

/// Estimate robust station velocity with MIDAS.
#[rustler::nif(schedule = "DirtyCpu")]
fn geodetic_velocity_midas<'a>(
    env: Env<'a>,
    frame_term: FrameTerm,
    sample_terms: Vec<SampleTerm>,
    opts: MidasOptionsTerm,
) -> NifResult<Term<'a>> {
    let frame = frame(frame_term)?;
    let samples = samples(sample_terms)?;
    let series = PositionSeries {
        frame,
        samples: &samples,
    };
    Ok(encode_result(
        env,
        velocity_midas(&series, midas_options(opts)).map(velocity_term),
    ))
}

/// Fit a linear trajectory model to a geodetic time series.
#[rustler::nif(schedule = "DirtyCpu")]
fn geodetic_fit_trajectory<'a>(
    env: Env<'a>,
    frame_term: FrameTerm,
    sample_terms: Vec<SampleTerm>,
    model: TrajectoryModelTerm,
    opts: TrajectoryFitOptionsTerm,
) -> NifResult<Term<'a>> {
    let frame = frame(frame_term)?;
    let samples = samples(sample_terms)?;
    let model = trajectory_model(model);
    let series = PositionSeries {
        frame,
        samples: &samples,
    };
    Ok(encode_result(
        env,
        fit_trajectory(&series, &model, fit_options(opts)?).map(trajectory_term_out),
    ))
}

/// Detect displacement step candidates.
#[rustler::nif(schedule = "DirtyCpu")]
fn geodetic_detect_steps<'a>(
    env: Env<'a>,
    frame_term: FrameTerm,
    sample_terms: Vec<SampleTerm>,
    opts: StepOptionsTerm,
) -> NifResult<Term<'a>> {
    let frame = frame(frame_term)?;
    let samples = samples(sample_terms)?;
    let series = PositionSeries {
        frame,
        samples: &samples,
    };
    Ok(encode_result(
        env,
        detect_steps(&series, step_options(opts))
            .map(|items| items.into_iter().map(step_candidate).collect::<Vec<_>>()),
    ))
}

/// Estimate a station network motion field.
#[rustler::nif(schedule = "DirtyCpu")]
fn geodetic_network_field<'a>(
    env: Env<'a>,
    station_terms: Vec<NetworkStationTerm>,
    frame_term: NetworkFrameTerm,
) -> NifResult<Term<'a>> {
    let owned = station_terms
        .into_iter()
        .map(station_owned)
        .collect::<NifResult<Vec<_>>>()?;
    let stations = owned
        .iter()
        .map(|station| NetworkStation {
            id: station.id.as_str(),
            reference: station.reference,
            series: PositionSeries {
                frame: station.frame,
                samples: &station.samples,
            },
        })
        .collect::<Vec<_>>();
    Ok(encode_result(
        env,
        network_field(&stations, network_frame(frame_term)?).map(motion_field),
    ))
}
