//! Rustler boundary for GPS C/A signal primitives.
//!
//! This module is glue only: it decodes normalized Elixir terms, calls
//! `sidereon_core::signal`, and encodes the existing Sidereon public result
//! shapes. C/A generation, sampled replicas, coherent correlation, acquisition,
//! and loss/SNR formulas live in the crate.

use rustler::{Encoder, Env, NifResult, Term};
use sidereon_core::signal::{
    self,
    analysis::{
        self, DllProcessing, DllTrackingOptions, InterferenceTerm, MultipathOptions,
        SignalAnalysisError, SignalModulation,
    },
    AcquisitionOptions, CorrelateOptions, IqSample, ReplicaOptions, SignalError,
};

mod atoms {
    rustler::atoms! {
        ok,
        error,
        unsupported_prn,
        empty_samples,
        too_short,
        neg_infinity,
        invalid_input,
        empty_components,
        no_discriminator_root
    }
}

#[derive(Debug, Clone, rustler::NifMap)]
struct ModulationTerm {
    kind: String,
    order: Option<f64>,
    m: Option<f64>,
    n: Option<f64>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct InterferenceTermTerm {
    modulation: ModulationTerm,
    power_ratio_to_carrier: f64,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct DllTrackingOptionsTerm {
    cn0_db_hz: f64,
    loop_bandwidth_hz: f64,
    integration_time_s: f64,
    correlator_spacing_chips: f64,
    receiver_bandwidth_hz: f64,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct MultipathOptionsTerm {
    multipath_to_direct_ratio: f64,
    correlator_spacing_chips: f64,
    receiver_bandwidth_hz: f64,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct MultipathEnvelopePointTerm {
    delay_chips: f64,
    delay_s: f64,
    in_phase_chips: f64,
    in_phase_s: f64,
    in_phase_m: f64,
    anti_phase_chips: f64,
    anti_phase_s: f64,
    anti_phase_m: f64,
    running_average_chips: f64,
    running_average_s: f64,
    running_average_m: f64,
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

#[rustler::nif]
fn signal_analysis_reference_chip_rate_hz() -> f64 {
    analysis::REFERENCE_CHIP_RATE_HZ
}

#[rustler::nif]
fn signal_analysis_betz_l1_receiver_bandwidth_hz() -> f64 {
    analysis::BETZ_L1_RECEIVER_BANDWIDTH_HZ
}

#[rustler::nif]
fn signal_analysis_modulation_label<'a>(env: Env<'a>, modulation: ModulationTerm) -> Term<'a> {
    let modulation = match decode_modulation(modulation) {
        Ok(modulation) => modulation,
        Err(err) => return encode_analysis_error(env, err),
    };
    (atoms::ok(), modulation.label()).encode(env)
}

#[rustler::nif]
fn signal_analysis_modulation_code_rate_hz<'a>(
    env: Env<'a>,
    modulation: ModulationTerm,
) -> Term<'a> {
    let modulation = match decode_modulation(modulation) {
        Ok(modulation) => modulation,
        Err(err) => return encode_analysis_error(env, err),
    };
    encode_analysis_result(env, || modulation.code_rate_hz())
}

#[rustler::nif(schedule = "DirtyCpu")]
fn signal_analysis_psd_hz<'a>(
    env: Env<'a>,
    modulation: ModulationTerm,
    offsets_hz: Vec<f64>,
) -> Term<'a> {
    let modulation = match decode_modulation(modulation) {
        Ok(modulation) => modulation,
        Err(err) => return encode_analysis_error(env, err),
    };
    encode_analysis_result(env, || {
        offsets_hz
            .into_iter()
            .map(|offset_hz| modulation.psd_hz(offset_hz))
            .collect::<Result<Vec<_>, _>>()
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn signal_analysis_power_in_band<'a>(
    env: Env<'a>,
    modulation: ModulationTerm,
    receiver_bandwidth_hz: f64,
) -> Term<'a> {
    let modulation = match decode_modulation(modulation) {
        Ok(modulation) => modulation,
        Err(err) => return encode_analysis_error(env, err),
    };
    encode_analysis_result(env, || {
        analysis::power_in_band(&modulation, receiver_bandwidth_hz)
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn signal_analysis_fraction_power<'a>(
    env: Env<'a>,
    modulation: ModulationTerm,
    receiver_bandwidth_hz: f64,
) -> Term<'a> {
    let modulation = match decode_modulation(modulation) {
        Ok(modulation) => modulation,
        Err(err) => return encode_analysis_error(env, err),
    };
    encode_analysis_result(env, || {
        analysis::fraction_power_in_band(&modulation, receiver_bandwidth_hz)
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn signal_analysis_rms_bandwidth_hz<'a>(
    env: Env<'a>,
    modulation: ModulationTerm,
    receiver_bandwidth_hz: f64,
) -> Term<'a> {
    let modulation = match decode_modulation(modulation) {
        Ok(modulation) => modulation,
        Err(err) => return encode_analysis_error(env, err),
    };
    encode_analysis_result(env, || {
        analysis::rms_bandwidth_hz(&modulation, receiver_bandwidth_hz)
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn signal_analysis_ssc_hz<'a>(
    env: Env<'a>,
    desired: ModulationTerm,
    interference: ModulationTerm,
    receiver_bandwidth_hz: f64,
) -> Term<'a> {
    let desired = match decode_modulation(desired) {
        Ok(modulation) => modulation,
        Err(err) => return encode_analysis_error(env, err),
    };
    let interference = match decode_modulation(interference) {
        Ok(modulation) => modulation,
        Err(err) => return encode_analysis_error(env, err),
    };
    encode_analysis_result(env, || {
        analysis::spectral_separation_coefficient_hz(&desired, &interference, receiver_bandwidth_hz)
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn signal_analysis_ssc_db_hz<'a>(
    env: Env<'a>,
    desired: ModulationTerm,
    interference: ModulationTerm,
    receiver_bandwidth_hz: f64,
) -> Term<'a> {
    let desired = match decode_modulation(desired) {
        Ok(modulation) => modulation,
        Err(err) => return encode_analysis_error(env, err),
    };
    let interference = match decode_modulation(interference) {
        Ok(modulation) => modulation,
        Err(err) => return encode_analysis_error(env, err),
    };
    encode_analysis_result(env, || {
        analysis::spectral_separation_coefficient_db_hz(
            &desired,
            &interference,
            receiver_bandwidth_hz,
        )
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn signal_analysis_white_noise_ssc_hz<'a>(
    env: Env<'a>,
    desired: ModulationTerm,
    receiver_bandwidth_hz: f64,
) -> Term<'a> {
    let desired = match decode_modulation(desired) {
        Ok(modulation) => modulation,
        Err(err) => return encode_analysis_error(env, err),
    };
    encode_analysis_result(env, || {
        analysis::white_noise_spectral_separation_hz(&desired, receiver_bandwidth_hz)
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn signal_analysis_effective_cn0_degradation<'a>(
    env: Env<'a>,
    desired: ModulationTerm,
    cn0_db_hz: f64,
    receiver_bandwidth_hz: f64,
    interferences: Vec<InterferenceTermTerm>,
) -> Term<'a> {
    let desired = match decode_modulation(desired) {
        Ok(modulation) => modulation,
        Err(err) => return encode_analysis_error(env, err),
    };
    let interferences = match interferences
        .into_iter()
        .map(decode_interference)
        .collect::<Result<Vec<_>, _>>()
    {
        Ok(interferences) => interferences,
        Err(err) => return encode_analysis_error(env, err),
    };
    encode_analysis_result(env, || {
        analysis::effective_cn0_degradation(
            &desired,
            cn0_db_hz,
            receiver_bandwidth_hz,
            &interferences,
        )
        .map(|result| {
            (
                result.effective_cn0_hz,
                result.effective_cn0_db_hz,
                result.degradation_db,
            )
        })
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn signal_analysis_dll_jitter<'a>(
    env: Env<'a>,
    modulation: ModulationTerm,
    options: DllTrackingOptionsTerm,
    processing: String,
) -> Term<'a> {
    let modulation = match decode_modulation(modulation) {
        Ok(modulation) => modulation,
        Err(err) => return encode_analysis_error(env, err),
    };
    let processing = match processing.as_str() {
        "coherent" => DllProcessing::Coherent,
        "non_coherent" => DllProcessing::NonCoherent,
        _ => {
            return encode_analysis_error(
                env,
                SignalAnalysisError::InvalidInput {
                    field: "processing",
                    reason: "must be coherent or non_coherent",
                },
            )
        }
    };
    encode_analysis_result(env, || {
        analysis::dll_thermal_noise_jitter(&modulation, decode_dll_options(options), processing)
            .map(encode_jitter_tuple)
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn signal_analysis_dll_lower_bound<'a>(
    env: Env<'a>,
    modulation: ModulationTerm,
    options: DllTrackingOptionsTerm,
) -> Term<'a> {
    let modulation = match decode_modulation(modulation) {
        Ok(modulation) => modulation,
        Err(err) => return encode_analysis_error(env, err),
    };
    encode_analysis_result(env, || {
        analysis::dll_lower_bound(&modulation, decode_dll_options(options)).map(encode_jitter_tuple)
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn signal_analysis_multipath_envelope<'a>(
    env: Env<'a>,
    modulation: ModulationTerm,
    options: MultipathOptionsTerm,
    delay_chips: Vec<f64>,
) -> Term<'a> {
    let modulation = match decode_modulation(modulation) {
        Ok(modulation) => modulation,
        Err(err) => return encode_analysis_error(env, err),
    };
    encode_analysis_result(env, || {
        analysis::multipath_error_envelope(
            &modulation,
            MultipathOptions {
                multipath_to_direct_ratio: options.multipath_to_direct_ratio,
                correlator_spacing_chips: options.correlator_spacing_chips,
                receiver_bandwidth_hz: options.receiver_bandwidth_hz,
            },
            &delay_chips,
        )
        .map(|points| {
            points
                .into_iter()
                .map(|point| MultipathEnvelopePointTerm {
                    delay_chips: point.delay_chips,
                    delay_s: point.delay_s,
                    in_phase_chips: point.in_phase_chips,
                    in_phase_s: point.in_phase_s,
                    in_phase_m: point.in_phase_m,
                    anti_phase_chips: point.anti_phase_chips,
                    anti_phase_s: point.anti_phase_s,
                    anti_phase_m: point.anti_phase_m,
                    running_average_chips: point.running_average_chips,
                    running_average_s: point.running_average_s,
                    running_average_m: point.running_average_m,
                })
                .collect::<Vec<_>>()
        })
    })
}

fn decode_code(code: Vec<i64>) -> Vec<i8> {
    code.into_iter().map(|chip| chip as i8).collect()
}

fn decode_iq(iq: Vec<(f64, f64)>) -> Vec<IqSample> {
    iq.into_iter().map(|(i, q)| IqSample { i, q }).collect()
}

fn decode_modulation(term: ModulationTerm) -> Result<SignalModulation, SignalAnalysisError> {
    match term.kind.as_str() {
        "bpsk" => SignalModulation::bpsk(required(term.order, "order")?),
        "boc_sine" => SignalModulation::boc_sine(required(term.m, "m")?, required(term.n, "n")?),
        "boc_cosine" => {
            SignalModulation::boc_cosine(required(term.m, "m")?, required(term.n, "n")?)
        }
        "mboc_6_1_1_over_11" => Ok(SignalModulation::mboc_6_1_1_over_11()),
        "tmboc_6_1_4_over_33" => Ok(SignalModulation::tmboc_6_1_4_over_33()),
        _ => Err(SignalAnalysisError::InvalidInput {
            field: "modulation.kind",
            reason: "unsupported modulation",
        }),
    }
}

fn decode_interference(
    term: InterferenceTermTerm,
) -> Result<InterferenceTerm, SignalAnalysisError> {
    Ok(InterferenceTerm::new(
        decode_modulation(term.modulation)?,
        term.power_ratio_to_carrier,
    ))
}

fn decode_dll_options(options: DllTrackingOptionsTerm) -> DllTrackingOptions {
    DllTrackingOptions {
        cn0_db_hz: options.cn0_db_hz,
        loop_bandwidth_hz: options.loop_bandwidth_hz,
        integration_time_s: options.integration_time_s,
        correlator_spacing_chips: options.correlator_spacing_chips,
        receiver_bandwidth_hz: options.receiver_bandwidth_hz,
    }
}

fn encode_jitter_tuple(jitter: analysis::DllJitter) -> (f64, f64, f64, f64) {
    (
        jitter.seconds,
        jitter.chips,
        jitter.meters,
        jitter.squaring_loss,
    )
}

fn required(value: Option<f64>, field: &'static str) -> Result<f64, SignalAnalysisError> {
    value.ok_or(SignalAnalysisError::InvalidInput {
        field,
        reason: "is required",
    })
}

fn encode_analysis_result<'a, T, F>(env: Env<'a>, f: F) -> Term<'a>
where
    T: Encoder,
    F: FnOnce() -> Result<T, SignalAnalysisError>,
{
    match f() {
        Ok(value) => (atoms::ok(), value).encode(env),
        Err(err) => encode_analysis_error(env, err),
    }
}

fn encode_analysis_error<'a>(env: Env<'a>, err: SignalAnalysisError) -> Term<'a> {
    match err {
        SignalAnalysisError::InvalidInput { field, reason } => {
            (atoms::error(), (atoms::invalid_input(), field, reason)).encode(env)
        }
        SignalAnalysisError::EmptyComponents => {
            (atoms::error(), atoms::empty_components()).encode(env)
        }
        SignalAnalysisError::NoDiscriminatorRoot {
            delay_chips,
            phase_sign,
        } => (
            atoms::error(),
            (atoms::no_discriminator_root(), delay_chips, phase_sign),
        )
            .encode(env),
    }
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
