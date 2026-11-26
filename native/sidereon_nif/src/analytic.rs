use crate::errors::{encode_result, Refusal};
use crate::{vector_tuple, Vec3};
use rustler::{Encoder, Env, NifMap, ResourceArc, Term};
use sidereon_core::astro::propagator::analytic::{self, AnalyticPropagationError, AnalyticTheory};
use sidereon_core::astro::state::CartesianState;

pub(crate) type StateTerm = (f64, Vec3, Vec3);

pub(crate) fn decode_state((epoch, position, velocity): StateTerm) -> CartesianState {
    CartesianState::new(epoch, position.into(), velocity.into())
}

pub(crate) fn encode_state(state: CartesianState) -> StateTerm {
    (
        state.epoch_tdb_seconds,
        vector_tuple(state.position_array()),
        vector_tuple(state.velocity_array()),
    )
}

rustler::atoms! { eckstein_hechler, brouwer_lyddane, non_finite, invalid_parameter, not_elliptic, retrograde_equatorial, inside_reference_sphere, eccentricity_too_large, nearly_equatorial, near_critical_inclination, mean_elements_not_converged, kepler_not_converged, non_finite_result }

fn theory_atom(theory: AnalyticTheory) -> rustler::Atom {
    match theory {
        AnalyticTheory::EcksteinHechler => eckstein_hechler(),
        AnalyticTheory::BrouwerLyddane => brouwer_lyddane(),
    }
}

#[derive(NifMap)]
#[rustler(encode)]
struct FieldDetail {
    field: &'static str,
}

#[derive(NifMap)]
#[rustler(encode)]
struct FieldReasonDetail {
    field: &'static str,
    reason: &'static str,
}

#[derive(NifMap)]
#[rustler(encode)]
struct InclinationRadDetail {
    inclination_rad: f64,
}

#[derive(NifMap)]
#[rustler(encode)]
struct SemiMajorAxisKmReferenceRadiusKmDetail {
    semi_major_axis_km: f64,
    reference_radius_km: f64,
}

#[derive(NifMap)]
#[rustler(encode)]
struct EccentricityLimitDetail {
    eccentricity: f64,
    limit: f64,
}

#[derive(NifMap)]
#[rustler(encode)]
struct TheoryIterationsDetail {
    theory: rustler::Atom,
    iterations: u32,
}

#[derive(NifMap)]
#[rustler(encode)]
struct TheoryFieldDetail {
    theory: rustler::Atom,
    field: &'static str,
}

fn analytic_error(env: Env<'_>, error: AnalyticPropagationError) -> Refusal<'_> {
    let (kind, detail) = match error {
        AnalyticPropagationError::NonFinite { field } => {
            (non_finite(), FieldDetail { field }.encode(env))
        }
        AnalyticPropagationError::InvalidParameter { field, reason } => (
            invalid_parameter(),
            FieldReasonDetail { field, reason }.encode(env),
        ),
        AnalyticPropagationError::NotElliptic { field } => {
            (not_elliptic(), FieldDetail { field }.encode(env))
        }
        AnalyticPropagationError::RetrogradeEquatorial { inclination_rad } => (
            retrograde_equatorial(),
            InclinationRadDetail { inclination_rad }.encode(env),
        ),
        AnalyticPropagationError::InsideReferenceSphere {
            semi_major_axis_km,
            reference_radius_km,
        } => (
            inside_reference_sphere(),
            SemiMajorAxisKmReferenceRadiusKmDetail {
                semi_major_axis_km,
                reference_radius_km,
            }
            .encode(env),
        ),
        AnalyticPropagationError::EccentricityTooLarge {
            eccentricity,
            limit,
        } => (
            eccentricity_too_large(),
            EccentricityLimitDetail {
                eccentricity,
                limit,
            }
            .encode(env),
        ),
        AnalyticPropagationError::NearlyEquatorial { inclination_rad } => (
            nearly_equatorial(),
            InclinationRadDetail { inclination_rad }.encode(env),
        ),
        AnalyticPropagationError::NearCriticalInclination { inclination_rad } => (
            near_critical_inclination(),
            InclinationRadDetail { inclination_rad }.encode(env),
        ),
        AnalyticPropagationError::MeanElementsNotConverged { theory, iterations } => (
            mean_elements_not_converged(),
            TheoryIterationsDetail {
                theory: theory_atom(theory),
                iterations,
            }
            .encode(env),
        ),
        AnalyticPropagationError::KeplerNotConverged { field } => {
            (kepler_not_converged(), FieldDetail { field }.encode(env))
        }
        AnalyticPropagationError::NonFiniteResult { theory, field } => (
            non_finite_result(),
            TheoryFieldDetail {
                theory: theory_atom(theory),
                field,
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

fn result<'a>(env: Env<'a>, value: Result<impl Encoder, AnalyticPropagationError>) -> Term<'a> {
    encode_result(env, value.map_err(|error| analytic_error(env, error)))
}

#[derive(NifMap)]
struct CircularElements {
    a_km: f64,
    ex: f64,
    ey: f64,
    i_rad: f64,
    raan_rad: f64,
    mean_latitude_argument_rad: f64,
}

impl From<analytic::CircularElements> for CircularElements {
    fn from(value: analytic::CircularElements) -> Self {
        Self {
            a_km: value.a_km,
            ex: value.ex,
            ey: value.ey,
            i_rad: value.i_rad,
            raan_rad: value.raan_rad,
            mean_latitude_argument_rad: value.mean_latitude_argument_rad,
        }
    }
}

impl From<CircularElements> for analytic::CircularElements {
    fn from(value: CircularElements) -> Self {
        Self {
            a_km: value.a_km,
            ex: value.ex,
            ey: value.ey,
            i_rad: value.i_rad,
            raan_rad: value.raan_rad,
            mean_latitude_argument_rad: value.mean_latitude_argument_rad,
        }
    }
}

#[rustler::nif]
fn analytic_circular_elements_from_cartesian<'a>(
    env: Env<'a>,
    position: Vec3,
    velocity: Vec3,
    mu: f64,
) -> Term<'a> {
    result(
        env,
        analytic::CircularElements::from_cartesian(position.into(), velocity.into(), mu)
            .map(CircularElements::from),
    )
}

#[rustler::nif]
fn analytic_circular_elements_to_cartesian<'a>(
    env: Env<'a>,
    elements: CircularElements,
    mu: f64,
) -> Term<'a> {
    result(
        env,
        analytic::CircularElements::from(elements)
            .to_cartesian(mu)
            .map(|(position, velocity)| (vector_tuple(position), vector_tuple(velocity))),
    )
}

#[rustler::nif]
fn analytic_eccentricity(elements: CircularElements) -> f64 {
    analytic::CircularElements::from(elements).eccentricity()
}

#[derive(NifMap)]
struct KeplerianElements {
    a_km: f64,
    e: f64,
    i_rad: f64,
    arg_perigee_rad: f64,
    raan_rad: f64,
    mean_anomaly_rad: f64,
}

impl From<analytic::KeplerianElements> for KeplerianElements {
    fn from(value: analytic::KeplerianElements) -> Self {
        Self {
            a_km: value.a_km,
            e: value.e,
            i_rad: value.i_rad,
            arg_perigee_rad: value.arg_perigee_rad,
            raan_rad: value.raan_rad,
            mean_anomaly_rad: value.mean_anomaly_rad,
        }
    }
}

impl From<KeplerianElements> for analytic::KeplerianElements {
    fn from(value: KeplerianElements) -> Self {
        Self {
            a_km: value.a_km,
            e: value.e,
            i_rad: value.i_rad,
            arg_perigee_rad: value.arg_perigee_rad,
            raan_rad: value.raan_rad,
            mean_anomaly_rad: value.mean_anomaly_rad,
        }
    }
}

#[rustler::nif]
fn analytic_keplerian_elements_from_cartesian<'a>(
    env: Env<'a>,
    position: Vec3,
    velocity: Vec3,
    mu: f64,
) -> Term<'a> {
    result(
        env,
        analytic::KeplerianElements::from_cartesian(position.into(), velocity.into(), mu)
            .map(KeplerianElements::from),
    )
}

#[rustler::nif]
fn analytic_keplerian_elements_to_cartesian<'a>(
    env: Env<'a>,
    elements: KeplerianElements,
    mu: f64,
) -> Term<'a> {
    result(
        env,
        analytic::KeplerianElements::from(elements)
            .to_cartesian(mu)
            .map(|(position, velocity)| (vector_tuple(position), vector_tuple(velocity))),
    )
}

#[derive(NifMap)]
struct ZonalHarmonics {
    mu_km3_s2: f64,
    re_km: f64,
    c20: f64,
    c30: f64,
    c40: f64,
    c50: f64,
    c60: f64,
}

impl From<analytic::ZonalHarmonics> for ZonalHarmonics {
    fn from(value: analytic::ZonalHarmonics) -> Self {
        Self {
            mu_km3_s2: value.mu_km3_s2,
            re_km: value.re_km,
            c20: value.c20,
            c30: value.c30,
            c40: value.c40,
            c50: value.c50,
            c60: value.c60,
        }
    }
}

impl From<ZonalHarmonics> for analytic::ZonalHarmonics {
    fn from(value: ZonalHarmonics) -> Self {
        Self {
            mu_km3_s2: value.mu_km3_s2,
            re_km: value.re_km,
            c20: value.c20,
            c30: value.c30,
            c40: value.c40,
            c50: value.c50,
            c60: value.c60,
        }
    }
}

#[rustler::nif]
fn analytic_zonal_earth() -> ZonalHarmonics {
    analytic::ZonalHarmonics::earth().into()
}

#[derive(NifMap)]
struct MeanConversionOptions {
    tolerance: f64,
    max_iterations: u32,
}

impl From<analytic::MeanConversionOptions> for MeanConversionOptions {
    fn from(value: analytic::MeanConversionOptions) -> Self {
        Self {
            tolerance: value.tolerance,
            max_iterations: value.max_iterations,
        }
    }
}

impl From<MeanConversionOptions> for analytic::MeanConversionOptions {
    fn from(value: MeanConversionOptions) -> Self {
        Self {
            tolerance: value.tolerance,
            max_iterations: value.max_iterations,
        }
    }
}

#[rustler::nif]
fn analytic_eckstein_hechler_default() -> MeanConversionOptions {
    analytic::MeanConversionOptions::ECKSTEIN_HECHLER_DEFAULT.into()
}

#[rustler::nif]
fn analytic_brouwer_lyddane_default() -> MeanConversionOptions {
    analytic::MeanConversionOptions::BROUWER_LYDDANE_DEFAULT.into()
}

#[rustler::nif]
fn analytic_eckstein_hechler_mean_elements<'a>(
    env: Env<'a>,
    state: StateTerm,
    gravity: ZonalHarmonics,
    options: MeanConversionOptions,
) -> Term<'a> {
    result(
        env,
        analytic::eckstein_hechler_mean_elements(
            &decode_state(state),
            &gravity.into(),
            options.into(),
        )
        .map(|mean| (CircularElements::from(mean.elements), mean.iterations)),
    )
}

#[rustler::nif]
fn analytic_eckstein_hechler_osculating_elements<'a>(
    env: Env<'a>,
    elements: CircularElements,
    gravity: ZonalHarmonics,
) -> Term<'a> {
    result(
        env,
        analytic::eckstein_hechler_osculating_elements(&elements.into(), &gravity.into())
            .map(CircularElements::from),
    )
}

pub(crate) struct EcksteinHechlerPropagator(pub analytic::EcksteinHechlerPropagator);

#[rustler::resource_impl]
impl rustler::Resource for EcksteinHechlerPropagator {}

#[rustler::nif(schedule = "DirtyCpu")]
fn analytic_eckstein_hechler_new<'a>(
    env: Env<'a>,
    state: StateTerm,
    gravity: ZonalHarmonics,
    options: MeanConversionOptions,
) -> Term<'a> {
    result(
        env,
        analytic::EcksteinHechlerPropagator::new(
            &decode_state(state),
            &gravity.into(),
            options.into(),
        )
        .map(EcksteinHechlerPropagator)
        .map(ResourceArc::new),
    )
}

#[rustler::nif]
fn analytic_eckstein_hechler_from_mean_elements<'a>(
    env: Env<'a>,
    epoch: f64,
    elements: CircularElements,
    gravity: ZonalHarmonics,
) -> Term<'a> {
    result(
        env,
        analytic::EcksteinHechlerPropagator::from_mean_elements(
            epoch,
            elements.into(),
            &gravity.into(),
        )
        .map(EcksteinHechlerPropagator)
        .map(ResourceArc::new),
    )
}

#[rustler::nif]
fn analytic_eckstein_hechler_propagate<'a>(
    env: Env<'a>,
    handle: ResourceArc<EcksteinHechlerPropagator>,
    epoch: f64,
) -> Term<'a> {
    result(env, handle.0.propagate(epoch).map(encode_state))
}

#[rustler::nif]
fn analytic_eckstein_hechler_propagator_osculating_elements<'a>(
    env: Env<'a>,
    handle: ResourceArc<EcksteinHechlerPropagator>,
    epoch: f64,
) -> Term<'a> {
    result(
        env,
        handle
            .0
            .osculating_elements(epoch)
            .map(CircularElements::from),
    )
}

#[rustler::nif(schedule = "DirtyCpu")]
fn analytic_eckstein_hechler_ephemeris<'a>(
    env: Env<'a>,
    handle: ResourceArc<EcksteinHechlerPropagator>,
    epochs: Vec<f64>,
) -> Term<'a> {
    result(
        env,
        handle
            .0
            .ephemeris(&epochs)
            .map(|states| states.into_iter().map(encode_state).collect::<Vec<_>>()),
    )
}

#[rustler::nif]
fn analytic_eckstein_hechler_propagator_epoch_tdb_seconds(
    handle: ResourceArc<EcksteinHechlerPropagator>,
) -> f64 {
    handle.0.epoch_tdb_seconds()
}

#[rustler::nif]
fn analytic_eckstein_hechler_propagator_mean_elements(
    handle: ResourceArc<EcksteinHechlerPropagator>,
) -> CircularElements {
    handle.0.mean_elements().into()
}

#[rustler::nif]
fn analytic_eckstein_hechler_propagator_gravity(
    handle: ResourceArc<EcksteinHechlerPropagator>,
) -> ZonalHarmonics {
    (*handle.0.gravity()).into()
}

#[rustler::nif]
fn analytic_brouwer_lyddane_mean_elements<'a>(
    env: Env<'a>,
    state: StateTerm,
    gravity: ZonalHarmonics,
    options: MeanConversionOptions,
) -> Term<'a> {
    result(
        env,
        analytic::brouwer_lyddane_mean_elements(
            &decode_state(state),
            &gravity.into(),
            options.into(),
        )
        .map(|mean| (KeplerianElements::from(mean.elements), mean.iterations)),
    )
}

#[rustler::nif]
fn analytic_brouwer_lyddane_osculating_elements<'a>(
    env: Env<'a>,
    elements: KeplerianElements,
    gravity: ZonalHarmonics,
) -> Term<'a> {
    result(
        env,
        analytic::brouwer_lyddane_osculating_elements(&elements.into(), &gravity.into())
            .map(KeplerianElements::from),
    )
}

pub(crate) struct BrouwerLyddanePropagator(pub analytic::BrouwerLyddanePropagator);

#[rustler::resource_impl]
impl rustler::Resource for BrouwerLyddanePropagator {}

#[rustler::nif(schedule = "DirtyCpu")]
fn analytic_brouwer_lyddane_new<'a>(
    env: Env<'a>,
    state: StateTerm,
    gravity: ZonalHarmonics,
    m2: f64,
    options: MeanConversionOptions,
) -> Term<'a> {
    result(
        env,
        analytic::BrouwerLyddanePropagator::new(
            &decode_state(state),
            &gravity.into(),
            m2,
            options.into(),
        )
        .map(BrouwerLyddanePropagator)
        .map(ResourceArc::new),
    )
}

#[rustler::nif]
fn analytic_brouwer_lyddane_from_mean_elements<'a>(
    env: Env<'a>,
    epoch: f64,
    elements: KeplerianElements,
    gravity: ZonalHarmonics,
    m2: f64,
) -> Term<'a> {
    result(
        env,
        analytic::BrouwerLyddanePropagator::from_mean_elements(
            epoch,
            elements.into(),
            &gravity.into(),
            m2,
        )
        .map(BrouwerLyddanePropagator)
        .map(ResourceArc::new),
    )
}

#[rustler::nif]
fn analytic_brouwer_lyddane_propagate<'a>(
    env: Env<'a>,
    handle: ResourceArc<BrouwerLyddanePropagator>,
    epoch: f64,
) -> Term<'a> {
    result(env, handle.0.propagate(epoch).map(encode_state))
}

#[rustler::nif]
fn analytic_brouwer_lyddane_propagator_osculating_elements<'a>(
    env: Env<'a>,
    handle: ResourceArc<BrouwerLyddanePropagator>,
    epoch: f64,
) -> Term<'a> {
    result(
        env,
        handle
            .0
            .osculating_elements(epoch)
            .map(KeplerianElements::from),
    )
}

#[rustler::nif(schedule = "DirtyCpu")]
fn analytic_brouwer_lyddane_ephemeris<'a>(
    env: Env<'a>,
    handle: ResourceArc<BrouwerLyddanePropagator>,
    epochs: Vec<f64>,
) -> Term<'a> {
    result(
        env,
        handle
            .0
            .ephemeris(&epochs)
            .map(|states| states.into_iter().map(encode_state).collect::<Vec<_>>()),
    )
}

#[rustler::nif]
fn analytic_brouwer_lyddane_propagator_epoch_tdb_seconds(
    handle: ResourceArc<BrouwerLyddanePropagator>,
) -> f64 {
    handle.0.epoch_tdb_seconds()
}

#[rustler::nif]
fn analytic_brouwer_lyddane_propagator_mean_elements(
    handle: ResourceArc<BrouwerLyddanePropagator>,
) -> KeplerianElements {
    handle.0.mean_elements().into()
}

#[rustler::nif]
fn analytic_brouwer_lyddane_propagator_gravity(
    handle: ResourceArc<BrouwerLyddanePropagator>,
) -> ZonalHarmonics {
    (*handle.0.gravity()).into()
}

#[rustler::nif]
fn analytic_brouwer_lyddane_propagator_m2_rad_s2(
    handle: ResourceArc<BrouwerLyddanePropagator>,
) -> f64 {
    handle.0.m2_rad_s2()
}

#[rustler::nif]
fn analytic_theory_display(theory: rustler::Atom) -> rustler::NifResult<String> {
    let value = if theory == eckstein_hechler() {
        AnalyticTheory::EcksteinHechler
    } else if theory == brouwer_lyddane() {
        AnalyticTheory::BrouwerLyddane
    } else {
        return Err(rustler::Error::BadArg);
    };
    Ok(value.to_string())
}
