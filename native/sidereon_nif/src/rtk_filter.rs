//! Rustler boundary for the sequential RTK filter kernel.
//!
//! This is intentionally a traceable primitive, not the public RTK API: Elixir
//! still owns normalization/reporting while the kernel migration is gated. Terms
//! are plain tuples/lists so parity tests can feed the exact epoch/state stream
//! into Rust without introducing a second Elixir struct layer.

use rustler::types::tuple::make_tuple;
use rustler::{Encoder, Env, NifResult, Term};
use sidereon_core::carrier_phase::{SlipReason, FREQ_EPSILON_HZ};
use sidereon_core::combinations::IonosphereFreeError;
use sidereon_core::rtk::{
    apply_elevation_mask, baseline_reference_satellites, hatch_smooth_baseline_code_epochs,
    prepare_cycle_slip_baseline_epochs, BaselineReferenceEpoch, BaselineReferenceSelection,
    CodeSmoothingEpoch, CodeSmoothingObservation, CycleSlipPrepError, CycleSlipReceiver,
    DoubleDifferenceError, ElevationMaskEpoch,
};
use sidereon_core::rtk_filter::{
    fix_wide_lane_rtk_arc, prepare_ionosphere_free_rtk_arc, solve_moving_baseline,
    solve_float_baseline, solve_fixed_baseline_validated, solve_rtk_arc, solve_static_rtk_arc,
    update_epoch,
    AmbiguityScale, AmbiguitySet, CycleSlipOptions, CycleSlipPolicy,
    CycleSlipSplitArc, DynamicsModel, Epoch, IonosphereFreeBaselineError, MovingBaselineEpoch,
    MovingBaselineEpochSolution, MovingBaselineError,
    MovingBaselineOpts, MovingBaselineStatus, FilterState, FixedBaselineSolution, FixedSolveError,
    FixedSolveOpts, FloatBaselineSolution, FloatResidual, FloatSolveError,
    FloatSolveOpts, FloatSolveStatus, FullSetIntegerSummary, InnovationScreen, InnovationScreenOpts,
    IntegerSearchMeta, IntegerStatus, MeasModel, ReceiverAntennaCalibration,
    ReceiverAntennaCorrections, ResidualComponentKind, ResidualValidationMeta,
    ResidualValidationOpts, ResidualValidationOutlier, RtkArcConfig, RtkArcEpoch,
    RtkArcEpochSolution, RtkArcError, RtkArcObservation, RtkArcPreprocessing, RtkArcSolution,
    RtkDualCycleSlipConfig, RtkDualFrequencyArcEpoch, RtkDualFrequencyObservation,
    RtkDualFrequencySatelliteObservation, RtkIonosphereFreeArcConfig, RtkIonosphereFreeArcError,
    RtkIonosphereFreeArcSolution, RtkStaticArcConfig, RtkStaticArcError, RtkStaticArcSolution,
    RtkWideLaneArcConfig, RtkWideLaneArcError, RtkWideLaneArcSolution, SatMeas, SearchOpts,
    StochasticModel, UpdateError, UpdateOpts, ValidatedFixedBaselineSolution,
    ValidatedFixedSolveError, ValidatedFixedSolveOpts, WideLaneError,
};
use std::collections::{BTreeMap, BTreeSet};

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
// Moving-baseline ambiguity set: ids, id->satellite map, wavelengths, offsets,
// and the constellations held float-only this epoch.
type MbAmbiguityTerm = (
    Vec<String>,
    Vec<(String, String)>,
    Vec<(String, f64)>,
    Vec<(String, f64)>,
    Vec<String>,
);
// One moving-baseline epoch: the base receiver's ECEF position, the DD epoch, and
// the ambiguity set to resolve against it.
type MbEpochTerm = (Vec3, EpochTerm, MbAmbiguityTerm);
// Float solver controls without an initial baseline (carried by the opts).
type MbFloatOptsTerm = (f64, f64, usize);
// Fixed solver controls: position_tol, ambiguity_tol, max_iter, ratio_threshold,
// partial_ambiguity_resolution, partial_min_ambiguities.
type MbFixedOptsTerm = (f64, f64, usize, f64, bool, usize);
// Sequence opts: model, float, fixed, initial baseline, warm-start.
type MbOptsTerm = (ModelTerm, MbFloatOptsTerm, MbFixedOptsTerm, Vec3, bool);
type ArcObservationOutputTerm = (String, String, f64, f64, Option<i64>);
type PreprocessedArcEpochTerm = (
    Vec<ArcObservationOutputTerm>,
    Vec<ArcObservationOutputTerm>,
    Vec<(String, Vec3)>,
    Vec<(String, Vec3)>,
    Vec<(String, Vec3)>,
    Option<Vec3>,
    Option<f64>,
);
type ArcScaleTerm = (String, f64, Vec<(String, f64)>);

/// Owned per-epoch storage so the borrowing `MovingBaselineEpoch`/`AmbiguitySet`
/// references outlive the solve call.
struct MbOwnedEpoch {
    base: [f64; 3],
    epoch: Epoch,
    ids: Vec<String>,
    satellites: BTreeMap<String, String>,
    wavelengths: BTreeMap<String, f64>,
    offsets: BTreeMap<String, f64>,
    float_only_systems: Vec<String>,
}

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
        receiver_antenna,
        empty_epochs,
        too_few_satellites,
        reference_selection_failed,
        no_common_reference_satellite,
        reference_satellite_missing,
        reference_satellite_single_system,
        reference_satellite_missing_system,
        missing_satellite_position,
        duplicate_observation,
        too_few_common_satellites,
        reference_satellite_id,
        invalid_option,
        cycle_slip_detected,
        update_failed,
        invalid_epoch_time,
        missing_position,
        cycle_slip_prep_failed,
        code_smoothing_failed,
        elevation_mask_failed,
        ambiguity_wavelength_m,
        ambiguity_offset_m,
        invalid_ambiguity_wavelength,
        invalid_ambiguity_offset,
        no_epochs,
        wide_lane_failed,
        equal_frequencies,
        invalid_frequency,
        unknown_system,
        unknown_band,
        too_few_wide_lane_epochs,
        wide_lane_not_integer,
        inconsistent_frequencies,
        ionosphere_free_failed,
        invalid_observation
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn rtk_solve_float<'a>(
    env: Env<'a>,
    epoch_terms: Vec<EpochTerm>,
    base: Vec3,
    ambiguity_ids: Vec<String>,
    initial_baseline_m: Vec3,
    model_term: ModelTerm,
    float_opts_term: FloatSolveOptsTerm,
    receiver_antenna_corrections_term: Option<ReceiverAntennaCorrectionsTerm>,
) -> NifResult<Term<'a>> {
    let Some(model) = decode_model(model_term) else {
        return Ok((atoms::error(), atoms::invalid_stochastic_model()).encode(env));
    };
    let epochs: Vec<Epoch> = epoch_terms.into_iter().map(decode_epoch).collect();
    let receiver_antenna_corrections =
        receiver_antenna_corrections_term.map(decode_receiver_antenna_corrections);

    Ok(match solve_float_baseline(
        &epochs,
        vec3(base),
        &ambiguity_ids,
        vec3(initial_baseline_m),
        &model,
        decode_float_solve_opts(float_opts_term),
        receiver_antenna_corrections.as_ref(),
    ) {
        Ok(solution) => (atoms::ok(), encode_float_solution(env, solution)).encode(env),
        Err(error) => (atoms::error(), encode_float_error(env, error)).encode(env),
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
pub fn rtk_solve_fixed<'a>(
    env: Env<'a>,
    epoch_terms: Vec<EpochTerm>,
    base: Vec3,
    ambiguity_ids: Vec<String>,
    ambiguity_satellites: Vec<(String, String)>,
    wavelengths_m: Vec<(String, f64)>,
    offsets_m: Vec<(String, f64)>,
    float_only_systems: Vec<String>,
    initial_baseline_m: Vec3,
    model_term: ModelTerm,
    float_opts_term: FloatSolveOptsTerm,
    fixed_opts_term: FixedSolveOptsTerm,
    residual_opts_term: ResidualValidationOptsTerm,
    receiver_antenna_corrections_term: Option<ReceiverAntennaCorrectionsTerm>,
) -> NifResult<Term<'a>> {
    let Some(model) = decode_model(model_term) else {
        return Ok((atoms::error(), atoms::invalid_stochastic_model()).encode(env));
    };
    let epochs: Vec<Epoch> = epoch_terms.into_iter().map(decode_epoch).collect();
    let ambiguity_satellites = ambiguity_satellites.into_iter().collect::<BTreeMap<_, _>>();
    let wavelengths_m = wavelengths_m.into_iter().collect::<BTreeMap<_, _>>();
    let offsets_m = offsets_m.into_iter().collect::<BTreeMap<_, _>>();
    let (fixed, _ignored_float_only) = decode_static_fixed_solve_opts(fixed_opts_term);
    let ambiguities = AmbiguitySet {
        ids: &ambiguity_ids,
        satellites: &ambiguity_satellites,
        scale: AmbiguityScale {
            wavelengths_m: &wavelengths_m,
            offsets_m: &offsets_m,
        },
        float_only_systems: &float_only_systems,
    };
    let receiver_antenna_corrections =
        receiver_antenna_corrections_term.map(decode_receiver_antenna_corrections);
    let opts = ValidatedFixedSolveOpts {
        float: decode_float_solve_opts(float_opts_term),
        fixed,
        residual: decode_residual_validation_opts(residual_opts_term),
    };

    Ok(match solve_fixed_baseline_validated(
        &epochs,
        vec3(base),
        ambiguities,
        vec3(initial_baseline_m),
        &model,
        opts,
        receiver_antenna_corrections.as_ref(),
    ) {
        Ok(solution) => (atoms::ok(), encode_validated_fixed_solution(env, solution)).encode(env),
        Err(error) => (atoms::error(), encode_validated_fixed_error(env, error)).encode(env),
    })
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

#[rustler::nif(schedule = "DirtyCpu")]
pub fn rtk_solve_moving_baseline<'a>(
    env: Env<'a>,
    epoch_terms: Vec<MbEpochTerm>,
    opts_term: MbOptsTerm,
    receiver_antenna_corrections_term: Option<ReceiverAntennaCorrectionsTerm>,
) -> NifResult<Term<'a>> {
    let (model_term, float_opts_term, fixed_opts_term, initial_baseline_m, warm_start) = opts_term;
    let Some(model) = decode_model(model_term) else {
        return Ok((atoms::error(), atoms::invalid_stochastic_model()).encode(env));
    };
    let opts = MovingBaselineOpts {
        model,
        float: decode_mb_float_opts(float_opts_term),
        fixed: decode_mb_fixed_opts(fixed_opts_term),
        initial_baseline_m: vec3(initial_baseline_m),
        warm_start,
    };
    let receiver_antenna_corrections =
        receiver_antenna_corrections_term.map(decode_receiver_antenna_corrections);

    // Materialize owned per-epoch storage first, then build the borrowing inputs.
    let owned: Vec<MbOwnedEpoch> = epoch_terms.into_iter().map(decode_mb_owned_epoch).collect();
    let inputs: Vec<MovingBaselineEpoch> = owned.iter().map(mb_epoch_ref).collect();

    match solve_moving_baseline(&inputs, opts, receiver_antenna_corrections.as_ref()) {
        Ok(solutions) => {
            let encoded: Vec<Term<'a>> = solutions
                .into_iter()
                .map(|solution| encode_moving_baseline_solution(env, solution))
                .collect();
            Ok((atoms::ok(), encoded).encode(env))
        }
        Err(err) => Ok((
            atoms::error(),
            err.epoch_index as u64,
            encode_moving_baseline_error(env, err.error),
        )
            .encode(env)),
    }
}

fn decode_mb_float_opts(term: MbFloatOptsTerm) -> FloatSolveOpts {
    let (position_tol_m, ambiguity_tol_m, max_iterations) = term;
    FloatSolveOpts {
        position_tol_m,
        ambiguity_tol_m,
        max_iterations,
    }
}

fn decode_mb_fixed_opts(term: MbFixedOptsTerm) -> FixedSolveOpts {
    let (
        position_tol_m,
        ambiguity_tol_m,
        max_iterations,
        ratio_threshold,
        partial_ambiguity_resolution,
        partial_min_ambiguities,
    ) = term;
    FixedSolveOpts {
        position_tol_m,
        ambiguity_tol_m,
        max_iterations,
        ratio_threshold,
        partial_ambiguity_resolution,
        partial_min_ambiguities,
    }
}

fn decode_mb_owned_epoch(term: MbEpochTerm) -> MbOwnedEpoch {
    let (base, epoch_term, (ids, satellites, wavelengths, offsets, float_only_systems)) = term;
    MbOwnedEpoch {
        base: vec3(base),
        epoch: decode_epoch(epoch_term),
        ids,
        satellites: satellites.into_iter().collect(),
        wavelengths: wavelengths.into_iter().collect(),
        offsets: offsets.into_iter().collect(),
        float_only_systems,
    }
}

fn mb_epoch_ref(owned: &MbOwnedEpoch) -> MovingBaselineEpoch<'_> {
    MovingBaselineEpoch {
        base_position_m: owned.base,
        epoch: &owned.epoch,
        ambiguities: AmbiguitySet {
            ids: &owned.ids,
            satellites: &owned.satellites,
            scale: AmbiguityScale {
                wavelengths_m: &owned.wavelengths,
                offsets_m: &owned.offsets,
            },
            float_only_systems: &owned.float_only_systems,
        },
    }
}

fn encode_moving_baseline_solution<'a>(
    env: Env<'a>,
    solution: MovingBaselineEpochSolution,
) -> Term<'a> {
    let status = match solution.status {
        MovingBaselineStatus::Fixed => "fixed",
        MovingBaselineStatus::Float => "float",
    };
    make_tuple(
        env,
        &[
            tuple3(solution.base_position_m).encode(env),
            tuple3(solution.baseline_m).encode(env),
            solution.baseline_length_m.encode(env),
            status.encode(env),
            encode_float_solution(env, solution.float),
            encode_fixed_solution(env, solution.fixed),
        ],
    )
}

fn encode_moving_baseline_error<'a>(env: Env<'a>, err: MovingBaselineError) -> Term<'a> {
    match err {
        MovingBaselineError::Float(err) => encode_float_error(env, err),
        MovingBaselineError::Fixed(err) => encode_fixed_error(env, err),
    }
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

// --- sequential RTK arc driver -------------------------------------------

#[derive(Debug, Clone, rustler::NifMap)]
struct RtkArcObservationTerm {
    satellite_id: String,
    ambiguity_id: String,
    code_m: f64,
    phase_m: f64,
    lli: Option<i64>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct RtkArcPreprocessingTerm {
    cycle_slip: Option<String>,
    hatch_window_cap: Option<usize>,
    elevation_mask_deg: Option<f64>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct RtkArcEpochTerm {
    base: Vec<RtkArcObservationTerm>,
    rover: Vec<RtkArcObservationTerm>,
    satellite_positions_m: Vec<(String, Vec3)>,
    base_satellite_positions_m: Vec<(String, Vec3)>,
    rover_satellite_positions_m: Vec<(String, Vec3)>,
    velocity_mps: Option<Vec3>,
    prediction_time_s: Option<f64>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct RtkArcReferenceTerm {
    mode: String,
    satellite: Option<String>,
    per_system: Vec<(String, String)>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct RtkArcConfigTerm {
    base_m: Vec3,
    reference: RtkArcReferenceTerm,
    model: ModelTerm,
    baseline_prior_sigma_m: f64,
    ambiguity_prior_sigma_m: f64,
    initial_baseline_m: Vec3,
    wavelengths_m: Vec<(String, f64)>,
    offsets_m: Vec<(String, f64)>,
    update_opts: UpdateOptsTerm,
    preprocessing: RtkArcPreprocessingTerm,
    receiver_antenna_corrections: Option<ReceiverAntennaCorrectionsTerm>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct RtkStaticArcConfigTerm {
    base_m: Vec3,
    reference: RtkArcReferenceTerm,
    model: ModelTerm,
    initial_baseline_m: Vec3,
    wavelengths_m: ArcScaleTerm,
    offsets_m: ArcScaleTerm,
    float_opts: FloatSolveOptsTerm,
    fixed_opts: FixedSolveOptsTerm,
    residual_opts: ResidualValidationOptsTerm,
    preprocessing: RtkArcPreprocessingTerm,
    receiver_antenna_corrections: Option<ReceiverAntennaCorrectionsTerm>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct RtkDualFrequencyObservationTerm {
    ambiguity_id: String,
    p1_m: f64,
    p2_m: f64,
    phi1_cycles: f64,
    phi2_cycles: f64,
    f1_hz: f64,
    f2_hz: f64,
    lli1: Option<i64>,
    lli2: Option<i64>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct RtkDualFrequencySatelliteObservationTerm {
    satellite_id: String,
    base: RtkDualFrequencyObservationTerm,
    rover: RtkDualFrequencyObservationTerm,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct RtkDualFrequencyArcEpochTerm {
    jd_whole: f64,
    jd_fraction: f64,
    epoch_sort_key: Option<String>,
    gap_time_s: Option<f64>,
    observations: Vec<RtkDualFrequencySatelliteObservationTerm>,
    satellite_positions_m: Vec<(String, Vec3)>,
    base_satellite_positions_m: Vec<(String, Vec3)>,
    rover_satellite_positions_m: Vec<(String, Vec3)>,
    velocity_mps: Option<Vec3>,
    prediction_time_s: Option<f64>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct RtkDualCycleSlipConfigTerm {
    policy: String,
    gf_threshold_m: f64,
    mw_threshold_cycles: f64,
    min_arc_gap_s: f64,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct RtkWideLaneArcConfigTerm {
    base_m: Vec3,
    reference: RtkArcReferenceTerm,
    min_epochs: u64,
    tolerance_cycles: f64,
    skip_short_fragments: bool,
    cycle_slip: Option<RtkDualCycleSlipConfigTerm>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct RtkIonosphereFreeArcConfigTerm {
    base_m: Vec3,
    initial_baseline_m: Vec3,
    reference: RtkArcReferenceTerm,
    apply_troposphere: bool,
}

/// Solve a sequential RTK baseline arc from raw rover+base epochs.
///
/// Pure glue over `sidereon_core::rtk_filter::solve_rtk_arc`: decode the raw
/// epochs and the arc config (reusing the shared measurement-model and
/// update-option decoders), call the kernel driver, and re-shape the per-epoch
/// solutions plus the carried final filter state. No normalization, reference
/// selection, or filter numerics live here.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn rtk_solve_arc<'a>(
    env: Env<'a>,
    epochs: Vec<RtkArcEpochTerm>,
    config: RtkArcConfigTerm,
) -> NifResult<Term<'a>> {
    let epochs: Vec<RtkArcEpoch> = epochs.into_iter().map(decode_arc_epoch).collect();
    let config = decode_arc_config(config)?;
    Ok(match solve_rtk_arc(&epochs, &config) {
        Ok(solution) => (atoms::ok(), encode_arc_solution(env, solution)).encode(env),
        Err(error) => (atoms::error(), encode_arc_error(env, error)).encode(env),
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn rtk_solve_static_arc<'a>(
    env: Env<'a>,
    epochs: Vec<RtkArcEpochTerm>,
    config: RtkStaticArcConfigTerm,
) -> NifResult<Term<'a>> {
    let epochs: Vec<RtkArcEpoch> = epochs.into_iter().map(decode_arc_epoch).collect();
    let config = match decode_static_arc_config(&epochs, config) {
        Ok(config) => config,
        Err(error) => return Ok((atoms::error(), encode_static_config_error(env, error)).encode(env)),
    };

    Ok(match solve_static_rtk_arc(&epochs, &config) {
        Ok(solution) => (atoms::ok(), encode_static_arc_solution(env, solution)).encode(env),
        Err(error) => (atoms::error(), encode_static_arc_error(env, error)).encode(env),
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn rtk_fix_wide_lane_arc<'a>(
    env: Env<'a>,
    epochs: Vec<RtkDualFrequencyArcEpochTerm>,
    config: RtkWideLaneArcConfigTerm,
) -> NifResult<Term<'a>> {
    let epochs: Vec<RtkDualFrequencyArcEpoch> =
        epochs.into_iter().map(decode_dual_frequency_arc_epoch).collect();
    let config = match decode_wide_lane_arc_config(config) {
        Some(config) => config,
        None => return Ok((atoms::error(), atoms::invalid_option()).encode(env)),
    };

    Ok(match fix_wide_lane_rtk_arc(&epochs, &config) {
        Ok(solution) => (atoms::ok(), encode_wide_lane_arc_solution(env, solution)).encode(env),
        Err(error) => (atoms::error(), encode_wide_lane_arc_error(env, error, &epochs)).encode(env),
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn rtk_prepare_ionosphere_free_arc<'a>(
    env: Env<'a>,
    epochs: Vec<RtkDualFrequencyArcEpochTerm>,
    wide_lane_cycles: Vec<(String, i64)>,
    config: RtkIonosphereFreeArcConfigTerm,
) -> NifResult<Term<'a>> {
    let epochs: Vec<RtkDualFrequencyArcEpoch> =
        epochs.into_iter().map(decode_dual_frequency_arc_epoch).collect();
    let config = match decode_ionosphere_free_arc_config(config) {
        Some(config) => config,
        None => return Ok((atoms::error(), atoms::invalid_option()).encode(env)),
    };
    let wide_lane_cycles = wide_lane_cycles.into_iter().collect::<BTreeMap<_, _>>();

    Ok(
        match prepare_ionosphere_free_rtk_arc(&epochs, &wide_lane_cycles, &config) {
            Ok(solution) => (atoms::ok(), encode_ionosphere_free_arc_solution(solution)).encode(env),
            Err(error) => (atoms::error(), encode_ionosphere_free_arc_error(env, error)).encode(env),
        },
    )
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn rtk_preprocess_arc_epochs<'a>(
    env: Env<'a>,
    epochs: Vec<RtkArcEpochTerm>,
    base_m: Vec3,
    preprocessing: RtkArcPreprocessingTerm,
) -> NifResult<Term<'a>> {
    let epochs: Vec<RtkArcEpoch> = epochs.into_iter().map(decode_arc_epoch).collect();
    let Some(preprocessing) = decode_arc_preprocessing(preprocessing) else {
        return Ok((atoms::error(), atoms::invalid_option()).encode(env));
    };

    Ok(
        match preprocess_arc_epochs_for_binding(&epochs, vec3(base_m), &preprocessing) {
            Ok((prepared, dropped_sats, split_cycle_slip_arcs, elevation_masked_sats)) => (
                atoms::ok(),
                (
                    encode_preprocessed_arc_epochs(prepared),
                    dropped_sats,
                    encode_arc_split_cycle_slip_arcs(split_cycle_slip_arcs),
                    elevation_masked_sats,
                ),
            )
                .encode(env),
            Err(error) => (atoms::error(), encode_arc_error(env, error)).encode(env),
        },
    )
}

enum StaticConfigError {
    InvalidStochasticModel,
    InvalidReference,
    InvalidPreprocessing,
    InvalidScaleOption(&'static str),
    InvalidAmbiguityWavelength(String),
    InvalidAmbiguityOffset(String),
    Arc(RtkArcError),
}

impl From<RtkArcError> for StaticConfigError {
    fn from(error: RtkArcError) -> Self {
        Self::Arc(error)
    }
}

struct StaticNormalizedEpoch<'a> {
    paired: BTreeMap<&'a str, (&'a RtkArcObservation, &'a RtkArcObservation)>,
    shared_positions: &'a BTreeMap<String, [f64; 3]>,
    available: Vec<String>,
}

fn decode_static_arc_config(
    epochs: &[RtkArcEpoch],
    term: RtkStaticArcConfigTerm,
) -> Result<RtkStaticArcConfig, StaticConfigError> {
    let model = decode_model(term.model).ok_or(StaticConfigError::InvalidStochasticModel)?;
    let reference = decode_arc_reference(term.reference).ok_or(StaticConfigError::InvalidReference)?;
    let preprocessing =
        decode_arc_preprocessing(term.preprocessing).ok_or(StaticConfigError::InvalidPreprocessing)?;
    let float = decode_float_solve_opts(term.float_opts);
    let (fixed, float_only_systems) = decode_static_fixed_solve_opts(term.fixed_opts);
    let residual = decode_residual_validation_opts(term.residual_opts);
    let receiver_antenna_corrections = term
        .receiver_antenna_corrections
        .map(decode_receiver_antenna_corrections);
    let mut arc = RtkArcConfig {
        base_m: vec3(term.base_m),
        reference,
        model,
        baseline_prior_sigma_m: 1.0,
        ambiguity_prior_sigma_m: 1.0,
        initial_baseline_m: vec3(term.initial_baseline_m),
        wavelengths_m: BTreeMap::new(),
        offsets_m: BTreeMap::new(),
        update_opts: UpdateOpts {
            hold_sigma_m: 1.0e-4,
            position_tol_m: float.position_tol_m,
            ambiguity_tol_m: float.ambiguity_tol_m,
            max_iterations: float.max_iterations,
            process_noise_baseline_sigma_m: 0.0,
            dynamics_model: DynamicsModel::ConstantPosition,
            float_only_systems,
            innovation_screen: None,
            report_residuals: false,
            receiver_antenna_corrections,
            ar_arming_sigma_m: None,
            search: SearchOpts {
                ratio_threshold: fixed.ratio_threshold,
            },
        },
        preprocessing,
    };
    let ambiguity_satellites = static_ambiguity_satellites(epochs, &arc)?;
    arc.wavelengths_m = expand_static_scale(
        term.wavelengths_m,
        &ambiguity_satellites,
        StaticScaleKind::Wavelength,
    )?;
    arc.offsets_m = expand_static_scale(
        term.offsets_m,
        &ambiguity_satellites,
        StaticScaleKind::Offset,
    )?;

    Ok(RtkStaticArcConfig {
        arc,
        opts: ValidatedFixedSolveOpts {
            float,
            fixed,
            residual,
        },
    })
}

fn decode_float_solve_opts(term: FloatSolveOptsTerm) -> FloatSolveOpts {
    let (initial_baseline_m, position_tol_m, ambiguity_tol_m, max_iterations) = term;
    let _ = initial_baseline_m;
    FloatSolveOpts {
        position_tol_m,
        ambiguity_tol_m,
        max_iterations,
    }
}

fn decode_static_fixed_solve_opts(term: FixedSolveOptsTerm) -> (FixedSolveOpts, Vec<String>) {
    let (
        position_tol_m,
        ambiguity_tol_m,
        max_iterations,
        ratio_threshold,
        partial_ambiguity_resolution,
        partial_min_ambiguities,
        float_only_systems,
    ) = term;
    (
        FixedSolveOpts {
            position_tol_m,
            ambiguity_tol_m,
            max_iterations,
            ratio_threshold,
            partial_ambiguity_resolution,
            partial_min_ambiguities,
        },
        float_only_systems,
    )
}

fn decode_residual_validation_opts(term: ResidualValidationOptsTerm) -> ResidualValidationOpts {
    let (threshold_sigma, max_exclusions) = term;
    ResidualValidationOpts {
        threshold_sigma,
        max_exclusions,
    }
}

enum StaticScaleKind {
    Wavelength,
    Offset,
}

fn expand_static_scale(
    term: ArcScaleTerm,
    ambiguity_satellites: &[(String, String)],
    kind: StaticScaleKind,
) -> Result<BTreeMap<String, f64>, StaticConfigError> {
    let (mode, scalar, pairs) = term;
    match mode.as_str() {
        "scalar" => {
            if matches!(kind, StaticScaleKind::Wavelength) && scalar <= 0.0 {
                return Err(StaticConfigError::InvalidScaleOption("ambiguity_wavelength_m"));
            }
            Ok(ambiguity_satellites
                .iter()
                .map(|(id, _sat)| (id.clone(), scalar))
                .collect())
        }
        "map" => {
            let values = pairs.into_iter().collect::<BTreeMap<_, _>>();
            let mut out = BTreeMap::new();
            for (id, sat) in ambiguity_satellites {
                let Some(value) = values.get(id).or_else(|| values.get(sat)) else {
                    return Err(match kind {
                        StaticScaleKind::Wavelength => {
                            StaticConfigError::InvalidAmbiguityWavelength(id.clone())
                        }
                        StaticScaleKind::Offset => {
                            StaticConfigError::InvalidAmbiguityOffset(id.clone())
                        }
                    });
                };
                if matches!(kind, StaticScaleKind::Wavelength) && *value <= 0.0 {
                    return Err(StaticConfigError::InvalidAmbiguityWavelength(id.clone()));
                }
                out.insert(id.clone(), *value);
            }
            Ok(out)
        }
        "none" if matches!(kind, StaticScaleKind::Offset) => Ok(ambiguity_satellites
            .iter()
            .map(|(id, _sat)| (id.clone(), 0.0))
            .collect()),
        _ => Err(match kind {
            StaticScaleKind::Wavelength => {
                StaticConfigError::InvalidScaleOption("ambiguity_wavelength_m")
            }
            StaticScaleKind::Offset => StaticConfigError::InvalidScaleOption("ambiguity_offset_m"),
        }),
    }
}

fn static_ambiguity_satellites(
    epochs: &[RtkArcEpoch],
    config: &RtkArcConfig,
) -> Result<Vec<(String, String)>, RtkArcError> {
    if epochs.is_empty() {
        return Err(RtkArcError::EmptyEpochs);
    }

    let preprocessing_active = arc_preprocessing_active(&config.preprocessing);
    let (prepared_epochs, _, _, _) = if preprocessing_active {
        preprocess_arc_epochs_for_binding(epochs, config.base_m, &config.preprocessing)?
    } else {
        (Vec::new(), Vec::new(), Vec::new(), Vec::new())
    };
    let solve_input: &[RtkArcEpoch] = if preprocessing_active {
        &prepared_epochs
    } else {
        epochs
    };
    let normalized: Vec<StaticNormalizedEpoch> =
        solve_input.iter().map(static_normalize_epoch).collect();
    let arc_sats = static_arc_satellites(&normalized);
    if arc_sats.len() < 4 {
        return Err(RtkArcError::TooFewSatellites {
            count: arc_sats.len(),
            minimum: 4,
        });
    }
    let reference_epochs = normalized
        .iter()
        .map(|epoch| BaselineReferenceEpoch {
            available_satellite_ids: epoch.available.clone(),
            satellite_positions_m: epoch.shared_positions.clone(),
        })
        .collect::<Vec<_>>();
    let refs = baseline_reference_satellites(
        config.base_m,
        &reference_epochs,
        config.reference.clone(),
    )
    .map_err(RtkArcError::Reference)?;
    let reference_sats = refs.values().map(String::as_str).collect::<BTreeSet<_>>();
    let mut ambiguity_satellites = BTreeMap::<(String, String), ()>::new();

    for epoch in &normalized {
        let reference_sds = static_reference_sds(epoch, &refs);
        for sat in &epoch.available {
            if reference_sats.contains(sat.as_str()) {
                continue;
            }
            let system = satellite_system_token(sat);
            let Some((reference_sat, reference_sd)) = reference_sds.get(system) else {
                continue;
            };
            let (base, rover) = epoch.paired[sat.as_str()];
            let sd_id = static_single_difference_ambiguity_id(sat, base, rover);
            let dd_id =
                static_double_difference_ambiguity_id(sat, &sd_id, reference_sat, reference_sd);
            ambiguity_satellites.insert((sat.clone(), dd_id), ());
        }
    }

    Ok(ambiguity_satellites
        .into_keys()
        .map(|(sat, id)| (id, sat))
        .collect())
}

fn static_normalize_epoch(epoch: &RtkArcEpoch) -> StaticNormalizedEpoch<'_> {
    let base_positions = if epoch.base_satellite_positions_m.is_empty() {
        &epoch.satellite_positions_m
    } else {
        &epoch.base_satellite_positions_m
    };
    let rover_positions = if epoch.rover_satellite_positions_m.is_empty() {
        &epoch.satellite_positions_m
    } else {
        &epoch.rover_satellite_positions_m
    };
    let base_by_sat: BTreeMap<&str, &RtkArcObservation> = epoch
        .base
        .iter()
        .map(|obs| (obs.satellite_id.as_str(), obs))
        .collect();
    let rover_by_sat: BTreeMap<&str, &RtkArcObservation> = epoch
        .rover
        .iter()
        .map(|obs| (obs.satellite_id.as_str(), obs))
        .collect();
    let mut paired = BTreeMap::new();
    let mut available = Vec::new();
    for (sat, base_obs) in &base_by_sat {
        let Some(rover_obs) = rover_by_sat.get(sat) else {
            continue;
        };
        if epoch.satellite_positions_m.contains_key(*sat)
            && base_positions.contains_key(*sat)
            && rover_positions.contains_key(*sat)
        {
            paired.insert(*sat, (*base_obs, *rover_obs));
            available.push((*sat).to_string());
        }
    }
    available.sort();

    StaticNormalizedEpoch {
        paired,
        shared_positions: &epoch.satellite_positions_m,
        available,
    }
}

fn static_arc_satellites(epochs: &[StaticNormalizedEpoch<'_>]) -> Vec<String> {
    let mut sats = BTreeSet::new();
    for epoch in epochs {
        for sat in &epoch.available {
            sats.insert(sat.clone());
        }
    }
    sats.into_iter().collect()
}

fn static_reference_sds(
    epoch: &StaticNormalizedEpoch<'_>,
    refs: &BTreeMap<String, String>,
) -> BTreeMap<String, (String, String)> {
    refs.iter()
        .filter_map(|(system, reference_sat)| {
            epoch
                .paired
                .get(reference_sat.as_str())
                .map(|(base, rover)| {
                    (
                        system.clone(),
                        (
                            reference_sat.clone(),
                            static_single_difference_ambiguity_id(reference_sat, base, rover),
                        ),
                    )
                })
        })
        .collect()
}

fn static_single_difference_ambiguity_id(
    sat: &str,
    base: &RtkArcObservation,
    rover: &RtkArcObservation,
) -> String {
    match (base.ambiguity_id.as_str(), rover.ambiguity_id.as_str()) {
        (base_id, rover_id) if base_id == sat && rover_id == sat => sat.to_string(),
        (base_id, rover_id) if base_id == sat => rover_id.to_string(),
        (base_id, rover_id) if rover_id == sat => base_id.to_string(),
        (base_id, rover_id) if base_id == rover_id => base_id.to_string(),
        (base_id, rover_id) => format!("{sat}:base={base_id},rover={rover_id}"),
    }
}

fn static_double_difference_ambiguity_id(
    sat: &str,
    sat_sd_id: &str,
    reference_sat: &str,
    reference_sd_id: &str,
) -> String {
    if sat_sd_id == sat && reference_sd_id == reference_sat {
        sat.to_string()
    } else {
        format!("{sat_sd_id}|ref={reference_sd_id}")
    }
}

fn satellite_system_token(satellite_id: &str) -> &str {
    satellite_id.get(0..1).unwrap_or("")
}

fn arc_preprocessing_active(preprocessing: &RtkArcPreprocessing) -> bool {
    preprocessing.cycle_slip.is_some()
        || preprocessing.hatch_window_cap.is_some()
        || preprocessing.elevation_mask_deg.is_some()
}

fn encode_static_config_error<'a>(env: Env<'a>, error: StaticConfigError) -> Term<'a> {
    match error {
        StaticConfigError::InvalidStochasticModel => atoms::invalid_stochastic_model().encode(env),
        StaticConfigError::InvalidReference => {
            (atoms::invalid_option(), atoms::reference_satellite_id()).encode(env)
        }
        StaticConfigError::InvalidPreprocessing => atoms::invalid_option().encode(env),
        StaticConfigError::InvalidScaleOption("ambiguity_wavelength_m") => {
            (atoms::invalid_option(), atoms::ambiguity_wavelength_m()).encode(env)
        }
        StaticConfigError::InvalidScaleOption("ambiguity_offset_m") => {
            (atoms::invalid_option(), atoms::ambiguity_offset_m()).encode(env)
        }
        StaticConfigError::InvalidScaleOption(_) => atoms::invalid_option().encode(env),
        StaticConfigError::InvalidAmbiguityWavelength(id) => {
            (atoms::invalid_ambiguity_wavelength(), id).encode(env)
        }
        StaticConfigError::InvalidAmbiguityOffset(id) => {
            (atoms::invalid_ambiguity_offset(), id).encode(env)
        }
        StaticConfigError::Arc(error) => encode_arc_error(env, error),
    }
}

fn encode_static_arc_solution<'a>(env: Env<'a>, solution: RtkStaticArcSolution) -> Term<'a> {
    make_tuple(
        env,
        &[
            solution.references.into_iter().collect::<Vec<_>>().encode(env),
            solution.ambiguity_ids.encode(env),
            solution
                .ambiguity_satellites
                .into_iter()
                .collect::<Vec<_>>()
                .encode(env),
            encode_float_solution(env, solution.float_solution),
            encode_validated_fixed_solution(env, solution.fixed_solution),
            solution.dropped_sats.encode(env),
            encode_arc_split_cycle_slip_arcs(solution.split_cycle_slip_arcs).encode(env),
            solution.elevation_masked_sats.encode(env),
        ],
    )
}

fn encode_static_arc_error<'a>(env: Env<'a>, error: RtkStaticArcError) -> Term<'a> {
    match error {
        RtkStaticArcError::Arc(error) => encode_arc_error(env, error),
        RtkStaticArcError::Float(error) => encode_float_error(env, error),
        RtkStaticArcError::Fixed(error) => encode_validated_fixed_error(env, error),
    }
}

fn decode_dual_frequency_arc_epoch(
    term: RtkDualFrequencyArcEpochTerm,
) -> RtkDualFrequencyArcEpoch {
    RtkDualFrequencyArcEpoch {
        jd_whole: term.jd_whole,
        jd_fraction: term.jd_fraction,
        epoch_sort_key: term.epoch_sort_key,
        gap_time_s: term.gap_time_s,
        observations: term
            .observations
            .into_iter()
            .map(decode_dual_frequency_satellite_observation)
            .collect(),
        satellite_positions_m: decode_position_map(term.satellite_positions_m),
        base_satellite_positions_m: decode_position_map(term.base_satellite_positions_m),
        rover_satellite_positions_m: decode_position_map(term.rover_satellite_positions_m),
        velocity_mps: term.velocity_mps.map(vec3),
        prediction_time_s: term.prediction_time_s,
    }
}

fn decode_dual_frequency_satellite_observation(
    term: RtkDualFrequencySatelliteObservationTerm,
) -> RtkDualFrequencySatelliteObservation {
    RtkDualFrequencySatelliteObservation {
        satellite_id: term.satellite_id,
        base: decode_dual_frequency_observation(term.base),
        rover: decode_dual_frequency_observation(term.rover),
    }
}

fn decode_dual_frequency_observation(
    term: RtkDualFrequencyObservationTerm,
) -> RtkDualFrequencyObservation {
    RtkDualFrequencyObservation {
        ambiguity_id: term.ambiguity_id,
        p1_m: term.p1_m,
        p2_m: term.p2_m,
        phi1_cycles: term.phi1_cycles,
        phi2_cycles: term.phi2_cycles,
        f1_hz: term.f1_hz,
        f2_hz: term.f2_hz,
        lli1: term.lli1,
        lli2: term.lli2,
    }
}

fn decode_wide_lane_arc_config(term: RtkWideLaneArcConfigTerm) -> Option<RtkWideLaneArcConfig> {
    let cycle_slip = match term.cycle_slip {
        Some(term) => Some(decode_dual_cycle_slip_config(term)?),
        None => None,
    };
    Some(RtkWideLaneArcConfig {
        base_m: vec3(term.base_m),
        reference: decode_arc_reference(term.reference)?,
        options: sidereon_core::rtk_filter::WideLaneOptions {
            min_epochs: term.min_epochs as usize,
            tolerance_cycles: term.tolerance_cycles,
            skip_short_fragments: term.skip_short_fragments,
        },
        cycle_slip,
    })
}

fn decode_dual_cycle_slip_config(
    term: RtkDualCycleSlipConfigTerm,
) -> Option<RtkDualCycleSlipConfig> {
    Some(RtkDualCycleSlipConfig {
        policy: decode_cycle_slip_policy(&term.policy)?,
        options: CycleSlipOptions {
            gf_threshold_m: term.gf_threshold_m,
            mw_threshold_cycles: term.mw_threshold_cycles,
            min_arc_gap_s: term.min_arc_gap_s,
        },
    })
}

fn decode_ionosphere_free_arc_config(
    term: RtkIonosphereFreeArcConfigTerm,
) -> Option<RtkIonosphereFreeArcConfig> {
    Some(RtkIonosphereFreeArcConfig {
        base_m: vec3(term.base_m),
        initial_baseline_m: vec3(term.initial_baseline_m),
        reference: decode_arc_reference(term.reference)?,
        apply_troposphere: term.apply_troposphere,
    })
}

fn encode_wide_lane_arc_solution<'a>(
    env: Env<'a>,
    solution: RtkWideLaneArcSolution,
) -> Term<'a> {
    make_tuple(
        env,
        &[
            solution.references.into_iter().collect::<Vec<_>>().encode(env),
            solution
                .wide_lane_cycles
                .into_iter()
                .collect::<Vec<_>>()
                .encode(env),
            encode_dual_frequency_arc_epochs(env, solution.epochs).encode(env),
            solution.dropped_sats.encode(env),
            encode_arc_split_cycle_slip_arcs(solution.split_cycle_slip_arcs).encode(env),
        ],
    )
}

fn encode_dual_frequency_arc_epochs<'a>(
    env: Env<'a>,
    epochs: Vec<RtkDualFrequencyArcEpoch>,
) -> Vec<Term<'a>> {
    epochs
        .into_iter()
        .map(|epoch| encode_dual_frequency_arc_epoch(env, epoch))
        .collect()
}

fn encode_dual_frequency_arc_epoch<'a>(
    env: Env<'a>,
    epoch: RtkDualFrequencyArcEpoch,
) -> Term<'a> {
    let observations: Vec<Term<'a>> = epoch
        .observations
        .into_iter()
        .map(|observation| encode_dual_frequency_satellite_observation(env, observation))
        .collect();
    make_tuple(
        env,
        &[
            epoch.jd_whole.encode(env),
            epoch.jd_fraction.encode(env),
            epoch.epoch_sort_key.encode(env),
            epoch.gap_time_s.encode(env),
            observations.encode(env),
            encode_position_map(epoch.satellite_positions_m).encode(env),
            encode_position_map(epoch.base_satellite_positions_m).encode(env),
            encode_position_map(epoch.rover_satellite_positions_m).encode(env),
            epoch.velocity_mps.map(tuple3).encode(env),
            epoch.prediction_time_s.encode(env),
        ],
    )
}

fn encode_dual_frequency_satellite_observation<'a>(
    env: Env<'a>,
    observation: RtkDualFrequencySatelliteObservation,
) -> Term<'a> {
    make_tuple(
        env,
        &[
            observation.satellite_id.encode(env),
            encode_dual_frequency_observation(env, observation.base),
            encode_dual_frequency_observation(env, observation.rover),
        ],
    )
}

fn encode_dual_frequency_observation<'a>(
    env: Env<'a>,
    observation: RtkDualFrequencyObservation,
) -> Term<'a> {
    make_tuple(
        env,
        &[
            observation.ambiguity_id.encode(env),
            observation.p1_m.encode(env),
            observation.p2_m.encode(env),
            observation.phi1_cycles.encode(env),
            observation.phi2_cycles.encode(env),
            observation.f1_hz.encode(env),
            observation.f2_hz.encode(env),
            observation.lli1.encode(env),
            observation.lli2.encode(env),
        ],
    )
}

fn encode_ionosphere_free_arc_solution(solution: RtkIonosphereFreeArcSolution) -> (
    Vec<(String, String)>,
    Vec<PreprocessedArcEpochTerm>,
    Vec<(String, f64)>,
    Vec<(String, f64)>,
) {
    (
        solution.references.into_iter().collect(),
        encode_preprocessed_arc_epochs(solution.epochs),
        solution.wavelengths_m.into_iter().collect(),
        solution.offsets_m.into_iter().collect(),
    )
}

fn encode_wide_lane_arc_error<'a>(
    env: Env<'a>,
    error: RtkWideLaneArcError,
    epochs: &[RtkDualFrequencyArcEpoch],
) -> Term<'a> {
    match error {
        RtkWideLaneArcError::EmptyEpochs => atoms::no_epochs().encode(env),
        RtkWideLaneArcError::Reference(error) => encode_arc_reference_error(env, error),
        RtkWideLaneArcError::CycleSlipPrep(error) => {
            encode_wide_lane_cycle_slip_error(env, error, epochs)
        }
        RtkWideLaneArcError::WideLane(error) => encode_wide_lane_error(env, error),
    }
}

fn encode_wide_lane_cycle_slip_error<'a>(
    env: Env<'a>,
    err: CycleSlipPrepError,
    epochs: &[RtkDualFrequencyArcEpoch],
) -> Term<'a> {
    match err {
        CycleSlipPrepError::InvalidInput {
            field: "rtk cycle slip frequencies_hz",
            reason: "degenerate frequencies",
        } => match first_equal_frequency_satellite(epochs) {
            Some(satellite_id) => (
                atoms::wide_lane_failed(),
                satellite_id,
                atoms::equal_frequencies(),
            )
                .encode(env),
            None => atoms::invalid_input().encode(env),
        },
        other => encode_arc_cycle_slip_error(env, other),
    }
}

fn first_equal_frequency_satellite(epochs: &[RtkDualFrequencyArcEpoch]) -> Option<String> {
    epochs.iter().find_map(|epoch| {
        epoch.observations.iter().find_map(|observation| {
            if dual_observation_equal_frequencies(&observation.base)
                || dual_observation_equal_frequencies(&observation.rover)
            {
                Some(observation.satellite_id.clone())
            } else {
                None
            }
        })
    })
}

fn dual_observation_equal_frequencies(observation: &RtkDualFrequencyObservation) -> bool {
    (observation.f1_hz - observation.f2_hz).abs() < FREQ_EPSILON_HZ
}

fn encode_ionosphere_free_arc_error<'a>(
    env: Env<'a>,
    error: RtkIonosphereFreeArcError,
) -> Term<'a> {
    match error {
        RtkIonosphereFreeArcError::EmptyEpochs => atoms::no_epochs().encode(env),
        RtkIonosphereFreeArcError::Reference(error) => encode_arc_reference_error(env, error),
        RtkIonosphereFreeArcError::IonosphereFree(error) => encode_if_error(env, error),
    }
}

fn encode_wide_lane_error<'a>(env: Env<'a>, err: WideLaneError) -> Term<'a> {
    match err {
        WideLaneError::InvalidInput { .. } => atoms::invalid_input().encode(env),
        WideLaneError::ReferenceSatelliteMissing(sat) => {
            (atoms::reference_satellite_missing(), sat).encode(env)
        }
        WideLaneError::WideLaneFailed { satellite_id, .. } => (
            atoms::wide_lane_failed(),
            satellite_id,
            atoms::equal_frequencies(),
        )
            .encode(env),
        WideLaneError::TooFewWideLaneEpochs {
            ambiguity_id,
            count,
            minimum,
        } => (
            atoms::too_few_wide_lane_epochs(),
            ambiguity_id,
            count as u64,
            minimum as u64,
        )
            .encode(env),
        WideLaneError::WideLaneNotInteger {
            ambiguity_id,
            mean_cycles,
            fixed_cycles,
        } => (
            atoms::wide_lane_not_integer(),
            ambiguity_id,
            mean_cycles,
            fixed_cycles,
        )
            .encode(env),
    }
}

fn encode_if_error<'a>(env: Env<'a>, err: IonosphereFreeBaselineError) -> Term<'a> {
    match err {
        IonosphereFreeBaselineError::InvalidInput { .. } => atoms::invalid_input().encode(env),
        IonosphereFreeBaselineError::NoEpochs => atoms::no_epochs().encode(env),
        IonosphereFreeBaselineError::InconsistentFrequencies(ambiguity_id) => {
            (atoms::inconsistent_frequencies(), ambiguity_id).encode(env)
        }
        IonosphereFreeBaselineError::NarrowLaneFailed(reason) => {
            iono_error_atom(reason).encode(env)
        }
        IonosphereFreeBaselineError::IonosphereFreeFailed {
            satellite_id,
            reason,
        } => (
            atoms::ionosphere_free_failed(),
            satellite_id,
            iono_error_atom(reason),
        )
            .encode(env),
    }
}

fn iono_error_atom(reason: IonosphereFreeError) -> rustler::Atom {
    match reason {
        IonosphereFreeError::EqualFrequencies => atoms::equal_frequencies(),
        IonosphereFreeError::InvalidFrequency => atoms::invalid_frequency(),
        IonosphereFreeError::UnknownSystem(_) => atoms::unknown_system(),
        IonosphereFreeError::UnknownBand { .. } => atoms::unknown_band(),
        IonosphereFreeError::InvalidObservation => atoms::invalid_observation(),
    }
}

#[allow(clippy::type_complexity)]
fn preprocess_arc_epochs_for_binding(
    epochs: &[RtkArcEpoch],
    base_m: [f64; 3],
    preprocessing: &RtkArcPreprocessing,
) -> Result<
    (
        Vec<RtkArcEpoch>,
        Vec<String>,
        Vec<CycleSlipSplitArc>,
        Vec<String>,
    ),
    RtkArcError,
> {
    let mut work = epochs.to_vec();
    let mut dropped_sats = Vec::new();
    let mut split_cycle_slip_arcs = Vec::new();
    let mut elevation_masked_sats = Vec::new();

    if let Some(policy) = preprocessing.cycle_slip {
        let cs_epochs: Vec<CodeSmoothingEpoch> =
            work.iter().map(to_binding_code_smoothing_epoch).collect();
        let result = prepare_cycle_slip_baseline_epochs(&cs_epochs, policy)
            .map_err(RtkArcError::CycleSlipPrep)?;
        work = apply_binding_prepared_observations(&work, &result.epochs);
        dropped_sats = result.dropped_sats;
        split_cycle_slip_arcs = result.split_arcs;
    }

    if let Some(window_cap) = preprocessing.hatch_window_cap {
        let cs_epochs: Vec<CodeSmoothingEpoch> =
            work.iter().map(to_binding_code_smoothing_epoch).collect();
        let smoothed = hatch_smooth_baseline_code_epochs(&cs_epochs, window_cap)
            .map_err(RtkArcError::CodeSmoothing)?;
        work = apply_binding_prepared_observations(&work, &smoothed);
    }

    if let Some(mask_deg) = preprocessing.elevation_mask_deg {
        let mask_epochs: Vec<ElevationMaskEpoch> = work
            .iter()
            .map(|epoch| ElevationMaskEpoch {
                satellite_positions_m: epoch.satellite_positions_m.clone(),
            })
            .collect();
        let result =
            apply_elevation_mask(base_m, &mask_epochs, mask_deg).map_err(RtkArcError::ElevationMask)?;
        work = work
            .iter()
            .zip(result.epochs.iter())
            .map(|(epoch, kept)| thin_binding_epoch_to_kept(epoch, &kept.kept_satellite_ids))
            .collect();
        elevation_masked_sats = result.masked_satellite_ids;
    }

    Ok((
        work,
        dropped_sats,
        split_cycle_slip_arcs,
        elevation_masked_sats,
    ))
}

fn to_binding_code_smoothing_epoch(epoch: &RtkArcEpoch) -> CodeSmoothingEpoch {
    CodeSmoothingEpoch {
        base_observations: epoch
            .base
            .iter()
            .map(to_binding_code_smoothing_obs)
            .collect(),
        rover_observations: epoch
            .rover
            .iter()
            .map(to_binding_code_smoothing_obs)
            .collect(),
    }
}

fn to_binding_code_smoothing_obs(obs: &RtkArcObservation) -> CodeSmoothingObservation {
    CodeSmoothingObservation {
        satellite_id: obs.satellite_id.clone(),
        ambiguity_id: obs.ambiguity_id.clone(),
        code_m: obs.code_m,
        phase_m: obs.phase_m,
        lli: obs.lli,
    }
}

fn from_binding_code_smoothing_obs(obs: &CodeSmoothingObservation) -> RtkArcObservation {
    RtkArcObservation {
        satellite_id: obs.satellite_id.clone(),
        ambiguity_id: obs.ambiguity_id.clone(),
        code_m: obs.code_m,
        phase_m: obs.phase_m,
        lli: obs.lli,
    }
}

fn apply_binding_prepared_observations(
    original: &[RtkArcEpoch],
    prepared: &[CodeSmoothingEpoch],
) -> Vec<RtkArcEpoch> {
    original
        .iter()
        .zip(prepared.iter())
        .map(|(orig, prep)| RtkArcEpoch {
            base: prep
                .base_observations
                .iter()
                .map(from_binding_code_smoothing_obs)
                .collect(),
            rover: prep
                .rover_observations
                .iter()
                .map(from_binding_code_smoothing_obs)
                .collect(),
            satellite_positions_m: orig.satellite_positions_m.clone(),
            base_satellite_positions_m: orig.base_satellite_positions_m.clone(),
            rover_satellite_positions_m: orig.rover_satellite_positions_m.clone(),
            velocity_mps: orig.velocity_mps,
            prediction_time_s: orig.prediction_time_s,
        })
        .collect()
}

fn thin_binding_epoch_to_kept(epoch: &RtkArcEpoch, kept: &[String]) -> RtkArcEpoch {
    let keep: std::collections::BTreeSet<&str> = kept.iter().map(String::as_str).collect();
    let filter_obs = |obs: &[RtkArcObservation]| {
        obs.iter()
            .filter(|o| keep.contains(o.satellite_id.as_str()))
            .cloned()
            .collect::<Vec<_>>()
    };
    let filter_positions = |map: &BTreeMap<String, [f64; 3]>| {
        map.iter()
            .filter(|(sat, _)| keep.contains(sat.as_str()))
            .map(|(sat, pos)| (sat.clone(), *pos))
            .collect::<BTreeMap<_, _>>()
    };
    RtkArcEpoch {
        base: filter_obs(&epoch.base),
        rover: filter_obs(&epoch.rover),
        satellite_positions_m: filter_positions(&epoch.satellite_positions_m),
        base_satellite_positions_m: filter_positions(&epoch.base_satellite_positions_m),
        rover_satellite_positions_m: filter_positions(&epoch.rover_satellite_positions_m),
        velocity_mps: epoch.velocity_mps,
        prediction_time_s: epoch.prediction_time_s,
    }
}

fn encode_preprocessed_arc_epochs(epochs: Vec<RtkArcEpoch>) -> Vec<PreprocessedArcEpochTerm> {
    epochs
        .into_iter()
        .map(|epoch| {
            (
                encode_preprocessed_arc_observations(epoch.base),
                encode_preprocessed_arc_observations(epoch.rover),
                encode_position_map(epoch.satellite_positions_m),
                encode_position_map(epoch.base_satellite_positions_m),
                encode_position_map(epoch.rover_satellite_positions_m),
                epoch.velocity_mps.map(tuple3),
                epoch.prediction_time_s,
            )
        })
        .collect()
}

fn encode_preprocessed_arc_observations(
    observations: Vec<RtkArcObservation>,
) -> Vec<ArcObservationOutputTerm> {
    observations
        .into_iter()
        .map(|obs| {
            (
                obs.satellite_id,
                obs.ambiguity_id,
                obs.code_m,
                obs.phase_m,
                obs.lli,
            )
        })
        .collect()
}

fn encode_position_map(positions: BTreeMap<String, [f64; 3]>) -> Vec<(String, Vec3)> {
    positions
        .into_iter()
        .map(|(sat, position)| (sat, tuple3(position)))
        .collect()
}

fn decode_arc_epoch(term: RtkArcEpochTerm) -> RtkArcEpoch {
    RtkArcEpoch {
        base: term.base.into_iter().map(decode_arc_observation).collect(),
        rover: term.rover.into_iter().map(decode_arc_observation).collect(),
        satellite_positions_m: decode_position_map(term.satellite_positions_m),
        base_satellite_positions_m: decode_position_map(term.base_satellite_positions_m),
        rover_satellite_positions_m: decode_position_map(term.rover_satellite_positions_m),
        velocity_mps: term.velocity_mps.map(vec3),
        prediction_time_s: term.prediction_time_s,
    }
}

fn decode_arc_observation(term: RtkArcObservationTerm) -> RtkArcObservation {
    RtkArcObservation {
        satellite_id: term.satellite_id,
        ambiguity_id: term.ambiguity_id,
        code_m: term.code_m,
        phase_m: term.phase_m,
        lli: term.lli,
    }
}

fn decode_position_map(entries: Vec<(String, Vec3)>) -> BTreeMap<String, [f64; 3]> {
    entries
        .into_iter()
        .map(|(id, position)| (id, vec3(position)))
        .collect()
}

fn decode_arc_config(term: RtkArcConfigTerm) -> NifResult<RtkArcConfig> {
    let model = decode_model(term.model)
        .ok_or_else(|| rustler::Error::Term(Box::new("invalid stochastic model")))?;
    let mut update_opts = decode_opts(term.update_opts)
        .ok_or_else(|| rustler::Error::Term(Box::new("invalid dynamics model")))?;
    update_opts.receiver_antenna_corrections = term
        .receiver_antenna_corrections
        .map(decode_receiver_antenna_corrections);
    let reference = decode_arc_reference(term.reference)
        .ok_or_else(|| rustler::Error::Term(Box::new("invalid reference selection")))?;
    let preprocessing = decode_arc_preprocessing(term.preprocessing)
        .ok_or_else(|| rustler::Error::Term(Box::new("invalid cycle-slip policy")))?;
    Ok(RtkArcConfig {
        base_m: vec3(term.base_m),
        reference,
        model,
        baseline_prior_sigma_m: term.baseline_prior_sigma_m,
        ambiguity_prior_sigma_m: term.ambiguity_prior_sigma_m,
        initial_baseline_m: vec3(term.initial_baseline_m),
        wavelengths_m: term.wavelengths_m.into_iter().collect(),
        offsets_m: term.offsets_m.into_iter().collect(),
        update_opts,
        preprocessing,
    })
}

fn decode_arc_preprocessing(term: RtkArcPreprocessingTerm) -> Option<RtkArcPreprocessing> {
    let cycle_slip = match term.cycle_slip {
        None => None,
        Some(policy) => Some(decode_cycle_slip_policy(&policy)?),
    };
    Some(RtkArcPreprocessing {
        cycle_slip,
        hatch_window_cap: term.hatch_window_cap,
        elevation_mask_deg: term.elevation_mask_deg,
    })
}

fn decode_cycle_slip_policy(policy: &str) -> Option<CycleSlipPolicy> {
    match policy {
        "error" => Some(CycleSlipPolicy::Error),
        "drop_satellite" => Some(CycleSlipPolicy::DropSatellite),
        "split_arc" => Some(CycleSlipPolicy::SplitArc),
        _ => None,
    }
}

fn decode_arc_reference(term: RtkArcReferenceTerm) -> Option<BaselineReferenceSelection> {
    match term.mode.as_str() {
        "auto" => Some(BaselineReferenceSelection::Auto),
        "satellite" => term.satellite.map(BaselineReferenceSelection::Satellite),
        "per_system" => Some(BaselineReferenceSelection::PerSystem(
            term.per_system.into_iter().collect(),
        )),
        _ => None,
    }
}

fn encode_arc_solution<'a>(env: Env<'a>, solution: RtkArcSolution) -> Term<'a> {
    let references: Vec<(String, String)> = solution.references.into_iter().collect();
    let epochs: Vec<Term<'a>> = solution
        .epochs
        .into_iter()
        .map(|epoch| encode_arc_epoch_solution(env, epoch))
        .collect();
    let split_cycle_slip_arcs = encode_arc_split_cycle_slip_arcs(solution.split_cycle_slip_arcs);
    make_tuple(
        env,
        &[
            references.encode(env),
            epochs.encode(env),
            encode_state(solution.final_state).encode(env),
            solution.dropped_sats.encode(env),
            split_cycle_slip_arcs.encode(env),
            solution.elevation_masked_sats.encode(env),
            solution.measurement_covariance.encode(env),
        ],
    )
}

type ArcSplitCycleSlipArcTerm = (String, String, String, u64, u64, u64);

fn encode_arc_split_cycle_slip_arcs(arcs: Vec<CycleSlipSplitArc>) -> Vec<ArcSplitCycleSlipArcTerm> {
    arcs.into_iter()
        .map(|arc| {
            (
                encode_arc_cycle_slip_receiver(arc.receiver),
                arc.satellite_id,
                arc.ambiguity_id,
                arc.start_epoch_index as u64,
                arc.end_epoch_index as u64,
                arc.n_epochs as u64,
            )
        })
        .collect()
}

fn encode_arc_cycle_slip_receiver(receiver: CycleSlipReceiver) -> String {
    match receiver {
        CycleSlipReceiver::Base => "base".to_string(),
        CycleSlipReceiver::Rover => "rover".to_string(),
    }
}

fn encode_arc_epoch_solution<'a>(env: Env<'a>, epoch: RtkArcEpochSolution) -> Term<'a> {
    make_tuple(
        env,
        &[
            tuple3(epoch.reported_baseline_m).encode(env),
            tuple3(epoch.float_baseline_m).encode(env),
            epoch.integer_fixed.encode(env),
            epoch.integer_ratio.encode(env),
            epoch.newly_fixed.encode(env),
            epoch.fixed_ids.encode(env),
            epoch.sd_ambiguities_m.encode(env),
            epoch.fixed_double_difference_ids.encode(env),
            epoch.used_satellite_ids.encode(env),
            epoch
                .search
                .map(|meta| encode_integer_search_meta(env, meta))
                .encode(env),
            encode_residuals(env, epoch.residuals).encode(env),
            epoch
                .innovation_screen
                .map(encode_innovation_screen)
                .encode(env),
        ],
    )
}

fn encode_arc_error<'a>(env: Env<'a>, error: RtkArcError) -> Term<'a> {
    match error {
        RtkArcError::EmptyEpochs => atoms::empty_epochs().encode(env),
        RtkArcError::TooFewSatellites { count, minimum } => {
            (atoms::too_few_satellites(), count as i64, minimum as i64).encode(env)
        }
        RtkArcError::Reference(error) => encode_arc_reference_error(env, error),
        RtkArcError::FilterState(error) => (atoms::invalid_state(), error.to_string()).encode(env),
        RtkArcError::Update {
            epoch_index,
            source,
        } => (
            atoms::update_failed(),
            epoch_index as i64,
            encode_update_error(env, source),
        )
            .encode(env),
        RtkArcError::InvalidEpochTime { epoch_index } => {
            (atoms::invalid_epoch_time(), epoch_index as i64).encode(env)
        }
        RtkArcError::MissingPosition {
            epoch_index,
            satellite_id,
        } => (
            atoms::missing_position(),
            epoch_index as i64,
            satellite_id,
        )
            .encode(env),
        RtkArcError::CycleSlipPrep(error) => encode_arc_cycle_slip_error(env, error),
        RtkArcError::CodeSmoothing(error) => {
            (atoms::code_smoothing_failed(), format!("{error:?}")).encode(env)
        }
        RtkArcError::ElevationMask(error) => {
            (atoms::elevation_mask_failed(), format!("{error:?}")).encode(env)
        }
    }
}

fn encode_arc_reference_error<'a>(env: Env<'a>, err: DoubleDifferenceError) -> Term<'a> {
    match err {
        DoubleDifferenceError::InvalidInput { .. } => atoms::invalid_input().encode(env),
        DoubleDifferenceError::MissingSatellitePosition(sat) => {
            (atoms::missing_satellite_position(), sat).encode(env)
        }
        DoubleDifferenceError::DuplicateObservation(sat) => {
            (atoms::duplicate_observation(), sat).encode(env)
        }
        DoubleDifferenceError::TooFewCommonSatellites { count, minimum } => (
            atoms::too_few_common_satellites(),
            count as u64,
            minimum as u64,
        )
            .encode(env),
        DoubleDifferenceError::NoCommonReferenceSatellite(system) => {
            (atoms::no_common_reference_satellite(), system).encode(env)
        }
        DoubleDifferenceError::ReferenceSatelliteMissing(sat) => {
            (atoms::reference_satellite_missing(), sat).encode(env)
        }
        DoubleDifferenceError::ReferenceSatelliteSingleSystem(sat) => {
            (atoms::reference_satellite_single_system(), sat).encode(env)
        }
        DoubleDifferenceError::ReferenceSatelliteMissingSystem(system) => {
            (atoms::reference_satellite_missing_system(), system).encode(env)
        }
        DoubleDifferenceError::InvalidReferenceOption => {
            (atoms::invalid_option(), atoms::reference_satellite_id()).encode(env)
        }
    }
}

fn encode_arc_cycle_slip_error<'a>(env: Env<'a>, err: CycleSlipPrepError) -> Term<'a> {
    match err {
        CycleSlipPrepError::InvalidInput { .. } => atoms::invalid_input().encode(env),
        CycleSlipPrepError::CycleSlipDetected {
            receiver,
            satellite_id,
            epoch_index,
            reasons,
        } => (
            atoms::cycle_slip_detected(),
            encode_arc_cycle_slip_receiver(receiver),
            satellite_id,
            epoch_index as u64,
            reasons
                .into_iter()
                .map(encode_arc_cycle_slip_reason)
                .collect::<Vec<String>>(),
        )
            .encode(env),
    }
}

fn encode_arc_cycle_slip_reason(reason: SlipReason) -> String {
    match reason {
        SlipReason::Lli => "lli".to_string(),
        SlipReason::DataGap => "data_gap".to_string(),
        SlipReason::GeometryFree => "geometry_free".to_string(),
        SlipReason::MelbourneWubbena => "melbourne_wubbena".to_string(),
    }
}
