# huber-irls GSDC truth metric (2026-06-14T08:11:04.922316Z)

Before/after single-frequency SPP on real GSDC Pixel-5 phone observations,
bare static-elevation-weighted crate solve vs the opt-in crate-layer
Huber/IRLS solve (`:huber`), on IDENTICAL inputs, vs the demo5/RTKLIB
position-domain oracle. Truth is GSDC ground truth carried in the oracle. See
huber-irls-spec.md (pre-registered).

Gate params: min epochs 100, Huber k 1.345, MAD scale floor 5.000 m, max outer 5. Every matched epoch is measured (no decimation).

## Accuracy (both-ok epochs)

| arc | n | bare med 3D | bare p95 3D | huber med 3D | huber p95 3D | bare med H | huber med H | delta med 3D | demo5 med 3D (all oracle) | classification |
|---|---|---|---|---|---|---|---|---|---|---|
| gsdc_2021_08_04_sjc1_pixel5_p222_grec_l1_demo5 | 1453 | 10.213 | 37.535 | 9.796 | 34.988 | 4.894 | 4.641 | 0.417 | 4.522 | improved: Huber non-regression on median and p95, no availability loss |
| gsdc_svl1_pixel5_p222_grec_l1_demo5 | 3136 | 9.241 | 26.877 | 8.624 | 23.296 | 3.973 | 3.711 | 0.617 | 3.977 | improved: Huber non-regression on median and p95, no availability loss |
| gsdc_2021_12_15_mtv1_pixel5_p222_grec_l1_demo5 | 1465 | 8.062 | 29.437 | 7.378 | 26.734 | 3.623 | 3.297 | 0.685 | 3.653 | improved: Huber non-regression on median and p95, no availability loss |
| gsdc_2021_12_28_mtv1_pixel5_p222_grec_l1_demo5 | 1610 | 10.599 | 27.830 | 10.190 | 24.998 | 4.949 | 4.661 | 0.410 | 3.974 | improved: Huber non-regression on median and p95, no availability loss |

All values in metres. Delta is bare minus Huber (positive = Huber better).
The bare/Huber `n` and stats are over both-ok epochs only; the epoch
accounting below shows that no epoch was silently dropped to get there. The
demo5 column is the reference median over ALL of its oracle epochs (a coarse
absolute-context bar, not aligned to the both-ok subset).

## Epoch accounting (all matched epochs)

| arc | matched | both ok | huber-only fail | bare-only fail | both fail | too few sats |
|---|---|---|---|---|---|---|
| gsdc_2021_08_04_sjc1_pixel5_p222_grec_l1_demo5 | 1453 | 1453 | 0 | 0 | 0 | 0 |
| gsdc_svl1_pixel5_p222_grec_l1_demo5 | 3136 | 3136 | 0 | 0 | 0 | 0 |
| gsdc_2021_12_15_mtv1_pixel5_p222_grec_l1_demo5 | 1465 | 1465 | 0 | 0 | 0 | 0 |
| gsdc_2021_12_28_mtv1_pixel5_p222_grec_l1_demo5 | 1610 | 1610 | 0 | 0 | 0 | 0 |

A huber-only failure (bare solves, Huber errors) is an availability
regression and fails the strict bar outright; there are none here. "too few
sats" epochs are those where both arms return `{:too_few_satellites, _, _}`
(fewer L1 pseudoranges than the solver's 3 + n_systems floor).

Pooled: powered arcs 4/4; Huber-off byte-identical to bare on every powered arc? true; all powered arcs median non-regress (Huber <= bare on median)? true; all powered arcs median AND p95 non-regress? true.

Strict bar (pre-registered): Huber 3D median <= bare AND p95 <= bare on EVERY
powered arc, no slack. A non-positive delta is a null result, not massaged.
The default path (`:huber` off) producing byte-identical numbers re-proves
additive-off on real data.

Reading: each epoch's SPP (both arms) is seeded from the network base-station
marker ECEF carried in the oracle, a fixed coarse regional prior identical for
bare and Huber (not the per-epoch rover truth); the elevation weights freeze at
that seed geometry. demo5 is a tuned multi-GNSS RTK reference and is the
absolute context bar, not the comparand for the reweighting delta. The
capability claim is solely the bare-vs-Huber delta on identical sidereon SPP
inputs.
