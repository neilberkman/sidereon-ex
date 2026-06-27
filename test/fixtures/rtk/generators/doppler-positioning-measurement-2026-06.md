# Doppler positioning measurement, June 2026

Spec: `doppler-positioning-spec.md`. Capability: Doppler receiver velocity and
Doppler-aided positioning in the Elixir reference layer of orbis.

Fixtures built by
`mix run test/fixtures/rtk/generators/doppler_velocity_fixture_2026_06.exs` from the
staged GSDC corpus. Gate pinned in `test/gnss_doppler_velocity_real_arc_test.exs`.

## What changed

No `Orbis.GNSS.Velocity` code change. `Velocity.solve/5` already implements the
standard range-rate least squares and is mathematically correct; the gap was
test-only. Before this work the only committed velocity test was a synthetic
injected-velocity self-recovery test, with no committed test against a real
receiver oracle. This adds a pinned, oracle-gated real-arc Doppler-velocity test
plus the self-contained fixtures it loads.

## Oracle

VELOCITY ORACLE: central finite-difference of the GSDC carrier-phase
post-processed ground-truth ECEF track, the `truth_ecef_m` field of the vendored
RTKLIB demo5 oracle `gsdc_2021_12_15_mtv1_pixel5_p222_demo5_rtklib_oracle.json`,
differenced over the matched GPST epoch grid. The vendored RTKLIB oracle JSONs are
position-only: they contain no Doppler and no velocity, so RTKLIB is not a usable
Doppler-velocity oracle here without regenerating it with a velocity-enabled
config. The truth-track finite difference is the defensible velocity reference and
models the true receiver kinematics.

ARC: `gsdc_2021_12_15_mtv1_pixel5` (2021-12-15 US-MTV-1, Pixel 5), the fastest of
the four vendored arcs (truth median speed 24.2 m/s), GPS L1 only.

## Metric

Per-epoch 3D velocity-vector error = `norm(v_doppler - v_truth)` over eligible
epochs (>= 4 GPS D1C satellites with a valid broadcast-code SPP position). Receiver
position for the velocity solve is broadcast-code SPP at that epoch. Truth velocity
is the central finite difference of the oracle truth track.

## Result

| Quantity | Value | Bar | Verdict |
|---|---:|---:|---|
| eligible epochs (n) | 1465 | >= 1000 | pass |
| median 3D velocity error | 0.250 m/s | <= 0.50 m/s | pass |
| p95 3D velocity error | 1.516 m/s | <= 2.50 m/s | pass |
| truth median speed | 24.21 m/s | > 5.0 m/s (fast-drive guard) | pass |
| epochs failed to solve | 0 | 0 | pass |

The thinned GPS-only NAV fixture reproduces the full-NAV D1 campaign velocity
result for this arc (campaign median 0.250 m/s, p95 1.513 m/s, n 1465), confirming
the thinning is faithful.

Cross-arc context from the archived D1 campaign (`d1-doppler-dynamics-2026-06.md`,
full broadcast NAV, not re-pinned here): pooled rover velocity error across all four
vendored Pixel-5 arcs was median 0.237 to 0.271 m/s, p95 1.21 to 1.51 m/s, 1453 to
3136 epochs per arc. The pinned single-arc gate is representative of the pool.

## Verdict

Doppler receiver velocity from a cheap single-frequency phone is solid. The pinned
gate clears the pre-registered tolerance with margin (median 0.250 vs 0.50 m/s, p95
1.516 vs 2.50 m/s, n 1465). The capability is confirmed, not merely self-consistent.

## Doppler-aided position assessment

INVESTIGATED, declined as a new capability. SPP (`Orbis.GNSS.Positioning.solve`) is
the Rust NIF and out of scope. The only position-side Doppler hook is the RTK
filter's caller-supplied per-epoch `:velocity_mps` with a `:velocity_propagated`
dynamics model. The D1 campaign already fed `Velocity.solve` output into that hook
and swept process noise (sigma 0.5, 2.0, 5.0 m):

* best pooled `error_3d` median 7.345 m at sigma 0.5 m (4/4 arcs, 7664 epochs);
* error grows monotonically with larger velocity-propagation weight (7.345 to
  8.078 to 8.763 m as sigma goes 0.5 to 2.0 to 5.0), i.e. the propagation
  prediction is best when trusted least;
* clears the memoryless bar (9.533 m): pass; misses the demo5 bar (4.007 m): miss.

There is no oracle-supported gain from Doppler-aiding the degraded phone position,
so no new position gate is proposed. Verdict: Doppler-aided position does not clear
the decimeter-grade bar and is not improved by the velocity-aiding weight.

## Scope and invariants

Elixir reference and measurement only. No Rust kernel, NIF, or astrodynamics
change. No default-behavior change. The synthetic velocity test assertions are kept
unchanged; the real-arc gate is additive. The capability is validated by the truth
metric, never by loosening a tolerance.

## Reproduce

    # rebuild fixtures from the staged GSDC corpus
    ORBIS_BUILD=1 mix run \
      test/fixtures/rtk/generators/doppler_velocity_fixture_2026_06.exs

    # run the pinned gate
    ORBIS_BUILD=1 mix test test/gnss_doppler_velocity_real_arc_test.exs
