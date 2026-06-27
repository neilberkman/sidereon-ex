//! JPL SPK/BSP ephemeris file reader.
//!
//! This module is a thin NIF shim over `sidereon_core::astro::spk`, the single
//! validated SPK reader. The core reader parses the DAF container and evaluates
//! SPK segment types 2 (Chebyshev position), 3 (Chebyshev state), and 21
//! (Extended Modified Difference Arrays), so the Elixir binding reads all three
//! through the same code path the rest of the engine uses.
//!
//! Bodies are addressed by raw NAIF integer code: the Elixir layer maps its body
//! atoms to codes and passes arbitrary integer codes straight through, which is
//! what lets spacecraft / minor-planet kernels (e.g. 433 Eros, code 20000433) be
//! queried in addition to the planetary bodies in DE-series kernels.

use rustler::NifResult;
use sidereon_core::astro::spk::Spk;
use std::fs;

/// J2000.0 epoch as a Julian Date (TDB).
const J2000_JD: f64 = 2451545.0;

/// Seconds per day.
const SECONDS_PER_DAY: f64 = 86400.0;

/// Convert a split Julian Date (TDB) to ET seconds past J2000.0 TDB.
///
/// The split form keeps the integer-day subtraction exact, preserving the full
/// precision of the fractional day for the seconds-scale multiplication that the
/// SPK record selection and Chebyshev/MDA arguments depend on.
fn jd_to_et_seconds(jd_whole: f64, jd_fraction: f64) -> f64 {
    (jd_whole - J2000_JD + jd_fraction) * SECONDS_PER_DAY
}

/// NIF: get_body_position(file_path, target_code, observer_code, jd_whole, jd_fraction)
///
/// Accepts NAIF integer body codes and a split Julian Date (TDB) for full
/// precision. Returns `{x, y, z}` of the target relative to the observer, in km,
/// in the segment's reference frame (J2000/ICRF for standard kernels).
pub(crate) fn get_body_position_impl(
    file_path: String,
    target_code: i32,
    observer_code: i32,
    jd_whole: f64,
    jd_fraction: f64,
) -> NifResult<(f64, f64, f64)> {
    let bytes = fs::read(&file_path)
        .map_err(|e| rustler::Error::Term(Box::new(format!("cannot read {file_path}: {e}"))))?;

    let spk = Spk::from_bytes(&bytes).map_err(|e| rustler::Error::Term(Box::new(e.to_string())))?;

    let et = jd_to_et_seconds(jd_whole, jd_fraction);

    let state = spk
        .spk_state(target_code, observer_code, et)
        .map_err(|e| rustler::Error::Term(Box::new(e.to_string())))?;

    Ok((
        state.position_km[0],
        state.position_km[1],
        state.position_km[2],
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn jd_to_et_seconds_j2000_is_zero() {
        assert_eq!(jd_to_et_seconds(J2000_JD, 0.0), 0.0);
    }

    #[test]
    fn jd_to_et_seconds_one_day() {
        assert!((jd_to_et_seconds(J2000_JD + 1.0, 0.0) - SECONDS_PER_DAY).abs() < 1e-6);
    }

    #[test]
    fn jd_to_et_seconds_split_preserves_fraction() {
        // Whole day + half day fraction => 1.5 * 86400 seconds.
        let et = jd_to_et_seconds(J2000_JD + 1.0, 0.5);
        assert!((et - 1.5 * SECONDS_PER_DAY).abs() < 1e-6);
    }

    // Delegation smoke test against the committed real type-21 kernel (433 Eros
    // from JPL Horizons). Reference: CSPICE spkgeo(20000433, et, "J2000", 10).
    // This proves the Elixir SPK path reaches a type-21 segment through the core
    // reader, which the previous hand-rolled type-2-only reader could not do.
    #[test]
    fn real_type21_kernel_matches_cspice_reference() {
        const KERNEL: &[u8] = include_bytes!("../../../test/fixtures/spk/horizons_eros_type21.bsp");

        let dir = std::env::temp_dir();
        let path = dir.join("sidereon_nif_eros_type21.bsp");
        fs::write(&path, KERNEL).expect("write temp kernel");

        // (et seconds past J2000 TDB, [x, y, z] km) from CSPICE.
        let et = 757339200.0_f64;
        let expected = [198083634.33689928, 56306354.00566181, 67761020.0290685];

        let jd_fraction = et / SECONDS_PER_DAY;
        let (x, y, z) = get_body_position_impl(
            path.to_string_lossy().into_owned(),
            20000433,
            10,
            J2000_JD,
            jd_fraction,
        )
        .expect("type-21 query");

        // Magnitudes are ~1e8 km; allow a tight absolute tolerance that the
        // split-JD round trip and core evaluation comfortably satisfy.
        assert!((x - expected[0]).abs() < 1e-3, "x: {x} vs {}", expected[0]);
        assert!((y - expected[1]).abs() < 1e-3, "y: {y} vs {}", expected[1]);
        assert!((z - expected[2]).abs() < 1e-3, "z: {z} vs {}", expected[2]);

        let _ = fs::remove_file(&path);
    }
}
