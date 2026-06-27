//! Rustler boundary for the `sidereon-core` compact mean-element model.
//!
//! Pure glue: it decodes Erlang terms, calls the `sidereon_core::orbit`
//! public APIs, and encodes the results back. No fitting, element, or frame math
//! lives here — those belong to the crate. The fitted elements are a small flat
//! value (not a resource handle), so they travel back and forth as plain tuples;
//! the Elixir layer owns persistence (`to_map`/`from_map`).

use rustler::{Encoder, Env, Error, NifResult, Term};
use sidereon_core::astro::time::model::TimeScale;
use sidereon_core::orbit::{
    self as ro, CalendarEpoch, EcefSample, Elements, FitStats, Frame, Model, PiecewiseOrbit,
    PiecewiseOrbitError, PiecewiseSegment, ReducedOrbit, ReducedOrbitError,
};

/// Map a time-scale abbreviation onto the core [`TimeScale`]. The epochs the
/// model carries (samples, t0, queries) are all interpreted in this scale.
fn scale_from_str(s: &str) -> NifResult<TimeScale> {
    Ok(match s {
        "UTC" => TimeScale::Utc,
        "TAI" => TimeScale::Tai,
        "TT" => TimeScale::Tt,
        "TDB" => TimeScale::Tdb,
        "GPST" => TimeScale::Gpst,
        "GST" => TimeScale::Gst,
        "BDT" => TimeScale::Bdt,
        other => {
            return Err(Error::Term(Box::new(format!(
                "unknown time scale {other:?}"
            ))))
        }
    })
}

mod atoms {
    rustler::atoms! {
        ok,
        error,
        too_few_samples,
        invalid_window,
        singular_plane_fit,
        raan_ambiguous,
        fit_did_not_converge,
        invalid_segment,
        out_of_range,
        circular_secular,
        eccentric_secular,
        unsupported_model,
        invalid_input,
    }
}

/// Map a model atom string onto the core [`Model`].
fn model_from_str(s: &str) -> Result<Model, &str> {
    match s {
        "circular_secular" => Ok(Model::CircularSecular),
        "eccentric_secular" => Ok(Model::EccentricSecular),
        _ => Err(s),
    }
}

type DateTuple = (i32, i32, i32);
type TimeTuple = (i32, i32, i32, i32);
type EpochTuple = (DateTuple, TimeTuple);
type Vec3 = (f64, f64, f64);
type StateTuple = (Vec3, Vec3);

/// Decode an Elixir `{{y,m,d},{h,min,s,us}}` datetime tuple into a calendar
/// epoch (microseconds folded into fractional seconds).
fn cal_from_term(term: Term) -> NifResult<CalendarEpoch> {
    let (d, t): (DateTuple, TimeTuple) = term.decode()?;
    let second = t.2 as f64 + t.3 as f64 / 1_000_000.0;
    Ok(CalendarEpoch::new(d.0, d.1, d.2, t.0, t.1, second))
}

/// Decode the stored element floats plus the epoch tuple into [`Elements`].
///
/// The list length selects the model: eight floats is the circular model
/// (`[a_m, e, i, raan, raan_rate, raan_rate_j2, arg_lat, n]`); ten floats is the
/// eccentric model with `h` and `k` appended. The circular layout is unchanged,
/// so circular elements round-trip byte-for-byte.
fn elements_from_parts(epoch: Term, e: &[f64]) -> NifResult<Elements> {
    let (model, h, k, arg_perigee_rad) = match e.len() {
        8 => (Model::CircularSecular, 0.0, 0.0, 0.0),
        10 => {
            let h = e[8];
            let k = e[9];
            let omega = if (h * h + k * k) < 1.0e-24 {
                0.0
            } else {
                h.atan2(k)
            };
            (Model::EccentricSecular, h, k, omega)
        }
        _ => return Err(Error::Term(Box::new("expected 8 or 10 element values"))),
    };
    Ok(Elements {
        model,
        epoch: cal_from_term(epoch)?,
        a_m: e[0],
        e: e[1],
        i_rad: e[2],
        raan_rad: e[3],
        raan_rate_rad_s: e[4],
        raan_rate_j2_rad_s: e[5],
        arg_lat_rad: e[6],
        mean_motion_rad_s: e[7],
        h,
        k,
        arg_perigee_rad,
    })
}

fn frame_from_str(s: &str) -> NifResult<Frame> {
    match s {
        "gcrs" => Ok(Frame::Gcrs),
        "ecef" => Ok(Frame::Ecef),
        other => Err(Error::Term(Box::new(format!("unknown frame {other:?}")))),
    }
}

fn encode_error<'a>(env: Env<'a>, e: &ReducedOrbitError) -> Term<'a> {
    let reason = match e {
        ReducedOrbitError::TooFewSamples { got, required } => {
            (atoms::too_few_samples(), *got as i64, *required as i64).encode(env)
        }
        ReducedOrbitError::InvalidWindow => atoms::invalid_window().encode(env),
        ReducedOrbitError::SingularPlaneFit => atoms::singular_plane_fit().encode(env),
        ReducedOrbitError::RaanAmbiguous => atoms::raan_ambiguous().encode(env),
        // A rank-deficient refinement is surfaced as a non-convergent fit.
        ReducedOrbitError::Singular(_) | ReducedOrbitError::FitDidNotConverge => {
            atoms::fit_did_not_converge().encode(env)
        }
        // A non-finite or out-of-domain evaluation input.
        ReducedOrbitError::InvalidInput { .. } => atoms::invalid_input().encode(env),
    };
    (atoms::error(), reason).encode(env)
}

fn encode_piecewise_error<'a>(env: Env<'a>, e: &PiecewiseOrbitError) -> Term<'a> {
    let reason = match e {
        PiecewiseOrbitError::InvalidSegment => atoms::invalid_segment().encode(env),
        PiecewiseOrbitError::OutOfRange => atoms::out_of_range().encode(env),
        PiecewiseOrbitError::TooFewSamples { got, required } => {
            (atoms::too_few_samples(), *got as i64, *required as i64).encode(env)
        }
        PiecewiseOrbitError::Reduced(e) => match e {
            ReducedOrbitError::TooFewSamples { got, required } => {
                (atoms::too_few_samples(), *got as i64, *required as i64).encode(env)
            }
            ReducedOrbitError::InvalidWindow => atoms::invalid_window().encode(env),
            ReducedOrbitError::SingularPlaneFit => atoms::singular_plane_fit().encode(env),
            ReducedOrbitError::RaanAmbiguous => atoms::raan_ambiguous().encode(env),
            ReducedOrbitError::Singular(_) | ReducedOrbitError::FitDidNotConverge => {
                atoms::fit_did_not_converge().encode(env)
            }
            // A non-finite or out-of-domain evaluation input.
            ReducedOrbitError::InvalidInput { .. } => atoms::invalid_input().encode(env),
        },
    };
    (atoms::error(), reason).encode(env)
}

fn encode_orbit_parts<'a>(
    env: Env<'a>,
    orbit: &ReducedOrbit,
) -> (Term<'a>, EpochTuple, Vec<f64>, (f64, f64, i64)) {
    let e = orbit.elements;
    let (model_atom, elements) = match e.model {
        Model::CircularSecular => (
            atoms::circular_secular().encode(env),
            vec![
                e.a_m,
                e.e,
                e.i_rad,
                e.raan_rad,
                e.raan_rate_rad_s,
                e.raan_rate_j2_rad_s,
                e.arg_lat_rad,
                e.mean_motion_rad_s,
            ],
        ),
        Model::EccentricSecular => (
            atoms::eccentric_secular().encode(env),
            vec![
                e.a_m,
                e.e,
                e.i_rad,
                e.raan_rad,
                e.raan_rate_rad_s,
                e.raan_rate_j2_rad_s,
                e.arg_lat_rad,
                e.mean_motion_rad_s,
                e.h,
                e.k,
            ],
        ),
    };
    let stats = (
        orbit.stats.rms_m,
        orbit.stats.max_m,
        orbit.stats.n_samples as i64,
    );
    (model_atom, epoch_to_tuple(&e.epoch), elements, stats)
}

/// Fit the chosen model (`"circular_secular"` or `"eccentric_secular"`) to ECEF
/// samples.
///
/// `samples` is a list of `{ {{y,m,d},{h,min,s,us}}, x_m, y_m, z_m }`. On
/// success returns `{:ok, model_atom, epoch_tuple, elements, {rms_m, max_m,
/// n_samples}}` where `epoch_tuple` is the fitted reference epoch `t0` (the
/// earliest sample, chosen after ordering) and `elements` is
/// `[a_m, e, i, raan, raan_rate, raan_rate_j2, arg_lat, n]` for the circular
/// model, with `h, k` appended for the eccentric model. On a degenerate input or
/// an unknown model, `{:error, reason}`.
#[rustler::nif(schedule = "DirtyCpu")]
fn reduced_orbit_fit<'a>(
    env: Env<'a>,
    samples: Vec<(Term<'a>, f64, f64, f64)>,
    scale: String,
    model: String,
) -> NifResult<Term<'a>> {
    let scale = scale_from_str(&scale)?;
    let model = match model_from_str(&model) {
        Ok(m) => m,
        Err(bad) => {
            let reason = (atoms::unsupported_model(), bad.to_string()).encode(env);
            return Ok((atoms::error(), reason).encode(env));
        }
    };
    let mut ecef = Vec::with_capacity(samples.len());
    for (epoch, x_m, y_m, z_m) in samples {
        ecef.push(EcefSample::new(cal_from_term(epoch)?, x_m, y_m, z_m));
    }

    match ro::fit_with_model(&ecef, scale, model) {
        Ok(orbit) => {
            let (model_atom, epoch, elements, stats) = encode_orbit_parts(env, &orbit);
            Ok((atoms::ok(), model_atom, epoch, elements, stats).encode(env))
        }
        Err(e) => Ok(encode_error(env, &e)),
    }
}

fn decode_samples<'a>(samples: Vec<(Term<'a>, f64, f64, f64)>) -> NifResult<Vec<EcefSample>> {
    let mut ecef = Vec::with_capacity(samples.len());
    for (epoch, x_m, y_m, z_m) in samples {
        ecef.push(EcefSample::new(cal_from_term(epoch)?, x_m, y_m, z_m));
    }
    Ok(ecef)
}

type PiecewiseSegmentTerm<'a> = (Term<'a>, Term<'a>, Term<'a>, Vec<f64>);

fn piecewise_from_parts<'a>(
    window_start: Term<'a>,
    window_end: Term<'a>,
    segment_s: i64,
    segments: Vec<PiecewiseSegmentTerm<'a>>,
) -> NifResult<PiecewiseOrbit> {
    let mut decoded = Vec::with_capacity(segments.len());
    for (t0, t1, epoch, elements) in segments {
        let elements = elements_from_parts(epoch, &elements)?;
        decoded.push(PiecewiseSegment {
            t0: cal_from_term(t0)?,
            t1: cal_from_term(t1)?,
            orbit: ReducedOrbit {
                elements,
                stats: FitStats {
                    rms_m: 0.0,
                    max_m: 0.0,
                    n_samples: 0,
                },
            },
        });
    }
    let Some(first) = decoded.first() else {
        return Err(Error::Term(Box::new("empty piecewise model")));
    };
    Ok(PiecewiseOrbit {
        model: first.orbit.elements.model,
        t0: cal_from_term(window_start)?,
        t1: cal_from_term(window_end)?,
        segment_s,
        segments: decoded,
    })
}

/// Fit a piecewise reduced-orbit model over normalized ECEF samples.
#[rustler::nif(schedule = "DirtyCpu")]
fn reduced_orbit_piecewise_fit<'a>(
    env: Env<'a>,
    samples: Vec<(Term<'a>, f64, f64, f64)>,
    scale: String,
    model: String,
    window_start: Term<'a>,
    window_end: Term<'a>,
    segment_s: i64,
) -> NifResult<Term<'a>> {
    let scale = scale_from_str(&scale)?;
    let model = match model_from_str(&model) {
        Ok(m) => m,
        Err(bad) => {
            let reason = (atoms::unsupported_model(), bad.to_string()).encode(env);
            return Ok((atoms::error(), reason).encode(env));
        }
    };
    let samples = decode_samples(samples)?;
    let t0 = cal_from_term(window_start)?;
    let t1 = cal_from_term(window_end)?;

    match ro::fit_piecewise(&samples, scale, model, t0, t1, segment_s) {
        Ok(piecewise) => {
            let segments: Vec<_> = piecewise
                .segments
                .iter()
                .map(|seg| {
                    let (model_atom, epoch, elements, stats) = encode_orbit_parts(env, &seg.orbit);
                    (
                        epoch_to_tuple(&seg.t0),
                        epoch_to_tuple(&seg.t1),
                        model_atom,
                        epoch,
                        elements,
                        stats,
                    )
                })
                .collect();
            Ok((
                atoms::ok(),
                epoch_to_tuple(&piecewise.t1),
                piecewise.segment_s,
                segments,
            )
                .encode(env))
        }
        Err(e) => Ok(encode_piecewise_error(env, &e)),
    }
}

/// Encode a [`CalendarEpoch`] as the `{{y,m,d},{h,min,s,us}}` tuple the Elixir
/// layer reads, splitting the fractional second into whole seconds + microseconds.
fn epoch_to_tuple(cal: &CalendarEpoch) -> EpochTuple {
    let whole = cal.second.trunc();
    let micros = ((cal.second - whole) * 1_000_000.0).round() as i32;
    (
        (cal.year, cal.month, cal.day),
        (cal.hour, cal.minute, whole as i32, micros),
    )
}

/// Evaluate the model position at `query` in `frame` (`"ecef"` or `"gcrs"`),
/// meters.
#[rustler::nif]
fn reduced_orbit_position(
    epoch: Term,
    scale: String,
    elements: Vec<f64>,
    query: Term,
    frame: String,
) -> NifResult<Vec3> {
    let e = elements_from_parts(epoch, &elements)?;
    let s = scale_from_str(&scale)?;
    let f = frame_from_str(&frame)?;
    let r = ro::position(&e, cal_from_term(query)?, s, f).map_err(crate::errors::invalid_input)?;
    Ok((r[0], r[1], r[2]))
}

/// Evaluate the model position and velocity at `query` in `frame`. Returns
/// `({x,y,z}_m, {vx,vy,vz}_m_s)`.
#[rustler::nif]
fn reduced_orbit_position_velocity(
    epoch: Term,
    scale: String,
    elements: Vec<f64>,
    query: Term,
    frame: String,
) -> NifResult<StateTuple> {
    let e = elements_from_parts(epoch, &elements)?;
    let s = scale_from_str(&scale)?;
    let f = frame_from_str(&frame)?;
    let (r, v) = ro::position_velocity(&e, cal_from_term(query)?, s, f)
        .map_err(crate::errors::invalid_input)?;
    Ok(((r[0], r[1], r[2]), (v[0], v[1], v[2])))
}

/// Evaluate a piecewise model position at `query`.
#[rustler::nif]
fn reduced_orbit_piecewise_position<'a>(
    env: Env<'a>,
    window_start: Term<'a>,
    window_end: Term<'a>,
    segment_s: i64,
    segments: Vec<PiecewiseSegmentTerm<'a>>,
    scale: String,
    query: Term<'a>,
    frame: String,
) -> NifResult<Term<'a>> {
    let piecewise = piecewise_from_parts(window_start, window_end, segment_s, segments)?;
    let s = scale_from_str(&scale)?;
    let f = frame_from_str(&frame)?;
    match ro::piecewise_position(&piecewise, cal_from_term(query)?, s, f) {
        Ok(r) => Ok((atoms::ok(), (r[0], r[1], r[2])).encode(env)),
        Err(e) => Ok(encode_piecewise_error(env, &e)),
    }
}

/// Select the piecewise segment index covering `query`.
#[rustler::nif]
fn reduced_orbit_piecewise_select_segment<'a>(
    env: Env<'a>,
    window_start: Term<'a>,
    window_end: Term<'a>,
    segment_s: i64,
    segments: Vec<PiecewiseSegmentTerm<'a>>,
    query: Term<'a>,
) -> NifResult<Term<'a>> {
    let piecewise = piecewise_from_parts(window_start, window_end, segment_s, segments)?;
    match ro::select_piecewise_segment(&piecewise, cal_from_term(query)?) {
        Ok(selected) => {
            let index = piecewise
                .segments
                .iter()
                .position(|candidate| core::ptr::eq(candidate, selected))
                .unwrap_or(0);
            Ok((atoms::ok(), index as i64).encode(env))
        }
        Err(e) => Ok(encode_piecewise_error(env, &e)),
    }
}

/// Evaluate a piecewise model position and velocity at `query`.
#[rustler::nif]
fn reduced_orbit_piecewise_position_velocity<'a>(
    env: Env<'a>,
    window_start: Term<'a>,
    window_end: Term<'a>,
    segment_s: i64,
    segments: Vec<PiecewiseSegmentTerm<'a>>,
    scale: String,
    query: Term<'a>,
    frame: String,
) -> NifResult<Term<'a>> {
    let piecewise = piecewise_from_parts(window_start, window_end, segment_s, segments)?;
    let s = scale_from_str(&scale)?;
    let f = frame_from_str(&frame)?;
    match ro::piecewise_position_velocity(&piecewise, cal_from_term(query)?, s, f) {
        Ok((r, v)) => Ok((atoms::ok(), ((r[0], r[1], r[2]), (v[0], v[1], v[2]))).encode(env)),
        Err(e) => Ok(encode_piecewise_error(env, &e)),
    }
}

/// Evaluate the model against truth ECEF samples. `truth` is a list of
/// `{ epoch_tuple, x_m, y_m, z_m }`. Returns
/// `{errors_m :: [float], max_m, rms_m, threshold_index :: integer}` where the
/// index is the first sample whose error exceeds `threshold_m`, or `-1` if none.
#[rustler::nif(schedule = "DirtyCpu")]
fn reduced_orbit_drift<'a>(
    env: Env<'a>,
    epoch: Term<'a>,
    scale: String,
    elements: Vec<f64>,
    truth: Vec<(Term<'a>, f64, f64, f64)>,
    threshold_m: f64,
) -> NifResult<Term<'a>> {
    let e = elements_from_parts(epoch, &elements)?;
    let s = scale_from_str(&scale)?;
    let mut samples = Vec::with_capacity(truth.len());
    for (ep, x_m, y_m, z_m) in truth {
        samples.push(EcefSample::new(cal_from_term(ep)?, x_m, y_m, z_m));
    }

    match ro::drift(&e, &samples, s, threshold_m) {
        Ok(report) => {
            let errors: Vec<f64> = report.per_epoch.iter().map(|d| d.error_m).collect();
            let idx: i64 = report
                .per_epoch
                .iter()
                .position(|d| d.error_m > threshold_m)
                .map(|i| i as i64)
                .unwrap_or(-1);

            Ok((errors, report.max_m, report.rms_m, idx).encode(env))
        }
        Err(e) => Ok(encode_error(env, &e)),
    }
}

/// Evaluate a piecewise model against truth ECEF samples.
#[rustler::nif(schedule = "DirtyCpu")]
fn reduced_orbit_piecewise_drift<'a>(
    env: Env<'a>,
    window_start: Term<'a>,
    window_end: Term<'a>,
    segment_s: i64,
    segments: Vec<PiecewiseSegmentTerm<'a>>,
    scale: String,
    truth: Vec<(Term<'a>, f64, f64, f64)>,
    threshold_m: f64,
) -> NifResult<Term<'a>> {
    let piecewise = piecewise_from_parts(window_start, window_end, segment_s, segments)?;
    let s = scale_from_str(&scale)?;
    let samples = decode_samples(truth)?;

    match ro::piecewise_drift(&piecewise, &samples, s, threshold_m) {
        Ok(report) => {
            let per_epoch: Vec<_> = report
                .per_epoch
                .iter()
                .map(|d| (epoch_to_tuple(&d.epoch), d.error_m))
                .collect();
            let idx: i64 = report
                .per_epoch
                .iter()
                .position(|d| d.error_m > threshold_m)
                .map(|i| i as i64)
                .unwrap_or(-1);
            Ok((atoms::ok(), per_epoch, report.max_m, report.rms_m, idx).encode(env))
        }
        Err(e) => Ok(encode_piecewise_error(env, &e)),
    }
}
