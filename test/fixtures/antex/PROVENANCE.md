# ANTEX fixture provenance

## `igs20_pasa_scoa_gps.atx`

- **Source:** IGS station general ANTEX file,
  `https://files.igs.org/pub/station/general/igs20.atx`.
- **Raw sha256** (`igs20.atx`, as fetched):
  `70e963f66ca46c801a9fc8b37b0a0023c8e5213a724d7f26972ae81a80ce9699`.
- **Trim:** preserved the ANTEX header, retained all GPS satellite antenna
  blocks whose serial begins with `G`, and retained the two active receiver
  antenna blocks needed by the C+D Phase 1 PASA/SCOA RTKLIB oracle:
  `LEIAR20         LEIM` and `TRM55971.00     NONE`.
- **Content:** 118 antenna blocks: 116 GPS satellite blocks plus the two
  receiver antenna blocks.
- **sha256** (committed `.atx`, 796072 bytes):
  `e9b611472cee755f162245e9ba06351f43f4fbf1dee8108e07c4f834e0c17fbd`.
- **Use:** referenced by both `file-satantfile` and `file-rcvantfile` in
  `test/fixtures/rtk/generators/cd_pasa_scoa_l1_static_fixhold.conf` and
  `test/fixtures/rtk/generators/cd_pasa_scoa_l1l2_static.conf`.
- **Oracle fixture:** `test/fixtures/antex/antex_golden.json` was copied from
  `.../astrodynamics/crates/astrodynamics-gnss/tests/fixtures/antex/`
  and includes source-line references for each checked PCO/PCV sample.
- **Rebuild recipe:**
  `test/fixtures/rtk/generators/cd_phase1_pasa_scoa_2026_120.py`.

## `igs20_mmet_usal_gps.atx`

- **Source:** IGS station general ANTEX file,
  `https://files.igs.org/pub/station/general/igs20.atx`.
- **Raw sha256** (`igs20.atx`, as fetched):
  `70e963f66ca46c801a9fc8b37b0a0023c8e5213a724d7f26972ae81a80ce9699`.
- **Trim:** preserved the ANTEX header, retained all 116 GPS satellite antenna
  blocks (serial begins with `G`), and retained the two `LEIAR20` receiver
  antenna blocks used by the MMET/USAL dual-frequency static cases:
  `LEIAR20         NONE` and `LEIAR20         LEIM`.
- **Content:** 118 antenna blocks: 116 GPS satellite blocks plus the two
  receiver antenna blocks.
- **sha256** (committed `.atx`, 844700 bytes):
  `5f4d3efa7103e7087864a4f0b6162a7b49fce3e6c2ae477ff225cfee3f05b5bc`.
- **Use:** the receiver-ANTEX correction cases in
  `test/gnss_precise_positioning_test.exs` load `LEIAR20         NONE`.
