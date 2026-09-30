//! Rustler boundary for CCSDS Tracking Data Message KVN.
//!
//! This file mirrors the canonical core TDM structs as `NifMap` terms. Parsing,
//! validation, unit assignment, metadata derivation and KVN serialization remain
//! in `sidereon_core::astro::tdm`.
//!
//! - `tdm_parse_kvn/1` and `tdm_encode_kvn/1` are the strict entries;
//!   `tdm_parse_kvn_with_policy/2` and `tdm_encode_kvn_with_policy/2` take a
//!   [`TdmPolicy`] or [`TdmWritePolicy`] and return every [`TdmWarning`] or
//!   [`TdmDeparture`] beside the value.
//! - `tdm_metadata_from_raw*/2,3` and `tdm_metadata_replace_raw*/3,4` build and
//!   replace a metadata block from its ordered raw fields and positioned
//!   comments through the core's constructors, so every derived property comes
//!   from those fields.
//! - Every refusal is `{tag, %{field => value}}` with every field its
//!   [`TdmError`] variant carries. The core error, warning and departure enums
//!   are `#[non_exhaustive]`; a variant this binding predates is tagged
//!   `:unhandled` with the core's own text, never another variant's tag.
//!
//! Every atom built here comes from the `atoms!` list below; nothing a message
//! carries becomes an atom.

use rustler::{Atom, Encoder, Env, NifResult, Term};
use sidereon_core::astro::tdm::{
    self as core_tdm, Tdm, TdmComment, TdmDataRecord, TdmDataSection, TdmDeparture, TdmError,
    TdmField, TdmInputErrorKind, TdmLeniency, TdmMetadata, TdmObservable, TdmParticipant, TdmPath,
    TdmPolicy, TdmScalar, TdmSegment, TdmUnit, TdmWarning, TdmWritePolicy,
};

mod atoms {
    rustler::atoms! {
        ok,
        error,
        strict,
        forgive,
        unhandled,
        invalid_policy_value,

        // Sections
        header,
        metadata,
        data,

        // Error, warning and departure tags
        no_segments,
        section,
        malformed_line,
        non_printable_character,
        line_too_long,
        malformed_epoch,
        records_out_of_order,
        duplicate_record,
        unterminated_final_line,
        unwritable,
        keyword_out_of_order,
        undefined_participant,
        conflicting_keyword,
        repeated_keyword,
        undefined_keyword,
        missing_keyword,
        empty_data_section,
        empty_value,
        invalid_version,
        keyword_not_assignable,
        malformed_record,
        invalid_field,
        metadata_not_derived,

        // Input error kinds
        missing,
        float_parse,
        non_finite,
        not_positive,
        out_of_range,
        invalid_index,
        unknown_keyword,
        unexpected_unit,
        non_integer,
        negative,
        negative_zero,
        unit_mismatch,
        decimal_mismatch,

        // Payload field names
        line,
        detail,
        text,
        keyword,
        column,
        character,
        length,
        segment,
        epoch,
        reason,
        index,
        first,
        second,
        value,
        kind,
        message,
        property,

        // Derived metadata properties
        participants,
        mode,
        paths,
        timetag_ref,
        time_system,
        range_units
    }
}

#[derive(Debug, Clone, rustler::NifMap)]
struct TdmFieldTerm {
    key: String,
    value: String,
}

/// A comment and the index of the field or record it precedes.
#[derive(Debug, Clone, rustler::NifMap)]
struct TdmCommentTerm {
    text: String,
    before_record: usize,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct TdmObservableTerm {
    kind: String,
    participant: Option<u8>,
    name: Option<String>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct TdmScalarTerm {
    text: String,
    value: f64,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct TdmDataRecordTerm {
    observable: TdmObservableTerm,
    keyword: String,
    epoch: String,
    value: TdmScalarTerm,
    unit: String,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct TdmDataSectionTerm {
    comments: Vec<TdmCommentTerm>,
    records: Vec<TdmDataRecordTerm>,
}

#[derive(Debug, Clone, PartialEq, rustler::NifMap)]
struct TdmParticipantTerm {
    index: u8,
    name: String,
}

#[derive(Debug, Clone, PartialEq, rustler::NifMap)]
struct TdmPathTerm {
    key: String,
    index: Option<u8>,
    participants: Vec<u8>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct TdmMetadataTerm {
    comments: Vec<TdmCommentTerm>,
    fields: Vec<TdmFieldTerm>,
    participants: Vec<TdmParticipantTerm>,
    mode: Option<String>,
    paths: Vec<TdmPathTerm>,
    timetag_ref: Option<String>,
    time_system: Option<String>,
    range_units: String,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct TdmSegmentTerm {
    metadata: TdmMetadataTerm,
    data: TdmDataSectionTerm,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct TdmTerm {
    version: String,
    comments: Vec<TdmCommentTerm>,
    creation_date: Option<String>,
    originator: Option<String>,
    message_id: Option<String>,
    header_fields: Vec<TdmFieldTerm>,
    segments: Vec<TdmSegmentTerm>,
}

/// The reader policy, one `:strict` or `:forgive` per axis [`TdmPolicy`] has.
#[derive(Debug, Clone, rustler::NifMap)]
struct TdmPolicyTerm {
    non_printable: Atom,
    missing_keywords: Atom,
    long_lines: Atom,
    empty_data_sections: Atom,
    record_order: Atom,
    duplicate_records: Atom,
    keyword_order: Atom,
    final_terminator: Atom,
}

/// The writer policy, one `:strict` or `:forgive` per axis [`TdmWritePolicy`]
/// has.
#[derive(Debug, Clone, rustler::NifMap)]
struct TdmWritePolicyTerm {
    non_printable: Atom,
    missing_keywords: Atom,
    long_lines: Atom,
    empty_data_sections: Atom,
    record_order: Atom,
    duplicate_records: Atom,
    keyword_order: Atom,
    final_terminator: Atom,
    repeated_keywords: Atom,
}

/// One [`TdmWarning`] with every field its variant carries and `nil` in every
/// other, beside the core's formatted text.
#[derive(Debug, Clone, rustler::NifMap)]
struct TdmWarningTerm<'a> {
    tag: Atom,
    line: Option<usize>,
    keyword: Option<String>,
    column: Option<usize>,
    character: Option<String>,
    length: Option<usize>,
    section: Option<Term<'a>>,
    segment: Option<usize>,
    epoch: Option<String>,
    message: String,
}

/// One [`TdmDeparture`] with every field its variant carries and `nil` in
/// every other, beside the core's formatted text.
#[derive(Debug, Clone, rustler::NifMap)]
struct TdmDepartureTerm<'a> {
    tag: Atom,
    keyword: Option<String>,
    character: Option<String>,
    length: Option<usize>,
    segment: Option<usize>,
    epoch: Option<String>,
    section: Option<Term<'a>>,
    message: String,
}

fn field_term(value: TdmField) -> TdmFieldTerm {
    TdmFieldTerm {
        key: value.key,
        value: value.value,
    }
}

fn field(value: TdmFieldTerm) -> TdmField {
    TdmField {
        key: value.key,
        value: value.value,
    }
}

fn comment_term(value: TdmComment) -> TdmCommentTerm {
    TdmCommentTerm {
        text: value.text,
        before_record: value.before_record,
    }
}

fn comment(value: TdmCommentTerm) -> TdmComment {
    TdmComment {
        text: value.text,
        before_record: value.before_record,
    }
}

fn observable_term(value: TdmObservable) -> TdmObservableTerm {
    let (kind, participant, name) = match value {
        TdmObservable::Range => ("range", None, None),
        TdmObservable::DopplerInstantaneous => ("doppler_instantaneous", None, None),
        TdmObservable::DopplerIntegrated => ("doppler_integrated", None, None),
        TdmObservable::ReceiveFreq { participant } => ("receive_freq", participant, None),
        TdmObservable::TransmitFreq { participant } => ("transmit_freq", participant, None),
        TdmObservable::TransmitFreqRate { participant } => {
            ("transmit_freq_rate", participant, None)
        }
        TdmObservable::Angle1 => ("angle_1", None, None),
        TdmObservable::Angle2 => ("angle_2", None, None),
        TdmObservable::Other(name) => ("other", None, Some(name)),
    };
    TdmObservableTerm {
        kind: kind.to_string(),
        participant,
        name,
    }
}

fn observable(value: TdmObservableTerm) -> TdmObservable {
    match value.kind.as_str() {
        "range" => TdmObservable::Range,
        "doppler_instantaneous" => TdmObservable::DopplerInstantaneous,
        "doppler_integrated" => TdmObservable::DopplerIntegrated,
        "receive_freq" => TdmObservable::ReceiveFreq {
            participant: value.participant,
        },
        "transmit_freq" => TdmObservable::TransmitFreq {
            participant: value.participant,
        },
        "transmit_freq_rate" => TdmObservable::TransmitFreqRate {
            participant: value.participant,
        },
        "angle_1" => TdmObservable::Angle1,
        "angle_2" => TdmObservable::Angle2,
        "other" => TdmObservable::Other(value.name.unwrap_or_default()),
        other => TdmObservable::Other(other.to_string()),
    }
}

fn unit_label(value: TdmUnit) -> String {
    value.as_str().to_string()
}

fn unit(value: String) -> TdmUnit {
    match value.as_str() {
        "km" => TdmUnit::Kilometers,
        "s" => TdmUnit::Seconds,
        "RU" => TdmUnit::RangeUnits,
        "km/s" => TdmUnit::KilometersPerSecond,
        "Hz" => TdmUnit::Hertz,
        "Hz/s" => TdmUnit::HertzPerSecond,
        "deg" => TdmUnit::Degrees,
        "dBW" => TdmUnit::DecibelWatts,
        "dBHz" => TdmUnit::DecibelHertz,
        "m**2" => TdmUnit::SquareMeters,
        "m" => TdmUnit::Meters,
        "s/s" => TdmUnit::SecondsPerSecond,
        "%" => TdmUnit::Percent,
        "K" => TdmUnit::Kelvin,
        "hPa" => TdmUnit::Hectopascals,
        "TECU" => TdmUnit::TotalElectronContentUnits,
        "n/a" => TdmUnit::Dimensionless,
        other => TdmUnit::Unknown(other.to_string()),
    }
}

fn record_term(value: TdmDataRecord) -> TdmDataRecordTerm {
    TdmDataRecordTerm {
        observable: observable_term(value.observable),
        keyword: value.keyword,
        epoch: value.epoch,
        value: TdmScalarTerm {
            text: value.value.text,
            value: value.value.value,
        },
        unit: unit_label(value.unit),
    }
}

fn record(value: TdmDataRecordTerm) -> TdmDataRecord {
    TdmDataRecord {
        observable: observable(value.observable),
        keyword: value.keyword,
        epoch: value.epoch,
        value: TdmScalar {
            text: value.value.text,
            value: value.value.value,
        },
        unit: unit(value.unit),
    }
}

fn data_section_term(value: TdmDataSection) -> TdmDataSectionTerm {
    TdmDataSectionTerm {
        comments: value.comments.into_iter().map(comment_term).collect(),
        records: value.records.into_iter().map(record_term).collect(),
    }
}

fn data_section(value: TdmDataSectionTerm) -> TdmDataSection {
    TdmDataSection {
        comments: value.comments.into_iter().map(comment).collect(),
        records: value.records.into_iter().map(record).collect(),
    }
}

fn participant_term(value: TdmParticipant) -> TdmParticipantTerm {
    TdmParticipantTerm {
        index: value.index,
        name: value.name,
    }
}

fn participant(value: TdmParticipantTerm) -> TdmParticipant {
    TdmParticipant {
        index: value.index,
        name: value.name,
    }
}

fn path_term(value: TdmPath) -> TdmPathTerm {
    TdmPathTerm {
        key: value.key,
        index: value.index,
        participants: value.participants,
    }
}

fn path(value: TdmPathTerm) -> TdmPath {
    TdmPath {
        key: value.key,
        index: value.index,
        participants: value.participants,
    }
}

fn metadata_term(value: TdmMetadata) -> TdmMetadataTerm {
    TdmMetadataTerm {
        comments: value.comments.into_iter().map(comment_term).collect(),
        fields: value.fields.into_iter().map(field_term).collect(),
        participants: value
            .participants
            .into_iter()
            .map(participant_term)
            .collect(),
        mode: value.mode,
        paths: value.paths.into_iter().map(path_term).collect(),
        timetag_ref: value.timetag_ref,
        time_system: value.time_system,
        range_units: unit_label(value.range_units),
    }
}

/// The metadata a caller holds, as the core type, with its derived properties
/// as the caller gave them. Used where the core takes an existing block to
/// replace; nothing here derives or corrects a property.
fn metadata_as_given(value: TdmMetadataTerm) -> TdmMetadata {
    TdmMetadata {
        comments: value.comments.into_iter().map(comment).collect(),
        fields: value.fields.into_iter().map(field).collect(),
        participants: value.participants.into_iter().map(participant).collect(),
        mode: value.mode,
        paths: value.paths.into_iter().map(path).collect(),
        timetag_ref: value.timetag_ref,
        time_system: value.time_system,
        range_units: unit(value.range_units),
    }
}

/// The first derived property on which a caller's metadata disagrees with what
/// its raw fields derive to, or `None` where they agree.
///
/// The raw fields are the metadata's authority: the writer emits them and
/// derives time system and range units from them. A derived property edited
/// without its field would be written as the field says, so a disagreement is
/// refused by name rather than dropped. Where the raw fields do not derive at
/// all, the writer refuses them with its own error, so no comparison is made.
fn stale_property(given: &TdmMetadataTerm) -> Option<Atom> {
    let fields: Vec<TdmField> = given.fields.iter().cloned().map(field).collect();
    let comments: Vec<TdmComment> = given.comments.iter().cloned().map(comment).collect();
    let (derived, _) =
        TdmMetadata::from_raw_with_policy(fields, comments, TdmWritePolicy::lenient()).ok()?;
    let derived = metadata_term(derived);
    if derived.participants != given.participants {
        Some(atoms::participants())
    } else if derived.mode != given.mode {
        Some(atoms::mode())
    } else if derived.paths != given.paths {
        Some(atoms::paths())
    } else if derived.timetag_ref != given.timetag_ref {
        Some(atoms::timetag_ref())
    } else if derived.time_system != given.time_system {
        Some(atoms::time_system())
    } else if derived.range_units != given.range_units {
        Some(atoms::range_units())
    } else {
        None
    }
}

fn segment_term(value: TdmSegment) -> TdmSegmentTerm {
    TdmSegmentTerm {
        metadata: metadata_term(value.metadata),
        data: data_section_term(value.data),
    }
}

fn tdm_term(value: Tdm) -> TdmTerm {
    TdmTerm {
        version: value.version,
        comments: value.comments.into_iter().map(comment_term).collect(),
        creation_date: value.creation_date,
        originator: value.originator,
        message_id: value.message_id,
        header_fields: value.header_fields.into_iter().map(field_term).collect(),
        segments: value.segments.into_iter().map(segment_term).collect(),
    }
}

/// The message a caller holds, as the core type, or
/// `{:metadata_not_derived, %{segment, property}}` naming the first segment
/// whose derived metadata properties disagree with its raw fields.
fn tdm<'a>(env: Env<'a>, value: TdmTerm) -> Result<Tdm, Term<'a>> {
    let mut segments = Vec::with_capacity(value.segments.len());
    for (index, segment) in value.segments.into_iter().enumerate() {
        if let Some(property) = stale_property(&segment.metadata) {
            return Err(tagged(
                env,
                atoms::metadata_not_derived(),
                vec![
                    (atoms::segment(), index.saturating_add(1).encode(env)),
                    (atoms::property(), property.encode(env)),
                ],
            ));
        }
        segments.push(TdmSegment {
            metadata: metadata_as_given(segment.metadata),
            data: data_section(segment.data),
        });
    }
    Ok(Tdm {
        version: value.version,
        comments: value.comments.into_iter().map(comment).collect(),
        creation_date: value.creation_date,
        originator: value.originator,
        message_id: value.message_id,
        header_fields: value.header_fields.into_iter().map(field).collect(),
        segments,
    })
}

fn leniency(value: Atom, name: &'static str) -> NifResult<TdmLeniency> {
    if value == atoms::strict() {
        Ok(TdmLeniency::Strict)
    } else if value == atoms::forgive() {
        Ok(TdmLeniency::Forgive)
    } else {
        Err(rustler::Error::Term(Box::new((
            atoms::invalid_policy_value(),
            name,
            value,
        ))))
    }
}

/// Build a [`TdmPolicy`] through its builders; the struct is
/// `#[non_exhaustive]`, and every axis is named, so none takes a default this
/// binding did not state.
fn read_policy(term: TdmPolicyTerm) -> NifResult<TdmPolicy> {
    Ok(TdmPolicy::strict()
        .with_non_printable(leniency(term.non_printable, "non_printable")?)
        .with_missing_keywords(leniency(term.missing_keywords, "missing_keywords")?)
        .with_long_lines(leniency(term.long_lines, "long_lines")?)
        .with_empty_data_sections(leniency(term.empty_data_sections, "empty_data_sections")?)
        .with_record_order(leniency(term.record_order, "record_order")?)
        .with_duplicate_records(leniency(term.duplicate_records, "duplicate_records")?)
        .with_keyword_order(leniency(term.keyword_order, "keyword_order")?)
        .with_final_terminator(leniency(term.final_terminator, "final_terminator")?))
}

/// Build a [`TdmWritePolicy`] through its builders, every axis named.
fn write_policy(term: TdmWritePolicyTerm) -> NifResult<TdmWritePolicy> {
    Ok(TdmWritePolicy::strict()
        .with_non_printable(leniency(term.non_printable, "non_printable")?)
        .with_missing_keywords(leniency(term.missing_keywords, "missing_keywords")?)
        .with_long_lines(leniency(term.long_lines, "long_lines")?)
        .with_empty_data_sections(leniency(term.empty_data_sections, "empty_data_sections")?)
        .with_record_order(leniency(term.record_order, "record_order")?)
        .with_duplicate_records(leniency(term.duplicate_records, "duplicate_records")?)
        .with_keyword_order(leniency(term.keyword_order, "keyword_order")?)
        .with_final_terminator(leniency(term.final_terminator, "final_terminator")?)
        .with_repeated_keywords(leniency(term.repeated_keywords, "repeated_keywords")?))
}

/// `:header`, `:metadata` or `:data` for the section names the core uses, and
/// the core's own string for any other.
fn section_term<'a>(env: Env<'a>, section: &str) -> Term<'a> {
    match section {
        "header" => atoms::header().encode(env),
        "metadata" => atoms::metadata().encode(env),
        "data" => atoms::data().encode(env),
        other => other.encode(env),
    }
}

/// The input-error category as an atom, and the core's own text for a category
/// this binding predates.
fn kind_term<'a>(env: Env<'a>, kind: TdmInputErrorKind) -> Term<'a> {
    let atom = match kind {
        TdmInputErrorKind::Missing => atoms::missing(),
        TdmInputErrorKind::FloatParse => atoms::float_parse(),
        TdmInputErrorKind::NonFinite => atoms::non_finite(),
        TdmInputErrorKind::NotPositive => atoms::not_positive(),
        TdmInputErrorKind::OutOfRange => atoms::out_of_range(),
        TdmInputErrorKind::InvalidIndex => atoms::invalid_index(),
        TdmInputErrorKind::UnknownKeyword => atoms::unknown_keyword(),
        TdmInputErrorKind::UnexpectedUnit => atoms::unexpected_unit(),
        TdmInputErrorKind::NonInteger => atoms::non_integer(),
        TdmInputErrorKind::Negative => atoms::negative(),
        TdmInputErrorKind::NegativeZero => atoms::negative_zero(),
        TdmInputErrorKind::UnitMismatch => atoms::unit_mismatch(),
        TdmInputErrorKind::DecimalMismatch => atoms::decimal_mismatch(),
        other => return other.to_string().encode(env),
    };
    atom.encode(env)
}

/// `{tag, %{field => value}}`, keyed by atoms from this module's list.
fn tagged<'a>(env: Env<'a>, tag: Atom, pairs: Vec<(Atom, Term<'a>)>) -> Term<'a> {
    let map = pairs
        .into_iter()
        .fold(rustler::types::map::map_new(env), |map, (key, value)| {
            // `map_put` fails only on a term that is not a map, and `map` is
            // always one here.
            map.map_put(key, value).unwrap_or(map)
        });
    (tag, map).encode(env)
}

/// A refusal with every field its variant carries.
fn error_term<'a>(env: Env<'a>, error: TdmError) -> Term<'a> {
    let message = error.to_string();
    let (tag, pairs): (Atom, Vec<(Atom, Term<'a>)>) = match error {
        TdmError::NoSegments => (atoms::no_segments(), vec![]),
        TdmError::Section { line, detail } => (
            atoms::section(),
            vec![
                (atoms::line(), line.encode(env)),
                (atoms::detail(), detail.encode(env)),
            ],
        ),
        TdmError::MalformedLine { line, text } => (
            atoms::malformed_line(),
            vec![
                (atoms::line(), line.encode(env)),
                (atoms::text(), text.encode(env)),
            ],
        ),
        TdmError::NonPrintableCharacter {
            line,
            keyword,
            column,
            character,
        } => (
            atoms::non_printable_character(),
            vec![
                (atoms::line(), line.encode(env)),
                (atoms::keyword(), keyword.encode(env)),
                (atoms::column(), column.encode(env)),
                (atoms::character(), character.to_string().encode(env)),
            ],
        ),
        TdmError::LineTooLong {
            line,
            keyword,
            length,
        } => (
            atoms::line_too_long(),
            vec![
                (atoms::line(), line.encode(env)),
                (atoms::keyword(), keyword.encode(env)),
                (atoms::length(), length.encode(env)),
            ],
        ),
        TdmError::MalformedEpoch {
            line,
            keyword,
            text,
        } => (
            atoms::malformed_epoch(),
            vec![
                (atoms::line(), line.encode(env)),
                (atoms::keyword(), keyword.encode(env)),
                (atoms::text(), text.encode(env)),
            ],
        ),
        TdmError::RecordsOutOfOrder {
            segment,
            keyword,
            epoch,
        } => (
            atoms::records_out_of_order(),
            vec![
                (atoms::segment(), segment.encode(env)),
                (atoms::keyword(), keyword.encode(env)),
                (atoms::epoch(), epoch.encode(env)),
            ],
        ),
        TdmError::DuplicateRecord {
            segment,
            keyword,
            epoch,
        } => (
            atoms::duplicate_record(),
            vec![
                (atoms::segment(), segment.encode(env)),
                (atoms::keyword(), keyword.encode(env)),
                (atoms::epoch(), epoch.encode(env)),
            ],
        ),
        TdmError::UnterminatedFinalLine { line } => (
            atoms::unterminated_final_line(),
            vec![(atoms::line(), line.encode(env))],
        ),
        TdmError::Unwritable { keyword, reason } => (
            atoms::unwritable(),
            vec![
                (atoms::keyword(), keyword.encode(env)),
                (atoms::reason(), reason.encode(env)),
            ],
        ),
        TdmError::KeywordOutOfOrder {
            line,
            keyword,
            section,
        } => (
            atoms::keyword_out_of_order(),
            vec![
                (atoms::line(), line.encode(env)),
                (atoms::keyword(), keyword.encode(env)),
                (atoms::section(), section_term(env, section)),
            ],
        ),
        TdmError::UndefinedParticipant {
            segment,
            keyword,
            index,
        } => (
            atoms::undefined_participant(),
            vec![
                (atoms::segment(), segment.encode(env)),
                (atoms::keyword(), keyword.encode(env)),
                (atoms::index(), index.encode(env)),
            ],
        ),
        TdmError::ConflictingKeyword {
            line,
            keyword,
            section,
            first,
            second,
        } => (
            atoms::conflicting_keyword(),
            vec![
                (atoms::line(), line.encode(env)),
                (atoms::keyword(), keyword.encode(env)),
                (atoms::section(), section_term(env, section)),
                (atoms::first(), first.encode(env)),
                (atoms::second(), second.encode(env)),
            ],
        ),
        TdmError::RepeatedKeyword {
            line,
            keyword,
            section,
        } => (
            atoms::repeated_keyword(),
            vec![
                (atoms::line(), line.encode(env)),
                (atoms::keyword(), keyword.encode(env)),
                (atoms::section(), section_term(env, section)),
            ],
        ),
        TdmError::UndefinedKeyword {
            line,
            keyword,
            section,
        } => (
            atoms::undefined_keyword(),
            vec![
                (atoms::line(), line.encode(env)),
                (atoms::keyword(), keyword.encode(env)),
                (atoms::section(), section_term(env, section)),
            ],
        ),
        TdmError::MissingKeyword { keyword, segment } => (
            atoms::missing_keyword(),
            vec![
                (atoms::keyword(), keyword.encode(env)),
                (atoms::segment(), segment.encode(env)),
            ],
        ),
        TdmError::EmptyDataSection { segment } => (
            atoms::empty_data_section(),
            vec![(atoms::segment(), segment.encode(env))],
        ),
        TdmError::EmptyValue { line, keyword } => (
            atoms::empty_value(),
            vec![
                (atoms::line(), line.encode(env)),
                (atoms::keyword(), keyword.encode(env)),
            ],
        ),
        TdmError::InvalidVersion { line, value } => (
            atoms::invalid_version(),
            vec![
                (atoms::line(), line.encode(env)),
                (atoms::value(), value.encode(env)),
            ],
        ),
        TdmError::KeywordNotAssignable { keyword } => (
            atoms::keyword_not_assignable(),
            vec![(atoms::keyword(), keyword.encode(env))],
        ),
        TdmError::MalformedRecord { line, keyword } => (
            atoms::malformed_record(),
            vec![
                (atoms::line(), line.encode(env)),
                (atoms::keyword(), keyword.encode(env)),
            ],
        ),
        TdmError::InvalidField { keyword, kind } => (
            atoms::invalid_field(),
            vec![
                (atoms::keyword(), keyword.encode(env)),
                (atoms::kind(), kind_term(env, kind)),
            ],
        ),
        _ => (
            atoms::unhandled(),
            vec![(atoms::message(), message.encode(env))],
        ),
    };
    tagged(env, tag, pairs)
}

fn warning_base<'a>(tag: Atom, message: String) -> TdmWarningTerm<'a> {
    TdmWarningTerm {
        tag,
        line: None,
        keyword: None,
        column: None,
        character: None,
        length: None,
        section: None,
        segment: None,
        epoch: None,
        message,
    }
}

fn warning_term<'a>(env: Env<'a>, warning: TdmWarning) -> TdmWarningTerm<'a> {
    let message = warning.to_string();
    match warning {
        TdmWarning::NonPrintableCharacter {
            line,
            keyword,
            column,
            character,
        } => {
            let mut term = warning_base(atoms::non_printable_character(), message);
            term.line = Some(line);
            term.keyword = Some(keyword);
            term.column = Some(column);
            term.character = Some(character.to_string());
            term
        }
        TdmWarning::LineTooLong {
            line,
            keyword,
            length,
        } => {
            let mut term = warning_base(atoms::line_too_long(), message);
            term.line = Some(line);
            term.keyword = Some(keyword);
            term.length = Some(length);
            term
        }
        TdmWarning::RepeatedKeyword {
            line,
            keyword,
            section,
        } => {
            let mut term = warning_base(atoms::repeated_keyword(), message);
            term.line = Some(line);
            term.keyword = Some(keyword);
            term.section = Some(section_term(env, section));
            term
        }
        TdmWarning::MissingKeyword { keyword, segment } => {
            let mut term = warning_base(atoms::missing_keyword(), message);
            term.keyword = Some(keyword);
            term.segment = segment;
            term
        }
        TdmWarning::EmptyDataSection { segment } => {
            let mut term = warning_base(atoms::empty_data_section(), message);
            term.segment = Some(segment);
            term
        }
        TdmWarning::RecordsOutOfOrder {
            segment,
            keyword,
            epoch,
        } => {
            let mut term = warning_base(atoms::records_out_of_order(), message);
            term.segment = Some(segment);
            term.keyword = Some(keyword);
            term.epoch = Some(epoch);
            term
        }
        TdmWarning::UnterminatedFinalLine { line } => {
            let mut term = warning_base(atoms::unterminated_final_line(), message);
            term.line = Some(line);
            term
        }
        TdmWarning::KeywordOutOfOrder {
            line,
            keyword,
            section,
        } => {
            let mut term = warning_base(atoms::keyword_out_of_order(), message);
            term.line = Some(line);
            term.keyword = Some(keyword);
            term.section = Some(section_term(env, section));
            term
        }
        TdmWarning::DuplicateRecord {
            segment,
            keyword,
            epoch,
        } => {
            let mut term = warning_base(atoms::duplicate_record(), message);
            term.segment = Some(segment);
            term.keyword = Some(keyword);
            term.epoch = Some(epoch);
            term
        }
        _ => warning_base(atoms::unhandled(), message),
    }
}

fn departure_base<'a>(tag: Atom, message: String) -> TdmDepartureTerm<'a> {
    TdmDepartureTerm {
        tag,
        keyword: None,
        character: None,
        length: None,
        segment: None,
        epoch: None,
        section: None,
        message,
    }
}

fn departure_term<'a>(env: Env<'a>, departure: TdmDeparture) -> TdmDepartureTerm<'a> {
    let message = departure.to_string();
    match departure {
        TdmDeparture::NonPrintableCharacter { keyword, character } => {
            let mut term = departure_base(atoms::non_printable_character(), message);
            term.keyword = Some(keyword);
            term.character = Some(character.to_string());
            term
        }
        TdmDeparture::LineTooLong { keyword, length } => {
            let mut term = departure_base(atoms::line_too_long(), message);
            term.keyword = Some(keyword);
            term.length = Some(length);
            term
        }
        TdmDeparture::MissingKeyword { keyword, segment } => {
            let mut term = departure_base(atoms::missing_keyword(), message);
            term.keyword = Some(keyword);
            term.segment = segment;
            term
        }
        TdmDeparture::EmptyDataSection { segment } => {
            let mut term = departure_base(atoms::empty_data_section(), message);
            term.segment = Some(segment);
            term
        }
        TdmDeparture::RecordsOutOfOrder {
            segment,
            keyword,
            epoch,
        } => {
            let mut term = departure_base(atoms::records_out_of_order(), message);
            term.segment = Some(segment);
            term.keyword = Some(keyword);
            term.epoch = Some(epoch);
            term
        }
        TdmDeparture::DuplicateRecord {
            segment,
            keyword,
            epoch,
        } => {
            let mut term = departure_base(atoms::duplicate_record(), message);
            term.segment = Some(segment);
            term.keyword = Some(keyword);
            term.epoch = Some(epoch);
            term
        }
        TdmDeparture::RepeatedKeyword { keyword, section } => {
            let mut term = departure_base(atoms::repeated_keyword(), message);
            term.keyword = Some(keyword);
            term.section = Some(section_term(env, section));
            term
        }
        TdmDeparture::KeywordOutOfOrder { keyword, section } => {
            let mut term = departure_base(atoms::keyword_out_of_order(), message);
            term.keyword = Some(keyword);
            term.section = Some(section_term(env, section));
            term
        }
        TdmDeparture::UnterminatedFinalLine => {
            departure_base(atoms::unterminated_final_line(), message)
        }
        _ => departure_base(atoms::unhandled(), message),
    }
}

fn departure_terms<'a>(env: Env<'a>, departures: Vec<TdmDeparture>) -> Vec<TdmDepartureTerm<'a>> {
    departures
        .into_iter()
        .map(|departure| departure_term(env, departure))
        .collect()
}

/// Parse a CCSDS TDM in KVN encoding under the strict reader policy.
///
/// Returns `{:ok, tdm}` or `{:error, {tag, fields}}`.
#[rustler::nif(schedule = "DirtyCpu")]
fn tdm_parse_kvn<'a>(env: Env<'a>, text: String) -> Term<'a> {
    match core_tdm::parse_kvn(&text) {
        Ok(parsed) => (atoms::ok(), tdm_term(parsed)).encode(env),
        Err(error) => (atoms::error(), error_term(env, error)).encode(env),
    }
}

/// Parse a CCSDS TDM in KVN encoding under a reader policy, keeping every
/// departure the policy forgave.
///
/// Returns `{:ok, tdm, warnings}` or `{:error, {tag, fields}}`.
#[rustler::nif(schedule = "DirtyCpu")]
fn tdm_parse_kvn_with_policy<'a>(
    env: Env<'a>,
    text: String,
    policy: TdmPolicyTerm,
) -> NifResult<Term<'a>> {
    let policy = read_policy(policy)?;
    Ok(match core_tdm::parse_kvn_with_policy(&text, policy) {
        Ok((parsed, warnings)) => {
            let warnings: Vec<TdmWarningTerm<'a>> = warnings
                .into_iter()
                .map(|warning| warning_term(env, warning))
                .collect();
            (atoms::ok(), tdm_term(parsed), warnings).encode(env)
        }
        Err(error) => (atoms::error(), error_term(env, error)).encode(env),
    })
}

/// Serialize a TDM as CCSDS TDM KVN text under the strict writer policy.
///
/// Returns `{:ok, text}` or `{:error, {tag, fields}}`.
#[rustler::nif(schedule = "DirtyCpu")]
fn tdm_encode_kvn<'a>(env: Env<'a>, fields: TdmTerm) -> Term<'a> {
    let value = match tdm(env, fields) {
        Ok(value) => value,
        Err(reason) => return (atoms::error(), reason).encode(env),
    };
    match core_tdm::encode_kvn(&value) {
        Ok(text) => (atoms::ok(), text).encode(env),
        Err(error) => (atoms::error(), error_term(env, error)).encode(env),
    }
}

/// Serialize a TDM under a writer policy, returning every departure it emitted.
///
/// Returns `{:ok, text, departures}` or `{:error, {tag, fields}}`.
#[rustler::nif(schedule = "DirtyCpu")]
fn tdm_encode_kvn_with_policy<'a>(
    env: Env<'a>,
    fields: TdmTerm,
    policy: TdmWritePolicyTerm,
) -> NifResult<Term<'a>> {
    let policy = write_policy(policy)?;
    let value = match tdm(env, fields) {
        Ok(value) => value,
        Err(reason) => return Ok((atoms::error(), reason).encode(env)),
    };
    Ok(match core_tdm::encode_kvn_with_policy(&value, policy) {
        Ok((text, departures)) => (atoms::ok(), text, departure_terms(env, departures)).encode(env),
        Err(error) => (atoms::error(), error_term(env, error)).encode(env),
    })
}

fn raw_parts(
    fields: Vec<TdmFieldTerm>,
    comments: Vec<TdmCommentTerm>,
) -> (Vec<TdmField>, Vec<TdmComment>) {
    (
        fields.into_iter().map(field).collect(),
        comments.into_iter().map(comment).collect(),
    )
}

/// Build a metadata block from ordered raw fields and positioned comments under
/// the strict writer policy, through [`TdmMetadata::from_raw`].
///
/// Returns `{:ok, metadata}` or `{:error, {tag, fields}}`.
#[rustler::nif(schedule = "DirtyCpu")]
fn tdm_metadata_from_raw<'a>(
    env: Env<'a>,
    fields: Vec<TdmFieldTerm>,
    comments: Vec<TdmCommentTerm>,
) -> Term<'a> {
    let (fields, comments) = raw_parts(fields, comments);
    match TdmMetadata::from_raw(fields, comments) {
        Ok(metadata) => (atoms::ok(), metadata_term(metadata)).encode(env),
        Err(error) => (atoms::error(), error_term(env, error)).encode(env),
    }
}

/// Build a metadata block under a writer policy, through
/// [`TdmMetadata::from_raw_with_policy`].
///
/// Returns `{:ok, metadata, departures}` or `{:error, {tag, fields}}`.
#[rustler::nif(schedule = "DirtyCpu")]
fn tdm_metadata_from_raw_with_policy<'a>(
    env: Env<'a>,
    fields: Vec<TdmFieldTerm>,
    comments: Vec<TdmCommentTerm>,
    policy: TdmWritePolicyTerm,
) -> NifResult<Term<'a>> {
    let policy = write_policy(policy)?;
    let (fields, comments) = raw_parts(fields, comments);
    Ok(
        match TdmMetadata::from_raw_with_policy(fields, comments, policy) {
            Ok((metadata, departures)) => (
                atoms::ok(),
                metadata_term(metadata),
                departure_terms(env, departures),
            )
                .encode(env),
            Err(error) => (atoms::error(), error_term(env, error)).encode(env),
        },
    )
}

/// Replace a metadata block's raw fields and comments under the strict writer
/// policy, through [`TdmMetadata::replace_raw`].
///
/// Returns `{:ok, metadata}` with every property derived from the new fields, or
/// `{:error, {tag, fields}}`, in which case nothing is replaced.
#[rustler::nif(schedule = "DirtyCpu")]
fn tdm_metadata_replace_raw<'a>(
    env: Env<'a>,
    current: TdmMetadataTerm,
    fields: Vec<TdmFieldTerm>,
    comments: Vec<TdmCommentTerm>,
) -> Term<'a> {
    let mut metadata = metadata_as_given(current);
    let (fields, comments) = raw_parts(fields, comments);
    match metadata.replace_raw(fields, comments) {
        Ok(()) => (atoms::ok(), metadata_term(metadata)).encode(env),
        Err(error) => (atoms::error(), error_term(env, error)).encode(env),
    }
}

/// Replace a metadata block's raw fields and comments under a writer policy,
/// through [`TdmMetadata::replace_raw_with_policy`].
///
/// Returns `{:ok, metadata, departures}` or `{:error, {tag, fields}}`, in which
/// case nothing is replaced.
#[rustler::nif(schedule = "DirtyCpu")]
fn tdm_metadata_replace_raw_with_policy<'a>(
    env: Env<'a>,
    current: TdmMetadataTerm,
    fields: Vec<TdmFieldTerm>,
    comments: Vec<TdmCommentTerm>,
    policy: TdmWritePolicyTerm,
) -> NifResult<Term<'a>> {
    let policy = write_policy(policy)?;
    let mut metadata = metadata_as_given(current);
    let (fields, comments) = raw_parts(fields, comments);
    Ok(
        match metadata.replace_raw_with_policy(fields, comments, policy) {
            Ok(departures) => (
                atoms::ok(),
                metadata_term(metadata),
                departure_terms(env, departures),
            )
                .encode(env),
            Err(error) => (atoms::error(), error_term(env, error)).encode(env),
        },
    )
}
