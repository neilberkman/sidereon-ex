//! Rustler boundary for inverse SGP4 TLE fitting.
//!
//! The NIF decodes sample arcs and solver options, delegates to the core fitter,
//! and encodes the returned elements, TLE lines, OMM text, and diagnostics.

use rustler::{Encoder, Env, Term};
use sidereon_core::astro::omm::encode_kvn;
use sidereon_core::astro::sgp4::{
    fit_tle, ElementSet, FitConfig, FitEpoch, FitSample, JulianDate, Loss, OpsMode, TleFit,
    TleFitError, TleMetadata, XScale,
};

type Vec3 = (f64, f64, f64);

mod atoms {
    rustler::atoms! {
        ok,
        error,
        did_not_converge,
        invalid_input
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
    bstar: f64,
    mean_motion_dot: f64,
    mean_motion_double_dot: f64,
    eccentricity: f64,
    argument_of_perigee_deg: f64,
    inclination_deg: f64,
    mean_anomaly_deg: f64,
    mean_motion_rev_per_day: f64,
    right_ascension_deg: f64,
    catalog_number: u32,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct FitStatsTerm {
    rms_position_km: f64,
    max_position_km: f64,
    rms_position_axes_km: Vec<f64>,
    rms_velocity_km_s: Option<f64>,
    tle_rms_position_km: f64,
    status: i32,
    nfev: i64,
    njev: i64,
    cost: f64,
    optimality: f64,
    bstar_observable: bool,
    seed_refine_passes: i64,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct TleFitTerm {
    elements: ElementSetTerm,
    line1: String,
    line2: String,
    omm_kvn: String,
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

impl From<TleFit> for TleFitTerm {
    fn from(value: TleFit) -> Self {
        let stats = value.stats;
        Self {
            elements: ElementSetTerm::from(&value.elements),
            line1: value.line1,
            line2: value.line2,
            omm_kvn: encode_kvn(&value.omm),
            stats: FitStatsTerm {
                rms_position_km: stats.rms_position_km,
                max_position_km: stats.max_position_km,
                rms_position_axes_km: stats.rms_position_axes_km.to_vec(),
                rms_velocity_km_s: stats.rms_velocity_km_s,
                tle_rms_position_km: stats.tle_rms_position_km,
                status: stats.status,
                nfev: stats.nfev as i64,
                njev: stats.njev as i64,
                cost: stats.cost,
                optimality: stats.optimality,
                bstar_observable: stats.bstar_observable,
                seed_refine_passes: stats.seed_refine_passes as i64,
            },
        }
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
        Ok(fit) => (atoms::ok(), TleFitTerm::from(fit)).encode(env),
        Err(TleFitError::DidNotConverge { result }) => (
            atoms::error(),
            (atoms::did_not_converge(), TleFitTerm::from(*result)),
        )
            .encode(env),
        Err(error) => (atoms::error(), error.to_string()).encode(env),
    }
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
