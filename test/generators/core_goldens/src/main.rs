//! Writes the expected values of the Elixir tests that compare against
//! `sidereon-core` directly, so those values come from the core's public API
//! rather than from this binding's own output.
//!
//! Run from this directory, against the core the binding builds with, naming
//! that core's revision:
//!
//! ```text
//! SIDEREON_CORE_REV=<core commit> cargo run --release -- ../../fixtures
//! ```
//!
//! Each golden holds the inputs the test hands to the binding and the core's
//! answer on exactly those inputs, with every float as the hex of its IEEE-754
//! bits, and names the core revision in its `source` field.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde_json::{json, Value};
use sidereon_core::astro::time::civil;
use sidereon_core::ephemeris::Sp3;
use sidereon_core::fusion::ekf::EkfUpdateOptions;
use sidereon_core::fusion::loose::{InertialFilter, InertialFilterConfig, LooseCouplingConfig};
use sidereon_core::fusion::state::{ErrorStateLayout, FusionFilterKind, InsFilterState};
use sidereon_core::fusion::tight::{
    TightCouplingConfig, TightGnssEpoch, TightGnssObservation, TightRangeRateObservation,
};
use sidereon_core::fusion::ukf::{UkfUpdateOptions, UnscentedTransformOptions};
use sidereon_core::fusion::GnssFixStatusWeighting;
use sidereon_core::inertial::{
    ConingCorrection, ImuBias, ImuCalibration, ImuErrorModel, ImuSpec, MechanizationConfig,
    NavState,
};
use sidereon_core::observables::{
    predict, pseudorange_transmit_epoch_j2000_s, pseudorange_transmit_geometry,
    ObservableEphemerisSource, PredictOptions,
};
use sidereon_core::positioning::{
    solve_static, solve_static_reference_station_rinex, solve_with_doppler_velocity,
    solve_with_policy, ClockRelativity, Corrections, DopplerObservation, KlobucharCoeffs,
    Observation, PseudorangeCode, ReceiverSolution, SolveInputs, SolvePolicy, StaticEpoch,
    StaticReferenceCarrierRinexOptions, StaticReferenceStationRinexOptions, StaticSolveOptions,
    SurfaceMet,
};
use sidereon_core::positioning::{QzssClock, TroposphereModel};
use sidereon_core::rinex::observations::RinexObs;
use sidereon_core::rtk::BaselineReferenceSelection;
use sidereon_core::rtk_filter::{
    CycleSlipPolicy, DynamicsModel, FixedSolveOpts, FloatSolveOpts, MeasModel,
    ResidualValidationOpts, RtkArcConfig, RtkArcPreprocessing, RtkRinexArcOptions,
    RtkStaticArcConfig, SearchOpts, StochasticModel, UpdateOpts, ValidatedFixedSolveOpts,
};
use sidereon_core::velocity::range_rate_to_doppler;
use sidereon_core::{GnssSatelliteId, GnssSystem};

const C_M_S: f64 = 299_792_458.0;
const F_L1_HZ: f64 = 1_575_420_000.0;
/// Surface meteorology the binding's positioning entry points default to.
const MET: SurfaceMet = SurfaceMet {
    pressure_hpa: 1013.25,
    temperature_k: 288.15,
    relative_humidity: 0.5,
};

struct Context {
    fixtures: PathBuf,
    revision: String,
}

fn main() {
    let fixtures: PathBuf = std::env::args()
        .nth(1)
        .map(PathBuf::from)
        .expect("usage: sidereon_ex_core_goldens <test/fixtures directory>");
    let revision = std::env::var("SIDEREON_CORE_REV")
        .expect("set SIDEREON_CORE_REV to the core commit this run builds against");
    let ctx = Context { fixtures, revision };

    scenario_expected(&ctx, "g01_two_epochs");
    spp_trace(&ctx);
    static_solve(&ctx);
    doppler_solve(&ctx);
    fusion_tight(&ctx);
    rtk_reference_station(&ctx);
    constellation_visibility(&ctx);
}

fn source(ctx: &Context, what: &str) -> String {
    format!("sidereon-core {} {what}", ctx.revision)
}

fn h(value: f64) -> String {
    format!("0x{:016x}", value.to_bits())
}

fn hv(values: &[f64]) -> Vec<String> {
    values.iter().map(|v| h(*v)).collect()
}

fn hm3(matrix: [[f64; 3]; 3]) -> Vec<Vec<String>> {
    matrix.iter().map(|row| hv(row)).collect()
}

fn hm4(matrix: [[f64; 4]; 4]) -> Vec<Vec<String>> {
    matrix.iter().map(|row| hv(row)).collect()
}

fn hex_to_f64(text: &str) -> f64 {
    let digits = text.trim_start_matches("0x");
    f64::from_bits(u64::from_str_radix(digits, 16).expect("hex float"))
}

fn write(dir: &Path, name: &str, value: &Value) {
    std::fs::create_dir_all(dir).expect("create golden directory");
    let output = dir.join(name);
    let mut rendered = serde_json::to_string_pretty(value).expect("render golden");
    rendered.push('\n');
    std::fs::write(&output, rendered).expect("write golden");
    eprintln!("wrote {}", output.display());
}

fn goldens_dir(ctx: &Context) -> PathBuf {
    ctx.fixtures.join("core_goldens")
}

fn load_sp3(ctx: &Context, name: &str) -> Sp3 {
    let bytes = std::fs::read(ctx.fixtures.join("sp3").join(name)).expect("read SP3 fixture");
    Sp3::parse(&bytes).expect("parse SP3 fixture")
}

fn gps(prn: u8) -> GnssSatelliteId {
    GnssSatelliteId::new(GnssSystem::Gps, prn).expect("GPS satellite")
}

fn sat_token(sat: GnssSatelliteId) -> String {
    sat.to_string()
}

/// Seconds since J2000, second of day and fractional day of year of a civil
/// epoch, as the binding's positioning entry points form them.
fn epoch_terms(
    year: i32,
    month: i32,
    day: i32,
    hour: i32,
    minute: i32,
    second: f64,
) -> (f64, f64, f64) {
    (
        civil::j2000_seconds(year, month, day, hour, minute, second),
        civil::second_of_day(hour, minute, second),
        civil::day_of_year(year, month, day, hour, minute, second),
    )
}

#[allow(clippy::too_many_arguments)]
fn solve_inputs(
    observations: &[(GnssSatelliteId, f64)],
    (t_rx_j2000_s, t_rx_second_of_day_s, day_of_year): (f64, f64, f64),
    initial_guess: [f64; 4],
    ionosphere: bool,
    troposphere: bool,
    klobuchar: KlobucharCoeffs,
    met: SurfaceMet,
) -> SolveInputs {
    SolveInputs {
        observations: observations
            .iter()
            .map(|(satellite_id, pseudorange_m)| Observation {
                satellite_id: *satellite_id,
                pseudorange_m: *pseudorange_m,
            })
            .collect(),
        t_rx_j2000_s,
        t_rx_second_of_day_s,
        day_of_year,
        initial_guess,
        corrections: Corrections {
            ionosphere,
            troposphere,
        },
        klobuchar,
        beidou_klobuchar: None,
        galileo_nequick: None,
        sbas_iono: None,
        glonass_channels: BTreeMap::new(),
        met,
        robust: None,
        pseudorange_code: PseudorangeCode::SingleFrequency,
        qzss_clock: QzssClock::Gps,
        troposphere_model: TroposphereModel::Rtklib,
    }
}

fn zero_klobuchar() -> KlobucharCoeffs {
    KlobucharCoeffs {
        alpha: [0.0; 4],
        beta: [0.0; 4],
    }
}

fn receiver_solution_json(solution: &ReceiverSolution) -> Value {
    let geodetic = solution.geodetic.expect("geodetic requested");
    json!({
        "position_m": hv(&solution.position.as_array()),
        "rx_clock_s": h(solution.rx_clock_s),
        "rx_clock_drift_s_s": solution.rx_clock_drift_s_s.map(h),
        "geodetic": {
            "lat_rad": h(geodetic.lat_rad),
            "lon_rad": h(geodetic.lon_rad),
            "height_m": h(geodetic.height_m),
        },
        "position_covariance_ecef_m2": hm3(solution.position_covariance.ecef_m2),
        "position_covariance_enu_m2": hm3(solution.position_covariance.enu_m2),
        "used_sats": solution.used_sats.iter().map(|s| sat_token(*s)).collect::<Vec<_>>(),
        "status": format!("{:?}", solution.metadata.status),
        "iterations": solution.metadata.iterations,
        "converged": solution.metadata.converged,
    })
}

/// The clock a single-frequency positioning model uses for `sat` at the
/// transmission epoch: the source clock, plus the relativistic term a product
/// clock leaves to the user, less the broadcast group delay.
fn model_clock_s<S: ObservableEphemerisSource>(
    source: &S,
    sat: GnssSatelliteId,
    t_tx: f64,
    clock_s: f64,
) -> f64 {
    let relativity = match source.clock_relativity_s(sat, t_tx) {
        ClockRelativity::NotApplicable => 0.0,
        ClockRelativity::Term(term) => term,
        ClockRelativity::Unavailable => panic!("no relativistic term for {sat} at {t_tx}"),
    };
    let group_delay = source
        .single_frequency_group_delay_s(sat, t_tx)
        .unwrap_or(0.0);
    clock_s + relativity - group_delay
}

/// The clean single-frequency pseudorange of `sat` for a receiver at
/// `receiver` with clock offset `rx_clock_s`, time-tagged `t_rx`, as SPP
/// models it: the satellite placed from the pseudorange itself (RTKLIB
/// `satposs`), the `geodist` range, and the model clock. The fixed point of
/// `P = range(P) + c (rx_clock - sat_clock(P))`, seeded by the geometric
/// light-time prediction.
fn spp_pseudorange<S: ObservableEphemerisSource>(
    source: &S,
    sat: GnssSatelliteId,
    receiver: [f64; 3],
    t_rx: f64,
    rx_clock_s: f64,
) -> f64 {
    let predicted =
        predict(source, sat, receiver, t_rx, PredictOptions::default()).expect("predict");
    let clock = model_clock_s(
        source,
        sat,
        predicted.transmit_time_j2000_s,
        predicted.sat_clock_s.expect("SP3 clock"),
    );
    let mut pseudorange_m = predicted.geometric_range_m + C_M_S * (rx_clock_s - clock);
    for _ in 0..8 {
        let t_tx =
            pseudorange_transmit_epoch_j2000_s(source, sat, t_rx, pseudorange_m).expect("place");
        let geometry = pseudorange_transmit_geometry(source, sat, receiver, t_rx, t_tx, true)
            .expect("geometry");
        let clock = model_clock_s(source, sat, t_tx, geometry.sat_clock_s.expect("SP3 clock"));
        let next = geometry.geometric_range_m + C_M_S * (rx_clock_s - clock);
        if next == pseudorange_m {
            break;
        }
        pseudorange_m = next;
    }
    pseudorange_m
}

/// The core scenario simulation of `scenario/<name>.json`, written to
/// `scenario/<name>_expected.json`.
fn scenario_expected(ctx: &Context, name: &str) {
    use sidereon_core::scenario::{simulate_scenario, Scenario};
    let dir = ctx.fixtures.join("scenario");
    let text = std::fs::read_to_string(dir.join(format!("{name}.json"))).expect("read scenario");
    let scenario: Scenario =
        serde_json::from_str(&text).expect("scenario fixture is a core scenario");
    let set = simulate_scenario(&scenario).expect("scenario simulates");
    let value = serde_json::to_value(&set).expect("observation set serializes");
    write(
        &dir,
        &format!("{name}_expected.json"),
        &json!({
            "source": source(ctx, &format!("simulate_scenario of {name}.json")),
            "observations": value["observations"],
            "truth_terms": value["truth_terms"],
            "receiver_truth": value["receiver_truth"],
        }),
    );
}

/// SPP on the unmodified `spp_trace_L2_tropo.json` inputs, with the options
/// the binding's trace tests pass, from each initial guess they use.
fn spp_trace(ctx: &Context) {
    let text =
        std::fs::read_to_string(ctx.fixtures.join("spp_trace_L2_tropo.json")).expect("read trace");
    let doc: Value = serde_json::from_str(&text).expect("trace JSON");
    let inputs = &doc["fixture"]["inputs"];
    let observations: Vec<(GnssSatelliteId, f64)> = inputs["observations"]
        .as_array()
        .expect("observations")
        .iter()
        .map(|obs| {
            let sat: GnssSatelliteId = obs["sat_id"].as_str().unwrap().parse().expect("satellite");
            (sat, hex_to_f64(obs["p_meas_m"].as_str().unwrap()))
        })
        .collect();
    let four = |key: &str| -> [f64; 4] {
        let values: Vec<f64> = inputs[key]
            .as_array()
            .unwrap()
            .iter()
            .map(|v| hex_to_f64(v.as_str().unwrap()))
            .collect();
        [values[0], values[1], values[2], values[3]]
    };
    let met = SurfaceMet {
        pressure_hpa: hex_to_f64(inputs["met"]["pressure_hpa"].as_str().unwrap()),
        temperature_k: hex_to_f64(inputs["met"]["temperature_k"].as_str().unwrap()),
        relative_humidity: hex_to_f64(inputs["met"]["relative_humidity"].as_str().unwrap()),
    };
    let klobuchar = KlobucharCoeffs {
        alpha: four("klobuchar_alpha"),
        beta: four("klobuchar_beta"),
    };
    let frozen: Vec<f64> = doc["fixture"]["frozen"]["initial_guess_x0"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| hex_to_f64(v.as_str().unwrap()))
        .collect();
    // The trace's epoch index 48, 2020-06-24 12:00:00 GPST, as the binding tests pass it.
    let epoch = epoch_terms(2020, 6, 24, 12, 0, 0.0);
    let sp3 = load_sp3(ctx, "GRG0MGXFIN_20201760000_01D_15M_ORB.SP3");

    let mut solves = serde_json::Map::new();
    for (label, guess) in [
        ("near_guess", [4_500_000.0, 500_000.0, 4_500_000.0, 0.0]),
        ("frozen_guess", [frozen[0], frozen[1], frozen[2], frozen[3]]),
    ] {
        let inputs = solve_inputs(&observations, epoch, guess, true, true, klobuchar, met);
        let solution =
            solve_with_policy(&sp3, &inputs, true, SolvePolicy::default()).expect("trace solve");
        solves.insert(
            label.to_string(),
            json!({"initial_guess": hv(&guess), "solution": receiver_solution_json(&solution)}),
        );
    }
    write(
        &goldens_dir(ctx),
        "spp_trace_L2_tropo.json",
        &json!({
            "source": source(ctx, "positioning::solve_with_policy on the unmodified spp_trace_L2_tropo.json inputs"),
            "epoch": "2020-06-24T12:00:00",
            "t_rx_j2000_s": h(epoch.0),
            "solves": Value::Object(solves),
        }),
    );
}

const STATIC_RECEIVER: [f64; 3] = [4_500_000.0, 500_000.0, 4_500_000.0];
const STATIC_SATELLITES: [u8; 7] = [10, 16, 18, 20, 21, 26, 27];

/// The static solve over three epochs, on pseudoranges formed by the SPP
/// model at a zero receiver clock.
fn static_solve(ctx: &Context) {
    let sp3 = load_sp3(ctx, "GRG0MGXFIN_20201760000_01D_15M_ORB.SP3");
    let initial = [4_400_000.0, 400_000.0, 4_400_000.0];
    let mut epochs = Vec::new();
    let mut epoch_inputs = Vec::new();
    for (label, minute) in [
        ("2020-06-24T12:00:00", 0),
        ("2020-06-24T12:15:00", 15),
        ("2020-06-24T12:30:00", 30),
    ] {
        let terms = epoch_terms(2020, 6, 24, 12, minute, 0.0);
        let observations: Vec<(GnssSatelliteId, f64)> = STATIC_SATELLITES
            .iter()
            .map(|prn| {
                (
                    gps(*prn),
                    spp_pseudorange(&sp3, gps(*prn), STATIC_RECEIVER, terms.0, 0.0),
                )
            })
            .collect();
        epoch_inputs.push(json!({
            "epoch": label,
            "observations": observations.iter().map(|(s, p)| json!([sat_token(*s), h(*p)])).collect::<Vec<_>>(),
        }));
        let inputs = solve_inputs(
            &observations,
            terms,
            [initial[0], initial[1], initial[2], 0.0],
            false,
            false,
            zero_klobuchar(),
            MET,
        );
        epochs.push(StaticEpoch::from_solve_inputs(inputs));
    }
    let mut options = StaticSolveOptions::default();
    options.initial_position_m = initial;
    options.with_geodetic = true;
    options.robust = None;
    let solution = solve_static(&sp3, &epochs, options).expect("static solve");
    let geodetic = solution.geodetic.expect("geodetic requested");
    write(
        &goldens_dir(ctx),
        "static_solve.json",
        &json!({
            "source": source(ctx, "positioning::solve_static"),
            "receiver_truth_m": hv(&STATIC_RECEIVER),
            "initial_position_m": hv(&initial),
            "epochs": epoch_inputs,
            "solution": {
                "position_m": hv(&solution.position.as_array()),
                "geodetic": {
                    "lat_rad": h(geodetic.lat_rad),
                    "lon_rad": h(geodetic.lon_rad),
                    "height_m": h(geodetic.height_m),
                },
                "per_epoch_clock": solution.per_epoch_clock.iter().map(|c| json!({
                    "epoch_index": c.epoch_index,
                    "system": c.system.letter().to_string(),
                    "clock_s": h(c.clock_s),
                })).collect::<Vec<_>>(),
                "status": format!("{:?}", solution.metadata.status),
                "iterations": solution.metadata.iterations,
                "converged": solution.metadata.converged,
                "used_measurements": solution.metadata.used_measurements,
                "n_parameters": solution.metadata.n_parameters,
                "redundancy": solution.metadata.redundancy,
                "residual_rms_m": h(solution.residual_rms_m()),
                "covariance_position_ecef_m2": hm3(solution.covariance.position_ecef_m2),
            },
        }),
    );
}

/// SPP with a Doppler velocity solve: pseudoranges formed by the SPP model at a
/// zero receiver clock, Doppler rows formed from the forward prediction's
/// range rate for a receiver moving at `velocity` with clock drift `drift`.
fn doppler_solve(ctx: &Context) {
    let sp3 = load_sp3(ctx, "GRG0MGXFIN_20201760000_01D_15M_ORB.SP3");
    let terms = epoch_terms(2020, 6, 24, 12, 0, 0.0);
    let velocity = [12.0, -7.0, 3.0];
    let drift = 1.0e-9;
    let initial_guess = [4_400_000.0, 400_000.0, 4_400_000.0, 0.0];
    let observations: Vec<(GnssSatelliteId, f64)> = STATIC_SATELLITES
        .iter()
        .map(|prn| {
            (
                gps(*prn),
                spp_pseudorange(&sp3, gps(*prn), STATIC_RECEIVER, terms.0, 0.0),
            )
        })
        .collect();
    let doppler: Vec<DopplerObservation> = STATIC_SATELLITES
        .iter()
        .map(|prn| {
            let predicted = predict(
                &sp3,
                gps(*prn),
                STATIC_RECEIVER,
                terms.0,
                PredictOptions::default(),
            )
            .expect("predict");
            let [ex, ey, ez] = predicted.los_unit;
            let rho_dot = predicted.range_rate_m_s
                - (ex * velocity[0] + ey * velocity[1] + ez * velocity[2])
                + C_M_S * drift;
            DopplerObservation {
                satellite_id: gps(*prn),
                doppler_hz: range_rate_to_doppler(rho_dot, F_L1_HZ).expect("doppler"),
                carrier_hz: F_L1_HZ,
                sat_clock_drift_s_s: 0.0,
            }
        })
        .collect();
    let inputs = solve_inputs(
        &observations,
        terms,
        initial_guess,
        false,
        false,
        zero_klobuchar(),
        MET,
    );
    let solution =
        solve_with_doppler_velocity(&sp3, &inputs, &doppler, true).expect("doppler solve");
    let velocity_solution = solution.velocity.as_ref().expect("velocity solved");
    write(
        &goldens_dir(ctx),
        "doppler_solve.json",
        &json!({
            "source": source(ctx, "positioning::solve_with_doppler_velocity"),
            "epoch": "2020-06-24T12:00:00",
            "receiver_truth_m": hv(&STATIC_RECEIVER),
            "velocity_truth_m_s": hv(&velocity),
            "clock_drift_truth_s_s": h(drift),
            "initial_guess": hv(&initial_guess),
            "observations": observations.iter().map(|(s, p)| json!([sat_token(*s), h(*p)])).collect::<Vec<_>>(),
            "doppler": doppler.iter().map(|d| json!([sat_token(d.satellite_id), h(d.doppler_hz), h(d.carrier_hz), h(d.sat_clock_drift_s_s)])).collect::<Vec<_>>(),
            "receiver": receiver_solution_json(&solution.receiver),
            "velocity": {
                "velocity_m_s": hv(&velocity_solution.velocity_m_s),
                "speed_m_s": h(velocity_solution.speed_m_s),
                "clock_drift_s_s": h(velocity_solution.clock_drift_s_s),
                "state_covariance": hm4(velocity_solution.state_covariance),
                "used_sats": velocity_solution.used_sats.iter().map(|s| sat_token(*s)).collect::<Vec<_>>(),
            },
        }),
    );
}

/// One tight GNSS/INS update from the SP3 source: a filter at the Earth's
/// surface on the X axis, one G01 pseudorange formed from the first SP3 record
/// plus 2 m, with a range-rate row.
fn fusion_tight(ctx: &Context) {
    let sp3 = load_sp3(ctx, "GBM0MGXRAP_20201770000_01D_05M_ORB_73epoch.sp3");
    let wgs84_a_m = 6_378_137.0;
    let epoch = sp3.epochs_j2000_seconds()[0];
    let record = sp3.state(gps(1), 0).expect("G01 first record");
    let p = record.position;
    let pseudorange_m = ((p.x_m - wgs84_a_m).powi(2) + p.y_m.powi(2) + p.z_m.powi(2)).sqrt()
        + record.clock_s.expect("G01 clock") * C_M_S
        + 2.0;

    let spec = ImuSpec::datasheet(0.0, 0.0, 0.0, 0.0, 3_600.0, 3_600.0, None, None);
    let mut config = InertialFilterConfig::new(spec).expect("filter config");
    config.filter_kind = FusionFilterKind::Ekf;
    config.imu_model = ImuErrorModel {
        bias: ImuBias {
            accel_mps2: [0.0; 3],
            gyro_rps: [0.0; 3],
        },
        calibration: ImuCalibration {
            accel_scale_misalignment: [[0.0; 3]; 3],
            gyro_scale_misalignment: [[0.0; 3]; 3],
        },
    };
    config.imu_to_body_dcm = [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]];
    let mut mechanization = MechanizationConfig::default();
    mechanization.coning_correction = ConingCorrection::Off;
    config.mechanization = mechanization;
    let mut loose = LooseCouplingConfig::default();
    loose.lever_arm_body_m = [0.0; 3];
    loose.update_options = EkfUpdateOptions::default();
    loose.fix_status_weighting = GnssFixStatusWeighting {
        single_sigma_multiplier: 1.0,
        float_sigma_multiplier: 1.0,
        fixed_sigma_multiplier: 1.0,
    };
    loose.measurement_reweighting = None;
    loose.prediction_adaptation = None;
    loose.stationary_updates = None;
    loose.non_holonomic = None;
    config.loose = loose;
    let mut tight = TightCouplingConfig::default();
    tight.lever_arm_body_m = [0.0; 3];
    tight.light_time = false;
    tight.sagnac = false;
    tight.initial_clock_bias_variance_m2 = 1.0e12;
    tight.initial_clock_drift_variance_m2_s2 = 1.0e6;
    tight.clock_bias_random_walk_m2_s = 1.0;
    tight.clock_drift_random_walk_m2_s3 = 1.0e-2;
    tight.update_options = EkfUpdateOptions::default();
    config.tight = tight;
    let mut transform = UnscentedTransformOptions::default();
    transform.alpha = 0.5;
    transform.beta = 2.0;
    transform.kappa = 0.0;
    let mut ukf = UkfUpdateOptions::default();
    ukf.transform = transform;
    ukf.innovation_gate = None;
    config.ukf_update_options = ukf;

    let nominal = NavState::new(
        epoch,
        [wgs84_a_m, 0.0, 0.0],
        [0.0; 3],
        [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]],
    )
    .expect("nav state")
    .with_biases([0.0; 3], [0.0; 3])
    .expect("biases");
    let mut state = InsFilterState::from_diagonal(nominal, ErrorStateLayout::Fifteen, &[100.0; 15])
        .expect("filter state");
    state.accel_scale_factor = [0.0; 3];
    state.gyro_scale_factor = [0.0; 3];
    let mut filter = InertialFilter::with_config(state, config).expect("filter");

    let observation = TightGnssObservation {
        satellite_id: gps(1),
        pseudorange_m,
        pseudorange_sigma_m: 10.0,
        range_rate: Some(TightRangeRateObservation {
            measured_range_rate_m_s: 0.5,
            sigma_m_s: 2.0,
            satellite_clock_drift_m_s: 0.0,
        }),
        carrier_phase: None,
        ionosphere_delay_m: 0.0,
        troposphere_delay_m: 0.0,
    };
    let tight_epoch = TightGnssEpoch::new(epoch, vec![observation]).expect("tight epoch");
    let update = filter
        .update_tight(&sp3, &tight_epoch)
        .expect("tight update");
    let clock = filter.tight_clock_state().expect("clock state");
    write(
        &goldens_dir(ctx),
        "fusion_tight_sp3.json",
        &json!({
            "source": source(ctx, "fusion InertialFilter::update_tight on an SP3 source"),
            "t_j2000_s": h(epoch),
            "pseudorange_m": h(pseudorange_m),
            "update": {
                "applied": update.applied,
                "rows": update.rows,
                "nis": h(update.nis),
                "dx": hv(&update.ekf.dx),
            },
            "clock": {
                "bias_m": h(clock.bias_m),
                "drift_m_s": h(clock.drift_m_s),
                "covariance": clock.covariance.iter().map(|row| hv(row)).collect::<Vec<_>>(),
            },
        }),
    );
}

const WTZR_MARKER_M: [f64; 3] = [4_075_580.3111, 931_854.0543, 4_801_568.2808];

/// The WTZR to WTZZ static reference-station coordinate, carrier mode only,
/// over the first 24 epochs, with the options the binding test passes.
fn rtk_reference_station(ctx: &Context) {
    let sp3 = load_sp3(ctx, "GBM0MGXRAP_20201770000_01D_05M_ORB_120epoch.sp3");
    let read_obs = |name: &str| {
        let text = std::fs::read_to_string(ctx.fixtures.join("obs").join(name)).expect("read OBS");
        RinexObs::parse(&text).expect("parse OBS")
    };
    let reference_obs = read_obs("WTZR00DEU_R_20201770000_01D_30S_MO_120epoch.rnx");
    let rover_obs = read_obs("WTZZ00DEU_R_20201770000_01D_30S_MO_120epoch.rnx");
    // The WTZR antenna reference point: the marker raised by the header's
    // antenna height along the geocentric up direction (east and north are 0).
    let [height_m, east_m, north_m] = reference_obs
        .header()
        .antenna_delta_hen_m
        .expect("antenna delta");
    assert_eq!((east_m, north_m), (0.0, 0.0));
    let m = WTZR_MARKER_M;
    let norm = (m[0] * m[0] + m[1] * m[1] + m[2] * m[2]).sqrt();
    let reference_position_m = [
        m[0] + m[0] / norm * height_m,
        m[1] + m[1] / norm * height_m,
        m[2] + m[2] / norm * height_m,
    ];

    let mut arc_options = RtkRinexArcOptions::gps_l1_c();
    arc_options.max_epochs = Some(24);
    arc_options.min_common_satellites = 4;
    arc_options.include_prediction_time = false;
    let update_opts = UpdateOpts {
        hold_sigma_m: 1.0e-4,
        position_tol_m: 1.0e-4,
        ambiguity_tol_m: 1.0e-4,
        max_iterations: 10,
        process_noise_baseline_sigma_m: 0.0,
        dynamics_model: DynamicsModel::ConstantPosition,
        float_only_systems: Vec::new(),
        report_residuals: false,
        receiver_antenna_corrections: None,
        ar_arming_sigma_m: None,
        search: SearchOpts {
            ratio_threshold: 3.0,
        },
    };
    let arc = RtkArcConfig::new(
        reference_position_m,
        BaselineReferenceSelection::Auto,
        MeasModel {
            code_sigma_m: 2.0,
            phase_sigma_m: 0.01,
            sagnac: true,
            stochastic: StochasticModel::Simple {
                elevation_weighting: true,
            },
        },
        30.0,
        30.0,
        [0.0; 3],
        BTreeMap::new(),
        BTreeMap::new(),
        update_opts,
        RtkArcPreprocessing {
            cycle_slip: Some(CycleSlipPolicy::SplitArc),
            hatch_window_cap: None,
            elevation_mask_deg: None,
        },
    );
    let opts = ValidatedFixedSolveOpts {
        float: FloatSolveOpts {
            position_tol_m: 1.0e-4,
            ambiguity_tol_m: 1.0e-4,
            max_iterations: 10,
        },
        fixed: FixedSolveOpts {
            position_tol_m: 1.0e-4,
            ambiguity_tol_m: 1.0e-4,
            max_iterations: 10,
            ratio_threshold: 3.0,
            partial_ambiguity_resolution: true,
            partial_min_ambiguities: 4,
        },
        residual: ResidualValidationOpts {
            threshold_sigma: None,
            max_exclusions: 0,
        },
    };
    let carrier =
        StaticReferenceCarrierRinexOptions::new(arc_options, RtkStaticArcConfig::new(arc, opts));
    let options = StaticReferenceStationRinexOptions::new(None, Some(carrier), true);
    let solution = solve_static_reference_station_rinex(
        &sp3,
        &reference_obs,
        &rover_obs,
        reference_position_m,
        &options,
    )
    .expect("reference-station solve");
    let carrier = solution
        .carrier_solution
        .as_ref()
        .expect("carrier solution");
    let report = &solution.mode_reports[0];
    write(
        &goldens_dir(ctx),
        "rtk_reference_station_wtzr_wtzz.json",
        &json!({
            "source": source(ctx, "positioning::solve_static_reference_station_rinex, carrier mode"),
            "reference_position_m": hv(&reference_position_m),
            "mode": format!("{:?}", solution.mode),
            "fix_status": format!("{:?}", solution.fix_status),
            "integer_status": format!("{:?}", carrier.integer_status),
            "integer_ratio": carrier.integer_ratio.map(h),
            "position_m": hv(&solution.position.as_array()),
            "baseline_vector_m": hv(&solution.baseline_vector_m),
            "covariance_position_ecef_m2": hm3(solution.covariance.position_ecef_m2),
            "mode_report": {
                "used_epochs": report.used_epochs,
                "skipped_epochs": report.skipped_epochs,
                "used_measurements": report.used_measurements,
            },
        }),
    );
}

/// Visibility of the first ten readable `celestrak/stations.tle` satellites from London
/// at the first satellite's TLE epoch, AFSPC opsmode, with a -50 degree mask, as
/// the binding's constellation test asks for it.
fn constellation_visibility(ctx: &Context) {
    use sidereon_core::astro::passes::{visible_from_satellites, GroundStation, UtcInstant};
    use sidereon_core::astro::sgp4::{OpsMode, Satellite};
    use sidereon_core::astro::tle;

    let text = std::fs::read_to_string(ctx.fixtures.join("celestrak").join("stations.tle"))
        .expect("read TLEs");
    let lines: Vec<&str> = text
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .collect();
    let mut satellites = Vec::new();
    let mut ids = Vec::new();
    // Every adjacent line-1/line-2 pair that reads, in file order, as the test
    // collects them; the first ten.
    for pair in lines.windows(2) {
        if ids.len() == 10 {
            break;
        }
        if !(pair[0].starts_with("1 ") && pair[1].starts_with("2 ")) {
            continue;
        }
        let Ok(parsed) = tle::parse(pair[0], pair[1]) else {
            continue;
        };
        let elements = parsed.elements.to_element_set().expect("element set");
        satellites.push(
            Satellite::from_elements_with_opsmode(&elements, OpsMode::Afspc).expect("SGP4 init"),
        );
        ids.push(parsed.elements.catalog_number.trim().to_string());
    }
    // The first satellite's epoch, 2026 day 95.55331950: 13:16:46.804800 UTC.
    let instant = UtcInstant::from_utc(2026, 4, 5, 13, 16, 46, 804_800).expect("instant");
    let station = GroundStation {
        latitude_deg: 51.5074,
        longitude_deg: -0.1278,
        altitude_m: 11.0,
    };
    let visible =
        visible_from_satellites(&satellites, &ids, station, instant, -50.0).expect("visibility");
    write(
        &goldens_dir(ctx),
        "constellation_visibility.json",
        &json!({
            "source": source(ctx, "astro::passes::visible_from_satellites, AFSPC opsmode"),
            "instant": "2026-04-05T13:16:46.804800Z",
            "station": {"latitude_deg": 51.5074, "longitude_deg": -0.1278, "altitude_m": 11.0},
            "min_elevation_deg": -50.0,
            "visible": visible.iter().map(|v| json!({
                "catalog_number": v.catalog_number,
                "elevation_deg": h(v.elevation_deg),
                "azimuth_deg": h(v.azimuth_deg),
                "range_km": h(v.range_km),
                "position_km": hv(&v.position_km),
            })).collect::<Vec<_>>(),
        }),
    );
}
