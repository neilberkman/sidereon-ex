# AR commitment discipline: measurement, June 2026

Pre-registered in ar-commitment-spec.md. Mechanism 1 (convergence arming
gate) is implemented in the Elixir reference as the additive
`:ar_arming_sigma_m` option (default nil = always armed = current behavior;
the Rust kernel refuses the option until ported). Generator:
`ar_sweep_2026_06.exs`. Arc and options are the Phase 2 PASA/SCOA L1
sequential cell; truth and floor are the vendored RTKLIB L1 fix-and-hold
oracle (mean 0.107 m, final 0.052 m, Amendment 1 floor 0.214 m).

## Instrument: where the baseline commits

A throwaway per-epoch print of the baseline-block posterior sigma
(sqrt of the trace of the 3x3 position covariance) on the uncorrected
sequential arc shows the first fix lands at epoch index 18 with baseline
sigma 0.1137 m, ABOVE the 0.095 m L1 half-wavelength AR decision boundary.
One epoch later the held set collapses the reported sigma to 0.004 m and the
wrong integers are locked. The float state needs many more epochs to
genuinely converge below the half-wavelength; the filter commits long before
it can.

## Sweep A: default hold (1.0e-4), continuous arc errors at epoch 124

With the shipped hold sigma the epoch-124 singularity (capability #3) still
fires, so the harness reports on reset sub-arcs and the fixed population is
confounded by per-segment re-convergence. Arming still produces correct
integers whenever it fixes:

| Arming sigma (m) | Fixed n | Fixed median (m) | Final (m) | Invariant |
|---|---:|---:|---:|---|
| none (baseline) | 148 | 0.7736 | 0.2605 | FAIL-by-floor |
| 0.10 / 0.08 / 0.06 | 17 | 0.0309 | 0.3768 | FAIL-by-n (17 < 20) |
| 0.05 | 11 | 0.0188 | 0.3768 | FAIL-by-n (11 < 20) |
| 0.04 | 60 | 0.0258 | 0.0261 | PASS (sub-arc caveat) |
| 0.03 / 0.02 | 0 | n/a | 0.1053 | FAIL-by-n |

The 0.04 cell passes the floor and the n >= 20 minimum, but every cell here
still uses the sub-arc reset crutch, so per the spec's no-crutch clause this
is a pass with caveat, not a clean pass. The non-monotonic population across
thresholds is the sub-arc confound (each reset re-converges the float), which
is exactly why sweep B uses the soft hold. Arming (1) and conditioning (3)
are coupled.

## Sweep B: interim soft hold (1.0e-3), clean continuous arc

With the known-safe soft hold the singularity is gone and all 240 epochs
solve in a single continuous segment (status solved, segs 1), isolating the
arming effect:

| Arming sigma (m) | First fix idx | Fixed n | Fixed median (m) | Final (m) | Invariant |
|---|---:|---:|---:|---:|---|
| none (baseline) | 18 | 222 | 0.7351 | 0.6572 | FAIL-by-floor |
| 0.10 | 136 | 104 | 0.0299 | 0.0234 | PASS |
| 0.08 | 136 | 104 | 0.0299 | 0.0234 | PASS |
| 0.06 | 136 | 104 | 0.0299 | 0.0234 | PASS |
| 0.05 | 136 | 104 | 0.0299 | 0.0234 | PASS |
| 0.04 | 136 | 104 | 0.0299 | 0.0234 | PASS |
| 0.03 | 136 | 104 | 0.0299 | 0.0234 | PASS |
| 0.02 | 136 | 104 | 0.0299 | 0.0234 | PASS |

## Verdict

Mechanism 1 (convergence arming gate) is the answer. On the clean continuous
arc it converts the sequential path from confident-wrong (222 fixed at
0.7351 m, FAIL) to correct (104 fixed at 0.0299 m, final 0.0234 m, PASS):
the fixed population lands in the oracle class, the median is well under the
0.214 m floor, and the final position beats the oracle final (0.052 m). The
soft hold alone does not do this (the baseline cell fixes 222 wrong integers
at 0.7351 m); the correctness comes from delaying commitment, not from the
hold.

The result is robust: every arming threshold in [0.02, 0.10] gives the
identical clean solve because the float baseline sigma stays above 0.10 m
until epoch 136 and then drops through the whole band within one epoch, so
the first armed epoch is the same. A default tied to the wavelength
(for example one half of the L1 half-wavelength, ~0.047 m) sits in the middle
of this plateau.

Two caveats:

- Sweep B uses the interim soft hold (hold sigma 1.0e-3) to isolate arming
  from the sibling epoch-124 singularity. That singularity is now fixed by the
  single-system SD gauge constraint (capability 3, gauge-constraint-spec.md and
  gauge-constraint-measurement-2026-06.md): on the DEFAULT hold the continuous
  arc solves and the arming clean pass reproduces sweep B (104 fixed, median
  0.0297 m, final 0.0234 m), so no soft-hold crutch is needed. Sweep A
  (default hold, no gauge) is retained as the pre-gauge record of the sub-arc
  confound.
- The sequential per-epoch float median for the armed cells is 0.40 m, worse
  than the 0.1455 m whole-arc batch float. This is the sequential float
  reality on this poor-early-geometry arc, not a regression: arming gates only
  the integer search, never the float update, so the float path is unchanged
  from the baseline. Arming correctly declines to fix during the loose-float
  stretch rather than committing wrong integers there.

## Promotion status

Complete. The gate is in the Elixir reference and ported to the Rust kernel
(astrodynamics-gnss `search_and_hold` takes an optional arming sigma; op-order
identical to the Elixir `ar_armed?`). Coverage: the Elixir unit tests (arming
withholds every fix below an unreachable threshold, leaves always-armed
behavior intact above any sigma, rejects bad values, and is accepted by both
kernels), the Rust kernel unit assertion, and a full per-epoch === parity gate
on the PASA/SCOA arc (both kernels bit-equal with arming and the soft hold,
fixed median <= 0.214 m). Full battery 859 passed; sigma-sweep gate green. The
Rust kernel change ships in a later astrodynamics-gnss release; the sidereon lane
pins the kernel rev until then.
