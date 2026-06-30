//! Rustler boundary for carrier-phase combinations and arc processing.
//!
//! Pure glue over `sidereon_core::carrier_phase`: decode already-normalized
//! arc tuples, forward thresholds/window caps to the crate, and encode the
//! unchanged Sidereon public result shapes.

use rustler::{Encoder, Env, NifResult, Term};
use sidereon_core::carrier_phase::{
    self, ArcEpoch, CarrierPhaseError, CycleSlipOptions, SlipReason,
};

#[derive(Debug, Clone, rustler::NifMap)]
struct ArcEpochTerm {
    phi1: Option<f64>,
    phi2: Option<f64>,
    p1: Option<f64>,
    p2: Option<f64>,
    lli1: Option<i64>,
    lli2: Option<i64>,
    f1: Option<f64>,
    f2: Option<f64>,
    gap_time_s: Option<f64>,
}

mod atoms {
    rustler::atoms! {
        ok,
        error,
        equal_frequencies,
        invalid_frequency,
        invalid_observation,
        invalid_threshold,
        lli,
        geometry_free,
        melbourne_wubbena,
        data_gap
    }
}

#[rustler::nif]
fn carrier_phase_phase_meters<'a>(env: Env<'a>, phi_cycles: f64, f_hz: f64) -> Term<'a> {
    encode_float_result(env, carrier_phase::phase_meters(phi_cycles, f_hz))
}

#[rustler::nif]
fn carrier_phase_geometry_free(l1_m: f64, l2_m: f64) -> NifResult<f64> {
    carrier_phase::geometry_free(l1_m, l2_m).map_err(crate::errors::invalid_input)
}

#[rustler::nif]
fn carrier_phase_wide_lane_wavelength<'a>(env: Env<'a>, f1_hz: f64, f2_hz: f64) -> Term<'a> {
    encode_float_result(env, carrier_phase::wide_lane_wavelength(f1_hz, f2_hz))
}

#[rustler::nif]
fn carrier_phase_narrow_lane_code<'a>(
    env: Env<'a>,
    p1_m: f64,
    p2_m: f64,
    f1_hz: f64,
    f2_hz: f64,
) -> Term<'a> {
    encode_float_result(
        env,
        carrier_phase::narrow_lane_code(p1_m, p2_m, f1_hz, f2_hz),
    )
}

#[rustler::nif]
#[allow(clippy::too_many_arguments)]
fn carrier_phase_melbourne_wubbena<'a>(
    env: Env<'a>,
    phi1_cycles: f64,
    phi2_cycles: f64,
    p1_m: f64,
    p2_m: f64,
    f1_hz: f64,
    f2_hz: f64,
) -> Term<'a> {
    encode_float_result(
        env,
        carrier_phase::melbourne_wubbena(phi1_cycles, phi2_cycles, p1_m, p2_m, f1_hz, f2_hz),
    )
}

#[rustler::nif]
#[allow(clippy::too_many_arguments)]
fn carrier_phase_wide_lane_cycles<'a>(
    env: Env<'a>,
    phi1_cycles: f64,
    phi2_cycles: f64,
    p1_m: f64,
    p2_m: f64,
    f1_hz: f64,
    f2_hz: f64,
) -> Term<'a> {
    encode_float_result(
        env,
        carrier_phase::wide_lane_cycles(phi1_cycles, phi2_cycles, p1_m, p2_m, f1_hz, f2_hz),
    )
}

#[rustler::nif]
fn carrier_phase_code_minus_carrier<'a>(
    env: Env<'a>,
    p_m: f64,
    phi_cycles: f64,
    f_hz: f64,
) -> Term<'a> {
    encode_float_result(
        env,
        carrier_phase::code_minus_carrier(p_m, phi_cycles, f_hz),
    )
}

#[rustler::nif(schedule = "DirtyCpu")]
fn carrier_phase_detect_cycle_slips<'a>(
    env: Env<'a>,
    arc: Vec<ArcEpochTerm>,
    gf_threshold_m: f64,
    mw_threshold_cycles: f64,
    min_arc_gap_s: f64,
) -> Term<'a> {
    let results = match carrier_phase::detect_cycle_slips(
        &decode_arc(arc),
        CycleSlipOptions {
            gf_threshold_m,
            mw_threshold_cycles,
            min_arc_gap_s,
        },
    ) {
        Ok(results) => results,
        Err(error) => return (atoms::error(), error_atom(error)).encode(env),
    };

    results
        .into_iter()
        .map(|result| {
            let reasons = result
                .reasons
                .into_iter()
                .map(reason_atom)
                .collect::<Vec<_>>();
            (
                result.slip,
                reasons,
                result.gf_m,
                result.mw_m,
                result.skipped,
            )
                .encode(env)
        })
        .collect::<Vec<Term<'a>>>()
        .encode(env)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn carrier_phase_smooth_code<'a>(
    env: Env<'a>,
    arc: Vec<ArcEpochTerm>,
    gf_threshold_m: f64,
    mw_threshold_cycles: f64,
    min_arc_gap_s: f64,
    hatch_window_cap: u64,
) -> Term<'a> {
    let results = match carrier_phase::smooth_code(
        &decode_arc(arc),
        CycleSlipOptions {
            gf_threshold_m,
            mw_threshold_cycles,
            min_arc_gap_s,
        },
        hatch_window_cap as usize,
    ) {
        Ok(results) => results,
        Err(error) => return (atoms::error(), error_atom(error)).encode(env),
    };

    results
        .into_iter()
        .map(|result| (result.p_smooth_m, result.window as u64, result.reset).encode(env))
        .collect::<Vec<Term<'a>>>()
        .encode(env)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn carrier_phase_smooth_iono_free_code<'a>(
    env: Env<'a>,
    arc: Vec<ArcEpochTerm>,
    gf_threshold_m: f64,
    mw_threshold_cycles: f64,
    min_arc_gap_s: f64,
    hatch_window_cap: u64,
) -> Term<'a> {
    let results = match carrier_phase::smooth_iono_free_code(
        &decode_arc(arc),
        CycleSlipOptions {
            gf_threshold_m,
            mw_threshold_cycles,
            min_arc_gap_s,
        },
        hatch_window_cap as usize,
    ) {
        Ok(results) => results,
        Err(error) => return (atoms::error(), error_atom(error)).encode(env),
    };

    results
        .into_iter()
        .map(|result| {
            (
                result.p_smooth_m,
                result.p_if_m,
                result.l_if_m,
                result.window as u64,
                result.reset,
            )
                .encode(env)
        })
        .collect::<Vec<Term<'a>>>()
        .encode(env)
}

fn decode_arc(arc: Vec<ArcEpochTerm>) -> Vec<ArcEpoch> {
    arc.into_iter()
        .map(|epoch| ArcEpoch {
            phi1_cycles: epoch.phi1,
            phi2_cycles: epoch.phi2,
            p1_m: epoch.p1,
            p2_m: epoch.p2,
            lli1: epoch.lli1,
            lli2: epoch.lli2,
            f1_hz: epoch.f1,
            f2_hz: epoch.f2,
            gap_time_s: epoch.gap_time_s,
        })
        .collect()
}

fn encode_float_result<'a>(env: Env<'a>, result: Result<f64, CarrierPhaseError>) -> Term<'a> {
    match result {
        Ok(value) => (atoms::ok(), value).encode(env),
        Err(error) => (atoms::error(), error_atom(error)).encode(env),
    }
}

fn error_atom(error: CarrierPhaseError) -> rustler::Atom {
    match error {
        CarrierPhaseError::EqualFrequencies => atoms::equal_frequencies(),
        CarrierPhaseError::InvalidFrequency => atoms::invalid_frequency(),
        CarrierPhaseError::InvalidObservation => atoms::invalid_observation(),
        CarrierPhaseError::InvalidThreshold => atoms::invalid_threshold(),
    }
}

fn reason_atom(reason: SlipReason) -> rustler::Atom {
    match reason {
        SlipReason::Lli => atoms::lli(),
        SlipReason::GeometryFree => atoms::geometry_free(),
        SlipReason::MelbourneWubbena => atoms::melbourne_wubbena(),
        SlipReason::DataGap => atoms::data_gap(),
    }
}
