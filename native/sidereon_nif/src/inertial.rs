use rustler::{Error, NifResult};
use sidereon_core::inertial::{
    attitude_yaw_pitch_roll_rad, dcm_to_quaternion, gauss_markov_bias_decay,
    gauss_markov_bias_variance_increment, gravity_ecef_mps2, normal_gravity_mps2,
    quaternion_to_dcm, AttitudeQuaternion,
};

type Mat3 = [[f64; 3]; 3];

mod atoms {
    rustler::atoms! {
        invalid_input,
        non_monotonic_sample,
        singular_calibration,
        degenerate_attitude
    }
}

pub(crate) fn normal_gravity(lat_rad: f64, height_m: f64) -> NifResult<f64> {
    normal_gravity_mps2(lat_rad, height_m).map_err(inertial_error)
}

pub(crate) fn gravity_ecef(position_ecef_m: (f64, f64, f64)) -> NifResult<(f64, f64, f64)> {
    let gravity = gravity_ecef_mps2([position_ecef_m.0, position_ecef_m.1, position_ecef_m.2])
        .map_err(inertial_error)?;
    Ok((gravity[0], gravity[1], gravity[2]))
}

pub(crate) fn quaternion_from_dcm(rows: Vec<Vec<f64>>) -> NifResult<(f64, f64, f64, f64)> {
    let dcm = matrix3(rows)?;
    let quaternion = dcm_to_quaternion(&dcm).map_err(inertial_error)?;
    Ok((quaternion.w, quaternion.x, quaternion.y, quaternion.z))
}

pub(crate) fn dcm_from_quaternion(quaternion: (f64, f64, f64, f64)) -> NifResult<Vec<Vec<f64>>> {
    let quaternion =
        AttitudeQuaternion::new(quaternion.0, quaternion.1, quaternion.2, quaternion.3)
            .map_err(inertial_error)?;
    Ok(quaternion_to_dcm(quaternion)
        .into_iter()
        .map(|row| row.to_vec())
        .collect())
}

pub(crate) fn yaw_pitch_roll(rows: Vec<Vec<f64>>) -> NifResult<(f64, f64, f64)> {
    let values = attitude_yaw_pitch_roll_rad(&matrix3(rows)?);
    Ok((values[0], values[1], values[2]))
}

pub(crate) fn bias_decay(dt_s: f64, tau_s: Option<f64>) -> NifResult<f64> {
    gauss_markov_bias_decay(dt_s, tau_s.unwrap_or(f64::INFINITY)).map_err(inertial_error)
}

pub(crate) fn bias_variance_increment(
    instability: f64,
    dt_s: f64,
    tau_s: Option<f64>,
) -> NifResult<f64> {
    gauss_markov_bias_variance_increment(instability, dt_s, tau_s.unwrap_or(f64::INFINITY))
        .map_err(inertial_error)
}

fn matrix3(rows: Vec<Vec<f64>>) -> NifResult<Mat3> {
    if rows.len() != 3 || rows.iter().any(|row| row.len() != 3) {
        return Err(Error::Term(Box::new("attitude matrix must be 3x3")));
    }
    Ok([
        [rows[0][0], rows[0][1], rows[0][2]],
        [rows[1][0], rows[1][1], rows[1][2]],
        [rows[2][0], rows[2][1], rows[2][2]],
    ])
}

fn inertial_error(error: sidereon_core::inertial::InertialError) -> Error {
    use sidereon_core::inertial::InertialError;

    match error {
        InertialError::InvalidInput { field, reason } => {
            Error::Term(Box::new((atoms::invalid_input(), field, reason)))
        }
        InertialError::NonMonotonicSample => Error::Term(Box::new(atoms::non_monotonic_sample())),
        InertialError::SingularCalibration => Error::Term(Box::new(atoms::singular_calibration())),
        InertialError::DegenerateAttitude => Error::Term(Box::new(atoms::degenerate_attitude())),
    }
}
