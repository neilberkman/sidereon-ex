//! Rustler boundary for ANTEX calibration products.
//!
//! This module is glue only: Elixir passes text or struct-shaped rows, the
//! `sidereon-core` crate parses/selects/interpolates, and the NIF encodes
//! the unchanged Sidereon public struct payloads.

use rustler::{Encoder, Env, Error, NifResult, ResourceArc, Term};
use sidereon_core::antex::{
    Antenna, AntennaKind, Antex, AntexDateTime, Frequency, PcvGrid, PcvSample,
};
use std::collections::BTreeMap;

/// Resource handle holding the parsed ANTEX product across NIF calls, so the
/// serializer can re-emit the full multi-interval product the lossy per-id row
/// view does not carry. Mirrors the SP3/RINEX-OBS parse-to-handle pattern.
pub struct AntexResource {
    pub antex: Antex,
}

#[rustler::resource_impl]
impl rustler::Resource for AntexResource {}

type Vec3 = (f64, f64, f64);
type DateTuple = (i32, i32, i32);
type TimeTuple = (i32, i32, i32, i32);
type DateTimeTuple = (DateTuple, TimeTuple);
type PcvSampleTerm = (String, Option<f64>, f64, f64);
type FrequencyTerm = (String, Vec3, Vec<PcvSampleTerm>);
type AntennaTerm = (
    (String, String, String, String),
    (f64, f64, f64, f64),
    (Option<String>, Option<DateTimeTuple>, Option<DateTimeTuple>),
    Vec<FrequencyTerm>,
);

mod atoms {
    rustler::atoms! {
        ok,
        error,
        not_found,
        unknown_frequency
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn antex_parse<'a>(env: Env<'a>, text: String) -> Term<'a> {
    match Antex::parse(&text) {
        Ok(antex) => {
            let rows = encode_antennas(env, antex.antennas.values());
            let handle = ResourceArc::new(AntexResource { antex });
            (atoms::ok(), rows, handle).encode(env)
        }
        Err(err) => (atoms::error(), err.to_string()).encode(env),
    }
}

/// Serialize the held ANTEX product back to ANTEX 1.4 text. Pure delegation to
/// `Antex::encode`; no formatting lives here.
#[rustler::nif(schedule = "DirtyCpu")]
fn antex_encode(handle: ResourceArc<AntexResource>) -> String {
    handle.antex.encode()
}

#[rustler::nif]
fn antex_satellite_antenna<'a>(
    env: Env<'a>,
    antennas: Vec<AntennaTerm>,
    prn: String,
    datetime: DateTimeTuple,
) -> NifResult<Term<'a>> {
    let antennas = decode_antennas_map(antennas)?;
    let epoch = decode_datetime(datetime)?;
    let prn = prn.trim();
    // Mirror the core `Antex::satellite_antenna` selection: the satellite block
    // whose serial matches the PRN and whose validity interval covers the epoch.
    let found = antennas.values().find(|antenna| {
        antenna.kind == AntennaKind::Satellite
            && antenna.serial.trim() == prn
            && antenna.valid_at(epoch)
    });
    match found {
        Some(antenna) => Ok((atoms::ok(), encode_antenna(env, antenna)).encode(env)),
        None => Ok((atoms::error(), atoms::not_found()).encode(env)),
    }
}

#[rustler::nif]
fn antex_pco<'a>(env: Env<'a>, antenna: AntennaTerm, frequency: String) -> NifResult<Term<'a>> {
    let antenna = decode_antenna(antenna)?;
    match antenna.pco(&frequency) {
        Ok(pco) => Ok((atoms::ok(), array_to_vec3(pco)).encode(env)),
        Err(_) => Ok((atoms::error(), atoms::unknown_frequency()).encode(env)),
    }
}

#[rustler::nif]
fn antex_pcv<'a>(
    env: Env<'a>,
    antenna: AntennaTerm,
    frequency: String,
    zenith_deg: f64,
    azimuth_deg: Option<f64>,
) -> NifResult<Term<'a>> {
    let antenna = decode_antenna(antenna)?;
    // The Sidereon public PCV contract clamps to the antenna grid rather than
    // rejecting out-of-range zeniths. The hardened core `pcv` now refuses any
    // zenith outside [zenith_start_deg, zenith_end_deg], so clamp a finite
    // zenith into that grid before delegating: at the grid boundary the core's
    // own linear interpolation returns the boundary sample value, reproducing
    // the clamp exactly. Non-finite zeniths fall through to the core rejection.
    let zenith_deg = if zenith_deg.is_finite() {
        zenith_deg
            .max(antenna.zenith_start_deg)
            .min(antenna.zenith_end_deg)
    } else {
        zenith_deg
    };
    match antenna.pcv(&frequency, zenith_deg, azimuth_deg) {
        Ok(value_m) => Ok((atoms::ok(), value_m).encode(env)),
        Err(_) => Ok((atoms::error(), atoms::unknown_frequency()).encode(env)),
    }
}

fn encode_antennas<'a, 'b>(
    env: Env<'a>,
    antennas: impl Iterator<Item = &'b Antenna>,
) -> Vec<Term<'a>> {
    antennas
        .map(|antenna| encode_antenna(env, antenna))
        .collect()
}

fn encode_antenna<'a>(env: Env<'a>, antenna: &Antenna) -> Term<'a> {
    (
        (
            antenna.id.clone(),
            kind_string(antenna.kind),
            antenna.antenna_type.clone(),
            antenna.serial.clone(),
        ),
        (
            antenna.dazi_deg,
            antenna.zenith_start_deg,
            antenna.zenith_end_deg,
            antenna.zenith_step_deg,
        ),
        (
            antenna.sinex_code.clone(),
            antenna.valid_from.map(encode_datetime),
            antenna.valid_until.map(encode_datetime),
        ),
        encode_frequencies(antenna.frequencies.values()),
    )
        .encode(env)
}

fn encode_frequencies<'a>(frequencies: impl Iterator<Item = &'a Frequency>) -> Vec<FrequencyTerm> {
    frequencies
        .map(|frequency| {
            (
                frequency.frequency.clone(),
                array_to_vec3(frequency.pco_m),
                frequency
                    .pcv_samples
                    .iter()
                    .map(|sample| {
                        (
                            grid_string(sample.grid),
                            sample.azimuth_deg,
                            sample.zenith_deg,
                            sample.value_m,
                        )
                    })
                    .collect(),
            )
        })
        .collect()
}

fn decode_antennas_map(antennas: Vec<AntennaTerm>) -> NifResult<BTreeMap<String, Antenna>> {
    antennas
        .into_iter()
        .map(decode_antenna)
        .map(|result| result.map(|antenna| (antenna.id.clone(), antenna)))
        .collect::<NifResult<BTreeMap<_, _>>>()
}

fn decode_antenna(term: AntennaTerm) -> NifResult<Antenna> {
    let (
        (id, kind, antenna_type, serial),
        (dazi_deg, zenith_start_deg, zenith_end_deg, zenith_step_deg),
        (sinex_code, valid_from, valid_until),
        frequencies,
    ) = term;

    let frequencies = frequencies
        .into_iter()
        .map(|(frequency, pco, samples)| {
            let pcv_samples = samples
                .into_iter()
                .map(|(grid, azimuth_deg, zenith_deg, value_m)| PcvSample {
                    grid: decode_grid(&grid),
                    azimuth_deg,
                    zenith_deg,
                    value_m,
                })
                .collect();
            let freq = Frequency {
                frequency,
                pco_m: vec3_to_array(pco),
                pcv_samples,
            };
            (freq.frequency.clone(), freq)
        })
        .collect();

    Ok(Antenna {
        id,
        kind: decode_kind(&kind),
        antenna_type,
        serial,
        dazi_deg,
        zenith_start_deg,
        zenith_end_deg,
        zenith_step_deg,
        sinex_code,
        valid_from: valid_from.map(decode_datetime).transpose()?,
        valid_until: valid_until.map(decode_datetime).transpose()?,
        frequencies,
    })
}

fn decode_datetime(datetime: DateTimeTuple) -> NifResult<AntexDateTime> {
    let ((year, month, day), (hour, minute, second, _microsecond)) = datetime;
    let month = u8::try_from(month).map_err(|_| Error::Term(Box::new("bad month")))?;
    let day = u8::try_from(day).map_err(|_| Error::Term(Box::new("bad day")))?;
    let hour = u8::try_from(hour).map_err(|_| Error::Term(Box::new("bad hour")))?;
    let minute = u8::try_from(minute).map_err(|_| Error::Term(Box::new("bad minute")))?;
    let second = u8::try_from(second).map_err(|_| Error::Term(Box::new("bad second")))?;
    AntexDateTime::new(year, month, day, hour, minute, second)
        .map_err(|err| Error::Term(Box::new(err.to_string())))
}

fn encode_datetime(datetime: AntexDateTime) -> DateTimeTuple {
    (
        (
            datetime.year,
            i32::from(datetime.month),
            i32::from(datetime.day),
        ),
        (
            i32::from(datetime.hour),
            i32::from(datetime.minute),
            i32::from(datetime.second),
            0,
        ),
    )
}

fn kind_string(kind: AntennaKind) -> String {
    match kind {
        AntennaKind::Receiver => "receiver".to_string(),
        AntennaKind::Satellite => "satellite".to_string(),
    }
}

fn decode_kind(kind: &str) -> AntennaKind {
    if kind == "satellite" {
        AntennaKind::Satellite
    } else {
        AntennaKind::Receiver
    }
}

fn grid_string(grid: PcvGrid) -> String {
    match grid {
        PcvGrid::NoAzimuth => "noazi".to_string(),
        PcvGrid::Azimuth => "azi".to_string(),
    }
}

fn decode_grid(grid: &str) -> PcvGrid {
    if grid == "azi" {
        PcvGrid::Azimuth
    } else {
        PcvGrid::NoAzimuth
    }
}

fn vec3_to_array(vec: Vec3) -> [f64; 3] {
    [vec.0, vec.1, vec.2]
}

fn array_to_vec3(array: [f64; 3]) -> Vec3 {
    (array[0], array[1], array[2])
}
