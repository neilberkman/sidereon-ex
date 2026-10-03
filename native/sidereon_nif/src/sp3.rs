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

use crate::time::ExactEpochQueryResource;
use rustler::{Encoder, Env, Error, NifResult, ResourceArc, Term};
use sidereon_core::astro::time::model::{Instant, InstantRepr, JulianDateSplit, TimeScale};
use sidereon_core::data::{ArchiveCompression, DistributionSource, ProductDate};
use sidereon_core::ephemeris::{
    align_clock_reference, check_continuity, clock_reference_offset, merge as crate_merge,
    parse_exact_sp3, validate_exact_sp3, AgreementMetric, CellSelection, ClockOmissionReason,
    ContinuityDefect, ContinuityOptions, ContinuityOptionsError, DroppedEpochReason,
    EpochAgreement, EpochWindow, ExactSp3Coverage, ExactSp3Request, ExactSp3ValidationError,
    InterpolationNodes, MergeCombine, MergeContinuityCell, MergeContinuityCellRole,
    MergeContinuityReport, MergeContinuityViolation, MergeFlag, MergeOptions, MergePrecedenceScope,
    MergeReport, MergeToleranceError, MergeToleranceField, OrbitClass, OutlierRejectOptions,
    ProvenanceMode, Sp3, Sp3ArtifactIdentity, Sp3EpochIntervalError, Sp3FrameLabelSet,
    Sp3FrameReconciliation, Sp3FrameReconciliationMethod, Sp3FrameReconciliationOptions,
    Sp3InterpolationOptions, Sp3MergeInputIdentity, Sp3MergeInputIdentityError, Sp3State,
    Sp3WriteError, SpeedBound, StencilExtent, TransitionReason, WindowContinuityDecision,
    WindowContinuityVerdict,
};
use sidereon_core::positioning::EphemerisSource;
use sidereon_core::{Error as CoreError, GnssSatelliteId, GnssSystem};
use std::collections::BTreeSet;

mod atoms {
    rustler::atoms! {
        ok,
        error,
        epoch_out_of_range,
        unknown_satellite,
        unsupported_satellite_system,
        insufficient_precise_nodes,
        known,
        unknown,
        too_large,
        invalid_base,
        overflow,
        exact_sp3_validation_failed,
        half_open,
        inclusive,

        // Writer refusals
        accuracy_not_representable,
        accuracy_record_mismatch,
        accuracy_basis_missing,
        satellite_not_representable,
        text_not_column_safe,
        text_not_column_stable,
        blank_descriptor,
        empty_comment,
        text_too_wide,
        integer_too_wide,
        non_finite,
        number_too_wide,
        precision_not_representable,
        year_not_representable,
        epoch_not_restatable,
        epoch_time_scale_mismatch,
        header_time_scale_mismatch,
        epoch_count_mismatch,
        accuracy_code_count_mismatch,
        duplicate_satellite,
        epoch_array_length_mismatch,
        undeclared_satellite_record,
        conflicting_records,
        velocity_state_in_position_product,
        record_value_non_finite,
        record_value_too_wide,
        record_value_not_representable,
        record_reads_as_absent,
        record_fields_disagree,
        unhandled,
        nonfinite,

        // Writer refusal payload fields
        field,
        value,
        index,
        columns,
        decimals,
        epoch_index,
        year,
        field_seconds,
        residual_s,
        epoch_scale,
        header_scale,
        time_system,
        time_scale,
        declared,
        epochs,
        satellites,
        codes,
        satellite,
        system,
        prn,
        component,
        exponent,
        entries,
        column_value,
        stored,
        native,
        message,
        not_applicable,
        unavailable,
        term,

        // Exact-SP3 validation detail fields
        kind,
        debug,
        actual,
        issue,
        token,
        canonical,
        agency,
        expected,
        line_number,
        record_length,
        record,
        tokens,
        first_index,
        duplicate_index,
        requested_s,
        header_s,
        parsed,
        requested_j2000_s,
        declared_j2000_s,
        actual_j2000_s,
        requested_tick,
        declared_tick,
        requested,
        actual_s,
        span_s,
        cadence_s
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

/// Opaque core merge report retained for later window-scoped queries.
pub struct Sp3MergeReportResource {
    report: MergeReport,
}

type Vec3Tuple = (f64, f64, f64);
/// `{kind, satellite, {from_j2000_s | nil, to_j2000_s | nil}, {magnitude | nil,
/// bound | nil}, details}`
type ContinuityDefectTuple = (
    String,
    String,
    (Option<f64>, Option<f64>),
    (Option<f64>, Option<f64>),
    ContinuityDefectDetailsTerm,
);

/// Every field of a continuity defect's kind under the core's name; the fields
/// of other kinds are `nil`.
#[derive(Debug, Default, rustler::NifMap)]
struct ContinuityDefectDetailsTerm {
    epoch_j2000_s: Option<f64>,
    occurrences: Option<u64>,
    interval_s: Option<f64>,
    displacement_m: Option<f64>,
    implied_speed_m_s: Option<f64>,
    bound_m_s: Option<f64>,
    preceding_j2000_s: Option<f64>,
    residual_m: Option<f64>,
    tolerance_m: Option<f64>,
    node_epochs_j2000_s: Option<Vec<f64>>,
    sample_index: Option<u64>,
    reason: Option<String>,
}

/// JSON-safe details for typed SP3 option refusals.
#[derive(Debug, rustler::NifMap)]
pub(crate) struct Sp3ValidationErrorTerm {
    kind: String,
    field: String,
    value: String,
    reason: String,
}

pub(crate) fn interpolation_options_error_term(
    factor: f64,
    error: impl std::fmt::Display,
) -> Sp3ValidationErrorTerm {
    let reason = error.to_string();
    validation_error_term(
        "sp3_interpolation_options",
        "gap_threshold_factor",
        format!("{factor:?}"),
        &reason,
    )
}

fn validation_error_term(
    kind: &str,
    field: &str,
    value: String,
    reason: &str,
) -> Sp3ValidationErrorTerm {
    Sp3ValidationErrorTerm {
        kind: kind.to_string(),
        field: field.to_string(),
        value,
        reason: reason.to_string(),
    }
}

fn continuity_validation_term(error: ContinuityOptionsError) -> Sp3ValidationErrorTerm {
    validation_error_term(
        "continuity_options",
        error.field,
        format!("{:?}", error.value),
        &format!("{:?}", error.reason),
    )
}

fn interval_validation_term(error: Sp3EpochIntervalError) -> Sp3ValidationErrorTerm {
    validation_error_term(
        "sp3_epoch_interval",
        error.field,
        format!("{:?}", error.value),
        &format!("{:?}", error.reason),
    )
}

fn tolerance_validation_term(error: MergeToleranceError) -> Sp3ValidationErrorTerm {
    validation_error_term(
        "sp3_merge_tolerance",
        match error.field {
            MergeToleranceField::Position => "Position",
            MergeToleranceField::Clock => "Clock",
            MergeToleranceField::OutlierPosition => "OutlierPosition",
            MergeToleranceField::OutlierClock => "OutlierClock",
            _ => "unknown",
        },
        format!("{:?}", error.value),
        "not_finite_or_negative",
    )
}

fn identity_validation_term(error: Sp3MergeInputIdentityError) -> Sp3ValidationErrorTerm {
    match error {
        Sp3MergeInputIdentityError::InvalidTolerance(error) => tolerance_validation_term(error),
        Sp3MergeInputIdentityError::TargetEpochInterval(error) => interval_validation_term(error),
        Sp3MergeInputIdentityError::ContinuityOptions(error) => continuity_validation_term(error),
        other => validation_error_term(
            "sp3_merge_input_identity",
            "policy",
            String::new(),
            &other.to_string(),
        ),
    }
}

fn core_validation_error(error: CoreError) -> Error {
    match error {
        CoreError::Sp3EpochInterval(error) => {
            Error::Term(Box::new(interval_validation_term(error)))
        }
        CoreError::Sp3MergeTolerance(error) => {
            Error::Term(Box::new(tolerance_validation_term(error)))
        }
        CoreError::ContinuityOptions(error) => {
            Error::Term(Box::new(continuity_validation_term(error)))
        }
        other => Error::Term(Box::new(other.to_string())),
    }
}

/// How the merge arrived at the value it wrote for one channel of one cell:
/// `kind` `"single_source"` (with `source`), `"precedence"` (with `source` and
/// `members`) or `"combined"` (with `rule` and `members`).
#[derive(Debug, rustler::NifMap)]
struct CellSelectionTerm {
    kind: String,
    source: Option<u64>,
    rule: Option<String>,
    members: Vec<u64>,
}

/// One merged cell a continuity finding rests on.
#[derive(Debug, rustler::NifMap)]
struct MergeContinuityCellTerm {
    epoch_j2000_s: f64,
    role: String,
    selection: Option<CellSelectionTerm>,
}
/// `{defects, {pairs_checked, residuals_checked, residuals_skipped}}`
type ContinuityReportTuple = (Vec<ContinuityDefectTuple>, (u64, u64, u64));
/// `{defect, from_sources, to_sources, crosses_contributors, cells, sources}`
type MergeContinuityViolationTuple = (
    ContinuityDefectTuple,
    Vec<u64>,
    Vec<u64>,
    bool,
    Vec<MergeContinuityCellTerm>,
    Vec<u64>,
);
type MergeContinuityReportTuple = (ContinuityReportTuple, Vec<MergeContinuityViolationTuple>);
type WindowContinuityVerdictTuple = (
    String,
    bool,
    Vec<ContinuityDefectTuple>,
    Vec<MergeContinuityViolationTuple>,
    Vec<ContinuityDefectTuple>,
    Vec<MergeContinuityViolationTuple>,
);
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

#[rustler::resource_impl]
impl rustler::Resource for Sp3MergeReportResource {}

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

fn exact_float_value(value: f64) -> serde_json::Value {
    serde_json::Number::from_f64(value)
        .map(serde_json::Value::Number)
        .unwrap_or_else(|| serde_json::Value::String(format!("{value:?}")))
}

/// Stable, JSON-safe public detail for every current exact-SP3 validation
/// failure. Counts and ticks cross as decimal strings so values wider than a
/// BEAM integer remain exact; diagnostic floats use strings except for the
/// already-public declared-start pair.
fn exact_validation_error_detail(error: &ExactSp3ValidationError) -> serde_json::Value {
    use ExactSp3ValidationError as E;

    match error {
        E::Parse(value) => serde_json::json!({
            "kind": "parse", "error": value.to_string(), "debug": format!("{value:?}")
        }),
        E::Catalog(value) => serde_json::json!({
            "kind": "catalog", "error": value.to_string(), "debug": format!("{value:?}")
        }),
        E::WrongProductFamily { actual } => {
            serde_json::json!({"kind":"wrong_product_family","actual":actual.code()})
        }
        E::InvalidIssue { issue } => {
            serde_json::json!({"kind":"invalid_issue","issue":issue})
        }
        E::UnsupportedSpanToken { token } => {
            serde_json::json!({"kind":"unsupported_span_token","token":token})
        }
        E::UnsupportedSampleToken { token } => {
            serde_json::json!({"kind":"unsupported_sample_token","token":token})
        }
        E::NonCanonicalSpanToken { token, canonical } => serde_json::json!({
            "kind":"non_canonical_span_token","token":token,"canonical":canonical
        }),
        E::NonCanonicalSampleToken { token, canonical } => serde_json::json!({
            "kind":"non_canonical_sample_token","token":token,"canonical":canonical
        }),
        E::InvalidExpectedAgency { agency } => {
            serde_json::json!({"kind":"invalid_expected_agency","agency":agency})
        }
        E::AgencyMismatch { expected, actual } => serde_json::json!({
            "kind":"agency_mismatch","expected":expected,"actual":actual
        }),
        E::MissingEof => serde_json::json!({"kind":"missing_eof"}),
        E::MalformedEofRecord {
            line_number,
            record_length,
        } => serde_json::json!({
            "kind":"malformed_eof_record",
            "line_number":line_number.to_string(),
            "record_length":record_length.to_string()
        }),
        E::TrailingContentAfterEof => {
            serde_json::json!({"kind":"trailing_content_after_eof"})
        }
        E::MandatoryHeaderRecordCount {
            record,
            expected,
            actual,
        } => serde_json::json!({
            "kind":"mandatory_header_record_count","record":record,
            "expected":expected.to_string(),"actual":actual.to_string()
        }),
        E::MissingDeclaredSatelliteCount => {
            serde_json::json!({"kind":"missing_declared_satellite_count"})
        }
        E::DeclaredSatelliteCountMismatch { declared, tokens } => serde_json::json!({
            "kind":"declared_satellite_count_mismatch",
            "declared":declared.to_string(),"tokens":tokens.to_string()
        }),
        E::DuplicateDeclaredSatellite {
            token,
            first_index,
            duplicate_index,
        } => serde_json::json!({
            "kind":"duplicate_declared_satellite","token":token,
            "first_index":first_index.to_string(),"duplicate_index":duplicate_index.to_string()
        }),
        E::NoDeclaredSatellites => serde_json::json!({"kind":"no_declared_satellites"}),
        E::SatelliteRecordSequenceMismatch {
            record,
            epoch_index,
            expected,
            actual,
        } => serde_json::json!({
            "kind":"satellite_record_sequence_mismatch","record":record,
            "epoch_index":epoch_index.to_string(),"expected":expected,"actual":actual
        }),
        E::BodyRecordInterleavingMismatch {
            epoch_index,
            expected,
            actual,
        } => serde_json::json!({
            "kind":"body_record_interleaving_mismatch",
            "epoch_index":epoch_index.to_string(),"expected":expected,"actual":actual
        }),
        E::NonFiniteHeaderCadence => {
            serde_json::json!({"kind":"non_finite_header_cadence"})
        }
        E::NonPositiveHeaderCadence { actual_s } => serde_json::json!({
            "kind":"non_positive_header_cadence","actual_s":actual_s.to_string()
        }),
        E::UnsupportedHeaderCadence { actual_s } => serde_json::json!({
            "kind":"unsupported_header_cadence","actual_s":actual_s.to_string()
        }),
        E::CadenceMismatch {
            requested_s,
            header_s,
        } => serde_json::json!({
            "kind":"cadence_mismatch","requested_s":requested_s.to_string(),
            "header_s":header_s.to_string()
        }),
        E::DeclaredEpochCountMismatch { declared, parsed } => serde_json::json!({
            "kind":"declared_epoch_count_mismatch",
            "declared":declared.to_string(),"parsed":parsed.to_string()
        }),
        E::MissingDeclaredStart => serde_json::json!({"kind":"missing_declared_start"}),
        E::DeclaredStartMismatch {
            requested_j2000_s,
            declared_j2000_s,
            requested_tick,
            declared_tick,
        } => serde_json::json!({
            "kind":"declared_start_mismatch",
            "requested_j2000_s":exact_float_value(*requested_j2000_s),
            "declared_j2000_s":exact_float_value(*declared_j2000_s),
            "requested_tick":requested_tick.to_string(),
            "declared_tick":declared_tick.map(|tick| tick.to_string())
        }),
        E::RequestBeforeGpsEpoch => serde_json::json!({"kind":"request_before_gps_epoch"}),
        E::NonFiniteHeaderStartMetadata { field } => serde_json::json!({
            "kind":"non_finite_header_start_metadata","field":field
        }),
        E::InvalidHeaderStartMetadata { field, actual } => serde_json::json!({
            "kind":"invalid_header_start_metadata","field":field,"actual":actual.to_string()
        }),
        E::HeaderStartMetadataMismatch {
            field,
            requested,
            actual,
        } => serde_json::json!({
            "kind":"header_start_metadata_mismatch","field":field,
            "requested":requested.to_string(),"actual":actual.to_string()
        }),
        E::EmptyEpochGrid => serde_json::json!({"kind":"empty_epoch_grid"}),
        E::FirstEpochMismatch {
            requested_j2000_s,
            actual_j2000_s,
        } => serde_json::json!({
            "kind":"first_epoch_mismatch",
            "requested_j2000_s":requested_j2000_s.to_string(),
            "actual_j2000_s":actual_j2000_s.to_string()
        }),
        E::IrregularEpochGrid {
            epoch_index,
            requested_s,
            actual_s,
        } => serde_json::json!({
            "kind":"irregular_epoch_grid","epoch_index":epoch_index.to_string(),
            "requested_s":requested_s.to_string(),"actual_s":actual_s.to_string()
        }),
        E::SpanNotMultipleOfCadence { span_s, cadence_s } => serde_json::json!({
            "kind":"span_not_multiple_of_cadence",
            "span_s":span_s.to_string(),"cadence_s":cadence_s.to_string()
        }),
        E::SpanMismatch {
            parsed,
            half_open,
            inclusive,
        } => serde_json::json!({
            "kind":"span_mismatch","parsed":parsed.to_string(),
            "half_open":half_open.to_string(),"inclusive":inclusive.to_string()
        }),
        E::FormatVersionMismatch { requested, actual } => serde_json::json!({
            "kind":"format_version_mismatch","requested":requested,"actual":actual
        }),
        other => serde_json::json!({
            "kind":"unknown","error":other.to_string(),"debug":format!("{other:?}")
        }),
    }
}

fn exact_detail_key(key: &str) -> rustler::Atom {
    match key {
        "kind" => atoms::kind(),
        "error" => atoms::error(),
        "debug" => atoms::debug(),
        "actual" => atoms::actual(),
        "issue" => atoms::issue(),
        "token" => atoms::token(),
        "canonical" => atoms::canonical(),
        "agency" => atoms::agency(),
        "expected" => atoms::expected(),
        "line_number" => atoms::line_number(),
        "record_length" => atoms::record_length(),
        "record" => atoms::record(),
        "declared" => atoms::declared(),
        "tokens" => atoms::tokens(),
        "first_index" => atoms::first_index(),
        "duplicate_index" => atoms::duplicate_index(),
        "epoch_index" => atoms::epoch_index(),
        "actual_s" => atoms::actual_s(),
        "requested_s" => atoms::requested_s(),
        "header_s" => atoms::header_s(),
        "parsed" => atoms::parsed(),
        "requested_j2000_s" => atoms::requested_j2000_s(),
        "declared_j2000_s" => atoms::declared_j2000_s(),
        "actual_j2000_s" => atoms::actual_j2000_s(),
        "requested_tick" => atoms::requested_tick(),
        "declared_tick" => atoms::declared_tick(),
        "field" => atoms::field(),
        "requested" => atoms::requested(),
        "half_open" => atoms::half_open(),
        "inclusive" => atoms::inclusive(),
        "span_s" => atoms::span_s(),
        "cadence_s" => atoms::cadence_s(),
        unknown => panic!("unexpected exact-SP3 detail key {unknown}"),
    }
}

fn exact_detail_term<'a>(env: Env<'a>, value: &serde_json::Value) -> Term<'a> {
    match value {
        serde_json::Value::Null => rustler::types::atom::nil().encode(env),
        serde_json::Value::Bool(value) => value.encode(env),
        serde_json::Value::Number(value) => value
            .as_i64()
            .map(|value| value.encode(env))
            .or_else(|| value.as_u64().map(|value| value.encode(env)))
            .or_else(|| value.as_f64().map(|value| value.encode(env)))
            .expect("serde number encodes on the BEAM"),
        serde_json::Value::String(value) => value.encode(env),
        serde_json::Value::Array(values) => values
            .iter()
            .map(|value| exact_detail_term(env, value))
            .collect::<Vec<_>>()
            .encode(env),
        serde_json::Value::Object(values) => {
            values
                .iter()
                .fold(rustler::types::map::map_new(env), |map, (key, value)| {
                    map.map_put(exact_detail_key(key), exact_detail_term(env, value))
                        .unwrap_or(map)
                })
        }
    }
}

fn exact_validation_error<'a>(env: Env<'a>, error: ExactSp3ValidationError) -> Term<'a> {
    let detail = exact_validation_error_detail(&error);
    (
        atoms::error(),
        (
            atoms::exact_sp3_validation_failed(),
            exact_detail_term(env, &detail),
        ),
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
    verify_continuity: Option<(Option<String>, Option<f64>, Option<f64>)>,
    provenance: Option<String>,
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

    let provenance = provenance
        .map(|mode| match mode.as_str() {
            "summary" => Ok(ProvenanceMode::Summary),
            "full" => Ok(ProvenanceMode::Full),
            other => Err(Error::Term(Box::new(format!(
                "unknown provenance mode {other:?}"
            )))),
        })
        .transpose()?;

    // Mutate-a-default rather than a struct literal: MergeOptions is
    // non-exhaustive, so any option the core learns later stays at its default
    // without this conversion having to name it.
    let mut options = MergeOptions::default();
    options.position_tolerance_m = position_tolerance_m;
    options.clock_tolerance_s = clock_tolerance_s;
    options.min_agree = min_agree;
    options.clock_min_common = clock_min_common;
    options.combine = combine;
    options.precedence_scope = precedence_scope;
    options.outlier_reject = outlier_reject.map(|(position_tolerance_m, clock_tolerance_s)| {
        OutlierRejectOptions::new(position_tolerance_m, clock_tolerance_s)
    });
    options.target_epoch_interval_s = target_epoch_interval_s;
    options.systems = if system_letters.is_empty() {
        None
    } else {
        Some(systems_from_letters(system_letters)?)
    };
    let mut frame_reconciliation = Sp3FrameReconciliationOptions::default();
    frame_reconciliation.asserted_equivalent_label_sets = asserted_equivalent_label_sets;
    frame_reconciliation.helmert = helmert_frame_reconciliation;
    options.frame_reconciliation = frame_reconciliation;
    options.verify_continuity = verify_continuity
        .map(
            |(orbit_class, residual_tolerance_m, gap_threshold_factor)| {
                continuity_options_from_terms(
                    orbit_class,
                    residual_tolerance_m,
                    gap_threshold_factor,
                )
            },
        )
        .transpose()
        .map_err(|error| Error::Term(Box::new(error)))?;
    options.provenance = provenance;
    Ok(options)
}

/// Map a time-scale abbreviation onto the core [`TimeScale`]. Pure translation;
/// used so an Elixir caller can name the epoch's scale explicitly when it is not
/// the file's own header scale.
pub(crate) fn time_scale_from_abbrev(abbrev: &str) -> NifResult<TimeScale> {
    // Every scale `TimeScale::abbrev` can emit, so a scale-tagged instant the
    // core hands out reads back in as the same scale rather than being refused
    // by a table that predates it.
    Ok(match abbrev {
        "UTC" => TimeScale::Utc,
        "TAI" => TimeScale::Tai,
        "TT" => TimeScale::Tt,
        "TCG" => TimeScale::Tcg,
        "TDB" => TimeScale::Tdb,
        "TCB" => TimeScale::Tcb,
        "GPST" => TimeScale::Gpst,
        "GST" => TimeScale::Gst,
        "BDT" => TimeScale::Bdt,
        "GLONASST" => TimeScale::Glonasst,
        "QZSST" => TimeScale::Qzsst,
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
fn sp3_parse(
    bytes: rustler::Binary,
    gap_threshold_factor: Option<f64>,
) -> NifResult<ResourceArc<Sp3Resource>> {
    let mut sp3 = Sp3::parse(bytes.as_slice()).map_err(|e| Error::Term(Box::new(e.to_string())))?;
    if let Some(factor) = gap_threshold_factor {
        let opts = Sp3InterpolationOptions::new(factor).map_err(|error| {
            Error::Term(Box::new(interpolation_options_error_term(factor, error)))
        })?;
        sp3 = sp3.with_interpolation_options(opts);
    }
    Ok(ResourceArc::new(Sp3Resource { sp3 }))
}

/// Position-interpolation gap threshold factor carried by the product.
#[rustler::nif]
fn sp3_gap_threshold_factor(handle: ResourceArc<Sp3Resource>) -> f64 {
    handle.sp3.interpolation_options().gap_threshold_factor()
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

/// Derive the position interpolator's reach from the parsed product interval.
#[rustler::nif]
fn sp3_stencil_extent(handle: ResourceArc<Sp3Resource>) -> Result<(f64, f64), String> {
    let stencil = StencilExtent::for_sp3(&handle.sp3).map_err(|error| error.to_string())?;
    Ok((stencil.before_s(), stencil.after_s()))
}

/// Return the canonical core speed bound for a named continuity orbit class.
#[rustler::nif]
fn sp3_orbit_class_speed_bound_m_s(orbit_class: String) -> Result<f64, String> {
    let class = match orbit_class.as_str() {
        "meo_gnss" => OrbitClass::MeoGnss,
        "geosynchronous" => OrbitClass::Geosynchronous,
        "leo" => OrbitClass::Leo,
        other => return Err(format!("unknown orbit class: {other}")),
    };
    Ok(class.max_earth_fixed_speed_m_s())
}

fn continuity_options_from_terms(
    orbit_class: Option<String>,
    residual_tolerance_m: Option<f64>,
    gap_threshold_factor: Option<f64>,
) -> Result<ContinuityOptions, Sp3ValidationErrorTerm> {
    let speed_bound = match orbit_class.as_deref() {
        None => None,
        Some("meo_gnss") => Some(SpeedBound::OrbitClass(OrbitClass::MeoGnss)),
        Some("geosynchronous") => Some(SpeedBound::OrbitClass(OrbitClass::Geosynchronous)),
        Some("leo") => Some(SpeedBound::OrbitClass(OrbitClass::Leo)),
        Some(other) => {
            return Err(validation_error_term(
                "continuity_options",
                "orbit_class",
                other.to_string(),
                "unknown_orbit_class",
            ))
        }
    };
    let mut options = ContinuityOptions::new(speed_bound, residual_tolerance_m)
        .map_err(continuity_validation_term)?;
    if let Some(factor) = gap_threshold_factor {
        let interpolation = Sp3InterpolationOptions::new(factor).map_err(|error| {
            validation_error_term(
                "sp3_interpolation_options",
                "gap_threshold_factor",
                format!("{factor:?}"),
                &error.to_string(),
            )
        })?;
        options = options.with_interpolation_options(interpolation);
    }
    Ok(options)
}

/// Attest that a parsed or merged product is physically continuous.
///
/// `orbit_class` selects the physical earth-fixed speed bound
/// (`"meo_gnss" | "geosynchronous" | "leo"`); passing `nil` disables that gate.
/// `residual_tolerance_m` enables the sensitive hold-out interpolation residual
/// check; passing `nil` disables it. `gap_threshold_factor` sets the
/// hold-out interpolation policy; passing `nil` uses the core default (1.5).
/// Returns the defects with their epochs and magnitudes plus the counts of what
/// was actually examined, so a caller can tell "checked and clean" from "not
/// checked".
#[rustler::nif(schedule = "DirtyCpu")]
fn sp3_check_continuity(
    handle: ResourceArc<Sp3Resource>,
    orbit_class: Option<String>,
    residual_tolerance_m: Option<f64>,
    gap_threshold_factor: Option<f64>,
) -> Result<ContinuityReportTuple, Sp3ValidationErrorTerm> {
    let options =
        continuity_options_from_terms(orbit_class, residual_tolerance_m, gap_threshold_factor)?;
    let report = check_continuity(&handle.sp3.precise_ephemeris_samples(), &options)
        .map_err(continuity_validation_term)?;
    Ok(continuity_report_to_tuple(&report))
}

fn continuity_report_to_tuple(
    report: &sidereon_core::ephemeris::ContinuityReport,
) -> ContinuityReportTuple {
    (
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
    )
}

/// One continuity defect: `{kind, satellite, {from_j2000_s, to_j2000_s},
/// {magnitude, bound}, details}`. `magnitude` and `bound` carry the implied
/// speed and its bound for a speed-bound defect, and the residual and its
/// tolerance for a hold-out residual defect; both are `nil` for the input-shape
/// defects. `details` carries every field of the kind.
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
            ContinuityDefectDetailsTerm {
                epoch_j2000_s: Some(*epoch_j2000_s),
                occurrences: Some(*occurrences as u64),
                ..ContinuityDefectDetailsTerm::default()
            },
        ),
        ContinuityDefect::SingleSampleSeries { sat } => (
            "single_sample_series".to_string(),
            sat.to_string(),
            (None, None),
            (None, None),
            ContinuityDefectDetailsTerm::default(),
        ),
        ContinuityDefect::UnusableSample {
            sat,
            sample_index,
            epoch_j2000_s,
            reason,
        } => (
            "unusable_sample".to_string(),
            sat.to_string(),
            (*epoch_j2000_s, *epoch_j2000_s),
            (None, None),
            ContinuityDefectDetailsTerm {
                epoch_j2000_s: *epoch_j2000_s,
                sample_index: Some(*sample_index as u64),
                reason: Some(
                    match reason {
                        sidereon_core::ephemeris::UnusableSampleReason::EpochNotPlaced => {
                            "epoch_not_placed"
                        }
                        sidereon_core::ephemeris::UnusableSampleReason::NonFinitePosition => {
                            "non_finite_position"
                        }
                        _ => "unknown",
                    }
                    .to_string(),
                ),
                ..ContinuityDefectDetailsTerm::default()
            },
        ),
        ContinuityDefect::SpeedBound {
            sat,
            from_j2000_s,
            to_j2000_s,
            interval_s,
            displacement_m,
            implied_speed_m_s,
            bound_m_s,
        } => (
            "speed_bound".to_string(),
            sat.to_string(),
            (Some(*from_j2000_s), Some(*to_j2000_s)),
            (Some(*implied_speed_m_s), Some(*bound_m_s)),
            ContinuityDefectDetailsTerm {
                interval_s: Some(*interval_s),
                displacement_m: Some(*displacement_m),
                implied_speed_m_s: Some(*implied_speed_m_s),
                bound_m_s: Some(*bound_m_s),
                ..ContinuityDefectDetailsTerm::default()
            },
        ),
        ContinuityDefect::HoldOutResidual {
            sat,
            preceding_j2000_s,
            epoch_j2000_s,
            residual_m,
            tolerance_m,
            node_epochs_j2000_s,
        } => (
            "hold_out_residual".to_string(),
            sat.to_string(),
            (Some(*preceding_j2000_s), Some(*epoch_j2000_s)),
            (Some(*residual_m), Some(*tolerance_m)),
            ContinuityDefectDetailsTerm {
                epoch_j2000_s: Some(*epoch_j2000_s),
                preceding_j2000_s: Some(*preceding_j2000_s),
                residual_m: Some(*residual_m),
                tolerance_m: Some(*tolerance_m),
                node_epochs_j2000_s: Some(node_epochs_j2000_s.clone()),
                ..ContinuityDefectDetailsTerm::default()
            },
        ),
    }
}

fn cell_selection_term(selection: &CellSelection) -> CellSelectionTerm {
    let members = |members: &[usize]| members.iter().map(|&member| member as u64).collect();
    match selection {
        CellSelection::SingleSource { source } => CellSelectionTerm {
            kind: "single_source".to_string(),
            source: Some(*source as u64),
            rule: None,
            members: vec![*source as u64],
        },
        CellSelection::Precedence {
            source,
            members: set,
        } => CellSelectionTerm {
            kind: "precedence".to_string(),
            source: Some(*source as u64),
            rule: None,
            members: members(set),
        },
        CellSelection::Combined { rule, members: set } => CellSelectionTerm {
            kind: "combined".to_string(),
            source: None,
            rule: Some(
                match rule {
                    MergeCombine::Mean => "mean",
                    MergeCombine::Median => "median",
                    MergeCombine::Precedence => "precedence",
                }
                .to_string(),
            ),
            members: members(set),
        },
    }
}

fn merge_continuity_cell_term(cell: &MergeContinuityCell) -> MergeContinuityCellTerm {
    MergeContinuityCellTerm {
        epoch_j2000_s: cell.epoch_j2000_s,
        role: match cell.role {
            MergeContinuityCellRole::HeldOut => "held_out",
            MergeContinuityCellRole::InterpolationNode => "interpolation_node",
            MergeContinuityCellRole::PairEnd => "pair_end",
            MergeContinuityCellRole::RepeatedEpoch => "repeated_epoch",
        }
        .to_string(),
        selection: cell.selection.as_ref().map(cell_selection_term),
    }
}

fn merge_continuity_violation_to_tuple(
    violation: &MergeContinuityViolation,
) -> MergeContinuityViolationTuple {
    (
        continuity_defect_to_tuple(&violation.defect),
        violation
            .from_sources
            .iter()
            .map(|source| *source as u64)
            .collect(),
        violation
            .to_sources
            .iter()
            .map(|source| *source as u64)
            .collect(),
        violation.crosses_contributors,
        violation
            .cells
            .iter()
            .map(merge_continuity_cell_term)
            .collect(),
        violation
            .sources
            .iter()
            .map(|source| *source as u64)
            .collect(),
    )
}

fn merge_continuity_report_to_tuple(report: &MergeContinuityReport) -> MergeContinuityReportTuple {
    (
        continuity_report_to_tuple(&report.report),
        report
            .violations
            .iter()
            .map(merge_continuity_violation_to_tuple)
            .collect(),
    )
}

fn window_continuity_verdict_to_tuple(
    verdict: WindowContinuityVerdict<'_>,
) -> WindowContinuityVerdictTuple {
    let decision = match verdict.decision {
        WindowContinuityDecision::Accept => "accept",
        WindowContinuityDecision::Refuse => "refuse",
    };
    (
        decision.to_string(),
        verdict.accepted(),
        verdict
            .influencing_defects
            .into_iter()
            .map(continuity_defect_to_tuple)
            .collect(),
        verdict
            .influencing_splices
            .into_iter()
            .map(merge_continuity_violation_to_tuple)
            .collect(),
        verdict
            .all_defects
            .iter()
            .map(continuity_defect_to_tuple)
            .collect(),
        verdict
            .all_splices
            .into_iter()
            .map(merge_continuity_violation_to_tuple)
            .collect(),
    )
}

/// Run the product-wide checker and filter its report for one evaluation
/// window using the product-derived stencil.
#[rustler::nif(schedule = "DirtyCpu")]
fn sp3_continuity_verdict(
    handle: ResourceArc<Sp3Resource>,
    from_j2000_s: f64,
    through_j2000_s: f64,
    orbit_class: Option<String>,
    residual_tolerance_m: Option<f64>,
    gap_threshold_factor: Option<f64>,
) -> Result<WindowContinuityVerdictTuple, Sp3ValidationErrorTerm> {
    let options =
        continuity_options_from_terms(orbit_class, residual_tolerance_m, gap_threshold_factor)?;
    let window = EpochWindow::new(from_j2000_s, through_j2000_s).map_err(|error| {
        validation_error_term(
            "invalid_continuity_window",
            "from_through_j2000_s",
            format!("{from_j2000_s:?},{through_j2000_s:?}"),
            &error.to_string(),
        )
    })?;
    let stencil = StencilExtent::for_sp3(&handle.sp3).map_err(|error| {
        validation_error_term(
            "invalid_sp3_stencil",
            "epoch_interval",
            String::new(),
            &error.to_string(),
        )
    })?;
    let report = check_continuity(&handle.sp3.precise_ephemeris_samples(), &options)
        .map_err(continuity_validation_term)?;
    Ok(window_continuity_verdict_to_tuple(
        report.verdict_for_window(window, stencil),
    ))
}

/// One merged cell, as the report's flag lists name it, with its epoch in the
/// representation the merge recorded.
#[derive(Debug, rustler::NifMap)]
struct MergeFlagTerm {
    epoch: crate::precise_samples::EpochTerm,
    satellite: String,
    sources: Vec<u64>,
}

/// An input epoch that took no part in a merge.
#[derive(Debug, rustler::NifMap)]
struct DroppedInputEpochTerm {
    source: u64,
    epoch_index: u64,
    epoch: crate::precise_samples::EpochTerm,
    reason: String,
}

/// One source's clock for a cell that the merge did not write.
#[derive(Debug, rustler::NifMap)]
struct ClockOmissionTerm {
    epoch: crate::precise_samples::EpochTerm,
    satellite: String,
    source: u64,
    reason: String,
    preferred: Option<u64>,
    cell_has_clock: bool,
}

/// The merge report's record of what it did not write.
#[derive(Debug, rustler::NifMap)]
struct MergeOmissionsTerm {
    dropped_input_epochs: Vec<DroppedInputEpochTerm>,
    omitted_epochs: Vec<crate::precise_samples::EpochTerm>,
    arc_withheld: Vec<MergeFlagTerm>,
    clock_omissions: Vec<ClockOmissionTerm>,
}

fn merge_flag_term(flag: &MergeFlag) -> MergeFlagTerm {
    MergeFlagTerm {
        epoch: crate::precise_samples::epoch_fields(flag.epoch),
        satellite: flag.satellite.to_string(),
        sources: flag.sources.iter().map(|&source| source as u64).collect(),
    }
}

/// Read the retained merge report's dropped input epochs, omitted union-grid
/// epochs, withheld arc cells and clock omissions.
#[rustler::nif]
fn sp3_merge_report_omissions(report: ResourceArc<Sp3MergeReportResource>) -> MergeOmissionsTerm {
    let report = &report.report;
    MergeOmissionsTerm {
        dropped_input_epochs: report
            .dropped_input_epochs
            .iter()
            .map(|dropped| DroppedInputEpochTerm {
                source: dropped.source as u64,
                epoch_index: dropped.epoch_index as u64,
                epoch: crate::precise_samples::epoch_fields(dropped.epoch),
                reason: match dropped.reason {
                    DroppedEpochReason::OffTargetGrid => "off_target_grid",
                    DroppedEpochReason::NotOnTickAxis => "not_on_tick_axis",
                }
                .to_string(),
            })
            .collect(),
        omitted_epochs: report
            .omitted_epochs
            .iter()
            .map(|&epoch| crate::precise_samples::epoch_fields(epoch))
            .collect(),
        arc_withheld: report.arc_withheld.iter().map(merge_flag_term).collect(),
        clock_omissions: report
            .clock_omissions
            .iter()
            .map(|omission| {
                let (reason, preferred) = match omission.reason {
                    ClockOmissionReason::DatumNotObservable => ("datum_not_observable", None),
                    ClockOmissionReason::PreferredSourceWithoutClock { preferred } => (
                        "preferred_source_without_clock",
                        preferred.map(|source| source as u64),
                    ),
                    ClockOmissionReason::NoConsensus => ("no_consensus", None),
                };
                ClockOmissionTerm {
                    epoch: crate::precise_samples::epoch_fields(omission.epoch),
                    satellite: omission.satellite.to_string(),
                    source: omission.source as u64,
                    reason: reason.to_string(),
                    preferred,
                    cell_has_clock: omission.cell_has_clock,
                }
            })
            .collect(),
    }
}

/// One accepted cell's provenance.
#[derive(Debug, rustler::NifMap)]
struct CellProvenanceTerm {
    epoch: crate::precise_samples::EpochTerm,
    satellite: String,
    position: Option<CellSelectionTerm>,
    clock: Option<CellSelectionTerm>,
}

/// One change of the source supplying a satellite's position.
#[derive(Debug, rustler::NifMap)]
struct PrecedenceTransitionTerm {
    satellite: String,
    epoch: crate::precise_samples::EpochTerm,
    from_source: Option<u64>,
    to_source: Option<u64>,
    reason: String,
}

/// What one contributor supplied to the merged product.
#[derive(Debug, rustler::NifMap)]
struct ContributorCoverageTerm {
    source: u64,
    cells_contributed: u64,
    cells_selected: u64,
    first_epoch: Option<crate::precise_samples::EpochTerm>,
    last_epoch: Option<crate::precise_samples::EpochTerm>,
    cells_absent: u64,
}

/// Per-epoch merge provenance.
#[derive(Debug, rustler::NifMap)]
struct MergeProvenanceTerm {
    mode: String,
    cells: Vec<CellProvenanceTerm>,
    transitions: Vec<PrecedenceTransitionTerm>,
    coverage: Vec<ContributorCoverageTerm>,
}

/// Read the retained merge report's per-epoch provenance; `nil` when the merge
/// did not record it.
#[rustler::nif]
fn sp3_merge_report_provenance(
    report: ResourceArc<Sp3MergeReportResource>,
) -> Option<MergeProvenanceTerm> {
    let epoch = crate::precise_samples::epoch_fields;
    report
        .report
        .provenance
        .as_ref()
        .map(|provenance| MergeProvenanceTerm {
            mode: match provenance.mode {
                ProvenanceMode::Summary => "summary",
                ProvenanceMode::Full => "full",
            }
            .to_string(),
            cells: provenance
                .cells
                .iter()
                .map(|cell| CellProvenanceTerm {
                    epoch: epoch(cell.epoch),
                    satellite: cell.satellite.to_string(),
                    position: cell.position.as_ref().map(cell_selection_term),
                    clock: cell.clock.as_ref().map(cell_selection_term),
                })
                .collect(),
            transitions: provenance
                .transitions
                .iter()
                .map(|transition| PrecedenceTransitionTerm {
                    satellite: transition.satellite.to_string(),
                    epoch: epoch(transition.epoch),
                    from_source: transition.from_source.map(|source| source as u64),
                    to_source: transition.to_source.map(|source| source as u64),
                    reason: match transition.reason {
                        TransitionReason::SoleAvailability => "sole_availability",
                        TransitionReason::Precedence => "precedence",
                        TransitionReason::OutlierRejection => "outlier_rejection",
                        TransitionReason::ConsensusChange => "consensus_change",
                    }
                    .to_string(),
                })
                .collect(),
            coverage: provenance
                .coverage
                .iter()
                .map(|coverage| ContributorCoverageTerm {
                    source: coverage.source as u64,
                    cells_contributed: coverage.cells_contributed as u64,
                    cells_selected: coverage.cells_selected as u64,
                    first_epoch: coverage.first_epoch.map(epoch),
                    last_epoch: coverage.last_epoch.map(epoch),
                    cells_absent: coverage.cells_absent as u64,
                })
                .collect(),
        })
}

/// Ask the retained core merge report for its optional continuity verdict.
#[rustler::nif]
fn sp3_merge_continuity_verdict(
    report: ResourceArc<Sp3MergeReportResource>,
    from_j2000_s: f64,
    through_j2000_s: f64,
) -> Result<Option<WindowContinuityVerdictTuple>, String> {
    let window =
        EpochWindow::new(from_j2000_s, through_j2000_s).map_err(|error| error.to_string())?;
    Ok(report
        .report
        .continuity_verdict_for_window(window)
        .map(window_continuity_verdict_to_tuple))
}

/// Epochs of the position nodes some interpolation of `satellite` in the
/// inclusive window selects, under the product's own interpolation options.
/// Dirty-CPU: it reads every satellite's node series of the product.
#[rustler::nif(schedule = "DirtyCpu")]
fn sp3_selected_nodes(
    handle: ResourceArc<Sp3Resource>,
    satellite: String,
    from_j2000_s: f64,
    through_j2000_s: f64,
) -> Result<Vec<f64>, String> {
    let sat = satellite
        .parse::<GnssSatelliteId>()
        .map_err(|error| error.to_string())?;
    let window =
        EpochWindow::new(from_j2000_s, through_j2000_s).map_err(|error| error.to_string())?;
    Ok(InterpolationNodes::for_sp3(&handle.sp3).selected_nodes(sat, window))
}

/// The merged product's position nodes a continuity verdict for the window
/// reads for `satellite`; `nil` when continuity verification was not requested.
#[rustler::nif(schedule = "DirtyCpu")]
fn sp3_merge_continuity_selected_nodes(
    report: ResourceArc<Sp3MergeReportResource>,
    satellite: String,
    from_j2000_s: f64,
    through_j2000_s: f64,
) -> Result<Option<Vec<f64>>, String> {
    let sat = satellite
        .parse::<GnssSatelliteId>()
        .map_err(|error| error.to_string())?;
    let window =
        EpochWindow::new(from_j2000_s, through_j2000_s).map_err(|error| error.to_string())?;
    Ok(report
        .report
        .continuity
        .as_ref()
        .map(|continuity| continuity.nodes.selected_nodes(sat, window)))
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
    gap_threshold_factor: Option<f64>,
) -> Term<'a> {
    match parse_exact_sp3(bytes.as_slice(), &request.request) {
        Ok((mut sp3, coverage)) => {
            if let Some(factor) = gap_threshold_factor {
                match Sp3InterpolationOptions::new(factor) {
                    Ok(opts) => sp3 = sp3.with_interpolation_options(opts),
                    Err(error) => return exact_error(env, error),
                }
            }
            (
                atoms::ok(),
                (
                    ResourceArc::new(Sp3Resource { sp3 }),
                    exact_coverage(env, coverage),
                ),
            )
                .encode(env)
        }
        Err(error) => exact_validation_error(env, error),
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
        Err(error) => exact_validation_error(env, error),
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

type AccuracyCodeGroupTerm = (
    Option<i16>,
    Option<i16>,
    Option<i16>,
    Option<i16>,
    Option<f64>,
    Option<f64>,
);

fn accuracy_code_group(
    group: sidereon_core::ephemeris::Sp3AccuracyCodeGroup,
) -> AccuracyCodeGroupTerm {
    (
        group.axis_exponents[0],
        group.axis_exponents[1],
        group.axis_exponents[2],
        group.clock_exponent,
        group.position_velocity_base,
        group.clock_rate_base,
    )
}

fn accuracy_value_term<'a>(
    env: Env<'a>,
    value: sidereon_core::ephemeris::Sp3AccuracyValue,
) -> Term<'a> {
    use sidereon_core::ephemeris::Sp3AccuracyValue;
    match value {
        Sp3AccuracyValue::Known(value) => (atoms::known(), value).encode(env),
        Sp3AccuracyValue::Unknown => atoms::unknown().encode(env),
        Sp3AccuracyValue::TooLarge => atoms::too_large().encode(env),
        Sp3AccuracyValue::InvalidBase => atoms::invalid_base().encode(env),
        Sp3AccuracyValue::Overflow => atoms::overflow().encode(env),
        other => (atoms::unhandled(), format!("{other:?}")).encode(env),
    }
}

#[rustler::nif]
fn sp3_record_accuracy_codes<'a>(
    env: Env<'a>,
    handle: ResourceArc<Sp3Resource>,
    system_letter: String,
    prn: u8,
    epoch_index: usize,
) -> Term<'a> {
    let system = match system_from_letter(&system_letter) {
        Ok(system) => system,
        Err(_) => return (atoms::error(), atoms::unsupported_satellite_system()).encode(env),
    };
    let sat = match GnssSatelliteId::new(system, prn) {
        Ok(sat) => sat,
        Err(_) => return (atoms::error(), atoms::unknown_satellite()).encode(env),
    };
    match handle.sp3.record_accuracy_codes(sat, epoch_index) {
        Ok(raw) => {
            let p = raw.p.map(accuracy_code_group);
            let v = raw.v.map(accuracy_code_group);
            (atoms::ok(), (p, v)).encode(env)
        }
        Err(error) => encode_sp3_error(env, error),
    }
}

#[rustler::nif]
fn sp3_record_accuracy<'a>(
    env: Env<'a>,
    handle: ResourceArc<Sp3Resource>,
    system_letter: String,
    prn: u8,
    epoch_index: usize,
) -> Term<'a> {
    let system = match system_from_letter(&system_letter) {
        Ok(system) => system,
        Err(_) => return (atoms::error(), atoms::unsupported_satellite_system()).encode(env),
    };
    let sat = match GnssSatelliteId::new(system, prn) {
        Ok(sat) => sat,
        Err(_) => return (atoms::error(), atoms::unknown_satellite()).encode(env),
    };
    match handle.sp3.record_accuracy(sat, epoch_index) {
        Ok(record) => {
            let p = record.p.map(|accuracy| {
                (
                    (
                        accuracy_value_term(env, accuracy.position_sigma_m[0]),
                        accuracy_value_term(env, accuracy.position_sigma_m[1]),
                        accuracy_value_term(env, accuracy.position_sigma_m[2]),
                    ),
                    accuracy_value_term(env, accuracy.clock_sigma_m),
                )
            });
            let v = record.v.map(|accuracy| {
                (
                    (
                        accuracy_value_term(env, accuracy.velocity_sigma_m_s[0]),
                        accuracy_value_term(env, accuracy.velocity_sigma_m_s[1]),
                        accuracy_value_term(env, accuracy.velocity_sigma_m_s[2]),
                    ),
                    accuracy_value_term(env, accuracy.clock_rate_sigma_m_s),
                )
            });
            (atoms::ok(), (p, v)).encode(env)
        }
        Err(error) => encode_sp3_error(env, error),
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
    let split = JulianDateSplit::new(jd_whole, jd_fraction)
        .map_err(crate::tropo::time_model_error_detail)?;
    let epoch = Instant::from_julian_date(scale, split);

    let state = match handle.sp3.position(sat, epoch) {
        Ok(state) => state,
        Err(error) => return Ok(encode_sp3_error(env, error)),
    };

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

#[rustler::nif]
fn sp3_position_at_epoch_query<'a>(
    env: Env<'a>,
    handle: ResourceArc<Sp3Resource>,
    system_letter: String,
    prn: u8,
    query: ResourceArc<ExactEpochQueryResource>,
) -> NifResult<Term<'a>> {
    let system = system_from_letter(&system_letter)?;
    let sat = GnssSatelliteId::new(system, prn).map_err(crate::errors::invalid_input)?;
    let state = match handle.sp3.position_at_epoch_query(sat, &query.query) {
        Ok(state) => state,
        Err(error) => return Ok(encode_sp3_error(env, error)),
    };
    let clock_term: Term<'a> = match state.clock_s {
        Some(clock) => clock.encode(env),
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

#[rustler::nif]
fn sp3_selected_state_at_epoch_queries<'a>(
    env: Env<'a>,
    handle: ResourceArc<Sp3Resource>,
    system_letter: String,
    prn: u8,
    state_epoch: ResourceArc<ExactEpochQueryResource>,
    selection_epoch: ResourceArc<ExactEpochQueryResource>,
) -> NifResult<Term<'a>> {
    let system = system_from_letter(&system_letter)?;
    let satellite = GnssSatelliteId::new(system, prn).map_err(crate::errors::invalid_input)?;
    let state = match handle
        .sp3
        .try_position_clock_group_delay_selected_at_epoch_query(
            satellite,
            &state_epoch.query,
            &selection_epoch.query,
        ) {
        Ok(Some(state)) => {
            let ([position_x, position_y, position_z], clock_s, group_delay_s) = state.value;
            let degraded = state
                .degraded
                .map(crate::errors::degrade_reason_atom)
                .map(|reason| reason.encode(env));
            (
                position_x,
                position_y,
                position_z,
                clock_s,
                group_delay_s,
                degraded,
            )
                .encode(env)
        }
        Ok(None) => rustler::types::atom::nil().encode(env),
        Err(error) => return Ok(encode_sp3_error(env, error)),
    };
    Ok((atoms::ok(), state).encode(env))
}

#[rustler::nif]
fn sp3_transmit_clock_at_epoch_queries<'a>(
    env: Env<'a>,
    handle: ResourceArc<Sp3Resource>,
    system_letter: String,
    prn: u8,
    state_epoch: ResourceArc<ExactEpochQueryResource>,
    selection_epoch: ResourceArc<ExactEpochQueryResource>,
) -> NifResult<Term<'a>> {
    let system = system_from_letter(&system_letter)?;
    let satellite = GnssSatelliteId::new(system, prn).map_err(crate::errors::invalid_input)?;
    let clock = match handle.sp3.try_transmit_epoch_clock_at_epoch_query(
        satellite,
        &state_epoch.query,
        &selection_epoch.query,
    ) {
        Ok(Some(clock)) => {
            let degraded = clock
                .degraded
                .map(crate::errors::degrade_reason_atom)
                .map(|reason| reason.encode(env));
            (clock.value, degraded).encode(env)
        }
        Ok(None) => rustler::types::atom::nil().encode(env),
        Err(error) => return Ok(encode_sp3_error(env, error)),
    };
    Ok((atoms::ok(), clock).encode(env))
}

#[rustler::nif]
fn sp3_clock_relativity_for_state_at_epoch_query<'a>(
    env: Env<'a>,
    handle: ResourceArc<Sp3Resource>,
    system_letter: String,
    prn: u8,
    epoch: ResourceArc<ExactEpochQueryResource>,
    position_m: (f64, f64, f64),
) -> NifResult<Term<'a>> {
    let system = system_from_letter(&system_letter)?;
    let satellite = GnssSatelliteId::new(system, prn).map_err(crate::errors::invalid_input)?;
    let position = [position_m.0, position_m.1, position_m.2];
    let result = match handle.sp3.clock_relativity_for_state_at_epoch_query(
        satellite,
        &epoch.query,
        position,
    ) {
        sidereon_core::positioning::ClockRelativity::NotApplicable => {
            atoms::not_applicable().encode(env)
        }
        sidereon_core::positioning::ClockRelativity::Unavailable => {
            atoms::unavailable().encode(env)
        }
        sidereon_core::positioning::ClockRelativity::Term(value) => {
            (atoms::term(), value).encode(env)
        }
    };
    Ok(result)
}

#[rustler::nif]
fn sp3_ephemeris_variance_at_epoch_queries(
    handle: ResourceArc<Sp3Resource>,
    system_letter: String,
    prn: u8,
    state_epoch: ResourceArc<ExactEpochQueryResource>,
    selection_epoch: ResourceArc<ExactEpochQueryResource>,
) -> NifResult<f64> {
    let system = system_from_letter(&system_letter)?;
    let satellite = GnssSatelliteId::new(system, prn).map_err(crate::errors::invalid_input)?;
    Ok(handle.sp3.ephemeris_variance_at_epoch_query(
        satellite,
        &state_epoch.query,
        &selection_epoch.query,
    ))
}

/// Split a flagged cell's epoch into a `(jd_whole, jd_fraction)` pair in the
/// product's own time scale (the same split convention `sp3_position/6` accepts).
/// Encoded as a 4-tuple `{sat_token, jd_whole, jd_fraction, [source_index]}` so
/// the Elixir wrapper can build a structured report.
fn flag_to_tuple(flag: &MergeFlag) -> (String, f64, f64, Vec<u64>) {
    let (jd_whole, jd_fraction) = instant_split(&flag.epoch);
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
    (u64, Option<f64>, Option<f64>),
    (u64, Option<f64>, Option<f64>),
);
type EpochAgreementTuple = (
    (f64, f64),
    u64,
    (Option<f64>, Option<f64>),
    (Option<f64>, Option<f64>),
);
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
/// tuples use, in the product's own time scale. An integer-nanosecond count is
/// split in `i128` as a parsed SP3 epoch line is: whole days from the civil
/// midnight before the J2000 origin (JD 2451544.5, exact in `f64`) and the day
/// fraction, rounded once.
fn instant_split(epoch: &Instant) -> (f64, f64) {
    match epoch.repr {
        InstantRepr::JulianDate(split) => (split.jd_whole, split.fraction),
        InstantRepr::Nanos(nanos) => {
            const NANOS_PER_DAY: i128 = 86_400_000_000_000;
            const NANOS_PER_HALF_DAY: i128 = NANOS_PER_DAY / 2;
            // Shift to the midnight origin after dividing, so no count
            // overflows.
            let (mut days, mut within_day) = (
                nanos.div_euclid(NANOS_PER_DAY),
                nanos.rem_euclid(NANOS_PER_DAY) + NANOS_PER_HALF_DAY,
            );
            if within_day >= NANOS_PER_DAY {
                days += 1;
                within_day -= NANOS_PER_DAY;
            }
            (
                sidereon_core::constants::J2000_JD - 0.5 + days as f64,
                within_day as f64 / NANOS_PER_DAY as f64,
            )
        }
    }
}

/// Per-accepted-cell consensus agreement, nested so the tuple stays within the
/// Rustler encoder's small-tuple arity:
/// `{sat, {jd_whole, jd_fraction}, {position_members, position_rms_m | nil,
///   position_max_m | nil}, {clock_members, clock_rms_s | nil, clock_max_s | nil}}`.
/// The position metrics are `nil` for a cell that carries no position, such as a
/// clock-only record, as the clock metrics are for a cell with no clock.
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

/// Per-epoch aggregate agreement over the cells with a multi-source consensus:
/// `{{jd_whole, jd_fraction}, satellites, {position_rms_m | nil,
///   position_max_m | nil}, {clock_rms_s | nil, clock_max_s | nil}}`, each
/// `nil` when no multi-source consensus for that channel exists at the epoch.
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
    verify_continuity: Option<(Option<String>, Option<f64>, Option<f64>)>,
    provenance: Option<String>,
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
        verify_continuity,
        provenance,
    )?;

    // The crate merge takes owned products; the handles are shared/immutable, so
    // clone each into the merge input.
    let sources: Vec<Sp3> = handles.iter().map(|h| h.sp3.clone()).collect();
    let (merged, report) = crate_merge(&sources, &opts).map_err(core_validation_error)?;

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
    let continuity = report
        .continuity
        .as_ref()
        .map(merge_continuity_report_to_tuple);
    let report_handle = ResourceArc::new(Sp3MergeReportResource { report });

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
                continuity,
                report_handle,
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

fn policy_validation_artifact() -> Result<Sp3ArtifactIdentity, Sp3ValidationErrorTerm> {
    // Sp3MergeInputIdentity validates the merge policy before inspecting
    // contributors. Supplying one valid catalog identity lets this preflight
    // delegate interval acceptance to that same core validator without
    // reimplementing its tick and range rules in the binding.
    let requested_fields = vec![
        "sp3",
        "esa",
        "ESA",
        "final",
        "MGN",
        "0",
        "2026",
        "7",
        "16",
        "0000",
        "01D",
        "05M",
        "ESA0MGNFIN_20261970000_01D_05M_ORB.SP3",
        "SP3",
        "",
        "",
    ]
    .into_iter()
    .map(str::to_string)
    .collect::<Vec<_>>();
    let requested_identity =
        crate::data::product_identity(requested_fields.clone()).map_err(|error| {
            validation_error_term(
                "sp3_merge_input_identity",
                "policy_validation_identity",
                String::new(),
                &error.to_string(),
            )
        })?;
    let mut resolved_fields = requested_fields;
    resolved_fields[14] = "SP3-d".to_string();
    let resolved_identity = crate::data::product_identity(resolved_fields).map_err(|error| {
        validation_error_term(
            "sp3_merge_input_identity",
            "policy_validation_identity",
            String::new(),
            &error.to_string(),
        )
    })?;
    Ok(Sp3ArtifactIdentity {
        requested_identity,
        resolved_identity,
        distribution_source: DistributionSource::InMemory,
        official_filename: "ESA0MGNFIN_20261970000_01D_05M_ORB.SP3".to_string(),
        product_sha256: "11".repeat(32),
        product_byte_length: 1,
        archive_sha256: "22".repeat(32),
        archive_byte_length: 1,
        compression: ArchiveCompression::Gzip,
    })
}

#[rustler::nif]
fn sp3_validate_merge_target_interval(
    target_epoch_interval_s: Option<f64>,
) -> Result<(), Sp3ValidationErrorTerm> {
    let mut options = MergeOptions::default();
    options.target_epoch_interval_s = target_epoch_interval_s;
    let artifact = policy_validation_artifact()?;
    Sp3MergeInputIdentity::new(&[artifact], &options)
        .map(|_| ())
        .map_err(identity_validation_term)
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
        None,
        None,
    )?;
    let identity = Sp3MergeInputIdentity::new(&contributors, &policy)
        .map_err(|error| Error::Term(Box::new(identity_validation_term(error))))?;
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
///
/// The writer refuses a value its columns cannot state exactly rather than
/// rounding it, so this is `{:ok, text}` or `{:error, {tag, fields}}` with every
/// field the [`Sp3WriteError`] variant carries.
#[rustler::nif(schedule = "DirtyCpu")]
fn sp3_to_iodata<'a>(env: Env<'a>, handle: ResourceArc<Sp3Resource>) -> Term<'a> {
    match handle.sp3.to_sp3_string() {
        Ok(text) => (atoms::ok(), text).encode(env),
        Err(err) => (atoms::error(), sp3_write_error_term(env, err)).encode(env),
    }
}

/// A double at the boundary: the float itself when finite, and
/// `{:nonfinite, bits}` otherwise, since the BEAM has no non-finite float and
/// the refusal is still reported with the value it names.
fn write_float_term<'a>(env: Env<'a>, value: f64) -> Term<'a> {
    if value.is_finite() {
        value.encode(env)
    } else {
        (atoms::nonfinite(), value.to_bits()).encode(env)
    }
}

fn write_optional_float_term<'a>(env: Env<'a>, value: Option<f64>) -> Term<'a> {
    match value {
        Some(value) => write_float_term(env, value),
        None => rustler::types::atom::nil().encode(env),
    }
}

/// A map of a refusal's payload fields, keyed by atoms from this module's
/// `atoms!` list.
fn write_field_map<'a>(env: Env<'a>, pairs: Vec<(rustler::Atom, Term<'a>)>) -> Term<'a> {
    pairs
        .into_iter()
        .fold(rustler::types::map::map_new(env), |map, (key, value)| {
            // `map_put` fails only on a term that is not a map, and `map` is
            // always one here.
            map.map_put(key, value).unwrap_or(map)
        })
}

#[derive(Debug, PartialEq)]
enum Sp3WriterErrorDetail {
    SatelliteNotRepresentable {
        satellite: String,
        system: String,
        prn: u8,
    },
    AccuracyNotRepresentable {
        satellite: String,
        epoch_index: usize,
        component: &'static str,
        exponent: Option<i16>,
        message: String,
    },
    AccuracyRecordMismatch {
        satellite: String,
        epoch_index: usize,
        message: String,
    },
    AccuracyBasisMissing {
        satellite: String,
        epoch_index: usize,
        message: String,
    },
}

fn sp3_writer_error_detail(error: &Sp3WriteError) -> Option<Sp3WriterErrorDetail> {
    let message = error.to_string();
    Some(match error {
        Sp3WriteError::SatelliteNotRepresentable { sat } => {
            Sp3WriterErrorDetail::SatelliteNotRepresentable {
                satellite: sat.to_string(),
                system: sat.system.to_string(),
                prn: sat.prn,
            }
        }
        Sp3WriteError::AccuracyNotRepresentable {
            sat,
            epoch_index,
            component,
            exponent,
        } => Sp3WriterErrorDetail::AccuracyNotRepresentable {
            satellite: sat.to_string(),
            epoch_index: *epoch_index,
            component,
            exponent: *exponent,
            message,
        },
        Sp3WriteError::AccuracyRecordMismatch { sat, epoch_index } => {
            Sp3WriterErrorDetail::AccuracyRecordMismatch {
                satellite: sat.to_string(),
                epoch_index: *epoch_index,
                message,
            }
        }
        Sp3WriteError::AccuracyBasisMissing { sat, epoch_index } => {
            Sp3WriterErrorDetail::AccuracyBasisMissing {
                satellite: sat.to_string(),
                epoch_index: *epoch_index,
                message,
            }
        }
        _ => return None,
    })
}

#[derive(Debug, PartialEq)]
enum Sp3WriterProjectionValue {
    Text(String),
    Usize(usize),
    U64(u64),
    I64(i64),
    U8(u8),
    FloatBits(u64),
    OptionalFloatBits(Option<u64>),
    OptionalI16(Option<i16>),
}

#[derive(Debug, PartialEq)]
struct Sp3WriterErrorProjection {
    tag: &'static str,
    fields: Vec<(&'static str, Sp3WriterProjectionValue)>,
}

fn sp3_writer_error_projection(error: &Sp3WriteError) -> Sp3WriterErrorProjection {
    use Sp3WriterProjectionValue as Value;

    let projection = |tag, fields| Sp3WriterErrorProjection { tag, fields };
    if let Some(detail) = sp3_writer_error_detail(error) {
        return match detail {
            Sp3WriterErrorDetail::SatelliteNotRepresentable {
                satellite,
                system,
                prn,
            } => projection(
                "satellite_not_representable",
                vec![
                    ("satellite", Value::Text(satellite)),
                    ("system", Value::Text(system)),
                    ("prn", Value::U8(prn)),
                ],
            ),
            Sp3WriterErrorDetail::AccuracyNotRepresentable {
                satellite,
                epoch_index,
                component,
                exponent,
                message,
            } => projection(
                "accuracy_not_representable",
                vec![
                    ("satellite", Value::Text(satellite)),
                    ("epoch_index", Value::Usize(epoch_index)),
                    ("component", Value::Text(component.to_string())),
                    ("exponent", Value::OptionalI16(exponent)),
                    ("message", Value::Text(message)),
                ],
            ),
            Sp3WriterErrorDetail::AccuracyRecordMismatch {
                satellite,
                epoch_index,
                message,
            } => projection(
                "accuracy_record_mismatch",
                vec![
                    ("satellite", Value::Text(satellite)),
                    ("epoch_index", Value::Usize(epoch_index)),
                    ("message", Value::Text(message)),
                ],
            ),
            Sp3WriterErrorDetail::AccuracyBasisMissing {
                satellite,
                epoch_index,
                message,
            } => projection(
                "accuracy_basis_missing",
                vec![
                    ("satellite", Value::Text(satellite)),
                    ("epoch_index", Value::Usize(epoch_index)),
                    ("message", Value::Text(message)),
                ],
            ),
        };
    }

    match error {
        Sp3WriteError::TextNotColumnSafe { field, value } => projection(
            "text_not_column_safe",
            vec![
                ("field", Value::Text((*field).to_string())),
                ("value", Value::Text(value.clone())),
            ],
        ),
        Sp3WriteError::TextNotColumnStable { field, value } => projection(
            "text_not_column_stable",
            vec![
                ("field", Value::Text((*field).to_string())),
                ("value", Value::Text(value.clone())),
            ],
        ),
        Sp3WriteError::BlankDescriptor { field, value } => projection(
            "blank_descriptor",
            vec![
                ("field", Value::Text((*field).to_string())),
                ("value", Value::Text(value.clone())),
            ],
        ),
        Sp3WriteError::EmptyComment { index, value } => projection(
            "empty_comment",
            vec![
                ("index", Value::Usize(*index)),
                ("value", Value::Text(value.clone())),
            ],
        ),
        Sp3WriteError::TextTooWide {
            field,
            columns,
            value,
        } => projection(
            "text_too_wide",
            vec![
                ("field", Value::Text((*field).to_string())),
                ("columns", Value::Usize(*columns)),
                ("value", Value::Text(value.clone())),
            ],
        ),
        Sp3WriteError::IntegerTooWide {
            field,
            columns,
            value,
        } => projection(
            "integer_too_wide",
            vec![
                ("field", Value::Text((*field).to_string())),
                ("columns", Value::Usize(*columns)),
                ("value", Value::U64(*value)),
            ],
        ),
        Sp3WriteError::NonFinite { field } => projection(
            "non_finite",
            vec![("field", Value::Text((*field).to_string()))],
        ),
        Sp3WriteError::NumberTooWide {
            field,
            columns,
            decimals,
            value,
        } => projection(
            "number_too_wide",
            vec![
                ("field", Value::Text((*field).to_string())),
                ("columns", Value::Usize(*columns)),
                ("decimals", Value::Usize(*decimals)),
                ("value", Value::FloatBits(value.to_bits())),
            ],
        ),
        Sp3WriteError::PrecisionNotRepresentable {
            field,
            columns,
            decimals,
            value,
        } => projection(
            "precision_not_representable",
            vec![
                ("field", Value::Text((*field).to_string())),
                ("columns", Value::Usize(*columns)),
                ("decimals", Value::Usize(*decimals)),
                ("value", Value::FloatBits(value.to_bits())),
            ],
        ),
        Sp3WriteError::YearNotRepresentable { epoch_index, year } => projection(
            "year_not_representable",
            vec![
                ("epoch_index", Value::Usize(*epoch_index)),
                ("year", Value::I64(*year)),
            ],
        ),
        Sp3WriteError::EpochNotRestatable {
            epoch_index,
            field_seconds,
            residual_s,
        } => projection(
            "epoch_not_restatable",
            vec![
                ("epoch_index", Value::Usize(*epoch_index)),
                ("field_seconds", Value::FloatBits(field_seconds.to_bits())),
                ("residual_s", Value::FloatBits(residual_s.to_bits())),
            ],
        ),
        Sp3WriteError::EpochTimeScaleMismatch {
            epoch_index,
            epoch_scale,
            header_scale,
        } => projection(
            "epoch_time_scale_mismatch",
            vec![
                ("epoch_index", Value::Usize(*epoch_index)),
                ("epoch_scale", Value::Text(epoch_scale.abbrev().to_string())),
                (
                    "header_scale",
                    Value::Text(header_scale.abbrev().to_string()),
                ),
            ],
        ),
        Sp3WriteError::HeaderTimeScaleMismatch {
            time_system,
            time_scale,
        } => projection(
            "header_time_scale_mismatch",
            vec![
                ("time_system", Value::Text(time_system.label().to_string())),
                ("time_scale", Value::Text(time_scale.abbrev().to_string())),
            ],
        ),
        Sp3WriteError::EpochCountMismatch { declared, epochs } => projection(
            "epoch_count_mismatch",
            vec![
                ("declared", Value::U64(*declared)),
                ("epochs", Value::Usize(*epochs)),
            ],
        ),
        Sp3WriteError::AccuracyCodeCountMismatch { satellites, codes } => projection(
            "accuracy_code_count_mismatch",
            vec![
                ("satellites", Value::Usize(*satellites)),
                ("codes", Value::Usize(*codes)),
            ],
        ),
        Sp3WriteError::DuplicateSatellite { sat } => projection(
            "duplicate_satellite",
            vec![("satellite", Value::Text(sat.to_string()))],
        ),
        Sp3WriteError::EpochArrayLengthMismatch {
            field,
            epochs,
            entries,
        } => projection(
            "epoch_array_length_mismatch",
            vec![
                ("field", Value::Text((*field).to_string())),
                ("epochs", Value::Usize(*epochs)),
                ("entries", Value::Usize(*entries)),
            ],
        ),
        Sp3WriteError::UndeclaredSatelliteRecord { sat, epoch_index } => projection(
            "undeclared_satellite_record",
            vec![
                ("satellite", Value::Text(sat.to_string())),
                ("epoch_index", Value::Usize(*epoch_index)),
            ],
        ),
        Sp3WriteError::ConflictingRecords { sat, epoch_index } => projection(
            "conflicting_records",
            vec![
                ("satellite", Value::Text(sat.to_string())),
                ("epoch_index", Value::Usize(*epoch_index)),
            ],
        ),
        Sp3WriteError::VelocityStateInPositionProduct {
            field,
            sat,
            epoch_index,
        } => projection(
            "velocity_state_in_position_product",
            vec![
                ("field", Value::Text((*field).to_string())),
                ("satellite", Value::Text(sat.to_string())),
                ("epoch_index", Value::Usize(*epoch_index)),
            ],
        ),
        Sp3WriteError::RecordValueNonFinite {
            field,
            sat,
            epoch_index,
        } => projection(
            "record_value_non_finite",
            vec![
                ("field", Value::Text((*field).to_string())),
                ("satellite", Value::Text(sat.to_string())),
                ("epoch_index", Value::Usize(*epoch_index)),
            ],
        ),
        Sp3WriteError::RecordValueTooWide {
            field,
            sat,
            epoch_index,
            columns,
            decimals,
            column_value,
        } => projection(
            "record_value_too_wide",
            vec![
                ("field", Value::Text((*field).to_string())),
                ("satellite", Value::Text(sat.to_string())),
                ("epoch_index", Value::Usize(*epoch_index)),
                ("columns", Value::Usize(*columns)),
                ("decimals", Value::Usize(*decimals)),
                ("column_value", Value::FloatBits(column_value.to_bits())),
            ],
        ),
        Sp3WriteError::RecordValueNotRepresentable {
            field,
            sat,
            epoch_index,
            columns,
            decimals,
            stored,
            column_value,
        } => projection(
            "record_value_not_representable",
            vec![
                ("field", Value::Text((*field).to_string())),
                ("satellite", Value::Text(sat.to_string())),
                ("epoch_index", Value::Usize(*epoch_index)),
                ("columns", Value::Usize(*columns)),
                ("decimals", Value::Usize(*decimals)),
                ("stored", Value::FloatBits(stored.to_bits())),
                ("column_value", Value::FloatBits(column_value.to_bits())),
            ],
        ),
        Sp3WriteError::RecordReadsAsAbsent {
            field,
            sat,
            epoch_index,
            column_value,
        } => projection(
            "record_reads_as_absent",
            vec![
                ("field", Value::Text((*field).to_string())),
                ("satellite", Value::Text(sat.to_string())),
                ("epoch_index", Value::Usize(*epoch_index)),
                ("column_value", Value::FloatBits(column_value.to_bits())),
            ],
        ),
        Sp3WriteError::RecordFieldsDisagree {
            field,
            sat,
            epoch_index,
            stored,
            native,
        } => projection(
            "record_fields_disagree",
            vec![
                ("field", Value::Text((*field).to_string())),
                ("satellite", Value::Text(sat.to_string())),
                ("epoch_index", Value::Usize(*epoch_index)),
                ("stored", Value::OptionalFloatBits(stored.map(f64::to_bits))),
                ("native", Value::OptionalFloatBits(native.map(f64::to_bits))),
            ],
        ),
        _ => projection(
            "unhandled",
            vec![("message", Value::Text(error.to_string()))],
        ),
    }
}

fn sp3_writer_atom(name: &'static str) -> rustler::Atom {
    match name {
        "text_not_column_safe" => atoms::text_not_column_safe(),
        "text_not_column_stable" => atoms::text_not_column_stable(),
        "blank_descriptor" => atoms::blank_descriptor(),
        "empty_comment" => atoms::empty_comment(),
        "text_too_wide" => atoms::text_too_wide(),
        "integer_too_wide" => atoms::integer_too_wide(),
        "non_finite" => atoms::non_finite(),
        "number_too_wide" => atoms::number_too_wide(),
        "precision_not_representable" => atoms::precision_not_representable(),
        "accuracy_not_representable" => atoms::accuracy_not_representable(),
        "accuracy_record_mismatch" => atoms::accuracy_record_mismatch(),
        "accuracy_basis_missing" => atoms::accuracy_basis_missing(),
        "year_not_representable" => atoms::year_not_representable(),
        "epoch_not_restatable" => atoms::epoch_not_restatable(),
        "epoch_time_scale_mismatch" => atoms::epoch_time_scale_mismatch(),
        "header_time_scale_mismatch" => atoms::header_time_scale_mismatch(),
        "epoch_count_mismatch" => atoms::epoch_count_mismatch(),
        "accuracy_code_count_mismatch" => atoms::accuracy_code_count_mismatch(),
        "duplicate_satellite" => atoms::duplicate_satellite(),
        "satellite_not_representable" => atoms::satellite_not_representable(),
        "epoch_array_length_mismatch" => atoms::epoch_array_length_mismatch(),
        "undeclared_satellite_record" => atoms::undeclared_satellite_record(),
        "conflicting_records" => atoms::conflicting_records(),
        "velocity_state_in_position_product" => atoms::velocity_state_in_position_product(),
        "record_value_non_finite" => atoms::record_value_non_finite(),
        "record_value_too_wide" => atoms::record_value_too_wide(),
        "record_value_not_representable" => atoms::record_value_not_representable(),
        "record_reads_as_absent" => atoms::record_reads_as_absent(),
        "record_fields_disagree" => atoms::record_fields_disagree(),
        "unhandled" => atoms::unhandled(),
        "field" => atoms::field(),
        "value" => atoms::value(),
        "message" => atoms::message(),
        "index" => atoms::index(),
        "columns" => atoms::columns(),
        "decimals" => atoms::decimals(),
        "satellite" => atoms::satellite(),
        "system" => atoms::system(),
        "prn" => atoms::prn(),
        "epoch_index" => atoms::epoch_index(),
        "component" => atoms::component(),
        "exponent" => atoms::exponent(),
        "year" => atoms::year(),
        "field_seconds" => atoms::field_seconds(),
        "residual_s" => atoms::residual_s(),
        "epoch_scale" => atoms::epoch_scale(),
        "header_scale" => atoms::header_scale(),
        "time_system" => atoms::time_system(),
        "time_scale" => atoms::time_scale(),
        "declared" => atoms::declared(),
        "epochs" => atoms::epochs(),
        "satellites" => atoms::satellites(),
        "codes" => atoms::codes(),
        "entries" => atoms::entries(),
        "column_value" => atoms::column_value(),
        "stored" => atoms::stored(),
        "native" => atoms::native(),
        _ => unreachable!("unknown SP3 writer projection atom"),
    }
}

fn sp3_writer_projection_value_term<'a>(env: Env<'a>, value: Sp3WriterProjectionValue) -> Term<'a> {
    match value {
        Sp3WriterProjectionValue::Text(value) => value.encode(env),
        Sp3WriterProjectionValue::Usize(value) => value.encode(env),
        Sp3WriterProjectionValue::U64(value) => value.encode(env),
        Sp3WriterProjectionValue::I64(value) => value.encode(env),
        Sp3WriterProjectionValue::U8(value) => value.encode(env),
        Sp3WriterProjectionValue::FloatBits(bits) => write_float_term(env, f64::from_bits(bits)),
        Sp3WriterProjectionValue::OptionalFloatBits(bits) => {
            write_optional_float_term(env, bits.map(f64::from_bits))
        }
        Sp3WriterProjectionValue::OptionalI16(value) => value.encode(env),
    }
}

/// A writer refusal as `{tag, %{field => value}}` with every field its variant
/// carries. [`Sp3WriteError`] is `#[non_exhaustive]`; a variant this binding
/// predates is `{:unhandled, %{message: text}}` with the core's own text, never
/// another variant's tag.
fn sp3_write_error_term<'a>(env: Env<'a>, err: Sp3WriteError) -> Term<'a> {
    let projection = sp3_writer_error_projection(&err);
    let fields = projection
        .fields
        .into_iter()
        .map(|(name, value)| {
            (
                sp3_writer_atom(name),
                sp3_writer_projection_value_term(env, value),
            )
        })
        .collect();
    (
        sp3_writer_atom(projection.tag),
        write_field_map(env, fields),
    )
        .encode(env)
}

#[cfg(test)]
mod exact_sp3_validation_error_mapping_tests {
    use super::*;
    use serde_json::json;
    use sidereon_core::data::{DataCatalogError, ProductType};

    #[test]
    fn every_current_exact_sp3_refusal_keeps_its_complete_public_payload() {
        use ExactSp3ValidationError as E;

        let cases = vec![
            (
                E::Parse(CoreError::Parse("bad product".to_string())),
                json!({"kind":"parse","error":"parse error: bad product","debug":"Parse(\"bad product\")"}),
            ),
            (
                E::Catalog(DataCatalogError::UnknownCenter("bad".to_string())),
                json!({"kind":"catalog","error":"unknown analysis center \"bad\"","debug":"UnknownCenter(\"bad\")"}),
            ),
            (
                E::WrongProductFamily {
                    actual: ProductType::Clk,
                },
                json!({"kind":"wrong_product_family","actual":"clk"}),
            ),
            (
                E::InvalidIssue {
                    issue: "2460".to_string(),
                },
                json!({"kind":"invalid_issue","issue":"2460"}),
            ),
            (
                E::UnsupportedSpanToken {
                    token: "02Q".to_string(),
                },
                json!({"kind":"unsupported_span_token","token":"02Q"}),
            ),
            (
                E::UnsupportedSampleToken {
                    token: "00S".to_string(),
                },
                json!({"kind":"unsupported_sample_token","token":"00S"}),
            ),
            (
                E::NonCanonicalSpanToken {
                    token: "24H".to_string(),
                    canonical: "01D".to_string(),
                },
                json!({"kind":"non_canonical_span_token","token":"24H","canonical":"01D"}),
            ),
            (
                E::NonCanonicalSampleToken {
                    token: "300S".to_string(),
                    canonical: "05M".to_string(),
                },
                json!({"kind":"non_canonical_sample_token","token":"300S","canonical":"05M"}),
            ),
            (
                E::InvalidExpectedAgency {
                    agency: "ABCDE".to_string(),
                },
                json!({"kind":"invalid_expected_agency","agency":"ABCDE"}),
            ),
            (
                E::AgencyMismatch {
                    expected: "IGS0".to_string(),
                    actual: "COD0".to_string(),
                },
                json!({"kind":"agency_mismatch","expected":"IGS0","actual":"COD0"}),
            ),
            (E::MissingEof, json!({"kind":"missing_eof"})),
            (
                E::MalformedEofRecord {
                    line_number: 42,
                    record_length: 79,
                },
                json!({"kind":"malformed_eof_record","line_number":"42","record_length":"79"}),
            ),
            (
                E::TrailingContentAfterEof,
                json!({"kind":"trailing_content_after_eof"}),
            ),
            (
                E::MandatoryHeaderRecordCount {
                    record: "++",
                    expected: 5,
                    actual: 4,
                },
                json!({"kind":"mandatory_header_record_count","record":"++","expected":"5","actual":"4"}),
            ),
            (
                E::MissingDeclaredSatelliteCount,
                json!({"kind":"missing_declared_satellite_count"}),
            ),
            (
                E::DeclaredSatelliteCountMismatch {
                    declared: 3,
                    tokens: 2,
                },
                json!({"kind":"declared_satellite_count_mismatch","declared":"3","tokens":"2"}),
            ),
            (
                E::DuplicateDeclaredSatellite {
                    token: "G01".to_string(),
                    first_index: 1,
                    duplicate_index: 4,
                },
                json!({"kind":"duplicate_declared_satellite","token":"G01","first_index":"1","duplicate_index":"4"}),
            ),
            (
                E::NoDeclaredSatellites,
                json!({"kind":"no_declared_satellites"}),
            ),
            (
                E::SatelliteRecordSequenceMismatch {
                    record: "P",
                    epoch_index: 7,
                    expected: vec!["G01".to_string(), "G02".to_string()],
                    actual: vec!["G02".to_string()],
                },
                json!({"kind":"satellite_record_sequence_mismatch","record":"P","epoch_index":"7","expected":["G01","G02"],"actual":["G02"]}),
            ),
            (
                E::BodyRecordInterleavingMismatch {
                    epoch_index: 8,
                    expected: vec!["PG01".to_string(), "VG01".to_string()],
                    actual: vec!["VG01".to_string(), "PG01".to_string()],
                },
                json!({"kind":"body_record_interleaving_mismatch","epoch_index":"8","expected":["PG01","VG01"],"actual":["VG01","PG01"]}),
            ),
            (
                E::NonFiniteHeaderCadence,
                json!({"kind":"non_finite_header_cadence"}),
            ),
            (
                E::NonPositiveHeaderCadence { actual_s: -1.5 },
                json!({"kind":"non_positive_header_cadence","actual_s":"-1.5"}),
            ),
            (
                E::UnsupportedHeaderCadence { actual_s: 99_999.5 },
                json!({"kind":"unsupported_header_cadence","actual_s":"99999.5"}),
            ),
            (
                E::CadenceMismatch {
                    requested_s: 300.0,
                    header_s: 900.0,
                },
                json!({"kind":"cadence_mismatch","requested_s":"300","header_s":"900"}),
            ),
            (
                E::DeclaredEpochCountMismatch {
                    declared: u64::MAX,
                    parsed: 288,
                },
                json!({"kind":"declared_epoch_count_mismatch","declared":u64::MAX.to_string(),"parsed":"288"}),
            ),
            (
                E::MissingDeclaredStart,
                json!({"kind":"missing_declared_start"}),
            ),
            (
                E::DeclaredStartMismatch {
                    requested_j2000_s: 1.25,
                    declared_j2000_s: f64::NAN,
                    requested_tick: i128::MAX,
                    declared_tick: None,
                },
                json!({
                    "kind":"declared_start_mismatch",
                    "requested_j2000_s":1.25,
                    "declared_j2000_s":"NaN",
                    "requested_tick":i128::MAX.to_string(),
                    "declared_tick":null
                }),
            ),
            (
                E::RequestBeforeGpsEpoch,
                json!({"kind":"request_before_gps_epoch"}),
            ),
            (
                E::NonFiniteHeaderStartMetadata { field: "mjd" },
                json!({"kind":"non_finite_header_start_metadata","field":"mjd"}),
            ),
            (
                E::InvalidHeaderStartMetadata {
                    field: "seconds_of_week",
                    actual: -1.5,
                },
                json!({"kind":"invalid_header_start_metadata","field":"seconds_of_week","actual":"-1.5"}),
            ),
            (
                E::HeaderStartMetadataMismatch {
                    field: "gps_week",
                    requested: 2200.0,
                    actual: 2201.0,
                },
                json!({"kind":"header_start_metadata_mismatch","field":"gps_week","requested":"2200","actual":"2201"}),
            ),
            (E::EmptyEpochGrid, json!({"kind":"empty_epoch_grid"})),
            (
                E::FirstEpochMismatch {
                    requested_j2000_s: 1.25,
                    actual_j2000_s: 2.5,
                },
                json!({"kind":"first_epoch_mismatch","requested_j2000_s":"1.25","actual_j2000_s":"2.5"}),
            ),
            (
                E::IrregularEpochGrid {
                    epoch_index: 100,
                    requested_s: 300.0,
                    actual_s: 301.0,
                },
                json!({"kind":"irregular_epoch_grid","epoch_index":"100","requested_s":"300","actual_s":"301"}),
            ),
            (
                E::SpanNotMultipleOfCadence {
                    span_s: 86_401,
                    cadence_s: 300,
                },
                json!({"kind":"span_not_multiple_of_cadence","span_s":"86401","cadence_s":"300"}),
            ),
            (
                E::SpanMismatch {
                    parsed: 287,
                    half_open: 288,
                    inclusive: 289,
                },
                json!({"kind":"span_mismatch","parsed":"287","half_open":"288","inclusive":"289"}),
            ),
            (
                E::FormatVersionMismatch {
                    requested: "d".to_string(),
                    actual: "c".to_string(),
                },
                json!({"kind":"format_version_mismatch","requested":"d","actual":"c"}),
            ),
        ];

        assert_eq!(cases.len(), 37);
        for (error, expected) in cases {
            assert_eq!(exact_validation_error_detail(&error), expected, "{error:?}");
        }
    }
}

#[cfg(test)]
mod sp3_writer_error_mapping_tests {
    use super::*;

    enum ExpectedTerm {
        Text(&'static str),
        Message,
        Usize(usize),
        U64(u64),
        I64(i64),
        U8(u8),
        Float(f64),
        OptionalFloat(Option<f64>),
        OptionalI16(Option<i16>),
        Nonfinite(u64),
    }

    type AtomFn = fn() -> rustler::Atom;

    struct TermCase {
        error: Sp3WriteError,
        tag: AtomFn,
        fields: Vec<(AtomFn, ExpectedTerm)>,
    }

    fn atom_name(atom: AtomFn) -> &'static str {
        macro_rules! known_atoms {
            ($($name:ident),+ $(,)?) => {
                $(
                    if atom as usize == atoms::$name as AtomFn as usize {
                        return stringify!($name);
                    }
                )+
            };
        }
        known_atoms!(
            text_not_column_safe,
            text_not_column_stable,
            blank_descriptor,
            empty_comment,
            text_too_wide,
            integer_too_wide,
            non_finite,
            number_too_wide,
            precision_not_representable,
            accuracy_not_representable,
            accuracy_record_mismatch,
            accuracy_basis_missing,
            year_not_representable,
            epoch_not_restatable,
            epoch_time_scale_mismatch,
            header_time_scale_mismatch,
            epoch_count_mismatch,
            accuracy_code_count_mismatch,
            duplicate_satellite,
            satellite_not_representable,
            epoch_array_length_mismatch,
            undeclared_satellite_record,
            conflicting_records,
            velocity_state_in_position_product,
            record_value_non_finite,
            record_value_too_wide,
            record_value_not_representable,
            record_reads_as_absent,
            record_fields_disagree,
            field,
            value,
            message,
            index,
            columns,
            decimals,
            satellite,
            system,
            prn,
            epoch_index,
            component,
            exponent,
            year,
            field_seconds,
            residual_s,
            epoch_scale,
            header_scale,
            time_system,
            time_scale,
            declared,
            epochs,
            satellites,
            codes,
            entries,
            column_value,
            stored,
            native,
        );
        panic!("unknown expected atom function")
    }

    fn assert_complete_term(case: TermCase) {
        let message = case.error.to_string();
        let projection = sp3_writer_error_projection(&case.error);
        assert_eq!(projection.tag, atom_name(case.tag));
        assert_eq!(projection.fields.len(), case.fields.len());
        for (key, expected) in case.fields {
            let key = atom_name(key);
            let value = &projection
                .fields
                .iter()
                .find(|(name, _)| *name == key)
                .unwrap_or_else(|| panic!("missing projected field {key}"))
                .1;
            match (expected, value) {
                (ExpectedTerm::Text(expected), Sp3WriterProjectionValue::Text(actual)) => {
                    assert_eq!(actual, expected)
                }
                (ExpectedTerm::Message, Sp3WriterProjectionValue::Text(actual)) => {
                    assert_eq!(actual, &message)
                }
                (ExpectedTerm::Usize(expected), Sp3WriterProjectionValue::Usize(actual)) => {
                    assert_eq!(*actual, expected)
                }
                (ExpectedTerm::U64(expected), Sp3WriterProjectionValue::U64(actual)) => {
                    assert_eq!(*actual, expected)
                }
                (ExpectedTerm::I64(expected), Sp3WriterProjectionValue::I64(actual)) => {
                    assert_eq!(*actual, expected)
                }
                (ExpectedTerm::U8(expected), Sp3WriterProjectionValue::U8(actual)) => {
                    assert_eq!(*actual, expected)
                }
                (ExpectedTerm::Float(expected), Sp3WriterProjectionValue::FloatBits(actual)) => {
                    assert_eq!(*actual, expected.to_bits())
                }
                (
                    ExpectedTerm::OptionalFloat(expected),
                    Sp3WriterProjectionValue::OptionalFloatBits(actual),
                ) => assert_eq!(*actual, expected.map(f64::to_bits)),
                (
                    ExpectedTerm::OptionalI16(expected),
                    Sp3WriterProjectionValue::OptionalI16(actual),
                ) => assert_eq!(*actual, expected),
                (
                    ExpectedTerm::Nonfinite(expected_bits),
                    Sp3WriterProjectionValue::FloatBits(actual),
                ) => assert_eq!(*actual, expected_bits),
                (expected, actual) => panic!(
                    "projected field {key} has wrong value kind: expected index {:?}, actual {actual:?}",
                    std::mem::discriminant(&expected)
                ),
            }
        }
    }

    #[test]
    fn current_epoch_and_accuracy_refusals_keep_their_complete_values() {
        let satellite = "G07".parse().expect("test satellite");
        let unrepresentable = GnssSatelliteId {
            system: GnssSystem::Gps,
            prn: 100,
        };
        let cases = [
            (
                Sp3WriteError::SatelliteNotRepresentable {
                    sat: unrepresentable,
                },
                Sp3WriterErrorDetail::SatelliteNotRepresentable {
                    satellite: "G100".to_string(),
                    system: "GPS".to_string(),
                    prn: 100,
                },
            ),
            (
                Sp3WriteError::AccuracyNotRepresentable {
                    sat: satellite,
                    epoch_index: 5,
                    component: "position",
                    exponent: Some(12),
                },
                Sp3WriterErrorDetail::AccuracyNotRepresentable {
                    satellite: "G07".to_string(),
                    epoch_index: 5,
                    component: "position",
                    exponent: Some(12),
                    message: Sp3WriteError::AccuracyNotRepresentable {
                        sat: satellite,
                        epoch_index: 5,
                        component: "position",
                        exponent: Some(12),
                    }
                    .to_string(),
                },
            ),
            (
                Sp3WriteError::AccuracyNotRepresentable {
                    sat: satellite,
                    epoch_index: 9,
                    component: "clock",
                    exponent: None,
                },
                Sp3WriterErrorDetail::AccuracyNotRepresentable {
                    satellite: "G07".to_string(),
                    epoch_index: 9,
                    component: "clock",
                    exponent: None,
                    message: Sp3WriteError::AccuracyNotRepresentable {
                        sat: satellite,
                        epoch_index: 9,
                        component: "clock",
                        exponent: None,
                    }
                    .to_string(),
                },
            ),
            (
                Sp3WriteError::AccuracyRecordMismatch {
                    sat: satellite,
                    epoch_index: 6,
                },
                Sp3WriterErrorDetail::AccuracyRecordMismatch {
                    satellite: "G07".to_string(),
                    epoch_index: 6,
                    message: Sp3WriteError::AccuracyRecordMismatch {
                        sat: satellite,
                        epoch_index: 6,
                    }
                    .to_string(),
                },
            ),
            (
                Sp3WriteError::AccuracyBasisMissing {
                    sat: satellite,
                    epoch_index: 8,
                },
                Sp3WriterErrorDetail::AccuracyBasisMissing {
                    satellite: "G07".to_string(),
                    epoch_index: 8,
                    message: Sp3WriteError::AccuracyBasisMissing {
                        sat: satellite,
                        epoch_index: 8,
                    }
                    .to_string(),
                },
            ),
        ];

        for (error, expected) in cases {
            assert_eq!(sp3_writer_error_detail(&error), Some(expected));
        }
    }

    #[test]
    fn every_sp3_write_refusal_keeps_its_complete_public_payload() {
        use sidereon_core::astro::time::TimeScale;
        use sidereon_core::ephemeris::Sp3TimeSystem;

        let satellite = "G07".parse().unwrap();
        let unrepresentable = GnssSatelliteId {
            system: GnssSystem::Gps,
            prn: 100,
        };
        let cases = vec![
            TermCase {
                error: Sp3WriteError::TextNotColumnSafe {
                    field: "agency",
                    value: "A\nB".into(),
                },
                tag: atoms::text_not_column_safe,
                fields: vec![
                    (atoms::field, ExpectedTerm::Text("agency")),
                    (atoms::value, ExpectedTerm::Text("A\nB")),
                ],
            },
            TermCase {
                error: Sp3WriteError::TextNotColumnStable {
                    field: "orbit type",
                    value: " FIT ".into(),
                },
                tag: atoms::text_not_column_stable,
                fields: vec![
                    (atoms::field, ExpectedTerm::Text("orbit type")),
                    (atoms::value, ExpectedTerm::Text(" FIT ")),
                ],
            },
            TermCase {
                error: Sp3WriteError::BlankDescriptor {
                    field: "data used",
                    value: "".into(),
                },
                tag: atoms::blank_descriptor,
                fields: vec![
                    (atoms::field, ExpectedTerm::Text("data used")),
                    (atoms::value, ExpectedTerm::Text("")),
                ],
            },
            TermCase {
                error: Sp3WriteError::EmptyComment {
                    index: 3,
                    value: "".into(),
                },
                tag: atoms::empty_comment,
                fields: vec![
                    (atoms::index, ExpectedTerm::Usize(3)),
                    (atoms::value, ExpectedTerm::Text("")),
                ],
            },
            TermCase {
                error: Sp3WriteError::TextTooWide {
                    field: "agency",
                    columns: 4,
                    value: "ABCDE".into(),
                },
                tag: atoms::text_too_wide,
                fields: vec![
                    (atoms::field, ExpectedTerm::Text("agency")),
                    (atoms::columns, ExpectedTerm::Usize(4)),
                    (atoms::value, ExpectedTerm::Text("ABCDE")),
                ],
            },
            TermCase {
                error: Sp3WriteError::IntegerTooWide {
                    field: "epoch count",
                    columns: 7,
                    value: u64::MAX,
                },
                tag: atoms::integer_too_wide,
                fields: vec![
                    (atoms::field, ExpectedTerm::Text("epoch count")),
                    (atoms::columns, ExpectedTerm::Usize(7)),
                    (atoms::value, ExpectedTerm::U64(u64::MAX)),
                ],
            },
            TermCase {
                error: Sp3WriteError::NonFinite { field: "interval" },
                tag: atoms::non_finite,
                fields: vec![(atoms::field, ExpectedTerm::Text("interval"))],
            },
            TermCase {
                error: Sp3WriteError::NumberTooWide {
                    field: "clock base",
                    columns: 10,
                    decimals: 7,
                    value: 12_345.25,
                },
                tag: atoms::number_too_wide,
                fields: vec![
                    (atoms::field, ExpectedTerm::Text("clock base")),
                    (atoms::columns, ExpectedTerm::Usize(10)),
                    (atoms::decimals, ExpectedTerm::Usize(7)),
                    (atoms::value, ExpectedTerm::Float(12_345.25)),
                ],
            },
            TermCase {
                error: Sp3WriteError::PrecisionNotRepresentable {
                    field: "position base",
                    columns: 10,
                    decimals: 7,
                    value: 1.25000001,
                },
                tag: atoms::precision_not_representable,
                fields: vec![
                    (atoms::field, ExpectedTerm::Text("position base")),
                    (atoms::columns, ExpectedTerm::Usize(10)),
                    (atoms::decimals, ExpectedTerm::Usize(7)),
                    (atoms::value, ExpectedTerm::Float(1.25000001)),
                ],
            },
            TermCase {
                error: Sp3WriteError::AccuracyNotRepresentable {
                    sat: satellite,
                    epoch_index: 5,
                    component: "position",
                    exponent: Some(-12),
                },
                tag: atoms::accuracy_not_representable,
                fields: vec![
                    (atoms::satellite, ExpectedTerm::Text("G07")),
                    (atoms::epoch_index, ExpectedTerm::Usize(5)),
                    (atoms::component, ExpectedTerm::Text("position")),
                    (atoms::exponent, ExpectedTerm::OptionalI16(Some(-12))),
                    (atoms::message, ExpectedTerm::Message),
                ],
            },
            TermCase {
                error: Sp3WriteError::AccuracyRecordMismatch {
                    sat: satellite,
                    epoch_index: 6,
                },
                tag: atoms::accuracy_record_mismatch,
                fields: vec![
                    (atoms::satellite, ExpectedTerm::Text("G07")),
                    (atoms::epoch_index, ExpectedTerm::Usize(6)),
                    (atoms::message, ExpectedTerm::Message),
                ],
            },
            TermCase {
                error: Sp3WriteError::AccuracyBasisMissing {
                    sat: satellite,
                    epoch_index: 8,
                },
                tag: atoms::accuracy_basis_missing,
                fields: vec![
                    (atoms::satellite, ExpectedTerm::Text("G07")),
                    (atoms::epoch_index, ExpectedTerm::Usize(8)),
                    (atoms::message, ExpectedTerm::Message),
                ],
            },
            TermCase {
                error: Sp3WriteError::YearNotRepresentable {
                    epoch_index: 9,
                    year: -12_345,
                },
                tag: atoms::year_not_representable,
                fields: vec![
                    (atoms::epoch_index, ExpectedTerm::Usize(9)),
                    (atoms::year, ExpectedTerm::I64(-12_345)),
                ],
            },
            TermCase {
                error: Sp3WriteError::EpochNotRestatable {
                    epoch_index: 10,
                    field_seconds: 59.125,
                    residual_s: 0.000_000_01,
                },
                tag: atoms::epoch_not_restatable,
                fields: vec![
                    (atoms::epoch_index, ExpectedTerm::Usize(10)),
                    (atoms::field_seconds, ExpectedTerm::Float(59.125)),
                    (atoms::residual_s, ExpectedTerm::Float(0.000_000_01)),
                ],
            },
            TermCase {
                error: Sp3WriteError::EpochTimeScaleMismatch {
                    epoch_index: 11,
                    epoch_scale: TimeScale::Gpst,
                    header_scale: TimeScale::Utc,
                },
                tag: atoms::epoch_time_scale_mismatch,
                fields: vec![
                    (atoms::epoch_index, ExpectedTerm::Usize(11)),
                    (atoms::epoch_scale, ExpectedTerm::Text("GPST")),
                    (atoms::header_scale, ExpectedTerm::Text("UTC")),
                ],
            },
            TermCase {
                error: Sp3WriteError::HeaderTimeScaleMismatch {
                    time_system: Sp3TimeSystem::Galileo,
                    time_scale: TimeScale::Gpst,
                },
                tag: atoms::header_time_scale_mismatch,
                fields: vec![
                    (atoms::time_system, ExpectedTerm::Text("GAL")),
                    (atoms::time_scale, ExpectedTerm::Text("GPST")),
                ],
            },
            TermCase {
                error: Sp3WriteError::EpochCountMismatch {
                    declared: u64::MAX,
                    epochs: 12,
                },
                tag: atoms::epoch_count_mismatch,
                fields: vec![
                    (atoms::declared, ExpectedTerm::U64(u64::MAX)),
                    (atoms::epochs, ExpectedTerm::Usize(12)),
                ],
            },
            TermCase {
                error: Sp3WriteError::AccuracyCodeCountMismatch {
                    satellites: 13,
                    codes: 12,
                },
                tag: atoms::accuracy_code_count_mismatch,
                fields: vec![
                    (atoms::satellites, ExpectedTerm::Usize(13)),
                    (atoms::codes, ExpectedTerm::Usize(12)),
                ],
            },
            TermCase {
                error: Sp3WriteError::DuplicateSatellite { sat: satellite },
                tag: atoms::duplicate_satellite,
                fields: vec![(atoms::satellite, ExpectedTerm::Text("G07"))],
            },
            TermCase {
                error: Sp3WriteError::SatelliteNotRepresentable {
                    sat: unrepresentable,
                },
                tag: atoms::satellite_not_representable,
                fields: vec![
                    (atoms::satellite, ExpectedTerm::Text("G100")),
                    (atoms::system, ExpectedTerm::Text("GPS")),
                    (atoms::prn, ExpectedTerm::U8(100)),
                ],
            },
            TermCase {
                error: Sp3WriteError::EpochArrayLengthMismatch {
                    field: "clocks",
                    epochs: 14,
                    entries: 13,
                },
                tag: atoms::epoch_array_length_mismatch,
                fields: vec![
                    (atoms::field, ExpectedTerm::Text("clocks")),
                    (atoms::epochs, ExpectedTerm::Usize(14)),
                    (atoms::entries, ExpectedTerm::Usize(13)),
                ],
            },
            TermCase {
                error: Sp3WriteError::UndeclaredSatelliteRecord {
                    sat: satellite,
                    epoch_index: 15,
                },
                tag: atoms::undeclared_satellite_record,
                fields: vec![
                    (atoms::satellite, ExpectedTerm::Text("G07")),
                    (atoms::epoch_index, ExpectedTerm::Usize(15)),
                ],
            },
            TermCase {
                error: Sp3WriteError::ConflictingRecords {
                    sat: satellite,
                    epoch_index: 16,
                },
                tag: atoms::conflicting_records,
                fields: vec![
                    (atoms::satellite, ExpectedTerm::Text("G07")),
                    (atoms::epoch_index, ExpectedTerm::Usize(16)),
                ],
            },
            TermCase {
                error: Sp3WriteError::VelocityStateInPositionProduct {
                    field: "velocity x",
                    sat: satellite,
                    epoch_index: 17,
                },
                tag: atoms::velocity_state_in_position_product,
                fields: vec![
                    (atoms::field, ExpectedTerm::Text("velocity x")),
                    (atoms::satellite, ExpectedTerm::Text("G07")),
                    (atoms::epoch_index, ExpectedTerm::Usize(17)),
                ],
            },
            TermCase {
                error: Sp3WriteError::RecordValueNonFinite {
                    field: "clock",
                    sat: satellite,
                    epoch_index: 18,
                },
                tag: atoms::record_value_non_finite,
                fields: vec![
                    (atoms::field, ExpectedTerm::Text("clock")),
                    (atoms::satellite, ExpectedTerm::Text("G07")),
                    (atoms::epoch_index, ExpectedTerm::Usize(18)),
                ],
            },
            TermCase {
                error: Sp3WriteError::RecordValueTooWide {
                    field: "position x",
                    sat: satellite,
                    epoch_index: 19,
                    columns: 14,
                    decimals: 6,
                    column_value: 123_456_789.25,
                },
                tag: atoms::record_value_too_wide,
                fields: vec![
                    (atoms::field, ExpectedTerm::Text("position x")),
                    (atoms::satellite, ExpectedTerm::Text("G07")),
                    (atoms::epoch_index, ExpectedTerm::Usize(19)),
                    (atoms::columns, ExpectedTerm::Usize(14)),
                    (atoms::decimals, ExpectedTerm::Usize(6)),
                    (atoms::column_value, ExpectedTerm::Float(123_456_789.25)),
                ],
            },
            TermCase {
                error: Sp3WriteError::RecordValueNotRepresentable {
                    field: "clock",
                    sat: satellite,
                    epoch_index: 20,
                    columns: 14,
                    decimals: 6,
                    stored: 0.000_001_25,
                    column_value: 1.250_000_01,
                },
                tag: atoms::record_value_not_representable,
                fields: vec![
                    (atoms::field, ExpectedTerm::Text("clock")),
                    (atoms::satellite, ExpectedTerm::Text("G07")),
                    (atoms::epoch_index, ExpectedTerm::Usize(20)),
                    (atoms::columns, ExpectedTerm::Usize(14)),
                    (atoms::decimals, ExpectedTerm::Usize(6)),
                    (atoms::stored, ExpectedTerm::Float(0.000_001_25)),
                    (atoms::column_value, ExpectedTerm::Float(1.250_000_01)),
                ],
            },
            TermCase {
                error: Sp3WriteError::RecordReadsAsAbsent {
                    field: "clock",
                    sat: satellite,
                    epoch_index: 21,
                    column_value: 999_999.999_999,
                },
                tag: atoms::record_reads_as_absent,
                fields: vec![
                    (atoms::field, ExpectedTerm::Text("clock")),
                    (atoms::satellite, ExpectedTerm::Text("G07")),
                    (atoms::epoch_index, ExpectedTerm::Usize(21)),
                    (atoms::column_value, ExpectedTerm::Float(999_999.999_999)),
                ],
            },
            TermCase {
                error: Sp3WriteError::RecordFieldsDisagree {
                    field: "velocity y",
                    sat: satellite,
                    epoch_index: 22,
                    stored: Some(-0.0),
                    native: None,
                },
                tag: atoms::record_fields_disagree,
                fields: vec![
                    (atoms::field, ExpectedTerm::Text("velocity y")),
                    (atoms::satellite, ExpectedTerm::Text("G07")),
                    (atoms::epoch_index, ExpectedTerm::Usize(22)),
                    (atoms::stored, ExpectedTerm::OptionalFloat(Some(-0.0))),
                    (atoms::native, ExpectedTerm::OptionalFloat(None)),
                ],
            },
        ];
        assert_eq!(cases.len(), 29);
        for case in cases {
            assert_complete_term(case);
        }
        assert_complete_term(TermCase {
            error: Sp3WriteError::AccuracyNotRepresentable {
                sat: satellite,
                epoch_index: 23,
                component: "clock",
                exponent: None,
            },
            tag: atoms::accuracy_not_representable,
            fields: vec![
                (atoms::satellite, ExpectedTerm::Text("G07")),
                (atoms::epoch_index, ExpectedTerm::Usize(23)),
                (atoms::component, ExpectedTerm::Text("clock")),
                (atoms::exponent, ExpectedTerm::OptionalI16(None)),
                (atoms::message, ExpectedTerm::Message),
            ],
        });
        assert_complete_term(TermCase {
            error: Sp3WriteError::EpochNotRestatable {
                epoch_index: 24,
                field_seconds: 0.0,
                residual_s: f64::NAN,
            },
            tag: atoms::epoch_not_restatable,
            fields: vec![
                (atoms::epoch_index, ExpectedTerm::Usize(24)),
                (atoms::field_seconds, ExpectedTerm::Float(0.0)),
                (
                    atoms::residual_s,
                    ExpectedTerm::Nonfinite(f64::NAN.to_bits()),
                ),
            ],
        });
        assert_complete_term(TermCase {
            error: Sp3WriteError::RecordFieldsDisagree {
                field: "clock rate",
                sat: satellite,
                epoch_index: 25,
                stored: None,
                native: Some(-2.5),
            },
            tag: atoms::record_fields_disagree,
            fields: vec![
                (atoms::field, ExpectedTerm::Text("clock rate")),
                (atoms::satellite, ExpectedTerm::Text("G07")),
                (atoms::epoch_index, ExpectedTerm::Usize(25)),
                (atoms::stored, ExpectedTerm::OptionalFloat(None)),
                (atoms::native, ExpectedTerm::OptionalFloat(Some(-2.5))),
            ],
        });
    }
}
