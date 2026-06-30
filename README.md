# sidereon

GNSS and astrodynamics for Elixir: propagate satellites, predict passes, solve
precise positions (SPP / RTK / PPP), and convert between coordinate frames and
time scales — checked against the references the field trusts (Vallado, Skyfield,
IGS, IERS).

The numerics run in a Rust engine that ships as a **precompiled NIF** — adding
the dependency downloads a prebuilt binary for your platform, so there's no Rust
toolchain to install and nothing to compile. You write ordinary Elixir.

[![Run in Livebook](https://livebook.dev/badge/v1/blue.svg)](https://livebook.dev/run?url=https://github.com/neilberkman/sidereon/blob/main/examples/iss_tracker.livemd)

## Install

```elixir
def deps do
  [{:sidereon, "~> 0.8"}]
end
```

Published on Hex. Releases ship precompiled NIFs for common Linux, macOS, and
Windows targets and download automatically — no Rust build. (Set
`SIDEREON_BUILD=1` to compile from source instead.)

## Quickstart: when does the ISS fly over you?

No data files, no setup — give it a two-line element set and a ground station,
and ask when the satellite is above the horizon.

```elixir
# Real orbital elements for the ISS (grab fresh ones from CelesTrak any time).
{:ok, iss} =
  Sidereon.parse_tle(
    "1 25544U 98067A   26178.50947090  .00006280  00000+0  12016-3 0  9996",
    "2 25544  51.6322 248.9966 0004278 238.4942 121.5629 15.49454046573359"
  )

# A ground station: latitude/longitude in degrees, altitude in meters.
berkeley = %{latitude: 37.87, longitude: -122.27, altitude_m: 0.0}

# Every pass that peaks above 10° over the next 24 hours.
now = DateTime.utc_now()

{:ok, passes} =
  Sidereon.predict_passes(iss, berkeley, now, DateTime.add(now, 1, :day),
    min_elevation: 10.0
  )

for p <- passes do
  rise = Calendar.strftime(p.rise, "%H:%M")
  mins = Float.round(p.duration_seconds / 60, 1)
  IO.puts("#{rise} UTC · #{mins} min · peak #{round(p.max_elevation)}°")
end
```

```
08:28 UTC · 10.9 min · peak 88°
10:06 UTC · 9.7 min · peak 16°
13:22 UTC · 9.3 min · peak 13°
14:59 UTC · 10.9 min · peak 56°
16:36 UTC · 9.2 min · peak 14°
```

Each `%Sidereon.Pass{}` carries `rise`, `set`, `max_elevation`,
`max_elevation_time`, and `duration_seconds`. The same parsed elements feed
`Sidereon.propagate/2` (TEME position/velocity), `Sidereon.geodetic/2` (the
sub-satellite point), and `Sidereon.look_angle/3` (azimuth/elevation/range from a
station). Times are plain `DateTime` structs in, `DateTime` structs out.

## Precise positioning

The positioning engine is the other half of the library: feed it pseudoranges
and a precise-ephemeris product and it returns a least-squares fix.

```elixir
{:ok, sp3} = Sidereon.GNSS.SP3.load("igs_product.sp3")

observations = [{"G07", 24_602_022.18}, {"G08", 23_676_569.52}, {"E05", 27_038_058.35}]

{:ok, sol} =
  Sidereon.GNSS.Positioning.solve(sp3, observations, ~N[2020-06-24 12:00:00],
    ionosphere: true,
    troposphere: true
  )

sol.position    # %{x_m: ..., y_m: ..., z_m: ...} — ITRF/IGS ECEF meters
sol.geodetic    # %{lat_rad: ..., lon_rad: ..., height_m: ...}
sol.dop.pdop    # position dilution of precision
sol.used_sats   # satellites that contributed to the fix
```

`Sidereon.GNSS.RTK` and the PPP solvers follow the same shape — observations and
a product in, a typed solution with ECEF/geodetic positions and geometry
diagnostics out. Need the products? `Sidereon.GNSS.Data` fetches and caches SP3,
RINEX, and IONEX from the public archives.

## What's in the box

Elixir is sidereon's **broadest** interface — the full engine is exposed:

- **Orbits** — SGP4/SDP4 and TLE/OMM, numerical force-model propagation, passes,
  look angles, ground track, eclipse, Sun/Moon angles, Doppler
- **Frames & time** — TEME ↔ GCRS ↔ ITRS, geodetic ↔ ECEF, topocentric, with
  IAU2000A nutation / IAU2006 precession and UTC/TAI/TT/TDB/UT1 conversions
- **Ephemeris** — JPL SPK / `.bsp` kernels for Sun, Moon, and planets
- **GNSS positioning** — SPP, RTK (float / integer-fixed / fix-and-hold), PPP,
  RAIM + FDE, DOP, receiver velocity from Doppler
- **GNSS data & observations** — SP3 (read, multi-center merge, write), broadcast
  navigation (RINEX 3.x/4.x), IONEX, ANTEX, CLK; RINEX 3 observations with
  Hatanaka/CRINEX decoding; carrier-phase combinations, cycle-slip detection,
  Hatch smoothing, ionosphere-free combination, DGNSS; GPS L1 C/A signal
  generation, acquisition, and LNAV decode
- **Space situational awareness** — conjunction / TCA screening, collision
  probability (Foster equal-area and numerical), CCSDS CDM parsing, catalog
  screening, covariance propagation
- **Atmosphere** — NRLMSISE-00 density, surface to ~1000 km
- **Initial orbit determination** — Gibbs / Herrick-Gibbs, Gauss angles-only,
  Lambert/Battin transfers
- **RF** — link budget (FSPL, EIRP, C/N₀, link margin, dish gain)
- **Real-time** — `Sidereon.Tracker` GenServer with PubSub-compatible broadcasts
- **Live data** — CelesTrak TLE/OMM fetch, constellation loading, name search
- **Batch** — Nx-powered tensorized geometry, visibility, and RF (GPU-ready via
  EXLA / Torchx)

Every result is exactly what the engine computes, returned as plain Elixir
structs and maps with `{:ok, _}` / `{:error, _}` tuples. Full signatures live on
[HexDocs](https://hexdocs.pm/sidereon), with runnable Livebooks under
[`examples/`](examples/).

## Other languages

sidereon is one validated engine with first-class interfaces in **Rust**,
**Python**, **C**, **Elixir**, and **WebAssembly** — same numbers everywhere.
See the live demo and docs at [sidereon.dev](https://sidereon.dev).

## How it's validated

The SGP4 propagator is a Rust port of David Vallado's reference implementation,
bit-exact to it. Frames and time are checked against Skyfield and IERS; the
positioning stack is checked against IGS products. Detailed agreement results are
in [guides/accuracy.md](guides/accuracy.md).

## License

MIT. The engine's SGP4 propagation is a Rust port of David Vallado's reference
implementation (credit: David Vallado, AIAA 2006); see the `sidereon-core` crate
for full attribution.
