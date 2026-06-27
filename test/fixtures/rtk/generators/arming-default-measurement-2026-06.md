# Arming gate default-on decision: measurement, June 2026

Pre-registered in arming-default-spec.md before this run. Generator:
`arming_default_2026_06.exs` (committed). Per-arc JSON written to
`/tmp/arming-default-results.json`. Source commit at generation:
`9529a100f6ae3551d965e03c7fce7dbfa43d6bac`. All cells use
`filter_kernel: :elixir` (house rule: Elixir reference only). No solver
behavior changed; the only code change in this lane is doc plus a decision
test.

## Decision

DO NOT flip the `:ar_arming_sigma_m` default. A wavelength-tied default
regresses both clean arcs hard, so per the pre-registered rule (and the task's
own conditional) the gate stays opt-in (`nil` default = always armed). No
behavior change ships.

## What was measured

Candidate wavelength-tied defaults across the L1 band, against the always-armed
baseline (`none`). L1 wavelength `0.190293673 m`, so quarter wavelength
`0.047573 m` and half wavelength `0.095147 m`; `0.10 m` is the ar-commitment
sweep upper sanity point. Common options: mask 10 (Wettzell) / 15 (PASA/SCOA),
rtklib stochastic, code 0.3 / phase 0.003, candidate limit 200000, ratio 3.0,
initial baseline `{0,0,0}` (Wettzell) / RINEX-approx-minus-marker (PASA/SCOA).

### Wettzell static (clean, process noise off)

| threshold (m) | first fix | fixed n | fixed median (m) | final (m) |
|---|---:|---:|---:|---:|
| none (current) | 0 | 120/120 | 0.00276 | 0.00236 |
| 0.04757 (quarter wl) | 42 | 78/120 | 0.00221 | 0.00236 |
| 0.09515 (half wl) | 25 | 95/120 | 0.00238 | 0.00236 |
| 0.10 | 24 | 96/120 | 0.00238 | 0.00236 |

### Wettzell kinematic (clean, process noise 30.0)

| threshold (m) | first fix | fixed n | fixed median (m) | final (m) |
|---|---:|---:|---:|---:|
| none (current) | 0 | 120/120 | 0.00570 | 0.00622 |
| 0.04757 (quarter wl) | 73 | 47/120 | 0.00728 | 0.00731 |
| 0.09515 (half wl) | 54 | 66/120 | 0.00664 | 0.00994 |
| 0.10 | 52 | 68/120 | 0.00697 | 0.00758 |

### PASA/SCOA L1 (protection arc, Amendment 1 floor 0.214 m)

| threshold (m) | first fix | fixed n | fixed median (m) | final (m) | invariant |
|---|---:|---:|---:|---:|---|
| none (current) | 18 | 222/240 | 0.73517 | 0.65933 | FAIL-by-floor |
| 0.04757 (quarter wl) | 136 | 104/240 | 0.02975 | 0.02345 | PASS |
| 0.09515 (half wl) | 136 | 104/240 | 0.02975 | 0.02345 | PASS |
| 0.10 | 136 | 104/240 | 0.02975 | 0.02345 | PASS |

## Pre-registered decision rule, evaluated

- (a) Wettzell static needs first_fix in [0,1] AND fixed >= 118. Every
  candidate FAILS: first_fix 42/25/24, fixed 78/95/96. **FAIL.**
- (b) Wettzell kinematic needs first_fix == 0 AND fixed >= 114. Every
  candidate FAILS: first_fix 73/54/52, fixed 47/66/68. **FAIL.**
- (c) Synthetic clean arc still fixes with no option: holds (current default,
  asserted in gnss_rtk_test.exs). Under a quarter-wl default it suppresses /
  delays the fix, asserted in the new decision test. Confirms the hazard.
- (d) PASA/SCOA retains its Amendment 1 PASS with the candidate default:
  fixed n 104 >= 20 AND fixed median 0.02975 m <= 0.214 m. **PASS.**

Bars (a) and (b) fail outright under the candidate default, so the default is
NOT flipped. The Amendment 1 refusal invariant on PASA/SCOA is satisfied by the
gate when explicitly set (n=104 >= 20, median 0.0298 m <= 0.214 m floor), but
that is the existing opt-in behavior, not a default-flip justification.

## Why the clean arcs regress

The arming proxy is `sqrt(trace)` of the 3x3 baseline-block posterior
covariance (`ar_armed?/2`, rtk.ex). On clean good-geometry arcs the baseline is
truth-accurate from epoch 0 (final error is identical ~0.0024 m static /
~0.006 m kinematic across every row, armed or not), but the FORMAL posterior
covariance trace stays above the quarter-wl tie until ~epoch 42 static /
~epoch 73 kinematic. The gate keys on formal covariance convergence, not truth
accuracy, so a wavelength-tied default suppresses dozens of correct early fixes
on exactly the clean arcs where early fixing is the point. This is the precise
failure mode the task flagged. It is not a tuning problem: even the loosest
tested 0.10 m threshold (above any reasonable wavelength tie) still pushes
static first-fix 0 -> 24 and drops fixed 120 -> 96.

The gate is correct and valuable where it was designed for: the PASA/SCOA
poor-early-geometry arc, where the float is genuinely loose early (sigma above
0.10 m until epoch 136 then drops through the whole band in one epoch, so all
candidate thresholds give the identical clean solve). There it converts
confident-wrong (222 fixed @ 0.7352 m, FAIL-by-floor) to correct (104 fixed @
0.0298 m, PASS). The clean arcs are the opposite case (tight formal covariance
would be needed to fix early, but the truth is already good), so one global
default cannot serve both.

## Verdict

Null result, and the null is the answer: a wavelength-tied default is measured
to be unsafe as a global default and the gate remains opt-in. The shipped
artifact is a caller-facing doc note on `:ar_arming_sigma_m` recording the
measured opt-in-by-design reason, plus a decision-record assertion in the
existing synthetic arming test. No existing assertion is weakened.
