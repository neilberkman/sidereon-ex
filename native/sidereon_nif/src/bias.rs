use rustler::{Encoder, Env, Error, NifResult, OwnedBinary, ResourceArc, Term};
use sidereon_core::astro::time::civil;
use sidereon_core::astro::time::model::{Instant, JulianDateSplit, TimeScale};
use sidereon_core::bias::{
    BiasDeparture, BiasError, BiasKind, BiasLookup, BiasMode, BiasNotice, BiasObservableFamily,
    BiasReadPolicy, BiasRecord, BiasSet, BiasTarget, CodeDcbOptions, Parsed,
};
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
        absent,
        unsupported_scale,
        ambiguous,
        carrier_frequency_required,
        invalid_carrier_frequency,
        carrier_frequency_unknown,
        undefined_slope_reference,
        invalid_epoch,
        unhandled,
        departure,
        invalid_utf8,
        repeated_declaration,
        conflicting_declaration,
        overlap,
        dcb_time_system_assumed,
        dcb_time_system_alias,
        header_layout,
        other_version,
        missing_footer,
        content_after_footer,
        unexpected_control_line,
        unclosed_block,
        unopened_block_end,
        mismatched_block_end,
        nested_block,
        missing_block,
        unknown_block,
        block_start_suffix,
        data_outside_block,
        missing_declaration,
        unsupported_bias_mode,
        non_standard_time_system,
        header_mode_mismatch,
        unknown_dcb_time_system,
        estimate_count_mismatch,
        unknown_observable,
        unsupported_version,
        missing_dcb_metadata,
        missing_clock_reference,
        missing_writer_metadata,
        utf8,
        unsupported_time_system,
        dcb_record_mismatch,
        io,
        other
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
    family: String,
    unit: String,
    line: Option<u64>,
}

/// The records an available lookup value comes from and the covering records a
/// later start overrides, as indices into the product's records.
#[derive(Debug, Clone, rustler::NifMap)]
struct LookupProvenanceTerm {
    records: Vec<u64>,
    overridden: Vec<u64>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct BiasInfoTerm {
    records: i64,
    skipped_records: i64,
    mode: String,
    time_scale: Option<String>,
    time_system_label: Option<String>,
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

fn read_policy(label: &str) -> NifResult<BiasReadPolicy> {
    match label {
        "strict" => Ok(BiasReadPolicy::Strict),
        "lenient" => Ok(BiasReadPolicy::Lenient),
        _ => Err(Error::Term(Box::new("unknown bias read policy"))),
    }
}

fn dcb_options(term: Option<CodeDcbOptionsTerm>) -> NifResult<Option<CodeDcbOptions>> {
    term.map(|opts| {
        let receiver_system = match opts.receiver_system {
            Some(letter) => Some(crate::sp3::system_from_letter(&letter)?),
            None => None,
        };
        let mut options = CodeDcbOptions::new(
            (opts.obs1, opts.obs2),
            opts.year,
            opts.month,
            parse_time_scale(&opts.time_scale)?,
        );
        options.receiver_system = receiver_system;
        Ok(options)
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
        JulianDateSplit::new(jd_whole, fraction).map_err(crate::tropo::time_model_error_detail)?,
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
        family: family_label(record.family).to_string(),
        unit: record.unit.label().to_string(),
        line: record.line.map(|line| line as u64),
    }
}

fn family_label(family: BiasObservableFamily) -> &'static str {
    match family {
        BiasObservableFamily::Code => "code",
        BiasObservableFamily::Phase => "phase",
        BiasObservableFamily::Mixed => "mixed",
    }
}

fn indices(values: &[usize]) -> Vec<u64> {
    values.iter().map(|&index| index as u64).collect()
}

/// `{:ok, value, %{records: [index], overridden: [index]}}` for an available
/// value, `{:error, reason}` for every other lookup status.
fn encode_lookup<'a>(env: Env<'a>, lookup: BiasLookup) -> Term<'a> {
    match lookup {
        BiasLookup::Available {
            value,
            records,
            overridden,
        } => {
            let provenance = LookupProvenanceTerm {
                records: indices(&records),
                overridden: indices(&overridden),
            };
            (atoms::ok(), value, provenance).encode(env)
        }
        BiasLookup::Absent => (atoms::error(), atoms::absent()).encode(env),
        BiasLookup::UnsupportedScale { product, query } => (
            atoms::error(),
            (
                atoms::unsupported_scale(),
                product.map(|scale| scale.abbrev().to_string()),
                query.abbrev().to_string(),
            ),
        )
            .encode(env),
        BiasLookup::Ambiguous { records } => {
            (atoms::error(), (atoms::ambiguous(), indices(&records))).encode(env)
        }
        BiasLookup::CarrierFrequencyRequired { record } => (
            atoms::error(),
            (atoms::carrier_frequency_required(), record as u64),
        )
            .encode(env),
        BiasLookup::InvalidCarrierFrequency => {
            (atoms::error(), atoms::invalid_carrier_frequency()).encode(env)
        }
        BiasLookup::CarrierFrequencyUnknown { observable } => (
            atoms::error(),
            (atoms::carrier_frequency_unknown(), observable),
        )
            .encode(env),
        BiasLookup::UndefinedSlopeReference { record } => (
            atoms::error(),
            (atoms::undefined_slope_reference(), record as u64),
        )
            .encode(env),
        BiasLookup::InvalidEpoch => (atoms::error(), atoms::invalid_epoch()).encode(env),
        other => (atoms::error(), (atoms::unhandled(), format!("{other:?}"))).encode(env),
    }
}

fn mode_label(mode: BiasMode) -> &'static str {
    match mode {
        BiasMode::Absolute => "absolute",
        BiasMode::Relative => "relative",
        BiasMode::Unspecified => "unspecified",
    }
}

fn encode_departure<'a>(env: Env<'a>, departure: &BiasDeparture) -> Term<'a> {
    match departure {
        BiasDeparture::HeaderLayout { reason } => (atoms::header_layout(), *reason).encode(env),
        BiasDeparture::OtherVersion { version } => {
            (atoms::other_version(), version.as_str()).encode(env)
        }
        BiasDeparture::MissingFooter => atoms::missing_footer().encode(env),
        BiasDeparture::ContentAfterFooter { line } => {
            (atoms::content_after_footer(), *line as u64).encode(env)
        }
        BiasDeparture::UnexpectedControlLine { line } => {
            (atoms::unexpected_control_line(), *line as u64).encode(env)
        }
        BiasDeparture::UnclosedBlock { name, line } => {
            (atoms::unclosed_block(), name.as_str(), *line as u64).encode(env)
        }
        BiasDeparture::UnopenedBlockEnd { name, line } => {
            (atoms::unopened_block_end(), name.as_str(), *line as u64).encode(env)
        }
        BiasDeparture::MismatchedBlockEnd { open, close, line } => (
            atoms::mismatched_block_end(),
            open.as_str(),
            close.as_str(),
            *line as u64,
        )
            .encode(env),
        BiasDeparture::NestedBlock { open, inner, line } => (
            atoms::nested_block(),
            open.as_str(),
            inner.as_str(),
            *line as u64,
        )
            .encode(env),
        BiasDeparture::MissingBlock { name } => (atoms::missing_block(), *name).encode(env),
        BiasDeparture::UnknownBlock { name, line } => {
            (atoms::unknown_block(), name.as_str(), *line as u64).encode(env)
        }
        BiasDeparture::BlockStartSuffix { line } => {
            (atoms::block_start_suffix(), *line as u64).encode(env)
        }
        BiasDeparture::DataOutsideBlock { line } => {
            (atoms::data_outside_block(), *line as u64).encode(env)
        }
        BiasDeparture::MissingDeclaration { keyword } => {
            (atoms::missing_declaration(), *keyword).encode(env)
        }
        BiasDeparture::UnsupportedBiasMode { line, label } => {
            (atoms::unsupported_bias_mode(), *line as u64, label.as_str()).encode(env)
        }
        BiasDeparture::NonStandardTimeSystem { line, label } => (
            atoms::non_standard_time_system(),
            *line as u64,
            label.as_str(),
        )
            .encode(env),
        BiasDeparture::HeaderModeMismatch {
            header,
            description,
        } => (
            atoms::header_mode_mismatch(),
            header.as_str(),
            mode_label(*description),
        )
            .encode(env),
        BiasDeparture::UnknownDcbTimeSystem { line, label } => (
            atoms::unknown_dcb_time_system(),
            *line as u64,
            label.as_str(),
        )
            .encode(env),
        BiasDeparture::EstimateCountMismatch {
            declared,
            solution_rows,
        } => (
            atoms::estimate_count_mismatch(),
            *declared,
            *solution_rows as u64,
        )
            .encode(env),
        other => (atoms::other(), format!("{other:?}")).encode(env),
    }
}

fn encode_notice<'a>(env: Env<'a>, notice: &BiasNotice) -> Term<'a> {
    match notice {
        BiasNotice::Departure(departure) => {
            (atoms::departure(), encode_departure(env, departure)).encode(env)
        }
        BiasNotice::InvalidUtf8 { line } => (atoms::invalid_utf8(), *line as u64).encode(env),
        BiasNotice::RepeatedDeclaration { line, keyword } => {
            (atoms::repeated_declaration(), *line as u64, *keyword).encode(env)
        }
        BiasNotice::ConflictingDeclaration { line, keyword } => {
            (atoms::conflicting_declaration(), *line as u64, *keyword).encode(env)
        }
        BiasNotice::Overlap { first, second } => {
            (atoms::overlap(), *first as u64, *second as u64).encode(env)
        }
        BiasNotice::DcbTimeSystemAssumed => atoms::dcb_time_system_assumed().encode(env),
        BiasNotice::DcbTimeSystemAlias { line, label } => {
            (atoms::dcb_time_system_alias(), *line as u64, label.as_str()).encode(env)
        }
        other => (atoms::other(), format!("{other:?}")).encode(env),
    }
}

fn encode_bias_error<'a>(env: Env<'a>, error: &BiasError) -> Term<'a> {
    match error {
        BiasError::InvalidInput { field, reason } => {
            (atoms::invalid_input(), *field, *reason).encode(env)
        }
        BiasError::InvalidEpoch => atoms::invalid_epoch().encode(env),
        BiasError::UnknownObservable { code } => {
            (atoms::unknown_observable(), code.as_str()).encode(env)
        }
        BiasError::UnsupportedVersion { version } => {
            (atoms::unsupported_version(), version.as_str()).encode(env)
        }
        BiasError::MissingDcbMetadata => atoms::missing_dcb_metadata().encode(env),
        BiasError::MissingClockReference => atoms::missing_clock_reference().encode(env),
        BiasError::MissingWriterMetadata { field } => {
            (atoms::missing_writer_metadata(), *field).encode(env)
        }
        BiasError::Utf8 => atoms::utf8().encode(env),
        BiasError::Departure { departure } => {
            (atoms::departure(), encode_departure(env, departure)).encode(env)
        }
        BiasError::InvalidUtf8Line { line } => (atoms::invalid_utf8(), *line as u64).encode(env),
        BiasError::UnsupportedTimeSystem { scale } => (
            atoms::unsupported_time_system(),
            scale.map(|value| value.abbrev()),
        )
            .encode(env),
        BiasError::DcbRecordMismatch { record, field } => {
            (atoms::dcb_record_mismatch(), *record as u64, *field).encode(env)
        }
    }
}

fn encode_bias_read_error<'a>(env: Env<'a>, error: &sidereon::Error) -> Term<'a> {
    if let sidereon::Error::Bias(error) = error {
        encode_bias_error(env, error)
    } else if let sidereon::Error::Io(error) = error {
        (atoms::io(), error.to_string()).encode(env)
    } else {
        (atoms::other(), error.to_string()).encode(env)
    }
}

fn encode_bias_set_result<'a>(env: Env<'a>, result: Result<BiasSet, sidereon::Error>) -> Term<'a> {
    match result {
        Ok(set) => ResourceArc::new(BiasResource { set }).encode(env),
        Err(error) => (atoms::error(), encode_bias_read_error(env, &error)).encode(env),
    }
}

fn encode_bias_parsed_result<'a>(
    env: Env<'a>,
    result: Result<Parsed<BiasSet>, sidereon::Error>,
) -> Term<'a> {
    match result {
        Ok(parsed) => (
            atoms::ok(),
            ResourceArc::new(BiasResource { set: parsed.value }),
            parsed.diagnostics.skips.len() as i64,
        )
            .encode(env),
        Err(error) => (atoms::error(), encode_bias_read_error(env, &error)).encode(env),
    }
}

fn bytes_to_binary<'a>(env: Env<'a>, bytes: &[u8]) -> Term<'a> {
    let mut binary = OwnedBinary::new(bytes.len()).expect("allocate bias product binary");
    binary.as_mut_slice().copy_from_slice(bytes);
    binary.release(env).encode(env)
}

fn info_term(set: &BiasSet) -> BiasInfoTerm {
    BiasInfoTerm {
        records: set.records().len() as i64,
        skipped_records: set.skipped_records() as i64,
        mode: mode_label(set.mode()).to_string(),
        time_scale: set.time_scale().map(|scale| scale.abbrev().to_string()),
        time_system_label: set.time_system_label().map(str::to_string),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn bias_parse_sinex<'a>(
    env: Env<'a>,
    bytes: rustler::Binary,
    policy: String,
) -> NifResult<Term<'a>> {
    Ok(encode_bias_set_result(
        env,
        sidereon::parse_bias_sinex_with_policy(bytes.as_slice(), read_policy(&policy)?),
    ))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn bias_parse_sinex_lossy<'a>(
    env: Env<'a>,
    bytes: rustler::Binary,
    policy: String,
) -> NifResult<Term<'a>> {
    Ok(encode_bias_parsed_result(
        env,
        sidereon::parse_bias_sinex_lossy_with_policy(bytes.as_slice(), read_policy(&policy)?),
    ))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn bias_load_sinex<'a>(env: Env<'a>, path: String, policy: String) -> NifResult<Term<'a>> {
    Ok(encode_bias_set_result(
        env,
        sidereon::load_bias_sinex_with_policy(path, read_policy(&policy)?),
    ))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn bias_load_sinex_lossy<'a>(env: Env<'a>, path: String, policy: String) -> NifResult<Term<'a>> {
    Ok(encode_bias_parsed_result(
        env,
        sidereon::load_bias_sinex_lossy_with_policy(path, read_policy(&policy)?),
    ))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn bias_parse_code_dcb<'a>(
    env: Env<'a>,
    bytes: rustler::Binary,
    options: Option<CodeDcbOptionsTerm>,
    policy: String,
) -> NifResult<Term<'a>> {
    Ok(encode_bias_set_result(
        env,
        sidereon::parse_code_dcb_with_policy(
            bytes.as_slice(),
            dcb_options(options)?,
            read_policy(&policy)?,
        ),
    ))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn bias_parse_code_dcb_lossy<'a>(
    env: Env<'a>,
    bytes: rustler::Binary,
    options: Option<CodeDcbOptionsTerm>,
    policy: String,
) -> NifResult<Term<'a>> {
    Ok(encode_bias_parsed_result(
        env,
        sidereon::parse_code_dcb_lossy_with_policy(
            bytes.as_slice(),
            dcb_options(options)?,
            read_policy(&policy)?,
        ),
    ))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn bias_load_code_dcb<'a>(
    env: Env<'a>,
    path: String,
    options: Option<CodeDcbOptionsTerm>,
    policy: String,
) -> NifResult<Term<'a>> {
    Ok(encode_bias_set_result(
        env,
        sidereon::load_code_dcb_with_policy(path, dcb_options(options)?, read_policy(&policy)?),
    ))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn bias_load_code_dcb_lossy<'a>(
    env: Env<'a>,
    path: String,
    options: Option<CodeDcbOptionsTerm>,
    policy: String,
) -> NifResult<Term<'a>> {
    Ok(encode_bias_parsed_result(
        env,
        sidereon::load_code_dcb_lossy_with_policy(
            path,
            dcb_options(options)?,
            read_policy(&policy)?,
        ),
    ))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn bias_write_sinex<'a>(env: Env<'a>, handle: ResourceArc<BiasResource>) -> Term<'a> {
    match sidereon::bias::write_bias_sinex(&handle.set) {
        Ok(text) => (atoms::ok(), text).encode(env),
        Err(error) => (atoms::error(), encode_bias_error(env, &error)).encode(env),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn bias_write_sinex_bytes<'a>(env: Env<'a>, handle: ResourceArc<BiasResource>) -> Term<'a> {
    match sidereon::bias::write_bias_sinex_bytes(&handle.set) {
        Ok(bytes) => (atoms::ok(), bytes_to_binary(env, &bytes)).encode(env),
        Err(error) => (atoms::error(), encode_bias_error(env, &error)).encode(env),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn bias_write_code_dcb<'a>(env: Env<'a>, handle: ResourceArc<BiasResource>) -> Term<'a> {
    match sidereon::bias::write_code_dcb(&handle.set) {
        Ok(text) => (atoms::ok(), text).encode(env),
        Err(error) => (atoms::error(), encode_bias_error(env, &error)).encode(env),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn bias_write_code_dcb_bytes<'a>(env: Env<'a>, handle: ResourceArc<BiasResource>) -> Term<'a> {
    match sidereon::bias::write_code_dcb_bytes(&handle.set) {
        Ok(bytes) => (atoms::ok(), bytes_to_binary(env, &bytes)).encode(env),
        Err(error) => (atoms::error(), encode_bias_error(env, &error)).encode(env),
    }
}

#[rustler::nif]
fn bias_info(handle: ResourceArc<BiasResource>) -> BiasInfoTerm {
    info_term(&handle.set)
}

/// Non-fatal findings about the product, each a tagged tuple.
#[rustler::nif]
fn bias_notices<'a>(env: Env<'a>, handle: ResourceArc<BiasResource>) -> Vec<Term<'a>> {
    handle
        .set
        .notices()
        .iter()
        .map(|notice| encode_notice(env, notice))
        .collect()
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
    Ok(encode_lookup(
        env,
        handle.set.code_osb_seconds(sat, &obs, epoch),
    ))
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
    Ok(encode_lookup(
        env,
        handle.set.code_dsb_seconds(sat, &obs1, &obs2, epoch),
    ))
}
