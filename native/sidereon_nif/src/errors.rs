//! Shared mapping of core engine errors to Elixir-idiomatic error terms.
//!
//! The hardened `sidereon-core` returns `Result` from formerly-infallible
//! numerics, guarding against non-finite or degenerate input. The NIF boundary
//! never panics: it converts those `Err` values into a raised error term whose
//! reason is an atom, so callers see `{:error, atom}` shapes rather than a
//! leaked Rust string.

mod atoms {
    rustler::atoms! {
        after_coverage,
        before_coverage,
        invalid_input,
        missing_ap_array,
        non_finite_input,
        out_of_domain,
        ut1_outside_coverage,
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

/// The atom naming which side of the UT1 table an instant fell on:
/// `:before_coverage` or `:after_coverage`.
pub(crate) fn degrade_reason_atom(
    reason: sidereon_core::astro::time::DegradeReason,
) -> rustler::Atom {
    use sidereon_core::astro::time::DegradeReason as R;
    match reason {
        R::BeforeCoverage => atoms::before_coverage(),
        R::AfterCoverage => atoms::after_coverage(),
    }
}

/// `{:ut1_outside_coverage, :before_coverage | :after_coverage}`, the term every
/// entry point uses for an instant whose UT1 lies outside the table.
pub(crate) fn ut1_outside_coverage_term<'a>(
    env: rustler::Env<'a>,
    reason: sidereon_core::astro::time::DegradeReason,
) -> rustler::Term<'a> {
    use rustler::Encoder;
    (atoms::ut1_outside_coverage(), degrade_reason_atom(reason)).encode(env)
}

/// As `ut1_outside_coverage_term`, raised as the error of a native call.
pub(crate) fn ut1_outside_coverage(
    reason: sidereon_core::astro::time::DegradeReason,
) -> rustler::Error {
    rustler::Error::Term(Box::new((
        atoms::ut1_outside_coverage(),
        degrade_reason_atom(reason),
    )))
}
