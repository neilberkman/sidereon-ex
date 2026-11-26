use std::sync::Arc;

use crate::de::DeResource;
use crate::errors::{degrade_reason_atom, detail_map, encode_result, Refusal};
use crate::{vector_tuple, Vec3};
use rustler::{Encoder, Env, NifMap, NifUnitEnum, ResourceArc, Term};
use sidereon_core::astro::frames::transforms::FrameTransformError;
use sidereon_core::astro::frames::{
    EarthOrientation, EarthOrientationProvider, Iers2010EarthOrientationProvider,
    Iers2010EopSample, TdbEarthOrientationProvider,
};
use sidereon_core::astro::propagator::PropagationContext;
use sidereon_core::astro::time::ValidityMode;

rustler::atoms! { invalid_input, ut1_outside_coverage, field, reason }

pub(crate) fn frame_error(env: Env<'_>, error: FrameTransformError) -> Refusal<'_> {
    let (kind, detail) = match &error {
        FrameTransformError::InvalidInput {
            field: label,
            reason: message,
        } => (
            invalid_input(),
            detail_map(
                env,
                &[
                    (field(), label.encode(env)),
                    (reason(), message.encode(env)),
                ],
            ),
        ),
        FrameTransformError::Ut1OutsideCoverage { reason: value } => (
            ut1_outside_coverage(),
            detail_map(env, &[(reason(), degrade_reason_atom(*value).encode(env))]),
        ),
    };
    Refusal {
        kind,
        detail,
        message: error.to_string(),
    }
}

pub(crate) fn time_error(
    env: Env<'_>,
    error: sidereon_core::astro::time::CoverageError,
) -> Refusal<'_> {
    use sidereon_core::astro::time::{CoverageError, TimeScaleInputErrorKind};
    let (kind, detail) = match error {
        CoverageError::InvalidInput { field: label, kind } => {
            let classification = match kind {
                TimeScaleInputErrorKind::Missing => "missing",
                TimeScaleInputErrorKind::NonFinite => "non_finite",
                TimeScaleInputErrorKind::NotPositive => "not_positive",
                TimeScaleInputErrorKind::Negative => "negative",
                TimeScaleInputErrorKind::OutOfRange => "out_of_range",
                TimeScaleInputErrorKind::FloatParse => "float_parse",
                TimeScaleInputErrorKind::IntParse => "int_parse",
                TimeScaleInputErrorKind::InvalidCivilDate => "invalid_civil_date",
                TimeScaleInputErrorKind::InvalidCivilTime => "invalid_civil_time",
            };
            (
                invalid_input(),
                detail_map(
                    env,
                    &[
                        (field(), label.encode(env)),
                        (reason(), classification.encode(env)),
                    ],
                ),
            )
        }
        CoverageError::OutsideCoverage(value) => (
            ut1_outside_coverage(),
            detail_map(env, &[(reason(), degrade_reason_atom(value).encode(env))]),
        ),
    };
    Refusal {
        kind,
        detail,
        message: error.to_string(),
    }
}

#[derive(NifMap)]
struct EopSample {
    mjd_utc: i32,
    xp_arcsec: f64,
    yp_arcsec: f64,
    ut1_minus_utc_s: f64,
    lod_s: f64,
    dx_arcsec: f64,
    dy_arcsec: f64,
    pole_rates_rad_s: Option<(f64, f64)>,
}

impl From<EopSample> for Iers2010EopSample {
    fn from(sample: EopSample) -> Self {
        Self {
            mjd_utc: sample.mjd_utc,
            xp_arcsec: sample.xp_arcsec,
            yp_arcsec: sample.yp_arcsec,
            ut1_minus_utc_s: sample.ut1_minus_utc_s,
            lod_s: sample.lod_s,
            dx_arcsec: sample.dx_arcsec,
            dy_arcsec: sample.dy_arcsec,
            pole_rates_rad_s: sample.pole_rates_rad_s.map(Into::into),
        }
    }
}

pub(crate) struct IersProvider(pub Arc<Iers2010EarthOrientationProvider>);

#[rustler::resource_impl]
impl rustler::Resource for IersProvider {}

#[derive(Clone, Copy, NifUnitEnum)]
pub(crate) enum Validity {
    Strict,
    Permissive,
}

impl From<Validity> for ValidityMode {
    fn from(value: Validity) -> Self {
        match value {
            Validity::Strict => Self::Strict,
            Validity::Permissive => Self::Permissive,
        }
    }
}

#[derive(NifMap)]
#[rustler(encode)]
struct Orientation {
    iers2010_quaternion: Option<(f64, f64, f64, f64)>,
    earth_rotation_vector_itrf_rad_s: Vec3,
    ut1_degraded: Option<rustler::Atom>,
    gcrf_to_itrf_matrix: Vec<Vec3>,
    itrf_to_gcrf_matrix: Vec<Vec3>,
    gcrf_to_itrf_rotation_rate_matrix: Vec<Vec3>,
    itrf_to_gcrf_rotation_rate_matrix: Vec<Vec3>,
}

impl From<EarthOrientation> for Orientation {
    fn from(value: EarthOrientation) -> Self {
        Self {
            iers2010_quaternion: value.iers2010_quaternion().map(|[w, x, y, z]| (w, x, y, z)),
            earth_rotation_vector_itrf_rad_s: vector_tuple(
                value.earth_rotation_vector_itrf_rad_s(),
            ),
            ut1_degraded: value.ut1_degraded().map(degrade_reason_atom),
            gcrf_to_itrf_matrix: value.gcrf_to_itrf_matrix().map(vector_tuple).to_vec(),
            itrf_to_gcrf_matrix: value.itrf_to_gcrf_matrix().map(vector_tuple).to_vec(),
            gcrf_to_itrf_rotation_rate_matrix: value
                .gcrf_to_itrf_rotation_rate_matrix()
                .map(vector_tuple)
                .to_vec(),
            itrf_to_gcrf_rotation_rate_matrix: value
                .itrf_to_gcrf_rotation_rate_matrix()
                .map(vector_tuple)
                .to_vec(),
        }
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn iers2010_new(env: Env<'_>, samples: Vec<EopSample>) -> Term<'_> {
    let samples = samples.into_iter().map(Into::into).collect();
    encode_result(
        env,
        Iers2010EarthOrientationProvider::new(samples)
            .map(Arc::new)
            .map(IersProvider)
            .map(ResourceArc::new)
            .map_err(|error| frame_error(env, error)),
    )
}

#[rustler::nif(schedule = "DirtyCpu")]
fn iers2010_with_validity(
    handle: ResourceArc<IersProvider>,
    validity: Validity,
) -> ResourceArc<IersProvider> {
    let provider = (*handle.0).clone().with_validity(validity.into());
    ResourceArc::new(IersProvider(Arc::new(provider)))
}

#[rustler::nif]
fn iers2010_equal(first: ResourceArc<IersProvider>, second: ResourceArc<IersProvider>) -> bool {
    first.0 == second.0
}

#[rustler::nif]
fn iers2010_orientation_at_utc_mjd(
    env: Env<'_>,
    handle: ResourceArc<IersProvider>,
    mjd: i32,
    seconds: f64,
) -> Term<'_> {
    encode_result(
        env,
        handle
            .0
            .orientation_at_utc_mjd(mjd, seconds)
            .map(Orientation::from)
            .map_err(|error| frame_error(env, error)),
    )
}

#[rustler::nif]
fn iers2010_orientation_at_tdb_seconds(
    env: Env<'_>,
    handle: ResourceArc<IersProvider>,
    epoch: f64,
) -> Term<'_> {
    encode_result(
        env,
        handle
            .0
            .orientation_at_tdb_seconds(epoch)
            .map(Orientation::from)
            .map_err(|error| frame_error(env, error)),
    )
}

pub(crate) struct ContextResource(pub PropagationContext);

#[rustler::resource_impl]
impl rustler::Resource for ContextResource {}

#[rustler::nif]
fn propagation_context_new(env: Env<'_>) -> Term<'_> {
    ResourceArc::new(ContextResource(PropagationContext::new())).encode(env)
}

#[rustler::nif]
fn propagation_context_with_de_ephemeris(
    env: Env<'_>,
    context: ResourceArc<ContextResource>,
    ephemeris: ResourceArc<DeResource>,
) -> Term<'_> {
    ResourceArc::new(ContextResource(
        context.0.clone().with_de_ephemeris(ephemeris.0.clone()),
    ))
    .encode(env)
}

#[derive(NifUnitEnum)]
pub(crate) enum DefaultProvider {
    Tdb,
}

#[derive(rustler::NifUntaggedEnum)]
pub(crate) enum BodyFixedProvider {
    Default(DefaultProvider),
    Tdb((DefaultProvider, Validity)),
    Iers(ResourceArc<IersProvider>),
}

impl BodyFixedProvider {
    pub(crate) fn tdb_provider(&self) -> TdbEarthOrientationProvider {
        let provider = TdbEarthOrientationProvider::new();
        match self {
            Self::Tdb((DefaultProvider::Tdb, validity)) => {
                provider.with_validity((*validity).into())
            }
            _ => provider,
        }
    }

    pub(crate) fn as_provider<'a>(
        &'a self,
        tdb: &'a TdbEarthOrientationProvider,
    ) -> &'a dyn EarthOrientationProvider {
        match self {
            Self::Iers(provider) => provider.0.as_ref(),
            _ => tdb,
        }
    }
}

#[rustler::nif]
fn propagation_context_with_body_fixed_frame_provider(
    env: Env<'_>,
    context: ResourceArc<ContextResource>,
    provider: BodyFixedProvider,
) -> Term<'_> {
    let provider: Arc<dyn EarthOrientationProvider> = match &provider {
        BodyFixedProvider::Iers(provider) => provider.0.clone(),
        _ => Arc::new(provider.tdb_provider()),
    };
    ResourceArc::new(ContextResource(
        context.0.clone().with_body_fixed_frame_provider(provider),
    ))
    .encode(env)
}

#[rustler::nif]
fn propagation_context_ut1_departure(
    context: ResourceArc<ContextResource>,
) -> Option<rustler::Atom> {
    context.0.ut1_departure().map(degrade_reason_atom)
}

pub(crate) fn propagation_context(
    resource: Option<ResourceArc<ContextResource>>,
) -> PropagationContext {
    resource
        .map(|resource| resource.0.clone())
        .unwrap_or_default()
}
