//! Rustler boundary for the `sidereon-core` RINEX 3 observation product
//! and Hatanaka (CRINEX) decoder.
//!
//! Pure glue: it decodes Erlang terms, calls the crate's `rinex` public APIs,
//! holds the parsed product as a resource handle, and
//! encodes results back. No CRINEX grammar, RINEX parsing, or pseudorange
//! selection numerics live here; those are the crate's responsibility.
//!
//! - `crinex_decode/1` expands CRINEX text to plain RINEX text.
//! - `rinex_obs_parse/1` parses plain RINEX observation text into a handle.
//! - `crinex_obs_parse/1` decodes CRINEX then parses, in one dirty call, so a
//!   multi-megabyte expanded RINEX string is consumed inside Rust rather than
//!   marshalled across the BEAM boundary only to be passed straight back.
//! - the accessors expose the header, the epoch list, and per-epoch
//!   single-frequency pseudoranges as the `[{sat_token, range_m}]` shape the
//!   point-positioning solver consumes.

use rustler::{Encoder, Env, Error, NifResult, ResourceArc, Term};
use sidereon_core::frequencies::rinex_band_frequency_hz;
use sidereon_core::rinex::{
    decode_crinex, encode_crinex,
    observations::{
        carrier_phase_rows, observation_values, pseudoranges, ObsEpoch, ObservationFilter,
        RinexObs, SignalPolicy,
    },
};
use sidereon_core::GnssSystem;

mod atoms {
    rustler::atoms! {
        invalid_input
    }
}

/// Resource handle holding a parsed RINEX observation product across NIF calls.
pub struct RinexObsResource {
    pub obs: RinexObs,
}

/// One labelled observation crossing the boundary: code, value (`nil` if blank),
/// loss-of-lock indicator, signal-strength indicator.
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
/// Frequency, wavelength, meter-valued phase, and phase-shift correction.
type PhaseMeta = (Option<f64>, Option<f64>, Option<f64>, f64);
/// One carrier-phase observation with derived frequency/wavelength/metres.
type PhaseRow = (String, Option<f64>, Option<u8>, Option<u8>, PhaseMeta);
/// A satellite token paired with its carrier-phase observations.
type SatPhaseRow = (String, Vec<PhaseRow>);

#[rustler::resource_impl]
impl rustler::Resource for RinexObsResource {}

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

/// Parse plain RINEX 3 observation text into a resource handle.
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

/// Serialize a parsed RINEX observation product back to standard RINEX 3
/// observation text. The inverse of `rinex_obs_parse`: re-parsing the output
/// reproduces the same header and epochs. Dirty-CPU because a daily file's
/// serialization is unbounded relative to the NIF budget.
#[rustler::nif(schedule = "DirtyCpu")]
fn rinex_obs_to_string(handle: ResourceArc<RinexObsResource>) -> String {
    handle.obs.to_rinex_string()
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

/// Carrier phase-shift header records as
/// `[{"G", "L1C", correction_cycles, ["G01", ...]}, ...]`.
#[rustler::nif]
fn rinex_obs_phase_shifts(
    handle: ResourceArc<RinexObsResource>,
) -> Vec<(String, String, f64, Vec<String>)> {
    handle
        .obs
        .header
        .phase_shifts
        .iter()
        .map(|shift| {
            (
                shift.system.letter().to_string(),
                shift.code.clone(),
                shift.correction_cycles,
                shift.satellites.iter().map(ToString::to_string).collect(),
            )
        })
        .collect()
}

/// The per-constellation observation-code table as `[{"G", ["C1C", ...]}, ...]`
/// in declared order (system letter, then the code list).
#[rustler::nif]
fn rinex_obs_codes(handle: ResourceArc<RinexObsResource>) -> Vec<(String, Vec<String>)> {
    handle
        .obs
        .header
        .obs_codes
        .iter()
        .map(|(sys, codes)| (sys.letter().to_string(), codes.clone()))
        .collect()
}

/// The GLONASS satellite slot/frequency-channel map from the optional
/// `GLONASS SLOT / FRQ #` header records, as `[{"R01", +1}, ...]`.
#[rustler::nif]
fn rinex_obs_glonass_slots(handle: ResourceArc<RinexObsResource>) -> Vec<(String, i8)> {
    handle
        .obs
        .header
        .glonass_slots
        .iter()
        .map(|(slot, channel)| (format!("R{slot:02}"), *channel))
        .collect()
}

/// The number of parsed epochs.
#[rustler::nif]
fn rinex_obs_epoch_count(handle: ResourceArc<RinexObsResource>) -> usize {
    handle.obs.epochs.len()
}

/// The epoch list as `[{ {{y,mo,d},{h,mi,second_float}}, flag, sat_count }]`, so
/// Elixir can index/select epochs without pulling every observation across the
/// boundary. The civil-time tuple is exactly the form `solve/4` accepts.
#[rustler::nif]
fn rinex_obs_epochs(env: Env<'_>, handle: ResourceArc<RinexObsResource>) -> Term<'_> {
    let list: Vec<Term> = handle
        .obs
        .epochs
        .iter()
        .map(|e| encode_epoch(env, e))
        .collect();
    list.encode(env)
}

/// Single-frequency pseudoranges for one epoch (by index), with an optional
/// per-system code override map `[{"G", ["C1C"]}, ...]` (an empty list uses the
/// crate's version-aware defaults).
///
/// Returns `{:ok, [{"G01", range_m}, ...]}` (exactly the solver's input shape)
/// or `{:error, :epoch_out_of_range}`.
#[rustler::nif(schedule = "DirtyCpu")]
fn rinex_obs_pseudoranges(
    env: Env<'_>,
    handle: ResourceArc<RinexObsResource>,
    epoch_index: usize,
    overrides: Vec<(String, Vec<String>)>,
) -> Term<'_> {
    let Some(epoch) = handle.obs.epochs.get(epoch_index) else {
        let reason = rustler::types::atom::Atom::from_str(env, "epoch_out_of_range")
            .map(|a| a.encode(env))
            .unwrap_or_else(|_| "epoch_out_of_range".encode(env));
        return (rustler::types::atom::error(), reason).encode(env);
    };

    // An empty override list uses the crate's version-aware defaults across all
    // systems; a non-empty override list defines the policy on its own (only the
    // listed systems are extracted), so a GPS-only request never pulls in, say,
    // GLONASS satellites that a later correction cannot model.
    let policy = if overrides.is_empty() {
        match SignalPolicy::default_for(handle.obs.header.version) {
            Ok(policy) => policy,
            Err(_) => {
                return (rustler::types::atom::error(), atoms::invalid_input()).encode(env);
            }
        }
    } else {
        let mut codes = std::collections::BTreeMap::new();
        for (letter, code_list) in overrides {
            if let Some(c) = letter.chars().next() {
                if let Some(system) = GnssSystem::from_letter(c) {
                    codes.insert(system, code_list);
                }
            }
        }
        SignalPolicy { codes }
    };

    let prs: Vec<(String, f64)> = match pseudoranges(&handle.obs, epoch, &policy) {
        Ok(rows) => rows
            .into_iter()
            .map(|(sat, range_m)| (sat.to_string(), range_m))
            .collect(),
        Err(_) => {
            return (rustler::types::atom::error(), atoms::invalid_input()).encode(env);
        }
    };

    (rustler::types::atom::ok(), prs).encode(env)
}

/// Raw per-satellite observation values for one epoch (by index): for each
/// satellite, every observation code its system carries (in the header's declared
/// order) paired with its value, loss-of-lock indicator (LLI), and signal-strength
/// indicator (SSI). Per the RINEX convention the value is metres for `C*`
/// pseudoranges and cycles for `L*` carrier phase (Hz for `D*` Doppler, etc.);
/// units are the caller's to interpret from the code's leading letter.
///
/// Returns `{:ok, [{"G01", [{"C1C", value | nil, lli | nil, ssi | nil}, ...]}, ...]}`
/// or `{:error, :epoch_out_of_range}`. A blank observation has a `nil` value;
/// trailing blank observations a satellite did not report are simply absent.
/// `overrides` is an optional per-system code filter `[{"G", ["L1C", "L2W"]}, ...]`:
/// an empty list crosses every code for every satellite, while a non-empty list
/// restricts the result to the listed systems only, and, within a listed system,
/// to the listed codes (an empty code list keeps all of that system's codes). This
/// keeps a daily product from marshalling every observable when the caller only
/// wants a few.
#[rustler::nif(schedule = "DirtyCpu")]
fn rinex_obs_values(
    env: Env<'_>,
    handle: ResourceArc<RinexObsResource>,
    epoch_index: usize,
    overrides: Vec<(String, Vec<String>)>,
) -> Term<'_> {
    let Some(epoch) = handle.obs.epochs.get(epoch_index) else {
        let reason = rustler::types::atom::Atom::from_str(env, "epoch_out_of_range")
            .map(|a| a.encode(env))
            .unwrap_or_else(|_| "epoch_out_of_range".encode(env));
        return (rustler::types::atom::error(), reason).encode(env);
    };

    let filter = decode_observation_filter(overrides);
    let values = match observation_values(&handle.obs, epoch, &filter) {
        Ok(values) => values,
        Err(_) => {
            return (rustler::types::atom::error(), atoms::invalid_input()).encode(env);
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

    (rustler::types::atom::ok(), rows).encode(env)
}

/// Carrier-phase observations for one epoch, with frequency, wavelength,
/// phase-shift, and meter-valued phase computed by the crate.
#[rustler::nif(schedule = "DirtyCpu")]
fn rinex_obs_phases(
    env: Env<'_>,
    handle: ResourceArc<RinexObsResource>,
    epoch_index: usize,
    overrides: Vec<(String, Vec<String>)>,
) -> Term<'_> {
    let Some(epoch) = handle.obs.epochs.get(epoch_index) else {
        let reason = rustler::types::atom::Atom::from_str(env, "epoch_out_of_range")
            .map(|a| a.encode(env))
            .unwrap_or_else(|_| "epoch_out_of_range".encode(env));
        return (rustler::types::atom::error(), reason).encode(env);
    };

    let filter = decode_observation_filter(overrides);
    let phase_rows = match carrier_phase_rows(&handle.obs, epoch, &filter) {
        Ok(phase_rows) => phase_rows,
        Err(_) => {
            return (rustler::types::atom::error(), atoms::invalid_input()).encode(env);
        }
    };
    let rows: Vec<SatPhaseRow> = phase_rows
        .into_iter()
        .map(|(sat, rows)| {
            (
                sat.to_string(),
                rows.into_iter()
                    .map(|row| {
                        // The hardened core keeps the SYS / PHASE SHIFT
                        // correction as metadata and leaves value_cycles as the
                        // raw recorded phase. The Elixir layer expects the shift
                        // folded into value_cycles (and value_m) so phases are
                        // aligned to a common reference, so re-apply it here.
                        let value_cycles = row
                            .value_cycles
                            .map(|cycles| cycles + row.phase_shift_cycles);
                        let value_m = value_cycles
                            .zip(row.wavelength_m)
                            .map(|(cycles, lambda)| cycles * lambda);
                        (
                            row.code,
                            value_cycles,
                            row.lli,
                            row.ssi,
                            (
                                row.frequency_hz,
                                row.wavelength_m,
                                value_m,
                                row.phase_shift_cycles,
                            ),
                        )
                    })
                    .collect(),
            )
        })
        .collect();

    (rustler::types::atom::ok(), rows).encode(env)
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

/// Encode one epoch as `{ {{y,mo,d},{h,mi,second_float}}, flag, sat_count }`.
fn encode_epoch<'a>(env: Env<'a>, epoch: &ObsEpoch) -> Term<'a> {
    let t = &epoch.epoch;
    let datetime = (
        (t.year, t.month as i32, t.day as i32),
        (t.hour as i32, t.minute as i32, t.second),
    );
    (datetime, epoch.flag, epoch.sats.len()).encode(env)
}

fn decode_observation_filter(overrides: Vec<(String, Vec<String>)>) -> ObservationFilter {
    ObservationFilter::from_entries(overrides.into_iter().filter_map(|(letter, codes)| {
        letter
            .chars()
            .next()
            .and_then(GnssSystem::from_letter)
            .map(|system| (system, codes))
    }))
}

fn decode_optional_i8(term: Term<'_>) -> NifResult<Option<i8>> {
    if term.is_atom() && term.atom_to_string().unwrap_or_default() == "nil" {
        return Ok(None);
    }
    let value = term.decode::<i64>()?;
    Ok(i8::try_from(value).ok())
}
