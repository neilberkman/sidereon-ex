//! Rustler boundary for RINEX clock products.
//!
//! This module is glue only: it decodes Erlang terms, calls the
//! `sidereon-core` RINEX clock reader, editor, writer and interpolator, and
//! encodes what the core exposes. A product crosses as a resource handle over
//! the core `RinexClock`, which keeps the text it read as its authority, so a
//! parsed product is written back byte for byte. Edits never change a handle:
//! each edit clones the product, applies the core edit to the clone, and
//! returns a new handle.

use rustler::{Atom, Encoder, Env, NifMap, NifResult, OwnedBinary, ResourceArc, Term};
use sidereon_core::astro::time::model::TimeScale;
use sidereon_core::rinex::clock::{
    civil_to_clock_instant, civil_to_gps_seconds, ClockEpoch, ClockHeaderField, ClockHeaderReading,
    ClockHeaderRecord, ClockLayout, ClockPoint, ClockRecord, ClockRecordReading, ClockRecordType,
    ClockTimeSystem, ClockTimeSystemStatus, ClockWriteDeparture, ClockWriteLeniency,
    ClockWritePolicy, RinexClock, RinexClockDiagnostic, RinexClockError, RinexClockNotice,
    RinexClockSkip,
};

use crate::iono::EpochTerm;
use crate::spp::atom_from;

/// A parsed or built RINEX clock product held across calls.
pub struct RinexClockResource {
    pub clock: RinexClock,
}

#[rustler::resource_impl]
impl rustler::Resource for RinexClockResource {}

mod atoms {
    rustler::atoms! {
        ok,
        error,
        no_clock,
        malformed_as_record,
        missing_continuation,
        malformed_continuation,
        bad_field,
        invalid_input,
        unsupported_time_scale,
        epoch_at_nearest_microsecond,
        columns,
        whitespace,
        edited,
        v300,
        v304,
        declared,
        defaulted,
        unrecognized,
        conflicting,
        constructed,
        other,
        strict,
        allow
    }
}

type SeriesRows = Vec<(String, Vec<(f64, f64)>)>;

/// A civil clock epoch in the product's time scale; `second` carries the
/// fraction and, on a UTC product, may be `60.x` on a leap-second day.
#[derive(NifMap)]
struct CivilEpochTerm {
    year: i32,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: f64,
}

#[derive(NifMap)]
struct ClockPointTerm {
    epoch: EpochTerm,
    bias_s: f64,
    additional_values: Vec<f64>,
}

#[derive(NifMap)]
struct SurplusTerm {
    position: usize,
    value: f64,
}

#[derive(NifMap)]
struct RecordTerm<'a> {
    record_type: Term<'a>,
    name: String,
    satellite: Option<String>,
    civil_epoch: CivilEpochTerm,
    epoch: Option<EpochTerm>,
    values: Vec<f64>,
    surplus_values: Vec<SurplusTerm>,
    line: Option<usize>,
    line_count: usize,
    reading: Term<'a>,
    continuation_reading: Option<Term<'a>>,
    /// The suffix bytes as an Erlang binary, as the public record declares.
    trailing_text_bytes: Option<Term<'a>>,
    trailing_text_column: Option<usize>,
}

/// A record to insert: its type, name, civil epoch and declared values, bias
/// first.
#[derive(NifMap)]
struct NewRecordTerm {
    record_type: Atom,
    name: String,
    epoch: CivilEpochTerm,
    values: Vec<f64>,
}

#[derive(NifMap)]
struct HeaderRecordTerm<'a> {
    line: Option<usize>,
    text: String,
    label: String,
    label_column: usize,
    payload: String,
    field: Option<Term<'a>>,
    reading: Term<'a>,
}

#[derive(NifMap)]
struct InfoTerm<'a> {
    version: Option<f64>,
    layout: Option<Atom>,
    satellite_system: Option<String>,
    time_system: Option<Term<'a>>,
    time_system_status: Term<'a>,
    time_scale: Option<String>,
    record_count: usize,
}

#[derive(NifMap)]
struct DiagnosticTerm<'a> {
    line: usize,
    error: Term<'a>,
}

#[derive(NifMap)]
struct LineReasonRecordTerm {
    line: usize,
    reason: String,
    record: String,
}

#[derive(NifMap)]
struct MissingContinuationTerm {
    line: usize,
    record_type: String,
}

#[derive(NifMap)]
struct BadFieldTerm {
    line: usize,
    field: String,
    value: String,
}

#[derive(NifMap)]
struct FieldReasonTerm {
    field: String,
    reason: String,
}

#[derive(NifMap)]
struct ScaleTerm {
    scale: String,
}

#[derive(NifMap)]
struct DepartureTerm {
    record: usize,
    name: String,
    epoch: Option<EpochTerm>,
    written: String,
}

/// Parse RINEX clock text strictly: `{:ok, handle, series_rows}` or
/// `{:error, reason}` for the first line that does not read.
#[rustler::nif(schedule = "DirtyCpu")]
fn rinex_clock_parse<'a>(env: Env<'a>, text: String) -> Term<'a> {
    product_result(env, RinexClock::parse(&text))
}

/// Parse RINEX clock text keeping every line that does not read verbatim with a
/// diagnostic: `{:ok, handle, series_rows}`.
#[rustler::nif(schedule = "DirtyCpu")]
fn rinex_clock_parse_lossy<'a>(env: Env<'a>, text: String) -> Term<'a> {
    product_result(env, Ok(RinexClock::parse_lossy(&text)))
}

/// Build a GPST product from `[{satellite, [{gps_seconds, bias_s}]}]` rows.
#[rustler::nif(schedule = "DirtyCpu")]
fn rinex_clock_from_series_rows<'a>(env: Env<'a>, series: SeriesRows) -> Term<'a> {
    product_result(env, RinexClock::from_series_rows(series))
}

/// Build a product in `time_scale` from per-satellite clock points, keeping
/// every declared value of each point.
#[rustler::nif(schedule = "DirtyCpu")]
fn rinex_clock_from_clock_points<'a>(
    env: Env<'a>,
    time_scale: String,
    rows: Vec<(String, Vec<ClockPointTerm>)>,
) -> NifResult<Term<'a>> {
    let scale = crate::sp3::time_scale_from_abbrev(&time_scale)?;
    let rows = rows
        .into_iter()
        .map(|(satellite, points)| {
            let points = points
                .into_iter()
                .map(|point| ClockPoint::new(point.epoch.0, point.bias_s, point.additional_values))
                .collect();
            (satellite, points)
        })
        .collect();
    Ok(product_result(
        env,
        RinexClock::from_clock_points(scale, rows),
    ))
}

/// The product's header facts: version, layout, satellite system, time system,
/// how the time system was established, time scale (`nil` when the system does
/// not resolve to one) and record count.
#[rustler::nif]
fn rinex_clock_info<'a>(env: Env<'a>, handle: ResourceArc<RinexClockResource>) -> Term<'a> {
    let clock = &handle.clock;
    InfoTerm {
        version: clock.version(),
        layout: clock.layout().map(layout_atom),
        satellite_system: clock.satellite_system().map(String::from),
        time_system: clock
            .time_system()
            .map(|system| time_system_term(env, system)),
        time_system_status: time_system_status_term(env, clock.time_system_status()),
        time_scale: clock.time_scale().map(|scale| scale.abbrev().to_string()),
        record_count: clock.record_count(),
    }
    .encode(env)
}

/// Every data record in order, with how it was read.
#[rustler::nif(schedule = "DirtyCpu")]
fn rinex_clock_records<'a>(env: Env<'a>, handle: ResourceArc<RinexClockResource>) -> Term<'a> {
    handle
        .clock
        .records()
        .map(|record| record_term(env, &handle.clock, &record))
        .collect::<Vec<_>>()
        .encode(env)
}

/// Every header line in order with its typed reading.
#[rustler::nif]
fn rinex_clock_header_records<'a>(
    env: Env<'a>,
    handle: ResourceArc<RinexClockResource>,
) -> Term<'a> {
    handle
        .clock
        .header_records()
        .iter()
        .map(|record| header_record_term(env, record))
        .collect::<Vec<_>>()
        .encode(env)
}

/// The per-satellite series of `AS` records whose epoch resolves to an
/// instant, as `[{satellite, [point]}]` with scale-tagged epochs.
#[rustler::nif(schedule = "DirtyCpu")]
fn rinex_clock_series<'a>(env: Env<'a>, handle: ResourceArc<RinexClockResource>) -> Term<'a> {
    handle
        .clock
        .series()
        .iter()
        .map(|(satellite, points)| {
            let points: Vec<ClockPointTerm> = points
                .iter()
                .map(|point| ClockPointTerm {
                    epoch: EpochTerm(point.epoch),
                    bias_s: point.bias_s,
                    additional_values: point.additional_values.clone(),
                })
                .collect();
            (satellite.as_str(), points)
        })
        .collect::<Vec<_>>()
        .encode(env)
}

/// Records read from the source that are not in the satellite series.
#[rustler::nif]
fn rinex_clock_skipped_records(handle: ResourceArc<RinexClockResource>) -> Vec<SkipTerm> {
    handle
        .clock
        .skipped_records()
        .iter()
        .map(skip_term)
        .collect()
}

/// Lines a lossy read kept without reading them, and header time-system errors.
#[rustler::nif]
fn rinex_clock_diagnostics<'a>(env: Env<'a>, handle: ResourceArc<RinexClockResource>) -> Term<'a> {
    handle
        .clock
        .diagnostics()
        .iter()
        .map(|diagnostic| diagnostic_term(env, diagnostic))
        .collect::<Vec<_>>()
        .encode(env)
}

/// Findings about how the product was read that do not stop it being read.
#[rustler::nif]
fn rinex_clock_notices<'a>(env: Env<'a>, handle: ResourceArc<RinexClockResource>) -> Term<'a> {
    handle
        .clock
        .notices()
        .iter()
        .map(|notice| notice_term(env, notice))
        .collect::<Vec<_>>()
        .encode(env)
}

/// One line of the source text by one-based line number, or `nil`.
#[rustler::nif]
fn rinex_clock_source_line(handle: ResourceArc<RinexClockResource>, line: usize) -> Option<String> {
    handle.clock.source_line(line).map(String::from)
}

/// Interpolate one satellite clock bias at a civil epoch in the product's
/// scale: `{:ok, bias_s}`, `{:error, :no_clock}`, or `{:error, reason}`.
#[rustler::nif]
fn rinex_clock_clock_s<'a>(
    env: Env<'a>,
    handle: ResourceArc<RinexClockResource>,
    satellite_id: String,
    epoch: CivilEpochTerm,
) -> Term<'a> {
    bias_result(
        env,
        handle.clock.clock_s(&satellite_id, clock_epoch(&epoch)),
    )
}

/// Interpolate one satellite clock bias at a scale-tagged instant.
#[rustler::nif]
fn rinex_clock_clock_s_at_instant<'a>(
    env: Env<'a>,
    handle: ResourceArc<RinexClockResource>,
    satellite_id: String,
    epoch: EpochTerm,
) -> Term<'a> {
    bias_result(env, handle.clock.clock_s_at_instant(&satellite_id, epoch.0))
}

/// Interpolate one satellite clock bias at GPS seconds.
#[rustler::nif]
fn rinex_clock_clock_s_at_gps_seconds<'a>(
    env: Env<'a>,
    handle: ResourceArc<RinexClockResource>,
    satellite_id: String,
    gps_seconds: f64,
) -> Term<'a> {
    bias_result(
        env,
        handle
            .clock
            .clock_s_at_gps_seconds(&satellite_id, gps_seconds),
    )
}

/// A civil clock tag in `time_scale` as a scale-tagged instant, reading the
/// second as the shortest decimal of the double given: `{:ok, epoch}` or
/// `{:error, :invalid_epoch}`.
#[rustler::nif]
fn rinex_clock_civil_to_instant<'a>(
    env: Env<'a>,
    time_scale: String,
    epoch: CivilEpochTerm,
) -> NifResult<Term<'a>> {
    let scale = crate::sp3::time_scale_from_abbrev(&time_scale)?;
    Ok(
        match civil_to_clock_instant(
            scale,
            epoch.year,
            epoch.month,
            epoch.day,
            epoch.hour,
            epoch.minute,
            epoch.second,
        ) {
            Some(instant) => (atoms::ok(), EpochTerm(instant)).encode(env),
            None => (atoms::error(), atom_from(env, "invalid_epoch")).encode(env),
        },
    )
}

/// A civil GPS-time tag as GPS seconds, reading the second as
/// [`rinex_clock_civil_to_instant`] does.
#[rustler::nif]
fn rinex_clock_civil_to_gps_seconds<'a>(env: Env<'a>, epoch: CivilEpochTerm) -> Term<'a> {
    match civil_to_gps_seconds(
        epoch.year,
        epoch.month,
        epoch.day,
        epoch.hour,
        epoch.minute,
        epoch.second,
    ) {
        Some(seconds) => (atoms::ok(), seconds).encode(env),
        None => (atoms::error(), atom_from(env, "invalid_epoch")).encode(env),
    }
}

/// Write the product as RINEX clock text, refusing what it cannot state
/// exactly.
#[rustler::nif(schedule = "DirtyCpu")]
fn rinex_clock_to_string<'a>(env: Env<'a>, handle: ResourceArc<RinexClockResource>) -> Term<'a> {
    match handle.clock.to_rinex_string() {
        Ok(text) => (atoms::ok(), text).encode(env),
        Err(err) => (atoms::error(), clock_error_term(env, &err)).encode(env),
    }
}

/// Write the product under a policy: `{:ok, text, departures}` with every
/// departure the policy allowed and the writer emitted, or `{:error, reason}`.
/// `nearest_microsecond_epochs` is `:strict` or `:allow`.
#[rustler::nif(schedule = "DirtyCpu")]
fn rinex_clock_to_string_with_policy<'a>(
    env: Env<'a>,
    handle: ResourceArc<RinexClockResource>,
    nearest_microsecond_epochs: Atom,
) -> NifResult<Term<'a>> {
    let leniency = if nearest_microsecond_epochs == atoms::allow() {
        ClockWriteLeniency::Allow
    } else if nearest_microsecond_epochs == atoms::strict() {
        ClockWriteLeniency::Strict
    } else {
        return Err(rustler::Error::Term(Box::new((
            atoms::invalid_input(),
            "nearest_microsecond_epochs",
        ))));
    };
    let policy = ClockWritePolicy::strict().with_nearest_microsecond_epochs(leniency);
    Ok(match handle.clock.to_rinex_string_with_policy(policy) {
        Ok((text, departures)) => {
            let departures: Vec<Term<'a>> = departures
                .iter()
                .map(|departure| departure_term(env, departure))
                .collect();
            (atoms::ok(), text, departures).encode(env)
        }
        Err(err) => (atoms::error(), clock_error_term(env, &err)).encode(env),
    })
}

/// Declare the product's time system on a copy: `{:ok, handle, series_rows}`
/// or `{:error, reason}` with the product unchanged.
#[rustler::nif(schedule = "DirtyCpu")]
fn rinex_clock_set_time_system<'a>(
    env: Env<'a>,
    handle: ResourceArc<RinexClockResource>,
    system: Atom,
) -> NifResult<Term<'a>> {
    let system = decode_time_system(env, system)?;
    let mut clock = handle.clock.clone();
    Ok(match clock.set_time_system(system) {
        Ok(()) => edited(env, clock, None),
        Err(err) => (atoms::error(), clock_error_term(env, &err)).encode(env),
    })
}

/// Replace the declared values of the record at `index` on a copy.
#[rustler::nif(schedule = "DirtyCpu")]
fn rinex_clock_set_record_values<'a>(
    env: Env<'a>,
    handle: ResourceArc<RinexClockResource>,
    index: usize,
    values: Vec<f64>,
) -> Term<'a> {
    let mut clock = handle.clock.clone();
    match clock.set_record_values(index, values) {
        Ok(()) => edited(env, clock, None),
        Err(err) => (atoms::error(), clock_error_term(env, &err)).encode(env),
    }
}

/// Insert a record before the record at `index` (or after the last when
/// `index` is the record count) on a copy.
#[rustler::nif(schedule = "DirtyCpu")]
fn rinex_clock_insert_record<'a>(
    env: Env<'a>,
    handle: ResourceArc<RinexClockResource>,
    index: usize,
    record: NewRecordTerm,
) -> NifResult<Term<'a>> {
    let record_type = decode_record_type(env, record.record_type)?;
    let record = match ClockRecord::new(
        record_type,
        &record.name,
        clock_epoch(&record.epoch),
        record.values,
    ) {
        Ok(record) => record,
        Err(err) => return Ok((atoms::error(), clock_error_term(env, &err)).encode(env)),
    };
    let mut clock = handle.clock.clone();
    Ok(match clock.insert_record(index, record) {
        Ok(()) => edited(env, clock, None),
        Err(err) => (atoms::error(), clock_error_term(env, &err)).encode(env),
    })
}

/// Remove the record at `index` on a copy: `{:ok, handle, series_rows,
/// removed_record}`.
#[rustler::nif(schedule = "DirtyCpu")]
fn rinex_clock_remove_record<'a>(
    env: Env<'a>,
    handle: ResourceArc<RinexClockResource>,
    index: usize,
) -> Term<'a> {
    let mut clock = handle.clock.clone();
    match clock.remove_record(index) {
        Ok(record) => {
            let removed = record_term(env, &clock, &record).encode(env);
            edited(env, clock, Some(removed))
        }
        Err(err) => (atoms::error(), clock_error_term(env, &err)).encode(env),
    }
}

/// Keep the records whose flag is `true`, in records order, on a copy:
/// `{:ok, handle, series_rows, removed_count}`. A list whose length is not the
/// record count is refused, since the flags could not be matched to records.
#[rustler::nif(schedule = "DirtyCpu")]
fn rinex_clock_retain_records<'a>(
    env: Env<'a>,
    handle: ResourceArc<RinexClockResource>,
    keep: Vec<bool>,
) -> Term<'a> {
    if keep.len() != handle.clock.record_count() {
        return (
            atoms::error(),
            invalid_input_term(env, "keep", "one flag for each record"),
        )
            .encode(env);
    }
    let mut clock = handle.clock.clone();
    let mut flags = keep.into_iter();
    let removed = clock.retain_records(|_| flags.next().unwrap_or(true));
    edited(env, clock, Some(removed.encode(env)))
}

/// Replace the declared values of every record whose entry is a list, in
/// records order, on a copy: `{:ok, handle, series_rows, edited_count}` or
/// `{:error, reason}` with nothing applied.
#[rustler::nif(schedule = "DirtyCpu")]
fn rinex_clock_edit_records<'a>(
    env: Env<'a>,
    handle: ResourceArc<RinexClockResource>,
    edits: Vec<Option<Vec<f64>>>,
) -> Term<'a> {
    if edits.len() != handle.clock.record_count() {
        return (
            atoms::error(),
            invalid_input_term(env, "edits", "one entry for each record"),
        )
            .encode(env);
    }
    let mut clock = handle.clock.clone();
    let mut entries = edits.into_iter();
    match clock.edit_records(|_| entries.next().flatten()) {
        Ok(count) => edited(env, clock, Some(count.encode(env))),
        Err(err) => (atoms::error(), clock_error_term(env, &err)).encode(env),
    }
}

fn product_result<'a>(env: Env<'a>, result: Result<RinexClock, RinexClockError>) -> Term<'a> {
    match result {
        Ok(clock) => {
            let rows = clock.series_rows();
            (
                atoms::ok(),
                ResourceArc::new(RinexClockResource { clock }),
                rows,
            )
                .encode(env)
        }
        Err(err) => (atoms::error(), clock_error_term(env, &err)).encode(env),
    }
}

fn edited<'a>(env: Env<'a>, clock: RinexClock, extra: Option<Term<'a>>) -> Term<'a> {
    let rows = clock.series_rows();
    let handle = ResourceArc::new(RinexClockResource { clock });
    match extra {
        Some(extra) => (atoms::ok(), handle, rows, extra).encode(env),
        None => (atoms::ok(), handle, rows).encode(env),
    }
}

fn bias_result<'a>(env: Env<'a>, result: Result<Option<f64>, RinexClockError>) -> Term<'a> {
    match result {
        Ok(Some(bias_s)) => (atoms::ok(), bias_s).encode(env),
        Ok(None) => (atoms::error(), atoms::no_clock()).encode(env),
        Err(err) => (atoms::error(), clock_error_term(env, &err)).encode(env),
    }
}

fn clock_epoch(epoch: &CivilEpochTerm) -> ClockEpoch {
    ClockEpoch {
        year: epoch.year,
        month: epoch.month,
        day: epoch.day,
        hour: epoch.hour,
        minute: epoch.minute,
        second: epoch.second,
    }
}

fn civil_epoch_term(epoch: ClockEpoch) -> CivilEpochTerm {
    CivilEpochTerm {
        year: epoch.year,
        month: epoch.month,
        day: epoch.day,
        hour: epoch.hour,
        minute: epoch.minute,
        second: epoch.second,
    }
}

fn record_term<'a>(env: Env<'a>, clock: &RinexClock, record: &ClockRecord) -> RecordTerm<'a> {
    let suffix = match record.reading() {
        ClockRecordReading::ColumnsTrailingText(layout) => record
            .line()
            .and_then(|line| clock.source_line(line))
            .and_then(|source_line| {
                let column = match layout {
                    ClockLayout::V300 => 80,
                    ClockLayout::V304 => 85,
                };
                source_line
                    .as_bytes()
                    .get(column..)
                    .filter(|bytes| bytes.iter().any(|byte| !byte.is_ascii_whitespace()))
                    .map(|bytes| (bytes.to_vec(), column))
            }),
        _ => None,
    };
    RecordTerm {
        record_type: record_type_term(env, record.record_type()),
        name: record.name().to_string(),
        satellite: record.satellite().map(String::from),
        civil_epoch: civil_epoch_term(record.civil_epoch()),
        epoch: record.epoch().map(EpochTerm),
        values: record.values().to_vec(),
        surplus_values: record
            .surplus_values()
            .iter()
            .map(|surplus| SurplusTerm {
                position: surplus.position,
                value: surplus.value,
            })
            .collect(),
        line: record.line(),
        line_count: record.line_count(),
        reading: record_reading_term(env, record.reading()),
        continuation_reading: record
            .continuation_reading()
            .map(|reading| record_reading_term(env, reading)),
        trailing_text_bytes: suffix
            .as_ref()
            .map(|(bytes, _)| bytes_to_binary(env, bytes)),
        trailing_text_column: suffix.map(|(_, column)| column),
    }
}

fn bytes_to_binary<'a>(env: Env<'a>, bytes: &[u8]) -> Term<'a> {
    let mut binary = OwnedBinary::new(bytes.len()).expect("allocate clock suffix binary");
    binary.as_mut_slice().copy_from_slice(bytes);
    binary.release(env).encode(env)
}

fn record_type_term(env: Env<'_>, record_type: ClockRecordType) -> Term<'_> {
    atom_from(env, &record_type.code().to_ascii_lowercase())
}

fn decode_record_type(env: Env<'_>, atom: Atom) -> NifResult<ClockRecordType> {
    let code = atom
        .to_term(env)
        .atom_to_string()
        .map(|name| name.to_ascii_uppercase())
        .unwrap_or_default();
    ClockRecordType::from_code(&code)
        .ok_or_else(|| rustler::Error::Term(Box::new((atoms::invalid_input(), "record_type"))))
}

/// `{:columns, :v300 | :v304}`, `:whitespace` or `:edited`.
fn record_reading_term(env: Env<'_>, reading: ClockRecordReading) -> Term<'_> {
    match reading {
        ClockRecordReading::Columns(layout) => (atoms::columns(), layout_atom(layout)).encode(env),
        ClockRecordReading::ColumnsTrailingText(layout) => {
            (atom_from(env, "columns_trailing_text"), layout_atom(layout)).encode(env)
        }
        ClockRecordReading::Whitespace => atoms::whitespace().encode(env),
        ClockRecordReading::Edited => atoms::edited().encode(env),
        other => (atoms::other(), format!("{other:?}")).encode(env),
    }
}

fn layout_atom(layout: ClockLayout) -> Atom {
    match layout {
        ClockLayout::V300 => atoms::v300(),
        ClockLayout::V304 => atoms::v304(),
    }
}

/// A time system as the lower-case atom of its label: `:gps`, `:glo`, `:gal`,
/// `:qzs`, `:bds`, `:irn`, `:utc` or `:tai`.
fn time_system_term(env: Env<'_>, system: ClockTimeSystem) -> Term<'_> {
    atom_from(env, &system.label().to_ascii_lowercase())
}

fn decode_time_system(env: Env<'_>, atom: Atom) -> NifResult<ClockTimeSystem> {
    let label = atom
        .to_term(env)
        .atom_to_string()
        .map(|name| name.to_ascii_uppercase())
        .unwrap_or_default();
    ClockTimeSystem::from_label(&label)
        .ok_or_else(|| rustler::Error::Term(Box::new((atoms::invalid_input(), "time_system"))))
}

fn time_system_status_term<'a>(env: Env<'a>, status: &ClockTimeSystemStatus) -> Term<'a> {
    match status {
        ClockTimeSystemStatus::Declared => atoms::declared().encode(env),
        ClockTimeSystemStatus::Defaulted => atoms::defaulted().encode(env),
        ClockTimeSystemStatus::Unrecognized { label } => {
            (atoms::unrecognized(), label.as_str()).encode(env)
        }
        ClockTimeSystemStatus::Conflicting { labels } => {
            (atoms::conflicting(), labels.clone()).encode(env)
        }
        ClockTimeSystemStatus::Constructed => atoms::constructed().encode(env),
        other => (atoms::other(), format!("{other:?}")).encode(env),
    }
}

fn header_record_term<'a>(env: Env<'a>, record: &ClockHeaderRecord) -> HeaderRecordTerm<'a> {
    HeaderRecordTerm {
        line: record.line(),
        text: record.text().to_string(),
        label: record.label().to_string(),
        label_column: record.label_column(),
        payload: record.payload().to_string(),
        field: record.field().map(|field| header_field_term(env, field)),
        reading: header_reading_term(env, record.reading()),
    }
}

fn header_reading_term(env: Env<'_>, reading: ClockHeaderReading) -> Term<'_> {
    let name = match reading {
        ClockHeaderReading::Columns => "columns",
        ClockHeaderReading::OtherVersionColumns => "other_version_columns",
        ClockHeaderReading::Whitespace => "whitespace",
        ClockHeaderReading::Uninterpreted => "uninterpreted",
        ClockHeaderReading::UnknownLabel => "unknown_label",
        _ => "other",
    };
    atom_from(env, name)
}

/// A typed header field as `{tag, value}`: a map of the variant's fields, the
/// value itself for a single-valued variant, or the bare tag for
/// `END OF HEADER`.
fn header_field_term<'a>(env: Env<'a>, field: &ClockHeaderField) -> Term<'a> {
    let tag = |name: &str| atom_from(env, name);
    let map = |pairs: &[(&str, Term<'a>)]| keyed_map(env, pairs);
    match field {
        ClockHeaderField::VersionType {
            version,
            file_type,
            satellite_system,
        } => (
            tag("version_type"),
            map(&[
                ("version", version.encode(env)),
                ("file_type", file_type.encode(env)),
                ("satellite_system", satellite_system.encode(env)),
            ]),
        )
            .encode(env),
        ClockHeaderField::ProgramRunByDate {
            program,
            run_by,
            date,
        } => (
            tag("program_run_by_date"),
            map(&[
                ("program", program.encode(env)),
                ("run_by", run_by.encode(env)),
                ("date", date.encode(env)),
            ]),
        )
            .encode(env),
        ClockHeaderField::Comment(text) => (tag("comment"), text.as_str()).encode(env),
        ClockHeaderField::ObservationTypes {
            system,
            count,
            descriptors,
        } => (
            tag("observation_types"),
            map(&[
                ("system", system.map(String::from).encode(env)),
                ("count", count.encode(env)),
                ("descriptors", descriptors.encode(env)),
            ]),
        )
            .encode(env),
        ClockHeaderField::TimeSystem { label } => {
            (tag("time_system"), map(&[("label", label.encode(env))])).encode(env)
        }
        ClockHeaderField::LeapSeconds(count) => (tag("leap_seconds"), *count).encode(env),
        ClockHeaderField::LeapSecondsGnss(count) => (tag("leap_seconds_gnss"), *count).encode(env),
        ClockHeaderField::DcbsApplied {
            system,
            program,
            source,
        } => (
            tag("dcbs_applied"),
            map(&[
                ("system", system.encode(env)),
                ("program", program.encode(env)),
                ("source", source.encode(env)),
            ]),
        )
            .encode(env),
        ClockHeaderField::PcvsApplied {
            system,
            program,
            source,
        } => (
            tag("pcvs_applied"),
            map(&[
                ("system", system.encode(env)),
                ("program", program.encode(env)),
                ("source", source.encode(env)),
            ]),
        )
            .encode(env),
        ClockHeaderField::TypesOfData { count, types } => (
            tag("types_of_data"),
            map(&[("count", count.encode(env)), ("types", types.encode(env))]),
        )
            .encode(env),
        ClockHeaderField::StationNameNum { name, identifier } => (
            tag("station_name_num"),
            map(&[
                ("name", name.encode(env)),
                ("identifier", identifier.encode(env)),
            ]),
        )
            .encode(env),
        ClockHeaderField::StationClockRef(text) => {
            (tag("station_clock_ref"), text.as_str()).encode(env)
        }
        ClockHeaderField::AnalysisCenter { designator, name } => (
            tag("analysis_center"),
            map(&[
                ("designator", designator.encode(env)),
                ("name", name.encode(env)),
            ]),
        )
            .encode(env),
        ClockHeaderField::ClockRefCount { count, start, stop } => (
            tag("clock_ref_count"),
            map(&[
                ("count", count.encode(env)),
                ("start", start.map(civil_epoch_term).encode(env)),
                ("stop", stop.map(civil_epoch_term).encode(env)),
            ]),
        )
            .encode(env),
        ClockHeaderField::AnalysisClockRef {
            name,
            identifier,
            constraint_s,
        } => (
            tag("analysis_clock_ref"),
            map(&[
                ("name", name.encode(env)),
                ("identifier", identifier.encode(env)),
                ("constraint_s", constraint_s.encode(env)),
            ]),
        )
            .encode(env),
        ClockHeaderField::SolutionStationCount { count, frame } => (
            tag("solution_station_count"),
            map(&[("count", count.encode(env)), ("frame", frame.encode(env))]),
        )
            .encode(env),
        ClockHeaderField::SolutionStation {
            name,
            identifier,
            xyz_mm,
        } => (
            tag("solution_station"),
            map(&[
                ("name", name.encode(env)),
                ("identifier", identifier.encode(env)),
                ("xyz_mm", (xyz_mm[0], xyz_mm[1], xyz_mm[2]).encode(env)),
            ]),
        )
            .encode(env),
        ClockHeaderField::SolutionSatelliteCount(count) => {
            (tag("solution_satellite_count"), *count).encode(env)
        }
        ClockHeaderField::PrnList(satellites) => (tag("prn_list"), satellites.clone()).encode(env),
        ClockHeaderField::EndOfHeader => tag("end_of_header"),
        other => (tag("other"), format!("{other:?}")).encode(env),
    }
}

/// A map from atom keys; a key that names no atom is kept as a string key.
fn keyed_map<'a>(env: Env<'a>, pairs: &[(&str, Term<'a>)]) -> Term<'a> {
    pairs.iter().fold(Term::map_new(env), |map, (key, value)| {
        map.map_put(atom_from(env, key), *value).unwrap_or(map)
    })
}

fn skip_term(skip: &RinexClockSkip) -> SkipTerm {
    SkipTerm {
        line: skip.line,
        record_type: skip.record_type.clone(),
    }
}

/// A record read from the source that is not in the satellite series.
#[derive(NifMap)]
struct SkipTerm {
    line: usize,
    record_type: String,
}

fn diagnostic_term<'a>(env: Env<'a>, diagnostic: &RinexClockDiagnostic) -> Term<'a> {
    DiagnosticTerm {
        line: diagnostic.line,
        error: clock_error_term(env, &diagnostic.error),
    }
    .encode(env)
}

/// A notice as `{tag, fields}`, or the bare tag for a notice with none.
fn notice_term<'a>(env: Env<'a>, notice: &RinexClockNotice) -> Term<'a> {
    let tag = |name: &str| atom_from(env, name);
    let map = |pairs: &[(&str, Term<'a>)]| keyed_map(env, pairs);
    match notice {
        RinexClockNotice::TimeSystemDefaulted { system } => (
            tag("time_system_defaulted"),
            map(&[("system", time_system_term(env, *system))]),
        )
            .encode(env),
        RinexClockNotice::TimeSystemMissing => tag("time_system_missing"),
        RinexClockNotice::TimeSystemWithoutScale { system } => (
            tag("time_system_without_scale"),
            map(&[("system", time_system_term(env, *system))]),
        )
            .encode(env),
        RinexClockNotice::HeaderRecordNonconforming { line } => (
            tag("header_record_nonconforming"),
            map(&[("line", line.encode(env))]),
        )
            .encode(env),
        RinexClockNotice::HeaderRecordUninterpreted { line } => (
            tag("header_record_uninterpreted"),
            map(&[("line", line.encode(env))]),
        )
            .encode(env),
        RinexClockNotice::HeaderRecordUnknownLabel { line } => (
            tag("header_record_unknown_label"),
            map(&[("line", line.encode(env))]),
        )
            .encode(env),
        RinexClockNotice::SurplusValues {
            records,
            first_line,
        } => (
            tag("surplus_values"),
            map(&[
                ("records", records.encode(env)),
                ("first_line", first_line.encode(env)),
            ]),
        )
            .encode(env),
        RinexClockNotice::OtherLayoutRecords {
            records,
            first_line,
        } => (
            tag("other_layout_records"),
            map(&[
                ("records", records.encode(env)),
                ("first_line", first_line.encode(env)),
            ]),
        )
            .encode(env),
        RinexClockNotice::WhitespaceRecords {
            records,
            first_line,
        } => (
            tag("whitespace_records"),
            map(&[
                ("records", records.encode(env)),
                ("first_line", first_line.encode(env)),
            ]),
        )
            .encode(env),
        RinexClockNotice::TrailingTextRecords {
            records,
            first_line,
        } => (
            tag("trailing_text_records"),
            map(&[
                ("records", records.encode(env)),
                ("first_line", first_line.encode(env)),
            ]),
        )
            .encode(env),
        other => (tag("other"), other.to_string()).encode(env),
    }
}

/// A RINEX clock error as `{tag, fields}` with every field its variant
/// carries. [`RinexClockError`] is exhaustive, so each variant is named.
fn clock_error_term<'a>(env: Env<'a>, err: &RinexClockError) -> Term<'a> {
    match err {
        RinexClockError::MalformedAsRecord {
            line,
            reason,
            record,
        } => (
            atoms::malformed_as_record(),
            LineReasonRecordTerm {
                line: *line,
                reason: (*reason).to_string(),
                record: record.clone(),
            },
        )
            .encode(env),
        RinexClockError::MissingContinuation { line, record_type } => (
            atoms::missing_continuation(),
            MissingContinuationTerm {
                line: *line,
                record_type: record_type.clone(),
            },
        )
            .encode(env),
        RinexClockError::MalformedContinuation {
            line,
            reason,
            record,
        } => (
            atoms::malformed_continuation(),
            LineReasonRecordTerm {
                line: *line,
                reason: (*reason).to_string(),
                record: record.clone(),
            },
        )
            .encode(env),
        RinexClockError::BadField { line, field, value } => (
            atoms::bad_field(),
            BadFieldTerm {
                line: *line,
                field: (*field).to_string(),
                value: value.clone(),
            },
        )
            .encode(env),
        RinexClockError::InvalidInput { field, reason } => invalid_input_term(env, field, reason),
        RinexClockError::UnsupportedTimeScale { scale } => (
            atoms::unsupported_time_scale(),
            ScaleTerm {
                scale: scale_abbrev(*scale),
            },
        )
            .encode(env),
    }
}

fn invalid_input_term<'a>(env: Env<'a>, field: &str, reason: &str) -> Term<'a> {
    (
        atoms::invalid_input(),
        FieldReasonTerm {
            field: field.to_string(),
            reason: reason.to_string(),
        },
    )
        .encode(env)
}

fn scale_abbrev(scale: TimeScale) -> String {
    scale.abbrev().to_string()
}

fn departure_term<'a>(env: Env<'a>, departure: &ClockWriteDeparture) -> Term<'a> {
    match departure {
        ClockWriteDeparture::EpochAtNearestMicrosecond {
            record,
            name,
            epoch,
            written,
        } => (
            atoms::epoch_at_nearest_microsecond(),
            DepartureTerm {
                record: *record,
                name: name.clone(),
                epoch: epoch.map(EpochTerm),
                written: written.clone(),
            },
        )
            .encode(env),
        other => (atoms::other(), other.to_string()).encode(env),
    }
}
