//! Rustler boundary for covariance-derived position error metrics.

use std::collections::BTreeMap;

use rustler::{Encoder, Env, Error, NifResult, Term};
use sidereon_core::error_metrics::{
    metrics_from_ecef_covariance_m2, metrics_from_enu_covariance_m2,
    metrics_from_kinematic_solution, ErrorEllipse, ErrorMetricsError, PercentileRadius,
    PositionErrorMetrics,
};
use sidereon_core::frame::Wgs84Geodetic;
use sidereon_core::precise_positioning::{KinematicEpochSolution, KinematicEpochStatus};

mod atoms {
    rustler::atoms! {
        ok,
        error,
        non_finite,
        not_positive_semidefinite,
        invalid_probability,
        rotation
    }
}

type Vec3 = (f64, f64, f64);

#[derive(Debug, Clone, rustler::NifMap)]
struct ErrorEllipseTerm {
    semi_major_m: f64,
    semi_minor_m: f64,
    orientation_rad: f64,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct PercentileRadiusTerm {
    probability: f64,
    radius_m: f64,
    approx_m: f64,
    approx_valid: bool,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct PositionErrorMetricsTerm {
    ellipse: ErrorEllipseTerm,
    sigma_e_m: f64,
    sigma_n_m: f64,
    sigma_u_m: f64,
    cep_m: PercentileRadiusTerm,
    r95_m: PercentileRadiusTerm,
    r99_m: PercentileRadiusTerm,
    drms_m: f64,
    two_drms_m: f64,
    vep_m: f64,
    sep_m: PercentileRadiusTerm,
    mrse_m: f64,
}

fn matrix3(rows: Vec<Vec<f64>>) -> NifResult<[[f64; 3]; 3]> {
    if rows.len() != 3 || rows.iter().any(|row| row.len() != 3) {
        return Err(Error::Term(Box::new("matrix must be 3x3")));
    }
    Ok([
        [rows[0][0], rows[0][1], rows[0][2]],
        [rows[1][0], rows[1][1], rows[1][2]],
        [rows[2][0], rows[2][1], rows[2][2]],
    ])
}

fn receiver((lat_rad, lon_rad, height_m): Vec3) -> NifResult<Wgs84Geodetic> {
    Wgs84Geodetic::new(lat_rad, lon_rad, height_m).map_err(crate::errors::invalid_input)
}

fn percentile_term(value: PercentileRadius) -> PercentileRadiusTerm {
    PercentileRadiusTerm {
        probability: value.probability,
        radius_m: value.radius_m,
        approx_m: value.approx_m,
        approx_valid: value.approx_valid,
    }
}

fn ellipse_term(value: ErrorEllipse) -> ErrorEllipseTerm {
    ErrorEllipseTerm {
        semi_major_m: value.semi_major_m,
        semi_minor_m: value.semi_minor_m,
        orientation_rad: value.orientation_rad,
    }
}

fn metrics_term(value: PositionErrorMetrics) -> PositionErrorMetricsTerm {
    PositionErrorMetricsTerm {
        ellipse: ellipse_term(value.ellipse),
        sigma_e_m: value.sigma_e_m,
        sigma_n_m: value.sigma_n_m,
        sigma_u_m: value.sigma_u_m,
        cep_m: percentile_term(value.cep_m),
        r95_m: percentile_term(value.r95_m),
        r99_m: percentile_term(value.r99_m),
        drms_m: value.drms_m,
        two_drms_m: value.two_drms_m,
        vep_m: value.vep_m,
        sep_m: percentile_term(value.sep_m),
        mrse_m: value.mrse_m,
    }
}

fn error_atom(error: ErrorMetricsError) -> rustler::Atom {
    match error {
        ErrorMetricsError::NonFinite => atoms::non_finite(),
        ErrorMetricsError::NotPositiveSemidefinite => atoms::not_positive_semidefinite(),
        ErrorMetricsError::InvalidProbability => atoms::invalid_probability(),
        ErrorMetricsError::Rotation(_) => atoms::rotation(),
    }
}

fn encode_metrics<'a>(
    env: Env<'a>,
    result: Result<PositionErrorMetrics, ErrorMetricsError>,
) -> Term<'a> {
    match result {
        Ok(value) => (atoms::ok(), metrics_term(value)).encode(env),
        Err(error) => (atoms::error(), error_atom(error)).encode(env),
    }
}

/// Compute position error metrics from an ENU covariance matrix in m^2.
#[rustler::nif]
fn position_error_metrics_from_enu_covariance<'a>(
    env: Env<'a>,
    covariance_enu_m2: Vec<Vec<f64>>,
) -> NifResult<Term<'a>> {
    Ok(encode_metrics(
        env,
        metrics_from_enu_covariance_m2(matrix3(covariance_enu_m2)?),
    ))
}

/// Rotate an ECEF covariance to ENU and compute position error metrics.
#[rustler::nif]
fn position_error_metrics_from_ecef_covariance<'a>(
    env: Env<'a>,
    covariance_ecef_m2: Vec<Vec<f64>>,
    receiver_llh_rad_m: Vec3,
) -> NifResult<Term<'a>> {
    Ok(encode_metrics(
        env,
        metrics_from_ecef_covariance_m2(
            matrix3(covariance_ecef_m2)?,
            receiver(receiver_llh_rad_m)?,
        ),
    ))
}

/// Compute position error metrics from the public kinematic solution shape.
#[rustler::nif]
fn position_error_metrics_from_kinematic_solution<'a>(
    env: Env<'a>,
    position_m: Vec3,
    position_covariance_m2: Vec<Vec<f64>>,
) -> NifResult<Term<'a>> {
    let solution = KinematicEpochSolution {
        position_m: [position_m.0, position_m.1, position_m.2],
        clock_m: 0.0,
        ztd_residual_m: 0.0,
        ambiguities_m: BTreeMap::new(),
        position_covariance_m2: matrix3(position_covariance_m2)?,
        used_sats: Vec::new(),
        innovation_rms_m: 0.0,
        status: KinematicEpochStatus::Updated,
    };
    Ok(encode_metrics(
        env,
        metrics_from_kinematic_solution(&solution),
    ))
}
