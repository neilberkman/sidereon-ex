use std::sync::Arc;

use crate::errors::{detail_map, encode_result, Refusal};
use crate::force_models::force_result;
use crate::{vector_tuple, Vec3};
use rustler::{Encoder, Env, NifMap, NifUnitEnum, ResourceArc, Term};
use sidereon_core::astro::forces::{
    IcgemError, IcgemErrors, IcgemFormat, IcgemGravityField, IcgemHeader, IcgemNormalization,
    IcgemSigmas, IcgemTermKind, IcgemTimeVariableTerm, SphericalHarmonicCoefficient,
    SphericalHarmonicGravity, TideSystem,
};

rustler::atoms! { assumed, constant, cosine, degree, degree_above_maximum, epoch_outside_validity, epoch_tt_seconds, field, first_line, icgem1_0, icgem2_0, infinity, invalid_field, keyword, keyword_not_in_format, line, lines, max_degree, missing_coefficient, missing_end_of_head, missing_field, missing_header_keyword, missing_record_keyword, negative_infinity, non_finite_coefficient, non_finite_epoch, normalization_out_of_range, order, order_above_degree, overlapping_term, repeated_coefficient, repeated_header_keyword, required, sine, stated, tide_system_conflict, too_few_records, trend, truncation_out_of_range, uncovered_term, unknown, unknown_record_keyword, unknown_tide_system, value }

fn icgem_error(env: Env<'_>, error: IcgemError) -> Refusal<'_> {
    let (kind, detail) = match &error {
        IcgemError::MissingField {
            line,
            keyword,
            field,
        } => (
            missing_field(),
            detail_map(
                env,
                &[
                    (self::line(), (line).encode(env)),
                    (self::keyword(), (keyword).encode(env)),
                    (self::field(), (field).encode(env)),
                ],
            ),
        ),
        IcgemError::InvalidField {
            line,
            keyword,
            field,
            value,
        } => (
            invalid_field(),
            detail_map(
                env,
                &[
                    (self::line(), (line).encode(env)),
                    (self::keyword(), (keyword).encode(env)),
                    (self::field(), (field).encode(env)),
                    (self::value(), (value).encode(env)),
                ],
            ),
        ),
        IcgemError::MissingHeaderKeyword { keyword } => (
            missing_header_keyword(),
            detail_map(env, &[(self::keyword(), (keyword).encode(env))]),
        ),
        IcgemError::RepeatedHeaderKeyword {
            line,
            first_line,
            keyword,
        } => (
            repeated_header_keyword(),
            detail_map(
                env,
                &[
                    (self::line(), (line).encode(env)),
                    (self::first_line(), (first_line).encode(env)),
                    (self::keyword(), (keyword).encode(env)),
                ],
            ),
        ),
        IcgemError::MissingEndOfHead => (missing_end_of_head(), detail_map(env, &[])),
        IcgemError::KeywordNotInFormat { line, keyword } => (
            keyword_not_in_format(),
            detail_map(
                env,
                &[
                    (self::line(), (line).encode(env)),
                    (self::keyword(), (keyword).encode(env)),
                ],
            ),
        ),
        IcgemError::UnknownRecordKeyword { line, keyword } => (
            unknown_record_keyword(),
            detail_map(
                env,
                &[
                    (self::line(), (line).encode(env)),
                    (self::keyword(), (keyword).encode(env)),
                ],
            ),
        ),
        IcgemError::MissingRecordKeyword { line } => (
            missing_record_keyword(),
            detail_map(env, &[(self::line(), (line).encode(env))]),
        ),
        IcgemError::DegreeAboveMaximum {
            line,
            degree,
            max_degree,
        } => (
            degree_above_maximum(),
            detail_map(
                env,
                &[
                    (self::line(), (line).encode(env)),
                    (self::degree(), (degree).encode(env)),
                    (self::max_degree(), (max_degree).encode(env)),
                ],
            ),
        ),
        IcgemError::OrderAboveDegree {
            line,
            degree,
            order,
        } => (
            order_above_degree(),
            detail_map(
                env,
                &[
                    (self::line(), (line).encode(env)),
                    (self::degree(), (degree).encode(env)),
                    (self::order(), (order).encode(env)),
                ],
            ),
        ),
        IcgemError::RepeatedCoefficient {
            line,
            first_line,
            degree,
            order,
        } => (
            repeated_coefficient(),
            detail_map(
                env,
                &[
                    (self::line(), (line).encode(env)),
                    (self::first_line(), (first_line).encode(env)),
                    (self::degree(), (degree).encode(env)),
                    (self::order(), (order).encode(env)),
                ],
            ),
        ),
        IcgemError::OverlappingTerm {
            line,
            first_line,
            keyword,
            degree,
            order,
        } => (
            overlapping_term(),
            detail_map(
                env,
                &[
                    (self::line(), (line).encode(env)),
                    (self::first_line(), (first_line).encode(env)),
                    (self::keyword(), (keyword).encode(env)),
                    (self::degree(), (degree).encode(env)),
                    (self::order(), (order).encode(env)),
                ],
            ),
        ),
        IcgemError::UncoveredTerm {
            line,
            keyword,
            degree,
            order,
        } => (
            uncovered_term(),
            detail_map(
                env,
                &[
                    (self::line(), (line).encode(env)),
                    (self::keyword(), (keyword).encode(env)),
                    (self::degree(), (degree).encode(env)),
                    (self::order(), (order).encode(env)),
                ],
            ),
        ),
        IcgemError::MissingCoefficient { degree, order } => (
            missing_coefficient(),
            detail_map(
                env,
                &[
                    (self::degree(), (degree).encode(env)),
                    (self::order(), (order).encode(env)),
                ],
            ),
        ),
        IcgemError::TooFewRecords {
            max_degree,
            required,
            lines,
        } => (
            too_few_records(),
            detail_map(
                env,
                &[
                    (self::max_degree(), (max_degree).encode(env)),
                    (self::required(), (required).encode(env)),
                    (self::lines(), (lines).encode(env)),
                ],
            ),
        ),
        IcgemError::NormalizationOutOfRange {
            line,
            degree,
            order,
        } => (
            normalization_out_of_range(),
            detail_map(
                env,
                &[
                    (self::line(), (line).encode(env)),
                    (self::degree(), (degree).encode(env)),
                    (self::order(), (order).encode(env)),
                ],
            ),
        ),
        IcgemError::TruncationOutOfRange {
            degree,
            order,
            max_degree,
        } => (
            truncation_out_of_range(),
            detail_map(
                env,
                &[
                    (self::degree(), (degree).encode(env)),
                    (self::order(), (order).encode(env)),
                    (self::max_degree(), (max_degree).encode(env)),
                ],
            ),
        ),
        IcgemError::UnknownTideSystem => (unknown_tide_system(), detail_map(env, &[])),
        IcgemError::TideSystemConflict { stated, assumed } => (
            tide_system_conflict(),
            detail_map(
                env,
                &[
                    (self::stated(), (TidalConvention::from(*stated)).encode(env)),
                    (
                        self::assumed(),
                        (TidalConvention::from(*assumed)).encode(env),
                    ),
                ],
            ),
        ),
        IcgemError::EpochOutsideValidity {
            degree,
            order,
            epoch_tt_seconds,
        } => (
            epoch_outside_validity(),
            detail_map(
                env,
                &[
                    (self::degree(), (degree).encode(env)),
                    (self::order(), (order).encode(env)),
                    (self::epoch_tt_seconds(), (epoch_tt_seconds).encode(env)),
                ],
            ),
        ),
        IcgemError::NonFiniteEpoch => (non_finite_epoch(), detail_map(env, &[])),
        IcgemError::NonFiniteCoefficient {
            degree,
            order,
            epoch_tt_seconds,
        } => (
            non_finite_coefficient(),
            detail_map(
                env,
                &[
                    (self::degree(), (degree).encode(env)),
                    (self::order(), (order).encode(env)),
                    (self::epoch_tt_seconds(), (epoch_tt_seconds).encode(env)),
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
}

#[derive(NifUnitEnum)]
pub(crate) enum TidalConvention {
    TideFree,
    ZeroTide,
    MeanTide,
}

impl From<TideSystem> for TidalConvention {
    fn from(value: TideSystem) -> Self {
        match value {
            TideSystem::TideFree => Self::TideFree,
            TideSystem::ZeroTide => Self::ZeroTide,
            TideSystem::MeanTide => Self::MeanTide,
        }
    }
}

impl From<TidalConvention> for TideSystem {
    fn from(value: TidalConvention) -> Self {
        match value {
            TidalConvention::TideFree => Self::TideFree,
            TidalConvention::ZeroTide => Self::ZeroTide,
            TidalConvention::MeanTide => Self::MeanTide,
        }
    }
}

#[derive(NifUnitEnum)]
pub(crate) enum Errors {
    No,
    Calibrated,
    Formal,
    CalibratedAndFormal,
}

impl From<IcgemErrors> for Errors {
    fn from(value: IcgemErrors) -> Self {
        match value {
            IcgemErrors::No => Self::No,
            IcgemErrors::Calibrated => Self::Calibrated,
            IcgemErrors::Formal => Self::Formal,
            IcgemErrors::CalibratedAndFormal => Self::CalibratedAndFormal,
        }
    }
}

#[derive(NifUnitEnum)]
pub(crate) enum Normalization {
    FullyNormalized,
    Unnormalized,
}

impl From<IcgemNormalization> for Normalization {
    fn from(value: IcgemNormalization) -> Self {
        match value {
            IcgemNormalization::FullyNormalized => Self::FullyNormalized,
            IcgemNormalization::Unnormalized => Self::Unnormalized,
        }
    }
}

#[derive(NifMap)]
#[rustler(encode)]
struct Header {
    model_name: String,
    gravity_constant_m3_s2: f64,
    radius_m: f64,
    max_degree: u16,
    errors: Errors,
    normalization: Normalization,
    tide_system: Option<TidalConvention>,
    format: rustler::Atom,
}

impl From<&IcgemHeader> for Header {
    fn from(value: &IcgemHeader) -> Self {
        Self {
            model_name: value.model_name.clone(),
            gravity_constant_m3_s2: value.gravity_constant_m3_s2,
            radius_m: value.radius_m,
            max_degree: value.max_degree,
            errors: value.errors.into(),
            normalization: value.normalization.into(),
            tide_system: value.tide_system.map(TidalConvention::from),
            format: match value.format {
                IcgemFormat::Icgem1_0 => icgem1_0(),
                IcgemFormat::Icgem2_0 => icgem2_0(),
            },
        }
    }
}

#[derive(NifMap)]
#[rustler(encode)]
struct Sigmas {
    calibrated: Option<(f64, f64)>,
    formal: Option<(f64, f64)>,
}

impl From<IcgemSigmas> for Sigmas {
    fn from(value: IcgemSigmas) -> Self {
        Self {
            calibrated: value.calibrated.map(|[c, s]| (c, s)),
            formal: value.formal.map(|[c, s]| (c, s)),
        }
    }
}

#[derive(NifMap)]
struct Coefficient {
    degree: u16,
    order: u16,
    c: f64,
    s: f64,
}

impl From<SphericalHarmonicCoefficient> for Coefficient {
    fn from(value: SphericalHarmonicCoefficient) -> Self {
        let SphericalHarmonicCoefficient {
            degree,
            order,
            c,
            s,
        } = value;
        Self {
            degree,
            order,
            c,
            s,
        }
    }
}

impl From<Coefficient> for SphericalHarmonicCoefficient {
    fn from(value: Coefficient) -> Self {
        let Coefficient {
            degree,
            order,
            c,
            s,
        } = value;
        Self {
            degree,
            order,
            c,
            s,
        }
    }
}

#[derive(NifMap)]
#[rustler(encode)]
struct TimeVariableTerm<'a> {
    line: usize,
    kind: Term<'a>,
    degree: u16,
    order: u16,
    c: f64,
    s: f64,
    sigmas: Sigmas,
    reference_tt_seconds: f64,
    valid_from_tt_seconds: Term<'a>,
    valid_until_tt_seconds: Term<'a>,
}

fn time_term<'a>(env: Env<'a>, value: &IcgemTimeVariableTerm) -> TimeVariableTerm<'a> {
    TimeVariableTerm {
        line: value.line,
        kind: match value.kind {
            IcgemTermKind::Constant => constant().encode(env),
            IcgemTermKind::Trend => trend().encode(env),
            IcgemTermKind::Cosine { period_years } => (cosine(), period_years).encode(env),
            IcgemTermKind::Sine { period_years } => (sine(), period_years).encode(env),
        },
        degree: value.degree,
        order: value.order,
        c: value.c,
        s: value.s,
        sigmas: value.sigmas.into(),
        reference_tt_seconds: value.reference_tt_seconds,
        valid_from_tt_seconds: if value.valid_from_tt_seconds == f64::NEG_INFINITY {
            negative_infinity().encode(env)
        } else {
            value.valid_from_tt_seconds.encode(env)
        },
        valid_until_tt_seconds: if value.valid_until_tt_seconds == f64::INFINITY {
            infinity().encode(env)
        } else {
            value.valid_until_tt_seconds.encode(env)
        },
    }
}

struct GravityField(IcgemGravityField);

#[rustler::resource_impl]
impl rustler::Resource for GravityField {}

pub(crate) struct HarmonicGravity(pub Arc<SphericalHarmonicGravity>);

#[rustler::resource_impl]
impl rustler::Resource for HarmonicGravity {}

fn field_result(env: Env<'_>, result: Result<IcgemGravityField, IcgemError>) -> Term<'_> {
    encode_result(
        env,
        result
            .map(GravityField)
            .map(ResourceArc::new)
            .map_err(|error| icgem_error(env, error)),
    )
}

fn gravity_result(env: Env<'_>, result: Result<SphericalHarmonicGravity, IcgemError>) -> Term<'_> {
    encode_result(
        env,
        result
            .map(Arc::new)
            .map(HarmonicGravity)
            .map(ResourceArc::new)
            .map_err(|error| icgem_error(env, error)),
    )
}

#[rustler::nif(schedule = "DirtyCpu")]
fn icgem_parse(env: Env<'_>, text: String) -> Term<'_> {
    field_result(env, IcgemGravityField::parse(&text))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn icgem_parse_truncated(env: Env<'_>, text: String, degree: u16, order: u16) -> Term<'_> {
    field_result(
        env,
        IcgemGravityField::parse_truncated(&text, degree, order),
    )
}

#[rustler::nif(schedule = "DirtyCpu")]
fn icgem_equal(first: ResourceArc<GravityField>, second: ResourceArc<GravityField>) -> bool {
    first.0 == second.0
}

#[rustler::nif(schedule = "DirtyCpu")]
fn icgem_with_assumed_tide_system(
    env: Env<'_>,
    handle: ResourceArc<GravityField>,
    tide: TidalConvention,
) -> Term<'_> {
    field_result(env, handle.0.clone().with_assumed_tide_system(tide.into()))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn icgem_gravity(
    env: Env<'_>,
    handle: ResourceArc<GravityField>,
    degree: u16,
    order: u16,
) -> Term<'_> {
    gravity_result(env, handle.0.gravity(degree, order))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn icgem_gravity_in_tide_system(
    env: Env<'_>,
    handle: ResourceArc<GravityField>,
    degree: u16,
    order: u16,
    tide: TidalConvention,
) -> Term<'_> {
    gravity_result(
        env,
        handle.0.gravity_in_tide_system(degree, order, tide.into()),
    )
}

#[rustler::nif(schedule = "DirtyCpu")]
fn icgem_time_variable_terms(
    env: Env<'_>,
    handle: ResourceArc<GravityField>,
) -> Vec<TimeVariableTerm<'_>> {
    handle
        .0
        .time_variable_terms()
        .iter()
        .map(|value| time_term(env, value))
        .collect()
}

#[rustler::nif]
fn icgem_coefficient_at(
    env: Env<'_>,
    handle: ResourceArc<GravityField>,
    degree: u16,
    order: u16,
    epoch: f64,
) -> Term<'_> {
    encode_result(
        env,
        handle
            .0
            .coefficient_at(degree, order, epoch)
            .map(|value| value.map(Coefficient::from))
            .map_err(|error| icgem_error(env, error)),
    )
}

#[rustler::nif]
fn icgem_header(handle: ResourceArc<GravityField>) -> Header {
    handle.0.header().into()
}

#[rustler::nif]
fn icgem_is_time_variable(handle: ResourceArc<GravityField>) -> bool {
    handle.0.is_time_variable()
}

#[rustler::nif]
fn icgem_stored_max_degree(handle: ResourceArc<GravityField>) -> u16 {
    handle.0.stored_max_degree()
}

#[rustler::nif]
fn icgem_stored_max_order(handle: ResourceArc<GravityField>) -> u16 {
    handle.0.stored_max_order()
}

#[rustler::nif]
fn icgem_static_coefficient(
    handle: ResourceArc<GravityField>,
    degree: u16,
    order: u16,
) -> Option<Coefficient> {
    handle
        .0
        .static_coefficient(degree, order)
        .map(Coefficient::from)
}

#[rustler::nif]
fn icgem_static_sigmas(
    handle: ResourceArc<GravityField>,
    degree: u16,
    order: u16,
) -> Option<Sigmas> {
    handle.0.static_sigmas(degree, order).map(Sigmas::from)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn harmonic_gravity_equal(
    first: ResourceArc<HarmonicGravity>,
    second: ResourceArc<HarmonicGravity>,
) -> bool {
    first.0 == second.0
}

#[rustler::nif(schedule = "DirtyCpu")]
fn harmonic_gravity_egm96_truncated(env: Env<'_>, degree: u16, order: u16) -> Term<'_> {
    force_result(
        env,
        SphericalHarmonicGravity::egm96_truncated(degree, order)
            .map(Arc::new)
            .map(HarmonicGravity)
            .map(ResourceArc::new),
    )
}

#[rustler::nif(schedule = "DirtyCpu")]
fn harmonic_gravity_coefficient_at(
    env: Env<'_>,
    handle: ResourceArc<HarmonicGravity>,
    degree: u16,
    order: u16,
    epoch: f64,
) -> Term<'_> {
    force_result(
        env,
        handle
            .0
            .coefficient_at(degree, order, epoch)
            .map(|value| value.map(Coefficient::from)),
    )
}

#[rustler::nif(schedule = "DirtyCpu")]
fn harmonic_gravity_body_fixed_acceleration_km_s2(
    env: Env<'_>,
    handle: ResourceArc<HarmonicGravity>,
    position: Vec3,
) -> Term<'_> {
    force_result(
        env,
        handle
            .0
            .body_fixed_acceleration_km_s2(position.into())
            .map(vector_tuple),
    )
}

#[rustler::nif(schedule = "DirtyCpu")]
fn harmonic_gravity_body_fixed_acceleration_at_km_s2(
    env: Env<'_>,
    handle: ResourceArc<HarmonicGravity>,
    position: Vec3,
    epoch: f64,
) -> Term<'_> {
    force_result(
        env,
        handle
            .0
            .body_fixed_acceleration_at_km_s2(position.into(), epoch)
            .map(vector_tuple),
    )
}

#[rustler::nif(schedule = "DirtyCpu")]
fn harmonic_gravity_body_fixed_potential_km2_s2(
    env: Env<'_>,
    handle: ResourceArc<HarmonicGravity>,
    position: Vec3,
) -> Term<'_> {
    force_result(env, handle.0.body_fixed_potential_km2_s2(position.into()))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn harmonic_gravity_body_fixed_potential_at_km2_s2(
    env: Env<'_>,
    handle: ResourceArc<HarmonicGravity>,
    position: Vec3,
    epoch: f64,
) -> Term<'_> {
    force_result(
        env,
        handle
            .0
            .body_fixed_potential_at_km2_s2(position.into(), epoch),
    )
}

#[rustler::nif]
fn harmonic_gravity_mu_km3_s2(handle: ResourceArc<HarmonicGravity>) -> f64 {
    handle.0.mu_km3_s2()
}

#[rustler::nif]
fn harmonic_gravity_reference_radius_km(handle: ResourceArc<HarmonicGravity>) -> f64 {
    handle.0.reference_radius_km()
}

#[rustler::nif]
fn harmonic_gravity_max_degree(handle: ResourceArc<HarmonicGravity>) -> u16 {
    handle.0.max_degree()
}

#[rustler::nif]
fn harmonic_gravity_max_order(handle: ResourceArc<HarmonicGravity>) -> u16 {
    handle.0.max_order()
}

#[rustler::nif]
fn harmonic_gravity_tide_system(handle: ResourceArc<HarmonicGravity>) -> TidalConvention {
    handle.0.tide_system().into()
}

#[rustler::nif]
fn harmonic_gravity_is_time_variable(handle: ResourceArc<HarmonicGravity>) -> bool {
    handle.0.is_time_variable()
}
