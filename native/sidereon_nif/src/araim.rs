//! Rustler boundary for ARAIM snapshot integrity.
//!
//! This is tuple decoding and result encoding around `sidereon_core::araim`.
//! The core owns geometry validation, ISM validation, fault-mode enumeration,
//! and protection-level numerics.

use rustler::{Encoder, Env, Error, NifResult, Term};
use sidereon_core::araim::{
    araim, AraimError, AraimGeometry, AraimRow, ConstellationIsm, IntegrityAllocation, Ism,
    SatelliteIsm, SatelliteIsmModel,
};
use sidereon_core::positioning::LineOfSight;
use sidereon_core::{GnssSatelliteId, GnssSystem, Wgs84Geodetic};

type Vec3 = (f64, f64, f64);
type RowTerm = (String, Vec3, String, f64);
type ReceiverTerm = (f64, f64, f64);
type SatModelTerm = (f64, f64, Option<f64>, Option<f64>, f64, f64);
type ConstellationTerm = (String, f64, SatModelTerm);
type SatelliteTerm = (String, f64, f64, Option<f64>, Option<f64>, f64, f64);
type AllocationTerm = (f64, f64, f64, f64, f64, f64, (f64, usize));

mod atoms {
    rustler::atoms! {
        ok,
        error,
        insufficient_geometry,
        unmonitorable_fault_mass,
        numerical_failure,
        invalid_ism,
        invalid_allocation
    }
}

#[derive(Debug, Clone, rustler::NifMap)]
struct FaultModeTerm {
    excluded: Vec<String>,
    excluded_constellation: Option<String>,
    prior: f64,
    sigma_int_enu_m: Vec3,
    bias_enu_m: Vec3,
    threshold_enu_m: Vec3,
    monitorable: bool,
}

#[derive(Debug, Clone, rustler::NifMap)]
struct AraimResultTerm {
    hpl_m: f64,
    vpl_m: f64,
    sigma_acc_h_m: f64,
    sigma_acc_v_m: f64,
    emt_m: f64,
    fault_modes: Vec<FaultModeTerm>,
    p_unmonitored: f64,
    availability: bool,
}

fn sat_id(token: &str) -> NifResult<GnssSatelliteId> {
    if token.len() < 2 {
        return Err(Error::Term(Box::new("invalid satellite id")));
    }
    let (system, prn) = token.split_at(1);
    let system = crate::sp3::system_from_letter(system)?;
    let prn: u8 = prn
        .parse()
        .map_err(|_| Error::Term(Box::new("invalid satellite prn")))?;
    GnssSatelliteId::new(system, prn).map_err(crate::errors::invalid_input)
}

fn system_from_term(system: &str) -> NifResult<GnssSystem> {
    crate::sp3::system_from_letter(system)
}

fn system_term(system: GnssSystem) -> String {
    system.letter().to_string()
}

fn decode_row((id, (e_x, e_y, e_z), system, elevation_rad): RowTerm) -> NifResult<AraimRow> {
    Ok(AraimRow {
        id: sat_id(&id)?,
        line_of_sight: LineOfSight::new(e_x, e_y, e_z),
        system: system_from_term(&system)?,
        elevation_rad,
    })
}

fn decode_receiver((lat_rad, lon_rad, height_m): ReceiverTerm) -> NifResult<Wgs84Geodetic> {
    Wgs84Geodetic::new(lat_rad, lon_rad, height_m).map_err(crate::errors::invalid_input)
}

fn decode_model(
    (
        sigma_ura_m,
        sigma_ure_m,
        effective_sigma_int_m,
        effective_sigma_acc_m,
        b_nom_m,
        p_sat,
    ): SatModelTerm,
) -> NifResult<SatelliteIsmModel> {
    match (effective_sigma_int_m, effective_sigma_acc_m) {
        (Some(sigma_int), Some(sigma_acc)) => Ok(SatelliteIsmModel::new_with_effective_sigmas(
            sigma_ura_m,
            sigma_ure_m,
            b_nom_m,
            p_sat,
            sigma_int,
            sigma_acc,
        )),
        (None, None) => Ok(SatelliteIsmModel::new(
            sigma_ura_m,
            sigma_ure_m,
            b_nom_m,
            p_sat,
        )),
        _ => Err(Error::Term(Box::new(
            "effective ARAIM sigmas must be supplied as a pair",
        ))),
    }
}

fn decode_constellation(
    (system, p_const, default_sat): ConstellationTerm,
) -> NifResult<ConstellationIsm> {
    Ok(ConstellationIsm::new(
        system_from_term(&system)?,
        p_const,
        decode_model(default_sat)?,
    ))
}

fn decode_satellite(
    (
        id,
        sigma_ura_m,
        sigma_ure_m,
        effective_sigma_int_m,
        effective_sigma_acc_m,
        b_nom_m,
        p_sat,
    ): SatelliteTerm,
) -> NifResult<SatelliteIsm> {
    let id = sat_id(&id)?;
    match (effective_sigma_int_m, effective_sigma_acc_m) {
        (Some(sigma_int), Some(sigma_acc)) => Ok(SatelliteIsm::new_with_effective_sigmas(
            id,
            sigma_ura_m,
            sigma_ure_m,
            b_nom_m,
            p_sat,
            sigma_int,
            sigma_acc,
        )),
        (None, None) => Ok(SatelliteIsm::new(
            id,
            sigma_ura_m,
            sigma_ure_m,
            b_nom_m,
            p_sat,
        )),
        _ => Err(Error::Term(Box::new(
            "effective ARAIM sigmas must be supplied as a pair",
        ))),
    }
}

fn decode_allocation(
    (
        phmi_total,
        phmi_vert,
        phmi_hor,
        pfa_vert,
        pfa_hor,
        p_threshold_unmonitored,
        (p_emt, max_fault_order),
    ): AllocationTerm,
) -> IntegrityAllocation {
    IntegrityAllocation {
        phmi_total,
        phmi_vert,
        phmi_hor,
        pfa_vert,
        pfa_hor,
        p_threshold_unmonitored,
        p_emt,
        max_fault_order,
    }
}

fn allocation_term(allocation: IntegrityAllocation) -> AllocationTerm {
    (
        allocation.phmi_total,
        allocation.phmi_vert,
        allocation.phmi_hor,
        allocation.pfa_vert,
        allocation.pfa_hor,
        allocation.p_threshold_unmonitored,
        (allocation.p_emt, allocation.max_fault_order),
    )
}

fn error_atom(err: AraimError) -> rustler::Atom {
    match err {
        AraimError::InsufficientGeometry => atoms::insufficient_geometry(),
        AraimError::UnmonitorableFaultMass => atoms::unmonitorable_fault_mass(),
        AraimError::NumericalFailure => atoms::numerical_failure(),
        AraimError::InvalidIsm => atoms::invalid_ism(),
        AraimError::InvalidAllocation => atoms::invalid_allocation(),
    }
}

fn vec3(values: [f64; 3]) -> Vec3 {
    (values[0], values[1], values[2])
}

fn result_term(result: sidereon_core::araim::AraimResult) -> AraimResultTerm {
    AraimResultTerm {
        hpl_m: result.hpl_m,
        vpl_m: result.vpl_m,
        sigma_acc_h_m: result.sigma_acc_h_m,
        sigma_acc_v_m: result.sigma_acc_v_m,
        emt_m: result.emt_m,
        fault_modes: result
            .fault_modes
            .into_iter()
            .map(|mode| FaultModeTerm {
                excluded: mode.excluded.into_iter().map(|id| id.to_string()).collect(),
                excluded_constellation: mode.excluded_constellation.map(system_term),
                prior: mode.prior,
                sigma_int_enu_m: vec3(mode.sigma_int_enu_m),
                bias_enu_m: vec3(mode.bias_enu_m),
                threshold_enu_m: vec3(mode.threshold_enu_m),
                monitorable: mode.monitorable,
            })
            .collect(),
        p_unmonitored: result.p_unmonitored,
        availability: result.availability,
    }
}

/// Return the core LPV-200 integrity allocation fields.
#[rustler::nif]
fn araim_lpv_200_allocation() -> AllocationTerm {
    allocation_term(IntegrityAllocation::lpv_200())
}

/// Run ARAIM for a caller-supplied snapshot geometry and ISM.
#[rustler::nif(schedule = "DirtyCpu")]
fn araim_solve<'a>(
    env: Env<'a>,
    rows: Vec<RowTerm>,
    receiver: ReceiverTerm,
    clock_systems: Vec<String>,
    constellations: Vec<ConstellationTerm>,
    satellites: Vec<SatelliteTerm>,
    allocation: AllocationTerm,
) -> NifResult<Term<'a>> {
    let geometry = AraimGeometry {
        rows: rows.into_iter().map(decode_row).collect::<NifResult<_>>()?,
        receiver: decode_receiver(receiver)?,
        clock_systems: clock_systems
            .iter()
            .map(|system| system_from_term(system))
            .collect::<NifResult<_>>()?,
    };
    let ism = Ism::new(
        constellations
            .into_iter()
            .map(decode_constellation)
            .collect::<NifResult<_>>()?,
        satellites
            .into_iter()
            .map(decode_satellite)
            .collect::<NifResult<_>>()?,
    );
    Ok(
        match araim(&geometry, &ism, &decode_allocation(allocation)) {
            Ok(result) => (atoms::ok(), result_term(result)).encode(env),
            Err(err) => (atoms::error(), error_atom(err)).encode(env),
        },
    )
}
