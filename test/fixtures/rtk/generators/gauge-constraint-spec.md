# Single-system SD gauge constraint: remove the epoch-124 singularity

Status: PRE-REGISTERED 2026-06-12, before the code change and measurement.
Inherits the C+D campaign method and the rover-gate-spec Amendment 1 refusal
invariant. Sibling of ar-commitment-spec.md (capability 3 of the ledger).

## Evidence base (committed, cd-measurement-2026-06.md addendum Q3)

The continuous PASA/SCOA L1 filter fails at epoch 124 with
`{:singular_geometry, [epoch_index: 124]}`. Mechanism: the single-difference
ambiguity state has a per-system gauge freedom (the reference SD ambiguity is
unobservable from double differences). With the default hold sigma 1.0e-4 the
held DD directions carry weight 1e8 while the gauge direction is carried only
by the 1e-6 initial prior; after 100+ held epochs the gauge pivot (`sd:G27`)
is subtractively cancelled to exactly 0.0 (a 14-order scale spread f64 cannot
hold). Soft hold 1.0e-3 only shrinks the spread to ~12 orders, which survives;
it is a crutch, not a fix.

A gauge constraint already exists in both kernels (`apply_reference_sd_gauge`
in Elixir, the matching block in the Rust kernel): it pins each system's
reference SD ambiguity at its prior-center value with the hold weight, a pure
DD-null-space constraint that leaves the baseline and every double difference
invariant. It is gated `when map_size(refs) > 1` (multi-system only),
explicitly to keep the single-system path bit-identical to its pre-gauge
history. The single system's reference SD is equally a gauge DOF, so the
single-system path has the same latent cancellation; the multi-system guard
is the defect.

## Hypothesis

Extending the existing gauge constraint to the single-system case (pinning the
one system's reference SD ambiguity at hold weight) removes the epoch-124
cancellation, so the continuous arc solves on the DEFAULT hold (1.0e-4) with
no soft-hold crutch, and the capability-1 arming clean pass holds on the
default hold.

## Pre-registered success bar

- The continuous PASA/SCOA L1 filter solves all 240 epochs on the default
  hold sigma 1.0e-4 (no `:singular_geometry`, no sub-arc reset crutch).
- With the arming gate (capability 1) on the default hold, the fixed
  population passes the Amendment 1 invariant: fixed n >= 20 and fixed median
  3D error <= 2x the oracle median (0.214 m floor). This is the clean pass the
  arming measurement could only reach with the soft hold.
- No regression: full Elixir + kernel battery green; the sigma-sweep gate
  green at its current thresholds; Wettzell static and kinematic suites
  unchanged; D1 GSDC pooled medians within their gate. The change alters the
  single-system numerics (the gauge is now applied), so tolerance-gated truth
  tests may shift within tolerance but must not fail.

## Promotion discipline

Reference-first: extend the Elixir gauge clause, then the Rust kernel block,
op-for-op, with the full per-epoch === parity gate proving the kernels stay
bit-equal on the single-system arc with the gauge active. The change is the
same in both kernels (drop the multi-system-only guard); the gauge math is
unchanged. No new options: the gauge is a conditioning property of the solve,
always on.
