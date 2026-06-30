# PPP fixture provenance

Fixtures backing `test/gnss_ppp_corrections_test.exs` (ZIM200CHE, 2026 day 133).

## `ZIM200CHE_R_20261330000_01D_30S_MO_1h.rnx`

- **Source:** IGS station RINEX 3 observation file for ZIM200CHE (Zimmerwald,
  Switzerland), 2026-05-13 (day 133), 30 s sampling.
- **Trim:** RINEX header plus the first 120 epochs (the first hour) of the daily
  file, enough for the bounded float solves and the correction-table property
  checks. Receiver antenna `TRM59800.00     NONE`.

## `IGS0OPSFIN_20261330000_01D_15M_ORB.SP3`

- **Source:** IGS final orbit SP3 for 2026 day 133, 15-minute nodes. Used whole
  (253 KB); the sliding-window interpolation needs nodes spanning the arc.

## `igs20_zim2_gps.atx`

- **Source:** IGS station general ANTEX file
  (`https://files.igs.org/pub/station/general/igs20.atx`).
- **Trim:** ANTEX header, all 116 GPS satellite antenna blocks, and the
  `TRM59800.00     NONE` receiver block used by ZIM200CHE.

## `golden/tides_dehant_golden.json`

- **Source:** copied verbatim from the `astrodynamics-gnss` crate
  (`tests/fixtures/tides/tides_dehant_golden.json`); IERS DEHANTTIDEINEL
  reference cases. Used to check `Orbis.NIF.solid_earth_tide` through the NIF.

## `golden/sun_moon_skyfield_golden.json`

- **Source:** copied from the `astrodynamics` crate
  (`tests/fixtures/bodies/sun_moon_skyfield_golden.json`); Skyfield/JPL DE440
  geocentric Sun/Moon positions in ITRS. Used to check `Orbis.NIF.sun_moon_ecef`.
