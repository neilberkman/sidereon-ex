//! Rustler boundary for ANTEX calibration products.
//!
//! This module is glue only: Elixir passes text, a product handle or the lookup
//! fields of an antenna block, the `sidereon-core` crate parses, selects and
//! interpolates, and the NIF encodes every record the core retains as plain
//! maps the Elixir wrapper turns into structs.

use rustler::{Atom, Encoder, Env, NifMap, NifResult, ResourceArc, Term};
use sidereon_core::antex::{
    Antenna, AntennaKind, Antex, AntexDateTime, AntexError, AntexHeader, Calibration, Frequency,
    FrequencyRms, OuterComment, PcvGrid, PcvSample, PcvType, SecondFraction, ZenithGrid,
};

/// Resource handle holding the parsed ANTEX product across NIF calls. The
/// writer, the validity lookups and the block order work on it, so every
/// antenna block, including earlier validity intervals of one id, stays
/// available.
pub struct AntexResource {
    pub antex: Antex,
}

#[rustler::resource_impl]
impl rustler::Resource for AntexResource {}

type Vec3 = (f64, f64, f64);

mod atoms {
    rustler::atoms! {
        ok,
        error,
        not_found,
        invalid_datetime,
        invalid_field,
        repeated_record,
        degenerate_grid,
        invalid_input,
        unknown_frequency,
        ambiguous_frequency,
        missing_pco,
        empty_pcv_grid,
        unwritable,
        receiver,
        satellite,
        absolute,
        relative,
        azi,
        noazi
    }
}

/// The parsed product: header, comments between blocks, every antenna block in
/// file order and the forgiving parse's skipped-record count.
#[derive(NifMap)]
struct ProductTerm {
    header: HeaderTerm,
    outer_comments: Vec<OuterCommentTerm>,
    blocks: Vec<AntennaTerm>,
    skipped_records: usize,
}

#[derive(NifMap)]
struct HeaderTerm {
    version: Option<VersionTerm>,
    pcv_type: Option<PcvTypeTerm>,
    comments: Vec<String>,
    end_of_header: bool,
}

#[derive(NifMap)]
struct VersionTerm {
    version: f64,
    system: Option<String>,
}

#[derive(NifMap)]
struct PcvTypeTerm {
    pcv_type: Atom,
    reference_antenna_type: String,
    reference_antenna_serial: String,
    reference_antenna: Option<String>,
}

#[derive(NifMap)]
struct OuterCommentTerm {
    blocks_before: usize,
    text: String,
}

#[derive(NifMap)]
struct AntennaTerm {
    id: String,
    kind: Atom,
    antenna_type: String,
    serial: String,
    leading_comments: Vec<String>,
    calibrations: Vec<CalibrationTerm>,
    dazi_deg: Option<f64>,
    zenith_grid: Option<ZenithGridTerm>,
    has_frequency_count: bool,
    sinex_code: Option<String>,
    valid_from: Option<EpochTerm>,
    valid_until: Option<EpochTerm>,
    comments: Vec<String>,
    frequencies: Vec<FrequencyTerm>,
}

#[derive(NifMap)]
struct CalibrationTerm {
    method: String,
    agency: String,
    antennas_calibrated: Option<u32>,
    date: String,
}

#[derive(NifMap)]
struct ZenithGridTerm {
    start_deg: f64,
    end_deg: f64,
    step_deg: f64,
}

/// A GPS-time validity bound with its exact fraction of a second,
/// `fraction_digits / 10^fraction_scale`.
#[derive(NifMap)]
struct EpochTerm {
    year: i32,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
    fraction_digits: u64,
    fraction_scale: u64,
}

#[derive(NifMap)]
struct FrequencyTerm {
    frequency: String,
    pco_m: Vec3,
    pcv_samples: Vec<SampleTerm>,
    rms: Option<RmsTerm>,
}

#[derive(NifMap)]
struct RmsTerm {
    pco_m: Option<Vec3>,
    pcv_samples: Vec<SampleTerm>,
}

#[derive(NifMap)]
struct SampleTerm {
    grid: Atom,
    azimuth_deg: Option<f64>,
    zenith_deg: f64,
    value_m: f64,
}

/// The fields of an antenna block a frequency, PCO or PCV lookup reads: its id,
/// its zenith grid and its frequency sections in file order. The Elixir
/// `Antenna` struct carries these under the same keys.
#[derive(NifMap)]
struct LookupAntennaTerm {
    id: String,
    zenith_grid: Option<ZenithGridTerm>,
    frequencies: Vec<FrequencyTerm>,
}

#[derive(NifMap)]
struct InvalidFieldTerm {
    antenna_id: Option<String>,
    record: String,
    field: String,
    value: String,
}

#[derive(NifMap)]
struct RepeatedRecordTerm {
    antenna_id: Option<String>,
    record: String,
}

#[derive(NifMap)]
struct DegenerateGridTerm {
    antenna_id: String,
    frequency: String,
    reason: String,
}

#[derive(NifMap)]
struct FieldReasonTerm {
    field: String,
    reason: String,
}

#[derive(NifMap)]
struct FrequencyRefTerm {
    antenna_id: String,
    frequency: String,
}

#[derive(NifMap)]
struct AmbiguousFrequencyTerm {
    antenna_id: String,
    frequency: String,
    sections: usize,
}

/// Parse ANTEX text: `{:ok, product, handle}` with every retained record, or
/// `{:error, reason}` with the typed [`AntexError`].
#[rustler::nif(schedule = "DirtyCpu")]
fn antex_parse<'a>(env: Env<'a>, text: String) -> Term<'a> {
    match Antex::parse(&text) {
        Ok(antex) => {
            let product = product_term(&antex);
            let handle = ResourceArc::new(AntexResource { antex });
            (atoms::ok(), product, handle).encode(env)
        }
        Err(err) => (atoms::error(), antex_error_term(env, err)).encode(env),
    }
}

/// Serialize the held ANTEX product back to ANTEX 1.4 text. Pure delegation to
/// `Antex::encode`; no formatting lives here.
///
/// The writer refuses a product it cannot state exactly rather than rounding
/// or dropping a value, so this is `{:ok, text}` or `{:error, reason}` with the
/// typed [`AntexError`].
#[rustler::nif(schedule = "DirtyCpu")]
fn antex_encode<'a>(env: Env<'a>, handle: ResourceArc<AntexResource>) -> Term<'a> {
    match handle.antex.encode() {
        Ok(text) => (atoms::ok(), text).encode(env),
        Err(err) => (atoms::error(), antex_error_term(env, err)).encode(env),
    }
}

/// The satellite antenna block for a PRN valid at an epoch, as its index in
/// file order: `{:ok, index}`, `{:error, :not_found}`, or
/// `{:error, :invalid_datetime}` for an epoch outside the GPS calendar.
#[rustler::nif]
fn antex_satellite_antenna<'a>(
    env: Env<'a>,
    handle: ResourceArc<AntexResource>,
    prn: String,
    epoch: EpochTerm,
) -> Term<'a> {
    let epoch = match decode_epoch(&epoch) {
        Ok(epoch) => epoch,
        Err(err) => return (atoms::error(), antex_error_term(env, err)).encode(env),
    };
    block_index_term(
        env,
        &handle.antex,
        handle.antex.satellite_antenna(&prn, epoch),
    )
}

/// The validity block of a `TYPE / SERIAL NO` id valid at an epoch, as its
/// index in file order, with the results of [`antex_satellite_antenna`].
#[rustler::nif]
fn antex_antenna_at<'a>(
    env: Env<'a>,
    handle: ResourceArc<AntexResource>,
    id: String,
    epoch: EpochTerm,
) -> Term<'a> {
    let epoch = match decode_epoch(&epoch) {
        Ok(epoch) => epoch,
        Err(err) => return (atoms::error(), antex_error_term(env, err)).encode(env),
    };
    block_index_term(env, &handle.antex, handle.antex.antenna_at(&id, epoch))
}

/// The frequency section a label selects, as its index in the block's
/// sections: `{:ok, index}` or `{:error, reason}`, refusing a label whose
/// sections differ as `:ambiguous_frequency`.
#[rustler::nif]
fn antex_frequency<'a>(
    env: Env<'a>,
    antenna: LookupAntennaTerm,
    frequency: String,
) -> NifResult<Term<'a>> {
    let antenna = decode_lookup_antenna(antenna)?;
    Ok(match antenna.frequency(&frequency) {
        Ok(found) => {
            let index = antenna
                .frequencies
                .iter()
                .position(|section| std::ptr::eq(section, found));
            match index {
                Some(index) => (atoms::ok(), index).encode(env),
                None => (atoms::error(), atoms::not_found()).encode(env),
            }
        }
        Err(err) => (atoms::error(), antex_error_term(env, err)).encode(env),
    })
}

#[rustler::nif]
fn antex_pco<'a>(
    env: Env<'a>,
    antenna: LookupAntennaTerm,
    frequency: String,
) -> NifResult<Term<'a>> {
    let antenna = decode_lookup_antenna(antenna)?;
    Ok(match antenna.pco(&frequency) {
        Ok(pco) => (atoms::ok(), array_to_vec3(pco)).encode(env),
        Err(err) => (atoms::error(), antex_error_term(env, err)).encode(env),
    })
}

#[rustler::nif]
fn antex_pcv<'a>(
    env: Env<'a>,
    antenna: LookupAntennaTerm,
    frequency: String,
    zenith_deg: f64,
    azimuth_deg: Option<f64>,
) -> NifResult<Term<'a>> {
    let antenna = decode_lookup_antenna(antenna)?;
    // The Sidereon public PCV contract clamps to the antenna grid rather than
    // rejecting out-of-range zeniths. The core `pcv` refuses a zenith outside
    // the declared `ZEN1..ZEN2` grid, so clamp a finite zenith into that grid
    // before delegating: at the grid boundary the core's own linear
    // interpolation returns the boundary sample value, reproducing the clamp
    // exactly. A block without a `ZEN1 / ZEN2 / DZEN` record has no grid to
    // clamp to, and non-finite zeniths fall through to the core rejection.
    let zenith_deg = match antenna.zenith_grid {
        Some(grid) if zenith_deg.is_finite() => zenith_deg.max(grid.start_deg).min(grid.end_deg),
        _ => zenith_deg,
    };
    Ok(match antenna.pcv(&frequency, zenith_deg, azimuth_deg) {
        Ok(value_m) => (atoms::ok(), value_m).encode(env),
        Err(err) => (atoms::error(), antex_error_term(env, err)).encode(env),
    })
}

fn block_index_term<'a>(env: Env<'a>, antex: &Antex, found: Option<&Antenna>) -> Term<'a> {
    let index = found.and_then(|found| {
        antex
            .antenna_blocks()
            .position(|block| std::ptr::eq(block, found))
    });
    match index {
        Some(index) => (atoms::ok(), index).encode(env),
        None => (atoms::error(), atoms::not_found()).encode(env),
    }
}

/// An ANTEX error with every field its variant carries, as `{tag, fields}` or
/// the bare tag for a variant with none. [`AntexError`] is exhaustive, so each
/// variant is named; none is reported under another's tag.
fn antex_error_term<'a>(env: Env<'a>, err: AntexError) -> Term<'a> {
    match err {
        AntexError::InvalidDateTime => atoms::invalid_datetime().encode(env),
        AntexError::InvalidField {
            antenna_id,
            record,
            field,
            value,
        } => (
            atoms::invalid_field(),
            InvalidFieldTerm {
                antenna_id,
                record: record.to_string(),
                field: field.to_string(),
                value,
            },
        )
            .encode(env),
        AntexError::RepeatedRecord { antenna_id, record } => (
            atoms::repeated_record(),
            RepeatedRecordTerm {
                antenna_id,
                record: record.to_string(),
            },
        )
            .encode(env),
        AntexError::DegenerateGrid {
            antenna_id,
            frequency,
            reason,
        } => (
            atoms::degenerate_grid(),
            DegenerateGridTerm {
                antenna_id,
                frequency,
                reason,
            },
        )
            .encode(env),
        AntexError::InvalidInput { field, reason } => (
            atoms::invalid_input(),
            FieldReasonTerm {
                field: field.to_string(),
                reason: reason.to_string(),
            },
        )
            .encode(env),
        AntexError::UnknownFrequency {
            antenna_id,
            frequency,
        } => (
            atoms::unknown_frequency(),
            FrequencyRefTerm {
                antenna_id,
                frequency,
            },
        )
            .encode(env),
        AntexError::AmbiguousFrequency {
            antenna_id,
            frequency,
            sections,
        } => (
            atoms::ambiguous_frequency(),
            AmbiguousFrequencyTerm {
                antenna_id,
                frequency,
                sections,
            },
        )
            .encode(env),
        AntexError::MissingPco {
            antenna_id,
            frequency,
        } => (
            atoms::missing_pco(),
            FrequencyRefTerm {
                antenna_id,
                frequency,
            },
        )
            .encode(env),
        AntexError::EmptyPcvGrid {
            antenna_id,
            frequency,
        } => (
            atoms::empty_pcv_grid(),
            FrequencyRefTerm {
                antenna_id,
                frequency,
            },
        )
            .encode(env),
        AntexError::Unwritable { field, reason } => (
            atoms::unwritable(),
            FieldReasonTerm {
                field: field.to_string(),
                reason,
            },
        )
            .encode(env),
    }
}

fn product_term(antex: &Antex) -> ProductTerm {
    ProductTerm {
        header: header_term(&antex.header),
        outer_comments: antex
            .outer_comments
            .iter()
            .map(outer_comment_term)
            .collect(),
        blocks: antex.antenna_blocks().map(antenna_term).collect(),
        skipped_records: antex.skipped_records(),
    }
}

fn header_term(header: &AntexHeader) -> HeaderTerm {
    HeaderTerm {
        version: header.version.map(|version| VersionTerm {
            version: version.version,
            system: version.system.map(String::from),
        }),
        pcv_type: header.pcv_type.as_ref().map(|record| PcvTypeTerm {
            pcv_type: match record.pcv_type {
                PcvType::Absolute => atoms::absolute(),
                PcvType::Relative => atoms::relative(),
            },
            reference_antenna_type: record.reference_antenna_type.clone(),
            reference_antenna_serial: record.reference_antenna_serial.clone(),
            reference_antenna: record.reference_antenna().map(String::from),
        }),
        comments: header.comments.clone(),
        end_of_header: header.end_of_header,
    }
}

fn outer_comment_term(comment: &OuterComment) -> OuterCommentTerm {
    OuterCommentTerm {
        blocks_before: comment.blocks_before,
        text: comment.text.clone(),
    }
}

fn antenna_term(antenna: &Antenna) -> AntennaTerm {
    AntennaTerm {
        id: antenna.id.clone(),
        kind: match antenna.kind {
            AntennaKind::Receiver => atoms::receiver(),
            AntennaKind::Satellite => atoms::satellite(),
        },
        antenna_type: antenna.antenna_type.clone(),
        serial: antenna.serial.clone(),
        leading_comments: antenna.leading_comments.clone(),
        calibrations: antenna.calibrations.iter().map(calibration_term).collect(),
        dazi_deg: antenna.dazi_deg,
        zenith_grid: antenna.zenith_grid.map(zenith_grid_term),
        has_frequency_count: antenna.has_frequency_count,
        sinex_code: antenna.sinex_code.clone(),
        valid_from: antenna.valid_from.map(epoch_term),
        valid_until: antenna.valid_until.map(epoch_term),
        comments: antenna.comments.clone(),
        frequencies: antenna.frequencies.iter().map(frequency_term).collect(),
    }
}

fn calibration_term(calibration: &Calibration) -> CalibrationTerm {
    CalibrationTerm {
        method: calibration.method.clone(),
        agency: calibration.agency.clone(),
        antennas_calibrated: calibration.antennas_calibrated,
        date: calibration.date.clone(),
    }
}

fn zenith_grid_term(grid: ZenithGrid) -> ZenithGridTerm {
    ZenithGridTerm {
        start_deg: grid.start_deg,
        end_deg: grid.end_deg,
        step_deg: grid.step_deg,
    }
}

fn epoch_term(epoch: AntexDateTime) -> EpochTerm {
    EpochTerm {
        year: epoch.year,
        month: epoch.month,
        day: epoch.day,
        hour: epoch.hour,
        minute: epoch.minute,
        second: epoch.second,
        fraction_digits: epoch.fraction.digits(),
        fraction_scale: epoch.fraction.scale(),
    }
}

fn frequency_term(frequency: &Frequency) -> FrequencyTerm {
    FrequencyTerm {
        frequency: frequency.frequency.clone(),
        pco_m: array_to_vec3(frequency.pco_m),
        pcv_samples: frequency.pcv_samples.iter().map(sample_term).collect(),
        rms: frequency.rms.as_ref().map(|rms| RmsTerm {
            pco_m: rms.pco_m.map(array_to_vec3),
            pcv_samples: rms.pcv_samples.iter().map(sample_term).collect(),
        }),
    }
}

fn sample_term(sample: &PcvSample) -> SampleTerm {
    SampleTerm {
        grid: match sample.grid {
            PcvGrid::NoAzimuth => atoms::noazi(),
            PcvGrid::Azimuth => atoms::azi(),
        },
        azimuth_deg: sample.azimuth_deg,
        zenith_deg: sample.zenith_deg,
        value_m: sample.value_m,
    }
}

/// An antenna block holding only what a lookup reads. The block's other
/// records do not take part in frequency, PCO or PCV lookup.
fn decode_lookup_antenna(term: LookupAntennaTerm) -> NifResult<Antenna> {
    let frequencies = term
        .frequencies
        .into_iter()
        .map(decode_frequency)
        .collect::<NifResult<Vec<_>>>()?;
    Ok(Antenna {
        id: term.id,
        kind: AntennaKind::Receiver,
        antenna_type: String::new(),
        serial: String::new(),
        leading_comments: Vec::new(),
        calibrations: Vec::new(),
        dazi_deg: None,
        zenith_grid: term.zenith_grid.map(|grid| ZenithGrid {
            start_deg: grid.start_deg,
            end_deg: grid.end_deg,
            step_deg: grid.step_deg,
        }),
        has_frequency_count: false,
        sinex_code: None,
        valid_from: None,
        valid_until: None,
        comments: Vec::new(),
        frequencies,
    })
}

fn decode_frequency(term: FrequencyTerm) -> NifResult<Frequency> {
    Ok(Frequency {
        frequency: term.frequency,
        pco_m: vec3_to_array(term.pco_m),
        pcv_samples: term
            .pcv_samples
            .into_iter()
            .map(decode_sample)
            .collect::<NifResult<_>>()?,
        rms: term
            .rms
            .map(|rms| -> NifResult<FrequencyRms> {
                Ok(FrequencyRms {
                    pco_m: rms.pco_m.map(vec3_to_array),
                    pcv_samples: rms
                        .pcv_samples
                        .into_iter()
                        .map(decode_sample)
                        .collect::<NifResult<_>>()?,
                })
            })
            .transpose()?,
    })
}

fn decode_sample(term: SampleTerm) -> NifResult<PcvSample> {
    let grid = if term.grid == atoms::azi() {
        PcvGrid::Azimuth
    } else if term.grid == atoms::noazi() {
        PcvGrid::NoAzimuth
    } else {
        return Err(rustler::Error::Term(Box::new((
            atoms::invalid_input(),
            "grid",
        ))));
    };
    Ok(PcvSample {
        grid,
        azimuth_deg: term.azimuth_deg,
        zenith_deg: term.zenith_deg,
        value_m: term.value_m,
    })
}

fn decode_epoch(term: &EpochTerm) -> Result<AntexDateTime, AntexError> {
    let fraction = SecondFraction::new(term.fraction_digits, term.fraction_scale)
        .ok_or(AntexError::InvalidDateTime)?;
    AntexDateTime::new_with_fraction(
        term.year,
        term.month,
        term.day,
        term.hour,
        term.minute,
        term.second,
        fraction,
    )
}

/// Past this many decimal places a fraction of at most twenty significant
/// digits is below 1e-380, under half the smallest subnormal double, so the
/// seconds round to the whole second.
const NEGLIGIBLE_FRACTION_SCALE: u64 = 400;

/// A validity bound's seconds as the nearest double to the exact decimal the
/// bound states, `second + fraction_digits / 10^fraction_scale`: the decimal
/// text is read by the correctly rounded `f64` parser, so no digit is dropped
/// before the one rounding to a double. `None` for a fraction that is not
/// below one second.
pub(crate) fn validity_seconds(
    second: u8,
    fraction_digits: u64,
    fraction_scale: u64,
) -> Option<f64> {
    let fraction = SecondFraction::new(fraction_digits, fraction_scale)?;
    if fraction.digits() == 0 || fraction.scale() > NEGLIGIBLE_FRACTION_SCALE {
        return Some(f64::from(second));
    }
    let digits = fraction.digits();
    let width = usize::try_from(fraction.scale()).ok()?;
    format!("{second}.{digits:0width$}").parse::<f64>().ok()
}

fn vec3_to_array(vec: Vec3) -> [f64; 3] {
    [vec.0, vec.1, vec.2]
}

fn array_to_vec3(array: [f64; 3]) -> Vec3 {
    (array[0], array[1], array[2])
}
