use std::collections::BTreeSet;
use std::sync::Mutex;

use rustler::{Encoder, Env, Error, NifResult, ResourceArc, Term};
use sidereon_core::astro::time::model::{GnssWeekTow, TimeScale};
use sidereon_core::ephemeris::{self, EphemerisSampleStatus};
use sidereon_core::ssr::{
    MissingCorrectionAction, RegionalPolicy, SsrClockCorrection, SsrCorrectedEphemeris,
    SsrCorrectionSizePolicy, SsrCorrectionStore, SsrFallbackPolicy, SsrNavigationMessage,
    SsrOrbitCorrection, SsrReferencePoint, SsrSatelliteAttitude, SsrSource,
};
use sidereon_core::GnssSatelliteId;

use crate::broadcast::BroadcastResource;
use crate::errors;
use crate::time::{ExactEpochQueryResource, ExactEpochResource};

pub struct SsrStoreResource {
    pub store: Mutex<SsrCorrectionStore>,
}

#[rustler::resource_impl]
impl rustler::Resource for SsrStoreResource {}

type Vec3 = (f64, f64, f64);

mod atoms {
    rustler::atoms! {
        ok,
        error,
        invalid_input,
        not_found,
        diagnostics,
        trailing_partial_frame_len,
        ingest_refusals,
        message_number,
        reason,
        correction_exceeds_limit
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
    transmitted_epoch_j2000_s: f64,
    update_interval_s: f64,
    crs_regional: bool,
    reference_point: String,
    has_nav_message: Option<i64>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct SsrClockTerm {
    solution: SsrSolutionTerm,
    iod_ssr: i64,
    c0_m: f64,
    c1_m_s: f64,
    c2_m_s2: f64,
    ref_epoch_j2000_s: f64,
    transmitted_epoch_j2000_s: f64,
    update_interval_s: f64,
    high_rate_c0_m: Option<f64>,
    has_nav_message: Option<i64>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct EphemerisSampleRowTerm {
    satellite_id: String,
    epoch_j2000_s: f64,
    status: String,
    position_ecef_m: Option<Vec3>,
    clock_s: Option<f64>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct SsrCorrectionSizeTerm {
    orbit_m: f64,
    clock_m: f64,
    orbit_exceeds_limit: bool,
    clock_exceeds_limit: bool,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct SsrOversizedCorrectionTerm {
    satellite_id: String,
    solution: SsrSolutionTerm,
    orbit_ref_epoch_j2000_s: f64,
    clock_ref_epoch_j2000_s: f64,
    t_j2000_s: f64,
    size: SsrCorrectionSizeTerm,
}

fn reference_point(value: &str) -> NifResult<SsrReferencePoint> {
    match value {
        "antenna_phase_center" => Ok(SsrReferencePoint::AntennaPhaseCenter),
        "center_of_mass" => Ok(SsrReferencePoint::CenterOfMass),
        _ => Err(Error::Term(Box::new("invalid SSR reference point"))),
    }
}

fn correction_size_policy(value: &str) -> NifResult<SsrCorrectionSizePolicy> {
    match value {
        "strict" => Ok(SsrCorrectionSizePolicy::Strict),
        "lenient" => Ok(SsrCorrectionSizePolicy::Lenient),
        _ => Err(Error::Term(Box::new("invalid correction size policy"))),
    }
}

fn satellite_attitude(value: &str) -> NifResult<SsrSatelliteAttitude> {
    match value {
        "unavailable" => Ok(SsrSatelliteAttitude::Unavailable),
        "nominal_sun_fixed" => Ok(SsrSatelliteAttitude::NominalSunFixed),
        _ => Err(Error::Term(Box::new("invalid SSR satellite attitude"))),
    }
}

fn configured_source<'a>(
    broadcast: &'a BroadcastResource,
    store: &'a SsrCorrectionStore,
    fallback: SsrFallbackPolicy,
    size_policy: SsrCorrectionSizePolicy,
    attitude: SsrSatelliteAttitude,
    satellite_antex: Option<&'a crate::antex::AntexResource>,
) -> SsrCorrectedEphemeris<'a> {
    let source = SsrCorrectedEphemeris::new(&broadcast.store, store)
        .with_fallback(fallback)
        .with_correction_size_policy(size_policy)
        .with_satellite_attitude(attitude);
    match satellite_antex {
        Some(antex) => source.with_satellite_antennas(&antex.antex),
        None => source,
    }
}

fn correction_size_term(size: sidereon_core::ssr::SsrCorrectionSize) -> SsrCorrectionSizeTerm {
    SsrCorrectionSizeTerm {
        orbit_m: size.orbit_m,
        clock_m: size.clock_m,
        orbit_exceeds_limit: size.orbit_exceeds_limit(),
        clock_exceeds_limit: size.clock_exceeds_limit(),
    }
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
    GnssWeekTow::new(parse_time_scale(&scale)?, week, tow_s)
        .map_err(crate::tropo::time_model_error_detail)
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
        SsrSource::IgsSsr => "igs_ssr",
    };
    SsrSolutionTerm {
        source: source_label.to_string(),
        provider_id: source.provider_id as i64,
        solution_id: source.solution_id as i64,
    }
}

fn oversized_correction_terms(
    corrections: Vec<sidereon_core::ssr::SsrOversizedCorrection>,
) -> Vec<SsrOversizedCorrectionTerm> {
    corrections
        .into_iter()
        .map(|correction| SsrOversizedCorrectionTerm {
            satellite_id: correction.sat.to_string(),
            solution: solution_term(correction.solution),
            orbit_ref_epoch_j2000_s: correction.orbit_ref_epoch_j2000_s,
            clock_ref_epoch_j2000_s: correction.clock_ref_epoch_j2000_s,
            t_j2000_s: correction.t_j2000_s,
            size: correction_size_term(correction.size),
        })
        .collect()
}

/// The Galileo HAS navigation-message index NM as transmitted, `None` for an
/// RTCM SSR correction.
fn has_nav_message(message: SsrNavigationMessage) -> Option<i64> {
    match message {
        SsrNavigationMessage::Rtcm => None,
        SsrNavigationMessage::Has(index) => Some(i64::from(index)),
        SsrNavigationMessage::IgsSsr => None,
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
        transmitted_epoch_j2000_s: orbit.transmitted_epoch_j2000_s,
        update_interval_s: orbit.update_interval_s,
        crs_regional: orbit.crs_regional,
        reference_point,
        has_nav_message: has_nav_message(orbit.nav_message),
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
        transmitted_epoch_j2000_s: clock.transmitted_epoch_j2000_s,
        update_interval_s: clock.update_interval_s,
        high_rate_c0_m: clock.high_rate.map(|hr| hr.c0_m),
        has_nav_message: has_nav_message(clock.nav_message),
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
fn ssr_store_new(reference_point_name: String) -> NifResult<ResourceArc<SsrStoreResource>> {
    let reference_point = reference_point(&reference_point_name)?;
    Ok(ResourceArc::new(SsrStoreResource {
        store: Mutex::new(SsrCorrectionStore::new().with_reference_point(reference_point)),
    }))
}

/// Build a store from every readable frame of framed RTCM bytes, read under
/// the lenient policy: `{handle, report}`, the report holding the stream
/// diagnostics, the length of an unfinished frame at the end, and each message
/// the store refused as `%{message_number, reason}`.
#[rustler::nif(schedule = "DirtyCpu")]
fn ssr_store_from_rtcm<'a>(
    env: Env<'a>,
    bytes: rustler::Binary,
    scale: String,
    week: u32,
    tow_s: f64,
    reference_point_name: String,
) -> NifResult<Term<'a>> {
    let reference_point = reference_point(&reference_point_name)?;
    let epoch = week_tow(scale, week, tow_s)?;
    if reference_point == SsrReferencePoint::AntennaPhaseCenter {
        let ingest = sidereon::ssr_store_from_rtcm(bytes.as_slice(), epoch);
        let refusals: Vec<Term<'a>> = ingest
            .ingest_refusals
            .iter()
            .map(|refusal| {
                Term::map_from_pairs(
                    env,
                    &[
                        (
                            atoms::message_number().encode(env),
                            i64::from(refusal.message_number).encode(env),
                        ),
                        (
                            atoms::reason().encode(env),
                            refusal.error.to_string().encode(env),
                        ),
                    ],
                )
            })
            .collect::<NifResult<_>>()?;
        let report = Term::map_from_pairs(
            env,
            &[
                (
                    atoms::diagnostics().encode(env),
                    crate::rtcm::diagnostics_term(env, &ingest.diagnostics),
                ),
                (
                    atoms::trailing_partial_frame_len().encode(env),
                    (ingest.trailing_partial_frame_len as u64).encode(env),
                ),
                (atoms::ingest_refusals().encode(env), refusals.encode(env)),
            ],
        )?;
        let handle = ResourceArc::new(SsrStoreResource {
            store: Mutex::new(ingest.store),
        });
        return Ok((handle, report).encode(env));
    }
    let mut store = SsrCorrectionStore::new().with_reference_point(reference_point);
    let mut assembler = sidereon_core::rtcm::SsrStreamAssembler::with_policy(
        sidereon_core::rtcm::RtcmPolicy::Lenient,
    );
    let mut decoded = assembler.push(bytes.as_slice());
    let trailing_partial_frame_len = assembler.retained_len();
    decoded.extend(assembler.finish());
    let mut refusals = Vec::new();
    for message in decoded.into_iter().flatten() {
        if let Err(error) = store.ingest(&message, epoch) {
            refusals.push((message.message_number() as i64, error.to_string()));
        }
    }
    let refusal_terms: Vec<Term<'a>> = refusals
        .into_iter()
        .map(|(number, reason)| {
            Term::map_from_pairs(
                env,
                &[
                    (atoms::message_number().encode(env), number.encode(env)),
                    (atoms::reason().encode(env), reason.encode(env)),
                ],
            )
        })
        .collect::<NifResult<_>>()?;
    let report = Term::map_from_pairs(
        env,
        &[
            (
                atoms::diagnostics().encode(env),
                crate::rtcm::diagnostics_term(env, assembler.diagnostics()),
            ),
            (
                atoms::trailing_partial_frame_len().encode(env),
                (trailing_partial_frame_len as u64).encode(env),
            ),
            (
                atoms::ingest_refusals().encode(env),
                refusal_terms.encode(env),
            ),
        ],
    )?;
    let handle = ResourceArc::new(SsrStoreResource {
        store: Mutex::new(store),
    });
    Ok((handle, report).encode(env))
}

/// Build a store from framed RTCM bytes, refusing anything that cannot be read
/// under the strict policy and applied in full.
#[rustler::nif(schedule = "DirtyCpu")]
fn ssr_store_from_rtcm_strict(
    bytes: rustler::Binary,
    scale: String,
    week: u32,
    tow_s: f64,
    reference_point_name: String,
) -> NifResult<ResourceArc<SsrStoreResource>> {
    let reference_point = reference_point(&reference_point_name)?;
    let epoch = week_tow(scale, week, tow_s)?;
    if reference_point == SsrReferencePoint::AntennaPhaseCenter {
        let store = sidereon::ssr_store_from_rtcm_strict(bytes.as_slice(), epoch)
            .map_err(|e| Error::Term(Box::new(e.to_string())))?;
        return Ok(ResourceArc::new(SsrStoreResource {
            store: Mutex::new(store),
        }));
    }
    let mut store = SsrCorrectionStore::new().with_reference_point(reference_point);
    let mut assembler = sidereon_core::rtcm::SsrStreamAssembler::new();
    let mut decoded = assembler.push(bytes.as_slice());
    let trailing = assembler.retained_len();
    decoded.extend(assembler.finish());
    for message in decoded {
        let message =
            message.map_err(|e| Error::Term(Box::new(format!("SSR ingest failed: {e}"))))?;
        store
            .ingest(&message, epoch)
            .map_err(|e| Error::Term(Box::new(format!("SSR ingest failed: {e}"))))?;
    }
    let diagnostics = assembler.diagnostics();
    if diagnostics.resync_bytes > 0 {
        return Err(Error::Term(Box::new(format!(
            "SSR ingest failed: parse error: RTCM input has {} bytes outside CRC-valid frames ({} CRC-24Q failures, {trailing} bytes from an unfinished frame at the end)",
            diagnostics.resync_bytes, diagnostics.crc_failures
        ))));
    }
    Ok(ResourceArc::new(SsrStoreResource {
        store: Mutex::new(store),
    }))
}

fn lock_store(
    handle: &ResourceArc<SsrStoreResource>,
) -> NifResult<std::sync::MutexGuard<'_, SsrCorrectionStore>> {
    handle
        .store
        .lock()
        .map_err(|_| Error::Term(Box::new("ssr store lock poisoned")))
}

#[rustler::nif]
fn ssr_orbit<'a>(
    env: Env<'a>,
    handle: ResourceArc<SsrStoreResource>,
    satellite_id: String,
) -> NifResult<Term<'a>> {
    let sat = sat_id(&satellite_id)?;
    let store = lock_store(&handle)?;
    Ok(match store.orbit(sat) {
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
    let store = lock_store(&handle)?;
    Ok(match store.clock(sat) {
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
    let store = lock_store(&handle)?;
    Ok(match store.ura_index(sat) {
        Some(ura) => (atoms::ok(), ura as i64).encode(env),
        None => (atoms::error(), atoms::not_found()).encode(env),
    })
}

#[rustler::nif]
fn ssr_store_ingest<'a>(
    env: Env<'a>,
    handle: ResourceArc<SsrStoreResource>,
    message: Term<'a>,
    week: u32,
    tow_s: f64,
) -> NifResult<Term<'a>> {
    let (kind_term, fields): (Term<'a>, Term<'a>) = message.decode()?;
    let kind = kind_term.atom_to_string()?;
    let message = crate::rtcm::build_message(&kind, fields)?;
    let mut store = lock_store(&handle)?;
    Ok(
        match store.ingest(&message, week_tow("GPST".to_string(), week, tow_s)?) {
            Ok(()) => atoms::ok().encode(env),
            Err(error) => (atoms::error(), error.to_string()).encode(env),
        },
    )
}

/// Keeps the established Elixir positional call contract intact.
#[rustler::nif]
#[allow(clippy::too_many_arguments)]
fn ssr_corrected_position<'a>(
    env: Env<'a>,
    broadcast: ResourceArc<BroadcastResource>,
    store: ResourceArc<SsrStoreResource>,
    satellite_id: String,
    t_j2000_s: f64,
    fallback_to_broadcast: bool,
    regional_providers: Vec<u16>,
    size_policy: String,
    satellite_antex: Option<ResourceArc<crate::antex::AntexResource>>,
    attitude: String,
) -> NifResult<Term<'a>> {
    let sat = sat_id(&satellite_id)?;
    let size_policy = correction_size_policy(&size_policy)?;
    let attitude = satellite_attitude(&attitude)?;
    let store = lock_store(&store)?;
    let source = configured_source(
        &broadcast,
        &store,
        fallback_policy(fallback_to_broadcast, regional_providers),
        size_policy,
        attitude,
        satellite_antex.as_deref(),
    );
    if size_policy == SsrCorrectionSizePolicy::Strict {
        if let Some(size) = source.correction_size_refusal(sat, t_j2000_s, t_j2000_s) {
            return Ok((
                atoms::error(),
                (
                    atoms::correction_exceeds_limit(),
                    correction_size_term(size),
                ),
            )
                .encode(env));
        }
    }
    Ok(match source.corrected_state(sat, t_j2000_s) {
        Some((position, clock_s)) => (
            atoms::ok(),
            ((position[0], position[1], position[2]), clock_s),
            oversized_correction_terms(source.oversized_corrections()),
        )
            .encode(env),
        None => (atoms::error(), atoms::not_found()).encode(env),
    })
}

/// Keeps the established Elixir positional call contract intact.
#[rustler::nif]
#[allow(clippy::too_many_arguments)]
fn ssr_corrected_position_at_epoch_query<'a>(
    env: Env<'a>,
    broadcast: ResourceArc<BroadcastResource>,
    store: ResourceArc<SsrStoreResource>,
    satellite_id: String,
    epoch: ResourceArc<ExactEpochQueryResource>,
    selection_epoch: ResourceArc<ExactEpochQueryResource>,
    fallback_to_broadcast: bool,
    regional_providers: Vec<u16>,
    size_policy: String,
    satellite_antex: Option<ResourceArc<crate::antex::AntexResource>>,
    attitude: String,
) -> NifResult<Term<'a>> {
    let sat = sat_id(&satellite_id)?;
    let size_policy = correction_size_policy(&size_policy)?;
    let attitude = satellite_attitude(&attitude)?;
    let store = lock_store(&store)?;
    let source = configured_source(
        &broadcast,
        &store,
        fallback_policy(fallback_to_broadcast, regional_providers),
        size_policy,
        attitude,
        satellite_antex.as_deref(),
    );
    if size_policy == SsrCorrectionSizePolicy::Strict {
        if let Some(size) =
            source.correction_size_refusal_at_epoch_query(sat, &epoch.query, &selection_epoch.query)
        {
            return Ok((
                atoms::error(),
                (
                    atoms::correction_exceeds_limit(),
                    correction_size_term(size),
                ),
            )
                .encode(env));
        }
    }
    match source.corrected_state_with_group_delay_checked_selected_query(
        sat,
        &epoch.query,
        &selection_epoch.query,
    ) {
        Ok(checked) => match checked.value {
            Some((position, clock_s, _)) => Ok((
                atoms::ok(),
                ((position[0], position[1], position[2]), clock_s),
                oversized_correction_terms(source.oversized_corrections()),
            )
                .encode(env)),
            None => Ok((atoms::error(), atoms::not_found()).encode(env)),
        },
        Err(sidereon_core::Error::Ut1OutsideCoverage(reason)) => {
            Err(errors::ut1_outside_coverage(reason))
        }
        Err(error) => Err(errors::invalid_input(error)),
    }
}

/// Keeps the established Elixir positional call contract intact.
#[rustler::nif]
#[allow(clippy::too_many_arguments)]
fn ssr_source_exact_epoch_hook<'a>(
    env: Env<'a>,
    broadcast: ResourceArc<BroadcastResource>,
    store: ResourceArc<SsrStoreResource>,
    satellite_id: String,
    state_epoch: ResourceArc<ExactEpochQueryResource>,
    selection_epoch: ResourceArc<ExactEpochQueryResource>,
    fallback_to_broadcast: bool,
    regional_providers: Vec<u16>,
    size_policy: String,
    hook: String,
    position_m: Option<Vec3>,
    satellite_antex: Option<ResourceArc<crate::antex::AntexResource>>,
    attitude: String,
) -> NifResult<Term<'a>> {
    let satellite = sat_id(&satellite_id)?;
    let size_policy = correction_size_policy(&size_policy)?;
    let attitude = satellite_attitude(&attitude)?;
    let store = lock_store(&store)?;
    let source = configured_source(
        &broadcast,
        &store,
        fallback_policy(fallback_to_broadcast, regional_providers),
        size_policy,
        attitude,
        satellite_antex.as_deref(),
    );
    if size_policy == SsrCorrectionSizePolicy::Strict
        && matches!(hook.as_str(), "selected_state" | "transmit_clock")
    {
        if let Some(size) = source.correction_size_refusal_at_epoch_query(
            satellite,
            &state_epoch.query,
            &selection_epoch.query,
        ) {
            return Ok((
                atoms::error(),
                (
                    atoms::correction_exceeds_limit(),
                    correction_size_term(size),
                ),
            )
                .encode(env));
        }
    }
    let position =
        position_m.map(|(position_x, position_y, position_z)| [position_x, position_y, position_z]);
    if hook == "clock_relativity" && position.is_none() {
        return Err(Error::Term(Box::new(
            "state position is required for clock relativity",
        )));
    }
    Ok(crate::observable_states::source_hook_result(
        env,
        &source,
        satellite,
        &state_epoch.query,
        &selection_epoch.query,
        &hook,
        position,
    ))
}

#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
fn spp_solve_ssr_exact<'a>(
    env: Env<'a>,
    broadcast: ResourceArc<BroadcastResource>,
    store: ResourceArc<SsrStoreResource>,
    receive_epoch: ResourceArc<ExactEpochResource>,
    observations: Vec<(String, f64)>,
    t_rx_second_of_day_s: f64,
    day_of_year: f64,
    initial_guess: (f64, f64, f64, f64),
    apply_iono: bool,
    apply_tropo: bool,
    alpha: (f64, f64, f64, f64),
    beta: (f64, f64, f64, f64),
    pressure_hpa: f64,
    temperature_k: f64,
    relative_humidity: f64,
    with_geodetic: bool,
    robust: Term<'a>,
    max_pdop: Term<'a>,
    coarse_search_seeds: Term<'a>,
    glonass_channels: Term<'a>,
    pseudorange_code: Term<'a>,
    qzss_clock: Term<'a>,
    troposphere_model: Term<'a>,
    fallback_to_broadcast: bool,
    regional_providers: Vec<u16>,
    size_policy: String,
) -> NifResult<Term<'a>> {
    let pseudorange_code = crate::spp::decode_pseudorange_code(pseudorange_code)?;
    let qzss_clock = crate::spp::decode_qzss_clock(qzss_clock)?;
    let troposphere_model = crate::spp::decode_troposphere_model(troposphere_model)?;
    let robust = crate::spp::decode_robust(robust)?;
    let policy = crate::spp::decode_policy(max_pdop, coarse_search_seeds)?;
    let mut inputs = crate::spp::build_solve_inputs(
        observations,
        receive_epoch.epoch.j2000_seconds(),
        t_rx_second_of_day_s,
        day_of_year,
        initial_guess,
        apply_iono,
        apply_tropo,
        alpha,
        beta,
        pressure_hpa,
        temperature_k,
        relative_humidity,
        robust,
    )?;
    crate::spp::set_models(&mut inputs, qzss_clock, troposphere_model);
    inputs.glonass_channels = crate::spp::decode_glonass_channels(glonass_channels)?;
    inputs.pseudorange_code = pseudorange_code;
    let ionosphere = broadcast.store.iono_corrections();
    if let Some(beidou) = ionosphere.beidou {
        inputs.beidou_klobuchar = Some(sidereon_core::positioning::KlobucharCoeffs {
            alpha: beidou.alpha,
            beta: beidou.beta,
        });
    }
    inputs.galileo_nequick = ionosphere.galileo;
    let size_policy = correction_size_policy(&size_policy)?;
    let store = lock_store(&store)?;
    let source = SsrCorrectedEphemeris::new(&broadcast.store, &store)
        .with_fallback(fallback_policy(fallback_to_broadcast, regional_providers))
        .with_correction_size_policy(size_policy);
    Ok(crate::spp::solve_exact_to_term(
        env,
        &source,
        inputs,
        receive_epoch.epoch,
        with_geodetic,
        policy,
    ))
}

#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
fn ssr_sample_broadcast(
    broadcast: ResourceArc<BroadcastResource>,
    store: ResourceArc<SsrStoreResource>,
    satellites: Vec<String>,
    start_j2000_s: f64,
    stop_j2000_s: f64,
    step_s: f64,
    fallback_to_broadcast: bool,
    regional_providers: Vec<u16>,
    size_policy: String,
    satellite_antex: Option<ResourceArc<crate::antex::AntexResource>>,
    attitude: String,
) -> NifResult<Vec<EphemerisSampleRowTerm>> {
    let sats: Vec<GnssSatelliteId> = satellites
        .iter()
        .map(|sat| sat_id(sat))
        .collect::<NifResult<_>>()?;
    let size_policy = correction_size_policy(&size_policy)?;
    let attitude = satellite_attitude(&attitude)?;
    let store = lock_store(&store)?;
    let source = configured_source(
        &broadcast,
        &store,
        fallback_policy(fallback_to_broadcast, regional_providers),
        size_policy,
        attitude,
        satellite_antex.as_deref(),
    );
    let rows = ephemeris::sample(&source, &sats, start_j2000_s, stop_j2000_s, step_s)
        .map_err(errors::invalid_input)?;
    Ok(rows.into_iter().map(sample_row).collect())
}
