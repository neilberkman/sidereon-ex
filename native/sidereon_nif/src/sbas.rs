use rustler::{Encoder, Env, Error, NifResult, ResourceArc, Term};
use sidereon_core::astro::time::model::{GnssWeekTow, TimeScale};
use sidereon_core::ephemeris::{self, EphemerisSampleStatus, EphemerisSource};
use sidereon_core::sbas::{
    parse_ems_lines, parse_rtklib_lines, sat_to_sbas_prn, sbas_prn_to_sat, SbasBlock,
    SbasCorrectedEphemeris, SbasCorrectionStore, SbasIonoDelays, SbasIonoGrid, SbasLogBlock,
    SbasLongTermHalf, SbasMessage, SbasMixedFastCorrections, SbasSolveMode, SbasWireForm,
    SpareBits,
};
use sidereon_core::sbas_pl::{
    sbas_protection_levels, AirborneModel, DegradationParams, ProtectionGeometry, SbasErrorModel,
    SbasKMultipliers, SbasPlError, SbasProtection, SbasSisError as SbasPlSisError,
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
type SbasPlKTerm = (f64, f64);
type SbasPlSisTerm = (String, f64, f64, f64, f64);
type SbasPlAirborneTerm = f64;
type SbasPlDegradationTerm = (f64, f64, f64, f64, f64, f64, bool);

mod atoms {
    rustler::atoms! {
        ok,
        error,
        invalid_input,
        not_found,
        insufficient_geometry,
        numerical_failure,
        invalid_error_model
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
    payload: SbasPayloadTerm,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct SbasPayloadTerm {
    data: Option<Vec<u8>>,
    iodp: Option<i64>,
    iodf: Option<i64>,
    iodf_by_block: Option<Vec<i64>>,
    mask: Option<Vec<bool>>,
    prc: Option<Vec<i64>>,
    udrei: Option<Vec<i64>>,
    system_latency_s: Option<i64>,
    ai: Option<Vec<i64>>,
    time_of_day_s: Option<i64>,
    ura: Option<i64>,
    x_m: Option<i64>,
    y_m: Option<i64>,
    z_m: Option<i64>,
    x_rate_m_s: Option<i64>,
    y_rate_m_s: Option<i64>,
    z_rate_m_s: Option<i64>,
    x_accel_m_s2: Option<i64>,
    y_accel_m_s2: Option<i64>,
    z_accel_m_s2: Option<i64>,
    a_gf0_s: Option<i64>,
    a_gf1_s_s: Option<i64>,
    band_number: Option<i64>,
    block_id: Option<i64>,
    iodi: Option<i64>,
    mixed_fast: Option<SbasMixedFastTerm>,
    long_term: Option<SbasLongHalfTerm>,
    halves: Option<Vec<SbasLongHalfTerm>>,
    entries: Option<Vec<SbasIgpDelayTerm>>,
    reserved: Vec<(i64, i64)>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct SbasMixedFastTerm {
    iodf: i64,
    iodp: i64,
    block_id: i64,
    prc: Vec<i64>,
    udrei: Vec<i64>,
    reserved: Vec<(i64, i64)>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct SbasLongHalfTerm {
    velocity_code: bool,
    iodp: i64,
    records: Vec<SbasLongRecordTerm>,
    reserved: Vec<(i64, i64)>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct SbasLongRecordTerm {
    monitored_index: i64,
    iode: i64,
    delta_x: i64,
    delta_y: i64,
    delta_z: i64,
    delta_x_rate: i64,
    delta_y_rate: i64,
    delta_z_rate: i64,
    delta_a_f0: i64,
    delta_a_f1: i64,
    time_of_day_s: Option<i64>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct SbasIgpDelayTerm {
    vertical_delay: i64,
    givei: i64,
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

#[derive(Debug, Clone, rustler::NifMap)]
struct SbasPlProtectionTerm {
    hpl_m: f64,
    vpl_m: f64,
    d_major_m: f64,
    sigma_u_m: f64,
    d_east_m: f64,
    d_north_m: f64,
    d_en_m2: f64,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct SbasPlSisTermOut {
    id: String,
    sigma_flt_m: f64,
    sigma_uire_m: f64,
    sigma_air_m: f64,
    sigma_tropo_m: f64,
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

fn sbas_pl_k((k_h, k_v): SbasPlKTerm) -> SbasKMultipliers {
    SbasKMultipliers { k_h, k_v }
}

fn sbas_pl_k_term(k: SbasKMultipliers) -> SbasPlKTerm {
    (k.k_h, k.k_v)
}

fn sbas_pl_airborne(sigma_noise_divergence_m: SbasPlAirborneTerm) -> AirborneModel {
    AirborneModel::new(sigma_noise_divergence_m)
}

fn sbas_pl_degradation(
    (
        delta_udre,
        eps_fc_m,
        eps_rrc_m,
        eps_ltc_m,
        eps_er_m,
        eps_iono_m,
        rss_udre,
    ): SbasPlDegradationTerm,
) -> DegradationParams {
    DegradationParams {
        delta_udre,
        eps_fc_m,
        eps_rrc_m,
        eps_ltc_m,
        eps_er_m,
        eps_iono_m,
        rss_udre,
    }
}

fn sbas_pl_degradation_term(value: DegradationParams) -> SbasPlDegradationTerm {
    (
        value.delta_udre,
        value.eps_fc_m,
        value.eps_rrc_m,
        value.eps_ltc_m,
        value.eps_er_m,
        value.eps_iono_m,
        value.rss_udre,
    )
}

fn sbas_pl_geometry(
    rows: Vec<crate::araim::RowTerm>,
    receiver: crate::araim::ReceiverTerm,
    clock_systems: Vec<String>,
) -> NifResult<ProtectionGeometry> {
    Ok(ProtectionGeometry {
        rows: rows
            .into_iter()
            .map(crate::araim::decode_row)
            .collect::<NifResult<_>>()?,
        receiver: crate::araim::decode_receiver(receiver)?,
        clock_systems: clock_systems
            .iter()
            .map(|system| crate::araim::system_from_term(system))
            .collect::<NifResult<_>>()?,
    })
}

fn sbas_pl_sis(
    (id, sigma_flt_m, sigma_uire_m, sigma_air_m, sigma_tropo_m): SbasPlSisTerm,
) -> NifResult<SbasPlSisError> {
    Ok(SbasPlSisError {
        id: sat_id(&id)?,
        sigma_flt_m,
        sigma_uire_m,
        sigma_air_m,
        sigma_tropo_m,
    })
}

fn sbas_pl_sis_term(value: SbasPlSisError) -> SbasPlSisTermOut {
    SbasPlSisTermOut {
        id: value.id.to_string(),
        sigma_flt_m: value.sigma_flt_m,
        sigma_uire_m: value.sigma_uire_m,
        sigma_air_m: value.sigma_air_m,
        sigma_tropo_m: value.sigma_tropo_m,
    }
}

fn sbas_pl_error_model(rows: Vec<SbasPlSisTerm>) -> NifResult<SbasErrorModel> {
    Ok(SbasErrorModel::new(
        rows.into_iter()
            .map(sbas_pl_sis)
            .collect::<NifResult<_>>()?,
    ))
}

fn sbas_pl_protection_term(value: SbasProtection) -> SbasPlProtectionTerm {
    SbasPlProtectionTerm {
        hpl_m: value.hpl_m,
        vpl_m: value.vpl_m,
        d_major_m: value.d_major_m,
        sigma_u_m: value.sigma_u_m,
        d_east_m: value.d_east_m,
        d_north_m: value.d_north_m,
        d_en_m2: value.d_en_m2,
    }
}

fn sbas_pl_error_atom(error: SbasPlError) -> rustler::Atom {
    match error {
        SbasPlError::InsufficientGeometry => atoms::insufficient_geometry(),
        SbasPlError::NumericalFailure => atoms::numerical_failure(),
        SbasPlError::InvalidErrorModel => atoms::invalid_error_model(),
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

fn spare_bits(bits: &SpareBits) -> Vec<(i64, i64)> {
    bits.0
        .iter()
        .map(|&(value, width)| (value as i64, i64::from(width)))
        .collect()
}

fn i16_vec<const N: usize>(values: &[i16; N]) -> Vec<i64> {
    values.iter().map(|&value| i64::from(value)).collect()
}

fn u8_vec<const N: usize>(values: &[u8; N]) -> Vec<i64> {
    values.iter().map(|&value| i64::from(value)).collect()
}

fn long_record_term(record: &sidereon_core::sbas::SbasLongTermRecord) -> SbasLongRecordTerm {
    SbasLongRecordTerm {
        monitored_index: i64::from(record.monitored_index),
        iode: i64::from(record.iode),
        delta_x: i64::from(record.delta_x),
        delta_y: i64::from(record.delta_y),
        delta_z: i64::from(record.delta_z),
        delta_x_rate: i64::from(record.delta_x_rate),
        delta_y_rate: i64::from(record.delta_y_rate),
        delta_z_rate: i64::from(record.delta_z_rate),
        delta_a_f0: i64::from(record.delta_a_f0),
        delta_a_f1: i64::from(record.delta_a_f1),
        time_of_day_s: record.time_of_day_s.map(i64::from),
    }
}

fn long_half_term(half: &SbasLongTermHalf) -> SbasLongHalfTerm {
    SbasLongHalfTerm {
        velocity_code: half.velocity_code,
        iodp: i64::from(half.iodp),
        records: half.records.iter().map(long_record_term).collect(),
        reserved: spare_bits(&half.reserved),
    }
}

fn mixed_fast_term(fast: &SbasMixedFastCorrections) -> SbasMixedFastTerm {
    SbasMixedFastTerm {
        iodf: i64::from(fast.iodf),
        iodp: i64::from(fast.iodp),
        block_id: i64::from(fast.block_id),
        prc: i16_vec(&fast.prc),
        udrei: u8_vec(&fast.udrei),
        reserved: spare_bits(&fast.reserved),
    }
}

fn igp_delay_terms(delays: &SbasIonoDelays) -> Vec<SbasIgpDelayTerm> {
    delays
        .entries
        .iter()
        .map(|entry| SbasIgpDelayTerm {
            vertical_delay: i64::from(entry.vertical_delay),
            givei: i64::from(entry.givei),
        })
        .collect()
}

fn empty_payload() -> SbasPayloadTerm {
    SbasPayloadTerm {
        data: None,
        iodp: None,
        iodf: None,
        iodf_by_block: None,
        mask: None,
        prc: None,
        udrei: None,
        system_latency_s: None,
        ai: None,
        time_of_day_s: None,
        ura: None,
        x_m: None,
        y_m: None,
        z_m: None,
        x_rate_m_s: None,
        y_rate_m_s: None,
        z_rate_m_s: None,
        x_accel_m_s2: None,
        y_accel_m_s2: None,
        z_accel_m_s2: None,
        a_gf0_s: None,
        a_gf1_s_s: None,
        band_number: None,
        block_id: None,
        iodi: None,
        mixed_fast: None,
        long_term: None,
        halves: None,
        entries: None,
        reserved: Vec::new(),
    }
}

fn message_payload(message: &SbasMessage) -> SbasPayloadTerm {
    let mut payload = empty_payload();
    match message {
        SbasMessage::DoNotUse(m) => {
            payload.data = Some(m.data.clone());
        }
        SbasMessage::PrnMask(m) => {
            payload.iodp = Some(i64::from(m.iodp));
            payload.mask = Some(m.mask.to_vec());
            payload.reserved = spare_bits(&m.reserved);
        }
        SbasMessage::FastCorrections(m) => {
            payload.iodf = Some(i64::from(m.iodf));
            payload.iodp = Some(i64::from(m.iodp));
            payload.prc = Some(i16_vec(&m.prc));
            payload.udrei = Some(u8_vec(&m.udrei));
            payload.reserved = spare_bits(&m.reserved);
        }
        SbasMessage::Integrity(m) => {
            payload.iodf_by_block = Some(u8_vec(&m.iodf));
            payload.udrei = Some(u8_vec(&m.udrei));
            payload.reserved = spare_bits(&m.reserved);
        }
        SbasMessage::FastDegradation(m) => {
            payload.system_latency_s = Some(i64::from(m.system_latency_s));
            payload.iodp = Some(i64::from(m.iodp));
            payload.ai = Some(u8_vec(&m.ai));
            payload.reserved = spare_bits(&m.reserved);
        }
        SbasMessage::GeoNav(m) => {
            payload.time_of_day_s = Some(i64::from(m.time_of_day_s));
            payload.ura = Some(i64::from(m.ura));
            payload.x_m = Some(i64::from(m.x_m));
            payload.y_m = Some(i64::from(m.y_m));
            payload.z_m = Some(i64::from(m.z_m));
            payload.x_rate_m_s = Some(i64::from(m.x_rate_m_s));
            payload.y_rate_m_s = Some(i64::from(m.y_rate_m_s));
            payload.z_rate_m_s = Some(i64::from(m.z_rate_m_s));
            payload.x_accel_m_s2 = Some(i64::from(m.x_accel_m_s2));
            payload.y_accel_m_s2 = Some(i64::from(m.y_accel_m_s2));
            payload.z_accel_m_s2 = Some(i64::from(m.z_accel_m_s2));
            payload.a_gf0_s = Some(i64::from(m.a_gf0_s));
            payload.a_gf1_s_s = Some(i64::from(m.a_gf1_s_s));
            payload.reserved = spare_bits(&m.reserved);
        }
        SbasMessage::NetworkTime(m) => {
            payload.data = Some(m.data.clone());
        }
        SbasMessage::GeoAlmanac(m) => {
            payload.data = Some(m.data.clone());
        }
        SbasMessage::IgpMask(m) => {
            payload.band_number = Some(i64::from(m.band_number));
            payload.iodi = Some(i64::from(m.iodi));
            payload.mask = Some(m.mask.to_vec());
            payload.reserved = spare_bits(&m.reserved);
        }
        SbasMessage::MixedCorrections(m) => {
            payload.mixed_fast = Some(mixed_fast_term(&m.fast));
            payload.long_term = Some(long_half_term(&m.long_term));
        }
        SbasMessage::LongTermCorrections(m) => {
            payload.halves = Some(m.halves.iter().map(long_half_term).collect());
        }
        SbasMessage::IonoDelays(m) => {
            payload.band_number = Some(i64::from(m.band_number));
            payload.block_id = Some(i64::from(m.block_id));
            payload.iodi = Some(i64::from(m.iodi));
            payload.entries = Some(igp_delay_terms(m));
            payload.reserved = spare_bits(&m.reserved);
        }
        SbasMessage::Unsupported(m) => {
            payload.data = Some(m.data.clone());
        }
    }
    payload
}

fn message_term(message: &SbasMessage) -> SbasMessageTerm {
    SbasMessageTerm {
        kind: message_kind(message).to_string(),
        message_type: i64::from(message.message_type()),
        preamble: i64::from(message_preamble(message)),
        details: format!("{message:?}"),
        payload: message_payload(message),
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
fn sbas_pl_k_precision_approach() -> SbasPlKTerm {
    sbas_pl_k_term(SbasKMultipliers::PRECISION_APPROACH)
}

#[rustler::nif]
fn sbas_pl_k_en_route_npa() -> SbasPlKTerm {
    sbas_pl_k_term(SbasKMultipliers::EN_ROUTE_NPA)
}

#[rustler::nif]
fn sbas_pl_airborne_aad_a() -> SbasPlAirborneTerm {
    AirborneModel::aad_a().sigma_noise_divergence_m
}

#[rustler::nif]
fn sbas_pl_degradation_none() -> SbasPlDegradationTerm {
    sbas_pl_degradation_term(DegradationParams::none())
}

#[rustler::nif(schedule = "DirtyCpu")]
fn sbas_pl_protection_levels<'a>(
    env: Env<'a>,
    rows: Vec<crate::araim::RowTerm>,
    receiver: crate::araim::ReceiverTerm,
    clock_systems: Vec<String>,
    error_rows: Vec<SbasPlSisTerm>,
    k: SbasPlKTerm,
) -> NifResult<Term<'a>> {
    let geometry = sbas_pl_geometry(rows, receiver, clock_systems)?;
    let model = sbas_pl_error_model(error_rows)?;
    Ok(
        match sbas_protection_levels(&geometry, &model, sbas_pl_k(k)) {
            Ok(value) => (atoms::ok(), sbas_pl_protection_term(value)).encode(env),
            Err(error) => (atoms::error(), sbas_pl_error_atom(error)).encode(env),
        },
    )
}

#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
fn sbas_pl_error_model_from_store<'a>(
    env: Env<'a>,
    store: ResourceArc<SbasStoreResource>,
    geo_id: String,
    rows: Vec<crate::araim::RowTerm>,
    receiver: crate::araim::ReceiverTerm,
    clock_systems: Vec<String>,
    airborne: SbasPlAirborneTerm,
    epoch_j2000_s: f64,
    degradation: SbasPlDegradationTerm,
) -> NifResult<Term<'a>> {
    let geometry = sbas_pl_geometry(rows, receiver, clock_systems)?;
    let geo = sbas_geo(&geo_id)?;
    let airborne = sbas_pl_airborne(airborne);
    let degradation = sbas_pl_degradation(degradation);
    Ok(
        match SbasErrorModel::from_store(
            &store.store,
            geo,
            &geometry,
            &airborne,
            epoch_j2000_s,
            &degradation,
        ) {
            Ok(model) => (
                atoms::ok(),
                model
                    .rows
                    .into_iter()
                    .map(sbas_pl_sis_term)
                    .collect::<Vec<_>>(),
            )
                .encode(env),
            Err(error) => (atoms::error(), sbas_pl_error_atom(error)).encode(env),
        },
    )
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
#[allow(clippy::too_many_arguments)]
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
