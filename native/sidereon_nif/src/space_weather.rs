//! Rustler boundary for core space-weather tables.
//!
//! Parsing, lookup, policy handling, and formatting stay in `sidereon-core`.
//! This module only moves terms across the BEAM boundary and keeps parsed
//! tables in resource handles.

use std::sync::Arc;

use rustler::{Binary, Encoder, Env, ResourceArc, Term};
use sidereon_core::astro::forces::SpaceWeather;
use sidereon_core::astro::forces::SpaceWeatherSource;
use sidereon_core::astro::propagator::decay::estimate_decay_with_source;
use sidereon_core::astro::space_weather::{
    encode_csv, encode_txt, parse, ObservationClass, SpaceWeatherCoverage, SpaceWeatherError,
    SpaceWeatherPolicy, SpaceWeatherSample, SpaceWeatherTable,
};

use crate::drag::{
    decay_config_from_terms, decode_decay_error, DecayEstimateTerm, DragParametersTerm,
};

pub struct SpaceWeatherTableResource {
    pub table: Arc<SpaceWeatherTable>,
}

#[rustler::resource_impl]
impl rustler::Resource for SpaceWeatherTableResource {}

mod atoms {
    rustler::atoms! {
        ok,
        error,
        observed,
        interpolated,
        daily_predicted,
        monthly_predicted,
        unrecognized_format,
        malformed,
        not_text,
        before_coverage,
        after_coverage,
        missing_data,
        rejected_by_policy,
        invalid_epoch,
    }
}

#[derive(Debug, Clone, rustler::NifMap)]
pub(crate) struct SpaceWeatherTerm {
    f107: f64,
    f107a: f64,
    ap: f64,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct SpaceWeatherSampleTerm {
    space_weather: SpaceWeatherTerm,
    class: rustler::Atom,
    ap_defaulted: bool,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct SpaceWeatherPolicyTerm {
    allow_interpolated: bool,
    allow_daily_predicted: bool,
    allow_monthly_predicted: bool,
    require_geomagnetic: bool,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct SpaceWeatherCoverageTerm {
    first_j2000_s: f64,
    last_observed_j2000_s: Option<f64>,
    last_daily_predicted_j2000_s: Option<f64>,
    end_j2000_s: f64,
}

impl From<SpaceWeather> for SpaceWeatherTerm {
    fn from(space_weather: SpaceWeather) -> Self {
        Self {
            f107: space_weather.f107,
            f107a: space_weather.f107a,
            ap: space_weather.ap,
        }
    }
}

impl From<SpaceWeatherPolicyTerm> for SpaceWeatherPolicy {
    fn from(policy: SpaceWeatherPolicyTerm) -> Self {
        Self {
            allow_interpolated: policy.allow_interpolated,
            allow_daily_predicted: policy.allow_daily_predicted,
            allow_monthly_predicted: policy.allow_monthly_predicted,
            require_geomagnetic: policy.require_geomagnetic,
        }
    }
}

impl From<SpaceWeatherSample> for SpaceWeatherSampleTerm {
    fn from(sample: SpaceWeatherSample) -> Self {
        Self {
            space_weather: sample.space_weather.into(),
            class: class_atom(sample.class),
            ap_defaulted: sample.ap_defaulted,
        }
    }
}

impl From<SpaceWeatherCoverage> for SpaceWeatherCoverageTerm {
    fn from(coverage: SpaceWeatherCoverage) -> Self {
        Self {
            first_j2000_s: coverage.first_j2000_s,
            last_observed_j2000_s: coverage.last_observed_j2000_s,
            last_daily_predicted_j2000_s: coverage.last_daily_predicted_j2000_s,
            end_j2000_s: coverage.end_j2000_s,
        }
    }
}

fn class_atom(class: ObservationClass) -> rustler::Atom {
    match class {
        ObservationClass::Observed => atoms::observed(),
        ObservationClass::Interpolated => atoms::interpolated(),
        ObservationClass::DailyPredicted => atoms::daily_predicted(),
        ObservationClass::MonthlyPredicted => atoms::monthly_predicted(),
    }
}

fn encode_error<'a>(env: Env<'a>, error: SpaceWeatherError) -> Term<'a> {
    match error {
        SpaceWeatherError::UnrecognizedFormat => {
            (atoms::error(), atoms::unrecognized_format()).encode(env)
        }
        SpaceWeatherError::Malformed { line, reason } => {
            (atoms::error(), (atoms::malformed(), line, reason)).encode(env)
        }
        SpaceWeatherError::NotText => (atoms::error(), atoms::not_text()).encode(env),
        SpaceWeatherError::BeforeCoverage {
            requested_j2000_s,
            first_j2000_s,
        } => (
            atoms::error(),
            (atoms::before_coverage(), requested_j2000_s, first_j2000_s),
        )
            .encode(env),
        SpaceWeatherError::AfterCoverage {
            requested_j2000_s,
            end_j2000_s,
        } => (
            atoms::error(),
            (atoms::after_coverage(), requested_j2000_s, end_j2000_s),
        )
            .encode(env),
        SpaceWeatherError::MissingData {
            year,
            month,
            day,
            field,
        } => (
            atoms::error(),
            (
                atoms::missing_data(),
                year,
                i64::from(month),
                i64::from(day),
                field,
            ),
        )
            .encode(env),
        SpaceWeatherError::RejectedByPolicy {
            class,
            year,
            month,
            day,
        } => (
            atoms::error(),
            (
                atoms::rejected_by_policy(),
                class_atom(class),
                year,
                i64::from(month),
                i64::from(day),
            ),
        )
            .encode(env),
        SpaceWeatherError::InvalidEpoch { epoch_j2000_s_bits } => (
            atoms::error(),
            (atoms::invalid_epoch(), f64::from_bits(epoch_j2000_s_bits)),
        )
            .encode(env),
    }
}

fn encode_lookup<'a, T, F>(
    env: Env<'a>,
    result: Result<T, SpaceWeatherError>,
    encode_ok: F,
) -> Term<'a>
where
    F: FnOnce(Env<'a>, T) -> Term<'a>,
{
    match result {
        Ok(value) => (atoms::ok(), encode_ok(env, value)).encode(env),
        Err(error) => encode_error(env, error),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn space_weather_parse<'a>(env: Env<'a>, bytes: Binary<'a>) -> Term<'a> {
    match parse(bytes.as_slice()) {
        Ok(parsed) => {
            let (table, _diagnostics) = parsed.into_parts();
            (
                atoms::ok(),
                ResourceArc::new(SpaceWeatherTableResource {
                    table: Arc::new(table),
                }),
            )
                .encode(env)
        }
        Err(error) => encode_error(env, error),
    }
}

#[rustler::nif]
fn space_weather_space_weather_at<'a>(
    env: Env<'a>,
    handle: ResourceArc<SpaceWeatherTableResource>,
    epoch_j2000_s: f64,
) -> Term<'a> {
    encode_lookup(
        env,
        handle.table.space_weather_at(epoch_j2000_s),
        |env, sw| SpaceWeatherTerm::from(sw).encode(env),
    )
}

#[rustler::nif]
fn space_weather_sample_at<'a>(
    env: Env<'a>,
    handle: ResourceArc<SpaceWeatherTableResource>,
    epoch_j2000_s: f64,
) -> Term<'a> {
    encode_lookup(env, handle.table.sample_at(epoch_j2000_s), |env, sample| {
        SpaceWeatherSampleTerm::from(sample).encode(env)
    })
}

#[rustler::nif]
fn space_weather_sample_at_with_policy<'a>(
    env: Env<'a>,
    handle: ResourceArc<SpaceWeatherTableResource>,
    epoch_j2000_s: f64,
    policy: SpaceWeatherPolicyTerm,
) -> Term<'a> {
    encode_lookup(
        env,
        handle
            .table
            .sample_at_with_policy(epoch_j2000_s, policy.into()),
        |env, sample| SpaceWeatherSampleTerm::from(sample).encode(env),
    )
}

#[rustler::nif]
fn space_weather_ap_array_at<'a>(
    env: Env<'a>,
    handle: ResourceArc<SpaceWeatherTableResource>,
    epoch_j2000_s: f64,
) -> Term<'a> {
    encode_lookup(env, handle.table.ap_array_at(epoch_j2000_s), |env, ap| {
        ap.to_vec().encode(env)
    })
}

#[rustler::nif]
fn space_weather_coverage<'a>(
    env: Env<'a>,
    handle: ResourceArc<SpaceWeatherTableResource>,
) -> Term<'a> {
    (
        atoms::ok(),
        SpaceWeatherCoverageTerm::from(handle.table.coverage()),
    )
        .encode(env)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn space_weather_to_csv_text(handle: ResourceArc<SpaceWeatherTableResource>) -> String {
    encode_csv(&handle.table)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn space_weather_to_txt_text(handle: ResourceArc<SpaceWeatherTableResource>) -> String {
    encode_txt(&handle.table)
}

#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
fn drag_estimate_decay_with_space_weather_table<'a>(
    env: Env<'a>,
    state: crate::drag::CartesianStateTerm,
    params: DragParametersTerm,
    force_model_name: String,
    abs_tol: f64,
    rel_tol: f64,
    reentry_altitude_km: f64,
    scan_step_s: f64,
    crossing_tolerance_s: f64,
    max_duration_s: f64,
    max_scan_samples: u32,
    table: ResourceArc<SpaceWeatherTableResource>,
) -> rustler::NifResult<Term<'a>> {
    let mut config = decay_config_from_terms(
        params,
        force_model_name,
        abs_tol,
        rel_tol,
        reentry_altitude_km,
        scan_step_s,
        crossing_tolerance_s,
        max_duration_s,
        max_scan_samples,
    )?;
    config.mu_km3_s2 = None;
    let source = SpaceWeatherSource::Table(table.table.clone());

    Ok(
        match estimate_decay_with_source(crate::drag::state_from_term(state), &config, &source) {
            Ok(estimate) => (
                atoms::ok(),
                DecayEstimateTerm {
                    time_to_decay_s: estimate.time_to_decay_s,
                    reentry_state: crate::drag::state_to_term(estimate.reentry_state),
                    reentry_altitude_km: estimate.reentry_altitude_km,
                },
            )
                .encode(env),
            Err(error) => decode_decay_error(env, error),
        },
    )
}
