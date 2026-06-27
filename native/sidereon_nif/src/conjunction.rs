//! Conjunction assessment: find closest approach between two satellites.
//!
//! Uses coarse-fine search: scan at configurable step size, then refine
//! with golden section search within each candidate interval. Backed by
//! the in-house `sidereon_core::astro::sgp4` propagator.

use rustler::{Encoder, Env, NifResult, Term};
use sidereon_core::astro::sgp4::{MinutesSinceEpoch, OpsMode, Satellite};

/// Distance between two 3-vectors.
fn dist(a: &[f64; 3], b: &[f64; 3]) -> f64 {
    let dx = a[0] - b[0];
    let dy = a[1] - b[1];
    let dz = a[2] - b[2];
    (dx * dx + dy * dy + dz * dz).sqrt()
}

/// Propagate one satellite to a given tsince and return the position vector.
fn propagate(sat: &Satellite, tsince: f64) -> Option<[f64; 3]> {
    sat.propagate(MinutesSinceEpoch(tsince))
        .ok()
        .map(|p| p.position)
}

/// Compute the distance between the two satellites at time `tsince` measured
/// from satellite 1's epoch. Satellite 2 is offset by `epoch_offset2_min`.
fn dist_at(s1: &Satellite, s2: &Satellite, epoch_offset2_min: f64, tsince: f64) -> Option<f64> {
    let p1 = propagate(s1, tsince)?;
    let p2 = propagate(s2, tsince - epoch_offset2_min)?;
    Some(dist(&p1, &p2))
}

/// Golden section search for minimum distance within [a, b] (minutes).
fn golden_search(
    s1: &Satellite,
    s2: &Satellite,
    epoch_offset2_min: f64,
    mut a: f64,
    mut b: f64,
) -> Option<(f64, f64)> {
    let gr = (5.0_f64.sqrt() + 1.0) / 2.0;
    let tol = 1.0 / 60.0; // 1 second

    let mut c = b - (b - a) / gr;
    let mut d = a + (b - a) / gr;

    for _ in 0..50 {
        if (b - a).abs() < tol {
            break;
        }

        let dc = dist_at(s1, s2, epoch_offset2_min, c)?;
        let dd = dist_at(s1, s2, epoch_offset2_min, d)?;

        if dc < dd {
            b = d;
        } else {
            a = c;
        }

        c = b - (b - a) / gr;
        d = a + (b - a) / gr;
    }

    let mid = (a + b) / 2.0;
    let d = dist_at(s1, s2, epoch_offset2_min, mid)?;
    Some((mid, d))
}

#[allow(clippy::too_many_arguments)]
pub(crate) fn conjunction_impl<'a>(
    env: Env<'a>,
    line1_a: &str,
    line2_a: &str,
    line1_b: &str,
    line2_b: &str,
    start_min: f64,
    end_min: f64,
    step_min: f64,
    threshold_km: f64,
) -> NifResult<Term<'a>> {
    let ok = rustler::types::atom::Atom::from_str(env, "ok")?;
    let error = rustler::types::atom::Atom::from_str(env, "error")?;

    // Parse and initialize once per satellite — Satellite caches the satrec
    // so subsequent propagate calls are pure step kernels. AFSPC opsmode
    // matches historical sidereon behavior calibrated against AFSPC reference
    // catalogs (see `propagation.rs` for the same rationale).
    let s1 = match Satellite::from_tle_with_opsmode(line1_a, line2_a, OpsMode::Afspc) {
        Ok(s) => s,
        Err(e) => return Ok((error, format!("failed to parse TLE 1: {e}")).encode(env)),
    };
    let s2 = match Satellite::from_tle_with_opsmode(line1_b, line2_b, OpsMode::Afspc) {
        Ok(s) => s,
        Err(e) => return Ok((error, format!("failed to parse TLE 2: {e}")).encode(env)),
    };

    // Epoch offset: TLE2 epoch - TLE1 epoch in minutes. Computed in split-JD
    // form to preserve precision over multi-decade epochs.
    let e1 = s1.epoch_jd();
    let e2 = s2.epoch_jd();
    let epoch_offset2_min = ((e2.0 - e1.0) + (e2.1 - e1.1)) * 1440.0;

    // Coarse scan + golden section refinement.
    let n_steps = ((end_min - start_min) / step_min).ceil() as usize;
    let mut results: Vec<(f64, f64)> = Vec::new();
    let mut prev_dist = f64::MAX;
    let mut prev_t = start_min;
    let mut decreasing = false;

    for i in 0..=n_steps {
        let t = (start_min + i as f64 * step_min).min(end_min);

        let d = match dist_at(&s1, &s2, epoch_offset2_min, t) {
            Some(d) => d,
            None => {
                prev_dist = f64::MAX;
                decreasing = false;
                prev_t = t;
                continue;
            }
        };

        if d > prev_dist && decreasing {
            let search_start = (prev_t - step_min).max(start_min);
            if let Some((tca, tca_dist)) =
                golden_search(&s1, &s2, epoch_offset2_min, search_start, t)
            {
                if tca_dist < threshold_km {
                    results.push((tca, tca_dist));
                }
            }
        }

        decreasing = d < prev_dist;
        prev_dist = d;
        prev_t = t;
    }

    Ok((ok, results).encode(env))
}
