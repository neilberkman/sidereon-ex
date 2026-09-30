//! Rustler boundary for PPP correction precomputation.
//!
//! This module decodes Sidereon' normalized epoch and ANTEX calibration terms,
//! forwards them to `sidereon_core::ppp_corrections`, and encodes indexed
//! correction tables. The correction algebra lives in the crate.

use crate::sp3::Sp3Resource;
use rustler::{Encoder, Env, Error, NifResult, ResourceArc, Term};
use sidereon_core::astro::time::{DegradeReason, ValidityMode};
use sidereon_core::observables::j2000_seconds_from_split;
use sidereon_core::ppp_corrections as core;
use sidereon_core::tides::{OceanLoadingBlq, StationTideConstants, NUM_OCEAN_CONSTITUENTS};
use sidereon_core::{GnssSatelliteId, GnssSystem};

type Vec3 = (f64, f64, f64);
type DateTuple = (i32, i32, i32);
type TimeTuple = (i32, i32, i32, i32);
type DateTimeTuple = (DateTuple, TimeTuple);
type ObservationTerm = (String, f64, f64);
type EpochTerm = (DateTimeTuple, f64, f64, Vec<ObservationTerm>);
type FrequencyTerm = (String, Vec3, Vec<(f64, f64)>);
type AntennaTerm = (
    String,
    Option<ValidityTerm>,
    Option<ValidityTerm>,
    Vec<FrequencyTerm>,
);
type SatelliteAntennaTerm = (String, f64, String, f64, Vec<AntennaTerm>);
// pole_tide: {xp_arcsec, yp_arcsec} | nil.
pub(crate) type PoleTideTerm = (f64, f64);
// ocean_loading: {amplitude_rows, phase_rows} | nil, each three rows
// (radial, west, south) of NUM_OCEAN_CONSTITUENTS coefficients.
pub(crate) type OceanLoadingTerm = (Vec<Vec<f64>>, Vec<Vec<f64>>);

mod atoms {
    rustler::atoms! {
        ok
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
pub fn ppp_corrections_build<'a>(
    env: Env<'a>,
    handle: ResourceArc<Sp3Resource>,
    epochs: Vec<EpochTerm>,
    receiver_ecef_m: Vec3,
    solid_earth_tide: bool,
    phase_windup: bool,
    satellite_antenna: Option<SatelliteAntennaTerm>,
    pole_tide: Option<PoleTideTerm>,
    ocean_loading: Option<OceanLoadingTerm>,
    validity: String,
    tide_constants: String,
) -> NifResult<Term<'a>> {
    let epochs = decode_epochs(epochs)?;
    let mut options = core::PppCorrectionsOptions::new();
    options.solid_earth_tide = solid_earth_tide;
    options.pole_tide = decode_pole_tide(pole_tide);
    options.ocean_loading = decode_ocean_loading(ocean_loading)?;
    options.phase_windup = phase_windup;
    options.satellite_antenna = decode_satellite_antenna_options(satellite_antenna)?;
    options.code_bias = None;
    let validity = match validity.as_str() {
        "strict" => ValidityMode::Strict,
        "permissive" => ValidityMode::Permissive,
        _ => {
            return Err(Error::Term(Box::new(
                "validity must be strict or permissive",
            )))
        }
    };
    let tide_constants = match tide_constants.as_str() {
        "conventions" => StationTideConstants::Conventions,
        "iers_routine" => StationTideConstants::IersRoutine,
        _ => return Err(Error::Term(Box::new("invalid station tide constants"))),
    };
    let validated = core::build_with_validity_and_tide_constants(
        &handle.sp3,
        &epochs,
        vec3_to_array(receiver_ecef_m),
        &options,
        validity,
        tide_constants,
    )
    .map_err(crate::errors::invalid_input)?;
    let corrections = validated.value;
    let degraded = validated.degraded.map(|reason| match reason {
        DegradeReason::BeforeCoverage => "before_coverage",
        DegradeReason::AfterCoverage => "after_coverage",
    });

    Ok((
        atoms::ok(),
        (
            encode_tide(&corrections.tide),
            encode_sat_scalars(&corrections.windup_m),
            encode_sat_vectors(&corrections.sat_pco_ecef),
            encode_sat_scalars(&corrections.sat_pcv_m),
            encode_tide(&corrections.pole_tide),
            encode_tide(&corrections.ocean_loading),
            degraded,
        ),
    )
        .encode(env))
}

fn decode_epochs(epochs: Vec<EpochTerm>) -> NifResult<Vec<core::PppCorrectionEpoch>> {
    epochs
        .into_iter()
        .map(|(datetime, jd_whole, jd_fraction, observations)| {
            let observations = observations
                .into_iter()
                .map(|(sat, freq1_hz, freq2_hz)| {
                    Ok(core::PppCorrectionObservation {
                        sat: sat_from_token(&sat)?,
                        freq1_hz,
                        freq2_hz,
                        glonass_channel: None,
                    })
                })
                .collect::<NifResult<Vec<_>>>()?;
            Ok(core::PppCorrectionEpoch {
                epoch: civil_from_tuple(datetime),
                t_rx_j2000_s: j2000_seconds_from_split(jd_whole, jd_fraction)
                    .map_err(crate::errors::invalid_input)?,
                observations,
            })
        })
        .collect()
}

fn decode_satellite_antenna_options(
    term: Option<SatelliteAntennaTerm>,
) -> NifResult<Option<core::SatelliteAntennaOptions>> {
    let Some((freq1_label, freq1_hz, freq2_label, freq2_hz, antennas)) = term else {
        return Ok(None);
    };

    let antennas = antennas
        .into_iter()
        .map(|(sat, valid_from, valid_until, frequencies)| {
            let frequencies = frequencies
                .into_iter()
                .map(|(label, pco, noazi_pcv)| core::SatelliteAntennaFrequency {
                    label,
                    pco_m: vec3_to_array(pco),
                    noazi_pcv_m: noazi_pcv,
                })
                .collect();
            Ok(core::SatelliteAntenna {
                sat: sat_from_token(&sat)?,
                valid_from: valid_from.map(civil_from_validity).transpose()?,
                valid_until: valid_until.map(civil_from_validity).transpose()?,
                frequencies,
            })
        })
        .collect::<NifResult<Vec<_>>>()?;

    Ok(Some(core::SatelliteAntennaOptions::new(
        freq1_label,
        freq1_hz,
        freq2_label,
        freq2_hz,
        antennas,
    )))
}

/// Decode the optional pole-tide polar-motion inputs `{xp_arcsec, yp_arcsec}`.
/// `None` leaves the pole tide off, byte-identical to the prior behavior.
pub(crate) fn decode_pole_tide(term: Option<PoleTideTerm>) -> Option<core::PoleTideOptions> {
    term.map(|(xp_arcsec, yp_arcsec)| core::PoleTideOptions::new(xp_arcsec, yp_arcsec))
}

/// Decode the optional ocean-loading BLQ block `{amplitude_rows, phase_rows}`.
/// Each is exactly three rows (radial, west, south) of
/// [`NUM_OCEAN_CONSTITUENTS`] coefficients. `None` leaves ocean loading off.
pub(crate) fn decode_ocean_loading(
    term: Option<OceanLoadingTerm>,
) -> NifResult<Option<OceanLoadingBlq>> {
    let Some((amplitude, phase)) = term else {
        return Ok(None);
    };
    Ok(Some(OceanLoadingBlq {
        amplitude_m: blq_rows(amplitude, "ocean_loading amplitude")?,
        phase_deg: blq_rows(phase, "ocean_loading phase")?,
    }))
}

fn blq_rows(
    rows: Vec<Vec<f64>>,
    field: &'static str,
) -> NifResult<[[f64; NUM_OCEAN_CONSTITUENTS]; 3]> {
    if rows.len() != 3 {
        return Err(crate::errors::invalid_input(format!(
            "{field}: expected 3 rows, got {}",
            rows.len()
        )));
    }
    let mut out = [[0.0_f64; NUM_OCEAN_CONSTITUENTS]; 3];
    for (i, row) in rows.into_iter().enumerate() {
        if row.len() != NUM_OCEAN_CONSTITUENTS {
            return Err(crate::errors::invalid_input(format!(
                "{field}: row {i} expected {NUM_OCEAN_CONSTITUENTS} coefficients, got {}",
                row.len()
            )));
        }
        out[i].copy_from_slice(&row);
    }
    Ok(out)
}

fn civil_from_tuple(tuple: DateTimeTuple) -> core::CivilDateTime {
    let (date, time) = tuple;
    core::CivilDateTime {
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
fn civil_from_validity(term: ValidityTerm) -> NifResult<core::CivilDateTime> {
    let ((year, month, day), (hour, minute, second), (digits, scale)) = term;
    let field = |value: i32, name: &'static str| {
        u8::try_from(value).map_err(|_| {
            Error::Term(Box::new(format!(
                "antenna validity {name} {value} is outside 0..=255"
            )))
        })
    };
    let second = field(second, "second")?;
    Ok(core::CivilDateTime {
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

fn encode_tide(corrections: &[core::EpochVectorCorrection]) -> Vec<(u64, Vec3)> {
    corrections
        .iter()
        .map(|c| (c.epoch_index as u64, array_to_vec3(c.vector_m)))
        .collect()
}

fn encode_sat_scalars(corrections: &[core::SatScalarCorrection]) -> Vec<(String, u64, f64)> {
    corrections
        .iter()
        .map(|c| (c.sat.to_string(), c.epoch_index as u64, c.value_m))
        .collect()
}

fn encode_sat_vectors(corrections: &[core::SatVectorCorrection]) -> Vec<(String, u64, Vec3)> {
    corrections
        .iter()
        .map(|c| {
            (
                c.sat.to_string(),
                c.epoch_index as u64,
                array_to_vec3(c.vector_m),
            )
        })
        .collect()
}
