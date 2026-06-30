//! Rustler boundary for the GPS LNAV navigation-message codec.
//!
//! This module is glue only: it decodes normalized Elixir terms, calls
//! `sidereon_core::navigation::lnav`, and encodes the existing Sidereon public
//! result shapes. All bit packing, parity (IS-GPS-200 Table 20-XIV), scaling,
//! and range validation live in the crate. The thin Elixir wrapper applies the
//! `nil`-default normalization and re-attaches the original value to an
//! out-of-range error.

use rustler::{Atom, Encoder, Env, NifResult, Term};
use sidereon_core::navigation::lnav::{
    self, LnavDecoded, LnavError, LnavNumber, LnavOptions, LnavParams,
};

mod atoms {
    rustler::atoms! {
        ok,
        error,
        out_of_range,
        parity_failed,
        bad_subframe_length,
        bad_word_length,
        bad_length
    }
}

/// Decode an Elixir number term into the type-preserving codec number.
fn decode_number(term: Term) -> LnavNumber {
    if let Ok(i) = term.decode::<i64>() {
        LnavNumber::Int(i)
    } else if let Ok(f) = term.decode::<f64>() {
        LnavNumber::Float(f)
    } else {
        // A non-numeric term cannot be a valid LNAV field; route it through the
        // codec as a float NaN so validation rejects it with an out_of_range
        // tagging rather than panicking in the glue.
        LnavNumber::Float(f64::NAN)
    }
}

fn bits_from(values: Vec<i64>) -> Vec<u8> {
    values.into_iter().map(|b| b as u8).collect()
}

fn bits_to_i64(bits: &[u8]) -> Vec<i64> {
    bits.iter().map(|&b| i64::from(b)).collect()
}

#[rustler::nif]
fn lnav_word_length() -> u64 {
    lnav::WORD_LENGTH as u64
}

#[rustler::nif]
fn lnav_subframe_length() -> u64 {
    lnav::SUBFRAME_LENGTH as u64
}

#[rustler::nif]
fn lnav_preamble() -> u64 {
    u64::from(lnav::PREAMBLE)
}

#[rustler::nif]
fn lnav_parity(data24: Vec<i64>, d29_prev: i64, d30_prev: i64) -> NifResult<Vec<i64>> {
    let data = bits_from(data24);
    let parity = lnav::parity(&data, d29_prev as u8, d30_prev as u8)
        .map_err(crate::errors::invalid_input)?;
    Ok(bits_to_i64(&parity))
}

#[rustler::nif]
fn lnav_parity_valid(word30: Vec<i64>, d29_prev: i64, d30_prev: i64) -> bool {
    let word = bits_from(word30);
    lnav::parity_valid(&word, d29_prev as u8, d30_prev as u8)
}

#[rustler::nif]
fn lnav_tow<'a>(env: Env<'a>, bits: Vec<i64>) -> Term<'a> {
    match lnav::tow(&bits_from(bits)) {
        Some(v) => (atoms::ok(), v).encode(env),
        None => (atoms::error(), atoms::bad_length()).encode(env),
    }
}

#[rustler::nif]
fn lnav_subframe_id<'a>(env: Env<'a>, bits: Vec<i64>) -> Term<'a> {
    match lnav::subframe_id(&bits_from(bits)) {
        Some(v) => (atoms::ok(), v).encode(env),
        None => (atoms::error(), atoms::bad_length()).encode(env),
    }
}

#[rustler::nif]
fn lnav_encode<'a>(env: Env<'a>, params: Vec<Term<'a>>, opts: Vec<Term<'a>>) -> Term<'a> {
    let p = decode_params(&params);
    let o = decode_options(&opts);

    match lnav::encode(&p, &o) {
        Ok([sf1, sf2, sf3]) => (
            atoms::ok(),
            (bits_to_i64(&sf1), bits_to_i64(&sf2), bits_to_i64(&sf3)),
        )
            .encode(env),
        Err(err) => encode_error(env, err),
    }
}

#[rustler::nif]
fn lnav_decode<'a>(env: Env<'a>, sf1: Vec<i64>, sf2: Vec<i64>, sf3: Vec<i64>) -> Term<'a> {
    let (b1, b2, b3) = (bits_from(sf1), bits_from(sf2), bits_from(sf3));
    match lnav::decode(&b1, &b2, &b3) {
        Ok(d) => (atoms::ok(), (decoded_ints(&d), decoded_floats(&d))).encode(env),
        Err(err) => encode_error(env, err),
    }
}

/// The ten integer-typed decoded fields, in the order the Elixir wrapper expects:
/// week_number, l2_code, ura_index, sv_health, iodc, toc, iode, toe,
/// fit_interval_flag, aodo.
fn decoded_ints(d: &LnavDecoded) -> Vec<i64> {
    vec![
        d.week_number,
        d.l2_code,
        d.ura_index,
        d.sv_health,
        d.iodc,
        d.toc,
        d.iode,
        d.toe,
        d.fit_interval_flag,
        d.aodo,
    ]
}

/// The nineteen scaled-float decoded fields, in the order the Elixir wrapper
/// expects: tgd, af0, af1, af2, crs, delta_n, m0, cuc, eccentricity, cus,
/// sqrt_a, cic, omega0, cis, i0, crc, omega, omega_dot, idot.
fn decoded_floats(d: &LnavDecoded) -> Vec<f64> {
    vec![
        d.tgd,
        d.af0,
        d.af1,
        d.af2,
        d.crs,
        d.delta_n,
        d.m0,
        d.cuc,
        d.eccentricity,
        d.cus,
        d.sqrt_a,
        d.cic,
        d.omega0,
        d.cis,
        d.i0,
        d.crc,
        d.omega,
        d.omega_dot,
        d.idot,
    ]
}

/// Decode the 30 ephemeris field terms (struct-field order) into [`LnavParams`].
fn decode_params(t: &[Term]) -> LnavParams {
    LnavParams {
        week_number: decode_number(t[0]),
        l2_code: decode_number(t[1]),
        l2_p_data_flag: decode_number(t[2]),
        ura_index: decode_number(t[3]),
        sv_health: decode_number(t[4]),
        iodc: decode_number(t[5]),
        tgd: decode_number(t[6]),
        toc: decode_number(t[7]),
        af0: decode_number(t[8]),
        af1: decode_number(t[9]),
        af2: decode_number(t[10]),
        iode: decode_number(t[11]),
        crs: decode_number(t[12]),
        delta_n: decode_number(t[13]),
        m0: decode_number(t[14]),
        cuc: decode_number(t[15]),
        eccentricity: decode_number(t[16]),
        cus: decode_number(t[17]),
        sqrt_a: decode_number(t[18]),
        toe: decode_number(t[19]),
        fit_interval_flag: decode_number(t[20]),
        aodo: decode_number(t[21]),
        cic: decode_number(t[22]),
        omega0: decode_number(t[23]),
        cis: decode_number(t[24]),
        i0: decode_number(t[25]),
        crc: decode_number(t[26]),
        omega: decode_number(t[27]),
        omega_dot: decode_number(t[28]),
        idot: decode_number(t[29]),
    }
}

/// Decode the 5 option terms (tow, alert, anti_spoof, integrity, tlm_message).
fn decode_options(t: &[Term]) -> LnavOptions {
    LnavOptions {
        tow: decode_number(t[0]),
        alert: decode_number(t[1]),
        anti_spoof: decode_number(t[2]),
        integrity: decode_number(t[3]),
        tlm_message: decode_number(t[4]),
    }
}

fn encode_error<'a>(env: Env<'a>, err: LnavError) -> Term<'a> {
    match err {
        // The thin Elixir wrapper re-attaches the offending value (preserving
        // its original integer/float/nil type) by the returned field atom.
        LnavError::OutOfRange { field, value: _ } => {
            let field_atom = Atom::from_str(env, field.name()).expect("valid field atom");
            (atoms::error(), (atoms::out_of_range(), field_atom)).encode(env)
        }
        LnavError::ParityFailed { subframe, word } => (
            atoms::error(),
            (atoms::parity_failed(), i64::from(subframe), i64::from(word)),
        )
            .encode(env),
        LnavError::BadSubframeLength { subframe } => (
            atoms::error(),
            (atoms::bad_subframe_length(), i64::from(subframe)),
        )
            .encode(env),
        LnavError::BadWordLength { expected, actual } => (
            atoms::error(),
            (atoms::bad_word_length(), expected as i64, actual as i64),
        )
            .encode(env),
    }
}
