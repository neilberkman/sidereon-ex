# Endpoint positioning hardening, June 2026

Single-frequency SPP default-path correctness, plus a Doppler-velocity gate.
Reference-first, Elixir only, gated against vendored public data. This records
the shipped subset; the FDE-in-solve (`:robust`) and coarse-search
(`:coarse_search`) work from the same effort was held for a rebuild after a
hostile review found blocking issues (exhausted-but-faulted FDE returning ok,
unit-weight FDE degrading real fixes, a scorer that deviated from its spec, a
mixed-constellation redundancy error, and an n=1 basin measurement).

## Default-path convergence sanity gate (bug fix, behavior change)

The `solve/4` default seed is the earth center `{0,0,0,0}`. With ionosphere and
troposphere enabled, the kernel step-tolerance test can fire at iteration 0 and
flag a position roughly 6.36e6 m from truth as converged. Calibration on the
ESBC00DNK arc: a real fix has post-fit residual RMS 1.5 m (good seed) to 17.75 m
(earth-center seed that does converge on this 12-sat epoch); the garbage case
has RMS about 4.1e6 m. A sanity bound of 1.0e4 m cleanly separates them with no
false rejection of a real fix. A fix outside the plausible
geocentric-radius band (the earth-center seed lands near radius zero, and a
wrong-root fix with zero residuals from an exactly determined geometry lands far
out) is refused with `{:error, {:implausible_position, radius_m}}`, and a
converged-flagged fix above the residual-RMS bound with
`{:error, {:no_convergence, rms_m}}`. The plausibility gate runs before the
residual gate so it also catches the zero-residual wrong-root case the residual
gate is blind to.

## Redundancy surfaced

`solve/4` metadata now carries `used_count`, `systems`, `redundancy`
(`used_count - (3 + systems)`), and `raim_checkable?`. A 5-satellite,
two-system fix has `redundancy = 0` and `raim_checkable? = false`: the residuals
are forced to zero and the fix is not RAIM-testable, which the metadata now
makes visible instead of presenting a zero-residual fix as ideal.

## `:max_pdop` geometry gate

Opt-in. A rank-deficient or above-ceiling geometry is refused with
`{:error, {:degenerate_geometry, pdop}}`; a non-positive ceiling is
`{:error, {:invalid_option, :max_pdop}}`. Default unset preserves prior behavior.

## Doppler-velocity regression gate

`Sidereon.GNSS.Velocity.solve(observable: :doppler)` on a real cheap-receiver arc
(GSDC Pixel-5, 2021-12-15 MTV-1, GPS L1 D1C): median 3D velocity error
0.2498 m/s, p95 1.5161 m/s, n=1465 vs a finite-difference of the carrier-phase
truth track. The bars (median <= 0.50, p95 <= 2.50, n >= 1000) are a fixed
regression gate set above the observed values, scoped to this one arc, not a
multi-arc accuracy claim and not an independent Doppler oracle.
