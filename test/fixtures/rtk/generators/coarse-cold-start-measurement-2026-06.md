# Coarse cold-start convergence-basin measurement (2026-06-14T01:17:41.182050Z)

Powered multi-epoch sweep of degraded position priors over the vendored
ESBC00DNK GPS-L1 120-epoch arc (30 s spacing). Truth = RINEX APPROX POSITION
XYZ `(3582105.291, 532589.731, 5232754.805)`.
Metric: per-epoch 3D ECEF error vs truth, metres, with `:coarse_search` on at
24 seeds, troposphere on.

Gate (pre-registered): per prior, convergence-basin pass rate
>= 0.95 where an epoch passes iff `{:ok}`, converged,
redundancy >= 1, and err_3d <= 5.0 m. Effective epochs
(>= 5 GPS sats): 120.

Substrate floor (the bare single solve from a good near-surface ~45 km seed,
the best unaided single-frequency SPP can do on this arc): pass rate
0.633, median 4.799 m,
p95 5.428 m. The 5.0 m tolerance sits at this
arc's accuracy floor, so the pre-registered 0.95 absolute bar cannot be met by
any seed, good or degraded; this is a reported NULL on the strict bar, not a
loosened tolerance. The substrate-relative column shows whether the coarse
cold start matches (or beats) the good-seed floor, which is the real
basin-widening claim: the degraded prior costs nothing versus a good seed.

| prior | n | coarse pass rate | coarse med 3D | coarse p95 3D | coarse max 3D | baseline pass rate | abs >=0.95 | >= floor |
|---|---|---|---|---|---|---|---|---|
| earth_center | 120 | 0.800 | 4.573 | 5.277 | 5.643 | 0.358 | FAIL | yes |
| antipodal | 120 | 0.800 | 4.573 | 5.277 | 5.643 | 0.000 | FAIL | yes |
| surface_100km | 120 | 0.758 | 4.652 | 5.302 | 5.590 | 0.658 | FAIL | yes |
| surface_1000km | 120 | 0.792 | 4.633 | 5.292 | 5.643 | 0.758 | FAIL | yes |
| surface_45km | 120 | 0.775 | 4.614 | 5.309 | 5.643 | 0.633 | FAIL | yes |

All distances in metres. "baseline pass rate" is the plain single-solve from
the same degraded prior (same pass predicate), quantifying the basin widening
versus no coarse search. "abs >=0.95" is the pre-registered absolute bar
(FAIL, substrate-limited). ">= floor" is whether coarse from this degraded
prior matches the good-seed substrate floor pass rate.

Invariant: `:coarse_search` nil byte-identical to the single solve (position
and rx_clock_s equal): true.

## Seed-count curve (earth_center prior, every 10th epoch)

| seeds | n | pass rate |
|---|---|---|
| 6 | 12 | 0.583 |
| 12 | 12 | 0.583 |
| 24 | 12 | 0.833 |
| 48 | 12 | 0.917 |

## Scorer evidence (defect-1 ratification)

On every 15th epoch (n=8), comparing the winning
candidate's err under the ratified most-satellites-first rule vs a pure
min-RMS rule, over the same converged+redundant candidate set from the
earth_center cold start:

- ratified (most-sats-first): median 4.854 m, p95 5.349 m
- pure min-RMS: median 6.196 m, p95 11.156 m

A non-positive verdict on any prior is reported as a fail; the 5.0 m tolerance
and 0.95 rate are not loosened.
