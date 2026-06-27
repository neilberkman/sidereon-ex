# Track A moving-rover gate: pre-registered specification

Status: PRE-REGISTERED 2026-06-12, BEFORE any orbis run on these arcs.
Nothing here may be adjusted after measurement results exist, except by an
explicit Neil-signed amendment recorded in this file.

## Doctrine boundary (ratified)

- Ports gate BITWISE against the reference implementation we control
  (Elixir <-> Rust, === / to_bits). Capabilities gate on TRUTH METRICS against
  external oracles. These are different bars answering different questions;
  neither substitutes for the other. No tolerance-flavored gate may ever serve
  as port acceptance.
- Reference-first (Elixir reference, then kernel port, both gated) is the
  price of PROMOTING a capability into the gated path — not of exploring one.
  Measurement runs and prototypes are single-sided, wherever iteration is
  fastest; they ship nothing.

## Arc set (selection criteria fixed now; arcs enumerated before any solve)

From the GSDC 2022 corpus (local zip), FOUR drives, selected by criteria only
- no peeking at any solver output during selection:
  1. The vendored arc (2021-08-24-US-SVL-1 / GooglePixel5, suburban) - in.
  2. One highway drive, different day, Pixel-class device.
  3. One mixed/arterial drive, different day.
  4. One repeat-route drive sharing the route of (1) or (2), different day
     (tests day-to-day variance on matched geometry).
Each arc gets a demo5 oracle via the committed pipeline (arthres=3.0, P-class
CORS base nearest the route, full provenance) BEFORE orbis runs on it.

## Metrics (fixed now)

Per arc AND pooled across the four:
- 3D median error vs ground truth
- 3D p95 error vs ground truth
- Comparative bar: orbis median <= demo5 median x 1.25, and orbis p95 <=
  demo5 p95 x 1.25, per arc; pooled medians compared without margin
  (reported, not gated, on the first pass - the first pass is a MEASUREMENT,
  see below).

## The hard invariant (binary, non-negotiable, applies to every run forever)

Any epoch orbis reports as :fixed must come from a population whose error
distribution strictly beats the same run's float distribution (median AND
p95). A run that reports confident garbage FAILS regardless of any aggregate
metric. This is the gate's spine; the statistical margins are its flesh.

## Sequencing

1. Generate the three additional demo5 oracles (pipeline exists).
2. MEASUREMENT pass: current filter (as shipped in 0.18.0, :rust default),
   suitable static-free options, NO code changes - record the four-arc error
   distributions and a miss-classification ledger (multipath outlier vs
   dropout gap vs antenna/geometry, with magnitudes), the way the divergence
   ledger named every bit.
3. The ledger picks the capability list, with magnitudes attached. Each
   capability: explore single-sided -> promote reference-first if it earns it.
4. Only then does the comparative bar become a pass/fail gate.

## Track C linkage

PCO/PCV, solid tides, wind-up implementations stay DEFERRED until the step-2
ledger reports. They are mm-to-cm effects; if the measured gap is meters of
multipath (expected for phone-grade C/N0), they are below the problem's noise
floor and their natural moment is when a cm-grade claim is on the table.


## Amendment 1 (ratified by Neil, 2026-06-12)

A refusal-invariant verdict requires BOTH:
a. Minimum population: fixed n >= 20 in the evaluated scope (arc or pooled);
   below that the verdict is "underpowered", never pass or fail.
b. Absolute credibility floor: the fixed population's median 3D error must be
   <= 2x the demo5 oracle's median on the same arc; otherwise the verdict is
   FAIL regardless of the relative comparison. Confident garbage fails;
   "less catastrophic than float" is not a pass.
Verdicts in pre-amendment reports are reinterpreted accordingly: the 2026-06
multi-epoch invariant verdicts become FAIL-by-floor; the single-epoch
comparison row stands.
