# RINEX clock fixture provenance

## `IGS0OPSFIN_2026120095930_02H01M_30S_CLK.CLK`

- **Source:** BKG IGS final products for GPS week 2416,
  `https://igs.bkg.bund.de/root_ftp/IGS/products/2416/IGS0OPSFIN_20261200000_01D_30S_CLK.CLK.gz`.
- **Product:** IGS final clock product for 2026 day-of-year 120, 30 s grid,
  aligned to the IGS time scale. Used by the C+D Phase 1 PASA/SCOA RTKLIB
  oracle with the matching final SP3 orbit product.
- **Raw sha256** (`.gz`, as fetched):
  `8483e969d69546ea2b6bbce7e6aaaece65ab6868b71a7a0398696b5b26ccdbe6`.
- **Trim:** decompressed the daily CLK, preserved the header, and retained
  `AS`/`AR` records from 09:59:30 through 12:00:30 GPST. The committed file has
  13436 clock records and covers the 10:00-12:00 observation arc with a 30 s
  margin at each side.
- **sha256** (committed `.CLK`, 1096426 bytes):
  `711d2791dfe2d20ecc21b99af9d37088aebf6d3382d25d1ecd540441e7ccc989`.
- **Rebuild recipe:**
  `test/fixtures/rtk/generators/cd_phase1_pasa_scoa_2026_120.py`.
