//! Rustler boundary for core force-model acceleration helpers.

use rustler::{Error, NifResult};
use sidereon_core::astro::forces::{ForceModel, J2Gravity, TwoBodyGravity};
use sidereon_core::astro::propagator::api::PropagationContext;
use sidereon_core::astro::state::CartesianState;

type Vec3 = (f64, f64, f64);

pub(crate) fn twobody_acceleration_impl(position: Vec3, velocity: Vec3) -> NifResult<Vec3> {
    acceleration_impl(&TwoBodyGravity::default(), position, velocity)
}

pub(crate) fn j2_acceleration_impl(position: Vec3, velocity: Vec3) -> NifResult<Vec3> {
    acceleration_impl(&J2Gravity::default(), position, velocity)
}

fn acceleration_impl(force: &impl ForceModel, position: Vec3, velocity: Vec3) -> NifResult<Vec3> {
    let state = CartesianState::new(
        0.0,
        [position.0, position.1, position.2],
        [velocity.0, velocity.1, velocity.2],
    );
    let acceleration = force
        .acceleration(&state, &PropagationContext::default())
        .map_err(|_| Error::BadArg)?;
    Ok((acceleration.x, acceleration.y, acceleration.z))
}
