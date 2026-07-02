use std::collections::BTreeSet;

use rustler::{Encoder, Env, Error, NifResult, ResourceArc, Term};
use sidereon_core::astro::time::model::{GnssWeekTow, TimeScale};
use sidereon_core::ephemeris::{self, EphemerisSampleStatus};
use sidereon_core::ssr::{
    MissingCorrectionAction, RegionalPolicy, SsrClockCorrection, SsrCorrectedEphemeris,
    SsrCorrectionStore, SsrFallbackPolicy, SsrOrbitCorrection, SsrSource,
};
use sidereon_core::GnssSatelliteId;

use crate::broadcast::BroadcastResource;
use crate::errors;

pub struct SsrStoreResource {
    pub store: SsrCorrectionStore,
}

#[rustler::resource_impl]
impl rustler::Resource for SsrStoreResource {}

type Vec3 = (f64, f64, f64);

mod atoms {
    rustler::atoms! {
        ok,
        error,
        invalid_input,
        not_found
    }
}

#[derive(Debug, Clone, rustler::NifMap)]
struct SsrSolutionTerm {
    source: String,
    provider_id: i64,
    solution_id: i64,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct SsrOrbitTerm {
    solution: SsrSolutionTerm,
    iode: i64,
    iod_ssr: i64,
    radial_m: f64,
    along_m: f64,
    cross_m: f64,
    radial_rate_m_s: f64,
    along_rate_m_s: f64,
    cross_rate_m_s: f64,
    ref_epoch_j2000_s: f64,
    update_interval_s: f64,
    crs_regional: bool,
    reference_point: String,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct SsrClockTerm {
    solution: SsrSolutionTerm,
    iod_ssr: i64,
    c0_m: f64,
    c1_m_s: f64,
    c2_m_s2: f64,
    ref_epoch_j2000_s: f64,
    update_interval_s: f64,
    high_rate_c0_m: Option<f64>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct EphemerisSampleRowTerm {
    satellite_id: String,
    epoch_j2000_s: f64,
    status: String,
    position_ecef_m: Option<Vec3>,
    clock_s: Option<f64>,
}

fn parse_time_scale(value: &str) -> NifResult<TimeScale> {
    Ok(match value {
        "GPST" => TimeScale::Gpst,
        "GST" => TimeScale::Gst,
        "BDT" => TimeScale::Bdt,
        "UTC" => TimeScale::Utc,
        _ => return Err(Error::Term(Box::new("unknown time scale"))),
    })
}

fn week_tow(scale: String, week: u32, tow_s: f64) -> NifResult<GnssWeekTow> {
    GnssWeekTow::new(parse_time_scale(&scale)?, week, tow_s).map_err(errors::invalid_input)
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

fn solution_term(source: sidereon_core::ssr::SsrSolution) -> SsrSolutionTerm {
    let source_label = match source.source {
        SsrSource::RtcmSsr => "rtcm_ssr",
        SsrSource::GalileoHas => "galileo_has",
    };
    SsrSolutionTerm {
        source: source_label.to_string(),
        provider_id: source.provider_id as i64,
        solution_id: source.solution_id as i64,
    }
}

fn orbit_term(orbit: &SsrOrbitCorrection) -> SsrOrbitTerm {
    let reference_point = format!("{:?}", orbit.reference_point).to_lowercase();
    SsrOrbitTerm {
        solution: solution_term(orbit.solution),
        iode: orbit.iode as i64,
        iod_ssr: orbit.iod_ssr as i64,
        radial_m: orbit.radial_m,
        along_m: orbit.along_m,
        cross_m: orbit.cross_m,
        radial_rate_m_s: orbit.radial_rate_m_s,
        along_rate_m_s: orbit.along_rate_m_s,
        cross_rate_m_s: orbit.cross_rate_m_s,
        ref_epoch_j2000_s: orbit.ref_epoch_j2000_s,
        update_interval_s: orbit.update_interval_s,
        crs_regional: orbit.crs_regional,
        reference_point,
    }
}

fn clock_term(clock: &SsrClockCorrection) -> SsrClockTerm {
    SsrClockTerm {
        solution: solution_term(clock.solution),
        iod_ssr: clock.iod_ssr as i64,
        c0_m: clock.c0_m,
        c1_m_s: clock.c1_m_s,
        c2_m_s2: clock.c2_m_s2,
        ref_epoch_j2000_s: clock.ref_epoch_j2000_s,
        update_interval_s: clock.update_interval_s,
        high_rate_c0_m: clock.high_rate.map(|hr| hr.c0_m),
    }
}

fn fallback_policy(fallback_to_broadcast: bool, providers: Vec<u16>) -> SsrFallbackPolicy {
    SsrFallbackPolicy {
        on_missing_correction: if fallback_to_broadcast {
            MissingCorrectionAction::FallBackToBroadcast
        } else {
            MissingCorrectionAction::Decline
        },
        regional: if providers.is_empty() {
            RegionalPolicy::DeclineRegional
        } else {
            RegionalPolicy::AllowProviders(providers.into_iter().collect::<BTreeSet<_>>())
        },
    }
}

fn sample_row(row: ephemeris::EphemerisSampleRow) -> EphemerisSampleRowTerm {
    let status = match row.status {
        EphemerisSampleStatus::Valid => "valid",
        EphemerisSampleStatus::Gap => "gap",
    }
    .to_string();
    EphemerisSampleRowTerm {
        satellite_id: row.sat.to_string(),
        epoch_j2000_s: row.epoch_j2000_s,
        status,
        position_ecef_m: row.position_ecef_m.map(|p| (p[0], p[1], p[2])),
        clock_s: row.clock_s,
    }
}

#[rustler::nif]
fn ssr_store_new() -> ResourceArc<SsrStoreResource> {
    ResourceArc::new(SsrStoreResource {
        store: SsrCorrectionStore::new(),
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn ssr_store_from_rtcm(
    bytes: rustler::Binary,
    scale: String,
    week: u32,
    tow_s: f64,
) -> NifResult<ResourceArc<SsrStoreResource>> {
    let store = sidereon::ssr_store_from_rtcm(bytes.as_slice(), week_tow(scale, week, tow_s)?)
        .map_err(|e| Error::Term(Box::new(e.to_string())))?;
    Ok(ResourceArc::new(SsrStoreResource { store }))
}

#[rustler::nif]
fn ssr_orbit<'a>(
    env: Env<'a>,
    handle: ResourceArc<SsrStoreResource>,
    satellite_id: String,
) -> NifResult<Term<'a>> {
    let sat = sat_id(&satellite_id)?;
    Ok(match handle.store.orbit(sat) {
        Some(orbit) => (atoms::ok(), orbit_term(orbit)).encode(env),
        None => (atoms::error(), atoms::not_found()).encode(env),
    })
}

#[rustler::nif]
fn ssr_clock<'a>(
    env: Env<'a>,
    handle: ResourceArc<SsrStoreResource>,
    satellite_id: String,
) -> NifResult<Term<'a>> {
    let sat = sat_id(&satellite_id)?;
    Ok(match handle.store.clock(sat) {
        Some(clock) => (atoms::ok(), clock_term(clock)).encode(env),
        None => (atoms::error(), atoms::not_found()).encode(env),
    })
}

#[rustler::nif]
fn ssr_ura_index<'a>(
    env: Env<'a>,
    handle: ResourceArc<SsrStoreResource>,
    satellite_id: String,
) -> NifResult<Term<'a>> {
    let sat = sat_id(&satellite_id)?;
    Ok(match handle.store.ura_index(sat) {
        Some(ura) => (atoms::ok(), ura as i64).encode(env),
        None => (atoms::error(), atoms::not_found()).encode(env),
    })
}

#[rustler::nif]
fn ssr_corrected_position<'a>(
    env: Env<'a>,
    broadcast: ResourceArc<BroadcastResource>,
    store: ResourceArc<SsrStoreResource>,
    satellite_id: String,
    t_j2000_s: f64,
    fallback_to_broadcast: bool,
    regional_providers: Vec<u16>,
) -> NifResult<Term<'a>> {
    let sat = sat_id(&satellite_id)?;
    let source = SsrCorrectedEphemeris::new(&broadcast.store, &store.store)
        .with_fallback(fallback_policy(fallback_to_broadcast, regional_providers));
    Ok(match source.corrected_state(sat, t_j2000_s) {
        Some((position, clock_s)) => (
            atoms::ok(),
            ((position[0], position[1], position[2]), clock_s),
        )
            .encode(env),
        None => (atoms::error(), atoms::not_found()).encode(env),
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn ssr_sample_broadcast(
    broadcast: ResourceArc<BroadcastResource>,
    store: ResourceArc<SsrStoreResource>,
    satellites: Vec<String>,
    start_j2000_s: f64,
    stop_j2000_s: f64,
    step_s: f64,
    fallback_to_broadcast: bool,
    regional_providers: Vec<u16>,
) -> NifResult<Vec<EphemerisSampleRowTerm>> {
    let sats: Vec<GnssSatelliteId> = satellites
        .iter()
        .map(|sat| sat_id(sat))
        .collect::<NifResult<_>>()?;
    let source = SsrCorrectedEphemeris::new(&broadcast.store, &store.store)
        .with_fallback(fallback_policy(fallback_to_broadcast, regional_providers));
    let rows = ephemeris::sample(&source, &sats, start_j2000_s, stop_j2000_s, step_s)
        .map_err(errors::invalid_input)?;
    Ok(rows.into_iter().map(sample_row).collect())
}
