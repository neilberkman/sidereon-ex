# sidereon

[![Hex.pm](https://img.shields.io/hexpm/v/sidereon.svg)](https://hex.pm/packages/sidereon)
[![HexDocs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/sidereon)
[![Run in Livebook](https://livebook.dev/badge/v1/blue.svg)](https://livebook.dev/run?url=https://github.com/neilberkman/sidereon-ex/blob/main/sidereon.livemd)

GNSS and astrodynamics for Elixir: propagate satellites, predict passes, solve
precise positions (SPP / RTK / PPP / DGNSS), screen for conjunctions, and
convert between coordinate frames and time scales.

This is the Elixir interface to **sidereon**, a GNSS and astrodynamics engine
written in Rust. The numerics run in that engine and ship to you as a
[Rustler](https://github.com/rusterlium/rustler) **precompiled NIF**: adding the
dependency downloads a prebuilt binary for your platform, so there is no Rust
toolchain to install and nothing to compile. You write ordinary Elixir, with
plain `DateTime` and map structures in and typed structs out.

The engine is reference-validated. The SGP4 propagator is a port of David
Vallado's reference implementation, bit-exact to it; frames and time are checked
against Skyfield and IERS; the positioning stack is checked against IGS products.

## Install

Add `:sidereon` to your dependencies in `mix.exs`:

```elixir
def deps do
  [{:sidereon, "~> 4.1"}]
end
```

Releases ship precompiled NIFs for common Linux, macOS, and Windows targets and
download automatically, so no Rust build is needed. On glibc Linux, a
`portable` artifact variant zig-linked against a glibc 2.17 floor is
available for old-glibc hosts and zig-based packaging pipelines (e.g.
Burrito): opt in at compile time with `SIDEREON_PORTABLE_NIF=1` or
`config :sidereon, portable_nif: true`. The musl (Alpine) artifacts are
already self-contained; in a bare `FROM alpine` runtime stage, `apk add
libgcc` is the only system dependency. To force a source build,
install a Rust toolchain, set `SIDEREON_BUILD=1`, and activate Sidereon's
optional Rustler dependency in the consuming application:

```elixir
def deps do
  [
    {:sidereon, "~> 4.1"},
    {:rustler, ">= 0.0.0", optional: true}
  ]
end
```


### musl and cross-libc packaging

`rustler_precompiled` selects its artifact from the **build host's** target
triple, not from the artifact you are ultimately producing. Publishing musl
builds does not protect against this, because selection happens before the
published set is consulted.

The trap: a glibc build host (Debian/Ubuntu CI, or the builder stage of a
multi-stage Dockerfile) producing a musl output - an Alpine image, a
self-extracting release, Nerves firmware - resolves to
`x86_64-unknown-linux-gnu`, downloads that `.so`, and packages it. **The build
succeeds.** The failure appears later, on the target machine, as an opaque
`load_nif` error that reads like a broken library rather than a build-host libc
mismatch.

If you package for a libc other than your build host's, build the NIF from
source on a host matching the target:

```elixir
def deps do
  [
    {:sidereon, "~> 4.1"},
    {:rustler, ">= 0.0.0", optional: true}
  ]
end
```

with `SIDEREON_BUILD=1` set for that build. Sidereon logs an explicit
diagnosis at application start when it detects that the packaged artifact's
libc does not match the running system, naming this section - but it can only
report the mismatch, not prevent it, because by then the wrong artifact is
already packaged.

## SP3 writer return values in 3.0

Before 3.0, `Sidereon.GNSS.SP3.to_sp3_string/2` returned the text directly, so
callers could pass it to byte-oriented functions such as `:zlib.gzip/1`:

```elixir
text = Sidereon.GNSS.SP3.to_sp3_string(sp3)
compressed = :zlib.gzip(text)
```

In 3.0, `to_sp3_string/2` returns `{:ok, binary}` or
`{:error, {tag, fields}}`; `to_iodata/2` returns `{:ok, iodata}` or the same
typed refusal. Unwrap the success value before using it:

```elixir
case Sidereon.GNSS.SP3.to_sp3_string(sp3) do
  {:ok, text} -> {:ok, :zlib.gzip(text)}
  {:error, {tag, fields}} -> {:error, {:sp3_write_refused, tag, fields}}
end
```

The same change applies to `to_iodata/2`. Before 3.0, a call site could pass
its result straight to an iodata consumer:

```elixir
iodata = Sidereon.GNSS.SP3.to_iodata(sp3)
compressed = :zlib.gzip(iodata)
```

In 3.0, unwrap the result and handle the typed refusal:

```elixir
case Sidereon.GNSS.SP3.to_iodata(sp3) do
  {:ok, iodata} -> {:ok, :zlib.gzip(iodata)}
  {:error, {tag, fields}} -> {:error, {:sp3_write_refused, tag, fields}}
end
```

Other products can still hold a value finer than the SP3 columns and return
`{:error, {:record_value_not_representable, fields}}`, where `fields` identifies
the field, satellite, and epoch. The strict writer refuses that value rather
than rounding it. Callers can preserve the named error and its fields as above,
or match the tag and fields to handle a particular refusal. See the
[complete 3.0 release notes](CHANGELOG.md#300---2026-10-04).

### Explicit rounding in 3.0.5

For a product that needs record-field rounding, use
`Sidereon.GNSS.SP3.to_sp3_string_with_rounding/2`. It returns
`{:ok, text, report}`; the report maps the eight position, velocity and clock
fields to maximum absolute changes in SI units. Header fields and epochs retain
the strict checks. `Sidereon.GNSS.Data.write_sp3_with_rounding/3` writes that
text atomically and returns `{:ok, path, report}`.

Merges from column-grid inputs keep derived record values on the SP3 grid,
including mean and median combinations. Accuracy metadata has its own
representability requirements, addressed below.

### Accuracy metadata in 3.0.6

SP3 accuracy exponents depend on the position and clock bases in the header.
Merging products now selects bases that preserve retained standard deviations
exactly when possible, including an input with unspecified bases followed by one
with known accuracy. Strict writers still refuse incompatible accuracy metadata.

An explicit accuracy conversion is available when exact encoding is impossible:

```elixir
case Sidereon.GNSS.SP3.to_sp3_string_with_accuracy_rounding(sp3, :conservative) do
  {:ok, text, %{record_values: values, accuracy_sigmas: sigmas}} ->
    {:ok, :zlib.gzip(text), values, sigmas}

  {:error, {:accuracy_not_representable, fields}} ->
    {:error, {:accuracy_not_representable, fields}}

  {:error, reason} ->
    {:error, reason}
end
```

The required `:conservative` policy chooses the smallest finite output standard
deviation at least as large as each source value. `accuracy_sigmas` reports the
maximum absolute change per field: position and clock range in metres, velocity
and clock rate in metres per second. Unknown metadata and sentinels retain their
meaning. Values beyond the finite output range remain errors. The source product
is unchanged, and the existing eight-field numeric rounding report is unchanged.

For atomic gzip file output, use
`Sidereon.GNSS.Data.write_sp3_with_accuracy_rounding(sp3, path, :conservative, gzip: true)`.
It returns `{:ok, path, report}` or a typed error; writer refusal preserves an
existing destination file.
Higher-precision inputs can still require the opt-in rounding writer.
Agreement and dispersion metrics use combined values before final column
quantization.

## Example: track a satellite

Parse a two-line element set, run SGP4, and take a look angle from a ground
station. No data files and no setup: give it the elements and a station, and it
returns azimuth, elevation, and slant range.

```elixir
line1 = "1 25544U 98067A   24001.50000000  .00016717  00000-0  10270-3 0  9009"
line2 = "2 25544  51.6400 208.8657 0002644 250.3037 109.7782 15.49560812999990"
station = %{latitude: 51.5, longitude: -0.1, altitude_m: 10.0}

with {:ok, tle} <- Sidereon.parse_tle(line1, line2),
     {:ok, look} <- Sidereon.look_angle(tle, ~U[2024-01-01 12:00:00Z], station) do
  look.azimuth      # degrees
  look.elevation    # degrees
  look.range_km     # slant range
end
```

The same parsed elements feed `Sidereon.propagate/2` (TEME position and
velocity), `Sidereon.geodetic/2` (the sub-satellite point), and
`Sidereon.predict_passes/5` (every pass above a minimum elevation over a window).

## Example: solve a position

The positioning engine is the other half of the library. Feed it pseudoranges
and a precise-ephemeris product and it returns a least-squares fix with ECEF and
geodetic positions plus geometry diagnostics.

```elixir
# GPS L1 pseudoranges (meters) for the satellites in view at the epoch.
observations = [
  {"G08", 23_825_519.8},
  {"G10", 22_717_690.1},
  {"G16", 20_478_653.4},
  {"G18", 21_768_335.2},
  {"G20", 21_248_327.7},
  {"G21", 20_808_709.8}
]

# `sp3_data` is a precise SP3 ephemeris (a string, or load one with
# `Sidereon.GNSS.SP3.load/1`).
with {:ok, sp3} <- Sidereon.GNSS.SP3.parse(sp3_data),
     {:ok, solution} <-
       Sidereon.GNSS.Positioning.solve(sp3, observations, ~N[2020-06-24 12:00:00],
         initial_guess: [4_500_000.0, 500_000.0, 4_500_000.0, 0.0]) do
  solution.position     # %{x_m, y_m, z_m} ITRF/IGS ECEF meters
  solution.geodetic     # %{lat_rad, lon_rad, height_m}
  solution.rx_clock_s   # receiver clock bias, seconds
  solution.dop.pdop     # position dilution of precision
  solution.used_sats    # satellites that contributed to the fix
end
```

`Sidereon.GNSS.RTK` and the PPP and DGNSS solvers follow the same pattern:
observations and a product in, a typed solution out.

Precise-positioning preprocessing and integrity support is grouped under
`Sidereon.GNSS.PrecisePositioning`: `TEC` estimates and levels dual-frequency
TEC arcs, `CycleSlip` maintains Melbourne-Wubbena and geometry-free detector
state, `Prep` prepares float and wide-lane-fixed epochs, `RAIM` provides global
tests, Brown snapshot-RAIM fault protection levels and FDE; protection levels
require positive redundancy, while `fault_free_accuracy_bounds` returns
fault-free accuracy bounds. `Kinematic` exposes the kinematic PPP
predict/correct cycle and ordered-arc solver. Exact epochs use
`Sidereon.GNSS.Time.ExactEpoch` resources throughout, and failures are typed
structs carrying stable core variants and display text.

For post-solve integrity checks, use `Sidereon.GNSS.QC.RaimInput.new/2` with
`Sidereon.GNSS.QC.raim/2` to run residual RAIM from satellite ids and
post-fit residuals. RAIM weights must come from per-satellite residual
variances; unit weights on metre-scale residuals make `fault_detected`
saturate near 100%:

```elixir
entries = [
  %{satellite_id: "G01", elevation_deg: 72.0},
  %{satellite_id: "G02", elevation_deg: 42.0},
  %{satellite_id: "G03", elevation_deg: 35.0}
]

weights = Sidereon.GNSS.QC.weight_vector(entries, a_m: 0.8, b_m: 0.8)
Sidereon.GNSS.QC.raim(input, weights: weights)
```

Use `Sidereon.GNSS.ARAIM.Geometry.from_az_el_deg/3` with
`Sidereon.GNSS.ARAIM.araim/3` to compute HPL/VPL protection levels from
azimuth/elevation rows, ISM records, and an integrity allocation.

A runnable [`sidereon.livemd`](sidereon.livemd) walks through propagation,
positioning, and conjunction screening; more notebooks live under
[the examples directory](https://github.com/neilberkman/sidereon-ex/tree/main/examples).

## SP3 interpolation policy and continuity

Precise orbit interpolation fits polynomial stencils over consecutive ephemeris
nodes. `Sidereon.GNSS.SP3.load/2`, `Sidereon.GNSS.SP3.parse/2`, and
`Sidereon.GNSS.SP3.parse_exact/3` accept optional `:gap_threshold_factor`
(default `1.5`, must be > 1.0) to configure the multiple of nominal node
spacing above which consecutive records mark a coverage gap:

```elixir
# Parse SP3 with a relaxed gap threshold to bridge coverage gaps:
{:ok, sp3} = Sidereon.GNSS.SP3.load("path/to/ephemeris.sp3", gap_threshold_factor: 13.0)
13.0 = Sidereon.GNSS.SP3.gap_threshold_factor(sp3)
```

The configured policy propagates across the pipeline:
- Carried by parsed `Sidereon.GNSS.SP3` products and retrievable with `Sidereon.GNSS.SP3.gap_threshold_factor/1`.
- Configurable on sample sources via `Sidereon.GNSS.PreciseEphemeris.from_samples/2` and `Sidereon.GNSS.PreciseEphemeris.gap_threshold_factor/1`.
- Inherited or overridden by cached interpolants via `Sidereon.GNSS.PreciseEphemeris.Interpolant.from_sp3/2`, `from_samples/2`, and `from_precise_ephemeris_samples/2`.
- Persisted in binary store headers via `artifact_bytes/2` and restored on `open/1` via `Sidereon.GNSS.PreciseEphemeris.InterpolantArtifact` and `PreciseInterpolantArtifact`.
- Applied during continuity checks and multi-center merges with `Sidereon.GNSS.SP3.check_continuity/2`, `Sidereon.GNSS.SP3.continuity_verdict/4`, and `Sidereon.GNSS.SP3.merge/2` (under `verify_continuity: [gap_threshold_factor: ...]`).

## What's in the box


- **Orbit propagation** SGP4 / SDP4 from TLE and OMM, numerical propagation
  with a composable force model (spherical-harmonic geopotential to selectable
  degree and order, Sun/Moon third-body, solar radiation pressure, relativistic
  correction, atmospheric drag), orbital decay estimation with a post-decay
  validity latch, two-body Kepler propagation, ground track,
  sub-satellite point, eclipse, Sun and Moon angles, and Doppler. See
  `Sidereon`, `Sidereon.Propagator`, `Sidereon.SGP4`, `Sidereon.Drag`.
- **GNSS positioning** single-point positioning (SPP), public multi-epoch
  static positioning with covariance, leave-one-out redundancy diagnostics,
  and robust weighting, RINEX observation to SPP assembly and solve helpers,
  RTK (float, integer-fixed, fix-and-hold) with typed arc/static/wide-lane
  configs, PPP with temporal-correlation covariance using calibrated day-length
  bounds, optional elevation cutoff, optional tropospheric-gradient estimation,
  reference/canonical PPP auto-init strategy selection, and a low-level
  precomputed-state range-rate prediction and velocity least-squares entry
  point, with additive detailed PPP solve errors,
  DGNSS, Huber-reweighted solves, RAIM with fault detection and exclusion,
  RAIM over existing SPP solutions, SBAS and RTCM SSR / Galileo HAS corrections,
  dilution of precision, and receiver velocity from Doppler. See
  `Sidereon.GNSS.Positioning`,
  `Sidereon.GNSS.StaticPositioning`, `Sidereon.GNSS.RTK`,
  `Sidereon.GNSS.PrecisePositioning`, `Sidereon.GNSS.DGNSS`,
  `Sidereon.GNSS.QC`, `Sidereon.GNSS.SBAS`, `Sidereon.GNSS.SSR`.
- **Integrity and error bounds** multi-constellation ARAIM protection levels,
  SBAS protection levels (DO-229), per-observation reliability (minimal
  detectable bias, internal and external), observability classification of
  every solution (rank, redundancy, conditioning), and covariance-derived
  error metrics (CEP, R95, SEP, error ellipse) that report wide or flagged
  bounds for weak geometry rather than fabricated confidence. See
  `Sidereon.GNSS.ARAIM`, `Sidereon.Reliability`, `Sidereon.ErrorMetrics`,
  `Sidereon.GNSS.QC`, `Sidereon.GNSS.SBAS`.
- **Timing, estimation, and geodesy** Allan-family clock stability with
  power-law noise identification (IEEE 1139), scalar Kalman and alpha-beta
  trackers with innovation gating, NIS/MAD/EWMA helpers, and CFAR thresholds,
  source localization (ToA/TDOA), station velocity (MIDAS) with trajectory fitting, step
  detection, and network motion fields, repeating-geometry (sidereal)
  filtering, geodesic direct and inverse problems (Karney), an epoch-aware
  terrestrial frame catalog (ITRF/ETRF Helmert sets), PROJ-compatible EGM96
  GTX vertical-grid interpolation, EGM2008 geoid grids, and
  batch least-squares orbit fitting against precise ephemerides (including
  terrestrial-frame SP3) with a per-satellite residual ledger. See
  `Sidereon.ClockStability`, `Sidereon.Estimation`, `Sidereon.SourceLocalization`,
  `Sidereon.GeodeticTimeSeries`, `Sidereon.Sidereal`, `Sidereon.OrbitDetermination`.
- **GNSS data and observations** SP3 (read, multi-center merge, write), broadcast
  navigation (RINEX 3.x / 4.x), IONEX, ANTEX, CLK, satellite code biases
  (Bias-SINEX and CODE DCB with OSB / DSB lookup), uniform satellite-state
  sampling that treats precise and broadcast sources interchangeably, RTCM 3
  broadcast ephemeris decode for GPS (1019), GLONASS (1020), Galileo
  (1045/1046), BeiDou (1042), and QZSS (1044), each real-data validated,
  RINEX 3 observations with Hatanaka / CRINEX decoding, carrier-phase
  combinations, cycle-slip detection, Hatch smoothing, ionosphere-free
  combination, precise interpolant artifacts, NTRIP request-byte construction,
  and GPS L1 C/A signal generation, acquisition, and LNAV decode.
  See `Sidereon.GNSS.SP3`, `Sidereon.GNSS.Broadcast`,
  `Sidereon.GNSS.Ephemeris`, `Sidereon.GNSS.Bias`,
  `Sidereon.GNSS.CarrierPhase`, `Sidereon.GNSS.RTCM`.
- **Ephemeris and time** JPL SPK / `.bsp` kernels for Sun, Moon, and planets;
  TEME, GCRS, ITRS, geodetic, ECEF, and topocentric frames with IAU2000A
  nutation and IAU2006 precession; UTC / TAI / TT / TDB / UT1 scales. See
  `Sidereon.Ephemeris`, `Sidereon.Coordinates`, `Sidereon.GNSS.Time`.
- **Geometry and events** pass prediction, look angles, conjunction and TCA
  screening, collision probability (Foster equal-area and numerical), CCSDS CDM
  parsing, covariance propagation, initial orbit determination (Gibbs,
  Herrick-Gibbs, Gauss angles-only), Lambert and Battin transfers, relative
  motion in RIC / RTN / LVLH frames with Clohessy-Wiltshire propagation,
  anomaly conversions, orbital element conversions including equinoctial and
  modified equinoctial forms, and angular geometry (angular separation,
  position angle, phase angle, beta angle). See `Sidereon.Passes`,
  `Sidereon.Conjunction`, `Sidereon.Collision`, `Sidereon.IOD`, `Sidereon.Lambert`,
  `Sidereon.OrbitalElements`, `Sidereon.Astro.Relative`, `Sidereon.Astro.Anomaly`,
  `Sidereon.Astro.Equinoctial`, `Sidereon.Angles`.
- **Observation and almanac** apparent topocentric places (right ascension,
  declination, azimuth, elevation) for the Sun, Moon, and any SPK body;
  sub-solar and sub-observer points, terminator latitude, parallactic angle,
  and satellite visual magnitude; Moon rise / set, illumination, and meridian
  transits; seasons, moon phases, planetary events, and lunar / solar eclipses
  over a window. See `Sidereon.Astro.Observe`, `Sidereon.Astro.Almanac`,
  `Sidereon.Bodies`, `Sidereon.Observation`.
- **Atmosphere** Klobuchar and Galileo NeQuick-G ionospheric delay, IONEX grids,
  tropospheric zenith delay and mapping, and NRLMSISE-00 neutral density. See
  `Sidereon.GNSS.Ionosphere`, `Sidereon.GNSS.Troposphere`, `Sidereon.Atmosphere`.
- **RF link budget** free-space path loss, EIRP, C/N0, dish gain, and link
  margin. See `Sidereon.RF`.
- **Terrain and data acquisition** DTED terrain elevation lookup with typed
  lookup options, memory-mappable terrain stores, EGM2008 raster-window geoid
  loading, and cache-first download of GNSS products (SP3, CLK, NAV, IONEX) and
  DTED tiles from public archives. Exact SP3/IONEX requests can select direct,
  NASA CDDIS/Earthdata, local-file, or in-memory sources without changing
  product identity, and return verified provenance. See `Sidereon.Terrain`,
  `Sidereon.GNSS.Data`, and `Sidereon.GNSS.Distribution`.
- **GNSS/INS fusion** strapdown mechanization with an error-state EKF (UKF
  option), loose and tight coupling with typed measurement inputs, IGG-III loose
  updates, an RTS smoother, encoded-state restore helpers, a serializable filter
  state, and field mode: zero-velocity and zero-angular-rate updates,
  non-holonomic constraints, per-fix-status weighting, and the IMU-to-body
  mounting matrix, all off by default. Per-row and joint innovation gates are
  mutually exclusive; EKF gates belong to the loose/tight update options and
  UKF gates to `ukf_update_options`. Rejected updates coast and retain their
  covariance. See `Sidereon.GNSS.Fusion`.
- **Reference-station static solve** rover and reference observations in, one
  station coordinate with covariance and typed per-mode errors out. See
  `Sidereon.GNSS.RTK`.
- **Scenario simulation** deterministic synthetic observables plus a
  ground-truth error ledger from a versioned scenario. See `Sidereon.GNSS.Scenario`.
- **Signal analysis** closed-form BPSK/BOC spectra, spectral separation
  coefficients, DLL jitter, multipath envelopes, and typed option structs. See
  `Sidereon.GNSS.Signal.Analysis`.
- **Format parse and serialize** TLE and OMM (KVN, XML, JSON) parse and encode,
  CCSDS OPM / OEM / CDM / TDM, and the GNSS products above. See `Sidereon.Format.TLE`,
  `Sidereon.Format.OMM`, `Sidereon.CCSDS.OPM`, `Sidereon.CCSDS.OEM`, `Sidereon.CCSDS.TDM`.
  OMM KVN and XML writers require mandatory CCSDS fields; their lenient
  counterparts accept partial messages.
  `Sidereon.GNSS.Data` builds CelesTrak GP and NAVCEN URLs, parses GP
  responses with source bytes and typed rejections, and fetches and caches
  catalog data. GP cache entries are fresh for two hours by default.
  TDM also exposes ordered metadata lookup, matching read/write policies, and
  typed input-error kinds with core diagnostic text.

Every result is what the engine computes, returned as plain Elixir structs and
maps with `{:ok, _}` / `{:error, _}` tuples. Full signatures live on
[HexDocs](https://hexdocs.pm/sidereon).

## Numerical forces and orbit fits

`Sidereon.Propagator.propagate_state/3` samples an inertial Cartesian state at
absolute TDB epochs. The integrator advances in elapsed TT and evaluates
forces at each step's TDB epoch. Atmospheric drag uses UT1 Earth orientation
and UTC space-weather inputs. Select built-in gravity and perturbations with
`:forces`. Supply `:drag` for fixed space weather or add `:space_weather_table`
and, optionally, `:space_weather_policy` for table-driven drag. The
`:additional_forces` option takes the same force objects as an orbit parameter
fit and evaluates them in list order after the built-in configuration and drag.

`Sidereon.Propagator.propagate_to_with_context/3` returns the full integration
result at a single TDB epoch. It takes the same force options as
`propagate_state/3`. With `dense_output: true` on the DP5(4) integration options,
`DenseOutput.coverage/1` gives the earliest and latest covered epochs and
`DenseOutput.eval/2` gives the GCRF state at an epoch on the arc.

`PropagationContext.with_body_fixed_frame_provider/2` accepts `:tdb` for the
built-in Earth orientation provider with strict UT1 validity, or an IERS 2010
provider for supplied daily samples. Pass `:strict` or `:permissive` as the third
argument to configure the built-in provider explicitly. An orbit parameter
fit with a configured provider requires the provider and fit to use the same
UT1 validity mode.

Pass a `:context` with a body-fixed frame provider when using tides in
`propagate_state/3` or `propagate_to_with_context/3`, whether selected in
`:forces` or supplied in `:additional_forces`. The `:de_ephemeris` option supplies
Sun and Moon positions. Standalone tide evaluation and orbit parameter fits
with tides also require a body-fixed frame provider. The relative-span
`propagate/3` uses its built-in TDB provider for tide selectors.

Select covariance forces with `:forces` on both `propagate_covariance/4` and
`propagate_covariance_with_context/5`. The `:twobody_j2` selector uses two-body
gravity with J2. The state, state-transition and covariance functions that
take a propagation context return `{:error, %Sidereon.Forces.PropagationError{}}`
for rejected force selectors and propagation failures. A covariance with
dimensions other than 6×6 has error kind `:invalid_dimensions` in the
context-based functions. The context-based decay estimators return
`{:error, %Sidereon.Drag.DecayError{}}` for invalid options and decay failures.

`Sidereon.Forces` evaluates accelerations, estimable parameters and position,
velocity and parameter partials. Its concrete force models include ECOM1,
ECOM2, empirical RTN, cannonball solar radiation pressure, and Earth albedo and
infrared radiation pressure. `CompositeForceModel` evaluates components in
the order supplied. Use a model as the variational equations' force or
supply it in `:additional_forces` for state propagation and orbit parameter
fitting in `Sidereon.OrbitDetermination.Parameters`. The position-based fit estimates
the initial state and selected force parameters, returning covariance,
correlation and post-fit residuals. Positions in the inertial fit and SP3
observations are in metres. The fitted state uses kilometres and kilometres
per second at the first observation's TDB epoch.
Both fits return `{:error, %OrbitParameterFitError{}}` for rejected options,
with the kind, detail and diagnostic message.

Solar radiation pressure uses the apparent discs of the WGS84 oblate Earth
and the Moon by default, with flux based on satellite–Sun distance. Set
`with_shadow_function/2`, `with_earth_shadow_model/2` and
`with_moon_eclipse/2` to choose its occultation geometry. Earth radiation
pressure offers lunar occultation as an option.

`Sidereon.Forces.IcgemGravityField` reads ICGEM coefficients, uncertainties,
tide conventions and time-variable terms. Its spherical-harmonic models
evaluate body-fixed acceleration and potential through Holmes–Featherstone
recursion. Time-variable coefficients take TT seconds past J2000.

## Analytic orbits and celestial geometry

`Sidereon.Propagator.Analytic` provides the Eckstein–Hechler and
Brouwer–Lyddane theories, Cartesian and orbital element conversions, and
mean and osculating states. Analytic angles are in radians and epochs are
TDB seconds past J2000.

`Sidereon.DeEphemeris` reads JPL DE binary files and returns geocentric
GCRF Sun and Moon states in metres and metres per second.
`Sidereon.Bodies` also provides analytic GCRS positions. Use
`Sidereon.Iers2010EarthOrientationProvider` with daily Earth orientation
samples to evaluate GCRF–ITRF rotations, rotation rates and quaternions.
A `Sidereon.Propagator.PropagationContext` can supply both Earth orientation
and JPL DE positions to propagation and force evaluation.

`Sidereon.Eclipse` provides lunar and combined Earth–Moon occultation alongside
the conical Earth shadow model. Gradient calls return position derivatives
per kilometre. `Sidereon.GNSS.Attitude` identifies GNSS spacecraft blocks,
returns their published yaw-law parameters, and evaluates nominal yaw and
Sun-fixed DYB axes from geocentric inertial vectors in SI units.

Use `Sidereon.GNSS.Attitude.gnss_attitude/3` to evaluate a yaw law along an
`OrbitAttitudeTrajectory` at TDB seconds past J2000. Build the trajectory from
SP3, broadcast navigation, an orbit scoring source, a GCRF analytic orbit or
continuous numerical output. Earth-fixed sources support the default TDB
orientation provider and the IERS 2010 provider. Pass `:tdb` to use core's
default UT1 policy, or `{:tdb, :strict}` or `{:tdb, :permissive}` to select it
explicitly. Use
`with_velocity_half_step_s/2` to set the differencing interval for
Earth-fixed velocities. `sample/2` returns the
satellite and Sun in GCRF in metres and metres per second. The Sun comes from
the analytic ephemeris by default. Use `with_de_ephemeris/2` to supply a JPL
DE ephemeris.

For continuous numerical output, set `dense_output: true` on
`Sidereon.Propagator.IntegratorOptions` and pass it under `:integration` to
`Sidereon.Propagator.propagate_to_with_context/3` with DP5(4). Pass the
result's `dense` field to `OrbitAttitudeTrajectory.from_dense_output/1`.
The requested epoch and any neighbouring epochs needed by the yaw law must
lie within the available coverage.

## Orbit scoring

`Sidereon.OrbitScoring` compares a predicted SP3 product, broadcast ephemeris
or sampled trajectory against a precise SP3 reference. The report gives
radial, transverse and normal errors, clock errors and SISRE by satellite,
constellation and prediction horizon. Coverage counts account for each
requested satellite and epoch. Callers can choose the evaluation epochs,
clock datum, RTN velocity convention, SISRE weights and frame reconciliation.
Invalid satellite identifiers and epochs are reported as `OrbitScoreError`
values with the refusal details.

## Other languages

sidereon is one validated engine with first-class interfaces in several
languages: Rust ([sidereon](https://github.com/neilberkman/sidereon)), Python
([sidereon-python](https://github.com/neilberkman/sidereon-python)), C
([sidereon-c](https://github.com/neilberkman/sidereon-c)), Go
([sidereon-go](https://github.com/neilberkman/sidereon-go)), Elixir (this
package), and WebAssembly
([sidereon-wasm](https://github.com/neilberkman/sidereon-wasm)). The same numbers
come out everywhere. See the live demo and docs at
[sidereon.dev](https://sidereon.dev).

## License

MIT. The engine's SGP4 propagation is a port of David Vallado's reference
implementation (credit: David Vallado, AIAA 2006); see the core
[sidereon](https://github.com/neilberkman/sidereon) crate for full attribution.
