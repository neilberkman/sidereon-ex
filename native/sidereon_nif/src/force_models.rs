use std::sync::Arc;

use crate::analytic::{decode_state, StateTerm};
use crate::earth_orientation::{propagation_context, ContextResource};
use crate::errors::{self, detail_map, encode_result, Refusal};
use crate::{vector_tuple, Vec3};
use nalgebra::{Matrix3, Vector3};
use rustler::{Encoder, Env, NifMap, NifResult, NifUnitEnum, ResourceArc, Term};
use sidereon_core::astro::error::PropagationError;
use sidereon_core::astro::events::eclipse::{EarthShadowModel, ShadowFunction};
use sidereon_core::astro::forces::{
    AccelerationPartials, CompositeForceModel, EarthRadiationPressure, Ecom1Coefficients,
    Ecom1SolarRadiationPressure, Ecom2D2b1Coefficients, Ecom2D4b1Coefficients,
    Ecom2SolarRadiationPressure, EmpiricalHarmonic, EmpiricalRtnAcceleration, ForceModel,
    ForceParameter, J2Gravity, RtnAxis, SchwarzschildRelativity, SolarRadiationPressure,
    SolidEarthPoleTideGravity, SolidEarthTideGravity, ThirdBodyGravity, ZonalGravity,
};
use sidereon_core::astro::propagator::{ForceModelComponents, ForceModelKind};

#[derive(NifMap)]
#[rustler(encode)]
struct ErrorMessage<'a> {
    reason: &'a str,
}

#[derive(NifMap)]
#[rustler(encode)]
struct Ut1Error {
    reason: rustler::Atom,
}

rustler::atoms! {
    invalid_input,
    numerical_failure,
    max_steps_exceeded,
    event_failure,
    force_model_failure,
    ut1_outside_coverage,
    moon_eclipse_enabled,
}

pub(crate) fn propagation_error(env: Env<'_>, error: PropagationError) -> Refusal<'_> {
    let (kind, detail) = match &error {
        PropagationError::InvalidInput(reason) => {
            (invalid_input(), ErrorMessage { reason }.encode(env))
        }
        PropagationError::NumericalFailure(reason) => {
            (numerical_failure(), ErrorMessage { reason }.encode(env))
        }
        PropagationError::MaxStepsExceeded => (max_steps_exceeded(), Term::map_new(env)),
        PropagationError::EventFailure(reason) => {
            (event_failure(), ErrorMessage { reason }.encode(env))
        }
        PropagationError::ForceModelFailure(reason) => {
            (force_model_failure(), ErrorMessage { reason }.encode(env))
        }
        PropagationError::Ut1OutsideCoverage(reason) => (
            ut1_outside_coverage(),
            Ut1Error {
                reason: errors::degrade_reason_atom(*reason),
            }
            .encode(env),
        ),
    };
    Refusal {
        kind,
        detail,
        message: error.to_string(),
    }
}

struct PropagationRefusal(PropagationError);

impl Encoder for PropagationRefusal {
    fn encode<'a>(&self, env: Env<'a>) -> Term<'a> {
        propagation_error(env, self.0.clone()).encode(env)
    }
}

pub(crate) fn propagation_refusal(error: PropagationError) -> rustler::Error {
    rustler::Error::Term(Box::new(PropagationRefusal(error)))
}

pub(crate) fn force_result<'a>(
    env: Env<'a>,
    value: Result<impl Encoder, PropagationError>,
) -> Term<'a> {
    encode_result(env, value.map_err(|error| propagation_error(env, error)))
}

#[derive(NifUnitEnum)]
pub(crate) enum Shadow {
    ApparentDisc,
    Conical,
}

impl From<Shadow> for ShadowFunction {
    fn from(value: Shadow) -> Self {
        match value {
            Shadow::ApparentDisc => Self::ApparentDisc,
            Shadow::Conical => Self::Conical,
        }
    }
}

#[derive(NifUnitEnum)]
pub(crate) enum Earth {
    Spherical,
    Wgs84Oblate,
}

impl From<Earth> for EarthShadowModel {
    fn from(value: Earth) -> Self {
        match value {
            Earth::Spherical => Self::Spherical,
            Earth::Wgs84Oblate => Self::Wgs84Oblate,
        }
    }
}

#[derive(NifMap)]
struct Occultation {
    shadow_function: Option<Shadow>,
    earth_shadow_model: Option<Earth>,
    moon_eclipse_enabled: Option<bool>,
}

#[derive(rustler::NifTaggedEnum)]
enum OccultationChange {
    Defaults,
    ShadowFunction(Shadow),
    MoonEclipse(bool),
}

fn shadow_function(value: ShadowFunction) -> NifResult<Shadow> {
    match value {
        ShadowFunction::ApparentDisc => Ok(Shadow::ApparentDisc),
        ShadowFunction::Conical => Ok(Shadow::Conical),
        _ => Err(rustler::Error::BadArg),
    }
}

fn earth_shadow_model(value: EarthShadowModel) -> Earth {
    match value {
        EarthShadowModel::Spherical => Earth::Spherical,
        EarthShadowModel::Wgs84Oblate => Earth::Wgs84Oblate,
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn force_update_occultation(
    env: Env<'_>,
    description: ForceDescription,
    change: OccultationChange,
) -> NifResult<Term<'_>> {
    macro_rules! updated {
        ($result:expr) => {
            match $result {
                Ok(model) => {
                    let model = match change {
                        OccultationChange::Defaults => model,
                        OccultationChange::ShadowFunction(function) => {
                            model.with_shadow_function(function.into())
                        }
                        OccultationChange::MoonEclipse(enabled) => model.with_moon_eclipse(enabled),
                    };
                    Ok(force_result(
                        env,
                        Ok(Occultation {
                            shadow_function: Some(shadow_function(model.shadow_function())?),
                            moon_eclipse_enabled: Some(model.moon_eclipse_enabled()),
                            earth_shadow_model: Some(earth_shadow_model(
                                model.earth_shadow_model(),
                            )),
                        }),
                    ))
                }
                Err(error) => Ok(force_result(env, Err::<(), _>(error))),
            }
        };
    }
    match description {
        ForceDescription::Ecom1(coefficients, options) => updated!(ecom1(coefficients, options)),
        ForceDescription::Ecom2(n_d, n_b, coefficients, options) => {
            updated!(ecom2(n_d, n_b, coefficients, options))
        }
        ForceDescription::SolarRadiationPressure(cr, area, options) => {
            updated!(solar(cr, area, options))
        }
        ForceDescription::EarthRadiationPressure(cr, area, moon) => Ok(force_result(
            env,
            earth_radiation(cr, area, moon).map(|model| {
                detail_map(
                    env,
                    &[(
                        moon_eclipse_enabled(),
                        model.moon_eclipse_enabled().encode(env),
                    )],
                )
            }),
        )),
        _ => Err(rustler::Error::BadArg),
    }
}

#[derive(NifUnitEnum, Copy, Clone)]
enum Axis {
    Radial,
    AlongTrack,
    CrossTrack,
}

#[derive(NifUnitEnum, Copy, Clone)]
enum Harmonic {
    Constant,
    Cosine,
    Sine,
}

impl From<Axis> for RtnAxis {
    fn from(axis: Axis) -> Self {
        match axis {
            Axis::Radial => Self::Radial,
            Axis::AlongTrack => Self::AlongTrack,
            Axis::CrossTrack => Self::CrossTrack,
        }
    }
}

impl From<Harmonic> for EmpiricalHarmonic {
    fn from(harmonic: Harmonic) -> Self {
        match harmonic {
            Harmonic::Constant => Self::Constant,
            Harmonic::Cosine => Self::Cosine,
            Harmonic::Sine => Self::Sine,
        }
    }
}

#[derive(rustler::NifTaggedEnum)]
enum ForceDescription {
    Ecom1(Vec<f64>, Occultation),
    Ecom2(usize, usize, Vec<f64>, Occultation),
    EmpiricalRtn(Vec<(Axis, Harmonic, f64)>),
    SolarRadiationPressure(f64, f64, Occultation),
    EarthRadiationPressure(f64, f64, Option<bool>),
}

pub(crate) struct ForceResource(pub Arc<dyn ForceModel>);

#[rustler::resource_impl]
impl rustler::Resource for ForceResource {}

#[derive(rustler::NifUntaggedEnum)]
pub(crate) enum ForceInput {
    Resource(ResourceArc<ForceResource>),
    HarmonicGravity(ResourceArc<crate::gravity_field::HarmonicGravity>),
}

#[derive(NifUnitEnum)]
pub(crate) enum BuiltIn {
    TwoBody,
    J2,
    Zonal,
    ThirdBody,
    Sun,
    Moon,
    Relativity,
    SolidEarthTide,
    SolidEarthPoleTide,
}

impl ForceInput {
    pub(crate) fn into_force(self) -> Arc<dyn ForceModel> {
        match self {
            Self::Resource(handle) => handle.0.clone(),
            Self::HarmonicGravity(model) => model.0.clone(),
        }
    }
}

#[rustler::nif]
fn force_builtin_model(env: Env<'_>, model: BuiltIn) -> Term<'_> {
    let empty = ForceModelComponents::EMPTY;
    let model = match model {
        BuiltIn::TwoBody => ForceModelKind::two_body(),
        BuiltIn::J2 => {
            // ForceModelKind has a combined central-plus-J2 model. Standalone
            // J2 is a perturbation and retains its own parameter interface.
            let force = ForceResource(Arc::new(J2Gravity::default()));
            return force_result(env, Ok(ResourceArc::new(force)));
        }
        BuiltIn::Zonal => {
            ForceModelKind::composite(empty.with_zonal(ZonalGravity::earth_j2_through_j6()))
        }
        BuiltIn::ThirdBody => {
            ForceModelKind::composite(empty.with_third_body(ThirdBodyGravity::default()))
        }
        BuiltIn::Sun => ForceModelKind::composite(empty.with_third_body(ThirdBodyGravity::sun())),
        BuiltIn::Moon => ForceModelKind::composite(empty.with_third_body(ThirdBodyGravity::moon())),
        BuiltIn::Relativity => {
            ForceModelKind::composite(empty.with_relativity(SchwarzschildRelativity::default()))
        }
        BuiltIn::SolidEarthTide => {
            ForceModelKind::composite(empty.with_solid_earth_tide(SolidEarthTideGravity::default()))
        }
        BuiltIn::SolidEarthPoleTide => ForceModelKind::composite(
            empty.with_solid_earth_pole_tide(SolidEarthPoleTideGravity::default()),
        ),
    };
    force_result(
        env,
        model
            .build()
            .map(|model| ResourceArc::new(ForceResource(Arc::from(model)))),
    )
}

macro_rules! with_occultation {
    ($model:expr, $options:expr) => {{
        let mut model = $model;
        let options = $options;
        if let Some(enabled) = options.moon_eclipse_enabled {
            model = model.with_moon_eclipse(enabled);
        }
        if let Some(shadow) = options.shadow_function {
            model = model.with_shadow_function(shadow.into());
        }
        if let Some(earth) = options.earth_shadow_model {
            model = model.with_earth_shadow_model(earth.into());
        }
        model
    }};
}

fn earth_radiation(
    cr: f64,
    area: f64,
    moon: Option<bool>,
) -> Result<EarthRadiationPressure, PropagationError> {
    let model = EarthRadiationPressure::new(cr, area)?;
    Ok(match moon {
        Some(enabled) => model.with_moon_eclipse(enabled),
        None => model,
    })
}

fn ecom1(
    coefficients: Vec<f64>,
    options: Occultation,
) -> Result<Ecom1SolarRadiationPressure, PropagationError> {
    let coefficients = coefficients.try_into().map_err(|values: Vec<f64>| {
        PropagationError::InvalidInput(format!(
            "ECOM1 requires nine coefficients, received {}",
            values.len()
        ))
    })?;
    Ok(with_occultation!(
        Ecom1SolarRadiationPressure::new(Ecom1Coefficients::from_array(coefficients))?,
        options
    ))
}

fn ecom2(
    n_d: usize,
    n_b: usize,
    coefficients: Vec<f64>,
    options: Occultation,
) -> Result<Ecom2SolarRadiationPressure, PropagationError> {
    Ok(with_occultation!(
        Ecom2SolarRadiationPressure::new(n_d, n_b, coefficients)?,
        options
    ))
}

fn empirical(
    terms: Vec<(Axis, Harmonic, f64)>,
) -> Result<EmpiricalRtnAcceleration, PropagationError> {
    terms.into_iter().try_fold(
        EmpiricalRtnAcceleration::new(),
        |model, (axis, harmonic, value)| model.with_term(axis.into(), harmonic.into(), value),
    )
}

fn solar(
    cr: f64,
    area: f64,
    options: Occultation,
) -> Result<SolarRadiationPressure, PropagationError> {
    Ok(with_occultation!(
        SolarRadiationPressure::new(cr, area)?,
        options
    ))
}

impl ForceDescription {
    fn into_force(self) -> Result<Arc<dyn ForceModel>, PropagationError> {
        Ok(match self {
            Self::Ecom1(values, options) => Arc::new(ecom1(values, options)?),
            Self::Ecom2(n_d, n_b, values, options) => Arc::new(ecom2(n_d, n_b, values, options)?),
            Self::EmpiricalRtn(terms) => Arc::new(empirical(terms)?),
            Self::SolarRadiationPressure(cr, area, options) => Arc::new(solar(cr, area, options)?),
            Self::EarthRadiationPressure(cr, area, moon) => {
                Arc::new(earth_radiation(cr, area, moon)?)
            }
        })
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn force_model_new(env: Env<'_>, description: ForceDescription) -> Term<'_> {
    force_result(
        env,
        description
            .into_force()
            .map(ForceResource)
            .map(ResourceArc::new),
    )
}

#[rustler::nif]
fn force_composite(env: Env<'_>, models: Vec<ForceInput>) -> Term<'_> {
    let mut composite = CompositeForceModel::new();
    for model in models {
        composite.add(Box::new(model.into_force()));
    }
    ResourceArc::new(ForceResource(Arc::new(composite))).encode(env)
}

#[derive(NifMap)]
#[rustler(encode)]
struct Parameter {
    name: String,
    value: f64,
}

impl From<ForceParameter> for Parameter {
    fn from(parameter: ForceParameter) -> Self {
        Self {
            name: parameter.name,
            value: parameter.value,
        }
    }
}

#[derive(NifMap)]
#[rustler(encode)]
struct Partials {
    wrt_position: Vec<Vec3>,
    wrt_velocity: Vec<Vec3>,
}

fn matrix_rows(matrix: Matrix3<f64>) -> Vec<Vec3> {
    (0..3)
        .map(|row| (matrix[(row, 0)], matrix[(row, 1)], matrix[(row, 2)]))
        .collect()
}

impl From<AccelerationPartials> for Partials {
    fn from(partials: AccelerationPartials) -> Self {
        Self {
            wrt_position: matrix_rows(partials.wrt_position),
            wrt_velocity: matrix_rows(partials.wrt_velocity),
        }
    }
}

#[rustler::nif]
fn force_parameters(model: ForceInput) -> Vec<Parameter> {
    model
        .into_force()
        .parameters()
        .into_iter()
        .map(Parameter::from)
        .collect()
}

#[rustler::nif]
fn force_parameter_count(model: ForceInput) -> usize {
    model.into_force().parameter_count()
}

#[rustler::nif(schedule = "DirtyCpu")]
fn force_acceleration(
    env: Env<'_>,
    model: ForceInput,
    state: StateTerm,
    de: Option<ResourceArc<ContextResource>>,
) -> Term<'_> {
    force_result(
        env,
        model
            .into_force()
            .acceleration(&decode_state(state), &propagation_context(de))
            .map(encode_vector),
    )
}

fn encode_vector(vector: Vector3<f64>) -> Vec3 {
    vector_tuple(vector.into())
}

#[rustler::nif(schedule = "DirtyCpu")]
fn force_acceleration_with_parameters(
    env: Env<'_>,
    model: ForceInput,
    parameters: Vec<f64>,
    state: StateTerm,
    de: Option<ResourceArc<ContextResource>>,
) -> Term<'_> {
    force_result(
        env,
        model
            .into_force()
            .acceleration_with_parameters(
                &parameters,
                &decode_state(state),
                &propagation_context(de),
            )
            .map(encode_vector),
    )
}

#[rustler::nif(schedule = "DirtyCpu")]
fn force_acceleration_partials(
    env: Env<'_>,
    model: ForceInput,
    parameters: Vec<f64>,
    state: StateTerm,
    de: Option<ResourceArc<ContextResource>>,
) -> Term<'_> {
    force_result(
        env,
        model
            .into_force()
            .acceleration_partials(&parameters, &decode_state(state), &propagation_context(de))
            .map(Partials::from),
    )
}

#[rustler::nif(schedule = "DirtyCpu")]
fn force_parameter_partials(
    env: Env<'_>,
    model: ForceInput,
    parameters: Vec<f64>,
    state: StateTerm,
    de: Option<ResourceArc<ContextResource>>,
) -> Term<'_> {
    force_result(
        env,
        model
            .into_force()
            .parameter_partials(&parameters, &decode_state(state), &propagation_context(de))
            .map(|values| values.into_iter().map(encode_vector).collect::<Vec<_>>()),
    )
}

#[rustler::nif]
fn force_ecom2_coefficient_count(n_d: usize, n_b: usize) -> Option<usize> {
    Ecom2SolarRadiationPressure::coefficient_count(n_d, n_b)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn force_ecom2_parameter_names(env: Env<'_>, n_d: usize, n_b: usize) -> Term<'_> {
    force_result(env, Ecom2SolarRadiationPressure::parameter_names(n_d, n_b))
}

#[rustler::nif]
fn force_partials_zeros() -> Partials {
    AccelerationPartials::zeros().into()
}

#[rustler::nif]
fn force_partials_position_only((a, b, c): (Vec3, Vec3, Vec3)) -> Partials {
    let matrix = Matrix3::new(a.0, a.1, a.2, b.0, b.1, b.2, c.0, c.1, c.2);
    AccelerationPartials::position_only(matrix).into()
}

#[rustler::nif]
fn force_empirical_parameter_name(axis: Axis, harmonic: Harmonic) -> String {
    EmpiricalRtnAcceleration::parameter_name(axis.into(), harmonic.into()).to_string()
}

fn axis_term(axis: RtnAxis) -> NifResult<Axis> {
    match axis {
        RtnAxis::Radial => Ok(Axis::Radial),
        RtnAxis::AlongTrack => Ok(Axis::AlongTrack),
        RtnAxis::CrossTrack => Ok(Axis::CrossTrack),
    }
}

fn harmonic_term(harmonic: EmpiricalHarmonic) -> NifResult<Harmonic> {
    match harmonic {
        EmpiricalHarmonic::Constant => Ok(Harmonic::Constant),
        EmpiricalHarmonic::Cosine => Ok(Harmonic::Cosine),
        EmpiricalHarmonic::Sine => Ok(Harmonic::Sine),
    }
}

type EmpiricalTerms = Vec<(Axis, Harmonic, f64)>;

fn empirical_terms(model: EmpiricalRtnAcceleration) -> NifResult<EmpiricalTerms> {
    model
        .terms()
        .into_iter()
        .map(|(axis, harmonic, value)| Ok((axis_term(axis)?, harmonic_term(harmonic)?, value)))
        .collect()
}

#[rustler::nif]
fn force_empirical_constant_terms() -> NifResult<EmpiricalTerms> {
    empirical_terms(EmpiricalRtnAcceleration::constant_terms())
}

#[rustler::nif]
fn force_empirical_all_terms() -> NifResult<EmpiricalTerms> {
    empirical_terms(EmpiricalRtnAcceleration::all_terms())
}

#[rustler::nif]
fn force_empirical_with_zero_terms(terms: Vec<(Axis, Harmonic)>) -> NifResult<EmpiricalTerms> {
    let terms = terms
        .into_iter()
        .map(|(axis, harmonic)| (axis.into(), harmonic.into()))
        .collect::<Vec<_>>();
    empirical_terms(EmpiricalRtnAcceleration::with_zero_terms(&terms))
}

#[rustler::nif]
fn force_empirical_with_term(
    env: Env<'_>,
    terms: EmpiricalTerms,
    axis: Axis,
    harmonic: Harmonic,
    value: f64,
) -> NifResult<Term<'_>> {
    let updated =
        empirical(terms).and_then(|model| model.with_term(axis.into(), harmonic.into(), value));
    Ok(match updated {
        Ok(model) => force_result(env, Ok(empirical_terms(model)?)),
        Err(error) => force_result(env, Err::<(), _>(error)),
    })
}

#[rustler::nif]
fn force_empirical_coefficient(
    env: Env<'_>,
    terms: EmpiricalTerms,
    axis: Axis,
    harmonic: Harmonic,
) -> Term<'_> {
    force_result(
        env,
        empirical(terms).map(|model| model.coefficient_km_s2(axis.into(), harmonic.into())),
    )
}

#[derive(NifMap)]
struct Ecom1CoefficientsTerm {
    d0: f64,
    dc: f64,
    ds: f64,
    y0: f64,
    yc: f64,
    ys: f64,
    b0: f64,
    bc: f64,
    bs: f64,
}

#[rustler::nif]
fn force_ecom1_coefficients_from_array(values: Vec<f64>) -> NifResult<Ecom1CoefficientsTerm> {
    let values = values.try_into().map_err(|_| rustler::Error::BadArg)?;
    let Ecom1Coefficients {
        d0,
        dc,
        ds,
        y0,
        yc,
        ys,
        b0,
        bc,
        bs,
    } = Ecom1Coefficients::from_array(values);
    Ok(Ecom1CoefficientsTerm {
        d0,
        dc,
        ds,
        y0,
        yc,
        ys,
        b0,
        bc,
        bs,
    })
}

#[rustler::nif]
fn force_ecom1_coefficients_to_array(
    Ecom1CoefficientsTerm {
        d0,
        dc,
        ds,
        y0,
        yc,
        ys,
        b0,
        bc,
        bs,
    }: Ecom1CoefficientsTerm,
) -> Vec<f64> {
    Ecom1Coefficients {
        d0,
        dc,
        ds,
        y0,
        yc,
        ys,
        b0,
        bc,
        bs,
    }
    .to_array()
    .to_vec()
}

#[rustler::nif]
fn force_ecom1_coefficients_names() -> Vec<&'static str> {
    Ecom1Coefficients::NAMES.to_vec()
}

#[rustler::nif]
fn force_ecom1_coefficients_parameter_names() -> Vec<&'static str> {
    Ecom1Coefficients::PARAMETER_NAMES.to_vec()
}

#[derive(NifMap)]
struct Ecom2D2b1CoefficientsTerm {
    b0: f64,
    b1c: f64,
    b1s: f64,
    d0: f64,
    d2c: f64,
    d2s: f64,
    y0: f64,
}

#[rustler::nif]
fn force_ecom2_d2b1_coefficients_from_array(
    values: Vec<f64>,
) -> NifResult<Ecom2D2b1CoefficientsTerm> {
    let values = values.try_into().map_err(|_| rustler::Error::BadArg)?;
    let Ecom2D2b1Coefficients {
        b0,
        b1c,
        b1s,
        d0,
        d2c,
        d2s,
        y0,
    } = Ecom2D2b1Coefficients::from_array(values);
    Ok(Ecom2D2b1CoefficientsTerm {
        b0,
        b1c,
        b1s,
        d0,
        d2c,
        d2s,
        y0,
    })
}

#[rustler::nif]
fn force_ecom2_d2b1_coefficients_to_array(
    Ecom2D2b1CoefficientsTerm {
        b0,
        b1c,
        b1s,
        d0,
        d2c,
        d2s,
        y0,
    }: Ecom2D2b1CoefficientsTerm,
) -> Vec<f64> {
    Ecom2D2b1Coefficients {
        b0,
        b1c,
        b1s,
        d0,
        d2c,
        d2s,
        y0,
    }
    .to_array()
    .to_vec()
}

#[rustler::nif]
fn force_ecom2_d2b1_coefficients_names() -> Vec<&'static str> {
    Ecom2D2b1Coefficients::NAMES.to_vec()
}

#[rustler::nif]
fn force_ecom2_d2b1_coefficients_parameter_names() -> Vec<&'static str> {
    Ecom2D2b1Coefficients::PARAMETER_NAMES.to_vec()
}

#[derive(NifMap)]
struct Ecom2D4b1CoefficientsTerm {
    b0: f64,
    b1c: f64,
    b1s: f64,
    d0: f64,
    d2c: f64,
    d4c: f64,
    d2s: f64,
    d4s: f64,
    y0: f64,
}

#[rustler::nif]
fn force_ecom2_d4b1_coefficients_from_array(
    values: Vec<f64>,
) -> NifResult<Ecom2D4b1CoefficientsTerm> {
    let values = values.try_into().map_err(|_| rustler::Error::BadArg)?;
    let Ecom2D4b1Coefficients {
        b0,
        b1c,
        b1s,
        d0,
        d2c,
        d4c,
        d2s,
        d4s,
        y0,
    } = Ecom2D4b1Coefficients::from_array(values);
    Ok(Ecom2D4b1CoefficientsTerm {
        b0,
        b1c,
        b1s,
        d0,
        d2c,
        d4c,
        d2s,
        d4s,
        y0,
    })
}

#[rustler::nif]
fn force_ecom2_d4b1_coefficients_to_array(
    Ecom2D4b1CoefficientsTerm {
        b0,
        b1c,
        b1s,
        d0,
        d2c,
        d4c,
        d2s,
        d4s,
        y0,
    }: Ecom2D4b1CoefficientsTerm,
) -> Vec<f64> {
    Ecom2D4b1Coefficients {
        b0,
        b1c,
        b1s,
        d0,
        d2c,
        d4c,
        d2s,
        d4s,
        y0,
    }
    .to_array()
    .to_vec()
}

#[rustler::nif]
fn force_ecom2_d4b1_coefficients_names() -> Vec<&'static str> {
    Ecom2D4b1Coefficients::NAMES.to_vec()
}

#[rustler::nif]
fn force_ecom2_d4b1_coefficients_parameter_names() -> Vec<&'static str> {
    Ecom2D4b1Coefficients::PARAMETER_NAMES.to_vec()
}

#[rustler::nif(schedule = "DirtyCpu")]
fn force_ecom1_acceleration_with_sun(
    env: Env<'_>,
    description: ForceDescription,
    position: Vec3,
    velocity: Vec3,
    sun: Vec3,
) -> NifResult<Term<'_>> {
    let ForceDescription::Ecom1(coefficients, options) = description else {
        return Err(rustler::Error::BadArg);
    };
    let value = ecom1(coefficients, options)
        .and_then(|model| {
            model.acceleration_with_sun(vector(position), vector(velocity), vector(sun))
        })
        .map(encode_vector);
    Ok(force_result(env, value))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn force_ecom1_acceleration_partials_with_sun(
    env: Env<'_>,
    description: ForceDescription,
    position: Vec3,
    velocity: Vec3,
    sun: Vec3,
) -> NifResult<Term<'_>> {
    let ForceDescription::Ecom1(coefficients, options) = description else {
        return Err(rustler::Error::BadArg);
    };
    let value = ecom1(coefficients, options)
        .and_then(|model| {
            model.acceleration_partials_with_sun(vector(position), vector(velocity), vector(sun))
        })
        .map(Partials::from);
    Ok(force_result(env, value))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn force_ecom1_parameter_partials_with_sun(
    env: Env<'_>,
    description: ForceDescription,
    position: Vec3,
    velocity: Vec3,
    sun: Vec3,
) -> NifResult<Term<'_>> {
    let ForceDescription::Ecom1(coefficients, options) = description else {
        return Err(rustler::Error::BadArg);
    };
    let value = ecom1(coefficients, options)
        .and_then(|model| {
            model.parameter_partials_with_sun(vector(position), vector(velocity), vector(sun))
        })
        .map(|values| values.into_iter().map(encode_vector).collect::<Vec<_>>());
    Ok(force_result(env, value))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn force_ecom1_acceleration_with_sun_moon(
    env: Env<'_>,
    description: ForceDescription,
    position: Vec3,
    velocity: Vec3,
    sun: Vec3,
    moon: Vec3,
) -> NifResult<Term<'_>> {
    let ForceDescription::Ecom1(coefficients, options) = description else {
        return Err(rustler::Error::BadArg);
    };
    let value = ecom1(coefficients, options)
        .and_then(|model| {
            model.acceleration_with_sun_moon(
                vector(position),
                vector(velocity),
                vector(sun),
                vector(moon),
            )
        })
        .map(encode_vector);
    Ok(force_result(env, value))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn force_ecom1_acceleration_partials_with_sun_moon(
    env: Env<'_>,
    description: ForceDescription,
    position: Vec3,
    velocity: Vec3,
    sun: Vec3,
    moon: Vec3,
) -> NifResult<Term<'_>> {
    let ForceDescription::Ecom1(coefficients, options) = description else {
        return Err(rustler::Error::BadArg);
    };
    let value = ecom1(coefficients, options)
        .and_then(|model| {
            model.acceleration_partials_with_sun_moon(
                vector(position),
                vector(velocity),
                vector(sun),
                vector(moon),
            )
        })
        .map(Partials::from);
    Ok(force_result(env, value))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn force_ecom1_parameter_partials_with_sun_moon(
    env: Env<'_>,
    description: ForceDescription,
    position: Vec3,
    velocity: Vec3,
    sun: Vec3,
    moon: Vec3,
) -> NifResult<Term<'_>> {
    let ForceDescription::Ecom1(coefficients, options) = description else {
        return Err(rustler::Error::BadArg);
    };
    let value = ecom1(coefficients, options)
        .and_then(|model| {
            model.parameter_partials_with_sun_moon(
                vector(position),
                vector(velocity),
                vector(sun),
                vector(moon),
            )
        })
        .map(|values| values.into_iter().map(encode_vector).collect::<Vec<_>>());
    Ok(force_result(env, value))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn force_ecom2_acceleration_with_sun(
    env: Env<'_>,
    description: ForceDescription,
    position: Vec3,
    velocity: Vec3,
    sun: Vec3,
) -> NifResult<Term<'_>> {
    let ForceDescription::Ecom2(n_d, n_b, coefficients, options) = description else {
        return Err(rustler::Error::BadArg);
    };
    let value = ecom2(n_d, n_b, coefficients, options)
        .and_then(|model| {
            model.acceleration_with_sun(vector(position), vector(velocity), vector(sun))
        })
        .map(encode_vector);
    Ok(force_result(env, value))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn force_ecom2_acceleration_partials_with_sun(
    env: Env<'_>,
    description: ForceDescription,
    position: Vec3,
    velocity: Vec3,
    sun: Vec3,
) -> NifResult<Term<'_>> {
    let ForceDescription::Ecom2(n_d, n_b, coefficients, options) = description else {
        return Err(rustler::Error::BadArg);
    };
    let value = ecom2(n_d, n_b, coefficients, options)
        .and_then(|model| {
            model.acceleration_partials_with_sun(vector(position), vector(velocity), vector(sun))
        })
        .map(Partials::from);
    Ok(force_result(env, value))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn force_ecom2_parameter_partials_with_sun(
    env: Env<'_>,
    description: ForceDescription,
    position: Vec3,
    velocity: Vec3,
    sun: Vec3,
) -> NifResult<Term<'_>> {
    let ForceDescription::Ecom2(n_d, n_b, coefficients, options) = description else {
        return Err(rustler::Error::BadArg);
    };
    let value = ecom2(n_d, n_b, coefficients, options)
        .and_then(|model| {
            model.parameter_partials_with_sun(vector(position), vector(velocity), vector(sun))
        })
        .map(|values| values.into_iter().map(encode_vector).collect::<Vec<_>>());
    Ok(force_result(env, value))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn force_ecom2_acceleration_with_sun_moon(
    env: Env<'_>,
    description: ForceDescription,
    position: Vec3,
    velocity: Vec3,
    sun: Vec3,
    moon: Vec3,
) -> NifResult<Term<'_>> {
    let ForceDescription::Ecom2(n_d, n_b, coefficients, options) = description else {
        return Err(rustler::Error::BadArg);
    };
    let value = ecom2(n_d, n_b, coefficients, options)
        .and_then(|model| {
            model.acceleration_with_sun_moon(
                vector(position),
                vector(velocity),
                vector(sun),
                vector(moon),
            )
        })
        .map(encode_vector);
    Ok(force_result(env, value))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn force_ecom2_acceleration_partials_with_sun_moon(
    env: Env<'_>,
    description: ForceDescription,
    position: Vec3,
    velocity: Vec3,
    sun: Vec3,
    moon: Vec3,
) -> NifResult<Term<'_>> {
    let ForceDescription::Ecom2(n_d, n_b, coefficients, options) = description else {
        return Err(rustler::Error::BadArg);
    };
    let value = ecom2(n_d, n_b, coefficients, options)
        .and_then(|model| {
            model.acceleration_partials_with_sun_moon(
                vector(position),
                vector(velocity),
                vector(sun),
                vector(moon),
            )
        })
        .map(Partials::from);
    Ok(force_result(env, value))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn force_ecom2_parameter_partials_with_sun_moon(
    env: Env<'_>,
    description: ForceDescription,
    position: Vec3,
    velocity: Vec3,
    sun: Vec3,
    moon: Vec3,
) -> NifResult<Term<'_>> {
    let ForceDescription::Ecom2(n_d, n_b, coefficients, options) = description else {
        return Err(rustler::Error::BadArg);
    };
    let value = ecom2(n_d, n_b, coefficients, options)
        .and_then(|model| {
            model.parameter_partials_with_sun_moon(
                vector(position),
                vector(velocity),
                vector(sun),
                vector(moon),
            )
        })
        .map(|values| values.into_iter().map(encode_vector).collect::<Vec<_>>());
    Ok(force_result(env, value))
}

#[rustler::nif]
fn force_cr_parameter() -> &'static str {
    SolarRadiationPressure::CR_PARAMETER
}

#[rustler::nif(schedule = "DirtyCpu")]
fn force_solar_acceleration_with_sun_moon(
    env: Env<'_>,
    description: ForceDescription,
    position: Vec3,
    sun: Vec3,
    moon: Vec3,
) -> NifResult<Term<'_>> {
    let ForceDescription::SolarRadiationPressure(cr, area, options) = description else {
        return Err(rustler::Error::BadArg);
    };
    let value = solar(cr, area, options)
        .and_then(|model| {
            model.acceleration_with_sun_moon(vector(position), vector(sun), vector(moon))
        })
        .map(encode_vector);
    Ok(force_result(env, value))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn force_earth_acceleration_with_sun_moon(
    env: Env<'_>,
    description: ForceDescription,
    state: StateTerm,
    sun: Vec3,
    moon: Vec3,
) -> NifResult<Term<'_>> {
    let ForceDescription::EarthRadiationPressure(cr, area, moon_enabled) = description else {
        return Err(rustler::Error::BadArg);
    };
    let value = earth_radiation(cr, area, moon_enabled)
        .and_then(|model| {
            model.acceleration_with_sun_moon(&decode_state(state), vector(sun), vector(moon))
        })
        .map(encode_vector);
    Ok(force_result(env, value))
}

#[derive(NifMap)]
#[rustler(encode)]
struct Geometry {
    dyb: crate::gnss_attitude::Dyb,
    delta_u_rad: Option<f64>,
    argument_of_latitude_rad: Option<f64>,
    lighting_ratio: f64,
}

impl From<sidereon_core::astro::forces::EcomGeometry> for Geometry {
    fn from(value: sidereon_core::astro::forces::EcomGeometry) -> Self {
        Self {
            dyb: value.dyb.into(),
            delta_u_rad: value.delta_u_rad,
            argument_of_latitude_rad: value.argument_of_latitude_rad,
            lighting_ratio: value.lighting_ratio,
        }
    }
}

fn vector((x, y, z): Vec3) -> Vector3<f64> {
    Vector3::new(x, y, z)
}

#[rustler::nif]
fn force_ecom_geometry(env: Env<'_>, position: Vec3, velocity: Vec3, sun: Vec3) -> Term<'_> {
    use sidereon_core::astro::forces::ecom_geometry;
    force_result(
        env,
        ecom_geometry(vector(position), vector(velocity), vector(sun)).map(Geometry::from),
    )
}

#[rustler::nif]
fn force_ecom_geometry_with_shadow(
    env: Env<'_>,
    position: Vec3,
    velocity: Vec3,
    sun: Vec3,
    moon: Option<Vec3>,
    earth: Earth,
) -> Term<'_> {
    use sidereon_core::astro::forces::ecom_geometry_with_shadow;
    force_result(
        env,
        ecom_geometry_with_shadow(
            vector(position),
            vector(velocity),
            vector(sun),
            moon.map(vector),
            earth.into(),
        )
        .map(Geometry::from),
    )
}

#[rustler::nif]
fn force_ecom1_coefficient_count() -> usize {
    sidereon_core::astro::forces::ECOM1_COEFFICIENT_COUNT
}

#[rustler::nif]
fn force_ecom2_d2b1_coefficient_count() -> usize {
    sidereon_core::astro::forces::ECOM2_D2B1_COEFFICIENT_COUNT
}

#[rustler::nif]
fn force_ecom2_d4b1_coefficient_count() -> usize {
    sidereon_core::astro::forces::ECOM2_D4B1_COEFFICIENT_COUNT
}

#[rustler::nif]
fn force_drag_model(env: Env<'_>, drag: crate::drag::DragParametersTerm) -> Term<'_> {
    force_result(
        env,
        drag.into_core()
            .map(|drag| ResourceArc::new(ForceResource(Arc::new(drag.to_force())))),
    )
}

#[rustler::nif]
fn eclipse_iau_2015_solar_radius_km() -> f64 {
    sidereon_core::astro::constants::astro::IAU_2015_SOLAR_RADIUS_KM
}

#[rustler::nif]
fn force_axis_compare(first: Axis, second: Axis) -> rustler::Atom {
    crate::errors::ordering_atom(RtnAxis::from(first).cmp(&second.into()))
}

#[rustler::nif]
fn force_harmonic_compare(first: Harmonic, second: Harmonic) -> rustler::Atom {
    crate::errors::ordering_atom(EmpiricalHarmonic::from(first).cmp(&second.into()))
}

#[rustler::nif]
fn force_all_axes() -> NifResult<Vec<Axis>> {
    RtnAxis::ALL.into_iter().map(axis_term).collect()
}

#[rustler::nif]
fn force_all_harmonics() -> NifResult<Vec<Harmonic>> {
    EmpiricalHarmonic::ALL
        .into_iter()
        .map(harmonic_term)
        .collect()
}

#[rustler::nif]
fn force_solar_au_km(env: Env<'_>, cr: f64, area: f64) -> Term<'_> {
    force_result(
        env,
        SolarRadiationPressure::new(cr, area).map(|model| model.au_km()),
    )
}

#[derive(NifUnitEnum)]
enum Ecom2Kind {
    D2b1,
    D4b1,
}

#[rustler::nif]
fn force_ecom2_named(env: Env<'_>, kind: Ecom2Kind, coefficients: Vec<f64>) -> NifResult<Term<'_>> {
    let model = match kind {
        Ecom2Kind::D2b1 => Ecom2SolarRadiationPressure::d2b1(Ecom2D2b1Coefficients::from_array(
            coefficients
                .try_into()
                .map_err(|_| rustler::Error::BadArg)?,
        )),
        Ecom2Kind::D4b1 => Ecom2SolarRadiationPressure::d4b1(Ecom2D4b1Coefficients::from_array(
            coefficients
                .try_into()
                .map_err(|_| rustler::Error::BadArg)?,
        )),
    };
    let model = match model {
        Ok(model) => model,
        Err(error) => return Ok(force_result(env, Err::<(), _>(error))),
    };
    let fields = (
        model.n_d(),
        model.n_b(),
        Occultation {
            shadow_function: Some(shadow_function(model.shadow_function())?),
            earth_shadow_model: Some(earth_shadow_model(model.earth_shadow_model())),
            moon_eclipse_enabled: Some(model.moon_eclipse_enabled()),
        },
    );
    Ok(force_result(env, Ok(fields)))
}
