//! Rustler boundary for the terrestrial Helmert frame catalog.
//!
//! All catalog math lives in `sidereon_core::frame_catalog`. This module only
//! maps frame labels, tuple triples, and catalog structs across the NIF boundary.

use rustler::{Encoder, Env, Term};
use sidereon_core::{
    catalog as core_catalog, catalog_entry as core_catalog_entry,
    propagate_position as core_propagate_position, transform as core_transform,
    transform_from_epoch as core_transform_from_epoch, FrameCatalogError, HelmertParameters,
    HelmertRates, HelmertTransform, TerrestrialFrame, TerrestrialPositionM, TerrestrialState,
    TerrestrialVelocityMPerYear,
};

mod atoms {
    rustler::atoms! {
        ok,
        error,
        invalid_frame,
        invalid_input,
        no_catalog_path,
        singular_transform
    }
}

type Vec3 = (f64, f64, f64);

#[derive(Debug, Clone, rustler::NifMap)]
struct HelmertParametersTerm {
    translation_mm: Vec3,
    scale_ppb: f64,
    rotation_mas: Vec3,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct HelmertRatesTerm {
    translation_mm_per_year: Vec3,
    scale_ppb_per_year: f64,
    rotation_mas_per_year: Vec3,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct HelmertTransformTerm {
    from_frame: String,
    to_frame: String,
    reference_epoch_year: f64,
    parameters: HelmertParametersTerm,
    rates: HelmertRatesTerm,
    provenance: String,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct TerrestrialStateTerm {
    position_m: Vec3,
    velocity_m_per_year: Option<Vec3>,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct FrameCatalogErrorTerm {
    kind: String,
    field: Option<String>,
    reason: Option<String>,
    from_frame: Option<String>,
    to_frame: Option<String>,
    epoch_year: Option<f64>,
}

fn tuple3(values: [f64; 3]) -> Vec3 {
    (values[0], values[1], values[2])
}

fn array3((x, y, z): Vec3) -> [f64; 3] {
    [x, y, z]
}

fn frame_label(frame: TerrestrialFrame) -> String {
    frame.to_string()
}

fn frame_from_label(value: &str) -> Option<TerrestrialFrame> {
    match value.trim().to_ascii_uppercase().replace('_', "").as_str() {
        "ITRF2020" => Some(TerrestrialFrame::Itrf2020),
        "ITRF2014" => Some(TerrestrialFrame::Itrf2014),
        "ITRF2008" => Some(TerrestrialFrame::Itrf2008),
        "ETRF2020" => Some(TerrestrialFrame::Etrf2020),
        _ => None,
    }
}

fn position(value: Vec3) -> Result<TerrestrialPositionM, FrameCatalogError> {
    TerrestrialPositionM::from_array(array3(value))
}

fn velocity(value: Vec3) -> Result<TerrestrialVelocityMPerYear, FrameCatalogError> {
    TerrestrialVelocityMPerYear::from_array(array3(value))
}

fn parameters(value: HelmertParameters) -> HelmertParametersTerm {
    HelmertParametersTerm {
        translation_mm: tuple3(value.translation_mm),
        scale_ppb: value.scale_ppb,
        rotation_mas: tuple3(value.rotation_mas),
    }
}

fn rates(value: HelmertRates) -> HelmertRatesTerm {
    HelmertRatesTerm {
        translation_mm_per_year: tuple3(value.translation_mm_per_year),
        scale_ppb_per_year: value.scale_ppb_per_year,
        rotation_mas_per_year: tuple3(value.rotation_mas_per_year),
    }
}

fn transform_term(value: &HelmertTransform) -> HelmertTransformTerm {
    HelmertTransformTerm {
        from_frame: frame_label(value.from),
        to_frame: frame_label(value.to),
        reference_epoch_year: value.reference_epoch_year,
        parameters: parameters(value.parameters),
        rates: rates(value.rates),
        provenance: value.provenance.to_string(),
    }
}

fn state_term(value: TerrestrialState) -> TerrestrialStateTerm {
    TerrestrialStateTerm {
        position_m: tuple3(value.position.as_array()),
        velocity_m_per_year: value.velocity.map(|velocity| tuple3(velocity.as_array())),
    }
}

fn error_term(error: FrameCatalogError) -> FrameCatalogErrorTerm {
    match error {
        FrameCatalogError::InvalidInput { field, reason } => FrameCatalogErrorTerm {
            kind: "invalid_input".to_string(),
            field: Some(field.to_string()),
            reason: Some(reason.to_string()),
            from_frame: None,
            to_frame: None,
            epoch_year: None,
        },
        FrameCatalogError::NoCatalogPath { from, to } => FrameCatalogErrorTerm {
            kind: "no_catalog_path".to_string(),
            field: None,
            reason: None,
            from_frame: Some(frame_label(from)),
            to_frame: Some(frame_label(to)),
            epoch_year: None,
        },
        FrameCatalogError::SingularTransform {
            from,
            to,
            epoch_year,
        } => FrameCatalogErrorTerm {
            kind: "singular_transform".to_string(),
            field: None,
            reason: None,
            from_frame: Some(frame_label(from)),
            to_frame: Some(frame_label(to)),
            epoch_year: Some(epoch_year),
        },
    }
}

fn decode_frame(value: String) -> Result<TerrestrialFrame, rustler::Atom> {
    frame_from_label(&value).ok_or_else(atoms::invalid_frame)
}

fn encode_state_result<'a>(
    env: Env<'a>,
    result: Result<TerrestrialState, FrameCatalogError>,
) -> Term<'a> {
    match result {
        Ok(state) => (atoms::ok(), state_term(state)).encode(env),
        Err(error) => (atoms::error(), error_term(error)).encode(env),
    }
}

fn encode_position_result<'a>(
    env: Env<'a>,
    result: Result<TerrestrialPositionM, FrameCatalogError>,
) -> Term<'a> {
    match result {
        Ok(position) => (atoms::ok(), tuple3(position.as_array())).encode(env),
        Err(error) => (atoms::error(), error_term(error)).encode(env),
    }
}

/// Return the built-in terrestrial frame catalog.
#[rustler::nif]
fn frame_catalog() -> Vec<HelmertTransformTerm> {
    core_catalog().iter().map(transform_term).collect()
}

/// Return the direct published catalog entry for two frames.
#[rustler::nif]
fn frame_catalog_entry<'a>(env: Env<'a>, from_frame: String, to_frame: String) -> Term<'a> {
    let from = match decode_frame(from_frame) {
        Ok(frame) => frame,
        Err(atom) => return (atoms::error(), atom).encode(env),
    };
    let to = match decode_frame(to_frame) {
        Ok(frame) => frame,
        Err(atom) => return (atoms::error(), atom).encode(env),
    };
    match core_catalog_entry(from, to) {
        Some(entry) => (atoms::ok(), transform_term(entry)).encode(env),
        None => (
            atoms::error(),
            FrameCatalogErrorTerm {
                kind: "no_catalog_path".to_string(),
                field: None,
                reason: None,
                from_frame: Some(frame_label(from)),
                to_frame: Some(frame_label(to)),
                epoch_year: None,
            },
        )
            .encode(env),
    }
}

/// Propagate a terrestrial station position between decimal-year epochs.
#[rustler::nif]
fn frame_catalog_propagate_position<'a>(
    env: Env<'a>,
    position_m: Vec3,
    velocity_m_per_year: Vec3,
    from_epoch_year: f64,
    to_epoch_year: f64,
) -> Term<'a> {
    let result = position(position_m).and_then(|position| {
        velocity(velocity_m_per_year).and_then(|velocity| {
            core_propagate_position(position, velocity, from_epoch_year, to_epoch_year)
        })
    });
    encode_position_result(env, result)
}

/// Transform a terrestrial position and optional velocity between catalog frames.
#[rustler::nif]
fn frame_catalog_transform<'a>(
    env: Env<'a>,
    position_m: Vec3,
    velocity_m_per_year: Option<Vec3>,
    from_frame: String,
    to_frame: String,
    epoch_year: f64,
) -> Term<'a> {
    let from = match decode_frame(from_frame) {
        Ok(frame) => frame,
        Err(atom) => return (atoms::error(), atom).encode(env),
    };
    let to = match decode_frame(to_frame) {
        Ok(frame) => frame,
        Err(atom) => return (atoms::error(), atom).encode(env),
    };
    let result = position(position_m).and_then(|position| {
        velocity_m_per_year
            .map(velocity)
            .transpose()
            .and_then(|velocity| core_transform(position, velocity, from, to, epoch_year))
    });
    encode_state_result(env, result)
}

/// Propagate a station to a transform epoch, then transform it between frames.
#[rustler::nif]
fn frame_catalog_transform_from_epoch<'a>(
    env: Env<'a>,
    position_m: Vec3,
    velocity_m_per_year: Vec3,
    position_epoch_year: f64,
    from_frame: String,
    to_frame: String,
    transform_epoch_year: f64,
) -> Term<'a> {
    let from = match decode_frame(from_frame) {
        Ok(frame) => frame,
        Err(atom) => return (atoms::error(), atom).encode(env),
    };
    let to = match decode_frame(to_frame) {
        Ok(frame) => frame,
        Err(atom) => return (atoms::error(), atom).encode(env),
    };
    let result = position(position_m).and_then(|position| {
        velocity(velocity_m_per_year).and_then(|velocity| {
            core_transform_from_epoch(
                position,
                velocity,
                position_epoch_year,
                from,
                to,
                transform_epoch_year,
            )
        })
    });
    encode_state_result(env, result)
}
