//! Rustler boundary that mirrors the canonical `sidereon-core` physical
//! constants and solver defaults.
//!
//! Pure glue: every value below is read straight from a `sidereon_core` public
//! constant, never redefined here. The Elixir side keeps literal copies for
//! compile-time ergonomics (module attributes, defaults), and a drift test
//! asserts each literal is bit-equal to the value these NIFs return, so a future
//! edit cannot silently diverge a binding constant or default from the core.

use rustler::{Encoder, Env, Term};
use sidereon_core::astro::constants::earth::{GM_EARTH_KM3_S2, J2_EARTH};
use sidereon_core::astro::math::robust::HUBER_K;
use sidereon_core::constants::{C_M_S, AU_KM, OMEGA_E_DOT_RAD_S, WGS84_A_KM, WGS84_E2, WGS84_F};
use sidereon_core::positioning::{
    SurfaceMet, DEFAULT_ROBUST_MAX_OUTER, DEFAULT_ROBUST_OUTER_TOL_M, DEFAULT_ROBUST_SCALE_FLOOR_M,
};
use sidereon_core::precise_positioning::defaults as ppp_defaults;
use sidereon_core::rtk_filter::defaults as rtk_defaults;
use sidereon_core::rtk_filter::defaults::{CODE_SIGMA_M, MAX_ITERATIONS, PHASE_SIGMA_M};

fn put<'a>(env: Env<'a>, map: Term<'a>, key: &str, value: impl Encoder) -> Term<'a> {
    let atom = rustler::types::atom::Atom::from_str(env, key).expect("atom key");
    map.map_put(atom.to_term(env), value).expect("map_put")
}

/// The physical constants the Elixir `Sidereon.Constants` module mirrors, read
/// from their canonical `sidereon_core` homes.
#[rustler::nif]
fn core_constants(env: Env<'_>) -> Term<'_> {
    let m = Term::map_new(env);
    let m = put(env, m, "speed_of_light_m_s", C_M_S);
    let m = put(env, m, "gm_earth_km3_s2", GM_EARTH_KM3_S2);
    let m = put(env, m, "wgs84_a_km", WGS84_A_KM);
    let m = put(env, m, "wgs84_f", WGS84_F);
    let m = put(env, m, "wgs84_e2", WGS84_E2);
    let m = put(env, m, "j2_earth", J2_EARTH);
    let m = put(env, m, "omega_e_dot_rad_s", OMEGA_E_DOT_RAD_S);
    put(env, m, "au_km", AU_KM)
}

/// The solver defaults the Elixir binding mirrors, read from their canonical
/// `sidereon_core` homes. Covers the RTK measurement/iteration/convergence
/// defaults (`rtk_filter::defaults`), the static-PPP convergence defaults
/// (`precise_positioning::defaults`), the robust SPP IRLS defaults
/// (`positioning::DEFAULT_ROBUST_*`), the standard-atmosphere surface
/// meteorology defaults (`positioning::SurfaceMet::default()`), and the publicly
/// exported Huber constant (`astro::math::robust::HUBER_K`).
#[rustler::nif]
fn core_defaults(env: Env<'_>) -> Term<'_> {
    let m = Term::map_new(env);

    // RTK measurement / iteration / convergence defaults.
    let m = put(env, m, "rtk_code_sigma_m", CODE_SIGMA_M);
    let m = put(env, m, "rtk_phase_sigma_m", PHASE_SIGMA_M);
    let m = put(env, m, "rtk_max_iterations", MAX_ITERATIONS as i64);
    let m = put(env, m, "rtk_position_tol_m", rtk_defaults::POSITION_TOL_M);
    let m = put(env, m, "rtk_ambiguity_tol_m", rtk_defaults::AMBIGUITY_TOL_M);
    let m = put(env, m, "rtk_ratio_threshold", rtk_defaults::RATIO_THRESHOLD);
    let m = put(
        env,
        m,
        "rtk_partial_min_ambiguities",
        rtk_defaults::PARTIAL_MIN_AMBIGUITIES as i64,
    );

    // Static-PPP convergence / iteration / integer defaults.
    let m = put(env, m, "ppp_position_tol_m", ppp_defaults::POSITION_TOLERANCE_M);
    let m = put(env, m, "ppp_clock_tol_m", ppp_defaults::CLOCK_TOLERANCE_M);
    let m = put(
        env,
        m,
        "ppp_ambiguity_tol_m",
        ppp_defaults::AMBIGUITY_TOLERANCE_M,
    );
    let m = put(env, m, "ppp_ztd_tol_m", ppp_defaults::ZTD_TOLERANCE_M);
    let m = put(env, m, "ppp_max_iterations", ppp_defaults::MAX_ITERATIONS as i64);
    let m = put(env, m, "ppp_ratio_threshold", ppp_defaults::RATIO_THRESHOLD);

    // Robust SPP IRLS defaults.
    let m = put(env, m, "robust_scale_floor_m", DEFAULT_ROBUST_SCALE_FLOOR_M);
    let m = put(env, m, "robust_max_outer", DEFAULT_ROBUST_MAX_OUTER as i64);
    let m = put(env, m, "robust_outer_tol_m", DEFAULT_ROBUST_OUTER_TOL_M);

    // Standard-atmosphere surface meteorology defaults, read from
    // `SurfaceMet::default()` so the troposphere term's fallback pressure /
    // temperature / humidity in the binding cannot diverge from the core.
    let met = SurfaceMet::default();
    let m = put(env, m, "surface_met_pressure_hpa", met.pressure_hpa);
    let m = put(env, m, "surface_met_temperature_k", met.temperature_k);
    let m = put(
        env,
        m,
        "surface_met_relative_humidity",
        met.relative_humidity,
    );

    put(env, m, "huber_k", HUBER_K)
}
