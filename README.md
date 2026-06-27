[![Hex.pm](https://img.shields.io/hexpm/v/sidereon)](https://hex.pm/packages/sidereon)
[![Hexdocs.pm](https://img.shields.io/badge/docs-hexdocs.pm-purple)](https://hexdocs.pm/sidereon)
[![CI](https://github.com/neilberkman/sidereon/actions/workflows/ci.yml/badge.svg)](https://github.com/neilberkman/sidereon/actions)

# Sidereon

Sidereon is an Elixir package for satellite and GNSS workflows.

It provides SGP4/SDP4 propagation, coordinate frame transforms, GNSS positioning, orbit determination, conjunction assessment, pass prediction, live TLE/OMM data access, tracking, RF utilities, and batch geometry analysis. Numeric kernels run in a Rust NIF; orchestration and application workflows run in Elixir, with Nx support for tensor workloads.

Validation coverage is summarized in [Pinned Fixture Agreement](#pinned-fixture-agreement) and [guides/accuracy.md](guides/accuracy.md).

### Try it in Livebook

[![Run in Livebook](https://livebook.dev/badge/v1/blue.svg)](https://livebook.dev/run?url=https://github.com/neilberkman/sidereon/blob/main/examples/iss_tracker.livemd)

## Features

| Category                   | What it does                                                                                                                                                                                                                                                                                                    |
| -------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Propagation**            | SGP4/SDP4 via the [`sgp4`](https://crates.io/crates/sgp4) Rust crate (Rust NIF)                                                                                                                                                                                                                                 |
| **Coordinate transforms**  | TEME, GCRS, ITRS, geodetic, and topocentric frame transforms (Rust NIF)                                                                                                                                                                                                                                        |
| **Ground station**         | Pass prediction, look angles, Doppler shift, RF link budget                                                                                                                                                                                                                                                     |
| **Orbit determination**    | Gibbs, Herrick-Gibbs, Gauss angles-only, Lambert/Battin (Rust NIF)                                                                                                                                                                                                                                              |
| **Conjunction assessment** | Closest-approach finder (validated against the Iridium 33 / Cosmos 2251 collision), collision probability (Foster equal-area and numerical), CCSDS CDM parsing, and catalog screening                                                                                                                            |
| **Eclipse prediction**     | Sunlit / penumbra / umbra with shadow fraction                                                                                                                                                                                                                                                                  |
| **Atmospheric density**    | NRLMSISE-00 model, surface to ~1000 km (Rust NIF)                                                                                                                                                                                                                                                               |
| **JPL ephemeris**          | SPK/BSP reader for Sun, Moon, planets (Rust NIF)                                                                                                                                                                                                                                                                |
| **GNSS positioning**       | Single-point positioning from SP3 or broadcast ephemeris for GPS, Galileo, BeiDou, and GLONASS; plus carrier-phase positioning, integer ambiguity fixing (LAMBDA, with partial ambiguity resolution), and RTK baseline solving: float, integer-fixed, and a sequential fix-and-hold filter                       |
| **GNSS ephemeris & data**  | SP3 precise products (read, multi-source merge across analysis centers, and write back out) plus broadcast and precise orbit/clock comparison checks, RINEX 3.x/4.xx broadcast navigation, GNSS constellation catalogs, and optional SP3/CLK/NAV/IONEX fetch/cache from public archives                            |
| **GNSS observations**      | RINEX 3 observation parsing with Hatanaka (CRINEX) decoding for raw observation values, carrier phases, pseudoranges, and station positioning from `.crx`/`.rnx` files (Rust NIF)                                                                                                                               |
| **Reduced orbit**          | Compact fitted mean-element model (circular or eccentric) for fast approximate position, caching, and transport, with source-backed drift reporting (Rust NIF)                                                                                                                                                  |
| **GNSS measurements & QC** | Predicted observables (range, range-rate, Doppler, az/el), receiver velocity from Doppler, RAIM fault detection + FDE, dilution of precision & visibility, carrier-phase combinations / slip detection / Hatch smoothing, dual-frequency ionosphere-free combination, and code-differential (DGNSS) positioning |
| **GNSS signals**           | GPS L1 C/A Gold-code generation, correlation, and acquisition; coherent-integration loss; LNAV navigation-message subframe synthesis and decoding                                                                                                                                                               |
| **Live data**              | CelesTrak TLE/OMM fetching, constellation loading, name search                                                                                                                                                                                                                                                  |
| **Real-time tracking**     | GenServer with PubSub-compatible broadcasts                                                                                                                                                                                                                                                                     |
| **RF primitives**          | FSPL, EIRP, C/N₀, link margin, dish gain                                                                                                                                                                                                                                                                        |
| **Batch analysis**         | Nx-powered tensorized geometry, visibility, and RF (GPU-ready via EXLA/Torchx)                                                                                                                                                                                                                                  |
| **Formats**                | `Sidereon.Elements` with TLE and OMM parsers/encoders                                                                                                                                                                                                                                                              |

## Installation

```elixir
def deps do
  [{:sidereon, "~> 0.22"}]
end
```

Release packages that include matching GitHub precompiled-NIF assets and
`checksum-Elixir.Sidereon.NIF.exs` download the Rust NIF for common Linux, macOS,
and Windows targets. Development builds, source releases without a checksum, and
`SIDEREON_BUILD=1` builds compile the NIF locally from Rust. GNSS product fetching
(`Sidereon.GNSS.Data`) uses Sidereon's built-in `Req` dependency.

## Quick Start

```elixir
# Fetch the ISS TLE from CelesTrak
{:ok, [iss]} = Sidereon.CelesTrak.fetch_tle(25544)

# Propagate to now
{:ok, teme} = Sidereon.propagate(iss, DateTime.utc_now())
teme.position   # {x, y, z} km
teme.velocity   # {vx, vy, vz} km/s

# Where is it over the Earth?
{:ok, geo} = Sidereon.geodetic(iss, DateTime.utc_now())
# %{latitude: 23.4, longitude: -45.6, altitude_km: 420.1}
```

## Usage

### Parse from TLE or OMM

```elixir
# Two-Line Element format
{:ok, elements} = Sidereon.Format.TLE.parse(line1, line2)

# OMM JSON (CelesTrak / Space-Track)
{:ok, elements} = Sidereon.Format.OMM.parse(omm_json_map)

# Encode back to either format
{:ok, {line1, line2}} = Sidereon.Format.TLE.encode(elements)
omm_map = Sidereon.Format.OMM.encode(elements)
```

The `Sidereon.Elements` struct is format-agnostic: parse from any source, serialize to any format.

### Coordinate Transforms

```elixir
gcrs = Sidereon.teme_to_gcrs(teme, datetime)

station = %{latitude: 40.7128, longitude: -74.006, altitude_m: 10.0}
{:ok, geo} = Sidereon.geodetic(elements, datetime)
{:ok, look} = Sidereon.look_angle(elements, datetime, station)
# %{azimuth: 359.6, elevation: -41.9, range_km: 9130.5}
```

The GCRS transform includes IAU2000A nutation (1365 terms), IAU2006 precession, frame bias, and time scale conversions (UTC→TAI→TT→TDB→UT1).

### Constellation Management

```elixir
{:ok, constellation} = Sidereon.Constellation.load("globalstar")
constellation.count  #=> 85

# Propagate all satellites in parallel
positions = Sidereon.Constellation.propagate_all(constellation, DateTime.utc_now())

# Find visible satellites from a ground station
{:ok, visible} = Sidereon.Constellation.visible_from(constellation, station, datetime)
```

### Real-Time Tracking

```elixir
{:ok, tracker} = Sidereon.Tracker.start_link(elements, interval_ms: 1000)
Sidereon.Tracker.subscribe(tracker)

receive do
  {:sidereon_tracker, _pid, state} ->
    IO.puts("#{state.geodetic.latitude}, #{state.geodetic.longitude}")
end
```

### Pass Prediction

```elixir
{:ok, passes} = Sidereon.Passes.predict(elements, station,
  ~U[2024-01-01 00:00:00Z], ~U[2024-01-02 00:00:00Z])

for pass <- passes do
  IO.puts("Rise: #{pass.rise} | Max el: #{pass.max_elevation}° | Set: #{pass.set}")
end
```

### Conjunction Assessment

```elixir
approaches = Sidereon.Conjunction.find(elements1, elements2,
  end_min: 2880.0, step_min: 1.0, threshold_km: 50.0)

for {tca_min, distance_km} <- approaches do
  IO.puts("TCA: +#{Float.round(tca_min / 60, 1)}h, miss: #{Float.round(distance_km, 2)} km")
end
```

For collision probability from a CCSDS CDM and catalog-wide screening, see
[`examples/conjunction_alert.livemd`](examples/conjunction_alert.livemd).

### RF Link Budget

```elixir
# Path loss from slant range
fspl = Sidereon.RF.fspl(look.range_km, 1616.0)  # MHz

# Full link margin
margin = Sidereon.RF.link_margin(%{
  eirp_dbw: Sidereon.RF.eirp(27.0, 3.0),
  fspl_db: fspl,
  receiver_gt_dbk: -12.0,
  other_losses_db: 3.0,
  required_cn0_dbhz: 35.0
})
```

### Orbit Determination

```elixir
# Gibbs: 3 position vectors → velocity
{v2, theta12, theta23, copa} = Sidereon.IOD.gibbs(r1, r2, r3)

# Gauss: 3 angular observations → full orbit
{r2, v2} = Sidereon.IOD.gauss(
  decl1, decl2, decl3, rtasc1, rtasc2, rtasc3,
  jd1, jdf1, jd2, jdf2, jd3, jdf3,
  site1, site2, site3)

# Lambert: transfer orbit between two positions
{v1t, v2t} = Sidereon.Lambert.solve(r1, r2, v1, dm, de, nrev, dtsec)
```

### Eclipse & Ephemeris

```elixir
{:ok, eph} = Sidereon.Ephemeris.load("/path/to/de421.bsp")

{:ok, status} = Sidereon.Eclipse.check(elements, datetime, eph)
# :sunlit | :penumbra | :umbra

{:ok, mars} = Sidereon.Ephemeris.position(eph, :mars, :earth, datetime)
```

### GNSS Positioning

GNSS-specific APIs are grouped under `Sidereon.GNSS.*`.

```elixir
# Precise ephemeris (SP3): interpolate a satellite's position/clock at any epoch
sp3 = Sidereon.GNSS.SP3.load!("GBM0MGXRAP_20201760000_01D_05M_ORB.SP3")
{:ok, state} = Sidereon.GNSS.SP3.position(sp3, "G01", ~N[2020-06-24 00:00:00])
# %Sidereon.GNSS.SP3.State{x_m: ..., y_m: ..., z_m: ..., clock_s: ...}

# Merge SP3 products from several analysis centers into one consistent dataset:
# union coverage, robust per-(sat, epoch) consensus, outliers quarantined
# rather than silently averaged.
{:ok, merged, _report} = Sidereon.GNSS.SP3.merge([sp3_esa, sp3_gfz, sp3_igs])

# ...and write the merged product back out as a single standard SP3 file
# (read → merge → write; atomic, optionally gzipped):
{:ok, _path} = Sidereon.GNSS.Data.write_sp3(merged, "merged.sp3")

# Or broadcast navigation for GPS, Galileo, BeiDou, and GLONASS (RINEX 3.x/4.xx)
eph = Sidereon.GNSS.Broadcast.load!("BRDC00WRD_R_20201770000_01D_MN.rnx")

# Single-point position from one epoch of pseudoranges
observations = [{"G07", 24_602_022.18}, {"G08", 23_676_569.52}, {"E05", 27_038_058.35}]

{:ok, sol} =
  Sidereon.GNSS.Positioning.solve(eph, observations, ~N[2020-06-25 12:00:00],
    ionosphere: true,
    troposphere: true,
    klobuchar_alpha: {1.0e-8, 0.0, 0.0, 0.0},
    klobuchar_beta: {9.0e4, 0.0, 0.0, 0.0}
  )

sol.position          # %{x_m: ..., y_m: ..., z_m: ...} - ITRF ECEF meters
sol.dop.pdop          # position dilution of precision
sol.system_clocks_s   # %{"G" => ..., "E" => ...} - one receiver clock per GNSS
```

Products can be fetched and cached:

```elixir
product = Sidereon.GNSS.Data.mgex_sp3(:gfz, ~D[2020-06-24])
{:ok, sp3} = Sidereon.GNSS.Data.sp3(product)   # downloads, verifies, caches, loads

# Current-day/live-latency orbit products use the ultra-rapid OPSULT tier.
ultra = Sidereon.GNSS.Data.ops_ultra_sp3(:igs_ult, DateTime.utc_now())
{:ok, sp3} = Sidereon.GNSS.Data.sp3(ultra)

# Or fetch several centers and merge whatever has published so far.
{:ok, merged, report} =
  Sidereon.GNSS.Data.fetch_merged_sp3(DateTime.utc_now(), [:igs_ult, :gfz_ult, :esa_ult])
```

Parse a station's RINEX observation file (Hatanaka `.crx` or plain `.rnx`),
extract pseudoranges, and recover its position:

```elixir
{:ok, obs} = Sidereon.GNSS.RINEX.Observations.load("STAT00DNK_R_..._MO.crx")
[%{index: i, epoch: epoch} | _] = Sidereon.GNSS.RINEX.Observations.epochs(obs)
{:ok, prs} = Sidereon.GNSS.RINEX.Observations.pseudoranges(obs, i, codes: %{"G" => ["C1C"]})
{:ok, sol} = Sidereon.GNSS.Positioning.solve(eph, prs, epoch)
```

Inspect carrier-phase observables and build the standard precise-positioning
combinations:

```elixir
{:ok, phases} =
  Sidereon.GNSS.RINEX.Observations.phases(obs, i, codes: %{"G" => ["L1C", "L2W"]})

g03 = phases["G03"]
l1 = Enum.find(g03, &(&1.code == "L1C"))
l2 = Enum.find(g03, &(&1.code == "L2W"))

geometry_free_m = Sidereon.GNSS.CarrierPhase.geometry_free(l1.value_m, l2.value_m)
{:ok, mw_m} =
  Sidereon.GNSS.CarrierPhase.melbourne_wubbena(
    l1.value_cycles,
    l2.value_cycles,
    24_000_000.0,
    24_000_005.0,
    l1.frequency_hz,
    l2.frequency_hz
  )
```

Fit a compact reduced-orbit model and check its drift against the source:

```elixir
{:ok, model} =
  Sidereon.GNSS.ReducedOrbit.fit(sp3,
    satellite_id: "G05",
    window: {~N[2020-06-24 00:00:00], ~N[2020-06-24 06:00:00]},
    model: :eccentric_secular
  )

{:ok, pos} = Sidereon.GNSS.ReducedOrbit.position(model, ~N[2020-06-24 12:00:00])  # ECEF m
map = Sidereon.GNSS.ReducedOrbit.to_map(model)   # versioned, transportable
```

The same reduced-orbit API accepts a parsed TLE/OMM element set and samples it
through SGP4:

```elixir
{:ok, tle} = Sidereon.Format.TLE.parse(line1, line2)
{:ok, leo_model} =
  Sidereon.GNSS.ReducedOrbit.fit(tle,
    window: {~N[2018-07-04 00:00:00], ~N[2018-07-04 01:30:00]},
    model: :eccentric_secular
  )
```

A runnable walkthrough is in [`examples/gnss_positioning.livemd`](examples/gnss_positioning.livemd).

A GPS constellation catalog (PRN ↔ SVN ↔ NORAD ↔ SP3 id, active/usable flags)
is built from CelesTrak and an optional NAVCEN overlay:

```elixir
{:ok, records} = Sidereon.GNSS.Constellation.fetch_gps()
Sidereon.GNSS.Constellation.to_csv(records)         # prn,norad_cat_id,active,sp3_id

# Cross-check a catalog against the satellites a precise product actually carries
report = Sidereon.GNSS.Constellation.validate_sp3(records, sp3)
Sidereon.GNSS.Constellation.valid?(report)
```

## Coordinate Frames

| Frame       | Description                                              |
| ----------- | -------------------------------------------------------- |
| TEME        | True Equator Mean Equinox, SGP4 output frame             |
| GCRS        | Geocentric Celestial Reference System, inertial          |
| ITRS        | International Terrestrial Reference System, Earth-fixed  |
| Geodetic    | WGS84 latitude, longitude, altitude                      |
| Topocentric | Azimuth, elevation, range from a ground station          |

## Pinned Fixture Agreement

These are agreement results against pinned test fixtures and oracles, not field-accuracy guarantees. Geodetic and topocentric coordinate checks use tolerance tests.

| Component              | Fixture / oracle                | Agreement in validation tests       |
| ---------------------- | ------------------------------- | ----------------------------------- |
| TEME→GCRS→ITRS         | Skyfield                        | 0 ULP (bit-identical)               |
| SGP4 propagation       | Skyfield                        | < 1 mm (via sgp4 crate)             |
| Gibbs / Herrick-Gibbs  | Vallado Python                  | 0 ULP                               |
| Gauss IOD              | Vallado Python                  | 1e-12 relative                      |
| Lambert (Battin)       | Vallado Python                  | 1e-12 relative                      |
| Conjunction            | Iridium/Cosmos 2251             | < 2 km miss, < 1 min timing         |
| RF (FSPL)              | Analytical (inverse square law) | Exact                               |
| SP3 interpolation      | gnssanalysis                    | 0 ULP                               |
| Broadcast orbit/clock  | pinned IS-GPS-200 recipe        | 0 ULP (recipe); ~m compared to SP3  |
| Ionosphere/troposphere | Klobuchar / Saastamoinen-Niell  | 0 ULP                               |
| GNSS DOP               | cofactor inverse                | 0 ULP                               |
| Single-point position  | scipy least squares             | sub-micron agreement                |
| RTK filter             | Elixir reference implementation | bit-identical trace gates           |
| RINEX / CRINEX decode  | RNXCMP `crx2rnx`                | byte-exact                          |
| Reduced orbit          | SP3 / SGP4 (drift-checked)      | approximate, source-backed drift    |

## License

MIT

## Attribution

The engine's SGP4 propagation is a Rust port of David Vallado's reference implementation (credit: David Vallado, AIAA 2006). See the `sidereon-core` crate for full attribution.
