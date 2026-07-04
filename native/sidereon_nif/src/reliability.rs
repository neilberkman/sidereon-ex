//! Rustler boundary for classical reliability diagnostics.
//!
//! The Baarda noncentrality, MDB, redundancy, and external reliability
//! calculations live in `sidereon_core::quality`. This module only converts
//! Elixir terms to core inputs and encodes the core report back.

use rustler::{Encoder, Env, NifResult, Term};
use sidereon_core::araim::{AraimError, AraimGeometry, Ism};
use sidereon_core::quality::{
    reliability_araim as core_reliability_araim, reliability_design as core_reliability_design,
    wtest_noncentrality as core_wtest_noncentrality, ObservationReliability, QualityError,
    RangeReliabilityRow, ReliabilityOptions, ReliabilityReport, ReliabilitySummary,
};

type DesignRowTerm = (String, Vec<f64>, f64);
type OptionsTerm = (f64, f64, Option<f64>, f64);
type Vec3 = (f64, f64, f64);

mod atoms {
    rustler::atoms! {
        ok,
        error,
        invalid_elevation,
        missing_cn0,
        invalid_parameter,
        invalid_probability,
        invalid_system_count,
        invalid_dof,
        invalid_weight,
        invalid_reliability_parameter,
        invalid_residuals,
        invalid_design,
        singular_geometry,
        insufficient_geometry,
        unmonitorable_fault_mass,
        numerical_failure,
        invalid_ism,
        invalid_allocation
    }
}

#[derive(Debug, Clone, rustler::NifMap)]
struct WTestTerm {
    delta0: f64,
    lambda0: f64,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct ObservationReliabilityTerm {
    id: String,
    redundancy: f64,
    mdb_m: Option<f64>,
    external_enu_m: Option<Vec3>,
    bias_to_noise: Option<f64>,
    uncheckable: bool,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct ReliabilitySummaryTerm {
    n_obs: i64,
    n_params: i64,
    dof: i64,
    sum_redundancy: f64,
    lambda0: f64,
    max_mdb_m: Option<(String, f64)>,
    min_redundancy: (String, f64),
    n_uncheckable: i64,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct ReliabilityReportTerm {
    per_observation: Vec<ObservationReliabilityTerm>,
    summary: ReliabilitySummaryTerm,
}

fn decode_design_row((id, design_row, sigma_m): DesignRowTerm) -> RangeReliabilityRow {
    RangeReliabilityRow {
        id,
        design_row,
        sigma_m,
    }
}

fn decode_options(
    (alpha, power, lambda0_override, min_redundancy): OptionsTerm,
) -> ReliabilityOptions {
    ReliabilityOptions {
        alpha,
        beta: 1.0 - power,
        lambda0_override,
        min_redundancy,
    }
}

fn quality_error_atom(error: QualityError) -> rustler::Atom {
    match error {
        QualityError::InvalidElevation => atoms::invalid_elevation(),
        QualityError::MissingCn0 => atoms::missing_cn0(),
        QualityError::InvalidParameter => atoms::invalid_parameter(),
        QualityError::InvalidProbability => atoms::invalid_probability(),
        QualityError::InvalidSystemCount => atoms::invalid_system_count(),
        QualityError::InvalidDof => atoms::invalid_dof(),
        QualityError::InvalidWeight => atoms::invalid_weight(),
        QualityError::InvalidReliabilityParameter => atoms::invalid_reliability_parameter(),
        QualityError::InvalidResiduals => atoms::invalid_residuals(),
        QualityError::InvalidDesign => atoms::invalid_design(),
        QualityError::SingularGeometry => atoms::singular_geometry(),
    }
}

fn araim_error_atom(error: AraimError) -> rustler::Atom {
    match error {
        AraimError::InsufficientGeometry => atoms::insufficient_geometry(),
        AraimError::UnmonitorableFaultMass => atoms::unmonitorable_fault_mass(),
        AraimError::NumericalFailure => atoms::numerical_failure(),
        AraimError::InvalidIsm => atoms::invalid_ism(),
        AraimError::InvalidAllocation => atoms::invalid_allocation(),
    }
}

fn vec3(values: [f64; 3]) -> Vec3 {
    (values[0], values[1], values[2])
}

fn observation_term(value: ObservationReliability) -> ObservationReliabilityTerm {
    ObservationReliabilityTerm {
        id: value.id,
        redundancy: value.redundancy,
        mdb_m: value.mdb_m,
        external_enu_m: value.external_enu_m.map(vec3),
        bias_to_noise: value.bias_to_noise,
        uncheckable: value.uncheckable,
    }
}

fn usize_term(value: usize) -> i64 {
    value as i64
}

fn summary_term(value: ReliabilitySummary) -> ReliabilitySummaryTerm {
    ReliabilitySummaryTerm {
        n_obs: usize_term(value.n_obs),
        n_params: usize_term(value.n_params),
        dof: usize_term(value.dof),
        sum_redundancy: value.sum_redundancy,
        lambda0: value.lambda0,
        max_mdb_m: value.max_mdb_m,
        min_redundancy: value.min_redundancy,
        n_uncheckable: usize_term(value.n_uncheckable),
    }
}

fn report_term(value: ReliabilityReport) -> ReliabilityReportTerm {
    ReliabilityReportTerm {
        per_observation: value
            .per_observation
            .into_iter()
            .map(observation_term)
            .collect(),
        summary: summary_term(value.summary),
    }
}

fn geometry_from_terms(
    rows: Vec<crate::araim::RowTerm>,
    receiver: crate::araim::ReceiverTerm,
    clock_systems: Vec<String>,
) -> NifResult<AraimGeometry> {
    Ok(AraimGeometry {
        rows: rows
            .into_iter()
            .map(crate::araim::decode_row)
            .collect::<NifResult<_>>()?,
        receiver: crate::araim::decode_receiver(receiver)?,
        clock_systems: clock_systems
            .iter()
            .map(|system| crate::araim::system_from_term(system))
            .collect::<NifResult<_>>()?,
    })
}

fn ism_from_terms(
    constellations: Vec<crate::araim::ConstellationTerm>,
    satellites: Vec<crate::araim::SatelliteTerm>,
) -> NifResult<Ism> {
    Ok(Ism::new(
        constellations
            .into_iter()
            .map(crate::araim::decode_constellation)
            .collect::<NifResult<_>>()?,
        satellites
            .into_iter()
            .map(crate::araim::decode_satellite)
            .collect::<NifResult<_>>()?,
    ))
}

/// Return the core default reliability options as `{alpha, power, lambda0, min_redundancy}`.
#[rustler::nif]
fn reliability_default_options() -> OptionsTerm {
    let options = ReliabilityOptions::default();
    (
        options.alpha,
        1.0 - options.beta,
        options.lambda0_override,
        options.min_redundancy,
    )
}

/// Compute Baarda's W-test noncentrality from false-alarm probability and detection power.
#[rustler::nif]
fn reliability_wtest_noncentrality<'a>(env: Env<'a>, alpha: f64, power: f64) -> Term<'a> {
    match core_wtest_noncentrality(alpha, 1.0 - power) {
        Ok(lambda0) => (
            atoms::ok(),
            WTestTerm {
                delta0: lambda0.sqrt(),
                lambda0,
            },
        )
            .encode(env),
        Err(error) => (atoms::error(), quality_error_atom(error)).encode(env),
    }
}

/// Compute reliability from a caller-supplied weighted design.
#[rustler::nif(schedule = "DirtyCpu")]
fn reliability_design<'a>(
    env: Env<'a>,
    rows: Vec<DesignRowTerm>,
    options: OptionsTerm,
) -> Term<'a> {
    let rows = rows.into_iter().map(decode_design_row).collect::<Vec<_>>();
    match core_reliability_design(&rows, &decode_options(options)) {
        Ok(report) => (atoms::ok(), report_term(report)).encode(env),
        Err(error) => (atoms::error(), quality_error_atom(error)).encode(env),
    }
}

/// Compute reliability from ARAIM geometry and ISM inputs.
#[rustler::nif(schedule = "DirtyCpu")]
fn reliability_araim<'a>(
    env: Env<'a>,
    rows: Vec<crate::araim::RowTerm>,
    receiver: crate::araim::ReceiverTerm,
    clock_systems: Vec<String>,
    constellations: Vec<crate::araim::ConstellationTerm>,
    satellites: Vec<crate::araim::SatelliteTerm>,
    options: OptionsTerm,
) -> NifResult<Term<'a>> {
    let geometry = geometry_from_terms(rows, receiver, clock_systems)?;
    let ism = ism_from_terms(constellations, satellites)?;
    Ok(
        match core_reliability_araim(&geometry, &ism, &decode_options(options)) {
            Ok(report) => (atoms::ok(), report_term(report)).encode(env),
            Err(error) => (atoms::error(), araim_error_atom(error)).encode(env),
        },
    )
}
