# AR commitment discipline: stop the sequential filter fixing wrong integers

Status: PRE-REGISTERED 2026-06-12, before any solver code or measurement runs
for this capability. Amendments require explicit Neil ratification recorded
here. Inherits the C+D campaign method (cd-campaign-spec.md) and the
rover-gate-spec Amendment 1 refusal invariant verbatim.

## Evidence base (already committed, cd-measurement-2026-06.md)

The sequential fix-and-hold filter commits integers far too early on the
PASA/SCOA L1 arc and then locks them:

- First fix at epoch index 18, when the carried float baseline error is well
  above the 0.095 m L1 half-wavelength AR decision boundary.
- Sequential fixed-epoch median error 0.7736 m (148/240 fixed) vs the RTKLIB
  fix-and-hold oracle at 0.107 m mean on the same arc.
- Receiver antenna corrections do not help: 0.7736 m to 0.7618 m, and they
  raise the wrong-fix count (148 to 189). Better physics buys more confidence
  in the same wrong integers.
- The full-arc batch search selects correct-class integers from the same data
  (0.0156 m), so the information is present; the sequential path commits
  before it can use it.
- RTKLIB reaches 0.107 m on the identical arc with the same per-epoch
  fix-and-hold structure, so a working commitment discipline is reachable, not
  speculative.

## Capability statement

The sequential filter must not enter (or must be able to back out of) an
integer fix that the float state cannot support at the half-wavelength scale.
Three candidate mechanisms are pre-registered. The choice among them (one,
or a composition) is made by measured truth against the oracle, not by taste.

1. Convergence arming gate. No AR search is attempted until a pre-registered
   float-state convergence proxy clears a threshold tied to the ambiguity
   wavelength (candidate proxy: the baseline-block posterior standard
   deviation from the filter covariance). Below the threshold the epoch stays
   float; the carried state keeps converging.
2. Hold re-validation. A held integer set must keep passing a post-fit
   residual / ratio re-check on subsequent epochs. A degrading hold is evicted
   back to float rather than carried (the RTKLIB arthres / fix-and-hold
   re-validation analog).
3. Commitment rollback. On a hold re-validation failure, the affected
   single-difference arcs return to float states and are eligible to re-fix
   once the state re-converges, instead of poisoning every downstream epoch.

## Pre-registered success bar

Primary arc: PASA/SCOA L1, the exact options of the Phase 2 sequential cell
(elevation mask, rtklib stochastic model, code 0.3 m / phase 0.003 m, L1
wavelength, ratio 3.0, candidate limit 200000).

- Refusal invariant (Amendment 1) verdict on the fixed population: fixed n
  >= 20 AND fixed-population median 3D error <= 2x the oracle median on the
  arc (floor = 2 x 0.107 = 0.214 m). Below n = 20 the verdict is
  underpowered, never pass.
- A refusal IS a pass of the invariant only if the float accuracy holds its
  class: declining to fix is acceptable, degrading the solution is not. The
  float-epoch median must stay within the measured float class (0.1455 m
  scale) when the discipline withholds fixes.
- The continuous arc must solve without the epoch-124 reset-sub-arc crutch
  for any cell that claims a pass (interacts with capability #3; if the
  singularity still requires sub-arc resets, the verdict is reported with
  that caveat and is not a clean pass).

Regression bar (no capability ships that regresses these):

- Full Elixir + kernel battery green (currently 856 tests).
- The sigma-sweep gate (real_arc_test) green at its current thresholds. The
  discipline must not be a back-door loosening of any existing gate.
- Wettzell static and kinematic suites unchanged.
- D1 GSDC pooled medians unchanged within their existing gate.

## Promotion discipline (binding)

Reference-first. The mechanism lands in the Elixir reference with its truth
and sweep gates, then ports to the Rust kernel with full per-epoch === gates
(baseline floats, statuses, ratios, residuals, metadata bit-equal across
kernels), exactly as the D1 dynamics and Phase 3a corrections did. No
tolerance gate closes the port. New filter options are additive and default
to current behavior so existing callers are unaffected until they opt in.

## Out of scope

- Iono and tide physics terms (separate ledger items; they target the batch
  ratio refusal, not the sequential wrong-fix problem).
- Capability #3 well-conditioned constraint handling is a sibling capability
  (the 1e8 hold-weight cancellation). It is referenced by the no-crutch
  clause above but specified and measured on its own.
