# Coarse cold-start convergence basin: pre-registered spec (v2)

Pre-registered before measuring. Capability: SPP convergence from a coarse,
degraded, or absent position prior, with no hardcoded seed. This is the rebuild
of the rejected `lane/ep-coarse-cold-start` (commit d703d9b), fixing the three
review defects called out below.

## Scope (house rules)

Elixir reference and measurement ONLY. The Rust SPP kernel, the NIF, and the
astrodynamics crate are out of scope and are not modified. The new
`:coarse_search` option is additive and defaults to `nil` (off), so the existing
single-solve path is byte-identical when the option is not passed.

## Question

A low-cost tracker often starts from only a rough position prior: region level,
last known hundreds of km away, antipodal, or none. The crate freezes its
elevation mask and weights at the seed geometry, so a single far-off seed can
starve on the horizon or be refused by the integrity gates. Widen the
convergence basin with an additive, default-off path that needs no hardcoded
answer, on top of the already-correct 0.24.0 refusal behavior.

The default-path false positive the original feature worked around (the
earth-center seed returning a converged ~6.36e6 m fix with zero iterations) is
ALREADY FIXED in 0.24.0 by `check_plausible_position` / `check_converged` in
`positioning.ex`. This capability is therefore purely about WIDENING the basin
(converging a degraded prior to a real fix), not masking a bad default. The
baseline control below shows the default path correctly refuses earth-center and
antipodal in the cases where the single seed does not converge.

## Three review defects, and the fix

DEFECT 1 (scorer did not match its own spec). The prior spec registered "keep
n_used >= 5, then minimum post-fit residual RMS, tie-break GDOP" but the code
ranked most-satellites-first then RMS/GDOP. RESOLUTION: this spec RATIFIES the
implemented rule (most-satellites-first, tie-broken by post-fit RMS then GDOP)
and registers it as the rule, with the ratification note below; the code and
spec now state the same rule. Ratification note: among redundant fits, dropping
a satellite lowers the post-fit residual RMS without lowering the true position
error (fewer equations are easier to fit), so a pure min-RMS scorer
systematically prefers a smaller, more biased subset. An `n_used >= 5` floor
does not cure this (it only excludes zero-DOF fits, not the general small-subset
bias). Ranking on satellites-used-first selects the fix that explains the most
observations. The measurement reports, on a sample of epochs, the error of the
pure-min-RMS pick alongside the ratified pick so the choice is evidenced, not
asserted.

DEFECT 2 (hard-coded min-5 redundancy gate). The prior code filtered on
`length(used_sats) >= 5`, which is wrong for mixed-constellation solves (two
systems estimate 5 states, so 5 sats is zero redundancy). RESOLUTION: the
eligibility filter is `metadata.converged and metadata.redundancy >= 1`, reading
the 0.24.0 `redundancy = used_count - (3 + distinct_systems)` that
`positioning.ex` `redundancy_meta/1` already populates on every candidate. No
new redundancy math, and correct for mixed constellations.

DEFECT 3 (n=1 measurement). The prior measurement was a single epoch.
RESOLUTION: the measurement is a powered multi-epoch sweep over the 120-epoch
ESBC arc (design below), reporting a convergence-basin pass rate per degraded
prior against a pre-registered bar.

No residual-RMS workaround is reintroduced. Every per-seed candidate is routed
through the same `run_solve`/`post_process` integrity gates the single path uses
(`check_rank`, `check_max_pdop`, `check_plausible_position`, `check_converged`),
so the never-iterated earth-center seed pass-through is dropped by the
plausibility gate before the scorer ever sees it. The prior code's
`@coarse_search_min_used` and `@coarse_search_max_residual_rms_m` are deleted.

## Oracle

ESBC00DNK (Esbjerg, Denmark) real IGS static station, 120 epochs at 30 s spacing
over ~59.5 min, GPS L1 C1C only.

- Observations: `test/fixtures/obs/ESBC00DNK_R_20201770000_01D_30S_MO_120epoch.rnx`
- Broadcast nav: `test/fixtures/nav/ESBC00DNK_R_20201770000_01D_MN.rnx` (01D
  coverage spans the arc)
- Truth: the RINEX header APPROX POSITION XYZ via
  `Sidereon.GNSS.RINEX.Observations.approx_position`, ECEF
  `(3582105.291, 532589.731, 5232754.805)`, the same truth the committed SPP
  test (`rinex_obs_spp_test.exs`) trusts. The station is static, so this single
  truth applies to every epoch.

The GSDC Pixel-5 demo5/RTKLIB JSON oracles are RTK carrier-phase rover
references; the convergence-basin claim needs only per-epoch truth plus
driveable single-frequency pseudoranges, which the ESBC arc supplies cleanly, so
the GSDC oracle is a noted future extension, not part of this gate.

## Metric

Per (degraded prior, epoch): 3D ECEF position error vs the APPROX POSITION
truth, in metres, with `:coarse_search` on at the pinned default seed count, with
troposphere on. An epoch is dropped (and counted) only if it has fewer than 5
usable GPS satellites. Effective n is reported.

## Degraded priors swept

No hardcoded answer in any seed.

- `earth_center` `{0,0,0,0}` (the module default)
- `antipodal` `{-tx,-ty,-tz,0}`
- `surface_100km` (tangential 100 km offset from truth)
- `surface_1000km` (tangential 1000 km offset from truth)

A near-surface small offset (`surface_45km`, the same offset the committed SPP
test uses) is reported as a control row.

## Pass bar (declared before measuring, never loosened)

Per degraded prior, over the effective epoch sample, convergence-basin PASS RATE
`>= 0.95`, where an epoch passes iff the coarse-search fix is `{:ok, sol}` with
`sol.metadata.converged` AND `sol.metadata.redundancy >= 1` AND `err_3d <= 5.0`
m. The 5.0 m tolerance (single-frequency broadcast SPP floor measured ~2 to 4 m
on this station, 5 m carries margin) and the 0.95 rate are fixed here before
running. If any swept degraded prior misses 0.95 at 5.0 m, that is a FAIL,
reported as such; neither the 5.0 m nor the 0.95 is loosened to manufacture a
pass.

## Controls reported alongside

- Baseline single-solve from each degraded prior at the same epochs (expected:
  earth_center and antipodal frequently refuse or land far; near-surface passes),
  quantifying the widening, not masking the already-fixed default.
- Invariant: `:coarse_search` nil is byte-identical to the plain single solve at
  a sample epoch (position and `rx_clock_s` equal).
- Seed-count curve: pass rate at N in {6, 12, 24, 48} on a subset, to pin the
  default seed count.
- Scorer evidence: on a sample of epochs, the err of the ratified
  (most-sats-first) pick vs the pure-min-RMS pick, to evidence the defect-1
  ratification note.

## Invariant (never weakened)

With `:coarse_search` unset, `solve/4` is byte-for-byte identical to the current
single solve. Proven by keeping every existing assertion in
`point_positioning_test.exs` and `rinex_obs_spp_test.exs` green and unchanged.
Out-of-tolerance or underpowered is a fail, not a pass.
