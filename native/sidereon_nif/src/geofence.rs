//! Rustler boundary for geodesic geofencing.
//!
//! This module is glue over `sidereon_core::geofence`: it owns the fence
//! resource, converts public degree inputs into core WGS84 geodetic positions,
//! decodes uncertainty descriptors, and preserves typed core errors.

use rustler::{Encoder, Env, ResourceArc, Term};
use sidereon_core::error_metrics::{ErrorMetricsError, PercentileRadius};
use sidereon_core::{
    containment, containment_probability_with_options, crossing, crossing_probability_with_options,
    distance_to_boundary, CrossingEvent, CrossingKind, Fence, GeofenceError,
    GeofencePositionEstimate, PositionUncertainty, ProbabilityHysteresis, ProbabilityMethod,
    ProbabilityOptions, Wgs84Geodetic,
};

type PositionTerm = (f64, f64, f64);

mod atoms {
    rustler::atoms! {
        ok,
        error,
        entered,
        left,
        too_few_vertices,
        invalid_input,
        geodesic,
        covariance_rotation_failed,
        uncertainty_validation_failed,
        non_finite,
        not_positive_semidefinite,
        invalid_probability,
        invalid_uncertainty,
        invalid_probability_method
    }
}

/// Resource handle for a constructed WGS84 geofence polygon.
pub struct GeofenceResource {
    fence: Fence,
}

#[rustler::resource_impl]
impl rustler::Resource for GeofenceResource {}

#[derive(Debug, Clone, rustler::NifMap)]
struct UncertaintyTerm {
    kind: String,
    covariance_m2: Option<Vec<Vec<f64>>>,
    probability: Option<f64>,
    radius_m: Option<f64>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct ProbabilitySampleTerm {
    position: PositionTerm,
    uncertainty: UncertaintyTerm,
}

/// Construct a WGS84 geodesic polygon fence from degree vertices.
#[rustler::nif(schedule = "DirtyCpu")]
fn geofence_new<'a>(env: Env<'a>, vertices: Vec<PositionTerm>) -> Term<'a> {
    let vertices = match vertices
        .into_iter()
        .map(position_from_term)
        .collect::<Result<Vec<_>, _>>()
    {
        Ok(vertices) => vertices,
        Err(error) => return (atoms::error(), boundary_error_term(env, error)).encode(env),
    };

    match Fence::new(vertices) {
        Ok(fence) => (atoms::ok(), ResourceArc::new(GeofenceResource { fence })).encode(env),
        Err(error) => (atoms::error(), geofence_error_term(env, error)).encode(env),
    }
}

/// Boolean containment for one WGS84 degree position.
#[rustler::nif(schedule = "DirtyCpu")]
fn geofence_contains<'a>(
    env: Env<'a>,
    handle: ResourceArc<GeofenceResource>,
    position: PositionTerm,
) -> Term<'a> {
    let position = match position_from_term(position) {
        Ok(position) => position,
        Err(error) => return (atoms::error(), boundary_error_term(env, error)).encode(env),
    };
    match containment(position, &handle.fence) {
        Ok(inside) => (atoms::ok(), inside).encode(env),
        Err(error) => (atoms::error(), geofence_error_term(env, error)).encode(env),
    }
}

/// Signed boundary distance for one WGS84 degree position, in metres.
#[rustler::nif(schedule = "DirtyCpu")]
fn geofence_distance_to_boundary<'a>(
    env: Env<'a>,
    handle: ResourceArc<GeofenceResource>,
    position: PositionTerm,
) -> Term<'a> {
    let position = match position_from_term(position) {
        Ok(position) => position,
        Err(error) => return (atoms::error(), boundary_error_term(env, error)).encode(env),
    };
    match distance_to_boundary(position, &handle.fence) {
        Ok(distance_m) => (atoms::ok(), distance_m).encode(env),
        Err(error) => (atoms::error(), geofence_error_term(env, error)).encode(env),
    }
}

/// Containment probability for one uncertain WGS84 degree position.
#[rustler::nif(schedule = "DirtyCpu")]
fn geofence_containment_probability<'a>(
    env: Env<'a>,
    handle: ResourceArc<GeofenceResource>,
    position: PositionTerm,
    uncertainty: UncertaintyTerm,
    method: String,
) -> Term<'a> {
    let position = match position_from_term(position) {
        Ok(position) => position,
        Err(error) => return (atoms::error(), boundary_error_term(env, error)).encode(env),
    };
    let uncertainty = match decode_uncertainty(uncertainty) {
        Ok(uncertainty) => uncertainty,
        Err(error) => return (atoms::error(), boundary_error_term(env, error)).encode(env),
    };
    let options = match probability_options(&method) {
        Ok(options) => options,
        Err(error) => return (atoms::error(), boundary_error_term(env, error)).encode(env),
    };

    match containment_probability_with_options(position, uncertainty, &handle.fence, options) {
        Ok(probability) => (atoms::ok(), probability).encode(env),
        Err(error) => (atoms::error(), geofence_error_term(env, error)).encode(env),
    }
}

/// Boolean crossing detection over a sequence of WGS84 degree positions.
#[rustler::nif(schedule = "DirtyCpu")]
fn geofence_crossing<'a>(
    env: Env<'a>,
    handle: ResourceArc<GeofenceResource>,
    positions: Vec<PositionTerm>,
) -> Term<'a> {
    let positions = match positions
        .into_iter()
        .map(position_from_term)
        .collect::<Result<Vec<_>, _>>()
    {
        Ok(positions) => positions,
        Err(error) => return (atoms::error(), boundary_error_term(env, error)).encode(env),
    };
    match crossing(&positions, &handle.fence) {
        Ok(events) => (atoms::ok(), encode_events(env, &events)).encode(env),
        Err(error) => (atoms::error(), geofence_error_term(env, error)).encode(env),
    }
}

/// Probabilistic crossing detection over uncertain WGS84 degree positions.
#[rustler::nif(schedule = "DirtyCpu")]
fn geofence_crossing_probability<'a>(
    env: Env<'a>,
    handle: ResourceArc<GeofenceResource>,
    samples: Vec<ProbabilitySampleTerm>,
    enter_confidence: f64,
    leave_confidence: f64,
    method: String,
) -> Term<'a> {
    let samples = match samples
        .into_iter()
        .map(|sample| {
            Ok(GeofencePositionEstimate {
                position: position_from_term(sample.position)?,
                uncertainty: decode_uncertainty(sample.uncertainty)?,
            })
        })
        .collect::<Result<Vec<_>, _>>()
    {
        Ok(samples) => samples,
        Err(error) => return (atoms::error(), boundary_error_term(env, error)).encode(env),
    };
    let hysteresis = match ProbabilityHysteresis::new(enter_confidence, leave_confidence) {
        Ok(hysteresis) => hysteresis,
        Err(error) => return (atoms::error(), geofence_error_term(env, error)).encode(env),
    };
    let options = match probability_options(&method) {
        Ok(options) => options,
        Err(error) => return (atoms::error(), boundary_error_term(env, error)).encode(env),
    };

    match crossing_probability_with_options(&samples, &handle.fence, hysteresis, options) {
        Ok(events) => (atoms::ok(), encode_events(env, &events)).encode(env),
        Err(error) => (atoms::error(), geofence_error_term(env, error)).encode(env),
    }
}

#[derive(Debug, Clone)]
enum BoundaryError {
    Geofence(GeofenceError),
    InvalidInput { field: &'static str, reason: String },
    InvalidUncertainty,
    InvalidProbabilityMethod,
}

fn position_from_term(
    (lat_deg, lon_deg, height_m): PositionTerm,
) -> Result<Wgs84Geodetic, BoundaryError> {
    Wgs84Geodetic::new(lat_deg.to_radians(), lon_deg.to_radians(), height_m).map_err(|error| {
        BoundaryError::InvalidInput {
            field: "position",
            reason: error.to_string(),
        }
    })
}

fn decode_uncertainty(term: UncertaintyTerm) -> Result<PositionUncertainty, BoundaryError> {
    match term.kind.as_str() {
        "enu_covariance_m2" => Ok(PositionUncertainty::EnuCovarianceM2(matrix3(
            term.covariance_m2,
        )?)),
        "ecef_covariance_m2" => Ok(PositionUncertainty::EcefCovarianceM2(matrix3(
            term.covariance_m2,
        )?)),
        "cep_radius_m" => Ok(PositionUncertainty::CepRadiusM(
            term.radius_m.ok_or(BoundaryError::InvalidUncertainty)?,
        )),
        "horizontal_radius_m" => Ok(PositionUncertainty::HorizontalRadius(PercentileRadius {
            probability: term.probability.ok_or(BoundaryError::InvalidUncertainty)?,
            radius_m: term.radius_m.ok_or(BoundaryError::InvalidUncertainty)?,
            approx_m: term.radius_m.unwrap_or(0.0),
            approx_valid: true,
        })),
        _ => Err(BoundaryError::InvalidUncertainty),
    }
}

fn matrix3(matrix: Option<Vec<Vec<f64>>>) -> Result<[[f64; 3]; 3], BoundaryError> {
    let matrix = matrix.ok_or(BoundaryError::InvalidUncertainty)?;
    if matrix.len() != 3 || matrix.iter().any(|row| row.len() != 3) {
        return Err(BoundaryError::InvalidInput {
            field: "covariance_m2",
            reason: "must be 3x3".to_string(),
        });
    }
    Ok([
        [matrix[0][0], matrix[0][1], matrix[0][2]],
        [matrix[1][0], matrix[1][1], matrix[1][2]],
        [matrix[2][0], matrix[2][1], matrix[2][2]],
    ])
}

fn probability_options(method: &str) -> Result<ProbabilityOptions, BoundaryError> {
    let method = match method {
        "boundary_normal" => ProbabilityMethod::BoundaryNormal,
        "planar_quadrature" => ProbabilityMethod::PlanarQuadrature,
        _ => return Err(BoundaryError::InvalidProbabilityMethod),
    };
    let mut options = ProbabilityOptions::default();
    options.method = method;
    Ok(options)
}

fn encode_events<'a>(env: Env<'a>, events: &[CrossingEvent]) -> Vec<Term<'a>> {
    events
        .iter()
        .map(|event| {
            let kind = match event.kind {
                CrossingKind::Entered => atoms::entered(),
                CrossingKind::Left => atoms::left(),
            };
            (event.sample_index as i64, kind, event.inside_probability).encode(env)
        })
        .collect()
}

fn geofence_error_term<'a>(env: Env<'a>, error: GeofenceError) -> Term<'a> {
    boundary_error_term(env, BoundaryError::Geofence(error))
}

fn boundary_error_term<'a>(env: Env<'a>, error: BoundaryError) -> Term<'a> {
    match error {
        BoundaryError::Geofence(GeofenceError::TooFewVertices) => {
            atoms::too_few_vertices().encode(env)
        }
        BoundaryError::Geofence(GeofenceError::InvalidInput { field, reason }) => {
            (atoms::invalid_input(), field, reason).encode(env)
        }
        BoundaryError::Geofence(GeofenceError::Geodesic(error)) => {
            (atoms::geodesic(), error.to_string()).encode(env)
        }
        BoundaryError::Geofence(GeofenceError::Dop(_)) => {
            atoms::covariance_rotation_failed().encode(env)
        }
        BoundaryError::Geofence(GeofenceError::ErrorMetrics(error)) => (
            atoms::uncertainty_validation_failed(),
            error_metrics_atom(error),
        )
            .encode(env),
        BoundaryError::InvalidInput { field, reason } => {
            (atoms::invalid_input(), field, reason).encode(env)
        }
        BoundaryError::InvalidUncertainty => atoms::invalid_uncertainty().encode(env),
        BoundaryError::InvalidProbabilityMethod => atoms::invalid_probability_method().encode(env),
    }
}

fn error_metrics_atom(error: ErrorMetricsError) -> rustler::Atom {
    match error {
        ErrorMetricsError::NonFinite => atoms::non_finite(),
        ErrorMetricsError::NotPositiveSemidefinite => atoms::not_positive_semidefinite(),
        ErrorMetricsError::InvalidProbability => atoms::invalid_probability(),
        ErrorMetricsError::Rotation(_) => atoms::covariance_rotation_failed(),
    }
}
