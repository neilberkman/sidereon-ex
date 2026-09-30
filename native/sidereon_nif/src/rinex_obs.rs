//! Rustler boundary for the `sidereon-core` RINEX observation product and
//! Hatanaka (CRINEX) codec.
//!
//! Pure glue: it decodes Erlang terms, calls the crate's `rinex` public APIs,
//! holds the parsed product as a resource handle, and encodes results back. No
//! CRINEX grammar, RINEX parsing, header-timeline rule or phase-shift policy
//! lives here; those are the crate's responsibility.
//!
//! - `crinex_decode/1` expands CRINEX text to plain RINEX text.
//! - `rinex_obs_parse/1` parses plain RINEX observation text into a handle.
//! - `crinex_obs_parse/1` decodes CRINEX then parses, in one dirty call, so a
//!   multi-megabyte expanded RINEX string is consumed inside Rust rather than
//!   marshalled across the BEAM boundary only to be passed straight back.
//! - `rinex_obs_to_string/1` and `rinex_obs_downgrade_to_rinex2/2` run the
//!   core's fallible writers, returning every refusal with the fields its
//!   [`RinexObsWriteError`] variant carries and every [`ObsDowngradeChange`].
//! - the header accessors return the file header, the header in effect at an
//!   epoch and every header segment of the timeline, each with every field
//!   [`ObsHeader`] carries.
//! - the epoch accessors return each epoch's time or its absence, flag, clock
//!   offset, picoseconds, declared count and event records, and per epoch the
//!   observations, cycle slips, carrier phases and pseudoranges.
//!
//! Every tagged payload built here takes its atoms from the `atoms!` list below,
//! so no atom is created from text a file carries.

use rustler::{Atom, Encoder, Env, Error, NifResult, ResourceArc, Term};
use sidereon_core::frequencies::rinex_band_frequency_hz;
use sidereon_core::rinex::{
    decode_crinex, encode_crinex,
    observations::{
        carrier_phase_rows, observation_values, pseudoranges, CorrectionUnavailable,
        ObsDowngradeChange, ObsEpoch, ObsEpochTime, ObsHeader, ObsLeapSeconds, ObsPhaseShift,
        ObsScaleFactor, ObservationFilter, RinexObs, RinexObsWriteError, SignalPolicy,
    },
};
use sidereon_core::{Error as CoreError, GnssSystem};
use std::collections::BTreeMap;

mod atoms {
    rustler::atoms! {
        ok,
        error,
        invalid_input,
        epoch_out_of_range,
        unknown_system,
        event_header_unreadable,
        unhandled,

        // Phase-shift status
        available,
        unknown,
        ambiguous,

        // Write error tags
        code_lists_not_version_two,
        not_version_two,
        scale_factors_in_version_two,
        values_without_codes,
        counts_without_codes,
        code_list_not_stated,
        epoch_flag_too_wide,
        epoch_time_missing,
        epoch_picoseconds_not_in_version,
        too_many_observation_types,
        code_lists_not_union,
        value_outside_declared_list,
        declared_list_not_stated,
        event_records_unreadable,
        observable_not_representable,
        leap_seconds_time_system_not_in_version,
        invalid_leap_seconds_time_system,
        read_back_mismatch,

        // Downgrade change tags
        code_renamed,
        code_moved,
        code_added,
        code_list_removed,
        value_rounded,
        cycle_slip_rounded,
        scale_factors_removed,
        epoch_picoseconds_removed,
        clock_offset_rounded,
        in_event_lists,
        deprecated_records_removed,
        event_records_rewritten,

        // Payload field names
        system,
        position,
        code,
        version,
        count,
        epoch_index,
        satellite,
        codes,
        values,
        counts,
        flag,
        message,
        time_system,
        what
    }
}

/// Resource handle holding a parsed RINEX observation product across NIF calls.
pub struct RinexObsResource {
    pub obs: RinexObs,
}

#[rustler::resource_impl]
impl rustler::Resource for RinexObsResource {}

/// A civil epoch as `{{year, month, day}, {hour, minute, second}}`.
type EpochTuple = ((i32, i32, i32), (i32, i32, f64));

/// One labelled observation crossing the boundary: code, kind, units, value
/// (`nil` if blank), loss-of-lock indicator, signal-strength indicator.
type ObsValueRow = (
    String,
    &'static str,
    &'static str,
    Option<f64>,
    Option<u8>,
    Option<u8>,
);
/// A satellite token paired with its labelled observation values.
type SatObsRow = (String, Vec<ObsValueRow>);

#[derive(Debug, Clone, rustler::NifMap)]
struct ProgramRunByDateTerm {
    program: String,
    run_by: String,
    date: String,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct ReceiverTerm {
    number: String,
    receiver_type: String,
    version: String,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct AntennaTerm {
    number: String,
    antenna_type: String,
}

/// One `SYS / PHASE SHIFT` record as the header holds it.
#[derive(Debug, Clone, rustler::NifMap)]
struct PhaseShiftTerm {
    system: String,
    /// `nil` for a record naming only its constellation, which declares the
    /// alignment unknown.
    code: Option<String>,
    /// `nil` where the record leaves the correction blank.
    correction_cycles: Option<f64>,
    satellites: Vec<String>,
    /// Satellites named by a designator no satellite id holds, as written.
    unrepresentable_satellites: Vec<String>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct ScaleFactorTerm {
    system: String,
    factor: f64,
    codes: Vec<String>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct LeapSecondsTerm {
    current: i64,
    delta_future: Option<i64>,
    week: Option<i64>,
    day: Option<i64>,
    /// The time-system identifier as written, `nil` where the field is blank.
    time_system: Option<String>,
}

/// Every field [`ObsHeader`] carries.
#[derive(Debug, Clone, rustler::NifMap)]
struct ObsHeaderTerm {
    version: f64,
    approx_position_m: Option<(f64, f64, f64)>,
    antenna_delta_hen_m: Option<(f64, f64, f64)>,
    obs_codes: Vec<(String, Vec<String>)>,
    declared_obs_codes: Vec<(String, Vec<String>)>,
    rinex2_types: Vec<String>,
    rinex2_system: Option<String>,
    program_run_by_date: Option<ProgramRunByDateTerm>,
    comments: Vec<String>,
    marker_name: Option<String>,
    marker_number: Option<String>,
    marker_type: Option<String>,
    observer: Option<String>,
    agency: Option<String>,
    receiver: Option<ReceiverTerm>,
    antenna: Option<AntennaTerm>,
    interval_s: Option<f64>,
    /// `{epoch, time_scale}`, the scale by its abbreviation, such as `"GPST"`.
    time_of_first_obs: Option<(EpochTuple, String)>,
    time_of_last_obs: Option<(EpochTuple, String)>,
    n_satellites: Option<usize>,
    prn_obs_counts: Vec<(String, Vec<Option<usize>>)>,
    phase_shifts: Vec<PhaseShiftTerm>,
    scale_factors: Vec<ScaleFactorTerm>,
    glonass_slots: Vec<(String, i8)>,
    /// `nil` where the header has no `GLONASS COD/PHS/BIS` record, `[]` for a
    /// blank record, which declares the alignment unknown.
    glonass_cod_phs_bis: Option<Vec<(String, Option<f64>)>>,
    signal_strength_unit: Option<String>,
    leap_seconds: Option<LeapSecondsTerm>,
    unretained_header_labels: Vec<String>,
}

/// One epoch record's descriptor.
#[derive(Debug, Clone, rustler::NifMap)]
struct ObsEpochTerm {
    /// `nil` for an event whose epoch fields are blank.
    epoch: Option<EpochTuple>,
    epoch_picoseconds: Option<u32>,
    flag: u8,
    rcv_clock_offset_s: Option<f64>,
    declared_record_count: usize,
    sat_count: usize,
    cycle_slip_count: usize,
    special_records: Vec<String>,
}

/// One carrier-phase observation, as the core's [`CarrierPhaseRow`] gives it.
///
/// `value_cycles` and `value_m` are the phase as the file records it. RINEX 3
/// phases are already aligned, and `SYS / PHASE SHIFT` reports the correction
/// that alignment applied, so the correction is carried beside the phase as
/// metadata and never added to it: adding it would apply it a second time.
///
/// [`CarrierPhaseRow`]: sidereon_core::rinex::observations::CarrierPhaseRow
#[derive(Debug, Clone, rustler::NifMap)]
struct PhaseRowTerm {
    code: String,
    value_cycles: Option<f64>,
    value_m: Option<f64>,
    lli: Option<u8>,
    ssi: Option<u8>,
    frequency_hz: Option<f64>,
    wavelength_m: Option<f64>,
    /// `:available`, `:unknown` or `:ambiguous`.
    phase_shift: Atom,
    /// The correction the header states for the signal, where it states one.
    phase_shift_cycles: Option<f64>,
    /// The different corrections an ambiguous header gives, in record order,
    /// `nil` for a blank one; empty unless `phase_shift` is `:ambiguous`.
    phase_shift_corrections: Vec<Option<f64>>,
}

/// One [`ObsDowngradeChange`], with every field its variant carries and `nil`
/// in every other.
#[derive(Debug, Clone, rustler::NifMap)]
struct DowngradeChangeTerm {
    tag: Atom,
    system: Option<String>,
    code: Option<String>,
    from_code: Option<String>,
    to_code: Option<String>,
    from_position: Option<usize>,
    to_position: Option<usize>,
    codes: Option<Vec<String>>,
    epoch_index: Option<usize>,
    satellite: Option<String>,
    from_value: Option<f64>,
    to_value: Option<f64>,
    count: Option<usize>,
    picoseconds: Option<u32>,
    label: Option<String>,
    records: Option<Vec<String>>,
    from_records: Option<Vec<String>>,
    to_records: Option<Vec<String>>,
    change: Option<Box<DowngradeChangeTerm>>,
    message: String,
}

/// Decode CRINEX (Hatanaka) text into the plain RINEX observation text it
/// expands to.
///
/// Dirty-CPU: a daily file's expansion is unbounded relative to the 1 ms NIF
/// budget. Returns the decoded String, or the crate's parse-error reason.
#[rustler::nif(schedule = "DirtyCpu")]
fn crinex_decode(text: String) -> NifResult<String> {
    decode_crinex(&text).map_err(|e| Error::Term(Box::new(e.to_string())))
}

/// Encode plain RINEX observation text into a CRINEX (Hatanaka) stream, the
/// inverse of `crinex_decode/1`.
///
/// Dirty-CPU: a daily file's compression is unbounded relative to the 1 ms NIF
/// budget. Returns the CRINEX String, or the crate's parse-error reason for
/// malformed RINEX input.
#[rustler::nif(schedule = "DirtyCpu")]
fn crinex_encode(text: String) -> NifResult<String> {
    encode_crinex(&text).map_err(|e| Error::Term(Box::new(e.to_string())))
}

/// Parse plain RINEX observation text into a resource handle.
///
/// Dirty-CPU: parsing a full daily file is unbounded relative to the NIF
/// budget. On a malformed file returns the parser's error as a term.
#[rustler::nif(schedule = "DirtyCpu")]
fn rinex_obs_parse(text: String) -> NifResult<ResourceArc<RinexObsResource>> {
    let obs = RinexObs::parse(&text).map_err(|e| Error::Term(Box::new(e.to_string())))?;
    Ok(ResourceArc::new(RinexObsResource { obs }))
}

/// Decode CRINEX text and parse the result in one dirty call.
///
/// The expanded RINEX text is consumed inside Rust, so only the compact typed
/// handle crosses back to the BEAM (the expansion is never marshalled).
#[rustler::nif(schedule = "DirtyCpu")]
fn crinex_obs_parse(text: String) -> NifResult<ResourceArc<RinexObsResource>> {
    let decoded = decode_crinex(&text).map_err(|e| Error::Term(Box::new(e.to_string())))?;
    let obs = RinexObs::parse(&decoded).map_err(|e| Error::Term(Box::new(e.to_string())))?;
    Ok(ResourceArc::new(RinexObsResource { obs }))
}

/// Serialize a product back to RINEX observation text, at the version its
/// header carries.
///
/// The core writer returns text only when reading it back gives the product,
/// so this is `{:ok, text}` or `{:error, {tag, fields}}` naming the first field
/// that would change. Dirty-CPU because a daily file's serialization and its
/// read-back comparison are unbounded relative to the NIF budget.
#[rustler::nif(schedule = "DirtyCpu")]
fn rinex_obs_to_string<'a>(env: Env<'a>, handle: ResourceArc<RinexObsResource>) -> Term<'a> {
    match handle.obs.to_rinex_string() {
        Ok(text) => (atoms::ok(), text).encode(env),
        Err(err) => (atoms::error(), write_error_term(env, err)).encode(env),
    }
}

/// The product as one a version 2 file can state exactly, with every change
/// that took: `{:ok, handle, changes}` or `{:error, {tag, fields}}`.
///
/// Dirty-CPU: the column layout search and the read-back write are unbounded
/// relative to the NIF budget.
#[rustler::nif(schedule = "DirtyCpu")]
fn rinex_obs_downgrade_to_rinex2<'a>(
    env: Env<'a>,
    handle: ResourceArc<RinexObsResource>,
    version: f64,
) -> Term<'a> {
    match handle.obs.downgrade_to_rinex2(version) {
        Ok((obs, changes)) => {
            let changes: Vec<DowngradeChangeTerm> =
                changes.into_iter().map(downgrade_change_term).collect();
            (
                atoms::ok(),
                ResourceArc::new(RinexObsResource { obs }),
                changes,
            )
                .encode(env)
        }
        Err(err) => (atoms::error(), write_error_term(env, err)).encode(env),
    }
}

/// The file header, with every field it carries.
///
/// Dirty-CPU: comments, `PRN / # OF OBS` counts and phase-shift lists are
/// file-sized.
#[rustler::nif(schedule = "DirtyCpu")]
fn rinex_obs_header(handle: ResourceArc<RinexObsResource>) -> ObsHeaderTerm {
    header_term(&handle.obs.header)
}

/// The header in effect at an epoch: the file header with every event at or
/// before it laid over it.
///
/// Returns `{:ok, header}`, `{:error, :epoch_out_of_range}` or
/// `{:error, {:event_header_unreadable, message}}`. Dirty-CPU: the core walks
/// every epoch up to the index and clones the header.
#[rustler::nif(schedule = "DirtyCpu")]
fn rinex_obs_header_at<'a>(
    env: Env<'a>,
    handle: ResourceArc<RinexObsResource>,
    epoch_index: usize,
) -> Term<'a> {
    if epoch_index >= handle.obs.epochs.len() {
        return (atoms::error(), atoms::epoch_out_of_range()).encode(env);
    }
    match handle.obs.header_at(epoch_index) {
        Ok(header) => (atoms::ok(), header_term(&header)).encode(env),
        Err(err) => (atoms::error(), header_error_term(env, err)).encode(env),
    }
}

/// Every header of the product's timeline with the index of the first epoch it
/// is in effect at, in file order, the file header first at index 0.
///
/// Returns `{:ok, [{first_epoch_index, header}]}` or
/// `{:error, {:event_header_unreadable, message}}`. Dirty-CPU: one header per
/// event that declares records.
#[rustler::nif(schedule = "DirtyCpu")]
fn rinex_obs_header_segments<'a>(env: Env<'a>, handle: ResourceArc<RinexObsResource>) -> Term<'a> {
    match handle.obs.header_timeline() {
        Ok(timeline) => {
            let segments: Vec<(usize, ObsHeaderTerm)> = timeline
                .segments()
                .map(|(first, header)| (first, header_term(header)))
                .collect();
            (atoms::ok(), segments).encode(env)
        }
        Err(err) => (atoms::error(), header_error_term(env, err)).encode(env),
    }
}

/// Count of records the parser skipped because their satellite token names no
/// representable satellite.
#[rustler::nif]
fn rinex_obs_skipped_records(handle: ResourceArc<RinexObsResource>) -> usize {
    handle.obs.skipped_records
}

/// The surveyed a-priori receiver position `{x_m, y_m, z_m}` (ECEF meters), or
/// the atom `nil` when the file carries no `APPROX POSITION XYZ`.
#[rustler::nif]
fn rinex_obs_approx_position(env: Env<'_>, handle: ResourceArc<RinexObsResource>) -> Term<'_> {
    match handle.obs.header.approx_position_m {
        Some([x, y, z]) => (x, y, z).encode(env),
        None => rustler::types::atom::nil().encode(env),
    }
}

/// The antenna reference-point offset from the marker `{h_m, e_m, n_m}`, or
/// the atom `nil` when the file carries no `ANTENNA: DELTA H/E/N`.
#[rustler::nif]
fn rinex_obs_antenna_delta_hen(env: Env<'_>, handle: ResourceArc<RinexObsResource>) -> Term<'_> {
    match handle.obs.header.antenna_delta_hen_m {
        Some([h, e, n]) => (h, e, n).encode(env),
        None => rustler::types::atom::nil().encode(env),
    }
}

/// The file header's `SYS / PHASE SHIFT` records, in header order.
#[rustler::nif]
fn rinex_obs_phase_shifts(handle: ResourceArc<RinexObsResource>) -> Vec<PhaseShiftTerm> {
    handle
        .obs
        .header
        .phase_shifts
        .iter()
        .map(phase_shift_term)
        .collect()
}

/// The per-constellation observation-code union as `[{"G", ["C1C", ...]}, ...]`
/// (system letter, then the code list every value is index-aligned to).
#[rustler::nif]
fn rinex_obs_codes(handle: ResourceArc<RinexObsResource>) -> Vec<(String, Vec<String>)> {
    code_table(&handle.obs.header.obs_codes)
}

/// The file header's GLONASS slot/frequency-channel map from the optional
/// `GLONASS SLOT / FRQ #` records, as `[{"R01", +1}, ...]`.
#[rustler::nif]
fn rinex_obs_glonass_slots(handle: ResourceArc<RinexObsResource>) -> Vec<(String, i8)> {
    glonass_slot_table(&handle.obs.header.glonass_slots)
}

/// The number of parsed epoch records, events and cycle slip records included.
#[rustler::nif]
fn rinex_obs_epoch_count(handle: ResourceArc<RinexObsResource>) -> usize {
    handle.obs.epochs.len()
}

/// Every epoch record's descriptor, in file order, so Elixir can index and
/// select epochs without pulling every observation across the boundary.
///
/// Dirty-CPU: one descriptor per epoch of a file-sized product.
#[rustler::nif(schedule = "DirtyCpu")]
fn rinex_obs_epochs(handle: ResourceArc<RinexObsResource>) -> Vec<ObsEpochTerm> {
    handle.obs.epochs.iter().map(epoch_term).collect()
}

/// Single-frequency pseudoranges for one epoch (by index), with an optional
/// per-system code override map `[{"G", ["C1C"]}, ...]` (an empty list uses the
/// crate's version-aware defaults).
///
/// Returns `{:ok, [{"G01", range_m}, ...]}` (exactly the solver's input shape),
/// `{:error, :epoch_out_of_range}` or `{:error, {:unknown_system, letter}}`.
#[rustler::nif(schedule = "DirtyCpu")]
fn rinex_obs_pseudoranges<'a>(
    env: Env<'a>,
    handle: ResourceArc<RinexObsResource>,
    epoch_index: usize,
    overrides: Vec<(String, Vec<String>)>,
) -> Term<'a> {
    let Some(epoch) = handle.obs.epochs.get(epoch_index) else {
        return (atoms::error(), atoms::epoch_out_of_range()).encode(env);
    };

    // An empty override list uses the crate's version-aware defaults across all
    // systems; a non-empty override list defines the policy on its own (only the
    // listed systems are extracted), so a GPS-only request never pulls in, say,
    // GLONASS satellites that a later correction cannot model.
    let policy = if overrides.is_empty() {
        match SignalPolicy::default_for(handle.obs.header.version) {
            Ok(policy) => policy,
            Err(_) => {
                return (atoms::error(), atoms::invalid_input()).encode(env);
            }
        }
    } else {
        match system_code_entries(overrides) {
            Ok(entries) => SignalPolicy {
                codes: entries.into_iter().collect(),
            },
            Err(letter) => return unknown_system(env, letter),
        }
    };

    let prs: Vec<(String, f64)> = match pseudoranges(&handle.obs, epoch, &policy) {
        Ok(rows) => rows
            .into_iter()
            .map(|(sat, range_m)| (sat.to_string(), range_m))
            .collect(),
        Err(_) => {
            return (atoms::error(), atoms::invalid_input()).encode(env);
        }
    };

    (atoms::ok(), prs).encode(env)
}

/// Raw per-satellite observation values for one epoch (by index): for each
/// satellite, every observation code its system carries (in the code union's
/// order) paired with its value, loss-of-lock indicator (LLI), and
/// signal-strength indicator (SSI).
///
/// Returns `{:ok, [{"G01", [{"C1C", kind, units, value | nil, lli | nil,
/// ssi | nil}, ...]}, ...]}`, `{:error, :epoch_out_of_range}` or
/// `{:error, {:unknown_system, letter}}`. `overrides` is an optional
/// per-system code filter `[{"G", ["L1C", "L2W"]}, ...]`: an empty list crosses
/// every code for every satellite, while a non-empty list restricts the result
/// to the listed systems only, and, within a listed system, to the listed codes
/// (an empty code list keeps all of that system's codes).
#[rustler::nif(schedule = "DirtyCpu")]
fn rinex_obs_values<'a>(
    env: Env<'a>,
    handle: ResourceArc<RinexObsResource>,
    epoch_index: usize,
    overrides: Vec<(String, Vec<String>)>,
) -> Term<'a> {
    let Some(epoch) = handle.obs.epochs.get(epoch_index) else {
        return (atoms::error(), atoms::epoch_out_of_range()).encode(env);
    };
    let filter = match decode_observation_filter(overrides) {
        Ok(filter) => filter,
        Err(letter) => return unknown_system(env, letter),
    };
    labelled_rows(env, &handle.obs, epoch, &filter)
}

/// The cycle slips a flag 6 epoch reports, labelled as `rinex_obs_values/3`
/// labels observations: each slip under the code its column declares, with its
/// indicators. Empty for every epoch whose flag is not 6.
///
/// Returns the same shapes and errors as `rinex_obs_values/3`.
#[rustler::nif(schedule = "DirtyCpu")]
fn rinex_obs_cycle_slips<'a>(
    env: Env<'a>,
    handle: ResourceArc<RinexObsResource>,
    epoch_index: usize,
    overrides: Vec<(String, Vec<String>)>,
) -> Term<'a> {
    let Some(epoch) = handle.obs.epochs.get(epoch_index) else {
        return (atoms::error(), atoms::epoch_out_of_range()).encode(env);
    };
    let filter = match decode_observation_filter(overrides) {
        Ok(filter) => filter,
        Err(letter) => return unknown_system(env, letter),
    };
    // Slips are index-aligned to the code union exactly as observations are, so
    // the core's own labelling of an epoch's observations labels them when they
    // stand in the observations' place. Only this copy is changed.
    let mut slips = epoch.clone();
    slips.sats = std::mem::take(&mut slips.cycle_slips);
    labelled_rows(env, &handle.obs, &slips, &filter)
}

/// Carrier-phase observations for one epoch, with frequency, wavelength,
/// meter-valued phase and the `SYS / PHASE SHIFT` correction status computed by
/// the crate against the header in effect at the epoch. The phase is the
/// recorded one; the correction is reported, not applied.
///
/// Returns `{:ok, [{"G01", [row]}]}`, `{:error, :epoch_out_of_range}`,
/// `{:error, {:unknown_system, letter}}` or
/// `{:error, {:event_header_unreadable, message}}`.
#[rustler::nif(schedule = "DirtyCpu")]
fn rinex_obs_phases<'a>(
    env: Env<'a>,
    handle: ResourceArc<RinexObsResource>,
    epoch_index: usize,
    overrides: Vec<(String, Vec<String>)>,
) -> Term<'a> {
    let Some(epoch) = handle.obs.epochs.get(epoch_index) else {
        return (atoms::error(), atoms::epoch_out_of_range()).encode(env);
    };
    let filter = match decode_observation_filter(overrides) {
        Ok(filter) => filter,
        Err(letter) => return unknown_system(env, letter),
    };
    // A phase shift or GLONASS channel an event declares applies from the
    // event's epoch, where the file header still holds the value from before it.
    let header = match handle.obs.header_at(epoch_index) {
        Ok(header) => header,
        Err(err) => return (atoms::error(), header_error_term(env, err)).encode(env),
    };
    let phase_rows = match carrier_phase_rows(&header, epoch, &filter) {
        Ok(phase_rows) => phase_rows,
        Err(_) => {
            return (atoms::error(), atoms::invalid_input()).encode(env);
        }
    };
    let rows: Vec<(String, Vec<PhaseRowTerm>)> = phase_rows
        .into_iter()
        .map(|(sat, rows)| {
            (
                sat.to_string(),
                rows.into_iter()
                    .map(|row| {
                        let (phase_shift, phase_shift_cycles, phase_shift_corrections) =
                            match row.phase_shift_cycles {
                                Ok(cycles) => (atoms::available(), Some(cycles), Vec::new()),
                                Err(CorrectionUnavailable::Unknown) => {
                                    (atoms::unknown(), None, Vec::new())
                                }
                                Err(CorrectionUnavailable::Ambiguous { corrections }) => {
                                    (atoms::ambiguous(), None, corrections)
                                }
                            };
                        PhaseRowTerm {
                            code: row.code,
                            value_cycles: row.value_cycles,
                            value_m: row.value_m,
                            lli: row.lli,
                            ssi: row.ssi,
                            frequency_hz: row.frequency_hz,
                            wavelength_m: row.wavelength_m,
                            phase_shift,
                            phase_shift_cycles,
                            phase_shift_corrections,
                        }
                    })
                    .collect(),
            )
        })
        .collect();

    (atoms::ok(), rows).encode(env)
}

/// Carrier frequency in hertz for a system letter and RINEX band digit.
#[rustler::nif]
fn rinex_obs_band_frequency_hz<'a>(
    env: Env<'a>,
    system: String,
    band: String,
    channel: Term<'a>,
) -> Term<'a> {
    let mut system_chars = system.chars();
    let system = match (system_chars.next(), system_chars.next()) {
        (Some(letter), None) => GnssSystem::from_letter(letter),
        _ => None,
    };
    let mut band_chars = band.chars();
    let band = match (band_chars.next(), band_chars.next()) {
        (Some(letter), None) => Some(letter),
        _ => None,
    };
    let channel = decode_optional_i8(channel).ok().flatten();
    match system
        .zip(band)
        .and_then(|(system, band)| rinex_band_frequency_hz(system, band, channel))
    {
        Some(freq) => freq.encode(env),
        None => rustler::types::atom::nil().encode(env),
    }
}

fn labelled_rows<'a>(
    env: Env<'a>,
    obs: &RinexObs,
    epoch: &ObsEpoch,
    filter: &ObservationFilter,
) -> Term<'a> {
    let values = match observation_values(obs, epoch, filter) {
        Ok(values) => values,
        Err(_) => {
            return (atoms::error(), atoms::invalid_input()).encode(env);
        }
    };
    let rows: Vec<SatObsRow> = values
        .into_iter()
        .map(|(sat, rows)| {
            (
                sat.to_string(),
                rows.into_iter()
                    .map(|row| {
                        (
                            row.code,
                            row.kind.as_str(),
                            row.kind.units_str(),
                            row.value,
                            row.lli,
                            row.ssi,
                        )
                    })
                    .collect(),
            )
        })
        .collect();

    (atoms::ok(), rows).encode(env)
}

fn epoch_tuple(t: &ObsEpochTime) -> EpochTuple {
    (
        (t.year, i32::from(t.month), i32::from(t.day)),
        (i32::from(t.hour), i32::from(t.minute), t.second),
    )
}

fn epoch_term(epoch: &ObsEpoch) -> ObsEpochTerm {
    ObsEpochTerm {
        epoch: epoch.epoch.as_ref().map(epoch_tuple),
        epoch_picoseconds: epoch.epoch_picoseconds,
        flag: epoch.flag,
        rcv_clock_offset_s: epoch.rcv_clock_offset_s,
        declared_record_count: epoch.declared_record_count,
        sat_count: epoch.sats.len(),
        cycle_slip_count: epoch.cycle_slips.len(),
        special_records: epoch.special_records.clone(),
    }
}

fn system_letter(system: GnssSystem) -> String {
    system.letter().to_string()
}

fn code_table(table: &BTreeMap<GnssSystem, Vec<String>>) -> Vec<(String, Vec<String>)> {
    table
        .iter()
        .map(|(sys, codes)| (system_letter(*sys), codes.clone()))
        .collect()
}

fn glonass_slot_table(slots: &BTreeMap<u8, i8>) -> Vec<(String, i8)> {
    slots
        .iter()
        .map(|(slot, channel)| (format!("R{slot:02}"), *channel))
        .collect()
}

fn phase_shift_term(shift: &ObsPhaseShift) -> PhaseShiftTerm {
    PhaseShiftTerm {
        system: system_letter(shift.system),
        code: shift.code.clone(),
        correction_cycles: shift.correction_cycles,
        satellites: shift.satellites.iter().map(ToString::to_string).collect(),
        unrepresentable_satellites: shift.unrepresentable_satellites.clone(),
    }
}

fn scale_factor_term(factor: &ObsScaleFactor) -> ScaleFactorTerm {
    ScaleFactorTerm {
        system: system_letter(factor.system),
        factor: factor.factor,
        codes: factor.codes.clone(),
    }
}

fn leap_seconds_term(leap: &ObsLeapSeconds) -> LeapSecondsTerm {
    LeapSecondsTerm {
        current: leap.current,
        delta_future: leap.delta_future,
        week: leap.week,
        day: leap.day,
        time_system: leap.time_system.clone(),
    }
}

fn header_term(header: &ObsHeader) -> ObsHeaderTerm {
    ObsHeaderTerm {
        version: header.version,
        approx_position_m: header.approx_position_m.map(|[x, y, z]| (x, y, z)),
        antenna_delta_hen_m: header.antenna_delta_hen_m.map(|[h, e, n]| (h, e, n)),
        obs_codes: code_table(&header.obs_codes),
        declared_obs_codes: code_table(&header.declared_obs_codes),
        rinex2_types: header.rinex2_types.clone(),
        rinex2_system: header.rinex2_system.map(system_letter),
        program_run_by_date: header
            .program_run_by_date
            .as_ref()
            .map(|pgm| ProgramRunByDateTerm {
                program: pgm.program.clone(),
                run_by: pgm.run_by.clone(),
                date: pgm.date.clone(),
            }),
        comments: header.comments.clone(),
        marker_name: header.marker_name.clone(),
        marker_number: header.marker_number.clone(),
        marker_type: header.marker_type.clone(),
        observer: header.observer.clone(),
        agency: header.agency.clone(),
        receiver: header.receiver.as_ref().map(|receiver| ReceiverTerm {
            number: receiver.number.clone(),
            receiver_type: receiver.receiver_type.clone(),
            version: receiver.version.clone(),
        }),
        antenna: header.antenna.as_ref().map(|antenna| AntennaTerm {
            number: antenna.number.clone(),
            antenna_type: antenna.antenna_type.clone(),
        }),
        interval_s: header.interval_s,
        time_of_first_obs: header
            .time_of_first_obs
            .as_ref()
            .map(|(time, scale)| (epoch_tuple(time), scale.abbrev().to_string())),
        time_of_last_obs: header
            .time_of_last_obs
            .as_ref()
            .map(|(time, scale)| (epoch_tuple(time), scale.abbrev().to_string())),
        n_satellites: header.n_satellites,
        prn_obs_counts: header
            .prn_obs_counts
            .iter()
            .map(|(sat, counts)| (sat.to_string(), counts.clone()))
            .collect(),
        phase_shifts: header.phase_shifts.iter().map(phase_shift_term).collect(),
        scale_factors: header.scale_factors.iter().map(scale_factor_term).collect(),
        glonass_slots: glonass_slot_table(&header.glonass_slots),
        glonass_cod_phs_bis: header.glonass_cod_phs_bis.clone(),
        signal_strength_unit: header.signal_strength_unit.clone(),
        leap_seconds: header.leap_seconds.as_ref().map(leap_seconds_term),
        unretained_header_labels: header.unretained_header_labels.clone(),
    }
}

/// A header-timeline failure. An event record that does not read is the one
/// failure a product can hold; anything else the core returns is carried with
/// its own text under `:unhandled`.
fn header_error_term<'a>(env: Env<'a>, err: CoreError) -> Term<'a> {
    match err {
        CoreError::Parse(message) => (atoms::event_header_unreadable(), message).encode(env),
        CoreError::InvalidInput(_) => atoms::epoch_out_of_range().encode(env),
        other => (atoms::unhandled(), other.to_string()).encode(env),
    }
}

/// A map of the payload fields a tagged variant carries, keyed by atoms from
/// this module's `atoms!` list.
fn field_map<'a>(env: Env<'a>, pairs: Vec<(Atom, Term<'a>)>) -> Term<'a> {
    pairs
        .into_iter()
        .fold(rustler::types::map::map_new(env), |map, (key, value)| {
            // `map_put` fails only on a term that is not a map, and `map` is
            // always one here.
            map.map_put(key, value).unwrap_or(map)
        })
}

/// A writer refusal as `{tag, %{field => value}}`, with every field its
/// variant carries. [`RinexObsWriteError`] is exhaustive, so every variant is
/// named here.
fn write_error_term<'a>(env: Env<'a>, err: RinexObsWriteError) -> Term<'a> {
    let (tag, fields): (Atom, Vec<(Atom, Term<'a>)>) = match err {
        RinexObsWriteError::CodeListsNotVersionTwo {
            system,
            position,
            code,
        } => (
            atoms::code_lists_not_version_two(),
            vec![
                (atoms::system(), system_letter(system).encode(env)),
                (atoms::position(), position.encode(env)),
                (atoms::code(), code.encode(env)),
            ],
        ),
        RinexObsWriteError::NotVersionTwo { version } => (
            atoms::not_version_two(),
            vec![(atoms::version(), version.encode(env))],
        ),
        RinexObsWriteError::ScaleFactorsInVersionTwo { count } => (
            atoms::scale_factors_in_version_two(),
            vec![(atoms::count(), count.encode(env))],
        ),
        RinexObsWriteError::ValuesWithoutCodes {
            epoch_index,
            satellite,
            codes,
            values,
        } => (
            atoms::values_without_codes(),
            vec![
                (atoms::epoch_index(), epoch_index.encode(env)),
                (atoms::satellite(), satellite.to_string().encode(env)),
                (atoms::codes(), codes.encode(env)),
                (atoms::values(), values.encode(env)),
            ],
        ),
        RinexObsWriteError::CountsWithoutCodes {
            satellite,
            codes,
            counts,
        } => (
            atoms::counts_without_codes(),
            vec![
                (atoms::satellite(), satellite.to_string().encode(env)),
                (atoms::codes(), codes.encode(env)),
                (atoms::counts(), counts.encode(env)),
            ],
        ),
        RinexObsWriteError::CodeListNotStated { system } => (
            atoms::code_list_not_stated(),
            vec![(atoms::system(), system_letter(system).encode(env))],
        ),
        RinexObsWriteError::EpochFlagTooWide { epoch_index, flag } => (
            atoms::epoch_flag_too_wide(),
            vec![
                (atoms::epoch_index(), epoch_index.encode(env)),
                (atoms::flag(), flag.encode(env)),
            ],
        ),
        RinexObsWriteError::EpochTimeMissing { epoch_index, flag } => (
            atoms::epoch_time_missing(),
            vec![
                (atoms::epoch_index(), epoch_index.encode(env)),
                (atoms::flag(), flag.encode(env)),
            ],
        ),
        RinexObsWriteError::EpochPicosecondsNotInVersion {
            epoch_index,
            version,
        } => (
            atoms::epoch_picoseconds_not_in_version(),
            vec![
                (atoms::epoch_index(), epoch_index.encode(env)),
                (atoms::version(), version.encode(env)),
            ],
        ),
        RinexObsWriteError::TooManyObservationTypes { count } => (
            atoms::too_many_observation_types(),
            vec![(atoms::count(), count.encode(env))],
        ),
        RinexObsWriteError::CodeListsNotUnion { system } => (
            atoms::code_lists_not_union(),
            vec![(atoms::system(), system_letter(system).encode(env))],
        ),
        RinexObsWriteError::ValueOutsideDeclaredList {
            epoch_index,
            satellite,
            code,
        } => (
            atoms::value_outside_declared_list(),
            vec![
                (atoms::epoch_index(), epoch_index.encode(env)),
                (atoms::satellite(), satellite.to_string().encode(env)),
                (atoms::code(), code.encode(env)),
            ],
        ),
        RinexObsWriteError::DeclaredListNotStated { system } => (
            atoms::declared_list_not_stated(),
            vec![(atoms::system(), system_letter(system).encode(env))],
        ),
        RinexObsWriteError::EventRecordsUnreadable { message } => (
            atoms::event_records_unreadable(),
            vec![(atoms::message(), message.encode(env))],
        ),
        RinexObsWriteError::ObservableNotRepresentable {
            system,
            code,
            version,
        } => (
            atoms::observable_not_representable(),
            vec![
                (atoms::system(), system_letter(system).encode(env)),
                (atoms::code(), code.encode(env)),
                (atoms::version(), version.encode(env)),
            ],
        ),
        RinexObsWriteError::LeapSecondsTimeSystemNotInVersion {
            time_system,
            version,
        } => (
            atoms::leap_seconds_time_system_not_in_version(),
            vec![
                (atoms::time_system(), time_system.encode(env)),
                (atoms::version(), version.encode(env)),
            ],
        ),
        RinexObsWriteError::InvalidLeapSecondsTimeSystem { time_system } => (
            atoms::invalid_leap_seconds_time_system(),
            vec![(atoms::time_system(), time_system.encode(env))],
        ),
        RinexObsWriteError::ReadBackMismatch { what } => (
            atoms::read_back_mismatch(),
            vec![(atoms::what(), what.encode(env))],
        ),
    };
    (tag, field_map(env, fields)).encode(env)
}

/// Encode a writer refusal for a caller in another module of this crate, such
/// as observation QC's repaired-product writer.
pub(crate) fn encode_write_error<'a>(env: Env<'a>, err: RinexObsWriteError) -> Term<'a> {
    write_error_term(env, err)
}

fn change_base(tag: Atom, message: String) -> DowngradeChangeTerm {
    DowngradeChangeTerm {
        tag,
        system: None,
        code: None,
        from_code: None,
        to_code: None,
        from_position: None,
        to_position: None,
        codes: None,
        epoch_index: None,
        satellite: None,
        from_value: None,
        to_value: None,
        count: None,
        picoseconds: None,
        label: None,
        records: None,
        from_records: None,
        to_records: None,
        change: None,
        message,
    }
}

/// One downgrade change with every field its variant carries.
/// [`ObsDowngradeChange`] is exhaustive, so every variant is named here. The
/// core gives the change no text of its own, so `message` is its `Debug` form.
fn downgrade_change_term(change: ObsDowngradeChange) -> DowngradeChangeTerm {
    let message = format!("{change:?}");
    match change {
        ObsDowngradeChange::CodeRenamed { system, from, to } => {
            let mut term = change_base(atoms::code_renamed(), message);
            term.system = Some(system_letter(system));
            term.from_code = Some(from);
            term.to_code = Some(to);
            term
        }
        ObsDowngradeChange::CodeMoved {
            system,
            code,
            from,
            to,
        } => {
            let mut term = change_base(atoms::code_moved(), message);
            term.system = Some(system_letter(system));
            term.code = Some(code);
            term.from_position = Some(from);
            term.to_position = Some(to);
            term
        }
        ObsDowngradeChange::CodeAdded { system, code } => {
            let mut term = change_base(atoms::code_added(), message);
            term.system = Some(system_letter(system));
            term.code = Some(code);
            term
        }
        ObsDowngradeChange::CodeListRemoved { system, codes } => {
            let mut term = change_base(atoms::code_list_removed(), message);
            term.system = Some(system_letter(system));
            term.codes = Some(codes);
            term
        }
        ObsDowngradeChange::ValueRounded {
            epoch_index,
            satellite,
            code,
            from,
            to,
        } => {
            let mut term = change_base(atoms::value_rounded(), message);
            term.epoch_index = Some(epoch_index);
            term.satellite = Some(satellite.to_string());
            term.code = Some(code);
            term.from_value = Some(from);
            term.to_value = Some(to);
            term
        }
        ObsDowngradeChange::CycleSlipRounded {
            epoch_index,
            satellite,
            code,
            from,
            to,
        } => {
            let mut term = change_base(atoms::cycle_slip_rounded(), message);
            term.epoch_index = Some(epoch_index);
            term.satellite = Some(satellite.to_string());
            term.code = Some(code);
            term.from_value = Some(from);
            term.to_value = Some(to);
            term
        }
        ObsDowngradeChange::ScaleFactorsRemoved { count } => {
            let mut term = change_base(atoms::scale_factors_removed(), message);
            term.count = Some(count);
            term
        }
        ObsDowngradeChange::EpochPicosecondsRemoved {
            epoch_index,
            picoseconds,
        } => {
            let mut term = change_base(atoms::epoch_picoseconds_removed(), message);
            term.epoch_index = Some(epoch_index);
            term.picoseconds = Some(picoseconds);
            term
        }
        ObsDowngradeChange::ClockOffsetRounded {
            epoch_index,
            from,
            to,
        } => {
            let mut term = change_base(atoms::clock_offset_rounded(), message);
            term.epoch_index = Some(epoch_index);
            term.from_value = Some(from);
            term.to_value = Some(to);
            term
        }
        ObsDowngradeChange::InEventLists {
            epoch_index,
            change,
        } => {
            let mut term = change_base(atoms::in_event_lists(), message);
            term.epoch_index = Some(epoch_index);
            term.change = Some(Box::new(downgrade_change_term(*change)));
            term
        }
        ObsDowngradeChange::DeprecatedRecordsRemoved {
            label,
            epoch_index,
            records,
        } => {
            let mut term = change_base(atoms::deprecated_records_removed(), message);
            term.label = Some(label);
            term.epoch_index = epoch_index;
            term.records = Some(records);
            term
        }
        ObsDowngradeChange::EventRecordsRewritten {
            epoch_index,
            from,
            to,
        } => {
            let mut term = change_base(atoms::event_records_rewritten(), message);
            term.epoch_index = Some(epoch_index);
            term.from_records = Some(from);
            term.to_records = Some(to);
            term
        }
    }
}

fn unknown_system<'a>(env: Env<'a>, letter: String) -> Term<'a> {
    (atoms::error(), (atoms::unknown_system(), letter)).encode(env)
}

/// Resolve `[{"G", codes}, ...]` entries to systems. A key that is not one
/// system letter is refused by name rather than dropped: dropping the only
/// entry of a filter would turn it into the empty filter, which keeps every
/// system.
fn system_code_entries(
    overrides: Vec<(String, Vec<String>)>,
) -> Result<Vec<(GnssSystem, Vec<String>)>, String> {
    overrides
        .into_iter()
        .map(|(letter, codes)| {
            let mut chars = letter.chars();
            match (chars.next(), chars.next()) {
                (Some(c), None) => GnssSystem::from_letter(c)
                    .map(|system| (system, codes))
                    .ok_or(letter),
                _ => Err(letter),
            }
        })
        .collect()
}

fn decode_observation_filter(
    overrides: Vec<(String, Vec<String>)>,
) -> Result<ObservationFilter, String> {
    system_code_entries(overrides).map(ObservationFilter::from_entries)
}

fn decode_optional_i8(term: Term<'_>) -> NifResult<Option<i8>> {
    if term.is_atom() && term.atom_to_string().unwrap_or_default() == "nil" {
        return Ok(None);
    }
    let value = term.decode::<i64>()?;
    Ok(i8::try_from(value).ok())
}
