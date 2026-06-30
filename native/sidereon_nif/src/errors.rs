//! Shared mapping of core engine errors to Elixir-idiomatic error terms.
//!
//! The hardened `sidereon-core` returns `Result` from formerly-infallible
//! numerics, guarding against non-finite or degenerate input. The NIF boundary
//! never panics: it converts those `Err` values into a raised error term whose
//! reason is an atom, so callers see `{:error, atom}` shapes rather than a
//! leaked Rust string.

mod atoms {
    rustler::atoms! {
        invalid_input,
        missing_ap_array,
        non_finite_input,
        out_of_domain,
    }
}

/// Map any core error whose only failure mode is invalid/degenerate input to a
/// raised `:invalid_input` atom. Used for the `{field, reason}` error enums
/// shared by the frame, angle, and RF primitives.
pub(crate) fn invalid_input<E>(_err: E) -> rustler::Error {
    rustler::Error::Term(Box::new(atoms::invalid_input()))
}

/// Map a neutral-atmosphere boundary error to a specific raised atom, so the
/// Elixir caller can distinguish a missing Ap history from a non-finite or
/// out-of-domain input.
pub(crate) fn atmosphere(err: sidereon_core::astro::atmosphere::AtmosphereError) -> rustler::Error {
    use sidereon_core::astro::atmosphere::AtmosphereError as E;
    let atom = match err {
        E::MissingApArray => atoms::missing_ap_array(),
        E::NonFiniteInput(_) => atoms::non_finite_input(),
        E::OutOfDomain(_) => atoms::out_of_domain(),
    };
    rustler::Error::Term(Box::new(atom))
}
