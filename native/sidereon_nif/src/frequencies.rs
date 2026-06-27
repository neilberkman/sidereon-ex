//! Rustler boundary for the canonical GNSS carrier-frequency table.
//!
//! This module is glue only: it decodes Elixir terms, calls
//! `sidereon_core::frequencies`, and encodes tagged `{:ok, _}` / `{:error, _}`
//! results. The carrier table itself lives only in the core crate.

use rustler::{Encoder, Env, Term};
use sidereon_core::frequencies::{self, CarrierBand};
use sidereon_core::GnssSystem;

mod atoms {
    rustler::atoms! {
        ok,
        error,
        unknown_system,
        unknown_band,
        no_default_pair,
        missing_glonass_channel,
        invalid_channel
    }
}

/// Carrier frequency in hertz for a constellation and canonical carrier band.
#[rustler::nif]
fn frequencies_carrier_frequency_hz<'a>(env: Env<'a>, system: String, band: String) -> Term<'a> {
    let Some(system_id) = parse_system(&system) else {
        return error(env, atoms::unknown_system());
    };
    let Some(band_id) = CarrierBand::from_name(&band) else {
        return error(env, atoms::unknown_band());
    };

    match frequencies::frequency_hz(system_id, band_id) {
        Some(frequency_hz) => (atoms::ok(), frequency_hz).encode(env),
        None => error(env, atoms::unknown_band()),
    }
}

/// Carrier wavelength in metres for a constellation and canonical carrier band.
#[rustler::nif]
fn frequencies_wavelength_m<'a>(env: Env<'a>, system: String, band: String) -> Term<'a> {
    let Some(system_id) = parse_system(&system) else {
        return error(env, atoms::unknown_system());
    };
    let Some(band_id) = CarrierBand::from_name(&band) else {
        return error(env, atoms::unknown_band());
    };

    match frequencies::wavelength_m(system_id, band_id) {
        Some(wavelength_m) => (atoms::ok(), wavelength_m).encode(env),
        None => error(env, atoms::unknown_band()),
    }
}

/// RINEX observation band frequency in hertz for a system and band digit.
#[rustler::nif]
fn frequencies_rinex_band_frequency_hz<'a>(
    env: Env<'a>,
    system: String,
    band: String,
    glonass_channel: Option<i64>,
) -> Term<'a> {
    rinex_band_lookup(
        env,
        system,
        band,
        glonass_channel,
        frequencies::rinex_band_frequency_hz,
    )
}

/// RINEX observation band wavelength in metres for a system and band digit.
#[rustler::nif]
fn frequencies_rinex_band_wavelength_m<'a>(
    env: Env<'a>,
    system: String,
    band: String,
    glonass_channel: Option<i64>,
) -> Term<'a> {
    rinex_band_lookup(
        env,
        system,
        band,
        glonass_channel,
        frequencies::rinex_band_wavelength_m,
    )
}

/// Standard dual-frequency ionosphere-free carrier pair for a constellation.
#[rustler::nif]
fn frequencies_default_pair<'a>(env: Env<'a>, system: String) -> Term<'a> {
    let Some(system_id) = parse_system(&system) else {
        return error(env, atoms::unknown_system());
    };

    match frequencies::default_iono_free_pair(system_id) {
        Some(pair) => (
            atoms::ok(),
            (pair.band1.name().to_string(), pair.band2.name().to_string()),
        )
            .encode(env),
        None => error(env, atoms::no_default_pair()),
    }
}

fn rinex_band_lookup<'a>(
    env: Env<'a>,
    system: String,
    band: String,
    glonass_channel: Option<i64>,
    lookup: fn(GnssSystem, char, Option<i8>) -> Option<f64>,
) -> Term<'a> {
    let Some(system_id) = parse_system(&system) else {
        return error(env, atoms::unknown_system());
    };
    let Some(band_char) = single_char(&band) else {
        return error(env, atoms::unknown_band());
    };

    let channel = match glonass_channel {
        Some(value) => match i8::try_from(value) {
            Ok(value) => Some(value),
            Err(_) => return error(env, atoms::invalid_channel()),
        },
        None => None,
    };

    if system_id == GnssSystem::Glonass && matches!(band_char, '1' | '2') && channel.is_none() {
        return error(env, atoms::missing_glonass_channel());
    }

    match lookup(system_id, band_char, channel) {
        Some(value) => (atoms::ok(), value).encode(env),
        None => error(env, atoms::unknown_band()),
    }
}

fn parse_system(value: &str) -> Option<GnssSystem> {
    value.chars().next().and_then(GnssSystem::from_letter)
}

fn single_char(value: &str) -> Option<char> {
    let mut chars = value.chars();
    let first = chars.next()?;
    if chars.next().is_none() {
        Some(first)
    } else {
        None
    }
}

fn error<'a>(env: Env<'a>, reason: rustler::Atom) -> Term<'a> {
    (atoms::error(), reason).encode(env)
}
