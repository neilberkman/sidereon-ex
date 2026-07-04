//! Rustler boundary for source localization.
//!
//! The ToA/TDOA solve, Chan-Ho seed, DOP, and CRLB are all delegated to
//! `sidereon-core::source_localization`. This module only decodes Elixir terms
//! and encodes core result structs.

use rustler::{Encoder, Env, Term};
use sidereon_core::dop::{Dop, DopError};
use sidereon_core::source_localization::{
    chan_ho_initial_guess, locate_source, source_crlb, source_dop, Loss, Sensor, SourceCovariance,
    SourceCrlb, SourceGeometryQuality, SourceInitialGuess, SourceLocalizationError,
    SourceLocateOptions, SourceResidual, SourceSensorInfluence, SourceSolution, SourceSolveMode,
};

type SensorTerm = (Vec<f64>, Option<f64>);
type ModeTerm = (String, usize);
type OptionsTerm = (
    (ModeTerm, f64, String, f64),
    (Option<f64>, Option<f64>, Option<f64>, Option<usize>),
);
type DopTerm = (f64, f64, f64, f64, f64);
type CovarianceTerm = (Vec<Vec<f64>>, Vec<Vec<f64>>, Option<f64>, f64);
type ResidualTerm = (usize, Option<usize>, f64);
type InfluenceTerm = (usize, f64, Option<f64>, Option<f64>, Option<f64>, f64, f64);
type GeometryQualityTerm = (usize, usize, usize, bool, bool);
type InitialGuessTerm = (Vec<f64>, Option<f64>, f64);
type SolutionTerm = (
    (
        Vec<f64>,
        Option<f64>,
        Option<CovarianceTerm>,
        Vec<ResidualTerm>,
        Vec<InfluenceTerm>,
        GeometryQualityTerm,
        InitialGuessTerm,
    ),
    (i32, usize, usize, f64, f64),
);
type CrlbTerm = (DopTerm, CovarianceTerm);

mod atoms {
    rustler::atoms! {
        ok,
        error,
        invalid_input,
        too_few_sensors,
        initializer_singular,
        geometry,
        solver,
        did_not_converge,
        too_few_satellites,
        singular
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn source_localization_locate<'a>(
    env: Env<'a>,
    sensors: Vec<SensorTerm>,
    arrival_times_s: Vec<f64>,
    propagation_speed_m_s: f64,
    options: OptionsTerm,
) -> Term<'a> {
    let options = decode_options(options);
    let result = match options {
        Ok(options) => locate_source(
            &decode_sensors(sensors),
            &arrival_times_s,
            propagation_speed_m_s,
            &options,
        )
        .map(solution_to_term),
        Err(error) => Err(error),
    };
    encode_result(env, result)
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn source_localization_chan_ho_initial_guess<'a>(
    env: Env<'a>,
    sensors: Vec<SensorTerm>,
    arrival_times_s: Vec<f64>,
    propagation_speed_m_s: f64,
    mode: ModeTerm,
) -> Term<'a> {
    let mode = decode_mode(mode);
    let result = match mode {
        Ok(mode) => chan_ho_initial_guess(
            &decode_sensors(sensors),
            &arrival_times_s,
            propagation_speed_m_s,
            mode,
        )
        .map(initial_guess_to_term),
        Err(error) => Err(error),
    };
    encode_result(env, result)
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn source_localization_dop<'a>(
    env: Env<'a>,
    sensors: Vec<SensorTerm>,
    source_position_m: Vec<f64>,
    propagation_speed_m_s: f64,
) -> Term<'a> {
    let result = source_dop(
        &decode_sensors(sensors),
        &source_position_m,
        propagation_speed_m_s,
    )
    .map(dop_to_term);
    encode_result(env, result)
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn source_localization_crlb<'a>(
    env: Env<'a>,
    sensors: Vec<SensorTerm>,
    source_position_m: Vec<f64>,
    propagation_speed_m_s: f64,
    timing_sigma_s: f64,
) -> Term<'a> {
    let result = source_crlb(
        &decode_sensors(sensors),
        &source_position_m,
        propagation_speed_m_s,
        timing_sigma_s,
    )
    .map(crlb_to_term);
    encode_result(env, result)
}

fn encode_result<'a, T: Encoder>(
    env: Env<'a>,
    result: Result<T, SourceLocalizationError>,
) -> Term<'a> {
    match result {
        Ok(value) => (atoms::ok(), value).encode(env),
        Err(error) => (atoms::error(), source_error_reason(env, error)).encode(env),
    }
}

fn decode_sensors(sensors: Vec<SensorTerm>) -> Vec<Sensor> {
    sensors
        .into_iter()
        .map(|(position_m, propagation_speed_m_s)| Sensor {
            position_m,
            propagation_speed_m_s,
        })
        .collect()
}

fn decode_options(
    ((mode, timing_sigma_s, loss, f_scale_s), (ftol, xtol, gtol, max_nfev)): OptionsTerm,
) -> Result<SourceLocateOptions, SourceLocalizationError> {
    Ok(SourceLocateOptions {
        mode: decode_mode(mode)?,
        timing_sigma_s,
        loss: decode_loss(&loss)?,
        f_scale_s,
        ftol,
        xtol,
        gtol,
        max_nfev,
    })
}

fn decode_mode(
    (label, reference_sensor): ModeTerm,
) -> Result<SourceSolveMode, SourceLocalizationError> {
    match label.as_str() {
        "toa" => Ok(SourceSolveMode::Toa),
        "tdoa" => Ok(SourceSolveMode::Tdoa { reference_sensor }),
        _ => Err(invalid_input("mode", "must be toa or tdoa")),
    }
}

fn decode_loss(loss: &str) -> Result<Loss, SourceLocalizationError> {
    match loss {
        "linear" => Ok(Loss::Linear),
        "huber" => Ok(Loss::Huber),
        "soft_l1" => Ok(Loss::SoftL1),
        "cauchy" => Ok(Loss::Cauchy),
        "arctan" => Ok(Loss::Arctan),
        _ => Err(invalid_input("loss", "unknown loss")),
    }
}

fn solution_to_term(solution: SourceSolution) -> SolutionTerm {
    (
        (
            solution.position_m,
            solution.origin_time_s,
            solution.covariance.map(covariance_to_term),
            solution
                .residuals
                .into_iter()
                .map(residual_to_term)
                .collect(),
            solution
                .per_sensor_influence
                .into_iter()
                .map(influence_to_term)
                .collect(),
            geometry_quality_to_term(solution.geometry_quality),
            initial_guess_to_term(solution.initial_guess),
        ),
        (
            solution.status,
            solution.nfev,
            solution.njev,
            solution.cost,
            solution.optimality,
        ),
    )
}

fn crlb_to_term(crlb: SourceCrlb) -> CrlbTerm {
    (dop_to_term(crlb.dop), covariance_to_term(crlb.covariance))
}

fn covariance_to_term(covariance: SourceCovariance) -> CovarianceTerm {
    (
        covariance.state,
        covariance.position_m2,
        covariance.origin_time_s2,
        covariance.timing_sigma_s,
    )
}

fn residual_to_term(residual: SourceResidual) -> ResidualTerm {
    (
        residual.sensor_index,
        residual.reference_sensor_index,
        residual.residual_s,
    )
}

fn influence_to_term(influence: SourceSensorInfluence) -> InfluenceTerm {
    (
        influence.sensor_index,
        influence.residual_s,
        influence.leave_one_out_residual_s,
        influence.position_delta_m,
        influence.origin_time_delta_s,
        influence.loss_weight,
        influence.score,
    )
}

fn geometry_quality_to_term(quality: SourceGeometryQuality) -> GeometryQualityTerm {
    (
        quality.residual_count,
        quality.parameter_count,
        quality.redundancy,
        quality.covariance_available,
        quality.rank_deficient,
    )
}

fn initial_guess_to_term(initial_guess: SourceInitialGuess) -> InitialGuessTerm {
    (
        initial_guess.position_m,
        initial_guess.origin_time_s,
        initial_guess.residual_rms_s,
    )
}

fn dop_to_term(dop: Dop) -> DopTerm {
    (dop.gdop, dop.pdop, dop.hdop, dop.vdop, dop.tdop)
}

fn source_error_reason<'a>(env: Env<'a>, error: SourceLocalizationError) -> Term<'a> {
    match error {
        SourceLocalizationError::InvalidInput { field, reason } => (
            atoms::invalid_input(),
            field.to_string(),
            reason.to_string(),
        )
            .encode(env),
        SourceLocalizationError::TooFewSensors { sensors, needed } => {
            (atoms::too_few_sensors(), sensors, needed).encode(env)
        }
        SourceLocalizationError::InitializerSingular => atoms::initializer_singular().encode(env),
        SourceLocalizationError::Geometry(error) => {
            (atoms::geometry(), dop_error_reason(env, error)).encode(env)
        }
        SourceLocalizationError::Solver(error) => (atoms::solver(), error.to_string()).encode(env),
        SourceLocalizationError::DidNotConverge { status } => {
            (atoms::did_not_converge(), status).encode(env)
        }
    }
}

fn dop_error_reason<'a>(env: Env<'a>, error: DopError) -> Term<'a> {
    match error {
        DopError::InvalidInput { field, reason } => (
            atoms::invalid_input(),
            field.to_string(),
            reason.to_string(),
        )
            .encode(env),
        DopError::TooFewSatellites => atoms::too_few_satellites().encode(env),
        DopError::Singular => atoms::singular().encode(env),
    }
}

fn invalid_input(field: &'static str, reason: &'static str) -> SourceLocalizationError {
    SourceLocalizationError::InvalidInput { field, reason }
}
