//! Rustler boundary for 0.13 precise-ephemeris state batches.
//!
//! This module only owns resource lifetime and term encoding. Satellite-state
//! interpolation, gap classification, and batch contracts stay in
//! `sidereon-core`.

use rustler::{Encoder, Env, Error, NifResult, ResourceArc, Term};
use sidereon_core::astro::time::model::{Instant, JulianDateSplit};
use sidereon_core::ephemeris::{
    observable_states_at_j2000_s as core_states_at_j2000_s,
    observable_states_at_shared_j2000_s as core_states_at_shared_j2000_s,
    ObservableEphemerisSource, ObservableStateBatch, ObservableStateElementStatus,
    ObservablesError, PreciseEphemerisInterpolant, PreciseEphemerisSample, PreciseInterpolantError,
    PreciseSamplesError, OBSERVABLE_STATE_MISSING_POSITION_ECEF_M,
};
use sidereon_core::{Error as CoreError, GnssSatelliteId};

use crate::precise_samples::SampleSourceResource;
use crate::sp3::{system_from_letter, time_scale_from_abbrev, Sp3Resource};

type Vec3 = (f64, f64, f64);
type EpochTerm = (String, f64, f64);
type SampleTerm = (String, u8, EpochTerm, Vec3, Option<f64>, bool);
type SatTerm = (String, u8);

mod atoms {
    rustler::atoms! {
        ok,
        error,
        valid,
        gap,
        invalid_input,
        no_ephemeris,
        epoch_out_of_range,
        unknown_satellite,
        empty,
        single_sample_satellite,
        non_monotonic,
        mixed_timescale,
        non_finite,
        out_of_range,
        nan
    }
}

/// Resource handle holding a cached precise-ephemeris interpolant.
pub struct PreciseInterpolantResource {
    pub interpolant: PreciseEphemerisInterpolant,
}

#[rustler::resource_impl]
impl rustler::Resource for PreciseInterpolantResource {}

/// Build a cached interpolant from a parsed SP3 product.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn precise_interpolant_from_sp3<'a>(
    env: Env<'a>,
    handle: ResourceArc<Sp3Resource>,
) -> Term<'a> {
    let interpolant = PreciseEphemerisInterpolant::from_sp3(&handle.sp3);
    (
        atoms::ok(),
        ResourceArc::new(PreciseInterpolantResource { interpolant }),
    )
        .encode(env)
}

/// Build a cached interpolant from sample tuples.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn precise_interpolant_from_samples<'a>(
    env: Env<'a>,
    samples: Vec<SampleTerm>,
) -> NifResult<Term<'a>> {
    let mut built = Vec::with_capacity(samples.len());
    for sample in samples {
        built.push(decode_sample(sample)?);
    }

    Ok(match PreciseEphemerisInterpolant::from_samples(built) {
        Ok(interpolant) => (
            atoms::ok(),
            ResourceArc::new(PreciseInterpolantResource { interpolant }),
        )
            .encode(env),
        Err(error) => (atoms::error(), interpolant_error_atom(error)).encode(env),
    })
}

/// Build a cached interpolant from an existing sample-backed source handle.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn precise_interpolant_from_precise_samples<'a>(
    env: Env<'a>,
    handle: ResourceArc<SampleSourceResource>,
) -> Term<'a> {
    let interpolant = PreciseEphemerisInterpolant::from_precise_ephemeris_samples(&handle.source);
    (
        atoms::ok(),
        ResourceArc::new(PreciseInterpolantResource { interpolant }),
    )
        .encode(env)
}

/// Time-scale abbreviation for the interpolant's source epochs.
#[rustler::nif]
pub fn precise_interpolant_time_scale(handle: ResourceArc<PreciseInterpolantResource>) -> String {
    handle.interpolant.time_scale().abbrev().to_string()
}

/// Satellite ids available in the cached interpolant.
#[rustler::nif]
pub fn precise_interpolant_satellite_ids(
    handle: ResourceArc<PreciseInterpolantResource>,
) -> Vec<String> {
    handle
        .interpolant
        .satellites()
        .map(|sat| sat.to_string())
        .collect()
}

/// Position sentinel used by failed observable-state batch rows.
#[rustler::nif]
pub fn observable_state_missing_position_ecef_m<'a>(env: Env<'a>) -> Term<'a> {
    encode_position(env, OBSERVABLE_STATE_MISSING_POSITION_ECEF_M)
}

/// Evaluate satellite states for parallel satellite and epoch arrays.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn observable_states_at_j2000_s<'a>(
    env: Env<'a>,
    source: Term<'a>,
    satellites: Vec<SatTerm>,
    epochs_j2000_s: Vec<f64>,
) -> NifResult<Term<'a>> {
    let satellites = decode_satellites(satellites)?;
    let result = with_source(source, |source| {
        core_states_at_j2000_s(source, &satellites, &epochs_j2000_s)
    })?;

    Ok(match result {
        Ok(batch) => (atoms::ok(), encode_batch(env, &batch)).encode(env),
        Err(error) => (atoms::error(), observables_error_reason(env, &error)).encode(env),
    })
}

/// Evaluate satellite states for many satellites at one shared epoch.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn observable_states_at_shared_j2000_s<'a>(
    env: Env<'a>,
    source: Term<'a>,
    satellites: Vec<SatTerm>,
    epoch_j2000_s: f64,
) -> NifResult<Term<'a>> {
    let satellites = decode_satellites(satellites)?;
    let batch = with_source(source, |source| {
        core_states_at_shared_j2000_s(source, &satellites, epoch_j2000_s)
    })?;
    Ok((atoms::ok(), encode_batch(env, &batch)).encode(env))
}

fn with_source<'a, F, R>(source: Term<'a>, f: F) -> NifResult<R>
where
    F: FnOnce(&dyn ObservableEphemerisSource) -> R,
{
    if let Ok(handle) = source.decode::<ResourceArc<Sp3Resource>>() {
        Ok(f(&handle.sp3))
    } else if let Ok(handle) = source.decode::<ResourceArc<SampleSourceResource>>() {
        Ok(f(&handle.source))
    } else if let Ok(handle) = source.decode::<ResourceArc<PreciseInterpolantResource>>() {
        Ok(f(&handle.interpolant))
    } else {
        Err(Error::Term(Box::new(
            "expected an SP3, precise-sample, or precise-interpolant handle",
        )))
    }
}

fn decode_satellites(satellites: Vec<SatTerm>) -> NifResult<Vec<GnssSatelliteId>> {
    let mut decoded = Vec::with_capacity(satellites.len());
    for (letter, prn) in satellites {
        let system = system_from_letter(&letter)?;
        decoded.push(GnssSatelliteId::new(system, prn).map_err(crate::errors::invalid_input)?);
    }
    Ok(decoded)
}

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

fn interpolant_error_atom(error: PreciseInterpolantError) -> rustler::Atom {
    match error {
        PreciseInterpolantError::Samples(error) => samples_error_atom(error),
    }
}

fn samples_error_atom(error: PreciseSamplesError) -> rustler::Atom {
    match error {
        PreciseSamplesError::Empty => atoms::empty(),
        PreciseSamplesError::SingleSampleSatellite(_) => atoms::single_sample_satellite(),
        PreciseSamplesError::NonMonotonicEpochs(_) => atoms::non_monotonic(),
        PreciseSamplesError::MixedTimeScales => atoms::mixed_timescale(),
        PreciseSamplesError::EpochNotRepresentable(_) => atoms::out_of_range(),
        PreciseSamplesError::NonFiniteSample(_) => atoms::non_finite(),
    }
}

fn encode_batch<'a>(env: Env<'a>, batch: &ObservableStateBatch) -> Term<'a> {
    let positions: Vec<Term<'a>> = batch
        .positions_ecef_m
        .iter()
        .map(|position| encode_position(env, *position))
        .collect();
    let statuses: Vec<Term<'a>> = (0..batch.len())
        .map(|index| {
            match batch.element_status(index) {
                Some(ObservableStateElementStatus::Valid) => atoms::valid(),
                Some(ObservableStateElementStatus::Gap) => atoms::gap(),
                Some(ObservableStateElementStatus::Error) | None => atoms::error(),
            }
            .encode(env)
        })
        .collect();
    let results: Vec<Term<'a>> = batch
        .element_results
        .iter()
        .map(|result| match result {
            Ok(()) => atoms::ok().encode(env),
            Err(error) => (atoms::error(), observables_error_reason(env, error)).encode(env),
        })
        .collect();

    (positions, batch.clocks_s.clone(), statuses, results).encode(env)
}

fn observables_error_reason<'a>(env: Env<'a>, error: &ObservablesError) -> Term<'a> {
    match error {
        ObservablesError::InvalidInput { field, kind } => {
            (atoms::invalid_input(), field.to_string(), kind.to_string()).encode(env)
        }
        ObservablesError::NoEphemeris => atoms::no_ephemeris().encode(env),
        ObservablesError::Ephemeris(CoreError::EpochOutOfRange) => {
            atoms::epoch_out_of_range().encode(env)
        }
        ObservablesError::Ephemeris(CoreError::UnknownSatellite(sat)) => {
            (atoms::unknown_satellite(), sat.to_string()).encode(env)
        }
        ObservablesError::Ephemeris(error) => error.to_string().encode(env),
    }
}

fn encode_position<'a>(env: Env<'a>, array: [f64; 3]) -> Term<'a> {
    (
        encode_float_or_nan(env, array[0]),
        encode_float_or_nan(env, array[1]),
        encode_float_or_nan(env, array[2]),
    )
        .encode(env)
}

fn encode_float_or_nan<'a>(env: Env<'a>, value: f64) -> Term<'a> {
    if value.is_nan() {
        atoms::nan().encode(env)
    } else {
        value.encode(env)
    }
}
