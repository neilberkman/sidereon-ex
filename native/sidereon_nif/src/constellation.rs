//! Rustler boundary for `sidereon_core::constellation` (multi-system GNSS
//! identity catalogs).
//!
//! Pure glue over the core crate: decode Erlang terms, call the core
//! constellation surface, and encode the results back. No PRN/slot/SVID parsing,
//! NAVCEN HTML scanning, FDMA channel table, block-type detection, validation,
//! or diff logic lives here; all of that is `sidereon_core::constellation`,
//! which covers GPS, Galileo, GLONASS, BeiDou, and QZSS.

use crate::errors;
use rustler::types::atom::Atom;
use rustler::{Decoder, Encoder, Env, NifResult, Term};
use sidereon_core::astro::omm::{parse_json_array, Omm, OmmEpoch};
use sidereon_core::constellation::{
    self as cc, BoolStyle, CelestrakSource, ConstellationError, Diff, NavcenSource, NavcenStatus,
    Record, RecordSource, Validation,
};
use sidereon_core::GnssSystem;

mod atoms {
    rustler::atoms! {
        ok,
        error,
        missing_prn,
    }
}

// ── system letter helpers ────────────────────────────────────────────────────

fn system_from_letter(letter: &str) -> NifResult<GnssSystem> {
    let c = letter
        .chars()
        .next()
        .ok_or_else(|| rustler::Error::Term(Box::new("empty GNSS system letter")))?;
    GnssSystem::from_letter(c).ok_or_else(|| {
        rustler::Error::Term(Box::new(format!("unknown GNSS system letter {letter:?}")))
    })
}

fn system_letter(system: GnssSystem) -> String {
    system.letter().to_string()
}

// ── small term helpers ───────────────────────────────────────────────────────

fn put<'a>(env: Env<'a>, map: Term<'a>, key: &str, value: impl Encoder) -> Term<'a> {
    let atom = Atom::from_str(env, key).expect("atom key");
    map.map_put(atom.to_term(env), value).expect("map_put")
}

/// Required map value: errors (BadArg) if the key is absent or mistyped. Used for
/// fields the Elixir wrapper always provides.
fn req<'a, T: Decoder<'a>>(env: Env<'a>, map: Term<'a>, key: &str) -> NifResult<T> {
    let atom = Atom::from_str(env, key)?;
    map.map_get(atom.to_term(env))?.decode()
}

/// Optional map value: a `nil` value, an absent key, or a type mismatch all read
/// as `None`. Lets a hand-built record carry a sparse `source` map.
fn opt<'a, T: Decoder<'a>>(env: Env<'a>, map: Term<'a>, key: &str) -> Option<T> {
    let atom = Atom::from_str(env, key).ok()?;
    map.map_get(atom.to_term(env)).ok()?.decode().ok()
}

fn checked_u16(value: i64, name: &'static str) -> NifResult<u16> {
    u16::try_from(value)
        .map_err(|_| rustler::Error::Term(Box::new(format!("{name} out of range for u16"))))
}

/// A nested sub-map, or `None` when the key is absent / `nil` / not a map.
fn submap<'a>(env: Env<'a>, map: Term<'a>, key: &str) -> Option<Term<'a>> {
    let atom = Atom::from_str(env, key).ok()?;
    let value = map.map_get(atom.to_term(env)).ok()?;
    value.is_map().then_some(value)
}

// ── OMM-lite decode → core Omm ───────────────────────────────────────────────

/// Build a minimal core [`Omm`] from the identity fields the constellation
/// catalog reads (`OBJECT_NAME`, `NORAD_CAT_ID`, `OBJECT_ID`, `EPOCH`). The
/// remaining mean-element fields are never consulted by
/// `sidereon_core::constellation`, so they are placeholders.
fn omm_from_term<'a>(env: Env<'a>, term: Term<'a>) -> NifResult<Omm> {
    let object_name: Option<String> = opt(env, term, "object_name");
    let norad_id: i64 = req(env, term, "norad_id")?;
    let object_id: Option<String> = opt(env, term, "object_id");
    let epoch: Option<String> = opt(env, term, "epoch");

    Ok(Omm {
        ccsds_omm_vers: String::new(),
        creation_date: None,
        originator: None,
        object_name,
        object_id,
        center_name: None,
        ref_frame: None,
        time_system: None,
        mean_element_theory: None,
        epoch: parse_epoch(epoch.as_deref()),
        mean_motion: 0.0,
        eccentricity: 0.0,
        inclination_deg: 0.0,
        ra_of_asc_node_deg: 0.0,
        arg_of_pericenter_deg: 0.0,
        mean_anomaly_deg: 0.0,
        ephemeris_type: 0,
        classification_type: "U".to_string(),
        norad_cat_id: u32::try_from(norad_id)
            .map_err(|_| rustler::Error::Term(Box::new("norad_id out of range for u32")))?,
        element_set_no: 0,
        rev_at_epoch: 0,
        bstar: 0.0,
        mean_motion_dot: 0.0,
        mean_motion_ddot: 0.0,
    })
}

/// Parse an OMM `EPOCH` string into the split [`OmmEpoch`] the core re-renders
/// into record provenance, delegating to the public
/// `sidereon_core::astro::omm::parse_epoch` (the same parser the full OMM decode
/// uses). Any unparseable / absent value yields a zero epoch; the catalog
/// identity does not depend on the epoch value.
fn parse_epoch(s: Option<&str>) -> OmmEpoch {
    let zero = OmmEpoch {
        year: 0,
        month: 0,
        day: 0,
        hour: 0,
        minute: 0,
        second: 0,
        microsecond: 0,
    };
    s.and_then(|text| sidereon_core::astro::omm::parse_epoch(text).ok())
        .unwrap_or(zero)
}

// ── Record decode (Elixir map → core Record) ─────────────────────────────────

fn decode_record<'a>(env: Env<'a>, term: Term<'a>) -> NifResult<Record> {
    let system = system_from_letter(&req::<String>(env, term, "system")?)?;
    let prn = checked_u16(req::<i64>(env, term, "prn")?, "prn")?;
    let svn = opt::<i64>(env, term, "svn")
        .map(|v| checked_u16(v, "svn"))
        .transpose()?;
    let norad_id = u32::try_from(req::<i64>(env, term, "norad_id")?)
        .map_err(|_| rustler::Error::Term(Box::new("norad_id out of range for u32")))?;
    let sp3_id = req::<String>(env, term, "sp3_id")?;
    let fdma_channel = opt::<i64>(env, term, "fdma_channel")
        .map(|v| {
            i8::try_from(v).map_err(|_| rustler::Error::Term(Box::new("fdma_channel out of range")))
        })
        .transpose()?;
    let active = req::<bool>(env, term, "active")?;
    let usable = req::<bool>(env, term, "usable")?;
    let source = decode_source(env, term);

    Ok(Record {
        system,
        prn,
        svn,
        norad_id,
        sp3_id,
        fdma_channel,
        active,
        usable,
        source,
    })
}

/// Decode the structured `source` provenance, tolerating a sparse or absent map
/// (a hand-built record may carry only `%{}` or unrelated keys).
fn decode_source<'a>(env: Env<'a>, record: Term<'a>) -> RecordSource {
    let Some(source) = submap(env, record, "source") else {
        return RecordSource::default();
    };

    RecordSource {
        celestrak: submap(env, source, "celestrak").map(|c| CelestrakSource {
            group: opt::<String>(env, c, "group").unwrap_or_default(),
            object_name: opt(env, c, "object_name"),
            object_id: opt(env, c, "object_id"),
            epoch: opt(env, c, "epoch"),
            block_type: opt(env, c, "block_type"),
        }),
        navcen: decode_navcen_source(env, source, "navcen"),
        navcen_conflict: decode_navcen_source(env, source, "navcen_conflict"),
    }
}

fn decode_navcen_source<'a>(env: Env<'a>, source: Term<'a>, key: &str) -> Option<NavcenSource> {
    let n = submap(env, source, key)?;
    Some(NavcenSource {
        svn: opt::<i64>(env, n, "svn").and_then(|v| u16::try_from(v).ok()),
        block_type: opt(env, n, "block_type"),
        plane: opt(env, n, "plane"),
        slot: opt(env, n, "slot"),
        clock: opt(env, n, "clock"),
        nanu_type: opt(env, n, "nanu_type"),
        nanu_subject: opt(env, n, "nanu_subject"),
        active_nanu: opt::<bool>(env, n, "active_nanu").unwrap_or(false),
    })
}

fn decode_records<'a>(env: Env<'a>, terms: Vec<Term<'a>>) -> NifResult<Vec<Record>> {
    terms.into_iter().map(|t| decode_record(env, t)).collect()
}

// ── NavcenStatus decode (Elixir map → core NavcenStatus) ─────────────────────

fn decode_navcen_status<'a>(env: Env<'a>, term: Term<'a>) -> NifResult<NavcenStatus> {
    Ok(NavcenStatus {
        system: system_from_letter(&req::<String>(env, term, "system")?)?,
        prn: checked_u16(req::<i64>(env, term, "prn")?, "prn")?,
        svn: opt::<i64>(env, term, "svn")
            .map(|v| checked_u16(v, "svn"))
            .transpose()?,
        usable: req::<bool>(env, term, "usable")?,
        active_nanu: req::<bool>(env, term, "active_nanu")?,
        nanu_type: opt(env, term, "nanu_type"),
        nanu_subject: opt(env, term, "nanu_subject"),
        plane: opt(env, term, "plane"),
        slot: opt(env, term, "slot"),
        block_type: opt(env, term, "block_type"),
        clock: opt(env, term, "clock"),
    })
}

// ── encoders (core → Elixir map) ─────────────────────────────────────────────

fn encode_celestrak<'a>(env: Env<'a>, c: &CelestrakSource) -> Term<'a> {
    let m = Term::map_new(env);
    let m = put(env, m, "group", c.group.clone());
    let m = put(env, m, "object_name", c.object_name.clone());
    let m = put(env, m, "object_id", c.object_id.clone());
    let m = put(env, m, "epoch", c.epoch.clone());
    put(env, m, "block_type", c.block_type.clone())
}

fn encode_navcen_source<'a>(env: Env<'a>, n: &NavcenSource) -> Term<'a> {
    let m = Term::map_new(env);
    let m = put(env, m, "svn", n.svn.map(i64::from));
    let m = put(env, m, "block_type", n.block_type.clone());
    let m = put(env, m, "plane", n.plane.clone());
    let m = put(env, m, "slot", n.slot.clone());
    let m = put(env, m, "clock", n.clock.clone());
    let m = put(env, m, "nanu_type", n.nanu_type.clone());
    let m = put(env, m, "nanu_subject", n.nanu_subject.clone());
    put(env, m, "active_nanu", n.active_nanu)
}

fn encode_source<'a>(env: Env<'a>, source: &RecordSource) -> Term<'a> {
    let m = Term::map_new(env);
    let m = put(
        env,
        m,
        "celestrak",
        source.celestrak.as_ref().map(|c| encode_celestrak(env, c)),
    );
    let m = put(
        env,
        m,
        "navcen",
        source.navcen.as_ref().map(|n| encode_navcen_source(env, n)),
    );
    put(
        env,
        m,
        "navcen_conflict",
        source
            .navcen_conflict
            .as_ref()
            .map(|n| encode_navcen_source(env, n)),
    )
}

fn encode_record<'a>(env: Env<'a>, r: &Record) -> Term<'a> {
    let m = Term::map_new(env);
    let m = put(env, m, "system", system_letter(r.system));
    let m = put(env, m, "prn", i64::from(r.prn));
    let m = put(env, m, "svn", r.svn.map(i64::from));
    let m = put(env, m, "norad_id", i64::from(r.norad_id));
    let m = put(env, m, "sp3_id", r.sp3_id.clone());
    let m = put(env, m, "fdma_channel", r.fdma_channel.map(i64::from));
    let m = put(env, m, "active", r.active);
    let m = put(env, m, "usable", r.usable);
    put(env, m, "source", encode_source(env, &r.source))
}

fn encode_records<'a>(env: Env<'a>, records: &[Record]) -> Term<'a> {
    records
        .iter()
        .map(|r| encode_record(env, r))
        .collect::<Vec<_>>()
        .encode(env)
}

fn encode_navcen_status<'a>(env: Env<'a>, s: &NavcenStatus) -> Term<'a> {
    let m = Term::map_new(env);
    let m = put(env, m, "system", system_letter(s.system));
    let m = put(env, m, "prn", i64::from(s.prn));
    let m = put(env, m, "svn", s.svn.map(i64::from));
    let m = put(env, m, "usable", s.usable);
    let m = put(env, m, "active_nanu", s.active_nanu);
    let m = put(env, m, "nanu_type", s.nanu_type.clone());
    let m = put(env, m, "nanu_subject", s.nanu_subject.clone());
    let m = put(env, m, "plane", s.plane.clone());
    let m = put(env, m, "slot", s.slot.clone());
    let m = put(env, m, "block_type", s.block_type.clone());
    put(env, m, "clock", s.clock.clone())
}

fn encode_change<'a, V: Encoder>(
    env: Env<'a>,
    system: GnssSystem,
    prn: u16,
    from: V,
    to: V,
) -> Term<'a> {
    let m = Term::map_new(env);
    let m = put(env, m, "system", system_letter(system));
    let m = put(env, m, "prn", i64::from(prn));
    let m = put(env, m, "from", from);
    put(env, m, "to", to)
}

fn encode_validation<'a>(env: Env<'a>, v: &Validation) -> Term<'a> {
    let prn_pairs = |pairs: &[(GnssSystem, u16)]| -> Vec<(String, i64)> {
        pairs
            .iter()
            .map(|(sys, prn)| (system_letter(*sys), i64::from(*prn)))
            .collect()
    };

    let m = Term::map_new(env);
    let m = put(env, m, "missing_sp3_ids", v.missing_sp3_ids.clone());
    let m = put(env, m, "duplicate_prns", prn_pairs(&v.duplicate_prns));
    let m = put(
        env,
        m,
        "duplicate_norad_ids",
        v.duplicate_norad_ids
            .iter()
            .map(|id| i64::from(*id))
            .collect::<Vec<_>>(),
    );
    let m = put(
        env,
        m,
        "inactive_unusable_prns",
        prn_pairs(&v.inactive_unusable_prns),
    );
    put(env, m, "extra_sp3_ids", v.extra_sp3_ids.clone())
}

fn encode_diff<'a>(env: Env<'a>, diff: &Diff) -> Term<'a> {
    let m = Term::map_new(env);
    let m = put(env, m, "added", encode_records(env, &diff.added));
    let m = put(env, m, "removed", encode_records(env, &diff.removed));
    let m = put(
        env,
        m,
        "norad_reassigned",
        diff.norad_reassigned
            .iter()
            .map(|c| encode_change(env, c.system, c.prn, i64::from(c.from), i64::from(c.to)))
            .collect::<Vec<_>>(),
    );
    let m = put(
        env,
        m,
        "sp3_id_changed",
        diff.sp3_id_changed
            .iter()
            .map(|c| encode_change(env, c.system, c.prn, c.from.clone(), c.to.clone()))
            .collect::<Vec<_>>(),
    );
    let m = put(
        env,
        m,
        "svn_changed",
        diff.svn_changed
            .iter()
            .map(|c| {
                encode_change(
                    env,
                    c.system,
                    c.prn,
                    c.from.map(i64::from),
                    c.to.map(i64::from),
                )
            })
            .collect::<Vec<_>>(),
    );
    let m = put(
        env,
        m,
        "fdma_channel_changed",
        diff.fdma_channel_changed
            .iter()
            .map(|c| {
                encode_change(
                    env,
                    c.system,
                    c.prn,
                    c.from.map(i64::from),
                    c.to.map(i64::from),
                )
            })
            .collect::<Vec<_>>(),
    );
    let m = put(
        env,
        m,
        "activity_changed",
        diff.activity_changed
            .iter()
            .map(|c| encode_change(env, c.system, c.prn, c.from, c.to))
            .collect::<Vec<_>>(),
    );
    put(
        env,
        m,
        "usability_changed",
        diff.usability_changed
            .iter()
            .map(|c| encode_change(env, c.system, c.prn, c.from, c.to))
            .collect::<Vec<_>>(),
    )
}

fn missing_prn_term<'a>(env: Env<'a>, name: Option<String>) -> Term<'a> {
    (atoms::error(), (atoms::missing_prn(), name)).encode(env)
}

fn encode_catalog<'a>(env: Env<'a>, catalog: &cc::Catalog) -> Term<'a> {
    let skipped: Vec<Term> = catalog
        .skipped
        .iter()
        .map(|s| {
            let m = Term::map_new(env);
            let m = put(env, m, "object_name", s.object_name.clone());
            put(env, m, "norad_id", i64::from(s.norad_id))
        })
        .collect();

    let result = Term::map_new(env);
    let result = put(
        env,
        result,
        "records",
        encode_records(env, &catalog.records),
    );
    put(env, result, "skipped", skipped)
}

// ── NIFs ─────────────────────────────────────────────────────────────────────

#[rustler::nif(schedule = "DirtyCpu")]
pub fn constellation_from_celestrak_omm<'a>(
    env: Env<'a>,
    system_letter: String,
    omms: Vec<Term<'a>>,
) -> NifResult<Term<'a>> {
    let system = system_from_letter(&system_letter)?;
    let core_omms: Vec<Omm> = omms
        .into_iter()
        .map(|t| omm_from_term(env, t))
        .collect::<NifResult<_>>()?;

    match cc::from_celestrak_omm(system, &core_omms) {
        Ok(records) => Ok((atoms::ok(), encode_records(env, &records)).encode(env)),
        Err(ConstellationError::MissingPrn(name)) => Ok(missing_prn_term(env, name)),
        Err(e) => Ok((atoms::error(), e.to_string()).encode(env)),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn constellation_from_celestrak_json<'a>(
    env: Env<'a>,
    system_letter: String,
    json: String,
) -> NifResult<Term<'a>> {
    let system = system_from_letter(&system_letter)?;
    let parsed = match parse_json_array(&json) {
        Ok(parsed) => parsed,
        Err(e) => return Ok((atoms::error(), e.to_string()).encode(env)),
    };

    match cc::from_celestrak_omm(system, &parsed.omms) {
        Ok(records) => Ok((atoms::ok(), encode_records(env, &records)).encode(env)),
        Err(ConstellationError::MissingPrn(name)) => Ok(missing_prn_term(env, name)),
        Err(e) => Ok((atoms::error(), e.to_string()).encode(env)),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn constellation_from_celestrak_omm_lenient<'a>(
    env: Env<'a>,
    system_letter: String,
    omms: Vec<Term<'a>>,
) -> NifResult<Term<'a>> {
    let system = system_from_letter(&system_letter)?;
    let core_omms: Vec<Omm> = omms
        .into_iter()
        .map(|t| omm_from_term(env, t))
        .collect::<NifResult<_>>()?;

    let catalog = cc::from_celestrak_omm_lenient(system, &core_omms);
    Ok((atoms::ok(), encode_catalog(env, &catalog)).encode(env))
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn constellation_from_celestrak_json_lenient<'a>(
    env: Env<'a>,
    system_letter: String,
    json: String,
) -> NifResult<Term<'a>> {
    let system = system_from_letter(&system_letter)?;
    let parsed = match parse_json_array(&json) {
        Ok(parsed) => parsed,
        Err(e) => return Ok((atoms::error(), e.to_string()).encode(env)),
    };

    let catalog = cc::from_celestrak_omm_lenient(system, &parsed.omms);
    Ok((atoms::ok(), encode_catalog(env, &catalog)).encode(env))
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn constellation_parse_navcen<'a>(env: Env<'a>, html: String) -> Term<'a> {
    match cc::parse_navcen(html.as_bytes()) {
        Ok(statuses) => {
            let encoded: Vec<Term> = statuses
                .iter()
                .map(|s| encode_navcen_status(env, s))
                .collect();
            (atoms::ok(), encoded).encode(env)
        }
        Err(e) => (atoms::error(), e.to_string()).encode(env),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn constellation_merge_navcen<'a>(
    env: Env<'a>,
    records: Vec<Term<'a>>,
    statuses: Vec<Term<'a>>,
) -> NifResult<Term<'a>> {
    let records = decode_records(env, records)?;
    let statuses: Vec<NavcenStatus> = statuses
        .into_iter()
        .map(|t| decode_navcen_status(env, t))
        .collect::<NifResult<_>>()?;

    let merged = cc::merge_navcen(&records, &statuses);
    Ok(encode_records(env, &merged))
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn constellation_to_csv<'a>(
    env: Env<'a>,
    records: Vec<Term<'a>>,
    booleans: String,
) -> NifResult<String> {
    let records = decode_records(env, records)?;
    let style = match booleans.as_str() {
        "title" => BoolStyle::Title,
        _ => BoolStyle::Lower,
    };
    Ok(cc::to_csv(&records, style))
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn constellation_validate<'a>(env: Env<'a>, records: Vec<Term<'a>>) -> NifResult<Term<'a>> {
    let records = decode_records(env, records)?;
    Ok(encode_validation(env, &cc::validate(&records)))
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn constellation_validate_against_sp3_ids<'a>(
    env: Env<'a>,
    records: Vec<Term<'a>>,
    sp3_ids: Vec<String>,
) -> NifResult<Term<'a>> {
    let records = decode_records(env, records)?;
    let ids: Vec<&str> = sp3_ids.iter().map(String::as_str).collect();
    Ok(encode_validation(
        env,
        &cc::validate_against_sp3_ids(&records, &ids),
    ))
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn constellation_validate_against_sp3_ids_strict<'a>(
    env: Env<'a>,
    records: Vec<Term<'a>>,
    sp3_ids: Vec<String>,
) -> NifResult<Term<'a>> {
    let records = decode_records(env, records)?;
    let ids: Vec<&str> = sp3_ids.iter().map(String::as_str).collect();
    match cc::validate_against_sp3_ids_strict(&records, &ids) {
        Ok(()) => Ok(atoms::ok().encode(env)),
        Err(e) => Ok((atoms::error(), e.to_string()).encode(env)),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn constellation_diff<'a>(
    env: Env<'a>,
    previous: Vec<Term<'a>>,
    current: Vec<Term<'a>>,
) -> NifResult<Term<'a>> {
    let previous = decode_records(env, previous)?;
    let current = decode_records(env, current)?;
    Ok(encode_diff(env, &cc::diff(&previous, &current)))
}

#[rustler::nif]
pub fn constellation_glonass_fdma_channel(slot: i64) -> Option<i64> {
    u16::try_from(slot)
        .ok()
        .and_then(cc::glonass_fdma_channel)
        .map(i64::from)
}

#[rustler::nif]
pub fn constellation_galileo_prn_for_gsat(gsat: i64) -> Option<i64> {
    u16::try_from(gsat)
        .ok()
        .and_then(cc::galileo_prn_for_gsat)
        .map(i64::from)
}

#[rustler::nif]
pub fn constellation_glonass_slot_for_number(number: i64) -> Option<i64> {
    u16::try_from(number)
        .ok()
        .and_then(cc::glonass_slot_for_number)
        .map(i64::from)
}

#[rustler::nif]
pub fn constellation_sp3_id(system_letter: String, prn: i64) -> NifResult<String> {
    let system = system_from_letter(&system_letter)?;
    let prn = u16::try_from(prn).map_err(errors::invalid_input)?;
    Ok(cc::gnss_sp3_id(system, prn))
}
