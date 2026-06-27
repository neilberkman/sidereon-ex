# Doppler positioning spec, June 2026

Pre-registered before measuring. Capability: `doppler-positioning`, Doppler receiver
velocity and Doppler-aided positioning in the Elixir reference layer of orbis.

## What is under test

`Orbis.GNSS.Velocity.solve/5` with `observable: :doppler`: receiver velocity and
clock drift from one epoch of phone GPS L1 Doppler (D1C) against broadcast
ephemeris, at a known receiver position. The module already implements the standard
range-rate least squares (`H = [-e, 1]`, `y = rho_dot - e.v_sat + c*sat_drift`); the
gap is that its only committed test is a synthetic injected-velocity self-recovery
test, with no committed test against a real receiver oracle. This spec pins a real
cheap-receiver Doppler-velocity gate.

## Capability claim

Doppler velocity from a cheap single-frequency phone (Pixel 5, GPS L1 only) on a
fast-moving drive recovers the receiver velocity vector to better than a metre per
second median against a decimeter-grade truth track.

## Oracle

VELOCITY ORACLE: central finite-difference of the GSDC carrier-phase post-processed
ground-truth ECEF track, the `truth_ecef_m` field of the vendored RTKLIB demo5
oracle JSON for the arc, differenced over the matched GPST epoch grid. This models
the true receiver kinematics, the correct reference for cheap-receiver Doppler
velocity. The vendored RTKLIB oracle JSONs are position-only and carry no Doppler
and no velocity, so RTKLIB itself is not usable as a Doppler-velocity oracle here;
the defensible velocity reference is the truth-track finite difference.

ARC: `gsdc_2021_12_15_mtv1_pixel5_p222_demo5` (2021-12-15 US-MTV-1, Pixel 5). Chosen
because it is the fastest of the four vendored arcs (truth median speed 24.2 m/s),
so the velocity vector is well above the truth-differencing noise floor and the
recovered direction is meaningful, not dominated by a near-static residual.

## Method

For each phone epoch that matches the oracle GPST grid and has at least four GPS
D1C observations:

1. receiver position = broadcast-code single-point solve from the phone GPS C1C
   pseudoranges at that epoch (broadcast NAV), several metres off truth, the same
   position source the D1 campaign used. A few metres of position error maps to a
   small velocity error through the line-of-sight geometry, acceptable here.
2. `Velocity.solve(nav, doppler_obs, epoch, receiver, observable: :doppler,
   carrier_hz: L1)` with the broadcast NAV as the geometry source.
3. truth velocity = central finite difference of `truth_ecef_m` over the GPST grid.
4. per-epoch 3D velocity error = `norm(v_doppler - v_truth)`.

Doppler sign: this arc's base station (P222) carries no Doppler observable, so the
sign basis falls back to the raw RINEX convention (sign = +1), the same basis the
D1 campaign applied to this arc. The sign is pinned explicitly in the fixture.

The pinned test loads a thinned GPS-only broadcast NAV fixture and a per-epoch
inputs fixture (Doppler observations with sign applied, SPP receiver ECEF, GPST
epoch, finite-difference truth velocity) and runs the real `Velocity.solve` so the
solver computes its own satellite geometry from real broadcast ephemeris. The
upstream RINEX-observation parse and SPP are tested elsewhere and are baked into the
inputs fixture.

## Truth metric and declared tolerance

METRIC: median and 95th-percentile per-epoch 3D velocity-vector error in m/s over
the eligible epochs of the arc.

PASS BAR (pre-registered, fixed assertions, never loosened to pass):

* median 3D velocity error <= 0.50 m/s
* p95 3D velocity error <= 2.50 m/s
* eligible sample size >= 1000 epochs (each with >= 4 GPS D1C satellites)

These tolerances are declared above the values observed in the D1 campaign
(median 0.250 m/s, p95 1.513 m/s, 1465 epochs for this arc) with headroom for
fixture thinning. Out of tolerance or n < 1000 is a FAIL, not a pass. The p95
headroom accounts for the truth finite-difference smoothing real acceleration at
~1 Hz, which inflates p95 independent of solver error.

## Doppler-aided position assessment

INVESTIGATED, declined as a new capability. The only position-side Doppler hook is
the RTK filter's caller-supplied per-epoch `:velocity_mps` with a
`:velocity_propagated` dynamics model. The D1 campaign already fed `Velocity.solve`
output into that hook and swept process noise. Result on the degraded phone arcs:
pooled `error_3d` median 7.345 m at the smallest process-noise sigma (0.5 m),
clearing the memoryless bar (9.533 m) but missing the demo5 bar (4.007 m), and the
error grows as the velocity-propagation weight is increased. There is no
oracle-supported gain to harden, and SPP (`Orbis.GNSS.Positioning.solve`) is the
Rust NIF and out of scope. Verdict reported against the existing pre-registered
position bars; no new position gate is proposed.

## Scope and invariants

Elixir reference and measurement only. No Rust kernel, NIF, or astrodynamics
changes. No default-behavior changes. The existing synthetic velocity test
assertions are kept unchanged; the new gate is additive. The capability is
validated by the truth metric above, never by loosening a tolerance.
