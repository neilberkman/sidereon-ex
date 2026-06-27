//! Rustler boundary for RTK double-difference construction.
//!
//! The double-difference reference selection, pairing, dropped-satellite
//! accounting, and ambiguity-id algebra live in `sidereon_core::rtk`.
//! This module only decodes normalized Sidereon terms and encodes public tags.

use rustler::{Encoder, Env, Term};
use sidereon_core::carrier_phase::{CycleSlipOptions, SlipReason, FREQ_EPSILON_HZ};
use sidereon_core::combinations::IonosphereFreeError;
use sidereon_core::rtk::{
    apply_elevation_mask, baseline_reference_satellites, double_differences,
    estimate_wide_lane_ambiguities, hatch_smooth_baseline_code_epochs,
    prepare_cycle_slip_baseline_epochs, prepare_dual_cycle_slip_baseline_epochs,
    prepare_ionosphere_free_baseline_epochs, BaselineReferenceEpoch, BaselineReferenceSelection,
    CodeSmoothingEpoch, CodeSmoothingError, CodeSmoothingObservation, CycleSlipPolicy,
    CycleSlipPrepError, CycleSlipReceiver, CycleSlipSplitArc, DoubleDifferenceError,
    DualCycleSlipEpoch, DualCycleSlipObservation, DualEpoch, DualIonosphereFreeSetupEpoch,
    DualObservation, DualSatelliteObservation, ElevationMaskEpoch, IonosphereFreeBaselineError,
    Observation, ReferenceReport, ReferenceSelection, WideLaneError, WideLaneOptions,
};
use std::collections::BTreeMap;

type ObservationTerm = (String, String, f64, f64);
type ReferenceTerm = (String, String, Vec<(String, String)>);
type Vec3 = (f64, f64, f64);
type BaselineReferenceEpochTerm = (Vec<String>, Vec<(String, Vec3)>);
type ElevationMaskEpochTerm = Vec<(String, Vec3)>;
type CodeSmoothingObservationTerm = (String, String, f64, f64, Option<i64>);
type CodeSmoothingEpochTerm = (
    Vec<CodeSmoothingObservationTerm>,
    Vec<CodeSmoothingObservationTerm>,
);
type CycleSlipSplitArcTerm = (String, String, String, u64, u64, u64);
type DualCycleSlipObservationTerm = (String, DualObservationTerm, Option<i64>, Option<i64>);
type DualCycleSlipEpochTerm = (
    String,
    Option<f64>,
    Vec<DualCycleSlipObservationTerm>,
    Vec<DualCycleSlipObservationTerm>,
);
type DualCycleSlipOutputEpochTerm = (
    Vec<DualCycleSlipObservationTerm>,
    Vec<DualCycleSlipObservationTerm>,
);
type DualObservationTerm = (String, f64, f64, f64, f64, f64, f64);
type DualSatelliteTerm = (String, DualObservationTerm, DualObservationTerm);
type DualEpochTerm = Vec<DualSatelliteTerm>;
type DualIfSetupSatelliteTerm = (String, DualObservationTerm, DualObservationTerm);
type DualIfSetupEpochTerm = (
    f64,
    f64,
    Vec<(String, Vec3)>,
    Vec<(String, Vec3)>,
    Vec<DualIfSetupSatelliteTerm>,
);
type IfEpochTerm = (u64, Vec<String>, Vec<ObservationTerm>, Vec<ObservationTerm>);

mod atoms {
    rustler::atoms! {
        ok,
        error,
        duplicate_observation,
        too_few_common_satellites,
        no_common_reference_satellite,
        reference_satellite_missing,
        reference_satellite_single_system,
        reference_satellite_missing_system,
        invalid_option,
        reference_satellite_id,
        wide_lane_failed,
        equal_frequencies,
        invalid_frequency,
        unknown_system,
        unknown_band,
        too_few_wide_lane_epochs,
        wide_lane_not_integer,
        no_epochs,
        inconsistent_frequencies,
        ionosphere_free_failed,
        hatch_window_cap,
        on_cycle_slip,
        invalid_input,
        missing_satellite_position,
        invalid_observation
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn rtk_double_differences<'a>(
    env: Env<'a>,
    base_observations: Vec<ObservationTerm>,
    rover_observations: Vec<ObservationTerm>,
    reference: ReferenceTerm,
) -> Term<'a> {
    let Some(reference) = decode_reference(reference) else {
        return (
            atoms::error(),
            (atoms::invalid_option(), atoms::reference_satellite_id()),
        )
            .encode(env);
    };
    let base = decode_observations(base_observations);
    let rover = decode_observations(rover_observations);

    match double_differences(&base, &rover, reference) {
        Ok(result) => {
            let reference = encode_reference_report(result.reference_satellite_id);
            let double_differences = result
                .double_differences
                .into_iter()
                .map(|dd| {
                    (
                        dd.satellite_id,
                        dd.reference_satellite_id,
                        dd.ambiguity_id,
                        dd.code_m,
                        dd.phase_m,
                    )
                })
                .collect::<Vec<_>>();
            (
                atoms::ok(),
                (reference, double_differences, result.dropped_sats),
            )
                .encode(env)
        }
        Err(err) => (atoms::error(), encode_error(env, err)).encode(env),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn rtk_baseline_reference_satellites<'a>(
    env: Env<'a>,
    base_m: Vec3,
    epochs: Vec<BaselineReferenceEpochTerm>,
    reference: ReferenceTerm,
) -> Term<'a> {
    let Some(reference) = decode_baseline_reference(reference) else {
        return (
            atoms::error(),
            (atoms::invalid_option(), atoms::reference_satellite_id()),
        )
            .encode(env);
    };

    match baseline_reference_satellites(vec3(base_m), &decode_baseline_epochs(epochs), reference) {
        Ok(refs) => (atoms::ok(), refs.into_iter().collect::<Vec<_>>()).encode(env),
        Err(err) => (atoms::error(), encode_error(env, err)).encode(env),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn rtk_apply_elevation_mask<'a>(
    env: Env<'a>,
    base_m: Vec3,
    epochs: Vec<ElevationMaskEpochTerm>,
    mask_deg: f64,
) -> Term<'a> {
    let result = match apply_elevation_mask(
        vec3(base_m),
        &decode_elevation_mask_epochs(epochs),
        mask_deg,
    ) {
        Ok(result) => result,
        Err(err) => return (atoms::error(), encode_error(env, err)).encode(env),
    };
    let kept = result
        .epochs
        .into_iter()
        .map(|epoch| epoch.kept_satellite_ids)
        .collect::<Vec<_>>();
    (atoms::ok(), (kept, result.masked_satellite_ids)).encode(env)
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn rtk_smooth_code_epochs<'a>(
    env: Env<'a>,
    epochs: Vec<CodeSmoothingEpochTerm>,
    hatch_window_cap: u64,
) -> Term<'a> {
    match hatch_smooth_baseline_code_epochs(
        &decode_code_smoothing_epochs(epochs),
        hatch_window_cap as usize,
    ) {
        Ok(epochs) => (atoms::ok(), encode_code_smoothing_epochs(epochs)).encode(env),
        Err(err) => (atoms::error(), encode_code_smoothing_error(env, err)).encode(env),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn rtk_prepare_cycle_slip_epochs<'a>(
    env: Env<'a>,
    epochs: Vec<CodeSmoothingEpochTerm>,
    policy: String,
) -> Term<'a> {
    let Some(policy) = decode_cycle_slip_policy(&policy) else {
        return (
            atoms::error(),
            (atoms::invalid_option(), atoms::on_cycle_slip()),
        )
            .encode(env);
    };

    match prepare_cycle_slip_baseline_epochs(&decode_code_smoothing_epochs(epochs), policy) {
        Ok(result) => (
            atoms::ok(),
            (
                encode_code_smoothing_epochs(result.epochs),
                result.dropped_sats,
                encode_cycle_slip_split_arcs(result.split_arcs),
            ),
        )
            .encode(env),
        Err(err) => (atoms::error(), encode_cycle_slip_error(env, err)).encode(env),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn rtk_prepare_dual_cycle_slip_epochs<'a>(
    env: Env<'a>,
    epochs: Vec<DualCycleSlipEpochTerm>,
    policy: String,
    gf_threshold_m: f64,
    mw_threshold_cycles: f64,
    min_arc_gap_s: f64,
) -> Term<'a> {
    let Some(policy) = decode_cycle_slip_policy(&policy) else {
        return (
            atoms::error(),
            (atoms::invalid_option(), atoms::on_cycle_slip()),
        )
            .encode(env);
    };

    let options = CycleSlipOptions {
        gf_threshold_m,
        mw_threshold_cycles,
        min_arc_gap_s,
    };

    let decoded_epochs = decode_dual_cycle_slip_epochs(epochs);

    // The hardened cycle-slip detector folds equal carrier frequencies into a
    // generic invalid-input error (and a related core path can abort on the same
    // degenerate input), which hides the per-satellite wide-lane failure the
    // baseline solver reports. Detect equal frequencies here, before the core
    // call, and surface them as the wide-lane failure for the affected
    // satellite so the dual-frequency input is tagged precisely.
    if let Some(satellite_id) = equal_frequency_satellite(&decoded_epochs) {
        return (
            atoms::error(),
            (
                atoms::wide_lane_failed(),
                satellite_id,
                atoms::equal_frequencies(),
            ),
        )
            .encode(env);
    }

    match prepare_dual_cycle_slip_baseline_epochs(&decoded_epochs, policy, options) {
        Ok(result) => (
            atoms::ok(),
            (
                encode_dual_cycle_slip_epochs(result.epochs),
                result.dropped_sats,
                encode_cycle_slip_split_arcs(result.split_arcs),
            ),
        )
            .encode(env),
        Err(err) => (atoms::error(), encode_cycle_slip_error(env, err)).encode(env),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn rtk_estimate_wide_lanes<'a>(
    env: Env<'a>,
    epochs: Vec<DualEpochTerm>,
    reference_satellite_id: String,
    min_epochs: u64,
    tolerance_cycles: f64,
    skip_short_fragments: bool,
) -> Term<'a> {
    let options = WideLaneOptions {
        min_epochs: min_epochs as usize,
        tolerance_cycles,
        skip_short_fragments,
    };

    match estimate_wide_lane_ambiguities(
        &decode_dual_epochs(epochs),
        &reference_satellite_id,
        options,
    ) {
        Ok(fixed) => (atoms::ok(), fixed.into_iter().collect::<Vec<_>>()).encode(env),
        Err(err) => (atoms::error(), encode_wide_lane_error(env, err)).encode(env),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn rtk_ionosphere_free_baseline_epochs<'a>(
    env: Env<'a>,
    base_m: Vec3,
    initial_baseline_m: Vec3,
    epochs: Vec<DualIfSetupEpochTerm>,
    reference_satellite_id: String,
    wide_lane_cycles: Vec<(String, i64)>,
    apply_troposphere: bool,
) -> Term<'a> {
    let wide_lane_cycles = wide_lane_cycles.into_iter().collect::<BTreeMap<_, _>>();
    match prepare_ionosphere_free_baseline_epochs(
        vec3(base_m),
        vec3(initial_baseline_m),
        &decode_dual_if_setup_epochs(epochs),
        &reference_satellite_id,
        &wide_lane_cycles,
        apply_troposphere,
    ) {
        Ok(result) => {
            let epochs = result
                .epochs
                .into_iter()
                .map(|epoch| {
                    (
                        epoch.epoch_index as u64,
                        epoch.satellite_ids,
                        encode_observations(epoch.base_observations),
                        encode_observations(epoch.rover_observations),
                    )
                })
                .collect::<Vec<IfEpochTerm>>();
            (
                atoms::ok(),
                (
                    epochs,
                    result.wavelengths_m.into_iter().collect::<Vec<_>>(),
                    result.offsets_m.into_iter().collect::<Vec<_>>(),
                ),
            )
                .encode(env)
        }
        Err(err) => (atoms::error(), encode_if_error(env, err)).encode(env),
    }
}

fn decode_observations(observations: Vec<ObservationTerm>) -> Vec<Observation> {
    observations
        .into_iter()
        .map(
            |(satellite_id, ambiguity_id, code_m, phase_m)| Observation {
                satellite_id,
                ambiguity_id,
                code_m,
                phase_m,
            },
        )
        .collect()
}

fn decode_baseline_epochs(epochs: Vec<BaselineReferenceEpochTerm>) -> Vec<BaselineReferenceEpoch> {
    epochs
        .into_iter()
        .map(
            |(available_satellite_ids, positions)| BaselineReferenceEpoch {
                available_satellite_ids,
                satellite_positions_m: positions
                    .into_iter()
                    .map(|(sat, pos)| (sat, vec3(pos)))
                    .collect(),
            },
        )
        .collect()
}

fn decode_elevation_mask_epochs(epochs: Vec<ElevationMaskEpochTerm>) -> Vec<ElevationMaskEpoch> {
    epochs
        .into_iter()
        .map(|positions| ElevationMaskEpoch {
            satellite_positions_m: positions
                .into_iter()
                .map(|(sat, position)| (sat, vec3(position)))
                .collect(),
        })
        .collect()
}

fn decode_code_smoothing_epochs(epochs: Vec<CodeSmoothingEpochTerm>) -> Vec<CodeSmoothingEpoch> {
    epochs
        .into_iter()
        .map(
            |(base_observations, rover_observations)| CodeSmoothingEpoch {
                base_observations: decode_code_smoothing_observations(base_observations),
                rover_observations: decode_code_smoothing_observations(rover_observations),
            },
        )
        .collect()
}

fn decode_code_smoothing_observations(
    observations: Vec<CodeSmoothingObservationTerm>,
) -> Vec<CodeSmoothingObservation> {
    observations
        .into_iter()
        .map(
            |(satellite_id, ambiguity_id, code_m, phase_m, lli)| CodeSmoothingObservation {
                satellite_id,
                ambiguity_id,
                code_m,
                phase_m,
                lli,
            },
        )
        .collect()
}

fn encode_code_smoothing_epochs(epochs: Vec<CodeSmoothingEpoch>) -> Vec<CodeSmoothingEpochTerm> {
    epochs
        .into_iter()
        .map(|epoch| {
            (
                encode_code_smoothing_observations(epoch.base_observations),
                encode_code_smoothing_observations(epoch.rover_observations),
            )
        })
        .collect()
}

fn encode_code_smoothing_observations(
    observations: Vec<CodeSmoothingObservation>,
) -> Vec<CodeSmoothingObservationTerm> {
    observations
        .into_iter()
        .map(|obs| {
            (
                obs.satellite_id,
                obs.ambiguity_id,
                obs.code_m,
                obs.phase_m,
                obs.lli,
            )
        })
        .collect()
}

/// The first satellite (scanning base then rover observations, epoch by epoch)
/// whose two carrier frequencies are degenerate. The wide-lane and cycle-slip
/// combinations both divide by `f1 - f2`, so equal frequencies cannot form a
/// wide-lane and must be reported per satellite rather than as a generic input
/// error.
fn equal_frequency_satellite(epochs: &[DualCycleSlipEpoch]) -> Option<String> {
    for epoch in epochs {
        for obs in epoch
            .base_observations
            .iter()
            .chain(epoch.rover_observations.iter())
        {
            if has_equal_frequencies(obs.f1_hz, obs.f2_hz) {
                return Some(obs.satellite_id.clone());
            }
        }
    }
    None
}

/// Whether two carrier frequencies are positive, finite, and closer together
/// than the core's wide-lane denominator tolerance (the EqualFrequencies case).
fn has_equal_frequencies(f1_hz: f64, f2_hz: f64) -> bool {
    f1_hz.is_finite()
        && f2_hz.is_finite()
        && f1_hz > 0.0
        && f2_hz > 0.0
        && (f1_hz - f2_hz).abs() < FREQ_EPSILON_HZ
}

fn decode_dual_cycle_slip_epochs(epochs: Vec<DualCycleSlipEpochTerm>) -> Vec<DualCycleSlipEpoch> {
    epochs
        .into_iter()
        .map(
            |(epoch_sort_key, gap_time_s, base_observations, rover_observations)| {
                DualCycleSlipEpoch {
                    epoch_sort_key,
                    gap_time_s,
                    base_observations: decode_dual_cycle_slip_observations(base_observations),
                    rover_observations: decode_dual_cycle_slip_observations(rover_observations),
                }
            },
        )
        .collect()
}

fn decode_dual_cycle_slip_observations(
    observations: Vec<DualCycleSlipObservationTerm>,
) -> Vec<DualCycleSlipObservation> {
    observations
        .into_iter()
        .map(|(satellite_id, observation, lli1, lli2)| {
            let observation = decode_dual_observation(observation);
            DualCycleSlipObservation {
                satellite_id,
                ambiguity_id: observation.ambiguity_id,
                p1_m: observation.p1_m,
                p2_m: observation.p2_m,
                phi1_cycles: observation.phi1_cycles,
                phi2_cycles: observation.phi2_cycles,
                f1_hz: observation.f1_hz,
                f2_hz: observation.f2_hz,
                lli1,
                lli2,
            }
        })
        .collect()
}

fn encode_dual_cycle_slip_epochs(
    epochs: Vec<DualCycleSlipEpoch>,
) -> Vec<DualCycleSlipOutputEpochTerm> {
    epochs
        .into_iter()
        .map(|epoch| {
            (
                encode_dual_cycle_slip_observations(epoch.base_observations),
                encode_dual_cycle_slip_observations(epoch.rover_observations),
            )
        })
        .collect()
}

fn encode_dual_cycle_slip_observations(
    observations: Vec<DualCycleSlipObservation>,
) -> Vec<DualCycleSlipObservationTerm> {
    observations
        .into_iter()
        .map(|obs| {
            (
                obs.satellite_id,
                (
                    obs.ambiguity_id,
                    obs.p1_m,
                    obs.p2_m,
                    obs.phi1_cycles,
                    obs.phi2_cycles,
                    obs.f1_hz,
                    obs.f2_hz,
                ),
                obs.lli1,
                obs.lli2,
            )
        })
        .collect()
}

fn decode_cycle_slip_policy(policy: &str) -> Option<CycleSlipPolicy> {
    match policy {
        "error" => Some(CycleSlipPolicy::Error),
        "drop_satellite" => Some(CycleSlipPolicy::DropSatellite),
        "split_arc" => Some(CycleSlipPolicy::SplitArc),
        _ => None,
    }
}

fn encode_cycle_slip_split_arcs(arcs: Vec<CycleSlipSplitArc>) -> Vec<CycleSlipSplitArcTerm> {
    arcs.into_iter()
        .map(|arc| {
            (
                encode_cycle_slip_receiver(arc.receiver),
                arc.satellite_id,
                arc.ambiguity_id,
                arc.start_epoch_index as u64,
                arc.end_epoch_index as u64,
                arc.n_epochs as u64,
            )
        })
        .collect()
}

fn encode_observations(observations: Vec<Observation>) -> Vec<ObservationTerm> {
    observations
        .into_iter()
        .map(|obs| (obs.satellite_id, obs.ambiguity_id, obs.code_m, obs.phase_m))
        .collect()
}

fn decode_dual_epochs(epochs: Vec<DualEpochTerm>) -> Vec<DualEpoch> {
    epochs
        .into_iter()
        .map(|observations| DualEpoch {
            observations: observations
                .into_iter()
                .map(decode_dual_satellite)
                .collect(),
        })
        .collect()
}

fn decode_dual_if_setup_epochs(
    epochs: Vec<DualIfSetupEpochTerm>,
) -> Vec<DualIonosphereFreeSetupEpoch> {
    epochs
        .into_iter()
        .map(
            |(
                jd_whole,
                jd_fraction,
                base_satellite_positions,
                rover_satellite_positions,
                observations,
            )| DualIonosphereFreeSetupEpoch {
                jd_whole,
                jd_fraction,
                base_satellite_positions_m: base_satellite_positions
                    .into_iter()
                    .map(|(sat, position)| (sat, vec3(position)))
                    .collect(),
                rover_satellite_positions_m: rover_satellite_positions
                    .into_iter()
                    .map(|(sat, position)| (sat, vec3(position)))
                    .collect(),
                observations: observations
                    .into_iter()
                    .map(decode_dual_if_setup_satellite)
                    .collect(),
            },
        )
        .collect()
}

fn decode_dual_satellite(term: DualSatelliteTerm) -> DualSatelliteObservation {
    let (satellite_id, base, rover) = term;
    DualSatelliteObservation {
        satellite_id,
        base: decode_dual_observation(base),
        rover: decode_dual_observation(rover),
    }
}

fn decode_dual_if_setup_satellite(term: DualIfSetupSatelliteTerm) -> DualSatelliteObservation {
    let (satellite_id, base, rover) = term;
    DualSatelliteObservation {
        satellite_id,
        base: decode_dual_observation(base),
        rover: decode_dual_observation(rover),
    }
}

fn decode_dual_observation(term: DualObservationTerm) -> DualObservation {
    let (ambiguity_id, p1_m, p2_m, phi1_cycles, phi2_cycles, f1_hz, f2_hz) = term;
    DualObservation {
        ambiguity_id,
        p1_m,
        p2_m,
        phi1_cycles,
        phi2_cycles,
        f1_hz,
        f2_hz,
    }
}

fn decode_reference(reference: ReferenceTerm) -> Option<ReferenceSelection> {
    let (mode, satellite_id, refs) = reference;
    match mode.as_str() {
        "auto" => Some(ReferenceSelection::Auto),
        "satellite" => Some(ReferenceSelection::Satellite(satellite_id)),
        "per_system" => Some(ReferenceSelection::PerSystem(
            refs.into_iter().collect::<BTreeMap<_, _>>(),
        )),
        _ => None,
    }
}

fn decode_baseline_reference(reference: ReferenceTerm) -> Option<BaselineReferenceSelection> {
    let (mode, satellite_id, refs) = reference;
    match mode.as_str() {
        "auto" => Some(BaselineReferenceSelection::Auto),
        "satellite" => Some(BaselineReferenceSelection::Satellite(satellite_id)),
        "per_system" => Some(BaselineReferenceSelection::PerSystem(
            refs.into_iter().collect::<BTreeMap<_, _>>(),
        )),
        _ => None,
    }
}

fn encode_reference_report(report: ReferenceReport) -> ReferenceTerm {
    match report {
        ReferenceReport::Satellite(satellite_id) => {
            ("satellite".to_string(), satellite_id, Vec::new())
        }
        ReferenceReport::PerSystem(refs) => (
            "per_system".to_string(),
            String::new(),
            refs.into_iter().collect(),
        ),
    }
}

fn encode_error<'a>(env: Env<'a>, err: DoubleDifferenceError) -> Term<'a> {
    match err {
        DoubleDifferenceError::InvalidInput { .. } => atoms::invalid_input().encode(env),
        DoubleDifferenceError::MissingSatellitePosition(sat) => {
            (atoms::missing_satellite_position(), sat).encode(env)
        }
        DoubleDifferenceError::DuplicateObservation(sat) => {
            (atoms::duplicate_observation(), sat).encode(env)
        }
        DoubleDifferenceError::TooFewCommonSatellites { count, minimum } => (
            atoms::too_few_common_satellites(),
            count as u64,
            minimum as u64,
        )
            .encode(env),
        DoubleDifferenceError::NoCommonReferenceSatellite(system) => {
            (atoms::no_common_reference_satellite(), system).encode(env)
        }
        DoubleDifferenceError::ReferenceSatelliteMissing(sat) => {
            (atoms::reference_satellite_missing(), sat).encode(env)
        }
        DoubleDifferenceError::ReferenceSatelliteSingleSystem(sat) => {
            (atoms::reference_satellite_single_system(), sat).encode(env)
        }
        DoubleDifferenceError::ReferenceSatelliteMissingSystem(system) => {
            (atoms::reference_satellite_missing_system(), system).encode(env)
        }
        DoubleDifferenceError::InvalidReferenceOption => {
            (atoms::invalid_option(), atoms::reference_satellite_id()).encode(env)
        }
    }
}

fn vec3(v: Vec3) -> [f64; 3] {
    [v.0, v.1, v.2]
}

fn encode_code_smoothing_error<'a>(env: Env<'a>, err: CodeSmoothingError) -> Term<'a> {
    match err {
        CodeSmoothingError::InvalidWindowCap => {
            (atoms::invalid_option(), atoms::hatch_window_cap()).encode(env)
        }
    }
}

fn encode_cycle_slip_error<'a>(env: Env<'a>, err: CycleSlipPrepError) -> Term<'a> {
    match err {
        CycleSlipPrepError::InvalidInput { .. } => atoms::invalid_input().encode(env),
        CycleSlipPrepError::CycleSlipDetected {
            receiver,
            satellite_id,
            epoch_index,
            reasons,
        } => (
            "cycle_slip_detected".to_string(),
            encode_cycle_slip_receiver(receiver),
            satellite_id,
            epoch_index as u64,
            reasons
                .into_iter()
                .map(encode_cycle_slip_reason)
                .collect::<Vec<String>>(),
        )
            .encode(env),
    }
}

fn encode_cycle_slip_receiver(receiver: CycleSlipReceiver) -> String {
    match receiver {
        CycleSlipReceiver::Base => "base".to_string(),
        CycleSlipReceiver::Rover => "rover".to_string(),
    }
}

fn encode_cycle_slip_reason(reason: SlipReason) -> String {
    match reason {
        SlipReason::Lli => "lli".to_string(),
        SlipReason::DataGap => "data_gap".to_string(),
        SlipReason::GeometryFree => "geometry_free".to_string(),
        SlipReason::MelbourneWubbena => "melbourne_wubbena".to_string(),
    }
}

fn encode_wide_lane_error<'a>(env: Env<'a>, err: WideLaneError) -> Term<'a> {
    match err {
        WideLaneError::InvalidInput { .. } => atoms::invalid_input().encode(env),
        WideLaneError::ReferenceSatelliteMissing(sat) => {
            (atoms::reference_satellite_missing(), sat).encode(env)
        }
        WideLaneError::WideLaneFailed { satellite_id, .. } => (
            atoms::wide_lane_failed(),
            satellite_id,
            atoms::equal_frequencies(),
        )
            .encode(env),
        WideLaneError::TooFewWideLaneEpochs {
            ambiguity_id,
            count,
            minimum,
        } => (
            atoms::too_few_wide_lane_epochs(),
            ambiguity_id,
            count as u64,
            minimum as u64,
        )
            .encode(env),
        WideLaneError::WideLaneNotInteger {
            ambiguity_id,
            mean_cycles,
            fixed_cycles,
        } => (
            atoms::wide_lane_not_integer(),
            ambiguity_id,
            mean_cycles,
            fixed_cycles,
        )
            .encode(env),
    }
}

fn encode_if_error<'a>(env: Env<'a>, err: IonosphereFreeBaselineError) -> Term<'a> {
    match err {
        IonosphereFreeBaselineError::InvalidInput { .. } => atoms::invalid_input().encode(env),
        IonosphereFreeBaselineError::NoEpochs => atoms::no_epochs().encode(env),
        IonosphereFreeBaselineError::InconsistentFrequencies(ambiguity_id) => {
            (atoms::inconsistent_frequencies(), ambiguity_id).encode(env)
        }
        IonosphereFreeBaselineError::NarrowLaneFailed(reason) => {
            iono_error_atom(reason).encode(env)
        }
        IonosphereFreeBaselineError::IonosphereFreeFailed {
            satellite_id,
            reason,
        } => (
            atoms::ionosphere_free_failed(),
            satellite_id,
            iono_error_atom(reason),
        )
            .encode(env),
    }
}

fn iono_error_atom(reason: IonosphereFreeError) -> rustler::Atom {
    match reason {
        IonosphereFreeError::EqualFrequencies => atoms::equal_frequencies(),
        IonosphereFreeError::InvalidFrequency => atoms::invalid_frequency(),
        IonosphereFreeError::UnknownSystem(_) => atoms::unknown_system(),
        IonosphereFreeError::UnknownBand { .. } => atoms::unknown_band(),
        IonosphereFreeError::InvalidObservation => atoms::invalid_observation(),
    }
}
