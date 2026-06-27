//! Rustler boundary for PPP correction precomputation.
//!
//! This module decodes Sidereon' normalized epoch and ANTEX calibration terms,
//! forwards them to `sidereon_core::ppp_corrections`, and encodes indexed
//! correction tables. The correction algebra lives in the crate.

use crate::sp3::Sp3Resource;
use rustler::{Encoder, Env, Error, NifResult, ResourceArc, Term};
use sidereon_core::observables::j2000_seconds_from_split;
use sidereon_core::ppp_corrections as core;
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
    Option<DateTimeTuple>,
    Option<DateTimeTuple>,
    Vec<FrequencyTerm>,
);
type SatelliteAntennaTerm = (String, f64, String, f64, Vec<AntennaTerm>);

mod atoms {
    rustler::atoms! {
        ok
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn ppp_corrections_build<'a>(
    env: Env<'a>,
    handle: ResourceArc<Sp3Resource>,
    epochs: Vec<EpochTerm>,
    receiver_ecef_m: Vec3,
    solid_earth_tide: bool,
    phase_windup: bool,
    satellite_antenna: Option<SatelliteAntennaTerm>,
) -> NifResult<Term<'a>> {
    let epochs = decode_epochs(epochs)?;
    let options = core::PppCorrectionsOptions {
        solid_earth_tide,
        phase_windup,
        satellite_antenna: decode_satellite_antenna_options(satellite_antenna)?,
    };
    let corrections = core::build(
        &handle.sp3,
        &epochs,
        vec3_to_array(receiver_ecef_m),
        &options,
    )
    .map_err(crate::errors::invalid_input)?;

    Ok((
        atoms::ok(),
        (
            encode_tide(&corrections.tide),
            encode_sat_scalars(&corrections.windup_m),
            encode_sat_vectors(&corrections.sat_pco_ecef),
            encode_sat_scalars(&corrections.sat_pcv_m),
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
                valid_from: valid_from.map(civil_from_tuple),
                valid_until: valid_until.map(civil_from_tuple),
                frequencies,
            })
        })
        .collect::<NifResult<Vec<_>>>()?;

    Ok(Some(core::SatelliteAntennaOptions {
        freq1_label,
        freq1_hz,
        freq2_label,
        freq2_hz,
        antennas,
    }))
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
