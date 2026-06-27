# Single-system SD gauge constraint: measurement, June 2026

Pre-registered in gauge-constraint-spec.md. The change extends the existing
per-system reference-SD gauge constraint (`apply_reference_sd_gauge` in the
Elixir reference, the matching block in the Rust kernel) from multi-system to
single-system by dropping the `map_size(refs) > 1` / `references.len() > 1`
guard. The gauge math is unchanged: each system's reference SD ambiguity is
pinned at its prior-center value with the hold weight, a DD-null-space
constraint that leaves the baseline and every double difference invariant.

## Result on the PASA/SCOA L1 arc (default hold 1.0e-4)

| Configuration | Continuous solve | Fixed n | Fixed median (m) | Final (m) |
|---|---|---:|---:|---:|
| no gauge, no arming (pre) | errors at epoch 124 (sub-arc resets) | 148 | 0.7736 | 0.2605 |
| gauge, no arming | solves 240/240 | 222 | 0.7351 | 0.6593 |
| gauge + arming (<= 0.05 m) | solves 240/240 | 104 | 0.0297 | 0.0234 |

The gauge removes the epoch-124 singularity: the bare default-hold continuous
arc now solves all 240 epochs in a single segment, with no soft-hold crutch
and no reset sub-arcs. Pairing it with the capability-1 arming gate reproduces
the soft-hold clean pass (sweep B of the AR commitment measurement) on the
default hold: 104 fixed at median 0.0297 m, final 0.0234 m, PASS under the
Amendment 1 invariant (floor 0.214 m, n >= 20), beating the RTKLIB oracle
final 0.052 m.

The gauge alone (no arming) does not fix correctness: it solves the arc but
still fixes the early wrong integers (222 at 0.7351 m, FAIL). Conditioning and
commitment discipline are the two separate capabilities the ledger named;
together they give the clean default-hold pass.

## Verdict

The epoch-124 singularity was a single-system instance of the same SD gauge
cancellation the multi-system gauge already handled; the multi-system-only
guard was the defect. With the guard dropped the continuous arc solves on the
default hold and the arming clean pass needs no soft-hold crutch.

## Promotion status

Complete and reference-first. The guard is dropped identically in the Elixir
reference and the Rust kernel; the change alters single-system numerics (the
gauge is now applied), so the previously "historical bit-identical"
single-system path is intentionally superseded. Gates: a default-hold
continuous === parity gate (both kernels solve 240/240 bit-equal) and the
arming === gate now on the default hold. Full battery 860 passed; sigma-sweep
gate green; no existing tolerance-gated truth test regressed. The Rust kernel
change ships in a later astrodynamics-gnss release; the orbis lane pins the
kernel rev until then.
