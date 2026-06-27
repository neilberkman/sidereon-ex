# SP3 test-fixture provenance

## `GRG0MGXFIN_20201760000_01D_15M_ORB.SP3`

IGS MGEX final combined precise orbit + clock product (CNES/CLS/GRGS), 2020
day-of-year 176, 15-minute grid, GPS time, carrying GPS / GLONASS / Galileo (no
BeiDou). Redistributed public IGS product. Used by the SP3 interpolation and
reduced-orbit tests.

## `GBM_BDS_C21_C08_trim.sp3`

Derived from the GFZ rapid MGEX product
`GBM0MGXRAP_20201770000_01D_05M_ORB.SP3` (2020 day-of-year 177, 5-minute grid,
GPS time) by keeping the verbatim header and only the position records for two
BeiDou satellites — **C21** (MEO, e ≈ 9e-4) and **C08** (IGSO, e ≈ 5e-3) — across
all 288 epochs. Other satellites' records were dropped (the header still lists
the full constellation, which the SP3 reader tolerates); no values were altered.

- size 72293 bytes, sha256
  `f77d83a0da91e7112c2890ba7aae29326b8c621cfee58ac18e4243d86e40238b`.
- Source product: GFZ Potsdam MGEX products for GPS week 2111.
- Purpose: the real BeiDou drift gate for `Orbis.GNSS.ReducedOrbit`'s
  `:eccentric_secular` model (the GRG product carries no BeiDou). GEO satellites
  (C01–C05) are excluded — near-equatorial and not orbital-element-friendly. An
  identical copy lives in the `astrodynamics-gnss` crate fixtures for the same
  gate at the Rust layer.

## `GBM0MGXRAP_20201770000_01D_05M_ORB_120epoch.sp3`

GFZ rapid MGEX precise orbit + clock product, 2020 day-of-year 177
(2020-06-25), 5-minute grid, GPS time. This is the SP3 companion to
`ESBC00DNK_R_20201770000_01D_30S_MO_120epoch.rnx` for the offline real
multi-epoch precise-positioning / troposphere regression.

- **Upstream source:** `GBM0MGXRAP_20201770000_01D_05M_ORB.SP3.gz` from the GFZ
  MGEX rapid products for GPS week 2111.
- **Trim:** decompressed the full SP3, kept the verbatim header plus the first 24
  epochs (00:00 through 01:55 GPST), updated the SP3 epoch count on the first
  line to `24`, and appended `EOF`. The retained window covers the first
  120 observation epochs at 30 s cadence with interpolation margin.
- **sha256:**
  - upstream `.SP3.gz`:
    `51971877df4b4bb6c43bb13ff5c850752100d38048526d6bf39ecd98b54aaf27`
  - upstream decompressed `.SP3`:
    `1922019f82ec071c7ca8813aeda4c6398322b986dee14414d629a5cac97fd10b`
  - committed 120-epoch `.sp3`:
    `769e61ab9153cac0c9103df1b1721cda8a8e04457188b862a5f63c431ca3cba2`

## `degenerate_coincident_5sat.sp3`

Hand-authored rank-deficient fixture (five GPS satellites at one ECEF point) for
the graceful-degeneracy path; not a redistributed product.

## `COD0MGXFIN_20201770000_01D_05M_ORB.SP3`

- **Upstream source:** `COD0MGXFIN_20201770000_01D_05M_ORB.SP3.gz`, the CODE MGEX
  final precise orbit/clock product for 2020 day-of-year 177 (GPS week 2111),
  fetched via `Orbis.GNSS.Data` from the ESA GSSC archive.
- **Trim:** none — the verbatim full-day product (289 epochs, 00:00 through the
  following day 00:00 GPST at 5-minute cadence), GPS+GLONASS+Galileo+BeiDou.
- **Use:** the precise reference for the full-day broadcast-vs-precise accuracy
  check in `gnss_ephemeris_test.exs`.
- **sha256 (committed `.SP3`):**
  `54b70fa009a840ecf8cec25fbd4d749c9aaef7c95bdf463484e115f74d802215`

## `IGS0OPSFIN_20261200945_02H30M_15M_ORB.SP3`

- **Source:** BKG IGS final products for GPS week 2416,
  `https://igs.bkg.bund.de/root_ftp/IGS/products/2416/IGS0OPSFIN_20261200000_01D_15M_ORB.SP3.gz`.
- **Product:** IGS final GPS precise orbit product for 2026 day-of-year 120,
  15-minute grid, GPS time. Used by the C+D Phase 1 PASA/SCOA RTKLIB oracle.
- **Raw sha256** (`.gz`, as fetched):
  `c06164f34b3e8fbbebe63d0619475c32fce4ce42e40254a9dbc531afb922a802`.
- **Trim:** decompressed the daily SP3, preserved the header, retained epochs
  from 09:45:00 through 12:15:00 GPST (11 SP3 epochs), then appended `EOF`.
  This gives the 10:00-12:00 observation arc one 15-minute interpolation margin
  at each side.
- **sha256** (committed `.SP3`, 29319 bytes):
  `8d3896583b8d2662d3012485c5c92f52a72124ccf199eb24760464411f968d6b`.
- **Rebuild recipe:**
  `test/fixtures/rtk/generators/cd_phase1_pasa_scoa_2026_120.py`.
