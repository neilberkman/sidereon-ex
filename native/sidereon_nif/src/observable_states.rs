//! Rustler boundary for 0.13 precise-ephemeris state batches.
//!
//! This module only owns resource lifetime and term encoding. Satellite-state
//! interpolation, gap classification, and batch contracts stay in
//! `sidereon-core`.

use std::sync::{RwLock, RwLockReadGuard, RwLockWriteGuard};

use rustler::{Binary, Encoder, Env, Error, NifResult, OwnedBinary, ResourceArc, Term};
use sidereon_core::ephemeris::{
    observable_states_at_j2000_s as core_states_at_j2000_s,
    observable_states_at_shared_j2000_s as core_states_at_shared_j2000_s,
    precise_interpolant_store_checksum64, MmapPreciseEphemerisInterpolant,
    ObservableEphemerisSource, ObservableStateBatch, ObservableStateElementStatus,
    ObservablesError, PreciseEphemerisInterpolant, PreciseInterpolantError,
    PreciseInterpolantStoreError, Sp3InterpolationOptions,
    OBSERVABLE_STATE_MISSING_POSITION_ECEF_M,
};
use sidereon_core::positioning::{ClockRelativity, EphemerisSource};
use sidereon_core::DigestProvenance;
use sidereon_core::{Error as CoreError, GnssSatelliteId};

use crate::observables::detailed_observables_error_term;
use crate::precise_samples::{decode_sample, samples_error_term, SampleSourceResource, SampleTerm};
use crate::sp3::{interpolation_options_error_term, system_from_letter, Sp3Resource};
use crate::time::ExactEpochQueryResource;

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
        insufficient_precise_nodes,
        nan,
        corrupt,
        truncated,
        io,
        parse,
        unsupported_version,
        unsupported_time_scale,
        unsupported_satellite_system,
        duplicate_satellite,
        checksum,
        satellite_checksum,
        attested_checksum_mismatch,
        verified,
        attested,
        not_applicable,
        unavailable,
        term,
        unhandled
    }
}

/// Resource handle holding a cached precise-ephemeris interpolant.
pub struct PreciseInterpolantResource {
    pub interpolant: PreciseEphemerisInterpolant,
}

#[rustler::resource_impl]
impl rustler::Resource for PreciseInterpolantResource {}

/// Resource handle holding an opened memory-mappable precise-interpolant store.
pub struct MappedPreciseInterpolantResource {
    interpolant: RwLock<MmapPreciseEphemerisInterpolant<'static>>,
}

impl MappedPreciseInterpolantResource {
    fn new(interpolant: MmapPreciseEphemerisInterpolant<'static>) -> Self {
        Self {
            interpolant: RwLock::new(interpolant),
        }
    }

    pub(crate) fn read(&self) -> RwLockReadGuard<'_, MmapPreciseEphemerisInterpolant<'static>> {
        self.interpolant
            .read()
            .expect("mapped precise interpolant resource lock poisoned")
    }

    fn write(&self) -> RwLockWriteGuard<'_, MmapPreciseEphemerisInterpolant<'static>> {
        self.interpolant
            .write()
            .expect("mapped precise interpolant resource lock poisoned")
    }
}

#[rustler::resource_impl]
impl rustler::Resource for MappedPreciseInterpolantResource {}

/// Build a cached interpolant from a parsed SP3 product.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn precise_interpolant_from_sp3<'a>(
    env: Env<'a>,
    handle: ResourceArc<Sp3Resource>,
    gap_threshold_factor: Option<f64>,
) -> NifResult<Term<'a>> {
    let mut interpolant = PreciseEphemerisInterpolant::from_sp3(&handle.sp3);
    if let Some(factor) = gap_threshold_factor {
        let opts = Sp3InterpolationOptions::new(factor).map_err(|error| {
            Error::Term(Box::new(interpolation_options_error_term(factor, error)))
        })?;
        interpolant = interpolant.with_interpolation_options(opts);
    }
    Ok((
        atoms::ok(),
        ResourceArc::new(PreciseInterpolantResource { interpolant }),
    )
        .encode(env))
}

/// Build a cached interpolant from sample tuples.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn precise_interpolant_from_samples<'a>(
    env: Env<'a>,
    samples: Vec<SampleTerm>,
    gap_threshold_factor: Option<f64>,
) -> NifResult<Term<'a>> {
    let mut built = Vec::with_capacity(samples.len());
    for sample in samples {
        built.push(decode_sample(sample)?);
    }

    let mut interpolant = match PreciseEphemerisInterpolant::from_samples(built) {
        Ok(interpolant) => interpolant,
        Err(PreciseInterpolantError::Samples(error)) => {
            return Ok((atoms::error(), samples_error_term(env, error)).encode(env))
        }
    };
    if let Some(factor) = gap_threshold_factor {
        let opts = Sp3InterpolationOptions::new(factor).map_err(|error| {
            Error::Term(Box::new(interpolation_options_error_term(factor, error)))
        })?;
        interpolant = interpolant.with_interpolation_options(opts);
    }
    Ok((
        atoms::ok(),
        ResourceArc::new(PreciseInterpolantResource { interpolant }),
    )
        .encode(env))
}

/// Build a cached interpolant from an existing sample-backed source handle.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn precise_interpolant_from_precise_samples<'a>(
    env: Env<'a>,
    handle: ResourceArc<SampleSourceResource>,
    gap_threshold_factor: Option<f64>,
) -> NifResult<Term<'a>> {
    let mut interpolant =
        PreciseEphemerisInterpolant::from_precise_ephemeris_samples(&handle.source);
    if let Some(factor) = gap_threshold_factor {
        let opts = Sp3InterpolationOptions::new(factor).map_err(|error| {
            Error::Term(Box::new(interpolation_options_error_term(factor, error)))
        })?;
        interpolant = interpolant.with_interpolation_options(opts);
    }
    Ok((
        atoms::ok(),
        ResourceArc::new(PreciseInterpolantResource { interpolant }),
    )
        .encode(env))
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn precise_interpolant_position_at_epoch_query<'a>(
    env: Env<'a>,
    source: Term<'a>,
    system_letter: String,
    prn: u8,
    query: ResourceArc<ExactEpochQueryResource>,
) -> NifResult<Term<'a>> {
    let system = system_from_letter(&system_letter)?;
    let satellite = GnssSatelliteId::new(system, prn).map_err(crate::errors::invalid_input)?;
    let result = if let Ok(handle) = source.decode::<ResourceArc<Sp3Resource>>() {
        PreciseEphemerisInterpolant::from_sp3(&handle.sp3)
            .position_at_epoch_query(satellite, &query.query)
    } else if let Ok(handle) = source.decode::<ResourceArc<SampleSourceResource>>() {
        PreciseEphemerisInterpolant::from_precise_ephemeris_samples(&handle.source)
            .position_at_epoch_query(satellite, &query.query)
    } else if let Ok(handle) = source.decode::<ResourceArc<PreciseInterpolantResource>>() {
        handle
            .interpolant
            .position_at_epoch_query(satellite, &query.query)
    } else if let Ok(handle) = source.decode::<ResourceArc<MappedPreciseInterpolantResource>>() {
        handle
            .read()
            .position_at_epoch_query(satellite, &query.query)
    } else {
        return Err(Error::Term(Box::new(
            "expected an SP3, precise-sample, or precise-interpolant source handle",
        )));
    };

    match result {
        Ok(state) => {
            let clock = state
                .clock_s
                .map(|value| value.encode(env))
                .unwrap_or_else(|| rustler::types::atom::nil().encode(env));
            Ok((
                atoms::ok(),
                (
                    state.position.x_m,
                    state.position.y_m,
                    state.position.z_m,
                    clock,
                ),
            )
                .encode(env))
        }
        Err(CoreError::EpochOutOfRange) => {
            Ok((atoms::error(), atoms::epoch_out_of_range()).encode(env))
        }
        Err(CoreError::UnknownSatellite(satellite)) => Ok((
            atoms::error(),
            (atoms::unknown_satellite(), satellite.to_string()),
        )
            .encode(env)),
        Err(error) => Ok((atoms::error(), error.to_string()).encode(env)),
    }
}

pub(crate) fn source_hook_result<'a, S: EphemerisSource>(
    env: Env<'a>,
    source: &S,
    satellite: GnssSatelliteId,
    state_epoch: &sidereon_core::astro::time::ExactEpochQuery,
    selection_epoch: &sidereon_core::astro::time::ExactEpochQuery,
    hook: &str,
    position_m: Option<[f64; 3]>,
) -> Term<'a> {
    match hook {
        "selected_state" => match source.try_position_clock_group_delay_selected_at_epoch_query(
            satellite,
            state_epoch,
            selection_epoch,
        ) {
            Ok(Some(state)) => {
                let ([position_x, position_y, position_z], clock_s, group_delay_s) = state.value;
                let degraded = state.degraded.map(crate::errors::degrade_reason_atom);
                (
                    atoms::ok(),
                    Some((
                        position_x,
                        position_y,
                        position_z,
                        clock_s,
                        group_delay_s,
                        degraded,
                    )),
                )
                    .encode(env)
            }
            Ok(None) => (atoms::ok(), rustler::types::atom::nil()).encode(env),
            Err(error) => source_hook_error(env, error),
        },
        "transmit_clock" => match source.try_transmit_epoch_clock_at_epoch_query(
            satellite,
            state_epoch,
            selection_epoch,
        ) {
            Ok(Some(clock)) => (
                atoms::ok(),
                (
                    clock.value,
                    clock.degraded.map(crate::errors::degrade_reason_atom),
                ),
            )
                .encode(env),
            Ok(None) => (atoms::ok(), rustler::types::atom::nil()).encode(env),
            Err(error) => source_hook_error(env, error),
        },
        "clock_relativity" => match source.clock_relativity_for_state_at_epoch_query(
            satellite,
            state_epoch,
            position_m.unwrap_or([f64::NAN; 3]),
        ) {
            ClockRelativity::NotApplicable => atoms::not_applicable().encode(env),
            ClockRelativity::Unavailable => atoms::unavailable().encode(env),
            ClockRelativity::Term(value) => (atoms::term(), value).encode(env),
        },
        "ephemeris_variance" => source
            .ephemeris_variance_at_epoch_query(satellite, state_epoch, selection_epoch)
            .encode(env),
        _ => (atoms::error(), "unknown source hook").encode(env),
    }
}

fn source_hook_error<'a>(env: Env<'a>, error: CoreError) -> Term<'a> {
    match error {
        CoreError::EpochOutOfRange => (atoms::error(), atoms::epoch_out_of_range()).encode(env),
        CoreError::UnknownSatellite(satellite) => (
            atoms::error(),
            (atoms::unknown_satellite(), satellite.to_string()),
        )
            .encode(env),
        CoreError::InsufficientPreciseNodes {
            sat,
            nodes,
            required,
        } => (
            atoms::error(),
            (
                atoms::insufficient_precise_nodes(),
                sat.to_string(),
                nodes,
                required,
            ),
        )
            .encode(env),
        CoreError::Ut1OutsideCoverage(reason) => (
            atoms::error(),
            crate::errors::ut1_outside_coverage_term(env, reason),
        )
            .encode(env),
        other => (atoms::error(), other.to_string()).encode(env),
    }
}

/// Keeps the established Elixir positional call contract intact.
#[rustler::nif]
#[allow(clippy::too_many_arguments)]
pub fn precise_source_exact_epoch_hook<'a>(
    env: Env<'a>,
    source: Term<'a>,
    system_letter: String,
    prn: u8,
    state_epoch: ResourceArc<ExactEpochQueryResource>,
    selection_epoch: ResourceArc<ExactEpochQueryResource>,
    hook: String,
    position_m: Option<(f64, f64, f64)>,
) -> NifResult<Term<'a>> {
    let system = system_from_letter(&system_letter)?;
    let satellite = GnssSatelliteId::new(system, prn).map_err(crate::errors::invalid_input)?;
    let position =
        position_m.map(|(position_x, position_y, position_z)| [position_x, position_y, position_z]);
    if hook == "clock_relativity" && position.is_none() {
        return Err(Error::Term(Box::new(
            "state position is required for clock relativity",
        )));
    }
    if let Ok(handle) = source.decode::<ResourceArc<Sp3Resource>>() {
        return Ok(source_hook_result(
            env,
            &handle.sp3,
            satellite,
            &state_epoch.query,
            &selection_epoch.query,
            &hook,
            position,
        ));
    }
    if let Ok(handle) = source.decode::<ResourceArc<crate::broadcast::BroadcastResource>>() {
        return Ok(source_hook_result(
            env,
            &handle.store,
            satellite,
            &state_epoch.query,
            &selection_epoch.query,
            &hook,
            position,
        ));
    }
    if let Ok(handle) = source.decode::<ResourceArc<SampleSourceResource>>() {
        let interpolant =
            PreciseEphemerisInterpolant::from_precise_ephemeris_samples(&handle.source);
        return Ok(source_hook_result(
            env,
            &interpolant,
            satellite,
            &state_epoch.query,
            &selection_epoch.query,
            &hook,
            position,
        ));
    }
    if let Ok(handle) = source.decode::<ResourceArc<PreciseInterpolantResource>>() {
        return Ok(source_hook_result(
            env,
            &handle.interpolant,
            satellite,
            &state_epoch.query,
            &selection_epoch.query,
            &hook,
            position,
        ));
    }
    if let Ok(handle) = source.decode::<ResourceArc<MappedPreciseInterpolantResource>>() {
        let interpolant = handle.read();
        return Ok(source_hook_result(
            env,
            &*interpolant,
            satellite,
            &state_epoch.query,
            &selection_epoch.query,
            &hook,
            position,
        ));
    }
    Err(Error::Term(Box::new(
        "expected a precise ephemeris source handle",
    )))
}

/// Position-interpolation gap threshold factor carried by the interpolant or opened artifact.
#[rustler::nif]
pub fn precise_interpolant_gap_threshold_factor(source: Term<'_>) -> NifResult<f64> {
    if let Ok(handle) = source.decode::<ResourceArc<PreciseInterpolantResource>>() {
        Ok(handle
            .interpolant
            .interpolation_options()
            .gap_threshold_factor())
    } else if let Ok(handle) = source.decode::<ResourceArc<MappedPreciseInterpolantResource>>() {
        Ok(handle.read().interpolation_options().gap_threshold_factor())
    } else {
        Err(Error::Term(Box::new(
            "expected a precise-interpolant handle",
        )))
    }
}

/// Time-scale abbreviation for the interpolant's source epochs.
#[rustler::nif]
pub fn precise_interpolant_time_scale(source: Term<'_>) -> NifResult<String> {
    if let Ok(handle) = source.decode::<ResourceArc<PreciseInterpolantResource>>() {
        Ok(handle.interpolant.time_scale().abbrev().to_string())
    } else if let Ok(handle) = source.decode::<ResourceArc<MappedPreciseInterpolantResource>>() {
        Ok(handle.read().time_scale().abbrev().to_string())
    } else {
        Err(Error::Term(Box::new(
            "expected a precise-interpolant handle",
        )))
    }
}

/// Satellite ids available in the cached interpolant.
#[rustler::nif]
pub fn precise_interpolant_satellite_ids(source: Term<'_>) -> NifResult<Vec<String>> {
    if let Ok(handle) = source.decode::<ResourceArc<PreciseInterpolantResource>>() {
        Ok(handle
            .interpolant
            .satellites()
            .map(|sat| sat.to_string())
            .collect())
    } else if let Ok(handle) = source.decode::<ResourceArc<MappedPreciseInterpolantResource>>() {
        Ok(handle
            .read()
            .satellites()
            .iter()
            .map(|sat| sat.to_string())
            .collect())
    } else {
        Err(Error::Term(Box::new(
            "expected a precise-interpolant handle",
        )))
    }
}

/// Build canonical precise-interpolant store bytes from a parsed SP3 product.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn precise_interpolant_store_bytes_from_sp3<'a>(
    env: Env<'a>,
    handle: ResourceArc<Sp3Resource>,
    gap_threshold_factor: Option<f64>,
) -> NifResult<Term<'a>> {
    let mut interpolant = PreciseEphemerisInterpolant::from_sp3(&handle.sp3);
    if let Some(factor) = gap_threshold_factor {
        let opts = Sp3InterpolationOptions::new(factor).map_err(|error| {
            Error::Term(Box::new(interpolation_options_error_term(factor, error)))
        })?;
        interpolant = interpolant.with_interpolation_options(opts);
    }
    Ok(match interpolant.to_mmap_store_bytes() {
        Ok(bytes) => (atoms::ok(), bytes_to_binary(env, &bytes)).encode(env),
        Err(error) => (atoms::error(), store_error_term(env, error)).encode(env),
    })
}

/// Build canonical precise-interpolant store bytes from a fitted interpolant.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn precise_interpolant_store_bytes_from_interpolant<'a>(
    env: Env<'a>,
    handle: ResourceArc<PreciseInterpolantResource>,
    gap_threshold_factor: Option<f64>,
) -> NifResult<Term<'a>> {
    let mut interpolant = handle.interpolant.clone();
    if let Some(factor) = gap_threshold_factor {
        let opts = Sp3InterpolationOptions::new(factor).map_err(|error| {
            Error::Term(Box::new(interpolation_options_error_term(factor, error)))
        })?;
        interpolant = interpolant.with_interpolation_options(opts);
    }
    Ok(match interpolant.to_mmap_store_bytes() {
        Ok(bytes) => (atoms::ok(), bytes_to_binary(env, &bytes)).encode(env),
        Err(error) => (atoms::error(), store_error_term(env, error)).encode(env),
    })
}

/// Open canonical precise-interpolant store bytes into an evaluation handle.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn precise_interpolant_store_open<'a>(env: Env<'a>, bytes: Binary<'a>) -> Term<'a> {
    match MmapPreciseEphemerisInterpolant::from_vec(bytes.as_slice().to_vec()) {
        Ok(interpolant) => (
            atoms::ok(),
            ResourceArc::new(MappedPreciseInterpolantResource::new(interpolant)),
        )
            .encode(env),
        Err(error) => (atoms::error(), store_error_term(env, error)).encode(env),
    }
}

/// Open a precise-interpolant artifact using a caller-attested checksum.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn precise_interpolant_store_from_path_attested<'a>(
    env: Env<'a>,
    path: String,
    claimed_checksum64: u64,
) -> Term<'a> {
    match MmapPreciseEphemerisInterpolant::from_path_attested(path, claimed_checksum64) {
        Ok(interpolant) => (
            atoms::ok(),
            ResourceArc::new(MappedPreciseInterpolantResource::new(interpolant)),
        )
            .encode(env),
        Err(error) => (atoms::error(), store_error_term(env, error)).encode(env),
    }
}

/// Return the checksum for precise-interpolant store bytes.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn precise_interpolant_store_checksum64_bytes(bytes: Binary<'_>) -> u64 {
    precise_interpolant_store_checksum64(bytes.as_slice())
}

/// Return the checksum for an opened precise-interpolant store handle.
#[rustler::nif]
pub fn precise_interpolant_store_checksum64_handle(
    handle: ResourceArc<MappedPreciseInterpolantResource>,
) -> u64 {
    handle.read().checksum64()
}

/// Return who computed the checksum carried by an opened artifact handle.
#[rustler::nif]
pub fn precise_interpolant_store_digest_provenance(
    handle: ResourceArc<MappedPreciseInterpolantResource>,
) -> rustler::Atom {
    match handle.read().digest_provenance() {
        DigestProvenance::Verified => atoms::verified(),
        DigestProvenance::Attested => atoms::attested(),
    }
}

/// Verify the file-level and per-satellite payload checksums.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn precise_interpolant_store_verify<'a>(
    env: Env<'a>,
    handle: ResourceArc<MappedPreciseInterpolantResource>,
) -> Term<'a> {
    match handle.write().verify() {
        Ok(()) => atoms::ok().encode(env),
        Err(error) => (atoms::error(), store_error_term(env, error)).encode(env),
    }
}

/// Return the bytes backing an opened artifact handle.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn precise_interpolant_store_bytes_handle<'a>(
    env: Env<'a>,
    handle: ResourceArc<MappedPreciseInterpolantResource>,
) -> Term<'a> {
    bytes_to_binary(env, handle.read().as_bytes())
}

/// Return the byte length of an opened artifact handle.
#[rustler::nif]
pub fn precise_interpolant_store_byte_len_handle(
    handle: ResourceArc<MappedPreciseInterpolantResource>,
) -> u64 {
    handle.read().as_bytes().len() as u64
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

/// Evaluate satellite states and preserve the typed cause of each row failure.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn observable_states_at_j2000_s_detailed<'a>(
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
        Ok(batch) => (atoms::ok(), encode_batch_detailed(env, &batch)).encode(env),
        Err(error) => (atoms::error(), detailed_observables_error_term(env, &error)).encode(env),
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
    } else if let Ok(handle) = source.decode::<ResourceArc<MappedPreciseInterpolantResource>>() {
        Ok(f(&*handle.read()))
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

fn encode_batch_detailed<'a>(env: Env<'a>, batch: &ObservableStateBatch) -> Term<'a> {
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
            Err(error) => (atoms::error(), detailed_observables_error_term(env, error)).encode(env),
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
        ObservablesError::Media(err) => {
            (atoms::invalid_input(), "media".to_string(), err.to_string()).encode(env)
        }
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

fn bytes_to_binary<'a>(env: Env<'a>, bytes: &[u8]) -> Term<'a> {
    let mut binary =
        OwnedBinary::new(bytes.len()).expect("allocate precise interpolant store binary");
    binary.as_mut_slice().copy_from_slice(bytes);
    binary.release(env).encode(env)
}

fn store_error_term<'a>(env: Env<'a>, error: PreciseInterpolantStoreError) -> Term<'a> {
    match error {
        PreciseInterpolantStoreError::Io { path, message } => {
            (atoms::io(), path.display().to_string(), message).encode(env)
        }
        PreciseInterpolantStoreError::Parse { reason } if parse_reason_is_truncated(&reason) => {
            (atoms::truncated(), reason).encode(env)
        }
        PreciseInterpolantStoreError::Parse { reason } => {
            (atoms::corrupt(), (atoms::parse(), reason)).encode(env)
        }
        PreciseInterpolantStoreError::UnsupportedVersion { version } => {
            (atoms::corrupt(), (atoms::unsupported_version(), version)).encode(env)
        }
        PreciseInterpolantStoreError::UnsupportedTimeScale { tag } => {
            (atoms::corrupt(), (atoms::unsupported_time_scale(), tag)).encode(env)
        }
        PreciseInterpolantStoreError::UnsupportedSatelliteSystem { tag } => (
            atoms::corrupt(),
            (atoms::unsupported_satellite_system(), tag),
        )
            .encode(env),
        PreciseInterpolantStoreError::DuplicateSatellite { sat } => (
            atoms::corrupt(),
            (atoms::duplicate_satellite(), sat.to_string()),
        )
            .encode(env),
        PreciseInterpolantStoreError::Checksum { expected, found } => {
            (atoms::corrupt(), (atoms::checksum(), expected, found)).encode(env)
        }
        PreciseInterpolantStoreError::SatelliteChecksum {
            sat,
            expected,
            found,
        } => (
            atoms::corrupt(),
            (
                atoms::satellite_checksum(),
                sat.to_string(),
                expected,
                found,
            ),
        )
            .encode(env),
        PreciseInterpolantStoreError::AttestedChecksumMismatch { claimed, declared } => {
            (atoms::attested_checksum_mismatch(), claimed, declared).encode(env)
        }
        other => (atoms::unhandled(), other.to_string()).encode(env),
    }
}

fn parse_reason_is_truncated(reason: &str) -> bool {
    let lower = reason.to_ascii_lowercase();
    lower.contains("trunc")
        || lower.contains("short")
        || lower.contains("needs at least")
        || lower.contains("out of bounds")
        || lower.contains("past end")
}
