use crate::analytic::{decode_state, encode_state, StateTerm};
use crate::earth_orientation::{
    frame_error, propagation_context, ContextResource, IersProvider, Validity,
};
use crate::errors::{degrade_reason_atom, detail_map, encode_result, Refusal};
use crate::force_models::{propagation_error, ForceInput};
use crate::orbit_determination::{
    geometry_quality as encode_geometry_quality, residual_stats, OrbitResidualStatsTerm,
};
use crate::orbit_scoring::decode_satellite;
use crate::precise_samples::{instant_from_fields, EpochTerm};
use crate::sp3::Sp3Resource;
use crate::space_weather::{table_source, SpaceWeatherPolicyTerm, SpaceWeatherTableResource};
use crate::variational::{Integrator, Options};
use crate::Vec3;
use rustler::{Encoder, Env, NifMap, NifResult, ResourceArc, Term};
use sidereon_core::astro::time::ValidityMode;
use sidereon_core::orbit_determination::{
    self as orbit, InertialPositionSample, OrbitFitError, OrbitParameterCovariance,
    OrbitParameterFitError, OrbitParameterFitOptions, Ut1ProviderRole,
};
use sidereon_core::TdbEarthOrientationProvider;

rustler::atoms! { condition_number, did_not_converge, empty_selection, error, estimated, field, fit, frame, geometry_quality, got, ill_conditioned_normal_equations, infinity, invalid_epoch, invalid_observation, invalid_option, invalid_parameter, iterations, last_step_sigmas, least_squares, limit, mixed_time_scales, name, nan, negative_infinity, non_monotonic_epochs, numerical_failure, orientation, permissive, propagation, provider, provider_mode, quantity, reason, required, rtn_frame, satellite, singular_geometry, singular_normal_equations, source, strict, too_few_samples, unbounded, unobservable_parameter, ut1_outside_coverage, ut1_validity_mismatch, weakest }

fn float_term(env: Env<'_>, value: f64) -> Term<'_> {
    if value.is_finite() {
        value.encode(env)
    } else if value == f64::INFINITY {
        infinity().encode(env)
    } else if value == f64::NEG_INFINITY {
        negative_infinity().encode(env)
    } else {
        nan().encode(env)
    }
}

fn validity_atom(value: ValidityMode) -> rustler::Atom {
    match value {
        ValidityMode::Strict => strict(),
        ValidityMode::Permissive => permissive(),
    }
}

fn provider_role(value: Ut1ProviderRole) -> rustler::Atom {
    match value {
        Ut1ProviderRole::Orientation => orientation(),
        Ut1ProviderRole::Propagation => propagation(),
    }
}
fn orbit_parameter_fit_error(env: Env<'_>, error: OrbitParameterFitError) -> Refusal<'_> {
    let (kind, detail) = match &error {
        OrbitParameterFitError::Fit(value) => (
            fit(),
            detail_map(
                env,
                &[(self::error(), (orbit_fit_error(env, value)).encode(env))],
            ),
        ),
        OrbitParameterFitError::InvalidParameter { name, reason } => (
            invalid_parameter(),
            detail_map(
                env,
                &[
                    (self::name(), (name).encode(env)),
                    (self::reason(), (reason).encode(env)),
                ],
            ),
        ),
        OrbitParameterFitError::UnobservableParameter { satellite, name } => (
            unobservable_parameter(),
            detail_map(
                env,
                &[
                    (self::satellite(), (satellite.to_string()).encode(env)),
                    (self::name(), (name).encode(env)),
                ],
            ),
        ),
        OrbitParameterFitError::SingularNormalEquations {
            satellite,
            condition_number,
            weakest,
        } => (
            singular_normal_equations(),
            detail_map(
                env,
                &[
                    (self::satellite(), (satellite.to_string()).encode(env)),
                    (
                        self::condition_number(),
                        (float_term(env, *condition_number)).encode(env),
                    ),
                    (self::weakest(), (weakest).encode(env)),
                ],
            ),
        ),
        OrbitParameterFitError::IllConditionedNormalEquations {
            satellite,
            condition_number,
            limit,
            weakest,
        } => (
            ill_conditioned_normal_equations(),
            detail_map(
                env,
                &[
                    (self::satellite(), (satellite.to_string()).encode(env)),
                    (
                        self::condition_number(),
                        (float_term(env, *condition_number)).encode(env),
                    ),
                    (self::limit(), (float_term(env, *limit)).encode(env)),
                    (self::weakest(), (weakest).encode(env)),
                ],
            ),
        ),
        OrbitParameterFitError::NumericalFailure {
            satellite,
            quantity,
        } => (
            numerical_failure(),
            detail_map(
                env,
                &[
                    (self::satellite(), (satellite.to_string()).encode(env)),
                    (self::quantity(), (quantity).encode(env)),
                ],
            ),
        ),
        OrbitParameterFitError::DidNotConverge {
            satellite,
            iterations,
            last_step_sigmas,
        } => (
            did_not_converge(),
            detail_map(
                env,
                &[
                    (self::satellite(), (satellite.to_string()).encode(env)),
                    (self::iterations(), (iterations).encode(env)),
                    (
                        self::last_step_sigmas(),
                        (float_term(env, *last_step_sigmas)).encode(env),
                    ),
                ],
            ),
        ),
    };
    Refusal {
        kind,
        detail,
        message: error.to_string(),
    }
}
fn orbit_fit_error<'a>(env: Env<'a>, error: &OrbitFitError) -> Refusal<'a> {
    let (kind, detail) = match error {
        OrbitFitError::EmptySelection => (empty_selection(), detail_map(env, &[])),
        OrbitFitError::InvalidOption { field, reason } => (
            invalid_option(),
            detail_map(
                env,
                &[
                    (self::field(), (field).encode(env)),
                    (self::reason(), (reason).encode(env)),
                ],
            ),
        ),
        OrbitFitError::TooFewSamples {
            satellite,
            got,
            required,
        } => (
            too_few_samples(),
            detail_map(
                env,
                &[
                    (self::satellite(), (satellite.to_string()).encode(env)),
                    (self::got(), (got).encode(env)),
                    (self::required(), (required).encode(env)),
                ],
            ),
        ),
        OrbitFitError::NonMonotonicEpochs { satellite } => (
            non_monotonic_epochs(),
            detail_map(
                env,
                &[(self::satellite(), (satellite.to_string()).encode(env))],
            ),
        ),
        OrbitFitError::MixedTimeScales => (mixed_time_scales(), detail_map(env, &[])),
        OrbitFitError::InvalidEpoch { satellite, reason } => (
            invalid_epoch(),
            detail_map(
                env,
                &[
                    (self::satellite(), (satellite.to_string()).encode(env)),
                    (self::reason(), (reason).encode(env)),
                ],
            ),
        ),
        OrbitFitError::InvalidObservation { satellite, reason } => (
            invalid_observation(),
            detail_map(
                env,
                &[
                    (self::satellite(), (satellite.to_string()).encode(env)),
                    (self::reason(), (reason).encode(env)),
                ],
            ),
        ),
        OrbitFitError::Frame { satellite, source } => (
            frame(),
            detail_map(
                env,
                &[
                    (self::satellite(), (satellite.to_string()).encode(env)),
                    (self::source(), (frame_error(env, *source)).encode(env)),
                ],
            ),
        ),
        OrbitFitError::Propagation { satellite, source } => (
            propagation(),
            detail_map(
                env,
                &[
                    (self::satellite(), (satellite.to_string()).encode(env)),
                    (
                        self::source(),
                        (propagation_error(env, source.clone())).encode(env),
                    ),
                ],
            ),
        ),
        OrbitFitError::LeastSquares { satellite, source } => (
            least_squares(),
            detail_map(
                env,
                &[
                    (self::satellite(), (satellite.to_string()).encode(env)),
                    (self::source(), (source.to_string()).encode(env)),
                ],
            ),
        ),
        OrbitFitError::SingularGeometry {
            satellite,
            geometry_quality,
        } => (
            singular_geometry(),
            detail_map(
                env,
                &[
                    (self::satellite(), (satellite.to_string()).encode(env)),
                    (
                        self::geometry_quality(),
                        (encode_geometry_quality(*geometry_quality)).encode(env),
                    ),
                ],
            ),
        ),
        OrbitFitError::DidNotConverge {
            satellite,
            iterations,
        } => (
            did_not_converge(),
            detail_map(
                env,
                &[
                    (self::satellite(), (satellite.to_string()).encode(env)),
                    (self::iterations(), (iterations).encode(env)),
                ],
            ),
        ),
        OrbitFitError::Ut1OutsideCoverage(value) => (
            ut1_outside_coverage(),
            detail_map(
                env,
                &[(self::reason(), (degrade_reason_atom(*value)).encode(env))],
            ),
        ),
        OrbitFitError::Ut1ValidityMismatch {
            fit,
            provider,
            provider_mode,
        } => (
            ut1_validity_mismatch(),
            detail_map(
                env,
                &[
                    (self::fit(), (validity_atom(*fit)).encode(env)),
                    (self::provider(), (provider_role(*provider)).encode(env)),
                    (
                        self::provider_mode(),
                        (validity_atom(*provider_mode)).encode(env),
                    ),
                ],
            ),
        ),
        OrbitFitError::RtnFrame { satellite, reason } => (
            rtn_frame(),
            detail_map(
                env,
                &[
                    (self::satellite(), (satellite.to_string()).encode(env)),
                    (self::reason(), rtn_reason(env, *reason)),
                ],
            ),
        ),
    };
    Refusal {
        kind,
        detail,
        message: error.to_string(),
    }
}

fn rtn_reason(env: Env<'_>, error: sidereon_core::astro::covariance::RtnFrameError) -> Term<'_> {
    use sidereon_core::astro::covariance::RtnFrameError;
    rustler::atoms! { zero_position, parallel_position_velocity, kind, field, reason, invalid_input }
    match error {
        RtnFrameError::InvalidInput {
            field: label,
            reason: message,
        } => detail_map(
            env,
            &[
                (kind(), invalid_input().encode(env)),
                (field(), label.encode(env)),
                (reason(), message.encode(env)),
            ],
        ),
        RtnFrameError::ZeroPosition => zero_position().encode(env),
        RtnFrameError::ParallelPositionVelocity => parallel_position_velocity().encode(env),
    }
}

#[derive(rustler::NifUnitEnum)]
enum ConditionLimitKind {
    Infinity,
}

#[derive(rustler::NifUntaggedEnum)]
enum ConditionLimit {
    Finite(f64),
    Unbounded(ConditionLimitKind),
}

#[derive(NifMap)]
struct FitOptions {
    forces: Option<Vec<String>>,
    drag: Option<crate::drag::DragParametersTerm>,
    space_weather: Option<ResourceArc<SpaceWeatherTableResource>>,
    space_weather_policy: Option<SpaceWeatherPolicyTerm>,
    additional_forces: Vec<ForceInput>,
    estimated_parameters: Vec<String>,
    integrator: Option<Integrator>,
    integrator_options: Option<Options>,
    propagation_context: Option<ResourceArc<ContextResource>>,
    observation_sigma_m: Option<f64>,
    max_iterations: Option<usize>,
    convergence_threshold: Option<f64>,
    max_condition_number: Option<ConditionLimit>,
    min_ledger_samples: Option<usize>,
}

impl FitOptions {
    fn into_core(self) -> NifResult<OrbitParameterFitOptions> {
        let force_model = self
            .forces
            .as_deref()
            .map(crate::propagation::force_model_kind)
            .transpose()?;
        let drag = self
            .drag
            .map(crate::drag::DragParametersTerm::decode_with_reason)
            .transpose()?;
        let space_weather = self
            .space_weather
            .map(|table| table_source(&table, self.space_weather_policy));
        let mut options = OrbitParameterFitOptions::default();
        options.force_model = force_model.unwrap_or(options.force_model);
        if let Some(limit) = self.max_condition_number {
            options.max_condition_number = match limit {
                ConditionLimit::Finite(value) => value,
                ConditionLimit::Unbounded(ConditionLimitKind::Infinity) => f64::INFINITY,
            };
        }
        options.drag = drag;
        options.space_weather = space_weather;
        options.additional_forces = self
            .additional_forces
            .into_iter()
            .map(ForceInput::into_force)
            .collect();
        options.estimated_parameters = self.estimated_parameters;
        options.integrator = self
            .integrator
            .map(Into::into)
            .unwrap_or(options.integrator);
        options.integrator_options = self
            .integrator_options
            .map(Into::into)
            .unwrap_or(options.integrator_options);
        if self.propagation_context.is_some() {
            options.propagation_context = propagation_context(self.propagation_context);
        }
        options.observation_sigma_m = self
            .observation_sigma_m
            .unwrap_or(options.observation_sigma_m);
        options.max_iterations = self.max_iterations.unwrap_or(options.max_iterations);
        options.convergence_threshold = self
            .convergence_threshold
            .unwrap_or(options.convergence_threshold);
        options.min_ledger_samples = self
            .min_ledger_samples
            .unwrap_or(options.min_ledger_samples);
        Ok(options)
    }
}

#[derive(NifMap)]
#[rustler(decode)]
struct Sample {
    epoch: EpochTerm,
    position_gcrf_m: Vec3,
}

impl TryFrom<Sample> for InertialPositionSample {
    type Error = rustler::Error;

    fn try_from(value: Sample) -> NifResult<Self> {
        Ok(Self {
            epoch: instant_from_fields(value.epoch)?,
            position_gcrf_m: value.position_gcrf_m.into(),
        })
    }
}

#[derive(NifMap)]
#[rustler(encode)]
struct EstimatedParameter {
    name: String,
    initial_value: f64,
    value: f64,
}

impl From<&orbit::EstimatedForceParameter> for EstimatedParameter {
    fn from(parameter: &orbit::EstimatedForceParameter) -> Self {
        Self {
            name: parameter.name.clone(),
            initial_value: parameter.initial_value,
            value: parameter.value,
        }
    }
}

#[derive(NifMap)]
#[rustler(encode)]
struct Residual {
    epoch_tdb_j2000_s: f64,
    elapsed_tt_s: f64,
    radial_m: f64,
    along_m: f64,
    cross_m: f64,
}

#[derive(NifMap)]
#[rustler(encode)]
struct Covariance {
    kind: rustler::Atom,
    matrix: Option<Vec<Vec<f64>>>,
    correlation: Option<Vec<Vec<f64>>>,
    variance_factor: Option<f64>,
    degrees_of_freedom: Option<usize>,
}

impl From<OrbitParameterCovariance> for Covariance {
    fn from(value: OrbitParameterCovariance) -> Self {
        match value {
            OrbitParameterCovariance::Estimated {
                matrix,
                correlation,
                variance_factor,
                degrees_of_freedom,
            } => Self {
                kind: estimated(),
                matrix: Some(
                    matrix
                        .row_iter()
                        .map(|row| row.iter().copied().collect())
                        .collect(),
                ),
                correlation: Some(
                    correlation
                        .row_iter()
                        .map(|row| row.iter().copied().collect())
                        .collect(),
                ),
                variance_factor: Some(variance_factor),
                degrees_of_freedom: Some(degrees_of_freedom),
            },
            OrbitParameterCovariance::Unbounded => Self {
                kind: unbounded(),
                matrix: None,
                correlation: None,
                variance_factor: None,
                degrees_of_freedom: None,
            },
        }
    }
}

#[derive(NifMap)]
#[rustler(encode)]
struct Fit {
    satellite: String,
    initial_state: StateTerm,
    force_parameters: Vec<EstimatedParameter>,
    parameter_names: Vec<String>,
    covariance: Covariance,
    residuals: Vec<Residual>,
    residual_stats: OrbitResidualStatsTerm,
    seed_rms_3d_m: f64,
    iterations: usize,
    condition_number: f64,
    sigmas: Vec<Option<f64>>,
    named_correlations: Vec<Vec<Option<f64>>>,
    named_force_parameters: Vec<EstimatedParameter>,
}

impl From<orbit::OrbitParameterFit> for Fit {
    fn from(value: orbit::OrbitParameterFit) -> Self {
        let sigmas = value
            .parameter_names
            .iter()
            .map(|name| value.sigma(name))
            .collect();
        let named_correlations = value
            .parameter_names
            .iter()
            .map(|first| {
                value
                    .parameter_names
                    .iter()
                    .map(|second| value.correlation(first, second))
                    .collect()
            })
            .collect();
        let named_force_parameters = value
            .force_parameters
            .iter()
            .filter_map(|parameter| value.force_parameter(&parameter.name))
            .map(EstimatedParameter::from)
            .collect();
        Self {
            satellite: value.satellite.to_string(),
            initial_state: encode_state(value.initial_state),
            force_parameters: value
                .force_parameters
                .into_iter()
                .map(|parameter| EstimatedParameter::from(&parameter))
                .collect(),
            parameter_names: value.parameter_names,
            covariance: value.covariance.into(),
            residuals: value
                .residuals
                .into_iter()
                .map(|residual| Residual {
                    epoch_tdb_j2000_s: residual.epoch_tdb_j2000_s,
                    elapsed_tt_s: residual.elapsed_tt_s,
                    radial_m: residual.radial_m,
                    along_m: residual.along_m,
                    cross_m: residual.cross_m,
                })
                .collect(),
            residual_stats: residual_stats(value.residual_stats),
            seed_rms_3d_m: value.seed_rms_3d_m,
            iterations: value.iterations,
            condition_number: value.condition_number,
            sigmas,
            named_correlations,
            named_force_parameters,
        }
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn fit_inertial_orbit_parameters<'a>(
    env: Env<'a>,
    samples: Vec<Sample>,
    satellite: (String, String),
    seed: Option<StateTerm>,
    options: FitOptions,
    mode: Validity,
) -> NifResult<Term<'a>> {
    let satellite = decode_satellite(satellite)?;
    let mode = mode.into();
    let options = options.into_core()?;
    let samples = samples
        .into_iter()
        .map(InertialPositionSample::try_from)
        .collect::<NifResult<Vec<_>>>()?;
    let fit = orbit::fit_inertial_orbit_parameters_with_validity(
        &samples,
        satellite,
        seed.map(decode_state),
        &options,
        mode,
    );
    Ok(encode_result(
        env,
        fit.map(|value| {
            (
                Fit::from(value.value),
                value.degraded.map(degrade_reason_atom),
            )
        })
        .map_err(|error| orbit_parameter_fit_error(env, error)),
    ))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn fit_sp3_ecef_orbit_parameters<'a>(
    env: Env<'a>,
    product: ResourceArc<Sp3Resource>,
    satellite: (String, String),
    seed: Option<StateTerm>,
    options: FitOptions,
    mode: Validity,
    orientation_provider: Option<ResourceArc<IersProvider>>,
) -> NifResult<Term<'a>> {
    let satellite = decode_satellite(satellite)?;
    let mode = mode.into();
    let options = options.into_core()?;
    let builtin = TdbEarthOrientationProvider::new().with_validity(mode);
    let orientation: &dyn sidereon_core::astro::frames::EarthOrientationProvider =
        match &orientation_provider {
            Some(provider) => provider.0.as_ref(),
            None => &builtin,
        };
    let fit = orbit::fit_sp3_ecef_orbit_parameters_with_validity(
        &product.sp3,
        satellite,
        orientation,
        seed.map(decode_state),
        &options,
        mode,
    );
    Ok(encode_result(
        env,
        fit.map(|value| {
            (
                Fit::from(value.value),
                value.degraded.map(degrade_reason_atom),
            )
        })
        .map_err(|error| orbit_parameter_fit_error(env, error)),
    ))
}

#[rustler::nif]
fn orbit_fit_state_parameter_names() -> Vec<&'static str> {
    orbit::STATE_PARAMETER_NAMES.to_vec()
}
