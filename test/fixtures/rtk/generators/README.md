# RTK oracle generators

Reproducible RTKLIB references for the RTK filter kernel parity gates. The
oracle JSONs in the parent directory are generated from the vendored RINEX
observations and broadcast nav by RTKLIB's `rnx2rtkp`, then converted to the
shared per-epoch JSON shape by `pos_to_oracle.py`.

## Provenance

- **Oracle binary:** RTKLIB `rnx2rtkp` **v2.4.2-p13**, commit `71db0ff`, built in
  this workspace at `_tools/RTKLIB/app/rnx2rtkp/gcc/rnx2rtkp`.
- **Inputs** (all vendored under `test/fixtures/`):
  - rover obs: `obs/WTZZ00DEU_R_20201770000_01D_30S_MO_120epoch.rnx`
  - base obs: `obs/WTZR00DEU_R_20201770000_01D_30S_MO_120epoch.rnx`
  - canonical/Track A nav: `nav/ESBC00DNK_R_20201770000_01D_MN.rnx`
    (mixed broadcast, filtered to GPS/Galileo/BeiDou)
  - Track B nav: `nav/BRDC00WRD_R_20201770000_01D_GREC.rnx`
    (BKG combined broadcast, filtered to GPS/GLONASS/Galileo/BeiDou)
- **Base reference position** (ARP): `49.144200524 12.878913935 666.0917`, the
  same fixed base used by the canonical `wtzr_wtzz_rtklib_oracle.json`.
- **Truth:** the static antenna baseline of the co-located WTZR/WTZZ pair
  (receivers do not move), copied verbatim into every oracle's `truth` block.

The first two configs below each change exactly **one** variable from the
canonical `l1_brdc_fix_and_hold` reference, so a parity failure isolates to that
variable. The GSDC rows are external moving-rover oracle recipes and keep their
solver settings pinned across arcs.

## Oracles

| JSON                                            | config                             | changed variable                                      | result                                                                      |
| ----------------------------------------------- | ---------------------------------- | ----------------------------------------------------- | --------------------------------------------------------------------------- |
| `wtzr_wtzz_kinematic_gps_rtklib_oracle.json`    | `track_a_kinematic_gps_l1.conf`    | `posmode` static→**kinematic** (GPS L1)               | 119/120 fixed, ~7mm converged; epoch-0 kinematic cold-start transient (~1m) |
| `wtzr_wtzz_multignss_static_rtklib_oracle.json` | `track_b_static_multignss_l1.conf` | `navsys` GPS→**GPS+GLO+GAL+BDS** (GLONASS float-only) | 120/120 fixed, ~1.8mm, 14–17 sats                                           |
| `gsdc_2021_08_24_svl1_pixel5_p222_demo5_rtklib_oracle.json` | `track_a_gsdc_p222_grec_l1.conf` | real GSDC moving rover, demo5, G/R/E/C L1, P222 base | 10/3136 fixed with AR ratio gate 3.0; median 3.98m 3D / 3.07m horizontal, p95 8.78m 3D |
| `gsdc_2021_08_04_sjc1_pixel5_p222_demo5_rtklib_oracle.json` | `track_a_gsdc_2021_08_04_sjc1_p222_grec_l1.conf` | pre-registered GSDC mixed/arterial Pixel5 arc, demo5, G/R/E/C L1, P222 base | 10/1554 fixed with AR ratio gate 3.0; median 4.52m 3D / 2.63m horizontal, p95 12.30m 3D |
| `gsdc_2021_12_15_mtv1_pixel5_p222_demo5_rtklib_oracle.json` | `track_a_gsdc_2021_12_15_mtv1_p222_grec_l1.conf` | pre-registered GSDC highway Pixel5 arc, demo5, G/R/E/C L1, P222 base | 1/1465 fixed with AR ratio gate 3.0; median 3.65m 3D / 2.82m horizontal, p95 7.91m 3D |
| `gsdc_2021_12_28_mtv1_pixel5_p222_demo5_rtklib_oracle.json` | `track_a_gsdc_2021_12_28_mtv1_p222_grec_l1.conf` | pre-registered GSDC repeat MTV1 Pixel5 arc, demo5, G/R/E/C L1, P222 base | 10/1610 fixed with AR ratio gate 3.0; median 3.97m 3D / 2.91m horizontal, p95 9.03m 3D |
| `pasa_scoa_2026_120_l1_static_fixhold_rtklib_oracle.json` | `cd_pasa_scoa_l1_static_fixhold.conf` | C+D Phase 1 EPN PASA00ESP/SCOA00FRA static 21.836 km baseline, GPS precise SP3/CLK, L1, fix-and-hold, ANTEX/tides | 171/240 fixed with AR ratio gate 3.0; mean 0.107 m / max 0.375 m truth error |
| `pasa_scoa_2026_120_l1l2_static_rtklib_oracle.json` | `cd_pasa_scoa_l1l2_static.conf` | C+D Phase 1 EPN PASA00ESP/SCOA00FRA static 21.836 km baseline, GPS precise SP3/CLK, L1/L2, continuous AR, ANTEX/tides | 80/240 fixed with AR ratio gate 3.0; mean 0.208 m / max 0.981 m truth error |

**GLONASS is float-only** (`pos2-gloarmode=off`): FDMA inter-channel biases break
the clean double-difference integer assumption, so GLONASS contributes to the
float solution but not to ambiguity resolution. FDMA AR is a non-goal until a
gate proves the win.

## Reproduce

```sh
RNX=../../../../../../_tools/RTKLIB/app/rnx2rtkp/gcc/rnx2rtkp
OBS=../../obs; NAV=../../nav/ESBC00DNK_R_20201770000_01D_MN.rnx
$RNX -k track_a_kinematic_gps_l1.conf -o track_a.pos \
  $OBS/WTZZ00DEU_R_20201770000_01D_30S_MO_120epoch.rnx \
  $OBS/WTZR00DEU_R_20201770000_01D_30S_MO_120epoch.rnx $NAV
python3 pos_to_oracle.py track_a.pos track_a_kinematic_gps_l1.conf \
  kinematic_gps_l1_fix_and_hold "..." ../wtzr_wtzz_kinematic_gps_rtklib_oracle.json

NAV=../../nav/BRDC00WRD_R_20201770000_01D_GREC.rnx
$RNX -k track_b_static_multignss_l1.conf -o track_b_static_multignss_l1.pos \
  $OBS/WTZZ00DEU_R_20201770000_01D_30S_MO_120epoch.rnx \
  $OBS/WTZR00DEU_R_20201770000_01D_30S_MO_120epoch.rnx $NAV
python3 pos_to_oracle.py track_b_static_multignss_l1.pos track_b_static_multignss_l1.conf \
  static_multignss_grec_l1_fix_and_hold "..." ../wtzr_wtzz_multignss_static_rtklib_oracle.json
```

Track B was regenerated with `rnx2rtkp -y 2` as a scratch audit while keeping
the committed JSON shape unchanged. The RTKLIB status trace reports 14-17 total
satellites over the 120 epochs, including 5-6 GLONASS satellites per epoch
(GPS 5-6, Galileo 3-5, BeiDou 0 on this RTKLIB 2.4.2 L1 arc).

## GSDC Track A moving rover

The GSDC oracle uses the RTKLIB Explorer **demo5** fork (`rnx2rtkp RTKLIB EX
2.5.0`, commit `57d39e7`) because vanilla RTKLIB 2.4.2 is weak on smartphone
carrier-phase logs. The raw GSDC competition files are not redistributable, so
only the generated JSON, config, generator, and provenance are committed.

Regenerate locally from the extracted drive and downloaded base/nav files:

```sh
RNX=/tmp/RTKLIB-demo5/app/consapp/rnx2rtkp/gcc/rnx2rtkp
WORK=/tmp/gsdc-work
DRIVE=$WORK/train/2021-08-24-US-SVL-1/GooglePixel5
NAV=$WORK/cors/BRDC00WRD_R_20212360000_01D_MN.rnx

$RNX -k track_a_gsdc_p222_grec_l1.conf \
  -ts 2021/08/24 20:33:00 -te 2021/08/24 21:25:20 \
  -o $WORK/track_a_gsdc_p222_grec_l1.pos \
  $DRIVE/supplemental/gnss_rinex.21o \
  $WORK/cors/p2222360.21o $NAV

python3 pos_to_oracle.py $WORK/track_a_gsdc_p222_grec_l1.pos \
  track_a_gsdc_p222_grec_l1.conf \
  gsdc_svl1_pixel5_p222_grec_l1_demo5 \
  "RTKLIB demo5 moving-rover oracle for GSDC 2022 train/2021-08-24-US-SVL-1/GooglePixel5 against NOAA CORS P222 (G/R/E/C L1, combined, fix-and-hold, AR ratio gate 3.0). Validated fixes on this phone arc are meter-class, not cm-class; the oracle is a calibrated trajectory accuracy reference, not a fix-rate target." \
  ../gsdc_2021_08_24_svl1_pixel5_p222_demo5_rtklib_oracle.json \
  --moving-truth-csv $DRIVE/ground_truth.csv \
  --truth-source train/2021-08-24-US-SVL-1/GooglePixel5/ground_truth.csv \
  --drive train/2021-08-24-US-SVL-1/GooglePixel5 \
  --rover-source train/2021-08-24-US-SVL-1/GooglePixel5/supplemental/gnss_rinex.21o \
  --base-source https://geodesy.noaa.gov/corsdata/rinex/2021/236/p222/p2222360.21d.gz \
  --nav-source https://igs.bkg.bund.de/root_ftp/IGS/BRDC/2021/236/BRDC00WRD_R_20212360000_01D_MN.rnx.gz \
  --base-station P222 \
  --base-ecef-m=-2689639.5060,-4290438.6360,3865050.9560 \
  --base-distance-km 18.936 \
  --rtklib-version "EX 2.5.0" --rtklib-commit 57d39e7
```

The three additional pre-registered arcs use the same command pattern and only
change the config, drive path, time window, day-of-year inputs, and 2 ms truth
matching tolerance for RTKLIB's rounded millisecond output:

| drive | config | RTKLIB time window | CORS/nav day | extra generator arg |
| --- | --- | --- | --- | --- |
| `train/2021-08-04-US-SJC-1/GooglePixel5` | `track_a_gsdc_2021_08_04_sjc1_p222_grec_l1.conf` | `2021/08/04 20:40:43` to `2021/08/04 21:06:40` | 216 | `--truth-time-tolerance-ms 2` |
| `train/2021-12-15-US-MTV-1/GooglePixel5` | `track_a_gsdc_2021_12_15_mtv1_p222_grec_l1.conf` | `2021/12/15 18:49:11` to `2021/12/15 19:13:40` | 349 | `--truth-time-tolerance-ms 2` |
| `train/2021-12-28-US-MTV-1/GooglePixel5` | `track_a_gsdc_2021_12_28_mtv1_p222_grec_l1.conf` | `2021/12/28 20:17:25` to `2021/12/28 20:44:20` | 362 | `--truth-time-tolerance-ms 2` |

The local byte-for-byte regeneration check is tagged `:local_data`, covers all
four GSDC fixtures, and is excluded by default.

## C+D Phase 1 EPN static baseline

The PASA/SCOA oracle uses vanilla RTKLIB **v2.4.2-p13** at commit `71db0ff`.
The raw public data download and trimming recipe is
`cd_phase1_pasa_scoa_2026_120.py`; it downloads the BKG EUREF observations, BKG
BRDC, BKG IGS final SP3/CLK, IGS20 ANTEX, EPN C2385 SSC, and EPN station logs,
then writes the committed 2 h observation arc and product margins.

```sh
PYTHONPATH=/tmp/cd-phase1-tools/py \
  python3 cd_phase1_pasa_scoa_2026_120.py \
  --work /tmp/cd-phase1-data/rebuild
```

Run the local byte-identical regeneration check with:

```sh
RTKLIB_RNX2RTKP=/tmp/cd-phase1-tools/RTKLIB/app/rnx2rtkp/gcc/rnx2rtkp \
  ORBIS_BUILD=1 mix test --include local_data test/gnss_rtk_rtklib_oracle_test.exs
```

The committed RTKLIB configs enable solid earth tides
(`pos1-tidecorr = on`), satellite antenna corrections (`pos1-posopt1 = on`),
receiver antenna corrections (`pos1-posopt2 = on`), and the trimmed ANTEX file
for both `file-satantfile` and `file-rcvantfile`. `pos1-navsys = 1` is
intentional because the public BKG IGS final SP3/CLK product for 2026 day 120 is
GPS-only, even though the observations and BRDC navigation are multi-GNSS.
