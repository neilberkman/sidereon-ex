# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.34.0] - 2026-07-21

### Added

- `Sidereon.GNSS.Data.sp3_content_start_convention/3` exposes the core's exact
  relationship between an SP3 filename epoch and first content epoch, including
  the official historical GFZ ultra-rapid transition.
- `Sidereon.GNSS.Data.supported_samples/4` exposes the core's product-, date-,
  and issue-aware set of officially cataloged sampling tokens. Product
  constructors enforce the same set before deriving filenames, URLs,
  identities, or cache keys.

### Fixed

- Exact SP3 parsing and acquisition now accept the public terminal-record
  variants supported by the core: bare `EOF` or `EOF` followed only by ASCII
  spaces through column 80, with LF, CRLF, or no final separator. Malformed or
  missing terminal records and nonblank trailing content remain terminal
  integrity failures.
- Bounded gzip acquisition now follows RFC 1952's member-sequence model under
  one cumulative output limit. Every member must have a complete header,
  DEFLATE stream, CRC32, and ISIZE trailer; corrupt or truncated later members
  and non-member trailing data fail before exact-product parsing, distributor
  fallback, or cache publication. Valid concatenated members and large legal
  optional headers are accepted.
- Built-in HTTP and local-file acquisition now stop at the compressed-input
  cap instead of buffering an oversized archive first. Error precedence for
  redirects and ordinary publication absence is unchanged.
- Identity-derived exact SP3 validation now applies cataloged filename/content
  start semantics. Direct `Sidereon.GNSS.SP3.ExactRequest.new/4` requests
  retain supplied-date semantics.
- Ultra-rapid exact candidates now contain only dated span/cadence variants
  evidenced for the exact center, date, and issue. CODE's moving latest-product
  snapshot is excluded because it is not the dated one-day product; the
  documented GFZ `2021-05-15 0000` cadence overlap remains the only
  two-candidate issue. Caller-built identities must use the cataloged span.

### Changed

- Updated the native backend to `sidereon` and `sidereon-core` 0.34.0.

### Compatibility

- The new catalog query is additive; existing Elixir call signatures and all
  numerical behavior are unchanged. Ultra-SP3 candidate lists can be shorter
  because unsupported alternate spans/cadences and CODE's non-exact moving
  snapshot are no longer returned. Reports or cache entries that claimed that
  snapshot as a dated identity no longer verify. This is a minor release
  because the catalog API is public and historical GFZ and canonical-span
  validation are newly enforced.

## [0.33.1] - 2026-07-20

### Changed

- Multi-distributor fallback now continues after ordinary publication absence,
  retired endpoints, and exhausted source-local transport availability while
  keeping integrity and configuration failures terminal. Retryable HTTP status
  is limited to 408, 429, and 500 through 599.
- Unix-compress acquisition now locks the current ncompress maxbits-9 behavior
  and rejects detectable partial terminal codes and invalid terminal padding
  before product parsing. Because `.Z` has no end marker, exact product
  validation and an optional caller digest remain authoritative.
- Acquisition byte limits now require positive integers at the public boundary.
- Multi-center SP3 acquisition now records a generally supported center outside
  its verified catalog era as `catalog_unavailable`; unrelated configuration
  and integrity errors remain terminal.
- Invalid or failing caller-supplied HTTP callbacks now return a typed terminal
  client failure instead of being retried or authorizing distributor fallback.
- Precompiled NIF archives now carry the project license and third-party
  attribution notice alongside the native library. Hex source packages and NIF
  archives also include the full Apache-2.0, ERFA BSD-3-Clause, IERS
  Conventions, libloading ISC, and SciPy BSD-3-Clause license texts required by
  the source and locked Rust dependency graph, plus exact public 0.33.1
  tide-derived sources.
- Precompiled-NIF release builds now pin action revisions, Elixir/OTP/Hex,
  Rust 1.92.0, the architecture-specific rustup bootstrap checksums, the
  source-build container digest, and the cross build tool revision; they require
  locked Cargo resolution and grant write permission only to the release-asset
  publication job.
- Updated the native backend to `sidereon` and `sidereon-core` 0.33.1.

## [0.33.0] - 2026-07-20

### Added

- Added product-aware `Sidereon.GNSS.Data.product_solution_class/2`, dated
  `default_sample_for_date/3`, core-derived exact product identities and
  distribution locations, and historical IGS final-SP3 naming support.
- Added `Sidereon.GNSS.SP3.ExactRequest`, `parse_exact/2`,
  `validate_exact/2`, declared epoch-count/start accessors, and explicit
  half-open/inclusive coverage results.
- Added size-limited Unix `compress` (`.Z`) decoding for historical CDDIS
  products.

### Changed

- Exact SP3 acquisition now validates mandatory SP3 structure, producing
  agency, declared and parsed start/count, requested cadence, regular epoch
  grid, and exact span before publishing bytes or provenance.
- Source and ultra-rapid candidate fallback now continues only after ordinary
  publication absence. Malformed content, parsing, digest, identity, cadence,
  span, caller configuration, and cache-integrity failures are terminal.
- IGS final SP3 uses the official short filename and CDDIS `.Z` layout before
  GPS week 2238, then the long filename and gzip layout. IGS broadcast
  navigation remains independently classified as `broadcast`.
- CODE SP3/clock/IONEX URLs are resolved by product family, and GFZ rapid-SP3
  sampling defaults are selected by date across the 2021 15-minute to
  five-minute transition.
- Catalog derivation now enforces the verified publication floors for ESA
  final, GFZ rapid, and IGS/ESA/GFZ ultra-rapid SP3. ESA and GFZ ultra-rapid
  defaults follow their historical cadence eras, including ESA's intraday
  transition between the 2025-02-02 0600 and 1200 issues. CDDIS rejects
  pre-week-2238 long-name SP3 identities instead of inventing archive paths.
- Updated the native backend to `sidereon` and `sidereon-core` 0.33.0.

### Compatibility

- Existing permissive `Sidereon.GNSS.SP3.parse/1` remains available, and the
  core's date-free sampling query is exposed as `Data.default_sample/2` for
  compatibility-oriented catalog inspection. Exact acquisition is
  intentionally stricter, and unsupported center/product combinations now fail
  before transport. This additive API and integrity-policy change requires a
  minor release.

## [0.32.0] - 2026-07-18

### Added

- Added `Sidereon.GNSS.Constellation.parse_navcen_html_at/2` and
  `merge_navcen_at/2` for deterministic UTC evaluation of NAVCEN forecast
  outages. Assessments retain the raw NANU fields, Outage Start cell, and a
  parsed half-open interval or explicit ambiguity; the existing clock-free
  parsing and merge APIs remain unchanged.
- The time-aware path recognizes active `UNUSUFN` notices as immediately
  unusable while preserving the legacy parser's pre-existing behavior.

### Changed

- Updated the native backend to `sidereon` and `sidereon-core` 0.32.0.

## [0.31.2] - 2026-07-16

### Added

- Merged-SP3 reports now retain a complete exact artifact identity and separate
  acquisition observations for every contributor, plus the shared versioned
  stable identity of the contributor set and merge policy. Mean/median input
  enumeration is canonicalized; precedence order is recorded and bound.
- Added `Sidereon.GNSS.SP3.merge_input_identity/2`,
  `Sidereon.GNSS.Data.merge_report_to_map/1`, `verify_merge_report/1`, and
  `fetch_merged_sp3_file_with_report/4` for validation, secret-free
  persistence, and file output without discarding provenance.
- Added the shared literal merged-SP3 canonicalization fixture and returns the
  complete core-canonical contributor list plus semantic precedence order.

### Changed

- Merged-SP3 candidate downloads now use the exact acquisition and atomic cache
  path. Existing unverifiable files in the legacy flat merged-SP3 cache are not
  accepted as provenance-bearing contributors.
- Latest-product aliases must prove their public catalog equivalence and exact
  artifact duration before publication. Persisted reports now reject unknown
  or inconsistent fields at every nested schema level, and authenticate the
  ordered requested-center partition across contributors and absent centers.
- Updated the native backend to `sidereon` and `sidereon-core` 0.31.2.

### Compatibility

- Existing `Contributor` construction and the path-only return from
  `fetch_merged_sp3_file/4` remain valid. The new report fields and report-
  retaining file helper are additive. Merged acquisition no longer trusts the
  former digest-only flat cache because it cannot prove exact artifact
  identity.

## [0.30.0] - 2026-07-16

### Fixed

- Publishes exact-product cache entries as immutable payload/archive/provenance
  transactions selected by one atomic digest-bound commit record. Cache hits
  cannot observe a mixed update after independent BEAM instances race or a
  process dies at a publication boundary.
- Delegates exact acquisition to the shared Rust transaction implementation.
  Its bounded advisory lock coordinates Linux and macOS processes; dead owners
  release automatically, waiters avoid a second acquisition, and abandoned
  transactions are removed only by a lock owner.
- Revalidates and atomically migrates valid 0.29.0-0.29.2 cache triples without
  reacquisition. Cache lock/write failures are terminal and never authorize a
  distributor change.

### Added

- Added the optional `:cache_lock_timeout_ms` acquisition option, defaulting to
  30,000 milliseconds.
- Added the documented `Sidereon.GNSS.ExactCache` transaction module and public
  full-identity cache-key derivation.

### Changed

- Updated the native backend to `sidereon` and `sidereon-core` 0.30.0. Full
  identity hashing now uses the same golden canonical key in all five
  interfaces.

## [0.29.2]

### Added

- Added `Sidereon.GNSS.Distribution.validate_exact_product_set/2`, a fail-closed
  gate for a declared exact identity inventory. Empty declarations,
  duplicates, missing products, and undeclared products are rejected.
- Exact-set comparison preserves prediction-tier identity. SP3
  observed/predicted timing remains sourced from the parser's authoritative
  record-flag summary.

### Changed

- Updated the native backend to `sidereon` and `sidereon-core` 0.29.2.

## [0.29.1]

### Fixed

- Fetches CODE predicted IONEX P1 and P2 products from their current official
  tier-specific HTTPS directories, retaining the requested identity year and
  exact filename across validated AIUB redirects.
- Routes the legacy IONEX helper through exact acquisition so downloaded and
  cached bytes receive the same date, issue, and cadence validation. Explicit
  legacy lookback continues only after typed not-published or offline-miss
  results; validation and transport failures remain terminal.
- Keeps P1 and P2 cache identities isolated even when their filenames match.

### Changed

- Updated the native backend to `sidereon` and `sidereon-core` 0.29.1.

## [0.29.0]

### Added

- Added exact SP3/IONEX acquisition that separates product identity from an
  ordered, caller-selected list of direct, NASA CDDIS/Earthdata, local-file,
  and in-memory sources.
- Added caller-supplied Earthdata bearer-token and netrc authentication,
  source-specific verified caches, retained archive bytes, structured failures,
  parsed semantic checks, and secret-free acquisition provenance.

### Fixed

- Accepts both binary and charlist results from OTP's user-cache-directory
  helper, preserving the default cache path across supported OTP versions.

## [0.28.1]

### Fixed

- Updated the native backend to `sidereon` and `sidereon-core` 0.28.1. CODE
  ultra-rapid products now use AIUB's current HTTPS download endpoint instead
  of the retired `ftp.aiub.unibe.ch` HTTP tree.
- Follows only AIUB's validated HTTPS handoff to its download host and public
  object store. Missing candidates retain the URL and HTTP status in merge
  diagnostics without claiming authoritative publication state.
- Updated the locked Mint HTTP dependency to 1.9.2, clearing the published
  HTTP/1 and HTTP/2 response memory-exhaustion advisories affecting 1.9.1.

## [0.28.0]

### Added

- Added per-cell SP3 precedence, optional deterministic outlier rejection,
  clock-outlier provenance, and observed/predicted epoch summaries.
- Added ultra-rapid product-pattern fallback with contributor provenance and
  complete merge-option forwarding through `fetch_merged_sp3/3`.

### Changed

- Updated the native backend to `sidereon` and `sidereon-core` 0.28.0.

### Fixed

- Hex source packages now include the Cargo workspace lockfile, use exact Rust
  registry pins, and clear verifier scratch directories before clean builds.

## [0.27.1]

### Fixed

- Updated the native backend to `sidereon` and `sidereon-core` 0.27.1. LAMBDA
  integer least-squares now returns `{:error, :invalid_input}` when an ambiguity
  or back-transformed candidate is outside the signed 64-bit integer lattice,
  instead of saturating the integer result and returning non-finite scores.

## [0.27.0]

### Added

- PROJ-compatible EGM96 15-arcminute GTX loading and vertical-grid
  interpolation through `Sidereon.Geoid`. Callers explicitly select fused or
  separately rounded multiply-add evaluation to match their reference PROJ
  build, and invalid coordinates return `ProjVgridshiftError` rather than
  panicking, clamping, or extrapolating.

### Changed

- Updated the native backend to `sidereon` and `sidereon-core` 0.27.0.

## [0.26.1]

### Security

- Updated `sidereon` and `sidereon-core` to 0.26.1, which rejects RINEX 2
  observation epoch headers that declare an oversized satellite count before
  processing continuation records. Malicious input could otherwise request an
  enormous allocation and terminate the BEAM VM. Core releases and binary
  artifacts 0.11.1 through 0.26.0 are affected. Published Sidereon Hex versions
  0.11.1 through 0.25.0 are affected; upgrade to 0.26.1.

## [0.26.0]

### Breaking

- Removed the unsound generic sequential-RTK innovation screen together with
  `ArcUpdateOptions.innovation_screen_sigma`,
  `ArcUpdateOptions.innovation_screen_min_rows`, the corresponding map-option
  aliases, and `ArcEpochSolution.innovation_screen`. The removed classifier
  divided residuals by measurement variance, omitted predicted-state
  covariance and shared-reference correlation, and treated carrier-phase
  events as ordinary row outliers. Sequential RTK now always assimilates the
  complete correlated double-difference block of all admitted rows; carrier
  anomalies remain under the causal slip/arc lifecycle.

### Fixed

- Updated the native backend to `sidereon-core` and the Rust facade 0.26.0.
  Near-polar ionospheric pierce-point evaluation now remains finite when
  rounding puts a valid latitude sine just outside `[-1, 1]`, and the locked
  Rust graph includes the `crossbeam-epoch` security fix.
- Release validation now builds the actual Hex tarball, verifies that its NIF
  crate pins `sidereon-core` only by a registry version, and forces
  a source build from the unpacked package through a throwaway consumer in a
  clean Rust-enabled container. The gate runs in pull-request CI and before
  tagged precompiled artifacts are published. The documented source-build
  instructions now include the consumer-side optional Rustler dependency.
- Audited every published Hex package from 0.8.0 through 0.25.0. Version 0.8.0
  is the only affected release: its source-build path pins a nonexistent
  `sidereon-core` git tag. Its precompiled path still works; consumers should
  upgrade to 0.25.0 or newer. Versions 0.9.0 through 0.25.0 already use
  registry pins and are not affected.

### Evaluation-bit stability

- The near-polar TEC correction intentionally changes affected pierce-point
  results from non-finite latitude/longitude values to finite values. Existing
  in-range TEC evaluations require no golden re-pin, and the ordinary
  sequential-RTK path remains bit-identical to its former no-screen execution.

## [0.25.0]

### Added

- Typed public structs for the RTK arc surfaces: sequential arc, static arc,
  wide-lane fixed, and ionosphere-free preparation results, plus typed arc
  config structs (map input still accepted).
- `Sidereon.GNSS.QC.raim_for_solution/2` as a first-class direct wrapper.
- `Sidereon.GNSS.SPP.spp_inputs_from_rinex_obs/3` and
  `solve_spp_from_rinex_obs/3`, mirroring the Rust facade conveniences.
- `Sidereon.GNSS.PreciseEphemeris.InterpolantArtifact` as a named public type
  over the existing artifact bytes/open/checksum calls.
- `Sidereon.GNSS.Ntrip.request_bytes/2` (and the `ntrip_request_bytes/2`
  facade-name alias) exposing the sans-I/O NTRIP request builder.
- Parity naming for estimation, terrain/geoid, SP3 precise-accessor, signal
  analysis, and fusion typed-input helpers, matching the other interfaces.

## [0.24.0]

### Added

- Direct post-solve RAIM (`Sidereon.GNSS.QC.raim/2`): residuals and geometry
  in, fault flag and test statistic out, including the for-solution overload.
  Docs state the weighting contract: pass per-satellite inverse-variance
  weights; unit weights on metre-scale residuals saturate the fault test.
- ARAIM results expose `available` (with `availability` kept as an alias), and
  geometry that cannot support the integrity budget now returns an unavailable
  result instead of an error, matching core 0.24.0 semantics.
- `Sidereon.Reliability` ARAIM parity with the other interfaces.

## [0.23.0]

### Added

- RTCM broadcast ephemeris decode for Galileo (1045/1046), BeiDou (1042), and
  QZSS (1044), with solver conversion, at parity with core's real-data
  validated decoders.
- Public multi-epoch static positioning (`solve_static`) with covariance,
  leave-one-out redundancy diagnostics, and robust weighting.
- Static PPP options: optional elevation cutoff and optional
  tropospheric-gradient estimation (off by default).
- Temporal-correlation covariance fields on static PPP solutions
  (`temporal_position_covariance`, scale factor, and correlation diagnostics).

## [0.22.0]

### Added

- Static PPP posterior position covariance (ECEF and ENU) on float and fixed
  solutions, with the posterior variance factor and applied scale factor.
- SP3 multi-center merge coordinate-label reconciliation (asserted equivalence
  and catalog Helmert), with merge-report audit fields.

### Changed

- Static PPP eliminates per-epoch receiver clocks for tractable day-length arcs,
  and scales result covariance by the posterior residual variance factor.

## [0.21.0]

### Added

- Fusion field mode (`Sidereon.GNSS.Fusion`): zero-velocity and zero-angular-rate
  updates with a stationarity detector, non-holonomic vehicle constraints,
  per-fix-status measurement weighting, and the IMU-to-body mounting matrix,
  all off by default with parity tests against core values.
- Multi-epoch reference-station static solve (`Sidereon.GNSS.RTK`): rover and
  reference observations in, one station coordinate with covariance and typed
  per-mode errors out, verified against a published ITRF station pair.

## [0.20.0]

### Added

- Carrier-phase RTK baselines built straight from raw RINEX
  (`Sidereon.GNSS.RTK.solve_static_rinex_rtk_baseline/5` and
  `Sidereon.GNSS.RTK.solve_wide_lane_fixed_rinex_rtk_baseline/5`): rover and base
  observations plus ephemeris and base coordinates in, float and wide-lane
  fixed baselines out with covariance and fix status, verified to millimeters
  against a published ITRF station pair.
- Position error metrics (`Sidereon.ErrorMetrics`): CEP, DRMS, 2DRMS, R95/R99,
  SEP, MRSE, per-axis sigmas, percentile radii with probability and validity,
  and the error ellipse, from ENU or ECEF covariances or a kinematic solution.

## [0.19.1]

### Added

- The GNSS/INS fusion surface (`Sidereon.GNSS.Fusion`): strapdown mechanization,
  loose and tight coupling with the robust update configuration, fixed-interval
  RTS smoothing over recorded fusion history, and static fusion, with parity
  tests against core values.

## [0.19.0]

### Added

- The no-IMU track filter and RTS smoother (`Sidereon.Estimation`):
  covariance-weighted constant-velocity filtering of position fixes so
  weak-geometry fixes cannot spike the track, with fixed-interval smoothing.
- Solid Earth and pole tide forces for numerical propagation, and station
  displacement corrections (solid tide, pole tide, ocean loading from BLQ).

## [0.18.0]

### Added

- GNSS/INS fusion (`Sidereon.GNSS.Fusion`): mechanization configuration, EKF
  and UKF filtering, loose and tight measurements, robust loose update
  options, the RTS smoother, time synchronization, and the serializable
  filter state.
- The deterministic scenario simulator (`Sidereon.GNSS.Scenario`):
  bit-reproducible synthetic observables plus the ground-truth term ledger.
- Closed-form signal analysis (`Sidereon.GNSS.Signal.Analysis`): spectra,
  spectral separation coefficients, DLL jitter, and multipath envelopes.

## [0.17.0]

### Added

- Uncertainty-aware geodesic geofencing (`Sidereon.Geofence`): containment and
  crossing probabilities from a position covariance, with hysteresis.
- Multi-epoch static positioning (`Sidereon.StaticPositioning`).
- Doppler velocity solve with receiver clock drift, and ECEF position
  covariance on receiver solutions.
- The one-call emission correction bundle (contiguous per-satellite arrays
  with typed coverage status).
- The precise-interpolant artifact: build once, evaluate zero-copy from bytes,
  checksummed.
- IONEX coverage policy: typed out-of-coverage results by default, explicit
  hold opt-in.

### Fixed

- Sample-backed SP3 interpolation reconstructs its node axis before time-scale
  conversion, closing the remaining boundary-node case on real converted
  epochs (consumer-verified).
- Tight-coupling measurement row signs and the transmit-time model; tight
  numeric behavior changes relative to 0.16.x, see the core changelog.

## [0.16.1]

### Fixed

- The geodesic module is now a first-party implementation; a transitive
  dependency of the previous release could not build on Windows.

## [0.16.0]

### Added

- Geodesic direct and inverse solvers on WGS84 (Karney) (`Sidereon.Geodesic`).
- Epoch-aware terrestrial reference frame catalog with published ITRF and ETRF
  Helmert parameter sets (`Sidereon.FrameCatalog`).
- EGM2008 geoid raster loading alongside EGM96 (`Sidereon.Geoid`).
- Spherical-harmonic geopotential force selection for numerical propagation
  (`Sidereon.Propagator`).
- CCSDS TDM parse and encode (`Sidereon.CCSDS.TDM`).
- Terrestrial-frame (ECEF) SP3 orbit fitting entries
  (`Sidereon.OrbitDetermination`).
- SGP4 post-decay validity latch, oblate-Earth shadow model option, and typed
  troposphere mapping validity errors.

### Fixed

- The core SP3 evaluation path: epoch bucketing no longer mis-serves the state
  from one second later at nodes sensitive to the GPS-UTC offset, and clock and
  position evaluation are now gated by an independent oracle against the parsed
  file text. Consumers of SP3 clock or state evaluation on 0.15.0 should
  upgrade.
- The terrain store surfaces skipped and void input as typed results instead of
  silent zeros.

### Changed

- Reliability marshaling takes both w-test noncentrality components from the
  core; `Sidereon.Format.TLE.encode/1` surfaces out-of-range catalog numbers as
  typed errors.

## [0.15.0]

### Added

- Position error metrics: CEP, R95/R99, drms/2drms, SEP, VEP, and the 1-sigma
  error ellipse from any solution covariance, with exact elliptical percentile
  radii and typed errors for non-positive-semidefinite input
  (`Sidereon.ErrorMetrics`).
- Classical reliability: per-observation minimal detectable bias and
  internal/external reliability over the shared ARAIM gain matrix, with
  zero-redundancy observations reported uncheckable (`Sidereon.Reliability`).
- SBAS protection levels per DO-229 with the MOPS tables frozen bit-exact
  (`Sidereon.GNSS.SBAS`).
- Composable perturbation forces for numerical propagation: zonal harmonics
  through J6, Sun/Moon third-body, solar radiation pressure, and the
  relativistic correction (`Sidereon.Propagator`).
- Batch least-squares orbit fitting against precise ephemerides with a
  per-satellite RTN residual ledger (`Sidereon.OrbitDetermination`).
- Power-law clock-noise identification per IEEE 1139 over the Allan-family
  deviations (`Sidereon.ClockStability`).
- Robust geodetic time series: MIDAS velocity, trajectory fitting, step
  detection, and network motion fields (`Sidereon.GeodeticTimeSeries`).
- Sidereal filtering with per-satellite orbit repeat lag and coverage-aware
  templates (`Sidereon.Sidereal`).
- Alpha-5 TLE catalog numbers and CelesTrak GP ingest in the core TLE/OMM
  path.

### Changed

- `Sidereon.Format.TLE.encode/1` surfaces catalog numbers beyond the TLE range
  as a typed error instead of raising.

## [0.14.0]

### Added

- Weak-geometry observability classification (`GeometryQuality`: rank,
  redundancy, conditioning, covariance-validated flags) on every solution.

## [0.13.0]

### Added

- Batched multi-satellite state interpolation, source localization (ToA/TDOA),
  and estimation/detection primitives (scalar Kalman, alpha-beta, NIS, MAD,
  CFAR).

## [0.12.0]

### Added

- Allan-family clock stability, ARAIM protection levels, sample-backed IONEX,
  batch terrain probes, the memory-mappable terrain store, SBAS decode
  extensions, and angular-separation utilities.

## [0.11.0] and [0.11.1]

### Added

- RINEX observation quality control, NTRIP client handling, NMEA 0183, and the
  geoid/vertical-datum surface.

## [0.10.1]

### Fixed

- DTED block-directory naming now matches production store layouts.
- Sample-ephemeris construction rejects non-finite derived epochs and clock
  values.

## [0.10.0]

### Added

- Astrodynamics coverage for anomaly conversions, analytic Kepler propagation,
  equinoctial and modified-equinoctial elements, solar beta angle,
  RIC/RTN/LVLH relative frames, Clohessy-Wiltshire motion, angular separation,
  position angle, general body observation, almanac events, atmospheric drag
  force, orbital decay, source-agnostic ephemeris grid sampling, and
  terrain/DTED lookup.
- GNSS DCB/OSB bias ingestion, SBAS augmentation with decode and corrected SPP,
  SSR/HAS real-time corrections, and robust SPP with a fault
  detection/exclusion driver.
- Cache-first data acquisition support for SP3, IONEX, CLK, NAV, and SRTM
  terrain to DTED products, using a single sans-IO core catalog and bit-exact
  hgt to DTED conversion.

### Changed

- Rust, Python, C, WASM, and Elixir interfaces now expose uniform capability
  parity for the 0.10.0 surface.
- GNSS constellation labels now use conventional styling: GPS, GLONASS, Galileo,
  BeiDou, QZSS, NavIC, and SBAS.

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

## [0.16.1]

### Fixed

- The geodesic module is now a first-party implementation; a transitive
  dependency of the previous release could not build on Windows.

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
