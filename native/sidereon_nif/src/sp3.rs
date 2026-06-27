//! Rustler boundary for the `sidereon-core` SP3 precise-ephemeris product.
//!
//! This module is **pure glue**: it decodes Erlang terms, calls
//! the `sidereon_core::ephemeris` public APIs, manages the parsed product as a
//! Rustler resource handle, and encodes results back. No SP3 grammar, no unit
//! conversion, and no interpolation numerics live here — those are the crate's
//! responsibility. In particular:
//!
//! - `sp3_parse/1` decodes a byte buffer, calls [`Sp3::parse`], and returns a
//!   [`ResourceArc`] wrapping the parsed product. The bytes are parsed exactly
//!   once; nothing stores a path to re-open per call.
//! - `sp3_position/6` operates on that handle plus a decoded epoch; it never
//!   touches the filesystem.
//! - `sp3_satellite_ids/1` exposes only the parsed header satellite tokens, so
//!   Elixir validation code can compare product identity without re-reading the
//!   file or probing interpolation.

use rustler::{Encoder, Env, Error, NifResult, ResourceArc, Term};
use sidereon_core::astro::time::model::{Instant, JulianDateSplit, TimeScale};
use sidereon_core::ephemeris::{
    align_clock_reference, clock_reference_offset, merge as crate_merge, MergeCombine, MergeFlag,
    MergeOptions, Sp3, Sp3State,
};
use sidereon_core::{Error as CoreError, GnssSatelliteId, GnssSystem};
use std::collections::BTreeSet;

mod atoms {
    rustler::atoms! {
        ok,
        error,
        epoch_out_of_range,
        unknown_satellite
    }
}

/// Resource handle holding a parsed SP3 product across NIF calls.
///
/// The parsed [`Sp3`] is read-only after construction, so the handle is shared
/// (`ResourceArc`) and evaluation borrows it immutably. The BEAM GC drops it
/// when the last Elixir reference is collected.
pub struct Sp3Resource {
    pub sp3: Sp3,
}

type Vec3Tuple = (f64, f64, f64);
type FlagsTuple = (bool, bool, bool, bool);
type StateTuple = (
    f64,
    f64,
    f64,
    Option<f64>,
    Option<Vec3Tuple>,
    Option<f64>,
    FlagsTuple,
);

#[rustler::resource_impl]
impl rustler::Resource for Sp3Resource {}

/// Map a GNSS single-letter system identifier (as the Elixir side passes it,
/// e.g. `"G"`) onto the crate's [`GnssSystem`]. Pure identifier translation.
fn system_from_letter(letter: &str) -> NifResult<GnssSystem> {
    let c = letter
        .chars()
        .next()
        .ok_or_else(|| Error::Term(Box::new("empty GNSS system letter")))?;
    GnssSystem::from_letter(c)
        .ok_or_else(|| Error::Term(Box::new(format!("unknown GNSS system letter {letter:?}"))))
}

fn systems_from_letters(letters: Vec<String>) -> NifResult<BTreeSet<GnssSystem>> {
    let mut systems = BTreeSet::new();
    for letter in letters {
        systems.insert(system_from_letter(&letter)?);
    }
    Ok(systems)
}

/// Map a time-scale abbreviation onto the core [`TimeScale`]. Pure translation;
/// used so an Elixir caller can name the epoch's scale explicitly when it is not
/// the file's own header scale.
fn time_scale_from_abbrev(abbrev: &str) -> NifResult<TimeScale> {
    Ok(match abbrev {
        "UTC" => TimeScale::Utc,
        "TAI" => TimeScale::Tai,
        "TT" => TimeScale::Tt,
        "TDB" => TimeScale::Tdb,
        "GPST" => TimeScale::Gpst,
        "GST" => TimeScale::Gst,
        "BDT" => TimeScale::Bdt,
        other => {
            return Err(Error::Term(Box::new(format!(
                "unknown time scale {other:?}"
            ))))
        }
    })
}

/// Parse an SP3-c / SP3-d byte buffer into a resource handle.
///
/// Dirty-CPU: parsing a full IGS day file is unbounded relative to the 1 ms NIF
/// budget. On success returns the [`Sp3Resource`] handle; on a
/// malformed buffer returns the crate's parse-error reason as an Erlang term.
#[rustler::nif(schedule = "DirtyCpu")]
fn sp3_parse(bytes: rustler::Binary) -> NifResult<ResourceArc<Sp3Resource>> {
    let sp3 = Sp3::parse(bytes.as_slice()).map_err(|e| Error::Term(Box::new(e.to_string())))?;
    Ok(ResourceArc::new(Sp3Resource { sp3 }))
}

/// The file's own header time-scale abbreviation (e.g. `"GPST"`), so the Elixir
/// wrapper can tag a query epoch in the product's native scale.
#[rustler::nif]
fn sp3_time_scale(handle: ResourceArc<Sp3Resource>) -> NifResult<String> {
    Ok(handle.sp3.header.time_scale.abbrev().to_string())
}

/// The SP3/RINEX satellite tokens declared in the product header, e.g. `"G01"`.
#[rustler::nif]
fn sp3_satellite_ids(handle: ResourceArc<Sp3Resource>) -> NifResult<Vec<String>> {
    Ok(handle
        .sp3
        .satellites()
        .iter()
        .map(|sat| sat.to_string())
        .collect())
}

/// Number of parsed SP3 epochs held by the product.
#[rustler::nif]
fn sp3_epoch_count(handle: ResourceArc<Sp3Resource>) -> usize {
    handle.sp3.epoch_count()
}

/// Parsed SP3 epoch grid as seconds since J2000 in the product's own time scale.
#[rustler::nif]
fn sp3_epochs_j2000_seconds(handle: ResourceArc<Sp3Resource>) -> Vec<f64> {
    handle.sp3.epochs_j2000_seconds()
}

fn state_tuple(state: Sp3State) -> StateTuple {
    let p = state.position;
    let v = state.velocity.map(|v| (v.vx_m_s, v.vy_m_s, v.vz_m_s));
    let flags = state.flags;

    (
        p.x_m,
        p.y_m,
        p.z_m,
        state.clock_s,
        v,
        state.clock_rate_s_s,
        (
            flags.clock_event,
            flags.clock_predicted,
            flags.maneuver,
            flags.orbit_predicted,
        ),
    )
}

fn encode_sp3_error<'a>(env: Env<'a>, error: CoreError) -> Term<'a> {
    match error {
        CoreError::EpochOutOfRange => (atoms::error(), atoms::epoch_out_of_range()).encode(env),
        CoreError::UnknownSatellite(sat) => (
            atoms::error(),
            (atoms::unknown_satellite(), sat.to_string()),
        )
            .encode(env),
        other => (atoms::error(), other.to_string()).encode(env),
    }
}

/// Exact parsed state of one satellite at a parsed epoch index.
///
/// Returns `{:ok, state}` where `state` is
/// `{x_m, y_m, z_m, clock_s, velocity_m_s, clock_rate_s_s, flags}`. Missing
/// clock, velocity, and clock-rate fields are encoded as `nil`; flags are
/// `{clock_event, clock_predicted, maneuver, orbit_predicted}`.
#[rustler::nif]
fn sp3_state<'a>(
    env: Env<'a>,
    handle: ResourceArc<Sp3Resource>,
    system_letter: String,
    prn: u8,
    epoch_index: usize,
) -> NifResult<Term<'a>> {
    let system = system_from_letter(&system_letter)?;
    let sat = GnssSatelliteId::new(system, prn).map_err(crate::errors::invalid_input)?;

    Ok(match handle.sp3.state(sat, epoch_index) {
        Ok(state) => (atoms::ok(), state_tuple(state)).encode(env),
        Err(error) => encode_sp3_error(env, error),
    })
}

/// All exact parsed states at one parsed epoch index, in ascending satellite order.
#[rustler::nif]
fn sp3_states_at<'a>(
    env: Env<'a>,
    handle: ResourceArc<Sp3Resource>,
    epoch_index: usize,
) -> NifResult<Term<'a>> {
    Ok(match handle.sp3.states_at(epoch_index) {
        Ok(states) => {
            let rows: Vec<Term<'a>> = states
                .iter()
                .map(|(sat, state)| (sat.to_string(), state_tuple(*state)).encode(env))
                .collect();
            (atoms::ok(), rows).encode(env)
        }
        Err(error) => encode_sp3_error(env, error),
    })
}

/// Evaluate `sat`'s interpolated state at `epoch` against a loaded handle.
///
/// The epoch is a split Julian date `(jd_whole, jd_fraction)` in the named
/// `scale`. Returns `{x_m, y_m, z_m, clock}` where `clock` is the satellite
/// clock offset in seconds, or the atom `nil` when the satellite has no clock
/// estimate at the epoch (the crate returns `None`). The clock is encoded as a
/// term rather than a float so a missing clock is not forced through `NaN`,
/// which the BEAM cannot represent.
///
/// Operates only on the resource handle — no file I/O.
#[rustler::nif]
fn sp3_position<'a>(
    env: Env<'a>,
    handle: ResourceArc<Sp3Resource>,
    system_letter: String,
    prn: u8,
    scale: String,
    jd_whole: f64,
    jd_fraction: f64,
) -> NifResult<Term<'a>> {
    let system = system_from_letter(&system_letter)?;
    let sat = GnssSatelliteId::new(system, prn).map_err(crate::errors::invalid_input)?;
    let scale = time_scale_from_abbrev(&scale)?;
    let split =
        JulianDateSplit::new(jd_whole, jd_fraction).map_err(crate::errors::invalid_input)?;
    let epoch = Instant::from_julian_date(scale, split);

    let state = handle
        .sp3
        .position(sat, epoch)
        .map_err(|e| Error::Term(Box::new(e.to_string())))?;

    // Encode clock as `nil` when absent so a fixed-arity tuple never carries a
    // NaN float (unrepresentable on the BEAM); the Elixir wrapper maps `nil`
    // straight through to `clock_s: nil`.
    let clock_term: Term<'a> = match state.clock_s {
        Some(c) => c.encode(env),
        None => rustler::types::atom::nil().encode(env),
    };

    Ok((
        state.position.x_m,
        state.position.y_m,
        state.position.z_m,
        clock_term,
    )
        .encode(env))
}

/// Split a flagged cell's epoch into a `(jd_whole, jd_fraction)` pair in the
/// product's own time scale (the same split convention `sp3_position/6` accepts).
/// Encoded as a 4-tuple `{sat_token, jd_whole, jd_fraction, [source_index]}` so
/// the Elixir wrapper can build a structured report.
fn flag_to_tuple(flag: &MergeFlag) -> (String, f64, f64, Vec<u64>) {
    let (jd_whole, jd_fraction) = flag
        .epoch
        .julian_date()
        .map(|jd| (jd.jd_whole, jd.fraction))
        .unwrap_or((0.0, 0.0));
    (
        flag.satellite.to_string(),
        jd_whole,
        jd_fraction,
        flag.sources.iter().map(|&s| s as u64).collect(),
    )
}

/// Estimate the per-epoch reference-clock offset of `other` relative to
/// `reference` (the clock-datum primitive).
///
/// Returns a list of `{jd_whole, jd_fraction, offset_s, satellites}` tuples, one
/// per epoch where at least `min_common` common clocked satellites let the
/// (robust median) offset be estimated. Dirty-CPU: a full IGS day is unbounded
/// relative to the 1 ms NIF budget.
#[rustler::nif(schedule = "DirtyCpu")]
fn sp3_clock_reference_offset(
    reference: ResourceArc<Sp3Resource>,
    other: ResourceArc<Sp3Resource>,
    min_common: usize,
) -> NifResult<Vec<(f64, f64, f64, u64)>> {
    Ok(
        clock_reference_offset(&reference.sp3, &other.sp3, min_common)
            .iter()
            .map(|o| {
                let (jd_whole, jd_fraction) = o
                    .epoch
                    .julian_date()
                    .map(|jd| (jd.jd_whole, jd.fraction))
                    .unwrap_or((0.0, 0.0));
                (jd_whole, jd_fraction, o.offset_s, o.satellites as u64)
            })
            .collect(),
    )
}

/// Return a new handle to a copy of `other` with its clocks shifted onto
/// `reference`'s clock datum (the clock-datum primitive, applied).
///
/// Dirty-CPU: clones and rewrites a full product.
#[rustler::nif(schedule = "DirtyCpu")]
fn sp3_align_clock_reference(
    reference: ResourceArc<Sp3Resource>,
    other: ResourceArc<Sp3Resource>,
    min_common: usize,
) -> NifResult<ResourceArc<Sp3Resource>> {
    let aligned = align_clock_reference(&reference.sp3, &other.sp3, min_common);
    Ok(ResourceArc::new(Sp3Resource { sp3: aligned }))
}

/// Merge several SP3 products into one consistent precise-ephemeris dataset.
///
/// `handles` are the source products in **precedence order**. `combine` is one
/// of `"mean"`, `"median"`, `"precedence"`. Returns
/// `{merged_handle, {quarantined, single_source, position_outliers}}` where each
/// report list is a list of `flag_to_tuple` 4-tuples. Dirty-CPU: combines full
/// products.
#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
fn sp3_merge<'a>(
    env: Env<'a>,
    handles: Vec<ResourceArc<Sp3Resource>>,
    position_tolerance_m: f64,
    clock_tolerance_s: f64,
    min_agree: usize,
    clock_min_common: usize,
    combine: String,
    target_epoch_interval_s: Option<f64>,
    system_letters: Vec<String>,
) -> NifResult<Term<'a>> {
    let combine = match combine.as_str() {
        "mean" => MergeCombine::Mean,
        "median" => MergeCombine::Median,
        "precedence" => MergeCombine::Precedence,
        other => {
            return Err(Error::Term(Box::new(format!(
                "unknown combine strategy {other:?}"
            ))))
        }
    };
    let opts = MergeOptions {
        position_tolerance_m,
        clock_tolerance_s,
        min_agree,
        clock_min_common,
        combine,
        target_epoch_interval_s,
        systems: if system_letters.is_empty() {
            None
        } else {
            Some(systems_from_letters(system_letters)?)
        },
    };

    // The crate merge takes owned products; the handles are shared/immutable, so
    // clone each into the merge input.
    let sources: Vec<Sp3> = handles.iter().map(|h| h.sp3.clone()).collect();
    let (merged, report) =
        crate_merge(&sources, &opts).map_err(|e| Error::Term(Box::new(e.to_string())))?;

    let handle = ResourceArc::new(Sp3Resource { sp3: merged });
    let quarantined: Vec<_> = report.quarantined.iter().map(flag_to_tuple).collect();
    let single_source: Vec<_> = report.single_source.iter().map(flag_to_tuple).collect();
    let position_outliers: Vec<_> = report.position_outliers.iter().map(flag_to_tuple).collect();

    Ok((handle, (quarantined, single_source, position_outliers)).encode(env))
}

/// Serialize a loaded SP3 product to standard SP3-c/-d text (the inverse of
/// `sp3_parse/1`). Dirty-CPU: a full IGS day serializes many thousands of
/// records, unbounded relative to the 1 ms NIF budget.
#[rustler::nif(schedule = "DirtyCpu")]
fn sp3_to_iodata(handle: ResourceArc<Sp3Resource>) -> NifResult<String> {
    Ok(handle.sp3.to_sp3_string())
}
