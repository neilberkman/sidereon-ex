# Multi-GNSS sequential filter with arming and gauge: validate and measure

Status: PRE-REGISTERED 2026-06-13, before the measurement run for this
capability. Inherits the C+D campaign method (cd-campaign-spec.md) and the
rover-gate-spec Amendment 1 refusal invariant verbatim. Siblings:
ar-commitment-spec.md (arming gate) and gauge-constraint-spec.md (multi-system
SD gauge). Scope is the ELIXIR reference and measurement only; the Rust kernel
port is downstream and out of scope here. Measurements run with
`filter_kernel: :elixir`.

## Capability statement

The sequential RTK fix-and-hold filter must resolve the multi-GNSS short
baseline (GPS + Galileo + BeiDou fixed, GLONASS float-only via
`:float_only_systems`) on the Wettzell WTZR (base) / WTZZ (rover) co-located
static pair, with:

- the existing multi-system SD gauge constraint active (one reference SD
  ambiguity pinned per constellation), so the continuous arc solves with no
  singularity and no sub-arc reset crutch;
- the additive `:ar_arming_sigma_m` convergence arming gate available and
  additive-safe (default nil = always armed = current behavior);
- GLONASS contributing to the float solution but never entering any integer
  fixed set (RTKLIB gloarmode=off).

This is a validate-and-document capability: origin/main (sidereon 0.22.0) already
ships the mechanism (`float_only_systems/1`, `apply_reference_sd_gauge` with the
multi-system path, per-system `baseline_reference_satellites`, `ar_armed?`).
The pre-registered question is whether the fixed population passes Amendment 1
against the multi-GNSS oracle, and whether arming is additive-safe (does not
regress) on this arc.

## Inputs

- Base obs: `test/fixtures/obs/WTZR00DEU_R_20201770000_01D_30S_MO_120epoch.rnx`.
- Rover obs: `test/fixtures/obs/WTZZ00DEU_R_20201770000_01D_30S_MO_120epoch.rnx`.
- Precise product: `test/fixtures/sp3/COD0MGXFIN_20201770000_01D_05M_ORB.SP3`.
- Oracle: `test/fixtures/rtk/wtzr_wtzz_multignss_static_rtklib_oracle.json`
  (RTKLIB rnx2rtkp v2.4.2-p13, `track_b_static_multignss_l1.conf`,
  pos1-navsys=45 GPS+GLONASS+Galileo+BeiDou, L1 only, brdc, saas, elmask=15,
  fix-and-hold, gloarmode=off).
- Truth: antenna ARP baseline `rover_arp - base_arp` from the marker ECEF
  coordinates adjusted by ARP heights (base 0.071 m, rover 0.284 m). 3D
  magnitude is frame-invariant, so the Sidereon ECEF baseline is compared directly
  to the ECEF ARP-difference truth (the oracle reports ENU; magnitudes match).
- Constellations: G, R, E, C; GLONASS float-only via `:float_only_systems`.

## Options (the same options as the existing real-arc multi-GNSS test)

`initial_baseline_m: {0,0,0}`, `max_iterations: 10`,
`on_cycle_slip: :split_arc`, `elevation_mask_deg: 10.0`,
`stochastic_model: :rtklib`, `code_sigma_m: 0.3`, `phase_sigma_m: 0.003`,
`ambiguity_wavelength_m: <per-sat multignss map>`,
`integer_candidate_limit: 200000`, `float_only_systems: ["R"]`,
`filter_kernel: :elixir`. Default hold (1.0e-4). Arming sweep adds
`ar_arming_sigma_m` from the pre-registered list below; the default-nil cell is
the headline.

Arming threshold list (pre-registered, no cherry-picking): `nil` (headline),
`0.10`, `0.05`, `0.047`.

## Truth metric

Per-epoch 3D position error of every integer-FIXED epoch's baseline vs the
antenna-baseline truth (frame-invariant ECEF magnitude). Compute fixed n and
fixed median.

## Pre-registered success bar (Amendment 1)

A fixed-population PASS requires:

- fixed n >= 20 AND
- fixed median 3D error <= 2x the oracle median on the arc
  (2 x mean_truth_error_m = 2 x 0.002311 = 0.004621 m).

Below fixed n = 20 the verdict is UNDERPOWERED, never a pass.

Secondary committed assertions (no tolerance loosening):

- continuous solve = 120/120 epochs in a single segment, no singularity;
- GLONASS never enters a fixed set (no `R*` key in `fixed_ambiguities_cycles`
  or in any epoch's `fixed_ambiguities`); GPS/Galileo/BeiDou do fix;
- per-system DD references present for all four constellations
  (`reference_satellites` has G/R/E/C keys);
- `sidereon_min_sats >= oracle floor` (the harness uses SP3/mask-10, the oracle
  uses brdc/mask-15; only the floor transfers, never per-satellite identity).

## Regression bar (no capability ships that regresses these)

- Full Elixir + kernel battery green.
- The existing real-arc multi-GNSS test's tolerance gates retained
  (final baseline < 0.01 m, 120/120 fixed, Rust===Elixir per-epoch parity):
  never weakened.
- The new Amendment 1 assertion is added as an independent block on the Elixir
  solution only, so it cannot fight the separately-gated Rust===Elixir parity.

## Promotion discipline

Validate-and-document; reference-first. No solver/library change is expected
(the mechanism is already shipped). The only additive work: (a) this spec, the
generator, and the measurement doc; (b) an Amendment 1 fixed-population
assertion added to the existing test without weakening any existing assertion.
The Rust kernel port is out of scope per house rules; measurements run with
`:elixir`.

## Caveats (pre-stated)

- This arc is easy: co-located true baseline, strong multi-system geometry, so
  the default already lands in the oracle class. Arming passes trivially here
  because fixing from epoch 0 is already correct; arming is validated as
  additive-safe and non-regressing on this arc, NOT as the correctness lever it
  was on the PASA/SCOA arc. The doc must say this plainly.
- Satellite-count/ephemeris mismatch with the oracle is intentional (SP3/mask-10
  vs brdc/mask-15). Only the floor invariant transfers.
