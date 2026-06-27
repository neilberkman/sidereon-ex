//! Shared decoder for the opt-in estimation-strategy selector threaded across the
//! SPP / RTK / PPP NIF boundary (Phase-6 increment 4).
//!
//! Every estimation NIF takes a trailing `strategy` atom. The default is the
//! reference-faithful strategy, so `nil` or `:reference` resolves to the
//! technique's reference [`StrategyId`] (the current 0-ULP path, byte-for-byte
//! unchanged); `:canonical` resolves to [`StrategyId::Canonical`] for the
//! technique. The NIF then drives the shared
//! [`sidereon_core::estimation::estimate`] selector with that id, so the
//! reference branch is the exact path the legacy `solve_*` wrappers took (they
//! are themselves thin `estimate(.., reference)` calls).

use rustler::{Error, NifResult, Term};
use sidereon_core::estimation::{StrategyId, Technique};

/// Which strategy family the caller selected at the sidereon boundary.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StrategySelection {
    /// The technique's reference-faithful strategy (the unchanged default).
    Reference,
    /// The technique's canonical strategy (bounded-tolerance, truth-gated).
    Canonical,
}

impl StrategySelection {
    /// The [`StrategyId`] this selection resolves to for `technique`: the
    /// technique's reference id (the current default) or its canonical id.
    pub fn strategy_id(self, technique: Technique) -> StrategyId {
        match self {
            Self::Reference => match technique {
                Technique::Spp => StrategyId::spp_reference(),
                Technique::Rtk => StrategyId::rtk_reference(),
                Technique::Ppp => StrategyId::ppp_reference(),
            },
            Self::Canonical => StrategyId::Canonical { technique },
        }
    }
}

/// Decode the trailing strategy selector term. `nil` or `:reference` selects the
/// reference strategy (the default, preserving existing output bit-for-bit);
/// `:canonical` selects the canonical strategy. Any other term is a contract
/// error, surfaced as a Rustler term error rather than silently defaulting.
pub fn decode_strategy(term: Term<'_>) -> NifResult<StrategySelection> {
    if !term.is_atom() {
        return Err(Error::Term(Box::new(
            "strategy must be the atom nil, :reference, or :canonical",
        )));
    }
    match term.atom_to_string().unwrap_or_default().as_str() {
        "nil" | "reference" => Ok(StrategySelection::Reference),
        "canonical" => Ok(StrategySelection::Canonical),
        other => Err(Error::Term(Box::new(format!(
            "strategy must be :reference or :canonical, got :{other}"
        )))),
    }
}
