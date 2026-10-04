//! Pure Rustler glue for the Sun/Moon ephemeris and solid-earth-tide kernels.
//!
//! No domain formula lives here: the analytic Sun/Moon positions are computed by
//! `sidereon_core::astro::bodies::sun_moon_ecef` and the tidal displacement by
//! `sidereon_core::tides::solid_earth_tide`. These entry points decode the
//! Elixir terms, build the crate `TimeScales`, call the crate functions, and
//! encode the results back.

use chrono::{DateTime, Datelike, Timelike, Utc};
use rustler::{Encoder, Env, Error, NifResult, Term};

use rustler::NifMap;
use sidereon_core::astro::bodies::{sun_moon_ecef, sun_moon_eci_at};
use sidereon_core::astro::time::eop::ValidityMode;
use sidereon_core::astro::time::scales::TimeScales;
use sidereon_core::frame::Wgs84Geodetic;
use sidereon_core::tides::{
    ocean_tide_loading, solid_earth_pole_tide, solid_earth_tide_with_constants,
    station_displacement_ecef_m_batch_with_validity, station_displacement_ecef_m_with_validity,
    OceanLoadingBlq, StationDisplacementEpoch, StationDisplacementOptions,
    StationDisplacementPosition, StationTideConstants,
};

type DateTuple = (i32, i32, i32);
type TimeTuple = (i32, i32, i32, i32);
type Vec3 = (f64, f64, f64);

mod atoms {
    rustler::atoms! { ok, error }
}

#[derive(Debug, NifMap)]
pub(crate) struct StationDisplacementRequest {
    pub position_kind: String,
    pub position: Vec<f64>,
    pub year: i64,
    pub month: i64,
    pub day: i64,
    pub hour: i64,
    pub minute: i64,
    pub second: f64,
    pub polar_motion_arcsec: Option<Vec<f64>>,
    pub solid_earth_tide: bool,
    pub pole_tide: bool,
    pub ocean_loading_amplitude_m: Option<Vec<Vec<f64>>>,
    pub ocean_loading_phase_deg: Option<Vec<Vec<f64>>>,
    pub tide_constants: String,
    pub validity: String,
}

#[derive(Debug, NifMap)]
pub(crate) struct StationDisplacementResult {
    pub ecef_m: Vec<f64>,
    pub solid_earth_tide_ecef_m: Option<Vec<f64>>,
    pub pole_tide_ecef_m: Option<Vec<f64>>,
    pub ocean_loading_ecef_m: Option<Vec<f64>>,
    pub valid: bool,
    pub degraded: Option<String>,
}

pub(crate) fn station_displacement_impl<'a>(
    env: Env<'a>,
    request: StationDisplacementRequest,
) -> Term<'a> {
    match station_displacement_result(request) {
        Ok(result) => (atoms::ok(), result).encode(env),
        Err(StationDisplacementFailure::Tide(error)) => {
            (atoms::error(), TideErrorFields::from(error)).encode(env)
        }
        Err(StationDisplacementFailure::Binding(detail)) => (
            atoms::error(),
            TideErrorFields {
                variant: "invalid_request".into(),
                field: None,
                kind: None,
                source: None,
                line: None,
                detail_variant: Some(detail),
                block: None,
                station: None,
                token: None,
                constituent: None,
                expected: None,
                found: None,
                index: None,
                row: None,
            },
        )
            .encode(env),
    }
}

pub(crate) fn station_displacement_batch_impl<'a>(
    env: Env<'a>,
    requests: Vec<StationDisplacementRequest>,
) -> Term<'a> {
    if requests.is_empty() {
        return (atoms::ok(), Vec::<Term<'a>>::new()).encode(env);
    }

    if requests
        .iter()
        .skip(1)
        .any(|request| !same_batch_options(&requests[0], request))
    {
        let fields = binding_tide_error("inconsistent_batch_options");
        let rows = (0..requests.len())
            .map(|_| (atoms::error(), fields.clone()).encode(env))
            .collect::<Vec<_>>();
        return (atoms::ok(), rows).encode(env);
    }

    let first = &requests[0];
    let shared = station_batch_shared(first);
    let (position, ocean_loading, tide_constants, validity) = match shared {
        Ok(shared) => shared,
        Err(error) => {
            let fields = station_failure_fields(error);
            let rows = (0..requests.len())
                .map(|_| (atoms::error(), fields.clone()).encode(env))
                .collect::<Vec<_>>();
            return (atoms::ok(), rows).encode(env);
        }
    };

    let mut options = StationDisplacementOptions::default();
    options.solid_earth_tide = first.solid_earth_tide;
    options.pole_tide = first.pole_tide;
    options.ocean_loading = ocean_loading.as_ref();
    options.solid_earth_tide_constants = tide_constants;
    let mut epochs = Vec::with_capacity(requests.len());
    let mut failures = Vec::with_capacity(requests.len());
    for request in &requests {
        match station_epoch(request) {
            Ok(epoch) => {
                epochs.push(Some(epoch));
                failures.push(None);
            }
            Err(error) => {
                epochs.push(None);
                failures.push(Some(station_failure_fields(error)));
            }
        }
    }

    let valid_epochs = epochs.into_iter().flatten().collect::<Vec<_>>();
    let results =
        station_displacement_ecef_m_batch_with_validity(position, &valid_epochs, options, validity);
    let mut results = results.into_iter();
    let rows = failures
        .into_iter()
        .map(|failure| match failure {
            Some(fields) => (atoms::error(), fields).encode(env),
            None => match results.next() {
                Some(Ok(result)) => (atoms::ok(), station_displacement_output(result)).encode(env),
                Some(Err(error)) => (atoms::error(), TideErrorFields::from(error)).encode(env),
                None => (atoms::error(), binding_tide_error("batch_result_mismatch")).encode(env),
            },
        })
        .collect::<Vec<_>>();
    (atoms::ok(), rows).encode(env)
}

fn same_batch_options(
    left: &StationDisplacementRequest,
    right: &StationDisplacementRequest,
) -> bool {
    left.position_kind == right.position_kind
        && left.position == right.position
        && left.solid_earth_tide == right.solid_earth_tide
        && left.pole_tide == right.pole_tide
        && left.ocean_loading_amplitude_m == right.ocean_loading_amplitude_m
        && left.ocean_loading_phase_deg == right.ocean_loading_phase_deg
        && left.tide_constants == right.tide_constants
        && left.validity == right.validity
}

fn station_batch_shared(
    request: &StationDisplacementRequest,
) -> Result<
    (
        StationDisplacementPosition,
        Option<OceanLoadingBlq>,
        StationTideConstants,
        ValidityMode,
    ),
    StationDisplacementFailure,
> {
    let position = station_position(request)?;
    let tide_constants = station_tide_constants(request)?;
    let validity = station_validity(request)?;
    let ocean_loading = match (
        request.ocean_loading_amplitude_m.clone(),
        request.ocean_loading_phase_deg.clone(),
    ) {
        (Some(amplitude_m), Some(phase_deg)) => Some(ocean_loading_blq(amplitude_m, phase_deg)?),
        (None, None) => None,
        _ => {
            return Err(StationDisplacementFailure::Binding(
                "incomplete_ocean_loading".into(),
            ))
        }
    };
    Ok((position, ocean_loading, tide_constants, validity))
}

fn station_position(
    request: &StationDisplacementRequest,
) -> Result<StationDisplacementPosition, StationDisplacementFailure> {
    match request.position_kind.as_str() {
        "ecef" => Ok(StationDisplacementPosition::from_ecef_m(fixed_vec3(
            request.position.clone(),
            "position",
        )?)?),
        "geodetic" => {
            let coordinates = fixed_vec3(request.position.clone(), "position")?;
            Ok(StationDisplacementPosition::Geodetic(
                Wgs84Geodetic::new(coordinates[0], coordinates[1], coordinates[2])
                    .map_err(|_| invalid_tide_input("position", "invalid_geodetic"))?,
            ))
        }
        _ => Err(StationDisplacementFailure::Binding(
            "invalid_position_kind".into(),
        )),
    }
}

fn station_tide_constants(
    request: &StationDisplacementRequest,
) -> Result<StationTideConstants, StationDisplacementFailure> {
    match request.tide_constants.as_str() {
        "conventions" => Ok(StationTideConstants::Conventions),
        "iers_routine" => Ok(StationTideConstants::IersRoutine),
        _ => Err(StationDisplacementFailure::Binding(
            "invalid_tide_constants".into(),
        )),
    }
}

fn station_validity(
    request: &StationDisplacementRequest,
) -> Result<ValidityMode, StationDisplacementFailure> {
    match request.validity.as_str() {
        "strict" => Ok(ValidityMode::Strict),
        "permissive" => Ok(ValidityMode::Permissive),
        _ => Err(StationDisplacementFailure::Binding(
            "invalid_validity".into(),
        )),
    }
}

fn station_epoch(
    request: &StationDisplacementRequest,
) -> Result<StationDisplacementEpoch, StationDisplacementFailure> {
    let mut epoch = StationDisplacementEpoch::from_utc(
        i32::try_from(request.year).map_err(|_| invalid_tide_input("year", "out_of_range"))?,
        u8::try_from(request.month).map_err(|_| invalid_tide_input("month", "out_of_range"))?,
        u8::try_from(request.day).map_err(|_| invalid_tide_input("day", "out_of_range"))?,
        u8::try_from(request.hour).map_err(|_| invalid_tide_input("hour", "out_of_range"))?,
        u8::try_from(request.minute).map_err(|_| invalid_tide_input("minute", "out_of_range"))?,
        request.second,
    );
    if let Some(polar_motion) = request.polar_motion_arcsec.clone() {
        let polar_motion = fixed_vec2(polar_motion, "polar_motion_arcsec")?;
        epoch = epoch.with_polar_motion_arcsec(polar_motion[0], polar_motion[1]);
    }
    Ok(epoch)
}

fn station_failure_fields(error: StationDisplacementFailure) -> TideErrorFields {
    match error {
        StationDisplacementFailure::Tide(error) => TideErrorFields::from(error),
        StationDisplacementFailure::Binding(detail) => binding_tide_error(&detail),
    }
}

fn binding_tide_error(detail: &str) -> TideErrorFields {
    TideErrorFields {
        variant: "invalid_request".into(),
        field: None,
        kind: None,
        source: None,
        line: None,
        detail_variant: Some(detail.into()),
        block: None,
        station: None,
        token: None,
        constituent: None,
        expected: None,
        found: None,
        index: None,
        row: None,
    }
}

fn station_displacement_output(
    result: sidereon_core::astro::time::Validated<sidereon_core::tides::StationDisplacement>,
) -> StationDisplacementResult {
    StationDisplacementResult {
        ecef_m: result.value.ecef_m.to_vec(),
        solid_earth_tide_ecef_m: result
            .value
            .solid_earth_tide_ecef_m
            .map(|value| value.to_vec()),
        pole_tide_ecef_m: result.value.pole_tide_ecef_m.map(|value| value.to_vec()),
        ocean_loading_ecef_m: result
            .value
            .ocean_loading_ecef_m
            .map(|value| value.to_vec()),
        valid: result.is_valid(),
        degraded: result.degraded.map(|reason| match reason {
            sidereon_core::astro::time::DegradeReason::BeforeCoverage => "before_coverage".into(),
            sidereon_core::astro::time::DegradeReason::AfterCoverage => "after_coverage".into(),
        }),
    }
}

fn station_displacement_result(
    request: StationDisplacementRequest,
) -> Result<StationDisplacementResult, StationDisplacementFailure> {
    let position = match request.position_kind.as_str() {
        "ecef" => {
            StationDisplacementPosition::from_ecef_m(fixed_vec3(request.position, "position")?)?
        }
        "geodetic" => {
            let coordinates = fixed_vec3(request.position, "position")?;
            StationDisplacementPosition::Geodetic(
                Wgs84Geodetic::new(coordinates[0], coordinates[1], coordinates[2])
                    .map_err(|_| invalid_tide_input("position", "invalid_geodetic"))?,
            )
        }
        _ => {
            return Err(StationDisplacementFailure::Binding(
                "invalid_position_kind".into(),
            ))
        }
    };
    let mut epoch = StationDisplacementEpoch::from_utc(
        i32::try_from(request.year).map_err(|_| invalid_tide_input("year", "out_of_range"))?,
        u8::try_from(request.month).map_err(|_| invalid_tide_input("month", "out_of_range"))?,
        u8::try_from(request.day).map_err(|_| invalid_tide_input("day", "out_of_range"))?,
        u8::try_from(request.hour).map_err(|_| invalid_tide_input("hour", "out_of_range"))?,
        u8::try_from(request.minute).map_err(|_| invalid_tide_input("minute", "out_of_range"))?,
        request.second,
    );
    if let Some(polar_motion) = request.polar_motion_arcsec {
        let polar_motion = fixed_vec2(polar_motion, "polar_motion_arcsec")?;
        epoch = epoch.with_polar_motion_arcsec(polar_motion[0], polar_motion[1]);
    }
    let tide_constants = match request.tide_constants.as_str() {
        "conventions" => StationTideConstants::Conventions,
        "iers_routine" => StationTideConstants::IersRoutine,
        _ => {
            return Err(StationDisplacementFailure::Binding(
                "invalid_tide_constants".into(),
            ))
        }
    };
    let validity = match request.validity.as_str() {
        "strict" => ValidityMode::Strict,
        "permissive" => ValidityMode::Permissive,
        _ => {
            return Err(StationDisplacementFailure::Binding(
                "invalid_validity".into(),
            ))
        }
    };
    let ocean_loading = match (
        request.ocean_loading_amplitude_m,
        request.ocean_loading_phase_deg,
    ) {
        (Some(amplitude_m), Some(phase_deg)) => Some(ocean_loading_blq(amplitude_m, phase_deg)?),
        (None, None) => None,
        _ => {
            return Err(StationDisplacementFailure::Binding(
                "incomplete_ocean_loading".into(),
            ))
        }
    };
    let mut options = StationDisplacementOptions::default();
    options.solid_earth_tide = request.solid_earth_tide;
    options.pole_tide = request.pole_tide;
    options.ocean_loading = ocean_loading.as_ref();
    options.solid_earth_tide_constants = tide_constants;
    let result = station_displacement_ecef_m_with_validity(position, epoch, options, validity)?;
    Ok(StationDisplacementResult {
        ecef_m: result.value.ecef_m.to_vec(),
        solid_earth_tide_ecef_m: result
            .value
            .solid_earth_tide_ecef_m
            .map(|value| value.to_vec()),
        pole_tide_ecef_m: result.value.pole_tide_ecef_m.map(|value| value.to_vec()),
        ocean_loading_ecef_m: result
            .value
            .ocean_loading_ecef_m
            .map(|value| value.to_vec()),
        valid: result.is_valid(),
        degraded: result.degraded.map(|reason| match reason {
            sidereon_core::astro::time::DegradeReason::BeforeCoverage => {
                "before_coverage".to_string()
            }
            sidereon_core::astro::time::DegradeReason::AfterCoverage => {
                "after_coverage".to_string()
            }
        }),
    })
}

#[derive(Debug, Clone, rustler::NifMap)]
struct TideErrorFields {
    variant: String,
    field: Option<String>,
    kind: Option<String>,
    source: Option<String>,
    line: Option<u64>,
    detail_variant: Option<String>,
    block: Option<u64>,
    station: Option<String>,
    token: Option<String>,
    constituent: Option<String>,
    expected: Option<u64>,
    found: Option<u64>,
    index: Option<u64>,
    row: Option<u64>,
}

impl From<sidereon_core::tides::TideError> for TideErrorFields {
    fn from(error: sidereon_core::tides::TideError) -> Self {
        use sidereon_core::tides::{TideError, TideInputErrorKind};
        let mut fields = Self {
            variant: String::new(),
            field: None,
            kind: None,
            source: None,
            line: None,
            detail_variant: None,
            block: None,
            station: None,
            token: None,
            constituent: None,
            expected: None,
            found: None,
            index: None,
            row: None,
        };
        match error {
            TideError::InvalidInput { field, kind } => {
                fields.variant = "invalid_input".into();
                fields.field = Some(field.into());
                fields.kind = Some(
                    match kind {
                        TideInputErrorKind::Missing => "missing",
                        TideInputErrorKind::NonFinite => "non_finite",
                        TideInputErrorKind::NotPositive => "not_positive",
                        TideInputErrorKind::Negative => "negative",
                        TideInputErrorKind::OutOfRange => "out_of_range",
                        TideInputErrorKind::FloatParse => "float_parse",
                        TideInputErrorKind::IntParse => "int_parse",
                        TideInputErrorKind::InvalidCivilDate => "invalid_civil_date",
                        TideInputErrorKind::InvalidCivilTime => "invalid_civil_time",
                    }
                    .into(),
                );
            }
            TideError::TimeScale(error) => {
                fields.variant = "time_scale".into();
                match error {
                    sidereon_core::astro::time::CoverageError::InvalidInput { field, kind } => {
                        fields.field = Some(field.into());
                        fields.kind = Some(match kind {
                            sidereon_core::astro::time::TimeScaleInputErrorKind::Missing => "missing",
                            sidereon_core::astro::time::TimeScaleInputErrorKind::NonFinite => "non_finite",
                            sidereon_core::astro::time::TimeScaleInputErrorKind::NotPositive => "not_positive",
                            sidereon_core::astro::time::TimeScaleInputErrorKind::Negative => "negative",
                            sidereon_core::astro::time::TimeScaleInputErrorKind::OutOfRange => "out_of_range",
                            sidereon_core::astro::time::TimeScaleInputErrorKind::FloatParse => "float_parse",
                            sidereon_core::astro::time::TimeScaleInputErrorKind::IntParse => "int_parse",
                            sidereon_core::astro::time::TimeScaleInputErrorKind::InvalidCivilDate => "invalid_civil_date",
                            sidereon_core::astro::time::TimeScaleInputErrorKind::InvalidCivilTime => "invalid_civil_time",
                        }.into());
                    }
                    sidereon_core::astro::time::CoverageError::OutsideCoverage(reason) => {
                        fields.detail_variant = Some(
                            match reason {
                                sidereon_core::astro::time::DegradeReason::BeforeCoverage => {
                                    "before_coverage"
                                }
                                sidereon_core::astro::time::DegradeReason::AfterCoverage => {
                                    "after_coverage"
                                }
                            }
                            .into(),
                        );
                    }
                }
            }
            TideError::FrameTransform(error) => {
                fields.variant = "frame_transform".into();
                match error {
                    sidereon_core::astro::frames::transforms::FrameTransformError::InvalidInput { field, reason } => {
                        fields.field = Some(field.into());
                        fields.kind = Some(reason.into());
                    }
                    sidereon_core::astro::frames::transforms::FrameTransformError::Ut1OutsideCoverage { reason } => {
                        fields.detail_variant = Some(match reason {
                            sidereon_core::astro::time::DegradeReason::BeforeCoverage => "before_coverage",
                            sidereon_core::astro::time::DegradeReason::AfterCoverage => "after_coverage",
                        }.into());
                    }
                }
            }
            TideError::SunMoon(error) => {
                fields.variant = "sun_moon".into();
                match error {
                    sidereon_core::astro::bodies::SunMoonError::InvalidInput { field, reason } => {
                        fields.field = Some(field.into());
                        fields.kind = Some(reason.into());
                    }
                    sidereon_core::astro::bodies::SunMoonError::FrameTransform(error) => {
                        fields.source = Some("frame_transform".into());
                        let nested = TideError::FrameTransform(error);
                        let nested_fields = Self::from(nested);
                        fields.field = nested_fields.field;
                        fields.kind = nested_fields.kind;
                        fields.detail_variant = nested_fields.detail_variant;
                    }
                }
            }
            TideError::MissingInput { field } => {
                fields.variant = "missing_input".into();
                fields.field = Some(field.into());
            }
            TideError::BlqParse { line, kind } => {
                fields.variant = "blq_parse".into();
                fields.line = u64::try_from(line).ok();
                set_blq_parse_payload(&mut fields, kind);
            }
            TideError::BlqWrite { block, kind } => {
                fields.variant = "blq_write".into();
                fields.block = u64::try_from(block).ok();
                set_blq_write_payload(&mut fields, kind);
            }
        }
        fields
    }
}

fn set_blq_parse_payload(
    fields: &mut TideErrorFields,
    kind: sidereon_core::tides::BlqParseErrorKind,
) {
    use sidereon_core::tides::BlqParseErrorKind as ParseKind;
    match kind {
        ParseKind::Empty => fields.detail_variant = Some("empty".into()),
        ParseKind::MissingStation => fields.detail_variant = Some("missing_station".into()),
        ParseKind::MissingCoefficientRows {
            station,
            expected,
            found,
        } => {
            fields.detail_variant = Some("missing_coefficient_rows".into());
            fields.station = Some(station);
            fields.expected = u64::try_from(expected).ok();
            fields.found = u64::try_from(found).ok();
        }
        ParseKind::TooManyCoefficientRows { station } => {
            fields.detail_variant = Some("too_many_coefficient_rows".into());
            fields.station = Some(station);
        }
        ParseKind::WrongColumnCount { expected, found } => {
            fields.detail_variant = Some("wrong_column_count".into());
            fields.expected = u64::try_from(expected).ok();
            fields.found = u64::try_from(found).ok();
        }
        ParseKind::InvalidNumber { token } => {
            fields.detail_variant = Some("invalid_number".into());
            fields.token = Some(token);
        }
        ParseKind::NonFiniteNumber { token } => {
            fields.detail_variant = Some("non_finite_number".into());
            fields.token = Some(token);
        }
        ParseKind::UnsupportedConstituent { constituent } => {
            fields.detail_variant = Some("unsupported_constituent".into());
            fields.constituent = Some(constituent);
        }
        ParseKind::DuplicateConstituent { constituent } => {
            fields.detail_variant = Some("duplicate_constituent".into());
            fields.constituent = Some(constituent);
        }
        ParseKind::MultipleBlocks { found } => {
            fields.detail_variant = Some("multiple_blocks".into());
            fields.found = u64::try_from(found).ok();
        }
    }
}

fn set_blq_write_payload(
    fields: &mut TideErrorFields,
    kind: sidereon_core::tides::BlqWriteErrorKind,
) {
    use sidereon_core::tides::BlqWriteErrorKind as WriteKind;
    match kind {
        WriteKind::EmptyStation => fields.detail_variant = Some("empty_station".into()),
        WriteKind::StationLineBreak => fields.detail_variant = Some("station_line_break".into()),
        WriteKind::StationSurroundingWhitespace => {
            fields.detail_variant = Some("station_surrounding_whitespace".into())
        }
        WriteKind::StationReadsAsComment => {
            fields.detail_variant = Some("station_reads_as_comment".into())
        }
        WriteKind::StationReadsAsHeader => {
            fields.detail_variant = Some("station_reads_as_header".into())
        }
        WriteKind::StationReadsAsCoefficientRow => {
            fields.detail_variant = Some("station_reads_as_coefficient_row".into())
        }
        WriteKind::NonFiniteCoefficient { row, constituent } => {
            fields.detail_variant = Some("non_finite_coefficient".into());
            fields.row = u64::try_from(row).ok();
            fields.constituent = Some(constituent.label().into());
        }
        WriteKind::CommentLineBreak { index } => {
            fields.detail_variant = Some("comment_line_break".into());
            fields.index = u64::try_from(index).ok();
        }
        WriteKind::NotACommentLine { index } => {
            fields.detail_variant = Some("not_a_comment_line".into());
            fields.index = u64::try_from(index).ok();
        }
        WriteKind::CommentPlacementOutOfRange { index } => {
            fields.detail_variant = Some("comment_placement_out_of_range".into());
            fields.index = u64::try_from(index).ok();
        }
        WriteKind::InvalidHeader { index, kind } => {
            fields.detail_variant = Some("invalid_header".into());
            fields.index = u64::try_from(index).ok();
            set_blq_parse_payload(fields, kind);
            fields.source = fields
                .detail_variant
                .take()
                .map(|nested| format!("blq_parse:{nested}"));
            fields.detail_variant = Some("invalid_header".into());
        }
        WriteKind::AfterRowsBeforeAnotherBlock { index } => {
            fields.detail_variant = Some("after_rows_before_another_block".into());
            fields.index = u64::try_from(index).ok();
        }
        WriteKind::CommentsOutOfPlacementOrder { index } => {
            fields.detail_variant = Some("comments_out_of_placement_order".into());
            fields.index = u64::try_from(index).ok();
        }
    }
}

fn invalid_tide_input(
    field: &'static str,
    reason: &'static str,
) -> sidereon_core::tides::TideError {
    sidereon_core::tides::TideError::InvalidInput {
        field,
        kind: if reason == "out_of_range" || reason == "invalid_geodetic" {
            sidereon_core::tides::TideInputErrorKind::OutOfRange
        } else {
            sidereon_core::tides::TideInputErrorKind::InvalidCivilDate
        },
    }
}

enum StationDisplacementFailure {
    Tide(sidereon_core::tides::TideError),
    Binding(String),
}

impl From<sidereon_core::tides::TideError> for StationDisplacementFailure {
    fn from(error: sidereon_core::tides::TideError) -> Self {
        Self::Tide(error)
    }
}

impl From<Error> for StationDisplacementFailure {
    fn from(error: Error) -> Self {
        Self::Binding(match error {
            Error::Term(_) => "invalid_request".into(),
            _ => "term_decode".into(),
        })
    }
}

fn fixed_vec3(values: Vec<f64>, field: &'static str) -> NifResult<[f64; 3]> {
    if values.len() != 3 {
        return Err(Error::Term(Box::new(format!(
            "{field} must have three values"
        ))));
    }
    Ok([values[0], values[1], values[2]])
}

fn fixed_vec2(values: Vec<f64>, field: &'static str) -> NifResult<[f64; 2]> {
    if values.len() != 2 {
        return Err(Error::Term(Box::new(format!(
            "{field} must have two values"
        ))));
    }
    Ok([values[0], values[1]])
}

fn parse_datetime_tuple(term: Term) -> NifResult<(i32, i32, i32, i32, i32, i32, i32)> {
    let (date, time): (DateTuple, TimeTuple) = term.decode()?;
    Ok((date.0, date.1, date.2, time.0, time.1, time.2, time.3))
}

/// Geocentric Sun and Moon positions in ECEF (m) for a UTC instant.
/// Returns `({sun_x, sun_y, sun_z}, {moon_x, moon_y, moon_z})`.
pub(crate) fn sun_moon_ecef_impl(datetime_tuple: Term) -> NifResult<(Vec3, Vec3)> {
    let (year, month, day, hour, minute, second, microsecond) =
        parse_datetime_tuple(datetime_tuple)?;
    let second_with_micro = second as f64 + microsecond as f64 / 1_000_000.0;
    let ts = TimeScales::from_utc(year, month, day, hour, minute, second_with_micro)
        .map_err(crate::errors::invalid_input)?;
    let sm = sun_moon_ecef(&ts).map_err(crate::errors::invalid_input)?;
    Ok((
        (sm.sun[0], sm.sun[1], sm.sun[2]),
        (sm.moon[0], sm.moon[1], sm.moon[2]),
    ))
}

/// Batch geocentric Sun and Moon positions in ECI (m) for UTC Unix microseconds.
pub(crate) fn sun_moon_eci_batch_impl(
    epochs_unix_us: Vec<i64>,
) -> NifResult<(Vec<Vec3>, Vec<Vec3>)> {
    sun_moon_batch(epochs_unix_us, |ts| {
        sun_moon_eci_at(ts).map_err(crate::errors::invalid_input)
    })
}

/// Batch geocentric Sun and Moon positions in ECEF (m) for UTC Unix microseconds.
pub(crate) fn sun_moon_ecef_batch_impl(
    epochs_unix_us: Vec<i64>,
) -> NifResult<(Vec<Vec3>, Vec<Vec3>)> {
    sun_moon_batch(epochs_unix_us, |ts| {
        sun_moon_ecef(ts).map_err(crate::errors::invalid_input)
    })
}

fn sun_moon_batch<F>(epochs_unix_us: Vec<i64>, mut f: F) -> NifResult<(Vec<Vec3>, Vec<Vec3>)>
where
    F: FnMut(&TimeScales) -> NifResult<sidereon_core::astro::bodies::SunMoon>,
{
    if epochs_unix_us.is_empty() {
        return Err(Error::Term(Box::new("empty epochs")));
    }

    let mut sun = Vec::with_capacity(epochs_unix_us.len());
    let mut moon = Vec::with_capacity(epochs_unix_us.len());

    for epoch_us in epochs_unix_us {
        let ts = time_scales_from_unix_micros(epoch_us)?;
        let sm = f(&ts)?;
        sun.push((sm.sun[0], sm.sun[1], sm.sun[2]));
        moon.push((sm.moon[0], sm.moon[1], sm.moon[2]));
    }

    Ok((sun, moon))
}

fn time_scales_from_unix_micros(epoch_us: i64) -> NifResult<TimeScales> {
    let seconds = epoch_us.div_euclid(1_000_000);
    let micros = epoch_us.rem_euclid(1_000_000) as u32;
    let dt = DateTime::<Utc>::from_timestamp(seconds, micros * 1_000)
        .ok_or_else(|| Error::Term(Box::new("invalid Unix microsecond epoch")))?;
    TimeScales::from_utc(
        dt.year(),
        dt.month() as i32,
        dt.day() as i32,
        dt.hour() as i32,
        dt.minute() as i32,
        dt.second() as f64 + f64::from(dt.timestamp_subsec_micros()) / 1_000_000.0,
    )
    .map_err(crate::errors::invalid_input)
}

/// Solid-earth tide station displacement (m, ECEF), IERS DEHANTTIDEINEL derived
/// kernel. Sun and Moon geocentric positions are supplied by the caller (m).
#[allow(clippy::too_many_arguments)]
pub(crate) fn solid_earth_tide_impl(
    sta_x: f64,
    sta_y: f64,
    sta_z: f64,
    year: i32,
    month: i32,
    day: i32,
    fhr: f64,
    sun: Vec3,
    moon: Vec3,
    constants: &str,
) -> NifResult<Vec3> {
    let constants = match constants {
        "conventions" => StationTideConstants::Conventions,
        "iers_routine" => StationTideConstants::IersRoutine,
        _ => return Err(rustler::Error::BadArg),
    };
    let xsta = [sta_x, sta_y, sta_z];
    let xsun = [sun.0, sun.1, sun.2];
    let xmon = [moon.0, moon.1, moon.2];
    let d = solid_earth_tide_with_constants(&xsta, year, month, day, fhr, &xsun, &xmon, constants)
        .map_err(crate::errors::invalid_input)?;
    Ok((d[0], d[1], d[2]))
}

/// Solid-earth pole tide station displacement (m, ECEF).
#[allow(clippy::too_many_arguments)]
pub(crate) fn solid_earth_pole_tide_impl(
    sta_x: f64,
    sta_y: f64,
    sta_z: f64,
    year: i32,
    month: i32,
    day: i32,
    fhr: f64,
    xp_arcsec: f64,
    yp_arcsec: f64,
) -> NifResult<Vec3> {
    let xsta = [sta_x, sta_y, sta_z];
    let d = solid_earth_pole_tide(&xsta, year, month, day, fhr, xp_arcsec, yp_arcsec)
        .map_err(crate::errors::invalid_input)?;
    Ok((d[0], d[1], d[2]))
}

/// Ocean tide loading station displacement (m, ECEF).
#[allow(clippy::too_many_arguments)]
pub(crate) fn ocean_tide_loading_impl(
    sta_x: f64,
    sta_y: f64,
    sta_z: f64,
    year: i32,
    month: i32,
    day: i32,
    fhr: f64,
    amplitude_m: Vec<Vec<f64>>,
    phase_deg: Vec<Vec<f64>>,
) -> NifResult<Vec3> {
    let blq = ocean_loading_blq(amplitude_m, phase_deg)?;
    let xsta = [sta_x, sta_y, sta_z];
    let d = ocean_tide_loading(&xsta, year, month, day, fhr, &blq)
        .map_err(crate::errors::invalid_input)?;
    Ok((d[0], d[1], d[2]))
}

fn ocean_loading_blq(
    amplitude_m: Vec<Vec<f64>>,
    phase_deg: Vec<Vec<f64>>,
) -> NifResult<OceanLoadingBlq> {
    Ok(OceanLoadingBlq {
        amplitude_m: fixed_3x11(amplitude_m, "ocean loading amplitude")?,
        phase_deg: fixed_3x11(phase_deg, "ocean loading phase")?,
    })
}

fn fixed_3x11(rows: Vec<Vec<f64>>, field: &'static str) -> NifResult<[[f64; 11]; 3]> {
    if rows.len() != 3 || rows.iter().any(|row| row.len() != 11) {
        return Err(Error::Term(Box::new(format!("{field} must be 3x11"))));
    }

    let mut out = [[0.0_f64; 11]; 3];
    for (i, row) in rows.into_iter().enumerate() {
        for (j, value) in row.into_iter().enumerate() {
            out[i][j] = value;
        }
    }
    Ok(out)
}
