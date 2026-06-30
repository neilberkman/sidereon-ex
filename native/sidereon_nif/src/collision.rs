//! Rustler boundary for the core conjunction geometry and collision
//! probability.
//!
//! Pure glue: decode the relative states and covariances, call the relocated
//! `sidereon_core::astro::conjunction` functions, encode the result. No encounter
//! geometry or `Pc` formula lives here.

use rustler::{Atom, Encoder, Env, NifResult, Term};
use sidereon_core::astro::conjunction::{
    self, CollisionPc, ConjunctionError, ConjunctionState, EncounterFrame, PcMethod,
};

mod atoms {
    rustler::atoms! {
        ok,
        error,
        equal_area,
        numerical,
        alfano_2005,
        non_finite,
        not_positive,
        undefined_frame
    }
}

type Vec3 = (f64, f64, f64);

/// Map a hardened-core conjunction error to the snake_case atom the Elixir
/// wrapper pattern matches on. The frame is undefined when relative velocity is
/// too small, which is the historical `zero relative velocity` failure.
fn conjunction_error_atom(err: ConjunctionError) -> Atom {
    match err {
        ConjunctionError::NonFinite { .. } => atoms::non_finite(),
        ConjunctionError::NotPositive { .. } => atoms::not_positive(),
        ConjunctionError::UndefinedFrame => atoms::undefined_frame(),
    }
}

fn to_array3(v: Vec3) -> [f64; 3] {
    [v.0, v.1, v.2]
}

fn to_tuple3(v: [f64; 3]) -> Vec3 {
    (v[0], v[1], v[2])
}

/// Decode a list-of-lists covariance into a fixed 3x3 array.
fn to_mat3(rows: &[Vec<f64>]) -> NifResult<[[f64; 3]; 3]> {
    if rows.len() != 3 || rows.iter().any(|r| r.len() != 3) {
        return Err(rustler::Error::BadArg);
    }
    Ok([
        [rows[0][0], rows[0][1], rows[0][2]],
        [rows[1][0], rows[1][1], rows[1][2]],
        [rows[2][0], rows[2][1], rows[2][2]],
    ])
}

fn method_from_atom(method: Atom) -> NifResult<PcMethod> {
    if method == atoms::equal_area() {
        Ok(PcMethod::FosterEqualArea)
    } else if method == atoms::numerical() {
        Ok(PcMethod::FosterNumerical)
    } else if method == atoms::alfano_2005() {
        Ok(PcMethod::Alfano2005)
    } else {
        Err(rustler::Error::BadArg)
    }
}

/// Encode an [`EncounterFrame`] as the tuple the Elixir wrapper rebuilds the
/// `%Sidereon.Encounter.Frame{}` struct from.
fn encode_frame<'a>(env: Env<'a>, frame: &EncounterFrame) -> Term<'a> {
    (
        to_tuple3(frame.x_hat),
        to_tuple3(frame.y_hat),
        to_tuple3(frame.z_hat),
        to_tuple3(frame.relative_position_km),
        to_tuple3(frame.relative_velocity_km_s),
        frame.miss_km,
        frame.relative_speed_km_s,
    )
        .encode(env)
}

pub(crate) fn encounter_frame_impl<'a>(
    env: Env<'a>,
    r1: Vec3,
    v1: Vec3,
    r2: Vec3,
    v2: Vec3,
) -> Term<'a> {
    match conjunction::encounter_frame(to_array3(r1), to_array3(v1), to_array3(r2), to_array3(v2)) {
        Ok(frame) => (atoms::ok(), encode_frame(env, &frame)).encode(env),
        Err(err) => (atoms::error(), conjunction_error_atom(err)).encode(env),
    }
}

pub(crate) fn encounter_plane_covariance_impl(
    x_hat: Vec3,
    z_hat: Vec3,
    cov: Vec<Vec<f64>>,
) -> NifResult<Vec<Vec<f64>>> {
    let cov3 = to_mat3(&cov)?;
    // Only the x and z axes of the frame are used by the projection; the other
    // fields are irrelevant here, so build a frame with the two real axes.
    let frame = EncounterFrame {
        x_hat: to_array3(x_hat),
        y_hat: [0.0, 0.0, 0.0],
        z_hat: to_array3(z_hat),
        relative_position_km: [0.0, 0.0, 0.0],
        relative_velocity_km_s: [0.0, 0.0, 0.0],
        miss_km: 0.0,
        relative_speed_km_s: 0.0,
    };
    let c = conjunction::encounter_plane_covariance(&frame, &cov3)
        .map_err(crate::errors::invalid_input)?;
    Ok(vec![vec![c[0][0], c[0][1]], vec![c[1][0], c[1][1]]])
}

#[allow(clippy::too_many_arguments)]
pub(crate) fn collision_probability_impl<'a>(
    env: Env<'a>,
    r1: Vec3,
    v1: Vec3,
    cov1: Vec<Vec<f64>>,
    r2: Vec3,
    v2: Vec3,
    cov2: Vec<Vec<f64>>,
    hard_body_radius_km: f64,
    method: Atom,
) -> NifResult<Term<'a>> {
    let object1 = ConjunctionState {
        position_km: to_array3(r1),
        velocity_km_s: to_array3(v1),
        covariance_km2: to_mat3(&cov1)?,
    };
    let object2 = ConjunctionState {
        position_km: to_array3(r2),
        velocity_km_s: to_array3(v2),
        covariance_km2: to_mat3(&cov2)?,
    };
    let method = method_from_atom(method)?;

    match conjunction::collision_probability(&object1, &object2, hard_body_radius_km, method) {
        Ok(CollisionPc {
            pc,
            miss_km,
            relative_speed_km_s,
            sigma_x_km,
            sigma_z_km,
        }) => Ok((
            atoms::ok(),
            (pc, miss_km, relative_speed_km_s, sigma_x_km, sigma_z_km),
        )
            .encode(env)),
        Err(err) => Ok((atoms::error(), conjunction_error_atom(err)).encode(env)),
    }
}
