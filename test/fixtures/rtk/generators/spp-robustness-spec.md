# spp-robustness pre-registration spec (v2)

Pre-registered before measuring. Capability: opt-in FDE-in-solve robustness
(`:robust`) for `Sidereon.GNSS.Positioning.solve/4`. This is the rebuild of the
rejected `lane/ep-spp-robustness` (commit a07f2ae), fixing the three review
defects called out below. The prior branch was cut from an OLDER main and
deleted the post_process integrity gates; this rebuild is strictly additive over
current main 0.24.0, which already carries `check_rank`, `check_max_pdop`,
`check_plausible_position`, `check_converged`, and the redundancy metadata.

## Scope (house rules)

Elixir reference and measurement ONLY. The Rust kernel, the NIF, and the
astrodynamics crate are out of scope and not modified. `:robust` is additive and
defaults off; when not passed, `solve/4` is byte-identical to today.

`:max_pdop` is ALREADY on current main (a 0.24.0 gate in post_process); it is not
part of this rebuild and is not re-added.

## Three review defects, and the fix

DEFECT 1 (exhausted-but-faulted FDE returned a silent {:ok, faulted_fix}). The
`Sidereon.GNSS.QC` `fde_loop/8` cap branch returned `{:ok, ...}` when the
leave-one-out loop hit `max_iterations` with RAIM still flagging the fix as
faulted. RESOLUTION: that branch now returns `{:error, {:fault_unresolved,
test_statistic}}`, carrying the final RAIM statistic. The legitimate success
exits are preserved: a clean set (RAIM passes) and a non-testable geometry
(`dof <= 0`, where `raim/2` reports `fault_detected? false`) still return
`{:ok, %{solution, excluded, iterations}}`.

DEFECT 2 (`:robust` silently defaulted to harmful unit weights). Unit-weight FDE
treats ordinary phone code noise (several metres) as faults and over-excludes,
making real arcs worse. RESOLUTION: `:robust` REQUIRES an explicit noise basis.
`:robust true` returns `{:error, {:robust_requires_noise_model, :no_weights}}`
before any solve unless one of: (a) `:weights` is a `%{sat => inverse_variance}`
map (from `QC.weight_vector/2`), forwarded to RAIM; or (b)
`:unsafe_unit_weights: true`, the only route to unit-weight FDE, named to be
self-documenting and grep-able, for callers whose measurements are genuinely
sigma-1 clean (e.g. the synthetic SP3 oracle). Default `:robust` with no basis is
a hard refusal, never a worse fix.

DEFECT 3 (no real-data test that `:robust` without a usable noise model cannot
silently degrade a phone fix). RESOLUTION: a fast in-suite contract test asserts
the refusal, and a staged GSDC real-arc test asserts that over >= 100 matched
epochs robust-with-realistic-weights 3D median <= bare 3D median (no-op-or-
better) AND robust-with-no-model refuses.

## Implementation (additive, default-off)

In `Sidereon.GNSS.Positioning.solve/4`:

  * `:robust` (default `false`). When set, the solve routes through `QC.fde/4`,
    returns the cleaned `Solution`, and records the excluded satellites in
    `solution.metadata.fde`. The cleaned re-solve runs through the same
    run_solve/post_process, so `:robust` composes with the rank, `:max_pdop`,
    plausibility, and convergence refusals.
  * `:weights` / `:unsafe_unit_weights` / `:p_fa` tune or gate the RAIM test as
    above; ignored when `:robust` is not set.

No positioning math is added; FDE and the chi-square test already live in
`Sidereon.GNSS.QC`.

## Oracles

1. In-repo, deterministic SP3-synthesized labelled fault (exclusion
   correctness). Clean pseudoranges are synthesized from
   `test/fixtures/sp3/GRG0MGXFIN_20201760000_01D_15M_ORB.SP3` via
   `Observables.predict_all`, exactly as `test/gnss_qc_test.exs` does today, and
   a known bias is injected on one chosen satellite. The biased satellite is the
   ground-truth fault the robust solve must isolate. These measurements are
   sigma-1 clean, so `:unsafe_unit_weights` is the correct route here.

2. Position-domain GSDC Pixel-5 demo5/RTKLIB oracles (before/after on real
   degraded data). The four vendored
   `test/fixtures/rtk/gsdc_*_pixel5_p222_demo5_rtklib_oracle.json` files carry
   RTKLIB output position, GSDC truth position, and per-epoch 3D/horizontal error
   vs truth. They are the absolute BAR (median 3D ~3.6-4.5 m), not the input. Raw
   phone L1 observations come from the staged
   `/tmp/gsdc-work/<drive>/supplemental/gnss_rinex.21o` plus staged broadcast
   NAV, fed to `Positioning.solve` per epoch, matched to the oracle truth by
   GPST. If staged raw observations are not reachable the arc is reported
   BLOCKED; gate 1 is fully in-repo and unaffected.

## Gates (declared up front, never loosened)

GATE 1 (FDE exclusion correctness, deterministic SP3 oracle). Inject a known
bias on one satellite, sweep `{50, 100, 200, 500}` m, in an otherwise clean
GPS-only set (~7 sats at the fixture epoch), with `:unsafe_unit_weights` (clean
synthetic, sigma-1). PASS bar:

  * the robust solve excludes EXACTLY the biased satellite
    (`excluded == [{biased, :raim_excluded}]`);
  * the recovered 3D position error is within `clean_3d_error + 0.5 m`;
  * the clean set excludes nothing and is bit-identical to the bare solve.

GATE 1b (defect 1). An over-determined faulted set forced past `max_iterations`
with the fault still flagged returns `{:error, {:fault_unresolved, T}}`, never
`{:ok, faulted}`.

GATE 2 (before/after on real GSDC degraded data, position-domain oracle). For
each vendored arc, run sidereon SPP per matched epoch as (A) bare crate solve,
(B) robust with unit weights via `:unsafe_unit_weights` (the harmful mode,
recorded explicitly), and (C) robust with a realistic 5 m uniform phone code sigma
via `:weights`. Match to oracle truth by GPST. Metrics per arc: 3D and
horizontal median and p95 vs truth.

  * Population floor: >= 100 matched epochs per arc.
  * Credibility floor: sidereon bare 3D median within 2x the demo5 median
    (absolute-accuracy floor only; sidereon is unaided single-freq SPP vs tuned
    multi-GNSS RTK, so this is expected to fail and gates an absolute claim NOT
    made).
  * Robustness claim (declared, strict): robust-weighted 3D median <= bare AND
    p95 <= bare on EVERY usable arc, exact non-regression (<=), no slack. A
    non-positive delta or a single-arc miss is a documented NULL on the strict
    all-arc bar, reported, not massaged. The defensible shipped claim is the
    narrower one the data supports, stated with oracle/metric/n/tolerance.

GATE 3 (defect 2, real-data no-silent-degrade). On a staged GSDC arc:
robust-with-no-model returns `{:error, {:robust_requires_noise_model,
:no_weights}}` (never a fix), and robust-with-realistic-weights 3D median <= bare
3D median over >= 100 epochs (no-op-or-better, never a worse fix).

## Never weaken

The elevation mask, the post_process gates, and every existing assertion are
untouched. An out-of-tolerance or no-improvement outcome is a fail/null result
reported with oracle, metric, sample size, and tolerance. No tolerance gate is
loosened to manufacture a pass.
