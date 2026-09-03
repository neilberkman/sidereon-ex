//! Rustler boundary for sidereal repeat-period filtering.

use rustler::{Encoder, Env, Error, NifResult, ResourceArc, Term};
use sidereon_core::astro::time::Duration;
use sidereon_core::sidereal::{
    orbit_repeat_lag, periodicity_strength_with_sample_interval, repeat_period, sidereal_filter,
    SiderealFilterError, SiderealFilterOptions, SiderealFilterOutput, SiderealTemplateMethod,
};
use sidereon_core::GnssSatelliteId;

use crate::broadcast::BroadcastResource;
use crate::sp3::system_from_letter;

mod atoms {
    rustler::atoms! {
        ok,
        error,
        invalid_input,
        no_broadcast_record,
        unsupported_constellation
    }
}

#[derive(Debug, Clone, rustler::NifMap)]
struct SiderealFilterOutputTerm {
    filtered: Vec<f64>,
    template: Vec<Option<f64>>,
    coverage: Vec<i64>,
    under_covered: Vec<bool>,
}

type OptionsTerm = (f64, i64, i64, String, f64);

fn duration(seconds: f64) -> NifResult<Duration> {
    Duration::from_seconds(seconds).map_err(crate::errors::invalid_input)
}

fn method(kind: &str, alpha: f64) -> NifResult<SiderealTemplateMethod> {
    match kind {
        "mean" => Ok(SiderealTemplateMethod::Mean),
        "robust_mad" => Ok(SiderealTemplateMethod::RobustMad),
        "ewma" => Ok(SiderealTemplateMethod::Ewma { alpha }),
        _ => Err(Error::Term(Box::new("unknown sidereal template method"))),
    }
}

fn options(
    (sample_interval_s, prior_periods, min_coverage, method_kind, alpha): OptionsTerm,
) -> NifResult<SiderealFilterOptions> {
    if prior_periods < 0 || min_coverage < 0 {
        return Err(Error::Term(Box::new("coverage counts must be nonnegative")));
    }
    let mut options = SiderealFilterOptions::default();
    options.sample_interval = duration(sample_interval_s)?;
    options.prior_periods = prior_periods as usize;
    options.min_coverage = min_coverage as usize;
    options.template_method = method(&method_kind, alpha)?;
    Ok(options)
}

fn output_term(output: SiderealFilterOutput) -> SiderealFilterOutputTerm {
    SiderealFilterOutputTerm {
        filtered: output.filtered,
        template: output
            .template
            .into_iter()
            .map(|value| if value.is_nan() { None } else { Some(value) })
            .collect(),
        coverage: output
            .coverage
            .into_iter()
            .map(|value| value as i64)
            .collect(),
        under_covered: output.under_covered,
    }
}

fn error_atom(error: SiderealFilterError) -> rustler::Atom {
    match error {
        SiderealFilterError::InvalidInput { .. } => atoms::invalid_input(),
        SiderealFilterError::NoBroadcastRecord { .. } => atoms::no_broadcast_record(),
        SiderealFilterError::UnsupportedConstellation { .. } => atoms::unsupported_constellation(),
    }
}

/// Return a constellation default repeat period in seconds.
#[rustler::nif]
fn sidereal_repeat_period(system_letter: String) -> NifResult<f64> {
    Ok(repeat_period(system_from_letter(&system_letter)?).as_seconds())
}

/// Return a broadcast-derived per-satellite repeat lag in seconds.
#[rustler::nif]
fn sidereal_orbit_repeat_lag<'a>(
    env: Env<'a>,
    handle: ResourceArc<BroadcastResource>,
    system_letter: String,
    prn: u8,
    near_epoch_j2000_s: f64,
) -> NifResult<Term<'a>> {
    let system = system_from_letter(&system_letter)?;
    let sat = GnssSatelliteId::new(system, prn).map_err(crate::errors::invalid_input)?;
    Ok(
        match orbit_repeat_lag(&handle.store, sat, near_epoch_j2000_s) {
            Ok(period) => (atoms::ok(), period.as_seconds()).encode(env),
            Err(error) => (atoms::error(), error_atom(error)).encode(env),
        },
    )
}

/// Filter a residual series against a supplied sidereal period.
#[rustler::nif(schedule = "DirtyCpu")]
fn sidereal_filter_series<'a>(
    env: Env<'a>,
    series: Vec<f64>,
    period_s: f64,
    opts: OptionsTerm,
) -> NifResult<Term<'a>> {
    Ok(
        match sidereal_filter(&series, duration(period_s)?, options(opts)?) {
            Ok(output) => (atoms::ok(), output_term(output)).encode(env),
            Err(error) => (atoms::error(), error_atom(error)).encode(env),
        },
    )
}

/// Score repeating components at candidate periods.
#[rustler::nif(schedule = "DirtyCpu")]
fn sidereal_periodicity_strength<'a>(
    env: Env<'a>,
    series: Vec<f64>,
    candidate_periods_s: Vec<f64>,
    sample_interval_s: f64,
) -> NifResult<Term<'a>> {
    let periods = candidate_periods_s
        .into_iter()
        .map(duration)
        .collect::<NifResult<Vec<_>>>()?;
    Ok(
        match periodicity_strength_with_sample_interval(
            &series,
            &periods,
            duration(sample_interval_s)?,
        ) {
            Ok(scores) => {
                let rows: Vec<(f64, f64)> = scores
                    .into_iter()
                    .map(|(period, strength)| (period.as_seconds(), strength))
                    .collect();
                (atoms::ok(), rows).encode(env)
            }
            Err(error) => (atoms::error(), error_atom(error)).encode(env),
        },
    )
}
