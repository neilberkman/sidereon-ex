# spp-robustness Gate 2/3 measurement (2026-06-14T02:16:02.272261Z)

Before/after single-frequency SPP on real GSDC Pixel-5 phone observations,
bare crate solve vs opt-in robust (FDE) solve, vs the demo5/RTKLIB
position-domain oracle. Truth is GSDC ground truth carried in the oracle.

Gate params: min epochs 100, credibility factor 2.0x demo5 median (absolute floor only), max_pdop 1.0e3, detection sigma 5.000 m. Epoch stride 1 (every 1th matched epoch; n per arc reported, kept above the 100-epoch floor).

| arc | n | bare med 3D | bare p95 3D | robust-unit med 3D | robust-unit p95 3D | robust-wtd med 3D | robust-wtd p95 3D | demo5 med 3D | wtd sats excl |
|---|---|---|---|---|---|---|---|---|---|
| gsdc_2021_08_04_sjc1_pixel5_p222_grec_l1_demo5 | 1453 | 10.213 | 37.535 | 13.054 | 64.905 | 9.680 | 42.778 | 4.522 | 1204 |
| gsdc_svl1_pixel5_p222_grec_l1_demo5 | 3136 | 9.241 | 26.877 | 10.596 | 39.410 | 8.837 | 24.673 | 3.977 | 1171 |
| gsdc_2021_12_15_mtv1_pixel5_p222_grec_l1_demo5 | 1465 | 8.062 | 29.437 | 9.327 | 37.561 | 7.729 | 28.366 | 3.653 | 367 |
| gsdc_2021_12_28_mtv1_pixel5_p222_grec_l1_demo5 | 1610 | 10.599 | 27.830 | 12.185 | 48.816 | 10.145 | 26.768 | 3.974 | 553 |

All values in metres. robust-unit is RAIM/FDE with unit weights (sigma=1 m
assumed), reachable ONLY via the explicit `:unsafe_unit_weights` opt-in;
robust-wtd is RAIM/FDE with a realistic uniform phone code sigma of
5.000 m via `:weights`.

Pooled: powered arcs 4/4; all powered arcs median non-regress (robust-wtd <= bare on median)? true; all powered arcs median AND p95 non-regress? false.

Reading: orbis runs an unaided single-frequency SPP per epoch; demo5 is a
tuned multi-GNSS RTK reference and is the absolute bar, not the comparand for
the robustness delta. The robustness claim is the bare-vs-robust delta on
identical orbis SPP inputs. The unit-weight FDE over-excludes on real phone
noise (it reads several-metre code noise as faults under a 1 m sigma
assumption) and degrades the fix: reported as the harmful mode, now reachable
only behind `:unsafe_unit_weights`. Default `:robust` without a noise model
refuses (`{:error, {:robust_requires_noise_model, :no_weights}}`), so it can
never silently degrade a fix. A non-positive delta is a null result, not
massaged. The strict all-arc bar (median AND p95 non-regress) being a null is
reported as a null.
