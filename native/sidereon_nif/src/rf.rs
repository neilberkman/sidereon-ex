//! Rustler boundary for the core RF link-budget primitives.
//!
//! Pure glue: forward scalars to the relocated `sidereon_core::astro::rf` functions.
//! No link-budget formula lives here. The core now rejects non-finite inputs and
//! outputs, surfaced here as the shared `:invalid_input` atom.

use crate::errors;
use rustler::{Error, NifResult};
use sidereon_core::astro::rf::{self, LinkBudget};

pub(crate) fn fspl_impl(distance_km: f64, frequency_mhz: f64) -> NifResult<f64> {
    rf::fspl(distance_km, frequency_mhz).map_err(errors::invalid_input)
}

pub(crate) fn fspl_batch_impl(distances_km: Vec<f64>, frequency_mhz: f64) -> NifResult<Vec<f64>> {
    rf::fspl_batch(&distances_km, frequency_mhz)
        .into_iter()
        .collect::<Result<Vec<_>, _>>()
        .map_err(|_| Error::BadArg)
}

pub(crate) fn eirp_impl(tx_power_dbm: f64, tx_antenna_gain_dbi: f64) -> NifResult<f64> {
    rf::eirp(tx_power_dbm, tx_antenna_gain_dbi).map_err(errors::invalid_input)
}

pub(crate) fn cn0_impl(
    eirp_dbw: f64,
    fspl_db: f64,
    receiver_gt_dbk: f64,
    other_losses_db: f64,
) -> NifResult<f64> {
    rf::cn0(eirp_dbw, fspl_db, receiver_gt_dbk, other_losses_db).map_err(errors::invalid_input)
}

pub(crate) fn link_margin_impl(
    eirp_dbw: f64,
    fspl_db: f64,
    receiver_gt_dbk: f64,
    other_losses_db: f64,
    required_cn0_dbhz: f64,
) -> NifResult<f64> {
    rf::link_margin(&LinkBudget {
        eirp_dbw,
        fspl_db,
        receiver_gt_dbk,
        other_losses_db,
        required_cn0_dbhz,
    })
    .map_err(errors::invalid_input)
}

pub(crate) fn link_margin_batch_impl(
    budgets: Vec<(f64, f64, f64, f64, f64)>,
) -> NifResult<Vec<f64>> {
    let budgets: Vec<LinkBudget> = budgets
        .into_iter()
        .map(
            |(eirp_dbw, fspl_db, receiver_gt_dbk, other_losses_db, required_cn0_dbhz)| LinkBudget {
                eirp_dbw,
                fspl_db,
                receiver_gt_dbk,
                other_losses_db,
                required_cn0_dbhz,
            },
        )
        .collect();
    rf::link_margin_batch(&budgets)
        .into_iter()
        .collect::<Result<Vec<_>, _>>()
        .map_err(|_| Error::BadArg)
}

pub(crate) fn wavelength_impl(frequency_hz: f64) -> NifResult<f64> {
    rf::wavelength(frequency_hz).map_err(errors::invalid_input)
}

pub(crate) fn dish_gain_impl(
    diameter_m: f64,
    frequency_hz: f64,
    efficiency: f64,
) -> NifResult<f64> {
    rf::dish_gain(diameter_m, frequency_hz, efficiency).map_err(errors::invalid_input)
}
