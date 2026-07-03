//! Rustler boundary for 6x6 state covariance transport.
//!
//! This module only converts terms to core covariance and propagator types,
//! then returns the core results. Frame transforms, PSD interpolation, state
//! transition matrices, process noise, and numerical propagation all live in
//! `sidereon-core`.

use rustler::{Encoder, Env, Term};
use sidereon_core::astro::covariance::{
    covariance6_km_to_m as core_covariance6_km_to_m,
    covariance6_m_to_km as core_covariance6_m_to_km, eci_to_rtn_covariance6,
    interpolate_covariance_psd, rtn_to_eci_covariance6, Covariance6, Covariance6Error, Mat6,
};
use sidereon_core::astro::propagator::{
    transport_covariance, CovarianceFrame, CovariancePropagationOptions, CovarianceSegment,
    ForceModelKind, IntegratorKind, IntegratorOptions, LabeledCovariance6, ProcessNoise,
    StatePropagator, StateTransitionMatrix,
};
use sidereon_core::astro::state::CartesianState;

type Vec3 = (f64, f64, f64);
type StateTerm = (f64, Vec3, Vec3);

mod atoms {
    rustler::atoms! {
        ok,
        error,
        invalid_input,
        non_finite,
        asymmetric,
        not_positive_semidefinite,
        not_factorizable,
        invalid_interpolation_parameter
    }
}

#[derive(Debug, Clone, rustler::NifMap)]
struct ProcessNoiseTerm {
    kind: String,
    q_radial_km2_s3: Option<f64>,
    q_transverse_km2_s3: Option<f64>,
    q_normal_km2_s3: Option<f64>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct PropagateOptionsTerm {
    input_frame: String,
    output_frame: String,
    process_noise: ProcessNoiseTerm,
    forces: Vec<String>,
    integrator: String,
    abs_tol: f64,
    rel_tol: f64,
    min_step: f64,
    max_step: f64,
    initial_step: f64,
    max_steps: u32,
    dense_output: bool,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct SegmentTerm {
    stm: Vec<Vec<f64>>,
    dt_seconds: f64,
    q_rotation_state: StateTerm,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct TransportOptionsTerm {
    process_noise: ProcessNoiseTerm,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct StateOutTerm {
    epoch_tdb_seconds: f64,
    position_km: Vec3,
    velocity_km_s: Vec3,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct CovarianceNodeTerm {
    state: StateOutTerm,
    covariance: Vec<Vec<f64>>,
    frame: String,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct CovarianceValidationTerm {
    symmetric: bool,
    positive_semidefinite: bool,
}

fn atom_error<'a>(env: Env<'a>, atom: rustler::Atom) -> Term<'a> {
    (atoms::error(), atom).encode(env)
}

fn string_error<'a>(env: Env<'a>, reason: impl ToString) -> Term<'a> {
    (atoms::error(), reason.to_string()).encode(env)
}

fn covariance_error_atom(error: Covariance6Error) -> rustler::Atom {
    match error {
        Covariance6Error::NonFinite => atoms::non_finite(),
        Covariance6Error::Asymmetric => atoms::asymmetric(),
        Covariance6Error::NotPositiveSemidefinite => atoms::not_positive_semidefinite(),
        Covariance6Error::NotFactorizable => atoms::not_factorizable(),
        Covariance6Error::InvalidInterpolationParameter => atoms::invalid_interpolation_parameter(),
    }
}

fn vec3(values: Vec3) -> [f64; 3] {
    [values.0, values.1, values.2]
}

fn state(value: StateTerm) -> CartesianState {
    CartesianState::new(value.0, vec3(value.1), vec3(value.2))
}

fn mat6_from_rows(rows: Vec<Vec<f64>>) -> Option<Mat6> {
    if rows.len() != 6 || rows.iter().any(|row| row.len() != 6) {
        return None;
    }
    let mut matrix = [[0.0_f64; 6]; 6];
    for (i, row) in rows.into_iter().enumerate() {
        for (j, value) in row.into_iter().enumerate() {
            matrix[i][j] = value;
        }
    }
    Some(matrix)
}

fn stm_from_rows(rows: Vec<Vec<f64>>) -> Option<StateTransitionMatrix> {
    mat6_from_rows(rows)
}

fn rows_from_mat6(matrix: Mat6) -> Vec<Vec<f64>> {
    matrix.iter().map(|row| row.to_vec()).collect()
}

fn covariance_from_rows(rows: Vec<Vec<f64>>) -> Result<Covariance6, Covariance6Error> {
    let matrix = mat6_from_rows(rows).ok_or(Covariance6Error::NonFinite)?;
    Covariance6::try_from_matrix(matrix)
}

fn covariance_result<'a>(env: Env<'a>, result: Result<Covariance6, Covariance6Error>) -> Term<'a> {
    match result {
        Ok(covariance) => (atoms::ok(), rows_from_mat6(covariance.into_matrix())).encode(env),
        Err(error) => atom_error(env, covariance_error_atom(error)),
    }
}

fn frame(label: &str) -> Option<CovarianceFrame> {
    match label {
        "inertial" => Some(CovarianceFrame::Inertial),
        "rtn" => Some(CovarianceFrame::Rtn),
        _ => None,
    }
}

fn frame_label(frame: CovarianceFrame) -> String {
    match frame {
        CovarianceFrame::Inertial => "inertial".to_string(),
        CovarianceFrame::Rtn => "rtn".to_string(),
    }
}

fn process_noise(term: ProcessNoiseTerm) -> Option<ProcessNoise> {
    match term.kind.as_str() {
        "none" => Some(ProcessNoise::None),
        "rtn_acceleration_psd" => Some(ProcessNoise::RtnAccelerationPsd {
            q_radial_km2_s3: term.q_radial_km2_s3?,
            q_transverse_km2_s3: term.q_transverse_km2_s3?,
            q_normal_km2_s3: term.q_normal_km2_s3?,
        }),
        _ => None,
    }
}

fn force_model(forces: &[String]) -> ForceModelKind {
    if forces
        .iter()
        .any(|force| force == "j2" || force == "twobody_j2")
    {
        ForceModelKind::two_body_j2()
    } else {
        ForceModelKind::two_body()
    }
}

fn integrator(label: &str) -> Option<IntegratorKind> {
    match label {
        "dp54" => Some(IntegratorKind::Dp54),
        "rk4" => Some(IntegratorKind::Rk4),
        _ => None,
    }
}

fn state_out(state: CartesianState) -> StateOutTerm {
    let position = state.position_array();
    let velocity = state.velocity_array();
    StateOutTerm {
        epoch_tdb_seconds: state.epoch_tdb_seconds,
        position_km: (position[0], position[1], position[2]),
        velocity_km_s: (velocity[0], velocity[1], velocity[2]),
    }
}

fn segments_from_terms(terms: Vec<SegmentTerm>) -> Option<Vec<CovarianceSegment>> {
    terms
        .into_iter()
        .map(|term| {
            Some(CovarianceSegment {
                stm: stm_from_rows(term.stm)?,
                dt_seconds: term.dt_seconds,
                q_rotation_state: state(term.q_rotation_state),
            })
        })
        .collect()
}

#[rustler::nif]
fn covariance6_from_diagonal<'a>(env: Env<'a>, diagonal: Vec<f64>) -> Term<'a> {
    if diagonal.len() != 6 {
        return atom_error(env, atoms::invalid_input());
    }
    let mut diag = [0.0_f64; 6];
    diag.copy_from_slice(&diagonal);
    covariance_result(env, Covariance6::from_diagonal(diag))
}

#[rustler::nif]
fn covariance6_validate<'a>(env: Env<'a>, matrix: Vec<Vec<f64>>) -> Term<'a> {
    match covariance_from_rows(matrix) {
        Ok(covariance) => (
            atoms::ok(),
            CovarianceValidationTerm {
                symmetric: covariance.is_symmetric(),
                positive_semidefinite: covariance.is_positive_semidefinite(),
            },
        )
            .encode(env),
        Err(error) => atom_error(env, covariance_error_atom(error)),
    }
}

#[rustler::nif]
fn covariance6_rtn_to_eci<'a>(
    env: Env<'a>,
    matrix: Vec<Vec<f64>>,
    state_term: StateTerm,
) -> Term<'a> {
    let covariance = match covariance_from_rows(matrix) {
        Ok(covariance) => covariance,
        Err(error) => return atom_error(env, covariance_error_atom(error)),
    };
    match rtn_to_eci_covariance6(&covariance, &state(state_term)) {
        Ok(covariance) => (atoms::ok(), rows_from_mat6(covariance.into_matrix())).encode(env),
        Err(error) => string_error(env, error.message()),
    }
}

#[rustler::nif]
fn covariance6_eci_to_rtn<'a>(
    env: Env<'a>,
    matrix: Vec<Vec<f64>>,
    state_term: StateTerm,
) -> Term<'a> {
    let covariance = match covariance_from_rows(matrix) {
        Ok(covariance) => covariance,
        Err(error) => return atom_error(env, covariance_error_atom(error)),
    };
    match eci_to_rtn_covariance6(&covariance, &state(state_term)) {
        Ok(covariance) => (atoms::ok(), rows_from_mat6(covariance.into_matrix())).encode(env),
        Err(error) => string_error(env, error.message()),
    }
}

#[rustler::nif]
fn covariance6_km_to_m<'a>(env: Env<'a>, matrix: Vec<Vec<f64>>) -> Term<'a> {
    match covariance_from_rows(matrix) {
        Ok(covariance) => covariance_result(env, core_covariance6_km_to_m(&covariance)),
        Err(error) => atom_error(env, covariance_error_atom(error)),
    }
}

#[rustler::nif]
fn covariance6_m_to_km<'a>(env: Env<'a>, matrix: Vec<Vec<f64>>) -> Term<'a> {
    match covariance_from_rows(matrix) {
        Ok(covariance) => covariance_result(env, core_covariance6_m_to_km(&covariance)),
        Err(error) => atom_error(env, covariance_error_atom(error)),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn covariance6_interpolate_psd<'a>(
    env: Env<'a>,
    a: Vec<Vec<f64>>,
    b: Vec<Vec<f64>>,
    u: f64,
) -> Term<'a> {
    let a = match covariance_from_rows(a) {
        Ok(covariance) => covariance,
        Err(error) => return atom_error(env, covariance_error_atom(error)),
    };
    let b = match covariance_from_rows(b) {
        Ok(covariance) => covariance,
        Err(error) => return atom_error(env, covariance_error_atom(error)),
    };
    covariance_result(env, interpolate_covariance_psd(&a, &b, u))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn covariance6_transport_segments<'a>(
    env: Env<'a>,
    matrix: Vec<Vec<f64>>,
    segment_terms: Vec<SegmentTerm>,
    options: TransportOptionsTerm,
) -> Term<'a> {
    let covariance0 = match covariance_from_rows(matrix) {
        Ok(covariance) => covariance,
        Err(error) => return atom_error(env, covariance_error_atom(error)),
    };
    let Some(segments) = segments_from_terms(segment_terms) else {
        return atom_error(env, atoms::invalid_input());
    };
    let Some(process_noise) = process_noise(options.process_noise) else {
        return atom_error(env, atoms::invalid_input());
    };

    match transport_covariance(covariance0, &segments, process_noise) {
        Ok(covariances) => {
            let rows: Vec<Vec<Vec<f64>>> = covariances
                .into_iter()
                .map(|covariance| rows_from_mat6(covariance.into_matrix()))
                .collect();
            (atoms::ok(), rows).encode(env)
        }
        Err(error) => string_error(env, error),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn propagate_covariance<'a>(
    env: Env<'a>,
    initial_state: StateTerm,
    matrix: Vec<Vec<f64>>,
    epochs_tdb_seconds: Vec<f64>,
    options: PropagateOptionsTerm,
) -> Term<'a> {
    let covariance = match covariance_from_rows(matrix) {
        Ok(covariance) => covariance,
        Err(error) => return atom_error(env, covariance_error_atom(error)),
    };
    let Some(input_frame) = frame(&options.input_frame) else {
        return atom_error(env, atoms::invalid_input());
    };
    let Some(output_frame) = frame(&options.output_frame) else {
        return atom_error(env, atoms::invalid_input());
    };
    let Some(process_noise) = process_noise(options.process_noise) else {
        return atom_error(env, atoms::invalid_input());
    };
    let Some(integrator) = integrator(&options.integrator) else {
        return atom_error(env, atoms::invalid_input());
    };
    let initial = state(initial_state);
    let propagator = StatePropagator::new(
        initial.epoch_tdb_seconds,
        initial.position_array(),
        initial.velocity_array(),
        force_model(&options.forces),
        integrator,
    )
    .with_options(IntegratorOptions {
        abs_tol: options.abs_tol,
        rel_tol: options.rel_tol,
        min_step: options.min_step,
        max_step: options.max_step,
        initial_step: options.initial_step,
        max_steps: options.max_steps,
        dense_output: options.dense_output,
    });

    let propagation_options = CovariancePropagationOptions {
        process_noise,
        output_frame,
    };
    match propagator.propagate_covariance(
        LabeledCovariance6 {
            covariance,
            frame: input_frame,
        },
        &epochs_tdb_seconds,
        &propagation_options,
    ) {
        Ok(ephemeris) => {
            let nodes: Vec<CovarianceNodeTerm> = ephemeris
                .nodes()
                .iter()
                .map(|node| CovarianceNodeTerm {
                    state: state_out(node.state),
                    covariance: rows_from_mat6(node.covariance.into_matrix()),
                    frame: frame_label(node.frame),
                })
                .collect();
            (atoms::ok(), nodes).encode(env)
        }
        Err(error) => string_error(env, error),
    }
}
