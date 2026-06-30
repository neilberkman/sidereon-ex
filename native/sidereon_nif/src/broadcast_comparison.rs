//! Rustler boundary for broadcast-vs-precise ephemeris accuracy (SISRE).
//!
//! Pure glue over `sidereon_core::broadcast_comparison`: it decodes the
//! broadcast and precise SP3 resource handles plus the sampling window the
//! Sidereon interface marshals (the broadcast J2000-second span, the precise
//! split Julian date at the window start, the step, and the velocity half-step),
//! calls the crate's window-form comparison driver (which builds the per-epoch
//! grid internally), and encodes the per-satellite / overall / missing report
//! back. No grid construction, RAC projection, statistics, or datum removal live
//! here.

use crate::broadcast::BroadcastResource;
use crate::sp3::Sp3Resource;
use rustler::{Encoder, Env, Error, NifResult, ResourceArc, Term};
use sidereon_core::astro::time::model::JulianDateSplit;
use sidereon_core::broadcast_comparison::{compare_window, CompareStats, CompareWindow};
use sidereon_core::{GnssSatelliteId, GnssSystem};

/// Parse a canonical RINEX satellite token (e.g. `"G05"`) into a typed id.
fn parse_token(token: &str) -> NifResult<GnssSatelliteId> {
    let mut chars = token.chars();
    let letter = chars
        .next()
        .ok_or_else(|| Error::Term(Box::new("empty satellite token")))?;
    let system = GnssSystem::from_letter(letter)
        .ok_or_else(|| Error::Term(Box::new(format!("unknown GNSS system letter {letter:?}"))))?;
    let prn: u8 = chars
        .as_str()
        .parse()
        .map_err(|_| Error::Term(Box::new(format!("invalid satellite PRN in {token:?}"))))?;
    GnssSatelliteId::new(system, prn).map_err(crate::errors::invalid_input)
}

/// Encode one statistics record as `{count, [12 optional floats]}` where each
/// float is `nil` when absent, in the fixed order the Elixir wrapper decodes.
fn encode_stats<'a>(env: Env<'a>, stats: &CompareStats) -> Term<'a> {
    let opt = |value: Option<f64>| -> Term<'a> {
        match value {
            Some(v) => v.encode(env),
            None => rustler::types::atom::nil().encode(env),
        }
    };
    let fields = vec![
        opt(stats.orbit_3d_rms_m),
        opt(stats.orbit_3d_max_m),
        opt(stats.radial_rms_m),
        opt(stats.radial_max_m),
        opt(stats.along_rms_m),
        opt(stats.along_max_m),
        opt(stats.cross_rms_m),
        opt(stats.cross_max_m),
        opt(stats.clock_rms_m),
        opt(stats.clock_max_m),
        opt(stats.clock_datum_removed_rms_m),
        opt(stats.clock_datum_removed_max_m),
    ];
    (stats.count as u64, fields).encode(env)
}

/// Compare a broadcast product against a precise SP3 product over a sampling
/// window. The interface supplies the two start anchors (the broadcast J2000
/// second axis `(t0, t1)` and the precise split Julian date at `t0`), the step,
/// and the velocity half-step; the core driver builds the per-epoch grid.
/// Returns `{overall_stats, per_satellite, missing}` where `per_satellite` is a
/// list of `{sat_token, stats}` and `missing` a list of `{sat_token,
/// skipped_count}`. Dirty-CPU: a full IGS day across all satellites is unbounded
/// relative to the 1 ms NIF budget.
#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
fn broadcast_comparison<'a>(
    env: Env<'a>,
    broadcast: ResourceArc<BroadcastResource>,
    precise: ResourceArc<Sp3Resource>,
    satellites: Vec<String>,
    broadcast_t0_j2000_s: f64,
    broadcast_t1_j2000_s: f64,
    precise_start_jd_whole: f64,
    precise_start_fraction: f64,
    step_s: f64,
    velocity_half_s: f64,
) -> NifResult<Term<'a>> {
    let satellites: Vec<GnssSatelliteId> = satellites
        .iter()
        .map(|token| parse_token(token))
        .collect::<NifResult<_>>()?;

    let window = CompareWindow {
        broadcast_window_j2000_s: (broadcast_t0_j2000_s, broadcast_t1_j2000_s),
        precise_start: JulianDateSplit::new(precise_start_jd_whole, precise_start_fraction)
            .map_err(crate::errors::invalid_input)?,
        step_s,
        velocity_half_s,
    };

    let report = compare_window(&broadcast.store, &precise.sp3, &satellites, &window)
        .map_err(crate::errors::invalid_input)?;

    let per_satellite: Vec<(String, Term<'a>)> = report
        .per_satellite
        .iter()
        .map(|(sat, stats)| (sat.to_string(), encode_stats(env, stats)))
        .collect();
    let missing: Vec<(String, u64)> = report
        .missing
        .iter()
        .map(|(sat, count)| (sat.to_string(), *count as u64))
        .collect();

    Ok((encode_stats(env, &report.overall), per_satellite, missing).encode(env))
}
