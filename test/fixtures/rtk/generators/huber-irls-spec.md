# huber-irls pre-registration spec

Pre-registered before measuring. Capability: an opt-in Huber/IRLS robust
reweighting loop inside the crate SPP solve, exposed as `:huber` on
`Orbis.GNSS.Positioning.solve/4`. Additive, default OFF: with `:huber` unset the
solve is byte-identical to the current static elevation-weighted solve.

This is the crate-layer reweighting lever, distinct from the existing
Elixir-layer `:robust` FDE (whole-satellite leave-one-out exclusion). The two are
mutually exclusive (`{:error, {:incompatible_options, [:robust, :huber]}}`).

## Hypothesis

On cheap single-frequency phone data (heavy broadband code noise plus
multipath), recomputing the per-satellite weight each outer iteration from the
current post-fit residual via the Huber psi-function progressively de-weights a
large multipath residual, rather than excluding whole satellites wholesale. The
question is whether that beats the current static elevation-weighted solve on the
vendored GSDC Pixel-5 arcs. A NULL (Huber does not beat bare) is a valid,
reportable outcome and is the expected risk: static elevation weighting is
already a decent proxy and the prior FDE attempt on these exact arcs improved
median but regressed p95 on 3/4 arcs (a weak null).

## Algorithm (frozen)

Per outer iteration, on the converged state of the previous solve:

  * unweighted post-fit residual `r_i = P_meas - P_hat` in `used_sats` order;
  * MAD scale `s = max(scale_floor_m, 1.4826 * median(|r_i - median(r)|))`,
    medians taken on a `total_cmp` sort (deterministic, NaN-safe);
  * Huber weight `w_i = 1` for `|r_i/s| <= k`, else `k / |r_i/s|`;
  * effective weight `a_i * w_i` where `a_i = sin^2(el)/sigma0^2` is the static
    elevation base weight, index-aligned to `used_sats`;
  * rebuild the weighted least-squares problem, warm-start at the previous state,
    re-solve;
  * stop when `||dx_pos||_2 < outer_tol_m` or `max_outer` total outer solves.

Iteration 0 is the static elevation-weighted warm start, bit-identical to the
current solve. `huber off` means `w_i == 1` identically, so the path is the
current single static solve.

## Declared parameters (measurement)

  * `k = 1.345` (textbook ~95%-efficiency Huber constant).
  * `scale_floor_m = 5.0` (the realistic phone L1 code sigma; the same
    several-metre code-noise figure the FDE measurement used as its detection
    sigma). This is the load-bearing scale source: it sets where Huber starts to
    engage on metre-class phone noise. Declared here so the golden and the GSDC
    harness cannot drift.
  * `max_outer = 5`.
  * `outer_tol_m = 1e-4`.

The reweighting MATH (the residual -> scale -> weight transform) is gated
separately and bit-exactly against a hand-rolled numpy outer-loop IRLS golden
(`crates/astrodynamics/tests/fixtures/huber_irls_trace.json`, scipy 1.17.1 /
numpy 2.4.6, NOT `scipy loss='huber'`); see `parity_huber_irls.rs`.

## Truth metric

Four vendored Pixel-5 demo5/RTKLIB oracles
(`gsdc_{2021_08_04_sjc1,2021_08_24_svl1,2021_12_15_mtv1,2021_12_28_mtv1}_pixel5_p222_demo5_rtklib_oracle.json`),
raw phone observations staged at `/tmp/gsdc-work/train/`. Per matched epoch, two
solves on IDENTICAL inputs and identical seed/troposphere settings:

  * A = bare (static elevation-weighted, `:huber` off);
  * B = Huber-on (`:huber true` with the declared `k` / `scale_floor_m`).

Epoch stride 1 (every matched epoch, ~1554/arc); no decimation. Every epoch's
outcome is tallied (both-ok, bare-only, huber-only, both-error); error stats are
over both-ok epochs and a Huber-only failure (bare ok, Huber error) is an
availability regression that fails the strict bar, never a silently dropped
epoch. Strict bar: powered (n >= 100), no availability regression, and Huber 3D
median <= bare AND Huber 3D p95 <= bare on every arc.

Report per arc and pooled: n (solved/matched), the outcome counts, 3D median, 3D
p95, horizontal median, horizontal p95 for bare vs Huber, plus delta, against the
demo5 absolute context.

## Strict bar (declared before measuring)

Huber non-regression on EVERY powered arc: Huber 3D median <= bare 3D median AND
Huber 3D p95 <= bare 3D p95, no slack. Classify per arc and pooled:

  * improved: median AND p95 non-regress;
  * median-only: median non-regress, p95 regressed (null on the strict bar);
  * null: Huber did not beat bare on median.

## Null handling

The null is the headline lesson from FDE. Report the null, do not massage, do
not loosen the bar, ship only the narrower data-supported claim. The default path
(`:huber` off) must produce byte-identical numbers to current orbis 0.25.0 on the
same arcs, re-proving additive-off on real data.
