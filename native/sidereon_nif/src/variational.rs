use crate::analytic::{decode_state, encode_state, StateTerm};
use crate::earth_orientation::{propagation_context, ContextResource};
use crate::force_models::{force_result, ForceInput};
use crate::space_weather::{table_source, SpaceWeatherPolicyTerm, SpaceWeatherTableResource};
use rustler::{Atom, Encoder, Env, NifMap, NifResult, NifUnitEnum, ResourceArc, Term};
use sidereon_core::astro::propagator::dense_output::{DenseOutput, DenseOutputError};
use sidereon_core::astro::propagator::result::PropagationResult;
use sidereon_core::astro::propagator::{
    propagate_variational, IntegratorKind, IntegratorOptions, PropagationContext, StatePropagator,
    VariationalEpoch, VariationalEquations, VariationalState,
};

#[derive(NifUnitEnum)]
pub(crate) enum Integrator {
    Rk4,
    Dp54,
}

impl From<Integrator> for IntegratorKind {
    fn from(integrator: Integrator) -> Self {
        match integrator {
            Integrator::Rk4 => Self::Rk4,
            Integrator::Dp54 => Self::Dp54,
        }
    }
}

#[derive(NifMap)]
pub(crate) struct Options {
    abs_tol: f64,
    rel_tol: f64,
    min_step: f64,
    max_step: f64,
    initial_step: f64,
    max_steps: u32,
    dense_output: bool,
}

impl From<Options> for IntegratorOptions {
    fn from(options: Options) -> Self {
        let mut value = Self::default();
        value.abs_tol = options.abs_tol;
        value.rel_tol = options.rel_tol;
        value.min_step = options.min_step;
        value.max_step = options.max_step;
        value.initial_step = options.initial_step;
        value.max_steps = options.max_steps;
        value.dense_output = options.dense_output;
        value
    }
}

#[derive(NifMap)]
struct Epoch {
    tdb_j2000_s: f64,
    elapsed_tt_s: f64,
}

impl From<VariationalEpoch> for Epoch {
    fn from(epoch: VariationalEpoch) -> Self {
        Self {
            tdb_j2000_s: epoch.tdb_j2000_s,
            elapsed_tt_s: epoch.elapsed_tt_s,
        }
    }
}

impl From<Epoch> for VariationalEpoch {
    fn from(epoch: Epoch) -> Self {
        Self {
            tdb_j2000_s: epoch.tdb_j2000_s,
            elapsed_tt_s: epoch.elapsed_tt_s,
        }
    }
}

#[rustler::nif]
fn variational_epoch_from_tdb_seconds(initial: f64, target: f64) -> Epoch {
    VariationalEpoch::from_tdb_seconds(initial, target).into()
}

#[derive(NifMap)]
struct Equations {
    force: ForceInput,
    parameters: Vec<f64>,
    sensitivity_parameters: Vec<usize>,
}

#[derive(NifMap)]
#[rustler(encode)]
struct State {
    state: StateTerm,
    state_transition: Vec<Vec<f64>>,
    sensitivity: Vec<Vec<f64>>,
}

impl From<VariationalState> for State {
    fn from(value: VariationalState) -> Self {
        Self {
            state: encode_state(value.state),
            state_transition: value
                .state_transition
                .row_iter()
                .map(|row| row.iter().copied().collect())
                .collect(),
            sensitivity: value
                .sensitivity
                .row_iter()
                .map(|row| row.iter().copied().collect())
                .collect(),
        }
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn propagate_variational_states(
    env: Env<'_>,
    initial: StateTerm,
    epochs: Vec<Epoch>,
    equations: Equations,
    integrator: Integrator,
    options: Options,
    de: Option<ResourceArc<ContextResource>>,
) -> Term<'_> {
    let initial = decode_state(initial);
    let epochs = epochs
        .into_iter()
        .map(VariationalEpoch::from)
        .collect::<Vec<_>>();
    let force = equations.force.into_force();
    let equations = VariationalEquations {
        force: force.as_ref(),
        parameters: &equations.parameters,
        sensitivity_parameters: &equations.sensitivity_parameters,
    };
    let context = propagation_context(de);
    force_result(
        env,
        propagate_variational(
            initial,
            &epochs,
            &equations,
            integrator.into(),
            &options.into(),
            &context,
        )
        .map(|states| states.into_iter().map(State::from).collect::<Vec<_>>()),
    )
}

#[derive(NifMap)]
struct TrajectoryOptions {
    propagation: BuiltInPropagationOptions,
    additional_forces: Vec<ForceInput>,
    context: Option<ResourceArc<ContextResource>>,
}

impl TrajectoryOptions {
    fn propagator(
        self,
        initial: StateTerm,
    ) -> NifResult<(StatePropagator, PropagationContext, Vec<ForceInput>)> {
        let propagator = self.propagation.propagator(initial)?;
        let context = propagation_context(self.context);
        Ok((propagator, context, self.additional_forces))
    }
}

pub(crate) struct DenseOutputResource(pub DenseOutput);

#[rustler::resource_impl]
impl rustler::Resource for DenseOutputResource {}

#[derive(NifMap)]
#[rustler(encode)]
struct Stats {
    accepted_steps: u32,
    rejected_steps: u32,
    evaluations: u32,
}

#[derive(NifMap)]
#[rustler(encode)]
struct ResultTerm {
    final_state: StateTerm,
    points: Vec<StateTerm>,
    events: Vec<()>,
    stats: Stats,
    dense: Option<ResourceArc<DenseOutputResource>>,
    ut1_degraded: Option<Atom>,
}

impl From<PropagationResult> for ResultTerm {
    fn from(result: PropagationResult) -> Self {
        debug_assert!(result.events.is_empty());
        Self {
            final_state: encode_state(result.final_state),
            points: result
                .points
                .into_iter()
                .map(|point| {
                    (
                        point.epoch_tdb_seconds,
                        crate::vector_tuple(point.position_km),
                        crate::vector_tuple(point.velocity_km_s),
                    )
                })
                .collect(),
            events: Vec::new(),
            stats: Stats {
                accepted_steps: result.stats.accepted_steps,
                rejected_steps: result.stats.rejected_steps,
                evaluations: result.stats.evaluations,
            },
            dense: result.dense.map(DenseOutputResource).map(ResourceArc::new),
            ut1_degraded: result.ut1_degraded.map(crate::errors::degrade_reason_atom),
        }
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn propagate_to_with_context(
    env: Env<'_>,
    initial: StateTerm,
    target: f64,
    options: TrajectoryOptions,
) -> NifResult<Term<'_>> {
    let (propagator, context, additional) = options.propagator(initial)?;
    let additional = additional
        .into_iter()
        .map(ForceInput::into_force)
        .collect::<Vec<_>>();
    Ok(force_result(
        env,
        propagator
            .propagate_to_with_additional_forces(target, &additional, &context)
            .map(ResultTerm::from),
    ))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn propagate_state_nodes(
    env: Env<'_>,
    initial: StateTerm,
    epochs: Vec<f64>,
    options: TrajectoryOptions,
) -> NifResult<Term<'_>> {
    let (propagator, context, additional) = options.propagator(initial)?;
    let additional = additional
        .into_iter()
        .map(ForceInput::into_force)
        .collect::<Vec<_>>();
    let states = propagator.ephemeris_with_additional_forces(&epochs, &additional, &context);
    Ok(force_result(
        env,
        states.map(|states| states.into_iter().map(encode_state).collect::<Vec<_>>()),
    ))
}

#[rustler::nif]
fn integration_defaults() -> Options {
    let value = IntegratorOptions::default();
    Options {
        abs_tol: value.abs_tol,
        rel_tol: value.rel_tol,
        min_step: value.min_step,
        max_step: value.max_step,
        initial_step: value.initial_step,
        max_steps: value.max_steps,
        dense_output: value.dense_output,
    }
}

#[derive(NifMap)]
struct BuiltInPropagationOptions {
    forces: Vec<String>,
    integrator: Integrator,
    integration: Options,
    drag: Option<crate::drag::DragParametersTerm>,
    space_weather: Option<ResourceArc<SpaceWeatherTableResource>>,
    space_weather_policy: Option<SpaceWeatherPolicyTerm>,
}

impl BuiltInPropagationOptions {
    fn propagator(self, initial: StateTerm) -> NifResult<StatePropagator> {
        Ok(StatePropagator {
            initial: decode_state(initial),
            force_model: crate::propagation::force_model_kind(&self.forces)?,
            integrator: self.integrator.into(),
            options: self.integration.into(),
            drag: self
                .drag
                .map(crate::drag::DragParametersTerm::decode_with_reason)
                .transpose()?,
            space_weather: self
                .space_weather
                .map(|table| table_source(&table, self.space_weather_policy)),
        })
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn state_transition_matrix_to_with_context(
    env: Env<'_>,
    initial: StateTerm,
    target: f64,
    options: BuiltInPropagationOptions,
    context: ResourceArc<ContextResource>,
) -> NifResult<Term<'_>> {
    let value = options
        .propagator(initial)?
        .state_transition_matrix_to_with_context(target, &context.0);
    Ok(force_result(
        env,
        value.map(|matrix| matrix.map(|row| row.to_vec()).to_vec()),
    ))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn propagate_state_with_covariance_with_context(
    env: Env<'_>,
    initial: StateTerm,
    covariance: Vec<Vec<f64>>,
    span: f64,
    options: BuiltInPropagationOptions,
    context: ResourceArc<ContextResource>,
) -> NifResult<Term<'_>> {
    let propagator = options.propagator(initial)?;
    let covariance = match crate::covariance_transport::decode_covariance(covariance) {
        Ok(covariance) => covariance,
        Err(reason) => return Ok((rustler::types::atom::error(), reason).encode(env)),
    };
    let result =
        propagator.propagate_state_with_covariance_with_context(covariance, span, &context.0);
    Ok(force_result(
        env,
        result.map(|(state, covariance)| {
            (
                encode_state(state),
                covariance.into_matrix().map(|row| row.to_vec()).to_vec(),
            )
        }),
    ))
}

#[rustler::nif]
fn dense_output_eval(
    env: Env<'_>,
    dense: ResourceArc<DenseOutputResource>,
    epoch: f64,
) -> Term<'_> {
    use crate::errors::{detail_map, encode_result, Refusal};
    rustler::atoms! { empty, output_out_of_range, segment_out_of_range, t, t_min, t_max, t_start, t_end, theta, unknown }
    encode_result(
        env,
        dense.0.eval(epoch).map(encode_state).map_err(|error| {
            let (kind, detail) = match error {
                DenseOutputError::Empty => (empty(), Term::map_new(env)),
                DenseOutputError::OutputOutOfRange {
                    t: epoch,
                    t_min: low,
                    t_max: high,
                } => (
                    output_out_of_range(),
                    detail_map(
                        env,
                        &[
                            (t(), epoch.encode(env)),
                            (t_min(), low.encode(env)),
                            (t_max(), high.encode(env)),
                        ],
                    ),
                ),
                DenseOutputError::SegmentOutOfRange {
                    t: epoch,
                    t_start: start,
                    t_end: end,
                    theta: fraction,
                } => (
                    segment_out_of_range(),
                    detail_map(
                        env,
                        &[
                            (t(), epoch.encode(env)),
                            (t_start(), start.encode(env)),
                            (t_end(), end.encode(env)),
                            (theta(), fraction.encode(env)),
                        ],
                    ),
                ),
                _ => (unknown(), Term::map_new(env)),
            };
            Refusal {
                kind,
                detail,
                message: error.to_string(),
            }
        }),
    )
}

#[rustler::nif]
fn dense_output_coverage(dense: ResourceArc<DenseOutputResource>) -> Option<(f64, f64)> {
    dense.0.coverage_tdb_seconds()
}
