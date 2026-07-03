//! Rustler boundary for NMEA 0183 parsing, epoch accumulation, and GGA writing.
//!
//! The core owns checksums, field validation, stream buffering, epoch grouping,
//! and formatting. This module only maps core structs to BEAM maps and keeps the
//! accumulator as a resource between chunk calls.

use rustler::{Binary, Encoder, Env, ResourceArc, Term};
use sidereon_core::nmea::{
    group_epochs, parse_nmea_str, parse_sentence, write_gga, Diagnostics, EpochSnapshot, Gga,
    GgaQuality, Gll, Gsa, GsaEntry, GsaFixMode, GsaSelectionMode, Gst, Gsv, GsvGroup, GsvSatellite,
    NmeaAccumulator, NmeaBody, NmeaChunkOutput, NmeaCoordinate, NmeaDate, NmeaError, NmeaSatNumber,
    NmeaSentence, NmeaSignalId, NmeaTalker, NmeaTime, RecordRef, Rmc, RmcStatus, SkipReason, Vtg,
    WarningKind, Zda,
};
use sidereon_core::GnssSystem;
use std::sync::Mutex;

mod atoms {
    rustler::atoms! {
        ok,
        error
    }
}

pub struct NmeaAccumulatorResource {
    pub accumulator: Mutex<NmeaAccumulator>,
}

#[rustler::resource_impl]
impl rustler::Resource for NmeaAccumulatorResource {}

#[derive(Debug, Clone, rustler::NifMap)]
struct RecordRefTerm {
    line: Option<i64>,
    record_index: Option<i64>,
    satellite: Option<String>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct SkipTerm {
    at: RecordRefTerm,
    reason: String,
    detail: Option<String>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct WarningTerm {
    at: RecordRefTerm,
    kind: String,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct DiagnosticsTerm {
    skips: Vec<SkipTerm>,
    warnings: Vec<WarningTerm>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct TimeTerm {
    hour: i64,
    minute: i64,
    second: i64,
    nanos: i64,
    decimals: i64,
    seconds_of_day: f64,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct DateTerm {
    year: i64,
    month: i64,
    day: i64,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct CoordinateTerm {
    degrees: i64,
    minutes_scaled: i64,
    decimals: i64,
    negative: bool,
    degrees_float: f64,
    radians: f64,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct SatNumberTerm {
    raw: i64,
    satellite_id: Option<String>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct SignalTerm {
    system: Option<String>,
    id: i64,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct GgaTerm {
    time: Option<TimeTerm>,
    latitude: Option<CoordinateTerm>,
    longitude: Option<CoordinateTerm>,
    quality: Option<i64>,
    satellites_used: Option<i64>,
    hdop: Option<f64>,
    altitude_msl_m: Option<f64>,
    geoid_separation_m: Option<f64>,
    differential_age_s: Option<f64>,
    differential_station_id: Option<i64>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct RmcTerm {
    time: Option<TimeTerm>,
    status: Option<String>,
    latitude: Option<CoordinateTerm>,
    longitude: Option<CoordinateTerm>,
    speed_over_ground_kn: Option<f64>,
    course_over_ground_deg: Option<f64>,
    date: Option<DateTerm>,
    magnetic_variation_deg: Option<f64>,
    faa_mode: Option<String>,
    navigational_status: Option<String>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct GsaTerm {
    selection_mode: Option<String>,
    fix_mode: Option<String>,
    satellites: Vec<SatNumberTerm>,
    pdop: Option<f64>,
    hdop: Option<f64>,
    vdop: Option<f64>,
    system_id: Option<i64>,
    system: Option<String>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct GsvSatelliteTerm {
    sat_number: Option<SatNumberTerm>,
    elevation_deg: Option<i64>,
    azimuth_deg: Option<i64>,
    cn0_db_hz: Option<i64>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct GsvTerm {
    total_messages: i64,
    message_number: i64,
    satellites_in_view: Option<i64>,
    satellites: Vec<GsvSatelliteTerm>,
    signal: Option<SignalTerm>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct GstTerm {
    time: Option<TimeTerm>,
    rms_range_residual_m: Option<f64>,
    semi_major_error_m: Option<f64>,
    semi_minor_error_m: Option<f64>,
    orientation_deg: Option<f64>,
    latitude_sigma_m: Option<f64>,
    longitude_sigma_m: Option<f64>,
    altitude_sigma_m: Option<f64>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct VtgTerm {
    course_true_deg: Option<f64>,
    course_magnetic_deg: Option<f64>,
    speed_kn: Option<f64>,
    speed_kmh: Option<f64>,
    faa_mode: Option<String>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct GllTerm {
    latitude: Option<CoordinateTerm>,
    longitude: Option<CoordinateTerm>,
    time: Option<TimeTerm>,
    status: Option<String>,
    faa_mode: Option<String>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct ZdaTerm {
    time: Option<TimeTerm>,
    date: Option<DateTerm>,
    local_zone_hours: Option<i64>,
    local_zone_minutes: Option<i64>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct SentenceTerm {
    talker: String,
    system: Option<String>,
    kind: String,
    gga: Option<GgaTerm>,
    rmc: Option<RmcTerm>,
    gsa: Option<GsaTerm>,
    gsv: Option<GsvTerm>,
    gst: Option<GstTerm>,
    vtg: Option<VtgTerm>,
    gll: Option<GllTerm>,
    zda: Option<ZdaTerm>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct GsaEntryTerm {
    system: Option<String>,
    gsa: GsaTerm,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct GsvGroupTerm {
    talker: String,
    system: Option<String>,
    signal: Option<SignalTerm>,
    claimed_in_view: Option<i64>,
    satellites: Vec<GsvSatelliteTerm>,
    complete: bool,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct SnapshotTerm {
    time_of_day: Option<TimeTerm>,
    date: Option<DateTerm>,
    gga: Option<GgaTerm>,
    rmc: Option<RmcTerm>,
    gll: Option<GllTerm>,
    gst: Option<GstTerm>,
    vtg: Option<VtgTerm>,
    zda: Option<ZdaTerm>,
    gsa: Vec<GsaEntryTerm>,
    gsv: Vec<GsvGroupTerm>,
    sentence_count: i64,
    diagnostics: DiagnosticsTerm,
    position_geodetic: Option<(f64, f64, f64)>,
    pdop: Option<f64>,
    hdop: Option<f64>,
    vdop: Option<f64>,
    used_satellites: Vec<SatNumberTerm>,
    satellites_in_view: i64,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct ParsedSentenceTerm {
    sentence: SentenceTerm,
    diagnostics: DiagnosticsTerm,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct ParsedLogTerm {
    sentences: Vec<SentenceTerm>,
    diagnostics: DiagnosticsTerm,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct EpochLogTerm {
    sentences: Vec<SentenceTerm>,
    epochs: Vec<SnapshotTerm>,
    diagnostics: DiagnosticsTerm,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct ChunkOutputTerm {
    snapshots: Vec<SnapshotTerm>,
    sentences: Vec<SentenceTerm>,
    diagnostics: DiagnosticsTerm,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct GgaWriteTerm {
    talker: String,
    time_seconds_of_day: Option<f64>,
    latitude_deg: Option<f64>,
    longitude_deg: Option<f64>,
    coordinate_decimals: i64,
    quality: Option<i64>,
    satellites_used: Option<i64>,
    hdop: Option<f64>,
    altitude_msl_m: Option<f64>,
    geoid_separation_m: Option<f64>,
    differential_age_s: Option<f64>,
    differential_station_id: Option<i64>,
}

fn record_ref_term(at: RecordRef) -> RecordRefTerm {
    RecordRefTerm {
        line: at.line.map(|value| value as i64),
        record_index: at.record_index.map(|value| value as i64),
        satellite: at.satellite,
    }
}

fn skip_reason(reason: SkipReason) -> (String, Option<String>) {
    match reason {
        SkipReason::UnrepresentableSatellite => ("unrepresentable_satellite".to_string(), None),
        SkipReason::UnsupportedRecordType(kind) => (
            "unsupported_record_type".to_string(),
            Some(kind.to_string()),
        ),
        SkipReason::MalformedField(error) => (
            "malformed_field".to_string(),
            Some(format!("{}: {}", error.field(), error.reason())),
        ),
        SkipReason::OutOfRangeEpoch => ("out_of_range_epoch".to_string(), None),
        SkipReason::Truncated => ("truncated".to_string(), None),
        SkipReason::UnsupportedUnit(unit) => {
            ("unsupported_unit".to_string(), Some(unit.to_string()))
        }
        SkipReason::UnknownBlock(block) => ("unknown_block".to_string(), Some(block)),
        SkipReason::InconsistentRecord(reason) => {
            ("inconsistent_record".to_string(), Some(reason.to_string()))
        }
    }
}

fn warning_kind(kind: WarningKind) -> String {
    match kind {
        WarningKind::Checksum => "checksum",
        WarningKind::Clamped => "clamped",
        WarningKind::Degraded => "degraded",
        WarningKind::Mismatch => "mismatch",
        WarningKind::Overlap => "overlap",
        WarningKind::MissingMetadata => "missing_metadata",
    }
    .to_string()
}

fn diagnostics_term(diagnostics: Diagnostics) -> DiagnosticsTerm {
    DiagnosticsTerm {
        skips: diagnostics
            .skips
            .into_iter()
            .map(|skip| {
                let (reason, detail) = skip_reason(skip.reason);
                SkipTerm {
                    at: record_ref_term(skip.at),
                    reason,
                    detail,
                }
            })
            .collect(),
        warnings: diagnostics
            .warnings
            .into_iter()
            .map(|warning| WarningTerm {
                at: record_ref_term(warning.at),
                kind: warning_kind(warning.kind),
            })
            .collect(),
    }
}

fn system_term(system: GnssSystem) -> String {
    system.letter().to_string()
}

fn talker_term(talker: NmeaTalker) -> String {
    talker
        .code()
        .map(|code| String::from_utf8_lossy(&code).into_owned())
        .unwrap_or_else(|_| "??".to_string())
}

fn time_term(time: NmeaTime) -> TimeTerm {
    let seconds_of_day = f64::from(time.hour) * 3600.0
        + f64::from(time.minute) * 60.0
        + f64::from(time.second)
        + f64::from(time.nanos) * 1.0e-9;
    TimeTerm {
        hour: i64::from(time.hour),
        minute: i64::from(time.minute),
        second: i64::from(time.second),
        nanos: i64::from(time.nanos),
        decimals: i64::from(time.decimals),
        seconds_of_day,
    }
}

fn date_term(date: NmeaDate) -> DateTerm {
    DateTerm {
        year: i64::from(date.year),
        month: i64::from(date.month),
        day: i64::from(date.day),
    }
}

fn coordinate_term(coordinate: NmeaCoordinate) -> CoordinateTerm {
    CoordinateTerm {
        degrees: i64::from(coordinate.degrees),
        minutes_scaled: coordinate.minutes_scaled as i64,
        decimals: i64::from(coordinate.decimals),
        negative: coordinate.negative,
        degrees_float: coordinate.degrees_f64(),
        radians: coordinate.radians(),
    }
}

fn sat_number_term(sat: NmeaSatNumber) -> SatNumberTerm {
    SatNumberTerm {
        raw: i64::from(sat.raw),
        satellite_id: sat.resolved.map(|id| id.to_string()),
    }
}

fn signal_term(signal: NmeaSignalId) -> SignalTerm {
    SignalTerm {
        system: signal.system.map(system_term),
        id: i64::from(signal.id),
    }
}

fn char_term(value: char) -> String {
    value.to_string()
}

fn rmc_status(status: RmcStatus) -> String {
    match status {
        RmcStatus::Valid => "valid".to_string(),
        RmcStatus::Warning => "warning".to_string(),
        RmcStatus::Other(value) => format!("other:{value}"),
    }
}

fn gsa_selection_mode(mode: GsaSelectionMode) -> String {
    match mode {
        GsaSelectionMode::Manual => "manual".to_string(),
        GsaSelectionMode::Automatic => "automatic".to_string(),
        GsaSelectionMode::Other(value) => format!("other:{value}"),
    }
}

fn gsa_fix_mode(mode: GsaFixMode) -> String {
    match mode {
        GsaFixMode::None => "none".to_string(),
        GsaFixMode::TwoD => "two_d".to_string(),
        GsaFixMode::ThreeD => "three_d".to_string(),
        GsaFixMode::Other(value) => format!("other:{value}"),
    }
}

fn gga_term(gga: Gga) -> GgaTerm {
    GgaTerm {
        time: gga.time.map(time_term),
        latitude: gga.latitude.map(coordinate_term),
        longitude: gga.longitude.map(coordinate_term),
        quality: gga.quality.map(|quality| i64::from(quality.value())),
        satellites_used: gga.satellites_used.map(i64::from),
        hdop: gga.hdop,
        altitude_msl_m: gga.altitude_msl_m,
        geoid_separation_m: gga.geoid_separation_m,
        differential_age_s: gga.differential_age_s,
        differential_station_id: gga.differential_station_id.map(i64::from),
    }
}

fn rmc_term(rmc: Rmc) -> RmcTerm {
    RmcTerm {
        time: rmc.time.map(time_term),
        status: rmc.status.map(rmc_status),
        latitude: rmc.latitude.map(coordinate_term),
        longitude: rmc.longitude.map(coordinate_term),
        speed_over_ground_kn: rmc.speed_over_ground_kn,
        course_over_ground_deg: rmc.course_over_ground_deg,
        date: rmc.date.map(date_term),
        magnetic_variation_deg: rmc.magnetic_variation_deg,
        faa_mode: rmc.faa_mode.map(char_term),
        navigational_status: rmc.navigational_status.map(char_term),
    }
}

fn gsa_term(gsa: Gsa) -> GsaTerm {
    GsaTerm {
        selection_mode: gsa.selection_mode.map(gsa_selection_mode),
        fix_mode: gsa.fix_mode.map(gsa_fix_mode),
        satellites: gsa.satellites.into_iter().map(sat_number_term).collect(),
        pdop: gsa.pdop,
        hdop: gsa.hdop,
        vdop: gsa.vdop,
        system_id: gsa.system_id.map(i64::from),
        system: gsa.system.map(system_term),
    }
}

fn gsv_satellite_term(satellite: GsvSatellite) -> GsvSatelliteTerm {
    GsvSatelliteTerm {
        sat_number: satellite.sat_number.map(sat_number_term),
        elevation_deg: satellite.elevation_deg.map(i64::from),
        azimuth_deg: satellite.azimuth_deg.map(i64::from),
        cn0_db_hz: satellite.cn0_db_hz.map(i64::from),
    }
}

fn gsv_term(gsv: Gsv) -> GsvTerm {
    GsvTerm {
        total_messages: i64::from(gsv.total_messages),
        message_number: i64::from(gsv.message_number),
        satellites_in_view: gsv.satellites_in_view.map(i64::from),
        satellites: gsv.satellites.into_iter().map(gsv_satellite_term).collect(),
        signal: gsv.signal.map(signal_term),
    }
}

fn gst_term(gst: Gst) -> GstTerm {
    GstTerm {
        time: gst.time.map(time_term),
        rms_range_residual_m: gst.rms_range_residual_m,
        semi_major_error_m: gst.semi_major_error_m,
        semi_minor_error_m: gst.semi_minor_error_m,
        orientation_deg: gst.orientation_deg,
        latitude_sigma_m: gst.latitude_sigma_m,
        longitude_sigma_m: gst.longitude_sigma_m,
        altitude_sigma_m: gst.altitude_sigma_m,
    }
}

fn vtg_term(vtg: Vtg) -> VtgTerm {
    VtgTerm {
        course_true_deg: vtg.course_true_deg,
        course_magnetic_deg: vtg.course_magnetic_deg,
        speed_kn: vtg.speed_kn,
        speed_kmh: vtg.speed_kmh,
        faa_mode: vtg.faa_mode.map(char_term),
    }
}

fn gll_term(gll: Gll) -> GllTerm {
    GllTerm {
        latitude: gll.latitude.map(coordinate_term),
        longitude: gll.longitude.map(coordinate_term),
        time: gll.time.map(time_term),
        status: gll.status.map(rmc_status),
        faa_mode: gll.faa_mode.map(char_term),
    }
}

fn zda_term(zda: Zda) -> ZdaTerm {
    ZdaTerm {
        time: zda.time.map(time_term),
        date: zda.date.map(date_term),
        local_zone_hours: zda.local_zone_hours.map(i64::from),
        local_zone_minutes: zda.local_zone_minutes.map(i64::from),
    }
}

fn sentence_term(sentence: NmeaSentence) -> SentenceTerm {
    let talker = sentence.talker;
    let system = talker.system().map(system_term);
    match sentence.body {
        NmeaBody::Gga(gga) => SentenceTerm {
            talker: talker_term(talker),
            system,
            kind: "gga".to_string(),
            gga: Some(gga_term(gga)),
            rmc: None,
            gsa: None,
            gsv: None,
            gst: None,
            vtg: None,
            gll: None,
            zda: None,
        },
        NmeaBody::Rmc(rmc) => SentenceTerm {
            talker: talker_term(talker),
            system,
            kind: "rmc".to_string(),
            gga: None,
            rmc: Some(rmc_term(rmc)),
            gsa: None,
            gsv: None,
            gst: None,
            vtg: None,
            gll: None,
            zda: None,
        },
        NmeaBody::Gsa(gsa) => SentenceTerm {
            talker: talker_term(talker),
            system,
            kind: "gsa".to_string(),
            gga: None,
            rmc: None,
            gsa: Some(gsa_term(gsa)),
            gsv: None,
            gst: None,
            vtg: None,
            gll: None,
            zda: None,
        },
        NmeaBody::Gsv(gsv) => SentenceTerm {
            talker: talker_term(talker),
            system,
            kind: "gsv".to_string(),
            gga: None,
            rmc: None,
            gsa: None,
            gsv: Some(gsv_term(gsv)),
            gst: None,
            vtg: None,
            gll: None,
            zda: None,
        },
        NmeaBody::Gst(gst) => SentenceTerm {
            talker: talker_term(talker),
            system,
            kind: "gst".to_string(),
            gga: None,
            rmc: None,
            gsa: None,
            gsv: None,
            gst: Some(gst_term(gst)),
            vtg: None,
            gll: None,
            zda: None,
        },
        NmeaBody::Vtg(vtg) => SentenceTerm {
            talker: talker_term(talker),
            system,
            kind: "vtg".to_string(),
            gga: None,
            rmc: None,
            gsa: None,
            gsv: None,
            gst: None,
            vtg: Some(vtg_term(vtg)),
            gll: None,
            zda: None,
        },
        NmeaBody::Gll(gll) => SentenceTerm {
            talker: talker_term(talker),
            system,
            kind: "gll".to_string(),
            gga: None,
            rmc: None,
            gsa: None,
            gsv: None,
            gst: None,
            vtg: None,
            gll: Some(gll_term(gll)),
            zda: None,
        },
        NmeaBody::Zda(zda) => SentenceTerm {
            talker: talker_term(talker),
            system,
            kind: "zda".to_string(),
            gga: None,
            rmc: None,
            gsa: None,
            gsv: None,
            gst: None,
            vtg: None,
            gll: None,
            zda: Some(zda_term(zda)),
        },
    }
}

fn gsa_entry_term(entry: GsaEntry) -> GsaEntryTerm {
    GsaEntryTerm {
        system: entry.system.map(system_term),
        gsa: gsa_term(entry.gsa),
    }
}

fn gsv_group_term(group: GsvGroup) -> GsvGroupTerm {
    GsvGroupTerm {
        talker: talker_term(group.talker),
        system: group.talker.system().map(system_term),
        signal: group.signal.map(signal_term),
        claimed_in_view: group.claimed_in_view.map(i64::from),
        satellites: group
            .satellites
            .into_iter()
            .map(gsv_satellite_term)
            .collect(),
        complete: group.complete,
    }
}

fn snapshot_term(snapshot: EpochSnapshot) -> SnapshotTerm {
    let position_geodetic = snapshot
        .position()
        .map(|position| (position.lat_rad, position.lon_rad, position.height_m));
    let pdop = snapshot.pdop();
    let hdop = snapshot.hdop();
    let vdop = snapshot.vdop();
    let used_satellites = snapshot
        .used_satellites()
        .copied()
        .map(sat_number_term)
        .collect();
    let satellites_in_view = snapshot.satellites_in_view() as i64;

    SnapshotTerm {
        time_of_day: snapshot.time_of_day.map(time_term),
        date: snapshot.date.map(date_term),
        gga: snapshot.gga.map(gga_term),
        rmc: snapshot.rmc.map(rmc_term),
        gll: snapshot.gll.map(gll_term),
        gst: snapshot.gst.map(gst_term),
        vtg: snapshot.vtg.map(vtg_term),
        zda: snapshot.zda.map(zda_term),
        gsa: snapshot.gsa.into_iter().map(gsa_entry_term).collect(),
        gsv: snapshot.gsv.into_iter().map(gsv_group_term).collect(),
        sentence_count: snapshot.sentence_count as i64,
        diagnostics: diagnostics_term(snapshot.diagnostics),
        position_geodetic,
        pdop,
        hdop,
        vdop,
        used_satellites,
        satellites_in_view,
    }
}

fn chunk_output_term(output: NmeaChunkOutput) -> ChunkOutputTerm {
    ChunkOutputTerm {
        snapshots: output.snapshots.into_iter().map(snapshot_term).collect(),
        sentences: output.sentences.into_iter().map(sentence_term).collect(),
        diagnostics: diagnostics_term(output.diagnostics),
    }
}

fn gga_quality(value: i64) -> Result<GgaQuality, NmeaError> {
    if !(0..=255).contains(&value) {
        return Err(NmeaError::InvalidInput {
            field: "quality",
            reason: "must fit in u8",
        });
    }
    Ok(match value as u8 {
        0 => GgaQuality::Invalid,
        1 => GgaQuality::GpsSps,
        2 => GgaQuality::Differential,
        3 => GgaQuality::Pps,
        4 => GgaQuality::RtkFixed,
        5 => GgaQuality::RtkFloat,
        6 => GgaQuality::Estimated,
        7 => GgaQuality::Manual,
        8 => GgaQuality::Simulator,
        other => GgaQuality::Other(other),
    })
}

fn option_u8(value: Option<i64>, field: &'static str) -> Result<Option<u8>, NmeaError> {
    value
        .map(|value| {
            u8::try_from(value).map_err(|_| NmeaError::InvalidInput {
                field,
                reason: "must fit in u8",
            })
        })
        .transpose()
}

fn option_u16(value: Option<i64>, field: &'static str) -> Result<Option<u16>, NmeaError> {
    value
        .map(|value| {
            u16::try_from(value).map_err(|_| NmeaError::InvalidInput {
                field,
                reason: "must fit in u16",
            })
        })
        .transpose()
}

fn build_gga(term: GgaWriteTerm) -> Result<(NmeaTalker, Gga), NmeaError> {
    if term.talker.len() != 2 || !term.talker.is_ascii() {
        return Err(NmeaError::InvalidInput {
            field: "talker",
            reason: "must be a two-character ASCII talker",
        });
    }
    let coordinate_decimals =
        u8::try_from(term.coordinate_decimals).map_err(|_| NmeaError::InvalidInput {
            field: "coordinate_decimals",
            reason: "must fit in u8",
        })?;
    let latitude = term
        .latitude_deg
        .map(|value| NmeaCoordinate::from_degrees(value, true, coordinate_decimals))
        .transpose()?;
    let longitude = term
        .longitude_deg
        .map(|value| NmeaCoordinate::from_degrees(value, false, coordinate_decimals))
        .transpose()?;
    let quality = term.quality.map(gga_quality).transpose()?;

    Ok((
        NmeaTalker::parse(&term.talker),
        Gga {
            time: term
                .time_seconds_of_day
                .map(NmeaTime::from_seconds_of_day_floor_centis)
                .transpose()?,
            latitude,
            longitude,
            quality,
            satellites_used: option_u8(term.satellites_used, "satellites_used")?,
            hdop: term.hdop,
            altitude_msl_m: term.altitude_msl_m,
            geoid_separation_m: term.geoid_separation_m,
            differential_age_s: term.differential_age_s,
            differential_station_id: option_u16(
                term.differential_station_id,
                "differential_station_id",
            )?,
        },
    ))
}

#[rustler::nif]
fn nmea_parse_sentence<'a>(env: Env<'a>, line: String) -> Term<'a> {
    match parse_sentence(&line) {
        Ok(parsed) => (
            atoms::ok(),
            ParsedSentenceTerm {
                sentence: sentence_term(parsed.value),
                diagnostics: diagnostics_term(parsed.diagnostics),
            },
        )
            .encode(env),
        Err(error) => (atoms::error(), error.to_string()).encode(env),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn nmea_parse<'a>(env: Env<'a>, text: String) -> Term<'a> {
    let parsed = parse_nmea_str(&text);
    (
        atoms::ok(),
        ParsedLogTerm {
            sentences: parsed
                .value
                .sentences
                .into_iter()
                .map(sentence_term)
                .collect(),
            diagnostics: diagnostics_term(parsed.diagnostics),
        },
    )
        .encode(env)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn nmea_group_epochs<'a>(env: Env<'a>, text: String) -> Term<'a> {
    let parsed = parse_nmea_str(&text);
    let epochs = group_epochs(&parsed.value);
    (
        atoms::ok(),
        EpochLogTerm {
            sentences: parsed
                .value
                .sentences
                .into_iter()
                .map(sentence_term)
                .collect(),
            epochs: epochs.into_iter().map(snapshot_term).collect(),
            diagnostics: diagnostics_term(parsed.diagnostics),
        },
    )
        .encode(env)
}

#[rustler::nif]
fn nmea_accumulator_new<'a>(
    env: Env<'a>,
    date: Option<(i64, i64, i64)>,
    max_sentences_per_epoch: i64,
) -> Term<'a> {
    let accumulator = match date {
        Some((year, month, day)) => {
            let year = match u16::try_from(year) {
                Ok(value) => value,
                Err(_) => return (atoms::error(), "invalid NMEA date").encode(env),
            };
            let month = match u8::try_from(month) {
                Ok(value) => value,
                Err(_) => return (atoms::error(), "invalid NMEA date").encode(env),
            };
            let day = match u8::try_from(day) {
                Ok(value) => value,
                Err(_) => return (atoms::error(), "invalid NMEA date").encode(env),
            };
            match NmeaDate::new(year, month, day) {
                Ok(date) => NmeaAccumulator::with_date(date),
                Err(error) => return (atoms::error(), error.to_string()).encode(env),
            }
        }
        None => NmeaAccumulator::new(),
    };

    let accumulator = if max_sentences_per_epoch > 0 {
        accumulator.with_max_sentences_per_epoch(max_sentences_per_epoch as usize)
    } else {
        accumulator
    };

    (
        atoms::ok(),
        ResourceArc::new(NmeaAccumulatorResource {
            accumulator: Mutex::new(accumulator),
        }),
    )
        .encode(env)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn nmea_accumulator_push<'a>(
    env: Env<'a>,
    handle: ResourceArc<NmeaAccumulatorResource>,
    bytes: Binary<'a>,
) -> Term<'a> {
    match handle.accumulator.lock() {
        Ok(mut accumulator) => {
            let output = accumulator.push_bytes(bytes.as_slice());
            (atoms::ok(), chunk_output_term(output)).encode(env)
        }
        Err(_) => (atoms::error(), "NMEA accumulator lock poisoned").encode(env),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn nmea_accumulator_finish<'a>(
    env: Env<'a>,
    handle: ResourceArc<NmeaAccumulatorResource>,
) -> Term<'a> {
    match handle.accumulator.lock() {
        Ok(mut accumulator) => {
            let snapshot = accumulator.finish().map(snapshot_term);
            (atoms::ok(), snapshot).encode(env)
        }
        Err(_) => (atoms::error(), "NMEA accumulator lock poisoned").encode(env),
    }
}

#[rustler::nif]
fn nmea_accumulator_retained_len(handle: ResourceArc<NmeaAccumulatorResource>) -> usize {
    handle
        .accumulator
        .lock()
        .map(|accumulator| accumulator.retained_len())
        .unwrap_or(0)
}

#[rustler::nif]
fn nmea_write_gga<'a>(env: Env<'a>, term: GgaWriteTerm) -> Term<'a> {
    match build_gga(term).and_then(|(talker, gga)| write_gga(talker, &gga)) {
        Ok(sentence) => (atoms::ok(), sentence).encode(env),
        Err(error) => (atoms::error(), error.to_string()).encode(env),
    }
}
