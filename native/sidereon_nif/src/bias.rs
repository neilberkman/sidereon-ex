use rustler::{Encoder, Env, Error, NifResult, ResourceArc, Term};
use sidereon_core::astro::time::civil;
use sidereon_core::astro::time::model::{Instant, JulianDateSplit, TimeScale};
use sidereon_core::bias::{BiasKind, BiasMode, BiasRecord, BiasSet, BiasTarget, CodeDcbOptions};
use sidereon_core::GnssSatelliteId;

use crate::errors;

pub struct BiasResource {
    pub set: BiasSet,
}

#[rustler::resource_impl]
impl rustler::Resource for BiasResource {}

mod atoms {
    rustler::atoms! {
        ok,
        error,
        invalid_input,
        not_found
    }
}

#[derive(Debug, Clone, rustler::NifMap)]
struct BiasRecordTerm {
    kind: String,
    target: String,
    svn: Option<String>,
    obs1: String,
    obs2: Option<String>,
    valid_from: Option<String>,
    valid_until: Option<String>,
    value: f64,
    sigma: Option<f64>,
    slope: Option<f64>,
    slope_sigma: Option<f64>,
    is_phase: bool,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct BiasInfoTerm {
    records: i64,
    skipped_records: i64,
    mode: String,
    time_scale: String,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct CodeDcbOptionsTerm {
    obs1: String,
    obs2: String,
    year: i32,
    month: u8,
    time_scale: String,
    receiver_system: Option<String>,
}

fn parse_time_scale(value: &str) -> NifResult<TimeScale> {
    Ok(match value {
        "UTC" => TimeScale::Utc,
        "TAI" => TimeScale::Tai,
        "TT" => TimeScale::Tt,
        "TDB" => TimeScale::Tdb,
        "GPST" => TimeScale::Gpst,
        "GST" => TimeScale::Gst,
        "BDT" => TimeScale::Bdt,
        "GLONASST" => TimeScale::Glonasst,
        "QZSST" => TimeScale::Qzsst,
        _ => return Err(Error::Term(Box::new("unknown time scale"))),
    })
}

fn dcb_options(term: Option<CodeDcbOptionsTerm>) -> NifResult<Option<CodeDcbOptions>> {
    term.map(|opts| {
        let receiver_system = match opts.receiver_system {
            Some(letter) => Some(crate::sp3::system_from_letter(&letter)?),
            None => None,
        };
        Ok(CodeDcbOptions {
            pair: (opts.obs1, opts.obs2),
            year: opts.year,
            month: opts.month,
            time_scale: parse_time_scale(&opts.time_scale)?,
            receiver_system,
        })
    })
    .transpose()
}

fn sat_id(token: &str) -> NifResult<GnssSatelliteId> {
    if token.len() < 2 {
        return Err(Error::Term(Box::new("invalid satellite id")));
    }
    let (system, prn) = token.split_at(1);
    let system = crate::sp3::system_from_letter(system)?;
    let prn: u8 = prn
        .parse()
        .map_err(|_| Error::Term(Box::new("invalid satellite prn")))?;
    GnssSatelliteId::new(system, prn).map_err(errors::invalid_input)
}

fn instant(scale: String, j2000_s: f64) -> NifResult<Instant> {
    let scale = parse_time_scale(&scale)?;
    let (jd_whole, fraction) = civil::split_julian_date_from_j2000_seconds(j2000_s.round() as i64);
    let fraction = fraction + (j2000_s - j2000_s.round()) / 86_400.0;
    Ok(Instant::from_julian_date(
        scale,
        JulianDateSplit::new(jd_whole, fraction).map_err(errors::invalid_input)?,
    ))
}

fn kind_label(kind: BiasKind) -> &'static str {
    match kind {
        BiasKind::Osb => "osb",
        BiasKind::Dsb => "dsb",
        BiasKind::Isb => "isb",
    }
}

fn target_label(target: &BiasTarget) -> String {
    match target {
        BiasTarget::System(system) => system.as_str().to_string(),
        BiasTarget::Satellite(sat) => sat.to_string(),
        BiasTarget::Receiver { system, station } => format!("{}:{station}", system.as_str()),
        BiasTarget::SatelliteReceiver { sat, station } => format!("{sat}:{station}"),
    }
}

fn record_term(record: &BiasRecord) -> BiasRecordTerm {
    BiasRecordTerm {
        kind: kind_label(record.kind).to_string(),
        target: target_label(&record.target),
        svn: record.svn.clone(),
        obs1: record.obs1.clone(),
        obs2: record.obs2.clone(),
        valid_from: record.valid_from.map(|e| e.format_sinex()),
        valid_until: record.valid_until.map(|e| e.format_sinex()),
        value: record.value,
        sigma: record.sigma,
        slope: record.slope,
        slope_sigma: record.slope_sigma,
        is_phase: record.is_phase,
    }
}

fn info_term(set: &BiasSet) -> BiasInfoTerm {
    let mode = match set.mode {
        BiasMode::Absolute => "absolute",
        BiasMode::Relative => "relative",
        BiasMode::Unspecified => "unspecified",
    };
    BiasInfoTerm {
        records: set.records().len() as i64,
        skipped_records: set.skipped_records() as i64,
        mode: mode.to_string(),
        time_scale: set.time_scale.abbrev().to_string(),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn bias_parse_sinex(bytes: rustler::Binary) -> NifResult<ResourceArc<BiasResource>> {
    let set = sidereon::parse_bias_sinex(bytes.as_slice())
        .map_err(|e| Error::Term(Box::new(e.to_string())))?;
    Ok(ResourceArc::new(BiasResource { set }))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn bias_parse_sinex_lossy<'a>(env: Env<'a>, bytes: rustler::Binary) -> NifResult<Term<'a>> {
    let parsed = sidereon::parse_bias_sinex_lossy(bytes.as_slice())
        .map_err(|e| Error::Term(Box::new(e.to_string())))?;
    let resource = ResourceArc::new(BiasResource { set: parsed.value });
    Ok((atoms::ok(), resource, parsed.diagnostics.skips.len() as i64).encode(env))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn bias_load_sinex(path: String) -> NifResult<ResourceArc<BiasResource>> {
    let set = sidereon::load_bias_sinex(path).map_err(|e| Error::Term(Box::new(e.to_string())))?;
    Ok(ResourceArc::new(BiasResource { set }))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn bias_load_sinex_lossy<'a>(env: Env<'a>, path: String) -> NifResult<Term<'a>> {
    let parsed =
        sidereon::load_bias_sinex_lossy(path).map_err(|e| Error::Term(Box::new(e.to_string())))?;
    let resource = ResourceArc::new(BiasResource { set: parsed.value });
    Ok((atoms::ok(), resource, parsed.diagnostics.skips.len() as i64).encode(env))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn bias_parse_code_dcb(
    bytes: rustler::Binary,
    options: Option<CodeDcbOptionsTerm>,
) -> NifResult<ResourceArc<BiasResource>> {
    let set = sidereon::parse_code_dcb(bytes.as_slice(), dcb_options(options)?)
        .map_err(|e| Error::Term(Box::new(e.to_string())))?;
    Ok(ResourceArc::new(BiasResource { set }))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn bias_parse_code_dcb_lossy<'a>(
    env: Env<'a>,
    bytes: rustler::Binary,
    options: Option<CodeDcbOptionsTerm>,
) -> NifResult<Term<'a>> {
    let parsed = sidereon::parse_code_dcb_lossy(bytes.as_slice(), dcb_options(options)?)
        .map_err(|e| Error::Term(Box::new(e.to_string())))?;
    let resource = ResourceArc::new(BiasResource { set: parsed.value });
    Ok((atoms::ok(), resource, parsed.diagnostics.skips.len() as i64).encode(env))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn bias_load_code_dcb(
    path: String,
    options: Option<CodeDcbOptionsTerm>,
) -> NifResult<ResourceArc<BiasResource>> {
    let set = sidereon::load_code_dcb(path, dcb_options(options)?)
        .map_err(|e| Error::Term(Box::new(e.to_string())))?;
    Ok(ResourceArc::new(BiasResource { set }))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn bias_load_code_dcb_lossy<'a>(
    env: Env<'a>,
    path: String,
    options: Option<CodeDcbOptionsTerm>,
) -> NifResult<Term<'a>> {
    let parsed = sidereon::load_code_dcb_lossy(path, dcb_options(options)?)
        .map_err(|e| Error::Term(Box::new(e.to_string())))?;
    let resource = ResourceArc::new(BiasResource { set: parsed.value });
    Ok((atoms::ok(), resource, parsed.diagnostics.skips.len() as i64).encode(env))
}

#[rustler::nif]
fn bias_info(handle: ResourceArc<BiasResource>) -> BiasInfoTerm {
    info_term(&handle.set)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn bias_records(handle: ResourceArc<BiasResource>) -> Vec<BiasRecordTerm> {
    handle.set.records().iter().map(record_term).collect()
}

#[rustler::nif]
fn bias_code_osb<'a>(
    env: Env<'a>,
    handle: ResourceArc<BiasResource>,
    satellite_id: String,
    obs: String,
    epoch_j2000_s: f64,
    scale: String,
) -> NifResult<Term<'a>> {
    let sat = sat_id(&satellite_id)?;
    let epoch = instant(scale, epoch_j2000_s)?;
    Ok(match handle.set.code_osb_seconds(sat, &obs, epoch) {
        Some(value) => (atoms::ok(), value).encode(env),
        None => (atoms::error(), atoms::not_found()).encode(env),
    })
}

#[rustler::nif]
fn bias_code_dsb<'a>(
    env: Env<'a>,
    handle: ResourceArc<BiasResource>,
    satellite_id: String,
    obs1: String,
    obs2: String,
    epoch_j2000_s: f64,
    scale: String,
) -> NifResult<Term<'a>> {
    let sat = sat_id(&satellite_id)?;
    let epoch = instant(scale, epoch_j2000_s)?;
    Ok(
        match handle.set.code_dsb_seconds(sat, &obs1, &obs2, epoch) {
            Some(value) => (atoms::ok(), value).encode(env),
            None => (atoms::error(), atoms::not_found()).encode(env),
        },
    )
}
