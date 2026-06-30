//! Rustler boundary for the `sidereon-core` product-staleness selection layer
//! (`sidereon_core::staleness`).
//!
//! This module is **pure glue**: it gathers the caller's already-parsed IONEX /
//! SP3 resource handles, calls the crate's `select_*` functions under a
//! [`StalenessPolicy`], and encodes the [`StalenessMetadata`] plus a usable
//! handle (or an index into the input set) back to Elixir. No selection,
//! degradation, or interpolation math lives here, and there is no networking:
//! fetching the products is a per-binding concern handled elsewhere.
//!
//! ## Result shape
//!
//! - SP3 selection only ever borrows one of the input products (exact or
//!   nearest-prior, never a synthesized product), so the selected product is
//!   returned as its INDEX into the input list. The Elixir wrapper maps that
//!   index back to the original `%Sidereon.GNSS.SP3{}` struct (with its coverage
//!   metadata intact), so the present/exact path is bit-for-bit the caller's own
//!   product.
//! - IONEX selection is either the present product (returned as an index, so the
//!   exact path is the caller's own untouched grid) or a whole-day diurnal-shift
//!   copy (returned as a fresh resource handle). The two cases are tagged
//!   `{:present, index}` / `{:shifted, handle}`.
//!
//! Every success carries the staleness metadata tuple
//! `{kind, requested_epoch_j2000_s, source_epoch_j2000_s, staleness_s,
//! staleness_days}`; a typed `{:error, reason}` is returned otherwise, so a
//! degraded answer is never substituted silently.

use rustler::{Encoder, Env, ResourceArc, Term};

use sidereon_core::atmosphere::ionosphere::Ionex;
use sidereon_core::ephemeris::Sp3;
use sidereon_core::staleness::{
    select_ionex, select_ionex_over_range, select_sp3, select_sp3_over_range, DegradationKind,
    SelectionError, StalenessMetadata, StalenessPolicy,
};

use crate::iono::IonexResource;
use crate::sp3::Sp3Resource;
use crate::spp::atom_from;

/// Encode a [`StalenessMetadata`] as the Elixir tuple
/// `{kind, requested_epoch_j2000_s, source_epoch_j2000_s, staleness_s,
/// staleness_days}`. Shared with the precise-to-broadcast fallback encoder.
pub(crate) fn metadata_term<'a>(env: Env<'a>, m: &StalenessMetadata) -> Term<'a> {
    let kind = match m.kind {
        DegradationKind::Exact => "exact",
        DegradationKind::NearestPrior => "nearest_prior",
        DegradationKind::DiurnalShift => "diurnal_shift",
    };
    (
        atom_from(env, kind),
        m.requested_epoch_j2000_s,
        m.source_epoch_j2000_s,
        m.staleness_s,
        m.staleness_days,
    )
        .encode(env)
}

/// Encode a [`SelectionError`] as a typed Elixir reason term. Shared with the
/// fallback encoder, where a declined precise selection surfaces as
/// `{:precise_unavailable, reason}`.
pub(crate) fn selection_error_term<'a>(env: Env<'a>, error: &SelectionError) -> Term<'a> {
    match error {
        SelectionError::EmptyProductSet => atom_from(env, "empty_product_set"),
        SelectionError::InvalidRange {
            start_epoch_j2000_s,
            end_epoch_j2000_s,
        } => (
            atom_from(env, "invalid_range"),
            *start_epoch_j2000_s,
            *end_epoch_j2000_s,
        )
            .encode(env),
        SelectionError::NoPriorProduct {
            requested_epoch_j2000_s,
        } => (atom_from(env, "no_prior_product"), *requested_epoch_j2000_s).encode(env),
        SelectionError::BeyondStalenessCap {
            requested_epoch_j2000_s,
            source_epoch_j2000_s,
            staleness_s,
            max_staleness_s,
        } => (
            atom_from(env, "beyond_staleness_cap"),
            *requested_epoch_j2000_s,
            *source_epoch_j2000_s,
            *staleness_s,
            *max_staleness_s,
        )
            .encode(env),
        SelectionError::InvalidProduct(message) => {
            (atom_from(env, "invalid_product"), message.clone()).encode(env)
        }
        SelectionError::InvalidPolicy { max_staleness_s } => {
            (atom_from(env, "invalid_policy"), *max_staleness_s).encode(env)
        }
        SelectionError::Overflow { context } => (atom_from(env, "overflow"), *context).encode(env),
    }
}

/// `{:error, reason}` for a failed selection.
fn selection_error_result<'a>(env: Env<'a>, error: &SelectionError) -> Term<'a> {
    (
        rustler::types::atom::error(),
        selection_error_term(env, error),
    )
        .encode(env)
}

/// Locate the borrowed product within the local slice, by identity. The crate's
/// `select_sp3` / `select_ionex` exact and nearest-prior paths return a borrow of
/// one of `products`, so a pointer-identity match recovers its index (the same
/// position as the caller's handle list).
fn index_of_sp3(products: &[Sp3], selected: &Sp3) -> Option<usize> {
    products.iter().position(|p| std::ptr::eq(p, selected))
}

fn index_of_ionex(products: &[Ionex], selected: &Ionex) -> Option<usize> {
    products.iter().position(|p| std::ptr::eq(p, selected))
}

/// Select an SP3 product usable at `requested_epoch_j2000_s`, degrading to the
/// most-recent prior product within the staleness cap.
///
/// Returns `{:ok, {index, metadata}}` where `index` is the position of the
/// selected product in `handles`, or `{:error, reason}`.
#[rustler::nif]
fn staleness_select_sp3<'a>(
    env: Env<'a>,
    handles: Vec<ResourceArc<Sp3Resource>>,
    requested_epoch_j2000_s: f64,
    max_staleness_s: f64,
) -> Term<'a> {
    sp3_selection(
        env,
        handles,
        requested_epoch_j2000_s,
        requested_epoch_j2000_s,
        max_staleness_s,
    )
}

/// Select an SP3 product usable across `[start, end]` (J2000 seconds).
#[rustler::nif]
fn staleness_select_sp3_over_range<'a>(
    env: Env<'a>,
    handles: Vec<ResourceArc<Sp3Resource>>,
    start_epoch_j2000_s: f64,
    end_epoch_j2000_s: f64,
    max_staleness_s: f64,
) -> Term<'a> {
    sp3_selection(
        env,
        handles,
        start_epoch_j2000_s,
        end_epoch_j2000_s,
        max_staleness_s,
    )
}

fn sp3_selection<'a>(
    env: Env<'a>,
    handles: Vec<ResourceArc<Sp3Resource>>,
    start_epoch_j2000_s: f64,
    end_epoch_j2000_s: f64,
    max_staleness_s: f64,
) -> Term<'a> {
    let products: Vec<Sp3> = handles.iter().map(|h| h.sp3.clone()).collect();
    let policy = StalenessPolicy::seconds(max_staleness_s);
    let result = if start_epoch_j2000_s == end_epoch_j2000_s {
        select_sp3(&products, start_epoch_j2000_s, policy)
    } else {
        select_sp3_over_range(&products, start_epoch_j2000_s, end_epoch_j2000_s, policy)
    };
    match result {
        Ok(selection) => {
            let index = index_of_sp3(&products, selection.sp3())
                .expect("selected SP3 product is one of the inputs");
            (
                rustler::types::atom::ok(),
                (index, metadata_term(env, &selection.metadata())),
            )
                .encode(env)
        }
        Err(error) => selection_error_result(env, &error),
    }
}

/// Select an IONEX product usable at `requested_epoch_j2000_s` (J2000 seconds,
/// integer for the IONEX map-epoch axis), degrading to a diurnal-shifted prior
/// product within the staleness cap.
///
/// Returns `{:ok, {selection, metadata}}` where `selection` is
/// `{:present, index}` (the caller's untouched grid) or `{:shifted, handle}`
/// (a fresh whole-day diurnal-shift copy), or `{:error, reason}`.
#[rustler::nif]
fn staleness_select_ionex<'a>(
    env: Env<'a>,
    handles: Vec<ResourceArc<IonexResource>>,
    requested_epoch_j2000_s: i64,
    max_staleness_s: f64,
) -> Term<'a> {
    ionex_selection(
        env,
        handles,
        requested_epoch_j2000_s,
        requested_epoch_j2000_s,
        max_staleness_s,
    )
}

/// Select an IONEX product usable across `[start, end]` (J2000 seconds, integer).
#[rustler::nif]
fn staleness_select_ionex_over_range<'a>(
    env: Env<'a>,
    handles: Vec<ResourceArc<IonexResource>>,
    start_epoch_j2000_s: i64,
    end_epoch_j2000_s: i64,
    max_staleness_s: f64,
) -> Term<'a> {
    ionex_selection(
        env,
        handles,
        start_epoch_j2000_s,
        end_epoch_j2000_s,
        max_staleness_s,
    )
}

fn ionex_selection<'a>(
    env: Env<'a>,
    handles: Vec<ResourceArc<IonexResource>>,
    start_epoch_j2000_s: i64,
    end_epoch_j2000_s: i64,
    max_staleness_s: f64,
) -> Term<'a> {
    let products: Vec<Ionex> = handles.iter().map(|h| h.ionex.clone()).collect();
    let policy = StalenessPolicy::seconds(max_staleness_s);
    let result = if start_epoch_j2000_s == end_epoch_j2000_s {
        select_ionex(&products, start_epoch_j2000_s, policy)
    } else {
        select_ionex_over_range(&products, start_epoch_j2000_s, end_epoch_j2000_s, policy)
    };
    match result {
        Ok(selection) => {
            let metadata = selection.metadata();
            // An exact selection borrows one of the inputs, so it is returned as
            // an index (zero-copy, the caller's own grid). A diurnal shift is a
            // synthesized product, so it is returned as a fresh handle.
            let selection_term = match index_of_ionex(&products, selection.ionex()) {
                Some(index) => (atom_from(env, "present"), index).encode(env),
                None => {
                    let handle = ResourceArc::new(IonexResource {
                        ionex: selection.ionex().clone(),
                    });
                    (atom_from(env, "shifted"), handle).encode(env)
                }
            };
            (
                rustler::types::atom::ok(),
                (selection_term, metadata_term(env, &metadata)),
            )
                .encode(env)
        }
        Err(error) => selection_error_result(env, &error),
    }
}
