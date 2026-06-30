//! Rustler boundary for static multi-epoch PPP float positioning.
//!
//! The solver and range-correction algebra live in
//! `sidereon_core::precise_positioning`; this module decodes Sidereon'
//! normalized epoch/option terms and encodes the unchanged public solution
//! fields.

use crate::sp3::Sp3Resource;
use rustler::{Encoder, Env, Error, NifResult, ResourceArc, Term};
use sidereon_core::observables::j2000_seconds_from_split;
use sidereon_core::ppp_corrections as ppp;
use sidereon_core::precise_positioning as core;
use sidereon_core::precise_positioning::auto_init::{
    solve_ppp_auto_init_fixed, solve_ppp_auto_init_float, PppAutoInitError, PppAutoInitOptions,
    PppInitialGuess,
};
use sidereon_core::positioning::SurfaceMet;
use sidereon_core::{GnssSatelliteId, GnssSystem};
use std::collections::BTreeMap;

type Vec3 = (f64, f64, f64);
type DateTuple = (i32, i32, i32);
type TimeTuple = (i32, i32, i32, i32);
type DateTimeTuple = (DateTuple, TimeTuple);
type ObservationTerm = (String, String, f64, f64, f64, f64);
type EpochTerm = (DateTimeTuple, f64, f64, Vec<ObservationTerm>);
type InitialStateTerm = (Vec3, Vec<f64>, Vec<(String, f64)>, Option<f64>);
type FloatPayloadTerm<'a> = (
    Vec3,
    Vec<f64>,
    Vec<(String, f64)>,
    Option<f64>,
    Vec<(u64, String, f64, f64, f64, f64)>,
    Vec<String>,
    (u64, bool, Term<'a>, f64, f64, f64),
);
type WeightsTerm = (f64, f64, bool);
type SolveOptionsTerm = (u64, f64, f64, f64, f64);
// (enabled, estimate_ztd, pressure_hpa, temperature_k, relative_humidity,
//  vmf1_site_samples | nil). The trailing element selects the tropospheric
// mapping: `nil` is Niell (the default), `Some([{mjd, ah, aw}, ...])` is VMF1.
type TropoTerm = (bool, bool, f64, f64, f64, Option<Vec<(f64, f64, f64)>>);
type FixedAmbiguityTerm = (Vec<(String, f64)>, Vec<(String, f64)>, f64);
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
        no_epochs,
        code_seed_failed
    }
}

// (initial_guess {position, clock_m} | nil, spp_initial_guess [x, y, z, b],
//  spp_troposphere, spp_met {pressure_hpa, temperature_k, relative_humidity}).
type PppAutoInitTerm = (Option<(Vec3, f64)>, (f64, f64, f64, f64), bool, (f64, f64, f64));

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
            tropo: decode_tropo(&tropo)?,
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
    let config = core::FloatSolveConfig {
        weights: decode_weights(weights),
        tropo: decode_tropo(&tropo)?,
        corrections: direct_range_corrections(&handle, &epochs, initial.position_m, &corrections)?,
        opts: decode_solve_options(solve_options),
        residual_screen,
    };
    Ok(encode_result(
        env,
        core::solve_float_epochs(&handle.sp3, &epochs, initial, config),
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
    let config = core::FixedSolveConfig {
        weights: decode_weights(weights),
        tropo: decode_tropo(&tropo)?,
        corrections: direct_range_corrections(
            &handle,
            &epochs,
            float_solution.position_m,
            &corrections,
        )?,
        opts: decode_solve_options(solve_options),
        ambiguity: decode_fixed_ambiguity(ambiguity),
    };
    Ok(encode_fixed_result(
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
    let config = core::FloatSolveConfig {
        weights: decode_weights(weights),
        tropo: decode_tropo(&tropo)?,
        corrections: auto_init_range_corrections(&handle, &epochs, &options, &corrections)?,
        opts: decode_solve_options(solve_options),
        residual_screen,
    };
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
    let float_config = core::FloatSolveConfig {
        weights: decode_weights(weights),
        tropo: decode_tropo(&tropo)?,
        corrections: auto_init_range_corrections(&handle, &epochs, &options, &corrections)?,
        opts: decode_solve_options(solve_options),
        residual_screen,
    };
    let fixed_config = core::FixedSolveConfig {
        weights: decode_weights(weights),
        tropo: decode_tropo(&tropo)?,
        corrections: auto_init_range_corrections(&handle, &epochs, &options, &corrections)?,
        opts: decode_solve_options(solve_options),
        ambiguity: decode_fixed_ambiguity(ambiguity),
    };
    let result = solve_ppp_auto_init_fixed(&handle.sp3, &epochs, options, float_config, fixed_config);
    Ok(match result {
        Ok(solution) => encode_fixed_result(env, Ok(solution)),
        Err(PppAutoInitError::Float(error)) => {
            encode_fixed_result(env, Err(core::FixedSolveError::Float(error)))
        }
        Err(PppAutoInitError::Fixed(error)) => encode_fixed_result(env, Err(error)),
        Err(error) => encode_auto_init_seed_error(env, error),
    })
}

/// Decode the auto-init policy term into [`PppAutoInitOptions`].
fn decode_auto_init(term: PppAutoInitTerm) -> PppAutoInitOptions {
    let (initial_guess, spp_initial_guess, spp_troposphere, met) = term;
    PppAutoInitOptions {
        initial_guess: initial_guess.map(|(position, clock_m)| PppInitialGuess {
            position_m: vec3_to_array(position),
            clock_m,
        }),
        spp_initial_guess: [
            spp_initial_guess.0,
            spp_initial_guess.1,
            spp_initial_guess.2,
            spp_initial_guess.3,
        ],
        spp_troposphere,
        spp_met: SurfaceMet {
            pressure_hpa: met.0,
            temperature_k: met.1,
            relative_humidity: met.2,
        },
    }
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

fn decode_float_payload<'a>(term: FloatPayloadTerm<'a>) -> NifResult<core::FloatSolution> {
    let (
        position,
        epoch_clocks_m,
        ambiguities_m,
        ztd_residual_m,
        residuals_m,
        used_sats,
        (iterations, converged, status, code_rms_m, phase_rms_m, weighted_rms_m),
    ) = term;
    Ok(core::FloatSolution {
        position_m: vec3_to_array(position),
        epoch_clocks_m,
        ambiguities_m: ambiguities_m.into_iter().collect(),
        ztd_residual_m,
        residuals_m: residuals_m
            .into_iter()
            .map(
                |(epoch_index, satellite_id, code_m, phase_m, code_weight, phase_weight)| {
                    core::FloatResidual {
                        epoch_index: epoch_index as usize,
                        satellite_id,
                        code_m,
                        phase_m,
                        code_weight,
                        phase_weight,
                    }
                },
            )
            .collect(),
        used_sats,
        iterations: iterations as usize,
        converged,
        status: decode_float_status(status)?,
        code_rms_m,
        phase_rms_m,
        weighted_rms_m,
    })
}

fn decode_float_status(status: Term<'_>) -> NifResult<core::FloatStatus> {
    match status.atom_to_string()?.as_str() {
        "state_tolerance" => Ok(core::FloatStatus::StateTolerance),
        "max_iterations" => Ok(core::FloatStatus::MaxIterations),
        other => Err(Error::Term(Box::new(format!("unknown PPP float status {other}")))),
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

fn decode_tropo(tropo: &TropoTerm) -> NifResult<core::TroposphereOptions> {
    Ok(core::TroposphereOptions {
        enabled: tropo.0,
        estimate_ztd: tropo.1,
        met: sidereon_core::atmosphere::troposphere::Met::new(tropo.2, tropo.3, tropo.4)
            .map_err(crate::errors::invalid_input)?,
        mapping: decode_tropo_mapping(tropo.5.clone())?,
    })
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
    core::FixedAmbiguityOptions {
        wavelengths_m: wavelengths_m.into_iter().collect(),
        offsets_m: offsets_m.into_iter().collect(),
        ratio_threshold,
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
        (pole_tide, ocean_loading),
    ) = term;
    Ok(DecodedCorrections {
        sat_clock_relativity,
        satellite_clock: decode_satellite_clock(satellite_clock)?,
        receiver_antenna: decode_receiver_antenna(receiver_antenna),
        ppp_options: ppp::PppCorrectionsOptions {
            solid_earth_tide,
            pole_tide: crate::ppp_corrections::decode_pole_tide(pole_tide),
            ocean_loading: crate::ppp_corrections::decode_ocean_loading(ocean_loading)?,
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
