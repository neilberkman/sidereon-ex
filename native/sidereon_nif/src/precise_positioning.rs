//! Rustler boundary for static multi-epoch PPP float positioning.
//!
//! The solver and range-correction algebra live in
//! `sidereon_core::precise_positioning`; this module decodes Sidereon'
//! normalized epoch/option terms and encodes the unchanged public solution
//! fields.

use crate::sp3::Sp3Resource;
use rustler::{Encoder, Env, Error, NifResult, ResourceArc, Term};
use sidereon_core::observables::j2000_seconds_from_split;
use sidereon_core::positioning::SurfaceMet;
use sidereon_core::ppp_corrections as ppp;
use sidereon_core::precise_positioning as core;
use sidereon_core::precise_positioning::auto_init::{
    solve_ppp_auto_init_fixed, solve_ppp_auto_init_fixed_with_strategy, solve_ppp_auto_init_float,
    solve_ppp_auto_init_float_with_strategy, PppAutoInitError, PppAutoInitOptions,
    PppAutoInitStrategy, PppInitialGuess,
};
use sidereon_core::{GnssSatelliteId, GnssSystem};
use std::collections::BTreeMap;

type Vec3 = (f64, f64, f64);
type DateTuple = (i32, i32, i32);
type TimeTuple = (i32, i32, i32, i32);
type DateTimeTuple = (DateTuple, TimeTuple);
// (code1, code2, phase1, phase2) signal codes, each `"1C"` or `"C1C"`.
type ObservationSignalsTerm = (String, String, String, String);
type ObservationTerm = (
    String,
    String,
    f64,
    f64,
    f64,
    f64,
    Option<ObservationSignalsTerm>,
);
type EpochTerm = (DateTimeTuple, f64, f64, Vec<ObservationTerm>);
type InitialStateTerm = (
    Vec3,
    Vec<f64>,
    Vec<(String, f64)>,
    Option<f64>,
    Option<(f64, f64)>,
    Vec<(String, f64)>,
);
type CovarianceMatrixTerm = (Vec<Vec<f64>>, Vec<Vec<f64>>);
type OptionalMatrixTerm = Option<Vec<Vec<f64>>>;
type TemporalCorrelationTerm = (f64, f64, Option<f64>, u64, f64, f64, u64);
// (position_covariance, formal_position_covariance, posterior_variance_factor,
//  position_covariance_scale_factor, temporal_position_covariance,
//  temporal_position_covariance_scale_factor, temporal_correlation,
//  tropo_gradient_covariance_m2, formal_tropo_gradient_covariance_m2).
// Position covariances are (ecef_m2, enu_m2) 3x3 row lists; gradient
// covariances are optional north/east 2x2 row lists.
type FloatCovarianceTerm = (
    CovarianceMatrixTerm,
    CovarianceMatrixTerm,
    (f64, f64, bool),
    CovarianceMatrixTerm,
    (f64, TemporalCorrelationTerm),
    OptionalMatrixTerm,
    OptionalMatrixTerm,
);
type FloatStateExtrasTerm = (
    Vec<(String, f64)>,
    Vec<(String, f64)>,
    Option<f64>,
    Option<(f64, f64)>,
);
// (epoch_index, satellite_id, ambiguity_id, code_m, phase_m, code_weight,
//  phase_weight).
type ResidualTerm = (u64, String, String, f64, f64, (f64, f64));
// (max_iterations, position_tolerance_m, clock_tolerance_m,
//  ambiguity_tolerance_m, ztd_tolerance_m).
type FloatSolveOptionsTerm = (u64, f64, f64, f64, f64);

#[derive(Debug, Clone, rustler::NifMap)]
struct SsrCorrectionSizeFields {
    orbit_m: f64,
    clock_m: f64,
}
use crate::ssr_bias_exclusion::{
    decode_ssr_bias_exclusions, encode_ssr_bias_exclusions, SsrBiasExclusionTerm,
};
// (epoch_index, satellite_id, ambiguity_id, reason).
type UnplacedObservationTerm<'a> = (u64, String, String, Term<'a>);
// (ssr_bias_exclusions, unplaced_observations, residual_screen,
//  solve_options, residual_screen_removals, solved_epoch_indices).
type FloatProvenanceTerm<'a> = (
    Vec<SsrBiasExclusionTerm>,
    Vec<UnplacedObservationTerm<'a>>,
    bool,
    FloatSolveOptionsTerm,
    Vec<(u64, String)>,
    Vec<u64>,
);
type FloatPayloadTerm<'a> = (
    Vec3,
    Vec<f64>,
    FloatStateExtrasTerm,
    Vec<ResidualTerm>,
    Vec<String>,
    (u64, bool, Term<'a>, f64, f64, f64, FloatCovarianceTerm),
    FloatProvenanceTerm<'a>,
);
type WeightsTerm = (f64, f64, bool);
type SolveOptionsTerm = (u64, f64, f64, f64, f64, Option<f64>, bool);
// (enabled, estimate_ztd, estimate_tropo_gradients, pressure_hpa,
//  temperature_k, relative_humidity, vmf1_site_samples | nil). The trailing
//  element selects the tropospheric mapping: `nil` is Niell (the default),
//  `Some([{mjd, ah, aw}, ...])` is VMF1.
type TropoTerm = (
    bool,
    bool,
    bool,
    f64,
    f64,
    f64,
    Option<Vec<(f64, f64, f64)>>,
);
type FixedAmbiguityTerm = (Vec<(String, f64)>, Vec<(String, f64)>, f64);
type ReceiverFrequencyTerm = (String, Vec3, Vec<(Option<f64>, f64, f64)>);
type ReceiverAntennaTerm = (String, f64, String, f64, Vec<ReceiverFrequencyTerm>);
type SatelliteClockTerm = Vec<(String, Vec<(f64, f64)>)>;
type SatelliteFrequencyTerm = (String, Vec3, Vec<(f64, f64)>);
type SatelliteAntennaTerm = (
    String,
    Option<ValidityTerm>,
    Option<ValidityTerm>,
    Vec<SatelliteFrequencyTerm>,
);
type SatelliteAntennaOptionsTerm = (String, f64, String, f64, Vec<SatelliteAntennaTerm>);
// Displacement-tide extras (pole tide + ocean loading) grouped into one trailing
// element so the corrections term stays within rustler's seven-element
// tuple-decoder ceiling: {pole_tide | nil, ocean_loading | nil}. The element
// shapes are the shared aliases owned by the ppp_corrections module.
use crate::ppp_corrections::{OceanLoadingTerm, PoleTideTerm};
type TideExtrasTerm = (Option<PoleTideTerm>, Option<OceanLoadingTerm>);
type CorrectionsTerm = (
    bool,
    Option<SatelliteClockTerm>,
    Option<ReceiverAntennaTerm>,
    bool,
    bool,
    Option<SatelliteAntennaOptionsTerm>,
    TideExtrasTerm,
);

mod atoms {
    rustler::atoms! {
        ok,
        error,
        nil,
        no_ephemeris,
        singular_geometry,
        missing_ambiguity,
        missing_correction,
        missing_satellite_clock,
        missing_wavelength,
        missing_offset,
        fixed,
        not_fixed,
        infinity,
        no_integer_candidates,
        too_many_integer_candidates,
        invalid_dimensions,
        non_finite_input,
        search_limit_exceeded,
        state_tolerance,
        max_iterations,
        invalid_option,
        invalid_clock_count,
        invalid_solve_option,
        invalid_input,
        insufficient_observations_after_elevation_cutoff,
        insufficient_observations_after_ssr_bias_exclusion,
        no_epochs,
        code_seed_failed,
        code_not_positive,
        ssr_correction_exceeds_limit,
        unrecognized_reason,
        too_few_observations,
        singular_velocity_geometry,
        clean,
        untested,
        numerical_protection_level,
        unsupported_noncentrality,
        unsupported_dof,
        restored,
        cannot_exclude,
        integrity_not_restored,
        passed,
        fault_detected,
        not_enough_redundancy,
        raim,
        invalid_config,
        invalid_residual,
        invalid_geometry,
        dop,
        singular_raim_geometry
    }
}

// (initial_guess {position, clock_m} | nil, spp_initial_guess [x, y, z, b],
//  spp_troposphere, spp_met {pressure_hpa, temperature_k, relative_humidity}).
type PppAutoInitTerm = (
    Option<(Vec3, f64)>,
    (f64, f64, f64, f64),
    bool,
    (f64, f64, f64),
);
type VelocityObservationTerm = (String, Vec3, Vec3, f64, f64, f64);
type VelocityRobustConfigTerm = (f64, f64, u64, f64);
type VelocityConfigTerm = (u64, Option<VelocityRobustConfigTerm>);
type ReceiverVelocityStateTerm = (Vec3, Vec3, f64);
type KinematicStateTerm = (Vec3, f64, f64, Vec<(String, f64)>);
type KinematicNoiseTerm = (String, f64, f64, f64, f64);
type KinematicMotionTerm = (String, Vec3);
type KinematicBaseConfigTerm = (
    KinematicStateTerm,
    Vec<Vec<f64>>,
    KinematicMotionTerm,
    KinematicNoiseTerm,
    f64,
    WeightsTerm,
);

#[rustler::nif]
pub fn precise_positioning_vmf_site_max_samples() -> u64 {
    core::VMF_SITE_MAX_SAMPLES as u64
}

#[rustler::nif]
pub fn precise_positioning_vmf_site_single_sample_clamp_days() -> f64 {
    core::VMF_SITE_SINGLE_SAMPLE_CLAMP_DAYS
}

#[rustler::nif]
pub fn precise_positioning_ppp_auto_init_strategy_default() -> String {
    match PppAutoInitStrategy::default() {
        PppAutoInitStrategy::Reference => "reference",
        PppAutoInitStrategy::Canonical => "canonical",
    }
    .to_string()
}

#[rustler::nif]
pub fn precise_positioning_velocity_config_default() -> VelocityConfigTerm {
    let config = core::VelocityConfig::default();
    (
        config.minimum_observations as u64,
        config.robust.map(encode_velocity_robust_config),
    )
}

#[rustler::nif]
pub fn precise_positioning_velocity_robust_config_default() -> VelocityRobustConfigTerm {
    encode_velocity_robust_config(core::VelocityRobustConfig::default())
}

fn encode_velocity_robust_config(config: core::VelocityRobustConfig) -> VelocityRobustConfigTerm {
    (
        config.huber_k,
        config.scale_floor_m_s,
        config.max_outer as u64,
        config.outer_tol_m_s,
    )
}

#[rustler::nif]
pub fn precise_positioning_stationary_velocity_state(
    position_m: Vec3,
) -> ReceiverVelocityStateTerm {
    let state = core::ReceiverVelocityState::stationary_at(vec3_to_array(position_m));
    (
        array_to_vec3(state.position_m),
        array_to_vec3(state.velocity_m_s),
        state.clock_drift_m_s,
    )
}

#[rustler::nif]
pub fn precise_positioning_predict_range_rate_m_s<'a>(
    env: Env<'a>,
    observation: VelocityObservationTerm,
    receiver: ReceiverVelocityStateTerm,
) -> Term<'a> {
    let observation = match decode_velocity_observation(observation) {
        Ok(observation) => observation,
        Err(field) => return (atoms::error(), (atoms::invalid_input(), field)).encode(env),
    };
    let receiver = core::ReceiverVelocityState {
        position_m: vec3_to_array(receiver.0),
        velocity_m_s: vec3_to_array(receiver.1),
        clock_drift_m_s: receiver.2,
    };
    match core::predict_range_rate_m_s(&observation, receiver) {
        Some(prediction) => (
            atoms::ok(),
            (
                array_to_vec3(prediction.los_unit),
                prediction.range_rate_m_s,
            ),
        )
            .encode(env),
        None => (atoms::error(), (atoms::invalid_input(), "geometry")).encode(env),
    }
}

/// Solve the precise-positioning leaf velocity model from precomputed states.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn precise_positioning_solve_velocity_least_squares<'a>(
    env: Env<'a>,
    observations: Vec<VelocityObservationTerm>,
    receiver_position_m: Vec3,
    config: VelocityConfigTerm,
) -> Term<'a> {
    let observations = match observations
        .into_iter()
        .map(decode_velocity_observation)
        .collect::<Result<Vec<_>, _>>()
    {
        Ok(observations) => observations,
        Err(field) => return (atoms::error(), (atoms::invalid_input(), field)).encode(env),
    };
    let robust = config
        .1
        .map(|(huber_k, scale_floor_m_s, max_outer, outer_tol_m_s)| {
            let mut robust = core::VelocityRobustConfig::default();
            robust.huber_k = huber_k;
            robust.scale_floor_m_s = scale_floor_m_s;
            robust.max_outer = max_outer as usize;
            robust.outer_tol_m_s = outer_tol_m_s;
            robust
        });
    let mut config_value = core::VelocityConfig::default();
    config_value.minimum_observations = config.0 as usize;
    config_value.robust = robust;
    match core::velocity::solve_velocity_least_squares(
        &observations,
        vec3_to_array(receiver_position_m),
        config_value,
    ) {
        Ok(solution) => (
            atoms::ok(),
            (
                array_to_vec3(solution.velocity_m_s),
                solution.clock_drift_m_s,
                solution.residual_rms_m_s,
                solution
                    .used_sats
                    .into_iter()
                    .map(|sat| sat.to_string())
                    .collect::<Vec<_>>(),
                solution
                    .downweighted_sats
                    .into_iter()
                    .map(|sat| sat.to_string())
                    .collect::<Vec<_>>(),
                solution.robust_iterations as u64,
                solution.robust_scale_m_s,
            ),
        )
            .encode(env),
        Err(error @ core::VelocitySolveError::TooFewObservations { required, actual }) => (
            atoms::error(),
            (
                atoms::too_few_observations(),
                required as u64,
                actual as u64,
                error.to_string(),
            ),
        )
            .encode(env),
        Err(error @ core::VelocitySolveError::InvalidInput { field, reason }) => (
            atoms::error(),
            (atoms::invalid_input(), field, reason, error.to_string()),
        )
            .encode(env),
        Err(error @ core::VelocitySolveError::SingularGeometry) => (
            atoms::error(),
            (atoms::singular_velocity_geometry(), error.to_string()),
        )
            .encode(env),
    }
}

fn decode_velocity_observation(
    term: VelocityObservationTerm,
) -> Result<core::VelocityObservation, &'static str> {
    let (sat, position, velocity, measured_range_rate_m_s, sigma_m_s, clock_drift) = term;
    Ok(core::VelocityObservation {
        sat: sat_from_token(&sat).map_err(|_| "satellite_id")?,
        satellite_position_m: vec3_to_array(position),
        satellite_velocity_m_s: vec3_to_array(velocity),
        measured_range_rate_m_s,
        sigma_m_s,
        satellite_clock_drift_m_s: clock_drift,
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
pub fn precise_positioning_solve_float<'a>(
    env: Env<'a>,
    handle: ResourceArc<Sp3Resource>,
    epoch: EpochTerm,
    initial: InitialStateTerm,
    weights: WeightsTerm,
    solve_options: SolveOptionsTerm,
    tropo: TropoTerm,
    corrections: CorrectionsTerm,
) -> NifResult<Term<'a>> {
    let epoch = decode_epoch(epoch)?;
    let initial = decode_initial(initial);
    let corrections = decode_corrections(corrections)?;
    let result = core::solve_float_epoch(
        &handle.sp3,
        epoch,
        initial,
        core::FloatSolveConfig::new(
            decode_weights(weights),
            decode_tropo(&tropo)?,
            core::RangeCorrections {
                receiver_antenna: corrections.receiver_antenna,
                sat_clock_relativity: corrections.sat_clock_relativity,
                satellite_clock: corrections.satellite_clock,
                ppp: core::PppCorrectionLookup::default(),
            },
            decode_solve_options(solve_options),
            solve_options.5,
            false,
            solve_options.6,
        ),
    );
    Ok(encode_result(env, result))
}

fn encode_raim_status(status: core::RaimStatus) -> rustler::Atom {
    match status {
        core::RaimStatus::Passed => atoms::passed(),
        core::RaimStatus::FaultDetected => atoms::fault_detected(),
        core::RaimStatus::NotEnoughRedundancy => atoms::not_enough_redundancy(),
    }
}

fn encode_fde_status(status: core::RaimFdeStatus) -> rustler::Atom {
    match status {
        core::RaimFdeStatus::Untested => atoms::untested(),
        core::RaimFdeStatus::Clean => atoms::clean(),
        core::RaimFdeStatus::Restored => atoms::restored(),
        core::RaimFdeStatus::CannotExclude => atoms::cannot_exclude(),
        core::RaimFdeStatus::IntegrityNotRestored => atoms::integrity_not_restored(),
    }
}

fn encode_raim_fde_result<'a>(
    env: Env<'a>,
    result: Result<core::RaimFdeResult, core::RaimFdeError>,
) -> Term<'a> {
    match result {
        Ok(value) => {
            let statistics = value
                .raim
                .satellite_statistics
                .into_iter()
                .map(|s| {
                    (
                        s.satellite_id,
                        s.code,
                        s.phase,
                        s.statistic,
                        s.code_testable,
                        s.phase_testable,
                    )
                })
                .collect::<Vec<_>>();
            let raim = (
                encode_raim_status(value.raim.status),
                value.raim.detected,
                value.raim.test_statistic,
                value.raim.threshold,
                value.raim.redundancy as i64,
                statistics,
                (
                    value.raim.most_likely_fault,
                    value.raim.hpl_m,
                    value.raim.vpl_m,
                ),
            );
            (
                atoms::ok(),
                (
                    encode_float_payload(env, value.solution),
                    raim,
                    value.excluded_sats,
                    encode_fde_status(value.status),
                ),
            )
                .encode(env)
        }
        Err(core::RaimFdeError::Solve(error)) => encode_float_error_detailed(env, error),
        Err(core::RaimFdeError::Raim(error)) => encode_raim_error(env, error),
    }
}

fn encode_raim_error<'a>(env: Env<'a>, error: core::RaimError) -> Term<'a> {
    let message = error.to_string();
    let detail = match error {
        core::RaimError::InvalidConfig { field, reason } => {
            (atoms::invalid_config(), field, Some(reason), message).encode(env)
        }
        core::RaimError::InvalidResidual { field } => (
            atoms::invalid_residual(),
            field,
            Option::<&str>::None,
            message,
        )
            .encode(env),
        core::RaimError::InvalidGeometry { field, reason } => {
            (atoms::invalid_geometry(), field, Some(reason), message).encode(env)
        }
        core::RaimError::Dop(_) => (atoms::dop(), "dop", Option::<&str>::None, message).encode(env),
        core::RaimError::NumericalProtectionLevel => (
            atoms::numerical_protection_level(),
            "",
            None::<&str>,
            message,
        )
            .encode(env),
        core::RaimError::UnsupportedNoncentrality => (
            atoms::unsupported_noncentrality(),
            "",
            None::<&str>,
            message,
        )
            .encode(env),
        core::RaimError::UnsupportedDof { dof, max } => (
            atoms::unsupported_dof(),
            "",
            None::<&str>,
            message,
            (dof as u64, max as u64),
        )
            .encode(env),
        core::RaimError::SingularGeometry => (
            atoms::singular_raim_geometry(),
            "geometry",
            Option::<&str>::None,
            message,
        )
            .encode(env),
    };
    (atoms::error(), (atoms::raim(), detail)).encode(env)
}

#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
pub fn precise_positioning_fde_float_epoch<'a>(
    env: Env<'a>,
    handle: ResourceArc<Sp3Resource>,
    epoch: EpochTerm,
    initial: InitialStateTerm,
    weights: WeightsTerm,
    solve_options: SolveOptionsTerm,
    tropo: TropoTerm,
    corrections: CorrectionsTerm,
    raim: (f64, f64, f64, Option<f64>),
) -> NifResult<Term<'a>> {
    let epoch = decode_epoch(epoch)?;
    let initial = decode_initial(initial);
    let corrections = decode_corrections(corrections)?;
    let solve = core::FloatSolveConfig::new(
        decode_weights(weights),
        decode_tropo(&tropo)?,
        core::RangeCorrections {
            receiver_antenna: corrections.receiver_antenna,
            sat_clock_relativity: corrections.sat_clock_relativity,
            satellite_clock: corrections.satellite_clock,
            ppp: core::PppCorrectionLookup::default(),
        },
        decode_solve_options(solve_options),
        solve_options.5,
        false,
        solve_options.6,
    );
    let mut rc = core::RaimConfig::default();
    rc.false_alarm_probability = raim.0;
    rc.missed_detection_probability = raim.1;
    rc.measurement_sigma_m = raim.2;
    rc.chi_square_threshold = raim.3;
    Ok(encode_raim_fde_result(
        env,
        core::raim::fde_float_epoch(&handle.sp3, epoch, initial, solve, rc),
    ))
}

#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
pub fn precise_positioning_solve_float_epoch_with_raim<'a>(
    env: Env<'a>,
    handle: ResourceArc<Sp3Resource>,
    epoch: EpochTerm,
    initial: InitialStateTerm,
    weights: WeightsTerm,
    solve_options: SolveOptionsTerm,
    tropo: TropoTerm,
    corrections: CorrectionsTerm,
    raim: (f64, f64, f64, Option<f64>),
) -> NifResult<Term<'a>> {
    let epoch = decode_epoch(epoch)?;
    let initial = decode_initial(initial);
    let corrections = decode_corrections(corrections)?;
    let solve = core::FloatSolveConfig::new(
        decode_weights(weights),
        decode_tropo(&tropo)?,
        core::RangeCorrections {
            receiver_antenna: corrections.receiver_antenna,
            sat_clock_relativity: corrections.sat_clock_relativity,
            satellite_clock: corrections.satellite_clock,
            ppp: core::PppCorrectionLookup::default(),
        },
        decode_solve_options(solve_options),
        solve_options.5,
        false,
        solve_options.6,
    );
    let mut rc = core::RaimConfig::default();
    rc.false_alarm_probability = raim.0;
    rc.missed_detection_probability = raim.1;
    rc.measurement_sigma_m = raim.2;
    rc.chi_square_threshold = raim.3;
    Ok(encode_raim_fde_result(
        env,
        core::solve_float_epoch_with_raim(&handle.sp3, epoch, initial, solve, rc),
    ))
}

fn decode_kinematic_state(term: KinematicStateTerm) -> core::KinematicState {
    core::KinematicState {
        position_m: vec3_to_array(term.0),
        clock_m: term.1,
        ztd_residual_m: term.2,
        ambiguities_m: term.3.into_iter().collect(),
    }
}

fn encode_kinematic_state(state: core::KinematicState) -> KinematicStateTerm {
    (
        array_to_vec3(state.position_m),
        state.clock_m,
        state.ztd_residual_m,
        state.ambiguities_m.into_iter().collect(),
    )
}

fn decode_kinematic_config(
    term: KinematicBaseConfigTerm,
    tropo: core::TroposphereOptions,
    corrections: core::RangeCorrections,
) -> core::KinematicConfig {
    let mut config = core::KinematicConfig::default();
    config.initial_state = decode_kinematic_state(term.0);
    config.initial_covariance_m2 = term.1;
    config.motion = match term.2 .0.as_str() {
        "hold" => core::KinematicMotionModel::Hold,
        _ => core::KinematicMotionModel::ConstantVelocity {
            velocity_m_s: vec3_to_array(term.2 .1),
        },
    };
    config.process_noise = core::KinematicProcessNoise {
        position: match term.3 .0.as_str() {
            "random_walk" => core::KinematicPositionProcessNoise::RandomWalk {
                spectral_density_m2_s: term.3 .1,
            },
            _ => core::KinematicPositionProcessNoise::WhiteNoiseAcceleration {
                spectral_density_m2_s3: term.3 .1,
            },
        },
        clock_white_m2_s: term.3 .2,
        ztd_random_walk_m2_s: term.3 .3,
        ambiguity_hold_m2_s: term.3 .4,
    };
    config.new_ambiguity_variance_m2 = term.4;
    config.weights = decode_weights(term.5);
    config.tropo = tropo;
    config.corrections = corrections;
    config
}

fn encode_kinematic_error<'a>(env: Env<'a>, error: core::KinematicSolveError) -> Term<'a> {
    let message = error.to_string();
    let detail = match error {
        core::KinematicSolveError::NoEphemeris {
            satellite_id,
            reason,
        } => (
            "no_ephemeris",
            Some(satellite_id),
            None::<String>,
            Some(reason.to_string()),
            message,
        )
            .encode(env),
        core::KinematicSolveError::SingularGeometry => (
            "singular_geometry",
            None::<String>,
            None::<String>,
            None::<String>,
            message,
        )
            .encode(env),
        core::KinematicSolveError::InvalidSolveOption { field, reason } => (
            "invalid_solve_option",
            None::<String>,
            Some(field.to_string()),
            Some(reason.to_string()),
            message,
        )
            .encode(env),
        core::KinematicSolveError::InvalidInput { field, reason } => (
            "invalid_input",
            None::<String>,
            Some(field.to_string()),
            Some(reason.to_string()),
            message,
        )
            .encode(env),
        core::KinematicSolveError::MissingCorrection {
            satellite_id,
            correction,
        } => (
            "missing_correction",
            Some(satellite_id),
            None::<String>,
            Some(correction.to_string()),
            message,
        )
            .encode(env),
        core::KinematicSolveError::Ut1OutsideCoverage(reason) => (
            "ut1_outside_coverage",
            None::<String>,
            None::<String>,
            Some(reason.to_string()),
            message,
        )
            .encode(env),
    };
    (atoms::error(), detail).encode(env)
}

fn encode_kinematic_summary<'a>(env: Env<'a>, value: core::KinematicUpdateSummary) -> Term<'a> {
    (
        value.innovation_rms_m,
        value.used_sats,
        encode_ssr_bias_exclusions(&value.ssr_bias_exclusions),
        encode_unplaced_observations(env, &value.unplaced_observations),
    )
        .encode(env)
}

fn encode_kinematic_solution<'a>(env: Env<'a>, value: core::KinematicEpochSolution) -> Term<'a> {
    let status = match value.status {
        core::KinematicEpochStatus::Updated => "updated",
        core::KinematicEpochStatus::PredictedOnly => "predicted_only",
    };
    (
        encode_kinematic_state(core::KinematicState {
            position_m: value.position_m,
            clock_m: value.clock_m,
            ztd_residual_m: value.ztd_residual_m,
            ambiguities_m: value.ambiguities_m,
        }),
        matrix3_to_lists(value.position_covariance_m2),
        value.used_sats,
        value.innovation_rms_m,
        encode_ssr_bias_exclusions(&value.ssr_bias_exclusions),
        encode_unplaced_observations(env, &value.unplaced_observations),
        status,
    )
        .encode(env)
}

#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
pub fn precise_positioning_correct_kinematic_state<'a>(
    env: Env<'a>,
    handle: ResourceArc<Sp3Resource>,
    correction_epochs: Vec<EpochTerm>,
    epoch_index: u64,
    state: KinematicStateTerm,
    covariance: Vec<Vec<f64>>,
    base: KinematicBaseConfigTerm,
    tropo: TropoTerm,
    corrections: CorrectionsTerm,
) -> NifResult<Term<'a>> {
    let epochs = decode_epochs(correction_epochs)?;
    let Some(epoch) = epochs.get(epoch_index as usize).cloned() else {
        let error = core::KinematicSolveError::InvalidInput {
            field: "epoch_index",
            reason: "outside correction epochs",
        };
        return Ok(encode_kinematic_error(env, error));
    };
    let mut state = decode_kinematic_state(state);
    let mut covariance = covariance;
    let decoded = decode_corrections(corrections)?;
    let range = direct_range_corrections(&handle, &epochs, state.position_m, &decoded)?;
    let config = decode_kinematic_config(base, decode_tropo(&tropo)?, range);
    match core::correct_kinematic_state(
        &handle.sp3,
        epoch_index as usize,
        &epoch,
        &mut state,
        &mut covariance,
        &config,
    ) {
        Ok(summary) => Ok((
            atoms::ok(),
            (
                encode_kinematic_state(state),
                covariance,
                encode_kinematic_summary(env, summary),
            ),
        )
            .encode(env)),
        Err(error) => Ok(encode_kinematic_error(env, error)),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn precise_positioning_solve_kinematic_ppp<'a>(
    env: Env<'a>,
    handle: ResourceArc<Sp3Resource>,
    epochs: Vec<EpochTerm>,
    base: KinematicBaseConfigTerm,
    tropo: TropoTerm,
    corrections: CorrectionsTerm,
) -> NifResult<Term<'a>> {
    let epochs = decode_epochs(epochs)?;
    let initial_position = decode_kinematic_state(base.0.clone()).position_m;
    let decoded = decode_corrections(corrections)?;
    let range = direct_range_corrections(&handle, &epochs, initial_position, &decoded)?;
    let config = decode_kinematic_config(base, decode_tropo(&tropo)?, range);
    match core::solve_kinematic_ppp(&handle.sp3, &epochs, config) {
        Ok(values) => Ok((
            atoms::ok(),
            values
                .into_iter()
                .map(|value| encode_kinematic_solution(env, value))
                .collect::<Vec<_>>(),
        )
            .encode(env)),
        Err(error) => Ok(encode_kinematic_error(env, error)),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
pub fn precise_positioning_solve_ppp_float<'a>(
    env: Env<'a>,
    handle: ResourceArc<Sp3Resource>,
    epochs: Vec<EpochTerm>,
    initial: InitialStateTerm,
    weights: WeightsTerm,
    solve_options: SolveOptionsTerm,
    tropo: TropoTerm,
    corrections: CorrectionsTerm,
    residual_screen: bool,
) -> NifResult<Term<'a>> {
    let epochs = decode_epochs(epochs)?;
    let initial = decode_initial(initial);
    let corrections = decode_corrections(corrections)?;
    let config = core::FloatSolveConfig::new(
        decode_weights(weights),
        decode_tropo(&tropo)?,
        direct_range_corrections(&handle, &epochs, initial.position_m, &corrections)?,
        decode_solve_options(solve_options),
        solve_options.5,
        residual_screen,
        solve_options.6,
    );
    Ok(encode_result(
        env,
        core::solve_float_epochs(&handle.sp3, &epochs, initial, config),
    ))
}

#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
pub fn precise_positioning_solve_ppp_float_detailed<'a>(
    env: Env<'a>,
    handle: ResourceArc<Sp3Resource>,
    epochs: Vec<EpochTerm>,
    initial: InitialStateTerm,
    weights: WeightsTerm,
    solve_options: SolveOptionsTerm,
    tropo: TropoTerm,
    corrections: CorrectionsTerm,
    residual_screen: bool,
) -> NifResult<Term<'a>> {
    let epochs = decode_epochs(epochs)?;
    let initial = decode_initial(initial);
    let corrections = decode_corrections(corrections)?;
    let config = core::FloatSolveConfig::new(
        decode_weights(weights),
        decode_tropo(&tropo)?,
        direct_range_corrections(&handle, &epochs, initial.position_m, &corrections)?,
        decode_solve_options(solve_options),
        solve_options.5,
        residual_screen,
        solve_options.6,
    );
    Ok(encode_result_detailed(
        env,
        core::solve_float_epochs(&handle.sp3, &epochs, initial, config),
    ))
}

/// Decode a float-solution payload into the core solution, as the fixed solve
/// does, and encode it back, as the float solve does. Returns the payload, or
/// `{:error, reason}` for one the decoder refuses.
#[rustler::nif]
pub fn precise_positioning_float_solution_round_trip<'a>(
    env: Env<'a>,
    float_solution: FloatPayloadTerm<'a>,
) -> NifResult<Term<'a>> {
    Ok(encode_float_payload(
        env,
        decode_float_payload(float_solution)?,
    ))
}

#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
pub fn precise_positioning_solve_ppp_fixed<'a>(
    env: Env<'a>,
    handle: ResourceArc<Sp3Resource>,
    epochs: Vec<EpochTerm>,
    float_solution: FloatPayloadTerm<'a>,
    weights: WeightsTerm,
    solve_options: SolveOptionsTerm,
    tropo: TropoTerm,
    corrections: CorrectionsTerm,
    ambiguity: FixedAmbiguityTerm,
) -> NifResult<Term<'a>> {
    let epochs = decode_epochs(epochs)?;
    let float_solution = decode_float_payload(float_solution)?;
    let corrections = decode_corrections(corrections)?;
    let config = core::FixedSolveConfig::new(
        decode_weights(weights),
        decode_tropo(&tropo)?,
        direct_range_corrections(&handle, &epochs, float_solution.position_m, &corrections)?,
        decode_solve_options(solve_options),
        solve_options.5,
        decode_fixed_ambiguity(ambiguity),
        solve_options.6,
    );
    Ok(encode_fixed_result(
        env,
        core::solve_fixed_from_float(&handle.sp3, &epochs, float_solution, config),
    ))
}

#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
pub fn precise_positioning_solve_ppp_fixed_detailed<'a>(
    env: Env<'a>,
    handle: ResourceArc<Sp3Resource>,
    epochs: Vec<EpochTerm>,
    float_solution: FloatPayloadTerm<'a>,
    weights: WeightsTerm,
    solve_options: SolveOptionsTerm,
    tropo: TropoTerm,
    corrections: CorrectionsTerm,
    ambiguity: FixedAmbiguityTerm,
) -> NifResult<Term<'a>> {
    let epochs = decode_epochs(epochs)?;
    let float_solution = decode_float_payload(float_solution)?;
    let corrections = decode_corrections(corrections)?;
    let config = core::FixedSolveConfig::new(
        decode_weights(weights),
        decode_tropo(&tropo)?,
        direct_range_corrections(&handle, &epochs, float_solution.position_m, &corrections)?,
        decode_solve_options(solve_options),
        solve_options.5,
        decode_fixed_ambiguity(ambiguity),
        solve_options.6,
    );
    Ok(encode_fixed_result_detailed(
        env,
        core::solve_fixed_from_float(&handle.sp3, &epochs, float_solution, config),
    ))
}

/// SPP-seeded auto-initialized static float PPP arc from raw epochs.
///
/// Pure glue over `sidereon_core::precise_positioning::auto_init::solve_ppp_auto_init_float`:
/// the driver computes the SPP code seed, the mean static position, the per-epoch
/// clocks, and the phase-minus-code float ambiguities internally, then runs the
/// existing static float solve. The binding only decodes the epochs, the
/// auto-init policy, and the float config (reusing the shared decoders), and
/// re-shapes the unchanged float solution payload.
#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
pub fn precise_positioning_solve_ppp_auto_init_float<'a>(
    env: Env<'a>,
    handle: ResourceArc<Sp3Resource>,
    epochs: Vec<EpochTerm>,
    auto_init: PppAutoInitTerm,
    weights: WeightsTerm,
    solve_options: SolveOptionsTerm,
    tropo: TropoTerm,
    corrections: CorrectionsTerm,
    residual_screen: bool,
) -> NifResult<Term<'a>> {
    let epochs = decode_epochs(epochs)?;
    let corrections = decode_corrections(corrections)?;
    let options = decode_auto_init(auto_init);
    let config = core::FloatSolveConfig::new(
        decode_weights(weights),
        decode_tropo(&tropo)?,
        auto_init_range_corrections(&handle, &epochs, &options, &corrections)?,
        decode_solve_options(solve_options),
        solve_options.5,
        residual_screen,
        solve_options.6,
    );
    let result = solve_ppp_auto_init_float(&handle.sp3, &epochs, options, config);
    Ok(match result {
        Ok(solution) => encode_result(env, Ok(solution)),
        Err(error) => encode_auto_init_float_error(env, error),
    })
}

/// SPP-seeded auto-initialized static integer-fixed PPP arc from raw epochs.
///
/// Pure glue over `sidereon_core::precise_positioning::auto_init::solve_ppp_auto_init_fixed`:
/// the driver auto-inits the seed, solves the float arc, then runs the LAMBDA
/// integer fix and the ambiguity-conditioned re-solve. The binding decodes the
/// epochs, the auto-init policy, and the float and fixed configs, and re-shapes
/// the unchanged fixed solution payload.
#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
pub fn precise_positioning_solve_ppp_auto_init_fixed<'a>(
    env: Env<'a>,
    handle: ResourceArc<Sp3Resource>,
    epochs: Vec<EpochTerm>,
    auto_init: PppAutoInitTerm,
    weights: WeightsTerm,
    solve_options: SolveOptionsTerm,
    tropo: TropoTerm,
    corrections: CorrectionsTerm,
    residual_screen: bool,
    ambiguity: FixedAmbiguityTerm,
) -> NifResult<Term<'a>> {
    let epochs = decode_epochs(epochs)?;
    let corrections = decode_corrections(corrections)?;
    let options = decode_auto_init(auto_init);
    let float_config = core::FloatSolveConfig::new(
        decode_weights(weights),
        decode_tropo(&tropo)?,
        auto_init_range_corrections(&handle, &epochs, &options, &corrections)?,
        decode_solve_options(solve_options),
        solve_options.5,
        residual_screen,
        solve_options.6,
    );
    let fixed_config = core::FixedSolveConfig::new(
        decode_weights(weights),
        decode_tropo(&tropo)?,
        auto_init_range_corrections(&handle, &epochs, &options, &corrections)?,
        decode_solve_options(solve_options),
        solve_options.5,
        decode_fixed_ambiguity(ambiguity),
        solve_options.6,
    );
    let result =
        solve_ppp_auto_init_fixed(&handle.sp3, &epochs, options, float_config, fixed_config);
    Ok(match result {
        Ok(solution) => encode_fixed_result(env, Ok(solution)),
        Err(PppAutoInitError::Float(error)) => {
            encode_fixed_result(env, Err(core::FixedSolveError::Float(error)))
        }
        Err(PppAutoInitError::Fixed(error)) => encode_fixed_result(env, Err(error)),
        Err(error) => encode_auto_init_seed_error(env, error),
    })
}

/// Auto-initialized static float PPP with an explicit core strategy.
#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
pub fn precise_positioning_solve_ppp_auto_init_float_with_strategy<'a>(
    env: Env<'a>,
    handle: ResourceArc<Sp3Resource>,
    epochs: Vec<EpochTerm>,
    auto_init: PppAutoInitTerm,
    weights: WeightsTerm,
    solve_options: SolveOptionsTerm,
    tropo: TropoTerm,
    corrections: CorrectionsTerm,
    residual_screen: bool,
    strategy: String,
) -> NifResult<Term<'a>> {
    let epochs = decode_epochs(epochs)?;
    let corrections = decode_corrections(corrections)?;
    let options = decode_auto_init(auto_init);
    let strategy = decode_auto_init_strategy(&strategy)?;
    let config = core::FloatSolveConfig::new(
        decode_weights(weights),
        decode_tropo(&tropo)?,
        auto_init_range_corrections(&handle, &epochs, &options, &corrections)?,
        decode_solve_options(solve_options),
        solve_options.5,
        residual_screen,
        solve_options.6,
    );
    let result =
        solve_ppp_auto_init_float_with_strategy(&handle.sp3, &epochs, options, config, strategy);
    Ok(match result {
        Ok(solution) => encode_result(env, Ok(solution)),
        Err(error) => encode_auto_init_float_error(env, error),
    })
}

/// Auto-initialized static integer-fixed PPP with an explicit core strategy.
#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
pub fn precise_positioning_solve_ppp_auto_init_fixed_with_strategy<'a>(
    env: Env<'a>,
    handle: ResourceArc<Sp3Resource>,
    epochs: Vec<EpochTerm>,
    auto_init: PppAutoInitTerm,
    weights: WeightsTerm,
    solve_options: SolveOptionsTerm,
    tropo: TropoTerm,
    corrections: CorrectionsTerm,
    residual_screen: bool,
    ambiguity: FixedAmbiguityTerm,
    strategy: String,
) -> NifResult<Term<'a>> {
    let epochs = decode_epochs(epochs)?;
    let corrections = decode_corrections(corrections)?;
    let options = decode_auto_init(auto_init);
    let strategy = decode_auto_init_strategy(&strategy)?;
    let float_config = core::FloatSolveConfig::new(
        decode_weights(weights),
        decode_tropo(&tropo)?,
        auto_init_range_corrections(&handle, &epochs, &options, &corrections)?,
        decode_solve_options(solve_options),
        solve_options.5,
        residual_screen,
        solve_options.6,
    );
    let fixed_config = core::FixedSolveConfig::new(
        decode_weights(weights),
        decode_tropo(&tropo)?,
        auto_init_range_corrections(&handle, &epochs, &options, &corrections)?,
        decode_solve_options(solve_options),
        solve_options.5,
        decode_fixed_ambiguity(ambiguity),
        solve_options.6,
    );
    let result = solve_ppp_auto_init_fixed_with_strategy(
        &handle.sp3,
        &epochs,
        options,
        float_config,
        fixed_config,
        strategy,
    );
    Ok(match result {
        Ok(solution) => encode_fixed_result(env, Ok(solution)),
        Err(PppAutoInitError::Float(error)) => {
            encode_fixed_result(env, Err(core::FixedSolveError::Float(error)))
        }
        Err(PppAutoInitError::Fixed(error)) => encode_fixed_result(env, Err(error)),
        Err(error) => encode_auto_init_seed_error(env, error),
    })
}

fn decode_auto_init_strategy(strategy: &str) -> NifResult<PppAutoInitStrategy> {
    match strategy {
        "reference" => Ok(PppAutoInitStrategy::Reference),
        "canonical" => Ok(PppAutoInitStrategy::Canonical),
        _ => Err(Error::Term(Box::new("invalid PPP auto-init strategy"))),
    }
}

/// Decode the auto-init policy term into [`PppAutoInitOptions`].
fn decode_auto_init(term: PppAutoInitTerm) -> PppAutoInitOptions {
    let (initial_guess, spp_initial_guess, spp_troposphere, met) = term;
    let mut options = PppAutoInitOptions::default();
    options.initial_guess = initial_guess.map(|(position, clock_m)| PppInitialGuess {
        position_m: vec3_to_array(position),
        clock_m,
    });
    options.spp_initial_guess = [
        spp_initial_guess.0,
        spp_initial_guess.1,
        spp_initial_guess.2,
        spp_initial_guess.3,
    ];
    options.spp_troposphere = spp_troposphere;
    options.spp_met = SurfaceMet {
        pressure_hpa: met.0,
        temperature_k: met.1,
        relative_humidity: met.2,
    };
    options
}

/// Build the PPP range corrections for an auto-init solve.
///
/// The position-dependent PPP correction lookup is linearized at the auto-init
/// reference position: the explicit guess when one is supplied, otherwise the
/// SPP cold-start position. With the PPP corrections disabled (the common case)
/// the lookup is empty and position-independent.
fn auto_init_range_corrections(
    handle: &ResourceArc<Sp3Resource>,
    epochs: &[core::FloatEpoch],
    options: &PppAutoInitOptions,
    corrections: &DecodedCorrections,
) -> NifResult<core::RangeCorrections> {
    let reference_position = match options.initial_guess {
        Some(guess) => guess.position_m,
        None => [
            options.spp_initial_guess[0],
            options.spp_initial_guess[1],
            options.spp_initial_guess[2],
        ],
    };
    let ppp = core::build_ppp_lookup(
        &handle.sp3,
        epochs,
        reference_position,
        &corrections.ppp_options,
    )
    .map_err(crate::errors::invalid_input)?;
    Ok(core::RangeCorrections {
        receiver_antenna: corrections.receiver_antenna.clone(),
        sat_clock_relativity: corrections.sat_clock_relativity,
        satellite_clock: corrections.satellite_clock.clone(),
        ppp,
    })
}

fn direct_range_corrections(
    handle: &ResourceArc<Sp3Resource>,
    epochs: &[core::FloatEpoch],
    reference_position: [f64; 3],
    corrections: &DecodedCorrections,
) -> NifResult<core::RangeCorrections> {
    let ppp = core::build_ppp_lookup(
        &handle.sp3,
        epochs,
        reference_position,
        &corrections.ppp_options,
    )
    .map_err(crate::errors::invalid_input)?;
    Ok(core::RangeCorrections {
        receiver_antenna: corrections.receiver_antenna.clone(),
        sat_clock_relativity: corrections.sat_clock_relativity,
        satellite_clock: corrections.satellite_clock.clone(),
        ppp,
    })
}

/// Encode an auto-init float-driver error. The driver only surfaces the empty
/// arc, an SPP seed failure, or a float solve failure on this path.
fn encode_auto_init_float_error<'a>(env: Env<'a>, error: PppAutoInitError) -> Term<'a> {
    match error {
        PppAutoInitError::Float(error) => encode_result(env, Err(error)),
        other => encode_auto_init_seed_error(env, other),
    }
}

/// Encode the auto-init seed-stage errors (empty arc or SPP code-seed failure).
fn encode_auto_init_seed_error<'a>(env: Env<'a>, error: PppAutoInitError) -> Term<'a> {
    match error {
        PppAutoInitError::EmptyEpochs => (atoms::error(), atoms::no_epochs()).encode(env),
        PppAutoInitError::CodeSeedFailed {
            epoch_index,
            source,
        } => (
            atoms::error(),
            (
                atoms::code_seed_failed(),
                epoch_index as i64,
                source.to_string(),
            ),
        )
            .encode(env),
        PppAutoInitError::Float(error) => encode_result(env, Err(error)),
        PppAutoInitError::Fixed(error) => encode_fixed_result(env, Err(error)),
    }
}

struct DecodedCorrections {
    sat_clock_relativity: bool,
    satellite_clock: Option<core::SatelliteClockCorrections>,
    receiver_antenna: Option<core::ReceiverAntennaOptions>,
    ppp_options: ppp::PppCorrectionsOptions,
}

fn decode_epochs(epochs: Vec<EpochTerm>) -> NifResult<Vec<core::FloatEpoch>> {
    epochs.into_iter().map(decode_epoch).collect()
}

fn decode_epoch(epoch: EpochTerm) -> NifResult<core::FloatEpoch> {
    let (datetime, jd_whole, jd_fraction, observations) = epoch;
    let observations = observations
        .into_iter()
        .map(
            |(satellite_id, ambiguity_id, code_m, phase_m, freq1_hz, freq2_hz, signals)| {
                Ok(core::FloatObservation {
                    sat: sat_from_token(&satellite_id)?,
                    satellite_id,
                    ambiguity_id,
                    code_m,
                    phase_m,
                    freq1_hz,
                    freq2_hz,
                    glonass_channel: None,
                    signals: signals.map(decode_observation_signals).transpose()?,
                })
            },
        )
        .collect::<NifResult<Vec<_>>>()?;
    Ok(core::FloatEpoch {
        epoch: civil_from_tuple(datetime),
        jd_whole,
        jd_fraction,
        t_rx_j2000_s: j2000_seconds_from_split(jd_whole, jd_fraction)
            .map_err(crate::errors::invalid_input)?,
        observations,
    })
}

/// The tracking codes of an observation's two pseudoranges and two carrier
/// phases, each a band and attribute (`"1C"`) or a RINEX 3 observation code
/// (`"C1C"`, `"L1C"`) read as written.
fn decode_observation_signals(
    term: ObservationSignalsTerm,
) -> NifResult<core::FloatObservationSignals> {
    let (code1, code2, phase1, phase2) = term;
    let parse = |text: &str, name: &str| {
        sidereon_core::ssr::SignalCode::parse(text).ok_or_else(|| {
            Error::Term(Box::new(format!(
                "observation signal {name} {text:?} is not a band and tracking attribute"
            )))
        })
    };
    Ok(core::FloatObservationSignals {
        code1: parse(&code1, "code1")?,
        code2: parse(&code2, "code2")?,
        phase1: parse(&phase1, "phase1")?,
        phase2: parse(&phase2, "phase2")?,
    })
}

fn decode_initial(initial: InitialStateTerm) -> core::FloatState {
    let (position, clocks_m, ambiguities, ztd_m, tropo_gradients, residual_ionosphere) = initial;
    let (tropo_gradient_north_m, tropo_gradient_east_m) = tropo_gradients.unwrap_or((0.0, 0.0));
    core::FloatState {
        position_m: vec3_to_array(position),
        clocks_m,
        ambiguities_m: ambiguities.into_iter().collect(),
        ztd_m: ztd_m.unwrap_or(0.0),
        tropo_gradient_north_m,
        tropo_gradient_east_m,
        residual_ionosphere_m: residual_ionosphere.into_iter().collect(),
    }
}

fn matrix3_to_lists(m: [[f64; 3]; 3]) -> Vec<Vec<f64>> {
    m.iter().map(|row| row.to_vec()).collect()
}

fn lists_to_matrix3(v: &[Vec<f64>]) -> NifResult<[[f64; 3]; 3]> {
    if v.len() != 3 || v.iter().any(|row| row.len() != 3) {
        return Err(Error::Term(Box::new(
            "expected a 3x3 covariance matrix".to_string(),
        )));
    }
    Ok([
        [v[0][0], v[0][1], v[0][2]],
        [v[1][0], v[1][1], v[1][2]],
        [v[2][0], v[2][1], v[2][2]],
    ])
}

fn matrix2_to_lists(m: [[f64; 2]; 2]) -> Vec<Vec<f64>> {
    m.iter().map(|row| row.to_vec()).collect()
}

fn lists_to_matrix2(v: &[Vec<f64>]) -> NifResult<[[f64; 2]; 2]> {
    if v.len() != 2 || v.iter().any(|row| row.len() != 2) {
        return Err(Error::Term(Box::new(
            "expected a 2x2 covariance matrix".to_string(),
        )));
    }
    Ok([[v[0][0], v[0][1]], [v[1][0], v[1][1]]])
}

fn decode_float_payload<'a>(term: FloatPayloadTerm<'a>) -> NifResult<core::FloatSolution> {
    let (
        position,
        epoch_clocks_m,
        (ambiguities_m, residual_ionosphere_m, ztd_residual_m, tropo_gradients),
        residuals_m,
        used_sats,
        (
            iterations,
            converged,
            status,
            code_rms_m,
            phase_rms_m,
            weighted_rms_m,
            (
                (position_cov_ecef, position_cov_enu),
                (formal_cov_ecef, formal_cov_enu),
                (
                    posterior_variance_factor,
                    position_covariance_scale_factor,
                    posterior_variance_factor_estimated,
                ),
                (temporal_cov_ecef, temporal_cov_enu),
                (temporal_position_covariance_scale_factor, temporal_correlation),
                tropo_gradient_covariance_m2,
                formal_tropo_gradient_covariance_m2,
            ),
        ),
        (
            ssr_bias_exclusions,
            unplaced_observations,
            residual_screen,
            solve_options,
            residual_screen_removals,
            solved_epoch_indices,
        ),
    ) = term;
    let (tropo_gradient_north_m, tropo_gradient_east_m) = match tropo_gradients {
        Some((north, east)) => (Some(north), Some(east)),
        None => (None, None),
    };
    Ok(core::FloatSolution {
        position_m: vec3_to_array(position),
        epoch_clocks_m,
        ambiguities_m: ambiguities_m.into_iter().collect(),
        residual_ionosphere_m: residual_ionosphere_m.into_iter().collect(),
        ztd_residual_m,
        tropo_gradient_north_m,
        tropo_gradient_east_m,
        tropo_gradient_covariance_m2: tropo_gradient_covariance_m2
            .as_deref()
            .map(lists_to_matrix2)
            .transpose()?,
        formal_tropo_gradient_covariance_m2: formal_tropo_gradient_covariance_m2
            .as_deref()
            .map(lists_to_matrix2)
            .transpose()?,
        residuals_m: residuals_m
            .into_iter()
            .map(
                |(
                    epoch_index,
                    satellite_id,
                    ambiguity_id,
                    code_m,
                    phase_m,
                    (code_weight, phase_weight),
                )| {
                    Ok(core::FloatResidual {
                        epoch_index: usize_from(epoch_index, "residual epoch_index")?,
                        satellite_id,
                        ambiguity_id,
                        code_m,
                        phase_m,
                        code_weight,
                        phase_weight,
                    })
                },
            )
            .collect::<NifResult<Vec<_>>>()?,
        used_sats,
        iterations: iterations as usize,
        converged,
        status: decode_float_status(status)?,
        code_rms_m,
        phase_rms_m,
        weighted_rms_m,
        position_covariance: core::PositionCovariance {
            ecef_m2: lists_to_matrix3(&position_cov_ecef)?,
            enu_m2: lists_to_matrix3(&position_cov_enu)?,
        },
        formal_position_covariance: core::PositionCovariance {
            ecef_m2: lists_to_matrix3(&formal_cov_ecef)?,
            enu_m2: lists_to_matrix3(&formal_cov_enu)?,
        },
        posterior_variance_factor,
        posterior_variance_factor_estimated,
        position_covariance_scale_factor,
        temporal_position_covariance: core::PositionCovariance {
            ecef_m2: lists_to_matrix3(&temporal_cov_ecef)?,
            enu_m2: lists_to_matrix3(&temporal_cov_enu)?,
        },
        temporal_position_covariance_scale_factor,
        temporal_correlation: decode_temporal_correlation(temporal_correlation),
        ssr_bias_exclusions: decode_ssr_bias_exclusions(ssr_bias_exclusions)?,
        solved_epoch_indices: solved_epoch_indices
            .into_iter()
            .map(|index| usize_from(index, "solved_epoch_indices"))
            .collect::<NifResult<Vec<_>>>()?,
        unplaced_observations: unplaced_observations
            .into_iter()
            .map(decode_unplaced_observation)
            .collect::<NifResult<Vec<_>>>()?,
        residual_screen,
        solve_options: decode_float_solve_options(solve_options),
        residual_screen_removals: decode_observation_keys(
            residual_screen_removals,
            "residual_screen_removals",
        )?,
    })
}

fn usize_from(value: u64, name: &str) -> NifResult<usize> {
    usize::try_from(value).map_err(|_| {
        Error::Term(Box::new(format!(
            "float solution {name} {value} does not fit this platform's index width"
        )))
    })
}

fn decode_observation_keys(
    keys: Vec<(u64, String)>,
    name: &str,
) -> NifResult<Vec<(usize, String)>> {
    keys.into_iter()
        .map(|(epoch_index, ambiguity_id)| Ok((usize_from(epoch_index, name)?, ambiguity_id)))
        .collect()
}

fn decode_float_solve_options(term: FloatSolveOptionsTerm) -> core::FloatSolveOptions {
    let mut options = core::FloatSolveOptions::default();
    options.max_iterations = term.0 as usize;
    options.position_tolerance_m = term.1;
    options.clock_tolerance_m = term.2;
    options.ambiguity_tolerance_m = term.3;
    options.ztd_tolerance_m = term.4;
    options
}

fn encode_float_solve_options(options: core::FloatSolveOptions) -> FloatSolveOptionsTerm {
    (
        options.max_iterations as u64,
        options.position_tolerance_m,
        options.clock_tolerance_m,
        options.ambiguity_tolerance_m,
        options.ztd_tolerance_m,
    )
}

fn encode_residuals(residuals: Vec<core::FloatResidual>) -> Vec<ResidualTerm> {
    residuals
        .into_iter()
        .map(|r| {
            (
                r.epoch_index as u64,
                r.satellite_id,
                r.ambiguity_id,
                r.code_m,
                r.phase_m,
                (r.code_weight, r.phase_weight),
            )
        })
        .collect()
}

pub(crate) fn encode_unplaced_observations<'a>(
    env: Env<'a>,
    unplaced: &[core::UnplacedObservation],
) -> Vec<UnplacedObservationTerm<'a>> {
    unplaced
        .iter()
        .map(|observation| {
            (
                observation.epoch_index as u64,
                observation.satellite_id.clone(),
                observation.ambiguity_id.clone(),
                match observation.reason {
                    core::UnplacedObservationReason::CodeNotPositive => {
                        atoms::code_not_positive().encode(env)
                    }
                    core::UnplacedObservationReason::SsrCorrectionExceedsLimit(size) => (
                        atoms::ssr_correction_exceeds_limit(),
                        SsrCorrectionSizeFields {
                            orbit_m: size.orbit_m,
                            clock_m: size.clock_m,
                        },
                    )
                        .encode(env),
                    _ => atoms::unrecognized_reason().encode(env),
                },
            )
        })
        .collect()
}

fn decode_unplaced_observation(
    term: UnplacedObservationTerm<'_>,
) -> NifResult<core::UnplacedObservation> {
    let (epoch_index, satellite_id, ambiguity_id, reason) = term;
    let reason = if reason
        .decode::<rustler::Atom>()
        .is_ok_and(|value| value == atoms::code_not_positive())
    {
        core::UnplacedObservationReason::CodeNotPositive
    } else if let Ok((reason_atom, size)) =
        reason.decode::<(rustler::Atom, SsrCorrectionSizeFields)>()
    {
        if reason_atom != atoms::ssr_correction_exceeds_limit() {
            return Err(Error::Term(Box::new("unknown unplaced-observation reason")));
        }
        core::UnplacedObservationReason::SsrCorrectionExceedsLimit(
            sidereon_core::ssr::SsrCorrectionSize {
                orbit_m: size.orbit_m,
                clock_m: size.clock_m,
            },
        )
    } else {
        return Err(Error::Term(Box::new("invalid unplaced-observation reason")));
    };
    Ok(core::UnplacedObservation {
        epoch_index: usize_from(epoch_index, "unplaced_observations")?,
        satellite_id,
        ambiguity_id,
        reason,
    })
}

fn encode_observation_keys(keys: &[(usize, String)]) -> Vec<(u64, String)> {
    keys.iter()
        .map(|(epoch_index, ambiguity_id)| (*epoch_index as u64, ambiguity_id.clone()))
        .collect()
}

fn decode_temporal_correlation(term: TemporalCorrelationTerm) -> core::TemporalCorrelationSummary {
    core::TemporalCorrelationSummary {
        lag1_autocorrelation: term.0,
        decorrelation_time_epochs: term.1,
        decorrelation_time_s: term.2,
        nominal_sample_count: term.3 as usize,
        effective_sample_count: term.4,
        variance_inflation_factor: term.5,
        arcs_used: term.6 as usize,
    }
}

fn decode_float_status(status: Term<'_>) -> NifResult<core::FloatStatus> {
    match status.atom_to_string()?.as_str() {
        "state_tolerance" => Ok(core::FloatStatus::StateTolerance),
        "max_iterations" => Ok(core::FloatStatus::MaxIterations),
        other => Err(Error::Term(Box::new(format!(
            "unknown PPP float status {other}"
        )))),
    }
}

fn decode_weights(weights: WeightsTerm) -> core::MeasurementWeights {
    core::MeasurementWeights {
        code: weights.0,
        phase: weights.1,
        elevation_weighting: weights.2,
    }
}

fn decode_solve_options(options: SolveOptionsTerm) -> core::FloatSolveOptions {
    let mut opts = core::FloatSolveOptions::default();
    opts.max_iterations = options.0 as usize;
    opts.position_tolerance_m = options.1;
    opts.clock_tolerance_m = options.2;
    opts.ambiguity_tolerance_m = options.3;
    opts.ztd_tolerance_m = options.4;
    opts
}

fn decode_tropo(tropo: &TropoTerm) -> NifResult<core::TroposphereOptions> {
    let met = sidereon_core::atmosphere::troposphere::Met::new(tropo.3, tropo.4, tropo.5)
        .map_err(crate::errors::invalid_input)?;
    let mut options = core::TroposphereOptions::new(met);
    options.enabled = tropo.0;
    options.estimate_ztd = tropo.1;
    options.estimate_tropo_gradients = tropo.2;
    options.mapping = decode_tropo_mapping(tropo.6.clone())?;
    Ok(options)
}

/// Decode the tropospheric mapping selection. `None` is the climatological
/// Niell (1996) mapping (the prior, byte-identical default). `Some(samples)` is
/// VMF1 driven by a site-wise `a`-coefficient series, each sample
/// `{mjd, ah, aw}`.
fn decode_tropo_mapping(
    term: Option<Vec<(f64, f64, f64)>>,
) -> NifResult<sidereon_core::precise_positioning::TropoMapping> {
    use sidereon_core::precise_positioning::{TropoMapping, VmfSiteSample, VmfSiteSeries};
    match term {
        None => Ok(TropoMapping::Niell),
        Some(samples) => {
            let parsed: Vec<VmfSiteSample> = samples
                .into_iter()
                .map(|(mjd, ah, aw)| VmfSiteSample { mjd, ah, aw })
                .collect();
            let series = VmfSiteSeries::new(&parsed).map_err(crate::errors::invalid_input)?;
            Ok(TropoMapping::Vmf1(series))
        }
    }
}

fn decode_fixed_ambiguity(term: FixedAmbiguityTerm) -> core::FixedAmbiguityOptions {
    let (wavelengths_m, offsets_m, ratio_threshold) = term;
    let mut options = core::FixedAmbiguityOptions::new(ratio_threshold);
    options.wavelengths_m = wavelengths_m.into_iter().collect();
    options.offsets_m = offsets_m.into_iter().collect();
    options
}

fn decode_corrections(term: CorrectionsTerm) -> NifResult<DecodedCorrections> {
    let (
        sat_clock_relativity,
        satellite_clock,
        receiver_antenna,
        solid_earth_tide,
        phase_windup,
        satellite_antenna,
        (pole_tide, ocean_loading),
    ) = term;
    let mut ppp_options = ppp::PppCorrectionsOptions::new();
    ppp_options.solid_earth_tide = solid_earth_tide;
    ppp_options.pole_tide = crate::ppp_corrections::decode_pole_tide(pole_tide);
    ppp_options.ocean_loading = crate::ppp_corrections::decode_ocean_loading(ocean_loading)?;
    ppp_options.phase_windup = phase_windup;
    ppp_options.satellite_antenna = decode_satellite_antenna_options(satellite_antenna)?;
    ppp_options.code_bias = None;
    Ok(DecodedCorrections {
        sat_clock_relativity,
        satellite_clock: decode_satellite_clock(satellite_clock)?,
        receiver_antenna: decode_receiver_antenna(receiver_antenna),
        ppp_options,
    })
}

fn decode_satellite_clock(
    term: Option<SatelliteClockTerm>,
) -> NifResult<Option<core::SatelliteClockCorrections>> {
    let Some(series) = term else {
        return Ok(None);
    };
    let mut out = BTreeMap::new();
    for (sat, records) in series {
        out.insert(sat_from_token(&sat)?, records);
    }
    Ok(Some(core::SatelliteClockCorrections { series: out }))
}

fn decode_receiver_antenna(
    term: Option<ReceiverAntennaTerm>,
) -> Option<core::ReceiverAntennaOptions> {
    term.map(
        |(freq1_label, freq1_hz, freq2_label, freq2_hz, frequencies)| {
            core::ReceiverAntennaOptions::new(
                freq1_label,
                freq1_hz,
                freq2_label,
                freq2_hz,
                frequencies
                    .into_iter()
                    .map(|(label, pco, pcv_samples)| core::ReceiverAntennaFrequency {
                        label,
                        pco_m: vec3_to_array(pco),
                        pcv_samples: pcv_samples
                            .into_iter()
                            .map(|(azimuth_deg, zenith_deg, value_m)| core::PcvSample {
                                azimuth_deg,
                                zenith_deg,
                                value_m,
                            })
                            .collect(),
                    })
                    .collect(),
            )
        },
    )
}

fn decode_satellite_antenna_options(
    term: Option<SatelliteAntennaOptionsTerm>,
) -> NifResult<Option<ppp::SatelliteAntennaOptions>> {
    let Some((freq1_label, freq1_hz, freq2_label, freq2_hz, antennas)) = term else {
        return Ok(None);
    };
    let antennas = antennas
        .into_iter()
        .map(|(sat, valid_from, valid_until, frequencies)| {
            let frequencies = frequencies
                .into_iter()
                .map(|(label, pco, noazi_pcv)| ppp::SatelliteAntennaFrequency {
                    label,
                    pco_m: vec3_to_array(pco),
                    noazi_pcv_m: noazi_pcv,
                })
                .collect();
            Ok(ppp::SatelliteAntenna {
                sat: sat_from_token(&sat)?,
                valid_from: valid_from.map(civil_from_validity).transpose()?,
                valid_until: valid_until.map(civil_from_validity).transpose()?,
                frequencies,
            })
        })
        .collect::<NifResult<Vec<_>>>()?;
    Ok(Some(ppp::SatelliteAntennaOptions::new(
        freq1_label,
        freq1_hz,
        freq2_label,
        freq2_hz,
        antennas,
    )))
}

fn civil_from_tuple(tuple: DateTimeTuple) -> ppp::CivilDateTime {
    let (date, time) = tuple;
    ppp::CivilDateTime {
        year: date.0,
        month: date.1 as u8,
        day: date.2 as u8,
        hour: time.0 as u8,
        minute: time.1 as u8,
        second: time.2 as f64 + time.3 as f64 / 1_000_000.0,
    }
}

/// A satellite antenna validity bound: date, whole clock fields and the exact
/// fraction of the second as `(digits, scale)`, as the ANTEX reader keeps it.
type ValidityTerm = ((i32, i32, i32), (i32, i32, i32), (u64, u64));

/// A validity bound as the civil epoch the antenna selection compares, its
/// seconds the nearest double to the exact decimal the bound states.
fn civil_from_validity(term: ValidityTerm) -> NifResult<ppp::CivilDateTime> {
    let ((year, month, day), (hour, minute, second), (digits, scale)) = term;
    let field = |value: i32, name: &'static str| {
        u8::try_from(value).map_err(|_| {
            Error::Term(Box::new(format!(
                "antenna validity {name} {value} is outside 0..=255"
            )))
        })
    };
    let second = field(second, "second")?;
    Ok(ppp::CivilDateTime {
        year,
        month: field(month, "month")?,
        day: field(day, "day")?,
        hour: field(hour, "hour")?,
        minute: field(minute, "minute")?,
        second: crate::antex::validity_seconds(second, digits, scale).ok_or_else(|| {
            Error::Term(Box::new(
                "antenna validity fraction is not below one second",
            ))
        })?,
    })
}

fn sat_from_token(token: &str) -> NifResult<GnssSatelliteId> {
    let Some(letter) = token.chars().next() else {
        return Err(Error::Term(Box::new("empty satellite token")));
    };
    let Some(system) = GnssSystem::from_letter(letter) else {
        return Err(Error::Term(Box::new(format!(
            "unknown GNSS system letter {letter:?}"
        ))));
    };
    let prn_text = &token[letter.len_utf8()..];
    let prn = prn_text
        .parse::<u8>()
        .map_err(|_| Error::Term(Box::new(format!("bad satellite token {token:?}"))))?;
    GnssSatelliteId::new(system, prn).map_err(crate::errors::invalid_input)
}

fn vec3_to_array(vec: Vec3) -> [f64; 3] {
    [vec.0, vec.1, vec.2]
}

fn array_to_vec3(array: [f64; 3]) -> Vec3 {
    (array[0], array[1], array[2])
}

fn encode_result_detailed<'a>(
    env: Env<'a>,
    result: Result<core::FloatSolution, core::FloatSolveError>,
) -> Term<'a> {
    match result {
        Err(error @ core::FloatSolveError::InvalidSolveOption { .. })
        | Err(error @ core::FloatSolveError::InvalidInput { .. }) => {
            encode_float_error_detailed(env, error)
        }
        other => encode_result(env, other),
    }
}

fn encode_result<'a>(
    env: Env<'a>,
    result: Result<core::FloatSolution, core::FloatSolveError>,
) -> Term<'a> {
    match result {
        Ok(solution) => (atoms::ok(), encode_float_payload(env, solution)).encode(env),
        Err(err) => encode_float_error(env, err),
    }
}

fn encode_float_payload<'a>(env: Env<'a>, solution: core::FloatSolution) -> Term<'a> {
    let covariance_bundle = encode_float_covariance_bundle(&solution);
    let ztd = match solution.ztd_residual_m {
        Some(value) => value.encode(env),
        None => atoms::nil().encode(env),
    };
    let tropo_gradients: Term<'a> = match (
        solution.tropo_gradient_north_m,
        solution.tropo_gradient_east_m,
    ) {
        (Some(north), Some(east)) => (north, east).encode(env),
        _ => atoms::nil().encode(env),
    };
    let status = encode_float_status(solution.status);
    let provenance: FloatProvenanceTerm<'a> = (
        encode_ssr_bias_exclusions(&solution.ssr_bias_exclusions),
        encode_unplaced_observations(env, &solution.unplaced_observations),
        solution.residual_screen,
        encode_float_solve_options(solution.solve_options),
        encode_observation_keys(&solution.residual_screen_removals),
        solution
            .solved_epoch_indices
            .iter()
            .map(|index| *index as u64)
            .collect(),
    );
    let residuals = encode_residuals(solution.residuals_m);
    (
        array_to_vec3(solution.position_m),
        solution.epoch_clocks_m,
        (
            solution.ambiguities_m.into_iter().collect::<Vec<_>>(),
            solution
                .residual_ionosphere_m
                .into_iter()
                .collect::<Vec<_>>(),
            ztd,
            tropo_gradients,
        ),
        residuals,
        solution.used_sats,
        (
            solution.iterations as u64,
            solution.converged,
            status,
            solution.code_rms_m,
            solution.phase_rms_m,
            solution.weighted_rms_m,
            covariance_bundle,
        ),
        provenance,
    )
        .encode(env)
}

fn encode_float_covariance_bundle(solution: &core::FloatSolution) -> FloatCovarianceTerm {
    (
        (
            matrix3_to_lists(solution.position_covariance.ecef_m2),
            matrix3_to_lists(solution.position_covariance.enu_m2),
        ),
        (
            matrix3_to_lists(solution.formal_position_covariance.ecef_m2),
            matrix3_to_lists(solution.formal_position_covariance.enu_m2),
        ),
        (
            solution.posterior_variance_factor,
            solution.position_covariance_scale_factor,
            solution.posterior_variance_factor_estimated,
        ),
        (
            matrix3_to_lists(solution.temporal_position_covariance.ecef_m2),
            matrix3_to_lists(solution.temporal_position_covariance.enu_m2),
        ),
        (
            solution.temporal_position_covariance_scale_factor,
            encode_temporal_correlation(solution.temporal_correlation),
        ),
        solution.tropo_gradient_covariance_m2.map(matrix2_to_lists),
        solution
            .formal_tropo_gradient_covariance_m2
            .map(matrix2_to_lists),
    )
}

fn encode_fixed_covariance_bundle(solution: &core::FixedSolution) -> FloatCovarianceTerm {
    (
        (
            matrix3_to_lists(solution.position_covariance.ecef_m2),
            matrix3_to_lists(solution.position_covariance.enu_m2),
        ),
        (
            matrix3_to_lists(solution.formal_position_covariance.ecef_m2),
            matrix3_to_lists(solution.formal_position_covariance.enu_m2),
        ),
        (
            solution.posterior_variance_factor,
            solution.position_covariance_scale_factor,
            solution.posterior_variance_factor_estimated,
        ),
        (
            matrix3_to_lists(solution.temporal_position_covariance.ecef_m2),
            matrix3_to_lists(solution.temporal_position_covariance.enu_m2),
        ),
        (
            solution.temporal_position_covariance_scale_factor,
            encode_temporal_correlation(solution.temporal_correlation),
        ),
        solution.tropo_gradient_covariance_m2.map(matrix2_to_lists),
        solution
            .formal_tropo_gradient_covariance_m2
            .map(matrix2_to_lists),
    )
}

fn encode_temporal_correlation(
    temporal: core::TemporalCorrelationSummary,
) -> TemporalCorrelationTerm {
    (
        temporal.lag1_autocorrelation,
        temporal.decorrelation_time_epochs,
        temporal.decorrelation_time_s,
        temporal.nominal_sample_count as u64,
        temporal.effective_sample_count,
        temporal.variance_inflation_factor,
        temporal.arcs_used as u64,
    )
}

fn encode_fixed_result_detailed<'a>(
    env: Env<'a>,
    result: Result<core::FixedSolution, core::FixedSolveError>,
) -> Term<'a> {
    match result {
        Err(core::FixedSolveError::Float(
            error @ core::FloatSolveError::InvalidSolveOption { .. },
        ))
        | Err(core::FixedSolveError::Float(error @ core::FloatSolveError::InvalidInput { .. })) => {
            encode_float_error_detailed(env, error)
        }
        other => encode_fixed_result(env, other),
    }
}

fn encode_fixed_result<'a>(
    env: Env<'a>,
    result: Result<core::FixedSolution, core::FixedSolveError>,
) -> Term<'a> {
    match result {
        Ok(solution) => {
            let status = encode_float_status(solution.status);
            let integer_status = match solution.integer.integer_status {
                core::IntegerStatus::Fixed => atoms::fixed(),
                core::IntegerStatus::NotFixed => atoms::not_fixed(),
            };
            let ratio_term: Term<'a> = if solution.integer.integer_ratio.is_infinite() {
                atoms::infinity().encode(env)
            } else {
                solution.integer.integer_ratio.encode(env)
            };
            let second_term: Term<'a> = match solution.integer.integer_second_best_score {
                Some(value) => value.encode(env),
                None => atoms::nil().encode(env),
            };
            let ztd = match solution.ztd_residual_m {
                Some(value) => value.encode(env),
                None => atoms::nil().encode(env),
            };
            let tropo_gradients: Term<'a> = match (
                solution.tropo_gradient_north_m,
                solution.tropo_gradient_east_m,
            ) {
                (Some(north), Some(east)) => (north, east).encode(env),
                _ => atoms::nil().encode(env),
            };
            let residual_ionosphere_m = solution
                .residual_ionosphere_m
                .clone()
                .into_iter()
                .collect::<Vec<_>>();
            let covariance_bundle = encode_fixed_covariance_bundle(&solution);
            let integer_best_score = solution.integer.integer_best_score;
            let integer_candidates = solution.integer.integer_candidates as u64;
            let fixed_provenance = (
                encode_ssr_bias_exclusions(&solution.ssr_bias_exclusions),
                solution
                    .solved_epoch_indices
                    .iter()
                    .map(|index| *index as u64)
                    .collect::<Vec<_>>(),
                encode_unplaced_observations(env, &solution.unplaced_observations),
            );
            let residuals = encode_residuals(solution.residuals_m);
            let search = solution.integer.ambiguity_search;
            (
                atoms::ok(),
                (
                    array_to_vec3(solution.position_m),
                    solution.epoch_clocks_m,
                    (
                        solution
                            .fixed_ambiguities_cycles
                            .into_iter()
                            .collect::<Vec<_>>(),
                        solution.fixed_ambiguities_m.into_iter().collect::<Vec<_>>(),
                        residual_ionosphere_m,
                    ),
                    (
                        ztd,
                        tropo_gradients,
                        encode_float_payload(env, solution.float_solution),
                        fixed_provenance,
                    ),
                    residuals,
                    solution.used_sats,
                    (
                        solution.iterations as u64,
                        solution.converged,
                        status,
                        solution.code_rms_m,
                        solution.phase_rms_m,
                        solution.weighted_rms_m,
                        (
                            (
                                integer_status,
                                ratio_term,
                                integer_best_score,
                                second_term,
                                integer_candidates,
                                (
                                    search.order,
                                    search.float_cycles.into_iter().collect::<Vec<_>>(),
                                    search.covariance_cycles,
                                    search.covariance_inverse_cycles,
                                ),
                            ),
                            covariance_bundle,
                        ),
                    ),
                ),
            )
                .encode(env)
        }
        Err(core::FixedSolveError::Float(err)) => encode_float_error(env, err),
        Err(core::FixedSolveError::Integer(err)) => encode_ils_error(env, err),
        Err(core::FixedSolveError::MissingWavelength(id)) => {
            (atoms::error(), (atoms::missing_wavelength(), id)).encode(env)
        }
        Err(core::FixedSolveError::MissingOffset(id)) => {
            (atoms::error(), (atoms::missing_offset(), id)).encode(env)
        }
        Err(core::FixedSolveError::MissingFixedAmbiguity(id)) => {
            (atoms::error(), (atoms::missing_ambiguity(), id)).encode(env)
        }
    }
}

fn encode_float_status(status: core::FloatStatus) -> rustler::Atom {
    match status {
        core::FloatStatus::StateTolerance => atoms::state_tolerance(),
        core::FloatStatus::MaxIterations => atoms::max_iterations(),
    }
}

fn encode_float_error_detailed<'a>(env: Env<'a>, err: core::FloatSolveError) -> Term<'a> {
    match err {
        error @ core::FloatSolveError::InvalidSolveOption { field, reason } => (
            atoms::error(),
            (
                atoms::invalid_solve_option(),
                field,
                reason,
                error.to_string(),
            ),
        )
            .encode(env),
        error @ core::FloatSolveError::InvalidInput { field, reason } => (
            atoms::error(),
            (atoms::invalid_input(), field, reason, error.to_string()),
        )
            .encode(env),
        other => encode_float_error(env, other),
    }
}

fn encode_float_error<'a>(env: Env<'a>, err: core::FloatSolveError) -> Term<'a> {
    match err {
        core::FloatSolveError::NoEphemeris {
            satellite_id,
            reason,
        } => {
            let reason = match reason {
                core::NoEphemerisReason::NoEphemeris => atoms::no_ephemeris().encode(env),
                core::NoEphemerisReason::MissingSatelliteClock => {
                    atoms::missing_satellite_clock().encode(env)
                }
                core::NoEphemerisReason::Reason(reason) => reason.encode(env),
            };
            (
                atoms::error(),
                (atoms::no_ephemeris(), satellite_id, reason),
            )
                .encode(env)
        }
        core::FloatSolveError::SingularGeometry => {
            (atoms::error(), atoms::singular_geometry()).encode(env)
        }
        core::FloatSolveError::InvalidClockCount { expected, actual } => (
            atoms::error(),
            (atoms::invalid_clock_count(), expected as u64, actual as u64),
        )
            .encode(env),
        core::FloatSolveError::InvalidSolveOption { .. } => {
            (atoms::error(), atoms::invalid_solve_option()).encode(env)
        }
        core::FloatSolveError::InvalidInput { .. } => {
            (atoms::error(), atoms::invalid_input()).encode(env)
        }
        core::FloatSolveError::InsufficientObservationsAfterElevationCutoff {
            cutoff_deg,
            retained_observations,
            required_observations,
        } => (
            atoms::error(),
            (
                atoms::insufficient_observations_after_elevation_cutoff(),
                cutoff_deg,
                retained_observations as u64,
                required_observations as u64,
            ),
        )
            .encode(env),
        core::FloatSolveError::InsufficientObservationsAfterSsrBiasExclusion {
            excluded_observations,
            retained_observations,
            required_observations,
        } => (
            atoms::error(),
            (
                atoms::insufficient_observations_after_ssr_bias_exclusion(),
                excluded_observations as u64,
                retained_observations as u64,
                required_observations as u64,
            ),
        )
            .encode(env),
        core::FloatSolveError::Ut1OutsideCoverage(reason) => (
            atoms::error(),
            crate::errors::ut1_outside_coverage_term(env, reason),
        )
            .encode(env),
        core::FloatSolveError::MissingAmbiguity(ambiguity_id) => {
            (atoms::error(), (atoms::missing_ambiguity(), ambiguity_id)).encode(env)
        }
        core::FloatSolveError::MissingCorrection {
            satellite_id,
            correction,
        } => (
            atoms::error(),
            (
                atoms::missing_correction(),
                satellite_id,
                correction.to_string(),
            ),
        )
            .encode(env),
    }
}

fn encode_ils_error<'a>(env: Env<'a>, err: sidereon_core::ils::IlsError) -> Term<'a> {
    match err {
        sidereon_core::ils::IlsError::Singular => {
            (atoms::error(), atoms::singular_geometry()).encode(env)
        }
        sidereon_core::ils::IlsError::NoCandidates(n) => {
            (atoms::error(), (atoms::no_integer_candidates(), n)).encode(env)
        }
        sidereon_core::ils::IlsError::TooManyCandidates { evaluated, limit } => (
            atoms::error(),
            (atoms::too_many_integer_candidates(), evaluated, limit),
        )
            .encode(env),
        sidereon_core::ils::IlsError::InvalidDimensions { n, rows } => {
            (atoms::error(), (atoms::invalid_dimensions(), n, rows)).encode(env)
        }
        sidereon_core::ils::IlsError::NonFinite => {
            (atoms::error(), atoms::non_finite_input()).encode(env)
        }
        sidereon_core::ils::IlsError::SearchLimitExceeded => {
            (atoms::error(), atoms::search_limit_exceeded()).encode(env)
        }
        sidereon_core::ils::IlsError::InvalidInput { .. } => {
            (atoms::error(), atoms::invalid_input()).encode(env)
        }
    }
}
