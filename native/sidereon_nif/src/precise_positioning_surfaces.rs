//! Rustler glue for precise-positioning TEC and cycle-slip leaf APIs.

use crate::time::ExactEpochResource;
use rustler::{Encoder, Env, NifMap, ResourceArc, Term};
use sidereon_core::carrier_phase::CycleSlipOptions;
use sidereon_core::carrier_phase::SlipReason;
use sidereon_core::precise_positioning as core;

type Observation = (
    String,
    String,
    (f64, f64, f64, f64),
    (f64, f64),
    (Option<i64>, Option<i64>),
);
type CycleConfig = (f64, f64, u64, f64, f64);
type TecConfig = (f64, f64);
type ExactEpochTerm = Option<ResourceArc<ExactEpochResource>>;
type CycleState = (
    Option<f64>,
    ExactEpochTerm,
    Option<f64>,
    (u64, f64, f64),
    Option<f64>,
);
type DualEpoch = (Option<f64>, ExactEpochTerm, Vec<Observation>);
type TecObservationTerm = (Observation, f64, f64);
type TecEpochTerm = (f64, f64, f64, Vec<TecObservationTerm>);
type PrepOptions = (u64, f64);
type SlipOptions = (f64, f64, f64);
type FloatSlipObservation = (String, String, Option<Observation>);
type FloatSlipEpoch = (Option<f64>, ExactEpochTerm, Vec<FloatSlipObservation>);
type Residual = (u64, String, String, f64, f64, (f64, f64));
type RaimGeometry = (String, (f64, f64, f64));
type RaimConfig = (f64, f64, f64, Option<f64>);
type RaimStatistic = (String, f64, f64, f64, bool, bool);
type RaimResult = (
    &'static str,
    bool,
    f64,
    Option<f64>,
    i64,
    Vec<RaimStatistic>,
    (Option<String>, Option<f64>, Option<f64>),
);
type KinematicState = ((f64, f64, f64), f64, f64, Vec<(String, f64)>);
type KinematicNoise = (String, f64, f64, f64, f64);
type KinematicConfig = (
    KinematicState,
    Vec<Vec<f64>>,
    (String, (f64, f64, f64)),
    KinematicNoise,
    f64,
    (f64, f64, bool),
);

mod atoms {
    rustler::atoms! { ok, error }
}

fn observation(value: Observation) -> core::DualFrequencyObservation {
    core::DualFrequencyObservation {
        satellite_id: value.0,
        ambiguity_id: value.1,
        p1_m: value.2 .0,
        p2_m: value.2 .1,
        phi1_cyc: value.2 .2,
        phi2_cyc: value.2 .3,
        f1_hz: value.3 .0,
        f2_hz: value.3 .1,
        lli1: value.4 .0,
        lli2: value.4 .1,
    }
}

fn cycle_config(value: CycleConfig) -> core::CycleSlipConfig {
    let mut config = core::CycleSlipConfig::default();
    config.melbourne_wubbena_threshold_cycles = value.0;
    config.geometry_free_threshold_m = value.1;
    config.minimum_arc_length = value.2 as usize;
    config.running_statistic_k_factor = value.3;
    config.maximum_gap_s = value.4;
    config
}

fn tec_config(value: TecConfig) -> core::TecConfig {
    let mut config = core::TecConfig::default();
    config.shell_height_m = value.0;
    config.earth_radius_m = value.1;
    config
}

fn cycle_state(value: CycleState) -> core::SatelliteCycleSlipState {
    core::SatelliteCycleSlipState {
        previous_epoch_time_s: value.0,
        previous_epoch: value.1.map(|resource| resource.epoch),
        previous_melbourne_wubbena_cycles: value.2,
        melbourne_wubbena: core::RunningMeanVariance {
            sample_count: value.3 .0 as usize,
            mean: value.3 .1,
            variance: value.3 .2,
        },
        previous_geometry_free_m: value.4,
    }
}

fn encode_state(value: core::SatelliteCycleSlipState) -> CycleState {
    (
        value.previous_epoch_time_s,
        value
            .previous_epoch
            .map(|epoch| ResourceArc::new(ExactEpochResource { epoch })),
        value.previous_melbourne_wubbena_cycles,
        (
            value.melbourne_wubbena.sample_count as u64,
            value.melbourne_wubbena.mean,
            value.melbourne_wubbena.variance,
        ),
        value.previous_geometry_free_m,
    )
}

fn epochs(values: Vec<DualEpoch>) -> Vec<core::DualFrequencyEpoch> {
    values
        .into_iter()
        .map(
            |(gap_time_s, gap_epoch, observations)| core::DualFrequencyEpoch {
                gap_time_s,
                gap_epoch: gap_epoch.map(|resource| resource.epoch),
                observations: observations.into_iter().map(observation).collect(),
            },
        )
        .collect()
}

fn reason(value: SlipReason) -> &'static str {
    match value {
        SlipReason::Lli => "lli",
        SlipReason::DataGap => "data_gap",
        SlipReason::GeometryFree => "geometry_free",
        SlipReason::MelbourneWubbena => "melbourne_wubbena",
    }
}

fn result<'a, T: Encoder, E: Encoder>(env: Env<'a>, value: Result<T, E>) -> Term<'a> {
    match value {
        Ok(value) => (atoms::ok(), value).encode(env),
        Err(error) => (atoms::error(), error).encode(env),
    }
}

type ErrorTerm = (String, Option<String>, Option<String>, String);
type KinematicErrorTerm = (String, Option<String>, Option<String>, String, String);

fn tec_error(error: core::TecError) -> ErrorTerm {
    let kind = match error {
        core::TecError::NonFiniteObservation => "non_finite_observation",
        core::TecError::InvalidShellHeight => "invalid_shell_height",
        core::TecError::InvalidEarthRadius => "invalid_earth_radius",
        core::TecError::InvalidFrequency => "invalid_frequency",
        core::TecError::EqualFrequencies => "equal_frequencies",
        core::TecError::InvalidReceiverLatitude => "invalid_receiver_latitude",
        core::TecError::InvalidReceiverLongitude => "invalid_receiver_longitude",
        core::TecError::InvalidElevation => "invalid_elevation",
        core::TecError::InvalidAzimuth => "invalid_azimuth",
        core::TecError::NonFiniteTec => "non_finite_tec",
        core::TecError::EmptyArc => "empty_arc",
        core::TecError::NoEpochs => "no_epochs",
        core::TecError::NoObservations => "no_observations",
        core::TecError::NonFiniteEpochTime => "non_finite_epoch_time",
        core::TecError::EpochsNotOrdered => "epochs_not_ordered",
        core::TecError::InsufficientArcSamples => "insufficient_arc_samples",
    };
    (kind.to_string(), None, None, error.to_string())
}

fn cycle_error(error: core::CycleSlipError) -> ErrorTerm {
    let (kind, field, reason) = match error {
        core::CycleSlipError::InvalidConfig(inner) => {
            let field = match inner {
                core::CycleSlipConfigError::InvalidMelbourneWubbenaThreshold => {
                    "melbourne_wubbena_threshold_cycles"
                }
                core::CycleSlipConfigError::InvalidGeometryFreeThreshold => {
                    "geometry_free_threshold_m"
                }
                core::CycleSlipConfigError::InvalidMinimumArcLength => "minimum_arc_length",
                core::CycleSlipConfigError::InvalidRunningStatisticKFactor => {
                    "running_statistic_k_factor"
                }
                core::CycleSlipConfigError::InvalidMaximumGap => "maximum_gap_s",
            };
            (
                "invalid_config",
                Some(field.to_string()),
                Some(inner.to_string()),
            )
        }
        core::CycleSlipError::NonFiniteObservation => ("non_finite_observation", None, None),
        core::CycleSlipError::NonFiniteEpochTime => ("non_finite_epoch_time", None, None),
        core::CycleSlipError::EpochsNotOrdered => ("epochs_not_ordered", None, None),
        core::CycleSlipError::InvalidFrequency => ("invalid_frequency", None, None),
        core::CycleSlipError::EqualFrequencies => ("equal_frequencies", None, None),
    };
    (kind.to_string(), field, reason, error.to_string())
}

fn raim_error(error: core::RaimError) -> ErrorTerm {
    let (kind, field, reason) = match error {
        core::RaimError::InvalidConfig { field, reason } => (
            "invalid_config",
            Some(field.to_string()),
            Some(reason.to_string()),
        ),
        core::RaimError::InvalidResidual { field } => {
            ("invalid_residual", Some(field.to_string()), None)
        }
        core::RaimError::InvalidGeometry { field, reason } => (
            "invalid_geometry",
            Some(field.to_string()),
            Some(reason.to_string()),
        ),
        core::RaimError::Dop(inner) => ("dop", None, Some(inner.to_string())),
        core::RaimError::SingularGeometry => ("singular_geometry", None, None),
    };
    (kind.to_string(), field, reason, error.to_string())
}

#[rustler::nif]
pub fn pp_tec_constants() -> (f64, f64, f64) {
    (
        core::DEFAULT_IONOSPHERIC_SHELL_HEIGHT_M,
        core::ELECTRONS_PER_TECU_M2,
        core::TEC_GROUP_DELAY_COEFFICIENT,
    )
}

#[rustler::nif]
pub fn pp_tec_config_default() -> TecConfig {
    let c = core::TecConfig::default();
    (c.shell_height_m, c.earth_radius_m)
}

#[rustler::nif]
pub fn pp_tec_code_geometry_free<'a>(env: Env<'a>, obs: Observation) -> Term<'a> {
    result(
        env,
        core::code_geometry_free_m(&observation(obs)).map_err(tec_error),
    )
}

#[rustler::nif]
pub fn pp_tec_phase_geometry_free<'a>(env: Env<'a>, obs: Observation) -> Term<'a> {
    result(
        env,
        core::phase_geometry_free_m(&observation(obs)).map_err(tec_error),
    )
}

#[rustler::nif]
pub fn pp_tec_slant_from_code<'a>(env: Env<'a>, value: f64, f1: f64, f2: f64) -> Term<'a> {
    result(
        env,
        core::slant_tec_from_code_geometry_free_m(value, f1, f2).map_err(tec_error),
    )
}

#[rustler::nif]
pub fn pp_tec_slant_from_phase<'a>(env: Env<'a>, value: f64, f1: f64, f2: f64) -> Term<'a> {
    result(
        env,
        core::slant_tec_from_phase_geometry_free_m(value, f1, f2).map_err(tec_error),
    )
}

#[rustler::nif]
pub fn pp_tec_estimate_code<'a>(env: Env<'a>, obs: Observation) -> Term<'a> {
    result(
        env,
        core::estimate_code_slant_tec(&observation(obs))
            .map(|v| {
                (
                    v.satellite_id,
                    v.ambiguity_id,
                    v.code_geometry_free_m,
                    v.slant_tec_tecu,
                )
            })
            .map_err(tec_error),
    )
}

#[rustler::nif]
pub fn pp_tec_estimate_phase<'a>(env: Env<'a>, obs: Observation) -> Term<'a> {
    result(
        env,
        core::estimate_phase_slant_tec(&observation(obs))
            .map(|v| {
                (
                    v.satellite_id,
                    v.ambiguity_id,
                    v.phase_geometry_free_m,
                    v.slant_tec_tecu,
                )
            })
            .map_err(tec_error),
    )
}

#[rustler::nif]
pub fn pp_tec_mapping<'a>(env: Env<'a>, elevation: f64, config: TecConfig) -> Term<'a> {
    result(
        env,
        core::thin_shell_mapping_function(elevation, tec_config(config)).map_err(tec_error),
    )
}

#[rustler::nif]
pub fn pp_tec_vertical<'a>(
    env: Env<'a>,
    slant: f64,
    elevation: f64,
    config: TecConfig,
) -> Term<'a> {
    result(
        env,
        core::vertical_tec_from_slant_tec(slant, elevation, tec_config(config)).map_err(tec_error),
    )
}

#[rustler::nif]
pub fn pp_tec_level<'a>(
    env: Env<'a>,
    samples: Vec<(f64, f64, f64)>,
    config: TecConfig,
) -> Term<'a> {
    let samples = samples
        .into_iter()
        .map(|v| core::TecLevelingSample {
            code_slant_tec_tecu: v.0,
            phase_slant_tec_tecu: v.1,
            elevation_rad: v.2,
        })
        .collect::<Vec<_>>();
    result(
        env,
        core::level_slant_tec_arc(&samples, tec_config(config))
            .map(|v| {
                (
                    v.phase_bias_tecu,
                    v.samples
                        .into_iter()
                        .map(|s| {
                            (
                                s.code_slant_tec_tecu,
                                s.phase_slant_tec_tecu,
                                s.leveled_slant_tec_tecu,
                                s.mapping_function,
                                s.vertical_tec_tecu,
                            )
                        })
                        .collect::<Vec<_>>(),
                )
            })
            .map_err(tec_error),
    )
}

#[rustler::nif]
pub fn pp_tec_pierce_point<'a>(
    env: Env<'a>,
    lat: f64,
    lon: f64,
    elevation: f64,
    azimuth: f64,
    config: TecConfig,
) -> Term<'a> {
    result(
        env,
        core::ionospheric_pierce_point(lat, lon, elevation, azimuth, tec_config(config))
            .map(|v| {
                (
                    v.latitude_rad,
                    v.longitude_rad,
                    v.latitude_deg,
                    v.longitude_deg,
                    v.earth_central_angle_rad,
                    v.shell_height_m,
                )
            })
            .map_err(tec_error),
    )
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn pp_tec_estimate<'a>(env: Env<'a>, values: Vec<TecEpochTerm>, config: TecConfig) -> Term<'a> {
    let epochs = values
        .into_iter()
        .map(|value| core::TecEpoch {
            time_s: value.0,
            receiver_latitude_rad: value.1,
            receiver_longitude_rad: value.2,
            observations: value
                .3
                .into_iter()
                .map(|row| core::TecObservation {
                    observation: observation(row.0),
                    elevation_rad: row.1,
                    azimuth_rad: row.2,
                })
                .collect(),
        })
        .collect::<Vec<_>>();
    result(
        env,
        core::estimate_tec(&epochs, tec_config(config))
            .map(|estimate| {
                estimate
                    .arcs
                    .into_iter()
                    .map(|arc| {
                        (
                            arc.satellite_id,
                            arc.ambiguity_id,
                            arc.phase_bias_tecu,
                            arc.samples
                                .into_iter()
                                .map(|s| {
                                    (
                                        (s.time_s, s.elevation_rad, s.azimuth_rad),
                                        (s.code_geometry_free_m, s.phase_geometry_free_m),
                                        (
                                            s.code_slant_tec_tecu,
                                            s.phase_slant_tec_tecu,
                                            s.leveled_slant_tec_tecu,
                                        ),
                                        (s.mapping_function, s.vertical_tec_tecu),
                                        (
                                            s.pierce_point.latitude_rad,
                                            s.pierce_point.longitude_rad,
                                            s.pierce_point.latitude_deg,
                                            s.pierce_point.longitude_deg,
                                            s.pierce_point.earth_central_angle_rad,
                                            s.pierce_point.shell_height_m,
                                        ),
                                    )
                                })
                                .collect::<Vec<_>>(),
                        )
                    })
                    .collect::<Vec<_>>()
            })
            .map_err(tec_error),
    )
}

#[rustler::nif]
pub fn pp_cycle_config_default() -> CycleConfig {
    let c = core::CycleSlipConfig::default();
    (
        c.melbourne_wubbena_threshold_cycles,
        c.geometry_free_threshold_m,
        c.minimum_arc_length as u64,
        c.running_statistic_k_factor,
        c.maximum_gap_s,
    )
}

#[rustler::nif]
pub fn pp_cycle_state_default() -> CycleState {
    encode_state(core::SatelliteCycleSlipState::default())
}

#[rustler::nif]
pub fn pp_cycle_mw<'a>(env: Env<'a>, obs: Observation) -> Term<'a> {
    result(
        env,
        core::melbourne_wubbena_cycles(&observation(obs)).map_err(cycle_error),
    )
}

#[rustler::nif]
pub fn pp_cycle_gf<'a>(env: Env<'a>, obs: Observation) -> Term<'a> {
    result(
        env,
        core::geometry_free_m(&observation(obs)).map_err(cycle_error),
    )
}

#[rustler::nif]
pub fn pp_cycle_update_mw<'a>(
    env: Env<'a>,
    state: CycleState,
    obs: Observation,
    config: CycleConfig,
) -> Term<'a> {
    let mut state = cycle_state(state);
    result(
        env,
        core::update_melbourne_wubbena(&mut state, &observation(obs), cycle_config(config))
            .map(|v| (encode_state(state), v.melbourne_wubbena_cycles, v.slip))
            .map_err(cycle_error),
    )
}

#[rustler::nif]
pub fn pp_cycle_update_gf<'a>(
    env: Env<'a>,
    state: CycleState,
    obs: Observation,
    time: Option<f64>,
    epoch: ExactEpochTerm,
    config: CycleConfig,
) -> Term<'a> {
    let mut state = cycle_state(state);
    result(
        env,
        core::update_geometry_free(
            &mut state,
            &observation(obs),
            time,
            epoch.map(|resource| resource.epoch),
            cycle_config(config),
        )
        .map(|v| (encode_state(state), v.geometry_free_m, v.slip, v.reset))
        .map_err(cycle_error),
    )
}

#[rustler::nif]
pub fn pp_cycle_detect<'a>(env: Env<'a>, values: Vec<DualEpoch>, config: CycleConfig) -> Term<'a> {
    result(
        env,
        core::detect_cycle_slips(&epochs(values), cycle_config(config))
            .map(|rows| {
                rows.into_iter()
                    .map(|row| {
                        (
                            row.gap_time_s,
                            row.gap_epoch
                                .map(|epoch| ResourceArc::new(ExactEpochResource { epoch })),
                            row.observations
                                .into_iter()
                                .map(|o| {
                                    (
                                        o.satellite_id,
                                        o.slip,
                                        o.reasons.into_iter().map(reason).collect::<Vec<_>>(),
                                    )
                                })
                                .collect::<Vec<_>>(),
                        )
                    })
                    .collect::<Vec<_>>()
            })
            .map_err(cycle_error),
    )
}

fn slip_options(value: SlipOptions) -> CycleSlipOptions {
    let mut options = CycleSlipOptions::default();
    options.gf_threshold_m = value.0;
    options.mw_threshold_cycles = value.1;
    options.min_arc_gap_s = value.2;
    options
}

fn policy(value: &str) -> Option<core::CycleSlipPolicy> {
    match value {
        "error" => Some(core::CycleSlipPolicy::Error),
        "drop_satellite" => Some(core::CycleSlipPolicy::DropSatellite),
        "split_arc" => Some(core::CycleSlipPolicy::SplitArc),
        _ => None,
    }
}

#[derive(NifMap)]
struct PrepErrorTerm {
    kind: String,
    ambiguity_id: Option<String>,
    satellite_id: Option<String>,
    epoch_index: Option<u64>,
    count: Option<u64>,
    minimum: Option<u64>,
    mean_cycles: Option<f64>,
    fixed_cycles: Option<i64>,
    reasons: Vec<String>,
    reason: Option<String>,
    message: String,
}

fn prep_error(error: core::WideLanePrepError) -> PrepErrorTerm {
    let mut out = PrepErrorTerm {
        kind: String::new(),
        ambiguity_id: None,
        satellite_id: None,
        epoch_index: None,
        count: None,
        minimum: None,
        mean_cycles: None,
        fixed_cycles: None,
        reasons: Vec::new(),
        reason: None,
        message: String::new(),
    };
    match error {
        core::WideLanePrepError::CycleSlipDetected {
            satellite_id,
            epoch_index,
            reasons,
        } => {
            out.kind = "cycle_slip_detected".into();
            out.satellite_id = Some(satellite_id.clone());
            out.epoch_index = Some(epoch_index as u64);
            out.reasons = reasons
                .into_iter()
                .map(reason)
                .map(str::to_string)
                .collect();
            out.message = format!(
                "cycle slip detected for {satellite_id} at epoch {epoch_index}: {}",
                out.reasons.join(",")
            );
        }
        core::WideLanePrepError::WideLaneFailed {
            ambiguity_id,
            reason,
        } => {
            out.kind = "wide_lane_failed".into();
            out.ambiguity_id = Some(ambiguity_id.clone());
            out.reason = Some(reason.to_string());
            out.message = format!("wide-lane preparation failed for {ambiguity_id}: {reason}");
        }
        core::WideLanePrepError::TooFewWideLaneEpochs {
            ambiguity_id,
            count,
            minimum,
        } => {
            out.kind = "too_few_wide_lane_epochs".into();
            out.ambiguity_id = Some(ambiguity_id.clone());
            out.count = Some(count as u64);
            out.minimum = Some(minimum as u64);
            out.message =
                format!("too few wide-lane epochs for {ambiguity_id}: {count}, minimum {minimum}");
        }
        core::WideLanePrepError::WideLaneNotInteger {
            ambiguity_id,
            mean_cycles,
            fixed_cycles,
        } => {
            out.kind = "wide_lane_not_integer".into();
            out.ambiguity_id = Some(ambiguity_id.clone());
            out.mean_cycles = Some(mean_cycles);
            out.fixed_cycles = Some(fixed_cycles);
            out.message=format!("wide-lane mean for {ambiguity_id} is not integer: {mean_cycles}, candidate {fixed_cycles}");
        }
        core::WideLanePrepError::MissingWideLaneAmbiguity(id) => {
            out.kind = "missing_wide_lane_ambiguity".into();
            out.ambiguity_id = Some(id.clone());
            out.message = format!("missing wide-lane ambiguity {id}");
        }
        core::WideLanePrepError::InconsistentFrequencies(id) => {
            out.kind = "inconsistent_frequencies".into();
            out.ambiguity_id = Some(id.clone());
            out.message = format!("inconsistent frequencies for {id}");
        }
        core::WideLanePrepError::IonosphereFreeFailed {
            satellite_id,
            reason,
        } => {
            out.kind = "ionosphere_free_failed".into();
            out.satellite_id = Some(satellite_id.clone());
            out.reason = Some(reason.to_string());
            out.message =
                format!("ionosphere-free preparation failed for {satellite_id}: {reason}");
        }
    }
    out
}

#[rustler::nif]
pub fn pp_prep_cycle_slip_options_default() -> SlipOptions {
    let o = CycleSlipOptions::default();
    (o.gf_threshold_m, o.mw_threshold_cycles, o.min_arc_gap_s)
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn pp_prepare_widelane<'a>(
    env: Env<'a>,
    values: Vec<DualEpoch>,
    wide: PrepOptions,
    policy_name: String,
    slip: SlipOptions,
) -> Term<'a> {
    let Some(policy) = policy(&policy_name) else {
        return (atoms::error(), "unknown cycle-slip policy").encode(env);
    };
    result(
        env,
        core::prepare_widelane_fixed_epochs(
            &epochs(values),
            core::WideLanePrepOptions::new(wide.0 as usize, wide.1),
            policy,
            slip_options(slip),
        )
        .map_err(prep_error)
        .map(|v| {
            (
                v.epochs
                    .into_iter()
                    .map(|e| {
                        (
                            e.epoch_index as u64,
                            e.observations
                                .into_iter()
                                .map(|o| (o.satellite_id, o.ambiguity_id, o.code_m, o.phase_m))
                                .collect::<Vec<_>>(),
                        )
                    })
                    .collect::<Vec<_>>(),
                v.wavelengths_m.into_iter().collect::<Vec<_>>(),
                v.offsets_m.into_iter().collect::<Vec<_>>(),
                v.wide_lane_cycles.into_iter().collect::<Vec<_>>(),
                v.dropped_sats,
                v.split_arcs
                    .into_iter()
                    .map(|a| {
                        (
                            a.satellite_id,
                            a.ambiguity_id,
                            a.start_epoch_index as u64,
                            a.end_epoch_index as u64,
                            a.n_epochs as u64,
                        )
                    })
                    .collect::<Vec<_>>(),
            )
        }),
    )
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn pp_split_float_slips(
    values: Vec<FloatSlipEpoch>,
    slip: SlipOptions,
) -> Vec<Vec<(String, String)>> {
    let epochs = values
        .into_iter()
        .map(
            |(gap_time_s, gap_epoch, observations)| core::FloatCycleSlipEpoch {
                gap_time_s,
                gap_epoch: gap_epoch.map(|r| r.epoch),
                observations: observations
                    .into_iter()
                    .map(
                        |(satellite_id, ambiguity_id, raw)| core::FloatCycleSlipObservation {
                            satellite_id,
                            ambiguity_id,
                            raw: raw.map(observation),
                        },
                    )
                    .collect(),
            },
        )
        .collect::<Vec<_>>();
    core::split_float_cycle_slip_epochs(&epochs, slip_options(slip))
        .into_iter()
        .map(|e| {
            e.observations
                .into_iter()
                .map(|o| (o.satellite_id, o.ambiguity_id))
                .collect()
        })
        .collect()
}

fn residual(value: Residual) -> core::FloatResidual {
    core::FloatResidual {
        epoch_index: value.0 as usize,
        satellite_id: value.1,
        ambiguity_id: value.2,
        code_m: value.3,
        phase_m: value.4,
        code_weight: value.5 .0,
        phase_weight: value.5 .1,
    }
}
fn geometry(value: RaimGeometry) -> core::RaimGeometryRow {
    core::RaimGeometryRow {
        satellite_id: value.0,
        line_of_sight: sidereon_core::geometry::LineOfSight::new(
            value.1 .0, value.1 .1, value.1 .2,
        ),
    }
}
fn raim_config(value: RaimConfig) -> core::RaimConfig {
    let mut c = core::RaimConfig::default();
    c.false_alarm_probability = value.0;
    c.missed_detection_probability = value.1;
    c.measurement_sigma_m = value.2;
    c.chi_square_threshold = value.3;
    c
}
fn raim_status(value: core::RaimStatus) -> &'static str {
    match value {
        core::RaimStatus::Passed => "passed",
        core::RaimStatus::FaultDetected => "fault_detected",
        core::RaimStatus::NotEnoughRedundancy => "not_enough_redundancy",
    }
}
fn statistic(value: core::SatelliteTestStatistic) -> RaimStatistic {
    (
        value.satellite_id,
        value.code,
        value.phase,
        value.statistic,
        value.code_testable,
        value.phase_testable,
    )
}
fn raim_result(value: core::RaimResult) -> RaimResult {
    (
        raim_status(value.status),
        value.detected,
        value.test_statistic,
        value.threshold,
        value.redundancy as i64,
        value
            .satellite_statistics
            .into_iter()
            .map(statistic)
            .collect(),
        (value.most_likely_fault, value.hpl_m, value.vpl_m),
    )
}

#[rustler::nif]
pub fn pp_raim_config_default() -> RaimConfig {
    let c = core::RaimConfig::default();
    (
        c.false_alarm_probability,
        c.missed_detection_probability,
        c.measurement_sigma_m,
        c.chi_square_threshold,
    )
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn pp_raim_global<'a>(
    env: Env<'a>,
    rows: Vec<Residual>,
    n_states: u64,
    config: RaimConfig,
) -> Term<'a> {
    let rows = rows.into_iter().map(residual).collect::<Vec<_>>();
    result(
        env,
        core::raim::global_test(&rows, n_states as usize, raim_config(config))
            .map(raim_result)
            .map_err(raim_error),
    )
}
#[rustler::nif(schedule = "DirtyCpu")]
pub fn pp_raim_global_geometry<'a>(
    env: Env<'a>,
    rows: Vec<Residual>,
    lines: Vec<RaimGeometry>,
    config: RaimConfig,
) -> Term<'a> {
    let rows = rows.into_iter().map(residual).collect::<Vec<_>>();
    let lines = lines.into_iter().map(geometry).collect::<Vec<_>>();
    result(
        env,
        core::raim::global_test_with_geometry(&rows, &lines, raim_config(config))
            .map(raim_result)
            .map_err(raim_error),
    )
}
#[rustler::nif(schedule = "DirtyCpu")]
pub fn pp_raim_statistics<'a>(
    env: Env<'a>,
    rows: Vec<Residual>,
    lines: Vec<RaimGeometry>,
    config: RaimConfig,
) -> Term<'a> {
    let rows = rows.into_iter().map(residual).collect::<Vec<_>>();
    let lines = lines.into_iter().map(geometry).collect::<Vec<_>>();
    result(
        env,
        core::raim::per_satellite_statistics(&rows, &lines, raim_config(config))
            .map(|v| {
                (
                    v.statistics.into_iter().map(statistic).collect::<Vec<_>>(),
                    v.most_likely_fault,
                )
            })
            .map_err(raim_error),
    )
}
#[rustler::nif(schedule = "DirtyCpu")]
pub fn pp_raim_protection<'a>(
    env: Env<'a>,
    lines: Vec<RaimGeometry>,
    receiver: (f64, f64, f64),
    config: RaimConfig,
) -> Term<'a> {
    let lines = lines.into_iter().map(geometry).collect::<Vec<_>>();
    let receiver = sidereon_core::geometry::Wgs84Geodetic {
        lat_rad: receiver.0,
        lon_rad: receiver.1,
        height_m: receiver.2,
    };
    result(
        env,
        core::raim::protection_levels(&lines, receiver, raim_config(config))
            .map(|v| (v.hpl_m, v.vpl_m))
            .map_err(raim_error),
    )
}

fn kine_state(value: KinematicState) -> core::KinematicState {
    core::KinematicState {
        position_m: [value.0 .0, value.0 .1, value.0 .2],
        clock_m: value.1,
        ztd_residual_m: value.2,
        ambiguities_m: value.3.into_iter().collect(),
    }
}
fn kine_state_term(value: core::KinematicState) -> KinematicState {
    (
        (
            value.position_m[0],
            value.position_m[1],
            value.position_m[2],
        ),
        value.clock_m,
        value.ztd_residual_m,
        value.ambiguities_m.into_iter().collect(),
    )
}
fn kine_config(value: KinematicConfig) -> core::KinematicConfig {
    let motion = if value.2 .0 == "hold" {
        core::KinematicMotionModel::Hold
    } else {
        core::KinematicMotionModel::ConstantVelocity {
            velocity_m_s: [value.2 .1 .0, value.2 .1 .1, value.2 .1 .2],
        }
    };
    let position = if value.3 .0 == "random_walk" {
        core::KinematicPositionProcessNoise::RandomWalk {
            spectral_density_m2_s: value.3 .1,
        }
    } else {
        core::KinematicPositionProcessNoise::WhiteNoiseAcceleration {
            spectral_density_m2_s3: value.3 .1,
        }
    };
    let mut c = core::KinematicConfig::default();
    c.initial_state = kine_state(value.0);
    c.initial_covariance_m2 = value.1;
    c.motion = motion;
    c.process_noise = core::KinematicProcessNoise {
        position,
        clock_white_m2_s: value.3 .2,
        ztd_random_walk_m2_s: value.3 .3,
        ambiguity_hold_m2_s: value.3 .4,
    };
    c.new_ambiguity_variance_m2 = value.4;
    c.weights = core::MeasurementWeights {
        code: value.5 .0,
        phase: value.5 .1,
        elevation_weighting: value.5 .2,
    };
    c
}
fn kine_config_term(c: core::KinematicConfig) -> KinematicConfig {
    let motion = match c.motion {
        core::KinematicMotionModel::Hold => ("hold".to_string(), (0.0, 0.0, 0.0)),
        core::KinematicMotionModel::ConstantVelocity { velocity_m_s: v } => {
            ("constant_velocity".to_string(), (v[0], v[1], v[2]))
        }
    };
    let (kind, density) = match c.process_noise.position {
        core::KinematicPositionProcessNoise::RandomWalk {
            spectral_density_m2_s: v,
        } => ("random_walk", v),
        core::KinematicPositionProcessNoise::WhiteNoiseAcceleration {
            spectral_density_m2_s3: v,
        } => ("white_noise_acceleration", v),
    };
    (
        kine_state_term(c.initial_state),
        c.initial_covariance_m2,
        motion,
        (
            kind.to_string(),
            density,
            c.process_noise.clock_white_m2_s,
            c.process_noise.ztd_random_walk_m2_s,
            c.process_noise.ambiguity_hold_m2_s,
        ),
        c.new_ambiguity_variance_m2,
        (
            c.weights.code,
            c.weights.phase,
            c.weights.elevation_weighting,
        ),
    )
}
#[rustler::nif]
pub fn pp_kinematic_config_default() -> KinematicConfig {
    kine_config_term(core::KinematicConfig::default())
}

fn kinematic_error(error: core::KinematicSolveError) -> KinematicErrorTerm {
    let message = error.to_string();
    match error {
        core::KinematicSolveError::NoEphemeris {
            satellite_id,
            reason,
        } => (
            "no_ephemeris".to_string(),
            Some(satellite_id),
            None,
            reason.to_string(),
            message,
        ),
        core::KinematicSolveError::SingularGeometry => (
            "singular_geometry".to_string(),
            None,
            None,
            String::new(),
            message,
        ),
        core::KinematicSolveError::InvalidSolveOption { field, reason } => (
            "invalid_solve_option".to_string(),
            None,
            Some(field.to_string()),
            reason.to_string(),
            message,
        ),
        core::KinematicSolveError::InvalidInput { field, reason } => (
            "invalid_input".to_string(),
            None,
            Some(field.to_string()),
            reason.to_string(),
            message,
        ),
        core::KinematicSolveError::MissingCorrection {
            satellite_id,
            correction,
        } => (
            "missing_correction".to_string(),
            Some(satellite_id),
            None,
            correction.to_string(),
            message,
        ),
        core::KinematicSolveError::Ut1OutsideCoverage(reason) => (
            "ut1_outside_coverage".to_string(),
            None,
            None,
            reason.to_string(),
            message,
        ),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn pp_kinematic_predict<'a>(
    env: Env<'a>,
    state: KinematicState,
    covariance: Vec<Vec<f64>>,
    dt_s: f64,
    ids: Vec<String>,
    config: KinematicConfig,
) -> Term<'a> {
    let mut state = kine_state(state);
    let mut covariance = covariance;
    let config = kine_config(config);
    result(
        env,
        core::predict_kinematic_state(&mut state, &mut covariance, dt_s, &ids, &config)
            .map(|_| (kine_state_term(state), covariance))
            .map_err(kinematic_error),
    )
}
