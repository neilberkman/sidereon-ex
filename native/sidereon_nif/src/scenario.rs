//! Rustler boundary for deterministic synthetic GNSS scenarios.
//!
//! This module accepts the core scenario JSON schema, delegates generation to
//! `sidereon_core::scenario`, and returns the core's deterministic serialized
//! output bytes. Scenario validation, satellite dynamics, observables, and term
//! ledger math stay in the core crate.

use rustler::{Encoder, Env, OwnedBinary, Term};
use sidereon_core::scenario::{simulate_scenario, Scenario, ScenarioError};

mod atoms {
    rustler::atoms! {
        ok,
        error,
        invalid_input,
        external_source_required,
        external_source_mismatch,
        external_ionosphere_required,
        ionosphere,
        no_ephemeris,
        observable,
        frame,
        json
    }
}

/// Simulate a synthetic-Keplerian scenario from a core-schema JSON document.
#[rustler::nif(schedule = "DirtyCpu")]
fn scenario_simulate_json<'a>(env: Env<'a>, text: String) -> Term<'a> {
    let scenario: Scenario = match serde_json::from_str(&text) {
        Ok(scenario) => scenario,
        Err(error) => return (atoms::error(), (atoms::json(), error.to_string())).encode(env),
    };

    let set = match simulate_scenario(&scenario) {
        Ok(set) => set,
        Err(error) => return (atoms::error(), encode_error(env, error)).encode(env),
    };

    match serde_json::to_vec(&set) {
        Ok(bytes) => (
            atoms::ok(),
            bytes_to_binary(env, &bytes),
            set.determinism_fingerprint(),
        )
            .encode(env),
        Err(error) => (atoms::error(), (atoms::json(), error.to_string())).encode(env),
    }
}

fn bytes_to_binary<'a>(env: Env<'a>, bytes: &[u8]) -> Term<'a> {
    let mut binary = OwnedBinary::new(bytes.len()).expect("allocate scenario binary");
    binary.as_mut_slice().copy_from_slice(bytes);
    binary.release(env).encode(env)
}

fn encode_error<'a>(env: Env<'a>, error: ScenarioError) -> Term<'a> {
    match error {
        ScenarioError::InvalidInput { field, reason } => {
            (atoms::invalid_input(), field, reason).encode(env)
        }
        ScenarioError::ExternalSourceRequired => atoms::external_source_required().encode(env),
        ScenarioError::ExternalSourceMismatch {
            field,
            expected,
            actual,
        } => (atoms::external_source_mismatch(), field, expected, actual).encode(env),
        ScenarioError::ExternalIonosphereRequired => {
            atoms::external_ionosphere_required().encode(env)
        }
        ScenarioError::Ionosphere(message) => (atoms::ionosphere(), message).encode(env),
        ScenarioError::NoEphemeris { satellite } => {
            (atoms::no_ephemeris(), satellite.to_string()).encode(env)
        }
        ScenarioError::Observable(error) => (atoms::observable(), error.to_string()).encode(env),
        ScenarioError::Frame(message) => (atoms::frame(), message).encode(env),
    }
}
