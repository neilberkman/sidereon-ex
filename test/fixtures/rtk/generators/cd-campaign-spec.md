# Tracks C+D campaign: measured centimeters beyond co-located baselines

Status: PRE-REGISTERED 2026-06-13, before any solver runs on campaign data.
Amendments require explicit Neil ratification recorded here.

## Goal claim (what "conquered" means)

RTK baselines at 10-50 km on geodetic EPN data, gated against RTKLIB on the
same arcs, with the station-physics terms (antenna PCO/PCV, solid earth
tides, carrier wind-up where applicable) implemented faithfully, i.e. each
term gated against its vendored reference values (igs20 ANTEX goldens, IERS
DEHANTTIDEINEL cases, already in the astrodynamics repo) before it may
influence any baseline result.

## Method (inherited, binding)

Oracle-before-code; instrument-the-gap before implementing; capabilities
promote reference-first (Elixir then kernel, ===-gated); truth-metric gates
for capability acceptance, bitwise gates for ports; no tolerance gate ever
closes a port. Per-epoch refusal invariant per rover-gate-spec Amendment 1
(min n=20 + credibility floor at 2x the oracle median) applies to every
fixed-population claim in this campaign.

## Phase 1: data + oracles (selection criteria fixed now)

ONE EPN station pair, selected by criteria only: baseline length 15-40 km;
both stations on an open archive (BKG EPN) with 30s multi-GNSS RINEX3, known
ITRF coordinates and ANTEX-listed antenna types (calibrations present in the
vendored igs20 trim or trim extended); a 2-hour arc on a day with IGS final
products available. Vendor: trimmed obs/nav/SP3(+CLK) with provenance and
committed generators; RTKLIB oracle runs in the canonical single-variable
pattern: (a) L1 static fix-and-hold, (b) dual-frequency static, both
arthres=3.0. Record RTKLIB's solution WITH its own antenna/tide handling ON
(rtklib applies ANTEX + tides when configured: document the exact conf).

## Phase 2: measurement pass (no solver changes)

Current shipped filter on the pair, dual-kernel default options, L1 and
dual-freq cells. Expected: a real gap attributable to the missing C terms
(PCO/PCV deltas between station antenna types, tide displacement over the
arc) + possibly iono at this length. THE LEDGER decomposes the error budget
term-by-term: compute each missing term's predicted magnitude on this arc
from the vendored models/goldens and compare against the observed gap.
No capability implementation before this ledger exists.

## Phase 3: capabilities, ledger-ordered

Anticipated (the ledger may reorder or strike): C-PCO/PCV application in the
measurement model; C-solid-tides station displacement; D-iono handling
(weighted DD or estimated states) if the ledger shows it at this length;
ZTD-in-filter. Each: gated against its physics reference values FIRST
(bitwise vs vendored goldens), then promoted reference-first with the EPN
gate as the truth metric: final criterion = sidereon matches RTKLIB's fixed
solution on the pair within 1.25x of RTKLIB's own truth error, with the
refusal invariant clean.

## Non-goals for this campaign

Ocean loading, pole tide (later, with their own references); GLONASS AR;
kinematic (Track A's world); PPP (Track E, builds on this).
