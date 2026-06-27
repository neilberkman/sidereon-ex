//! Rustler boundary for the sequential RTK filter kernel.
//!
//! This is intentionally a traceable primitive, not the public RTK API: Elixir
//! still owns normalization/reporting while the kernel migration is gated. Terms
//! are plain tuples/lists so parity tests can feed the exact epoch/state stream
//! into Rust without introducing a second Elixir struct layer.

use crate::strategy::decode_strategy;
use rustler::types::tuple::make_tuple;
use rustler::{Encoder, Env, NifResult, Term};
use sidereon_core::estimation::{
    estimate, EstimateError, EstimateInput, EstimateOptions, EstimateOutput, Technique,
};
use sidereon_core::rtk_filter::{
    solve_fixed_baseline, update_epoch, AmbiguityScale, AmbiguitySet, DynamicsModel, Epoch,
    FilterState, FixedBaselineSolution, FixedSolveError, FixedSolveOpts, FloatBaselineSolution,
    FloatPrior, FloatResidual, FloatSolveError, FloatSolveOpts, FloatSolveStatus,
    FullSetIntegerSummary, InnovationScreen, InnovationScreenOpts, IntegerSearchMeta,
    IntegerStatus, MeasModel, ReceiverAntennaCalibration, ReceiverAntennaCorrections,
    ResidualComponentKind, ResidualValidationMeta, ResidualValidationOpts,
    ResidualValidationOutlier, SatMeas, SearchOpts, StochasticModel, UpdateError, UpdateOpts,
    ValidatedFixedBaselineSolution, ValidatedFixedSolveError, ValidatedFixedSolveOpts,
};
use std::collections::BTreeMap;

type Vec3 = (f64, f64, f64);
type SatIdsTerm = (String, String);
type SatObsTerm = (f64, f64, f64, f64);
type SatPosTerm = (Vec3, Vec3, Vec3);
type SatTerm = (SatIdsTerm, SatObsTerm, SatPosTerm);
// References: the per-system reference satellites present this epoch (one per
// constellation letter), then the non-reference satellites, optional rover ECEF
// velocity, and elapsed seconds for the prediction step.
type EpochTerm = (Vec<SatTerm>, Vec<SatTerm>, Option<Vec3>, f64);
// Header references: sorted [{system_letter, reference_sd_ambiguity_id}].
type StateHeaderTerm = (u16, Vec<(String, String)>, Vec<String>, f64, usize);
type StateTerm = (
    StateHeaderTerm,
    Vec3,
    Vec<f64>,
    Vec<f64>,
    Vec<(String, i64)>,
    Vec<(String, f64)>,
);
type ScreenTailTerm = (usize, Option<f64>, Option<f64>, bool);
type ScreenTerm = (f64, usize, usize, usize, usize, usize, ScreenTailTerm);
type ModelTerm = (f64, f64, String, bool, bool);
type UpdateOptsExtraTerm = (String, Vec<String>, f64, usize, Option<f64>, bool);
type UpdateOptsTerm = (f64, f64, f64, usize, f64, f64, UpdateOptsExtraTerm);
type FloatSolveOptsTerm = (Vec3, f64, f64, usize);
type FixedSolveOptsTerm = (f64, f64, usize, f64, bool, usize, Vec<String>);
type ResidualValidationOptsTerm = (Option<f64>, usize);
type PcvNoaziTerm = (f64, f64);
type PcvAziTerm = (f64, f64, f64);
type ReceiverAntennaCorrectionTerm = (Vec3, Vec<PcvNoaziTerm>, Vec<PcvAziTerm>);
type ReceiverAntennaCorrectionsTerm =
    (ReceiverAntennaCorrectionTerm, ReceiverAntennaCorrectionTerm);

mod atoms {
    rustler::atoms! {
        ok,
        error,
        infinity,
        invalid_stochastic_model,
        invalid_dynamics_model,
        reference_changed,
        unknown_reference_system,
        missing_system_reference,
        missing_ambiguity_column,
        missing_wavelength,
        missing_offset,
        singular_geometry,
        incomplete_residual_pair,
        no_integer_candidates,
        too_many_integer_candidates,
        invalid_dimensions,
        invalid_covariance_dimensions,
        non_finite_input,
        search_limit_exceeded,
        residual_validation_failed,
        duplicate_ambiguity_id,
        underdetermined,
        invalid_input,
        invalid_state,
        receiver_antenna
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
pub fn rtk_solve_float_baseline<'a>(
    env: Env<'a>,
    epoch_terms: Vec<EpochTerm>,
    base: Vec3,
    ambiguity_ids: Vec<String>,
    model_term: ModelTerm,
    opts_term: FloatSolveOptsTerm,
    receiver_antenna_corrections_term: Option<ReceiverAntennaCorrectionsTerm>,
    strategy: Term<'a>,
) -> NifResult<Term<'a>> {
    let Some(model) = decode_model(model_term) else {
        return Ok((atoms::error(), atoms::invalid_stochastic_model()).encode(env));
    };
    let strategy = decode_strategy(strategy)?;
    let (initial_baseline_m, position_tol_m, ambiguity_tol_m, max_iterations) = opts_term;
    let receiver_antenna_corrections =
        receiver_antenna_corrections_term.map(decode_receiver_antenna_corrections);
    let epochs: Vec<Epoch> = epoch_terms.into_iter().map(decode_epoch).collect();

    // Drive the shared estimate() selector: Reference is byte-identical to the
    // legacy solve_float_baseline path (itself an estimate(.., reference) call),
    // Canonical selects the owned Cholesky square-root-information solve.
    match estimate(
        EstimateInput::RtkFloat {
            epochs: &epochs,
            base: vec3(base),
            ambiguity_ids: &ambiguity_ids,
            initial_baseline_m: vec3(initial_baseline_m),
            model: &model,
            opts: FloatSolveOpts {
                position_tol_m,
                ambiguity_tol_m,
                max_iterations,
            },
            receiver_antenna_corrections: receiver_antenna_corrections.as_ref(),
        },
        EstimateOptions::new(strategy.strategy_id(Technique::Rtk)),
    ) {
        Ok(EstimateOutput::RtkFloat(solution)) => {
            Ok((atoms::ok(), encode_float_solution(env, *solution)).encode(env))
        }
        Err(EstimateError::RtkFloat(err)) => {
            Ok((atoms::error(), encode_float_error(env, err)).encode(env))
        }
        Ok(_) | Err(_) => {
            unreachable!("an RTK float input yields an RTK float solution or an RTK float error")
        }
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
pub fn rtk_solve_fixed_baseline<'a>(
    env: Env<'a>,
    epoch_terms: Vec<EpochTerm>,
    base: Vec3,
    ambiguity_ids: Vec<String>,
    float_baseline_m: Vec3,
    float_ambiguities_m: Vec<(String, f64)>,
    float_covariance_m: Vec<Vec<f64>>,
    wavelengths_m: Vec<(String, f64)>,
    offsets_m: Vec<(String, f64)>,
    ambiguity_satellites: Vec<(String, String)>,
    model_term: ModelTerm,
    opts_term: FixedSolveOptsTerm,
    receiver_antenna_corrections_term: Option<ReceiverAntennaCorrectionsTerm>,
) -> NifResult<Term<'a>> {
    let Some(model) = decode_model(model_term) else {
        return Ok((atoms::error(), atoms::invalid_stochastic_model()).encode(env));
    };
    let (
        position_tol_m,
        ambiguity_tol_m,
        max_iterations,
        ratio_threshold,
        partial_ambiguity_resolution,
        partial_min_ambiguities,
        float_only_systems,
    ) = opts_term;
    let receiver_antenna_corrections =
        receiver_antenna_corrections_term.map(decode_receiver_antenna_corrections);

    let result = solve_fixed_baseline(
        &epoch_terms
            .into_iter()
            .map(decode_epoch)
            .collect::<Vec<_>>(),
        vec3(base),
        AmbiguitySet {
            ids: &ambiguity_ids,
            satellites: &ambiguity_satellites.into_iter().collect::<BTreeMap<_, _>>(),
            scale: AmbiguityScale {
                wavelengths_m: &wavelengths_m.into_iter().collect::<BTreeMap<_, _>>(),
                offsets_m: &offsets_m.into_iter().collect::<BTreeMap<_, _>>(),
            },
            float_only_systems: &float_only_systems,
        },
        FloatPrior {
            baseline_m: vec3(float_baseline_m),
            ambiguities_m: &float_ambiguities_m,
            covariance_m: &float_covariance_m.into_iter().flatten().collect::<Vec<_>>(),
        },
        &model,
        FixedSolveOpts {
            position_tol_m,
            ambiguity_tol_m,
            max_iterations,
            ratio_threshold,
            partial_ambiguity_resolution,
            partial_min_ambiguities,
        },
        receiver_antenna_corrections.as_ref(),
    );

    match result {
        Ok(solution) => Ok((atoms::ok(), encode_fixed_solution(env, solution)).encode(env)),
        Err(err) => Ok((atoms::error(), encode_fixed_error(env, err)).encode(env)),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
pub fn rtk_solve_fixed_baseline_validated<'a>(
    env: Env<'a>,
    epoch_terms: Vec<EpochTerm>,
    base: Vec3,
    ambiguity_ids: Vec<String>,
    wavelengths_m: Vec<(String, f64)>,
    offsets_m: Vec<(String, f64)>,
    ambiguity_satellites: Vec<(String, String)>,
    model_term: ModelTerm,
    float_opts_term: FloatSolveOptsTerm,
    fixed_opts_term: FixedSolveOptsTerm,
    residual_opts_term: ResidualValidationOptsTerm,
    receiver_antenna_corrections_term: Option<ReceiverAntennaCorrectionsTerm>,
    strategy: Term<'a>,
) -> NifResult<Term<'a>> {
    let Some(model) = decode_model(model_term) else {
        return Ok((atoms::error(), atoms::invalid_stochastic_model()).encode(env));
    };
    let strategy = decode_strategy(strategy)?;
    let (initial_baseline_m, position_tol_m, ambiguity_tol_m, max_iterations) = float_opts_term;
    let (
        fixed_position_tol_m,
        fixed_ambiguity_tol_m,
        fixed_max_iterations,
        ratio_threshold,
        partial_ambiguity_resolution,
        partial_min_ambiguities,
        float_only_systems,
    ) = fixed_opts_term;
    let (threshold_sigma, max_exclusions) = residual_opts_term;
    let receiver_antenna_corrections =
        receiver_antenna_corrections_term.map(decode_receiver_antenna_corrections);
    // Bind the AmbiguitySet-backing maps and epoch stream to locals so the
    // borrowed AmbiguitySet outlives the estimate() call.
    let epochs: Vec<Epoch> = epoch_terms.into_iter().map(decode_epoch).collect();
    let satellites: BTreeMap<String, String> = ambiguity_satellites.into_iter().collect();
    let wavelengths: BTreeMap<String, f64> = wavelengths_m.into_iter().collect();
    let offsets: BTreeMap<String, f64> = offsets_m.into_iter().collect();

    // Drive the shared estimate() selector: Reference is byte-identical to the
    // legacy solve_fixed_baseline_validated path, Canonical selects the owned
    // Cholesky square-root-information solve in both the float and fixed runners.
    let result = estimate(
        EstimateInput::RtkFixed {
            epochs: &epochs,
            base: vec3(base),
            initial_ambiguities: AmbiguitySet {
                ids: &ambiguity_ids,
                satellites: &satellites,
                scale: AmbiguityScale {
                    wavelengths_m: &wavelengths,
                    offsets_m: &offsets,
                },
                float_only_systems: &float_only_systems,
            },
            initial_baseline_m: vec3(initial_baseline_m),
            model: &model,
            opts: ValidatedFixedSolveOpts {
                float: FloatSolveOpts {
                    position_tol_m,
                    ambiguity_tol_m,
                    max_iterations,
                },
                fixed: FixedSolveOpts {
                    position_tol_m: fixed_position_tol_m,
                    ambiguity_tol_m: fixed_ambiguity_tol_m,
                    max_iterations: fixed_max_iterations,
                    ratio_threshold,
                    partial_ambiguity_resolution,
                    partial_min_ambiguities,
                },
                residual: ResidualValidationOpts {
                    threshold_sigma,
                    max_exclusions,
                },
            },
            receiver_antenna_corrections: receiver_antenna_corrections.as_ref(),
        },
        EstimateOptions::new(strategy.strategy_id(Technique::Rtk)),
    );

    match result {
        Ok(EstimateOutput::RtkFixed(solution)) => {
            Ok((atoms::ok(), encode_validated_fixed_solution(env, *solution)).encode(env))
        }
        Err(EstimateError::RtkFixed(err)) => {
            Ok((atoms::error(), encode_validated_fixed_error(env, err)).encode(env))
        }
        Ok(_) | Err(_) => {
            unreachable!("an RTK fixed input yields an RTK fixed solution or an RTK fixed error")
        }
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
pub fn rtk_filter_update_epoch<'a>(
    env: Env<'a>,
    state_term: StateTerm,
    epoch_term: EpochTerm,
    base: Vec3,
    model_term: ModelTerm,
    wavelengths: Vec<(String, f64)>,
    offsets: Vec<(String, f64)>,
    opts_term: UpdateOptsTerm,
    receiver_antenna_corrections_term: Option<ReceiverAntennaCorrectionsTerm>,
) -> NifResult<Term<'a>> {
    let Some(model) = decode_model(model_term) else {
        return Ok((atoms::error(), atoms::invalid_stochastic_model()).encode(env));
    };

    let Some(mut opts) = decode_opts(opts_term) else {
        return Ok((atoms::error(), atoms::invalid_dynamics_model()).encode(env));
    };
    opts.receiver_antenna_corrections =
        receiver_antenna_corrections_term.map(decode_receiver_antenna_corrections);

    let update = match update_epoch(
        decode_state(state_term),
        &decode_epoch(epoch_term),
        vec3(base),
        &model,
        &wavelengths.into_iter().collect::<BTreeMap<_, _>>(),
        &offsets.into_iter().collect::<BTreeMap<_, _>>(),
        &opts,
    ) {
        Ok(update) => update,
        Err(err) => return Ok((atoms::error(), encode_update_error(env, err)).encode(env)),
    };

    Ok((atoms::ok(), encode_update(env, update)).encode(env))
}

#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
pub fn rtk_filter_update_epochs<'a>(
    env: Env<'a>,
    state_term: StateTerm,
    epoch_terms: Vec<EpochTerm>,
    base: Vec3,
    model_term: ModelTerm,
    wavelengths: Vec<(String, f64)>,
    offsets: Vec<(String, f64)>,
    opts_term: UpdateOptsTerm,
    receiver_antenna_corrections_term: Option<ReceiverAntennaCorrectionsTerm>,
) -> NifResult<Term<'a>> {
    let Some(model) = decode_model(model_term) else {
        return Ok((atoms::error(), atoms::invalid_stochastic_model()).encode(env));
    };

    let base = vec3(base);
    let wavelengths = wavelengths.into_iter().collect::<BTreeMap<_, _>>();
    let offsets = offsets.into_iter().collect::<BTreeMap<_, _>>();
    let Some(mut opts) = decode_opts(opts_term) else {
        return Ok((atoms::error(), atoms::invalid_dynamics_model()).encode(env));
    };
    opts.receiver_antenna_corrections =
        receiver_antenna_corrections_term.map(decode_receiver_antenna_corrections);
    let mut state = decode_state(state_term);
    let mut updates = Vec::with_capacity(epoch_terms.len());

    for (idx, epoch_term) in epoch_terms.into_iter().enumerate() {
        let update = match update_epoch(
            state,
            &decode_epoch(epoch_term),
            base,
            &model,
            &wavelengths,
            &offsets,
            &opts,
        ) {
            Ok(update) => update,
            // Carry the failing epoch index so a long-arc failure is a lookup,
            // not a debugging session: {:error, epoch_index, reason}.
            Err(err) => return Ok((atoms::error(), idx, encode_update_error(env, err)).encode(env)),
        };

        state = update.state.clone();
        updates.push(encode_update(env, update));
    }

    Ok((atoms::ok(), updates).encode(env))
}

fn encode_float_solution<'a>(env: Env<'a>, solution: FloatBaselineSolution) -> Term<'a> {
    let n = solution.ambiguities_m.len();
    let residuals = encode_residuals(env, solution.residuals);
    let summary = make_tuple(
        env,
        &[
            (solution.iterations as u64).encode(env),
            solution.converged.encode(env),
            encode_float_status(solution.status).encode(env),
            solution.code_rms_m.encode(env),
            solution.phase_rms_m.encode(env),
            solution.weighted_rms_m.encode(env),
            (solution.n_observations as u64).encode(env),
        ],
    );

    make_tuple(
        env,
        &[
            tuple3(solution.baseline_m).encode(env),
            solution.ambiguities_m.encode(env),
            matrix_rows(solution.ambiguity_covariance_m, n).encode(env),
            matrix_rows(solution.ambiguity_covariance_inverse_m, n).encode(env),
            residuals.encode(env),
            summary,
        ],
    )
}

fn encode_fixed_solution<'a>(env: Env<'a>, solution: FixedBaselineSolution) -> Term<'a> {
    let residuals = encode_residuals(env, solution.residuals);
    let summary = make_tuple(
        env,
        &[
            (solution.iterations as u64).encode(env),
            solution.converged.encode(env),
            encode_float_status(solution.status).encode(env),
            solution.code_rms_m.encode(env),
            solution.phase_rms_m.encode(env),
            solution.weighted_rms_m.encode(env),
            (solution.n_observations as u64).encode(env),
        ],
    );

    make_tuple(
        env,
        &[
            tuple3(solution.baseline_m).encode(env),
            solution.free_ambiguities_m.encode(env),
            solution.fixed_ambiguities_cycles.encode(env),
            solution.fixed_ambiguities_m.encode(env),
            residuals.encode(env),
            summary,
            encode_integer_search_meta(env, solution.search),
        ],
    )
}

fn encode_validated_fixed_solution<'a>(
    env: Env<'a>,
    solution: ValidatedFixedBaselineSolution,
) -> Term<'a> {
    make_tuple(
        env,
        &[
            encode_float_solution(env, solution.float_solution),
            encode_fixed_solution(env, solution.fixed_solution),
            solution
                .residual_validation
                .map(|meta| encode_residual_validation_meta(env, meta))
                .encode(env),
            solution.ambiguity_ids.encode(env),
            solution
                .ambiguity_satellites
                .into_iter()
                .collect::<Vec<_>>()
                .encode(env),
        ],
    )
}

fn encode_residuals<'a>(env: Env<'a>, residuals: Vec<FloatResidual>) -> Vec<Term<'a>> {
    residuals
        .into_iter()
        .map(|r| {
            make_tuple(
                env,
                &[
                    (r.epoch_index as u64).encode(env),
                    r.satellite_id.encode(env),
                    r.reference_satellite_id.encode(env),
                    r.ambiguity_id.encode(env),
                    r.code_m.encode(env),
                    r.phase_m.encode(env),
                    r.code_sigma_m.encode(env),
                    r.phase_sigma_m.encode(env),
                    r.code_normalized.encode(env),
                    r.phase_normalized.encode(env),
                ],
            )
        })
        .collect()
}

fn encode_residual_validation_meta<'a>(env: Env<'a>, meta: ResidualValidationMeta) -> Term<'a> {
    make_tuple(
        env,
        &[
            meta.threshold_sigma.encode(env),
            (meta.max_exclusions as u64).encode(env),
            meta.excluded_sats.encode(env),
            encode_residual_validation_outliers(env, meta.exclusions).encode(env),
        ],
    )
}

fn encode_residual_validation_outliers<'a>(
    env: Env<'a>,
    outliers: Vec<ResidualValidationOutlier>,
) -> Vec<Term<'a>> {
    outliers
        .into_iter()
        .map(|outlier| encode_residual_validation_outlier(env, outlier))
        .collect()
}

fn encode_residual_validation_outlier<'a>(
    env: Env<'a>,
    outlier: ResidualValidationOutlier,
) -> Term<'a> {
    make_tuple(
        env,
        &[
            (outlier.epoch_index as u64).encode(env),
            outlier.satellite_id.encode(env),
            outlier.reference_satellite_id.encode(env),
            outlier.ambiguity_id.encode(env),
            encode_residual_component_kind(outlier.kind).encode(env),
            outlier.residual_m.encode(env),
            outlier.sigma_m.encode(env),
            outlier.normalized_residual.encode(env),
            outlier.threshold_sigma.encode(env),
        ],
    )
}

fn encode_residual_component_kind(kind: ResidualComponentKind) -> &'static str {
    match kind {
        ResidualComponentKind::Code => "code",
        ResidualComponentKind::Phase => "phase",
    }
}

fn encode_integer_search_meta<'a>(env: Env<'a>, meta: IntegerSearchMeta) -> Term<'a> {
    let n = meta.ambiguity_search.order.len();
    let ambiguity_search = make_tuple(
        env,
        &[
            meta.ambiguity_search.order.encode(env),
            meta.ambiguity_search.float_cycles.encode(env),
            matrix_rows(meta.ambiguity_search.covariance_cycles, n).encode(env),
            matrix_rows(meta.ambiguity_search.covariance_inverse_cycles, n).encode(env),
        ],
    );
    let partial = make_tuple(
        env,
        &[
            meta.partial.enabled.encode(env),
            meta.partial.fixed.encode(env),
            meta.partial.fixed_ambiguities.encode(env),
            meta.partial.free_ambiguities.encode(env),
            encode_full_set_integer_summary(env, meta.partial.full_set),
            option_usize_term(env, meta.partial.exhaustive_subsets_evaluated),
        ],
    );

    make_tuple(
        env,
        &[
            encode_integer_status(meta.integer_status).encode(env),
            meta.integer_method.encode(env),
            option_f64_term(env, meta.integer_ratio),
            option_f64_term(env, meta.integer_best_score),
            option_f64_term(env, meta.integer_second_best_score),
            (meta.integer_candidates as u64).encode(env),
            ambiguity_search,
            meta.ambiguity_offsets_m.encode(env),
            partial,
        ],
    )
}

fn encode_full_set_integer_summary<'a>(
    env: Env<'a>,
    summary: Option<FullSetIntegerSummary>,
) -> Term<'a> {
    match summary {
        Some(summary) => make_tuple(
            env,
            &[
                encode_integer_status(summary.integer_status).encode(env),
                option_f64_term(env, summary.integer_ratio),
                option_f64_term(env, summary.integer_best_score),
                option_f64_term(env, summary.integer_second_best_score),
                (summary.integer_candidates as u64).encode(env),
                summary.order.encode(env),
            ],
        ),
        None => rustler::types::atom::nil().encode(env),
    }
}

fn encode_integer_status(status: IntegerStatus) -> &'static str {
    match status {
        IntegerStatus::Fixed => "fixed",
        IntegerStatus::NotFixed => "not_fixed",
    }
}

fn option_f64_term<'a>(env: Env<'a>, value: Option<f64>) -> Term<'a> {
    match value {
        Some(value) if value.is_infinite() => atoms::infinity().encode(env),
        Some(value) => value.encode(env),
        None => rustler::types::atom::nil().encode(env),
    }
}

fn option_usize_term<'a>(env: Env<'a>, value: Option<usize>) -> Term<'a> {
    match value {
        Some(value) => (value as u64).encode(env),
        None => rustler::types::atom::nil().encode(env),
    }
}

fn encode_float_status(status: FloatSolveStatus) -> String {
    match status {
        FloatSolveStatus::StateTolerance => "state_tolerance".to_string(),
        FloatSolveStatus::MaxIterations => "max_iterations".to_string(),
    }
}

fn matrix_rows(values: Vec<f64>, n: usize) -> Vec<Vec<f64>> {
    values.chunks(n).map(|row| row.to_vec()).collect()
}

fn encode_validated_fixed_error<'a>(env: Env<'a>, err: ValidatedFixedSolveError) -> Term<'a> {
    match err {
        ValidatedFixedSolveError::Fixed(err) => encode_fixed_error(env, err),
        ValidatedFixedSolveError::ResidualValidationFailed {
            outlier,
            exclusions,
        } => (
            atoms::residual_validation_failed(),
            encode_residual_validation_outlier(env, *outlier),
            encode_residual_validation_outliers(env, exclusions),
        )
            .encode(env),
        ValidatedFixedSolveError::DuplicateAmbiguityId {
            ambiguity_id,
            first_satellite_id,
            second_satellite_id,
        } => (
            atoms::duplicate_ambiguity_id(),
            ambiguity_id,
            first_satellite_id,
            second_satellite_id,
        )
            .encode(env),
        ValidatedFixedSolveError::Underdetermined {
            row_count,
            unknown_count,
        } => (
            atoms::underdetermined(),
            row_count as u64,
            unknown_count as u64,
        )
            .encode(env),
    }
}

fn encode_fixed_error<'a>(env: Env<'a>, err: FixedSolveError) -> Term<'a> {
    match err {
        FixedSolveError::InvalidInput { .. } => atoms::invalid_input().encode(env),
        FixedSolveError::ReceiverAntenna(_) => atoms::receiver_antenna().encode(env),
        FixedSolveError::Float(err) => encode_float_error(env, err),
        FixedSolveError::Ils(err) => encode_ils_error(env, err),
        FixedSolveError::MissingAmbiguity(id) => {
            (atoms::missing_ambiguity_column(), id).encode(env)
        }
        FixedSolveError::MissingWavelength(id) => (atoms::missing_wavelength(), id).encode(env),
        FixedSolveError::MissingOffset(id) => (atoms::missing_offset(), id).encode(env),
        FixedSolveError::InvalidCovarianceDimensions => {
            atoms::invalid_covariance_dimensions().encode(env)
        }
        FixedSolveError::SingularGeometry => atoms::singular_geometry().encode(env),
        FixedSolveError::IncompleteResidualPair => atoms::incomplete_residual_pair().encode(env),
    }
}

fn encode_float_error<'a>(env: Env<'a>, err: FloatSolveError) -> Term<'a> {
    match err {
        FloatSolveError::InvalidInput { .. } => atoms::invalid_input().encode(env),
        FloatSolveError::ReceiverAntenna(_) => atoms::receiver_antenna().encode(env),
        FloatSolveError::MissingSystemReference(system) => {
            (atoms::missing_system_reference(), system).encode(env)
        }
        FloatSolveError::MissingAmbiguityColumn(id) => {
            (atoms::missing_ambiguity_column(), id).encode(env)
        }
        FloatSolveError::SingularGeometry => atoms::singular_geometry().encode(env),
        FloatSolveError::IncompleteResidualPair => atoms::incomplete_residual_pair().encode(env),
    }
}

fn encode_update<'a>(env: Env<'a>, update: sidereon_core::rtk_filter::EpochUpdate) -> Term<'a> {
    make_tuple(
        env,
        &[
            encode_state(update.state).encode(env),
            tuple3(update.reported_baseline_m).encode(env),
            update.reported_sd_ambiguities_m.encode(env),
            update.integer_ratio.encode(env),
            update.integer_fixed.encode(env),
            update.newly_fixed.encode(env),
            update.fixed_ids.encode(env),
            update
                .search
                .map(|meta| encode_integer_search_meta(env, meta))
                .encode(env),
            update
                .innovation_screen
                .map(encode_innovation_screen)
                .encode(env),
            encode_residuals(env, update.residuals).encode(env),
        ],
    )
}

fn encode_innovation_screen(screen: InnovationScreen) -> ScreenTerm {
    (
        screen.threshold_sigma,
        screen.min_rows,
        screen.input_rows,
        screen.accepted_rows,
        screen.rejected_rows,
        screen.rejected_code_rows,
        (
            screen.rejected_phase_rows,
            screen.max_abs_normalized_innovation,
            screen.max_rejected_abs_normalized_innovation,
            screen.coasted,
        ),
    )
}

fn encode_update_error<'a>(env: Env<'a>, err: UpdateError) -> Term<'a> {
    match err {
        UpdateError::InvalidState { .. } => atoms::invalid_state().encode(env),
        UpdateError::InvalidInput { .. } => atoms::invalid_input().encode(env),
        UpdateError::ReceiverAntenna(_) => atoms::receiver_antenna().encode(env),
        UpdateError::ReferenceChanged {
            system,
            expected,
            actual,
        } => (atoms::reference_changed(), system, expected, actual).encode(env),
        UpdateError::UnknownReferenceSystem(system) => {
            (atoms::unknown_reference_system(), system).encode(env)
        }
        UpdateError::MissingSystemReference(system) => {
            (atoms::missing_system_reference(), system).encode(env)
        }
        UpdateError::MissingAmbiguityColumn(id) => {
            (atoms::missing_ambiguity_column(), id).encode(env)
        }
        UpdateError::MissingWavelength(id) => (atoms::missing_wavelength(), id).encode(env),
        UpdateError::MissingOffset(id) => (atoms::missing_offset(), id).encode(env),
        UpdateError::SingularGeometry => atoms::singular_geometry().encode(env),
        UpdateError::Ils(err) => encode_ils_error(env, err),
    }
}

fn encode_ils_error<'a>(env: Env<'a>, err: sidereon_core::ils::IlsError) -> Term<'a> {
    match err {
        sidereon_core::ils::IlsError::Singular => atoms::singular_geometry().encode(env),
        sidereon_core::ils::IlsError::NoCandidates(n) => {
            (atoms::no_integer_candidates(), n).encode(env)
        }
        sidereon_core::ils::IlsError::TooManyCandidates { evaluated, limit } => {
            (atoms::too_many_integer_candidates(), evaluated, limit).encode(env)
        }
        sidereon_core::ils::IlsError::InvalidDimensions { n, rows } => {
            (atoms::invalid_dimensions(), n, rows).encode(env)
        }
        sidereon_core::ils::IlsError::NonFinite => atoms::non_finite_input().encode(env),
        sidereon_core::ils::IlsError::SearchLimitExceeded => {
            atoms::search_limit_exceeded().encode(env)
        }
        sidereon_core::ils::IlsError::InvalidInput { .. } => atoms::invalid_input().encode(env),
    }
}

fn decode_state(term: StateTerm) -> FilterState {
    let (
        (version, references, sd_ambiguity_ids, ambiguity_prior_sigma_m, epoch_count),
        baseline_m,
        sd_ambiguities_m,
        information,
        fixed_cycles,
        fixed_m,
    ) = term;

    FilterState {
        version,
        references: references.into_iter().collect(),
        sd_ambiguity_ids,
        baseline_m: vec3(baseline_m),
        sd_ambiguities_m,
        information,
        ambiguity_prior_sigma_m,
        epoch_count,
        fixed_cycles: fixed_cycles.into_iter().collect(),
        fixed_m: fixed_m.into_iter().collect(),
    }
}

fn encode_state(state: FilterState) -> StateTerm {
    (
        (
            state.version,
            state.references.into_iter().collect(),
            state.sd_ambiguity_ids,
            state.ambiguity_prior_sigma_m,
            state.epoch_count,
        ),
        tuple3(state.baseline_m),
        state.sd_ambiguities_m,
        state.information,
        state.fixed_cycles.into_iter().collect(),
        state.fixed_m.into_iter().collect(),
    )
}

fn decode_epoch(term: EpochTerm) -> Epoch {
    let (references, nonref, velocity_mps, dt_s) = term;
    Epoch {
        references: references.into_iter().map(decode_sat).collect(),
        nonref: nonref.into_iter().map(decode_sat).collect(),
        velocity_mps: velocity_mps.map(vec3),
        dt_s,
    }
}

fn decode_sat(term: SatTerm) -> SatMeas {
    let (
        (sat, sd_ambiguity_id),
        (base_code_m, base_phase_m, rover_code_m, rover_phase_m),
        (base_tx_pos, rover_tx_pos, pos),
    ) = term;

    SatMeas {
        sat,
        sd_ambiguity_id,
        base_code_m,
        base_phase_m,
        rover_code_m,
        rover_phase_m,
        base_tx_pos: vec3(base_tx_pos),
        rover_tx_pos: vec3(rover_tx_pos),
        pos: vec3(pos),
    }
}

fn decode_model(term: ModelTerm) -> Option<MeasModel> {
    let (code_sigma_m, phase_sigma_m, stochastic, elevation_weighting, sagnac) = term;
    let stochastic = match stochastic.as_str() {
        "simple" => StochasticModel::Simple {
            elevation_weighting,
        },
        "rtklib" => StochasticModel::Rtklib,
        _ => return None,
    };

    Some(MeasModel {
        code_sigma_m,
        phase_sigma_m,
        sagnac,
        stochastic,
    })
}

fn decode_opts(term: UpdateOptsTerm) -> Option<UpdateOpts> {
    let (
        hold_sigma_m,
        position_tol_m,
        ambiguity_tol_m,
        max_iterations,
        process_noise_baseline_sigma_m,
        ratio_threshold,
        (
            dynamics_model,
            float_only_systems,
            innovation_screen_sigma,
            innovation_screen_min_rows,
            ar_arming_sigma_m,
            report_residuals,
        ),
    ) = term;
    let dynamics_model = match dynamics_model.as_str() {
        "constant_position" => DynamicsModel::ConstantPosition,
        "velocity_propagated" => DynamicsModel::VelocityPropagated,
        _ => return None,
    };

    Some(UpdateOpts {
        hold_sigma_m,
        position_tol_m,
        ambiguity_tol_m,
        max_iterations,
        process_noise_baseline_sigma_m,
        dynamics_model,
        float_only_systems,
        innovation_screen: if innovation_screen_sigma > 0.0 {
            Some(InnovationScreenOpts {
                threshold_sigma: innovation_screen_sigma,
                min_rows: innovation_screen_min_rows,
            })
        } else {
            None
        },
        report_residuals,
        receiver_antenna_corrections: None,
        ar_arming_sigma_m,
        search: SearchOpts { ratio_threshold },
    })
}

fn decode_receiver_antenna_corrections(
    term: ReceiverAntennaCorrectionsTerm,
) -> ReceiverAntennaCorrections {
    let (base, rover) = term;
    ReceiverAntennaCorrections {
        base: decode_receiver_antenna_calibration(base),
        rover: decode_receiver_antenna_calibration(rover),
    }
}

fn decode_receiver_antenna_calibration(
    term: ReceiverAntennaCorrectionTerm,
) -> ReceiverAntennaCalibration {
    let (pco_neu_m, mut noazi_pcv_m, azi_pcv_m) = term;
    // A PCO-only calibration carries no PCV samples. The core's PCV lookup
    // treats a calibration with no usable samples as MissingPcv rather than a
    // zero contribution, so a PCO-only antenna would be rejected. Supply a
    // single zero noazi sample, which interpolates to 0.0 at every zenith and
    // leaves the PCO projection as the only correction (the prior behavior).
    if noazi_pcv_m.is_empty() && azi_pcv_m.is_empty() {
        noazi_pcv_m.push((0.0, 0.0));
    }
    ReceiverAntennaCalibration {
        pco_neu_m: vec3(pco_neu_m),
        noazi_pcv_m,
        azi_pcv_m,
    }
}

fn vec3(v: Vec3) -> [f64; 3] {
    [v.0, v.1, v.2]
}

fn tuple3(v: [f64; 3]) -> Vec3 {
    (v[0], v[1], v[2])
}
