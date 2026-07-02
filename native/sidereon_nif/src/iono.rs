//! Rustler boundary for the `sidereon-core` ionospheric delay models.
//!
//! This module is **pure glue**: it decodes Erlang terms, calls the
//! `sidereon_core::atmosphere::ionosphere` public APIs, manages the parsed IONEX product as
//! a Rustler resource handle, and encodes the results back. No Klobuchar
//! polynomial, no single-layer-model geometry, and no grid interpolation lives
//! here; those are the crate's responsibility.
//!
//! - `klobuchar_delay/7` evaluates the GPS broadcast Klobuchar L1 model scaled
//!   to the requested carrier, taking radians at the boundary (the public Elixir
//!   wrapper converts its degree inputs).
//! - `ionex_parse/1` decodes a byte buffer, calls [`Ionex::parse`], and returns
//!   a [`ResourceArc`] wrapping the parsed grid; the bytes are parsed once.
//! - `ionex_slant_delay/7` operates on that handle plus an integer J2000-second
//!   epoch; it never touches the filesystem.

use rustler::{Encoder, Env, Error, NifResult, ResourceArc, Term};
use sidereon_core::astro::time::model::{Instant, JulianDateSplit, TimeScale};
use sidereon_core::atmosphere::ionosphere::{
    ionex_slant_delay, ionosphere_delay, klobuchar_native,
    nequick_g_delay_m as core_nequick_g_delay_m, nequick_g_stec_tecu as core_nequick_g_stec_tecu,
    GalileoNequickCoeffs, Ionex, IonoModel, KlobucharParams, NequickGRayEval,
};
use sidereon_core::combinations::{self, IonosphereFreeError, PseudorangeDropReason};
use sidereon_core::frequencies::{self, CarrierBand};
use sidereon_core::{GnssSystem, Wgs84Geodetic};

mod atoms {
    rustler::atoms! {
        ok,
        error,
        equal_frequencies,
        invalid_frequency,
        invalid_observation,
        unknown_system,
        unknown_band,
        missing_band1,
        missing_band2,
        duplicate_observation
    }
}

/// Resource handle holding a parsed IONEX product across NIF calls.
///
/// The parsed [`Ionex`] grid is read-only after construction, so the handle is
/// shared (`ResourceArc`) and evaluation borrows it immutably. The BEAM GC
/// drops it when the last Elixir reference is collected.
pub struct IonexResource {
    pub ionex: Ionex,
}

#[rustler::resource_impl]
impl rustler::Resource for IonexResource {}

/// The standard ionosphere-free carrier-frequency table.
///
/// Returns `[{"G", [{"l1", f}, ...]}, ...]`; the Elixir wrapper maps the band
/// names back to atom keys to preserve the public API shape.
#[rustler::nif]
fn iono_free_frequencies() -> Vec<(String, Vec<(String, f64)>)> {
    let mut by_system = std::collections::BTreeMap::<String, Vec<(String, f64)>>::new();
    for entry in frequencies::iono_free_carrier_frequencies() {
        by_system
            .entry(entry.system.letter().to_string())
            .or_default()
            .push((entry.band.name().to_string(), entry.frequency_hz));
    }
    by_system.into_iter().collect()
}

/// Standard ionosphere-free carrier pair for a constellation.
#[rustler::nif]
fn iono_free_default_pair<'a>(env: Env<'a>, system: String) -> Term<'a> {
    let system_id = first_char(&system).and_then(GnssSystem::from_letter);
    match system_id.and_then(frequencies::default_iono_free_pair) {
        Some(pair) => (
            atoms::ok(),
            (pair.band1.name().to_string(), pair.band2.name().to_string()),
        )
            .encode(env),
        None => (atoms::error(), atoms::unknown_system()).encode(env),
    }
}

/// Carrier-frequency lookup by constellation and lower-case band name.
#[rustler::nif]
fn iono_free_frequency<'a>(env: Env<'a>, system: String, band: String) -> Term<'a> {
    let frequency_hz = first_char(&system)
        .and_then(GnssSystem::from_letter)
        .zip(CarrierBand::from_iono_free_name(&band))
        .and_then(|(system, band)| frequencies::frequency_hz(system, band));
    match frequency_hz {
        Some(frequency_hz) => (atoms::ok(), frequency_hz).encode(env),
        None => (atoms::error(), atoms::unknown_band()).encode(env),
    }
}

/// Ionosphere-free coefficient `gamma = f1^2 / (f1^2 - f2^2)`.
#[rustler::nif]
fn iono_free_gamma<'a>(env: Env<'a>, f1_hz: f64, f2_hz: f64) -> Term<'a> {
    encode_float_result(env, combinations::gamma(f1_hz, f2_hz))
}

/// Equal-variance noise amplification of the ionosphere-free combination.
#[rustler::nif]
fn iono_free_noise_amplification<'a>(env: Env<'a>, f1_hz: f64, f2_hz: f64) -> Term<'a> {
    encode_float_result(env, combinations::noise_amplification(f1_hz, f2_hz))
}

/// Ionosphere-free pseudorange combination from two carrier bands.
#[rustler::nif]
fn iono_free_code<'a>(env: Env<'a>, pr1_m: f64, pr2_m: f64, f1_hz: f64, f2_hz: f64) -> Term<'a> {
    encode_float_result(
        env,
        combinations::ionosphere_free(pr1_m, pr2_m, f1_hz, f2_hz),
    )
}

/// Ionosphere-free carrier-phase combination from metre-valued phase inputs.
#[rustler::nif]
fn iono_free_phase<'a>(
    env: Env<'a>,
    phase1_m: f64,
    phase2_m: f64,
    f1_hz: f64,
    f2_hz: f64,
) -> Term<'a> {
    encode_float_result(
        env,
        combinations::ionosphere_free_phase_m(phase1_m, phase2_m, f1_hz, f2_hz),
    )
}

/// Ionosphere-free carrier-phase combination from cycle-valued phase inputs.
#[rustler::nif]
fn iono_free_phase_cycles<'a>(
    env: Env<'a>,
    phi1_cycles: f64,
    phi2_cycles: f64,
    f1_hz: f64,
    f2_hz: f64,
) -> Term<'a> {
    encode_float_result(
        env,
        combinations::ionosphere_free_phase_cycles(phi1_cycles, phi2_cycles, f1_hz, f2_hz),
    )
}

/// Pair and combine two per-satellite pseudorange bands.
///
/// `overrides` is `[{"G", "l1", "l2"}, ...]`; the Elixir wrapper handles the
/// public `%{"G" => {:l1, :l2}}` shape.
#[rustler::nif(schedule = "DirtyCpu")]
fn iono_free_pseudoranges<'a>(
    env: Env<'a>,
    band1: Vec<(String, f64)>,
    band2: Vec<(String, f64)>,
    overrides: Vec<(String, String, String)>,
) -> Term<'a> {
    let overrides = overrides
        .into_iter()
        .filter_map(|(system, band1, band2)| first_char(&system).map(|s| (s, band1, band2)))
        .collect::<Vec<_>>();
    let (combined, dropped) =
        match combinations::ionosphere_free_pseudoranges(&band1, &band2, &overrides) {
            Ok(result) => result,
            Err(error) => return (atoms::error(), iono_error_atom(error)).encode(env),
        };
    let dropped_terms = dropped
        .into_iter()
        .map(|(sat, reason)| (sat, drop_reason_atom(reason)).encode(env))
        .collect::<Vec<Term<'a>>>();
    (combined, dropped_terms).encode(env)
}

fn first_char(value: &str) -> Option<char> {
    value.chars().next()
}

fn encode_float_result<'a>(env: Env<'a>, result: Result<f64, IonosphereFreeError>) -> Term<'a> {
    match result {
        Ok(value) => (atoms::ok(), value).encode(env),
        Err(error) => (atoms::error(), iono_error_atom(error)).encode(env),
    }
}

fn iono_error_atom(error: IonosphereFreeError) -> rustler::Atom {
    match error {
        IonosphereFreeError::EqualFrequencies => atoms::equal_frequencies(),
        IonosphereFreeError::InvalidFrequency => atoms::invalid_frequency(),
        IonosphereFreeError::InvalidObservation => atoms::invalid_observation(),
        IonosphereFreeError::UnknownSystem(_) => atoms::unknown_system(),
        IonosphereFreeError::UnknownBand { .. } => atoms::unknown_band(),
    }
}

fn drop_reason_atom(reason: PseudorangeDropReason) -> rustler::Atom {
    match reason {
        PseudorangeDropReason::MissingBand1 => atoms::missing_band1(),
        PseudorangeDropReason::MissingBand2 => atoms::missing_band2(),
        PseudorangeDropReason::DuplicateObservation => atoms::duplicate_observation(),
        PseudorangeDropReason::UnknownSystem => atoms::unknown_system(),
    }
}

/// GPS broadcast Klobuchar L1 ionospheric group delay (positive meters).
///
/// All inputs arrive in the model's native boundary units: receiver
/// latitude/longitude and satellite azimuth/elevation in **degrees**, and the
/// GPS **second-of-day** in `[0, 86400)`. The Elixir wrapper supplies these
/// directly (it has the degree inputs and forms the second-of-day from the
/// epoch's integer clock fields), so no angle or time conversion happens at this
/// boundary and the delay is bit-exact to the model reference. `frequency_hz` is
/// the carrier on which the delay is reported (the model is dispersive).
#[rustler::nif]
#[allow(clippy::too_many_arguments)]
fn klobuchar_delay(
    lat_deg: f64,
    lon_deg: f64,
    azimuth_deg: f64,
    elevation_deg: f64,
    t_gps_s: f64,
    frequency_hz: f64,
    alpha: (f64, f64, f64, f64),
    beta: (f64, f64, f64, f64),
) -> NifResult<f64> {
    let params = KlobucharParams {
        alpha: [alpha.0, alpha.1, alpha.2, alpha.3],
        beta: [beta.0, beta.1, beta.2, beta.3],
    };
    klobuchar_native(
        &params,
        lat_deg,
        lon_deg,
        azimuth_deg,
        elevation_deg,
        t_gps_s,
        frequency_hz,
    )
    .map_err(crate::errors::invalid_input)
}

/// Galileo NeQuick-G single-frequency ionospheric group delay (positive meters).
///
/// Pure glue over `sidereon_core::atmosphere::ionosphere::ionosphere_delay` with
/// the `GalileoNequickG` model: the `ai0`/`ai1`/`ai2` broadcast effective-
/// ionisation coefficients drive the core NeQuick-G kernel. The receiver
/// latitude/longitude and the satellite azimuth/elevation arrive in degrees; the
/// NIF converts them to the core's radians. The epoch arrives as the split
/// Julian date `(jd_whole, jd_fraction)` the SP3/IONEX path already uses, so the
/// core kernel derives the Galileo second-of-day and fractional day-of-year from
/// the same instant with no second representation. `azimuth_deg` is validated by
/// the shared model entry but the NeQuick-G arm maps slant by elevation only.
/// `frequency_hz` is the carrier on which the dispersive delay is reported.
#[rustler::nif]
#[allow(clippy::too_many_arguments)]
fn galileo_nequick_g_delay(
    lat_deg: f64,
    lon_deg: f64,
    elevation_deg: f64,
    azimuth_deg: f64,
    jd_whole: f64,
    jd_fraction: f64,
    frequency_hz: f64,
    ai0: f64,
    ai1: f64,
    ai2: f64,
) -> NifResult<f64> {
    let receiver = Wgs84Geodetic::new(lat_deg.to_radians(), lon_deg.to_radians(), 0.0)
        .map_err(crate::errors::invalid_input)?;
    let split =
        JulianDateSplit::new(jd_whole, jd_fraction).map_err(crate::errors::invalid_input)?;
    let epoch = Instant::from_julian_date(TimeScale::Gpst, split);
    let model = IonoModel::GalileoNequickG(GalileoNequickCoeffs { ai0, ai1, ai2 });
    ionosphere_delay(
        receiver,
        elevation_deg.to_radians(),
        azimuth_deg.to_radians(),
        epoch,
        frequency_hz,
        &model,
    )
    .map_err(crate::errors::invalid_input)
}

/// Parse an IONEX byte buffer into a resource handle.
///
/// Dirty-CPU: a full daily IONEX map set is unbounded relative to the 1 ms NIF
/// budget. On success returns the [`IonexResource`] handle; on a malformed
/// buffer returns the crate's parse-error reason as an Erlang term.
#[rustler::nif(schedule = "DirtyCpu")]
fn ionex_parse(bytes: rustler::Binary) -> NifResult<ResourceArc<IonexResource>> {
    let ionex = Ionex::parse(bytes.as_slice()).map_err(|e| Error::Term(Box::new(e.to_string())))?;
    Ok(ResourceArc::new(IonexResource { ionex }))
}

/// Serialize a parsed IONEX product back to standard IONEX text. The inverse of
/// `ionex_parse`: re-parsing the output reproduces the same grids. Dirty-CPU
/// because a full daily map set's serialization is unbounded relative to the NIF
/// budget.
#[rustler::nif(schedule = "DirtyCpu")]
fn ionex_to_string(handle: ResourceArc<IonexResource>) -> String {
    handle.ionex.to_ionex_string()
}

/// IONEX vertical-TEC-grid slant ionospheric group delay (positive meters).
///
/// Operates on the parsed handle plus the receiver geodetic latitude/longitude
/// and the satellite azimuth/elevation in degrees. `epoch_j2000_s` is integer
/// seconds since the J2000 epoch so it lands exactly on the product's own epoch
/// axis with no float-rounded time entering the temporal bracket. `frequency_hz`
/// is the carrier on which the delay is reported. No file I/O.
#[rustler::nif]
#[allow(clippy::too_many_arguments)]
fn ionex_slant(
    handle: ResourceArc<IonexResource>,
    lat_deg: f64,
    lon_deg: f64,
    elevation_deg: f64,
    azimuth_deg: f64,
    epoch_j2000_s: i64,
    frequency_hz: f64,
) -> NifResult<f64> {
    let receiver = Wgs84Geodetic::new(lat_deg.to_radians(), lon_deg.to_radians(), 0.0)
        .map_err(crate::errors::invalid_input)?;
    ionex_slant_delay(
        &handle.ionex,
        receiver,
        elevation_deg.to_radians(),
        azimuth_deg.to_radians(),
        epoch_j2000_s,
        frequency_hz,
    )
    .map_err(crate::errors::invalid_input)
}

/// Build a [`NequickGRayEval`] from the boundary scalar fields.
///
/// The full NeQuick-G integration consumes the reference algorithm's own native
/// units directly (degree longitudes/latitudes, metre heights, month `1..=12`,
/// and UTC hours), so this is a pure field copy with no conversion.
#[allow(clippy::too_many_arguments)]
fn nequick_g_ray(
    month: u8,
    utc_hours: f64,
    station_lon_deg: f64,
    station_lat_deg: f64,
    station_height_m: f64,
    satellite_lon_deg: f64,
    satellite_lat_deg: f64,
    satellite_height_m: f64,
) -> NequickGRayEval {
    NequickGRayEval {
        month,
        utc_hours,
        station_lon_deg,
        station_lat_deg,
        station_height_m,
        satellite_lon_deg,
        satellite_lat_deg,
        satellite_height_m,
    }
}

/// Galileo NeQuick-G full three-dimensional slant total electron content (TECU).
///
/// Pure glue over `sidereon_core::atmosphere::ionosphere::nequick_g_stec_tecu`:
/// the `ai0`/`ai1`/`ai2` broadcast effective-ionisation coefficients drive the
/// NeQuick 2 profiler integrated along the full receiver-to-satellite ray. This
/// is the reference-grade companion to the compact `galileo_nequick_g_delay`
/// single-layer helper, so it takes both endpoints' geodetic positions rather
/// than an azimuth/elevation pair. No unit conversion happens at this boundary.
#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
fn nequick_g_stec_tecu(
    ai0: f64,
    ai1: f64,
    ai2: f64,
    month: u8,
    utc_hours: f64,
    station_lon_deg: f64,
    station_lat_deg: f64,
    station_height_m: f64,
    satellite_lon_deg: f64,
    satellite_lat_deg: f64,
    satellite_height_m: f64,
) -> NifResult<f64> {
    let coeffs = GalileoNequickCoeffs { ai0, ai1, ai2 };
    let ray = nequick_g_ray(
        month,
        utc_hours,
        station_lon_deg,
        station_lat_deg,
        station_height_m,
        satellite_lon_deg,
        satellite_lat_deg,
        satellite_height_m,
    );
    core_nequick_g_stec_tecu(&coeffs, &ray).map_err(crate::errors::invalid_input)
}

/// Galileo NeQuick-G full slant ionospheric group delay (positive metres).
///
/// Pure glue over `sidereon_core::atmosphere::ionosphere::nequick_g_delay_m`:
/// the full 3D slant TEC mapped to a dispersive group delay on `frequency_hz`.
#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
fn nequick_g_delay_m(
    ai0: f64,
    ai1: f64,
    ai2: f64,
    month: u8,
    utc_hours: f64,
    station_lon_deg: f64,
    station_lat_deg: f64,
    station_height_m: f64,
    satellite_lon_deg: f64,
    satellite_lat_deg: f64,
    satellite_height_m: f64,
    frequency_hz: f64,
) -> NifResult<f64> {
    let coeffs = GalileoNequickCoeffs { ai0, ai1, ai2 };
    let ray = nequick_g_ray(
        month,
        utc_hours,
        station_lon_deg,
        station_lat_deg,
        station_height_m,
        satellite_lon_deg,
        satellite_lat_deg,
        satellite_height_m,
    );
    core_nequick_g_delay_m(&coeffs, &ray, frequency_hz).map_err(crate::errors::invalid_input)
}
