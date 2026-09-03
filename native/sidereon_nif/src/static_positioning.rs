//! Rustler boundary for multi-epoch static GNSS positioning.
//!
//! This module reuses the SPP boundary marshalling for each epoch, then calls
//! `sidereon_core::positioning::solve_static`. The stacked least-squares model,
//! covariance, residuals, and influence diagnostics live in the core crate.

use rustler::types::atom;
use rustler::types::tuple::make_tuple;
use rustler::{Encoder, Env, NifResult, ResourceArc, Term};
use sidereon_core::positioning::{
    solve_static, KlobucharCoeffs, StaticEpoch, StaticInfluenceStatus, StaticSolution,
    StaticSolveError, StaticSolveOptions,
};

use crate::broadcast::BroadcastResource;
use crate::geometry_quality::geometry_quality_to_term;
use crate::sp3::Sp3Resource;
use crate::spp::{
    atom_from, build_solve_inputs, decode_robust, matrix3_to_rows, spp_error_reason_term,
    status_atom_name,
};
use std::collections::BTreeMap;

type Vec3 = (f64, f64, f64);

#[derive(Debug, Clone, rustler::NifMap)]
struct StaticEpochTerm {
    observations: Vec<(String, f64)>,
    weights: Option<Vec<f64>>,
    t_rx_j2000_s: f64,
    t_rx_second_of_day_s: f64,
    day_of_year: f64,
    clock_initial_m: f64,
    apply_iono: bool,
    apply_tropo: bool,
    alpha: (f64, f64, f64, f64),
    beta: (f64, f64, f64, f64),
    pressure_hpa: f64,
    temperature_k: f64,
    relative_humidity: f64,
    glonass_channels: Vec<(u8, i8)>,
}

/// Solve one static receiver position from several SP3-backed epochs.
#[rustler::nif(schedule = "DirtyCpu")]
fn static_positioning_solve_sp3<'a>(
    env: Env<'a>,
    handle: ResourceArc<Sp3Resource>,
    epochs: Vec<StaticEpochTerm>,
    initial_position_m: Vec3,
    with_geodetic: bool,
    robust: Term<'a>,
) -> NifResult<Term<'a>> {
    let robust = decode_robust(robust)?;
    let options = static_options(initial_position_m, with_geodetic, robust);
    let epochs = decode_epochs(epochs, initial_position_m, robust)?;
    Ok(match solve_static(&handle.sp3, &epochs, options) {
        Ok(solution) => (atom::ok(), encode_solution(env, &solution)).encode(env),
        Err(error) => (atom::error(), static_error_term(env, &error)).encode(env),
    })
}

/// Solve one static receiver position from several broadcast-backed epochs.
#[rustler::nif(schedule = "DirtyCpu")]
fn static_positioning_solve_broadcast<'a>(
    env: Env<'a>,
    handle: ResourceArc<BroadcastResource>,
    epochs: Vec<StaticEpochTerm>,
    initial_position_m: Vec3,
    with_geodetic: bool,
    robust: Term<'a>,
) -> NifResult<Term<'a>> {
    let robust = decode_robust(robust)?;
    let options = static_options(initial_position_m, with_geodetic, robust);
    let mut epochs = decode_epochs(epochs, initial_position_m, robust)?;
    let iono = handle.store.iono_corrections();
    for epoch in &mut epochs {
        if let Some(bds) = iono.beidou {
            epoch.beidou_klobuchar = Some(KlobucharCoeffs {
                alpha: bds.alpha,
                beta: bds.beta,
            });
        }
        epoch.galileo_nequick = iono.galileo;
    }
    Ok(match solve_static(&handle.store, &epochs, options) {
        Ok(solution) => (atom::ok(), encode_solution(env, &solution)).encode(env),
        Err(error) => (atom::error(), static_error_term(env, &error)).encode(env),
    })
}

fn static_options(
    initial_position_m: Vec3,
    with_geodetic: bool,
    robust: Option<sidereon_core::positioning::RobustConfig>,
) -> StaticSolveOptions {
    let mut options = StaticSolveOptions::default();
    options.initial_position_m = [
        initial_position_m.0,
        initial_position_m.1,
        initial_position_m.2,
    ];
    options.with_geodetic = with_geodetic;
    options.robust = robust;
    options
}

fn decode_epochs(
    epochs: Vec<StaticEpochTerm>,
    initial_position_m: Vec3,
    robust: Option<sidereon_core::positioning::RobustConfig>,
) -> NifResult<Vec<StaticEpoch>> {
    epochs
        .into_iter()
        .map(|epoch| decode_epoch(epoch, initial_position_m, robust))
        .collect()
}

fn decode_epoch(
    epoch: StaticEpochTerm,
    initial_position_m: Vec3,
    robust: Option<sidereon_core::positioning::RobustConfig>,
) -> NifResult<StaticEpoch> {
    let glonass_channels: BTreeMap<u8, i8> = epoch.glonass_channels.into_iter().collect();
    let mut inputs = build_solve_inputs(
        epoch.observations,
        epoch.t_rx_j2000_s,
        epoch.t_rx_second_of_day_s,
        epoch.day_of_year,
        (
            initial_position_m.0,
            initial_position_m.1,
            initial_position_m.2,
            epoch.clock_initial_m,
        ),
        epoch.apply_iono,
        epoch.apply_tropo,
        epoch.alpha,
        epoch.beta,
        epoch.pressure_hpa,
        epoch.temperature_k,
        epoch.relative_humidity,
        robust,
    )?;
    inputs.glonass_channels = glonass_channels;
    let mut static_epoch = StaticEpoch::from_solve_inputs(inputs);
    static_epoch.weights = epoch.weights;
    Ok(static_epoch)
}

fn encode_solution<'a>(env: Env<'a>, solution: &StaticSolution) -> Term<'a> {
    let position_array = solution.position.as_array();
    let position = (position_array[0], position_array[1], position_array[2]);
    let geodetic = match solution.geodetic {
        Some(geodetic) => (geodetic.lat_rad, geodetic.lon_rad, geodetic.height_m).encode(env),
        None => atom::nil().encode(env),
    };
    let per_epoch_clock: Vec<(i64, String, f64)> = solution
        .per_epoch_clock
        .iter()
        .map(|clock| {
            (
                clock.epoch_index as i64,
                clock.system.letter().to_string(),
                clock.clock_s,
            )
        })
        .collect();
    let covariance = (
        solution.covariance.state_m2.clone(),
        matrix3_to_rows(solution.covariance.position_ecef_m2),
        matrix3_to_rows(solution.covariance.position_enu_m2),
    );
    let per_epoch_influence: Vec<Term<'a>> = solution
        .per_epoch_influence
        .iter()
        .map(|row| {
            (
                row.epoch_index as i64,
                row.omitted_measurements as i64,
                influence_status_atom(env, row.status),
                optional_vec3(env, row.position_delta_m),
                optional_f64(env, row.position_delta_norm_m),
                optional_f64(env, row.residual_rms_m),
                row.min_robust_weight_ratio,
            )
                .encode(env)
        })
        .collect();
    let per_satellite_influence: Vec<Term<'a>> = solution
        .per_satellite_influence
        .iter()
        .map(|row| {
            make_tuple(
                env,
                &[
                    (row.epoch_index as i64).encode(env),
                    row.satellite_id.to_string().encode(env),
                    influence_status_atom(env, row.status),
                    optional_vec3(env, row.position_delta_m),
                    optional_f64(env, row.position_delta_norm_m),
                    optional_f64(env, row.residual_rms_m),
                    row.residual_m.encode(env),
                    row.base_weight.encode(env),
                    row.effective_weight.encode(env),
                    row.robust_weight_ratio.encode(env),
                ],
            )
        })
        .collect();
    let per_satellite_batch_influence: Vec<Term<'a>> = solution
        .per_satellite_batch_influence
        .iter()
        .map(|row| {
            (
                row.satellite_id.to_string(),
                row.omitted_measurements as i64,
                influence_status_atom(env, row.status),
                optional_vec3(env, row.position_delta_m),
                optional_f64(env, row.position_delta_norm_m),
                optional_f64(env, row.residual_rms_m),
                row.min_robust_weight_ratio,
            )
                .encode(env)
        })
        .collect();
    let residuals: Vec<(i64, String, f64, f64, f64, f64)> = solution
        .residuals_m
        .iter()
        .map(|row| {
            (
                row.epoch_index as i64,
                row.satellite_id.to_string(),
                row.residual_m,
                row.base_weight,
                row.effective_weight,
                row.robust_weight_ratio,
            )
        })
        .collect();
    let used_sats: Vec<Vec<String>> = solution
        .used_sats
        .iter()
        .map(|epoch| epoch.iter().map(ToString::to_string).collect())
        .collect();
    let rejected_sats: Vec<Vec<Term<'a>>> = solution
        .rejected_sats
        .iter()
        .map(|epoch| {
            epoch
                .iter()
                .map(|row| {
                    (
                        row.satellite_id.to_string(),
                        rejection_reason_atom(env, row.reason),
                    )
                        .encode(env)
                })
                .collect()
        })
        .collect();
    let status = atom_from(env, status_atom_name(solution.metadata.status));
    let final_robust_scale = optional_f64(env, solution.metadata.final_robust_scale_m);
    let metadata = make_tuple(
        env,
        &[
            (solution.metadata.iterations as i64).encode(env),
            solution.metadata.converged.encode(env),
            status,
            (solution.metadata.outer_iterations as i64).encode(env),
            final_robust_scale,
            (solution.metadata.used_measurements as i64).encode(env),
            (solution.metadata.n_parameters as i64).encode(env),
            (solution.metadata.redundancy as i64).encode(env),
        ],
    );

    make_tuple(
        env,
        &[
            position.encode(env),
            geodetic,
            per_epoch_clock.encode(env),
            covariance.encode(env),
            per_epoch_influence.encode(env),
            per_satellite_influence.encode(env),
            per_satellite_batch_influence.encode(env),
            geometry_quality_to_term(env, solution.geometry_quality),
            residuals.encode(env),
            used_sats.encode(env),
            rejected_sats.encode(env),
            metadata,
            solution.residual_rms_m().encode(env),
        ],
    )
}

fn optional_vec3<'a>(env: Env<'a>, value: Option<[f64; 3]>) -> Term<'a> {
    match value {
        Some(value) => (value[0], value[1], value[2]).encode(env),
        None => atom::nil().encode(env),
    }
}

fn optional_f64<'a>(env: Env<'a>, value: Option<f64>) -> Term<'a> {
    match value {
        Some(value) => value.encode(env),
        None => atom::nil().encode(env),
    }
}

fn influence_status_atom<'a>(env: Env<'a>, status: StaticInfluenceStatus) -> Term<'a> {
    let name = match status {
        StaticInfluenceStatus::Solved => "solved",
        StaticInfluenceStatus::TooFewMeasurements => "too_few_measurements",
        StaticInfluenceStatus::SingularGeometry => "singular_geometry",
        StaticInfluenceStatus::InvalidInput => "invalid_input",
        StaticInfluenceStatus::EphemerisUnavailable => "ephemeris_unavailable",
        StaticInfluenceStatus::SolveFailed => "solve_failed",
    };
    atom_from(env, name)
}

fn rejection_reason_atom<'a>(
    env: Env<'a>,
    reason: sidereon_core::positioning::RejectionReason,
) -> Term<'a> {
    let name = match reason {
        sidereon_core::positioning::RejectionReason::NoEphemeris => "no_ephemeris",
        sidereon_core::positioning::RejectionReason::LowElevation => "low_elevation",
        sidereon_core::positioning::RejectionReason::SbasWithdrawn => "sbas_withdrawn",
        sidereon_core::positioning::RejectionReason::SbasIonoUncovered => "sbas_iono_uncovered",
    };
    atom_from(env, name)
}

fn static_error_term<'a>(env: Env<'a>, error: &StaticSolveError) -> Term<'a> {
    match error {
        StaticSolveError::EmptyEpochs => atom_from(env, "empty_epochs"),
        StaticSolveError::InvalidInput { field, kind } => {
            (atom_from(env, "invalid_input"), *field, kind.to_string()).encode(env)
        }
        StaticSolveError::EpochInput {
            epoch_index,
            source,
        } => (
            atom_from(env, "epoch_input"),
            *epoch_index as i64,
            spp_error_reason_term(env, source),
        )
            .encode(env),
        StaticSolveError::DuplicateObservation {
            epoch_index,
            satellite,
        } => (
            atom_from(env, "duplicate_observation"),
            *epoch_index as i64,
            satellite.to_string(),
        )
            .encode(env),
        StaticSolveError::IonosphereUnsupported {
            epoch_index,
            satellite,
        } => (
            atom_from(env, "ionosphere_unsupported"),
            *epoch_index as i64,
            satellite.to_string(),
        )
            .encode(env),
        StaticSolveError::TooFewMeasurements { used, required } => (
            atom_from(env, "too_few_measurements"),
            *used as i64,
            *required as i64,
        )
            .encode(env),
        StaticSolveError::EphemerisLost {
            epoch_index,
            satellite,
        } => (
            atom_from(env, "ephemeris_lost"),
            *epoch_index as i64,
            satellite.to_string(),
        )
            .encode(env),
        StaticSolveError::Singular(_) => atom_from(env, "singular_geometry"),
    }
}
