# Multi-GNSS sequential filter measurement, June 2026

Pre-registered in multignss-seq-spec.md. Generator:
`multignss_seq_measurement_2026_06.exs`. Per-cell JSON was emitted to
`/tmp/multignss-seq-measurement-2026-06-results.json`. This is a
validate-and-document capability: origin/main (orbis 0.22.0) already ships the
multi-GNSS sequential mechanism. No solver or library code was changed. The
only additive work is this measurement, the spec, the generator, and an
Amendment 1 fixed-population assertion added to the existing real-arc test
without weakening any existing assertion.

## Mechanism (already present on origin/main, validated here)

1. Per-system DD references: `baseline_reference_satellites` picks one reference
   per constellation. On this arc the reference set is `%{G: G..., R: R...,
   E: E..., C: C...}`, carried in `sol.metadata.reference_satellites` for all
   four systems.
2. `:float_only_systems` with `["R"]`: GLONASS ambiguities are removed from the
   integer search and from the ratio computation, so GLONASS contributes to the
   float solution but never enters a fixed set. This matches the RTKLIB
   gloarmode=off oracle. Verified: `glonass_fixed=false` in every cell, no `R*`
   key in `fixed_ambiguities_cycles`, no `R*` in any epoch's
   `fixed_ambiguities`.
3. Multi-system SD gauge: `apply_reference_sd_gauge` pins each system's
   reference-SD ambiguity at the hold weight. With four systems present the
   gauge is fully active (the original multi-system path, never the
   single-system guard that caused the PASA/SCOA epoch-124 singularity), so the
   continuous arc solves 120/120 in one segment on the default hold (1.0e-4),
   no sub-arc resets, no singularity.
4. `:ar_arming_sigma_m` arming gate: additive, default nil = always armed =
   current behavior. Withholds the integer search until the baseline posterior
   sigma converges. On this arc it is not needed for a pass (the geometry is
   strong enough that fixing from epoch 0 is already correct), but it is
   additive-safe and still passes.

## Inputs and epoch construction

- Base obs: `WTZR00DEU_R_20201770000_01D_30S_MO_120epoch.rnx`.
- Rover obs: `WTZZ00DEU_R_20201770000_01D_30S_MO_120epoch.rnx`.
- Precise product: `COD0MGXFIN_20201770000_01D_05M_ORB.SP3`.
- Oracle: `wtzr_wtzz_multignss_static_rtklib_oracle.json` (RTKLIB rnx2rtkp
  v2.4.2-p13 commit 71db0ff, `track_b_static_multignss_l1.conf`, pos1-navsys=45
  GPS+GLONASS+Galileo+BeiDou, L1 only, brdc, saas, elmask=15, fix-and-hold,
  gloarmode=off, no tide correction).
- Truth: antenna ARP baseline `rover_arp - base_arp`, marker ECEF adjusted by
  ARP heights (base 0.071 m, rover 0.284 m). The Orbis ECEF baseline magnitude
  is compared directly to the ECEF ARP-difference truth; 3D magnitude is
  frame-invariant so this matches the oracle's ENU report.
- Constellations: G, R, E, C; GLONASS float-only via `:float_only_systems`.
- 120 epochs built (the full arc).

## Options (the same options as the existing real-arc multi-GNSS test)

`initial_baseline_m: {0,0,0}`, `max_iterations: 10`,
`on_cycle_slip: :split_arc`, `elevation_mask_deg: 10.0`,
`stochastic_model: :rtklib`, `code_sigma_m: 0.3`, `phase_sigma_m: 0.003`,
`ambiguity_wavelength_m: <per-sat multignss map>`,
`integer_candidate_limit: 200000`, `float_only_systems: ["R"]`,
`filter_kernel: :elixir`. Default hold (1.0e-4). The arming sweep adds
`ar_arming_sigma_m` from the pre-registered list.

## Oracle context

`mean_truth_error_m = 0.002311 m` (the oracle median used for Amendment 1),
`final_truth_error_m = 0.001835 m`, 120/120 fixed, first fixed index 0.
Amendment 1 credibility floor = 2 x 0.002311 = 0.004621 m. Oracle satellites
per epoch: 14 to 17.

## Measured result (filter_kernel: :elixir, default hold)

| Arming sigma (m) | Continuous | First fix idx | Fixed n | Fixed median (m) | Final (m) | Per-system fixed | GLONASS fixed | Verdict |
|---|---|---:|---:|---:|---:|---|---|---|
| none (default) | solved 1 seg | 0 | 120/120 | 0.002834 | 0.003521 | G=8 E=7 C=1 | false | PASS |
| 0.10 | solved 1 seg | 15 | 105/120 | 0.002760 | 0.003521 | G=8 E=7 C=1 | false | PASS |
| 0.05 | solved 1 seg | 26 | 94/120 | 0.002750 | 0.003528 | G=8 E=6 C=1 | false | PASS |
| 0.047 | solved 1 seg | 27 | 93/120 | 0.002745 | 0.003502 | G=8 E=5 C=1 | false | PASS |

## Amendment 1 verdict

The headline cell (default, no arming) is the verdict:

- fixed n = 120 (>= 20), and
- fixed median 3D error = 0.002834 m (<= floor 0.004621 m).

Both conditions hold, so this is a clean PASS. The fixed population lands in
the oracle class (oracle mean 0.002311 m, our fixed median 0.002834 m), and the
final baseline (0.003521 m) is well under the existing test's 0.01 m gate and
near the oracle final (0.001835 m).

Every arming cell also PASSes: arming only delays the first fix (idx 15/26/27)
and trims the fixed population (105/94/93), each still well above n=20 with a
fixed median essentially unchanged (~0.00275 m). Arming is additive-safe and
non-regressing on this arc.

## Caveats

- This arc is easy. The true baseline is co-located (~1.7 m) with strong
  multi-system geometry, so the default already lands in the oracle class and
  fixing from epoch 0 is already correct. Arming therefore passes trivially
  here; it is validated as additive-safe and non-regressing, NOT as the
  correctness lever it was on the PASA/SCOA L1 arc (ar-commitment-measurement,
  where the default fixes wrong integers from epoch 18 and arming converts
  confident-wrong to correct). This measurement does not stress-test arming.
- Satellite-count / ephemeris mismatch with the oracle is intentional: Orbis
  uses COD0MGXFIN SP3 with elevation_mask_deg=10 (the harness sees 21-23 sats)
  vs RTKLIB brdc/elmask=15 (14-17 sats). The transferable invariant is
  `orbis_min_sats >= oracle floor`, asserted in the test; per-satellite
  identity and exact per-epoch counts are not asserted.
- The fixed-median truth metric compares the Orbis ECEF baseline magnitude to
  the ECEF ARP-difference truth; the oracle reports ENU. 3D magnitude is
  frame-invariant, so this is sound.

## Promotion status

Complete (Elixir reference, validate-and-document). The Amendment 1
fixed-population assertion is added to
`test/gnss_rtk_real_arc_test.exs` ("multi-GNSS static RTK filter reproduces the
RTKLIB Track B oracle with GLONASS float-only") as an independent block on the
Elixir solution only: fixed n >= 20 and fixed median 3D error <= 2x the oracle
mean_truth_error_m. The existing tolerance gates (final baseline < 0.01 m,
120/120 fixed, Rust===Elixir per-epoch parity) are retained and unweakened. The
Rust kernel port is out of scope per house rules; the measurement runs with
`:elixir`.
