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
        _ => return Err(identity_field_error("publisher")),
    };
    let solution = match fields[3].as_str() {
        "final" => SolutionClass::Final,
        "rapid" => SolutionClass::Rapid,
        "ultra_rapid" => SolutionClass::UltraRapid,
        "predicted" => SolutionClass::Predicted,
        "broadcast" => SolutionClass::Broadcast,
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

fn encode_catalog_error<'a>(env: Env<'a>, err: DataCatalogError) -> Term<'a> {
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
        other => (
            atoms::error(),
            (atoms::unsupported_product(), other.to_string()),
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
