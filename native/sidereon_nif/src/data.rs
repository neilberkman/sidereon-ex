//! Rustler boundary for the pure data catalog and terrain conversion APIs.
//!
//! This module contains only term translation. Catalog derivation and HGT to
//! DTED conversion remain in `sidereon-core`; transport and cache IO remain in
//! Elixir.

use rustler::{Binary, Encoder, Env, OwnedBinary, Term};
use sidereon_core::data::{
    self, AnalysisCenter, DataCatalogError, DistributionSource, HgtConversionError,
    ProductCampaign, ProductDate, ProductDateTime, ProductFormat, ProductIdentity,
    ProductPublisher, ProductType, SolutionClass, SpaceWeatherProduct,
};

mod atoms {
    rustler::atoms! {
        ok,
        error,
        unknown_center,
        unsupported_product,
        unrecognized_archive_listing,
        invalid_coordinate,
        invalid_tile_index,
        invalid_tile_id,
        decompress,
        bad_hgt_length,
        invalid_unix_compress,
        size_limit,
        no_open_mirror,
        unknown_product_type,
        exact_product_set,

        // Lossless catalog-error detail. The eight historical public tuples
        // keep their existing representation; variants which used to collapse
        // to `unsupported_product` use this fixed vocabulary.
        catalog_error,
        unsupported_distribution,
        unsupported_product_era,
        unsupported_distribution_era,
        no_distribution_sources,
        invalid_official_filename,
        inconsistent_product_identity,
        invalid_date,
        date_out_of_range,
        date_before_gps_epoch,
        invalid_gps_day_of_week,
        invalid_sample,
        unsupported_sample,
        invalid_span,
        invalid_issue,
        missing_issue,
        unexpected_issue,
        unsupported_issue,
        invalid_date_time,
        no_ultra_issue,
        no_available_ultra_issue,
        unsupported_nominal_schedule,
        invalid_station,
        kind,
        message,
        value,
        center,
        product_type,
        source,
        date,
        field,
        year,
        month,
        day,
        gps_day,
        sample,
        issue,
        hour,
        minute,
        second,
        reason,
        lat_deg_bits,
        lon_deg_bits,
        lat_index,
        lon_index,
    }
}

fn bytes_to_binary<'a>(env: Env<'a>, bytes: &[u8]) -> Term<'a> {
    let mut binary = OwnedBinary::new(bytes.len()).expect("allocate data binary");
    binary.as_mut_slice().copy_from_slice(bytes);
    binary.release(env).encode(env)
}

fn center(code: &str) -> Result<AnalysisCenter, DataCatalogError> {
    code.parse()
}

fn product_type(code: &str) -> Result<ProductType, DataCatalogError> {
    code.parse()
}

fn distribution_source(code: &str) -> Result<DistributionSource, DataCatalogError> {
    match code {
        "direct" => Ok(DistributionSource::Direct),
        "nasa_cddis" => Ok(DistributionSource::NasaCddis),
        "local_file" => Ok(DistributionSource::LocalFile),
        "in_memory" => Ok(DistributionSource::InMemory),
        _ => Err(DataCatalogError::InconsistentProductIdentity {
            field: "distribution_source",
        }),
    }
}

fn identity_field_error(field: &'static str) -> DataCatalogError {
    DataCatalogError::InconsistentProductIdentity { field }
}

pub(crate) fn product_identity(fields: Vec<String>) -> Result<ProductIdentity, DataCatalogError> {
    if fields.len() != 16 {
        return Err(identity_field_error("field_count"));
    }
    let family = product_type(&fields[0])?;
    let analysis_center = center(&fields[1])?;
    let publisher = match fields[2].as_str() {
        "IGS" => ProductPublisher::Igs,
        "COD" => ProductPublisher::Code,
        "ESA" => ProductPublisher::Esa,
        "GFZ" => ProductPublisher::Gfz,
        "WUM" => ProductPublisher::Whu,
        _ => return Err(identity_field_error("publisher")),
    };
    let solution = match fields[3].as_str() {
        "final" => SolutionClass::Final,
        "rapid" => SolutionClass::Rapid,
        "ultra_rapid" => SolutionClass::UltraRapid,
        "predicted" => SolutionClass::Predicted,
        "broadcast" => SolutionClass::Broadcast,
        "near_real_time" => SolutionClass::NearRealTime,
        _ => return Err(identity_field_error("solution_class")),
    };
    let campaign = match fields[4].as_str() {
        "OPS" => ProductCampaign::Operational,
        "MGN" => ProductCampaign::MultiGnss,
        "MGX" => ProductCampaign::MultiGnssExperiment,
        "BRD" => ProductCampaign::Broadcast,
        _ => return Err(identity_field_error("campaign")),
    };
    let version = fields[5]
        .parse::<u8>()
        .map_err(|_| identity_field_error("filename_version"))?;
    let year = fields[6]
        .parse::<i32>()
        .map_err(|_| identity_field_error("date"))?;
    let month = fields[7]
        .parse::<u8>()
        .map_err(|_| identity_field_error("date"))?;
    let day = fields[8]
        .parse::<u8>()
        .map_err(|_| identity_field_error("date"))?;
    let format = match fields[13].as_str() {
        "SP3" => ProductFormat::Sp3,
        "IONEX" => ProductFormat::Ionex,
        "RINEX_CLK" => ProductFormat::RinexClock,
        "RINEX_NAV" => ProductFormat::RinexNavigation,
        _ => return Err(identity_field_error("format")),
    };
    let prediction_horizon_days = if fields[15].is_empty() {
        None
    } else {
        Some(
            fields[15]
                .parse::<u8>()
                .map_err(|_| identity_field_error("prediction_horizon_days"))?,
        )
    };
    let identity = ProductIdentity {
        family,
        analysis_center,
        publisher,
        solution,
        campaign,
        version,
        date: ProductDate::new(year, month, day)?,
        issue: (!fields[9].is_empty()).then(|| fields[9].clone()),
        span: fields[10].clone(),
        sample: fields[11].clone(),
        official_filename: fields[12].clone(),
        format,
        format_version: (!fields[14].is_empty()).then(|| fields[14].clone()),
        prediction_horizon_days,
    };
    identity.validate()?;
    Ok(identity)
}

pub(crate) fn product_identity_fields(identity: &ProductIdentity) -> Vec<String> {
    vec![
        identity.family.code().to_string(),
        identity.analysis_center.code().to_string(),
        identity.publisher.code().to_string(),
        identity.solution.code().to_string(),
        identity.campaign.code().to_string(),
        identity.version.to_string(),
        identity.date.year.to_string(),
        identity.date.month.to_string(),
        identity.date.day.to_string(),
        identity.issue.clone().unwrap_or_default(),
        identity.span.clone(),
        identity.sample.clone(),
        identity.official_filename.clone(),
        identity.format.code().to_string(),
        identity.format_version.clone().unwrap_or_default(),
        identity
            .prediction_horizon_days
            .map_or_else(String::new, |days| days.to_string()),
    ]
}

fn space_weather_product(code: &str) -> Result<SpaceWeatherProduct, DataCatalogError> {
    code.parse()
}

fn product_date(year: i32, month: i32, day: i32) -> Result<ProductDate, DataCatalogError> {
    let month = u8::try_from(month).map_err(|_| DataCatalogError::DateOutOfRange)?;
    let day = u8::try_from(day).map_err(|_| DataCatalogError::DateOutOfRange)?;
    ProductDate::new(year, month, day)
}

fn product_datetime(
    year: i32,
    month: i32,
    day: i32,
    hour: i32,
    minute: i32,
    second: i32,
) -> Result<ProductDateTime, DataCatalogError> {
    let date = product_date(year, month, day)?;
    let hour = u8::try_from(hour).map_err(|_| DataCatalogError::DateOutOfRange)?;
    let minute = u8::try_from(minute).map_err(|_| DataCatalogError::DateOutOfRange)?;
    let second = u8::try_from(second).map_err(|_| DataCatalogError::DateOutOfRange)?;
    ProductDateTime::new(date, hour, minute, second)
}

type ProductDateTimeTuple = ((i32, u8, u8), (u8, u8, u8));
type NominalCoverageIntervalTuple = (ProductDateTimeTuple, ProductDateTimeTuple);
type NominalIssueTuple = (
    Vec<String>,
    ProductDateTimeTuple,
    (
        Option<NominalCoverageIntervalTuple>,
        Option<NominalCoverageIntervalTuple>,
    ),
);

fn product_datetime_tuple(datetime: ProductDateTime) -> ProductDateTimeTuple {
    (
        (datetime.date.year, datetime.date.month, datetime.date.day),
        (datetime.hour, datetime.minute, datetime.second),
    )
}

fn nominal_coverage_interval_tuple(
    interval: data::NominalCoverageInterval,
) -> NominalCoverageIntervalTuple {
    (
        product_datetime_tuple(interval.from),
        product_datetime_tuple(interval.until),
    )
}

#[derive(Debug, Clone, PartialEq)]
enum CatalogProjectionValue {
    Text(String),
    I32(i32),
    U8(u8),
    Date(ProductDate),
}

#[derive(Debug, Clone, PartialEq)]
struct CatalogErrorProjection {
    kind: &'static str,
    fields: Vec<(&'static str, CatalogProjectionValue)>,
    message: String,
}

fn catalog_error_projection(error: &DataCatalogError) -> CatalogErrorProjection {
    use CatalogProjectionValue as Value;

    let projection = |kind, fields| CatalogErrorProjection {
        kind,
        fields,
        message: error.to_string(),
    };

    match error {
        DataCatalogError::UnknownCenter(value) => projection(
            "unknown_center",
            vec![("value", Value::Text(value.clone()))],
        ),
        DataCatalogError::UnknownProductType(value) => projection(
            "unknown_product_type",
            vec![("value", Value::Text(value.clone()))],
        ),
        DataCatalogError::UnsupportedProduct {
            center,
            product_type,
        } => projection(
            "unsupported_product",
            vec![
                ("center", Value::Text(center.code().to_owned())),
                ("product_type", Value::Text(product_type.code().to_owned())),
            ],
        ),
        DataCatalogError::UnsupportedDistribution {
            source,
            product_type,
        } => projection(
            "unsupported_distribution",
            vec![
                ("source", Value::Text(source.code().to_owned())),
                ("product_type", Value::Text(product_type.code().to_owned())),
            ],
        ),
        DataCatalogError::UnsupportedProductEra {
            center,
            product_type,
            date,
        } => projection(
            "unsupported_product_era",
            vec![
                ("center", Value::Text(center.code().to_owned())),
                ("product_type", Value::Text(product_type.code().to_owned())),
                ("date", Value::Date(*date)),
            ],
        ),
        DataCatalogError::UnsupportedDistributionEra {
            source,
            center,
            product_type,
            date,
        } => projection(
            "unsupported_distribution_era",
            vec![
                ("source", Value::Text(source.code().to_owned())),
                ("center", Value::Text(center.code().to_owned())),
                ("product_type", Value::Text(product_type.code().to_owned())),
                ("date", Value::Date(*date)),
            ],
        ),
        DataCatalogError::NoDistributionSources => projection("no_distribution_sources", vec![]),
        DataCatalogError::InvalidOfficialFilename(value) => projection(
            "invalid_official_filename",
            vec![("value", Value::Text(value.clone()))],
        ),
        DataCatalogError::InconsistentProductIdentity { field } => projection(
            "inconsistent_product_identity",
            vec![("field", Value::Text((*field).to_owned()))],
        ),
        DataCatalogError::NoOpenMirror {
            center,
            product_type,
        } => projection(
            "no_open_mirror",
            vec![
                ("center", Value::Text(center.clone())),
                ("product_type", Value::Text(product_type.clone())),
            ],
        ),
        DataCatalogError::InvalidDate { year, month, day } => projection(
            "invalid_date",
            vec![
                ("year", Value::I32(*year)),
                ("month", Value::U8(*month)),
                ("day", Value::U8(*day)),
            ],
        ),
        DataCatalogError::DateOutOfRange => projection("date_out_of_range", vec![]),
        DataCatalogError::DateBeforeGpsEpoch(date) => {
            projection("date_before_gps_epoch", vec![("date", Value::Date(*date))])
        }
        DataCatalogError::InvalidGpsDayOfWeek(day) => projection(
            "invalid_gps_day_of_week",
            vec![("gps_day", Value::U8(*day))],
        ),
        DataCatalogError::InvalidSample(value) => projection(
            "invalid_sample",
            vec![("value", Value::Text(value.clone()))],
        ),
        DataCatalogError::UnsupportedSample {
            center,
            product_type,
            sample,
        } => projection(
            "unsupported_sample",
            vec![
                ("center", Value::Text(center.code().to_owned())),
                ("product_type", Value::Text(product_type.code().to_owned())),
                ("sample", Value::Text(sample.clone())),
            ],
        ),
        DataCatalogError::InvalidSpan(value) => {
            projection("invalid_span", vec![("value", Value::Text(value.clone()))])
        }
        DataCatalogError::InvalidIssue(value) => {
            projection("invalid_issue", vec![("value", Value::Text(value.clone()))])
        }
        DataCatalogError::MissingIssue { center } => projection(
            "missing_issue",
            vec![("center", Value::Text(center.code().to_owned()))],
        ),
        DataCatalogError::UnexpectedIssue { center } => projection(
            "unexpected_issue",
            vec![("center", Value::Text(center.code().to_owned()))],
        ),
        DataCatalogError::UnsupportedIssue { center, issue } => projection(
            "unsupported_issue",
            vec![
                ("center", Value::Text(center.code().to_owned())),
                ("issue", Value::Text(issue.clone())),
            ],
        ),
        DataCatalogError::InvalidDateTime {
            hour,
            minute,
            second,
        } => projection(
            "invalid_date_time",
            vec![
                ("hour", Value::U8(*hour)),
                ("minute", Value::U8(*minute)),
                ("second", Value::U8(*second)),
            ],
        ),
        DataCatalogError::NoUltraIssue => projection("no_ultra_issue", vec![]),
        DataCatalogError::NoAvailableUltraIssue => projection("no_available_ultra_issue", vec![]),
        DataCatalogError::UnsupportedNominalSchedule {
            center,
            product_type,
        } => projection(
            "unsupported_nominal_schedule",
            vec![
                ("center", Value::Text(center.code().to_owned())),
                ("product_type", Value::Text(product_type.code().to_owned())),
            ],
        ),
        DataCatalogError::UnrecognizedArchiveListing { reason } => projection(
            "unrecognized_archive_listing",
            vec![("reason", Value::Text(reason.clone()))],
        ),
        DataCatalogError::InvalidStation(value) => projection(
            "invalid_station",
            vec![("value", Value::Text(value.clone()))],
        ),
        DataCatalogError::InvalidCoordinate {
            lat_deg_bits,
            lon_deg_bits,
        } => projection(
            "invalid_coordinate",
            vec![
                ("lat_deg_bits", Value::Text(format!("{lat_deg_bits:016x}"))),
                ("lon_deg_bits", Value::Text(format!("{lon_deg_bits:016x}"))),
            ],
        ),
        DataCatalogError::InvalidTileIndex {
            lat_index,
            lon_index,
        } => projection(
            "invalid_tile_index",
            vec![
                ("lat_index", Value::I32(*lat_index)),
                ("lon_index", Value::I32(*lon_index)),
            ],
        ),
        DataCatalogError::InvalidTileId(value) => projection(
            "invalid_tile_id",
            vec![("value", Value::Text(value.clone()))],
        ),
    }
}

fn catalog_atom(name: &str) -> rustler::Atom {
    match name {
        "unknown_center" => atoms::unknown_center(),
        "unknown_product_type" => atoms::unknown_product_type(),
        "unsupported_product" => atoms::unsupported_product(),
        "unsupported_distribution" => atoms::unsupported_distribution(),
        "unsupported_product_era" => atoms::unsupported_product_era(),
        "unsupported_distribution_era" => atoms::unsupported_distribution_era(),
        "no_distribution_sources" => atoms::no_distribution_sources(),
        "invalid_official_filename" => atoms::invalid_official_filename(),
        "inconsistent_product_identity" => atoms::inconsistent_product_identity(),
        "no_open_mirror" => atoms::no_open_mirror(),
        "invalid_date" => atoms::invalid_date(),
        "date_out_of_range" => atoms::date_out_of_range(),
        "date_before_gps_epoch" => atoms::date_before_gps_epoch(),
        "invalid_gps_day_of_week" => atoms::invalid_gps_day_of_week(),
        "invalid_sample" => atoms::invalid_sample(),
        "unsupported_sample" => atoms::unsupported_sample(),
        "invalid_span" => atoms::invalid_span(),
        "invalid_issue" => atoms::invalid_issue(),
        "missing_issue" => atoms::missing_issue(),
        "unexpected_issue" => atoms::unexpected_issue(),
        "unsupported_issue" => atoms::unsupported_issue(),
        "invalid_date_time" => atoms::invalid_date_time(),
        "no_ultra_issue" => atoms::no_ultra_issue(),
        "no_available_ultra_issue" => atoms::no_available_ultra_issue(),
        "unsupported_nominal_schedule" => atoms::unsupported_nominal_schedule(),
        "unrecognized_archive_listing" => atoms::unrecognized_archive_listing(),
        "invalid_station" => atoms::invalid_station(),
        "invalid_coordinate" => atoms::invalid_coordinate(),
        "invalid_tile_index" => atoms::invalid_tile_index(),
        "invalid_tile_id" => atoms::invalid_tile_id(),
        "value" => atoms::value(),
        "center" => atoms::center(),
        "product_type" => atoms::product_type(),
        "source" => atoms::source(),
        "date" => atoms::date(),
        "field" => atoms::field(),
        "year" => atoms::year(),
        "month" => atoms::month(),
        "day" => atoms::day(),
        "gps_day" => atoms::gps_day(),
        "sample" => atoms::sample(),
        "issue" => atoms::issue(),
        "hour" => atoms::hour(),
        "minute" => atoms::minute(),
        "second" => atoms::second(),
        "reason" => atoms::reason(),
        "lat_deg_bits" => atoms::lat_deg_bits(),
        "lon_deg_bits" => atoms::lon_deg_bits(),
        "lat_index" => atoms::lat_index(),
        "lon_index" => atoms::lon_index(),
        other => panic!("unrecognized fixed catalog atom {other}"),
    }
}

fn catalog_projection_value_term<'a>(env: Env<'a>, value: CatalogProjectionValue) -> Term<'a> {
    match value {
        CatalogProjectionValue::Text(value) => value.encode(env),
        CatalogProjectionValue::I32(value) => value.encode(env),
        CatalogProjectionValue::U8(value) => value.encode(env),
        CatalogProjectionValue::Date(value) => (value.year, value.month, value.day).encode(env),
    }
}

fn catalog_projection_term<'a>(env: Env<'a>, projection: CatalogErrorProjection) -> Term<'a> {
    let mut map = rustler::types::map::map_new(env);
    map = map
        .map_put(atoms::kind(), catalog_atom(projection.kind))
        .expect("catalog detail is a map");
    map = map
        .map_put(atoms::message(), projection.message)
        .expect("catalog detail is a map");
    for (name, value) in projection.fields {
        map = map
            .map_put(
                catalog_atom(name),
                catalog_projection_value_term(env, value),
            )
            .expect("catalog detail is a map");
    }
    map
}

fn encode_catalog_error<'a>(env: Env<'a>, err: DataCatalogError) -> Term<'a> {
    let projection = catalog_error_projection(&err);
    match err {
        DataCatalogError::UnknownCenter(code) => {
            (atoms::error(), (atoms::unknown_center(), code)).encode(env)
        }
        DataCatalogError::UnknownProductType(code) => (
            atoms::error(),
            (
                atoms::unsupported_product(),
                (atoms::unknown_product_type(), code),
            ),
        )
            .encode(env),
        DataCatalogError::UnsupportedProduct {
            center,
            product_type,
        } => (
            atoms::error(),
            (
                atoms::unsupported_product(),
                format!("{}/{}", center.code(), product_type.code()),
            ),
        )
            .encode(env),
        DataCatalogError::NoOpenMirror {
            center,
            product_type,
        } => (
            atoms::error(),
            (
                atoms::unsupported_product(),
                (atoms::no_open_mirror(), center, product_type),
            ),
        )
            .encode(env),
        DataCatalogError::InvalidCoordinate {
            lat_deg_bits,
            lon_deg_bits,
        } => (
            atoms::error(),
            (
                atoms::invalid_coordinate(),
                f64::from_bits(lat_deg_bits),
                f64::from_bits(lon_deg_bits),
            ),
        )
            .encode(env),
        DataCatalogError::InvalidTileIndex {
            lat_index,
            lon_index,
        } => (
            atoms::error(),
            (atoms::invalid_tile_index(), lat_index, lon_index),
        )
            .encode(env),
        DataCatalogError::InvalidTileId(id) => {
            (atoms::error(), (atoms::invalid_tile_id(), id)).encode(env)
        }
        // Closed dialect detection: an unreadable listing must stay
        // distinguishable from every other catalog failure, because callers
        // map it to "unreachable", never "nothing published".
        DataCatalogError::UnrecognizedArchiveListing { reason } => (
            atoms::error(),
            (atoms::unrecognized_archive_listing(), reason),
        )
            .encode(env),
        _ => (
            atoms::error(),
            (
                atoms::unsupported_product(),
                (
                    atoms::catalog_error(),
                    catalog_projection_term(env, projection),
                ),
            ),
        )
            .encode(env),
    }
}

fn encode_hgt_error<'a>(env: Env<'a>, err: HgtConversionError) -> Term<'a> {
    match err {
        HgtConversionError::BadLength { expected, got } => (
            atoms::error(),
            (
                atoms::decompress(),
                (atoms::bad_hgt_length(), expected as u64, got as u64),
            ),
        )
            .encode(env),
        HgtConversionError::InvalidTileIndex {
            lat_index,
            lon_index,
        } => (
            atoms::error(),
            (atoms::invalid_tile_index(), lat_index, lon_index),
        )
            .encode(env),
    }
}

fn encode_result<'a, T, F>(
    env: Env<'a>,
    result: Result<T, DataCatalogError>,
    encode_ok: F,
) -> Term<'a>
where
    F: FnOnce(Env<'a>, T) -> Term<'a>,
{
    match result {
        Ok(value) => (atoms::ok(), encode_ok(env, value)).encode(env),
        Err(err) => encode_catalog_error(env, err),
    }
}

#[rustler::nif]
fn data_centers() -> Vec<String> {
    data::centers()
        .iter()
        .map(|center| center.code().to_string())
        .collect()
}

#[rustler::nif]
fn data_content_types() -> Vec<String> {
    data::product_types()
        .iter()
        .map(|entry| entry.product_type.code().to_string())
        .collect()
}

#[rustler::nif]
fn data_allowed_hosts() -> Vec<String> {
    data::allowed_hosts()
        .iter()
        .map(|host| (*host).to_string())
        .collect()
}

#[rustler::nif]
fn data_validate_exact_product_set<'a>(
    env: Env<'a>,
    expected: Vec<Vec<String>>,
    available: Vec<Vec<String>>,
) -> Term<'a> {
    let expected = expected
        .into_iter()
        .map(product_identity)
        .collect::<Result<Vec<_>, _>>();
    let available = available
        .into_iter()
        .map(product_identity)
        .collect::<Result<Vec<_>, _>>();
    match (expected, available) {
        (Ok(expected), Ok(available)) => {
            match data::validate_exact_product_set(&expected, &available) {
                Ok(()) => atoms::ok().encode(env),
                Err(error) => (
                    atoms::error(),
                    (atoms::exact_product_set(), error.to_string()),
                )
                    .encode(env),
            }
        }
        (Err(error), _) | (_, Err(error)) => encode_catalog_error(env, error),
    }
}

#[rustler::nif]
fn data_center_entry<'a>(env: Env<'a>, code: String) -> Term<'a> {
    encode_result(env, center(&code), |env, center| {
        let entry = data::center_catalog(center).expect("catalog entry exists for enum variant");
        let products: Vec<String> = entry
            .products
            .iter()
            .map(|product| product.product_type.code().to_string())
            .collect();
        let issues: Vec<String> = entry
            .issues
            .iter()
            .map(|issue| (*issue).to_string())
            .collect();
        (
            entry.protocol.as_str(),
            entry.host,
            entry.root_url,
            products,
            issues,
        )
            .encode(env)
    })
}

#[rustler::nif]
fn data_default_sample<'a>(env: Env<'a>, center_code: String, product_code: String) -> Term<'a> {
    let result = center(&center_code).and_then(|center| {
        product_type(&product_code).and_then(|kind| data::default_sample(center, kind))
    });
    encode_result(env, result, |env, sample| sample.encode(env))
}

/// Product-aware solution classification. This keeps the legacy center-wide
/// query out of the binding and lets the core reject unsupported combinations.
#[rustler::nif]
fn data_product_solution_class<'a>(
    env: Env<'a>,
    center_code: String,
    product_code: String,
) -> Term<'a> {
    let result = center(&center_code).and_then(|center| {
        product_type(&product_code).and_then(|kind| data::product_solution_class(center, kind))
    });
    encode_result(env, result, |env, solution| solution.code().encode(env))
}

/// Resolve the cataloged relationship between an SP3 filename epoch and its
/// first content epoch. Historical publication rules remain in the core.
#[rustler::nif]
fn data_sp3_content_start_convention<'a>(
    env: Env<'a>,
    center_code: String,
    year: i32,
    month: i32,
    day: i32,
    issue: Option<String>,
) -> Term<'a> {
    let result = center(&center_code).and_then(|center| {
        product_date(year, month, day)
            .and_then(|date| data::sp3_content_start_convention(center, date, issue.as_deref()))
    });
    encode_result(env, result, |env, convention| {
        (convention.code(), convention.content_start_offset_s()).encode(env)
    })
}

/// Date-aware sampling default used whenever an exact product is derived.
#[rustler::nif]
#[allow(clippy::too_many_arguments)]
fn data_default_sample_for_date<'a>(
    env: Env<'a>,
    center_code: String,
    product_code: String,
    year: i32,
    month: i32,
    day: i32,
) -> Term<'a> {
    let result = center(&center_code).and_then(|center| {
        product_type(&product_code).and_then(|kind| {
            product_date(year, month, day)
                .and_then(|date| data::default_sample_for_date(center, kind, date))
        })
    });
    encode_result(env, result, |env, sample| sample.encode(env))
}

/// Officially cataloged sampling tokens for an exact product date and issue.
#[rustler::nif]
#[allow(clippy::too_many_arguments)]
fn data_supported_samples<'a>(
    env: Env<'a>,
    center_code: String,
    product_code: String,
    year: i32,
    month: i32,
    day: i32,
    issue: Option<String>,
) -> Term<'a> {
    let result = center(&center_code).and_then(|center| {
        product_type(&product_code).and_then(|kind| {
            product_date(year, month, day).and_then(|date| {
                data::supported_samples(center, kind, date, issue.as_deref()).map(|samples| {
                    samples
                        .iter()
                        .map(|sample| (*sample).to_owned())
                        .collect::<Vec<_>>()
                })
            })
        })
    });
    encode_result(env, result, |env, samples| samples.encode(env))
}

/// Issue-aware sampling default for exact product derivation. Resolving the
/// complete identity in the core keeps intraday publication transitions in one
/// catalog rather than duplicating them in this binding.
#[rustler::nif]
#[allow(clippy::too_many_arguments)]
fn data_default_sample_for_issue<'a>(
    env: Env<'a>,
    center_code: String,
    product_code: String,
    year: i32,
    month: i32,
    day: i32,
    issue: String,
) -> Term<'a> {
    let result = center(&center_code).and_then(|center| {
        product_type(&product_code).and_then(|kind| {
            product_date(year, month, day).and_then(|date| {
                data::product_identity(center, kind, date, None, Some(&issue))
                    .map(|identity| identity.sample)
            })
        })
    });
    encode_result(env, result, |env, sample| sample.encode(env))
}

/// Resolve a complete distributor-independent identity through the core
/// catalog, including historical naming eras and product-aware solution class.
#[rustler::nif]
#[allow(clippy::too_many_arguments)]
fn data_product_identity<'a>(
    env: Env<'a>,
    center_code: String,
    product_code: String,
    year: i32,
    month: i32,
    day: i32,
    sample: Option<String>,
    issue: Option<String>,
) -> Term<'a> {
    let result = center(&center_code).and_then(|center| {
        product_type(&product_code).and_then(|kind| {
            product_date(year, month, day).and_then(|date| {
                data::product_identity(center, kind, date, sample.as_deref(), issue.as_deref())
            })
        })
    });
    encode_result(env, result, |env, identity| {
        product_identity_fields(&identity).encode(env)
    })
}

/// Resolve a cataloged distribution location without reconstructing or
/// weakening the caller's exact identity.
#[rustler::nif]
fn data_distribution_location_for_identity<'a>(
    env: Env<'a>,
    identity_fields: Vec<String>,
    source_code: String,
) -> Term<'a> {
    let result = product_identity(identity_fields).and_then(|identity| {
        distribution_source(&source_code)
            .and_then(|source| data::distribution_location_for_identity(&identity, source))
    });
    encode_result(env, result, |env, location| {
        (
            location.source.code(),
            location.original_url,
            location.archive_filename,
            location.compression.as_str(),
        )
            .encode(env)
    })
}

/// Officially cataloged dated ultra-rapid SP3 locations for one exact issue.
#[rustler::nif]
fn data_ultra_sp3_locations<'a>(
    env: Env<'a>,
    center_code: String,
    year: i32,
    month: i32,
    day: i32,
    issue: String,
) -> Term<'a> {
    let result = center(&center_code).and_then(|center| {
        product_date(year, month, day)
            .and_then(|date| data::ultra_sp3_locations(center, date, &issue))
    });
    encode_result(env, result, |env, locations| {
        locations
            .into_iter()
            .map(|location| {
                (
                    location.pattern,
                    location.span,
                    location.sample,
                    location.filename,
                    location.url,
                    location.compression.as_str(),
                )
            })
            .collect::<Vec<_>>()
            .encode(env)
    })
}

#[rustler::nif]
fn data_archive_compression<'a>(
    env: Env<'a>,
    center_code: String,
    product_code: String,
) -> Term<'a> {
    let result = center(&center_code).and_then(|center| {
        product_type(&product_code).and_then(|kind| {
            data::product_convention(center, kind).map(|entry| entry.compression.as_str())
        })
    });
    encode_result(env, result, |env, compression| compression.encode(env))
}

#[rustler::nif]
fn data_gps_week<'a>(env: Env<'a>, year: i32, month: i32, day: i32) -> Term<'a> {
    let result = product_date(year, month, day).and_then(data::gps_week);
    encode_result(env, result, |env, week| week.encode(env))
}

#[rustler::nif]
fn data_day_of_year<'a>(env: Env<'a>, year: i32, month: i32, day: i32) -> Term<'a> {
    let result = product_date(year, month, day);
    encode_result(env, result, |env, date| data::day_of_year(date).encode(env))
}

#[rustler::nif]
fn data_predicted_day_offset<'a>(env: Env<'a>, center_code: String) -> Term<'a> {
    encode_result(env, center(&center_code), |env, center| {
        data::predicted_day_offset(center).encode(env)
    })
}

#[rustler::nif]
#[allow(clippy::too_many_arguments)]
fn data_canonical_filename<'a>(
    env: Env<'a>,
    center_code: String,
    product_code: String,
    year: i32,
    month: i32,
    day: i32,
    sample: Option<String>,
    issue: Option<String>,
) -> Term<'a> {
    let result = center(&center_code).and_then(|center| {
        product_type(&product_code).and_then(|kind| {
            product_date(year, month, day).and_then(|date| {
                data::canonical_filename(center, kind, date, sample.as_deref(), issue.as_deref())
            })
        })
    });
    encode_result(env, result, |env, filename| filename.encode(env))
}

#[rustler::nif]
#[allow(clippy::too_many_arguments)]
fn data_archive_url<'a>(
    env: Env<'a>,
    center_code: String,
    product_code: String,
    year: i32,
    month: i32,
    day: i32,
    sample: Option<String>,
    issue: Option<String>,
) -> Term<'a> {
    let result = center(&center_code).and_then(|center| {
        product_type(&product_code).and_then(|kind| {
            product_date(year, month, day).and_then(|date| {
                data::archive_url(center, kind, date, sample.as_deref(), issue.as_deref())
            })
        })
    });
    encode_result(env, result, |env, url| url.encode(env))
}

#[rustler::nif]
fn data_gim_date_candidates<'a>(
    env: Env<'a>,
    center_code: String,
    year: i32,
    month: i32,
    day: i32,
    lookback: u32,
) -> Term<'a> {
    let result = center(&center_code).and_then(|center| {
        product_date(year, month, day)
            .and_then(|date| data::gim_date_candidates(center, date, lookback))
    });
    encode_result(env, result, |env, dates| {
        dates
            .into_iter()
            .map(|date| (date.year, date.month, date.day))
            .collect::<Vec<_>>()
            .encode(env)
    })
}

#[rustler::nif]
#[allow(clippy::too_many_arguments)]
fn data_ultra_issue_candidates<'a>(
    env: Env<'a>,
    center_code: String,
    year: i32,
    month: i32,
    day: i32,
    hour: i32,
    minute: i32,
    second: i32,
) -> Term<'a> {
    let result = center(&center_code).and_then(|center| {
        product_datetime(year, month, day, hour, minute, second)
            .and_then(|target| data::ultra_issue_candidates(center, target))
    });
    encode_result(env, result, |env, issues| {
        issues
            .into_iter()
            .map(|issue| {
                (
                    issue.date.year,
                    issue.date.month,
                    issue.date.day,
                    issue.issue,
                )
            })
            .collect::<Vec<_>>()
            .encode(env)
    })
}

#[rustler::nif]
fn data_predicted_ionex_line_candidates<'a>(
    env: Env<'a>,
    year: i32,
    month: i32,
    day: i32,
    sample: Option<String>,
) -> Term<'a> {
    let result = product_date(year, month, day)
        .and_then(|date| data::predicted_ionex_line_candidates(date, sample.as_deref()))
        .and_then(|candidates| {
            candidates
                .into_iter()
                .map(|candidate| {
                    let filename = candidate.canonical_filename()?;
                    let url = candidate.archive_url()?;
                    Ok((
                        candidate.center.code().to_string(),
                        (
                            candidate.date.year,
                            i32::from(candidate.date.month),
                            i32::from(candidate.date.day),
                        ),
                        candidate.sample.clone(),
                        candidate.issue.clone().unwrap_or_default(),
                        filename,
                        url,
                    ))
                })
                .collect::<Result<Vec<_>, DataCatalogError>>()
        });
    encode_result(env, result, |env, rows| rows.encode(env))
}

#[rustler::nif]
fn data_publication_listing_urls<'a>(
    env: Env<'a>,
    center_code: String,
    product_code: String,
    year: i32,
    month: i32,
    day: i32,
) -> Term<'a> {
    let result = center(&center_code).and_then(|center| {
        product_type(&product_code).and_then(|kind| {
            product_date(year, month, day)
                .and_then(|date| data::publication_listing_urls(center, kind, date))
        })
    });
    encode_result(env, result, |env, urls| urls.encode(env))
}

// Archive listings are unbounded caller input: AIUB's whole-tree CSV is ~34 MiB
// over ~426k rows, far past the ~1 ms budget a regular scheduler slot allows.
//
// The body arrives as a binary and is borrowed as text for the duration of
// the call rather than decoded into an owned `String`, so a multi-megabyte
// listing is parsed in place instead of being copied first. A body that is
// not UTF-8 cannot be a listing in any supported dialect, so it takes the same
// typed, fail-closed error as any other unrecognized listing.
#[rustler::nif(schedule = "DirtyCpu")]
fn data_parse_archive_listing<'a>(env: Env<'a>, body: Binary<'a>) -> Term<'a> {
    let result = std::str::from_utf8(body.as_slice())
        .map_err(|error| DataCatalogError::UnrecognizedArchiveListing {
            reason: format!("listing body is not UTF-8 text: {error}"),
        })
        .and_then(data::parse_archive_listing)
        .map(|objects| {
            objects
                .into_iter()
                .map(|object| (object.path, object.observed_at))
                .collect::<Vec<_>>()
        });
    encode_result(env, result, |env, rows| rows.encode(env))
}

fn published_objects(rows: Vec<(String, Option<String>)>) -> Vec<data::PublishedObject> {
    rows.into_iter()
        .map(|(path, observed_at)| data::PublishedObject { path, observed_at })
        .collect()
}

#[rustler::nif]
fn data_newest_published_product<'a>(
    env: Env<'a>,
    center_code: String,
    product_code: String,
    objects: Vec<(String, Option<String>)>,
) -> Term<'a> {
    let result = center(&center_code).and_then(|center| {
        product_type(&product_code).and_then(|kind| {
            data::newest_published_product(center, kind, &published_objects(objects))
        })
    });
    encode_result(env, result, |env, newest| {
        newest
            .map(|product| {
                (
                    product.date.year,
                    product.date.month,
                    product.date.day,
                    product.issue,
                    product.filename,
                    product.observed_at,
                )
            })
            .encode(env)
    })
}

#[rustler::nif]
#[allow(clippy::too_many_arguments)]
fn data_published_issue_age_minutes<'a>(
    env: Env<'a>,
    year: i32,
    month: i32,
    day: i32,
    issue: String,
    filename: String,
    now_year: i32,
    now_month: i32,
    now_day: i32,
    now_hour: i32,
    now_minute: i32,
    now_second: i32,
) -> Term<'a> {
    let result = product_date(year, month, day).and_then(|date| {
        let published = data::PublishedProduct {
            date,
            issue,
            filename,
            observed_at: None,
        };
        product_datetime(
            now_year, now_month, now_day, now_hour, now_minute, now_second,
        )
        .and_then(|now| data::published_issue_age_minutes(&published, now))
    });
    encode_result(env, result, |env, minutes| minutes.encode(env))
}

/// Return the first catalog issue nominally due at or after the UTC query
/// instant. This is pure catalog translation and performs no archive access.
#[rustler::nif]
#[allow(clippy::too_many_arguments)]
fn data_next_issue_due<'a>(
    env: Env<'a>,
    center_code: String,
    product_code: String,
    year: i32,
    month: i32,
    day: i32,
    hour: i32,
    minute: i32,
    second: i32,
) -> Term<'a> {
    let result = center(&center_code).and_then(|center| {
        product_type(&product_code).and_then(|kind| {
            product_datetime(year, month, day, hour, minute, second)
                .and_then(|now| data::next_issue_due(center, kind, now))
        })
    });
    encode_result(env, result, |env, issue| {
        let tuple: NominalIssueTuple = (
            product_identity_fields(&issue.identity),
            product_datetime_tuple(issue.due_at),
            (
                issue.covers.observed.map(nominal_coverage_interval_tuple),
                issue.covers.predicted.map(nominal_coverage_interval_tuple),
            ),
        );
        tuple.encode(env)
    })
}

type CandidateSpecTuple = (
    String,
    String,
    i32,
    i32,
    i32,
    Option<String>,
    Option<String>,
);

#[rustler::nif]
fn data_resolve_first_published<'a>(
    env: Env<'a>,
    candidates: Vec<CandidateSpecTuple>,
    objects: Vec<(String, Option<String>)>,
) -> Term<'a> {
    let result = candidates
        .into_iter()
        .map(
            |(center_code, product_code, year, month, day, sample, issue)| {
                let center = center(&center_code)?;
                let kind = product_type(&product_code)?;
                let date = product_date(year, month, day)?;
                data::product(center, kind, date, sample.as_deref(), issue.as_deref())
            },
        )
        .collect::<Result<Vec<_>, DataCatalogError>>()
        .and_then(|specs| data::resolve_first_published(&specs, &published_objects(objects)));
    encode_result(env, result, |env, index| index.encode(env))
}

#[rustler::nif]
fn data_skadi_source_entry<'a>(env: Env<'a>) -> Term<'a> {
    let entry = data::skadi_source_entry();
    (
        entry.protocol.as_str(),
        entry.host,
        entry.compression.as_str(),
        entry.root_url,
    )
        .encode(env)
}

#[rustler::nif]
fn data_space_weather_source_entry<'a>(env: Env<'a>) -> Term<'a> {
    let entry = data::space_weather_source_entry();
    (
        entry.protocol.as_str(),
        entry.host,
        entry.compression.as_str(),
        entry.root_url,
    )
        .encode(env)
}

#[rustler::nif]
fn data_space_weather_filename<'a>(env: Env<'a>, product_code: String) -> Term<'a> {
    encode_result(env, space_weather_product(&product_code), |env, product| {
        data::space_weather_filename(product).encode(env)
    })
}

#[rustler::nif]
fn data_space_weather_archive_url<'a>(env: Env<'a>, product_code: String) -> Term<'a> {
    encode_result(env, space_weather_product(&product_code), |env, product| {
        data::space_weather_archive_url(product).encode(env)
    })
}

#[rustler::nif]
fn data_space_weather_cache_relpath<'a>(env: Env<'a>, product_code: String) -> Term<'a> {
    encode_result(env, space_weather_product(&product_code), |env, product| {
        data::space_weather_cache_relpath(product).encode(env)
    })
}

#[rustler::nif]
fn data_skadi_tile_id<'a>(env: Env<'a>, lat_index: i32, lon_index: i32) -> Term<'a> {
    encode_result(env, data::skadi_tile_id(lat_index, lon_index), |env, id| {
        id.encode(env)
    })
}

#[rustler::nif]
fn data_skadi_band<'a>(env: Env<'a>, lat_index: i32) -> Term<'a> {
    encode_result(env, data::skadi_band(lat_index), |env, band| {
        band.encode(env)
    })
}

#[rustler::nif]
fn data_skadi_archive_url<'a>(env: Env<'a>, lat_index: i32, lon_index: i32) -> Term<'a> {
    encode_result(
        env,
        data::skadi_archive_url(lat_index, lon_index),
        |env, url| url.encode(env),
    )
}

#[rustler::nif]
fn data_terrain_tile_index<'a>(env: Env<'a>, lat_deg: f64, lon_deg: f64) -> Term<'a> {
    encode_result(
        env,
        data::terrain_tile_index(lat_deg, lon_deg),
        |env, pair| pair.encode(env),
    )
}

#[rustler::nif]
fn data_dted_tile_filename<'a>(env: Env<'a>, lat_index: i32, lon_index: i32) -> Term<'a> {
    encode_result(
        env,
        data::dted_tile_filename(lat_index, lon_index),
        |env, name| name.encode(env),
    )
}

#[rustler::nif]
fn data_dted_block_dir<'a>(env: Env<'a>, lat_index: i32, lon_index: i32) -> Term<'a> {
    encode_result(
        env,
        data::dted_block_dir(lat_index, lon_index),
        |env, dir| dir.encode(env),
    )
}

#[rustler::nif]
fn data_dted_cache_relpath<'a>(env: Env<'a>, lat_index: i32, lon_index: i32) -> Term<'a> {
    encode_result(
        env,
        data::dted_cache_relpath(lat_index, lon_index),
        |env, path| path.encode(env),
    )
}

#[rustler::nif]
fn data_parse_skadi_tile_id<'a>(env: Env<'a>, tile_id: String) -> Term<'a> {
    encode_result(env, data::parse_skadi_tile_id(&tile_id), |env, pair| {
        pair.encode(env)
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn data_hgt_to_dted<'a>(env: Env<'a>, lat_index: i32, lon_index: i32, hgt: Binary<'a>) -> Term<'a> {
    match data::hgt_to_dted(lat_index, lon_index, hgt.as_slice()) {
        Ok(dt2) => (atoms::ok(), bytes_to_binary(env, &dt2)).encode(env),
        Err(err) => encode_hgt_error(env, err),
    }
}

/// Decode a historical Unix-compress (`.Z`) archive. The transport layer owns
/// compression; the core continues to receive only decompressed product bytes.
#[rustler::nif(schedule = "DirtyCpu")]
fn data_unix_compress_decompress<'a>(env: Env<'a>, archive: Binary<'a>, limit: u64) -> Term<'a> {
    let limit = usize::try_from(limit).unwrap_or(usize::MAX);

    match crate::unix_compress::decode_bounded(archive.as_slice(), limit) {
        Ok(bytes) => (atoms::ok(), bytes_to_binary(env, &bytes)).encode(env),
        Err(crate::unix_compress::DecodeError::SizeLimit) => {
            (atoms::error(), (atoms::decompress(), atoms::size_limit())).encode(env)
        }
        Err(_) => (
            atoms::error(),
            (atoms::decompress(), atoms::invalid_unix_compress()),
        )
            .encode(env),
    }
}

#[cfg(test)]
mod catalog_error_contract_tests {
    use super::*;
    use sidereon_core::data::{
        AnalysisCenter, DataCatalogError as E, DistributionSource, ProductType,
    };

    #[test]
    fn every_catalog_variant_field_and_display_value_has_a_lossless_projection() {
        use CatalogProjectionValue as Value;

        type ExpectedCase = (E, &'static str, Vec<(&'static str, Value)>);

        let date = |year, month, day| ProductDate { year, month, day };
        let cases: Vec<ExpectedCase> = vec![
            (
                E::UnknownCenter("unknown_c".into()),
                "unknown_center",
                vec![("value", Value::Text("unknown_c".into()))],
            ),
            (
                E::UnknownProductType("unknown_pt".into()),
                "unknown_product_type",
                vec![("value", Value::Text("unknown_pt".into()))],
            ),
            (
                E::UnsupportedProduct {
                    center: AnalysisCenter::Cod,
                    product_type: ProductType::Sp3,
                },
                "unsupported_product",
                vec![
                    ("center", Value::Text("cod".into())),
                    ("product_type", Value::Text("sp3".into())),
                ],
            ),
            (
                E::UnsupportedDistribution {
                    source: DistributionSource::Direct,
                    product_type: ProductType::Sp3,
                },
                "unsupported_distribution",
                vec![
                    ("source", Value::Text("direct".into())),
                    ("product_type", Value::Text("sp3".into())),
                ],
            ),
            (
                E::UnsupportedProductEra {
                    center: AnalysisCenter::Cod,
                    product_type: ProductType::Sp3,
                    date: date(2020, 1, 2),
                },
                "unsupported_product_era",
                vec![
                    ("center", Value::Text("cod".into())),
                    ("product_type", Value::Text("sp3".into())),
                    ("date", Value::Date(date(2020, 1, 2))),
                ],
            ),
            (
                E::UnsupportedDistributionEra {
                    source: DistributionSource::Direct,
                    center: AnalysisCenter::Cod,
                    product_type: ProductType::Sp3,
                    date: date(2020, 1, 2),
                },
                "unsupported_distribution_era",
                vec![
                    ("source", Value::Text("direct".into())),
                    ("center", Value::Text("cod".into())),
                    ("product_type", Value::Text("sp3".into())),
                    ("date", Value::Date(date(2020, 1, 2))),
                ],
            ),
            (E::NoDistributionSources, "no_distribution_sources", vec![]),
            (
                E::InvalidOfficialFilename("bad..name".into()),
                "invalid_official_filename",
                vec![("value", Value::Text("bad..name".into()))],
            ),
            (
                E::InconsistentProductIdentity {
                    field: "official_filename",
                },
                "inconsistent_product_identity",
                vec![("field", Value::Text("official_filename".into()))],
            ),
            (
                E::NoOpenMirror {
                    center: "cod".into(),
                    product_type: "sp3".into(),
                },
                "no_open_mirror",
                vec![
                    ("center", Value::Text("cod".into())),
                    ("product_type", Value::Text("sp3".into())),
                ],
            ),
            (
                E::InvalidDate {
                    year: 2026,
                    month: 13,
                    day: 40,
                },
                "invalid_date",
                vec![
                    ("year", Value::I32(2026)),
                    ("month", Value::U8(13)),
                    ("day", Value::U8(40)),
                ],
            ),
            (E::DateOutOfRange, "date_out_of_range", vec![]),
            (
                E::DateBeforeGpsEpoch(date(1970, 1, 1)),
                "date_before_gps_epoch",
                vec![("date", Value::Date(date(1970, 1, 1)))],
            ),
            (
                E::InvalidGpsDayOfWeek(7),
                "invalid_gps_day_of_week",
                vec![("gps_day", Value::U8(7))],
            ),
            (
                E::InvalidSample("99X".into()),
                "invalid_sample",
                vec![("value", Value::Text("99X".into()))],
            ),
            (
                E::UnsupportedSample {
                    center: AnalysisCenter::Cod,
                    product_type: ProductType::Sp3,
                    sample: "99X".into(),
                },
                "unsupported_sample",
                vec![
                    ("center", Value::Text("cod".into())),
                    ("product_type", Value::Text("sp3".into())),
                    ("sample", Value::Text("99X".into())),
                ],
            ),
            (
                E::InvalidSpan("99D".into()),
                "invalid_span",
                vec![("value", Value::Text("99D".into()))],
            ),
            (
                E::InvalidIssue("9999".into()),
                "invalid_issue",
                vec![("value", Value::Text("9999".into()))],
            ),
            (
                E::MissingIssue {
                    center: AnalysisCenter::IgsUlt,
                },
                "missing_issue",
                vec![("center", Value::Text("igs_ult".into()))],
            ),
            (
                E::UnexpectedIssue {
                    center: AnalysisCenter::Cod,
                },
                "unexpected_issue",
                vec![("center", Value::Text("cod".into()))],
            ),
            (
                E::UnsupportedIssue {
                    center: AnalysisCenter::IgsUlt,
                    issue: "0130".into(),
                },
                "unsupported_issue",
                vec![
                    ("center", Value::Text("igs_ult".into())),
                    ("issue", Value::Text("0130".into())),
                ],
            ),
            (
                E::InvalidDateTime {
                    hour: 25,
                    minute: 61,
                    second: 62,
                },
                "invalid_date_time",
                vec![
                    ("hour", Value::U8(25)),
                    ("minute", Value::U8(61)),
                    ("second", Value::U8(62)),
                ],
            ),
            (E::NoUltraIssue, "no_ultra_issue", vec![]),
            (E::NoAvailableUltraIssue, "no_available_ultra_issue", vec![]),
            (
                E::UnsupportedNominalSchedule {
                    center: AnalysisCenter::WumNrt,
                    product_type: ProductType::Sp3,
                },
                "unsupported_nominal_schedule",
                vec![
                    ("center", Value::Text("wum_nrt".into())),
                    ("product_type", Value::Text("sp3".into())),
                ],
            ),
            (
                E::UnrecognizedArchiveListing {
                    reason: "bad grammar".into(),
                },
                "unrecognized_archive_listing",
                vec![("reason", Value::Text("bad grammar".into()))],
            ),
            (
                E::InvalidStation("BADSTATION".into()),
                "invalid_station",
                vec![("value", Value::Text("BADSTATION".into()))],
            ),
            (
                E::InvalidCoordinate {
                    lat_deg_bits: (-0.0_f64).to_bits(),
                    lon_deg_bits: f64::INFINITY.to_bits(),
                },
                "invalid_coordinate",
                vec![
                    ("lat_deg_bits", Value::Text("8000000000000000".into())),
                    ("lon_deg_bits", Value::Text("7ff0000000000000".into())),
                ],
            ),
            (
                E::InvalidTileIndex {
                    lat_index: -95,
                    lon_index: 185,
                },
                "invalid_tile_index",
                vec![
                    ("lat_index", Value::I32(-95)),
                    ("lon_index", Value::I32(185)),
                ],
            ),
            (
                E::InvalidTileId("invalid_tile".into()),
                "invalid_tile_id",
                vec![("value", Value::Text("invalid_tile".into()))],
            ),
        ];

        assert_eq!(cases.len(), 30);
        let field_count: usize = cases.iter().map(|(_, _, fields)| fields.len()).sum();
        assert_eq!(field_count, 44);
        // owner + 30 variants + 44 fields + Display
        assert_eq!(1 + cases.len() + field_count + 1, 76);

        for (error, expected_kind, expected_fields) in cases {
            let expected_message = match expected_kind {
                "unknown_center" => "unknown analysis center \"unknown_c\"",
                "unknown_product_type" => "unknown product type \"unknown_pt\"",
                "unsupported_product" => "cod does not serve sp3",
                "unsupported_distribution" => "distributor direct does not serve sp3",
                "unsupported_product_era" => "cod/sp3 has no cataloged naming convention for 2020-01-02",
                "unsupported_distribution_era" => "distributor direct has no cataloged cod/sp3 layout for 2020-01-02",
                "no_distribution_sources" => "exact product request has no distributors",
                "invalid_official_filename" => "invalid official product filename \"bad..name\"",
                "inconsistent_product_identity" => "product identity field \"official_filename\" disagrees with its official filename",
                "no_open_mirror" => "cod/sp3 has no open mirror",
                "invalid_date" => "invalid product date 2026-13-40",
                "date_out_of_range" => "product date is out of range",
                "date_before_gps_epoch" => "product date 1970-01-01 is before the GPS week epoch",
                "invalid_gps_day_of_week" => "invalid GPS day-of-week 7",
                "invalid_sample" => "invalid sample code \"99X\"",
                "unsupported_sample" => "cod/sp3 does not publish sample interval \"99X\"",
                "invalid_span" => "invalid coverage span \"99D\"",
                "invalid_issue" => "invalid issue time \"9999\"",
                "missing_issue" => "igs_ult requires an issue time",
                "unexpected_issue" => "cod does not take an issue time",
                "unsupported_issue" => "igs_ult does not publish issue \"0130\"",
                "invalid_date_time" => "invalid product time 25:61:62",
                "no_ultra_issue" => "no ultra-rapid issue at or before target",
                "no_available_ultra_issue" => "no available ultra-rapid issue at or before target",
                "unsupported_nominal_schedule" => "wum_nrt/sp3 has no nominal due-time schedule",
                "unrecognized_archive_listing" => "unrecognized archive listing: bad grammar",
                "invalid_station" => "invalid station code \"BADSTATION\"",
                "invalid_coordinate" => "invalid terrain coordinate lat=-0 lon=inf",
                "invalid_tile_index" => "invalid terrain tile index lat=-95 lon=185",
                "invalid_tile_id" => "invalid skadi tile id \"invalid_tile\"",
                other => panic!("unexpected DataCatalogError kind: {other}"),
            };
            assert_eq!(
                error.to_string(),
                expected_message,
                "{expected_kind} Display"
            );
            let actual = catalog_error_projection(&error);
            assert_eq!(actual.kind, expected_kind);
            assert_eq!(actual.fields, expected_fields, "{expected_kind} fields");
            assert_eq!(
                actual.message, expected_message,
                "{expected_kind} mapped message"
            );
            assert_eq!(
                actual,
                catalog_error_projection(&error),
                "{expected_kind} repeat"
            );
            assert_eq!(error, error.clone(), "{expected_kind} derived Eq");
        }
    }
}
