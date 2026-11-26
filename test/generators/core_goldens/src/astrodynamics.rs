use serde_json::{json, Value};
use sidereon_core::astro::attitude::gnss::{
    self, AttitudeMode, AttitudeTrajectory, DybAxes, GnssAttitude, GnssAttitudeLaw,
    OrbitAttitudeTrajectory,
};
use sidereon_core::astro::bodies::sun_moon::{
    sun_moon_gcrs, sun_moon_gcrs_at, sun_moon_gcrs_at_tdb_seconds, SunMoon,
};
use sidereon_core::astro::covariance::Covariance6;
use sidereon_core::astro::de::{DeBody, DeEphemeris};
use sidereon_core::astro::events::eclipse::{self, EarthShadowModel};
use sidereon_core::astro::forces::{
    ecom_geometry, ecom_geometry_with_shadow, AccelerationPartials, CompositeForceModel,
    DragParameters, EarthRadiationPressure, Ecom1Coefficients, Ecom1SolarRadiationPressure,
    Ecom2SolarRadiationPressure, EmpiricalHarmonic, EmpiricalRtnAcceleration, ForceModel,
    IcgemGravityField, J2Gravity, RtnAxis, SolarRadiationPressure, SpaceWeather,
    SphericalHarmonicGravity, ThirdBodyGravity, TwoBodyGravity,
};
use sidereon_core::astro::frames::{
    transforms::{gcrs_to_mean_of_date_matrix, mean_of_date_to_gcrs_matrix},
    EarthOrientationProvider, Iers2010EarthOrientationProvider, Iers2010EopSample,
    TdbEarthOrientationProvider,
};
use sidereon_core::astro::propagator::analytic::{
    brouwer_lyddane_mean_elements, brouwer_lyddane_osculating_elements,
    eckstein_hechler_mean_elements, eckstein_hechler_osculating_elements, BrouwerLyddanePropagator,
    CircularElements, EcksteinHechlerPropagator, KeplerianElements, MeanConversionOptions,
    ZonalHarmonics,
};
use sidereon_core::astro::propagator::{
    propagate_variational, CovarianceFrame, CovariancePropagationOptions, ForceModelComponents,
    ForceModelKind, IntegratorKind, IntegratorOptions, LabeledCovariance6, PropagationContext,
    StatePropagator, VariationalEpoch, VariationalEquations,
};
use sidereon_core::astro::state::CartesianState;
use sidereon_core::astro::time::model::{Instant, TimeScale};
use sidereon_core::astro::time::scales::{
    tdb_from_tt_j2000_seconds, tdb_minus_tt_seconds, tt_from_tdb_j2000_seconds, TimeScales,
};
use sidereon_core::ephemeris::BroadcastEphemeris;
use sidereon_core::orbit_determination::{
    fit_inertial_orbit_parameters, fit_inertial_orbit_parameters_with_validity,
    fit_sp3_ecef_orbit_parameters, InertialPositionSample, OrbitParameterCovariance,
    OrbitParameterFitError, OrbitParameterFitOptions,
};
use sidereon_core::orbit_scoring::{
    score_orbit, BroadcastOrbit, OrbitScoreOptions, OrbitTrajectory, PredictedSp3,
    SisreWeightSelection, SisreWeights, TrajectorySample,
};
use std::sync::Arc;

use super::{goldens_dir, gps, h, hm3, hv, load_sp3, source, write, Context};

pub(super) fn write_goldens(ctx: &Context) {
    let output = goldens_dir(ctx);
    for (file, value) in [
        ("numerical_orbits.json", numerical_orbits(ctx)),
        ("celestial_geometry.json", celestial_geometry(ctx)),
        ("analytic_orbits.json", analytic_orbits(ctx)),
        ("gravity_and_radiation.json", gravity_and_radiation(ctx)),
        ("orbit_assessment.json", orbit_assessment(ctx)),
        ("de_ephemeris.json", de_ephemeris(ctx)),
        ("orbit_attitude.json", orbit_attitude(ctx)),
    ] {
        write(&output, file, &value);
    }
}

fn state(value: CartesianState) -> Value {
    json!([
        h(value.epoch_tdb_seconds),
        hv(&value.position_array()),
        hv(&value.velocity_array())
    ])
}

fn numerical_orbits(ctx: &Context) -> Value {
    let mut options = IntegratorOptions::default();
    options.abs_tol = 1e-12;
    options.rel_tol = 1e-12;
    let mut propagator = StatePropagator::new(
        0.0,
        [7000.0, 0.0, 0.0],
        [0.0, 7.546049108166282, 0.0],
        ForceModelKind::two_body(),
        IntegratorKind::Dp54,
    )
    .with_options(options);
    let legacy_twobody = propagator.ephemeris(&[60.0]).unwrap()[0];
    let earth_mu = 398_600.4418_f64;
    let radius = 7000.0_f64;
    let period = 2.0 * std::f64::consts::PI * (radius.powi(3) / earth_mu).sqrt();
    let circular = StatePropagator::new(
        0.0,
        [radius, 0.0, 0.0],
        [0.0, (earth_mu / radius).sqrt(), 0.0],
        ForceModelKind::two_body(),
        IntegratorKind::Dp54,
    )
    .with_options(options);
    let orbit_end = circular.ephemeris(&[period]).unwrap()[0];
    options.max_step = 30.0;
    options.initial_step = 1.0;
    let covariance = Covariance6::from_diagonal([1e-6, 2e-6, 3e-6, 1e-8, 2e-8, 3e-8]).unwrap();
    propagator.options = options;
    let nodes = propagator
        .propagate_covariance(
            LabeledCovariance6 {
                covariance,
                frame: CovarianceFrame::Inertial,
            },
            &[60.0, 120.0],
            &CovariancePropagationOptions::default(),
        )
        .unwrap();
    let rows = covariance_nodes(&nodes);
    propagator.force_model = ForceModelKind::two_body_j2();
    let j2_nodes = propagator
        .propagate_covariance(
            LabeledCovariance6 {
                covariance,
                frame: CovarianceFrame::Inertial,
            },
            &[60.0, 120.0],
            &CovariancePropagationOptions::default(),
        )
        .unwrap();
    let context = PropagationContext::new()
        .with_body_fixed_frame_provider(Arc::new(TdbEarthOrientationProvider::new()));
    let tide_model = ForceModelKind::composite(
        ForceModelComponents::earth_two_body()
            .with_solid_earth_tide(Default::default())
            .with_solid_earth_pole_tide(Default::default()),
    );
    let tide_propagator = StatePropagator::new(
        0.0,
        [7000.0, 0.0, 0.0],
        [0.0, 7.546049108166282, 0.0],
        tide_model,
        IntegratorKind::Dp54,
    )
    .with_options(options);
    let tide_nodes = tide_propagator
        .propagate_covariance_with_context(
            LabeledCovariance6 {
                covariance,
                frame: CovarianceFrame::Inertial,
            },
            &[60.0, 120.0],
            &CovariancePropagationOptions::default(),
            &context,
        )
        .unwrap();
    let tide_stm = tide_propagator
        .state_transition_matrix_to_with_context(60.0, &context)
        .unwrap();
    let (tide_state, tide_covariance) = tide_propagator
        .propagate_state_with_covariance_with_context(covariance, 60.0, &context)
        .unwrap();
    let j2_state = CartesianState::new(0.0, [7000.0, -1210.0, 1300.0], [0.0; 3]);
    let j2 = J2Gravity::default()
        .acceleration(&j2_state, &context)
        .unwrap();
    let tide = ForceModelKind::composite(
        ForceModelComponents::EMPTY.with_solid_earth_tide(Default::default()),
    )
    .build()
    .unwrap()
    .acceleration(&j2_state, &context)
    .unwrap();
    let pole_tide = ForceModelKind::composite(
        ForceModelComponents::EMPTY.with_solid_earth_pole_tide(Default::default()),
    )
    .build()
    .unwrap()
    .acceleration(&j2_state, &context)
    .unwrap();
    let de = Arc::new(DeEphemeris::load(ctx.fixtures.join("de/lnxp1990.440")).unwrap());
    let de_state = CartesianState::new(
        de.coverage_tdb_seconds().0 + 600.0,
        j2_state.position_array(),
        [0.0, 7.5, 1.0],
    );
    let de_context = context.clone().with_de_ephemeris(de);
    let tide_force: Arc<dyn ForceModel> = ForceModelKind::composite(
        ForceModelComponents::EMPTY.with_solid_earth_tide(Default::default()),
    )
    .build()
    .unwrap()
    .into();
    let de_tide = tide_force.acceleration(&de_state, &de_context).unwrap();
    let de_target = de_state.epoch_tdb_seconds + 60.0;
    let with_de = StatePropagator::new(
        de_state.epoch_tdb_seconds,
        de_state.position_array(),
        de_state.velocity_array(),
        tide_model,
        IntegratorKind::Dp54,
    )
    .with_options(options);
    let de_propagated = with_de
        .ephemeris_with_context(&[de_target], &de_context)
        .unwrap()[0];
    let de_additional_tide = StatePropagator {
        force_model: ForceModelKind::two_body(),
        ..with_de
    }
    .ephemeris_with_additional_forces(&[de_target], &[Arc::clone(&tide_force)], &de_context)
    .unwrap()[0];
    let mut relative_options = IntegratorOptions::default();
    relative_options.abs_tol = relative_options.rel_tol;
    let legacy_tide = tide_propagator
        .with_options(relative_options)
        .ephemeris_with_context(&[60.0], &context)
        .unwrap()[0];
    let de_epoch = VariationalEpoch::from_tdb_seconds(de_state.epoch_tdb_seconds, de_target);
    let de_variational = propagate_variational(
        de_state,
        &[de_epoch],
        &VariationalEquations {
            force: tide_force.as_ref(),
            parameters: &[],
            sensitivity_parameters: &[],
        },
        IntegratorKind::Dp54,
        &IntegratorOptions::default(),
        &de_context,
    )
    .unwrap()
    .remove(0);
    let empirical = |axis, value| {
        Arc::new(
            EmpiricalRtnAcceleration::new()
                .with_term(axis, EmpiricalHarmonic::Constant, value)
                .unwrap(),
        ) as Arc<dyn ForceModel>
    };
    let additional = [
        empirical(RtnAxis::Radial, 1e-6),
        empirical(RtnAxis::CrossTrack, 3e-6),
    ];
    let mut dense_options = IntegratorOptions::default();
    dense_options.dense_output = true;
    let drag_initial = CartesianState::new(108_000.0, [6778.0, 0.0, 0.0], [0.0, 7.5, 1.0]);
    let drag_config =
        DragParameters::from_bc_factor_m2_kg(0.02, SpaceWeather::default(), 100.0).unwrap();
    let mut with_additional = StatePropagator::new(
        drag_initial.epoch_tdb_seconds,
        drag_initial.position_array(),
        drag_initial.velocity_array(),
        ForceModelKind::two_body_j2(),
        IntegratorKind::Dp54,
    )
    .with_drag(drag_config)
    .with_options(dense_options);
    let drag_context = PropagationContext::default();
    let fixed = with_additional
        .ephemeris_with_additional_forces(&[108_060.0], &additional, &drag_context)
        .unwrap()[0];
    let csv = std::fs::read_to_string(ctx.fixtures.join("space_weather/drag_arc.csv")).unwrap();
    let weather = sidereon_core::astro::space_weather::parse_csv(&csv)
        .unwrap()
        .value;
    use sidereon_core::astro::forces::SpaceWeatherSource;
    with_additional =
        with_additional.with_space_weather(SpaceWeatherSource::Table(Arc::new(weather)));
    let table = with_additional
        .propagate_to_with_additional_forces(108_060.0, &additional, &drag_context)
        .unwrap();
    let dense = table.dense.unwrap();
    let (start, end) = dense.coverage_tdb_seconds().unwrap();
    let backward = with_additional
        .propagate_to_with_additional_forces(107_940.0, &additional, &drag_context)
        .unwrap();
    let (backward_start, backward_end) = backward.dense.unwrap().coverage_tdb_seconds().unwrap();
    let sample = dense.eval(108_030.0).unwrap();
    let inner_refusal_time = start - 0.00000005;
    use sidereon_core::astro::propagator::dense_output::DenseOutputError;
    let inner_refusal = match dense.eval(inner_refusal_time).unwrap_err() {
        DenseOutputError::SegmentOutOfRange {
            t,
            t_start,
            t_end,
            theta,
        } => hv(&[t, t_start, t_end, theta]),
        error => panic!("{error}"),
    };

    let initial = CartesianState::new(646_056_000.25, [6778.137, 0.0, 0.0], [0.0, 4.77, 6.0]);
    let drag = DragParameters::from_bc_factor_m2_kg(0.02, SpaceWeather::default(), 100.0).unwrap();
    let drag_accel = drag
        .to_force()
        .acceleration(&initial, &PropagationContext::default())
        .unwrap();
    let context = PropagationContext::new()
        .with_body_fixed_frame_provider(Arc::new(TdbEarthOrientationProvider::new()));
    let tle = StatePropagator::new(
        initial.epoch_tdb_seconds,
        initial.position_array(),
        initial.velocity_array(),
        ForceModelKind::earth_phase_b(8, 8, Some(SolarRadiationPressure::new(1.3, 0.02).unwrap()))
            .unwrap(),
        IntegratorKind::Dp54,
    )
    .with_drag(drag)
    .ephemeris_with_context(&[initial.epoch_tdb_seconds + 120.0], &context)
    .unwrap()[0];
    let force = TwoBodyGravity::default();
    let epochs = [VariationalEpoch::from_tdb_seconds(0.0, 30.0)];
    let equation = VariationalEquations {
        force: &force,
        parameters: &[],
        sensitivity_parameters: &[],
    };
    let variational = propagate_variational(
        CartesianState::new(0.0, [7000.0, 0.0, 0.0], [0.0, 7.546049108166282, 0.0]),
        &epochs,
        &equation,
        IntegratorKind::Dp54,
        &IntegratorOptions::default(),
        &PropagationContext::new(),
    )
    .unwrap()
    .remove(0);
    use sidereon_core::astro::propagator::decay::{estimate_decay_with_context, DecayConfig};
    let erp = EarthRadiationPressure::new(1.3, 0.02).unwrap();
    let radiation = StatePropagator::new(
        0.0,
        [7000.0, 0.0, 0.0],
        [0.0, 7.546049108166282, 0.0],
        ForceModelKind::Composite {
            components: ForceModelComponents::earth_two_body().with_earth_radiation_pressure(erp),
        },
        IntegratorKind::Dp54,
    )
    .ephemeris(&[30.0])
    .unwrap()[0];
    let decay = estimate_decay_with_context(
        CartesianState::new(0.0, [7000.0, 0.0, 0.0], [0.0, 7.5, 0.0]),
        &DecayConfig::new(drag).with_reentry_altitude_km(1000.0),
        &PropagationContext::new(),
    )
    .unwrap();
    json!({
        "decay_initial_altitude": h(decay.reentry_altitude_km),
        "earth_radiation_state": state(radiation),
        "source": source(ctx, "TT propagation, UT1 drag and covariance evolution"),
        "circular_end": state(orbit_end),
        "additional_forces": {
            "initial": state(drag_initial),
            "fixed": state(fixed),
            "table": state(table.final_state),
            "coverage": hv(&[start, end]),
            "backward_coverage": hv(&[backward_start, backward_end]),
            "dense_sample": state(sample),
            "segment_refusal": inner_refusal,
        },
        "j2_acceleration": hv(j2.as_slice()),
        "tide_acceleration": hv(tide.as_slice()),
        "pole_tide_acceleration": hv(pole_tide.as_slice()),
        "de_tides": {
            "initial": state(de_state),
            "acceleration": hv(de_tide.as_slice()),
            "propagated": state(de_propagated),
            "additional_tide": state(de_additional_tide),
            "variational": state(de_variational.state),
            "stm": de_variational.state_transition.row_iter().map(|row| row.iter().map(|value| h(*value)).collect::<Vec<_>>()).collect::<Vec<_>>(),
        },
        "legacy_tide": state(legacy_tide),
        "legacy_twobody": state(legacy_twobody),
        "j2_covariance_nodes": covariance_nodes(&j2_nodes),
        "tide_covariance_nodes": covariance_nodes(&tide_nodes),
        "tide_stm": tide_stm.iter().map(|row| hv(row)).collect::<Vec<_>>(),
        "tide_state_covariance": [state(tide_state), json!(tide_covariance.into_matrix().iter().map(|row| hv(row)).collect::<Vec<_>>())],
        "covariance_nodes": rows,
        "drag_state": state(initial),
        "drag_accel": hv(drag_accel.as_slice()),
        "perturbed_state": state(tle),
        "variational_state": state(variational.state),
        "variational_elapsed_tt_s": h(epochs[0].elapsed_tt_s),
        "state_transition": variational.state_transition.row_iter().map(|row| row.iter().map(|value| h(*value)).collect::<Vec<_>>()).collect::<Vec<_>>(),
    })
}

fn covariance_nodes(nodes: &sidereon_core::astro::propagator::CovarianceEphemeris) -> Vec<Value> {
    nodes.nodes().iter().map(|node| json!({
        "state": state(node.state),
        "covariance": node.covariance.into_matrix().iter().map(|row| row.iter().map(|value| h(*value)).collect::<Vec<_>>()).collect::<Vec<_>>()
    })).collect()
}

fn sun_moon(value: SunMoon) -> Vec<Vec<String>> {
    vec![hv(&value.sun), hv(&value.moon)]
}

fn dyb(value: DybAxes) -> Value {
    json!({"d": hv(&value.d), "y": hv(&value.y), "b": hv(&value.b)})
}

fn celestial_geometry(ctx: &Context) -> Value {
    let scales = TimeScales::from_utc(2020, 6, 25, 0, 0, 0.0).unwrap();
    let position = [26_000.0, 2400.0, 930.0];
    let velocity = [-0.3, 2.6, 2.7];
    let sun = [1.5e8, 7e6, 2e7];
    let moon = [384_400.0, -123_456.0, 739.0];
    let yaw = gnss::nominal_yaw(position, velocity, sun).unwrap();
    let sample = Iers2010EopSample {
        mjd_utc: 59_025,
        xp_arcsec: 0.1,
        yp_arcsec: 0.15,
        ut1_minus_utc_s: -0.21,
        lod_s: 0.001,
        dx_arcsec: 0.0001,
        dy_arcsec: -0.0002,
        pole_rates_rad_s: None,
    };
    let provider = Iers2010EarthOrientationProvider::new(vec![
        sample,
        Iers2010EopSample {
            mjd_utc: 59_026,
            ..sample
        },
    ])
    .unwrap();
    let eop = provider.orientation_at_utc_mjd(59_025, 12_345.5).unwrap();
    let orientation_tdb = tdb_from_tt_j2000_seconds(
        sidereon_core::astro::time::j2000_seconds(2020, 6, 25, 0, 0, 0.0) + 69.184 + 12_345.5,
    );
    let tdb_orientation = provider
        .orientation_at_tdb_seconds(orientation_tdb)
        .unwrap();
    let tdb = 16_000_000.0;
    let shadow = eclipse::shadow_fraction_with_model_moon_and_gradient(
        position,
        sun,
        moon,
        EarthShadowModel::Wgs84Oblate,
    )
    .unwrap();
    json!({
        "source": source(ctx, "celestial positions, frame rotations, eclipse geometry and GNSS yaw"),
        "sun_moon_gcrs": sun_moon(sun_moon_gcrs(0.2).unwrap()),
        "sun_moon_gcrs_at": sun_moon(sun_moon_gcrs_at(&scales).unwrap()),
        "sun_moon_gcrs_at_tdb_seconds": sun_moon(sun_moon_gcrs_at_tdb_seconds(tdb).unwrap()),
        "gcrs_to_mean_of_date_matrix": hm3(gcrs_to_mean_of_date_matrix(&scales).unwrap()),
        "mean_of_date_to_gcrs_matrix": hm3(mean_of_date_to_gcrs_matrix(&scales).unwrap()),
        "tt_from_tdb_j2000_seconds": h(tt_from_tdb_j2000_seconds(tdb)),
        "tdb_from_tt_j2000_seconds": h(tdb_from_tt_j2000_seconds(tdb)),
        "tdb_minus_tt_seconds": h(tdb_minus_tt_seconds(tdb)),
        "position": hv(&position), "velocity": hv(&velocity), "sun": hv(&sun), "moon": hv(&moon),
        "yaw": {"yaw_rad": h(yaw.yaw_rad), "beta_rad": h(yaw.beta_rad), "body_x": hv(&yaw.body_x),
                "body_y": hv(&yaw.body_y), "body_z": hv(&yaw.body_z)},
        "dyb": dyb(gnss::dyb_axes(position, sun).unwrap()),
        "iers_tdb_epoch": h(orientation_tdb),
        "iers_at_tdb_quaternion": hv(&tdb_orientation.iers2010_quaternion().unwrap()),
        "eop": {
            "quaternion": hv(&eop.iers2010_quaternion().unwrap()),
            "rotation": hm3(eop.gcrf_to_itrf_matrix()),
            "rotation_rate": hm3(eop.gcrf_to_itrf_rotation_rate_matrix()),
            "inverse_rotation": hm3(eop.itrf_to_gcrf_matrix()),
            "inverse_rotation_rate": hm3(eop.itrf_to_gcrf_rotation_rate_matrix()),
            "earth_rotation_vector_itrf_rad_s": hv(&eop.earth_rotation_vector_itrf_rad_s()),
        },
        "shadow_model_moon_gradient": [h(shadow.0), hv(&shadow.1)],
    })
}

fn circular(value: CircularElements) -> Value {
    json!(hv(&[
        value.a_km,
        value.ex,
        value.ey,
        value.i_rad,
        value.raan_rad,
        value.mean_latitude_argument_rad
    ]))
}

fn keplerian(value: KeplerianElements) -> Value {
    json!(hv(&[
        value.a_km,
        value.e,
        value.i_rad,
        value.arg_perigee_rad,
        value.raan_rad,
        value.mean_anomaly_rad
    ]))
}

fn analytic_orbits(ctx: &Context) -> Value {
    let gravity = ZonalHarmonics::earth();
    let c = CircularElements {
        a_km: 7200.0,
        ex: 0.01,
        ey: -0.004,
        i_rad: 0.62,
        raan_rad: 1.2,
        mean_latitude_argument_rad: 0.15,
    };
    let k = KeplerianElements {
        a_km: 7200.0,
        e: 0.03,
        i_rad: 0.62,
        arg_perigee_rad: 0.22,
        raan_rad: 1.15,
        mean_anomaly_rad: 0.34,
    };
    let eh = EcksteinHechlerPropagator::from_mean_elements(10.0, c, &gravity).unwrap();
    let bl = BrouwerLyddanePropagator::from_mean_elements(10.0, k, &gravity, 1e-15).unwrap();
    let (cp, cv) = c.to_cartesian(gravity.mu_km3_s2).unwrap();
    let (kp, kv) = k.to_cartesian(gravity.mu_km3_s2).unwrap();
    let input = CartesianState::new(10.0, cp, cv);
    let eh_mean = eckstein_hechler_mean_elements(
        &input,
        &gravity,
        MeanConversionOptions::ECKSTEIN_HECHLER_DEFAULT,
    )
    .unwrap();
    let bl_mean = brouwer_lyddane_mean_elements(
        &input,
        &gravity,
        MeanConversionOptions::BROUWER_LYDDANE_DEFAULT,
    )
    .unwrap();
    json!({
        "source": source(ctx, "closed-form zonal propagation"),
        "gravity": hv(&[gravity.mu_km3_s2, gravity.re_km, gravity.c20, gravity.c30, gravity.c40, gravity.c50, gravity.c60]),
        "circular_position": hv(&cp), "circular_velocity": hv(&cv),
        "keplerian_position": hv(&kp), "keplerian_velocity": hv(&kv),
        "circular_from_cartesian": circular(CircularElements::from_cartesian(cp, cv, gravity.mu_km3_s2).unwrap()),
        "keplerian_from_cartesian": keplerian(KeplerianElements::from_cartesian(kp, kv, gravity.mu_km3_s2).unwrap()),
        "eccentricity": h(c.eccentricity()),
        "eh_state": state(eh.propagate(600.0).unwrap()), "bl_state": state(bl.propagate(600.0).unwrap()),
        "eh_osc": circular(eh.osculating_elements(600.0).unwrap()), "bl_osc": keplerian(bl.osculating_elements(600.0).unwrap()),
        "eh_initial_osc": circular(eckstein_hechler_osculating_elements(&c, &gravity).unwrap()),
        "bl_initial_osc": keplerian(brouwer_lyddane_osculating_elements(&k, &gravity).unwrap()),
        "eh_mean": [circular(eh_mean.elements), json!(eh_mean.iterations)],
        "bl_mean": [keplerian(bl_mean.elements), json!(bl_mean.iterations)],
    })
}

fn partials(value: AccelerationPartials) -> Value {
    let joint = |matrix: [[f64; 3]; 3]| hm3(matrix);
    json!({
        "wrt_position": joint(std::array::from_fn(|row| std::array::from_fn(|col| value.wrt_position[(row, col)]))),
        "wrt_velocity": joint(std::array::from_fn(|row| std::array::from_fn(|col| value.wrt_velocity[(row, col)]))),
    })
}

fn gravity_and_radiation(ctx: &Context) -> Value {
    let text = std::fs::read_to_string(ctx.fixtures.join("gravity/degree2.gfc")).unwrap();
    let icgem = IcgemGravityField::parse(&text)
        .unwrap()
        .gravity(2, 2)
        .unwrap();
    let egm = SphericalHarmonicGravity::egm96_truncated(8, 8).unwrap();
    let pos = [26_000.0, 1500.0, 500.0];
    let vel = [-0.2, 2.7, 2.5];
    let sun = [1.5e8, 7e6, 2e7];
    let moon = [384_400.0, -123_456.0, 739.0];
    let geometry = ecom_geometry(pos.into(), vel.into(), sun.into()).unwrap();
    let with_shadow = ecom_geometry_with_shadow(
        pos.into(),
        vel.into(),
        sun.into(),
        Some(moon.into()),
        EarthShadowModel::Spherical,
    )
    .unwrap();
    let initial = CartesianState::new(646_056_000.25, pos, vel);
    let ctx0 = PropagationContext::new();
    let srp = SolarRadiationPressure::new(1.3, 0.02).unwrap();
    let earth = EarthRadiationPressure::new(1.3, 0.02).unwrap();
    let ecom1 = Ecom1SolarRadiationPressure::new(Ecom1Coefficients {
        d0: 1.3e-9,
        dc: -3.0e-10,
        y0: 9.0e-11,
        ..Ecom1Coefficients::default()
    })
    .unwrap();
    let ecom2 =
        Ecom2SolarRadiationPressure::new(1, 1, vec![1e-9, 0.0, 0.0, 2e-9, 0.0, 0.0, 0.0]).unwrap();
    macro_rules! radiation {
        ($model:expr) => {{
            let model = $model;
            let sun_only = model.clone().with_moon_eclipse(false);
            let (p, v, s, m) = (pos.into(), vel.into(), sun.into(), moon.into());
            json!({
                "acceleration_with_sun": hv(sun_only.acceleration_with_sun(p, v, s).unwrap().as_slice()),
                "acceleration_with_sun_moon": hv(model.acceleration_with_sun_moon(p, v, s, m).unwrap().as_slice()),
                "acceleration_partials_with_sun": partials(sun_only.acceleration_partials_with_sun(p, v, s).unwrap()),
                "acceleration_partials_with_sun_moon": partials(model.acceleration_partials_with_sun_moon(p, v, s, m).unwrap()),
                "parameter_partials_with_sun": sun_only.parameter_partials_with_sun(p, v, s).unwrap().iter().map(|p| hv(p.as_slice())).collect::<Vec<_>>(),
                "parameter_partials_with_sun_moon": model.parameter_partials_with_sun_moon(p, v, s, m).unwrap().iter().map(|p| hv(p.as_slice())).collect::<Vec<_>>()
            })
        }};
    }
    json!({
        "source": source(ctx, "geopotential and radiation pressure"),
        "initial": state(initial),
        "sun": hv(&sun), "moon": hv(&moon),
        "icgem_acceleration": hv(&icgem.body_fixed_acceleration_at_km_s2(pos, 0.0).unwrap()),
        "icgem_potential": h(icgem.body_fixed_potential_km2_s2(pos).unwrap()),
        "egm96_acceleration": hv(&egm.body_fixed_acceleration_km_s2(pos).unwrap()),
        "srp_acceleration": hv(srp.acceleration(&initial, &ctx0).unwrap().as_slice()),
        "third_body_acceleration": hv(ThirdBodyGravity::default().acceleration(&initial, &ctx0).unwrap().as_slice()),
        "srp_explicit": hv(srp.acceleration_with_sun_moon(pos.into(), sun.into(), moon.into()).unwrap().as_slice()),
        "earth_explicit": hv(earth.acceleration_with_sun_moon(&initial, sun.into(), moon.into()).unwrap().as_slice()),
        "ecom1": radiation!(ecom1),
        "ecom2": radiation!(ecom2),
        "geometry": {"dyb": dyb(geometry.dyb), "delta_u_rad": geometry.delta_u_rad.map(h),
             "argument_of_latitude_rad": geometry.argument_of_latitude_rad.map(h), "lighting_ratio": h(geometry.lighting_ratio)},
        "geometry_with_shadow": {"dyb": dyb(with_shadow.dyb), "delta_u_rad": with_shadow.delta_u_rad.map(h),
             "argument_of_latitude_rad": with_shadow.argument_of_latitude_rad.map(h), "lighting_ratio": h(with_shadow.lighting_ratio)},
    })
}

pub(super) fn orbit_assessment(ctx: &Context) -> Value {
    let product = load_sp3(ctx, "GBM0MGXRAP_20201770000_01D_05M_ORB_73epoch.sp3");
    let epoch = Instant::from_nanos(TimeScale::Gpst, 646_056_000_000_000_000);
    let predicted = PredictedSp3::with_cutoff(&product, epoch).unwrap();
    let nav = std::fs::read_to_string(ctx.fixtures.join("nav/ESBC00DNK_R_20201770000_01D_MN.rnx"))
        .unwrap();
    let nav = BroadcastEphemeris::from_nav(&nav).unwrap();
    let broadcast = BroadcastOrbit::new(&nav, epoch).unwrap();
    let comparison = score_orbit(
        &broadcast,
        &product,
        &[gps(3)],
        &OrbitScoreOptions::new(vec![-1.0e7, 1.0e7]),
    )
    .unwrap();
    let broadcast_bin = &comparison.per_satellite[0].bins[0];
    let mut options = OrbitScoreOptions::new(vec![-1.0e7, 1.0e7]);
    options.sisre_weights = SisreWeightSelection::Fixed(SisreWeights::new(0.5, 0.25).unwrap());
    let score = score_orbit(&predicted, &product, &[gps(1)], &options).unwrap();

    let initial = CartesianState::new(0.0, [7000.0, 0.0, 0.0], [0.0, 7.5, 1.0]);
    let empirical = EmpiricalRtnAcceleration::new()
        .with_term(RtnAxis::Radial, EmpiricalHarmonic::Constant, 1e-8)
        .unwrap();
    let mut forces = CompositeForceModel::new();
    forces.add(Box::new(TwoBodyGravity::default()));
    forces.add(Box::new(empirical));
    let equations = VariationalEquations {
        force: &forces,
        parameters: &[1e-8],
        sensitivity_parameters: &[],
    };
    let epochs: Vec<_> = (0..7)
        .map(|index| VariationalEpoch::from_tdb_seconds(0.0, f64::from(index) * 120.0))
        .collect();
    let positions = propagate_variational(
        initial,
        &epochs,
        &equations,
        IntegratorKind::Dp54,
        &IntegratorOptions::default(),
        &PropagationContext::new(),
    )
    .unwrap();
    let samples: Vec<_> = positions
        .iter()
        .map(|value| InertialPositionSample {
            epoch: Instant::from_nanos(
                TimeScale::Tdb,
                (value.state.epoch_tdb_seconds * 1e9) as i128,
            ),
            position_gcrf_m: value.state.position_array().map(|x| x * 1000.0),
        })
        .collect();
    let mut fit_options = OrbitParameterFitOptions::default();
    fit_options.force_model = ForceModelKind::two_body();
    fit_options.additional_forces = vec![Arc::new(empirical)];
    fit_options.estimated_parameters = vec![EmpiricalRtnAcceleration::parameter_name(
        RtnAxis::Radial,
        EmpiricalHarmonic::Constant,
    )
    .into()];
    let fit = fit_inertial_orbit_parameters(&samples, gps(1), None, &fit_options).unwrap();
    let sp3_fit = fit_sp3_ecef_orbit_parameters(
        &product,
        gps(1),
        &TdbEarthOrientationProvider::new(),
        None,
        &OrbitParameterFitOptions::default(),
    )
    .unwrap();
    let mut limited = fit_options.clone();
    limited.max_condition_number = 1.5;
    let ill_conditioned = match fit_inertial_orbit_parameters(&samples, gps(1), None, &limited)
        .unwrap_err()
    {
        OrbitParameterFitError::IllConditionedNormalEquations {
            condition_number,
            limit,
            weakest,
            ..
        } => {
            json!({"condition_number": h(condition_number), "limit": h(limit), "weakest": weakest.into_iter().map(|(name, value)| (name, h(value))).collect::<Vec<_>>() })
        }
        error => panic!("{error}"),
    };
    let mut singular = fit_options.clone();
    singular.additional_forces = vec![
        Arc::new(Ecom1SolarRadiationPressure::new(Ecom1Coefficients::default()).unwrap()),
        Arc::new(Ecom2SolarRadiationPressure::new(0, 0, vec![0.0; 3]).unwrap()),
    ];
    singular.estimated_parameters = vec!["ecom1.d0".into(), "ecom2.d0".into()];
    let singular = match fit_inertial_orbit_parameters(&samples, gps(1), None, &singular)
        .unwrap_err()
    {
        OrbitParameterFitError::SingularNormalEquations {
            condition_number,
            weakest,
            ..
        } => {
            json!({"condition_number": h(condition_number), "weakest": weakest.into_iter().map(|(name, value)| (name, h(value))).collect::<Vec<_>>() })
        }
        error => panic!("{error}"),
    };
    let mut limited = fit_options.clone();
    limited.max_iterations = 1;
    let no_convergence =
        match fit_inertial_orbit_parameters(&samples, gps(1), None, &limited).unwrap_err() {
            OrbitParameterFitError::DidNotConverge {
                iterations,
                last_step_sigmas,
                ..
            } => json!({"iterations": iterations, "last_step_sigmas": h(last_step_sigmas)}),
            error => panic!("{error}"),
        };

    let scales = [0.0, 1.0]
        .map(|seconds| TimeScales::from_scale(TimeScale::Tdb, 2000, 1, 1, 12, 0, seconds).unwrap());
    let j2000 = sidereon_core::astro::time::j2000_seconds_from_split;
    let tdb = scales.map(|scale| j2000(scale.jd_whole, scale.tdb_fraction));
    let tt = scales.map(|scale| j2000(scale.jd_whole, scale.tt_fraction));
    let radial_seed = CartesianState::new(tdb[0], [7000.0, 0.0, 0.0], [-0.001, 0.0, 0.0]);
    let radial = propagate_variational(
        radial_seed,
        &[VariationalEpoch {
            tdb_j2000_s: tdb[1],
            elapsed_tt_s: tt[1] - tt[0],
        }],
        &VariationalEquations {
            force: &TwoBodyGravity::default(),
            parameters: &[],
            sensitivity_parameters: &[],
        },
        IntegratorKind::Dp54,
        &IntegratorOptions::default(),
        &PropagationContext::new(),
    )
    .unwrap();
    let covariance = match &fit.covariance {
        OrbitParameterCovariance::Estimated {
            matrix,
            correlation,
            variance_factor,
            degrees_of_freedom,
        } => json!({
            "matrix": matrix.row_iter().map(|row| row.iter().map(|value| h(*value)).collect::<Vec<_>>()).collect::<Vec<_>>(),
            "correlation": correlation.row_iter().map(|row| row.iter().map(|value| h(*value)).collect::<Vec<_>>()).collect::<Vec<_>>(),
            "variance_factor": h(*variance_factor),
            "degrees_of_freedom": degrees_of_freedom,
        }),
        OrbitParameterCovariance::Unbounded => panic!("expected estimated covariance"),
    };
    let late_propagator = StatePropagator::new(
        1_577_880_000.0,
        [6778.0, 0.0, 0.0],
        [0.0, 7.5, 1.0],
        ForceModelKind::two_body(),
        IntegratorKind::Dp54,
    )
    .with_drag(DragParameters::from_bc_factor_m2_kg(0.02, SpaceWeather::default(), 100.0).unwrap());
    let late_epochs: Vec<_> = (0..7)
        .map(|i| 1_577_880_000.0 + f64::from(i) * 120.0)
        .collect();
    let late_samples: Vec<_> = late_propagator
        .ephemeris(&late_epochs)
        .unwrap()
        .into_iter()
        .map(|state| InertialPositionSample {
            epoch: Instant::from_nanos(
                TimeScale::Tdb,
                state.epoch_tdb_seconds as i128 * 1_000_000_000,
            ),
            position_gcrf_m: state.position_array().map(|value| value * 1000.0),
        })
        .collect();
    let mut late_options = OrbitParameterFitOptions::default();
    late_options.force_model = late_propagator.force_model;
    late_options.drag = late_propagator.drag;
    assert!(matches!(
        fit_inertial_orbit_parameters(&late_samples, gps(1), None, &late_options),
        Err(OrbitParameterFitError::Fit(
            sidereon_core::orbit_determination::OrbitFitError::Ut1OutsideCoverage(
                sidereon_core::astro::time::DegradeReason::AfterCoverage,
            )
        ))
    ));
    use sidereon_core::astro::time::ValidityMode;
    let mut tide_options = OrbitParameterFitOptions::default();
    tide_options.force_model = ForceModelKind::composite(
        ForceModelComponents::earth_two_body().with_solid_earth_tide(Default::default()),
    );
    tide_options.propagation_context = PropagationContext::new().with_body_fixed_frame_provider(
        Arc::new(TdbEarthOrientationProvider::new().with_validity(ValidityMode::Permissive)),
    );
    let tide_fit = fit_inertial_orbit_parameters_with_validity(
        &samples,
        gps(1),
        None,
        &tide_options,
        ValidityMode::Permissive,
    )
    .unwrap();
    assert!(tide_fit.degraded.is_none());
    let defaults = OrbitParameterFitOptions::default();
    let stats = |stats: sidereon_core::orbit_scoring::ErrorStats| {
        hv(&[stats.rms_m, stats.mean_m, stats.max_abs_m])
    };
    json!({
        "source": source(ctx, "orbit score and parameter fit"),
        "score": {"scored": score.coverage.scored, "clocked": score.coverage.clocked,
                  "max_abs_m": h(score.per_satellite[0].bins[0].orbit_3d.unwrap().max_abs_m)},
        "broadcast_score": {
            "count": broadcast_bin.count,
            "radial": stats(broadcast_bin.radial.unwrap()),
            "transverse": stats(broadcast_bin.transverse.unwrap()),
            "normal": stats(broadcast_bin.normal.unwrap()),
            "orbit_3d": stats(broadcast_bin.orbit_3d.unwrap()),
            "sisre_orbit": stats(broadcast_bin.sisre_orbit.unwrap()),
        },
        "late_fit_samples": late_samples.iter().zip(&late_epochs).map(|(sample, epoch)|
            json!([*epoch as i64 * 1_000_000_000, hv(&sample.position_gcrf_m)])
        ).collect::<Vec<_>>(),
        "permissive_tide_fit": {
            "initial_state": state(tide_fit.value.initial_state),
            "condition_number": h(tide_fit.value.condition_number),
            "iterations": tide_fit.value.iterations,
        },
        "fit_defaults": {
            "observation_sigma_m": h(defaults.observation_sigma_m),
            "max_iterations": defaults.max_iterations,
            "convergence_threshold": h(defaults.convergence_threshold),
            "max_condition_number": h(defaults.max_condition_number),
            "min_ledger_samples": defaults.min_ledger_samples,
        },
        "sp3_fit": {
            "initial_state": state(sp3_fit.initial_state),
            "condition_number": h(sp3_fit.condition_number),
            "iterations": sp3_fit.iterations,
            "rms_3d_m": h(sp3_fit.residual_stats.rms_3d_m),
        },
        "ill_conditioned": ill_conditioned,
        "singular": singular,
        "no_convergence": no_convergence,
        "radial_seed": state(radial_seed),
        "radial_position_1s_m": hv(&radial[0].state.position_array().map(|value| value * 1000.0)),
        "fit": {
            "initial_state": state(fit.initial_state),
            "names": fit.parameter_names,
            "force_parameter": h(fit.force_parameters[0].value),
            "sigmas": fit.parameter_names.iter().map(|name| fit.sigma(name).map(h)).collect::<Vec<_>>(),
            "covariance": covariance,
            "residuals": fit.residuals.iter().map(|residual| hv(&[
                residual.epoch_tdb_j2000_s, residual.elapsed_tt_s,
                residual.radial_m, residual.along_m, residual.cross_m,
            ])).collect::<Vec<_>>(),
            "seed_rms_3d_m": h(fit.seed_rms_3d_m),
            "iterations": fit.iterations,
            "residual_stats": hv(&[fit.residual_stats.radial_rms_m, fit.residual_stats.along_rms_m,
                                    fit.residual_stats.cross_rms_m, fit.residual_stats.rms_3d_m]),
            "condition_number": h(fit.condition_number),
            "samples": positions.iter().zip(samples).map(|(value, sample)|
                json!([value.state.epoch_tdb_seconds as i64 * 1_000_000_000, hv(&sample.position_gcrf_m)])).collect::<Vec<_>>(),
        }
    })
}

fn de_ephemeris(ctx: &Context) -> Value {
    let data = DeEphemeris::load(ctx.fixtures.join("de/lnxp1990.440")).unwrap();
    let (start, end) = data.coverage_tdb_seconds();
    let time = start + 200.0;
    let states = data.sun_moon_at_tdb_seconds(time).unwrap();
    let body_gm = [
        ("sun", DeBody::Sun),
        ("mercury", DeBody::Mercury),
        ("venus", DeBody::Venus),
        ("earth_moon", DeBody::EarthMoon),
        ("earth", DeBody::Earth),
        ("moon", DeBody::Moon),
        ("mars", DeBody::Mars),
        ("jupiter", DeBody::Jupiter),
        ("saturn", DeBody::Saturn),
        ("uranus", DeBody::Uranus),
        ("neptune", DeBody::Neptune),
        ("pluto", DeBody::Pluto),
        ("solar_system", DeBody::SolarSystem),
    ]
    .map(|(name, body)| (name, data.gm_m3_s2(body).map(h)))
    .into_iter()
    .collect::<std::collections::BTreeMap<_, _>>();
    json!({
        "source": source(ctx, "JPL DE binary record and state"),
        "version": data.version(), "record_size": data.record_size(), "coverage": hv(&[start, end]),
        "constants": data.constants().iter().map(|(name, value)| (name, h(*value))).collect::<std::collections::BTreeMap<_, _>>(),
        "astronomical_unit_m": h(data.astronomical_unit_m()),
        "earth_moon_mass_ratio": h(data.earth_moon_mass_ratio()),
        "sun_gm": data.gm_m3_s2(DeBody::Sun).map(h),
        "body_gm": body_gm,
        "epoch": h(time),
        "sun": {"position_m": hv(&states.sun.position_m), "velocity_m_s": hv(&states.sun.velocity_m_s)},
        "moon": {"position_m": hv(&states.moon.position_m), "velocity_m_s": hv(&states.moon.velocity_m_s)}
    })
}

fn attitude_value(attitude: GnssAttitude) -> Value {
    let mode = match attitude.mode {
        AttitudeMode::Nominal => "nominal",
        AttitudeMode::NoonTurn => "noon_turn",
        AttitudeMode::MidnightTurn => "midnight_turn",
        AttitudeMode::Shadow => "shadow",
        AttitudeMode::OrbitNormal => "orbit_normal",
        AttitudeMode::ModifiedYawSteering => "modified_yaw_steering",
        _ => panic!("unknown attitude mode"),
    };
    json!({
        "mode": mode, "yaw_rad": h(attitude.yaw_rad),
        "nominal_yaw_rad": h(attitude.nominal_yaw_rad), "beta_rad": h(attitude.beta_rad),
        "orbit_angle_rad": h(attitude.orbit_angle_rad), "body_x": hv(&attitude.body_x),
        "body_y": hv(&attitude.body_y), "body_z": hv(&attitude.body_z),
        "dyb": attitude.dyb.map(dyb),
    })
}

fn attitude_modes(gravity: &ZonalHarmonics) -> Value {
    let orbit = EcksteinHechlerPropagator::from_mean_elements(
        0.0,
        CircularElements {
            a_km: 26_560.0,
            ex: 0.0,
            ey: 0.0,
            i_rad: 0.409,
            raan_rad: 0.0,
            mean_latitude_argument_rad: 0.0,
        },
        gravity,
    )
    .unwrap();
    let trajectory = OrbitAttitudeTrajectory::from_eckstein_hechler(&orbit);
    let gps_iir = GnssAttitudeLaw::GpsIIR {
        yaw_rate_rad_s: gnss::GPS_IIR_DEFAULT_YAW_RATE_RAD_S,
    };
    let gps_iif = GnssAttitudeLaw::GpsIIF {
        yaw_rate_rad_s: gnss::GPS_IIF_DEFAULT_YAW_RATE_RAD_S,
        yaw_bias_rad: gnss::GPS_IIF_DEFAULT_YAW_BIAS_RAD,
        shadow_limit_rad: gnss::GPS_SHADOW_LIMIT_RAD,
    };
    let fixed = GnssAttitudeLaw::FixedBetaYawSteering { beta0_rad: 0.1 };
    let mut cases = serde_json::Map::new();
    for (name, law, mode) in [
        ("nominal", gps_iir, AttitudeMode::Nominal),
        ("noon_turn", gps_iir, AttitudeMode::NoonTurn),
        ("midnight_turn", gps_iir, AttitudeMode::MidnightTurn),
        ("shadow", gps_iif, AttitudeMode::Shadow),
        (
            "modified_yaw_steering",
            fixed,
            AttitudeMode::ModifiedYawSteering,
        ),
    ] {
        let (epoch, attitude) = (0..1440)
            .find_map(|minute| {
                let epoch = f64::from(minute) * 60.0;
                let attitude = gnss::gnss_attitude(&law, &trajectory, epoch).ok()?;
                (attitude.mode == mode).then_some((epoch, attitude))
            })
            .unwrap_or_else(|| panic!("unavailable attitude mode {name}"));
        cases.insert(
            name.into(),
            json!({"epoch": h(epoch), "attitude": attitude_value(attitude)}),
        );
    }
    Value::Object(cases)
}

fn orbit_attitude(ctx: &Context) -> Value {
    let default = TdbEarthOrientationProvider::new();
    let satellite = gps(3);
    let gpst = sidereon_core::astro::time::j2000_seconds(2020, 6, 25, 18, 10, 0.25);
    let tdb = tdb_from_tt_j2000_seconds(gpst + 51.184);
    let sp3_tdb = tdb_from_tt_j2000_seconds(646_316_400.25 + 51.184);
    let origin = Instant::from_nanos(TimeScale::Gpst, 646_056_000_000_000_000);
    let product = load_sp3(ctx, "GBM0MGXRAP_20201770000_01D_05M_ORB_120epoch.sp3");
    let predicted = PredictedSp3::with_cutoff(&product, origin).unwrap();
    let nav = std::fs::read_to_string(ctx.fixtures.join("nav/ESBC00DNK_R_20201770000_01D_MN.rnx"))
        .unwrap();
    let nav = BroadcastEphemeris::from_nav(&nav).unwrap();
    let broadcast = BroadcastOrbit::new(&nav, origin).unwrap();

    let eop = Iers2010EopSample {
        mjd_utc: 59_025,
        xp_arcsec: 0.1,
        yp_arcsec: 0.15,
        ut1_minus_utc_s: -0.21,
        lod_s: 0.001,
        dx_arcsec: 0.0001,
        dy_arcsec: -0.0002,
        pole_rates_rad_s: None,
    };
    let iers = Iers2010EarthOrientationProvider::new(vec![
        eop,
        Iers2010EopSample {
            mjd_utc: 59_026,
            ..eop
        },
    ])
    .unwrap();
    let utc =
        |shift: i128| Instant::from_nanos(TimeScale::Utc, (646_358_400 + shift) * 1_000_000_000);
    let sample_source = OrbitTrajectory::new(
        "ITRF",
        utc(0),
        [
            (-2, [21_002_000.0, -15_002_000.0, 8_001_000.0]),
            (0, [21_000_000.0, -15_000_000.0, 8_000_000.0]),
            (2, [20_996_000.0, -14_997_000.0, 7_998_000.0]),
        ]
        .map(|(shift, position_ecef_m)| TrajectorySample {
            satellite,
            epoch: utc(shift),
            position_ecef_m,
            clock_s: None,
        }),
    )
    .unwrap();
    let sampled = OrbitAttitudeTrajectory::from_orbit_source(&sample_source, satellite, &default)
        .with_velocity_half_step_s(2.0)
        .unwrap();

    let gravity = ZonalHarmonics::earth();
    let eh_elements = CircularElements {
        a_km: 7200.0,
        ex: 0.01,
        ey: -0.004,
        i_rad: 0.62,
        raan_rad: 1.2,
        mean_latitude_argument_rad: 0.15,
    };
    let eh = EcksteinHechlerPropagator::from_mean_elements(10.0, eh_elements, &gravity).unwrap();
    let bl = BrouwerLyddanePropagator::from_mean_elements(
        10.0,
        KeplerianElements {
            a_km: 7200.0,
            e: 0.03,
            i_rad: 0.62,
            arg_perigee_rad: 0.22,
            raan_rad: 1.15,
            mean_anomaly_rad: 0.34,
        },
        &gravity,
        1e-15,
    )
    .unwrap();
    let de = DeEphemeris::load(ctx.fixtures.join("de/lnxp1990.440")).unwrap();
    let de_epoch = de.coverage_tdb_seconds().0 + 200.0;
    let eh_de =
        EcksteinHechlerPropagator::from_mean_elements(de_epoch, eh_elements, &gravity).unwrap();
    let mut options = IntegratorOptions::default();
    options.dense_output = true;
    let numerical = StatePropagator::new(
        0.0,
        [7000.0, 0.0, 0.0],
        [0.0, 7.546049108166282, 0.0],
        ForceModelKind::two_body(),
        IntegratorKind::Dp54,
    )
    .with_options(options)
    .propagate_to(600.0)
    .unwrap();
    let case = |name, trajectory: OrbitAttitudeTrajectory<'_>, epoch| {
        let sample = trajectory
            .sample(epoch)
            .unwrap_or_else(|| panic!("unavailable {name} at {epoch}"));
        let attitude =
            gnss::gnss_attitude(&GnssAttitudeLaw::OrbitNormal, &trajectory, epoch).unwrap();
        json!({
            "epoch": h(epoch),
            "sample": {"position_m": hv(&sample.position_m), "velocity_m_s": hv(&sample.velocity_m_s),
                       "sun_position_m": hv(&sample.sun_position_m)},
            "attitude": attitude_value(attitude),
        })
    };
    json!({
        "source": source(ctx, "orbit attitude and continuous propagation"),
        "modes": attitude_modes(&gravity),
        "sp3": case("sp3", OrbitAttitudeTrajectory::from_sp3(&product, satellite, &iers), sp3_tdb),
        "predicted": case("predicted", OrbitAttitudeTrajectory::from_orbit_source(&predicted, satellite, &iers), sp3_tdb),
        "broadcast": case("broadcast", OrbitAttitudeTrajectory::from_broadcast(&nav, satellite, &default), tdb),
        "broadcast_source": case("broadcast_source", OrbitAttitudeTrajectory::from_orbit_source(&broadcast, satellite, &default), tdb),
        "sampled": case("sampled", sampled, tdb_from_tt_j2000_seconds(646_358_400.0 + 69.184)),
        "eckstein_hechler": case("eckstein_hechler", OrbitAttitudeTrajectory::from_eckstein_hechler(&eh), 600.0),
        "brouwer_lyddane": case("brouwer_lyddane", OrbitAttitudeTrajectory::from_brouwer_lyddane(&bl), 600.0),
        "de": case("de", OrbitAttitudeTrajectory::from_eckstein_hechler(&eh_de).with_de_ephemeris(&de), de_epoch),
        "dense": case("dense", OrbitAttitudeTrajectory::from_dense_output(numerical.dense.as_ref().unwrap()), 123.25),
        "numerical": {
            "final_state": state(numerical.final_state),
            "points": numerical.points.iter().map(|point| json!([
                h(point.epoch_tdb_seconds), hv(&point.position_km), hv(&point.velocity_km_s)
            ])).collect::<Vec<_>>(),
            "stats": [numerical.stats.accepted_steps, numerical.stats.rejected_steps, numerical.stats.evaluations],
        },
    })
}
