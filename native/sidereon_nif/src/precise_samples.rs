//! Rustler boundary for the sample-backed precise-ephemeris source.
//!
//! Pure glue over `sidereon_core`'s sample IR: decode `PreciseEphemerisSample`
//! terms, build a [`PreciseEphemerisSamples`] source held as a resource handle,
//! and extract that same canonical sample IR from a parsed SP3 handle. No
//! interpolation numerics, unit conversion, or validation logic live here; those
//! are the crate's responsibility.
//!
//! - `precise_samples_from_samples/1` groups the supplied samples into the
//!   interpolatable source, surfacing the crate's [`PreciseSamplesError`] as a
//!   typed `{:error, reason}`.
//! - `sp3_precise_ephemeris_samples/1` extracts a parsed SP3 product as the
//!   canonical samples, one per real position record.

use rustler::{Encoder, Env, Error, NifResult, ResourceArc, Term};
use sidereon_core::astro::time::model::{Instant, InstantRepr, JulianDateSplit};
use sidereon_core::ephemeris::{
    PreciseEphemerisAccuracySample, PreciseEphemerisSample, PreciseEphemerisSamples,
    PreciseSamplesError, Sp3AccuracyValue, Sp3InterpolationOptions,
};
use sidereon_core::GnssSatelliteId;

use crate::sp3::{
    interpolation_options_error_term, system_from_letter, time_scale_from_abbrev, Sp3Resource,
};

mod atoms {
    rustler::atoms! {
        ok,
        error,
        empty,
        single_sample_satellite,
        non_monotonic,
        mixed_timescale,
        non_finite,
        out_of_range,
        accuracy_samples_mismatch,
        invalid_accuracy_value,
        known,
        unknown,
        too_large,
        invalid_base,
        overflow,
        unhandled
    }
}

type Vec3 = (f64, f64, f64);
#[derive(Debug, Clone, rustler::NifMap)]
pub(crate) struct EpochTerm {
    time_scale: String,
    julian_date: Option<(f64, f64)>,
    nanos_since_j2000: Option<String>,
}
/// One sample as it crosses the boundary in both directions:
/// `{system_letter, prn, epoch, position_ecef_m, clock_s, clock_event}`. The
/// clock is `nil` when the sample carries no clock estimate.
pub(crate) type SampleTerm = (String, u8, EpochTerm, Vec3, Option<f64>, bool);
type AccuracySampleTerm<'a> = (
    String,
    u8,
    EpochTerm,
    (Term<'a>, Term<'a>, Term<'a>),
    Term<'a>,
);

/// Resource handle holding a sample-built precise-ephemeris source across NIF
/// calls. Read-only after construction, so it is shared (`ResourceArc`).
pub struct SampleSourceResource {
    pub source: PreciseEphemerisSamples,
}

#[rustler::resource_impl]
impl rustler::Resource for SampleSourceResource {}

pub(crate) fn samples_error_term<'a>(env: Env<'a>, err: PreciseSamplesError) -> Term<'a> {
    match err {
        PreciseSamplesError::Empty => atoms::empty().encode(env),
        PreciseSamplesError::SingleSampleSatellite(satellite) => {
            (atoms::single_sample_satellite(), satellite.to_string()).encode(env)
        }
        PreciseSamplesError::NonMonotonicEpochs(satellite) => {
            (atoms::non_monotonic(), satellite.to_string()).encode(env)
        }
        PreciseSamplesError::MixedTimeScales => atoms::mixed_timescale().encode(env),
        PreciseSamplesError::EpochNotRepresentable(satellite) => {
            (atoms::out_of_range(), satellite.to_string()).encode(env)
        }
        PreciseSamplesError::NonFiniteSample(satellite) => {
            (atoms::non_finite(), satellite.to_string()).encode(env)
        }
        PreciseSamplesError::AccuracySamplesMismatch => {
            atoms::accuracy_samples_mismatch().encode(env)
        }
        PreciseSamplesError::InvalidAccuracyValue(satellite) => {
            (atoms::invalid_accuracy_value(), satellite.to_string()).encode(env)
        }
        _ => atoms::unhandled().encode(env),
    }
}

fn decode_accuracy_value(term: Term<'_>) -> NifResult<Sp3AccuracyValue> {
    if term.is_atom() {
        return match term.atom_to_string()?.as_str() {
            "unknown" => Ok(Sp3AccuracyValue::Unknown),
            "too_large" => Ok(Sp3AccuracyValue::TooLarge),
            "invalid_base" => Ok(Sp3AccuracyValue::InvalidBase),
            "overflow" => Ok(Sp3AccuracyValue::Overflow),
            _ => Err(Error::Term(Box::new("invalid accuracy value"))),
        };
    }
    let (tag, value): (Term<'_>, f64) = term.decode()?;
    if tag.atom_to_string()?.as_str() == "known" {
        Ok(Sp3AccuracyValue::Known(value))
    } else {
        Err(Error::Term(Box::new("invalid accuracy value")))
    }
}

fn decode_accuracy_sample(
    (letter, prn, epoch, (axis_x, axis_y, axis_z), clock): AccuracySampleTerm<'_>,
) -> NifResult<PreciseEphemerisAccuracySample> {
    let system = system_from_letter(&letter)?;
    let sat = GnssSatelliteId::new(system, prn).map_err(crate::errors::invalid_input)?;
    let epoch = instant_from_fields(epoch)?;
    Ok(PreciseEphemerisAccuracySample::new(
        sat,
        epoch,
        [
            decode_accuracy_value(axis_x)?,
            decode_accuracy_value(axis_y)?,
            decode_accuracy_value(axis_z)?,
        ],
        decode_accuracy_value(clock)?,
    ))
}

/// Decode one boundary tuple into a core [`PreciseEphemerisSample`]. A malformed
/// satellite token, time scale, or Julian-date split is raised as an
/// `:invalid_input` term (rescued to `{:error, _}` on the Elixir side); the six
/// structural validation failures are reported as typed reasons by `from_samples` instead.
pub(crate) fn decode_sample(
    (letter, prn, epoch, (x, y, z), clock_s, clock_event): SampleTerm,
) -> NifResult<PreciseEphemerisSample> {
    let system = system_from_letter(&letter)?;
    let sat = GnssSatelliteId::new(system, prn).map_err(crate::errors::invalid_input)?;
    let epoch = instant_from_fields(epoch)?;
    Ok(PreciseEphemerisSample {
        sat,
        epoch,
        position_ecef_m: [x, y, z],
        clock_s,
        clock_event,
    })
}

fn instant_from_fields(fields: EpochTerm) -> NifResult<Instant> {
    let scale = time_scale_from_abbrev(&fields.time_scale)?;
    match (fields.julian_date, fields.nanos_since_j2000) {
        (Some((jd_whole, jd_fraction)), None) => {
            let split = JulianDateSplit::new(jd_whole, jd_fraction)
                .map_err(crate::tropo::time_model_error_detail)?;
            Ok(Instant::from_julian_date(scale, split))
        }
        (None, Some(nanos)) => {
            let nanos = nanos
                .parse::<i128>()
                .map_err(|_| Error::Term(Box::new("invalid nanosecond epoch")))?;
            Ok(Instant::from_nanos(scale, nanos))
        }
        _ => Err(Error::Term(Box::new(
            "epoch must contain exactly one representation",
        ))),
    }
}

pub(crate) fn epoch_fields(epoch: Instant) -> EpochTerm {
    match epoch.repr {
        InstantRepr::JulianDate(split) => EpochTerm {
            time_scale: epoch.scale.abbrev().to_string(),
            julian_date: Some((split.jd_whole, split.fraction)),
            nanos_since_j2000: None,
        },
        InstantRepr::Nanos(nanos) => EpochTerm {
            time_scale: epoch.scale.abbrev().to_string(),
            julian_date: None,
            nanos_since_j2000: Some(nanos.to_string()),
        },
    }
}

/// Encode one core sample with its original Julian-date or integer-nanosecond
/// epoch representation.
fn sample_to_tuple(sample: &PreciseEphemerisSample) -> SampleTerm {
    (
        sample.sat.system.letter().to_string(),
        sample.sat.prn,
        epoch_fields(sample.epoch),
        (
            sample.position_ecef_m[0],
            sample.position_ecef_m[1],
            sample.position_ecef_m[2],
        ),
        sample.clock_s,
        sample.clock_event,
    )
}

/// Build a precise-ephemeris source from decoded samples.
///
/// Returns `{:ok, handle}` or `{:error, reason}` for the crate's structural
/// validation failures (empty, single-sample satellite, non-monotonic epochs,
/// mixed time scales, non-finite value, epoch out of range). Dirty-CPU: the
/// sample set is unbounded relative to the 1 ms NIF budget.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn precise_samples_from_samples(
    env: Env<'_>,
    samples: Vec<SampleTerm>,
    gap_threshold_factor: Option<f64>,
) -> NifResult<Term<'_>> {
    let mut built = Vec::with_capacity(samples.len());
    for sample in samples {
        built.push(decode_sample(sample)?);
    }

    let mut source = match PreciseEphemerisSamples::from_samples(built) {
        Ok(source) => source,
        Err(err) => return Ok((atoms::error(), samples_error_term(env, err)).encode(env)),
    };
    if let Some(factor) = gap_threshold_factor {
        let opts = Sp3InterpolationOptions::new(factor).map_err(|error| {
            Error::Term(Box::new(interpolation_options_error_term(factor, error)))
        })?;
        source = source.with_interpolation_options(opts);
    }

    Ok((
        atoms::ok(),
        ResourceArc::new(SampleSourceResource { source }),
    )
        .encode(env))
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn precise_samples_from_samples_with_accuracy<'a>(
    env: Env<'a>,
    samples: Vec<SampleTerm>,
    accuracy: Vec<AccuracySampleTerm<'a>>,
    gap_threshold_factor: Option<f64>,
) -> NifResult<Term<'a>> {
    let mut built_samples = Vec::with_capacity(samples.len());
    for sample in samples {
        built_samples.push(decode_sample(sample)?);
    }
    let mut built_accuracy = Vec::with_capacity(accuracy.len());
    for sidecar in accuracy {
        built_accuracy.push(decode_accuracy_sample(sidecar)?);
    }

    let mut source =
        match PreciseEphemerisSamples::from_samples_with_accuracy(built_samples, built_accuracy) {
            Ok(source) => source,
            Err(error) => return Ok((atoms::error(), samples_error_term(env, error)).encode(env)),
        };
    if let Some(factor) = gap_threshold_factor {
        let options = Sp3InterpolationOptions::new(factor).map_err(|error| {
            Error::Term(Box::new(interpolation_options_error_term(factor, error)))
        })?;
        source = source.with_interpolation_options(options);
    }

    Ok((
        atoms::ok(),
        ResourceArc::new(SampleSourceResource { source }),
    )
        .encode(env))
}

/// Position-interpolation gap threshold factor carried by the sample source.
#[rustler::nif]
pub fn precise_samples_gap_threshold_factor(handle: ResourceArc<SampleSourceResource>) -> f64 {
    handle.source.interpolation_options().gap_threshold_factor()
}

/// Extract a parsed SP3 product as the canonical precise-ephemeris samples, one
/// per real position record in ascending epoch order. Dirty-CPU: a full IGS day
/// yields many thousands of records, unbounded relative to the NIF budget.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn sp3_precise_ephemeris_samples(handle: ResourceArc<Sp3Resource>) -> Vec<SampleTerm> {
    handle
        .sp3
        .precise_ephemeris_samples()
        .iter()
        .map(sample_to_tuple)
        .collect()
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn sp3_precise_ephemeris_accuracy_samples<'a>(
    env: Env<'a>,
    handle: ResourceArc<Sp3Resource>,
) -> Vec<AccuracySampleTerm<'a>> {
    handle
        .sp3
        .precise_ephemeris_accuracy_samples()
        .into_iter()
        .map(|sample: PreciseEphemerisAccuracySample| {
            (
                sample.sat.system.letter().to_string(),
                sample.sat.prn,
                epoch_fields(sample.epoch),
                (
                    accuracy_value_term(env, sample.position_variance_m2[0]),
                    accuracy_value_term(env, sample.position_variance_m2[1]),
                    accuracy_value_term(env, sample.position_variance_m2[2]),
                ),
                accuracy_value_term(env, sample.clock_variance_m2),
            )
        })
        .collect()
}

fn accuracy_value_term<'a>(env: Env<'a>, value: Sp3AccuracyValue) -> Term<'a> {
    match value {
        Sp3AccuracyValue::Known(value) => (atoms::known(), value).encode(env),
        Sp3AccuracyValue::Unknown => atoms::unknown().encode(env),
        Sp3AccuracyValue::TooLarge => atoms::too_large().encode(env),
        Sp3AccuracyValue::InvalidBase => atoms::invalid_base().encode(env),
        Sp3AccuracyValue::Overflow => atoms::overflow().encode(env),
        other => (atoms::unhandled(), format!("{other:?}")).encode(env),
    }
}
