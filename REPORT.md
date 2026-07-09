# Parity Lane PE Report

Worktree: `/private/tmp/pl-ex`

## #8/#9/#13 RTK Sequential Arc, Static Arc, Wide-Lane Fixed

Partially closed.

Closed in this run:

- `Sidereon.GNSS.RTK.solve_arc/2` now returns `%Sidereon.GNSS.RTK.ArcSolution{}` with typed nested `%ArcEpochSolution{}`, `%ArcState{}`, and `%ArcCycleSlipSplit{}` rows.
- `Sidereon.GNSS.RTK.solve_static_arc/2` now returns `%Sidereon.GNSS.RTK.StaticArcSolution{}`.
- `Sidereon.GNSS.RTK.fix_wide_lane_rtk_arc/2` now returns `%Sidereon.GNSS.RTK.WideLaneArcSolution{}`.
- `Sidereon.GNSS.RTK.prepare_ionosphere_free_rtk_arc/3` now returns `%Sidereon.GNSS.RTK.IonosphereFreeArcSolution{}`.
- `Sidereon.GNSS.RTK.solve_wide_lane_fixed_rinex_rtk_baseline/5` now attaches typed `%Sidereon.GNSS.RTK.WideLaneFixedMetadata{}` metadata.

Still remaining:

- Input config structs for the full Python RTK arc class model were not added in this subset; the existing map config input remains the marshaling surface.

Proof tests:

- `test/gnss_rtk_test.exs`: `solve_arc/2 delegates raw arc epochs to the core sequential arc solver`
- `test/gnss_rtk_test.exs`: `solve_static_arc/2 delegates raw arc epochs to the core static arc solver`
- `test/gnss_rtk_test.exs`: `fix_wide_lane_rtk_arc/2 surfaces geometry quality for a synthetic dual-frequency arc`
- `test/gnss_rtk_test.exs`: `solves the WTZR to WTZZ wide-lane fixed baseline from raw dual-frequency RINEX`

## #48 SBAS Protection Levels

Closed by existing surface.

`Sidereon.GNSS.SBAS.sbas_protection_levels/3` and typed public rows already mirror the Python/wasm protection-level call path over the existing NIFs.

Proof tests:

- `test/build_015_bindings_test.exs`: `SBAS K multipliers and fixed protection levels match core reference`

## #56 Geometry Visibility Set Completion

Closed by existing surface.

`Sidereon.GNSS.Geometry.visible/4`, `visibility_series/5`, `passes/5`, and `dop/4` cover the SP3-backed visibility helper set exposed by Python/wasm.

Proof tests:

- `test/gnss_geometry_test.exs`: `visible/4 no returned satellite is below the elevation mask`
- `test/gnss_geometry_test.exs`: `visible/4 counts match a manual az/el filter via Observables`
- `test/gnss_geometry_test.exs`: `visibility_series counts visible satellites per epoch`
- `test/gnss_geometry_test.exs`: `a satellite that rises and sets has its peak between rise and set`

## #60 Ephemeris Sample Rows

Closed by existing surface.

`Sidereon.GNSS.PreciseEphemerisSample`, `Sidereon.GNSS.PreciseEphemeris`, and `Sidereon.GNSS.PreciseEphemeris.Interpolant` provide the sample-row and interpolant public type surface.

Proof tests:

- `test/precise_ephemeris_samples_test.exs`: `SP3.precise_ephemeris_samples/1 extracts one sample per real position record`
- `test/precise_ephemeris_samples_test.exs`: `PreciseEphemeris.from_samples/1 validation sample source matches the SP3-parsed source within round-trip tolerance`
- `test/precise_interpolant_artifact_test.exs`: `builds, opens, checksums, and evaluates artifact bytes`

## #77/#78 Tides and Almanac Module-Level Parity

Partially closed by existing surface.

Existing root and module wrappers expose the tested tide, body, and almanac calls. I did not widen this row in this subset.

Still remaining:

- A separate module-level parity sweep against every Python/wasm almanac helper name.

Proof tests:

- `test/public_tides_bodies_test.exs`
- `test/phase_b_api_test.exs`

## #88 Estimation Public Wrapper Set

Partially closed by existing surface.

The existing estimation modules expose alpha-beta, NIS, CFAR, and track filter wrappers. I did not add wrappers in this subset.

Still remaining:

- Cross-check every Python/wasm estimation helper against a named Elixir wrapper.

Proof tests:

- `test/estimation_primitives_test.exs`
- `test/statistics_test.exs`

## #62/#32/#33/#34 Staleness and SP3 Precise Accessors

Partially closed by existing surface.

Existing staleness selectors, SP3 merge tests, precise samples, and interpolant artifact wrappers cover much of the row. I did not widen this row in this subset.

Still remaining:

- Public accessor audit for every SP3 merge reconciliation and precise-interpolant method exposed in Python/wasm.

Proof tests:

- `test/staleness_test.exs`
- `test/sp3_merge_test.exs`
- `test/precise_ephemeris_samples_test.exs`
- `test/precise_interpolant_artifact_test.exs`

## #21 RAIM For Solution

Closed in this run.

Added `Sidereon.GNSS.QC.raim_for_solution/2` as the first-class direct wrapper for an existing SPP solution, matching the Rust/C naming while using the same residual RAIM NIF path.

Proof tests:

- `test/gnss_qc_test.exs`: `raim/2 on a clean SP3-synthesized set clean solve recovers truth and RAIM passes`

## #90/#92 Fusion And Signal

Partially closed by existing surface.

The current Elixir surface already includes a typed GNSS/INS fusion subset and signal analysis/correlator wrappers. I did not widen these rows in this subset.

Still remaining:

- Expand toward the broader Python typed class model under the gated subset rule.

Proof tests:

- `test/gnss_fusion_test.exs`
- `test/gnss_signal_analysis_test.exs`
- `test/gnss_signal_correlator_test.exs`
- `test/gnss_signal_ca_test.exs`

## #93 Terrain/Geoid Store Drift

Partially closed by existing surface.

Geoid and mmap terrain store wrappers are present and tested. I did not widen data acquisition or terrain-store parity in this subset.

Still remaining:

- Terrain store/data catalog parity sweep against the Python convenience layer.

Proof tests:

- `test/geoid_test.exs`
- `test/geoid_egm96_test.exs`
- `test/build_012_bindings_test.exs`: `terrain height_batch matches scalar DTED lookups in longitude-first order`
- `test/build_012_bindings_test.exs`: `mmap terrain store matches DTED reader and missing EGM96 DAC is typed`

## Run 2

### #90 Fusion/Inertial

Still remaining.

No fusion/inertial surface was widened in this gated subset.

### #92 Signal Analysis

Still remaining.

No signal-analysis surface was widened in this gated subset.

### #93 Terrain/Geoid Store Drift

Still remaining.

No terrain/geoid store surface was widened in this gated subset.

### #88 Estimation Public Wrapper Set

Closed in this run.

Cross-checked the Python/wasm estimation helper names against the Elixir public surface. Added the missing canonical helper-name wrappers over the existing NIF-backed paths:

- `Sidereon.Estimation.nis_statistic/2`
- `Sidereon.Estimation.nis_gate_test/4`
- `Sidereon.Estimation.mad_spread/2`
- `Sidereon.Estimation.ewma_update/3`
- `Sidereon.Estimation.ewma_update_power_of_two/3`
- `Sidereon.Estimation.TrackInnovation.gate/2`

Intentionally-not:

- Python/wasm expose `TrackCoordinateFrame` enum/class names; Elixir already uses the idiomatic atom values `:ecef`, `:enu`, and `:caller_defined_cartesian` in `Sidereon.Estimation.TrackFilterConfig` and `Sidereon.Estimation.TrackState`.

Proof tests:

- `test/estimation_primitives_test.exs`: `alpha-beta step, NIS, MAD, EWMA, and CA-CFAR match analytic references`
- `test/estimation_primitives_test.exs`: `track innovation gate uses the NIF-backed chi-square threshold`

### #77/#78 Tides and Almanac Module-Level Parity

Still remaining.

No tides/almanac module-level sweep was completed in this gated subset.

### #62/#32/#33/#34 Staleness and SP3 Precise Accessors

Still remaining.

No SP3 merge-reconciliation or precise-interpolant accessor sweep was completed in this gated subset.

### #8/#9/#13 RTK Arc Input Config Structs

Closed in this run.

Added typed public RTK arc input config structs while keeping map input accepted:

- `Sidereon.GNSS.RTK.MeasurementModel`
- `Sidereon.GNSS.RTK.FloatOptions`
- `Sidereon.GNSS.RTK.FixedOptions`
- `Sidereon.GNSS.RTK.ResidualValidationOptions`
- `Sidereon.GNSS.RTK.ArcUpdateOptions`
- `Sidereon.GNSS.RTK.ArcPreprocessing`
- `Sidereon.GNSS.RTK.ArcConfig`
- `Sidereon.GNSS.RTK.StaticArcConfig`
- `Sidereon.GNSS.RTK.WideLaneOptions`
- `Sidereon.GNSS.RTK.DualCycleSlipConfig`
- `Sidereon.GNSS.RTK.WideLaneArcConfig`
- `Sidereon.GNSS.RTK.IonosphereFreeArcConfig`

Proof tests:

- `test/gnss_rtk_test.exs`: `accepts typed arc config structs on the real sequential solver path`
- `test/gnss_rtk_test.exs`: `accepts typed static arc config structs on the real static solver path`
- `test/gnss_rtk_test.exs`: `accepts typed wide-lane and ionosphere-free arc config structs`
