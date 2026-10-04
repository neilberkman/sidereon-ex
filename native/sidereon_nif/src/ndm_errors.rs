//! Typed error terms for the CCSDS NDM (OMM, OPM, OEM, CDM), TLE and SGP4
//! element-set boundaries.
//!
//! Every core error crosses as a term that carries every field the core error
//! holds, in one shape:
//!
//! * a variant with no fields is its atom (`:incomplete_state_vector`);
//! * a variant with fields is a tuple of its atom and its fields in core order
//!   (`{:duplicate_field, field, first, second}`).
//!
//! A field the core names with a compile-time identifier (`&'static str`, such
//! as `MEAN_MOTION` or `epoch.month`) crosses as an atom, lowercased
//! (`:mean_motion`, `:"epoch.month"`); these names form a fixed set. Text the
//! core took from the input (a `String`, such as a keyword a message states)
//! crosses as a string, so no atom is formed from input. Counts, indices and
//! line numbers cross as integers, an optional value as `nil` when absent, and
//! a nested error (`OmmError::InRecord`) as its own term.
//!
//! An input the binding refuses before the core sees it uses the same shape:
//! `{:invalid_length, group, expected, got}` for a list of the wrong length,
//! and `{:invalid_field, field, kind}` for a value out of range or not finite.

use rustler::{Encoder, Env, Term};
use sidereon_core::astro::cdm::{CdmError, CdmInputErrorKind};
use sidereon_core::astro::ndm::TextIssue;
use sidereon_core::astro::oem::{OemError, OemInputErrorKind, OemStateLineError};
use sidereon_core::astro::omm::{OmmError, OmmInputErrorKind};
use sidereon_core::astro::opm::{OpmError, OpmInputErrorKind};
use sidereon_core::astro::sgp4::{Error as Sgp4Error, Sgp4InputErrorKind};
use sidereon_core::astro::tle::TleError;

mod atoms {
    rustler::atoms! {
        // Shared variant tags.
        missing_field,
        invalid_field,
        field,
        epoch,
        duplicate_field,
        unknown_field,
        csv_column_count,
        csv_empty_block,
        malformed_line,
        unit_mismatch,
        multiple_messages,
        in_record,
        csv_column_order,
        incompatible_metadata,
        unwritable_text,
        incomplete_state_vector,
        malformed_xml,
        unexpected_object_count,
        unknown_object,
        repeated_object,
        hard_body_radius_comment,
        item_count,
        invalid_length,
        // TLE.
        non_ascii,
        format,
        satellite_mismatch,
        invalid_catalog_number,
        catalog_number_out_of_range,
        checksum_mismatch,
        checksum_not_digit,
        // SGP4.
        invalid_input,
        non_finite_output,
        invalid_tle,
        sgp4,
        resonance_step_budget,
        // Input error kinds.
        missing,
        non_finite,
        float_parse,
        int_parse,
        not_positive,
        negative,
        out_of_range,
        invalid_civil_date,
        invalid_civil_time,
        // Text issues.
        line_break,
        surrounding_whitespace,
        interior_whitespace,
        keyword_separator,
        xml_illegal_character,
        empty,
        detached_comment,
        repeated_parameter,
        comment_not_carried,
    }
}

/// The atom for a core compile-time field or block name, lowercased:
/// `MEAN_MOTION` is `:mean_motion`, `epoch.month` is `:"epoch.month"`.
pub(crate) fn name_atom<'a>(env: Env<'a>, name: &str) -> Term<'a> {
    match rustler::Atom::from_str(env, &name.to_ascii_lowercase()) {
        Ok(atom) => atom.encode(env),
        Err(_) => name.encode(env),
    }
}

/// `:line_break`, `:surrounding_whitespace`, `:interior_whitespace`,
/// `:keyword_separator`, `:xml_illegal_character`, `:empty`,
/// `:detached_comment`, `:repeated_parameter` or `:comment_not_carried`.
pub(crate) fn text_issue_atom(issue: TextIssue) -> rustler::Atom {
    match issue {
        TextIssue::LineBreak => atoms::line_break(),
        TextIssue::SurroundingWhitespace => atoms::surrounding_whitespace(),
        TextIssue::InteriorWhitespace => atoms::interior_whitespace(),
        TextIssue::KeywordSeparator => atoms::keyword_separator(),
        TextIssue::XmlIllegalCharacter => atoms::xml_illegal_character(),
        TextIssue::Empty => atoms::empty(),
        TextIssue::DetachedComment => atoms::detached_comment(),
        TextIssue::RepeatedParameter => atoms::repeated_parameter(),
        TextIssue::CommentNotCarried => atoms::comment_not_carried(),
    }
}

// The four NDM input error kinds and the SGP4 one share their variants; each
// maps to the same atoms.
macro_rules! input_kind_atom {
    ($name:ident, $kind:ty) => {
        pub(crate) fn $name(kind: $kind) -> rustler::Atom {
            type K = $kind;
            match kind {
                K::Missing => atoms::missing(),
                K::NonFinite => atoms::non_finite(),
                K::FloatParse => atoms::float_parse(),
                K::IntParse => atoms::int_parse(),
                K::NotPositive => atoms::not_positive(),
                K::Negative => atoms::negative(),
                K::OutOfRange => atoms::out_of_range(),
                K::InvalidCivilDate => atoms::invalid_civil_date(),
                K::InvalidCivilTime => atoms::invalid_civil_time(),
            }
        }
    };
}

input_kind_atom!(omm_kind_atom, OmmInputErrorKind);
input_kind_atom!(opm_kind_atom, OpmInputErrorKind);
input_kind_atom!(oem_kind_atom, OemInputErrorKind);
input_kind_atom!(cdm_kind_atom, CdmInputErrorKind);
input_kind_atom!(sgp4_kind_atom, Sgp4InputErrorKind);

/// `{:duplicate_field, field, first, second}`.
fn duplicate<'a>(env: Env<'a>, field: &str, first: &str, second: &str) -> Term<'a> {
    (atoms::duplicate_field(), field, first, second).encode(env)
}

/// `{:unit_mismatch, field, unit, expected | nil}`.
fn unit_mismatch<'a>(
    env: Env<'a>,
    field: &str,
    unit: &str,
    expected: Option<&'static str>,
) -> Term<'a> {
    (atoms::unit_mismatch(), field, unit, expected).encode(env)
}

/// `{:malformed_line, line, text}`.
fn malformed_line<'a>(env: Env<'a>, line: usize, text: &str) -> Term<'a> {
    (atoms::malformed_line(), line as u64, text).encode(env)
}

/// `{:unwritable_text, field, value, issue}`.
fn unwritable<'a>(env: Env<'a>, field: &str, value: &str, issue: TextIssue) -> Term<'a> {
    (
        atoms::unwritable_text(),
        field,
        value,
        text_issue_atom(issue),
    )
        .encode(env)
}

/// The typed term for an [`OmmError`].
pub(crate) fn omm_error_term<'a>(env: Env<'a>, error: &OmmError) -> Term<'a> {
    match error {
        OmmError::MissingField(field) => {
            (atoms::missing_field(), name_atom(env, field)).encode(env)
        }
        OmmError::InvalidField { field, kind } => (
            atoms::invalid_field(),
            name_atom(env, field),
            omm_kind_atom(*kind),
        )
            .encode(env),
        OmmError::Field(text) => (atoms::field(), text).encode(env),
        OmmError::Epoch(text) => (atoms::epoch(), text).encode(env),
        OmmError::DuplicateField {
            field,
            first,
            second,
        } => duplicate(env, field, first, second),
        OmmError::UnknownField(field) => (atoms::unknown_field(), field).encode(env),
        OmmError::CsvColumnCount { found, expected } => {
            (atoms::csv_column_count(), *found as u64, *expected as u64).encode(env)
        }
        OmmError::CsvEmptyBlock(block) => {
            (atoms::csv_empty_block(), name_atom(env, block)).encode(env)
        }
        OmmError::MalformedLine { line, text } => malformed_line(env, *line, text),
        OmmError::UnitMismatch {
            field,
            unit,
            expected,
        } => unit_mismatch(env, field, unit, *expected),
        OmmError::MultipleMessages { count } => {
            (atoms::multiple_messages(), *count as u64).encode(env)
        }
        OmmError::InRecord { index, source } => (
            atoms::in_record(),
            *index as u64,
            omm_error_term(env, source),
        )
            .encode(env),
        OmmError::CsvColumnOrder { first, second } => {
            (atoms::csv_column_order(), first, second).encode(env)
        }
        OmmError::IncompatibleMetadata { field, value } => {
            (atoms::incompatible_metadata(), name_atom(env, field), value).encode(env)
        }
        OmmError::UnwritableText {
            field,
            value,
            issue,
        } => unwritable(env, field, value, *issue),
    }
}

/// The typed term for an [`OpmError`].
pub(crate) fn opm_error_term<'a>(env: Env<'a>, error: &OpmError) -> Term<'a> {
    match error {
        OpmError::MissingField(field) => {
            (atoms::missing_field(), name_atom(env, field)).encode(env)
        }
        OpmError::InvalidField { field, kind } => (
            atoms::invalid_field(),
            name_atom(env, field),
            opm_kind_atom(*kind),
        )
            .encode(env),
        OpmError::Field(text) => (atoms::field(), text).encode(env),
        OpmError::DuplicateField {
            field,
            first,
            second,
        } => duplicate(env, field, first, second),
        OpmError::UnitMismatch {
            field,
            unit,
            expected,
        } => unit_mismatch(env, field, unit, *expected),
        OpmError::MultipleMessages { count } => {
            (atoms::multiple_messages(), *count as u64).encode(env)
        }
        OpmError::UnknownField(field) => (atoms::unknown_field(), field).encode(env),
        OpmError::MalformedLine { line, text } => malformed_line(env, *line, text),
        OpmError::UnwritableText {
            field,
            value,
            issue,
        } => unwritable(env, field, value, *issue),
    }
}

/// The typed term for an [`OemError`].
pub(crate) fn oem_error_term<'a>(env: Env<'a>, error: &OemError) -> Term<'a> {
    match error {
        OemError::MissingField(field) => {
            (atoms::missing_field(), name_atom(env, field)).encode(env)
        }
        OemError::InvalidField { field, kind } => (
            atoms::invalid_field(),
            name_atom(env, field),
            oem_kind_atom(*kind),
        )
            .encode(env),
        OemError::Field(text) => (atoms::field(), text).encode(env),
        OemError::DuplicateField {
            field,
            first,
            second,
        } => duplicate(env, field, first, second),
        OemError::UnitMismatch {
            field,
            unit,
            expected,
        } => unit_mismatch(env, field, unit, *expected),
        OemError::MultipleMessages { count } => {
            (atoms::multiple_messages(), *count as u64).encode(env)
        }
        OemError::UnknownField(field) => (atoms::unknown_field(), field).encode(env),
        OemError::MalformedLine { line, text } => malformed_line(env, *line, text),
        OemError::UnwritableText {
            field,
            value,
            issue,
        } => unwritable(env, field, value, *issue),
    }
}

/// `{:item_count, n}` or `{:invalid_field, item, kind}` for an OEM ephemeris
/// data line the reader skipped.
pub(crate) fn oem_state_line_error_term<'a>(env: Env<'a>, error: &OemStateLineError) -> Term<'a> {
    match error {
        OemStateLineError::ItemCount(count) => (atoms::item_count(), *count as u64).encode(env),
        OemStateLineError::InvalidField { field, kind } => (
            atoms::invalid_field(),
            name_atom(env, field),
            oem_kind_atom(*kind),
        )
            .encode(env),
    }
}

/// The typed term for a [`CdmError`].
pub(crate) fn cdm_error_term<'a>(env: Env<'a>, error: &CdmError) -> Term<'a> {
    match error {
        CdmError::IncompleteStateVector => atoms::incomplete_state_vector().encode(env),
        CdmError::InvalidField { field, kind } => (
            atoms::invalid_field(),
            name_atom(env, field),
            cdm_kind_atom(*kind),
        )
            .encode(env),
        CdmError::MalformedXml(text) => (atoms::malformed_xml(), text).encode(env),
        CdmError::DuplicateField {
            field,
            first,
            second,
        } => duplicate(env, field, first, second),
        CdmError::UnitMismatch {
            field,
            unit,
            expected,
        } => unit_mismatch(env, field, unit, *expected),
        CdmError::UnexpectedObjectCount(count) => {
            (atoms::unexpected_object_count(), *count as u64).encode(env)
        }
        CdmError::MultipleMessages { count } => {
            (atoms::multiple_messages(), *count as u64).encode(env)
        }
        CdmError::UnknownField(field) => (atoms::unknown_field(), field).encode(env),
        CdmError::MalformedLine { line, text } => malformed_line(env, *line, text),
        CdmError::UnknownObject(object) => (atoms::unknown_object(), object).encode(env),
        CdmError::RepeatedObject(object) => (atoms::repeated_object(), object).encode(env),
        CdmError::UnwritableText {
            field,
            value,
            issue,
        } => unwritable(env, field, value, *issue),
        CdmError::HardBodyRadiusComment { comment } => {
            (atoms::hard_body_radius_comment(), comment).encode(env)
        }
    }
}

/// The typed term for a [`TleError`]. `reason` fields are the core's fixed
/// description of the refusal, and line labels are `"line 1"` / `"line 2"`.
pub(crate) fn tle_error_term<'a>(env: Env<'a>, error: &TleError) -> Term<'a> {
    match error {
        TleError::NonAscii => atoms::non_ascii().encode(env),
        TleError::Format => atoms::format().encode(env),
        TleError::SatelliteMismatch => atoms::satellite_mismatch().encode(env),
        TleError::InvalidCatalogNumber { value, reason } => {
            (atoms::invalid_catalog_number(), value, *reason).encode(env)
        }
        TleError::CatalogNumberOutOfRange { catalog_number } => {
            (atoms::catalog_number_out_of_range(), *catalog_number).encode(env)
        }
        TleError::InvalidField { field, reason } => {
            (atoms::invalid_field(), name_atom(env, field), *reason).encode(env)
        }
        TleError::Field(text) => (atoms::field(), text).encode(env),
        TleError::ChecksumMismatch {
            line_label,
            expected,
            computed,
        } => (
            atoms::checksum_mismatch(),
            *line_label,
            *expected as u64,
            *computed as u64,
        )
            .encode(env),
        TleError::ChecksumNotDigit {
            line_label,
            found,
            computed,
        } => (
            atoms::checksum_not_digit(),
            *line_label,
            found.to_string(),
            *computed as u64,
        )
            .encode(env),
    }
}

/// The typed term for an SGP4 element-set [`Sgp4Error`]:
/// `{:invalid_input, field, kind}`, `{:non_finite_output, field}`,
/// `{:invalid_tle, text}` or `{:sgp4, code}`.
pub(crate) fn sgp4_error_term<'a>(env: Env<'a>, error: &Sgp4Error) -> Term<'a> {
    match error {
        Sgp4Error::InvalidInput { field, kind } => (
            atoms::invalid_input(),
            name_atom(env, field),
            sgp4_kind_atom(*kind),
        )
            .encode(env),
        Sgp4Error::NonFiniteOutput { field } => {
            (atoms::non_finite_output(), name_atom(env, field)).encode(env)
        }
        Sgp4Error::InvalidTle(text) => (atoms::invalid_tle(), text).encode(env),
        Sgp4Error::Sgp4 { code } => (atoms::sgp4(), *code).encode(env),
        Sgp4Error::ResonanceStepBudget { budget } => {
            (atoms::resonance_step_budget(), *budget).encode(env)
        }
    }
}

/// An input the binding refuses before it reaches the core.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum InputRefusal {
    /// A list that must hold exactly `expected` values holds `got`.
    Length {
        group: &'static str,
        expected: usize,
        got: usize,
    },
    /// An integer outside the range the core field holds.
    OutOfRange { field: &'static str },
    /// A number that is not finite.
    NonFinite { field: &'static str },
}

impl InputRefusal {
    /// `{:invalid_length, group, expected, got}` or
    /// `{:invalid_field, field, :out_of_range | :non_finite}`.
    pub(crate) fn term<'a>(&self, env: Env<'a>) -> Term<'a> {
        match *self {
            InputRefusal::Length {
                group,
                expected,
                got,
            } => (
                atoms::invalid_length(),
                name_atom(env, group),
                expected as u64,
                got as u64,
            )
                .encode(env),
            InputRefusal::OutOfRange { field } => (
                atoms::invalid_field(),
                name_atom(env, field),
                atoms::out_of_range(),
            )
                .encode(env),
            InputRefusal::NonFinite { field } => (
                atoms::invalid_field(),
                name_atom(env, field),
                atoms::non_finite(),
            )
                .encode(env),
        }
    }
}
