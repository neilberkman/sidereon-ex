//! Rustler boundary for GPS C/A signal primitives.
//!
//! This module is glue only: it decodes normalized Elixir terms, calls
//! `sidereon_core::signal`, and encodes the existing Sidereon public result
//! shapes. C/A generation, sampled replicas, coherent correlation, acquisition,
//! and loss/SNR formulas live in the crate.

use rustler::{Encoder, Env, NifResult, Term};
use sidereon_core::signal::{
    self, AcquisitionOptions, CorrelateOptions, IqSample, ReplicaOptions, SignalError,
};

mod atoms {
    rustler::atoms! {
        ok,
        error,
        unsupported_prn,
        empty_samples,
        too_short,
        neg_infinity,
        invalid_input
    }
}

#[rustler::nif]
fn signal_ca_code_length() -> u64 {
    signal::CA_CODE_LENGTH as u64
}

#[rustler::nif]
fn signal_ca_chip_rate_hz() -> u64 {
    signal::CA_CHIP_RATE_HZ as u64
}

#[rustler::nif]
fn signal_ca_code<'a>(env: Env<'a>, prn: i64) -> Term<'a> {
    match signal::ca_code(prn) {
        Ok(chips) => (
            atoms::ok(),
            chips.into_iter().map(i64::from).collect::<Vec<i64>>(),
        )
            .encode(env),
        Err(err) => encode_error(env, err),
    }
}

#[rustler::nif]
fn signal_ca_chip<'a>(env: Env<'a>, prn: i64, index: i64) -> Term<'a> {
    match signal::ca_chip(prn, index) {
        Ok(chip) => (atoms::ok(), i64::from(chip)).encode(env),
        Err(err) => encode_error(env, err),
    }
}

#[rustler::nif]
fn signal_ca_autocorrelation(code: Vec<i64>) -> Vec<i64> {
    let code = decode_code(code);
    signal::autocorrelation(&code)
        .into_iter()
        .map(i64::from)
        .collect()
}

#[rustler::nif]
fn signal_ca_cross_correlation(code_a: Vec<i64>, code_b: Vec<i64>) -> NifResult<Vec<i64>> {
    let code_a = decode_code(code_a);
    let code_b = decode_code(code_b);
    Ok(signal::cross_correlation(&code_a, &code_b)
        .map_err(crate::errors::invalid_input)?
        .into_iter()
        .map(i64::from)
        .collect())
}

#[rustler::nif]
fn signal_ca_correlation_at(code_a: Vec<i64>, code_b: Vec<i64>, lag: i64) -> NifResult<i64> {
    let code_a = decode_code(code_a);
    let code_b = decode_code(code_b);
    Ok(i64::from(
        signal::correlation_at(&code_a, &code_b, lag).map_err(crate::errors::invalid_input)?,
    ))
}

#[rustler::nif]
fn signal_correlator_replica<'a>(
    env: Env<'a>,
    prn: i64,
    num_samples: u64,
    sample_rate_hz: f64,
    code_phase_chips: f64,
    code_doppler_hz: f64,
) -> Term<'a> {
    match signal::replica(
        prn,
        ReplicaOptions {
            sample_rate_hz,
            num_samples: num_samples as usize,
            code_phase_chips,
            code_doppler_hz,
        },
    ) {
        Ok(samples) => (
            atoms::ok(),
            samples.into_iter().map(i64::from).collect::<Vec<i64>>(),
        )
            .encode(env),
        Err(err) => encode_error(env, err),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn signal_correlator_correlate<'a>(
    env: Env<'a>,
    iq: Vec<(f64, f64)>,
    prn: i64,
    sample_rate_hz: f64,
    doppler_hz: f64,
    code_phase_chips: f64,
    code_doppler_hz: f64,
) -> Term<'a> {
    let iq = decode_iq(iq);
    match signal::correlate(
        &iq,
        prn,
        CorrelateOptions {
            sample_rate_hz,
            doppler_hz,
            code_phase_chips,
            code_doppler_hz,
        },
    ) {
        Ok(result) => (atoms::ok(), (result.i, result.q, result.power)).encode(env),
        Err(err) => encode_error(env, err),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn signal_correlator_correlate_against(
    iq: Vec<(f64, f64)>,
    code: Vec<i64>,
    sample_rate_hz: f64,
    doppler_hz: f64,
) -> NifResult<(f64, f64)> {
    let iq = decode_iq(iq);
    let code = decode_code(code);
    signal::correlate_against(&iq, &code, sample_rate_hz, doppler_hz)
        .map_err(crate::errors::invalid_input)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn signal_correlator_acquire<'a>(
    env: Env<'a>,
    samples: Vec<(f64, f64)>,
    prn: i64,
    sample_rate_hz: f64,
    doppler_min_hz: f64,
    doppler_max_hz: f64,
    doppler_step_hz: f64,
) -> Term<'a> {
    let samples = decode_iq(samples);
    match signal::acquire(
        &samples,
        prn,
        AcquisitionOptions {
            sample_rate_hz,
            doppler_min_hz,
            doppler_max_hz,
            doppler_step_hz,
        },
    ) {
        Ok(result) => (
            atoms::ok(),
            (
                result.code_phase_chips,
                result.doppler_hz,
                result.metric,
                result.peak_power,
                (
                    result.grid.doppler_hz,
                    result.grid.code_phase_bins as u64,
                    result.grid.doppler_step_hz,
                    result.grid.samples_per_chip,
                ),
            ),
        )
            .encode(env),
        Err(err) => encode_error(env, err),
    }
}

#[rustler::nif]
fn signal_coherent_loss(freq_error_hz: f64, integration_time_s: f64) -> NifResult<f64> {
    signal::coherent_loss(freq_error_hz, integration_time_s).map_err(crate::errors::invalid_input)
}

#[rustler::nif]
fn signal_coherent_loss_db<'a>(
    env: Env<'a>,
    freq_error_hz: f64,
    integration_time_s: f64,
) -> Term<'a> {
    match signal::coherent_loss_db(freq_error_hz, integration_time_s) {
        Ok(loss_db) => loss_db.encode(env),
        Err(err) => match signal::coherent_loss(freq_error_hz, integration_time_s) {
            // An exact correlation null gives zero linear loss, i.e. minus
            // infinity in dB. Preserve the documented neg_infinity contract for
            // that case; any other rejection surfaces as an error term.
            Ok(loss) if loss <= 0.0 => atoms::neg_infinity().encode(env),
            _ => encode_error(env, err),
        },
    }
}

#[rustler::nif]
fn signal_snr_post_db(cn0_dbhz: f64, integration_time_s: f64) -> NifResult<f64> {
    signal::snr_post_db(cn0_dbhz, integration_time_s).map_err(crate::errors::invalid_input)
}

fn decode_code(code: Vec<i64>) -> Vec<i8> {
    code.into_iter().map(|chip| chip as i8).collect()
}

fn decode_iq(iq: Vec<(f64, f64)>) -> Vec<IqSample> {
    iq.into_iter().map(|(i, q)| IqSample { i, q }).collect()
}

fn encode_error<'a>(env: Env<'a>, err: SignalError) -> Term<'a> {
    match err {
        SignalError::UnsupportedPrn(prn) => {
            (atoms::error(), (atoms::unsupported_prn(), prn)).encode(env)
        }
        SignalError::InvalidInput { .. } => (atoms::error(), atoms::invalid_input()).encode(env),
        SignalError::EmptySamples => (atoms::error(), atoms::empty_samples()).encode(env),
        SignalError::TooShort => (atoms::error(), atoms::too_short()).encode(env),
    }
}
