mod angles;
mod antex;
mod astro_observe_almanac;
mod astro_phase_b;
mod atmosphere;
mod bias;
mod bodies;
mod broadcast;
mod broadcast_comparison;
mod carrier_phase;
mod cdm;
mod collision;
mod conjunction;
mod constellation;
mod consts;
mod covariance;
mod coverage;
mod data;
mod dgnss;
mod drag;
mod eclipse;
mod elements;
mod ephemeris;
mod errors;
mod forces;
mod frequencies;
mod gauss;
mod geoid;
mod geometry;
mod ils;
mod iod;
mod iono;
mod lambert;
mod lnav;
mod look_angle;
mod normality;
mod observables;
mod observation;
mod oem;
mod omm;
mod opm;
mod passes;
mod ppp_corrections;
mod precise_positioning;
mod precise_samples;
mod propagation;
mod qc;
mod reduced_orbit;
mod rf;
mod rinex_clock;
mod rinex_obs;
mod rtcm;
mod rtk;
mod rtk_filter;
mod sbas;
mod sgp4_batch;
mod signal;
mod sp3;
mod spp;
mod ssr;
mod staleness;
mod tides;
mod time;
mod tle;
mod trls;
mod tropo;
mod velocity;

use rustler::{Env, NifResult, Term};

// The float-producing numerics for the time-scale and frame-transform substrate
// live in the `sidereon-core` crate. The NIF entry points below are pure
// Rustler glue:
// they decode Erlang terms, call the relocated `sidereon_core::astro::` public compute
// functions, and encode the results back. No domain formula for these moved
// modules lives in `sidereon_nif`.
use sidereon_core::astro::frames::transforms::{
    gcrs_to_itrs_compute, gcrs_to_topocentric_compute,
    geodetic_to_itrs as geodetic_to_itrs_compute, itrs_to_gcrs_compute, itrs_to_geodetic_compute,
    teme_to_gcrs_compute, GeodeticStationKm, TemeStateKm,
};
use sidereon_core::astro::time::scales::TimeScales;

type DateTuple = (i32, i32, i32);
type TimeTuple = (i32, i32, i32, i32);

/// Decode an Elixir `{{y,m,d},{h,min,s,us}}` datetime tuple into UTC components.
/// Pure term decode (glue); no domain formula.
fn parse_datetime_tuple(term: Term) -> NifResult<(i32, i32, i32, i32, i32, i32, i32)> {
    let (date, time): (DateTuple, TimeTuple) = term.decode()?;
    Ok((date.0, date.1, date.2, time.0, time.1, time.2, time.3))
}

/// Build the relocated `TimeScales` from an Elixir datetime tuple. Glue only:
/// folds microseconds into fractional seconds and forwards to the crate.
fn time_scales_from_tuple(datetime_tuple: Term) -> NifResult<TimeScales> {
    let (year, month, day, hour, minute, second, microsecond) =
        parse_datetime_tuple(datetime_tuple)?;
    let second_with_micro = second as f64 + microsecond as f64 / 1_000_000.0;
    TimeScales::from_utc(year, month, day, hour, minute, second_with_micro)
        .map_err(errors::invalid_input)
}

#[rustler::nif]
fn propagate_with_elements<'a>(
    env: Env<'a>,
    tle_map: Term<'a>,
    datetime_tuple: Term<'a>,
) -> NifResult<Term<'a>> {
    propagation::propagate_with_elements_impl(env, tle_map, datetime_tuple)
}

type Vec3 = (f64, f64, f64);

#[rustler::nif(schedule = "DirtyCpu")]
fn propagate_dp54<'a>(
    env: Env<'a>,
    position_km: Vec3,
    velocity_km_s: Vec3,
    dt_seconds: f64,
    forces: Vec<String>,
    abs_tol: f64,
    rel_tol: f64,
) -> NifResult<Term<'a>> {
    propagation::propagate_dp54_impl(
        env,
        position_km,
        velocity_km_s,
        dt_seconds,
        forces,
        abs_tol,
        rel_tol,
    )
}

#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
fn propagate_dp54_with_drag<'a>(
    env: Env<'a>,
    position_km: Vec3,
    velocity_km_s: Vec3,
    dt_seconds: f64,
    forces: Vec<String>,
    abs_tol: f64,
    rel_tol: f64,
    drag: Term<'a>,
) -> NifResult<Term<'a>> {
    let drag = Some(drag::decode_drag_parameters(drag)?);
    propagation::propagate_dp54_impl_with_drag(
        env,
        position_km,
        velocity_km_s,
        dt_seconds,
        forces,
        abs_tol,
        rel_tol,
        drag,
    )
}

#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
fn predict_passes<'a>(
    env: Env<'a>,
    tle_map: Term<'a>,
    station_latitude_deg: f64,
    station_longitude_deg: f64,
    station_altitude_m: f64,
    start_datetime: Term<'a>,
    end_datetime: Term<'a>,
    min_elevation_deg: f64,
    step_seconds: i64,
    opsmode: Term<'a>,
) -> NifResult<Vec<(i64, i64, f64, i64)>> {
    passes::predict_passes_impl(
        env,
        tle_map,
        station_latitude_deg,
        station_longitude_deg,
        station_altitude_m,
        start_datetime,
        end_datetime,
        min_elevation_deg,
        step_seconds,
        opsmode,
    )
}

#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments, clippy::type_complexity)]
fn constellation_visible<'a>(
    env: Env<'a>,
    tle_maps: Vec<Term<'a>>,
    station_latitude_deg: f64,
    station_longitude_deg: f64,
    station_altitude_m: f64,
    datetime_tuple: Term<'a>,
    min_elevation_deg: f64,
    opsmode: Term<'a>,
) -> NifResult<Vec<(String, f64, f64, f64, Vec3)>> {
    passes::constellation_visible_impl(
        env,
        tle_maps,
        station_latitude_deg,
        station_longitude_deg,
        station_altitude_m,
        datetime_tuple,
        min_elevation_deg,
        opsmode,
    )
}

#[rustler::nif(schedule = "DirtyCpu")]
fn ground_track<'a>(
    env: Env<'a>,
    tle_map: Term<'a>,
    datetimes: Vec<Term<'a>>,
    opsmode: Term<'a>,
) -> NifResult<Term<'a>> {
    passes::ground_track_impl(env, tle_map, datetimes, opsmode)
}

#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
fn constellation_look_angle_arcs<'a>(
    env: Env<'a>,
    tle_maps: Vec<Term<'a>>,
    station_latitude_deg: f64,
    station_longitude_deg: f64,
    station_altitude_m: f64,
    datetimes: Vec<Term<'a>>,
    opsmode: Term<'a>,
) -> NifResult<Vec<Vec<Vec3>>> {
    passes::constellation_look_angle_arcs_impl(
        env,
        tle_maps,
        station_latitude_deg,
        station_longitude_deg,
        station_altitude_m,
        datetimes,
        opsmode,
    )
}

#[rustler::nif(schedule = "DirtyCpu")]
fn constellation_ground_tracks<'a>(
    env: Env<'a>,
    tle_maps: Vec<Term<'a>>,
    datetimes: Vec<Term<'a>>,
    opsmode: Term<'a>,
) -> NifResult<Vec<Vec<Vec3>>> {
    passes::constellation_ground_tracks_impl(env, tle_maps, datetimes, opsmode)
}

#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
fn constellation_passes<'a>(
    env: Env<'a>,
    tle_maps: Vec<Term<'a>>,
    station_latitude_deg: f64,
    station_longitude_deg: f64,
    station_altitude_m: f64,
    start_datetime: Term<'a>,
    end_datetime: Term<'a>,
    min_elevation_deg: f64,
    step_seconds: i64,
    opsmode: Term<'a>,
) -> NifResult<Vec<(u32, String, i64, i64, f64, i64)>> {
    passes::constellation_passes_impl(
        env,
        tle_maps,
        station_latitude_deg,
        station_longitude_deg,
        station_altitude_m,
        start_datetime,
        end_datetime,
        min_elevation_deg,
        step_seconds,
        opsmode,
    )
}

#[rustler::nif]
fn tle_look_angle<'a>(
    env: Env<'a>,
    tle_map: Term<'a>,
    station_latitude_deg: f64,
    station_longitude_deg: f64,
    station_altitude_m: f64,
    datetime_tuple: Term<'a>,
    opsmode: Term<'a>,
) -> NifResult<Term<'a>> {
    look_angle::tle_look_angle_impl(
        env,
        tle_map,
        station_latitude_deg,
        station_longitude_deg,
        station_altitude_m,
        datetime_tuple,
        opsmode,
    )
}

#[rustler::nif]
fn force_twobody_acceleration(position: Vec3, velocity: Vec3) -> NifResult<Vec3> {
    forces::twobody_acceleration_impl(position, velocity)
}

#[rustler::nif]
fn force_j2_acceleration(position: Vec3, velocity: Vec3) -> NifResult<Vec3> {
    forces::j2_acceleration_impl(position, velocity)
}

#[rustler::nif]
fn eclipse_shadow_fraction(sat_pos: Vec3, sun_pos: Vec3) -> NifResult<f64> {
    eclipse::shadow_fraction_impl(sat_pos, sun_pos)
}

#[rustler::nif]
fn eclipse_status(sat_pos: Vec3, sun_pos: Vec3) -> NifResult<rustler::Atom> {
    eclipse::status_impl(sat_pos, sun_pos)
}

#[rustler::nif]
fn angles_sun_angle(sat_pos: Vec3, sun_pos: Vec3) -> NifResult<f64> {
    angles::sun_angle_impl(sat_pos, sun_pos)
}

#[rustler::nif]
fn angles_moon_angle(sat_pos: Vec3, moon_pos: Vec3) -> NifResult<f64> {
    angles::moon_angle_impl(sat_pos, moon_pos)
}

#[rustler::nif]
fn angles_sun_elevation(sat_pos: Vec3, sun_pos: Vec3) -> NifResult<f64> {
    angles::sun_elevation_impl(sat_pos, sun_pos)
}

#[rustler::nif]
fn angles_phase_angle(sat_pos: Vec3, sun_pos: Vec3, observer_pos: Vec3) -> NifResult<f64> {
    angles::phase_angle_impl(sat_pos, sun_pos, observer_pos)
}

#[rustler::nif]
fn angles_earth_angular_radius(sat_pos: Vec3) -> NifResult<f64> {
    angles::earth_angular_radius_impl(sat_pos)
}

#[rustler::nif]
fn rf_fspl(distance_km: f64, frequency_mhz: f64) -> NifResult<f64> {
    rf::fspl_impl(distance_km, frequency_mhz)
}

#[rustler::nif]
fn rf_fspl_batch(distances_km: Vec<f64>, frequency_mhz: f64) -> NifResult<Vec<f64>> {
    rf::fspl_batch_impl(distances_km, frequency_mhz)
}

#[rustler::nif]
fn rf_eirp(tx_power_dbm: f64, tx_antenna_gain_dbi: f64) -> NifResult<f64> {
    rf::eirp_impl(tx_power_dbm, tx_antenna_gain_dbi)
}

#[rustler::nif]
fn rf_cn0(
    eirp_dbw: f64,
    fspl_db: f64,
    receiver_gt_dbk: f64,
    other_losses_db: f64,
) -> NifResult<f64> {
    rf::cn0_impl(eirp_dbw, fspl_db, receiver_gt_dbk, other_losses_db)
}

#[rustler::nif]
fn rf_link_margin(
    eirp_dbw: f64,
    fspl_db: f64,
    receiver_gt_dbk: f64,
    other_losses_db: f64,
    required_cn0_dbhz: f64,
) -> NifResult<f64> {
    rf::link_margin_impl(
        eirp_dbw,
        fspl_db,
        receiver_gt_dbk,
        other_losses_db,
        required_cn0_dbhz,
    )
}

#[rustler::nif]
fn rf_link_margin_batch(budgets: Vec<(f64, f64, f64, f64, f64)>) -> NifResult<Vec<f64>> {
    rf::link_margin_batch_impl(budgets)
}

#[rustler::nif]
fn rf_wavelength(frequency_hz: f64) -> NifResult<f64> {
    rf::wavelength_impl(frequency_hz)
}

#[rustler::nif]
fn rf_dish_gain(diameter_m: f64, frequency_hz: f64, efficiency: f64) -> NifResult<f64> {
    rf::dish_gain_impl(diameter_m, frequency_hz, efficiency)
}

#[rustler::nif]
fn covariance_rtn_to_eci<'a>(
    env: Env<'a>,
    cov_rtn: Vec<Vec<f64>>,
    r: Vec3,
    v: Vec3,
) -> NifResult<Term<'a>> {
    covariance::rtn_to_eci_impl(env, cov_rtn, r, v)
}

#[rustler::nif]
fn covariance_positive_semidefinite(m: Vec<Vec<f64>>) -> NifResult<bool> {
    covariance::positive_semidefinite_impl(m)
}

#[rustler::nif]
fn covariance_symmetric(m: Vec<Vec<f64>>) -> NifResult<bool> {
    covariance::symmetric_impl(m)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn covariance_normal_covariance<'a>(
    env: Env<'a>,
    jacobian: Vec<Vec<f64>>,
    variance_scale: f64,
) -> NifResult<Term<'a>> {
    covariance::normal_covariance_impl(env, jacobian, variance_scale)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn covariance_hessian_trace(jacobian: Vec<Vec<f64>>) -> NifResult<f64> {
    covariance::hessian_trace_impl(jacobian)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn covariance_from_jacobian<'a>(
    env: Env<'a>,
    jacobian: Vec<Vec<f64>>,
    cost: f64,
) -> NifResult<Term<'a>> {
    covariance::covariance_from_jacobian_impl(env, jacobian, cost)
}

#[rustler::nif]
fn covariance_error_ellipse_2x2<'a>(
    env: Env<'a>,
    covariance_2x2: Vec<Vec<f64>>,
    confidence: f64,
) -> NifResult<Term<'a>> {
    covariance::error_ellipse_2x2_impl(env, covariance_2x2, confidence)
}

#[rustler::nif]
fn encounter_frame<'a>(env: Env<'a>, r1: Vec3, v1: Vec3, r2: Vec3, v2: Vec3) -> Term<'a> {
    collision::encounter_frame_impl(env, r1, v1, r2, v2)
}

#[rustler::nif]
fn encounter_plane_covariance(
    x_hat: Vec3,
    z_hat: Vec3,
    cov: Vec<Vec<f64>>,
) -> NifResult<Vec<Vec<f64>>> {
    collision::encounter_plane_covariance_impl(x_hat, z_hat, cov)
}

#[rustler::nif]
#[allow(clippy::too_many_arguments)]
fn collision_probability<'a>(
    env: Env<'a>,
    r1: Vec3,
    v1: Vec3,
    cov1: Vec<Vec<f64>>,
    r2: Vec3,
    v2: Vec3,
    cov2: Vec<Vec<f64>>,
    hard_body_radius_km: f64,
    method: rustler::Atom,
) -> NifResult<Term<'a>> {
    collision::collision_probability_impl(
        env,
        r1,
        v1,
        cov1,
        r2,
        v2,
        cov2,
        hard_body_radius_km,
        method,
    )
}

#[rustler::nif]
#[allow(clippy::too_many_arguments)]
fn teme_to_gcrs(
    x: f64,
    y: f64,
    z: f64,
    vx: f64,
    vy: f64,
    vz: f64,
    datetime_tuple: Term,
    skyfield_compat: bool,
) -> NifResult<(Vec3, Vec3)> {
    let ts = time_scales_from_tuple(datetime_tuple)?;
    teme_to_gcrs_compute(
        &TemeStateKm {
            position_km: [x, y, z],
            velocity_km_s: [vx, vy, vz],
        },
        &ts,
        skyfield_compat,
    )
    .map_err(errors::invalid_input)
}

#[rustler::nif]
fn gcrs_to_itrs(
    x: f64,
    y: f64,
    z: f64,
    datetime_tuple: Term,
    skyfield_compat: bool,
) -> NifResult<(f64, f64, f64)> {
    let ts = time_scales_from_tuple(datetime_tuple)?;
    gcrs_to_itrs_compute(x, y, z, &ts, skyfield_compat).map_err(errors::invalid_input)
}

#[rustler::nif]
fn itrs_to_gcrs(x: f64, y: f64, z: f64, datetime_tuple: Term) -> NifResult<(f64, f64, f64)> {
    let ts = time_scales_from_tuple(datetime_tuple)?;
    itrs_to_gcrs_compute(x, y, z, &ts).map_err(errors::invalid_input)
}

#[rustler::nif]
fn itrs_to_geodetic(x: f64, y: f64, z: f64) -> NifResult<(f64, f64, f64)> {
    itrs_to_geodetic_compute(x, y, z).map_err(errors::invalid_input)
}

#[rustler::nif]
fn geodetic_to_itrs(
    latitude_deg: f64,
    longitude_deg: f64,
    altitude_km: f64,
) -> NifResult<(f64, f64, f64)> {
    geodetic_to_itrs_compute(latitude_deg, longitude_deg, altitude_km)
        .map_err(errors::invalid_input)
}

#[rustler::nif]
#[allow(clippy::too_many_arguments)]
fn gcrs_to_topocentric(
    sat_x: f64,
    sat_y: f64,
    sat_z: f64,
    station_lat_deg: f64,
    station_lon_deg: f64,
    station_alt_km: f64,
    datetime_tuple: Term,
    skyfield_compat: bool,
) -> NifResult<(f64, f64, f64)> {
    let ts = time_scales_from_tuple(datetime_tuple)?;
    gcrs_to_topocentric_compute(
        [sat_x, sat_y, sat_z],
        &GeodeticStationKm {
            latitude_deg: station_lat_deg,
            longitude_deg: station_lon_deg,
            altitude_km: station_alt_km,
        },
        &ts,
        skyfield_compat,
    )
    .map_err(errors::invalid_input)
}

#[rustler::nif]
#[allow(clippy::too_many_arguments)]
fn atmosphere_density(
    lat_deg: f64,
    lon_deg: f64,
    alt_km: f64,
    year: i32,
    doy: i32,
    sec: f64,
    f107: f64,
    f107a: f64,
    ap: f64,
) -> NifResult<(f64, f64)> {
    atmosphere::atmosphere_density_impl(lat_deg, lon_deg, alt_km, year, doy, sec, f107, f107a, ap)
}

#[rustler::nif]
fn j2000_seconds_from_split(jd_whole: f64, jd_fraction: f64) -> NifResult<f64> {
    sidereon_core::observables::j2000_seconds_from_split(jd_whole, jd_fraction)
        .map_err(errors::invalid_input)
}

#[rustler::nif]
fn utc_to_tdb_jd_split(
    year: i32,
    month: i32,
    day: i32,
    hour: i32,
    minute: i32,
    second: f64,
) -> NifResult<(f64, f64)> {
    let ts = TimeScales::from_utc(year, month, day, hour, minute, second)
        .map_err(errors::invalid_input)?;
    Ok((ts.jd_whole, ts.tdb_fraction))
}

#[rustler::nif]
fn utc_to_tdb_jd(
    year: i32,
    month: i32,
    day: i32,
    hour: i32,
    minute: i32,
    second: f64,
) -> NifResult<f64> {
    let ts = TimeScales::from_utc(year, month, day, hour, minute, second)
        .map_err(errors::invalid_input)?;
    Ok(ts.jd_tdb)
}

#[rustler::nif]
#[allow(clippy::too_many_arguments)]
fn doppler_shift(
    sat_x: f64,
    sat_y: f64,
    sat_z: f64,
    sat_vx: f64,
    sat_vy: f64,
    sat_vz: f64,
    station_lat_deg: f64,
    station_lon_deg: f64,
    station_alt_km: f64,
    datetime_tuple: Term,
    frequency_hz: f64,
) -> NifResult<(f64, f64, f64)> {
    let ts = time_scales_from_tuple(datetime_tuple)?;
    let shift = sidereon_core::astro::doppler::doppler_shift(
        [sat_x, sat_y, sat_z],
        [sat_vx, sat_vy, sat_vz],
        station_lat_deg,
        station_lon_deg,
        station_alt_km,
        &ts,
        frequency_hz,
    )
    .map_err(errors::invalid_input)?;
    Ok((shift.range_rate_km_s, shift.doppler_hz, shift.doppler_ratio))
}

#[rustler::nif]
fn iod_gibbs(r1: Vec3, r2: Vec3, r3: Vec3) -> NifResult<(Vec3, f64, f64, f64)> {
    iod::gibbs_impl(r1, r2, r3)
}

#[rustler::nif]
#[allow(clippy::too_many_arguments)]
fn iod_hgibbs(
    r1: Vec3,
    r2: Vec3,
    r3: Vec3,
    jd1: f64,
    jd2: f64,
    jd3: f64,
) -> NifResult<(Vec3, f64, f64, f64)> {
    iod::hgibbs_impl(r1, r2, r3, jd1, jd2, jd3)
}

#[rustler::nif]
#[allow(clippy::too_many_arguments)]
fn iod_gauss(
    decl1: f64,
    decl2: f64,
    decl3: f64,
    rtasc1: f64,
    rtasc2: f64,
    rtasc3: f64,
    jd1: f64,
    jdf1: f64,
    jd2: f64,
    jdf2: f64,
    jd3: f64,
    jdf3: f64,
    rseci1: Vec3,
    rseci2: Vec3,
    rseci3: Vec3,
) -> NifResult<(Vec3, Vec3)> {
    gauss::gauss_impl(
        decl1, decl2, decl3, rtasc1, rtasc2, rtasc3, jd1, jdf1, jd2, jdf2, jd3, jdf3, rseci1,
        rseci2, rseci3,
    )
}

#[rustler::nif]
#[allow(clippy::too_many_arguments)]
fn lambert_battin(
    r1: Vec3,
    r2: Vec3,
    v1: Vec3,
    dm: i32,
    de: i32,
    nrev: i32,
    dtsec: f64,
) -> NifResult<(Vec3, Vec3)> {
    lambert::lambert_battin_impl(r1, r2, v1, dm, de, nrev, dtsec)
}

#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
fn tca_find_candidates<'a>(
    env: Env<'a>,
    primary_line1: String,
    primary_line2: String,
    secondary_line1: String,
    secondary_line2: String,
    start_whole: f64,
    start_fraction: f64,
    end_whole: f64,
    end_fraction: f64,
    coarse_step_seconds: f64,
    time_tolerance_seconds: f64,
) -> NifResult<Term<'a>> {
    conjunction::find_tca_candidates_impl(
        env,
        primary_line1,
        primary_line2,
        secondary_line1,
        secondary_line2,
        start_whole,
        start_fraction,
        end_whole,
        end_fraction,
        coarse_step_seconds,
        time_tolerance_seconds,
    )
}

#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
fn tca_find_conjunctions<'a>(
    env: Env<'a>,
    primary_line1: String,
    primary_line2: String,
    secondary_line1: String,
    secondary_line2: String,
    start_whole: f64,
    start_fraction: f64,
    end_whole: f64,
    end_fraction: f64,
    hard_body_radius_km: f64,
    method: rustler::Atom,
    primary_covariance_km2: Option<Vec<Vec<f64>>>,
    secondary_covariance_km2: Option<Vec<Vec<f64>>>,
    coarse_step_seconds: f64,
    time_tolerance_seconds: f64,
) -> NifResult<Term<'a>> {
    conjunction::find_tca_conjunctions_impl(
        env,
        primary_line1,
        primary_line2,
        secondary_line1,
        secondary_line2,
        start_whole,
        start_fraction,
        end_whole,
        end_fraction,
        hard_body_radius_km,
        method,
        primary_covariance_km2,
        secondary_covariance_km2,
        coarse_step_seconds,
        time_tolerance_seconds,
    )
}

#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
fn tca_screen_candidates<'a>(
    env: Env<'a>,
    primary_line1: String,
    primary_line2: String,
    secondaries: Vec<(String, String)>,
    start_whole: f64,
    start_fraction: f64,
    end_whole: f64,
    end_fraction: f64,
    miss_distance_threshold_km: f64,
    coarse_step_seconds: f64,
    time_tolerance_seconds: f64,
) -> NifResult<Term<'a>> {
    conjunction::screen_tca_candidates_impl(
        env,
        primary_line1,
        primary_line2,
        secondaries,
        start_whole,
        start_fraction,
        end_whole,
        end_fraction,
        miss_distance_threshold_km,
        coarse_step_seconds,
        time_tolerance_seconds,
    )
}

#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
fn tca_screen_conjunctions<'a>(
    env: Env<'a>,
    primary_line1: String,
    primary_line2: String,
    secondaries: Vec<(String, String)>,
    start_whole: f64,
    start_fraction: f64,
    end_whole: f64,
    end_fraction: f64,
    miss_distance_threshold_km: f64,
    hard_body_radius_km: f64,
    method: rustler::Atom,
    primary_covariance_km2: Option<Vec<Vec<f64>>>,
    secondary_covariance_km2: Option<Vec<Vec<f64>>>,
    coarse_step_seconds: f64,
    time_tolerance_seconds: f64,
) -> NifResult<Term<'a>> {
    conjunction::screen_tca_conjunctions_impl(
        env,
        primary_line1,
        primary_line2,
        secondaries,
        start_whole,
        start_fraction,
        end_whole,
        end_fraction,
        miss_distance_threshold_km,
        hard_body_radius_km,
        method,
        primary_covariance_km2,
        secondary_covariance_km2,
        coarse_step_seconds,
        time_tolerance_seconds,
    )
}

#[rustler::nif]
#[allow(clippy::type_complexity)]
fn sun_moon_ecef(datetime_tuple: Term) -> NifResult<((f64, f64, f64), (f64, f64, f64))> {
    tides::sun_moon_ecef_impl(datetime_tuple)
}

#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::type_complexity)]
fn sun_moon_eci_batch(epochs_unix_us: Vec<i64>) -> NifResult<(Vec<Vec3>, Vec<Vec3>)> {
    tides::sun_moon_eci_batch_impl(epochs_unix_us)
}

#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::type_complexity)]
fn sun_moon_ecef_batch(epochs_unix_us: Vec<i64>) -> NifResult<(Vec<Vec3>, Vec<Vec3>)> {
    tides::sun_moon_ecef_batch_impl(epochs_unix_us)
}

#[rustler::nif]
#[allow(clippy::too_many_arguments)]
fn solid_earth_tide(
    sta_x: f64,
    sta_y: f64,
    sta_z: f64,
    year: i32,
    month: i32,
    day: i32,
    fhr: f64,
    sun: (f64, f64, f64),
    moon: (f64, f64, f64),
) -> NifResult<(f64, f64, f64)> {
    tides::solid_earth_tide_impl(sta_x, sta_y, sta_z, year, month, day, fhr, sun, moon)
}

#[rustler::nif]
#[allow(clippy::too_many_arguments)]
fn solid_earth_pole_tide(
    sta_x: f64,
    sta_y: f64,
    sta_z: f64,
    year: i32,
    month: i32,
    day: i32,
    fhr: f64,
    xp_arcsec: f64,
    yp_arcsec: f64,
) -> NifResult<(f64, f64, f64)> {
    tides::solid_earth_pole_tide_impl(
        sta_x, sta_y, sta_z, year, month, day, fhr, xp_arcsec, yp_arcsec,
    )
}

#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
fn ocean_tide_loading(
    sta_x: f64,
    sta_y: f64,
    sta_z: f64,
    year: i32,
    month: i32,
    day: i32,
    fhr: f64,
    amplitude_m: Vec<Vec<f64>>,
    phase_deg: Vec<Vec<f64>>,
) -> NifResult<(f64, f64, f64)> {
    tides::ocean_tide_loading_impl(
        sta_x,
        sta_y,
        sta_z,
        year,
        month,
        day,
        fhr,
        amplitude_m,
        phase_deg,
    )
}

rustler::init!("Elixir.Sidereon.NIF");
