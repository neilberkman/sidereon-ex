//! Rustler boundary for the pure data catalog and terrain conversion APIs.
//!
//! This module contains only term translation. Catalog derivation and HGT to
//! DTED conversion remain in `sidereon-core`; transport and cache IO remain in
//! Elixir.

use rustler::{Binary, Encoder, Env, OwnedBinary, Term};
use sidereon_core::data::{
    self, AnalysisCenter, DataCatalogError, HgtConversionError, ProductDate, ProductDateTime,
    ProductType,
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
        no_open_mirror,
        unknown_product_type,
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
