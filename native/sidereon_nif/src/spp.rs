//! Rustler boundary for the `sidereon-core` single-point-positioning (SPP)
//! least-squares PVT solve.
//!
//! This module is **pure glue**: it decodes Erlang terms into the crate's
//! [`SolveInputs`], drives the shared [`estimate`] selector under the reference
//! strategy, and encodes the
//! [`ReceiverSolution`] back. No transmit-time iteration, no least-squares
//! numerics, no atmospheric
//! model, and no frame conversion lives here — those are the crate's
//! responsibility. The SP3 product is reused from the [`Sp3Resource`] handle the
//! `sp3_parse/1` NIF already returns; this call never touches the filesystem.
//!
//! Boundary units: pseudoranges and the initial guess are meters, epoch scalars
//! are seconds (and a fractional day-of-year), pressure is hPa, temperature is
//! kelvin, relative humidity is a `[0, 1]` fraction. The returned position is
//! ITRF/IGS ECEF meters and the geodetic latitude/longitude are radians, exactly
//! as the crate produces them.

use sidereon_core::{
    ephemeris::Sp3,
    estimation::{
        estimate, EstimateError, EstimateInput, EstimateOptions, EstimateOutput, StrategyId,
    },
    positioning::{
        solve_spp_batch_parallel, solve_spp_batch_serial, solve_with_fallback, BroadcastReason,
        Corrections, EphemerisSource, FallbackError, FixSource, KlobucharCoeffs, Observation,
        ReceiverSolution, RejectionReason, RobustConfig, SolveInputs, SolvePolicy,
        SolvePolicyError, SourcedSolution, SppError, SurfaceMet, DEFAULT_ROBUST_OUTER_TOL_M,
    },
    quality::{SolutionValidationError, SolutionValidationOptions},
    staleness::StalenessPolicy,
    GnssSatelliteId, GnssSystem,
};

use crate::broadcast::BroadcastResource;
use crate::staleness::{metadata_term, selection_error_term};
use rustler::types::atom;
use rustler::types::tuple::make_tuple;
use rustler::{Encoder, Env, Error, NifResult, ResourceArc, Term};

use crate::sp3::Sp3Resource;
use std::collections::BTreeMap;

#[rustler::nif]
fn spp_residual_rms_m(residuals_m: Vec<f64>) -> f64 {
    sidereon_core::positioning::residual_rms(&residuals_m)
}

/// Map a GNSS single-letter system identifier (e.g. `"G"`) onto the crate's
/// [`GnssSystem`]. Pure identifier translation; mirrors `sp3::system_from_letter`.
fn system_from_letter(letter: &str) -> NifResult<GnssSystem> {
    let c = letter
        .chars()
        .next()
        .ok_or_else(|| Error::Term(Box::new("empty GNSS system letter")))?;
    GnssSystem::from_letter(c)
        .ok_or_else(|| Error::Term(Box::new(format!("unknown GNSS system letter {letter:?}"))))
}

/// The Elixir-facing reason for a failed solve, as a pure value with no `Env`
/// dependency, so the `SppError` → public-reason mapping is unit-testable
/// without the BEAM runtime. The satellite-carrying variants render the offender
/// with the crate's canonical `Display` token (e.g. `"G01"`) so the reason stays
/// informative without leaking crate internals. [`spp_error_term`] is the thin
/// encoder that turns this into the actual `{:error, ...}` term.
#[derive(Debug, Clone, PartialEq, Eq)]
enum SppErrorReason {
    InvalidInput,
    TooFewSatellites { used: i64, required: i64 },
    SingularGeometry,
    DuplicateObservation { satellite: String },
    EphemerisLost { satellite: String },
    IonosphereUnsupported { satellite: String },
}

impl SppErrorReason {
    /// The atom name the Elixir wrapper destructures as the error reason. These
    /// strings are the public contract (`Sidereon.GNSS.Positioning.solve/4`), so a
    /// rename here is a breaking change.
    fn atom_name(&self) -> &'static str {
        match self {
            SppErrorReason::InvalidInput => "invalid_input",
            SppErrorReason::TooFewSatellites { .. } => "too_few_satellites",
            SppErrorReason::SingularGeometry => "singular_geometry",
            SppErrorReason::DuplicateObservation { .. } => "duplicate_observation",
            SppErrorReason::EphemerisLost { .. } => "ephemeris_lost",
            SppErrorReason::IonosphereUnsupported { .. } => "ionosphere_unsupported",
        }
    }
}

/// Map an [`SppError`] onto its pure [`SppErrorReason`]. Total over the enum, so
/// every variant — including the defensive `Singular` / `EphemerisLost` paths
/// that real SP3 inputs do not naturally reach — has a tested mapping.
fn spp_error_reason(e: &SppError) -> SppErrorReason {
    match e {
        SppError::InvalidInput { .. } => SppErrorReason::InvalidInput,
        SppError::TooFewSatellites { used, required } => SppErrorReason::TooFewSatellites {
            used: *used as i64,
            required: *required as i64,
        },
        SppError::Singular(_) => SppErrorReason::SingularGeometry,
        SppError::DuplicateObservation { satellite } => SppErrorReason::DuplicateObservation {
            satellite: satellite.to_string(),
        },
        SppError::EphemerisLost { satellite } => SppErrorReason::EphemerisLost {
            satellite: satellite.to_string(),
        },
        SppError::IonosphereUnsupported { satellite } => SppErrorReason::IonosphereUnsupported {
            satellite: satellite.to_string(),
        },
    }
}

/// The bare reason term (atom or tagged tuple, no `:error` wrapper) for an
/// [`SppError`]. This is the nested-reason form used where a solve error is
/// carried inside a larger result, e.g. the precise-to-broadcast fallback's
/// `{:precise, reason}` / `{:precise_degraded_unusable, staleness, reason}`
/// shapes. [`spp_error_term`] keeps the historical FLAT `{:error, tag, ..}`
/// shape that `Sidereon.GNSS.Positioning.Decode` already destructures, so the
/// two encoders are intentionally separate.
pub(crate) fn spp_error_reason_term<'a>(env: Env<'a>, e: &SppError) -> Term<'a> {
    let reason = spp_error_reason(e);
    let tag = atom_from(env, reason.atom_name());
    match reason {
        SppErrorReason::InvalidInput => tag,
        SppErrorReason::TooFewSatellites { used, required } => (tag, used, required).encode(env),
        SppErrorReason::SingularGeometry => tag,
        SppErrorReason::DuplicateObservation { satellite } => (tag, satellite).encode(env),
        SppErrorReason::EphemerisLost { satellite } => (tag, satellite).encode(env),
        SppErrorReason::IonosphereUnsupported { satellite } => (tag, satellite).encode(env),
    }
}

/// Translate an [`SppError`] into the `{:error, reason}` term the Elixir wrapper
/// maps to a public reason. A thin `Env`-bound wrapper over [`spp_error_reason`].
pub(crate) fn spp_error_term<'a>(env: Env<'a>, e: &SppError) -> Term<'a> {
    let reason = spp_error_reason(e);
    let tag = atom_from(env, reason.atom_name());
    match reason {
        SppErrorReason::InvalidInput => (atom::error(), tag).encode(env),
        SppErrorReason::TooFewSatellites { used, required } => {
            (atom::error(), tag, used, required).encode(env)
        }
        SppErrorReason::SingularGeometry => (atom::error(), tag).encode(env),
        SppErrorReason::DuplicateObservation { satellite } => {
            (atom::error(), tag, satellite).encode(env)
        }
        SppErrorReason::EphemerisLost { satellite } => (atom::error(), tag, satellite).encode(env),
        SppErrorReason::IonosphereUnsupported { satellite } => {
            (atom::error(), tag, satellite).encode(env)
        }
    }
}

fn validation_error_term<'a>(env: Env<'a>, error: SolutionValidationError) -> Term<'a> {
    match error {
        SolutionValidationError::InvalidOptions { .. } => {
            (atom::error(), atom_from(env, "invalid_options")).encode(env)
        }
        SolutionValidationError::InvalidResiduals => {
            (atom::error(), atom_from(env, "invalid_residuals")).encode(env)
        }
        SolutionValidationError::DegenerateGeometryRankDeficient => (
            atom::error(),
            (
                atom_from(env, "degenerate_geometry"),
                atom_from(env, "rank_deficient"),
            ),
        )
            .encode(env),
        SolutionValidationError::DegenerateGeometryPdop(pdop) => {
            (atom::error(), (atom_from(env, "degenerate_geometry"), pdop)).encode(env)
        }
        SolutionValidationError::ImplausiblePosition(radius) => (
            atom::error(),
            (atom_from(env, "implausible_position"), radius),
        )
            .encode(env),
        SolutionValidationError::NoConvergence(rms) => {
            (atom::error(), (atom_from(env, "no_convergence"), rms)).encode(env)
        }
    }
}

fn solve_policy_error_term<'a>(env: Env<'a>, error: &SolvePolicyError) -> Term<'a> {
    match error {
        SolvePolicyError::Solve(error) => spp_error_term(env, error),
        SolvePolicyError::Validation(error) => validation_error_term(env, *error),
        SolvePolicyError::NoCoarseSolution => {
            (atom::error(), atom_from(env, "no_coarse_solution")).encode(env)
        }
    }
}

/// The atom name for a solver termination [`Status`]. Pure (no `Env`) so the
/// status → atom mapping is unit-testable; the strings are the public contract
/// surfaced as `Solution.metadata.status`.
///
/// [`Status`]: sidereon_core::astro::math::least_squares::Status
fn status_atom_name(status: sidereon_core::astro::math::least_squares::Status) -> &'static str {
    use sidereon_core::astro::math::least_squares::Status;
    match status {
        Status::GradientTolerance => "gradient_tolerance",
        Status::CostTolerance => "cost_tolerance",
        Status::StepTolerance => "step_tolerance",
        Status::MaxEvaluations => "max_evaluations",
    }
}

/// Intern a runtime atom. Glue helper so error reasons and rejection reasons are
/// encoded as atoms (idiomatic on the Elixir side) rather than strings.
pub(crate) fn atom_from<'a>(env: Env<'a>, name: &str) -> Term<'a> {
    atom::Atom::from_str(env, name)
        .map(|a| a.encode(env))
        .unwrap_or_else(|_| name.encode(env))
}

/// Encode the converged [`ReceiverSolution`] as the `{:ok, solution}` term the
/// Elixir wrapper destructures. The solution body is a fixed-arity tuple:
///
/// ```text
/// {{x_m, y_m, z_m},                      # ITRF/IGS ECEF position, meters
///  rx_clock_s,                           # reference-system clock bias, seconds
///  {lat_rad, lon_rad, height_m} | nil,   # geodetic, when requested
///  {gdop, pdop, hdop, vdop, tdop} | nil, # DOP, when the geometry is full rank
///  [residual_m, ...],                    # post-fit residuals, used_sats order
///  ["G01", ...],                         # used satellites
///  [{"G07", :low_elevation}, ...],       # rejected satellites + reason atom
///  {iterations, converged, status,       # solver metadata, plus the opt-in
///   ionosphere_applied, troposphere_applied,
///   outer_iterations,                    # Huber/IRLS outer reweighting count (0 off)
///   final_robust_scale_m | nil,
///   used_count, ["G", ...], redundancy,
///   raim_checkable},                     # core-computed integrity metadata
///  [{"G", clock_s}, {"E", clock_s}],     # per-system receiver clocks, seconds
///  [{"G", tdop}, {"E", tdop}]}           # per-system TDOP, ascending system order
/// ```
pub(crate) fn encode_solution<'a>(env: Env<'a>, sol: &ReceiverSolution) -> Term<'a> {
    (atom::ok(), encode_solution_body(env, sol)).encode(env)
}

/// The fixed-arity solution body tuple, WITHOUT the `{:ok, _}` wrapper. Shared by
/// [`encode_solution`] (the SP3/broadcast SPP entry points) and the
/// precise-to-broadcast fallback's [`SourcedSolution`] encoder, which pairs this
/// body with the fix-source provenance.
pub(crate) fn encode_solution_body<'a>(env: Env<'a>, sol: &ReceiverSolution) -> Term<'a> {
    let pos = sol.position.as_array();
    let position = (pos[0], pos[1], pos[2]);

    let geodetic: Term<'a> = match sol.geodetic {
        Some(g) => (g.lat_rad, g.lon_rad, g.height_m).encode(env),
        None => atom::nil().encode(env),
    };

    let dop: Term<'a> = match &sol.dop {
        Some(d) => (d.gdop, d.pdop, d.hdop, d.vdop, d.tdop).encode(env),
        None => atom::nil().encode(env),
    };

    // A3: per-constellation TDOP as [{system_letter, tdop}, ...] in ascending
    // system order (mirrors `system_clocks`). Empty only when the geometry is
    // rank-deficient (i.e. `dop` is nil).
    let system_tdops: Vec<(String, f64)> = sol
        .system_tdops
        .iter()
        .map(|(sys, tdop)| (sys.letter().to_string(), *tdop))
        .collect();

    let used_sats: Vec<String> = sol.used_sats.iter().map(|s| s.to_string()).collect();

    let rejected_sats: Vec<(String, Term<'a>)> = sol
        .rejected_sats
        .iter()
        .map(|r| {
            let reason = match r.reason {
                RejectionReason::NoEphemeris => atom_from(env, "no_ephemeris"),
                RejectionReason::LowElevation => atom_from(env, "low_elevation"),
            };
            (r.satellite_id.to_string(), reason)
        })
        .collect();

    // Per-system receiver clocks as [{system_letter, clock_s}, ...].
    let system_clocks: Vec<(String, f64)> = sol
        .system_clocks_s
        .iter()
        .map(|(sys, clk)| (sys.letter().to_string(), *clk))
        .collect();

    let status = atom_from(env, status_atom_name(sol.metadata.status));
    let final_robust_scale: Term<'a> = match sol.metadata.final_robust_scale_m {
        Some(scale) => scale.encode(env),
        None => atom::nil().encode(env),
    };
    let systems: Vec<String> = sol
        .metadata
        .systems
        .iter()
        .map(|sys| sys.letter().to_string())
        .collect();
    let metadata = make_tuple(
        env,
        &[
            (sol.metadata.iterations as i64).encode(env),
            sol.metadata.converged.encode(env),
            status,
            sol.metadata.ionosphere_applied.encode(env),
            sol.metadata.troposphere_applied.encode(env),
            (sol.metadata.outer_iterations as i64).encode(env),
            final_robust_scale,
            (sol.metadata.used_count as i64).encode(env),
            systems.encode(env),
            (sol.metadata.redundancy as i64).encode(env),
            sol.metadata.raim_checkable.encode(env),
        ],
    );

    // The body has nine fields, past the arity of the blanket tuple `Encoder`,
    // so it is assembled with `make_tuple` over the already-encoded terms.
    make_tuple(
        env,
        &[
            position.encode(env),
            sol.rx_clock_s.encode(env),
            geodetic,
            dop,
            sol.residuals_m.encode(env),
            used_sats.encode(env),
            rejected_sats.encode(env),
            metadata,
            system_clocks.encode(env),
            system_tdops.encode(env),
        ],
    )
}

/// Solve single-point positioning for one receive epoch against a loaded SP3
/// handle.
///
/// Dirty-CPU: the transmit-time iteration and trust-region least-squares solve
/// are unbounded relative to the 1 ms NIF budget. `observations` is a list of
/// `{sat_token, pseudorange_m}` pairs where `sat_token` is the canonical
/// SP3/RINEX id string (e.g. `"G01"`); the system letter and PRN are parsed via
/// [`GnssSystem::from_letter`]. The three epoch scalars, the four-element initial
/// guess `[x_m, y_m, z_m, b_m]`, the correction toggles, the Klobuchar
/// alpha/beta coefficient tuples, and the surface meteorology are forwarded
/// verbatim into [`SolveInputs`]; no domain math happens here.
///
/// Returns `{:ok, solution}` (see [`encode_solution`]) or `{:error, reason}`
/// where `reason` is the mapped [`SppError`] atom.
/// Decode the opt-in Huber robust-reweighting argument. `nil` (the off path)
/// decodes to `None`, byte-identical to the static elevation-weighted solve. A
/// `{huber_k, scale_floor_m, max_outer}` tuple decodes to a [`RobustConfig`];
/// the outer-loop position step tolerance is left at the crate default. This is
/// the only place the boundary touches the robust path, so the off path is a
/// straight `None`.
fn is_nil(term: Term<'_>) -> bool {
    term.is_atom()
        && term
            .atom_to_string()
            .map(|name| name == "nil")
            .unwrap_or(false)
}

fn decode_robust(term: Term<'_>) -> NifResult<Option<RobustConfig>> {
    if term.is_atom() {
        // The only valid atom is `nil` (off). Any other atom is a contract error.
        let name: String = term.atom_to_string().unwrap_or_default();
        if name == "nil" {
            return Ok(None);
        }
        return Err(Error::Term(Box::new(format!(
            "robust must be nil or {{k, sigma, max_iter}}, got atom {name:?}"
        ))));
    }
    let (huber_k, scale_floor_m, max_outer): (f64, f64, u64) = term.decode()?;
    Ok(Some(RobustConfig {
        huber_k,
        scale_floor_m,
        max_outer: max_outer as usize,
        outer_tol_m: DEFAULT_ROBUST_OUTER_TOL_M,
    }))
}

/// Decode the GLONASS FDMA channel map. The Elixir wrapper passes the public
/// `%{slot => channel}` map as a list of `{slot, channel}` pairs (the codebase
/// idiom for map arguments; see the RAIM `weights` and DGNSS `corrections`
/// boundaries), so the term decodes as `Vec<(u8, i8)>` and collects into the
/// core's [`BTreeMap<u8, i8>`]. An empty list yields an empty map, leaving every
/// non-GLONASS solve bit-identical. Channel-range validity ([-7, +6]) is the
/// crate's concern: an out-of-range channel for an observed GLONASS satellite
/// with the ionosphere requested surfaces as
/// [`SppError::IonosphereUnsupported`], not a boundary rejection.
fn decode_glonass_channels(term: Term<'_>) -> NifResult<BTreeMap<u8, i8>> {
    let pairs: Vec<(u8, i8)> = term.decode().map_err(|_| {
        Error::Term(Box::new(
            "glonass_channels must be a list of {slot, channel} integer pairs",
        ))
    })?;
    Ok(pairs.into_iter().collect())
}

fn decode_optional_f64(term: Term<'_>, name: &'static str) -> NifResult<Option<f64>> {
    if is_nil(term) {
        return Ok(None);
    }
    term.decode::<f64>()
        .map(Some)
        .map_err(|_| Error::Term(Box::new(format!("{name} must be nil or a float"))))
}

fn decode_optional_usize(term: Term<'_>, name: &'static str) -> NifResult<Option<usize>> {
    if is_nil(term) {
        return Ok(None);
    }
    let value = term.decode::<i64>().map_err(|_| {
        Error::Term(Box::new(format!(
            "{name} must be nil or a non-negative integer"
        )))
    })?;
    if value < 0 {
        return Err(Error::Term(Box::new(format!(
            "{name} must be nil or a non-negative integer"
        ))));
    }
    Ok(Some(value as usize))
}

fn decode_policy(max_pdop: Term<'_>, coarse_search_seeds: Term<'_>) -> NifResult<SolvePolicy> {
    Ok(SolvePolicy {
        validation: SolutionValidationOptions {
            max_pdop: decode_optional_f64(max_pdop, "max_pdop")?,
            ..SolutionValidationOptions::default()
        },
        coarse_search_seeds: decode_optional_usize(coarse_search_seeds, "coarse_search_seeds")?,
    })
}

/// Decode the common SPP term arguments into a [`SolveInputs`]. Shared by the
/// SP3-backed and broadcast-backed entry points, which differ only in the
/// ephemeris source they pass to the solver.
#[allow(clippy::too_many_arguments)]
pub(crate) fn build_solve_inputs(
    observations: Vec<(String, f64)>,
    t_rx_j2000_s: f64,
    t_rx_second_of_day_s: f64,
    day_of_year: f64,
    initial_guess: (f64, f64, f64, f64),
    apply_iono: bool,
    apply_tropo: bool,
    alpha: (f64, f64, f64, f64),
    beta: (f64, f64, f64, f64),
    pressure_hpa: f64,
    temperature_k: f64,
    relative_humidity: f64,
    robust: Option<RobustConfig>,
) -> NifResult<SolveInputs> {
    let mut obs = Vec::with_capacity(observations.len());
    for (token, pseudorange_m) in &observations {
        let (letter, rest) = token.split_at(token.char_indices().nth(1).map_or(0, |(i, _)| i));
        let system = system_from_letter(letter)?;
        let prn: u8 = rest
            .parse()
            .map_err(|_| Error::Term(Box::new(format!("bad satellite token {token:?}"))))?;
        obs.push(Observation {
            satellite_id: GnssSatelliteId::new(system, prn)
                .map_err(crate::errors::invalid_input)?,
            pseudorange_m: *pseudorange_m,
        });
    }

    Ok(SolveInputs {
        observations: obs,
        t_rx_j2000_s,
        t_rx_second_of_day_s,
        day_of_year,
        initial_guess: [
            initial_guess.0,
            initial_guess.1,
            initial_guess.2,
            initial_guess.3,
        ],
        corrections: Corrections {
            ionosphere: apply_iono,
            troposphere: apply_tropo,
        },
        klobuchar: KlobucharCoeffs {
            alpha: [alpha.0, alpha.1, alpha.2, alpha.3],
            beta: [beta.0, beta.1, beta.2, beta.3],
        },
        // Set by the broadcast path from the NAV header's BDSA/BDSB; the SP3 path
        // (no broadcast ionosphere coefficients) leaves it None.
        beidou_klobuchar: None,
        // Galileo NeQuick-G coefficients come from a broadcast NAV header; the
        // None fallback preserves the historical Klobuchar path bit-identically.
        galileo_nequick: None,
        // GLONASS FDMA channel map; empty by default (no GLONASS observation, or
        // ionosphere off). The SPP entry points set it from the caller-supplied
        // %{slot => channel} map via `decode_glonass_channels`; every non-GLONASS
        // solve stays bit-identical to the empty-map path.
        glonass_channels: BTreeMap::new(),
        met: SurfaceMet {
            pressure_hpa,
            temperature_k,
            relative_humidity,
        },
        robust,
    })
}

/// Run the solve against any ephemeris source and encode the result term.
fn solve_to_term<'a>(
    env: Env<'a>,
    eph: &dyn EphemerisSource,
    inputs: &SolveInputs,
    with_geodetic: bool,
    policy: SolvePolicy,
) -> Term<'a> {
    let options = EstimateOptions::new(StrategyId::spp_reference());
    match estimate(
        EstimateInput::Spp {
            eph,
            inputs,
            with_geodetic,
            policy,
        },
        options,
    ) {
        Ok(EstimateOutput::Spp(sol)) => encode_solution(env, &sol),
        Err(EstimateError::Spp(e)) => solve_policy_error_term(env, &e),
        Ok(_) | Err(_) => {
            unreachable!("an SPP input yields an SPP solution or an SPP error")
        }
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
fn spp_solve<'a>(
    env: Env<'a>,
    handle: ResourceArc<Sp3Resource>,
    observations: Vec<(String, f64)>,
    t_rx_j2000_s: f64,
    t_rx_second_of_day_s: f64,
    day_of_year: f64,
    initial_guess: (f64, f64, f64, f64),
    apply_iono: bool,
    apply_tropo: bool,
    alpha: (f64, f64, f64, f64),
    beta: (f64, f64, f64, f64),
    pressure_hpa: f64,
    temperature_k: f64,
    relative_humidity: f64,
    with_geodetic: bool,
    robust: Term<'a>,
    max_pdop: Term<'a>,
    coarse_search_seeds: Term<'a>,
    glonass_channels: Term<'a>,
) -> NifResult<Term<'a>> {
    let robust = decode_robust(robust)?;
    let policy = decode_policy(max_pdop, coarse_search_seeds)?;
    let glonass_channels = decode_glonass_channels(glonass_channels)?;
    let mut inputs = build_solve_inputs(
        observations,
        t_rx_j2000_s,
        t_rx_second_of_day_s,
        day_of_year,
        initial_guess,
        apply_iono,
        apply_tropo,
        alpha,
        beta,
        pressure_hpa,
        temperature_k,
        relative_humidity,
        robust,
    )?;
    inputs.glonass_channels = glonass_channels;
    Ok(solve_to_term(
        env,
        &handle.sp3,
        &inputs,
        with_geodetic,
        policy,
    ))
}

/// As [`spp_solve`] but against a parsed broadcast-navigation product
/// ([`BroadcastResource`]) instead of an SP3 precise product.
#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
fn spp_solve_broadcast<'a>(
    env: Env<'a>,
    handle: ResourceArc<BroadcastResource>,
    observations: Vec<(String, f64)>,
    t_rx_j2000_s: f64,
    t_rx_second_of_day_s: f64,
    day_of_year: f64,
    initial_guess: (f64, f64, f64, f64),
    apply_iono: bool,
    apply_tropo: bool,
    alpha: (f64, f64, f64, f64),
    beta: (f64, f64, f64, f64),
    pressure_hpa: f64,
    temperature_k: f64,
    relative_humidity: f64,
    with_geodetic: bool,
    robust: Term<'a>,
    max_pdop: Term<'a>,
    coarse_search_seeds: Term<'a>,
    glonass_channels: Term<'a>,
) -> NifResult<Term<'a>> {
    let robust = decode_robust(robust)?;
    let policy = decode_policy(max_pdop, coarse_search_seeds)?;
    let glonass_channels = decode_glonass_channels(glonass_channels)?;
    let mut inputs = build_solve_inputs(
        observations,
        t_rx_j2000_s,
        t_rx_second_of_day_s,
        day_of_year,
        initial_guess,
        apply_iono,
        apply_tropo,
        alpha,
        beta,
        pressure_hpa,
        temperature_k,
        relative_humidity,
        robust,
    )?;
    inputs.glonass_channels = glonass_channels;
    // A BeiDou satellite uses the NAV product's own broadcast Klobuchar
    // coefficients (BDSA/BDSB) when present, rather than the GPS set the caller
    // supplied; both feed the same model, frequency-scaled to B1I.
    let iono = handle.store.iono_corrections();
    if let Some(bds) = iono.beidou {
        inputs.beidou_klobuchar = Some(KlobucharCoeffs {
            alpha: bds.alpha,
            beta: bds.beta,
        });
    }
    // A Galileo satellite uses the NAV product's broadcast NeQuick-G
    // effective-ionisation coefficients (GAL ai0/ai1/ai2) when present; the
    // broadcast truth is generated with NeQuick, so the default Klobuchar
    // fallback would mis-model the Galileo ionosphere.
    inputs.galileo_nequick = iono.galileo;
    Ok(solve_to_term(
        env,
        &handle.store,
        &inputs,
        with_geodetic,
        policy,
    ))
}

/// One epoch's solve inputs in a batch request, as the Elixir map the binding
/// passes per element. The per-epoch varying data (observations, the three epoch
/// scalars, the initial guess) and the per-epoch correction configuration cross
/// together so a batch can mix configurations across epochs without the binding
/// restricting the core capability. Decoded into a [`SolveInputs`] via the same
/// [`build_solve_inputs`] glue the single-epoch entry points use.
#[derive(Debug, Clone, rustler::NifMap)]
struct BatchEpoch {
    observations: Vec<(String, f64)>,
    t_rx_j2000_s: f64,
    t_rx_second_of_day_s: f64,
    day_of_year: f64,
    initial_guess: (f64, f64, f64, f64),
    apply_iono: bool,
    apply_tropo: bool,
    alpha: (f64, f64, f64, f64),
    beta: (f64, f64, f64, f64),
    pressure_hpa: f64,
    temperature_k: f64,
    relative_humidity: f64,
    glonass_channels: Vec<(u8, i8)>,
}

impl BatchEpoch {
    /// Turn one batch element into the core [`SolveInputs`], reusing the shared
    /// observation/correction marshalling and threading the per-epoch GLONASS
    /// channel map. The `robust` config is shared across the batch (the caller's
    /// single batch-wide reweighting choice).
    fn into_solve_inputs(self, robust: Option<RobustConfig>) -> NifResult<SolveInputs> {
        let mut inputs = build_solve_inputs(
            self.observations,
            self.t_rx_j2000_s,
            self.t_rx_second_of_day_s,
            self.day_of_year,
            self.initial_guess,
            self.apply_iono,
            self.apply_tropo,
            self.alpha,
            self.beta,
            self.pressure_hpa,
            self.temperature_k,
            self.relative_humidity,
            robust,
        )?;
        inputs.glonass_channels = self.glonass_channels.into_iter().collect();
        Ok(inputs)
    }
}

/// Encode each per-epoch [`SolvePolicyError`]/[`ReceiverSolution`] result as the
/// same `{:ok, body}` / `{:error, ..}` term the single-epoch entry points return,
/// so the Elixir layer reuses its existing per-epoch decoder element-wise.
fn encode_batch_results<'a>(
    env: Env<'a>,
    results: Vec<Result<ReceiverSolution, SolvePolicyError>>,
) -> Term<'a> {
    let terms: Vec<Term<'a>> = results
        .iter()
        .map(|result| match result {
            Ok(sol) => encode_solution(env, sol),
            Err(error) => solve_policy_error_term(env, error),
        })
        .collect();
    terms.encode(env)
}

/// Decode the shared batch arguments common to the serial and parallel entry
/// points into the per-epoch [`SolveInputs`] list and the shared [`SolvePolicy`].
fn decode_batch<'a>(
    epochs: Vec<BatchEpoch>,
    robust: Term<'a>,
    max_pdop: Term<'a>,
    coarse_search_seeds: Term<'a>,
) -> NifResult<(Vec<SolveInputs>, SolvePolicy)> {
    let robust = decode_robust(robust)?;
    let policy = decode_policy(max_pdop, coarse_search_seeds)?;
    let inputs = epochs
        .into_iter()
        .map(|epoch| epoch.into_solve_inputs(robust))
        .collect::<NifResult<Vec<_>>>()?;
    Ok((inputs, policy))
}

/// Solve a batch of independent SPP epochs against one shared SP3 handle,
/// serially. Each element of the returned list is the standard single-epoch solve
/// term (`{:ok, body}` or `{:error, ..}`) for the matching input epoch, in order.
///
/// Dirty-CPU: a batch is many unbounded trust-region solves. Pure glue over
/// [`solve_spp_batch_serial`]; no solve numerics live here.
#[rustler::nif(schedule = "DirtyCpu")]
fn spp_solve_batch_serial<'a>(
    env: Env<'a>,
    handle: ResourceArc<Sp3Resource>,
    epochs: Vec<BatchEpoch>,
    with_geodetic: bool,
    robust: Term<'a>,
    max_pdop: Term<'a>,
    coarse_search_seeds: Term<'a>,
) -> NifResult<Term<'a>> {
    let (inputs, policy) = decode_batch(epochs, robust, max_pdop, coarse_search_seeds)?;
    let results = solve_spp_batch_serial(&handle.sp3, &inputs, with_geodetic, policy);
    Ok(encode_batch_results(env, results))
}

/// As [`spp_solve_batch_serial`] but fanning the independent per-epoch solves
/// across the crate's rayon thread pool. Element `i` is byte-for-byte identical to
/// the serial result (the core proves this); throughput scales with cores.
///
/// Dirty-CPU: a batch is many unbounded trust-region solves. Pure glue over
/// [`solve_spp_batch_parallel`]; no solve numerics live here.
#[rustler::nif(schedule = "DirtyCpu")]
fn spp_solve_batch_parallel<'a>(
    env: Env<'a>,
    handle: ResourceArc<Sp3Resource>,
    epochs: Vec<BatchEpoch>,
    with_geodetic: bool,
    robust: Term<'a>,
    max_pdop: Term<'a>,
    coarse_search_seeds: Term<'a>,
) -> NifResult<Term<'a>> {
    let (inputs, policy) = decode_batch(epochs, robust, max_pdop, coarse_search_seeds)?;
    let results = solve_spp_batch_parallel(&handle.sp3, &inputs, with_geodetic, policy);
    Ok(encode_batch_results(env, results))
}

/// Encode a [`FixSource`] as the Elixir provenance term carried alongside a
/// fallback solution. `Precise` carries the staleness metadata tuple;
/// `Broadcast` carries the reason it substituted broadcast, so a degraded or
/// substituted source is never reported silently.
fn fix_source_term<'a>(env: Env<'a>, source: &FixSource) -> Term<'a> {
    match source {
        FixSource::Precise(meta) => {
            (atom_from(env, "precise"), metadata_term(env, meta)).encode(env)
        }
        FixSource::Broadcast(reason) => (
            atom_from(env, "broadcast"),
            broadcast_reason_term(env, reason),
        )
            .encode(env),
    }
}

/// Encode a [`BroadcastReason`] into its Elixir tagged form.
fn broadcast_reason_term<'a>(env: Env<'a>, reason: &BroadcastReason) -> Term<'a> {
    match reason {
        BroadcastReason::PreciseUnavailable(selection_error) => (
            atom_from(env, "precise_unavailable"),
            selection_error_term(env, selection_error),
        )
            .encode(env),
        BroadcastReason::PreciseDegradedUnusable { staleness, error } => (
            atom_from(env, "precise_degraded_unusable"),
            metadata_term(env, staleness),
            spp_error_reason_term(env, error),
        )
            .encode(env),
    }
}

/// Encode a [`SourcedSolution`] as `{:ok, {solution_body, source}}`.
fn encode_sourced_solution<'a>(env: Env<'a>, sourced: &SourcedSolution) -> Term<'a> {
    (
        atom::ok(),
        (
            encode_solution_body(env, &sourced.solution),
            fix_source_term(env, &sourced.source),
        ),
    )
        .encode(env)
}

/// Encode a [`FallbackError`] as `{:error, {:precise | :broadcast, reason}}`,
/// tagged with which path's solve failed.
fn fallback_error_term<'a>(env: Env<'a>, error: &FallbackError) -> Term<'a> {
    let (path, spp_error) = match error {
        FallbackError::Precise(e) => ("precise", e),
        FallbackError::Broadcast(e) => ("broadcast", e),
    };
    (
        atom::error(),
        (atom_from(env, path), spp_error_reason_term(env, spp_error)),
    )
        .encode(env)
}

/// Solve preferring precise SP3 products and falling back to the broadcast
/// product, reporting which source produced the fix and how stale it is.
///
/// Thin wrapper over [`solve_with_fallback`]: the precise products are the
/// caller's already-parsed [`Sp3Resource`] handles, the broadcast product is a
/// parsed [`BroadcastResource`], and `max_staleness_s` is the staleness cap in
/// seconds. The broadcast NAV header's BeiDou Klobuchar / Galileo NeQuick-G
/// ionosphere coefficients are applied to the inputs exactly as in
/// [`spp_solve_broadcast`], since the broadcast fallback solve uses them. No
/// staleness or solve math runs here; this only marshals terms and surfaces the
/// [`SourcedSolution`] provenance.
#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
fn spp_solve_with_fallback<'a>(
    env: Env<'a>,
    precise: Vec<ResourceArc<Sp3Resource>>,
    broadcast: ResourceArc<BroadcastResource>,
    observations: Vec<(String, f64)>,
    t_rx_j2000_s: f64,
    t_rx_second_of_day_s: f64,
    day_of_year: f64,
    initial_guess: (f64, f64, f64, f64),
    apply_iono: bool,
    apply_tropo: bool,
    alpha: (f64, f64, f64, f64),
    beta: (f64, f64, f64, f64),
    pressure_hpa: f64,
    temperature_k: f64,
    relative_humidity: f64,
    with_geodetic: bool,
    max_staleness_s: f64,
    glonass_channels: Term<'a>,
) -> NifResult<Term<'a>> {
    let glonass_channels = decode_glonass_channels(glonass_channels)?;
    let mut inputs = build_solve_inputs(
        observations,
        t_rx_j2000_s,
        t_rx_second_of_day_s,
        day_of_year,
        initial_guess,
        apply_iono,
        apply_tropo,
        alpha,
        beta,
        pressure_hpa,
        temperature_k,
        relative_humidity,
        // The fallback entry uses the crate's plain `solve` on both paths, so no
        // Huber/IRLS reweighting is threaded here.
        None,
    )?;
    inputs.glonass_channels = glonass_channels;
    // The broadcast fallback solve uses the NAV product's own BeiDou (BDSA/BDSB)
    // and Galileo (NeQuick-G) broadcast ionosphere coefficients when present,
    // matching `spp_solve_broadcast`; the GPS Klobuchar set the caller supplied
    // still drives the GPS path.
    let iono = broadcast.store.iono_corrections();
    if let Some(bds) = iono.beidou {
        inputs.beidou_klobuchar = Some(KlobucharCoeffs {
            alpha: bds.alpha,
            beta: bds.beta,
        });
    }
    inputs.galileo_nequick = iono.galileo;

    // `solve_with_fallback` takes a contiguous `&[Sp3]`; the precise products are
    // held in separate resource handles, so they are gathered into a local slice.
    let products: Vec<Sp3> = precise.iter().map(|h| h.sp3.clone()).collect();
    let policy = StalenessPolicy::seconds(max_staleness_s);

    match solve_with_fallback(&products, &broadcast.store, &inputs, policy, with_geodetic) {
        Ok(sourced) => Ok(encode_sourced_solution(env, &sourced)),
        Err(error) => Ok(fallback_error_term(env, &error)),
    }
}

#[cfg(test)]
mod mapping_tests {
    //! Mechanical coverage of the boundary mappings that term encoding wraps.
    //! These exercise every `SppError` variant and every solver `Status`,
    //! including the defensive `Singular` / `EphemerisLost` paths that a real
    //! SP3 product does not naturally reach, so the advertised public reasons
    //! stay correct without depending on a physics fixture to trigger them.
    use super::*;
    use sidereon_core::astro::math::least_squares::{SolveError, Status};

    fn gps(prn: u8) -> GnssSatelliteId {
        GnssSatelliteId::new(GnssSystem::Gps, prn).expect("valid satellite id")
    }

    #[test]
    fn spp_error_reason_is_total_over_every_variant() {
        assert_eq!(
            spp_error_reason(&SppError::TooFewSatellites {
                used: 3,
                required: 5
            }),
            SppErrorReason::TooFewSatellites {
                used: 3,
                required: 5
            }
        );
        assert_eq!(
            spp_error_reason(&SppError::Singular(SolveError::SingularJacobian)),
            SppErrorReason::SingularGeometry
        );
        assert_eq!(
            spp_error_reason(&SppError::DuplicateObservation { satellite: gps(7) }),
            SppErrorReason::DuplicateObservation {
                satellite: "G07".to_string()
            }
        );
        assert_eq!(
            spp_error_reason(&SppError::EphemerisLost { satellite: gps(12) }),
            SppErrorReason::EphemerisLost {
                satellite: "G12".to_string()
            }
        );
        assert_eq!(
            spp_error_reason(&SppError::IonosphereUnsupported {
                satellite: GnssSatelliteId::new(GnssSystem::BeiDou, 5).expect("valid satellite id")
            }),
            SppErrorReason::IonosphereUnsupported {
                satellite: "C05".to_string()
            }
        );
    }

    #[test]
    fn error_reason_atom_names_are_the_documented_public_reasons() {
        assert_eq!(
            SppErrorReason::TooFewSatellites {
                used: 0,
                required: 4
            }
            .atom_name(),
            "too_few_satellites"
        );
        assert_eq!(
            SppErrorReason::SingularGeometry.atom_name(),
            "singular_geometry"
        );
        assert_eq!(
            SppErrorReason::DuplicateObservation {
                satellite: String::new()
            }
            .atom_name(),
            "duplicate_observation"
        );
        assert_eq!(
            SppErrorReason::EphemerisLost {
                satellite: String::new()
            }
            .atom_name(),
            "ephemeris_lost"
        );
        assert_eq!(
            SppErrorReason::IonosphereUnsupported {
                satellite: String::new()
            }
            .atom_name(),
            "ionosphere_unsupported"
        );
    }

    #[test]
    fn status_atom_names_cover_every_status() {
        assert_eq!(
            status_atom_name(Status::GradientTolerance),
            "gradient_tolerance"
        );
        assert_eq!(status_atom_name(Status::CostTolerance), "cost_tolerance");
        assert_eq!(status_atom_name(Status::StepTolerance), "step_tolerance");
        assert_eq!(status_atom_name(Status::MaxEvaluations), "max_evaluations");
    }
}
