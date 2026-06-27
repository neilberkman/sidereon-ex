# Arming gate default-on decision: pre-registration

Status: PRE-REGISTERED 2026-06-13, before any solver code change or
measurement run for this capability. Inherits the C+D campaign method
(cd-campaign-spec.md), the ar-commitment-spec.md mechanism-1 definition, and
the rover-gate-spec Amendment 1 refusal invariant verbatim.

## Question

Should `:ar_arming_sigma_m` (the convergence arming gate, mechanism 1 of
ar-commitment-spec.md) be ON by default with a wavelength-tied threshold,
instead of the current opt-in `nil` default?

The risk the task flags: a default arming threshold could delay or suppress
correct early fixes on clean, good-geometry arcs where early fixing is the
whole point. The gate keys on the formal baseline-block posterior sigma
(`sqrt(trace)` of the 3x3 position covariance, `ar_armed?/2`), which is a
formal-convergence proxy, not a truth-accuracy proxy.

## Candidate default

Wavelength-tied to the ambiguity wavelength. For GPS L1 the wavelength is
`lambda = 0.190293673 m`. The task names one quarter to one half of the
wavelength as the candidate band:

- quarter wavelength: `0.047573 m`
- half wavelength: `0.095147 m`

Both endpoints are measured, plus the `0.10 m` value used in the
ar-commitment sweep as an upper sanity point. The L1 half-wavelength AR
decision boundary is `0.095 m`, so the half-wavelength tie sits right at the
decision boundary and the quarter-wavelength tie sits well inside it.

## Arcs and the binding measurement

All measurements run with `filter_kernel: :elixir` (house rule: Elixir
reference only; no Rust kernel / NIF / astrodynamics change). The Rust kernel
is bit-exact to Elixir on these arcs via the existing parity gates, so the
decision carries; but since the only candidate change is a default flip, the
kernel is not modified here regardless.

Clean arcs (must not regress):

1. Wettzell static L1, COD SP3, WTZR base / WTZZ rover, mask 10, rtklib
   stochastic (code 0.3 / phase 0.003), candidate limit 200000, initial
   baseline `{0,0,0}`, process noise off. Oracle:
   `wtzr_wtzz_rtklib_precise_oracle.json` (first_fixed_index 1, fixed 119/120,
   final truth error 0.0032 m).
2. Wettzell kinematic L1, same arc and options, process noise 30.0. Oracle:
   `wtzr_wtzz_kinematic_gps_rtklib_oracle.json` (first_fixed_index 0, fixed
   119/120, mean truth error 0.0157 m).
3. Synthetic sequential filter arc (gnss_rtk_test.exs clean L1 synthetic),
   which the existing unit test expects to fix with no explicit arming option.

Protection arc (must keep its wrong-fix protection):

4. PASA/SCOA L1 static fix-and-hold, the exact Phase 2 sequential cell.
   Oracle: `pasa_scoa_2026_120_l1_static_fixhold_rtklib_oracle.json`
   (mean 0.107 m, Amendment 1 floor 0.214 m). This is the arc the gate exists
   to protect: with the gate it converts confident-wrong (222 fixed @ 0.7351 m)
   to correct (104 fixed @ 0.0297 m).

## Truth metric

Per arc, against the propagated ARP / marker truth baseline:
`first_fixed_index`, fixed-epoch count out of 120, fixed-population median 3D
error, final baseline 3D error.

## Pre-registered decision rule (no assertion is loosened either way)

Flip the default to the wavelength-tied value if and ONLY if ALL of:

- (a) Wettzell static: `first_fixed_index` stays in `[0, 1]` AND fixed count
  `>= 118` (oracle 119, existing real_arc gate margin -1) AND fixed median in
  the current `~0.0028 m` class.
- (b) Wettzell kinematic: `first_fixed_index == 0` AND fixed count `>= 114`
  (oracle 119, existing real_arc gate margin -5) AND final baseline error in
  the current mm class.
- (c) Synthetic: still fixes with no explicit option (`first_fixed_index`
  non-nil, fixed count `> 0`).
- (d) PASA/SCOA L1: retains its Amendment 1 PASS with the candidate default
  unset (fixed n `>= 20` AND fixed median `<= 0.214 m`).

If ANY clean arc (a/b/c) regresses, do NOT flip the default; report the
regression and leave the gate opt-in. A null result is a result.

Amendment 1 refusal invariant (binding on any claimed PASA/SCOA pass): fixed
n `>= 20` AND fixed median `<= 2x` the oracle median on the arc. Below n=20 it
is "underpowered", never a pass.

## Implementation rule

New behavior is additive and must default to current behavior unless the
decision above flips the default. If the decision is to flip: option unset
means "use the wavelength-tied default", an explicit positive value still
overrides, explicit nil/0 disables. If the decision is NOT to flip: no
behavior change ships; the only artifact is a doc note recording the measured
reason the gate is opt-in by design.

## Out of scope

- Any Rust kernel / NIF / astrodynamics change.
- A smarter accuracy-aware arming proxy (innovation magnitude, post-fit
  residual): that is a new capability with its own pre-registration, not this
  go/no-go.
