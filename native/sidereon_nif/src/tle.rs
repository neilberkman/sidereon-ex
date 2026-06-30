//! Rustler boundary for the TLE format parser/encoder.
//!
//! Pure glue over `sidereon_core::astro::tle`: decode the two raw lines or the
//! normalized element map, forward to the crate codec, and encode the unchanged
//! Sidereon result shapes. No format grammar, checksum, or number codec lives here;
//! the epoch crosses as `(epoch_year, epoch_day_of_year)` and the Elixir binding
//! marshals it to/from its native `DateTime`.

use rustler::{Encoder, Env, Term};
use sidereon_core::astro::sgp4;
use sidereon_core::astro::tle::{self, TleElements};

mod atoms {
    rustler::atoms! {
        ok,
        error
    }
}

/// Normalized element fields exchanged with the Elixir binding. Mirrors the
/// `%Sidereon.Elements{}` numeric content with the epoch already split into a
/// calendar year and one-based fractional day-of-year.
#[derive(Debug, Clone, rustler::NifMap)]
struct TleFields {
    catalog_number: String,
    classification: String,
    international_designator: String,
    epoch_year: i32,
    epoch_day_of_year: f64,
    mean_motion_dot: f64,
    mean_motion_double_dot: f64,
    bstar: f64,
    ephemeris_type: i32,
    elset_number: i32,
    inclination_deg: f64,
    raan_deg: f64,
    eccentricity: f64,
    arg_perigee_deg: f64,
    mean_anomaly_deg: f64,
    mean_motion: f64,
    rev_number: i32,
}

impl From<TleElements> for TleFields {
    fn from(el: TleElements) -> Self {
        Self {
            catalog_number: el.catalog_number,
            classification: el.classification,
            international_designator: el.international_designator,
            epoch_year: el.epoch_year,
            epoch_day_of_year: el.epoch_day_of_year,
            mean_motion_dot: el.mean_motion_dot,
            mean_motion_double_dot: el.mean_motion_double_dot,
            bstar: el.bstar,
            ephemeris_type: el.ephemeris_type,
            elset_number: el.elset_number,
            inclination_deg: el.inclination_deg,
            raan_deg: el.raan_deg,
            eccentricity: el.eccentricity,
            arg_perigee_deg: el.arg_perigee_deg,
            mean_anomaly_deg: el.mean_anomaly_deg,
            mean_motion: el.mean_motion,
            rev_number: el.rev_number,
        }
    }
}

impl From<TleFields> for TleElements {
    fn from(f: TleFields) -> Self {
        Self {
            catalog_number: f.catalog_number,
            classification: f.classification,
            international_designator: f.international_designator,
            epoch_year: f.epoch_year,
            epoch_day_of_year: f.epoch_day_of_year,
            mean_motion_dot: f.mean_motion_dot,
            mean_motion_double_dot: f.mean_motion_double_dot,
            bstar: f.bstar,
            ephemeris_type: f.ephemeris_type,
            elset_number: f.elset_number,
            inclination_deg: f.inclination_deg,
            raan_deg: f.raan_deg,
            eccentricity: f.eccentricity,
            arg_perigee_deg: f.arg_perigee_deg,
            mean_anomaly_deg: f.mean_anomaly_deg,
            mean_motion: f.mean_motion,
            rev_number: f.rev_number,
        }
    }
}

/// Returns `{:ok, fields, checksum_warnings}` on success, or `{:error, reason}`.
/// Each checksum warning is `{line_label, expected_digit, computed_digit}` for
/// the host to log; the bad checksum does not reject the parse.
#[rustler::nif]
fn tle_parse<'a>(env: Env<'a>, line1: String, line2: String) -> Term<'a> {
    match tle::parse(&line1, &line2) {
        Ok(parsed) => {
            let fields: TleFields = parsed.elements.into();
            let warnings: Vec<(String, i64, i64)> = parsed
                .checksum_warnings
                .into_iter()
                .map(|w| {
                    (
                        w.line_label.to_string(),
                        w.expected as i64,
                        w.computed as i64,
                    )
                })
                .collect();
            (atoms::ok(), fields, warnings).encode(env)
        }
        Err(e) => (atoms::error(), e.to_string()).encode(env),
    }
}

#[rustler::nif]
fn tle_encode(fields: TleFields) -> (String, String) {
    tle::encode(&fields.into())
}

/// Parse a CelesTrak/Space-Track multi-record TLE file.
///
/// Returns `{:ok, satellites, skipped}` where `satellites` is a list of
/// `{name, fields}` tuples in file order (the name is the empty string for a
/// bare two-line record), and `skipped` counts records whose element set failed
/// SGP4 initialization. The per-record `fields` reuse the same `TleFields` shape
/// as `tle_parse`, so the Elixir binding marshals each into `%Sidereon.Elements{}`
/// through the identical path. The file scan, name handling, and skip accounting
/// all live in `sidereon_core::astro::sgp4::parse_tle_file`; this is pure glue.
#[rustler::nif]
fn parse_tle_file<'a>(env: Env<'a>, text: String) -> Term<'a> {
    let file = sgp4::parse_tle_file(&text);
    let satellites: Vec<(String, TleFields)> = file
        .satellites
        .into_iter()
        .filter_map(|named| {
            // Re-derive the normalized element fields from the satellite's source
            // lines through the same codec `tle_parse` uses. Every satellite in a
            // parsed file carries its raw lines, and the core already proved they
            // SGP4-initialize, so this parse cannot fail.
            tle::parse(named.satellite.line1(), named.satellite.line2())
                .ok()
                .map(|parsed| (named.name, parsed.elements.into()))
        })
        .collect();
    (atoms::ok(), satellites, file.skipped as i64).encode(env)
}
