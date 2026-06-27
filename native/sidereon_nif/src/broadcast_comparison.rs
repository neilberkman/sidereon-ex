//! Rustler boundary for broadcast-vs-precise ephemeris accuracy (SISRE).
//!
//! Pure glue over `sidereon_core::broadcast_comparison`: it decodes the
//! broadcast and precise SP3 resource handles plus the per-epoch evaluation keys
//! marshaled by the Sidereon interface (broadcast J2000 seconds and SP3 split Julian
//! dates for the epoch and its `+/-` velocity neighbours), calls the crate
//! comparison, and encodes the per-satellite / overall / missing report back. No
//! RAC projection, statistics, or datum removal live here.

use crate::broadcast::BroadcastResource;
use crate::sp3::Sp3Resource;
use rustler::{Encoder, Env, Error, NifResult, ResourceArc, Term};
use sidereon_core::astro::time::model::JulianDateSplit;
use sidereon_core::broadcast_comparison::{compare, CompareStats, EpochInputs};
use sidereon_core::{GnssSatelliteId, GnssSystem};

/// One epoch's evaluation keys as marshaled from Elixir:
/// `(broadcast_t_j2000_s, jd_whole, jd_frac, jd_whole_plus, jd_frac_plus,
/// jd_whole_minus, jd_frac_minus)`.
type EpochKeys = (f64, f64, f64, f64, f64, f64, f64);

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

/// Compare a broadcast product against a precise SP3 product over the marshaled
/// epoch keys. Returns `{overall_stats, per_satellite, missing}` where
/// `per_satellite` is a list of `{sat_token, stats}` and `missing` a list of
/// `{sat_token, skipped_count}`. Dirty-CPU: a full IGS day across all satellites
/// is unbounded relative to the 1 ms NIF budget.
#[rustler::nif(schedule = "DirtyCpu")]
fn broadcast_comparison<'a>(
    env: Env<'a>,
    broadcast: ResourceArc<BroadcastResource>,
    precise: ResourceArc<Sp3Resource>,
    satellites: Vec<String>,
    epochs: Vec<EpochKeys>,
    velocity_half_s: f64,
) -> NifResult<Term<'a>> {
    let satellites: Vec<GnssSatelliteId> = satellites
        .iter()
        .map(|token| parse_token(token))
        .collect::<NifResult<_>>()?;

    let epochs: Vec<EpochInputs> = epochs
        .iter()
        .map(|&(bc_t, jdw, jdf, jdw_p, jdf_p, jdw_m, jdf_m)| {
            Ok(EpochInputs {
                broadcast_t_j2000_s: bc_t,
                precise: JulianDateSplit::new(jdw, jdf).map_err(crate::errors::invalid_input)?,
                precise_plus: JulianDateSplit::new(jdw_p, jdf_p)
                    .map_err(crate::errors::invalid_input)?,
                precise_minus: JulianDateSplit::new(jdw_m, jdf_m)
                    .map_err(crate::errors::invalid_input)?,
            })
        })
        .collect::<NifResult<_>>()?;

    let report = compare(
        &broadcast.store,
        &precise.sp3,
        &satellites,
        &epochs,
        velocity_half_s,
    )
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
