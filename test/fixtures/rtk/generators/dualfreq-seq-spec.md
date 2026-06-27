# dualfreq-seq capability spec (pre-registration)

Pre-registered BEFORE measurement. Capability key `dualfreq-seq`.

## Capability

Dual-frequency (L1/L2) sequential per-epoch fix-and-hold RTK filter:
wide-lane fixed up front, narrow-lane resolved sequentially per epoch,
reusing the existing arming gate (`:ar_arming_sigma_m`) and the single-system
SD gauge constraint that already exist on `solve_filter_baseline_epochs/3`.

## What is implemented vs deferred

Implemented (the largest correct sub-step): a wide-lane-fixed, narrow-lane
sequential filter. Wide-lane integers are estimated per double-difference arc
up front by Melbourne-Wubbena averaging (the existing batch pre-step,
`estimate_dual_baseline_wide_lanes`), then the narrow-lane single observable
per satellite (`ionosphere_free_baseline_epochs`: wavelength `c/(f1+f2)`,
offset `beta*lambda2*N_wl` with the wide-lane integer baked in) is fed into the
existing sequential machinery (`run_sequential_baseline_filter`) via the
per-ambiguity `:ambiguity_wavelength_m` / `:ambiguity_offset_m` maps. The
filter math (arming gate, gauge, holds, LAMBDA search, sequential carry of the
narrow-lane SD ambiguity) is unchanged; this is a new public entry point that
wires existing wide-lane/narrow-lane construction into the existing sequential
filter.

New public entry point: `solve_widelane_filter_baseline_epochs/3`. Additive:
the single-frequency `solve_filter_baseline_epochs/3` is untouched and its
behavior is unchanged. The new entry point validates against a widelane-filter
option set (the filter options minus the internally-derived
`:ambiguity_wavelength_m` / `:ambiguity_offset_m`, plus the wide-lane options).

Deferred (reported, not implemented): full sequential carry of the WIDE-LANE
ambiguity as a second filter state (per-epoch Melbourne-Wubbena carry plus
sequential wide-lane fix-and-hold) rather than an arc batch pre-fix. That needs
a second ambiguity layer (two wavelengths per satellite) in the sequential
state, which the current single-observable runner cannot carry without
restructuring `sequential_filter_epoch`. The wide-lane-as-batch-prefix sub-step
is the largest correct increment and matches what RTKLIB's continuous
dual-frequency mode effectively does for a static arc.

## Measurement

- Oracle: `test/fixtures/rtk/pasa_scoa_2026_120_l1l2_static_rtklib_oracle.json`
  (RTKLIB 2.4.2-p13, PASA00ESP rover vs SCOA00FRA base, 2026-04-30
  10:00-12:00 GPST, 240 epochs, 30 s, GPS-only, dual-frequency iono-free,
  CONTINUOUS AR). Oracle reference: epochs 240, fixed 80, fix_rate 0.333,
  first_fixed_index 2, final_status FLOAT, mean_truth_error 0.2081 m,
  final_truth_error 0.0581 m, max 0.9808 m.
- Arc construction: identical to the cd-measurement L1/L2 builder
  (`real_gps_l1_l2_rtk_epochs`), per-receiver transmit-time SP3 positions,
  elevation mask 15 deg, GPS only.
- Truth metric: per-epoch 3D baseline error vs the propagated EPN C2385
  ITRF2020 marker (marker = ARP for both stations).
- Filter kernel: `:elixir`. The Rust kernel port is a separate downstream step
  and out of scope; the measurement is not exercised with `:rust`.
- Options: same regime as the Phase 2 L1 sequential cell plus the arming gate.
  Code sigma 0.3 m, phase sigma 0.003 m, integer ratio threshold 3.0, hold on
  default, gauge on by default. Arming sigma swept; the registered headline
  cell uses the L1 reference's clean-pass arming value family (`<= 0.05 m`).

## Amendment 1 verdict (pre-registered bar)

Fixed-population PASS requires fixed n >= 20 AND fixed median 3D error
<= 2x the oracle median-on-the-arc. Oracle floor = 2 x mean_truth_error
= 2 x 0.2081 = 0.4163 m. The L1/L2 oracle is continuous-AR and ends FLOAT, so
its mean error (0.208 m) is higher than the L1 fix-and-hold oracle (0.107 m);
the dual-frequency floor is correspondingly looser at 0.416 m. A pass here is
therefore a weaker claim than the L1 sequential pass; this is stated plainly.

Below n = 20 the result is "underpowered", never a pass. Above the floor it is
FAIL-by-floor. The refusal-invariant and oracle-summary logic are reused
verbatim from `cd_measurement_2026_06.exs` so the verdict is computed
identically.

## Report

Continuous solve status (240/240 or segmented), fixed n, fixed median, fixed
p95, float median, final error, first-fixed index, the Amendment 1 verdict,
and the wide-lane fixed count. Secondary diagnostics (not the gate): the L1/L2
batch cells already in cd-measurement and the L1 sequential pass.

No tolerance gate is loosened; no existing assertion is weakened. If the result
does not clear n >= 20 at <= 0.416 m it is reported as underpowered or FAIL,
plainly.
