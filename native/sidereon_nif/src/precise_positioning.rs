//! Rustler boundary for static multi-epoch PPP float positioning.
//!
//! The solver and range-correction algebra live in
//! `sidereon_core::precise_positioning`; this module decodes Sidereon'
//! normalized epoch/option terms and encodes the unchanged public solution
//! fields.

use crate::sp3::Sp3Resource;
use crate::strategy::decode_strategy;
use rustler::{Encoder, Env, Error, NifResult, ResourceArc, Term};
use sidereon_core::estimation::{
    estimate, EstimateError, EstimateInput, EstimateOptions, EstimateOutput, Technique,
};
use sidereon_core::observables::j2000_seconds_from_split;
use sidereon_core::ppp_corrections as ppp;
use sidereon_core::precise_positioning as core;
use sidereon_core::{GnssSatelliteId, GnssSystem};
use std::collections::BTreeMap;

type Vec3 = (f64, f64, f64);
type DateTuple = (i32, i32, i32);
type TimeTuple = (i32, i32, i32, i32);
type DateTimeTuple = (DateTuple, TimeTuple);
type ObservationTerm = (String, String, f64, f64, f64, f64);
type EpochTerm = (DateTimeTuple, f64, f64, Vec<ObservationTerm>);
type InitialStateTerm = (Vec3, Vec<f64>, Vec<(String, f64)>, Option<f64>);
type WeightsTerm = (f64, f64, bool);
type SolveOptionsTerm = (u64, f64, f64, f64, f64);
type TropoTerm = (bool, bool, f64, f64, f64);
type FixedAmbiguityTerm = (Vec<(String, f64)>, Vec<(String, f64)>, f64);
type SlipOptionsTerm = (f64, f64, f64);
type WideLanePrepOptionsTerm = (u64, f64);
type DualFrequencyEpochTerm = (Option<f64>, Vec<DualFrequencyObservationTerm>);
type FloatCycleSlipObservationTerm = (String, String, Option<DualFrequencyObservationTerm>);
type FloatCycleSlipEpochTerm = (Option<f64>, Vec<FloatCycleSlipObservationTerm>);
type ReceiverFrequencyTerm = (String, Vec3, Vec<(Option<f64>, f64, f64)>);
type ReceiverAntennaTerm = (String, f64, String, f64, Vec<ReceiverFrequencyTerm>);
type SatelliteClockTerm = Vec<(String, Vec<(f64, f64)>)>;
type SatelliteFrequencyTerm = (String, Vec3, Vec<(f64, f64)>);
type SatelliteAntennaTerm = (
    String,
    Option<DateTimeTuple>,
    Option<DateTimeTuple>,
    Vec<SatelliteFrequencyTerm>,
);
type SatelliteAntennaOptionsTerm = (String, f64, String, f64, Vec<SatelliteAntennaTerm>);
type CorrectionsTerm = (
    bool,
    Option<SatelliteClockTerm>,
    Option<ReceiverAntennaTerm>,
    bool,
    bool,
    Option<SatelliteAntennaOptionsTerm>,
);

#[derive(Debug, Clone, rustler::NifMap)]
struct DualFrequencyObservationTerm {
    satellite_id: String,
    p1_m: f64,
    p2_m: f64,
    phi1_cyc: f64,
    phi2_cyc: f64,
    f1_hz: f64,
    f2_hz: f64,
    lli1: Option<i64>,
    lli2: Option<i64>,
}

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
        on_cycle_slip,
        cycle_slip_detected,
        wide_lane_failed,
        too_few_wide_lane_epochs,
        wide_lane_not_integer,
        missing_wide_lane_ambiguity,
        inconsistent_frequencies,
        ionosphere_free_failed,
        equal_frequencies,
        invalid_frequency,
        unknown_system,
        unknown_band,
        lli,
        geometry_free,
        melbourne_wubbena,
        data_gap,
        invalid_observation,
        invalid_threshold,
        invalid_clock_count,
        invalid_solve_option,
        invalid_input
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
pub fn precise_positioning_solve_float_epochs<'a>(
    env: Env<'a>,
    handle: ResourceArc<Sp3Resource>,
    epochs: Vec<EpochTerm>,
    initial: InitialStateTerm,
    weights: WeightsTerm,
    solve_options: SolveOptionsTerm,
    tropo: TropoTerm,
    corrections: CorrectionsTerm,
    residual_screen: bool,
    strategy: Term<'a>,
) -> NifResult<Term<'a>> {
    let epochs = decode_epochs(epochs)?;
    let initial = decode_initial(initial);
    let corrections = decode_corrections(corrections)?;
    let strategy = decode_strategy(strategy)?;
    let ppp_lookup = core::build_ppp_lookup(
        &handle.sp3,
        &epochs,
        initial.position_m,
        &corrections.ppp_options,
    )
    .map_err(crate::errors::invalid_input)?;
    let range_corrections = core::RangeCorrections {
        receiver_antenna: corrections.receiver_antenna,
        sat_clock_relativity: corrections.sat_clock_relativity,
        satellite_clock: corrections.satellite_clock,
        ppp: ppp_lookup,
    };
    // Drive the shared estimate() selector: Reference is byte-identical to the
    // legacy solve_float_epochs path, Canonical selects the owned Cholesky
    // square-root-information solve on the dense weighted PPP normal system.
    let result = match estimate(
        EstimateInput::PppFloat {
            source: &handle.sp3,
            epochs: &epochs,
            initial_state: initial,
            config: core::FloatSolveConfig {
                weights: decode_weights(weights),
                tropo: decode_tropo(tropo)?,
                corrections: range_corrections,
                opts: decode_solve_options(solve_options),
                residual_screen,
            },
        },
        EstimateOptions::new(strategy.strategy_id(Technique::Ppp)),
    ) {
        Ok(EstimateOutput::PppFloat(solution)) => Ok(*solution),
        Err(EstimateError::PppFloat(err)) => Err(err),
        Ok(_) | Err(_) => {
            unreachable!("a PPP float input yields a PPP float solution or a PPP float error")
        }
    };
    Ok(encode_result(env, result))
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
        core::FloatSolveConfig {
            weights: decode_weights(weights),
            tropo: decode_tropo(tropo)?,
            corrections: core::RangeCorrections {
                receiver_antenna: corrections.receiver_antenna,
                sat_clock_relativity: corrections.sat_clock_relativity,
                satellite_clock: corrections.satellite_clock,
                ppp: core::PppCorrectionLookup::default(),
            },
            opts: decode_solve_options(solve_options),
            residual_screen: false,
        },
    );
    Ok(encode_result(env, result))
}

#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
pub fn precise_positioning_solve_fixed_epochs<'a>(
    env: Env<'a>,
    handle: ResourceArc<Sp3Resource>,
    epochs: Vec<EpochTerm>,
    initial: InitialStateTerm,
    weights: WeightsTerm,
    solve_options: SolveOptionsTerm,
    tropo: TropoTerm,
    corrections: CorrectionsTerm,
    residual_screen: bool,
    ambiguity: FixedAmbiguityTerm,
    strategy: Term<'a>,
) -> NifResult<Term<'a>> {
    let epochs = decode_epochs(epochs)?;
    let initial = decode_initial(initial);
    let corrections = decode_corrections(corrections)?;
    let strategy = decode_strategy(strategy)?;
    let options = EstimateOptions::new(strategy.strategy_id(Technique::Ppp));
    let float_ppp = core::build_ppp_lookup(
        &handle.sp3,
        &epochs,
        initial.position_m,
        &corrections.ppp_options,
    )
    .map_err(crate::errors::invalid_input)?;
    // Both the float seed and the integer-fixed re-solve run under the selected
    // strategy, so canonical PPP fixes on its own canonical float solution.
    let float_result = match estimate(
        EstimateInput::PppFloat {
            source: &handle.sp3,
            epochs: &epochs,
            initial_state: initial,
            config: core::FloatSolveConfig {
                weights: decode_weights(weights),
                tropo: decode_tropo(tropo)?,
                corrections: core::RangeCorrections {
                    receiver_antenna: corrections.receiver_antenna.clone(),
                    sat_clock_relativity: corrections.sat_clock_relativity,
                    satellite_clock: corrections.satellite_clock.clone(),
                    ppp: float_ppp,
                },
                opts: decode_solve_options(solve_options),
                residual_screen,
            },
        },
        options,
    ) {
        Ok(EstimateOutput::PppFloat(solution)) => Ok(*solution),
        Err(EstimateError::PppFloat(err)) => Err(err),
        Ok(_) | Err(_) => {
            unreachable!("a PPP float input yields a PPP float solution or a PPP float error")
        }
    };
    let float_solution = match float_result {
        Ok(solution) => solution,
        Err(err) => {
            return Ok(encode_fixed_result(
                env,
                Err(core::FixedSolveError::Float(err)),
            ))
        }
    };
    let fixed_ppp = core::build_ppp_lookup(
        &handle.sp3,
        &epochs,
        float_solution.position_m,
        &corrections.ppp_options,
    )
    .map_err(crate::errors::invalid_input)?;
    let fixed_result = match estimate(
        EstimateInput::PppFixed {
            source: &handle.sp3,
            epochs: &epochs,
            float_solution,
            config: core::FixedSolveConfig {
                weights: decode_weights(weights),
                tropo: decode_tropo(tropo)?,
                corrections: core::RangeCorrections {
                    receiver_antenna: corrections.receiver_antenna,
                    sat_clock_relativity: corrections.sat_clock_relativity,
                    satellite_clock: corrections.satellite_clock,
                    ppp: fixed_ppp,
                },
                opts: decode_solve_options(solve_options),
                ambiguity: decode_fixed_ambiguity(ambiguity),
            },
        },
        options,
    ) {
        Ok(EstimateOutput::PppFixed(solution)) => Ok(*solution),
        Err(EstimateError::PppFixed(err)) => Err(err),
        Ok(_) | Err(_) => {
            unreachable!("a PPP fixed input yields a PPP fixed solution or a PPP fixed error")
        }
    };
    Ok(encode_fixed_result(env, fixed_result))
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn precise_positioning_prepare_widelane_fixed_epochs<'a>(
    env: Env<'a>,
    epochs: Vec<DualFrequencyEpochTerm>,
    wide_lane: WideLanePrepOptionsTerm,
    policy: String,
    slip_options: SlipOptionsTerm,
) -> NifResult<Term<'a>> {
    let Some(policy) = decode_ppp_cycle_slip_policy(&policy) else {
        return Ok((
            atoms::error(),
            (atoms::invalid_option(), atoms::on_cycle_slip()),
        )
            .encode(env));
    };
    let decoded = decode_dual_frequency_epochs(epochs);
    // The core cycle-slip detector .expect()s on a CarrierPhaseError, so a
    // malformed wide-lane pair (e.g. equal carrier frequencies) would abort the
    // NIF before the integer estimate runs. Surface the same wide_lane_failed
    // reason that estimate_wide_lane_integer would itself raise on that
    // observation, returned up front as a tagged error instead of a panic.
    if let Some((ambiguity_id, reason)) = first_invalid_wide_lane(&decoded) {
        return Ok((
            atoms::error(),
            (
                atoms::wide_lane_failed(),
                ambiguity_id,
                encode_carrier_phase_error(reason),
            ),
        )
            .encode(env));
    }
    let result = core::prepare_widelane_fixed_epochs(
        &decoded,
        core::WideLanePrepOptions {
            min_epochs: wide_lane.0 as usize,
            tolerance_cycles: wide_lane.1,
        },
        policy,
        decode_slip_options(slip_options),
    );
    Ok(encode_wide_lane_prep_result(env, result))
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn precise_positioning_split_float_cycle_slip_epochs(
    epochs: Vec<FloatCycleSlipEpochTerm>,
    slip_options: SlipOptionsTerm,
) -> Vec<Vec<(String, String)>> {
    core::split_float_cycle_slip_epochs(
        &decode_float_cycle_slip_epochs(epochs),
        decode_slip_options(slip_options),
    )
    .into_iter()
    .map(|epoch| {
        epoch
            .observations
            .into_iter()
            .map(|obs| (obs.satellite_id, obs.ambiguity_id))
            .collect()
    })
    .collect()
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
            |(satellite_id, ambiguity_id, code_m, phase_m, freq1_hz, freq2_hz)| {
                Ok(core::FloatObservation {
                    sat: sat_from_token(&satellite_id)?,
                    satellite_id,
                    ambiguity_id,
                    code_m,
                    phase_m,
                    freq1_hz,
                    freq2_hz,
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

fn decode_initial(initial: InitialStateTerm) -> core::FloatState {
    let (position, clocks_m, ambiguities, ztd_m) = initial;
    core::FloatState {
        position_m: vec3_to_array(position),
        clocks_m,
        ambiguities_m: ambiguities.into_iter().collect(),
        ztd_m: ztd_m.unwrap_or(0.0),
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
    core::FloatSolveOptions {
        max_iterations: options.0 as usize,
        position_tolerance_m: options.1,
        clock_tolerance_m: options.2,
        ambiguity_tolerance_m: options.3,
        ztd_tolerance_m: options.4,
    }
}

fn decode_tropo(tropo: TropoTerm) -> NifResult<core::TroposphereOptions> {
    Ok(core::TroposphereOptions {
        enabled: tropo.0,
        estimate_ztd: tropo.1,
        met: sidereon_core::atmosphere::troposphere::Met::new(tropo.2, tropo.3, tropo.4)
            .map_err(crate::errors::invalid_input)?,
    })
}

fn decode_fixed_ambiguity(term: FixedAmbiguityTerm) -> core::FixedAmbiguityOptions {
    let (wavelengths_m, offsets_m, ratio_threshold) = term;
    core::FixedAmbiguityOptions {
        wavelengths_m: wavelengths_m.into_iter().collect(),
        offsets_m: offsets_m.into_iter().collect(),
        ratio_threshold,
    }
}

fn decode_slip_options(term: SlipOptionsTerm) -> sidereon_core::carrier_phase::CycleSlipOptions {
    sidereon_core::carrier_phase::CycleSlipOptions {
        gf_threshold_m: term.0,
        mw_threshold_cycles: term.1,
        min_arc_gap_s: term.2,
    }
}

fn decode_ppp_cycle_slip_policy(policy: &str) -> Option<core::CycleSlipPolicy> {
    match policy {
        "error" => Some(core::CycleSlipPolicy::Error),
        "drop_satellite" => Some(core::CycleSlipPolicy::DropSatellite),
        "split_arc" => Some(core::CycleSlipPolicy::SplitArc),
        _ => None,
    }
}

/// Find the first observation whose wide-lane (Melbourne-Wubbena) combination
/// is undefined, mirroring the `wide_lane_cycles` check the core integer
/// estimate performs. Returns the offending ambiguity id and the carrier-phase
/// reason so the caller can emit a tagged `wide_lane_failed` term rather than
/// letting the core cycle-slip detector panic on the same input.
fn first_invalid_wide_lane(
    epochs: &[core::DualFrequencyEpoch],
) -> Option<(String, sidereon_core::carrier_phase::CarrierPhaseError)> {
    for epoch in epochs {
        for obs in &epoch.observations {
            if let Err(reason) = sidereon_core::carrier_phase::wide_lane_cycles(
                obs.phi1_cyc,
                obs.phi2_cyc,
                obs.p1_m,
                obs.p2_m,
                obs.f1_hz,
                obs.f2_hz,
            ) {
                return Some((obs.ambiguity_id.clone(), reason));
            }
        }
    }
    None
}

fn decode_dual_frequency_epochs(
    epochs: Vec<DualFrequencyEpochTerm>,
) -> Vec<core::DualFrequencyEpoch> {
    epochs
        .into_iter()
        .map(|(gap_time_s, observations)| core::DualFrequencyEpoch {
            gap_time_s,
            observations: observations
                .into_iter()
                .map(decode_dual_frequency_observation)
                .collect(),
        })
        .collect()
}

fn decode_dual_frequency_observation(
    term: DualFrequencyObservationTerm,
) -> core::DualFrequencyObservation {
    core::DualFrequencyObservation {
        ambiguity_id: term.satellite_id.clone(),
        satellite_id: term.satellite_id,
        p1_m: term.p1_m,
        p2_m: term.p2_m,
        phi1_cyc: term.phi1_cyc,
        phi2_cyc: term.phi2_cyc,
        f1_hz: term.f1_hz,
        f2_hz: term.f2_hz,
        lli1: term.lli1,
        lli2: term.lli2,
    }
}

fn decode_float_cycle_slip_epochs(
    epochs: Vec<FloatCycleSlipEpochTerm>,
) -> Vec<core::FloatCycleSlipEpoch> {
    epochs
        .into_iter()
        .map(|(gap_time_s, observations)| core::FloatCycleSlipEpoch {
            gap_time_s,
            observations: observations
                .into_iter()
                .map(decode_float_cycle_slip_observation)
                .collect(),
        })
        .collect()
}

fn decode_float_cycle_slip_observation(
    term: FloatCycleSlipObservationTerm,
) -> core::FloatCycleSlipObservation {
    let (satellite_id, ambiguity_id, raw) = term;
    core::FloatCycleSlipObservation {
        satellite_id,
        ambiguity_id,
        raw: raw.map(decode_dual_frequency_observation),
    }
}

fn decode_corrections(term: CorrectionsTerm) -> NifResult<DecodedCorrections> {
    let (
        sat_clock_relativity,
        satellite_clock,
        receiver_antenna,
        solid_earth_tide,
        phase_windup,
        satellite_antenna,
    ) = term;
    Ok(DecodedCorrections {
        sat_clock_relativity,
        satellite_clock: decode_satellite_clock(satellite_clock)?,
        receiver_antenna: decode_receiver_antenna(receiver_antenna),
        ppp_options: ppp::PppCorrectionsOptions {
            solid_earth_tide,
            phase_windup,
            satellite_antenna: decode_satellite_antenna_options(satellite_antenna)?,
        },
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
            core::ReceiverAntennaOptions {
                freq1_label,
                freq1_hz,
                freq2_label,
                freq2_hz,
                frequencies: frequencies
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
            }
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
                valid_from: valid_from.map(civil_from_tuple),
                valid_until: valid_until.map(civil_from_tuple),
                frequencies,
            })
        })
        .collect::<NifResult<Vec<_>>>()?;
    Ok(Some(ppp::SatelliteAntennaOptions {
        freq1_label,
        freq1_hz,
        freq2_label,
        freq2_hz,
        antennas,
    }))
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

fn encode_wide_lane_prep_result<'a>(
    env: Env<'a>,
    result: Result<core::WideLanePrepResult, core::WideLanePrepError>,
) -> Term<'a> {
    match result {
        Ok(result) => {
            let epochs = result
                .epochs
                .into_iter()
                .map(|epoch| {
                    (
                        epoch.epoch_index as u64,
                        epoch
                            .observations
                            .into_iter()
                            .map(|obs| {
                                (obs.satellite_id, obs.ambiguity_id, obs.code_m, obs.phase_m)
                            })
                            .collect::<Vec<_>>(),
                    )
                })
                .collect::<Vec<_>>();
            let split_arcs = result
                .split_arcs
                .into_iter()
                .map(|arc| {
                    (
                        arc.satellite_id,
                        arc.ambiguity_id,
                        arc.start_epoch_index as u64,
                        arc.end_epoch_index as u64,
                        arc.n_epochs as u64,
                    )
                })
                .collect::<Vec<_>>();
            (
                atoms::ok(),
                (
                    epochs,
                    result.wavelengths_m.into_iter().collect::<Vec<_>>(),
                    result.offsets_m.into_iter().collect::<Vec<_>>(),
                    result.wide_lane_cycles.into_iter().collect::<Vec<_>>(),
                    result.dropped_sats,
                    split_arcs,
                ),
            )
                .encode(env)
        }
        Err(err) => encode_wide_lane_prep_error(env, err),
    }
}

fn encode_wide_lane_prep_error<'a>(env: Env<'a>, err: core::WideLanePrepError) -> Term<'a> {
    match err {
        core::WideLanePrepError::CycleSlipDetected {
            satellite_id,
            epoch_index,
            reasons,
        } => (
            atoms::error(),
            (
                atoms::cycle_slip_detected(),
                satellite_id,
                epoch_index as u64,
                reasons
                    .into_iter()
                    .map(encode_slip_reason)
                    .collect::<Vec<_>>(),
            ),
        )
            .encode(env),
        core::WideLanePrepError::WideLaneFailed {
            ambiguity_id,
            reason,
        } => (
            atoms::error(),
            (
                atoms::wide_lane_failed(),
                ambiguity_id,
                encode_carrier_phase_error(reason),
            ),
        )
            .encode(env),
        core::WideLanePrepError::TooFewWideLaneEpochs {
            ambiguity_id,
            count,
            minimum,
        } => (
            atoms::error(),
            (
                atoms::too_few_wide_lane_epochs(),
                ambiguity_id,
                count as u64,
                minimum as u64,
            ),
        )
            .encode(env),
        core::WideLanePrepError::WideLaneNotInteger {
            ambiguity_id,
            mean_cycles,
            fixed_cycles,
        } => (
            atoms::error(),
            (
                atoms::wide_lane_not_integer(),
                ambiguity_id,
                mean_cycles,
                fixed_cycles,
            ),
        )
            .encode(env),
        core::WideLanePrepError::MissingWideLaneAmbiguity(id) => {
            (atoms::error(), (atoms::missing_wide_lane_ambiguity(), id)).encode(env)
        }
        core::WideLanePrepError::InconsistentFrequencies(id) => {
            (atoms::error(), (atoms::inconsistent_frequencies(), id)).encode(env)
        }
        core::WideLanePrepError::IonosphereFreeFailed {
            satellite_id,
            reason,
        } => (
            atoms::error(),
            (
                atoms::ionosphere_free_failed(),
                satellite_id,
                encode_ionosphere_free_error(reason),
            ),
        )
            .encode(env),
    }
}

fn encode_carrier_phase_error(
    reason: sidereon_core::carrier_phase::CarrierPhaseError,
) -> rustler::Atom {
    match reason {
        sidereon_core::carrier_phase::CarrierPhaseError::EqualFrequencies => {
            atoms::equal_frequencies()
        }
        sidereon_core::carrier_phase::CarrierPhaseError::InvalidFrequency => {
            atoms::invalid_frequency()
        }
        sidereon_core::carrier_phase::CarrierPhaseError::InvalidObservation => {
            atoms::invalid_observation()
        }
        sidereon_core::carrier_phase::CarrierPhaseError::InvalidThreshold => {
            atoms::invalid_threshold()
        }
    }
}

fn encode_ionosphere_free_error(
    reason: sidereon_core::combinations::IonosphereFreeError,
) -> rustler::Atom {
    match reason {
        sidereon_core::combinations::IonosphereFreeError::UnknownSystem(_) => {
            atoms::unknown_system()
        }
        sidereon_core::combinations::IonosphereFreeError::UnknownBand { .. } => {
            atoms::unknown_band()
        }
        sidereon_core::combinations::IonosphereFreeError::EqualFrequencies => {
            atoms::equal_frequencies()
        }
        sidereon_core::combinations::IonosphereFreeError::InvalidFrequency => {
            atoms::invalid_frequency()
        }
        sidereon_core::combinations::IonosphereFreeError::InvalidObservation => {
            atoms::invalid_observation()
        }
    }
}

fn encode_slip_reason(reason: sidereon_core::carrier_phase::SlipReason) -> rustler::Atom {
    match reason {
        sidereon_core::carrier_phase::SlipReason::Lli => atoms::lli(),
        sidereon_core::carrier_phase::SlipReason::GeometryFree => atoms::geometry_free(),
        sidereon_core::carrier_phase::SlipReason::MelbourneWubbena => atoms::melbourne_wubbena(),
        sidereon_core::carrier_phase::SlipReason::DataGap => atoms::data_gap(),
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
    let ztd = match solution.ztd_residual_m {
        Some(value) => value.encode(env),
        None => atoms::nil().encode(env),
    };
    let status = encode_float_status(solution.status);
    let residuals: Vec<(u64, String, f64, f64, f64, f64)> = solution
        .residuals_m
        .into_iter()
        .map(|r| {
            (
                r.epoch_index as u64,
                r.satellite_id,
                r.code_m,
                r.phase_m,
                r.code_weight,
                r.phase_weight,
            )
        })
        .collect();
    (
        array_to_vec3(solution.position_m),
        solution.epoch_clocks_m,
        solution.ambiguities_m.into_iter().collect::<Vec<_>>(),
        ztd,
        residuals,
        solution.used_sats,
        (
            solution.iterations as u64,
            solution.converged,
            status,
            solution.code_rms_m,
            solution.phase_rms_m,
            solution.weighted_rms_m,
        ),
    )
        .encode(env)
}

fn encode_fixed_result<'a>(
    env: Env<'a>,
    result: Result<core::FixedSolution, core::FixedSolveError>,
) -> Term<'a> {
    match result {
        Ok(solution) => {
            let ztd = match solution.ztd_residual_m {
                Some(value) => value.encode(env),
                None => atoms::nil().encode(env),
            };
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
            let residuals: Vec<(u64, String, f64, f64, f64, f64)> = solution
                .residuals_m
                .into_iter()
                .map(|r| {
                    (
                        r.epoch_index as u64,
                        r.satellite_id,
                        r.code_m,
                        r.phase_m,
                        r.code_weight,
                        r.phase_weight,
                    )
                })
                .collect();
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
                    ),
                    (ztd, encode_float_payload(env, solution.float_solution)),
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
                            integer_status,
                            ratio_term,
                            solution.integer.integer_best_score,
                            second_term,
                            solution.integer.integer_candidates as u64,
                            (
                                search.order,
                                search.float_cycles.into_iter().collect::<Vec<_>>(),
                                search.covariance_cycles,
                                search.covariance_inverse_cycles,
                            ),
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
                format!("{correction:?}"),
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
