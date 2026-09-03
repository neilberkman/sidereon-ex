//! Rustler boundary for the core NTRIP sans-I/O client.
//!
//! All protocol classification, sourcetable parsing, chunk handling, and GGA
//! sentence formatting are delegated to `sidereon-core`. Elixir owns sockets,
//! clocks, reconnects, and cache policy.

use std::sync::Mutex;

use rustler::{Binary, Encoder, Env, Error, NifResult, OwnedBinary, ResourceArc, Term};
use sidereon_core::ntrip::{
    classify_http_response, format_gga, parse_sourcetable, CasRecord, Field, GgaPosition,
    HttpClassification, NetRecord, NtripClientMachine, NtripConfig, NtripCredentials, NtripEvent,
    NtripHandshake, NtripRejection, NtripState, NtripVersion, OtherRecord, Sourcetable,
    SourcetableRecord, StrAuth, StrRecord,
};
use sidereon_core::rtcm::{Message, SsrStreamAssembler};

pub struct NtripConfigResource {
    config: NtripConfig,
}

pub struct NtripMachineResource {
    machine: Mutex<NtripClientMachine>,
}

pub struct SourcetableResource {
    table: Sourcetable,
}

pub struct RtcmAssemblerResource {
    assembler: Mutex<SsrStreamAssembler>,
}

#[rustler::resource_impl]
impl rustler::Resource for NtripConfigResource {}

#[rustler::resource_impl]
impl rustler::Resource for NtripMachineResource {}

#[rustler::resource_impl]
impl rustler::Resource for SourcetableResource {}

#[rustler::resource_impl]
impl rustler::Resource for RtcmAssemblerResource {}

mod atoms {
    rustler::atoms! {
        ok,
        error,
        stream,
        sourcetable,
        rejected,
        connected,
        payload,
        stream_corrupted,
        stream_ended,
        unauthorized,
        mountpoint_not_found,
        digest_not_supported,
        caster_error,
        unexpected_content_type,
        http_status,
        malformed_handshake,
        rev1,
        rev2,
        idle,
        awaiting_status,
        awaiting_headers,
        streaming,
        closed,
        str,
        cas,
        net,
        other,
        none,
        basic,
        digest,
        raw,
    }
}

#[derive(Debug, Clone, rustler::NifMap)]
struct NtripConfigTerm {
    host: String,
    port: u16,
    mountpoint: String,
    version: String,
    username: Option<String>,
    password: Option<String>,
    user_agent_product: Option<String>,
    gga_interval_s: Option<f64>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct GgaPositionTerm {
    lat_deg: f64,
    lon_deg: f64,
    height_m: f64,
    fix_quality: u8,
    num_satellites: u8,
    hdop: f64,
}

fn bytes_to_binary<'a>(env: Env<'a>, bytes: &[u8]) -> Term<'a> {
    let mut binary = OwnedBinary::new(bytes.len()).expect("allocate NTRIP binary");
    binary.as_mut_slice().copy_from_slice(bytes);
    binary.release(env).encode(env)
}

fn atom_key<'a>(env: Env<'a>, key: &str) -> Term<'a> {
    rustler::types::atom::Atom::from_str(env, key)
        .expect("valid atom key")
        .to_term(env)
}

fn map_from_pairs<'a>(env: Env<'a>, pairs: Vec<(&str, Term<'a>)>) -> Term<'a> {
    let keys: Vec<Term<'a>> = pairs.iter().map(|(key, _)| atom_key(env, key)).collect();
    let values: Vec<Term<'a>> = pairs.into_iter().map(|(_, value)| value).collect();
    Term::map_from_term_arrays(env, &keys, &values).expect("build NIF map")
}

fn encode_error<'a>(env: Env<'a>, error: impl ToString) -> Term<'a> {
    (atoms::error(), error.to_string()).encode(env)
}

fn parse_version(value: &str) -> NifResult<NtripVersion> {
    match value {
        "rev1" => Ok(NtripVersion::Rev1),
        "rev2" => Ok(NtripVersion::Rev2),
        _ => Err(Error::Term(Box::new("invalid NTRIP version"))),
    }
}

fn config_from_term(term: NtripConfigTerm) -> NifResult<NtripConfig> {
    let credentials = match (term.username, term.password) {
        (Some(username), Some(password)) => Some(NtripCredentials { username, password }),
        (None, None) => None,
        _ => {
            return Err(Error::Term(Box::new(
                "NTRIP credentials require user and password",
            )))
        }
    };
    let mut config = NtripConfig::default();
    config.host = term.host;
    config.port = term.port;
    config.mountpoint = term.mountpoint;
    config.version = parse_version(&term.version)?;
    config.credentials = credentials;
    config.user_agent_product = term
        .user_agent_product
        .unwrap_or_else(|| NtripConfig::default().user_agent_product);
    config.gga_interval_s = term.gga_interval_s;
    Ok(config)
}

fn position_from_term(term: GgaPositionTerm) -> GgaPosition {
    GgaPosition {
        lat_deg: term.lat_deg,
        lon_deg: term.lon_deg,
        height_m: term.height_m,
        fix_quality: term.fix_quality,
        num_satellites: term.num_satellites,
        hdop: term.hdop,
    }
}

fn lock_machine(
    handle: &ResourceArc<NtripMachineResource>,
) -> NifResult<std::sync::MutexGuard<'_, NtripClientMachine>> {
    handle
        .machine
        .lock()
        .map_err(|_| Error::Term(Box::new("ntrip machine lock poisoned")))
}

fn lock_assembler(
    handle: &ResourceArc<RtcmAssemblerResource>,
) -> NifResult<std::sync::MutexGuard<'_, SsrStreamAssembler>> {
    handle
        .assembler
        .lock()
        .map_err(|_| Error::Term(Box::new("rtcm assembler lock poisoned")))
}

fn version_atom(version: NtripVersion) -> rustler::Atom {
    match version {
        NtripVersion::Rev1 => atoms::rev1(),
        NtripVersion::Rev2 => atoms::rev2(),
    }
}

fn state_atom(state: NtripState) -> rustler::Atom {
    match state {
        NtripState::Idle => atoms::idle(),
        NtripState::AwaitingStatus => atoms::awaiting_status(),
        NtripState::AwaitingHeaders => atoms::awaiting_headers(),
        NtripState::Streaming => atoms::streaming(),
        NtripState::Sourcetable => atoms::sourcetable(),
        NtripState::Closed => atoms::closed(),
    }
}

fn encode_handshake<'a>(env: Env<'a>, handshake: NtripHandshake) -> Term<'a> {
    map_from_pairs(
        env,
        vec![
            ("version", version_atom(handshake.version).encode(env)),
            ("chunked", handshake.chunked.encode(env)),
            ("headers", handshake.headers.encode(env)),
        ],
    )
}

fn encode_rejection<'a>(env: Env<'a>, rejection: NtripRejection) -> Term<'a> {
    match rejection {
        NtripRejection::Unauthorized => atoms::unauthorized().encode(env),
        NtripRejection::MountpointNotFound => atoms::mountpoint_not_found().encode(env),
        NtripRejection::DigestRequired => atoms::digest_not_supported().encode(env),
        NtripRejection::CasterError { reason } => (atoms::caster_error(), reason).encode(env),
        NtripRejection::UnexpectedContentType { content_type } => {
            (atoms::unexpected_content_type(), content_type).encode(env)
        }
        NtripRejection::HttpError { status, reason } => {
            (atoms::http_status(), status, reason).encode(env)
        }
        NtripRejection::MalformedHandshake { prefix } => {
            (atoms::malformed_handshake(), bytes_to_binary(env, &prefix)).encode(env)
        }
    }
}

fn field_to_term<'a, T, F>(env: Env<'a>, field: &Field<T>, encode_value: F) -> Term<'a>
where
    F: FnOnce(Env<'a>, &T) -> Term<'a>,
{
    match field {
        Field::Parsed(value) => encode_value(env, value),
        Field::Empty => rustler::types::atom::nil().encode(env),
        Field::Raw(value) => (atoms::raw(), value).encode(env),
    }
}

fn bool_term<'a>(env: Env<'a>, value: &bool) -> Term<'a> {
    value.encode(env)
}

fn auth_term<'a>(env: Env<'a>, auth: &StrAuth) -> Term<'a> {
    match auth {
        StrAuth::None => atoms::none().encode(env),
        StrAuth::Basic => atoms::basic().encode(env),
        StrAuth::Digest => atoms::digest().encode(env),
        StrAuth::Other(value) => (atoms::other(), value).encode(env),
    }
}

fn encode_str_record<'a>(env: Env<'a>, record: &StrRecord) -> Term<'a> {
    (
        atoms::str(),
        map_from_pairs(
            env,
            vec![
                ("mountpoint", record.mountpoint.encode(env)),
                ("identifier", record.identifier.encode(env)),
                ("format", record.format.encode(env)),
                ("format_details", record.format_details.encode(env)),
                (
                    "carrier",
                    field_to_term(env, &record.carrier, |env, value| {
                        i64::from(*value).encode(env)
                    }),
                ),
                ("nav_system", record.nav_system.encode(env)),
                ("network", record.network.encode(env)),
                ("country", record.country.encode(env)),
                (
                    "lat_deg",
                    field_to_term(env, &record.lat_deg, |env, value| value.encode(env)),
                ),
                (
                    "lon_deg",
                    field_to_term(env, &record.lon_deg, |env, value| value.encode(env)),
                ),
                (
                    "nmea_required",
                    field_to_term(env, &record.nmea_required, bool_term),
                ),
                (
                    "network_solution",
                    field_to_term(env, &record.network_solution, bool_term),
                ),
                ("generator", record.generator.encode(env)),
                ("compression", record.compression.encode(env)),
                ("authentication", auth_term(env, &record.authentication)),
                ("fee", field_to_term(env, &record.fee, bool_term)),
                (
                    "bitrate",
                    field_to_term(env, &record.bitrate, |env, value| {
                        i64::from(*value).encode(env)
                    }),
                ),
                ("misc", record.misc.encode(env)),
            ],
        ),
    )
        .encode(env)
}

fn encode_cas_record<'a>(env: Env<'a>, record: &CasRecord) -> Term<'a> {
    (
        atoms::cas(),
        map_from_pairs(
            env,
            vec![
                ("host", record.host.encode(env)),
                (
                    "port",
                    field_to_term(env, &record.port, |env, value| {
                        i64::from(*value).encode(env)
                    }),
                ),
                ("identifier", record.identifier.encode(env)),
                ("operator", record.operator.encode(env)),
                (
                    "nmea_required",
                    field_to_term(env, &record.nmea_required, bool_term),
                ),
                ("country", record.country.encode(env)),
                (
                    "lat_deg",
                    field_to_term(env, &record.lat_deg, |env, value| value.encode(env)),
                ),
                (
                    "lon_deg",
                    field_to_term(env, &record.lon_deg, |env, value| value.encode(env)),
                ),
                ("fallback_host", record.fallback_host.encode(env)),
                (
                    "fallback_port",
                    field_to_term(env, &record.fallback_port, |env, value| {
                        i64::from(*value).encode(env)
                    }),
                ),
                ("misc", record.misc.encode(env)),
            ],
        ),
    )
        .encode(env)
}

fn encode_net_record<'a>(env: Env<'a>, record: &NetRecord) -> Term<'a> {
    (
        atoms::net(),
        map_from_pairs(
            env,
            vec![
                ("identifier", record.identifier.encode(env)),
                ("operator", record.operator.encode(env)),
                ("authentication", auth_term(env, &record.authentication)),
                ("fee", field_to_term(env, &record.fee, bool_term)),
                ("web_net", record.web_net.encode(env)),
                ("web_str", record.web_str.encode(env)),
                ("web_reg", record.web_reg.encode(env)),
                ("misc", record.misc.encode(env)),
            ],
        ),
    )
        .encode(env)
}

fn encode_other_record<'a>(env: Env<'a>, record: &OtherRecord) -> Term<'a> {
    (
        atoms::other(),
        map_from_pairs(
            env,
            vec![
                ("type_tag", record.type_tag.encode(env)),
                ("fields", record.fields.encode(env)),
            ],
        ),
    )
        .encode(env)
}

fn encode_record<'a>(env: Env<'a>, record: &SourcetableRecord) -> Term<'a> {
    match record {
        SourcetableRecord::Str(record) => encode_str_record(env, record),
        SourcetableRecord::Cas(record) => encode_cas_record(env, record),
        SourcetableRecord::Net(record) => encode_net_record(env, record),
        SourcetableRecord::Other(record) => encode_other_record(env, record),
    }
}

fn encode_table<'a>(env: Env<'a>, table: Sourcetable) -> Term<'a> {
    let records: Vec<Term<'a>> = table
        .records
        .iter()
        .map(|record| encode_record(env, record))
        .collect();
    (ResourceArc::new(SourcetableResource { table }), records).encode(env)
}

fn encode_event<'a>(env: Env<'a>, event: NtripEvent) -> Term<'a> {
    match event {
        NtripEvent::Connected(handshake) => {
            (atoms::connected(), encode_handshake(env, handshake)).encode(env)
        }
        NtripEvent::Payload(bytes) => (atoms::payload(), bytes_to_binary(env, &bytes)).encode(env),
        NtripEvent::Sourcetable(table) => {
            (atoms::sourcetable(), encode_table(env, table)).encode(env)
        }
        NtripEvent::Rejected(rejection) => {
            (atoms::rejected(), encode_rejection(env, rejection)).encode(env)
        }
        NtripEvent::StreamCorrupted { detail } => (atoms::stream_corrupted(), detail).encode(env),
        NtripEvent::StreamEnded => atoms::stream_ended().encode(env),
    }
}

fn encode_message_result<'a>(env: Env<'a>, result: sidereon_core::Result<Message>) -> Term<'a> {
    match result {
        Ok(message) => (atoms::ok(), crate::rtcm::encode_message(env, message)).encode(env),
        Err(error) => (atoms::error(), error.to_string()).encode(env),
    }
}

#[rustler::nif]
fn ntrip_config_new<'a>(env: Env<'a>, config: NtripConfigTerm) -> NifResult<Term<'a>> {
    let config = config_from_term(config)?;
    Ok(match config.request_bytes() {
        Ok(_) => (
            atoms::ok(),
            ResourceArc::new(NtripConfigResource { config }),
        )
            .encode(env),
        Err(error) => encode_error(env, error),
    })
}

#[rustler::nif]
fn ntrip_request_bytes<'a>(env: Env<'a>, handle: ResourceArc<NtripConfigResource>) -> Term<'a> {
    match handle.config.request_bytes() {
        Ok(bytes) => (atoms::ok(), bytes_to_binary(env, &bytes)).encode(env),
        Err(error) => encode_error(env, error),
    }
}

#[rustler::nif]
fn ntrip_request_headers<'a>(env: Env<'a>, handle: ResourceArc<NtripConfigResource>) -> Term<'a> {
    match handle.config.request_headers() {
        Ok((path, headers)) => (atoms::ok(), (path, headers)).encode(env),
        Err(error) => encode_error(env, error),
    }
}

#[rustler::nif]
fn ntrip_machine_new(
    handle: ResourceArc<NtripConfigResource>,
) -> ResourceArc<NtripMachineResource> {
    ResourceArc::new(NtripMachineResource {
        machine: Mutex::new(NtripClientMachine::new(handle.config.clone())),
    })
}

#[rustler::nif]
fn ntrip_machine_push<'a>(
    env: Env<'a>,
    handle: ResourceArc<NtripMachineResource>,
    bytes: Binary<'a>,
) -> NifResult<Vec<Term<'a>>> {
    let mut machine = lock_machine(&handle)?;
    Ok(machine
        .push(bytes.as_slice())
        .into_iter()
        .map(|event| encode_event(env, event))
        .collect())
}

#[rustler::nif]
fn ntrip_machine_finish<'a>(
    env: Env<'a>,
    handle: ResourceArc<NtripMachineResource>,
) -> NifResult<Vec<Term<'a>>> {
    let mut machine = lock_machine(&handle)?;
    Ok(machine
        .finish()
        .into_iter()
        .map(|event| encode_event(env, event))
        .collect())
}

#[rustler::nif]
fn ntrip_machine_gga<'a>(
    env: Env<'a>,
    handle: ResourceArc<NtripMachineResource>,
    now_s: f64,
    position: GgaPositionTerm,
    utc_seconds_of_day: f64,
) -> NifResult<Term<'a>> {
    let mut machine = lock_machine(&handle)?;
    match machine.try_gga_message(now_s, &position_from_term(position), utc_seconds_of_day) {
        Ok(Some(bytes)) => Ok((atoms::ok(), bytes_to_binary(env, &bytes)).encode(env)),
        Ok(None) => Ok((atoms::ok(), rustler::types::atom::nil()).encode(env)),
        Err(error) => Ok(encode_error(env, error)),
    }
}

#[rustler::nif]
fn ntrip_machine_reset(handle: ResourceArc<NtripMachineResource>) -> NifResult<rustler::Atom> {
    let mut machine = lock_machine(&handle)?;
    machine.reset();
    Ok(atoms::ok())
}

#[rustler::nif]
fn ntrip_machine_state(handle: ResourceArc<NtripMachineResource>) -> NifResult<rustler::Atom> {
    let machine = lock_machine(&handle)?;
    Ok(state_atom(machine.state()))
}

#[rustler::nif]
fn ntrip_classify_http_response<'a>(
    env: Env<'a>,
    status: u16,
    reason: String,
    headers: Vec<(String, String)>,
) -> Term<'a> {
    match classify_http_response(status, &reason, &headers) {
        HttpClassification::Stream { chunked } => (
            atoms::stream(),
            map_from_pairs(env, vec![("chunked", chunked.encode(env))]),
        )
            .encode(env),
        HttpClassification::Sourcetable { chunked } => (
            atoms::sourcetable(),
            map_from_pairs(env, vec![("chunked", chunked.encode(env))]),
        )
            .encode(env),
        HttpClassification::Rejection(rejection) => {
            (atoms::rejected(), encode_rejection(env, rejection)).encode(env)
        }
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn ntrip_parse_sourcetable<'a>(env: Env<'a>, bytes: Binary<'a>) -> Term<'a> {
    match std::str::from_utf8(bytes.as_slice()) {
        Ok(text) => match parse_sourcetable(text) {
            Ok(table) => (atoms::ok(), encode_table(env, table)).encode(env),
            Err(error) => encode_error(env, error),
        },
        Err(error) => encode_error(env, error),
    }
}

#[rustler::nif]
fn ntrip_sourcetable_to_text<'a>(
    env: Env<'a>,
    handle: ResourceArc<SourcetableResource>,
) -> Term<'a> {
    match handle.table.to_text() {
        Ok(text) => (atoms::ok(), text).encode(env),
        Err(error) => encode_error(env, error),
    }
}

#[rustler::nif]
fn ntrip_format_gga<'a>(
    env: Env<'a>,
    position: GgaPositionTerm,
    utc_seconds_of_day: f64,
) -> Term<'a> {
    match format_gga(&position_from_term(position), utc_seconds_of_day) {
        Ok(bytes) => (atoms::ok(), bytes_to_binary(env, &bytes)).encode(env),
        Err(error) => encode_error(env, error),
    }
}

#[rustler::nif]
fn rtcm_assembler_new() -> ResourceArc<RtcmAssemblerResource> {
    ResourceArc::new(RtcmAssemblerResource {
        assembler: Mutex::new(SsrStreamAssembler::new()),
    })
}

#[rustler::nif]
fn rtcm_assembler_push<'a>(
    env: Env<'a>,
    handle: ResourceArc<RtcmAssemblerResource>,
    bytes: Binary<'a>,
) -> NifResult<Vec<Term<'a>>> {
    let mut assembler = lock_assembler(&handle)?;
    Ok(assembler
        .push(bytes.as_slice())
        .into_iter()
        .map(|result| encode_message_result(env, result))
        .collect())
}
