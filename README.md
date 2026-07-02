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
  [{:sidereon, "~> 0.9"}]
end
```

Releases ship precompiled NIFs for common Linux, macOS, and Windows targets and
download automatically, so no Rust build is needed. (Set `SIDEREON_BUILD=1` to
compile from source instead.)

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

`Sidereon.GNSS.RTK` and the PPP and DGNSS solvers follow the same shape:
observations and a product in, a typed solution out.

A runnable [`sidereon.livemd`](sidereon.livemd) walks through propagation,
positioning, and conjunction screening; more notebooks live under
[`examples/`](examples).

## What's in the box

- **Orbit propagation** SGP4 / SDP4 from TLE and OMM, numerical force-model
  propagation with an optional atmospheric drag model, orbital decay estimation,
  two-body Kepler propagation, ground track, sub-satellite point, eclipse, Sun
  and Moon angles, and Doppler. See `Sidereon`, `Sidereon.Propagator`,
  `Sidereon.SGP4`, `Sidereon.Drag`.
- **GNSS positioning** single-point positioning (SPP), RTK (float,
  integer-fixed, fix-and-hold), PPP, DGNSS, robust Huber-reweighted solves,
  RAIM with fault detection and exclusion, SBAS and RTCM SSR / Galileo HAS
  corrections, dilution of precision, and receiver velocity from Doppler. See
  `Sidereon.GNSS.Positioning`, `Sidereon.GNSS.RTK`, `Sidereon.GNSS.PrecisePositioning`,
  `Sidereon.GNSS.DGNSS`, `Sidereon.GNSS.QC`, `Sidereon.GNSS.SBAS`, `Sidereon.GNSS.SSR`.
- **GNSS data and observations** SP3 (read, multi-center merge, write), broadcast
  navigation (RINEX 3.x / 4.x), IONEX, ANTEX, CLK, satellite code biases
  (Bias-SINEX and CODE DCB with OSB / DSB lookup), uniform satellite-state
  sampling that treats precise and broadcast sources interchangeably, RINEX 3
  observations with Hatanaka / CRINEX decoding, carrier-phase combinations,
  cycle-slip detection, Hatch smoothing, ionosphere-free combination, and GPS
  L1 C/A signal generation, acquisition, and LNAV decode. See `Sidereon.GNSS.SP3`,
  `Sidereon.GNSS.Broadcast`, `Sidereon.GNSS.Ephemeris`, `Sidereon.GNSS.Bias`,
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
- **Terrain and data acquisition** DTED terrain elevation lookup, and
  cache-first download of GNSS products (SP3, CLK, NAV, IONEX) and DTED tiles
  from public archives, with canonical filenames and archive URLs for callers
  who fetch their own. See `Sidereon.Terrain`, `Sidereon.GNSS.Data`.
- **Format parse and serialize** TLE and OMM (KVN, XML, JSON) parse and encode,
  CCSDS OPM / OEM / CDM, and the GNSS products above. See `Sidereon.Format.TLE`,
  `Sidereon.Format.OMM`, `Sidereon.CCSDS.OPM`, `Sidereon.CCSDS.OEM`.

Every result is what the engine computes, returned as plain Elixir structs and
maps with `{:ok, _}` / `{:error, _}` tuples. Full signatures live on
[HexDocs](https://hexdocs.pm/sidereon).

## Other languages

sidereon is one validated engine with first-class interfaces in several
languages: Rust ([sidereon](https://github.com/neilberkman/sidereon)), Python
([sidereon-python](https://github.com/neilberkman/sidereon-python)), C
([sidereon-c](https://github.com/neilberkman/sidereon-c)), Elixir (this
package), and WebAssembly
([sidereon-wasm](https://github.com/neilberkman/sidereon-wasm)). The same numbers
come out everywhere. See the live demo and docs at
[sidereon.dev](https://sidereon.dev).

## License

MIT. The engine's SGP4 propagation is a port of David Vallado's reference
implementation (credit: David Vallado, AIAA 2006); see the core
[sidereon](https://github.com/neilberkman/sidereon) crate for full attribution.
