//! Rustler boundary for the `sidereon-core` SP3 precise-ephemeris product.
//!
//! This module is **pure glue**: it decodes Erlang terms, calls
//! the `sidereon_core::ephemeris` public APIs, manages the parsed product as a
//! Rustler resource handle, and encodes results back. No SP3 grammar, no unit
//! conversion, and no interpolation numerics live here: those are the crate's
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
use sidereon_core::data::{ArchiveCompression, DistributionSource, ProductDate};
use sidereon_core::ephemeris::{
    align_clock_reference, check_continuity, clock_reference_offset, merge as crate_merge,
    parse_exact_sp3, validate_exact_sp3, AgreementMetric, ContinuityDefect, ContinuityOptions,
    EpochAgreement, ExactSp3Coverage, ExactSp3Request, MergeCombine, MergeFlag, MergeOptions,
    MergePrecedenceScope, MergeReport, OrbitClass, OutlierRejectOptions, Sp3, Sp3ArtifactIdentity,
    Sp3FrameLabelSet, Sp3FrameReconciliation, Sp3FrameReconciliationMethod,
    Sp3FrameReconciliationOptions, Sp3MergeInputIdentity, Sp3State, SpeedBound,
};
use sidereon_core::{Error as CoreError, GnssSatelliteId, GnssSystem};
use std::collections::BTreeSet;

mod atoms {
    rustler::atoms! {
        ok,
        error,
        epoch_out_of_range,
        unknown_satellite,
        exact_sp3_validation_failed,
        half_open,
        inclusive
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

/// Opaque validated exact-SP3 request. Keeping the core value in a resource
/// preserves identity-derived agency and format-revision constraints without
/// asking Elixir to reconstruct them.
pub struct ExactSp3RequestResource {
    request: ExactSp3Request,
}

type Vec3Tuple = (f64, f64, f64);
/// `{kind, satellite, {from_j2000_s | nil, to_j2000_s | nil}, {magnitude | nil, bound | nil}}`
type ContinuityDefectTuple = (
    String,
    String,
    (Option<f64>, Option<f64>),
    (Option<f64>, Option<f64>),
);
/// `{defects, {pairs_checked, residuals_checked, residuals_skipped}}`
type ContinuityReportTuple = (Vec<ContinuityDefectTuple>, (u64, u64, u64));
type FlagsTuple = (bool, bool, bool, bool);
type ExactRequestFields = (
    (i32, u8, u8),
    Option<String>,
    String,
    String,
    Option<String>,
    Option<String>,
);
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

#[rustler::resource_impl]
impl rustler::Resource for ExactSp3RequestResource {}

fn exact_coverage<'a>(env: Env<'a>, coverage: ExactSp3Coverage) -> Term<'a> {
    match coverage {
        ExactSp3Coverage::HalfOpen => atoms::half_open().encode(env),
        ExactSp3Coverage::Inclusive => atoms::inclusive().encode(env),
    }
}

fn exact_error<'a>(env: Env<'a>, error: impl std::fmt::Display) -> Term<'a> {
    (
        atoms::error(),
        (atoms::exact_sp3_validation_failed(), error.to_string()),
    )
        .encode(env)
}

/// Map a GNSS single-letter system identifier (as the Elixir side passes it,
/// e.g. `"G"`) onto the crate's [`GnssSystem`]. Pure identifier translation.
pub(crate) fn system_from_letter(letter: &str) -> NifResult<GnssSystem> {
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

#[allow(clippy::too_many_arguments)]
fn merge_options_from_terms(
    position_tolerance_m: f64,
    clock_tolerance_s: f64,
    min_agree: usize,
    clock_min_common: usize,
    combine: String,
    precedence_scope: String,
    outlier_reject: Option<(f64, f64)>,
    target_epoch_interval_s: Option<f64>,
    system_letters: Vec<String>,
    asserted_frame_label_sets: Vec<Vec<String>>,
    helmert_frame_reconciliation: bool,
) -> NifResult<MergeOptions> {
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
    let precedence_scope = match precedence_scope.as_str() {
        "cell" => MergePrecedenceScope::Cell,
        "satellite_arc" => MergePrecedenceScope::SatelliteArc,
        other => {
            return Err(Error::Term(Box::new(format!(
                "unknown precedence scope {other:?}"
            ))))
        }
    };
    let asserted_equivalent_label_sets = asserted_frame_label_sets
        .into_iter()
        .enumerate()
        .map(|(idx, labels)| {
            if labels.len() < 2 {
                return Err(Error::Term(Box::new(format!(
                    "asserted_frame_label_sets[{idx}] must contain at least two labels"
                ))));
            }
            let labels = labels
                .into_iter()
                .map(|label| label.trim().to_string())
                .collect::<Vec<_>>();
            if labels.iter().any(String::is_empty) {
                return Err(Error::Term(Box::new(format!(
                    "asserted_frame_label_sets[{idx}] contains an empty label"
                ))));
            }
            Ok(Sp3FrameLabelSet::new(labels))
        })
        .collect::<NifResult<Vec<_>>>()?;

    // Mutate-a-default rather than a struct literal: MergeOptions is
    // non-exhaustive, so per-epoch provenance, the continuity post-condition,
    // and any future option the core learns stay at their defaults (off)
    // without this conversion having to name them.
    let mut options = MergeOptions::default();
    options.position_tolerance_m = position_tolerance_m;
    options.clock_tolerance_s = clock_tolerance_s;
    options.min_agree = min_agree;
    options.clock_min_common = clock_min_common;
    options.combine = combine;
    options.precedence_scope = precedence_scope;
    options.outlier_reject =
        outlier_reject.map(
            |(position_tolerance_m, clock_tolerance_s)| OutlierRejectOptions {
                position_tolerance_m,
                clock_tolerance_s,
            },
        );
    options.target_epoch_interval_s = target_epoch_interval_s;
    options.systems = if system_letters.is_empty() {
        None
    } else {
        Some(systems_from_letters(system_letters)?)
    };
    options.frame_reconciliation = Sp3FrameReconciliationOptions {
        asserted_equivalent_label_sets,
        helmert: helmert_frame_reconciliation,
    };
    Ok(options)
}

/// Map a time-scale abbreviation onto the core [`TimeScale`]. Pure translation;
/// used so an Elixir caller can name the epoch's scale explicitly when it is not
/// the file's own header scale.
pub(crate) fn time_scale_from_abbrev(abbrev: &str) -> NifResult<TimeScale> {
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

/// Epoch count declared on SP3 header line 1.
#[rustler::nif]
fn sp3_declared_epoch_count(handle: ResourceArc<Sp3Resource>) -> u64 {
    handle.sp3.declared_epoch_count()
}

/// Start epoch declared on SP3 header line 1, in product-scale J2000 seconds.
#[rustler::nif]
fn sp3_declared_start_j2000_seconds(handle: ResourceArc<Sp3Resource>) -> Option<f64> {
    handle.sp3.declared_start_j2000_s()
}

/// Attest that a parsed or merged product is physically continuous.
///
/// `orbit_class` selects the physical earth-fixed speed bound
/// (`"meo_gnss" | "geosynchronous" | "leo"`); passing `nil` disables that gate.
/// `residual_tolerance_m` enables the sensitive hold-out interpolation residual
/// check; passing `nil` disables it. Returns the defects with their epochs and
/// magnitudes plus the counts of what was actually examined, so a caller can
/// tell "checked and clean" from "not checked".
#[rustler::nif(schedule = "DirtyCpu")]
fn sp3_check_continuity(
    handle: ResourceArc<Sp3Resource>,
    orbit_class: Option<String>,
    residual_tolerance_m: Option<f64>,
) -> Result<ContinuityReportTuple, String> {
    let speed_bound = match orbit_class.as_deref() {
        None => None,
        Some("meo_gnss") => Some(SpeedBound::OrbitClass(OrbitClass::MeoGnss)),
        Some("geosynchronous") => Some(SpeedBound::OrbitClass(OrbitClass::Geosynchronous)),
        Some("leo") => Some(SpeedBound::OrbitClass(OrbitClass::Leo)),
        Some(other) => return Err(format!("unknown orbit class: {other}")),
    };
    let options = ContinuityOptions {
        speed_bound,
        residual_tolerance_m,
    };
    let report = check_continuity(&handle.sp3.precise_ephemeris_samples(), &options);
    Ok((
        report
            .defects
            .iter()
            .map(continuity_defect_to_tuple)
            .collect(),
        (
            report.pairs_checked as u64,
            report.residuals_checked as u64,
            report.residuals_skipped as u64,
        ),
    ))
}

/// One continuity defect: `{kind, satellite, {from_j2000_s, to_j2000_s},
/// {magnitude, bound}}`. `magnitude` and `bound` carry the implied speed and its
/// bound for a speed-bound defect, and the residual and its tolerance for a
/// hold-out residual defect; both are `nil` for the input-shape defects.
fn continuity_defect_to_tuple(defect: &ContinuityDefect) -> ContinuityDefectTuple {
    match defect {
        ContinuityDefect::DuplicateEpoch {
            sat,
            epoch_j2000_s,
            occurrences,
        } => (
            "duplicate_epoch".to_string(),
            sat.to_string(),
            (Some(*epoch_j2000_s), Some(*epoch_j2000_s)),
            (Some(*occurrences as f64), None),
        ),
        ContinuityDefect::SingleSampleSeries { sat } => (
            "single_sample_series".to_string(),
            sat.to_string(),
            (None, None),
            (None, None),
        ),
        ContinuityDefect::SpeedBound {
            sat,
            from_j2000_s,
            to_j2000_s,
            implied_speed_m_s,
            bound_m_s,
            ..
        } => (
            "speed_bound".to_string(),
            sat.to_string(),
            (Some(*from_j2000_s), Some(*to_j2000_s)),
            (Some(*implied_speed_m_s), Some(*bound_m_s)),
        ),
        ContinuityDefect::HoldOutResidual {
            sat,
            preceding_j2000_s,
            epoch_j2000_s,
            residual_m,
            tolerance_m,
        } => (
            "hold_out_residual".to_string(),
            sat.to_string(),
            (Some(*preceding_j2000_s), Some(*epoch_j2000_s)),
            (Some(*residual_m), Some(*tolerance_m)),
        ),
    }
}

/// Parsed SP3 epoch grid as seconds since J2000 in the product's own time scale.
#[rustler::nif]
fn sp3_epochs_j2000_seconds(handle: ResourceArc<Sp3Resource>) -> Vec<f64> {
    handle.sp3.epochs_j2000_seconds()
}

/// Construct and validate a source-independent exact-SP3 request.
#[rustler::nif]
#[allow(clippy::too_many_arguments)]
fn sp3_exact_request_new<'a>(
    env: Env<'a>,
    year: i32,
    month: u8,
    day: u8,
    issue: Option<String>,
    span: String,
    sample: String,
    expected_agency: Option<String>,
) -> Term<'a> {
    let request = ProductDate::new(year, month, day)
        .map_err(|error| error.to_string())
        .and_then(|date| {
            ExactSp3Request::new(date, issue.as_deref(), &span, &sample)
                .map_err(|error| error.to_string())
        })
        .and_then(|request| match expected_agency.as_deref() {
            Some(agency) => request
                .with_expected_agency(agency)
                .map_err(|error| error.to_string()),
            None => Ok(request),
        });

    match request {
        Ok(request) => (
            atoms::ok(),
            ResourceArc::new(ExactSp3RequestResource { request }),
        )
            .encode(env),
        Err(error) => exact_error(env, error),
    }
}

/// Construct an exact-SP3 request from a complete core-validated identity.
#[rustler::nif]
fn sp3_exact_request_from_identity<'a>(env: Env<'a>, fields: Vec<String>) -> Term<'a> {
    let request = crate::data::product_identity(fields)
        .map_err(|error| error.to_string())
        .and_then(|identity| {
            ExactSp3Request::from_identity(&identity).map_err(|error| error.to_string())
        });
    match request {
        Ok(request) => (
            atoms::ok(),
            ResourceArc::new(ExactSp3RequestResource { request }),
        )
            .encode(env),
        Err(error) => exact_error(env, error),
    }
}

/// Return the normalized public request fields carried by an opaque request.
#[rustler::nif]
fn sp3_exact_request_fields(handle: ResourceArc<ExactSp3RequestResource>) -> ExactRequestFields {
    let date = handle.request.date();
    (
        (date.year, date.month, date.day),
        handle.request.issue().map(ToOwned::to_owned),
        handle.request.span().to_owned(),
        handle.request.sample().to_owned(),
        handle.request.format_version().map(ToOwned::to_owned),
        handle.request.expected_agency().map(ToOwned::to_owned),
    )
}

/// Return a cloned request with a validated producing-agency constraint.
#[rustler::nif]
fn sp3_exact_request_require_agency<'a>(
    env: Env<'a>,
    handle: ResourceArc<ExactSp3RequestResource>,
    agency: String,
) -> Term<'a> {
    match handle.request.clone().with_expected_agency(&agency) {
        Ok(request) => (
            atoms::ok(),
            ResourceArc::new(ExactSp3RequestResource { request }),
        )
            .encode(env),
        Err(error) => exact_error(env, error),
    }
}

/// Parse and validate exact SP3 bytes in one core operation.
#[rustler::nif(schedule = "DirtyCpu")]
fn sp3_parse_exact<'a>(
    env: Env<'a>,
    bytes: rustler::Binary<'a>,
    request: ResourceArc<ExactSp3RequestResource>,
) -> Term<'a> {
    match parse_exact_sp3(bytes.as_slice(), &request.request) {
        Ok((sp3, coverage)) => (
            atoms::ok(),
            (
                ResourceArc::new(Sp3Resource { sp3 }),
                exact_coverage(env, coverage),
            ),
        )
            .encode(env),
        Err(error) => exact_error(env, error),
    }
}

/// Validate an already parsed SP3 product against an exact request.
#[rustler::nif(schedule = "DirtyCpu")]
fn sp3_validate_exact<'a>(
    env: Env<'a>,
    product: ResourceArc<Sp3Resource>,
    request: ResourceArc<ExactSp3RequestResource>,
) -> Term<'a> {
    match validate_exact_sp3(&product.sp3, &request.request) {
        Ok(coverage) => (atoms::ok(), exact_coverage(env, coverage)).encode(env),
        Err(error) => exact_error(env, error),
    }
}

type PredictionEpochTuple = ((f64, f64), bool, Vec<String>, Vec<String>);

/// Per-epoch observed/predicted status and the contiguous observed-through
/// boundary, derived from the parsed SP3 record flags.
#[rustler::nif]
fn sp3_prediction_summary(
    handle: ResourceArc<Sp3Resource>,
) -> (Vec<PredictionEpochTuple>, Option<(f64, f64)>) {
    let summary = handle.sp3.prediction_summary();
    let epochs = summary
        .epochs
        .iter()
        .map(|epoch| {
            (
                instant_split(&epoch.epoch),
                epoch.is_observed(),
                epoch
                    .orbit_predicted_satellites
                    .iter()
                    .map(ToString::to_string)
                    .collect(),
                epoch
                    .clock_predicted_satellites
                    .iter()
                    .map(ToString::to_string)
                    .collect(),
            )
        })
        .collect();
    (epochs, summary.observed_through.as_ref().map(instant_split))
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
/// Operates only on the resource handle, no file I/O.
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

type AgreementCellTuple = (
    String,
    (f64, f64),
    (u64, f64, f64),
    (u64, Option<f64>, Option<f64>),
);
type EpochAgreementTuple = ((f64, f64), u64, (f64, f64), (Option<f64>, Option<f64>));
type AgreementAggregateTuple = (Option<f64>, Option<f64>, Option<f64>, Option<f64>);
type HelmertParametersTuple = (Vec<f64>, f64, Vec<f64>);
type HelmertRatesTuple = (Vec<f64>, f64, Vec<f64>);
type FrameReconciliationTuple = (
    (u64, String, String, String),
    (Option<Vec<String>>, (Option<String>, Option<String>)),
    (
        (Option<String>, Option<String>, bool),
        Option<f64>,
        Option<HelmertParametersTuple>,
    ),
    (
        Option<HelmertRatesTuple>,
        Option<String>,
        Option<(f64, f64)>,
        (u64, bool),
    ),
);

/// Split an [`Instant`] into the `(jd_whole, jd_fraction)` pair the SP3 epoch
/// tuples use, in the product's own time scale.
fn instant_split(epoch: &Instant) -> (f64, f64) {
    epoch
        .julian_date()
        .map(|jd| (jd.jd_whole, jd.fraction))
        .unwrap_or((0.0, 0.0))
}

/// Per-accepted-cell consensus agreement, nested so the tuple stays within the
/// Rustler encoder's small-tuple arity:
/// `{sat, {jd_whole, jd_fraction}, {position_members, position_rms_m, position_max_m},
///   {clock_members, clock_rms_s | nil, clock_max_s | nil}}`.
fn agreement_to_tuple(metric: &AgreementMetric) -> AgreementCellTuple {
    let (jd_whole, jd_fraction) = instant_split(&metric.epoch);
    (
        metric.satellite.to_string(),
        (jd_whole, jd_fraction),
        (
            metric.position_members as u64,
            metric.position_rms_m,
            metric.position_max_m,
        ),
        (
            metric.clock_members as u64,
            metric.clock_rms_s,
            metric.clock_max_s,
        ),
    )
}

/// Per-epoch aggregate agreement. RMS and the satellite count use multi-source
/// cells; position maximum covers every accepted cell, while clock maximum uses
/// multi-source clock cells to match the core epoch accessor:
/// `{{jd_whole, jd_fraction}, satellites, {position_rms_m, position_max_m},
///   {clock_rms_s | nil, clock_max_s | nil}}`.
fn epoch_agreement_to_tuple(agreement: &EpochAgreement) -> EpochAgreementTuple {
    let (jd_whole, jd_fraction) = instant_split(&agreement.epoch);
    (
        (jd_whole, jd_fraction),
        agreement.satellites as u64,
        (agreement.position_rms_m, agreement.position_max_m),
        (agreement.clock_rms_s, agreement.clock_max_s),
    )
}

/// Whole-product aggregate agreement. RMS values use multi-source cells;
/// maxima cover every accepted position cell and every clock-bearing cell:
/// `{position_rms_m | nil, position_max_m | nil, clock_rms_s | nil, clock_max_s | nil}`.
fn agreement_aggregate(report: &MergeReport) -> AgreementAggregateTuple {
    (
        report.position_agreement_rms_m(),
        report.position_agreement_max_m(),
        report.clock_agreement_rms_s(),
        report.clock_agreement_max_s(),
    )
}

fn frame_reconciliation_to_tuple(value: &Sp3FrameReconciliation) -> FrameReconciliationTuple {
    (
        (
            value.source_index as u64,
            value.source_label.clone(),
            value.target_label.clone(),
            match value.method {
                Sp3FrameReconciliationMethod::AssertedEquivalence => "asserted_equivalence",
                Sp3FrameReconciliationMethod::Helmert => "helmert",
            }
            .to_string(),
        ),
        (
            value.asserted_label_set.clone(),
            (
                value.source_frame.map(|frame| frame.to_string()),
                value.target_frame.map(|frame| frame.to_string()),
            ),
        ),
        (
            (
                value.catalog_source_frame.map(|frame| frame.to_string()),
                value.catalog_target_frame.map(|frame| frame.to_string()),
                value.catalog_inverse,
            ),
            value.reference_epoch_year,
            value.parameters.map(|parameters| {
                (
                    parameters.translation_mm.to_vec(),
                    parameters.scale_ppb,
                    parameters.rotation_mas.to_vec(),
                )
            }),
        ),
        (
            value.rates.map(|rates| {
                (
                    rates.translation_mm_per_year.to_vec(),
                    rates.scale_ppb_per_year,
                    rates.rotation_mas_per_year.to_vec(),
                )
            }),
            value.provenance.clone(),
            value.epoch_year_span.map(|span| (span[0], span[1])),
            (value.records_affected as u64, value.identity),
        ),
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
/// `{merged_handle, {quarantined, single_source, position_outliers,
/// clock_outliers, details}}` where each
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
    precedence_scope: String,
    outlier_reject: Option<(f64, f64)>,
    target_epoch_interval_s: Option<f64>,
    system_letters: Vec<String>,
    asserted_frame_label_sets: Vec<Vec<String>>,
    helmert_frame_reconciliation: bool,
) -> NifResult<Term<'a>> {
    let opts = merge_options_from_terms(
        position_tolerance_m,
        clock_tolerance_s,
        min_agree,
        clock_min_common,
        combine,
        precedence_scope,
        outlier_reject,
        target_epoch_interval_s,
        system_letters,
        asserted_frame_label_sets,
        helmert_frame_reconciliation,
    )?;

    // The crate merge takes owned products; the handles are shared/immutable, so
    // clone each into the merge input.
    let sources: Vec<Sp3> = handles.iter().map(|h| h.sp3.clone()).collect();
    let (merged, report) =
        crate_merge(&sources, &opts).map_err(|e| Error::Term(Box::new(e.to_string())))?;

    let handle = ResourceArc::new(Sp3Resource { sp3: merged });
    let quarantined: Vec<_> = report.quarantined.iter().map(flag_to_tuple).collect();
    let single_source: Vec<_> = report.single_source.iter().map(flag_to_tuple).collect();
    let position_outliers: Vec<_> = report.position_outliers.iter().map(flag_to_tuple).collect();
    let clock_outliers: Vec<_> = report.clock_outliers.iter().map(flag_to_tuple).collect();
    let frame_reconciliations: Vec<_> = report
        .frame_reconciliations
        .iter()
        .map(frame_reconciliation_to_tuple)
        .collect();

    // B2: per-cell + per-epoch agreement statistics and the whole-product
    // aggregate, so the caller can quantify how tightly the analysis centers
    // clustered about the combined product.
    let agreement: Vec<_> = report.agreement.iter().map(agreement_to_tuple).collect();
    let per_epoch_agreement: Vec<_> = report
        .per_epoch_agreement()
        .iter()
        .map(epoch_agreement_to_tuple)
        .collect();
    let aggregate = agreement_aggregate(&report);

    Ok((
        handle,
        (
            quarantined,
            single_source,
            position_outliers,
            clock_outliers,
            (
                frame_reconciliations,
                (aggregate, agreement, per_epoch_agreement),
            ),
        ),
    )
        .encode(env))
}

type ArtifactIdentityTuple = (
    (Vec<String>, Vec<String>),
    (String, String),
    (String, u64),
    (String, u64),
    String,
);

type MergeInputIdentityTuple = (
    u8,
    String,
    Vec<ArtifactIdentityTuple>,
    Option<Vec<ArtifactIdentityTuple>>,
);

fn artifact_identity_tuple(value: Sp3ArtifactIdentity) -> ArtifactIdentityTuple {
    (
        (
            crate::data::product_identity_fields(&value.requested_identity),
            crate::data::product_identity_fields(&value.resolved_identity),
        ),
        (
            value.distribution_source.code().to_string(),
            value.official_filename,
        ),
        (value.product_sha256, value.product_byte_length),
        (value.archive_sha256, value.archive_byte_length),
        value.compression.as_str().to_string(),
    )
}

/// Build the shared, versioned identity for exact SP3 artifacts and merge policy.
#[rustler::nif]
#[allow(clippy::too_many_arguments)]
fn sp3_merge_input_identity(
    contributors: Vec<ArtifactIdentityTuple>,
    position_tolerance_m: f64,
    clock_tolerance_s: f64,
    min_agree: usize,
    clock_min_common: usize,
    combine: String,
    precedence_scope: String,
    outlier_reject: Option<(f64, f64)>,
    target_epoch_interval_s: Option<f64>,
    system_letters: Vec<String>,
    asserted_frame_label_sets: Vec<Vec<String>>,
    helmert_frame_reconciliation: bool,
) -> NifResult<MergeInputIdentityTuple> {
    let contributors = contributors
        .into_iter()
        .map(
            |(
                (requested, resolved),
                (source, official_filename),
                (product_sha256, product_byte_length),
                (archive_sha256, archive_byte_length),
                compression,
            )| {
                let distribution_source = match source.as_str() {
                    "direct" => DistributionSource::Direct,
                    "nasa_cddis" => DistributionSource::NasaCddis,
                    "local_file" => DistributionSource::LocalFile,
                    "in_memory" => DistributionSource::InMemory,
                    _ => return Err(Error::Term(Box::new("unknown distribution source"))),
                };
                let compression = match compression.as_str() {
                    "gzip" => ArchiveCompression::Gzip,
                    "none" => ArchiveCompression::None,
                    _ => return Err(Error::Term(Box::new("unknown archive compression"))),
                };
                Ok(Sp3ArtifactIdentity {
                    requested_identity: crate::data::product_identity(requested)
                        .map_err(|error| Error::Term(Box::new(error.to_string())))?,
                    resolved_identity: crate::data::product_identity(resolved)
                        .map_err(|error| Error::Term(Box::new(error.to_string())))?,
                    distribution_source,
                    official_filename,
                    product_sha256,
                    product_byte_length,
                    archive_sha256,
                    archive_byte_length,
                    compression,
                })
            },
        )
        .collect::<NifResult<Vec<_>>>()?;
    let policy = merge_options_from_terms(
        position_tolerance_m,
        clock_tolerance_s,
        min_agree,
        clock_min_common,
        combine,
        precedence_scope,
        outlier_reject,
        target_epoch_interval_s,
        system_letters,
        asserted_frame_label_sets,
        helmert_frame_reconciliation,
    )?;
    let identity = Sp3MergeInputIdentity::new(&contributors, &policy)
        .map_err(|error| Error::Term(Box::new(error.to_string())))?;
    Ok((
        identity.schema_version,
        identity.stable_id,
        identity
            .contributors
            .into_iter()
            .map(artifact_identity_tuple)
            .collect(),
        identity.precedence_contributors.map(|contributors| {
            contributors
                .into_iter()
                .map(artifact_identity_tuple)
                .collect()
        }),
    ))
}

/// Serialize a loaded SP3 product to standard SP3-c/-d text (the inverse of
/// `sp3_parse/1`). Dirty-CPU: a full IGS day serializes many thousands of
/// records, unbounded relative to the 1 ms NIF budget.
#[rustler::nif(schedule = "DirtyCpu")]
fn sp3_to_iodata(handle: ResourceArc<Sp3Resource>) -> NifResult<String> {
    Ok(handle.sp3.to_sp3_string())
}
