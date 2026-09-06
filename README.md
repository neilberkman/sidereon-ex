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
  [{:sidereon, "~> 2.1"}]
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
    {:sidereon, "~> 2.1"},
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
    {:sidereon, "~> 2.1"},
    {:rustler, ">= 0.0.0", optional: true}
  ]
end
```

with `SIDEREON_BUILD=1` set for that build. Sidereon logs an explicit
diagnosis at application start when it detects that the packaged artifact's
libc does not match the running system, naming this section - but it can only
report the mismatch, not prevent it, because by then the wrong artifact is
already packaged.

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
  mounting matrix, all off by default. See `Sidereon.GNSS.Fusion`.
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

Every result is what the engine computes, returned as plain Elixir structs and
maps with `{:ok, _}` / `{:error, _}` tuples. Full signatures live on
[HexDocs](https://hexdocs.pm/sidereon).

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
