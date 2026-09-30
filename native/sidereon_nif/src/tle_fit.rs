//! Rustler boundary for inverse SGP4 TLE fitting.
//!
//! The NIF decodes sample arcs and solver options, delegates to the core fitter,
//! and encodes the returned elements, TLE lines, OMM text, and diagnostics.

use rustler::{Encoder, Env, Term};
use sidereon_core::astro::omm::{encode_kvn, OmmError};
use sidereon_core::astro::sgp4::{
    fit_tle, ElementSet, FitConfig, FitEpoch, FitSample, JulianDate, Loss, OpsMode, TleFit,
    TleFitError, TleMetadata, XScale,
};
use trust_region_least_squares::trf::{BackendError, TrfError};

type Vec3 = (f64, f64, f64);

mod atoms {
    rustler::atoms! {
        ok,
        error,
        did_not_converge,
        invalid_input,
        omm_kvn,
        tle_fit_error,
        arc_too_short,
        epochs_not_increasing,
        epoch_outside_arc,
        mixed_velocity_presence,
        not_elliptical,
        inclination_near_retrograde,
        seed_propagation,
        solver,
        solution_infeasible,
        final_elements,
        tle_encode,
        trf_error,
        empty_residual,
        empty_parameters,
        non_finite_parameters,
        non_finite_initial_residual,
        insufficient_rows,
        size_overflow,
        degree_overflow,
        invalid_max_nfev,
        invalid_f_scale,
        invalid_x_scale_length,
        invalid_x_scale_value,
        invalid_jacobian_length,
        invalid_residual_length,
        invalid_slice_length,
        invalid_svd_output,
        backend_error,
        backend_failed,
        backend_bad_dimensions,
    }
}

#[derive(Debug, Clone, rustler::NifMap)]
struct FitSampleTerm {
    epoch: (f64, f64),
    position_teme_km: Vec3,
    velocity_teme_km_s: Option<Vec3>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct MetadataTerm {
    catalog_number: u32,
    classification: String,
    international_designator: String,
    element_set_number: i32,
    rev_at_epoch: i64,
    object_name: String,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct FitConfigTerm {
    epoch_kind: String,
    epoch_jd: Option<(f64, f64)>,
    epoch_sample: Option<i64>,
    fit_bstar: bool,
    bstar_seed: f64,
    use_velocity: bool,
    velocity_weight_s: Option<f64>,
    weights: Option<Vec<f64>>,
    opsmode: String,
    ftol: Option<f64>,
    xtol: Option<f64>,
    gtol: Option<f64>,
    max_nfev: Option<i64>,
    x_scale_kind: String,
    x_scale_values: Option<Vec<f64>>,
    loss: String,
    f_scale: f64,
    metadata: MetadataTerm,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct ElementSetTerm {
    epoch: (f64, f64),
    omm_epoch_days: Option<f64>,
    bstar: f64,
    mean_motion_dot: Option<f64>,
    mean_motion_double_dot: Option<f64>,
    eccentricity: f64,
    argument_of_perigee_deg: f64,
    inclination_deg: f64,
    mean_anomaly_deg: f64,
    mean_motion_rev_per_day: f64,
    right_ascension_deg: f64,
    catalog_number: Option<u32>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct FitStatsTerm {
    rms_position_km: f64,
    max_position_km: f64,
    rms_position_axes_km: Vec<f64>,
    rms_velocity_km_s: Option<f64>,
    tle_rms_position_km: f64,
    status: i32,
    nfev: u64,
    njev: u64,
    cost: f64,
    optimality: f64,
    bstar_observable: bool,
    seed_refine_passes: u64,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct TleFitTerm {
    elements: ElementSetTerm,
    omm: crate::omm::OmmFields,
    line1: String,
    line2: String,
    omm_kvn: Option<String>,
    omm_exact_sgp4_epoch: Option<(f64, f64)>,
    omm_quantize_tle_derived_fields: bool,
    stats: FitStatsTerm,
}

impl From<FitSampleTerm> for FitSample {
    fn from(value: FitSampleTerm) -> Self {
        Self {
            epoch: JulianDate(value.epoch.0, value.epoch.1),
            position_teme_km: [
                value.position_teme_km.0,
                value.position_teme_km.1,
                value.position_teme_km.2,
            ],
            velocity_teme_km_s: value
                .velocity_teme_km_s
                .map(|velocity| [velocity.0, velocity.1, velocity.2]),
        }
    }
}

impl From<MetadataTerm> for TleMetadata {
    fn from(value: MetadataTerm) -> Self {
        Self {
            catalog_number: value.catalog_number,
            classification: value.classification,
            international_designator: value.international_designator,
            element_set_number: value.element_set_number,
            rev_at_epoch: value.rev_at_epoch,
            object_name: value.object_name,
        }
    }
}

impl From<&ElementSet> for ElementSetTerm {
    fn from(value: &ElementSet) -> Self {
        Self {
            epoch: (value.epoch.0, value.epoch.1),
            omm_epoch_days: value.omm_epoch_days,
            bstar: value.bstar,
            mean_motion_dot: value.mean_motion_dot,
            mean_motion_double_dot: value.mean_motion_double_dot,
            eccentricity: value.eccentricity,
            argument_of_perigee_deg: value.argument_of_perigee_deg,
            inclination_deg: value.inclination_deg,
            mean_anomaly_deg: value.mean_anomaly_deg,
            mean_motion_rev_per_day: value.mean_motion_rev_per_day,
            right_ascension_deg: value.right_ascension_deg,
            catalog_number: value.catalog_number,
        }
    }
}

impl TleFitTerm {
    fn from_fit(value: TleFit) -> (Self, Option<OmmError>) {
        let omm_kvn = encode_kvn(&value.omm);
        let omm_error = omm_kvn.as_ref().err().cloned();
        let stats = value.stats;
        let term = Self {
            elements: ElementSetTerm::from(&value.elements),
            omm: value.omm.clone().into(),
            line1: value.line1,
            line2: value.line2,
            omm_kvn: omm_kvn.ok(),
            stats: FitStatsTerm {
                rms_position_km: stats.rms_position_km,
                max_position_km: stats.max_position_km,
                rms_position_axes_km: stats.rms_position_axes_km.to_vec(),
                rms_velocity_km_s: stats.rms_velocity_km_s,
                tle_rms_position_km: stats.tle_rms_position_km,
                status: stats.status,
                nfev: stats.nfev as u64,
                njev: stats.njev as u64,
                cost: stats.cost,
                optimality: stats.optimality,
                bstar_observable: stats.bstar_observable,
                seed_refine_passes: stats.seed_refine_passes as u64,
            },
            omm_exact_sgp4_epoch: value.omm.exact_sgp4_epoch.map(|epoch| (epoch.0, epoch.1)),
            omm_quantize_tle_derived_fields: value.omm.quantize_tle_derived_fields,
        };
        (term, omm_error)
    }
}

fn decode_epoch(config: &FitConfigTerm) -> Option<FitEpoch> {
    match config.epoch_kind.as_str() {
        "midpoint" => Some(FitEpoch::Midpoint),
        "first" => Some(FitEpoch::First),
        "last" => Some(FitEpoch::Last),
        "sample" => Some(FitEpoch::Sample(
            usize::try_from(config.epoch_sample?).ok()?,
        )),
        "jd" => {
            let jd = config.epoch_jd?;
            Some(FitEpoch::Jd(JulianDate(jd.0, jd.1)))
        }
        _ => None,
    }
}

fn decode_opsmode(label: &str) -> Option<OpsMode> {
    match label {
        "improved" => Some(OpsMode::Improved),
        "afspc" => Some(OpsMode::Afspc),
        _ => None,
    }
}

fn decode_loss(label: &str) -> Option<Loss> {
    match label {
        "linear" => Some(Loss::Linear),
        "soft_l1" => Some(Loss::SoftL1),
        "huber" => Some(Loss::Huber),
        "cauchy" => Some(Loss::Cauchy),
        "arctan" => Some(Loss::Arctan),
        _ => None,
    }
}

fn decode_x_scale(config: &FitConfigTerm) -> Option<Option<XScale>> {
    match config.x_scale_kind.as_str() {
        "default" => Some(None),
        "unit" => Some(Some(XScale::Unit)),
        "jac" => Some(Some(XScale::Jac)),
        "values" => Some(Some(XScale::Values(config.x_scale_values.clone()?))),
        _ => None,
    }
}

fn decode_config(config: FitConfigTerm) -> Option<FitConfig> {
    let epoch = decode_epoch(&config)?;
    let opsmode = decode_opsmode(&config.opsmode)?;
    let x_scale = decode_x_scale(&config)?;
    let loss = decode_loss(&config.loss)?;
    let max_nfev = config.max_nfev.map(usize::try_from).transpose().ok()?;

    let mut fit_config = FitConfig::default();
    fit_config.epoch = epoch;
    fit_config.fit_bstar = config.fit_bstar;
    fit_config.bstar_seed = config.bstar_seed;
    fit_config.use_velocity = config.use_velocity;
    fit_config.velocity_weight_s = config.velocity_weight_s;
    fit_config.weights = config.weights;
    fit_config.opsmode = opsmode;
    fit_config.ftol = config.ftol;
    fit_config.xtol = config.xtol;
    fit_config.gtol = config.gtol;
    fit_config.max_nfev = max_nfev;
    fit_config.x_scale = x_scale;
    fit_config.loss = loss;
    fit_config.f_scale = config.f_scale;
    fit_config.metadata = config.metadata.into();
    Some(fit_config)
}

fn encode_fit_result<'a>(env: Env<'a>, result: Result<TleFit, TleFitError>) -> Term<'a> {
    match result {
        Ok(fit) => {
            let (term, omm_error) = TleFitTerm::from_fit(fit);
            match omm_error {
                None => (atoms::ok(), term).encode(env),
                Some(error) => (
                    atoms::error(),
                    (
                        atoms::omm_kvn(),
                        crate::ndm_errors::omm_error_term(env, &error),
                        term,
                    ),
                )
                    .encode(env),
            }
        }
        Err(TleFitError::DidNotConverge { result }) => {
            let (term, omm_error) = TleFitTerm::from_fit(*result);
            let result = match omm_error {
                None => (atoms::did_not_converge(), term).encode(env),
                Some(error) => (
                    atoms::did_not_converge(),
                    (
                        atoms::omm_kvn(),
                        crate::ndm_errors::omm_error_term(env, &error),
                        term,
                    ),
                )
                    .encode(env),
            };
            (atoms::error(), result).encode(env)
        }
        Err(error) => (atoms::error(), tle_fit_error_term(env, &error)).encode(env),
    }
}

fn tle_fit_error_term<'a>(env: Env<'a>, error: &TleFitError) -> Term<'a> {
    use TleFitError as E;
    let (kind, detail) = match error {
        E::ArcTooShort { samples, needed } => (
            atoms::arc_too_short().encode(env),
            (*samples as u64, *needed as u64).encode(env),
        ),
        E::InvalidInput { field, reason } => (
            atoms::invalid_input().encode(env),
            (*field, *reason).encode(env),
        ),
        E::EpochsNotIncreasing { index } => (
            atoms::epochs_not_increasing().encode(env),
            (*index as u64).encode(env),
        ),
        E::EpochOutsideArc => (atoms::epoch_outside_arc().encode(env), ().encode(env)),
        E::MixedVelocityPresence => (atoms::mixed_velocity_presence().encode(env), ().encode(env)),
        E::NotElliptical => (atoms::not_elliptical().encode(env), ().encode(env)),
        E::InclinationNearRetrograde { inclination_deg } => (
            atoms::inclination_near_retrograde().encode(env),
            inclination_deg.encode(env),
        ),
        E::SeedPropagation {
            epoch_index,
            source,
        } => (
            atoms::seed_propagation().encode(env),
            (
                *epoch_index as u64,
                crate::ndm_errors::sgp4_error_term(env, source),
            )
                .encode(env),
        ),
        E::Solver(source) => (atoms::solver().encode(env), trf_error_term(env, source)),
        E::SolutionInfeasible => (atoms::solution_infeasible().encode(env), ().encode(env)),
        E::DidNotConverge { result } => {
            let (term, omm_error) = TleFitTerm::from_fit((**result).clone());
            let detail = match omm_error {
                None => term.encode(env),
                Some(error) => (
                    atoms::omm_kvn(),
                    crate::ndm_errors::omm_error_term(env, &error),
                    term,
                )
                    .encode(env),
            };
            (atoms::did_not_converge().encode(env), detail)
        }
        E::FinalElements(source) => (
            atoms::final_elements().encode(env),
            crate::ndm_errors::sgp4_error_term(env, source),
        ),
        E::TleEncode(source) => (
            atoms::tle_encode().encode(env),
            crate::ndm_errors::tle_error_term(env, source),
        ),
    };
    (atoms::tle_fit_error(), kind, error.to_string(), detail).encode(env)
}

fn backend_error_term<'a>(env: Env<'a>, error: &BackendError) -> Term<'a> {
    let (kind, detail) = match error {
        BackendError::Failed(message) => (atoms::backend_failed(), message.encode(env)),
        BackendError::BadDimensions {
            expected_m,
            expected_n,
            got,
        } => (
            atoms::backend_bad_dimensions(),
            (*expected_m as u64, *expected_n as u64, *got as u64).encode(env),
        ),
    };
    (atoms::backend_error(), kind, error.to_string(), detail).encode(env)
}

fn trf_error_term<'a>(env: Env<'a>, error: &TrfError) -> Term<'a> {
    use TrfError as E;
    let (kind, detail) = match error {
        E::EmptyResidual => (atoms::empty_residual(), ().encode(env)),
        E::EmptyParameters => (atoms::empty_parameters(), ().encode(env)),
        E::NonFiniteParameters => (atoms::non_finite_parameters(), ().encode(env)),
        E::NonFiniteInitialResidual => (atoms::non_finite_initial_residual(), ().encode(env)),
        E::InsufficientRows { m, n } => (
            atoms::insufficient_rows(),
            (*m as u64, *n as u64).encode(env),
        ),
        E::SizeOverflow { m, n } => (atoms::size_overflow(), (*m as u64, *n as u64).encode(env)),
        E::DegreeOverflow { degree } => (atoms::degree_overflow(), (*degree as u64).encode(env)),
        E::InvalidMaxNfev => (atoms::invalid_max_nfev(), ().encode(env)),
        E::InvalidFScale { f_scale } => (atoms::invalid_f_scale(), f_scale.encode(env)),
        E::InvalidXScaleLength { expected, got } => (
            atoms::invalid_x_scale_length(),
            (*expected as u64, *got as u64).encode(env),
        ),
        E::InvalidXScaleValue { index, value } => (
            atoms::invalid_x_scale_value(),
            (*index as u64, value).encode(env),
        ),
        E::InvalidJacobianLength { expected, got } => (
            atoms::invalid_jacobian_length(),
            (*expected as u64, *got as u64).encode(env),
        ),
        E::InvalidResidualLength { expected, got } => (
            atoms::invalid_residual_length(),
            (*expected as u64, *got as u64).encode(env),
        ),
        E::InvalidSliceLength {
            what,
            expected,
            got,
        } => (
            atoms::invalid_slice_length(),
            (*what, *expected as u64, *got as u64).encode(env),
        ),
        E::InvalidSvdOutput(message) => (atoms::invalid_svd_output(), message.encode(env)),
        E::Backend(source) => (atoms::backend_error(), backend_error_term(env, source)),
    };
    (atoms::trf_error(), kind, error.to_string(), detail).encode(env)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn sgp4_fit_tle<'a>(
    env: Env<'a>,
    sample_terms: Vec<FitSampleTerm>,
    config: FitConfigTerm,
) -> Term<'a> {
    let Some(config) = decode_config(config) else {
        return (atoms::error(), atoms::invalid_input()).encode(env);
    };
    let samples: Vec<FitSample> = sample_terms.into_iter().map(FitSample::from).collect();
    encode_fit_result(env, fit_tle(&samples, &config))
}
