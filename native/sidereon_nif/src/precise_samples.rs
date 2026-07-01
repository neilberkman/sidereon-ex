//! Rustler boundary for the sample-backed precise-ephemeris source.
//!
//! Pure glue over `sidereon_core`'s sample IR: decode `PreciseEphemerisSample`
//! terms, build a [`PreciseEphemerisSamples`] source held as a resource handle,
//! and extract that same canonical sample IR from a parsed SP3 handle. No
//! interpolation numerics, unit conversion, or validation logic live here; those
//! are the crate's responsibility.
//!
//! - `precise_samples_from_samples/1` groups the supplied samples into the
//!   interpolatable source, surfacing the crate's [`PreciseSamplesError`] as an
//!   `{:error, atom}` reason.
//! - `sp3_precise_ephemeris_samples/1` extracts a parsed SP3 product as the
//!   canonical samples, one per real position record.

use rustler::{Encoder, Env, NifResult, ResourceArc, Term};
use sidereon_core::astro::time::model::{Instant, JulianDateSplit};
use sidereon_core::ephemeris::{
    PreciseEphemerisSample, PreciseEphemerisSamples, PreciseSamplesError,
};
use sidereon_core::GnssSatelliteId;

use crate::sp3::{system_from_letter, time_scale_from_abbrev, Sp3Resource};

mod atoms {
    rustler::atoms! {
        ok,
        error,
        empty,
        single_sample_satellite,
        non_monotonic,
        mixed_timescale,
        non_finite,
        out_of_range
    }
}

type Vec3 = (f64, f64, f64);
/// Epoch as `{time_scale_abbrev, jd_whole, jd_fraction}`, matching the split
/// Julian-date convention the SP3 boundary uses.
type EpochTerm = (String, f64, f64);
/// One sample as it crosses the boundary in both directions:
/// `{system_letter, prn, epoch, position_ecef_m, clock_s, clock_event}`. The
/// clock is `nil` when the sample carries no clock estimate.
type SampleTerm = (String, u8, EpochTerm, Vec3, Option<f64>, bool);

/// Resource handle holding a sample-built precise-ephemeris source across NIF
/// calls. Read-only after construction, so it is shared (`ResourceArc`).
pub struct SampleSourceResource {
    pub source: PreciseEphemerisSamples,
}

#[rustler::resource_impl]
impl rustler::Resource for SampleSourceResource {}

/// Map the crate's construction error onto the Elixir-facing reason atom.
fn samples_error_atom(err: PreciseSamplesError) -> rustler::Atom {
    match err {
        PreciseSamplesError::Empty => atoms::empty(),
        PreciseSamplesError::SingleSampleSatellite(_) => atoms::single_sample_satellite(),
        PreciseSamplesError::NonMonotonicEpochs(_) => atoms::non_monotonic(),
        PreciseSamplesError::MixedTimeScales => atoms::mixed_timescale(),
        PreciseSamplesError::EpochNotRepresentable(_) => atoms::out_of_range(),
        PreciseSamplesError::NonFiniteSample(_) => atoms::non_finite(),
    }
}

/// Decode one boundary tuple into a core [`PreciseEphemerisSample`]. A malformed
/// satellite token, time scale, or Julian-date split is raised as an
/// `:invalid_input` term (rescued to `{:error, _}` on the Elixir side); the six
/// structural validation failures are reported by `from_samples` instead.
fn decode_sample(
    (letter, prn, (scale, jd_whole, jd_fraction), (x, y, z), clock_s, clock_event): SampleTerm,
) -> NifResult<PreciseEphemerisSample> {
    let system = system_from_letter(&letter)?;
    let sat = GnssSatelliteId::new(system, prn).map_err(crate::errors::invalid_input)?;
    let scale = time_scale_from_abbrev(&scale)?;
    let split =
        JulianDateSplit::new(jd_whole, jd_fraction).map_err(crate::errors::invalid_input)?;
    let epoch = Instant::from_julian_date(scale, split);
    Ok(PreciseEphemerisSample {
        sat,
        epoch,
        position_ecef_m: [x, y, z],
        clock_s,
        clock_event,
    })
}

/// Encode one core sample as the boundary tuple. The epoch is split in the
/// sample's own time scale, the same split convention `precise_samples_from_samples/1`
/// accepts.
fn sample_to_tuple(sample: &PreciseEphemerisSample) -> SampleTerm {
    let (jd_whole, jd_fraction) = sample
        .epoch
        .julian_date()
        .map(|jd| (jd.jd_whole, jd.fraction))
        .unwrap_or((0.0, 0.0));
    (
        sample.sat.system.letter().to_string(),
        sample.sat.prn,
        (sample.epoch.scale.abbrev().to_string(), jd_whole, jd_fraction),
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
/// Returns `{:ok, handle}` or `{:error, atom}` for the crate's structural
/// validation failures (empty, single-sample satellite, non-monotonic epochs,
/// mixed time scales, non-finite value, epoch out of range). Dirty-CPU: the
/// sample set is unbounded relative to the 1 ms NIF budget.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn precise_samples_from_samples(env: Env<'_>, samples: Vec<SampleTerm>) -> NifResult<Term<'_>> {
    let mut built = Vec::with_capacity(samples.len());
    for sample in samples {
        built.push(decode_sample(sample)?);
    }

    Ok(match PreciseEphemerisSamples::from_samples(built) {
        Ok(source) => {
            (atoms::ok(), ResourceArc::new(SampleSourceResource { source })).encode(env)
        }
        Err(err) => (atoms::error(), samples_error_atom(err)).encode(env),
    })
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
