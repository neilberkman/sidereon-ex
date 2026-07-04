//! Rustler boundary for CCSDS Tracking Data Message KVN.
//!
//! This file mirrors the canonical core TDM structs as `NifMap` terms. Parsing,
//! validation, unit assignment, and KVN serialization remain in
//! `sidereon_core::astro::tdm`.

use rustler::{Encoder, Env, Term};
use sidereon_core::astro::tdm::{
    self as core_tdm, Tdm, TdmDataRecord, TdmDataSection, TdmError, TdmField, TdmInputErrorKind,
    TdmMetadata, TdmObservable, TdmParticipant, TdmPath, TdmScalar, TdmSegment, TdmUnit,
};

mod atoms {
    rustler::atoms! {
        ok,
        error,
        missing_version,
        no_segments,
        section,
        malformed_line,
        malformed_record,
        invalid_field
    }
}

#[derive(Debug, Clone, rustler::NifMap)]
struct TdmFieldTerm {
    key: String,
    value: String,
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
    comments: Vec<String>,
    records: Vec<TdmDataRecordTerm>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct TdmParticipantTerm {
    index: u8,
    name: String,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct TdmPathTerm {
    key: String,
    index: Option<u8>,
    participants: Vec<u8>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct TdmMetadataTerm {
    comments: Vec<String>,
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
    comments: Vec<String>,
    creation_date: Option<String>,
    originator: Option<String>,
    message_id: Option<String>,
    header_fields: Vec<TdmFieldTerm>,
    segments: Vec<TdmSegmentTerm>,
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

fn observable_term(value: TdmObservable) -> TdmObservableTerm {
    match value {
        TdmObservable::Range => TdmObservableTerm {
            kind: "range".to_string(),
            participant: None,
            name: None,
        },
        TdmObservable::DopplerInstantaneous => TdmObservableTerm {
            kind: "doppler_instantaneous".to_string(),
            participant: None,
            name: None,
        },
        TdmObservable::DopplerIntegrated => TdmObservableTerm {
            kind: "doppler_integrated".to_string(),
            participant: None,
            name: None,
        },
        TdmObservable::ReceiveFreq { participant } => TdmObservableTerm {
            kind: "receive_freq".to_string(),
            participant,
            name: None,
        },
        TdmObservable::TransmitFreq { participant } => TdmObservableTerm {
            kind: "transmit_freq".to_string(),
            participant,
            name: None,
        },
        TdmObservable::TransmitFreqRate { participant } => TdmObservableTerm {
            kind: "transmit_freq_rate".to_string(),
            participant,
            name: None,
        },
        TdmObservable::Angle1 => TdmObservableTerm {
            kind: "angle_1".to_string(),
            participant: None,
            name: None,
        },
        TdmObservable::Angle2 => TdmObservableTerm {
            kind: "angle_2".to_string(),
            participant: None,
            name: None,
        },
        TdmObservable::Other(name) => TdmObservableTerm {
            kind: "other".to_string(),
            participant: None,
            name: Some(name),
        },
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

fn scalar_term(value: TdmScalar) -> TdmScalarTerm {
    TdmScalarTerm {
        text: value.text,
        value: value.value,
    }
}

fn scalar(value: TdmScalarTerm) -> TdmScalar {
    TdmScalar {
        text: value.text,
        value: value.value,
    }
}

fn record_term(value: TdmDataRecord) -> TdmDataRecordTerm {
    TdmDataRecordTerm {
        observable: observable_term(value.observable),
        keyword: value.keyword,
        epoch: value.epoch,
        value: scalar_term(value.value),
        unit: unit_label(value.unit),
    }
}

fn record(value: TdmDataRecordTerm) -> TdmDataRecord {
    TdmDataRecord {
        observable: observable(value.observable),
        keyword: value.keyword,
        epoch: value.epoch,
        value: scalar(value.value),
        unit: unit(value.unit),
    }
}

fn data_section_term(value: TdmDataSection) -> TdmDataSectionTerm {
    TdmDataSectionTerm {
        comments: value.comments,
        records: value.records.into_iter().map(record_term).collect(),
    }
}

fn data_section(value: TdmDataSectionTerm) -> TdmDataSection {
    TdmDataSection {
        comments: value.comments,
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
        comments: value.comments,
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

fn metadata(value: TdmMetadataTerm) -> TdmMetadata {
    TdmMetadata {
        comments: value.comments,
        fields: value.fields.into_iter().map(field).collect(),
        participants: value.participants.into_iter().map(participant).collect(),
        mode: value.mode,
        paths: value.paths.into_iter().map(path).collect(),
        timetag_ref: value.timetag_ref,
        time_system: value.time_system,
        range_units: unit(value.range_units),
    }
}

fn segment_term(value: TdmSegment) -> TdmSegmentTerm {
    TdmSegmentTerm {
        metadata: metadata_term(value.metadata),
        data: data_section_term(value.data),
    }
}

fn segment(value: TdmSegmentTerm) -> TdmSegment {
    TdmSegment {
        metadata: metadata(value.metadata),
        data: data_section(value.data),
    }
}

fn tdm_term(value: Tdm) -> TdmTerm {
    TdmTerm {
        version: value.version,
        comments: value.comments,
        creation_date: value.creation_date,
        originator: value.originator,
        message_id: value.message_id,
        header_fields: value.header_fields.into_iter().map(field_term).collect(),
        segments: value.segments.into_iter().map(segment_term).collect(),
    }
}

fn tdm(value: TdmTerm) -> Tdm {
    Tdm {
        version: value.version,
        comments: value.comments,
        creation_date: value.creation_date,
        originator: value.originator,
        message_id: value.message_id,
        header_fields: value.header_fields.into_iter().map(field).collect(),
        segments: value.segments.into_iter().map(segment).collect(),
    }
}

fn error_atom(error: &TdmError) -> rustler::Atom {
    match error {
        TdmError::MissingVersion => atoms::missing_version(),
        TdmError::NoSegments => atoms::no_segments(),
        TdmError::Section { .. } => atoms::section(),
        TdmError::MalformedLine { .. } => atoms::malformed_line(),
        TdmError::MalformedRecord { .. } => atoms::malformed_record(),
        TdmError::InvalidField { .. } => atoms::invalid_field(),
    }
}

fn error_kind_label(kind: TdmInputErrorKind) -> &'static str {
    match kind {
        TdmInputErrorKind::Missing => "missing",
        TdmInputErrorKind::FloatParse => "float_parse",
        TdmInputErrorKind::NonFinite => "non_finite",
        TdmInputErrorKind::NotPositive => "not_positive",
        TdmInputErrorKind::OutOfRange => "out_of_range",
        TdmInputErrorKind::InvalidIndex => "invalid_index",
        TdmInputErrorKind::UnknownKeyword => "unknown_keyword",
        TdmInputErrorKind::UnexpectedUnit => "unexpected_unit",
        TdmInputErrorKind::NonInteger => "non_integer",
        TdmInputErrorKind::Negative => "negative",
        TdmInputErrorKind::NegativeZero => "negative_zero",
        TdmInputErrorKind::UnitMismatch => "unit_mismatch",
        TdmInputErrorKind::DecimalMismatch => "decimal_mismatch",
    }
}

fn error_detail(error: &TdmError) -> Option<(String, String)> {
    match error {
        TdmError::InvalidField { field, kind } => {
            Some((field.clone(), error_kind_label(*kind).to_string()))
        }
        TdmError::Section { line, detail } => Some((line.to_string(), detail.to_string())),
        TdmError::MalformedLine { line, text } => Some((line.to_string(), text.clone())),
        TdmError::MalformedRecord { line, keyword } => Some((line.to_string(), keyword.clone())),
        TdmError::MissingVersion | TdmError::NoSegments => None,
    }
}

fn parse_result<'a>(env: Env<'a>, result: Result<Tdm, TdmError>) -> Term<'a> {
    match result {
        Ok(parsed) => (atoms::ok(), tdm_term(parsed)).encode(env),
        Err(error) => {
            let detail = error_detail(&error);
            (atoms::error(), error_atom(&error), detail).encode(env)
        }
    }
}

/// Parse a CCSDS TDM in KVN encoding.
#[rustler::nif(schedule = "DirtyCpu")]
fn tdm_parse_kvn<'a>(env: Env<'a>, text: String) -> Term<'a> {
    parse_result(env, core_tdm::parse_kvn(&text))
}

/// Serialize normalized TDM fields as CCSDS TDM KVN text.
#[rustler::nif(schedule = "DirtyCpu")]
fn tdm_encode_kvn<'a>(env: Env<'a>, fields: TdmTerm) -> Term<'a> {
    match core_tdm::encode_kvn(&tdm(fields)) {
        Ok(text) => (atoms::ok(), text).encode(env),
        Err(error) => {
            let detail = error_detail(&error);
            (atoms::error(), error_atom(&error), detail).encode(env)
        }
    }
}
