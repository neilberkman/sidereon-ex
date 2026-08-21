//! Rustler bridge to the shared exact-product cache implementation.

use crate::data::product_identity;
use rustler::{Binary, Encoder, Env, OwnedBinary, ResourceArc, Term};
use sidereon_core::data::DistributionSource;
use sidereon_core::exact_cache::{
    CommittedExactCacheEntry, ExactCacheError, ExactCacheGuard, ExactCacheOpen, ExactCacheOwner,
    ExactCacheSingleFlightOptions, ExactProductCache,
};
use std::sync::Mutex;
use std::time::Duration;

mod atoms {
    rustler::atoms! {
        ok,
        error,
        miss,
        hit,
        owner,
        single_flight_timeout,
        single_flight_ownership_lost,
        invalid_single_flight_options,
    }
}

pub struct ExactCacheResource {
    cache: ExactProductCache,
    guard: Mutex<Option<ExactCacheGuard>>,
}

#[rustler::resource_impl]
impl rustler::Resource for ExactCacheResource {}

pub struct ExactCacheOwnerResource {
    owner: Mutex<Option<ExactCacheOwner>>,
}

#[rustler::resource_impl]
impl rustler::Resource for ExactCacheOwnerResource {}

fn source(value: &str) -> Option<DistributionSource> {
    match value {
        "direct" => Some(DistributionSource::Direct),
        "nasa_cddis" => Some(DistributionSource::NasaCddis),
        "local_file" => Some(DistributionSource::LocalFile),
        "in_memory" => Some(DistributionSource::InMemory),
        _ => None,
    }
}

fn binary<'a>(env: Env<'a>, bytes: &[u8]) -> Term<'a> {
    let mut binary = OwnedBinary::new(bytes.len()).expect("allocate exact-cache binary");
    binary.as_mut_slice().copy_from_slice(bytes);
    binary.release(env).encode(env)
}

fn encode_error<'a>(env: Env<'a>, error: impl std::fmt::Display) -> Term<'a> {
    (atoms::error(), error.to_string()).encode(env)
}

fn encode_single_flight_error<'a>(env: Env<'a>, error: ExactCacheError) -> Term<'a> {
    let reason = match error {
        ExactCacheError::SingleFlightTimeout => atoms::single_flight_timeout().encode(env),
        ExactCacheError::SingleFlightOwnershipLost => {
            atoms::single_flight_ownership_lost().encode(env)
        }
        ExactCacheError::InvalidSingleFlightOptions => {
            atoms::invalid_single_flight_options().encode(env)
        }
        other => other.to_string().encode(env),
    };
    (atoms::error(), reason).encode(env)
}

fn encode_entry<'a>(env: Env<'a>, tag: rustler::Atom, entry: CommittedExactCacheEntry) -> Term<'a> {
    rustler::types::tuple::make_tuple(
        env,
        &[
            tag.encode(env),
            entry
                .product_path
                .to_string_lossy()
                .into_owned()
                .encode(env),
            entry
                .archive_path
                .to_string_lossy()
                .into_owned()
                .encode(env),
            entry
                .provenance_path
                .to_string_lossy()
                .into_owned()
                .encode(env),
            entry.entry_id.encode(env),
            binary(env, &entry.product),
            binary(env, &entry.archive),
            binary(env, &entry.provenance),
        ],
    )
}

fn encode_read<'a>(
    env: Env<'a>,
    result: Result<
        Option<sidereon_core::exact_cache::CommittedExactCacheEntry>,
        impl std::fmt::Display,
    >,
) -> Term<'a> {
    match result {
        Ok(None) => atoms::miss().encode(env),
        Ok(Some(entry)) => encode_entry(env, atoms::ok(), entry),
        Err(error) => encode_error(env, error),
    }
}

#[rustler::nif(schedule = "DirtyIo")]
pub fn data_exact_cache_open<'a>(
    env: Env<'a>,
    path: String,
    identity_fields: Vec<String>,
    source_code: String,
    timeout_ms: u64,
) -> Term<'a> {
    let result = product_identity(identity_fields)
        .map_err(|error| error.to_string())
        .and_then(|identity| {
            let source =
                source(&source_code).ok_or_else(|| "unknown distribution source".to_string())?;
            ExactProductCache::new(path, identity, source).map_err(|error| error.to_string())
        })
        .and_then(|cache| {
            cache
                .lock(Duration::from_millis(timeout_ms))
                .map(|guard| ExactCacheResource {
                    cache,
                    guard: Mutex::new(Some(guard)),
                })
                .map_err(|error| error.to_string())
        });
    match result {
        Ok(cache) => (atoms::ok(), ResourceArc::new(cache)).encode(env),
        Err(error) => encode_error(env, error),
    }
}

#[rustler::nif(schedule = "DirtyIo")]
#[allow(clippy::too_many_arguments)]
pub fn data_exact_cache_open_single_flight<'a>(
    env: Env<'a>,
    path: String,
    identity_fields: Vec<String>,
    source_code: String,
    poll_interval_ms: u64,
    heartbeat_interval_ms: u64,
    liveness_timeout_ms: u64,
    wait_timeout_ms: u64,
) -> Term<'a> {
    let result = product_identity(identity_fields)
        .map_err(|error| error.to_string())
        .and_then(|identity| {
            let source =
                source(&source_code).ok_or_else(|| "unknown distribution source".to_string())?;
            ExactProductCache::new(path, identity, source).map_err(|error| error.to_string())
        });
    let cache = match result {
        Ok(cache) => cache,
        Err(error) => return encode_error(env, error),
    };
    let options = ExactCacheSingleFlightOptions {
        poll_interval: Duration::from_millis(poll_interval_ms),
        heartbeat_interval: Duration::from_millis(heartbeat_interval_ms),
        liveness_timeout: Duration::from_millis(liveness_timeout_ms),
        wait_timeout: Duration::from_millis(wait_timeout_ms),
    };
    match cache.open_single_flight(options) {
        Ok(ExactCacheOpen::Hit(entry)) => encode_entry(env, atoms::hit(), entry),
        Ok(ExactCacheOpen::Owner(owner)) => (
            atoms::owner(),
            ResourceArc::new(ExactCacheOwnerResource {
                owner: Mutex::new(Some(owner)),
            }),
        )
            .encode(env),
        Err(error) => encode_single_flight_error(env, error),
    }
}

#[rustler::nif(schedule = "DirtyIo")]
pub fn data_exact_cache_owner_heartbeat<'a>(
    env: Env<'a>,
    resource: ResourceArc<ExactCacheOwnerResource>,
) -> Term<'a> {
    let owner = match resource.owner.lock() {
        Ok(owner) => owner,
        Err(_) => return encode_error(env, "exact-cache single-flight owner was poisoned"),
    };
    let Some(owner) = owner.as_ref() else {
        return encode_error(env, "exact-cache single-flight owner is closed");
    };
    match owner.heartbeat() {
        Ok(()) => atoms::ok().encode(env),
        Err(error) => encode_single_flight_error(env, error),
    }
}

#[rustler::nif(schedule = "DirtyIo")]
pub fn data_exact_cache_owner_publish<'a>(
    env: Env<'a>,
    resource: ResourceArc<ExactCacheOwnerResource>,
    product: Binary<'a>,
    archive: Binary<'a>,
    provenance: Binary<'a>,
) -> Term<'a> {
    let owner = match resource.owner.lock() {
        Ok(mut owner) => owner.take(),
        Err(_) => return encode_error(env, "exact-cache single-flight owner was poisoned"),
    };
    let Some(owner) = owner else {
        return encode_error(env, "exact-cache single-flight owner is closed");
    };
    match owner.publish(&product, &archive, &provenance) {
        Ok(entry) => encode_entry(env, atoms::ok(), entry),
        Err(error) => encode_single_flight_error(env, error),
    }
}

#[rustler::nif(schedule = "DirtyIo")]
pub fn data_exact_cache_owner_abandon<'a>(
    env: Env<'a>,
    resource: ResourceArc<ExactCacheOwnerResource>,
) -> Term<'a> {
    let owner = match resource.owner.lock() {
        Ok(mut owner) => owner.take(),
        Err(_) => return encode_error(env, "exact-cache single-flight owner was poisoned"),
    };
    drop(owner);
    atoms::ok().encode(env)
}

#[rustler::nif(schedule = "DirtyIo")]
pub fn data_exact_cache_read<'a>(env: Env<'a>, cache: ResourceArc<ExactCacheResource>) -> Term<'a> {
    let open = cache
        .guard
        .lock()
        .map(|guard| guard.is_some())
        .unwrap_or(false);
    if !open {
        return encode_error(env, "exact-product cache lock is closed");
    }
    encode_read(env, cache.cache.read())
}

#[rustler::nif(schedule = "DirtyIo")]
pub fn data_exact_cache_read_unlocked<'a>(
    env: Env<'a>,
    path: String,
    identity_fields: Vec<String>,
    source_code: String,
) -> Term<'a> {
    let result = product_identity(identity_fields)
        .map_err(|error| error.to_string())
        .and_then(|identity| {
            let source =
                source(&source_code).ok_or_else(|| "unknown distribution source".to_string())?;
            ExactProductCache::new(path, identity, source).map_err(|error| error.to_string())
        });
    match result {
        Ok(cache) => encode_read(env, cache.read()),
        Err(error) => encode_error(env, error),
    }
}

#[rustler::nif(schedule = "DirtyIo")]
pub fn data_exact_cache_publish<'a>(
    env: Env<'a>,
    cache: ResourceArc<ExactCacheResource>,
    product: Binary<'a>,
    archive: Binary<'a>,
    provenance: Binary<'a>,
) -> Term<'a> {
    let guard = match cache.guard.lock() {
        Ok(guard) => guard,
        Err(_) => return encode_error(env, "exact-product cache lock was poisoned"),
    };
    let Some(guard) = guard.as_ref() else {
        return encode_error(env, "exact-product cache lock is closed");
    };
    encode_read(
        env,
        cache
            .cache
            .publish(guard, &product, &archive, &provenance)
            .map(Some),
    )
}

#[rustler::nif(schedule = "DirtyIo")]
pub fn data_exact_cache_cleanup<'a>(
    env: Env<'a>,
    cache: ResourceArc<ExactCacheResource>,
) -> Term<'a> {
    let guard = match cache.guard.lock() {
        Ok(guard) => guard,
        Err(_) => return encode_error(env, "exact-product cache lock was poisoned"),
    };
    let Some(guard) = guard.as_ref() else {
        return encode_error(env, "exact-product cache lock is closed");
    };
    match cache.cache.cleanup_abandoned(guard) {
        Ok(()) => atoms::ok().encode(env),
        Err(error) => encode_error(env, error),
    }
}

#[rustler::nif(schedule = "DirtyIo")]
pub fn data_exact_cache_close<'a>(
    env: Env<'a>,
    cache: ResourceArc<ExactCacheResource>,
) -> Term<'a> {
    match cache.guard.lock() {
        Ok(mut guard) => {
            guard.take();
            atoms::ok().encode(env)
        }
        Err(_) => encode_error(env, "exact-product cache lock was poisoned"),
    }
}
