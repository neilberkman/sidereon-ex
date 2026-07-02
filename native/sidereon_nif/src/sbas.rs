use rustler::{Encoder, Env, Error, NifResult, ResourceArc, Term};
use sidereon_core::astro::time::model::{GnssWeekTow, TimeScale};
use sidereon_core::ephemeris::{self, EphemerisSampleStatus, EphemerisSource};
use sidereon_core::sbas::{
    parse_ems_lines, parse_rtklib_lines, sat_to_sbas_prn, sbas_prn_to_sat, SbasBlock,
    SbasCorrectedEphemeris, SbasCorrectionStore, SbasIonoGrid, SbasLogBlock, SbasMessage,
    SbasSolveMode, SbasWireForm,
};
use sidereon_core::staleness::StalenessPolicy;
use sidereon_core::GnssSatelliteId;

use crate::broadcast::BroadcastResource;
use crate::errors;
use crate::spp;

pub struct SbasStoreResource {
    pub store: SbasCorrectionStore,
}

#[rustler::resource_impl]
impl rustler::Resource for SbasStoreResource {}

type Vec3 = (f64, f64, f64);

mod atoms {
    rustler::atoms! {
        ok,
        error,
        invalid_input,
        not_found
    }
}

#[derive(Debug, Clone, rustler::NifMap)]
struct SbasBlockTerm {
    satellite_id: String,
    epoch_scale: String,
    week: i64,
    tow_s: f64,
    form: String,
    bytes: Vec<u8>,
    message: SbasMessageTerm,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct SbasMessageTerm {
    kind: String,
    message_type: i64,
    preamble: i64,
    details: String,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct SbasFastTerm {
    prc_m: f64,
    rrc_m_s: f64,
    udrei: i64,
    t_of_j2000_s: f64,
    iodf: i64,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct SbasLongTerm {
    iode: i64,
    delta_ecef_m: Vec3,
    delta_ecef_rate_m_s: Vec3,
    delta_af0_s: f64,
    delta_af1_s_s: f64,
    t0_j2000_s: f64,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct SbasIgpTerm {
    latitude_deg: f64,
    longitude_deg: f64,
    vertical_delay_m: f64,
    give_variance_m2: Option<f64>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct SbasIonoGridTerm {
    iodi: i64,
    igps: Vec<SbasIgpTerm>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct SbasGeoNavTerm {
    position_ecef_m: Vec3,
    velocity_ecef_m_s: Vec3,
    acceleration_ecef_m_s2: Vec3,
    clock_offset_s: f64,
    clock_drift_s_s: f64,
    t0_j2000_s: f64,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct EphemerisSampleRowTerm {
    satellite_id: String,
    epoch_j2000_s: f64,
    status: String,
    position_ecef_m: Option<Vec3>,
    clock_s: Option<f64>,
}

fn parse_time_scale(value: &str) -> NifResult<TimeScale> {
    Ok(match value {
        "GPST" => TimeScale::Gpst,
        "GST" => TimeScale::Gst,
        "BDT" => TimeScale::Bdt,
        "UTC" => TimeScale::Utc,
        _ => return Err(Error::Term(Box::new("unknown time scale"))),
    })
}

fn week_tow(scale: String, week: u32, tow_s: f64) -> NifResult<GnssWeekTow> {
    GnssWeekTow::new(parse_time_scale(&scale)?, week, tow_s).map_err(errors::invalid_input)
}

fn wire_form(value: &str) -> NifResult<SbasWireForm> {
    Ok(match value {
        "framed_250" | "framed250" => SbasWireForm::Framed250,
        "body_226" | "body226" => SbasWireForm::Body226,
        _ => return Err(Error::Term(Box::new("unknown SBAS wire form"))),
    })
}

fn wire_form_label(form: SbasWireForm) -> String {
    match form {
        SbasWireForm::Framed250 => "framed_250",
        SbasWireForm::Body226 => "body_226",
    }
    .to_string()
}

fn solve_mode(value: &str) -> NifResult<SbasSolveMode> {
    Ok(match value {
        "mixed" | "mixed_augmentation" => SbasSolveMode::MixedAugmentation,
        "sbas_only" => SbasSolveMode::SbasOnly,
        _ => return Err(Error::Term(Box::new("unknown SBAS solve mode"))),
    })
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

fn sbas_geo(token: &str) -> NifResult<GnssSatelliteId> {
    if let Some(rest) = token.strip_prefix('S') {
        let prn: u16 = rest
            .parse()
            .map_err(|_| Error::Term(Box::new("invalid SBAS GEO id")))?;
        sbas_prn_to_sat(prn).ok_or_else(|| Error::Term(Box::new("invalid SBAS GEO prn")))
    } else {
        sat_id(token)
    }
}

fn block_from_terms(
    bytes: &[u8],
    form: &str,
    geo: &str,
    scale: String,
    week: u32,
    tow_s: f64,
) -> NifResult<(GnssSatelliteId, GnssWeekTow, SbasBlock)> {
    let block = SbasBlock::decode(bytes, wire_form(form)?)
        .map_err(|e| Error::Term(Box::new(e.to_string())))?;
    Ok((sbas_geo(geo)?, week_tow(scale, week, tow_s)?, block))
}

fn message_kind(message: &SbasMessage) -> &'static str {
    match message {
        SbasMessage::DoNotUse(_) => "do_not_use",
        SbasMessage::PrnMask(_) => "prn_mask",
        SbasMessage::FastCorrections(_) => "fast_corrections",
        SbasMessage::Integrity(_) => "integrity",
        SbasMessage::FastDegradation(_) => "fast_degradation",
        SbasMessage::GeoNav(_) => "geo_nav",
        SbasMessage::NetworkTime(_) => "network_time",
        SbasMessage::GeoAlmanac(_) => "geo_almanac",
        SbasMessage::IgpMask(_) => "igp_mask",
        SbasMessage::MixedCorrections(_) => "mixed_corrections",
        SbasMessage::LongTermCorrections(_) => "long_term_corrections",
        SbasMessage::IonoDelays(_) => "iono_delays",
        SbasMessage::Unsupported(_) => "unsupported",
    }
}

fn message_preamble(message: &SbasMessage) -> u8 {
    match message {
        SbasMessage::DoNotUse(m) => m.preamble,
        SbasMessage::PrnMask(m) => m.preamble,
        SbasMessage::FastCorrections(m) => m.preamble,
        SbasMessage::Integrity(m) => m.preamble,
        SbasMessage::FastDegradation(m) => m.preamble,
        SbasMessage::GeoNav(m) => m.preamble,
        SbasMessage::NetworkTime(m) => m.preamble,
        SbasMessage::GeoAlmanac(m) => m.preamble,
        SbasMessage::IgpMask(m) => m.preamble,
        SbasMessage::MixedCorrections(m) => m.preamble,
        SbasMessage::LongTermCorrections(m) => m.preamble,
        SbasMessage::IonoDelays(m) => m.preamble,
        SbasMessage::Unsupported(m) => m.preamble,
    }
}

fn message_term(message: &SbasMessage) -> SbasMessageTerm {
    SbasMessageTerm {
        kind: message_kind(message).to_string(),
        message_type: i64::from(message.message_type()),
        preamble: i64::from(message_preamble(message)),
        details: format!("{message:?}"),
    }
}

fn block_term(block: SbasLogBlock) -> NifResult<SbasBlockTerm> {
    let decoded = SbasBlock::decode(&block.bytes, block.form)
        .map_err(|e| Error::Term(Box::new(e.to_string())))?;
    let scale = match block.epoch.system {
        TimeScale::Gpst => "GPST",
        TimeScale::Gst => "GST",
        TimeScale::Bdt => "BDT",
        TimeScale::Utc => "UTC",
        _ => "unknown",
    };
    Ok(SbasBlockTerm {
        satellite_id: block.satellite_id.to_string(),
        epoch_scale: scale.to_string(),
        week: i64::from(block.epoch.week),
        tow_s: block.epoch.tow_s,
        form: wire_form_label(block.form),
        bytes: block.bytes,
        message: message_term(&decoded.message),
    })
}

fn ingest_blocks(
    blocks: Vec<SbasLogBlock>,
    max_staleness_s: f64,
    allow_partial: bool,
) -> NifResult<SbasCorrectionStore> {
    let mut store = SbasCorrectionStore::new()
        .with_policy(StalenessPolicy::seconds(max_staleness_s))
        .allow_partial(allow_partial);
    for block in blocks {
        let decoded = SbasBlock::decode(&block.bytes, block.form)
            .map_err(|e| Error::Term(Box::new(e.to_string())))?;
        store
            .ingest(&decoded.message, block.satellite_id, block.epoch)
            .map_err(|e| Error::Term(Box::new(e.to_string())))?;
    }
    Ok(store)
}

fn sample_row(row: ephemeris::EphemerisSampleRow) -> EphemerisSampleRowTerm {
    let status = match row.status {
        EphemerisSampleStatus::Valid => "valid",
        EphemerisSampleStatus::Gap => "gap",
    }
    .to_string();
    EphemerisSampleRowTerm {
        satellite_id: row.sat.to_string(),
        epoch_j2000_s: row.epoch_j2000_s,
        status,
        position_ecef_m: row.position_ecef_m.map(|p| (p[0], p[1], p[2])),
        clock_s: row.clock_s,
    }
}

fn iono_grid_term(grid: &SbasIonoGrid) -> SbasIonoGridTerm {
    SbasIonoGridTerm {
        iodi: i64::from(grid.iodi),
        igps: grid
            .igps()
            .iter()
            .map(|igp| SbasIgpTerm {
                latitude_deg: igp.lat_deg,
                longitude_deg: igp.lon_deg,
                vertical_delay_m: igp.vertical_delay_m,
                give_variance_m2: igp.give_variance_m2,
            })
            .collect(),
    }
}

#[rustler::nif]
fn sbas_decode<'a>(env: Env<'a>, bytes: rustler::Binary, form: String) -> NifResult<Term<'a>> {
    match SbasBlock::decode(bytes.as_slice(), wire_form(&form)?) {
        Ok(block) => Ok((atoms::ok(), message_term(&block.message)).encode(env)),
        Err(error) => Ok((atoms::error(), error.to_string()).encode(env)),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn sbas_parse_ems(text: String) -> NifResult<Vec<SbasBlockTerm>> {
    parse_ems_lines(&text)
        .map_err(|e| Error::Term(Box::new(e.to_string())))?
        .into_iter()
        .map(block_term)
        .collect()
}

#[rustler::nif(schedule = "DirtyCpu")]
fn sbas_parse_rtklib(text: String) -> NifResult<Vec<SbasBlockTerm>> {
    parse_rtklib_lines(&text)
        .map_err(|e| Error::Term(Box::new(e.to_string())))?
        .into_iter()
        .map(block_term)
        .collect()
}

#[rustler::nif]
fn sbas_store_new(max_staleness_s: f64, allow_partial: bool) -> ResourceArc<SbasStoreResource> {
    ResourceArc::new(SbasStoreResource {
        store: SbasCorrectionStore::new()
            .with_policy(StalenessPolicy::seconds(max_staleness_s))
            .allow_partial(allow_partial),
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn sbas_store_from_ems(
    text: String,
    max_staleness_s: f64,
    allow_partial: bool,
) -> NifResult<ResourceArc<SbasStoreResource>> {
    let blocks = parse_ems_lines(&text).map_err(|e| Error::Term(Box::new(e.to_string())))?;
    Ok(ResourceArc::new(SbasStoreResource {
        store: ingest_blocks(blocks, max_staleness_s, allow_partial)?,
    }))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn sbas_store_from_rtklib(
    text: String,
    max_staleness_s: f64,
    allow_partial: bool,
) -> NifResult<ResourceArc<SbasStoreResource>> {
    let blocks = parse_rtklib_lines(&text).map_err(|e| Error::Term(Box::new(e.to_string())))?;
    Ok(ResourceArc::new(SbasStoreResource {
        store: ingest_blocks(blocks, max_staleness_s, allow_partial)?,
    }))
}

#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
fn sbas_store_from_messages(
    messages: Vec<(Vec<u8>, String, String, String, u32, f64)>,
    max_staleness_s: f64,
    allow_partial: bool,
) -> NifResult<ResourceArc<SbasStoreResource>> {
    let mut store = SbasCorrectionStore::new()
        .with_policy(StalenessPolicy::seconds(max_staleness_s))
        .allow_partial(allow_partial);
    for (bytes, form, geo, scale, week, tow_s) in messages {
        let (geo, epoch, block) = block_from_terms(&bytes, &form, &geo, scale, week, tow_s)?;
        store
            .ingest(&block.message, geo, epoch)
            .map_err(|e| Error::Term(Box::new(e.to_string())))?;
    }
    Ok(ResourceArc::new(SbasStoreResource { store }))
}

#[rustler::nif]
fn sbas_ready_geos(handle: ResourceArc<SbasStoreResource>, t_j2000_s: f64) -> Vec<String> {
    handle
        .store
        .ready_geos(t_j2000_s)
        .into_iter()
        .map(|sat| sat_to_sbas_prn(sat).map_or_else(|| sat.to_string(), |prn| format!("S{prn}")))
        .collect()
}

#[rustler::nif]
fn sbas_fast<'a>(
    env: Env<'a>,
    handle: ResourceArc<SbasStoreResource>,
    geo_id: String,
    satellite_id: String,
) -> NifResult<Term<'a>> {
    let geo = sbas_geo(&geo_id)?;
    let sat = sat_id(&satellite_id)?;
    Ok(match handle.store.fast(geo, sat) {
        Some(fast) => (
            atoms::ok(),
            SbasFastTerm {
                prc_m: fast.prc_m,
                rrc_m_s: fast.rrc_m_s,
                udrei: i64::from(fast.udrei),
                t_of_j2000_s: fast.t_of_j2000_s,
                iodf: i64::from(fast.iodf),
            },
        )
            .encode(env),
        None => (atoms::error(), atoms::not_found()).encode(env),
    })
}

#[rustler::nif]
fn sbas_long_term<'a>(
    env: Env<'a>,
    handle: ResourceArc<SbasStoreResource>,
    geo_id: String,
    satellite_id: String,
) -> NifResult<Term<'a>> {
    let geo = sbas_geo(&geo_id)?;
    let sat = sat_id(&satellite_id)?;
    Ok(match handle.store.long_term(geo, sat) {
        Some(long) => (
            atoms::ok(),
            SbasLongTerm {
                iode: i64::from(long.iode),
                delta_ecef_m: (
                    long.delta_ecef_m[0],
                    long.delta_ecef_m[1],
                    long.delta_ecef_m[2],
                ),
                delta_ecef_rate_m_s: (
                    long.delta_ecef_rate_m_s[0],
                    long.delta_ecef_rate_m_s[1],
                    long.delta_ecef_rate_m_s[2],
                ),
                delta_af0_s: long.delta_af0_s,
                delta_af1_s_s: long.delta_af1_s_s,
                t0_j2000_s: long.t0_j2000_s,
            },
        )
            .encode(env),
        None => (atoms::error(), atoms::not_found()).encode(env),
    })
}

#[rustler::nif]
fn sbas_iono_grid<'a>(
    env: Env<'a>,
    handle: ResourceArc<SbasStoreResource>,
    geo_id: String,
) -> NifResult<Term<'a>> {
    let geo = sbas_geo(&geo_id)?;
    Ok(match handle.store.iono_grid(geo) {
        Some(grid) => (atoms::ok(), iono_grid_term(grid)).encode(env),
        None => (atoms::error(), atoms::not_found()).encode(env),
    })
}

#[rustler::nif]
fn sbas_geo_nav<'a>(
    env: Env<'a>,
    handle: ResourceArc<SbasStoreResource>,
    geo_id: String,
) -> NifResult<Term<'a>> {
    let geo = sbas_geo(&geo_id)?;
    Ok(match handle.store.geo_nav(geo) {
        Some(nav) => (
            atoms::ok(),
            SbasGeoNavTerm {
                position_ecef_m: (
                    nav.position_ecef_m[0],
                    nav.position_ecef_m[1],
                    nav.position_ecef_m[2],
                ),
                velocity_ecef_m_s: (
                    nav.velocity_ecef_m_s[0],
                    nav.velocity_ecef_m_s[1],
                    nav.velocity_ecef_m_s[2],
                ),
                acceleration_ecef_m_s2: (
                    nav.acceleration_ecef_m_s2[0],
                    nav.acceleration_ecef_m_s2[1],
                    nav.acceleration_ecef_m_s2[2],
                ),
                clock_offset_s: nav.clock_offset_s,
                clock_drift_s_s: nav.clock_drift_s_s,
                t0_j2000_s: nav.t0_j2000_s,
            },
        )
            .encode(env),
        None => (atoms::error(), atoms::not_found()).encode(env),
    })
}

fn corrected_source<'a>(
    broadcast: &'a BroadcastResource,
    store: &'a SbasStoreResource,
    geo: GnssSatelliteId,
    mode: &str,
) -> NifResult<SbasCorrectedEphemeris<'a>> {
    Ok(
        SbasCorrectedEphemeris::new(&broadcast.store, &store.store, geo)
            .with_mode(solve_mode(mode)?),
    )
}

#[rustler::nif]
fn sbas_corrected_position<'a>(
    env: Env<'a>,
    broadcast: ResourceArc<BroadcastResource>,
    store: ResourceArc<SbasStoreResource>,
    geo_id: String,
    satellite_id: String,
    t_j2000_s: f64,
    mode: String,
) -> NifResult<Term<'a>> {
    let geo = sbas_geo(&geo_id)?;
    let sat = sat_id(&satellite_id)?;
    let source = corrected_source(&broadcast, &store, geo, &mode)?;
    Ok(match source.position_clock_at_j2000_s(sat, t_j2000_s) {
        Some((position, clock_s)) => (
            atoms::ok(),
            ((position[0], position[1], position[2]), clock_s),
        )
            .encode(env),
        None => (atoms::error(), atoms::not_found()).encode(env),
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn sbas_sample_broadcast(
    broadcast: ResourceArc<BroadcastResource>,
    store: ResourceArc<SbasStoreResource>,
    geo_id: String,
    satellites: Vec<String>,
    start_j2000_s: f64,
    stop_j2000_s: f64,
    step_s: f64,
    mode: String,
) -> NifResult<Vec<EphemerisSampleRowTerm>> {
    let geo = sbas_geo(&geo_id)?;
    let sats: Vec<GnssSatelliteId> = satellites
        .iter()
        .map(|sat| sat_id(sat))
        .collect::<NifResult<_>>()?;
    let source = corrected_source(&broadcast, &store, geo, &mode)?;
    let rows = ephemeris::sample(&source, &sats, start_j2000_s, stop_j2000_s, step_s)
        .map_err(errors::invalid_input)?;
    Ok(rows.into_iter().map(sample_row).collect())
}

#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
fn sbas_spp_solve_broadcast<'a>(
    env: Env<'a>,
    broadcast: ResourceArc<BroadcastResource>,
    store: ResourceArc<SbasStoreResource>,
    geo_id: String,
    mode: String,
    observations: Vec<(String, f64)>,
    t_rx_j2000_s: f64,
    t_rx_second_of_day_s: f64,
    day_of_year: f64,
    initial_guess: (f64, f64, f64, f64),
    apply_iono: bool,
    apply_tropo: bool,
    alpha: (f64, f64, f64, f64),
    beta: (f64, f64, f64, f64),
    pressure_hpa: f64,
    temperature_k: f64,
    relative_humidity: f64,
    with_geodetic: bool,
    max_pdop: Term<'a>,
    coarse_search_seeds: Term<'a>,
    glonass_channels: Term<'a>,
) -> NifResult<Term<'a>> {
    let geo = sbas_geo(&geo_id)?;
    let source = corrected_source(&broadcast, &store, geo, &mode)?;
    let mut inputs = spp::build_solve_inputs(
        observations,
        t_rx_j2000_s,
        t_rx_second_of_day_s,
        day_of_year,
        initial_guess,
        apply_iono,
        apply_tropo,
        alpha,
        beta,
        pressure_hpa,
        temperature_k,
        relative_humidity,
        None,
    )?;
    inputs.sbas_iono = source.iono_grid().cloned();
    inputs.glonass_channels = spp::decode_glonass_channels(glonass_channels)?;
    let policy = sidereon_core::positioning::SolvePolicy {
        validation: sidereon_core::quality::SolutionValidationOptions {
            max_pdop: if spp::is_nil(max_pdop) {
                None
            } else {
                Some(max_pdop.decode::<f64>()?)
            },
            ..sidereon_core::quality::SolutionValidationOptions::default()
        },
        coarse_search_seeds: if spp::is_nil(coarse_search_seeds) {
            None
        } else {
            let value = coarse_search_seeds.decode::<i64>()?;
            if value < 0 {
                return Err(Error::Term(Box::new(
                    "coarse_search_seeds must be nil or non-negative",
                )));
            }
            Some(value as usize)
        },
    };
    Ok(spp::solve_to_term(
        env,
        &source,
        &inputs,
        with_geodetic,
        policy,
    ))
}
