# Observation fixtures — provenance

Small, trimmed RINEX 3 observation fixtures for the CRINEX round-trip and the
end-to-end single-point-positioning test. Committed offline; no test fetches
the network by default.

## ESBC00DNK_R_20201770000_01D_30S_MO_trim.crx / .rnx

- **Station / day:** ESBC00DNK (Esbjerg, Denmark), 2020 day-of-year 177
  (2020-06-25), 30 s sampling, MIXED observation, RINEX 3.05.
- **Upstream source:** the full daily file
  `CRNX/V3/ESBC00DNK_R_20201770000_01D_30S_MO.crx.gz` from the
  `nav-solutions/data` redistribution
  (`https://github.com/nav-solutions/data`), which mirrors the IGS/MGEX
  archive. The same station and day as the committed broadcast navigation
  fixture `test/fixtures/nav/ESBC00DNK_R_20201770000_01D_MN.rnx`.
- **Trim:** decoded with `crx2rnx`, kept the verbatim header plus the first two
  epochs (epoch boundary trim — a CRINEX body cannot be cut mid-stream because
  the difference engines are stateful), then re-compressed with `rnx2crx` so the
  committed `.crx` is self-consistent and re-initializes cleanly at epoch 1. The
  `.rnx` is the `crx2rnx` decode of the committed `.crx`.
- **Reference decoder:** RNXCMP `crx2rnx` / `rnx2crx` version 4.1.0 (the
  `hatanaka` Python package's bundled RNXCMP binaries).
- **Trim commands (equivalent):**

  ```
  gunzip -k ESBC00DNK_R_20201770000_01D_30S_MO.crx.gz
  crx2rnx - < ESBC00DNK_R_20201770000_01D_30S_MO.crx > full.rnx
  head -n 143 full.rnx > trim.rnx        # header + first 2 epochs
  rnx2crx - < trim.rnx > ESBC00DNK_R_20201770000_01D_30S_MO_trim.crx
  crx2rnx - < ESBC..._trim.crx > ESBC00DNK_R_20201770000_01D_30S_MO_trim.rnx
  ```

- **sha256:**
  - `.crx`: `73b2294711f317c20a043c290c5d590917b037caac8feb21d74dc7600f55f5c2`
  - `.rnx`: `c1fbc120be90d7498b3ff138f28ceb7865ce050ddd9cd2f55ce413e553f2e7e0`
- **Header APPROX POSITION XYZ (ECEF m):** `3582105.2910  532589.7313  5232754.8054`
  — the surveyed receiver position the SPP test recovers to metre level.

## ESBC00DNK_R_20201770000_01D_30S_MO_120epoch.rnx

- **Station / day:** ESBC00DNK (Esbjerg, Denmark), 2020 day-of-year 177
  (2020-06-25), 30 s sampling, MIXED observation, RINEX 3.05.
- **Purpose:** real multi-epoch precise-positioning regression. The fixture is
  long enough to exercise the static-position / per-epoch-clock /
  per-satellite-ambiguity float model and the a-priori troposphere correction,
  while still small enough for the default offline test suite.
- **Upstream source:** the same full daily CRINEX product as the two-epoch trim:
  `CRNX/V3/ESBC00DNK_R_20201770000_01D_30S_MO.crx.gz` from the
  `nav-solutions/data` redistribution
  (`https://github.com/nav-solutions/data`).
- **Decode / trim:** decompressed the upstream `.crx.gz`, decoded the `.crx`
  with `Orbis.GNSS.RINEX.Observations.decode_crinex/1`, kept the verbatim
  header plus the first 120 epochs (00:00:00 through 00:59:30 GPST), and updated
  `TIME OF LAST OBS` to the last retained epoch. The committed fixture is plain
  `.rnx`; it is not re-compressed because the real-arc gate only needs the RINEX
  observation parser, not the CRINEX round-trip path.
- **sha256:**
  - upstream `.crx.gz`:
    `f1b689715e2b5e71b42196a9c8941d5a8826a161dca6c6e8fc509979268df382`
  - upstream `.crx`:
    `28f6470df726adf2daa497af0802b02fd64f17ececd0259bc6672ae3b4f2a531`
  - Orbis-decoded full `.rnx`:
    `09f3f8fe46880c458964cc8a115999244587b947ff39a367245bbaa67a0df77a`
  - committed 120-epoch `.rnx`:
    `8ed476c011802032040beaf7a3fb774f06bb180a93f856eb7ae2396366496c45`
- **Header APPROX POSITION XYZ (ECEF m):** `3582105.2910  532589.7313  5232754.8054`.

## WTZR00DEU / WTZZ00DEU 2020 DOY177 120-epoch RTK pair

- **Stations / day:** WTZR00DEU and WTZZ00DEU (Wettzell, Germany), 2020
  day-of-year 177 (2020-06-25), 30 s sampling, MIXED observation.
- **Purpose:** real short-baseline RTK regression. The stations are co-located
  at Wettzell with a 1.6 m surveyed marker baseline, so receiver/satellite clock
  terms and short-baseline atmosphere should cancel in double differences. The
  fixture exercises GPS L1 C/A code + L1 carrier phase, cycle-slip splitting,
  elevation-weighted correlated DD covariance, and the LAMBDA refusal path on
  noisy real data.
- **Upstream source:** daily gzip-compressed CRINEX products staged locally from
  public BKG/EPN data products:
  - `WTZR00DEU_R_20201770000_01D_30S_MO.crx.gz`
  - `WTZZ00DEU_R_20201770000_01D_30S_MO.crx.gz`
- **Decode / trim:** decompressed the upstream `.crx.gz`, decoded each `.crx`
  with `Orbis.GNSS.RINEX.Observations.decode_crinex/1`, kept the verbatim header
  plus the first 120 epochs (00:00:00 through 00:59:30 GPST), and updated
  `TIME OF LAST OBS` to the last retained epoch. The committed fixtures are
  plain `.rnx`; they are not re-compressed because the RTK real-arc gate only
  needs the RINEX observation parser.
- **sha256:**
  - WTZR upstream `.crx.gz`:
    `4b89b3c69a001a5ed286d13299f09fcfb2af952cec6d9fb58cc6b972149a736c`
  - WTZZ upstream `.crx.gz`:
    `7bff7904f6faf1f3b03e11b2d3bc6f06e6027361a7d3a31715ee31233a1d46ea`
  - committed WTZR 120-epoch `.rnx`:
    `95d20f3a80c03284d06055ab67f8dbdc801057ba231df46d164c15884fa886a3`
  - committed WTZZ 120-epoch `.rnx`:
    `8ffeea547a2f588cdacae418610259f17af97cc18d2c1557251c48e36fcde736`
- **Truth coordinates:** EPN ITRF2020 SSC marker coordinates at epoch
  2020-01-01:
  - WTZR00DEU: `4075580.3111  931854.0543  4801568.2808`
  - WTZZ00DEU: `4075579.1913  931853.3696  4801569.1897`
- **Marker baseline WTZR -> WTZZ (ECEF m):**
  `-1.119800  -0.684700  +0.908900`, length `1.596517`.
- **Antenna-height deltas:** WTZR `0.0710 m`, WTZZ `0.2840 m`, from the RINEX
  `ANTENNA: DELTA H/E/N` header records. The real RTK gate compares the solved
  L1 carrier/code baseline to the antenna-reference-point baseline, i.e. marker
  coordinates plus the local-up height deltas.

## algo0010_2015001_v1_trim.crx / .rnx

- **Station / day:** ALGO (Algonquin Park, Canada), 2015 day-of-year 001
  (2015-01-01), 30 s sampling, MIXED (GPS+GLONASS), RINEX 2.11 / CRINEX 1.0.
- **Purpose:** exercises the CRINEX 1.0 (RINEX 2) decode path — the
  12-satellite epoch-line wrap (20 satellites in epoch 1) and the
  five-observations-per-line wrap (8 observation types).
- **Upstream source:** the full daily file
  `gnss/data/daily/2015/001/algo0010.15d.Z` from the historical ESA GSSC
  archive.
- **Trim:** decompressed, decoded, kept the verbatim header plus the first two
  epochs, then re-compressed with `rnx2crx` so the committed `.crx`
  re-initializes cleanly at epoch 1. The `.rnx` is the `crx2rnx` decode of the
  committed `.crx`.
- **Reference decoder:** RNXCMP `crx2rnx` / `rnx2crx` version 4.1.0 (the
  `hatanaka` Python package's bundled RNXCMP binaries).
- **sha256:**
  - `.crx`: `acc0d16347d28fb5911798f792046b1d32b8177a73b8b8fb4e521fa1fcf0af38`
  - `.rnx`: `f2eae58b37fa267b6f64549de8eb1504473057b46fba1d039b9d2f063b536f22`

The crate carries identical copies under
`crates/astrodynamics-gnss/tests/fixtures/obs/` for the crate's own
CRINEX round-trip and RINEX observation parser tests.

## PASA00ESP / SCOA00FRA 2026 DOY120 2-hour RTK pair

- **Stations / day:** PASA00ESP (Pasaia, Spain) and SCOA00FRA (Ciboure,
  France), 2026 day-of-year 120 (2026-04-30), 30 s sampling, RINEX 3.05 mixed
  GNSS observations.
- **Purpose:** C+D Phase 1 static RTKLIB oracle pair. The 21.836327792 km
  baseline is long enough to leave short-baseline comfort while staying inside
  the 15-40 km campaign gate.
- **Upstream source:** BKG EUREF daily CRINEX products:
  - `https://igs.bkg.bund.de/root_ftp/EUREF/obs/2026/120/PASA00ESP_R_20261200000_01D_30S_MO.crx.gz`
  - `https://igs.bkg.bund.de/root_ftp/EUREF/obs/2026/120/SCOA00FRA_R_20261200000_01D_30S_MO.crx.gz`
- **Decode / trim:** decoded with the Python `hatanaka` package, kept the
  verbatim header with `TIME OF FIRST OBS` / `TIME OF LAST OBS` updated, then
  retained epochs from 2026-04-30T10:00:00 through 11:59:30 GPST (240 epochs).
  The committed fixtures are plain `.rnx` files.
- **Raw sha256:**
  - PASA `.crx.gz`:
    `f749babda4d522609314ccb36a4725960f652bc8525f4c172a82eccd155ebc48`
  - SCOA `.crx.gz`:
    `ef01c8f42b966450a2f6d472ceb5a2b864585036543d3dba95393d1438b5f9ca`
- **Committed sha256:**
  - `PASA00ESP_R_20261201000_02H_30S_MO.rnx`:
    `3410f0ef73c7704353ae5efda0d86e30611a281a56acf77e5511ca4ff1486d2b`
  - `SCOA00FRA_R_20261201000_02H_30S_MO.rnx`:
    `684902dec4e06d3c0478c4fc421dc717dcb8d5426b33674e322b3ccef502f492`
- **Rebuild recipe:**
  `test/fixtures/rtk/generators/cd_phase1_pasa_scoa_2026_120.py`.

## ESBC00DNK_phase_shift_nonzero_trim.rnx (synthetic SYS / PHASE SHIFT regression)

- **Derived from:** `ESBC00DNK_R_20201770000_01D_30S_MO_trim.rnx` (byte-for-byte
  identical) with a single header edit: the `G L1C ... SYS / PHASE SHIFT` record
  was changed from a blank (0.0) correction to `0.25000` cycles. Every other
  `SYS / PHASE SHIFT` record stays 0.0.
- **Purpose:** regression fixture for `Observations.phases/3` applying the
  `SYS / PHASE SHIFT` `correction_cycles` to the carrier-phase `value_cycles`
  (and `value_m`). The all-zero parent verifies the correction is a no-op when
  no shift is present; this fixture verifies a non-zero shift is added.
- **Edit recipe:** copy the parent file and replace the `G L1C` phase-shift line
  with `G L1C  0.25000` padded to the RINEX label column.
