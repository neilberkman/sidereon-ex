//! Rustler boundary for the `sidereon-core` RTCM 3.x stream decoder.
//!
//! Pure glue over `sidereon_core::rtcm`: it forwards a byte buffer to the crate's
//! forgiving frame scanner / message decoder and re-shapes the canonical message
//! IR into Elixir-friendly maps. No bit-field layout, CRC, or framing math lives
//! here. Each decoded message crosses as a `{type_atom, fields_map}` pair; the raw
//! transmitted integer fields are widened to signed 64-bit for a uniform numeric
//! boundary (decode is one-way, so no precision is lost relative to the
//! scaling-helper conversions the crate exposes). An unrecognized message number
//! is preserved as `{:unsupported, %{message_number, body}}`.

use rustler::{Encoder, Env, Error, NifResult, OwnedBinary, Term};
use sidereon_core::rtcm::{
    self, AntennaDescriptor, GlonassEphemeris, GpsEphemeris, Message, MsmHeader, MsmKind,
    MsmMessage, MsmSatellite, MsmSignal, StationCoordinates, UnsupportedMessage,
};
use sidereon_core::GnssSystem;

use crate::spp::atom_from;

mod atoms {
    rustler::atoms! {
        ok,
        error,
        station_coordinates,
        antenna_descriptor,
        gps_ephemeris,
        glonass_ephemeris,
        msm,
        unsupported
    }
}

#[derive(Debug, Clone, rustler::NifMap)]
struct StationCoordinatesFields {
    message_number: i64,
    reference_station_id: i64,
    itrf_realization_year: i64,
    gps_indicator: bool,
    glonass_indicator: bool,
    galileo_indicator: bool,
    reference_station_indicator: bool,
    ecef_x: i64,
    single_receiver_oscillator: bool,
    reserved: bool,
    ecef_y: i64,
    quarter_cycle_indicator: i64,
    ecef_z: i64,
    antenna_height: Option<i64>,
    x_m: f64,
    y_m: f64,
    z_m: f64,
    antenna_height_m: Option<f64>,
}

impl From<StationCoordinates> for StationCoordinatesFields {
    fn from(s: StationCoordinates) -> Self {
        Self {
            message_number: s.message_number as i64,
            reference_station_id: s.reference_station_id as i64,
            itrf_realization_year: s.itrf_realization_year as i64,
            gps_indicator: s.gps_indicator,
            glonass_indicator: s.glonass_indicator,
            galileo_indicator: s.galileo_indicator,
            reference_station_indicator: s.reference_station_indicator,
            ecef_x: s.ecef_x,
            single_receiver_oscillator: s.single_receiver_oscillator,
            reserved: s.reserved,
            ecef_y: s.ecef_y,
            quarter_cycle_indicator: s.quarter_cycle_indicator as i64,
            ecef_z: s.ecef_z,
            antenna_height: s.antenna_height.map(|h| h as i64),
            x_m: s.x_m(),
            y_m: s.y_m(),
            z_m: s.z_m(),
            antenna_height_m: s.antenna_height_m(),
        }
    }
}

#[derive(Debug, Clone, rustler::NifMap)]
struct AntennaDescriptorFields {
    message_number: i64,
    reference_station_id: i64,
    antenna_descriptor: String,
    antenna_setup_id: i64,
    antenna_serial_number: Option<String>,
    receiver_type: Option<String>,
    receiver_firmware_version: Option<String>,
    receiver_serial_number: Option<String>,
}

impl From<AntennaDescriptor> for AntennaDescriptorFields {
    fn from(a: AntennaDescriptor) -> Self {
        Self {
            message_number: a.message_number as i64,
            reference_station_id: a.reference_station_id as i64,
            antenna_descriptor: a.antenna_descriptor,
            antenna_setup_id: a.antenna_setup_id as i64,
            antenna_serial_number: a.antenna_serial_number,
            receiver_type: a.receiver_type,
            receiver_firmware_version: a.receiver_firmware_version,
            receiver_serial_number: a.receiver_serial_number,
        }
    }
}

#[derive(Debug, Clone, rustler::NifMap)]
struct GpsEphemerisFields {
    satellite_id: i64,
    week_number: i64,
    sv_accuracy: i64,
    code_on_l2: i64,
    idot: i64,
    iode: i64,
    t_oc: i64,
    a_f2: i64,
    a_f1: i64,
    a_f0: i64,
    iodc: i64,
    c_rs: i64,
    delta_n: i64,
    m0: i64,
    c_uc: i64,
    eccentricity: i64,
    c_us: i64,
    sqrt_a: i64,
    t_oe: i64,
    c_ic: i64,
    omega0: i64,
    c_is: i64,
    i0: i64,
    c_rc: i64,
    omega: i64,
    omega_dot: i64,
    t_gd: i64,
    sv_health: i64,
    l2_p_data_flag: bool,
    fit_interval: bool,
}

impl From<GpsEphemeris> for GpsEphemerisFields {
    fn from(e: GpsEphemeris) -> Self {
        Self {
            satellite_id: e.satellite_id as i64,
            week_number: e.week_number as i64,
            sv_accuracy: e.sv_accuracy as i64,
            code_on_l2: e.code_on_l2 as i64,
            idot: e.idot as i64,
            iode: e.iode as i64,
            t_oc: e.t_oc as i64,
            a_f2: e.a_f2 as i64,
            a_f1: e.a_f1 as i64,
            a_f0: e.a_f0 as i64,
            iodc: e.iodc as i64,
            c_rs: e.c_rs as i64,
            delta_n: e.delta_n as i64,
            m0: e.m0,
            c_uc: e.c_uc as i64,
            eccentricity: e.eccentricity as i64,
            c_us: e.c_us as i64,
            sqrt_a: e.sqrt_a as i64,
            t_oe: e.t_oe as i64,
            c_ic: e.c_ic as i64,
            omega0: e.omega0,
            c_is: e.c_is as i64,
            i0: e.i0,
            c_rc: e.c_rc as i64,
            omega: e.omega,
            omega_dot: e.omega_dot as i64,
            t_gd: e.t_gd as i64,
            sv_health: e.sv_health as i64,
            l2_p_data_flag: e.l2_p_data_flag,
            fit_interval: e.fit_interval,
        }
    }
}

#[derive(Debug, Clone, rustler::NifMap)]
struct GlonassEphemerisFields {
    satellite_id: i64,
    frequency_channel: i64,
    almanac_health: bool,
    almanac_health_availability: bool,
    p1: i64,
    t_k: i64,
    b_n_msb: bool,
    p2: bool,
    t_b: i64,
    xn_dot: i64,
    xn: i64,
    xn_dot_dot: i64,
    yn_dot: i64,
    yn: i64,
    yn_dot_dot: i64,
    zn_dot: i64,
    zn: i64,
    zn_dot_dot: i64,
    p3: bool,
    gamma_n: i64,
    m_p: i64,
    m_l_n_third: bool,
    tau_n: i64,
    delta_tau_n: i64,
    e_n: i64,
    m_p4: bool,
    m_f_t: i64,
    m_n_t: i64,
    m_m: i64,
    additional_data_available: bool,
    n_a: i64,
    tau_c: i64,
    m_n4: i64,
    m_tau_gps: i64,
    m_l_n_fifth: bool,
    reserved: i64,
}

impl From<GlonassEphemeris> for GlonassEphemerisFields {
    fn from(e: GlonassEphemeris) -> Self {
        Self {
            satellite_id: e.satellite_id as i64,
            frequency_channel: e.frequency_channel as i64,
            almanac_health: e.almanac_health,
            almanac_health_availability: e.almanac_health_availability,
            p1: e.p1 as i64,
            t_k: e.t_k as i64,
            b_n_msb: e.b_n_msb,
            p2: e.p2,
            t_b: e.t_b as i64,
            xn_dot: e.xn_dot as i64,
            xn: e.xn as i64,
            xn_dot_dot: e.xn_dot_dot as i64,
            yn_dot: e.yn_dot as i64,
            yn: e.yn as i64,
            yn_dot_dot: e.yn_dot_dot as i64,
            zn_dot: e.zn_dot as i64,
            zn: e.zn as i64,
            zn_dot_dot: e.zn_dot_dot as i64,
            p3: e.p3,
            gamma_n: e.gamma_n as i64,
            m_p: e.m_p as i64,
            m_l_n_third: e.m_l_n_third,
            tau_n: e.tau_n as i64,
            delta_tau_n: e.delta_tau_n as i64,
            e_n: e.e_n as i64,
            m_p4: e.m_p4,
            m_f_t: e.m_f_t as i64,
            m_n_t: e.m_n_t as i64,
            m_m: e.m_m as i64,
            additional_data_available: e.additional_data_available,
            n_a: e.n_a as i64,
            tau_c: e.tau_c,
            m_n4: e.m_n4 as i64,
            m_tau_gps: e.m_tau_gps as i64,
            m_l_n_fifth: e.m_l_n_fifth,
            reserved: e.reserved as i64,
        }
    }
}

#[derive(Debug, Clone, rustler::NifMap)]
struct MsmHeaderFields {
    reference_station_id: i64,
    epoch_time: i64,
    multiple_message: bool,
    iods: i64,
    reserved: i64,
    clock_steering: i64,
    external_clock: i64,
    divergence_free_smoothing: bool,
    smoothing_interval: i64,
}

impl From<MsmHeader> for MsmHeaderFields {
    fn from(h: MsmHeader) -> Self {
        Self {
            reference_station_id: h.reference_station_id as i64,
            epoch_time: h.epoch_time as i64,
            multiple_message: h.multiple_message,
            iods: h.iods as i64,
            reserved: h.reserved as i64,
            clock_steering: h.clock_steering as i64,
            external_clock: h.external_clock as i64,
            divergence_free_smoothing: h.divergence_free_smoothing,
            smoothing_interval: h.smoothing_interval as i64,
        }
    }
}

#[derive(Debug, Clone, rustler::NifMap)]
struct MsmSatelliteFields {
    id: i64,
    rough_range_ms: i64,
    rough_range_mod1: i64,
    extended_info: Option<i64>,
    rough_phase_range_rate_m_s: Option<i64>,
}

impl From<MsmSatellite> for MsmSatelliteFields {
    fn from(s: MsmSatellite) -> Self {
        Self {
            id: s.id as i64,
            rough_range_ms: s.rough_range_ms as i64,
            rough_range_mod1: s.rough_range_mod1 as i64,
            extended_info: s.extended_info.map(|v| v as i64),
            rough_phase_range_rate_m_s: s.rough_phase_range_rate_m_s.map(|v| v as i64),
        }
    }
}

#[derive(Debug, Clone, rustler::NifMap)]
struct MsmSignalFields {
    satellite_id: i64,
    signal_id: i64,
    fine_pseudorange: i64,
    fine_phase_range: i64,
    lock_time_indicator: i64,
    half_cycle_ambiguity: bool,
    cnr: i64,
    fine_phase_range_rate: Option<i64>,
}

impl From<MsmSignal> for MsmSignalFields {
    fn from(s: MsmSignal) -> Self {
        Self {
            satellite_id: s.satellite_id as i64,
            signal_id: s.signal_id as i64,
            fine_pseudorange: s.fine_pseudorange as i64,
            fine_phase_range: s.fine_phase_range as i64,
            lock_time_indicator: s.lock_time_indicator as i64,
            half_cycle_ambiguity: s.half_cycle_ambiguity,
            cnr: s.cnr as i64,
            fine_phase_range_rate: s.fine_phase_range_rate.map(|v| v as i64),
        }
    }
}

#[derive(Debug, Clone, rustler::NifMap)]
struct MsmMessageFields {
    message_number: i64,
    system: String,
    kind: String,
    header: MsmHeaderFields,
    satellites: Vec<MsmSatelliteFields>,
    signals: Vec<MsmSignalFields>,
}

impl From<MsmMessage> for MsmMessageFields {
    fn from(m: MsmMessage) -> Self {
        let kind = match m.kind {
            MsmKind::Msm4 => "msm4",
            MsmKind::Msm7 => "msm7",
        };
        Self {
            message_number: m.message_number as i64,
            system: m.system.letter().to_string(),
            kind: kind.to_string(),
            header: m.header.into(),
            satellites: m.satellites.into_iter().map(Into::into).collect(),
            signals: m.signals.into_iter().map(Into::into).collect(),
        }
    }
}

#[derive(Debug, Clone, rustler::NifMap)]
struct UnsupportedFields {
    message_number: i64,
    body: Vec<u8>,
}

/// Construction input for a 1005 / 1006 station antenna reference point.
///
/// Carries only the raw transmitted fields, so a caller builds a message from
/// scratch without supplying the scaled `x_m`/`y_m`/`z_m` outputs the decoder
/// derives. A round-trip caller can also pass the full decoded map directly: the
/// extra derived keys are ignored at decode.
#[derive(Debug, Clone, rustler::NifMap)]
struct StationCoordinatesInput {
    message_number: i64,
    reference_station_id: i64,
    itrf_realization_year: i64,
    gps_indicator: bool,
    glonass_indicator: bool,
    galileo_indicator: bool,
    reference_station_indicator: bool,
    ecef_x: i64,
    single_receiver_oscillator: bool,
    reserved: bool,
    ecef_y: i64,
    quarter_cycle_indicator: i64,
    ecef_z: i64,
    antenna_height: Option<i64>,
}

impl From<StationCoordinatesInput> for StationCoordinates {
    fn from(s: StationCoordinatesInput) -> Self {
        Self {
            message_number: s.message_number as u16,
            reference_station_id: s.reference_station_id as u16,
            itrf_realization_year: s.itrf_realization_year as u8,
            gps_indicator: s.gps_indicator,
            glonass_indicator: s.glonass_indicator,
            galileo_indicator: s.galileo_indicator,
            reference_station_indicator: s.reference_station_indicator,
            ecef_x: s.ecef_x,
            single_receiver_oscillator: s.single_receiver_oscillator,
            reserved: s.reserved,
            ecef_y: s.ecef_y,
            quarter_cycle_indicator: s.quarter_cycle_indicator as u8,
            ecef_z: s.ecef_z,
            antenna_height: s.antenna_height.map(|h| h as u16),
        }
    }
}

impl From<AntennaDescriptorFields> for AntennaDescriptor {
    fn from(a: AntennaDescriptorFields) -> Self {
        Self {
            message_number: a.message_number as u16,
            reference_station_id: a.reference_station_id as u16,
            antenna_descriptor: a.antenna_descriptor,
            antenna_setup_id: a.antenna_setup_id as u8,
            antenna_serial_number: a.antenna_serial_number,
            receiver_type: a.receiver_type,
            receiver_firmware_version: a.receiver_firmware_version,
            receiver_serial_number: a.receiver_serial_number,
        }
    }
}

impl From<GpsEphemerisFields> for GpsEphemeris {
    fn from(e: GpsEphemerisFields) -> Self {
        Self {
            satellite_id: e.satellite_id as u8,
            week_number: e.week_number as u16,
            sv_accuracy: e.sv_accuracy as u8,
            code_on_l2: e.code_on_l2 as u8,
            idot: e.idot as i32,
            iode: e.iode as u8,
            t_oc: e.t_oc as u16,
            a_f2: e.a_f2 as i16,
            a_f1: e.a_f1 as i32,
            a_f0: e.a_f0 as i32,
            iodc: e.iodc as u16,
            c_rs: e.c_rs as i32,
            delta_n: e.delta_n as i32,
            m0: e.m0,
            c_uc: e.c_uc as i32,
            eccentricity: e.eccentricity as u64,
            c_us: e.c_us as i32,
            sqrt_a: e.sqrt_a as u64,
            t_oe: e.t_oe as u16,
            c_ic: e.c_ic as i32,
            omega0: e.omega0,
            c_is: e.c_is as i32,
            i0: e.i0,
            c_rc: e.c_rc as i32,
            omega: e.omega,
            omega_dot: e.omega_dot as i32,
            t_gd: e.t_gd as i16,
            sv_health: e.sv_health as u8,
            l2_p_data_flag: e.l2_p_data_flag,
            fit_interval: e.fit_interval,
        }
    }
}

impl From<GlonassEphemerisFields> for GlonassEphemeris {
    fn from(e: GlonassEphemerisFields) -> Self {
        Self {
            satellite_id: e.satellite_id as u8,
            frequency_channel: e.frequency_channel as u8,
            almanac_health: e.almanac_health,
            almanac_health_availability: e.almanac_health_availability,
            p1: e.p1 as u8,
            t_k: e.t_k as u16,
            b_n_msb: e.b_n_msb,
            p2: e.p2,
            t_b: e.t_b as u8,
            xn_dot: e.xn_dot as i32,
            xn: e.xn as i32,
            xn_dot_dot: e.xn_dot_dot as i8,
            yn_dot: e.yn_dot as i32,
            yn: e.yn as i32,
            yn_dot_dot: e.yn_dot_dot as i8,
            zn_dot: e.zn_dot as i32,
            zn: e.zn as i32,
            zn_dot_dot: e.zn_dot_dot as i8,
            p3: e.p3,
            gamma_n: e.gamma_n as i16,
            m_p: e.m_p as u8,
            m_l_n_third: e.m_l_n_third,
            tau_n: e.tau_n as i32,
            delta_tau_n: e.delta_tau_n as i8,
            e_n: e.e_n as u8,
            m_p4: e.m_p4,
            m_f_t: e.m_f_t as u8,
            m_n_t: e.m_n_t as u16,
            m_m: e.m_m as u8,
            additional_data_available: e.additional_data_available,
            n_a: e.n_a as u16,
            tau_c: e.tau_c,
            m_n4: e.m_n4 as u8,
            m_tau_gps: e.m_tau_gps as i32,
            m_l_n_fifth: e.m_l_n_fifth,
            reserved: e.reserved as u8,
        }
    }
}

impl From<MsmHeaderFields> for MsmHeader {
    fn from(h: MsmHeaderFields) -> Self {
        Self {
            reference_station_id: h.reference_station_id as u16,
            epoch_time: h.epoch_time as u32,
            multiple_message: h.multiple_message,
            iods: h.iods as u8,
            reserved: h.reserved as u8,
            clock_steering: h.clock_steering as u8,
            external_clock: h.external_clock as u8,
            divergence_free_smoothing: h.divergence_free_smoothing,
            smoothing_interval: h.smoothing_interval as u8,
        }
    }
}

impl From<MsmSatelliteFields> for MsmSatellite {
    fn from(s: MsmSatelliteFields) -> Self {
        Self {
            id: s.id as u8,
            rough_range_ms: s.rough_range_ms as u8,
            rough_range_mod1: s.rough_range_mod1 as u16,
            extended_info: s.extended_info.map(|v| v as u8),
            rough_phase_range_rate_m_s: s.rough_phase_range_rate_m_s.map(|v| v as i16),
        }
    }
}

impl From<MsmSignalFields> for MsmSignal {
    fn from(s: MsmSignalFields) -> Self {
        Self {
            satellite_id: s.satellite_id as u8,
            signal_id: s.signal_id as u8,
            fine_pseudorange: s.fine_pseudorange as i32,
            fine_phase_range: s.fine_phase_range as i32,
            lock_time_indicator: s.lock_time_indicator as u16,
            half_cycle_ambiguity: s.half_cycle_ambiguity,
            cnr: s.cnr as u16,
            fine_phase_range_rate: s.fine_phase_range_rate.map(|v| v as i16),
        }
    }
}

/// Build an [`MsmMessage`] from its decoded field map. The constellation letter
/// and MSM kind are validated here (the only fallible parts of construction).
fn build_msm(fields: MsmMessageFields) -> NifResult<MsmMessage> {
    let system = fields
        .system
        .chars()
        .next()
        .and_then(GnssSystem::from_letter)
        .ok_or_else(|| Error::Term(Box::new("unknown RTCM MSM constellation letter")))?;
    let kind = match fields.kind.as_str() {
        "msm4" => MsmKind::Msm4,
        "msm7" => MsmKind::Msm7,
        _ => return Err(Error::Term(Box::new("unknown RTCM MSM kind"))),
    };
    Ok(MsmMessage {
        message_number: fields.message_number as u16,
        system,
        kind,
        header: fields.header.into(),
        satellites: fields.satellites.into_iter().map(Into::into).collect(),
        signals: fields.signals.into_iter().map(Into::into).collect(),
    })
}

/// Build the canonical [`Message`] IR for a `{type, fields}` construction pair.
fn build_message(kind: &str, fields: Term<'_>) -> NifResult<Message> {
    let message = match kind {
        "station_coordinates" => {
            Message::StationCoordinates(fields.decode::<StationCoordinatesInput>()?.into())
        }
        "antenna_descriptor" => {
            Message::AntennaDescriptor(fields.decode::<AntennaDescriptorFields>()?.into())
        }
        "gps_ephemeris" => Message::GpsEphemeris(fields.decode::<GpsEphemerisFields>()?.into()),
        "glonass_ephemeris" => {
            Message::GlonassEphemeris(fields.decode::<GlonassEphemerisFields>()?.into())
        }
        "msm" => Message::Msm(build_msm(fields.decode::<MsmMessageFields>()?)?),
        "unsupported" => {
            let unsupported = fields.decode::<UnsupportedFields>()?;
            Message::Unsupported(UnsupportedMessage {
                message_number: unsupported.message_number as u16,
                body: unsupported.body,
            })
        }
        _ => return Err(Error::Term(Box::new("unsupported RTCM message type"))),
    };
    Ok(message)
}

fn encode_message<'a>(env: Env<'a>, message: Message) -> Term<'a> {
    match message {
        Message::Msm(m) => (atoms::msm(), MsmMessageFields::from(m)).encode(env),
        Message::StationCoordinates(s) => (
            atoms::station_coordinates(),
            StationCoordinatesFields::from(s),
        )
            .encode(env),
        Message::AntennaDescriptor(a) => (
            atoms::antenna_descriptor(),
            AntennaDescriptorFields::from(a),
        )
            .encode(env),
        Message::GpsEphemeris(e) => {
            (atoms::gps_ephemeris(), GpsEphemerisFields::from(e)).encode(env)
        }
        Message::GlonassEphemeris(e) => {
            (atoms::glonass_ephemeris(), GlonassEphemerisFields::from(e)).encode(env)
        }
        Message::Ssr(s) => (atom_from(env, "ssr"), format!("{s:?}")).encode(env),
        Message::Unsupported(u) => (
            atoms::unsupported(),
            UnsupportedFields {
                message_number: u.message_number as i64,
                body: u.body,
            },
        )
            .encode(env),
    }
}

/// Decode every CRC-valid RTCM 3 frame in a byte buffer into the message IR.
///
/// Mirrors the forgiving `rtcm::decode_messages`: frames whose CRC fails or whose
/// body cannot be decoded are skipped, and the scan resynchronizes on the next
/// preamble. Returns a list of `{type_atom, fields_map}` pairs.
#[rustler::nif(schedule = "DirtyCpu")]
fn rtcm_decode_messages<'a>(env: Env<'a>, bytes: rustler::Binary) -> Vec<Term<'a>> {
    rtcm::decode_messages(bytes.as_slice())
        .into_iter()
        .map(|message| encode_message(env, message))
        .collect()
}

/// Decode a single RTCM message body into the message IR.
#[rustler::nif]
fn rtcm_decode_message<'a>(env: Env<'a>, body: rustler::Binary) -> NifResult<Term<'a>> {
    match Message::decode(body.as_slice()) {
        Ok(message) => Ok((atoms::ok(), encode_message(env, message)).encode(env)),
        Err(error) => Ok((atoms::error(), error.to_string()).encode(env)),
    }
}

/// Read the RTCM message number from a message body.
#[rustler::nif]
fn rtcm_message_number<'a>(env: Env<'a>, body: rustler::Binary) -> NifResult<Term<'a>> {
    match rtcm::message_number(body.as_slice()) {
        Ok(number) => Ok((atoms::ok(), number as i64).encode(env)),
        Err(error) => Ok((atoms::error(), error.to_string()).encode(env)),
    }
}

/// Decode the single RTCM 3 frame that begins at the start of `bytes`.
///
/// Verifies the preamble and the CRC-24Q. Returns
/// `{:ok, %{message_number, frame_len, body}}` (body as a binary) or
/// `{:error, reason}` for a missing preamble, a truncated buffer, or a CRC
/// mismatch.
#[rustler::nif]
fn rtcm_decode_frame<'a>(env: Env<'a>, bytes: rustler::Binary) -> NifResult<Term<'a>> {
    match rtcm::decode_frame(bytes.as_slice()) {
        Ok(frame) => {
            let message_number = rtcm::message_number(frame.body)
                .map(|n| n as i64)
                .unwrap_or(-1);
            let body = frame.body.to_vec();
            Ok((
                atoms::ok(),
                FrameFields {
                    message_number,
                    frame_len: frame.frame_len as i64,
                    body,
                },
            )
                .encode(env))
        }
        Err(e) => Ok((atoms::error(), e.to_string()).encode(env)),
    }
}

/// Wrap an RTCM message body in a fresh RTCM frame.
#[rustler::nif]
fn rtcm_encode_frame_body<'a>(env: Env<'a>, body: rustler::Binary) -> NifResult<Term<'a>> {
    match rtcm::encode_frame(body.as_slice()) {
        Ok(frame) => Ok((atoms::ok(), bytes_to_binary(env, &frame)).encode(env)),
        Err(error) => Ok((atoms::error(), error.to_string()).encode(env)),
    }
}

#[derive(Debug, Clone, rustler::NifMap)]
struct FrameFields {
    message_number: i64,
    frame_len: i64,
    body: Vec<u8>,
}

/// Construct a supported RTCM 3 message from a `{type, fields}` pair and encode
/// it into a complete transport frame (preamble, length, body, CRC-24Q).
///
/// Pure glue over the per-type constructors and `Message::to_frame`: it builds
/// the canonical message IR from the field map and emits the framed bytes a
/// stream consumer (or `decode_messages/1`) reads back. Returns
/// `{:ok, binary}` or `{:error, reason}` for an unsupported type, a malformed
/// field map, or a body that overflows the frame length limit.
#[rustler::nif(schedule = "DirtyCpu")]
fn rtcm_encode_message<'a>(env: Env<'a>, kind: String, fields: Term<'a>) -> NifResult<Term<'a>> {
    let message = build_message(&kind, fields)?;
    match message.to_frame() {
        Ok(frame) => Ok((atoms::ok(), bytes_to_binary(env, &frame)).encode(env)),
        Err(error) => Ok((atoms::error(), error.to_string()).encode(env)),
    }
}

/// Construct a supported RTCM 3 message and return its message body.
#[rustler::nif(schedule = "DirtyCpu")]
fn rtcm_encode<'a>(env: Env<'a>, kind: String, fields: Term<'a>) -> NifResult<Term<'a>> {
    let message = build_message(&kind, fields)?;
    Ok((atoms::ok(), bytes_to_binary(env, &message.encode())).encode(env))
}

/// Construct a supported RTCM 3 message and return its complete frame.
#[rustler::nif(schedule = "DirtyCpu")]
fn rtcm_encode_frame<'a>(env: Env<'a>, kind: String, fields: Term<'a>) -> NifResult<Term<'a>> {
    let message = build_message(&kind, fields)?;
    match message.to_frame() {
        Ok(frame) => Ok((atoms::ok(), bytes_to_binary(env, &frame)).encode(env)),
        Err(error) => Ok((atoms::error(), error.to_string()).encode(env)),
    }
}

/// Copy a byte slice into an Elixir binary term.
fn bytes_to_binary<'a>(env: Env<'a>, bytes: &[u8]) -> Term<'a> {
    let mut binary = OwnedBinary::new(bytes.len()).expect("allocate RTCM frame binary");
    binary.as_mut_slice().copy_from_slice(bytes);
    binary.release(env).encode(env)
}
