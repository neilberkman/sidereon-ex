//! Rustler boundary for the `sidereon-core` ionospheric delay models.
//!
//! This module is **pure glue**: it decodes Erlang terms, calls the
//! `sidereon_core::atmosphere::ionosphere` public APIs, manages the parsed IONEX product and
//! the standalone regular TEC grid as Rustler resource handles, and encodes the
//! results back. No Klobuchar polynomial, no single-layer-model geometry, and no
//! grid interpolation lives here; those are the crate's responsibility.
//!
//! - `klobuchar_delay/8` evaluates the GPS broadcast Klobuchar L1 model scaled
//!   to the requested carrier, taking degrees and the GPS second-of-day at the
//!   boundary.
//! - `ionex_parse/1` and `ionex_parse_with_warnings/1` decode a byte buffer,
//!   call [`Ionex::parse`] / [`Ionex::parse_with_warnings`], and return a
//!   [`ResourceArc`] wrapping the parsed grid; the bytes are parsed once.
//! - `ionex_slant/7`, `ionex_slant_with_policy/8` and `ionex_slant_batch/3`
//!   operate on that handle plus an integer J2000-second epoch; they never touch
//!   the filesystem.
//! - `ionex_skipped_records/1` reports what a forgiving parse passed over, which
//!   the warning list does not carry.
//! - `tec_grid_new/4` and the `tec_grid_*` entries wrap the standalone
//!   [`TecGrid`], whose epoch axis is floating Unix nanoseconds and whose values
//!   are flat `[epoch][latitude][longitude]`.
//! - `tec_grid_tec_xyz_prepare/5`, `tec_grid_iono_delay_xyz_prepare/6` and
//!   their `_resume/2` steps run the core's staged XYZ evaluations,
//!   [`TecGridXyzConversion`] and [`TecGridDelayXyzConversion`]. Each step
//!   returns the ECEF position the core asks to have converted, and the Elixir
//!   caller converts it and resumes; no native code calls back into Elixir.
//!
//! Angles cross this boundary in degrees. A conversion to radians happens only
//! where the called core signature takes radians, immediately before the call.
//!
//! Several core types are `#[non_exhaustive]`. They are built through the
//! crate's public constructors and builder methods, and every match over one
//! carries an `unhandled` arm that reports the variant's own `Display` text
//! rather than standing in another variant's name for it.

use std::sync::{Mutex, PoisonError};

use rustler::{Decoder, Encoder, Env, Error, NifResult, ResourceArc, Term};
use sidereon_core::astro::time::model::{
    Instant, InstantRepr, JulianDateSplit, TimeModelError, TimeScale,
};
use sidereon_core::atmosphere::ionosphere::{
    ionex_slant_delay_results, ionex_slant_delay_with_policy, ionosphere_delay, klobuchar_native,
    nequick_g_delay_m as core_nequick_g_delay_m, nequick_g_stec_tecu as core_nequick_g_stec_tecu,
    GalileoNequickCoeffs, Ionex, IonexAssumedMapping, IonexCoverageError, IonexCoveragePolicy,
    IonexHeader, IonexMappingDeclaration, IonexMappingFunction, IonexMappingPolicy,
    IonexMissingNodePolicy, IonexMissingNodes, IonexNodeGap, IonexSlantDelayEvaluation,
    IonexSlantPolicy, IonexSlantRefusal, IonexSlantRequest, IonexWarning, IonoModel,
    KlobucharParams, NequickGRayEval, TecGrid, TecGridDelayXyzConversion, TecGridDelayXyzStep,
    TecGridEpoch, TecGridError, TecGridEvalOptions, TecGridEvaluation, TecGridSamples,
    TecGridXyzConversion, TecGridXyzStep, TecSample, TecSamplesError,
};
use sidereon_core::combinations::{self, IonosphereFreeError, PseudorangeDropReason};
use sidereon_core::frequencies::{self, CarrierBand};
use sidereon_core::{Error as CoreError, FrameValueError, GnssSystem, Wgs84Geodetic};

mod atoms {
    rustler::atoms! {
        ok,
        error,
        equal_frequencies,
        invalid_frequency,
        invalid_observation,
        unknown_system,
        unknown_band,
        missing_band1,
        missing_band2,
        duplicate_observation,
        empty,
        too_few_nodes,
        non_monotonic_lat,
        non_monotonic_lon,
        non_monotonic_epochs,
        epoch_not_representable,
        grid_mismatch,
        rms_count_mismatch,
        height_count_mismatch,
        non_finite_value,
        non_positive_step,
        axis_out_of_range,

        // Epoch representations
        julian_date,
        nanos,

        // Slant policies
        strict,
        hold,
        renormalize,
        single_layer,
        declared,

        // Coverage errors
        epoch_before_first_map,
        epoch_after_last_map,
        latitude_out_of_range,
        longitude_out_of_range,

        // Mapping codes / declarations
        none,
        cosz,
        qfac,
        absent,

        // Assumed mapping
        no_mapping,
        q_factor,
        other,

        // Slant refusals
        varying_heights,
        height_not_available,
        mapping_function,

        // Warnings
        missing_record,
        version_record_not_first,
        epoch_mismatch,
        map_count_mismatch,
        not_a_number_value,
        interval_mismatch,
        exponent_carried_into_map,

        // Warning kinds
        tec,
        rms,
        height,

        // TecGrid errors
        axes_too_short,
        axes_not_increasing,
        dimensions_overflow,
        value_count_mismatch,
        invalid_field,
        nodes_not_available,
        out_of_bounds,

        // Staged TecGrid XYZ evaluation
        convert,
        complete,
        nonfinite,
        conversion_consumed,
        invalid_transport,

        out_of_coverage,
        invalid_input,

        // A variant this binding was built before the core declared.
        unhandled
    }
}

/// A scale-tagged instant at the boundary, in whichever representation the core
/// holds it in.
///
/// [`Instant`] carries either a split Julian date or exact integer nanoseconds,
/// and the two are not interchangeable without loss, so the term names which one
/// it carries: `{:julian_date, scale, jd_whole, jd_fraction}` or
/// `{:nanos, scale, nanos}`. Nothing here converts between them or rounds, in
/// either direction. The IONEX parser builds its map epochs as split Julian
/// dates; the sample constructors accept both, and an instant built from
/// nanoseconds comes back out as nanoseconds.
///
/// The nanosecond count is nanoseconds since **J2000** (JD 2451545.0 in the
/// instant's own scale), which is the origin the IONEX code reads it against:
/// `exact_j2000_second` divides the count by 1e9 and uses the result as the
/// J2000 second. It is not a Unix count. The standalone [`TecGrid`] is the other
/// convention - its axis and its `unix_nanos` query argument are Unix - and
/// neither origin is converted into the other here.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct EpochTerm(pub Instant);

impl Encoder for EpochTerm {
    fn encode<'a>(&self, env: Env<'a>) -> Term<'a> {
        let scale = self.0.scale.abbrev();
        match self.0.repr {
            InstantRepr::JulianDate(split) => {
                (atoms::julian_date(), scale, split.jd_whole, split.fraction).encode(env)
            }
            InstantRepr::Nanos(nanos) => (atoms::nanos(), scale, nanos).encode(env),
        }
    }
}

impl<'a> Decoder<'a> for EpochTerm {
    fn decode(term: Term<'a>) -> NifResult<Self> {
        if let Ok((tag, scale, jd_whole, fraction)) =
            term.decode::<(rustler::Atom, String, f64, f64)>()
        {
            if tag == atoms::julian_date() {
                let scale = crate::sp3::time_scale_from_abbrev(&scale)?;
                // `TimeModelError::InvalidInput` names the rejected part and
                // why; both are carried through rather than flattened into one
                // message that names neither.
                let split = JulianDateSplit::new(jd_whole, fraction).map_err(|err| {
                    let TimeModelError::InvalidInput { field, reason } = err;
                    Error::Term(Box::new((atoms::invalid_field(), field, reason)))
                })?;
                return Ok(Self(Instant::from_julian_date(scale, split)));
            }
        }
        if let Ok((tag, scale, nanos)) = term.decode::<(rustler::Atom, String, i128)>() {
            if tag == atoms::nanos() {
                let scale = crate::sp3::time_scale_from_abbrev(&scale)?;
                return Ok(Self(Instant::from_nanos(scale, nanos)));
            }
        }
        Err(Error::Term(Box::new(
            "epoch must be {:julian_date, scale, jd_whole, jd_fraction} or \
             {:nanos, scale, nanos}",
        )))
    }
}

#[derive(Debug, Clone, rustler::NifMap)]
pub struct IonexHeaderTerm<'a> {
    pub version: f64,
    pub satellite_system: String,
    pub program: String,
    pub run_by: String,
    pub date: String,
    pub descriptions: Vec<String>,
    pub comments: Vec<String>,
    pub interval_s: u32,
    /// The `MAPPING FUNCTION` code: `nil` where the product declares none,
    /// `:none`, `:cosz` or `:qfac` for the codes the spec names, and the code's
    /// own text for any other. A blank declared code is the string `""`, which
    /// is a declaration of a blank code and not the same as `nil`.
    pub mapping_function: Option<Term<'a>>,
    pub elevation_cutoff_deg: f64,
    pub observables_used: String,
    pub station_count: Option<u32>,
    pub satellite_count: Option<u32>,
    pub maps_in_file: Option<u32>,
}

#[derive(Debug, Clone, rustler::NifMap)]
pub struct TecSampleTerm {
    pub epoch: EpochTerm,
    pub lat_deg: f64,
    pub lon_deg: f64,
    pub vtec_tecu: Option<f64>,
    pub rms_tecu: Option<f64>,
    pub height_offset_km: Option<f64>,
}

#[derive(Debug, Clone, rustler::NifMap)]
pub struct TecGridSamplesTerm<'a> {
    pub map_epochs: Vec<EpochTerm>,
    pub lat_nodes_deg: Vec<f64>,
    pub lon_nodes_deg: Vec<f64>,
    pub dlat_deg: f64,
    pub dlon_deg: f64,
    pub shell_height_km: f64,
    pub base_radius_km: f64,
    pub exponent: i64,
    pub tec_maps: Vec<Vec<Vec<Option<f64>>>>,
    /// `nil` where the product carries no RMS maps at all, which is not the same
    /// as maps present with every node non-available.
    pub rms_maps: Option<Vec<Vec<Vec<Option<f64>>>>>,
    /// `nil` where the product carries no height maps at all.
    pub height_maps: Option<Vec<Vec<Vec<Option<f64>>>>>,
    pub header: IonexHeaderTerm<'a>,
}

#[derive(Debug, Clone, rustler::NifMap)]
pub struct SlantPolicyTerm {
    pub coverage: rustler::Atom,
    pub missing_nodes: rustler::Atom,
    pub mapping: rustler::Atom,
}

#[derive(Debug, Clone, rustler::NifMap)]
pub struct SlantRequestTerm {
    pub lat_deg: f64,
    pub lon_deg: f64,
    pub elevation_deg: f64,
    pub azimuth_deg: f64,
    pub epoch_j2000_s: i64,
    pub frequency_hz: f64,
}

#[derive(Debug, Clone, rustler::NifMap)]
pub struct MissingNodesTerm {
    pub map_number: usize,
    pub lat_index: usize,
    pub lon_index: usize,
    pub lon_index_next: usize,
    pub missing: Vec<bool>,
}

#[derive(Debug, Clone, rustler::NifMap)]
pub struct NodeGapTerm {
    pub earlier: Option<MissingNodesTerm>,
    pub later: Option<MissingNodesTerm>,
}

#[derive(Debug, Clone, rustler::NifMap)]
pub struct SlantStatusTerm<'a> {
    /// The coverage miss a `:hold` coverage policy held the value through.
    pub held: Option<rustler::Atom>,
    /// Every non-available node a `:renormalize` missing-node policy
    /// interpolated around, on each bracketing map that has any.
    pub degraded: Option<NodeGapTerm>,
    /// What the product declares, where the single-layer factor mapped a
    /// product declaring anything but `COSZ`: `:no_mapping`, `:q_factor`,
    /// `:absent`, or `{:other, code}` carrying the declared code's own text.
    pub assumed_mapping: Option<Term<'a>>,
    /// Whether the value was neither held through a coverage miss nor degraded
    /// by a non-available node. An assumed mapping does not clear this, matching
    /// `IonexSlantDelayStatus::is_valid`.
    pub valid: bool,
}

#[derive(Debug, Clone, rustler::NifMap)]
pub struct SlantEvaluationTerm<'a> {
    pub delay_m: f64,
    pub status: SlantStatusTerm<'a>,
}

#[derive(Debug, Clone, rustler::NifMap)]
pub struct HeightNodeRefusalTerm {
    pub map_number: usize,
    pub lat_index: usize,
    pub lon_index: usize,
}

#[derive(Debug, Clone, rustler::NifMap)]
pub struct WarningTerm<'a> {
    pub tag: rustler::Atom,
    pub label: Option<String>,
    pub line: Option<usize>,
    pub declared_epoch: Option<EpochTerm>,
    pub maps_epoch: Option<EpochTerm>,
    pub declared_count: Option<u64>,
    pub tec_maps: Option<usize>,
    pub all_maps: Option<usize>,
    /// `:tec`, `:rms` or `:height` for the band names the core uses, and the
    /// core's own string for any other, which is never restated as one of them.
    pub kind: Option<Term<'a>>,
    pub map_number: Option<usize>,
    pub lat_deg: Option<f64>,
    pub lon_deg: Option<f64>,
    pub declared_s: Option<u32>,
    pub spacing_s: Option<i64>,
    pub exponent: Option<i32>,
    pub set_by_line: Option<usize>,
    pub message: String,
}

#[derive(Debug, Clone, rustler::NifMap)]
pub struct TecGridEvaluationTerm {
    pub value: f64,
    pub degraded: Option<NodeGapTerm>,
}

/// A finished XYZ TEC evaluation: `value` is `{vtec_tecu, stec_tecu}`.
#[derive(Debug, Clone, rustler::NifMap)]
pub struct TecGridTecEvaluationTerm {
    pub value: (f64, f64),
    pub degraded: Option<NodeGapTerm>,
}

/// The options an XYZ evaluation states beside its epoch, carrier and
/// positions.
///
/// Each double is a transported double (a float, or `{:nonfinite, bits}`), or
/// `nil` where the caller leaves the value [`TecGridEvalOptions::new`] gives it.
#[derive(Debug, Clone, rustler::NifMap)]
pub struct TecGridXyzOptionsTerm<'a> {
    pub min_elevation_rad: Term<'a>,
    pub nan_pierce_point_height_m: Term<'a>,
    pub earth_radius_m: Term<'a>,
    pub shell_height_m: Term<'a>,
    pub missing_nodes: rustler::Atom,
}

/// Resource handle holding a parsed IONEX product across NIF calls.
pub struct IonexResource {
    pub ionex: Ionex,
}

#[rustler::resource_impl]
impl rustler::Resource for IonexResource {}

/// Resource handle holding a standalone regular TEC grid across NIF calls.
pub struct TecGridResource {
    pub grid: TecGrid,
}

#[rustler::resource_impl]
impl rustler::Resource for TecGridResource {}

/// A standalone-grid vertical and slant TEC evaluation waiting for one ECEF to
/// geodetic conversion.
///
/// `grid` is the handle the evaluation was prepared on, cloned from the
/// caller's. Every step reads that one grid, no resume takes a grid argument
/// that could replace it, and the grid stays alive for as long as a step
/// refers to it, whatever becomes of the caller's own reference.
///
/// `conversion` is taken out by the one resume that answers it; a step the
/// evaluation continues with is a new resource. The lock is held only for that
/// take, never across the core step or a return to Elixir, so a converter that
/// re-enters this boundary never finds it held. A second resume of the same
/// resource finds the slot empty and is refused as `:conversion_consumed`.
pub struct TecGridTecXyzStage {
    grid: ResourceArc<TecGridResource>,
    conversion: Mutex<Option<TecGridXyzConversion>>,
}

#[rustler::resource_impl]
impl rustler::Resource for TecGridTecXyzStage {}

/// The group-delay counterpart of [`TecGridTecXyzStage`], with the same grid
/// ownership and the same single answer per resource.
pub struct TecGridDelayXyzStage {
    grid: ResourceArc<TecGridResource>,
    conversion: Mutex<Option<TecGridDelayXyzConversion>>,
}

#[rustler::resource_impl]
impl rustler::Resource for TecGridDelayXyzStage {}

/// Takes the conversion out of its slot, leaving the slot empty.
///
/// The guard is a temporary of this one expression, so the lock is released
/// before the conversion is resumed. The only work done under the lock is
/// `Option::take`, which cannot panic, so nothing here poisons it; a poisoned
/// slot would still hold a whole conversion or none, and is read as it stands.
fn take_conversion<C>(slot: &Mutex<Option<C>>) -> Option<C> {
    slot.lock().unwrap_or_else(PoisonError::into_inner).take()
}

/// A double crossing this boundary where it may be NaN or infinite.
///
/// `enif_make_double` refuses a double that is not finite, and an Erlang float
/// is always finite, so a finite value crosses as a float and any other as
/// `{:nonfinite, bits}`, `bits` being its IEEE 754 binary64 pattern as an
/// unsigned 64-bit integer. The pattern keeps the sign and the NaN payload, and
/// [`decode_transport`] reads it back to the same double with
/// `f64::from_bits`. The tag only carries the bits: a NaN read here reaches the
/// core as that NaN, and the core's own checks apply to it.
#[derive(Debug, Clone, Copy)]
struct TransportF64(f64);

impl Encoder for TransportF64 {
    fn encode<'a>(&self, env: Env<'a>) -> Term<'a> {
        if self.0.is_finite() {
            self.0.encode(env)
        } else {
            (atoms::nonfinite(), self.0.to_bits()).encode(env)
        }
    }
}

fn transport_xyz([x, y, z]: [f64; 3]) -> (TransportF64, TransportF64, TransportF64) {
    (TransportF64(x), TransportF64(y), TransportF64(z))
}

/// `{:invalid_transport, field}`, returned as `{:error, _}` for a value that is
/// not a transported double.
fn invalid_transport(field: &'static str) -> Error {
    Error::Term(Box::new((atoms::invalid_transport(), field)))
}

/// Reads one transported double, refusing anything else under `field`.
///
/// A float is read as itself. `{:nonfinite, bits}` is read with
/// `f64::from_bits` only where the bits are a NaN or an infinity, because a
/// finite value crosses as a float. An integer is not read here; the Elixir
/// side reads every integer onto its double before the call and names one no
/// double holds.
fn decode_transport(term: Term<'_>, field: &'static str) -> NifResult<f64> {
    if term.is_float() {
        return term.decode::<f64>();
    }
    if let Ok((tag, bits)) = term.decode::<(rustler::Atom, u64)>() {
        let value = f64::from_bits(bits);
        if tag == atoms::nonfinite() && !value.is_finite() {
            return Ok(value);
        }
    }
    Err(invalid_transport(field))
}

/// Reads an `{x, y, z}` of transported doubles, refusing it under `field`.
fn decode_transport_xyz<'a>(term: Term<'a>, field: &'static str) -> NifResult<[f64; 3]> {
    let (x, y, z) = term
        .decode::<(Term<'a>, Term<'a>, Term<'a>)>()
        .map_err(|_| invalid_transport(field))?;
    Ok([
        decode_transport(x, field)?,
        decode_transport(y, field)?,
        decode_transport(z, field)?,
    ])
}

/// Reads a converter answer, `{lon_deg, lat_deg, alt}` of transported doubles.
fn decode_conversion<'a>(term: Term<'a>) -> NifResult<[f64; 3]> {
    let (lon, lat, alt) = term
        .decode::<(Term<'a>, Term<'a>, Term<'a>)>()
        .map_err(|_| invalid_transport("lonlatalt"))?;
    Ok([
        decode_transport(lon, "lon_deg")?,
        decode_transport(lat, "lat_deg")?,
        decode_transport(alt, "alt")?,
    ])
}

/// A transported double, or `None` for `nil`.
fn decode_optional_transport(term: Term<'_>, field: &'static str) -> NifResult<Option<f64>> {
    if term == rustler::types::atom::nil().to_term(term.get_env()) {
        Ok(None)
    } else {
        decode_transport(term, field).map(Some)
    }
}

/// Applies the options a caller stated over `options`, which holds the core
/// defaults, and reads the missing-node policy.
///
/// Each option sets its own field and nothing else. In particular a shell
/// height does not also set `nan_pierce_point_height_m`, as
/// `TecGridEvalOptions::with_shell_geometry` would; the caller states that one
/// separately.
fn apply_xyz_options(
    mut options: TecGridEvalOptions,
    term: &TecGridXyzOptionsTerm<'_>,
) -> NifResult<(TecGridEvalOptions, IonexMissingNodePolicy)> {
    if let Some(value) = decode_optional_transport(term.min_elevation_rad, "min_elevation_rad")? {
        options.min_elevation_rad = value;
    }
    if let Some(value) =
        decode_optional_transport(term.nan_pierce_point_height_m, "nan_pierce_point_height_m")?
    {
        options.nan_pierce_point_height_m = value;
    }
    if let Some(value) = decode_optional_transport(term.earth_radius_m, "earth_radius_m")? {
        options.shell_geometry.earth_radius_m = value;
    }
    if let Some(value) = decode_optional_transport(term.shell_height_m, "shell_height_m")? {
        options.shell_geometry.shell_height_m = value;
    }
    Ok((options, decode_missing_node_policy(term.missing_nodes)?))
}

/// `{:convert, stage, xyz}`: the ECEF position `conversion` asks to have
/// converted, and the stage that takes the answer.
fn tec_xyz_request<'a>(
    env: Env<'a>,
    grid: ResourceArc<TecGridResource>,
    conversion: TecGridXyzConversion,
) -> Term<'a> {
    let xyz = transport_xyz(conversion.xyz());
    let stage = ResourceArc::new(TecGridTecXyzStage {
        grid,
        conversion: Mutex::new(Some(conversion)),
    });
    (atoms::convert(), stage, xyz).encode(env)
}

/// The group-delay counterpart of [`tec_xyz_request`].
fn delay_xyz_request<'a>(
    env: Env<'a>,
    grid: ResourceArc<TecGridResource>,
    conversion: TecGridDelayXyzConversion,
) -> Term<'a> {
    let xyz = transport_xyz(conversion.xyz());
    let stage = ResourceArc::new(TecGridDelayXyzStage {
        grid,
        conversion: Mutex::new(Some(conversion)),
    });
    (atoms::convert(), stage, xyz).encode(env)
}

fn tec_evaluation_to_term(evaluation: TecGridEvaluation<(f64, f64)>) -> TecGridTecEvaluationTerm {
    TecGridTecEvaluationTerm {
        value: evaluation.value,
        degraded: evaluation.degraded.map(node_gap_to_term),
    }
}

fn delay_evaluation_to_term(evaluation: TecGridEvaluation<f64>) -> TecGridEvaluationTerm {
    TecGridEvaluationTerm {
        value: evaluation.value,
        degraded: evaluation.degraded.map(node_gap_to_term),
    }
}

/// The sample-validation failure, with the value or count the variant carries.
fn tec_samples_error_to_term<'a>(env: Env<'a>, err: TecSamplesError) -> Term<'a> {
    match err {
        TecSamplesError::Empty => atoms::empty().encode(env),
        TecSamplesError::TooFewNodes(count) => (atoms::too_few_nodes(), count).encode(env),
        TecSamplesError::NonMonotonicLat => atoms::non_monotonic_lat().encode(env),
        TecSamplesError::NonMonotonicLon => atoms::non_monotonic_lon().encode(env),
        TecSamplesError::NonMonotonicEpochs => atoms::non_monotonic_epochs().encode(env),
        TecSamplesError::EpochNotRepresentable(_) => atoms::epoch_not_representable().encode(env),
        TecSamplesError::ShapeMismatch => atoms::grid_mismatch().encode(env),
        TecSamplesError::RmsCountMismatch => atoms::rms_count_mismatch().encode(env),
        TecSamplesError::HeightCountMismatch => atoms::height_count_mismatch().encode(env),
        TecSamplesError::NonFiniteValue => atoms::non_finite_value().encode(env),
        TecSamplesError::NonPositiveStep => atoms::non_positive_step().encode(env),
        TecSamplesError::AxisOutOfRange(value) => (atoms::axis_out_of_range(), value).encode(env),
    }
}

fn checked_i32(value: i64, field: &'static str) -> NifResult<i32> {
    i32::try_from(value).map_err(|_| Error::Term(Box::new(format!("{field} out of range"))))
}

fn epoch_from_term(term: EpochTerm) -> Instant {
    term.0
}

fn epoch_to_term(epoch: Instant) -> EpochTerm {
    EpochTerm(epoch)
}

/// Decode the `MAPPING FUNCTION` a caller states.
///
/// `nil` and `:absent` are the absent declaration, which is a different
/// statement from a declared blank code. Note that `Option<Term>` decodes the
/// `nil` atom as `Some(nil)` rather than `None`, because a `Term` decodes from
/// any term at all, so the absent case is recognized here rather than by the
/// field's `Option`.
fn decode_mapping_function(term: Option<Term<'_>>) -> NifResult<Option<IonexMappingFunction>> {
    let Some(term) = term else {
        return Ok(None);
    };
    if term.is_atom() {
        let env = term.get_env();
        if term == rustler::types::atom::nil().to_term(env) || term == atoms::absent().to_term(env)
        {
            Ok(None)
        } else if term == atoms::none().to_term(env) {
            Ok(Some(IonexMappingFunction::NoMapping))
        } else if term == atoms::cosz().to_term(env) {
            Ok(Some(IonexMappingFunction::CosZ))
        } else if term == atoms::qfac().to_term(env) {
            Ok(Some(IonexMappingFunction::QFactor))
        } else {
            Err(Error::Term(Box::new("unknown mapping function atom")))
        }
    } else if let Ok(code) = term.decode::<String>() {
        // A declared code is kept as the caller wrote it. Only the three codes
        // the spec names map to their variants; anything else, a blank code
        // included, is an `Other` carrying that exact text.
        Ok(Some(if code == "NONE" {
            IonexMappingFunction::NoMapping
        } else if code == "COSZ" {
            IonexMappingFunction::CosZ
        } else if code == "QFAC" {
            IonexMappingFunction::QFactor
        } else {
            IonexMappingFunction::Other(code)
        }))
    } else {
        Err(Error::Term(Box::new("invalid mapping function format")))
    }
}

fn encode_mapping_function<'a>(env: Env<'a>, func: &Option<IonexMappingFunction>) -> Term<'a> {
    match func {
        None => None::<()>.encode(env),
        Some(IonexMappingFunction::NoMapping) => atoms::none().encode(env),
        Some(IonexMappingFunction::CosZ) => atoms::cosz().encode(env),
        Some(IonexMappingFunction::QFactor) => atoms::qfac().encode(env),
        Some(IonexMappingFunction::Other(code)) => code.encode(env),
    }
}

/// Build an [`IonexHeader`] from the boundary fields.
///
/// `IonexHeader` is `#[non_exhaustive]` and its unstated-record constructor is
/// private, so the header starts from the public [`IonexHeader::new`] and every
/// record the caller states is assigned to its public field. A caller that
/// declares no mapping function gets the absent declaration explicitly, which is
/// the value `IonexHeader::new` cannot express on its own.
fn make_header(term: IonexHeaderTerm<'_>) -> NifResult<IonexHeader> {
    let mut header = IonexHeader::new(IonexMappingFunction::NoMapping);
    header.mapping_function = decode_mapping_function(term.mapping_function)?;
    header.version = term.version;
    header.satellite_system = term.satellite_system;
    header.program = term.program;
    header.run_by = term.run_by;
    header.date = term.date;
    header.descriptions = term.descriptions;
    header.comments = term.comments;
    header.interval_s = term.interval_s;
    header.elevation_cutoff_deg = term.elevation_cutoff_deg;
    header.observables_used = term.observables_used;
    header.station_count = term.station_count;
    header.satellite_count = term.satellite_count;
    header.maps_in_file = term.maps_in_file;
    Ok(header)
}

fn header_to_term<'a>(env: Env<'a>, header: &IonexHeader) -> IonexHeaderTerm<'a> {
    IonexHeaderTerm {
        version: header.version,
        satellite_system: header.satellite_system.clone(),
        program: header.program.clone(),
        run_by: header.run_by.clone(),
        date: header.date.clone(),
        descriptions: header.descriptions.clone(),
        comments: header.comments.clone(),
        interval_s: header.interval_s,
        mapping_function: Some(encode_mapping_function(env, &header.mapping_function)),
        elevation_cutoff_deg: header.elevation_cutoff_deg,
        observables_used: header.observables_used.clone(),
        station_count: header.station_count,
        satellite_count: header.satellite_count,
        maps_in_file: header.maps_in_file,
    }
}

fn missing_nodes_to_term(nodes: IonexMissingNodes) -> MissingNodesTerm {
    MissingNodesTerm {
        map_number: nodes.map_number,
        lat_index: nodes.lat_index,
        lon_index: nodes.lon_index,
        lon_index_next: nodes.lon_index_next,
        missing: nodes.missing.to_vec(),
    }
}

fn node_gap_to_term(gap: IonexNodeGap) -> NodeGapTerm {
    NodeGapTerm {
        earlier: gap.earlier.map(missing_nodes_to_term),
        later: gap.later.map(missing_nodes_to_term),
    }
}

/// The band a warning names: the fixed atom for a name the core uses today, and
/// the core's own string for any other, never restated as one of the three.
fn warning_kind_term<'a>(env: Env<'a>, kind: &str) -> Term<'a> {
    match kind {
        "TEC" => atoms::tec().encode(env),
        "RMS" => atoms::rms().encode(env),
        "HEIGHT" => atoms::height().encode(env),
        other => other.encode(env),
    }
}

fn warning_base<'a>(tag: rustler::Atom, message: String) -> WarningTerm<'a> {
    WarningTerm {
        tag,
        label: None,
        line: None,
        declared_epoch: None,
        maps_epoch: None,
        declared_count: None,
        tec_maps: None,
        all_maps: None,
        kind: None,
        map_number: None,
        lat_deg: None,
        lon_deg: None,
        declared_s: None,
        spacing_s: None,
        exponent: None,
        set_by_line: None,
        message,
    }
}

/// One parse finding, with every field its variant carries.
///
/// [`IonexWarning`] is `#[non_exhaustive]`; a variant added after this binding
/// was written is tagged `:unhandled` and carries the core's own `Display` text
/// rather than being reported as one of the variants named here.
fn warning_to_term<'a>(env: Env<'a>, warning: IonexWarning) -> WarningTerm<'a> {
    let message = warning.to_string();
    match warning {
        IonexWarning::MissingRecord(label) => {
            let mut term = warning_base(atoms::missing_record(), message);
            term.label = Some(label.to_string());
            term
        }
        IonexWarning::VersionRecordNotFirst { line } => {
            let mut term = warning_base(atoms::version_record_not_first(), message);
            term.line = Some(line);
            term
        }
        IonexWarning::EpochMismatch {
            label,
            line,
            declared,
            maps,
        } => {
            let mut term = warning_base(atoms::epoch_mismatch(), message);
            term.label = Some(label.to_string());
            term.line = Some(line);
            term.declared_epoch = Some(epoch_to_term(declared));
            term.maps_epoch = Some(epoch_to_term(maps));
            term
        }
        IonexWarning::MapCountMismatch {
            line,
            declared,
            tec_maps,
            all_maps,
        } => {
            let mut term = warning_base(atoms::map_count_mismatch(), message);
            term.line = Some(line);
            term.declared_count = Some(declared);
            term.tec_maps = Some(tec_maps);
            term.all_maps = Some(all_maps);
            term
        }
        IonexWarning::NotANumberValue {
            kind,
            map_number,
            line,
            lat_deg,
            lon_deg,
        } => {
            let mut term = warning_base(atoms::not_a_number_value(), message);
            term.line = Some(line);
            term.kind = Some(warning_kind_term(env, kind));
            term.map_number = Some(map_number);
            term.lat_deg = Some(lat_deg);
            term.lon_deg = Some(lon_deg);
            term
        }
        IonexWarning::IntervalMismatch {
            line,
            declared_s,
            map_number,
            spacing_s,
        } => {
            let mut term = warning_base(atoms::interval_mismatch(), message);
            term.line = Some(line);
            term.declared_s = Some(declared_s);
            term.map_number = Some(map_number);
            term.spacing_s = Some(spacing_s);
            term
        }
        IonexWarning::ExponentCarriedIntoMap {
            kind,
            map_number,
            line,
            exponent,
            set_by_line,
        } => {
            let mut term = warning_base(atoms::exponent_carried_into_map(), message);
            term.line = Some(line);
            term.kind = Some(warning_kind_term(env, kind));
            term.map_number = Some(map_number);
            term.exponent = Some(exponent);
            term.set_by_line = Some(set_by_line);
            term
        }
        _ => warning_base(atoms::unhandled(), message),
    }
}

/// Why the product gives no slant delay under the requested policy.
///
/// [`IonexSlantRefusal`] is `#[non_exhaustive]`; an unrecognized variant is
/// `{:unhandled, message}` carrying the core's own text.
fn slant_refusal_to_term<'a>(env: Env<'a>, refusal: IonexSlantRefusal) -> Term<'a> {
    let message = refusal.to_string();
    match refusal {
        IonexSlantRefusal::VaryingHeights {
            map_number,
            lat_index,
            lon_index,
        } => (
            atoms::varying_heights(),
            HeightNodeRefusalTerm {
                map_number,
                lat_index,
                lon_index,
            },
        )
            .encode(env),
        IonexSlantRefusal::HeightNotAvailable {
            map_number,
            lat_index,
            lon_index,
        } => (
            atoms::height_not_available(),
            HeightNodeRefusalTerm {
                map_number,
                lat_index,
                lon_index,
            },
        )
            .encode(env),
        IonexSlantRefusal::MappingFunction(decl) => {
            let decl_term = match decl {
                IonexMappingDeclaration::Declared(func) => {
                    encode_mapping_function(env, &Some(func))
                }
                IonexMappingDeclaration::Absent => atoms::absent().encode(env),
            };
            (atoms::mapping_function(), decl_term).encode(env)
        }
        _ => (atoms::unhandled(), message).encode(env),
    }
}

fn coverage_error_to_atom(err: IonexCoverageError) -> rustler::Atom {
    match err {
        IonexCoverageError::EpochBeforeFirstMap => atoms::epoch_before_first_map(),
        IonexCoverageError::EpochAfterLastMap => atoms::epoch_after_last_map(),
        IonexCoverageError::LatitudeOutOfRange => atoms::latitude_out_of_range(),
        IonexCoverageError::LongitudeOutOfRange => atoms::longitude_out_of_range(),
    }
}

/// What the product declares, where the single-layer factor mapped a product
/// declaring anything but `COSZ`.
///
/// [`IonexAssumedMapping::Other`] names the case without the code's text, which
/// the core keeps in the header, so the code is read from there and carried as
/// `{:other, code}`.
fn assumed_mapping_to_term<'a>(
    env: Env<'a>,
    mapping: IonexAssumedMapping,
    header: &IonexHeader,
) -> Term<'a> {
    match mapping {
        IonexAssumedMapping::NoMapping => atoms::no_mapping().encode(env),
        IonexAssumedMapping::QFactor => atoms::q_factor().encode(env),
        IonexAssumedMapping::Absent => atoms::absent().encode(env),
        IonexAssumedMapping::Other => (
            atoms::other(),
            encode_mapping_function(env, &header.mapping_function),
        )
            .encode(env),
    }
}

fn slant_evaluation_to_term<'a>(
    env: Env<'a>,
    eval: IonexSlantDelayEvaluation,
    header: &IonexHeader,
) -> SlantEvaluationTerm<'a> {
    SlantEvaluationTerm {
        delay_m: eval.delay_m,
        status: SlantStatusTerm {
            held: eval.status.held.map(coverage_error_to_atom),
            degraded: eval.status.degraded.map(node_gap_to_term),
            assumed_mapping: eval
                .status
                .assumed_mapping
                .map(|mapping| assumed_mapping_to_term(env, mapping, header)),
            valid: eval.status.is_valid(),
        },
    }
}

/// The reason a slant-delay evaluation gives no value, as a typed term.
///
/// `sidereon_core::Error` is `#[non_exhaustive]`; anything that is not one of
/// the three IONEX arms is `{:invalid_input, message}` carrying the core's text.
fn slant_error_to_term<'a>(env: Env<'a>, err: CoreError) -> Term<'a> {
    match err {
        CoreError::IonexSlantUnavailable(refusal) => slant_refusal_to_term(env, refusal),
        CoreError::IonexOutOfCoverage(cov) => {
            (atoms::out_of_coverage(), coverage_error_to_atom(cov)).encode(env)
        }
        CoreError::IonexNodesNotAvailable(gap) => {
            (atoms::nodes_not_available(), node_gap_to_term(*gap)).encode(env)
        }
        other => (atoms::invalid_input(), other.to_string()).encode(env),
    }
}

/// A regular-grid failure, with every field its variant carries.
///
/// [`TecGridError`] is `#[non_exhaustive]`; an unrecognized variant is
/// `{:unhandled, message}` carrying the core's own text.
fn tec_grid_error_to_term<'a>(env: Env<'a>, err: TecGridError) -> Term<'a> {
    let message = err.to_string();
    match err {
        TecGridError::AxesTooShort => atoms::axes_too_short().encode(env),
        TecGridError::AxesNotIncreasing => atoms::axes_not_increasing().encode(env),
        TecGridError::DimensionsOverflow => atoms::dimensions_overflow().encode(env),
        TecGridError::ValueCountMismatch { actual, expected } => {
            (atoms::value_count_mismatch(), actual, expected).encode(env)
        }
        TecGridError::InvalidField { field, reason } => {
            (atoms::invalid_field(), field, reason).encode(env)
        }
        TecGridError::NodesNotAvailable(gap) => {
            (atoms::nodes_not_available(), node_gap_to_term(gap)).encode(env)
        }
        TecGridError::OutOfBounds { name, value } => {
            (atoms::out_of_bounds(), name, value).encode(env)
        }
        _ => (atoms::unhandled(), message).encode(env),
    }
}

/// Build an [`IonexSlantPolicy`] from the three named choices.
///
/// The struct is `#[non_exhaustive]`, so the policy starts from
/// [`IonexSlantPolicy::default`] and each choice is applied through its public
/// builder. An unknown name for any of the three is an error; none of them falls
/// back to a default.
fn decode_slant_policy(term: SlantPolicyTerm) -> NifResult<IonexSlantPolicy> {
    let coverage = if term.coverage == atoms::strict() {
        IonexCoveragePolicy::Strict
    } else if term.coverage == atoms::hold() {
        IonexCoveragePolicy::Hold
    } else {
        return Err(Error::Term(Box::new("unknown coverage policy")));
    };

    let missing_nodes = decode_missing_node_policy(term.missing_nodes)?;

    let mapping = if term.mapping == atoms::single_layer() {
        IonexMappingPolicy::SingleLayer
    } else if term.mapping == atoms::declared() {
        IonexMappingPolicy::Declared
    } else {
        return Err(Error::Term(Box::new("unknown mapping policy")));
    };

    Ok(IonexSlantPolicy::default()
        .with_coverage(coverage)
        .with_missing_nodes(missing_nodes)
        .with_mapping(mapping))
}

fn decode_missing_node_policy(policy: rustler::Atom) -> NifResult<IonexMissingNodePolicy> {
    if policy == atoms::strict() {
        Ok(IonexMissingNodePolicy::Strict)
    } else if policy == atoms::renormalize() {
        Ok(IonexMissingNodePolicy::Renormalize)
    } else {
        Err(Error::Term(Box::new("unknown missing_nodes policy")))
    }
}

fn grid_samples_from_term(term: TecGridSamplesTerm<'_>) -> NifResult<TecGridSamples> {
    let header = make_header(term.header)?;
    Ok(TecGridSamples {
        map_epochs: term.map_epochs.into_iter().map(epoch_from_term).collect(),
        lat_nodes_deg: term.lat_nodes_deg,
        lon_nodes_deg: term.lon_nodes_deg,
        dlat_deg: term.dlat_deg,
        dlon_deg: term.dlon_deg,
        shell_height_km: term.shell_height_km,
        base_radius_km: term.base_radius_km,
        exponent: checked_i32(term.exponent, "exponent")?,
        tec_maps: term.tec_maps,
        // The core carries "no such maps" as an empty vector and "maps present,
        // every node non-available" as a full one; `nil` is the former, and a
        // list of all-`nil` nodes is the latter.
        rms_maps: term.rms_maps.unwrap_or_default(),
        height_maps: term.height_maps.unwrap_or_default(),
        header,
    })
}

fn grid_samples_to_term<'a>(env: Env<'a>, samples: TecGridSamples) -> TecGridSamplesTerm<'a> {
    let rms_maps = (!samples.rms_maps.is_empty()).then_some(samples.rms_maps);
    let height_maps = (!samples.height_maps.is_empty()).then_some(samples.height_maps);
    let header = header_to_term(env, &samples.header);
    TecGridSamplesTerm {
        map_epochs: samples.map_epochs.into_iter().map(epoch_to_term).collect(),
        lat_nodes_deg: samples.lat_nodes_deg,
        lon_nodes_deg: samples.lon_nodes_deg,
        dlat_deg: samples.dlat_deg,
        dlon_deg: samples.dlon_deg,
        shell_height_km: samples.shell_height_km,
        base_radius_km: samples.base_radius_km,
        exponent: i64::from(samples.exponent),
        tec_maps: samples.tec_maps,
        rms_maps,
        height_maps,
        header,
    }
}

fn tec_sample_from_term(term: TecSampleTerm) -> TecSample {
    TecSample {
        epoch: epoch_from_term(term.epoch),
        lat_deg: term.lat_deg,
        lon_deg: term.lon_deg,
        vtec_tecu: term.vtec_tecu,
        rms_tecu: term.rms_tecu,
        height_offset_km: term.height_offset_km,
    }
}

fn tec_sample_to_term(sample: TecSample) -> TecSampleTerm {
    TecSampleTerm {
        epoch: epoch_to_term(sample.epoch),
        lat_deg: sample.lat_deg,
        lon_deg: sample.lon_deg,
        vtec_tecu: sample.vtec_tecu,
        rms_tecu: sample.rms_tecu,
        height_offset_km: sample.height_offset_km,
    }
}

/// The receiver position for a slant query, converting the boundary's degrees to
/// the radians `Wgs84Geodetic` takes. The pierce point rides on the product's
/// shell, so the receiver height is not part of the query.
fn slant_receiver(lat_deg: f64, lon_deg: f64) -> Result<Wgs84Geodetic, FrameValueError> {
    Wgs84Geodetic::new(lat_deg.to_radians(), lon_deg.to_radians(), 0.0)
}

/// The named component of a receiver position the frame rejected, and why.
fn frame_error_to_term<'a>(env: Env<'a>, err: FrameValueError) -> Term<'a> {
    let FrameValueError::InvalidInput { field, reason } = err;
    (atoms::invalid_field(), field, reason).encode(env)
}

/// Why one slant query gives no value.
///
/// A receiver position the frame refuses and a query the product refuses are
/// different failures and keep their own reasons; neither is restated as the
/// other.
enum SlantFailure {
    Receiver(FrameValueError),
    Core(CoreError),
}

fn slant_failure_to_term<'a>(env: Env<'a>, failure: SlantFailure) -> Term<'a> {
    match failure {
        SlantFailure::Receiver(err) => frame_error_to_term(env, err),
        SlantFailure::Core(err) => slant_error_to_term(env, err),
    }
}

/// One batch row's query, or the reason that row could not be formed.
///
/// [`IonexSlantRequest`] is `#[non_exhaustive]`, so a row is built through
/// [`IonexSlantRequest::new`]. A row whose receiver position is out of range
/// fails as that row and not as the call.
enum PreparedRequest {
    Ready(IonexSlantRequest),
    Invalid(FrameValueError),
}

fn prepare_slant_request(term: &SlantRequestTerm) -> PreparedRequest {
    match slant_receiver(term.lat_deg, term.lon_deg) {
        Ok(receiver) => PreparedRequest::Ready(IonexSlantRequest::new(
            receiver,
            term.elevation_deg.to_radians(),
            term.azimuth_deg.to_radians(),
            Instant::from_nanos(
                TimeScale::Utc,
                i128::from(term.epoch_j2000_s) * 1_000_000_000,
            ),
            term.frequency_hz,
        )),
        Err(err) => PreparedRequest::Invalid(err),
    }
}

/// The standard ionosphere-free carrier-frequency table.
///
/// Returns `[{"G", [{"l1", f}, ...]}, ...]`; the Elixir wrapper maps the band
/// names back to atom keys to preserve the public API shape.
#[rustler::nif]
fn iono_free_frequencies() -> Vec<(String, Vec<(String, f64)>)> {
    let mut by_system = std::collections::BTreeMap::<String, Vec<(String, f64)>>::new();
    for entry in frequencies::iono_free_carrier_frequencies() {
        by_system
            .entry(entry.system.letter().to_string())
            .or_default()
            .push((entry.band.name().to_string(), entry.frequency_hz));
    }
    by_system.into_iter().collect()
}

/// Standard ionosphere-free carrier pair for a constellation.
#[rustler::nif]
fn iono_free_default_pair<'a>(env: Env<'a>, system: String) -> Term<'a> {
    let system_id = first_char(&system).and_then(GnssSystem::from_letter);
    match system_id.and_then(frequencies::default_iono_free_pair) {
        Some(pair) => (
            atoms::ok(),
            (pair.band1.name().to_string(), pair.band2.name().to_string()),
        )
            .encode(env),
        None => (atoms::error(), atoms::unknown_system()).encode(env),
    }
}

/// Carrier-frequency lookup by constellation and lower-case band name.
#[rustler::nif]
fn iono_free_frequency<'a>(env: Env<'a>, system: String, band: String) -> Term<'a> {
    let frequency_hz = first_char(&system)
        .and_then(GnssSystem::from_letter)
        .zip(CarrierBand::from_iono_free_name(&band))
        .and_then(|(system, band)| frequencies::frequency_hz(system, band));
    match frequency_hz {
        Some(frequency_hz) => (atoms::ok(), frequency_hz).encode(env),
        None => (atoms::error(), atoms::unknown_band()).encode(env),
    }
}

/// Ionosphere-free coefficient `gamma = f1^2 / (f1^2 - f2^2)`.
#[rustler::nif]
fn iono_free_gamma<'a>(env: Env<'a>, f1_hz: f64, f2_hz: f64) -> Term<'a> {
    encode_float_result(env, combinations::gamma(f1_hz, f2_hz))
}

/// Equal-variance noise amplification of the ionosphere-free combination.
#[rustler::nif]
fn iono_free_noise_amplification<'a>(env: Env<'a>, f1_hz: f64, f2_hz: f64) -> Term<'a> {
    encode_float_result(env, combinations::noise_amplification(f1_hz, f2_hz))
}

/// Ionosphere-free pseudorange combination from two carrier bands.
#[rustler::nif]
fn iono_free_code<'a>(env: Env<'a>, pr1_m: f64, pr2_m: f64, f1_hz: f64, f2_hz: f64) -> Term<'a> {
    encode_float_result(
        env,
        combinations::ionosphere_free(pr1_m, pr2_m, f1_hz, f2_hz),
    )
}

/// Ionosphere-free carrier-phase combination from metre-valued phase inputs.
#[rustler::nif]
fn iono_free_phase<'a>(
    env: Env<'a>,
    phase1_m: f64,
    phase2_m: f64,
    f1_hz: f64,
    f2_hz: f64,
) -> Term<'a> {
    encode_float_result(
        env,
        combinations::ionosphere_free_phase_m(phase1_m, phase2_m, f1_hz, f2_hz),
    )
}

/// Ionosphere-free carrier-phase combination from cycle-valued phase inputs.
#[rustler::nif]
fn iono_free_phase_cycles<'a>(
    env: Env<'a>,
    phi1_cycles: f64,
    phi2_cycles: f64,
    f1_hz: f64,
    f2_hz: f64,
) -> Term<'a> {
    encode_float_result(
        env,
        combinations::ionosphere_free_phase_cycles(phi1_cycles, phi2_cycles, f1_hz, f2_hz),
    )
}

/// Pair and combine two per-satellite pseudorange bands.
///
/// `overrides` is `[{"G", "l1", "l2"}, ...]`; the Elixir wrapper handles the
/// public `%{"G" => {:l1, :l2}}` shape.
#[rustler::nif(schedule = "DirtyCpu")]
fn iono_free_pseudoranges<'a>(
    env: Env<'a>,
    band1: Vec<(String, f64)>,
    band2: Vec<(String, f64)>,
    overrides: Vec<(String, String, String)>,
) -> Term<'a> {
    let overrides = overrides
        .into_iter()
        .filter_map(|(system, band1, band2)| first_char(&system).map(|s| (s, band1, band2)))
        .collect::<Vec<_>>();
    let (combined, dropped) =
        match combinations::ionosphere_free_pseudoranges(&band1, &band2, &overrides) {
            Ok(result) => result,
            Err(error) => return (atoms::error(), iono_error_atom(error)).encode(env),
        };
    let dropped_terms = dropped
        .into_iter()
        .map(|(sat, reason)| (sat, drop_reason_atom(reason)).encode(env))
        .collect::<Vec<Term<'a>>>();
    (combined, dropped_terms).encode(env)
}

fn first_char(value: &str) -> Option<char> {
    value.chars().next()
}

fn encode_float_result<'a>(env: Env<'a>, result: Result<f64, IonosphereFreeError>) -> Term<'a> {
    match result {
        Ok(value) => (atoms::ok(), value).encode(env),
        Err(error) => (atoms::error(), iono_error_atom(error)).encode(env),
    }
}

fn iono_error_atom(error: IonosphereFreeError) -> rustler::Atom {
    match error {
        IonosphereFreeError::EqualFrequencies => atoms::equal_frequencies(),
        IonosphereFreeError::InvalidFrequency => atoms::invalid_frequency(),
        IonosphereFreeError::InvalidObservation => atoms::invalid_observation(),
        IonosphereFreeError::UnknownSystem(_) => atoms::unknown_system(),
        IonosphereFreeError::UnknownBand { .. } => atoms::unknown_band(),
    }
}

fn drop_reason_atom(reason: PseudorangeDropReason) -> rustler::Atom {
    match reason {
        PseudorangeDropReason::MissingBand1 => atoms::missing_band1(),
        PseudorangeDropReason::MissingBand2 => atoms::missing_band2(),
        PseudorangeDropReason::DuplicateObservation => atoms::duplicate_observation(),
        PseudorangeDropReason::UnknownSystem => atoms::unknown_system(),
    }
}

/// GPS broadcast Klobuchar L1 ionospheric group delay (positive meters).
///
/// All inputs arrive in the model's native boundary units: receiver
/// latitude/longitude and satellite azimuth/elevation in **degrees**, and the
/// GPS **second-of-day** in `[0, 86400)`. The Elixir wrapper supplies these
/// directly (it has the degree inputs and forms the second-of-day from the
/// epoch's integer clock fields), so no angle or time conversion happens at this
/// boundary and the delay is bit-exact to the model reference. `frequency_hz` is
/// the carrier on which the delay is reported (the model is dispersive).
#[rustler::nif]
#[allow(clippy::too_many_arguments)]
fn klobuchar_delay(
    lat_deg: f64,
    lon_deg: f64,
    azimuth_deg: f64,
    elevation_deg: f64,
    t_gps_s: f64,
    frequency_hz: f64,
    alpha: (f64, f64, f64, f64),
    beta: (f64, f64, f64, f64),
) -> NifResult<f64> {
    let params = KlobucharParams {
        alpha: [alpha.0, alpha.1, alpha.2, alpha.3],
        beta: [beta.0, beta.1, beta.2, beta.3],
    };
    klobuchar_native(
        &params,
        lat_deg,
        lon_deg,
        azimuth_deg,
        elevation_deg,
        t_gps_s,
        frequency_hz,
    )
    .map_err(crate::errors::invalid_input)
}

/// Galileo NeQuick-G single-frequency ionospheric group delay (positive meters).
///
/// Pure glue over `sidereon_core::atmosphere::ionosphere::ionosphere_delay` with
/// the `GalileoNequickG` model: the `ai0`/`ai1`/`ai2` broadcast effective-
/// ionisation coefficients drive the core NeQuick-G kernel. The receiver
/// latitude/longitude and the satellite azimuth/elevation arrive in degrees; the
/// NIF converts them to the core's radians. The epoch arrives as the split
/// Julian date `(jd_whole, jd_fraction)` the SP3/IONEX path already uses, so the
/// core kernel derives the Galileo second-of-day and fractional day-of-year from
/// the same instant with no second representation. `azimuth_deg` is validated by
/// the shared model entry but the NeQuick-G arm maps slant by elevation only.
/// `frequency_hz` is the carrier on which the dispersive delay is reported.
#[rustler::nif]
#[allow(clippy::too_many_arguments)]
fn galileo_nequick_g_delay(
    lat_deg: f64,
    lon_deg: f64,
    elevation_deg: f64,
    azimuth_deg: f64,
    jd_whole: f64,
    jd_fraction: f64,
    frequency_hz: f64,
    ai0: f64,
    ai1: f64,
    ai2: f64,
) -> NifResult<f64> {
    let receiver = Wgs84Geodetic::new(lat_deg.to_radians(), lon_deg.to_radians(), 0.0)
        .map_err(crate::errors::invalid_input)?;
    let split = JulianDateSplit::new(jd_whole, jd_fraction)
        .map_err(crate::tropo::time_model_error_detail)?;
    let epoch = Instant::from_julian_date(TimeScale::Gpst, split);
    let model = IonoModel::GalileoNequickG(GalileoNequickCoeffs { ai0, ai1, ai2 });
    ionosphere_delay(
        receiver,
        elevation_deg.to_radians(),
        azimuth_deg.to_radians(),
        epoch,
        frequency_hz,
        &model,
    )
    .map_err(crate::errors::invalid_input)
}

/// Parse an IONEX byte buffer into a resource handle.
///
/// Dirty-CPU: a full daily IONEX map set is unbounded relative to the 1 ms NIF
/// budget. On success returns the [`IonexResource`] handle; on a malformed
/// buffer returns the crate's parse-error reason as an Erlang term.
#[rustler::nif(schedule = "DirtyCpu")]
fn ionex_parse(bytes: rustler::Binary) -> NifResult<ResourceArc<IonexResource>> {
    let ionex = Ionex::parse(bytes.as_slice()).map_err(|e| Error::Term(Box::new(e.to_string())))?;
    Ok(ResourceArc::new(IonexResource { ionex }))
}

/// Parse an IONEX byte buffer, keeping the findings the reader reports without
/// refusing the file.
///
/// Returns `{:ok, handle, warnings}` with every warning in reader order and
/// every field its variant carries. Dirty-CPU for the same reason as
/// `ionex_parse/1`.
#[rustler::nif(schedule = "DirtyCpu")]
fn ionex_parse_with_warnings<'a>(env: Env<'a>, bytes: rustler::Binary) -> Term<'a> {
    match Ionex::parse_with_warnings(bytes.as_slice()) {
        Ok((ionex, warnings)) => {
            let warnings: Vec<WarningTerm<'a>> = warnings
                .into_iter()
                .map(|warning| warning_to_term(env, warning))
                .collect();
            (
                atoms::ok(),
                ResourceArc::new(IonexResource { ionex }),
                warnings,
            )
                .encode(env)
        }
        Err(err) => (atoms::error(), err.to_string()).encode(env),
    }
}

/// The descriptive header records a parsed or sample-built product carries.
///
/// Dirty-CPU: the descriptions and comments are caller-sized lists copied out of
/// the product, so the work is not bounded by the header's fixed fields.
#[rustler::nif(schedule = "DirtyCpu")]
fn ionex_header<'a>(env: Env<'a>, handle: ResourceArc<IonexResource>) -> IonexHeaderTerm<'a> {
    header_to_term(env, handle.ionex.header())
}

/// The number of records a forgiving parse passed over.
///
/// A skipped record raises no warning, so this is the only report that anything
/// in the file was left out. A sample-built product has skipped nothing.
#[rustler::nif]
fn ionex_skipped_records(handle: ResourceArc<IonexResource>) -> usize {
    handle.ionex.skipped_records()
}

/// Serialize a parsed IONEX product back to standard IONEX text.
///
/// The inverse of `ionex_parse/1`: re-parsing the output reproduces the same
/// grids. The writer is fallible — it refuses a value it cannot write exactly
/// rather than rounding it — so this returns `{:ok, text}` or `{:error, reason}`.
/// Dirty-CPU because a full daily map set's serialization is unbounded relative
/// to the NIF budget.
#[rustler::nif(schedule = "DirtyCpu")]
fn ionex_to_string<'a>(env: Env<'a>, handle: ResourceArc<IonexResource>) -> Term<'a> {
    match handle.ionex.to_ionex_string() {
        Ok(text) => (atoms::ok(), text).encode(env),
        Err(err) => (atoms::error(), (atoms::invalid_input(), err.to_string())).encode(env),
    }
}

/// Build an IONEX product directly from whole-grid TEC samples.
#[rustler::nif(schedule = "DirtyCpu")]
fn ionex_from_samples<'a>(env: Env<'a>, samples: TecGridSamplesTerm<'a>) -> NifResult<Term<'a>> {
    let samples = grid_samples_from_term(samples)?;
    Ok(match Ionex::from_samples(samples) {
        Ok(ionex) => (atoms::ok(), ResourceArc::new(IonexResource { ionex })).encode(env),
        Err(err) => (atoms::error(), tec_samples_error_to_term(env, err)).encode(env),
    })
}

/// Build an IONEX product from one TEC sample per grid node.
///
/// `header` carries the descriptive records the product keeps, which the core
/// takes as its own argument: a node-sample product is not otherwise told which
/// mapping function or program produced it.
#[rustler::nif(schedule = "DirtyCpu")]
fn ionex_from_node_samples<'a>(
    env: Env<'a>,
    samples: Vec<TecSampleTerm>,
    shell_height_km: f64,
    base_radius_km: f64,
    exponent: i64,
    header: IonexHeaderTerm<'a>,
) -> NifResult<Term<'a>> {
    let header = make_header(header)?;
    let samples: Vec<TecSample> = samples.into_iter().map(tec_sample_from_term).collect();
    Ok(
        match Ionex::from_node_samples(
            samples,
            shell_height_km,
            base_radius_km,
            checked_i32(exponent, "exponent")?,
            header,
        ) {
            Ok(ionex) => (atoms::ok(), ResourceArc::new(IonexResource { ionex })).encode(env),
            Err(err) => (atoms::error(), tec_samples_error_to_term(env, err)).encode(env),
        },
    )
}

/// Extract a parsed or sample-built IONEX product as whole-grid TEC samples.
#[rustler::nif(schedule = "DirtyCpu")]
fn ionex_tec_grid_samples<'a>(
    env: Env<'a>,
    handle: ResourceArc<IonexResource>,
) -> TecGridSamplesTerm<'a> {
    grid_samples_to_term(env, handle.ionex.tec_grid_samples())
}

/// Extract a parsed or sample-built IONEX product as node TEC samples.
#[rustler::nif(schedule = "DirtyCpu")]
fn ionex_tec_samples(handle: ResourceArc<IonexResource>) -> Vec<TecSampleTerm> {
    handle
        .ionex
        .tec_samples()
        .into_iter()
        .map(tec_sample_to_term)
        .collect()
}

/// IONEX vertical-TEC-grid slant ionospheric group delay (positive meters).
///
/// Operates on the parsed handle plus the receiver geodetic latitude/longitude
/// and the satellite azimuth/elevation in degrees, which this boundary converts
/// to the radians the core signature takes. `epoch_j2000_s` is integer seconds
/// since the J2000 epoch so it lands exactly on the product's own epoch axis
/// with no float-rounded time entering the temporal bracket. `frequency_hz` is
/// the carrier on which the delay is reported. Uses the default policy: it
/// refuses a query outside coverage and one weighting a non-available node.
/// No file I/O.
///
/// Dirty-CPU: the shell height the pierce point rides on is read by
/// `slant_shell_height`, which walks the height nodes of *every* height map the
/// product carries - not the two maps bracketing the query epoch - to confirm
/// they all give one and the same height, stopping at the first node that gives
/// none or gives a different one. The map and node counts are properties of the
/// caller's product and the scan does not narrow with the query, so the work is
/// unbounded relative to the NIF budget.
#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
fn ionex_slant<'a>(
    env: Env<'a>,
    handle: ResourceArc<IonexResource>,
    lat_deg: f64,
    lon_deg: f64,
    elevation_deg: f64,
    azimuth_deg: f64,
    epoch_j2000_s: i64,
    frequency_hz: f64,
) -> Term<'a> {
    match evaluate_slant(
        &handle.ionex,
        lat_deg,
        lon_deg,
        elevation_deg,
        azimuth_deg,
        Instant::from_nanos(TimeScale::Utc, i128::from(epoch_j2000_s) * 1_000_000_000),
        frequency_hz,
        IonexSlantPolicy::default(),
    ) {
        Ok(evaluation) => (atoms::ok(), evaluation.delay_m).encode(env),
        Err(failure) => (atoms::error(), slant_failure_to_term(env, failure)).encode(env),
    }
}

/// IONEX slant delay under explicit coverage, missing-node and mapping policies.
///
/// Returns `{:ok, evaluation}` carrying the delay together with its independent
/// `held`, `degraded` and `assumed_mapping` status fields, which can all be set
/// on one value, or `{:error, reason}` naming the refusal, the coverage miss or
/// the non-available nodes in full.
///
/// Dirty-CPU for the same reason as `ionex_slant/7`: the shell-height scan walks
/// the height nodes of every height map the product carries, independently of
/// the query epoch.
#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
fn ionex_slant_with_policy<'a>(
    env: Env<'a>,
    handle: ResourceArc<IonexResource>,
    lat_deg: f64,
    lon_deg: f64,
    elevation_deg: f64,
    azimuth_deg: f64,
    epoch_j2000_s: i64,
    frequency_hz: f64,
    policy: SlantPolicyTerm,
) -> NifResult<Term<'a>> {
    let policy = decode_slant_policy(policy)?;
    Ok(
        match evaluate_slant(
            &handle.ionex,
            lat_deg,
            lon_deg,
            elevation_deg,
            azimuth_deg,
            Instant::from_nanos(TimeScale::Utc, i128::from(epoch_j2000_s) * 1_000_000_000),
            frequency_hz,
            policy,
        ) {
            Ok(evaluation) => (
                atoms::ok(),
                slant_evaluation_to_term(env, evaluation, handle.ionex.header()),
            )
                .encode(env),
            Err(failure) => (atoms::error(), slant_failure_to_term(env, failure)).encode(env),
        },
    )
}

#[allow(clippy::too_many_arguments)]
fn evaluate_slant(
    ionex: &Ionex,
    lat_deg: f64,
    lon_deg: f64,
    elevation_deg: f64,
    azimuth_deg: f64,
    epoch: Instant,
    frequency_hz: f64,
    policy: IonexSlantPolicy,
) -> Result<IonexSlantDelayEvaluation, SlantFailure> {
    let receiver = slant_receiver(lat_deg, lon_deg).map_err(SlantFailure::Receiver)?;
    ionex_slant_delay_with_policy(
        ionex,
        receiver,
        elevation_deg.to_radians(),
        azimuth_deg.to_radians(),
        epoch,
        frequency_hz,
        policy,
    )
    .map_err(SlantFailure::Core)
}

/// Batch IONEX slant delays, one result per request in request order.
///
/// Every row keeps its own outcome: `{:ok, evaluation}` or `{:error, reason}`
/// with the refusal, coverage miss or node gap in full. A row that fails leaves
/// the rest of the batch alone and is never dropped or filled with a zero. The
/// call itself fails only on an argument it cannot read at all, such as an
/// unknown policy name. Dirty-CPU: the batch length is caller-chosen and
/// unbounded relative to the NIF budget.
#[rustler::nif(schedule = "DirtyCpu")]
fn ionex_slant_batch<'a>(
    env: Env<'a>,
    handle: ResourceArc<IonexResource>,
    requests: Vec<SlantRequestTerm>,
    policy: SlantPolicyTerm,
) -> NifResult<Term<'a>> {
    let policy = decode_slant_policy(policy)?;
    let prepared: Vec<PreparedRequest> = requests.iter().map(prepare_slant_request).collect();
    let ready: Vec<IonexSlantRequest> = prepared
        .iter()
        .filter_map(|request| match request {
            PreparedRequest::Ready(request) => Some(*request),
            PreparedRequest::Invalid(_) => None,
        })
        .collect();

    let header = handle.ionex.header();
    let mut evaluated = ionex_slant_delay_results(&handle.ionex, &ready, policy).into_iter();
    let rows: Vec<Term<'a>> = prepared
        .iter()
        .map(|request| match request {
            PreparedRequest::Invalid(err) => {
                (atoms::error(), frame_error_to_term(env, *err)).encode(env)
            }
            PreparedRequest::Ready(_) => match evaluated.next() {
                Some(Ok(evaluation)) => (
                    atoms::ok(),
                    slant_evaluation_to_term(env, evaluation, header),
                )
                    .encode(env),
                Some(Err(err)) => (atoms::error(), slant_error_to_term(env, err)).encode(env),
                // One result per readable request is the core's contract; a
                // short result list is reported as such rather than passed off
                // as a value.
                None => (
                    atoms::error(),
                    (
                        atoms::unhandled(),
                        "IONEX batch returned fewer results than requests",
                    ),
                )
                    .encode(env),
            },
        })
        .collect();
    Ok((atoms::ok(), rows).encode(env))
}

/// Build a standalone regular TEC grid from its three axes and flat values.
///
/// The axes are floating Unix nanoseconds, degrees latitude and degrees
/// longitude, each strictly increasing with at least two nodes. `values` is flat
/// `[epoch][latitude][longitude]` with longitude varying fastest, in TECU, where
/// `nil` is a node without a value and `0.0` is a node holding zero. Dirty-CPU:
/// the value count is the product of the three axis lengths.
#[rustler::nif(schedule = "DirtyCpu")]
fn tec_grid_new<'a>(
    env: Env<'a>,
    epochs_ns: Vec<f64>,
    latitudes_deg: Vec<f64>,
    longitudes_deg: Vec<f64>,
    values: Vec<Option<f64>>,
) -> Term<'a> {
    match TecGrid::new(epochs_ns, latitudes_deg, longitudes_deg, values) {
        Ok(grid) => (atoms::ok(), ResourceArc::new(TecGridResource { grid })).encode(env),
        Err(err) => (atoms::error(), tec_grid_error_to_term(env, err)).encode(env),
    }
}

/// Vertical TEC interpolated at a pierce point on a standalone regular grid.
///
/// The core signature takes `longitude_deg` before `latitude_deg`, and this
/// boundary passes them in that order; both stay in degrees. `unix_nanos` is an
/// exact integer Unix-nanosecond epoch, which the core converts to its floating
/// epoch axis. `missing_nodes` is `:strict` or `:renormalize`; under
/// `:renormalize` the result names every node it interpolated around.
///
/// The day-of-year companion [`TecGridEpoch`] carries is not read by regular
/// grid interpolation, so it is zero here and no day-of-year is invented for it.
#[rustler::nif]
fn tec_grid_vtec_at_pierce_point<'a>(
    env: Env<'a>,
    handle: ResourceArc<TecGridResource>,
    unix_nanos: i64,
    longitude_deg: f64,
    latitude_deg: f64,
    missing_nodes: rustler::Atom,
) -> NifResult<Term<'a>> {
    let policy = decode_missing_node_policy(missing_nodes)?;
    let epoch = TecGridEpoch::new(unix_nanos, 0);
    Ok(
        match handle.grid.vtec_at_pierce_point_with_policy(
            epoch,
            longitude_deg,
            latitude_deg,
            policy,
        ) {
            Ok(evaluation) => (
                atoms::ok(),
                TecGridEvaluationTerm {
                    value: evaluation.value,
                    degraded: evaluation.degraded.map(node_gap_to_term),
                },
            )
                .encode(env),
            Err(err) => (atoms::error(), tec_grid_error_to_term(env, err)).encode(env),
        },
    )
}

/// The grid's epoch axis, as the floating Unix nanoseconds the core stores. Dirty-CPU: the
/// axis length is caller-chosen and the copy is not bounded by the NIF budget.
#[rustler::nif(schedule = "DirtyCpu")]
fn tec_grid_epochs_ns(handle: ResourceArc<TecGridResource>) -> Vec<f64> {
    handle.grid.epochs_ns().to_vec()
}

/// The grid's latitude axis in degrees. Dirty-CPU: the
/// axis length is caller-chosen and the copy is not bounded by the NIF budget.
#[rustler::nif(schedule = "DirtyCpu")]
fn tec_grid_latitudes_deg(handle: ResourceArc<TecGridResource>) -> Vec<f64> {
    handle.grid.latitudes_deg().to_vec()
}

/// The grid's longitude axis in degrees. Dirty-CPU: the
/// axis length is caller-chosen and the copy is not bounded by the NIF budget.
#[rustler::nif(schedule = "DirtyCpu")]
fn tec_grid_longitudes_deg(handle: ResourceArc<TecGridResource>) -> Vec<f64> {
    handle.grid.longitudes_deg().to_vec()
}

/// The grid's TECU values, flat in `[epoch][latitude][longitude]` order with
/// longitude varying fastest; `nil` is a node without a value. Dirty-CPU: the
/// length is the product of the three axis lengths.
#[rustler::nif(schedule = "DirtyCpu")]
fn tec_grid_values(handle: ResourceArc<TecGridResource>) -> Vec<Option<f64>> {
    handle.grid.values().to_vec()
}

/// Prepares a vertical and slant TEC evaluation on a standalone grid for a
/// caller that converts the ECEF positions it asks about itself.
///
/// `unix_nanos` is the exact integer Unix-nanosecond epoch; the day-of-year
/// companion is zero, as for `tec_grid_vtec_at_pierce_point`. The positions are
/// ECEF meters, `{x, y, z}` of transported doubles. The TEC evaluation reads no
/// carrier frequency, so the options start from [`TecGridEvalOptions::l1`]
/// only because the struct holds one.
///
/// [`TecGridXyzConversion::prepare`] checks the inputs in the order
/// `tec_xyz_with_policy` does. Returns `{:ok, {:convert, stage, xyz}}` asking
/// for the pierce point `xyz`, or `{:error, reason}` for inputs the core
/// refuses, before any conversion is asked for. Dirty-CPU, as are the steps
/// that continue it.
#[rustler::nif(schedule = "DirtyCpu")]
fn tec_grid_tec_xyz_prepare<'a>(
    env: Env<'a>,
    handle: ResourceArc<TecGridResource>,
    unix_nanos: i64,
    satellite_xyz: Term<'a>,
    receiver_xyz: Term<'a>,
    options: TecGridXyzOptionsTerm<'a>,
) -> NifResult<Term<'a>> {
    let satellite_xyz = decode_transport_xyz(satellite_xyz, "satellite_xyz")?;
    let receiver_xyz = decode_transport_xyz(receiver_xyz, "receiver_xyz")?;
    let epoch = TecGridEpoch::new(unix_nanos, 0);
    let (options, policy) = apply_xyz_options(TecGridEvalOptions::l1(epoch), &options)?;
    Ok(
        match TecGridXyzConversion::prepare(options, &satellite_xyz, &receiver_xyz, policy) {
            Ok(conversion) => (atoms::ok(), tec_xyz_request(env, handle, conversion)).encode(env),
            Err(err) => (atoms::error(), tec_grid_error_to_term(env, err)).encode(env),
        },
    )
}

/// Answers the conversion a TEC stage asks for with `lonlatalt`,
/// `{lon_deg, lat_deg, alt}` of transported doubles, and continues the
/// evaluation on the grid the stage holds.
///
/// Returns `{:ok, {:convert, next_stage, xyz}}` when the answer held a NaN and
/// the core asks for the receiver, `{:ok, {:complete, evaluation}}` with
/// `value` `{vtec_tecu, stec_tecu}`, or `{:error, reason}`. A stage already
/// answered is refused as `:conversion_consumed`. An answer that is not three
/// transported doubles is refused before the stage is taken, and leaves it
/// unanswered.
///
/// Dirty-CPU: a concurrent resume of the same stage from another process
/// contends for its lock, and a dirty scheduler may wait on it where a normal
/// one must not.
#[rustler::nif(schedule = "DirtyCpu")]
fn tec_grid_tec_xyz_resume<'a>(
    env: Env<'a>,
    stage: ResourceArc<TecGridTecXyzStage>,
    lonlatalt: Term<'a>,
) -> NifResult<Term<'a>> {
    let lonlatalt = decode_conversion(lonlatalt)?;
    let Some(conversion) = take_conversion(&stage.conversion) else {
        return Ok((atoms::error(), atoms::conversion_consumed()).encode(env));
    };
    Ok(match conversion.resume(&stage.grid.grid, lonlatalt) {
        Ok(TecGridXyzStep::Convert(next)) => {
            (atoms::ok(), tec_xyz_request(env, stage.grid.clone(), next)).encode(env)
        }
        Ok(TecGridXyzStep::Complete(evaluation)) => (
            atoms::ok(),
            (atoms::complete(), tec_evaluation_to_term(evaluation)),
        )
            .encode(env),
        Err(err) => (atoms::error(), tec_grid_error_to_term(env, err)).encode(env),
    })
}

/// Prepares an ionospheric group-delay evaluation on a standalone grid for a
/// caller that converts the ECEF positions it asks about itself.
///
/// As `tec_grid_tec_xyz_prepare`, with the carrier `frequency_hz`, a
/// transported double in hertz. [`TecGridDelayXyzConversion::prepare`] checks
/// the frequency before the geometry, as `iono_delay_xyz_with_policy` does.
/// Dirty-CPU, as are the steps that continue it.
#[rustler::nif(schedule = "DirtyCpu")]
fn tec_grid_iono_delay_xyz_prepare<'a>(
    env: Env<'a>,
    handle: ResourceArc<TecGridResource>,
    unix_nanos: i64,
    frequency_hz: Term<'a>,
    satellite_xyz: Term<'a>,
    receiver_xyz: Term<'a>,
    options: TecGridXyzOptionsTerm<'a>,
) -> NifResult<Term<'a>> {
    let frequency_hz = decode_transport(frequency_hz, "frequency_hz")?;
    let satellite_xyz = decode_transport_xyz(satellite_xyz, "satellite_xyz")?;
    let receiver_xyz = decode_transport_xyz(receiver_xyz, "receiver_xyz")?;
    let epoch = TecGridEpoch::new(unix_nanos, 0);
    let (options, policy) =
        apply_xyz_options(TecGridEvalOptions::new(epoch, frequency_hz), &options)?;
    Ok(
        match TecGridDelayXyzConversion::prepare(options, &satellite_xyz, &receiver_xyz, policy) {
            Ok(conversion) => (atoms::ok(), delay_xyz_request(env, handle, conversion)).encode(env),
            Err(err) => (atoms::error(), tec_grid_error_to_term(env, err)).encode(env),
        },
    )
}

/// As `tec_grid_tec_xyz_resume`, for a group-delay stage; a finished
/// evaluation's `value` is the delay in meters.
///
/// Dirty-CPU for the same reason as `tec_grid_tec_xyz_resume`.
#[rustler::nif(schedule = "DirtyCpu")]
fn tec_grid_iono_delay_xyz_resume<'a>(
    env: Env<'a>,
    stage: ResourceArc<TecGridDelayXyzStage>,
    lonlatalt: Term<'a>,
) -> NifResult<Term<'a>> {
    let lonlatalt = decode_conversion(lonlatalt)?;
    let Some(conversion) = take_conversion(&stage.conversion) else {
        return Ok((atoms::error(), atoms::conversion_consumed()).encode(env));
    };
    Ok(match conversion.resume(&stage.grid.grid, lonlatalt) {
        Ok(TecGridDelayXyzStep::Convert(next)) => (
            atoms::ok(),
            delay_xyz_request(env, stage.grid.clone(), next),
        )
            .encode(env),
        Ok(TecGridDelayXyzStep::Complete(evaluation)) => (
            atoms::ok(),
            (atoms::complete(), delay_evaluation_to_term(evaluation)),
        )
            .encode(env),
        Err(err) => (atoms::error(), tec_grid_error_to_term(env, err)).encode(env),
    })
}

/// Build a [`NequickGRayEval`] from the boundary scalar fields.
///
/// The full NeQuick-G integration consumes the reference algorithm's own native
/// units directly (degree longitudes/latitudes, metre heights, month `1..=12`,
/// and UTC hours), so this is a pure field copy with no conversion.
#[allow(clippy::too_many_arguments)]
fn nequick_g_ray(
    month: u8,
    utc_hours: f64,
    station_lon_deg: f64,
    station_lat_deg: f64,
    station_height_m: f64,
    satellite_lon_deg: f64,
    satellite_lat_deg: f64,
    satellite_height_m: f64,
) -> NequickGRayEval {
    NequickGRayEval {
        month,
        utc_hours,
        station_lon_deg,
        station_lat_deg,
        station_height_m,
        satellite_lon_deg,
        satellite_lat_deg,
        satellite_height_m,
    }
}

/// Galileo NeQuick-G full three-dimensional slant total electron content (TECU).
///
/// Pure glue over `sidereon_core::atmosphere::ionosphere::nequick_g_stec_tecu`:
/// the `ai0`/`ai1`/`ai2` broadcast effective-ionisation coefficients drive the
/// NeQuick 2 profiler integrated along the full receiver-to-satellite ray. This
/// is the reference-grade companion to the compact `galileo_nequick_g_delay`
/// single-layer helper, so it takes both endpoints' geodetic positions rather
/// than an azimuth/elevation pair. No unit conversion happens at this boundary.
#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
fn nequick_g_stec_tecu(
    ai0: f64,
    ai1: f64,
    ai2: f64,
    month: u8,
    utc_hours: f64,
    station_lon_deg: f64,
    station_lat_deg: f64,
    station_height_m: f64,
    satellite_lon_deg: f64,
    satellite_lat_deg: f64,
    satellite_height_m: f64,
) -> NifResult<f64> {
    let coeffs = GalileoNequickCoeffs { ai0, ai1, ai2 };
    let ray = nequick_g_ray(
        month,
        utc_hours,
        station_lon_deg,
        station_lat_deg,
        station_height_m,
        satellite_lon_deg,
        satellite_lat_deg,
        satellite_height_m,
    );
    core_nequick_g_stec_tecu(&coeffs, &ray).map_err(crate::errors::invalid_input)
}

/// Galileo NeQuick-G full slant ionospheric group delay (positive metres).
///
/// Pure glue over `sidereon_core::atmosphere::ionosphere::nequick_g_delay_m`:
/// the full 3D slant TEC mapped to a dispersive group delay on `frequency_hz`.
#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
fn nequick_g_delay_m(
    ai0: f64,
    ai1: f64,
    ai2: f64,
    month: u8,
    utc_hours: f64,
    station_lon_deg: f64,
    station_lat_deg: f64,
    station_height_m: f64,
    satellite_lon_deg: f64,
    satellite_lat_deg: f64,
    satellite_height_m: f64,
    frequency_hz: f64,
) -> NifResult<f64> {
    let coeffs = GalileoNequickCoeffs { ai0, ai1, ai2 };
    let ray = nequick_g_ray(
        month,
        utc_hours,
        station_lon_deg,
        station_lat_deg,
        station_height_m,
        satellite_lon_deg,
        satellite_lat_deg,
        satellite_height_m,
    );
    core_nequick_g_delay_m(&coeffs, &ray, frequency_hz).map_err(crate::errors::invalid_input)
}
