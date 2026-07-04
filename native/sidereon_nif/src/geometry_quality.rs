//! Tuple encoding for core geometry observability diagnostics.

use rustler::types::tuple::make_tuple;
use rustler::{Encoder, Env, Term};
use sidereon_core::geometry_quality::{GeometryQuality, ObservabilityTier};

mod atoms {
    rustler::atoms! {
        rank_deficient,
        zero_redundancy,
        weak,
        nominal
    }
}

pub(crate) fn geometry_quality_to_term<'a>(env: Env<'a>, value: GeometryQuality) -> Term<'a> {
    make_tuple(
        env,
        &[
            tier_to_atom(value.tier).encode(env),
            (value.redundancy as i64).encode(env),
            (value.rank as u64).encode(env),
            value.condition_number.encode(env),
            value.gdop.encode(env),
            value.raim_checkable.encode(env),
            value.covariance_validated.encode(env),
        ],
    )
}

fn tier_to_atom(tier: ObservabilityTier) -> rustler::Atom {
    match tier {
        ObservabilityTier::RankDeficient => atoms::rank_deficient(),
        ObservabilityTier::ZeroRedundancy => atoms::zero_redundancy(),
        ObservabilityTier::Weak => atoms::weak(),
        ObservabilityTier::Nominal => atoms::nominal(),
    }
}
