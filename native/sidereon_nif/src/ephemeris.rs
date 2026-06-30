//! JPL/NAIF SPK (DAF `.bsp`) ephemeris kernel reader.
//!
//! This module is a thin Rustler shim over `sidereon_core::astro::spk`, the
//! single validated SPK reader. It manages a parsed kernel as a Rustler resource
//! handle so the bytes are parsed exactly once (`spk_load/1`), exposes the parsed
//! segment descriptors (`spk_segments/1`), and answers a body-to-center state
//! query (`spk_state/4`) returning position and velocity. No SPK grammar or
//! evaluation numerics live here: the parse is [`Spk::from_bytes`] and the query
//! is [`Spk::spk_state`], so the numbers are exactly what `sidereon-core`
//! produces, including SPK segment types 2 (Chebyshev position), 3 (Chebyshev
//! state), and 21 (Extended Modified Difference Arrays).
//!
//! Bodies are addressed by raw NAIF integer code; the Elixir layer maps its body
//! atoms to codes and passes arbitrary integer codes straight through, which is
//! what lets spacecraft / minor-planet kernels (e.g. 433 Eros, code 20000433) be
//! queried in addition to the planetary bodies in DE-series kernels.

use rustler::{Encoder, Env, NifResult, ResourceArc, Term};
use sidereon_core::astro::spk::{Spk, SpkError, SpkSegmentDescriptor, SpkState};

mod atoms {
    rustler::atoms! {
        ok,
        error,
        unknown_body,
        no_segment_path
    }
}

/// Resource handle holding a parsed SPK kernel across NIF calls.
///
/// The parsed [`Spk`] is read-only after construction, so the handle is shared
/// (`ResourceArc`) and every query borrows it immutably. The BEAM GC drops it
/// when the last Elixir reference is collected; nothing re-reads the file.
pub struct SpkResource {
    pub spk: Spk,
}

#[rustler::resource_impl]
impl rustler::Resource for SpkResource {}

/// One SPK segment descriptor as recorded in the DAF summary, in summary order.
/// Encoded to Elixir as a map with these atom keys.
#[derive(Debug, Clone, rustler::NifMap)]
struct SpkSegmentFields {
    name: String,
    target: i32,
    center: i32,
    frame: i32,
    data_type: i32,
    start_et: f64,
    stop_et: f64,
    start_address: i32,
    end_address: i32,
}

impl SpkSegmentFields {
    fn from_descriptor(descriptor: &SpkSegmentDescriptor) -> Self {
        Self {
            name: descriptor.name.clone(),
            target: descriptor.target,
            center: descriptor.center,
            frame: descriptor.frame,
            data_type: descriptor.data_type,
            start_et: descriptor.start_et,
            stop_et: descriptor.stop_et,
            start_address: descriptor.start_address,
            end_address: descriptor.end_address,
        }
    }
}

/// The state of one body relative to another, evaluated from the kernel.
/// Encoded to Elixir as a map; `velocity_km_s` is `nil` when the resolved
/// segment path runs through a position-only type-2 segment.
#[derive(Debug, Clone, rustler::NifMap)]
struct SpkStateFields {
    target: i32,
    center: i32,
    position_km: (f64, f64, f64),
    velocity_km_s: Option<(f64, f64, f64)>,
    frame: i32,
}

impl SpkStateFields {
    fn from_state(state: SpkState) -> Self {
        let [px, py, pz] = state.position_km;
        Self {
            target: state.target,
            center: state.center,
            position_km: (px, py, pz),
            velocity_km_s: state.velocity_km_s.map(|[vx, vy, vz]| (vx, vy, vz)),
            frame: state.frame,
        }
    }
}

/// Parse an SPK/DAF byte buffer into a resource handle.
///
/// Dirty-CPU: parsing a full DE-series kernel is unbounded relative to the 1 ms
/// NIF budget. On success returns the [`SpkResource`] handle; on a malformed
/// buffer returns the crate's parse-error reason as an Erlang term.
#[rustler::nif(schedule = "DirtyCpu")]
fn spk_load(bytes: rustler::Binary) -> NifResult<ResourceArc<SpkResource>> {
    let spk = Spk::from_bytes(bytes.as_slice())
        .map_err(|e| rustler::Error::Term(Box::new(e.to_string())))?;
    Ok(ResourceArc::new(SpkResource { spk }))
}

/// The DAF internal file name recorded in the kernel header.
#[rustler::nif]
fn spk_internal_name(handle: ResourceArc<SpkResource>) -> String {
    handle.spk.file_record().internal_name.clone()
}

/// The kernel's parsed segment descriptors, in DAF summary order.
#[rustler::nif]
fn spk_segments(handle: ResourceArc<SpkResource>) -> Vec<SpkSegmentFields> {
    handle
        .spk
        .segments()
        .iter()
        .map(SpkSegmentFields::from_descriptor)
        .collect()
}

/// Map a state-query [`SpkError`] onto an Elixir error term, splitting bad input
/// (a body absent from the kernel, or two bodies with no connecting segment
/// chain) from a query the loaded kernel cannot satisfy, the same split the
/// Python and WASM bindings make.
fn encode_spk_error(env: Env<'_>, error: SpkError) -> Term<'_> {
    match error {
        SpkError::UnknownBody { body } => {
            (atoms::error(), (atoms::unknown_body(), body)).encode(env)
        }
        SpkError::NoSegmentPath { target, center } => (
            atoms::error(),
            (atoms::no_segment_path(), target, center),
        )
            .encode(env),
        other => (atoms::error(), other.to_string()).encode(env),
    }
}

/// Query the state of `target` relative to `center` at ephemeris epoch `et`
/// (TDB seconds past J2000), resolving and chaining segments as needed.
///
/// Returns `{:ok, state}` where `state` is the [`SpkStateFields`] map, or
/// `{:error, reason}`. Operates only on the resource handle: no file I/O.
#[rustler::nif]
fn spk_state<'a>(
    env: Env<'a>,
    handle: ResourceArc<SpkResource>,
    target: i32,
    center: i32,
    et: f64,
) -> NifResult<Term<'a>> {
    Ok(match handle.spk.spk_state(target, center, et) {
        Ok(state) => (atoms::ok(), SpkStateFields::from_state(state)).encode(env),
        Err(error) => encode_spk_error(env, error),
    })
}
