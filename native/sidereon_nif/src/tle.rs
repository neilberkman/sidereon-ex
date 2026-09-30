//! Rustler boundary for the TLE format parser/encoder.
//!
//! Pure glue over `sidereon_core::astro::tle`: decode the two raw lines or the
//! normalized element map, forward to the crate codec, and encode the unchanged
//! Sidereon result shapes. No format grammar, checksum, or number codec lives here;
//! the epoch crosses as `(epoch_year, epoch_day_of_year)` and the Elixir binding
//! marshals it to/from its native `DateTime`.

use crate::ndm_errors::{sgp4_error_term, tle_error_term};
use rustler::{Atom, Encoder, Env, NifResult, Term};
use sidereon_core::astro::sgp4::{self, TleRecordIssue};
use sidereon_core::astro::tle::{
    self, ChecksumWarning, ChecksumWarningKind, TleElements, TlePolicy,
};

mod atoms {
    rustler::atoms! {
        ok,
        error,
        strict,
        lenient,
        mismatch,
        not_digit,
        missing,
        invalid,
        missing_line_2,
        orphan_line_2,
        orphan_name,
    }
}

/// Normalized element fields exchanged with the Elixir binding. Mirrors the
/// `%Sidereon.Elements{}` numeric content with the epoch already split into a
/// calendar year and one-based fractional day-of-year.
#[derive(Debug, Clone, rustler::NifMap)]
struct TleFields {
    catalog_number: String,
    classification: String,
    international_designator: String,
    epoch_year: i32,
    epoch_day_of_year: f64,
    mean_motion_dot: f64,
    mean_motion_double_dot: f64,
    mean_motion_double_dot_text: Option<String>,
    bstar: f64,
    bstar_text: Option<String>,
    ephemeris_type: Option<i32>,
    elset_number: Option<i32>,
    inclination_deg: f64,
    raan_deg: f64,
    eccentricity: f64,
    arg_perigee_deg: f64,
    mean_anomaly_deg: f64,
    mean_motion: f64,
    rev_number: Option<i32>,
}

impl From<TleElements> for TleFields {
    fn from(el: TleElements) -> Self {
        Self {
            catalog_number: el.catalog_number,
            classification: el.classification,
            international_designator: el.international_designator,
            epoch_year: el.epoch_year,
            epoch_day_of_year: el.epoch_day_of_year,
            mean_motion_dot: el.mean_motion_dot,
            mean_motion_double_dot: el.mean_motion_double_dot,
            mean_motion_double_dot_text: el.mean_motion_double_dot_text,
            bstar: el.bstar,
            bstar_text: el.bstar_text,
            ephemeris_type: el.ephemeris_type,
            elset_number: el.elset_number,
            inclination_deg: el.inclination_deg,
            raan_deg: el.raan_deg,
            eccentricity: el.eccentricity,
            arg_perigee_deg: el.arg_perigee_deg,
            mean_anomaly_deg: el.mean_anomaly_deg,
            mean_motion: el.mean_motion,
            rev_number: el.rev_number,
        }
    }
}

impl From<TleFields> for TleElements {
    fn from(f: TleFields) -> Self {
        Self {
            catalog_number: f.catalog_number,
            classification: f.classification,
            international_designator: f.international_designator,
            epoch_year: f.epoch_year,
            epoch_day_of_year: f.epoch_day_of_year,
            mean_motion_dot: f.mean_motion_dot,
            mean_motion_double_dot: f.mean_motion_double_dot,
            mean_motion_double_dot_text: f.mean_motion_double_dot_text,
            bstar: f.bstar,
            bstar_text: f.bstar_text,
            ephemeris_type: f.ephemeris_type,
            elset_number: f.elset_number,
            inclination_deg: f.inclination_deg,
            raan_deg: f.raan_deg,
            eccentricity: f.eccentricity,
            arg_perigee_deg: f.arg_perigee_deg,
            mean_anomaly_deg: f.mean_anomaly_deg,
            mean_motion: f.mean_motion,
            rev_number: f.rev_number,
        }
    }
}

fn decode_policy(policy: Atom) -> NifResult<TlePolicy> {
    if policy == atoms::strict() {
        Ok(TlePolicy::Strict)
    } else if policy == atoms::lenient() {
        Ok(TlePolicy::Lenient)
    } else {
        Err(rustler::Error::BadArg)
    }
}

/// `{line_label, kind, computed}`, where `kind` is `{:mismatch, digit}`,
/// `{:not_digit, character}` or `:missing`.
fn encode_warning<'a>(env: Env<'a>, warning: &ChecksumWarning) -> Term<'a> {
    let kind = match warning.kind {
        ChecksumWarningKind::Mismatch { expected } => {
            (atoms::mismatch(), expected as i64).encode(env)
        }
        ChecksumWarningKind::NotDigit { found } => {
            (atoms::not_digit(), found.to_string()).encode(env)
        }
        ChecksumWarningKind::Missing => atoms::missing().encode(env),
    };
    (
        warning.line_label.to_string(),
        kind,
        warning.computed as i64,
    )
        .encode(env)
}

fn encode_warnings<'a>(env: Env<'a>, warnings: &[ChecksumWarning]) -> Term<'a> {
    warnings
        .iter()
        .map(|w| encode_warning(env, w))
        .collect::<Vec<_>>()
        .encode(env)
}

/// Returns `{:ok, fields, checksum_warnings}` on success, or `{:error, reason}`.
/// Each checksum warning is `{line_label, kind, computed_digit}`: a line with
/// no column 69 under either policy, and under `:lenient` also a mismatching
/// digit or a non-digit, which `:strict` refuses.
#[rustler::nif]
fn tle_parse<'a>(env: Env<'a>, line1: String, line2: String, policy: Atom) -> NifResult<Term<'a>> {
    let policy = decode_policy(policy)?;
    Ok(match tle::parse_with_policy(&line1, &line2, policy) {
        Ok(parsed) => {
            let fields: TleFields = parsed.elements.into();
            let warnings = encode_warnings(env, &parsed.checksum_warnings);
            (atoms::ok(), fields, warnings).encode(env)
        }
        Err(e) => (atoms::error(), tle_error_term(env, &e)).encode(env),
    })
}

#[rustler::nif]
fn tle_encode(env: Env, fields: TleFields) -> Term {
    match tle::encode(&fields.into()) {
        Ok(lines) => (atoms::ok(), lines).encode(env),
        Err(e) => (atoms::error(), tle_error_term(env, &e)).encode(env),
    }
}

fn encode_issue<'a>(env: Env<'a>, issue: &TleRecordIssue) -> Term<'a> {
    match issue {
        TleRecordIssue::Invalid(error) => {
            (atoms::invalid(), sgp4_error_term(env, error)).encode(env)
        }
        TleRecordIssue::MissingLine2 => atoms::missing_line_2().encode(env),
        TleRecordIssue::OrphanLine2 => atoms::orphan_line_2().encode(env),
        TleRecordIssue::OrphanName => atoms::orphan_name().encode(env),
    }
}

/// Parse a CelesTrak/Space-Track multi-record TLE file.
///
/// Returns `{:ok, satellites, rejected}`. `satellites` lists
/// `{name, fields, line_number, checksum_warnings}` in file order (the name is
/// the empty string for a bare two-line record, `line_number` the one-based
/// line of its line 1). `rejected` lists `{line_number, name, issue}` for every
/// other non-blank line, where `issue` is `{:invalid, reason}`,
/// `:missing_line_2`, `:orphan_line_2` or `:orphan_name`. The file scan, name
/// handling and rejection accounting live in
/// `sidereon_core::astro::sgp4::parse_tle_file_with_policy`; this is glue.
#[rustler::nif]
fn parse_tle_file<'a>(env: Env<'a>, text: String, policy: Atom) -> NifResult<Term<'a>> {
    let policy = decode_policy(policy)?;
    let file = sgp4::parse_tle_file_with_policy(&text, sgp4::OpsMode::Improved, policy);
    let mut satellites = Vec::with_capacity(file.satellites.len());
    for named in file.satellites {
        // Re-derive the normalized element fields from the satellite's source
        // lines through the same codec and policy `tle_parse` uses. Every
        // satellite in a parsed file carries its raw lines and was read under
        // this policy, so this parse cannot fail.
        let parsed =
            tle::parse_with_policy(named.satellite.line1(), named.satellite.line2(), policy)
                .map_err(|e| rustler::Error::Term(Box::new(e.to_string())))?;
        let fields: TleFields = parsed.elements.into();
        satellites.push(
            (
                named.name,
                fields,
                named.line_number as u64,
                encode_warnings(env, &named.checksum_warnings),
            )
                .encode(env),
        );
    }
    let rejected: Vec<Term<'a>> = file
        .rejected
        .iter()
        .map(|record| {
            (
                record.line_number as u64,
                record.name.clone(),
                encode_issue(env, &record.issue),
            )
                .encode(env)
        })
        .collect();
    Ok((atoms::ok(), satellites, rejected).encode(env))
}
