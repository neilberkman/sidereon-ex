# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.32.0] - 2026-06-16

### Added

- Opt-in `:strategy` option (`:reference` default, or `:canonical`) on the SP3 and
  broadcast `Positioning.solve/4`, `RTK.solve_float_baseline_epochs/3` /
  `solve_fixed_baseline_epochs/3`, and `PrecisePositioning.solve_float_epochs/3` /
  `solve_fixed_epochs/3`. `:canonical` selects the canonical (IERS/IGS-rigorous)
  estimation strategy from `astrodynamics-gnss` 0.21.0: full iterative light-time
  with the closed-form Sagnac correction and a consistent WGS84/ITRF basis for SPP,
  and a numerically rigorous square-root-information solve for RTK and PPP. The
  default is byte-identical to 0.31.0 (the reference-faithful result), proven by a
  default-equals-reference bit-for-bit test. An unknown value returns
  `{:invalid_option, :strategy}`; `:canonical` is refused on the robust-FDE path and
  on the RTK sequential-filter / wide-lane paths rather than silently ignored.

## [0.31.0] - 2026-06-16

### Changed

- Rebuilds the native solver on `astrodynamics-gnss` 0.20.0, whose SPP / RTK /
  PPP estimators are now consolidated onto one shared estimation substrate plus
  runtime-selectable named-recipe strategies. The consolidation is
  behavior-preserving: every solver result is bit-identical to 0.30.0 and all
  reference goldens are unchanged. No public API or numerical change.

## [0.30.0] - 2026-06-16

### Changed

- Rust-primary port: GNSS modeling that previously lived in the Elixir wrapper
  now lives in the `astrodynamics-gnss` crate behind an unchanged public API.

## [0.29.1] - 2026-06-15

### Changed

- `Sidereon.GNSS.SP3.merge/2` and `Sidereon.GNSS.Data.fetch_merged_sp3/3` now combine
  source products with different native epoch intervals by decimating the finer
  ones onto a common coarser grid (exact subset selection, no positional
  interpolation), instead of rejecting the merge. This lets ultra-rapid products
  published at different cadences be consensus-merged across the full center set
  (e.g. `fetch_merged_sp3(target, [:igs_ult, :cod_ult, :esa_ult, :gfz_ult],
  combine: :precedence, systems: [:gps], epoch_interval_s: 900)` - IGS/ESA at
  15 min, CODE/GFZ at 5 min - now returns `{:ok, %SP3{}, provenance}`). Inputs
  whose interval does not evenly divide the common grid are still rejected;
  same-interval merges are unchanged. Rides astrodynamics-gnss 0.18.0.

## [0.29.0] - 2026-06-15

### Added

- PPP per-range correction stack for the static float/fixed precise-positioning
  solve, all opt-in (no change to default behaviour):
  - `solid_earth_tide`: IERS DEHANTTIDEINEL station displacement.
  - `phase_windup`: demo5/RTKLIB carrier-phase wind-up (nominal yaw attitude),
    applied to the phase observable only.
  - `satellite_antenna`: satellite antenna PCO/PCV from an ANTEX file, iono-free
    combined, projected onto the line of sight.
  These ride `astrodynamics` 0.11.0 (analytic Sun/Moon in ITRS, corrected for an
  of-date precession double-count) and `astrodynamics-gnss` 0.17.0 (solid-earth
  tide kernel). The Sun/Moon and tide kernels are validated through the NIF
  against Skyfield/DE440 and IERS golden vectors.
- RINEX `SYS / PHASE SHIFT`: the parsed `correction_cycles` are now applied to
  the carrier-phase observable (previously parsed but never applied).
- GLONASS FDMA: `Sidereon.GNSS.Velocity` accepts a per-satellite carrier
  (`:carrier_hz_by_sat`) so a GLONASS Doppler is converted to range rate with its
  own slot frequency instead of a single global GPS L1 carrier.

### Documentation

- Clarified the IONEX rapid/predicted fetch story. The latest-available-day
  candidate fallback described in 0.28.0 is delivered by `fetch_ionex/3` (which
  walks candidate days newest-first), not by `fetch/2` on a single product, which
  is single-shot by design. The `mgex_ionex/3`, `rapid_ionex/2`, and
  `predicted_ionex/3` docs now point to `fetch_ionex/3` for fallback fetching.
- Documented that the CODE rapid GIM (`:cod_rap`) is a rolling-recent window on
  the AIUB `/CODE` root (current day not yet published; files older than roughly
  three days roll off), and that the predicted map (`:cod_prd1`) is preferred for
  same-day use.

## [0.28.0] - 2026-06-14

### Added

- Lower-latency CODE IONEX (global ionosphere TEC map) products in the data
  catalog, alongside the existing final `COD0OPSFIN`: `:cod_rap` (rapid GIM,
  `COD0OPSRAP`) and `:cod_prd1` / `:cod_prd2` (predicted GIM, `COD0OPSPRD`, the
  map for the requested UTC day and the day after). Final GIMs lag one to three
  weeks; the rapid and predicted maps resolve same-day / before-the-day over the
  AIUB CODE archive, so a near-real-time ionosphere map is now fetchable through
  the same path as the final IONEX. Rapid and predicted lines carry a
  latest-available-day candidate fallback, mirroring the SP3 ultra-rapid pattern.
  Single-product fetch only (no merge/combine). IGS rapid IONEX has no verified
  open mirror and remains in the no-open-mirrors set.

## [0.27.0] - 2026-06-14

### Fixed

- SP3 satellite-orbit interpolation (via `astrodynamics-gnss` 0.16.0): the
  position channel was a global cubic spline that erred ~200 m at the day
  boundary and across coverage gaps, invisible in double-differenced RTK (it
  cancels) but corrupting undifferenced precise positioning. Replaced with the
  IGS/RTKLIB-standard sliding-window Lagrange. Anyone using SP3-based
  undifferenced positioning should upgrade.

### Added

- A-priori Saastamoinen troposphere in the dual-frequency RTK path (matching
  RTKLIB `tropopt=saas`), improving short/medium-baseline fixes; default on,
  `troposphere: false` to disable.
- Precise-positioning foundation toward static-arc PPP: cycle-slip arc-splitting
  in the iono-free float solve, a RINEX clock (`.CLK`) reader, receiver-antenna
  PCO/PCV and SP3 satellite-clock relativity applied through a single
  per-one-way-range correction point, a configurable data-gap arc reset, and a
  post-fit residual screen. The ratio-test threshold now rejects values below
  1.0 (which would silently disable ambiguity validation).

### Changed

- Rides `astrodynamics-gnss` 0.16.0.

## [0.26.0] - 2026-06-14

### Added

- `Sidereon.GNSS.Positioning.solve/4` gains an opt-in `:huber` option: a
  crate-layer Huber/IRLS robust reweighting loop that recomputes each
  satellite's weight from its post-fit residual, down-weighting multipath and
  gross code outliers on cheap single-frequency receivers rather than excluding
  whole satellites. Tunable via `:huber_k`, `:huber_sigma` (MAD scale floor,
  default 5.0 m), and `:huber_max_iter`. Default off and byte-identical to the
  static elevation-weighted solve when unused. On the vendored GSDC Pixel-5
  arcs it improves the 3D median and p95 on every arc with no loss of
  availability.
- When `:huber` runs, `solution.metadata` carries `:huber` with the
  `outer_iterations` count and the `final_scale_m` (the last MAD robust scale);
  the key is absent on the default path.

### Changed

- Riding `astrodynamics-gnss` 0.15.0 / `astrodynamics` 0.10.0, which carry the
  robust-reweighting kernel.

## [0.25.0] - 2026-06-13

### Added

- `Sidereon.GNSS.Positioning.solve/4` accepts an opt-in `:robust` flag that routes
  the single-point solve through RAIM leave-one-out fault detection and
  exclusion. It requires a real measurement noise model: a `:weights` map with a
  positive, finite weight for every observed satellite (extra keys are ignored),
  or the explicit `:unsafe_unit_weights` escape hatch. Without a noise model it
  refuses (`{:error, {:robust_requires_noise_model, :no_weights}}`) rather than
  silently running unit-weight FDE, which degrades real receiver fixes. An
  exhausted-but-still-faulted search returns `{:error, {:fault_unresolved, statistic}}`,
  and the exclusion ledger is reported in `solution.metadata.fde`.
- `solve/4` accepts an opt-in `:coarse_search` that widens the cold-start
  convergence basin from a degraded or absent position prior by solving from a
  deterministic golden-spiral lattice of near-surface seeds and selecting the
  best redundant converged fix. It is mutually exclusive with `:robust`. Default
  off (`nil`) preserves the single exact solve.

### Notes

- All `solve/4` robust and coarse options are additive and default to current
  behavior; with neither set the solve is unchanged from 0.24.0. Malformed
  robust/coarse option values return tagged `{:error, _}` rather than raising.

## [0.24.0] - 2026-06-13

### Fixed

- `Sidereon.GNSS.Positioning.solve/4` no longer returns a fix that did not converge
  to a physical receiver position. A fix whose geocentric radius is outside the
  plausible band (for example a degenerate first step from the earth-center
  default seed, previously returned as a ~6.4e6 m "converged" position, or a
  wrong-root least-squares fix whose residuals are forced to zero by an exactly
  determined geometry) is refused with `{:error, {:implausible_position, radius_m}}`,
  and a converged-flagged fix with physically implausible post-fit residual RMS
  with `{:error, {:no_convergence, rms_m}}`. A rank-deficient geometry (no DOP
  cofactor inverse, which is also what lets a wrong-root mirror land on the
  plausible shell) is refused with `{:error, {:degenerate_geometry, :rank_deficient}}`.
  These are behavior changes: inputs that previously returned a bogus
  `{:ok, solution}` now return a tagged error.

### Added

- `solve/4` solution metadata now carries the geometry redundancy:
  `used_count`, distinct `systems`, `redundancy` (degrees of freedom,
  `used_count - (3 + systems)`), and `raim_checkable?`. An exactly determined
  fix (`redundancy < 1`) is now visibly unverifiable rather than appearing
  perfect at zero residual.
- `solve/4` accepts an optional `:max_pdop` ceiling: a rank-deficient or
  high-PDOP geometry is refused with `{:error, {:degenerate_geometry, pdop}}`,
  and a non-positive ceiling is `{:error, {:invalid_option, :max_pdop}}`.
- A real-arc Doppler-velocity regression gate for `Sidereon.GNSS.Velocity` on a
  cheap single-frequency phone arc (GSDC Pixel-5), checking receiver velocity
  against a finite-differenced truth track.

## [0.23.0] - 2026-06-13

### Added

- `Sidereon.GNSS.RTK.solve_widelane_filter_baseline_epochs/3`: a dual-frequency
  (L1/L2) sequential RTK filter. It resolves the Melbourne-Wubbena wide-lane
  integers per arc, forms the ionosphere-free narrow-lane observable, and runs
  the sequential fix-and-hold filter (including the convergence arming gate and
  the SD gauge constraint) on it. On the vendored PASA/SCOA L1/L2 arc it solves
  continuously and reaches a centimeter-class fixed solution. Available on both
  the Rust and Elixir kernels.

### Documentation

- Documented the `:ar_arming_sigma_m` convergence arming gate option and why it
  is opt-in by default.
- README install version, feature-table wording, and the example livebooks
  refreshed; the livebooks now install the hex release so they run from the
  Run-in-Livebook badge without a Rust toolchain.

## [0.22.0] - 2026-06-12

### Added

- `Sidereon.GNSS.RTK.solve_filter_baseline_epochs/3` accepts an opt-in
  `ar_arming_sigma_m` convergence arming gate: the per-epoch ambiguity search
  is attempted only once the baseline-block posterior standard deviation has
  converged to at most the threshold, so the sequential filter stops committing
  integers while the float state is still too loose to support a
  half-wavelength decision. The default (unset) preserves the always-armed
  behavior. Implemented in both kernels with a per-epoch bit-equality gate.

### Changed

- The reference single-difference ambiguity gauge constraint now applies to
  single-system arcs (previously multi-system only). The reference SD ambiguity
  is an unobservable gauge degree of freedom in any system count; on a long
  single-system arc with tight integer holds its pivot otherwise cancels to
  zero (a `:singular_geometry` failure). The gauge is a double-difference
  null-space constraint, so baselines and double differences are unchanged, but
  single-system sequential filter numerics now include it. Together with the
  arming gate, the continuous real-arc L1 filter resolves centimeter-class
  fixed solutions on the default ambiguity-hold sigma.

## [0.21.0] - 2026-06-12

### Added

- The Rust RTK filter kernel applies receiver antenna corrections
  (`:receiver_antenna_corrections`), previously accepted only by the `:elixir`
  kernel. PCO/PCV are projected in the double-difference row builder with
  op-for-op parity against the Elixir reference, gated for bit-equality across
  both kernels on the vendored PASA/SCOA real arc.

## [0.20.0] - 2026-06-13

### Added

- `dynamics_model: :velocity_propagated` - the filter's prediction mean
  advances by a caller-supplied per-epoch ECEF velocity (`:velocity_mps` on
  epochs); default remains constant-position. Bit-equality gated across both
  kernels.
- Optional per-epoch innovation screen (`:innovation_screen_sigma`,
  `:innovation_screen_min_rows`): rows with excessive normalized predicted
  residuals are excluded from the measurement update; epochs coast below the
  survivor floor. Implemented in both kernels with firing bit-equality gates
  and per-epoch screen metadata.
- `Sidereon.GNSS.Antex`: ANTEX 1.4 receiver-antenna parser (PCO/PCV with zenith
  and azimuth interpolation), gated against vendored reference values.
  Measurement-model application lands in a later release.

### Changed

- GNSS data downloads no longer use the deprecated Erlang `:ftp` transport,
  which is no longer started or listed as an application dependency.
- GNSS product URLs now resolve through verified open HTTP(S) archives:
  GFZ rapid/ultra via `isdc-data.gfz.de`, ESA final/ultra/IONEX via
  `navigation-office.esa.int`, IGS broadcast nav / IGS ultra / station OBS via
  `igs.bkg.bund.de`, and CODE products via AIUB at `ftp.aiub.unibe.ch`.
- Restored CODE products over AIUB plain HTTP: `{:cod, :sp3}` and
  `{:cod, :clk}` use `CODE_MGEX/CODE/<year>/COD0MGXFIN_...`, `{:cod, :ionex}`
  uses `CODE/<year>/COD0OPSFIN_...`, and `{:cod_ult, :sp3}` uses the recent
  `CODE/COD0OPSULT_...` product. AIUB does not offer HTTPS; transport
  integrity relies on the plain-HTTP channel for these public products.
- `Sidereon.GNSS.RTK.solve_filter_baseline_epochs/3` now defaults to the Rust
  RTK filter kernel. `:elixir` remains fully supported as the reference
  implementation.

### Removed

- Still-retired catalog products with no verified open HTTP(S) mirror:
  `{:grg, :sp3}`, `{:grg, :clk}`, `{:wum, :sp3}`, `{:wum, :clk}`,
  `{:grg_ult, :sp3}`, `{:grg_ult, :clk}`, and `{:igs, :ionex}` now return
  `{:error, {:no_open_mirror, {center, content}}}`.

### Notes

- The default ambiguity-hold sigma is unchanged (1.0e-4): a softer default
  (1.0e-3) cures a documented long-arc conditioning failure but measurably
  degrades clean kinematic accuracy (the sigma-sweep gate caught it), so the
  softer value remains an explicit per-arc option pending a proper
  constraint-conditioning capability. See the C+D measurement report.

## [0.19.0] - 2026-06-12

### Changed

- `filter_kernel` now defaults to `:rust`. The Elixir path remains fully
  supported as the reference implementation; every kernel capability is gated
  by bit-equality (`===`) trace tests against it.
- The FTP transport was removed (`:ftp` is deprecated and removed in OTP 30).
  GFZ/ESA/BKG products moved to verified HTTPS archives; CODE (AIUB) products
  are served over plain HTTP (AIUB offers no TLS); products with no open
  mirror return `{:error, {:no_open_mirror, {center, content}}}`.

### Added

- GSDC moving-rover oracle fixtures generated with RTKLIB-demo5 (four
  pre-registered arcs, committed generators, ratio test enabled) and the
  pre-registered moving-rover gate specification with measurement report.
- Multi-GNSS oracle regenerated with GLONASS ephemerides present
  (BRDC00WRD GREC nav); oracle gates tightened to exact fixed-epoch equality.
- Early `{:unsupported_widelane, :multi_gnss}` rejection for multi-GNSS
  dual-frequency widelane input.

## [0.18.0] - 2026-06-12

### Added

- `Sidereon.GNSS.RTK.solve_filter_baseline_epochs/3` now supports multi-GNSS RTK
  filter epochs with per-system reference satellites. GLONASS can be kept in the
  float solution via `:float_only_systems` while GPS/Galileo/etc. remain
  eligible for integer search and hold.
- The sequential RTK filter accepts `:process_noise_baseline_sigma_m` for
  kinematic baseline tracking. The default remains the static filter.
- Added four vendored RTKLIB oracle fixtures for the WTZR/WTZZ real arc,
  covering broadcast/precise and static/kinematic RTK tracks, with the generator
  configs and conversion script checked in with the fixtures.

### Fixed

- Fixed cold-start fixed epochs so the reported fixed solution uses the
  ambiguity-conditioned baseline from the same epoch instead of reporting the
  float baseline while marking the epoch fixed.

### Tests

- Added `===` bit-equality gates between the Elixir RTK filter path and the Rust
  NIF kernel for multi-GNSS references, GLONASS float-only handling, kinematic
  process noise, gauge constraints, held ambiguities, and cold-start fixes.
- Added a sigma-sweep RTK gate that exercises the filter across the measurement
  variance settings used by the real-arc parity tests.
- Multi-GNSS input to `solve_widelane_fixed_baseline_epochs/3` is rejected
  early with `{:unsupported_widelane, :multi_gnss}` (single-constellation
  scope; previously failed late at the delegated fixed solve).

## [0.17.0] - 2026-06-11

### Added

- `Sidereon.GNSS.RTK.solve_filter_baseline_epochs/3` gains an opt-in Rust filter
  kernel via `filter_kernel: :rust` (default remains `:elixir`). The kernel
  reproduces the Elixir sequential RTK information filter - iterated
  Gauss-Newton update with correlated double-difference measurement covariance,
  SD→DD ambiguity transform, LAMBDA search-and-hold, and the elevation-weighted
  / RTKLIB stochastic models - and is verified epoch-for-epoch against the
  Elixir path on real Wettzell arcs. Existing callers are unaffected.

### Changed

- The native NIF now builds against the published `astrodynamics-gnss` 0.10.0
  crate (was a git-rev pin), which carries the RTK filter kernel. The kernel
  hot path holds a measured baseline of ~210k single-core solves/sec on a
  6-satellite epoch with a CI-gated allocations-per-solve regression bound.

## [0.16.0] - 2026-06-10

### Added

- RTK fixed-baseline solving can now run an opt-in normalized-residual gate
  before integer search. When enabled, the solver excludes the worst offending
  satellite up to a bounded cap, re-solves, and reports the exclusions in
  solution metadata; if the residuals still fail, it returns a tagged
  `:residual_validation_failed` error with the offending residual.
- RTK float and fixed baseline solvers now accept `:elevation_mask_deg`, which
  removes satellites below the base-station elevation mask before reference
  selection and ambiguity construction. Masked satellites are reported in
  solution metadata.
- `Sidereon.GNSS.RTK.solve_filter_baseline_epochs/3` adds a sequential static RTK
  information filter: it carries baseline/ambiguity covariance epoch to epoch,
  attempts LAMBDA ambiguity fixing from the posterior covariance, and holds
  accepted integers with a configurable pseudo-measurement. The filter carries
  RTKLIB-style single-difference ambiguity states, searches/holds the
  corresponding double-difference integer combinations, and seeds the
  single-difference ambiguities from phase-code differences rather than starting
  every ambiguity at zero.
- Sequential RTK epoch metadata now includes integer-search diagnostics
  (`integer_best_score`, `integer_second_best_score`, `integer_candidates`, and
  `ambiguity_search`) so parity/debug gates can inspect the posterior ambiguity
  vector, covariance, and postfit residuals at each fix attempt.
- RTK float/fixed/filter baseline solvers accept `stochastic_model: :rtklib`
  for RTKLIB's floor-plus-elevation single-difference variance shape. The
  default remains `:simple`.
- RTK baseline epochs may now carry receiver-specific
  `:base_satellite_positions_m` and `:rover_satellite_positions_m` maps for
  transmit-time satellite positions. When omitted, the solvers keep the previous
  shared `:satellite_positions_m` behavior.
- RTK float/fixed/filter baseline solvers now apply the first-order Sagnac
  Earth-rotation range correction by default (`sagnac: true`), with
  `sagnac: false` available for synthetic Euclidean fixtures.
- `Sidereon.GNSS.RINEX.Observations.antenna_delta_hen/1` exposes the parsed
  `ANTENNA: DELTA H/E/N` receiver antenna offset so real RTK gates and
  consumers can derive antenna-reference-point baselines from the observation
  product itself.
- `Sidereon.GNSS.RINEX.Observations.phase_shifts/1` exposes parsed
  `SYS / PHASE SHIFT` carrier correction metadata for correction-model and
  RTK parity work.

### Fixed

- The sequential RTK filter now starts a fresh ambiguity arc when a satellite
  reappears after an outage (set below the horizon, or lost lock without an LLI
  flag). Previously only an explicit LLI cycle slip broke an arc, so a re-risen
  satellite reused its pre-outage carrier-phase ambiguity - a stale integer that
  could differ from the truth and corrupt the static baseline. Re-acquisition is
  now always treated as a new arc, independent of the `:on_cycle_slip` policy;
  continuous arcs are unaffected.
- RTK APIs now reject unknown/misspelled options at the public boundary instead
  of silently falling back to defaults, and RTK residual finalization returns a
  tagged error if an internal row set is missing either the code or phase member
  of a double-difference pair. Fractional-epoch helpers in broadcast and SPP
  positioning also no longer carry dead error clauses that produced
  warnings-as-errors failures on newer Elixir compilers.

### Tests

- Added a vendored WTZR/WTZZ real RTK oracle fixture generated with RTKLIB
  `rnx2rtkp`. The fixture pins the L1+broadcast fix-and-hold reference target
  (119/120 fixed, first fix at 2020-06-25 00:00:30 GPST, millimetre final ARP
  baseline error) plus L1 instantaneous, L1 float, and L1/L2 comparison
  summaries. The provenance now records that RTKLIB defaults to broadcast
  ephemeris unless `pos1-sateph = precise` is set, so this fixture is not
  mislabeled as an SP3 parity oracle.
- Added a separate RTKLIB precise-mode fixture for the same WTZR/WTZZ arc,
  generated with `pos1-sateph = precise`, a CODE final SP3 orbit, and a
  CNES/CLS RINEX clock. The provenance records RTKLIB 2.4.2's lowercase `.sp3`
  staging requirement and pins that the precise run fixes the same 119/120
  epochs as the broadcast reference.
- The real WTZR/WTZZ RTK gate now builds receiver-specific transmit-time
  satellite-position maps and verifies the corrected geometry against committed
  fixture targets: the two-epoch prefix fixes below 1 cm, the 120-epoch
  single-frequency partial-AR path fixes a safe subset below 1 cm, and the
  dual-frequency wide-lane/narrow-lane path fixes the full set below 1 cm.

## [0.15.1] - 2026-06-09

### Fixed

- The internal integer least-squares search wrappers now reject malformed
  covariance dimensions with tagged errors before entering the NIF, and map the
  Rust kernel's non-finite/search-limit failures explicitly. Undersized matrices
  no longer panic the NIF, and oversized matrices are no longer silently
  truncated to a submatrix.

## [0.15.0] - 2026-06-09

### Fixed

- `Sidereon.GNSS.SP3.merge/2` and `Sidereon.GNSS.Data.fetch_merged_sp3/3` now reject
  heterogeneous SP3 merge inputs conservatively instead of emitting a corrupt
  union product: mixed epoch intervals must be resampled before merge (or match
  a requested `:epoch_interval_s`), coordinate-system labels must match exactly,
  and `combine: :precedence` selects one source per satellite arc rather than
  switching centers between adjacent epochs. Merge callers can also restrict the
  output with `:systems` (for example `[:gps]`).

### Added

- `Sidereon.GNSS.Constellation.health_timeline/2`, `health_state/1`, and
  `health_timeline_to_map/1` build deterministic health/outage intervals from
  timestamped catalog snapshots. The timeline reuses `diff/2` for snapshot
  transitions, reports derived health-state changes, preserves source metadata
  (including NAVCEN/NANU fields), supports stale-snapshot detection for catalog
  watchers, and serializes to a versioned map for notification/state files.

## [0.14.1] - 2026-06-09

### Fixed

- Re-published the 0.14.x release line with precompiled-NIF checksums matching
  the final GitHub release assets built against `astrodynamics-gnss` 0.9.4. The
  0.14.0 package was published before the final checksum file was committed, so
  supported platforms could reject the downloaded precompiled archive and fall
  back poorly. No API or numerical behavior changed from 0.14.0.

## [0.14.0] - 2026-06-08

### Added

- `Sidereon.GNSS.SP3.to_iodata/2` serializes an `%Sidereon.GNSS.SP3{}` product back to
  standard SP3-c / SP3-d text - the inverse of the reader, so a read → `merge/2`
  → write pipeline emits a single standard SP3 file any reader consumes. Pure and
  deterministic; header fields are derived from the product; a satellite absent
  at an epoch is written as the SP3 missing-orbit sentinel (so a quarantined
  merge cell re-reads as missing, never a fabricated position). Round-trips to
  SP3 format precision (mm / sub-ns) for position-only and position+velocity,
  multi-constellation products.
- `Sidereon.GNSS.Data.write_sp3/3` writes a product to disk with the fetch layer's
  atomic-commit discipline (same-directory temp file + `File.rename/2`), with an
  optional `gzip: true` for the gzipped-archive shape. Unblocks persisting a
  merged product, which was otherwise only an in-memory handle.
- `Sidereon.GNSS.Data.fetch_merged_sp3_file/4` composes `fetch_merged_sp3/3` and
  `write_sp3/3` into one call - fetch the merged current-day product from several
  ultra-rapid centers and persist it to a standard SP3 file, returning
  `{:ok, path, report}` so a live-latency product feeds the cache / observables /
  positioning layers with no network at solve time.
- `Sidereon.GNSS.RTK.solve_widelane_fixed_baseline_epochs/3` now supports
  `partial_ambiguity_resolution: true`. When the full narrow-lane set fails the
  ratio test, a bounded largest-first exhaustive subset search (run only after
  the greedy ranking finds nothing) accepts the highest-ratio subset of the
  largest size that passes the **unchanged** ratio threshold. Holding the
  widelane integers fixed collapses the per-satellite bias, so the dual-frequency
  partial fix safely covers a larger subset than the single-frequency partial -
  on the real Wettzell arc, a 6-satellite fix (ratio 4.27, 4.4 cm baseline error)
  compared with the single-frequency 4. The full-set refusal and single-frequency
  behavior are unchanged.

### Fixed

- `Sidereon.GNSS.Data` now starts the Erlang `:ftp` transport itself before its
  first FTP fetch (the GSSC/MGEX archives are FTP). A consumer that used Sidereon
  without starting the `:sidereon` application tree (an escript, a bare script, a
  release that did not start the dep) previously crashed with
  `(EXIT) no process: :ftp_sup`; it no longer has to start Erlang transports by
  hand.
- `Sidereon.GNSS.SP3.merge/2` now treats equivalent IGS reference-frame
  realizations as compatible: `IGS20` / `IGb20` / `IGc20` are the same
  ITRF2020-based IGS frame (the middle letter is the product/realization line,
  not a datum), so products labeled differently across centers merge instead of
  failing with `{:incompatible_sources, "mismatched coordinate systems"}`. A
  genuinely different datum (e.g. `IGS14` vs `IGS20`) is still rejected.

## [0.13.0] - 2026-06-08

### Added

- `Sidereon.GNSS.Data.ops_ultra_sp3/3` and `ops_ultra_clk/3` add the ultra-rapid
  precise-product tier to the offline-safe catalog/fetch layer. The catalog now
  derives anonymous GSSC archive names and URLs for `IGS0OPSULT`, `COD0OPSULT`,
  `ESA0OPSULT`, `GFZ0OPSULT`, and `GRG0OPSULT` SP3 products (plus `GRG0OPSULT`
  clocks), including sub-daily issue times, `02D` spans, per-center sampling,
  and latest-available issue fallback before a target epoch.
- `Sidereon.GNSS.Data.fetch_merged_sp3/3` fetches the same SP3 product from several
  centers in precedence order, tolerates not-yet-published or missing centers,
  and returns one merged `Sidereon.GNSS.SP3` plus provenance and merge-audit
  metadata. One available center is returned as a flagged single-source result;
  zero available centers returns `{:error, {:no_products, reasons}}`; centers
  that cannot be combined (mismatched time scale / coordinate-system frame)
  return `{:error, {:incompatible_sources, %{centers:, reason:}}}` rather than
  leaking a raw merge error.

## [0.12.0] - 2026-06-08

### Added

- `Sidereon.GNSS.SP3.merge/2` merges several SP3 products from different analysis
  centers into one consistent precise-ephemeris dataset. Coverage is the union
  across satellite×epoch (a satellite present in any input is present in the
  output, filling a single center's dropouts); overlapping records are resolved
  by robust consensus - the largest subset of centers agreeing within tolerance
  is combined (`:mean`, `:median`, or `:precedence`), disagreeing centers are
  recorded as outliers, and a cell with no agreeing subset is quarantined rather
  than averaged. Pure and deterministic; returns the merged product plus an audit
  report (`:quarantined`, `:single_source`, `:position_outliers`).
- `Sidereon.GNSS.SP3.clock_reference_offset/3` and
  `Sidereon.GNSS.SP3.align_clock_reference/3` expose the clock-datum primitive:
  precise clock products from different centers are referenced to different
  station/ensemble clocks, so their raw clocks differ by a per-epoch common
  offset. The first estimates that offset (robust median over common satellites);
  the second returns a copy of a product with its clocks shifted onto a
  reference's datum so the two are directly comparable. Positions need no such
  treatment.
- `Sidereon.GNSS.BroadcastComparison` now reports `clock_datum_removed_rms_m` /
  `clock_datum_removed_max_m` alongside the raw clock statistics: the per-epoch
  common reference-clock offset (median over satellites) is removed to give the
  actual signal-in-space clock error, several times smaller than the raw value.
- `Sidereon.GNSS.Ephemeris.sample/3` samples a precise (`Sidereon.GNSS.SP3`) or
  broadcast (`Sidereon.GNSS.Broadcast`) ephemeris over an epoch window into a
  unified per-satellite, per-epoch table of ECEF position and clock bias - the
  same call shape for either source, with out-of-coverage cells reported as an
  explicit `:no_ephemeris` gap rather than extrapolated.
- `Sidereon.GNSS.Broadcast.position/3` evaluates a single satellite's broadcast
  ECEF position and clock at an epoch (IS-GPS-200 LNAV, Galileo OS-SIS-ICD,
  BeiDou BDS-SIS-ICD).
- `Sidereon.GNSS.BroadcastComparison.compare/4` (and the `mix gnss.broadcast_diff`
  task, with a `--system` selector) computes per-satellite broadcast and precise
  orbit and clock differences (3D plus radial/along/cross RMS and max) over a
  window - the standard broadcast ephemeris accuracy check. Validated over a full
  UTC day against the IGS combined broadcast (`BRDC00IGS`) and CODE MGEX final
  precise orbits (`COD0MGXFIN`): GPS LNAV ~1.4 m, Galileo I/NAV ~0.9 m, BeiDou
  ~2.5 m orbit RMS.
- `Sidereon.GNSS.RTK.solve_float_baseline_epochs/3` and fixed RTK solvers now
  accept `code_smoothing: true` to apply per-receiver/per-ambiguity-arc Hatch
  carrier smoothing to code observations before forming double differences.
  The real Wettzell RTK gate verifies the smoothing reduces code residual RMS
  while still refusing unsafe integer fixes.
- `Sidereon.GNSS.RTK.solve_fixed_baseline_epochs/3` now supports opt-in partial
  ambiguity resolution with `partial_ambiguity_resolution: true`. When the full
  ambiguity set fails the ratio test, Sidereon tries confidence-ranked subsets and
  re-solves with the accepted subset fixed while rejected ambiguities remain
  float-estimated. The real Wettzell RTK gate now verifies a safe four-ambiguity
  partial fix improves the L1 baseline while the unsafe full-set fix remains
  rejected.

### Changed

- GNSS integer ambiguity fixing now uses a complete bounded integer
  least-squares scan over the caller's `integer_search_radius_cycles`, scored by
  the exact ambiguity covariance inverse. Fixed-solution metadata reports
  `integer_method: :bounded_ils` (or
  `:widelane_narrowlane_bounded_ils`) for this path.
- The default integer candidate cap for precise positioning and RTK fixed
  solvers is now `200_000`, enough for the default radius-1 search with up to 11
  ambiguities.
- `Sidereon.GNSS.RTK.solve_float_baseline_epochs/3` and fixed RTK solvers now use
  non-reference satellites on the epochs where they are available instead of
  dropping a satellite from the entire arc when it is absent from one epoch. The
  reference satellite is still required across the arc.

### Fixed

- GNSS integer ambiguity fixing no longer treats a missing runner-up lattice
  candidate as infinite ratio confidence; one-candidate searches now return
  `integer_status: :not_fixed`.
- `Sidereon.GNSS.SP3.position/3` (and everything built on it, including
  `Sidereon.GNSS.Observables` and the ephemeris sampler) now refuses an epoch
  beyond the product's node coverage with an `epoch out of range` error instead
  of silently extrapolating the interpolation spline to a non-physical position.
  Queries within one sampling step of the ends still interpolate; in-coverage
  results are bit-for-bit unchanged.

## [0.11.0] - 2026-06-08

### Added

- `Sidereon.GNSS.PrecisePositioning.solve_fixed_epochs/3` now reports
  `metadata.ambiguity_search` diagnostics (satellite order, float ambiguities,
  ambiguity covariance, and inverse covariance in cycles) so callers can audit
  the LAMBDA integer decision against the same lattice metric.
- `Sidereon.GNSS.PrecisePositioning` now accepts `elevation_weighting: true` on
  float, multi-epoch, and fixed solves, scaling code and phase row sigmas by
  `1 / sin(elevation)` for a simple real-data stochastic model that down-weights
  low-elevation observations.
- `Sidereon.GNSS.RTK.double_differences/3` for deterministic base/rover
  code-and-carrier double differences, the RTK measurement primitive that
  cancels receiver clocks and common short-baseline satellite errors before
  baseline estimation.
- `Sidereon.GNSS.RTK.solve_float_baseline_epochs/3` for static float RTK baseline
  estimation from supplied satellite ECEF positions and multi-epoch
  code/carrier double differences, holding one float ambiguity per
  non-reference double-difference arc. The float solution now exposes the
  double-difference ambiguity covariance and inverse covariance in metres.
- `Sidereon.GNSS.RTK.solve_fixed_baseline_epochs/3` for LAMBDA-fixed RTK baseline
  estimation. It starts from the float RTK baseline, fixes double-difference
  carrier ambiguities with the same correlated covariance used by the float
  solve, and re-solves the baseline with those integers held fixed.
- `Sidereon.GNSS.RTK.solve_fixed_baseline_epochs/3` now accepts
  `ambiguity_offset_m`, so fixed RTK ambiguities can be modeled as
  `offset + integer * wavelength`. This is the hook needed for
  wide-lane-fixed / narrow-lane dual-frequency RTK workflows.
- `Sidereon.GNSS.RTK.solve_widelane_fixed_baseline_epochs/3` for dual-frequency
  RTK fixing. It estimates Melbourne-Wubbena wide-lane double-difference
  integers, converts the arc to ionosphere-free narrow-lane measurements, then
  runs the existing correlated LAMBDA baseline solve with the wide-lane offsets
  held fixed.
- `Sidereon.GNSS.RTK.solve_float_baseline_epochs/3` and
  `solve_fixed_baseline_epochs/3` now understand carrier-phase arc identities:
  map observations may carry `:ambiguity_id`, and LLI loss-of-lock can be
  handled with `on_cycle_slip: :error | :drop_satellite | :split_arc`. Split
  arcs reset the affected double-difference ambiguity while residuals keep the
  physical satellite id.
- `Sidereon.GNSS.RTK.solve_float_baseline_epochs/3` and
  `solve_fixed_baseline_epochs/3` now accept `elevation_weighting: true`, which
  scales each undifferenced measurement sigma by
  `1 / max(sin(elevation), 0.05)` before propagating the correlated
  double-difference covariance.
- `Sidereon.GNSS.PrecisePositioning.solve_widelane_fixed_epochs/3` now supports
  `on_cycle_slip: :split_arc`, which resets a satellite's carrier ambiguity at
  detected cycle slips and keeps any post-slip fragments long enough for
  wide-lane fixing. Split fragments are reported in
  `metadata.split_cycle_slip_arcs` and use suffixed ambiguity ids such as
  `"G21#2"` in `used_sats` and the ambiguity maps.

### Changed

- `Sidereon.GNSS.PrecisePositioning.solve_fixed_epochs/3` now uses an
  LDL-consistent forward recursion for the decorrelated LAMBDA sphere search.
  This fixes the zero-candidate search miss on noisy real arcs without an
  original-space substitute path: those arcs now return a `FixedSolution` with
  `metadata.integer_status == :not_fixed` when candidates exist but fail the
  ratio test.
- `Sidereon.GNSS.RTK.solve_float_baseline_epochs/3` now propagates the
  non-diagonal double-difference measurement covariance into the normal
  equations and ambiguity covariance instead of treating DD rows that share a
  reference satellite as independent.
- `Sidereon.GNSS.RTK.solve_float_baseline_epochs/3` now chooses the
  highest-average-elevation common satellite as the default reference, with a
  deterministic satellite-id tie-break. `double_differences/3` still defaults to
  the lexicographically first common satellite because it has no geometry.

## [0.10.0] - 2026-06-07

### Added

- `Sidereon.GNSS.IonosphereFree.iono_free_phase/4` and
  `iono_free_phase_cycles/4` for PPP/RTK-facing first-order ionosphere-free
  carrier-phase combinations, plus `Sidereon.GNSS.CarrierPhase.phase_meters/2`,
  `code_minus_carrier/3`, and `smooth_iono_free_code/2` for code-carrier
  diagnostics and dual-frequency divergence-free Hatch smoothing.
- `Sidereon.GNSS.PrecisePositioning.solve_float/4`, a first float-ambiguity
  carrier-phase estimator for one SP3-backed epoch from ionosphere-free code and
  phase observations. It estimates receiver ECEF position, clock, and one float
  ambiguity per satellite, exposing residuals and metadata for later PPP/RTK
  layers.
- `Sidereon.GNSS.PrecisePositioning.solve_float_epochs/3`, a static multi-epoch
  float carrier-phase estimator that holds one ambiguity per satellite across an
  arc while estimating one receiver clock per epoch. This is the bridge from
  single-epoch float positioning toward PPP/RTK ambiguity fixing.
- `Sidereon.GNSS.PrecisePositioning.solve_fixed_epochs/3`, an integer-fixed
  multi-epoch carrier-phase estimator. It starts from the float arc, builds the
  ambiguity covariance from the float normal matrix, runs LAMBDA integer
  decorrelation plus a covariance-weighted integer sphere search on explicit
  caller-supplied wavelengths, then re-solves receiver position and epoch clocks
  with the selected ambiguities held fixed. The fixed solution reports the
  integer method, ratio-test status, weighted scores, and evaluated candidate
  count.
- `Sidereon.GNSS.PrecisePositioning.solve_widelane_fixed_epochs/3`, a
  dual-frequency convenience layer that fixes Melbourne-Wubbena wide-lane
  integers first, then uses LAMBDA on the remaining narrow-lane integer while
  returning both ambiguity sets.
- `Sidereon.GNSS.PrecisePositioning` can now apply an opt-in a-priori
  Saastamoinen/Niell tropospheric slant delay to ionosphere-free code and phase
  observations (`troposphere: true` with surface meteorology options), including
  the float, multi-epoch, and fixed-ambiguity solve paths.
- `Sidereon.GNSS.PrecisePositioning.solve_float_epochs/3` and
  `solve_fixed_epochs/3` can now estimate one residual zenith troposphere delay
  over a static arc (`estimate_ztd: true`, with `troposphere: true`), reporting
  `ztd_residual_m` and `metadata.ztd_estimated`.
- `Sidereon.GNSS.PrecisePositioning.solve_widelane_fixed_epochs/3` accepts
  `on_cycle_slip: :drop_satellite` to remove slipped satellite arcs before the
  wide-lane / narrow-lane solve. The default remains `:error`; dropped satellites
  are reported in `metadata.dropped_cycle_slip_sats`.

### Changed

- `Req` is now a required dependency. Network-backed features (`CelesTrak`,
  `Sidereon.GNSS.Data`, NAVCEN constellation status) are first-class Sidereon
  capabilities, and making the HTTP client required keeps consumer compiles
  warning-free.
- The LAMBDA integer search now shrinks its live search bound to the current
  second-best candidate, so `solve_fixed_epochs/3` keeps the same integer
  decision and ratio-test semantics while visiting far fewer complete
  candidates.
- `Sidereon.GNSS.PrecisePositioning.solve_fixed_epochs/3` now reports an empty
  LAMBDA sphere-search result as `{:error, {:no_integer_candidates, count}}`
  instead of conflating it with the `:too_many_integer_candidates` cap.

## [0.9.2] - 2026-06-06

### Added

- `Sidereon.GNSS.Constellation.diff/2` and `changed?/1` for deterministic
  snapshot-to-snapshot catalog comparisons keyed by `{system, prn}`. The diff
  reports added/removed PRNs plus NORAD, SP3 id, SVN, activity, and usability
  changes in structured lists.
- GLONASS FDMA carrier-phase wavelengths. `Sidereon.GNSS.RINEX.Observations`
  exposes the parsed `GLONASS SLOT / FRQ #` channel map and `phases/3` now
  derives carrier frequency, G1/G2 wavelengths, and metre phases for GLONASS
  satellites with a channel entry, so `Sidereon.GNSS.CarrierPhase` can process
  real GLONASS phase arcs instead of skipping them.
- `Sidereon.GNSS.ReducedOrbit` and `Sidereon.GNSS.ReducedOrbit.Piecewise` can now fit
  and drift against `%Sidereon.Elements{}` TLE/OMM sources by sampling SGP4 over the
  requested window (TEME → GCRS → ECEF, UTC scale). This closes the LEO reduced
  orbit source path without changing the Rust reduced-orbit numerics.

## [0.9.1] - 2026-06-05

### Added

- Rustler precompiled-NIF packaging support. Release tags now build GitHub
  Release archives for common Linux/macOS/Windows targets, and the Hex package
  will include `checksum-*.exs` so supported users do not need a local Rust
  toolchain. If no checksum file is present, Sidereon source-builds instead of
  trying to download missing assets; `SIDEREON_BUILD=1` remains the explicit
  source-build escape hatch.
- **`Sidereon.GNSS.CarrierPhase`** - dual-frequency carrier-phase combinations and
  the quality tooling on them: geometry-free (`L1 - L2`), wide-lane wavelength,
  narrow-lane code, Melbourne-Wübbena, arc-wise cycle-slip detection (LLI bit,
  geometry-free step, and Melbourne-Wübbena step, with documented thresholds),
  and the single-frequency Hatch carrier-smoothed code (with slip/LLI reset).
  GPS/Galileo/BeiDou; GLONASS satellites are skipped (FDMA wavelengths not yet
  derived). Builds on the newly exposed phase observations; no crate change.
- `Sidereon.GNSS.RINEX.Observations.values/3` and `phases/3` - expose the raw RINEX
  observations for an epoch (pseudorange, carrier phase, Doppler, signal strength
  with their LLI/SSI), and a carrier-phase convenience that adds the wavelength
  and the phase in metres for GPS/Galileo/BeiDou bands (`band_frequency_hz/2` is
  public; GLONASS FDMA wavelengths are not yet derived). `values/3` takes a
  `:codes` per-system filter so only the requested systems/codes cross the NIF
  boundary. This unlocks carrier-phase combinations without a parser change.
- `Sidereon.GNSS.Constellation.validate_sp3!/2` - a build-time validation gate that
  returns `:ok` or raises `ArgumentError` describing the findings (e.g. a
  stale-active PRN that is active and usable in the catalog but missing from a
  current SP3 product). Intended for catalog-build automation, not the runtime.
- Python/georinex/scipy oracle gates for the recent Sidereon-only GNSS layer:
  raw RINEX `values/3` / `phases/3`, `CarrierPhase` combinations/slip/Hatch
  smoothing, `IonosphereFree` coefficients and combinations, `GNSS.QC`
  weighting/chi-square thresholds, `GNSS.Observables.predict/5`, C/A
  code/correlation/acquisition, LNAV parity/subframe synthesis,
  visibility/DOP, velocity, DGNSS, `SolutionReport`, and `ReducedOrbit` /
  `ReducedOrbit.Piecewise` fit/evaluation/drift against Astropy/scipy.

### Changed

- `Sidereon.GNSS.Constellation.to_csv/2` gains a `:booleans` option: `:lower`
  (default, conventional `true`/`false`) or `:title` (`True`/`False`, for a
  pandas-style consumer that reads the `active` column as Python booleans).
- `Sidereon.GNSS.QC.chi2_inv/2` now inverts the regularized-gamma chi-square CDF
  and is checked against `scipy.stats.chi2.ppf`, replacing the older
  Wilson-Hilferty approximation.

## [0.9.0] - 2026-06-05

A large GNSS expansion - signal generation, measurement modelling, velocity,
quality control, and differential positioning - alongside a consolidation of
the whole GNSS surface under the `Sidereon.GNSS.*` namespace.

### Added

- **`Sidereon.GNSS.Signal.CA`** - GPS L1 C/A Gold-code generation, chip indexing,
  and auto/cross-correlation (IS-GPS-200 G1/G2 generators and per-PRN taps).
- **`Sidereon.GNSS.Signal.Correlator`** - C/A code+carrier replica, coherent
  correlation, a 2-D code-phase/Doppler acquisition search, and the
  coherent-integration (sinc²) loss model.
- **`Sidereon.GNSS.Navigation.LNAV`** - GPS LNAV subframe synthesis and decoding:
  TLM/HOW, time-of-week, subframe parity (IS-GPS-200 Table 20-XIV), and
  ephemeris bit-packing.
- **`Sidereon.GNSS.Observables`** - predicted geometric range, range-rate, Doppler,
  satellite clock, elevation, and azimuth from a receiver position and an SP3
  ephemeris, with light-time (transmit-time) and Sagnac corrections.
- **`Sidereon.GNSS.Geometry`** - satellite visibility above an elevation mask,
  dilution of precision (GDOP/PDOP/HDOP/VDOP/TDOP), DOP/visibility time series,
  and rise/set passes.
- **`Sidereon.GNSS.Velocity`** - receiver velocity and clock drift from Doppler or
  pseudorange-rate measurements by least squares over the line-of-sight geometry.
- **`Sidereon.GNSS.QC`** - measurement quality control: residual-based RAIM fault
  detection, leave-one-out fault detection and exclusion (FDE), and
  elevation/C-N₀ measurement weighting.
- **`Sidereon.GNSS.IonosphereFree`** - the dual-frequency ionosphere-free
  pseudorange combination, with standard per-system frequency pairs
  (GPS L1/L2, Galileo E1/E5a, BeiDou B1I/B3I).
- **`Sidereon.GNSS.DGNSS`** - code-differential positioning: base-station
  pseudorange corrections and corrected rover solves that cancel the errors
  common to both receivers (satellite clock, ephemeris, short-baseline
  atmosphere).
- **`Sidereon.GNSS.SolutionReport`** - a per-satellite and summary diagnostic over
  a position solution: elevation/azimuth, post-fit and RAIM-normalized
  residuals, DOP, residual RMS, and the integrity verdict.
- **`Sidereon.GNSS.ReducedOrbit.Piecewise`** - a piecewise (segmented)
  reduced-orbit model that tiles a span into contiguous fitted segments for
  tighter caching/transport accuracy than a single mean-element fit.

### Changed

- **Breaking:** GNSS modules now live under the `Sidereon.GNSS.*` namespace. The
  old top-level GNSS names (`Sidereon.SP3`, `Sidereon.PointPositioning`,
  `Sidereon.GnssData`, etc.) were removed instead of retained as aliases, matching
  the library's current single-client / pre-broad-adoption status. Examples:
  `Sidereon.GNSS.SP3`, `Sidereon.GNSS.Positioning`, `Sidereon.GNSS.Data`,
  `Sidereon.GNSS.RINEX.Observations`, `Sidereon.GNSS.ReducedOrbit`,
  `Sidereon.GNSS.Signal.CA`, and `Sidereon.GNSS.Navigation.LNAV`.
- Internal GNSS implementation helpers were consolidated under
  `Sidereon.GNSS.Core` for shared constants, ECEF input normalization,
  epoch/window handling, validation, source sampling, and versioned-map guards.
- Hardened public-API input validation across the GNSS modules: malformed
  receiver/base positions, out-of-range RAIM options, sub-second piecewise
  segment lengths, out-of-range LNAV flags, and duplicate observations now
  return tagged errors (or raise a clear `ArgumentError` for invalid options)
  instead of crashing, looping, or silently truncating.

## [0.8.0] - 2026-06-05

Observation parsing and a compact orbit model. Sidereon can now read a station's
RINEX observation file end-to-end into pseudoranges, and distill a position
track into a tiny, transportable mean-element model.

### Added

- **`Sidereon.GNSS.RINEX.Observations`** - RINEX 3 observation parsing with Hatanaka (CRINEX 1.0
  and 3.0) decoding. Decodes `.crx`/`.rnx`, exposes the header (incl. the
  surveyed `APPROX POSITION`), observation codes, and epochs, and extracts
  single-frequency pseudoranges (`pseudoranges/3`) in the
  `[{satellite_id, range_m}]` shape `Sidereon.GNSS.Positioning.solve/4` consumes -
  closing the loop from a station's observation file to a recovered position.
  `Sidereon.GNSS.Data` gains a station observation product fetch and an
  `observations/2` loader. CRINEX decoding is verified byte-for-byte against
  `crx2rnx`; an end-to-end test recovers a surveyed station position to metre
  level from real GPS observations.

- **`Sidereon.GNSS.ReducedOrbit`** - a compact, fitted mean-element approximation of an
  orbit for caching, transport, and quick visibility math (not orbit
  determination). Fits from an `Sidereon.GNSS.SP3` track or a list of ECEF samples;
  evaluates position/velocity (ECEF by default, GCRS on request); reports a
  source-backed `drift/3` against the source ephemeris; and serialises to a
  stable, versioned map (`to_map/1`/`from_map/1`). Two models: `:circular_secular`
  (default) and `:eccentric_secular` (nonsingular `h = e·sin ω`, `k = e·cos ω`),
  the latter recovering the radial `a·e` signal that the circular model discards -
  cutting full-day extrapolation error by one-to-three orders of magnitude for
  GPS and BeiDou while matching the circular model on near-circular Galileo.

## [0.7.0] - 2026-06-04

GNSS positioning. Sidereon can now recover a receiver position from pseudoranges
against precise or broadcast ephemeris, with the supporting ephemeris,
correction, time, and data-fetch layers.

### Added

- **`Sidereon.GNSS.Positioning`** - single-point positioning (SPP). Solves a
  receiver position, clock, and geometry diagnostics from one epoch of
  pseudoranges against either an `Sidereon.GNSS.SP3` precise product or an
  `Sidereon.GNSS.Broadcast` handle. Multi-constellation
  (GPS / Galileo / BeiDou / GLONASS) solves carry one receiver clock per system;
  the solution reports position, geodetic position, per-system clocks, DOP,
  residuals, used/rejected satellites, and solver metadata.
- **`Sidereon.GNSS.SP3`** - SP3-c/SP3-d precise orbit/clock loading and arbitrary-epoch
  satellite position/clock interpolation, plus `satellite_ids/1` to read the
  product's declared satellite set.
- **`Sidereon.GNSS.Constellation`** - a GPS constellation catalog built from
  CelesTrak `gps-ops` OMM identity and an optional NAVCEN status/SVN overlay
  (PRN ↔ SVN ↔ NORAD ↔ SP3 id, active/usable flags). Merges sources only when
  the block type matches, recording PRN-transition disagreements as conflicts
  rather than corrupting identity; exports the compact mapping CSV and validates
  a catalog (duplicate PRNs/NORAD ids, inactive/unusable PRNs, and missing/extra
  satellites against a loaded `Sidereon.GNSS.SP3` product).
- **`Sidereon.GNSS.Broadcast`** - RINEX 3.x and 4.xx navigation parsing and
  broadcast orbit/clock evaluation: GPS LNAV, Galileo I/NAV and F/NAV, BeiDou
  D1/D2 (including geostationary satellites), and GLONASS (PZ-90.11 state-vector
  propagation by Runge–Kutta integration).
- **`Sidereon.GNSS.Ionosphere`** (broadcast Klobuchar, frequency-aware across L1/E1/B1I)
  and **`Sidereon.GNSS.Troposphere`** (Saastamoinen zenith delay + Niell mapping)
  correction models.
- **`Sidereon.GNSS.Data`** - an optional product fetch/cache layer: a catalog over
  public archives, HTTPS (`Req`) and FTP downloads, an atomic on-disk cache with
  SHA-256 integrity and provenance sidecars, a gzip-bomb guard, and an offline
  mode. Includes convenience loaders that return `Sidereon.GNSS.SP3` /
  `Sidereon.GNSS.Broadcast` handles. `Req` is an optional dependency.
- **`Sidereon.GNSS.Time`** - GNSS epoch/seconds-of-week and day-of-year helpers.

### Notes

- The GNSS numerical core lives in the Rust `astrodynamics` / `astrodynamics-gnss`
  crate layer. Its libm-bound components (orbit and clock evaluation, ionosphere,
  troposphere, dilution of precision) are held to bit-exact (0 ULP) parity
  against pinned Python references; broadcast orbits are additionally validated
  against precise SP3 products. The least-squares solver's final position is a
  sub-micron solver-agreement result, not a 0-ULP claim.

---

Releases before 0.7.0 predate this changelog.
