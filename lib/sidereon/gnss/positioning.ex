defmodule Sidereon.GNSS.Positioning do
  @moduledoc """
  GNSS single-point positioning (SPP): recover a receiver position, clock bias,
  and geometry diagnostics from one epoch of pseudorange observations against a
  precise SP3 ephemeris or a broadcast navigation product.

  This is the Elixir surface over the `astrodynamics-gnss` SPP solver. Given an
  ephemeris source, an `Sidereon.GNSS.SP3` product or an `Sidereon.GNSS.Broadcast`
  handle (GPS / Galileo / BeiDou / GLONASS), a set of single-frequency
  pseudoranges, the receive epoch, and the broadcast/atmosphere parameters, it
  runs the transmit-time iteration and trust-region least-squares solve in the
  crate and returns an `Sidereon.GNSS.Positioning.Solution`. A mixed-constellation
  set is solved together with one receiver clock per system. No positioning math
  lives on the Elixir side; this module marshals units and epoch arguments and
  decodes the result.

  ## Units at the boundary

    * pseudoranges and the initial guess position/clock are **meters**;
    * the recovered `position` is ITRF/IGS ECEF **meters**, matching the SP3 frame;
    * `geodetic` latitude/longitude are **radians** and height is **meters**;
    * `rx_clock_s` is **seconds**;
    * pressure is **hPa**, temperature is **kelvin**, relative humidity is a
      fraction in `[0, 1]`;
    * the Klobuchar `alpha`/`beta` coefficients are passed in their broadcast
      units.

  The epoch is interpreted in the SP3 product's own time scale (typically GPST);
  no leap-second shifting is applied. The seconds-since-J2000, second-of-day, and
  fractional day-of-year arguments the crate needs are derived from the supplied
  epoch via `Sidereon.GNSS.Time`.

  ## Example

      {:ok, sp3} = Sidereon.GNSS.SP3.load("igs.sp3")

      observations = [{"G01", 2.41e7}, {"G02", 2.49e7}, {"G05", 2.05e7}, {"G07", 2.30e7}]

      {:ok, solution} =
        Sidereon.GNSS.Positioning.solve(sp3, observations, ~N[2020-06-24 12:00:00],
          ionosphere: true,
          troposphere: true,
          klobuchar_alpha: {1.0e-8, 2.2e-8, -6.0e-8, -1.2e-7},
          klobuchar_beta: {96_256.0, 131_072.0, -65_536.0, -589_824.0}
        )

      solution.position.x_m
      solution.rx_clock_s
  """

  alias Sidereon.GNSS.Broadcast
  alias Sidereon.GNSS.Positioning.Decode
  alias Sidereon.GNSS.SP3
  alias Sidereon.GNSS.Staleness
  alias Sidereon.GNSS.Time
  alias Sidereon.NIF

  defmodule Solution do
    @moduledoc """
    A single-point-positioning solution at one receive epoch.

    `position` is the converged ITRF/IGS ECEF position in meters. `geodetic` is
    the same point as `%{lat_rad, lon_rad, height_m}` when geodetic output was
    requested (the default), otherwise `nil`. `rx_clock_s` is the reference-system
    receiver clock bias in seconds; `system_clocks_s` is a map of GNSS letter
    (e.g. `"G"`, `"E"`) to that system's **absolute** receiver clock in seconds (a
    single entry for a one-system solve, one per constellation for a mixed solve).
    These are per-system clocks, not biases: the inter-system bias of a system is
    its clock minus the reference system's (`rx_clock_s`). `dop` carries the
    dilution-of-precision scalars for any full-rank geometry; a single-system
    solve uses the bit-exact four-state cofactor, a multi-system solve a general
    inverse with one clock column per constellation, and is `nil` only when the
    geometry is rank-deficient. `residuals_m` are the post-fit
    pseudorange residuals in meters, in `used_sats` order. `used_sats` are the
    contributing satellite id strings (e.g. `"G01"`); `rejected_sats` pairs each
    excluded satellite id with its reason atom (`:no_ephemeris` or
    `:low_elevation`). `metadata` reports solver iterations, convergence, the
    corrections applied, and the geometry redundancy: `used_count`, the distinct
    `systems`, the `redundancy` (degrees of freedom, `used_count - (3 + systems)`),
    and `raim_checkable?` (`redundancy >= 1`). An exactly determined fix has
    `redundancy < 1`, forcing the residuals near zero and leaving the fix
    unverifiable by RAIM. When the opt-in `:huber` reweighting runs, `metadata`
    also carries `:huber` with the `outer_iterations` count and the
    `final_scale_m` (the last MAD robust scale in meters); the key is absent on
    the default static path.
    """
    @enforce_keys [
      :position,
      :geodetic,
      :rx_clock_s,
      :system_clocks_s,
      :dop,
      :residuals_m,
      :used_sats,
      :rejected_sats,
      :metadata
    ]
    defstruct [
      :position,
      :geodetic,
      :rx_clock_s,
      :system_clocks_s,
      :dop,
      :residuals_m,
      :used_sats,
      :rejected_sats,
      :metadata
    ]

    @type position :: %{x_m: float(), y_m: float(), z_m: float()}
    @type geodetic :: %{lat_rad: float(), lon_rad: float(), height_m: float()}
    @type dop :: %{
            gdop: float(),
            pdop: float(),
            hdop: float(),
            vdop: float(),
            tdop: float()
          }
    @type metadata :: %{
            :iterations => non_neg_integer(),
            :converged => boolean(),
            :status => atom(),
            :ionosphere_applied => boolean(),
            :troposphere_applied => boolean(),
            :used_count => non_neg_integer(),
            :systems => [String.t()],
            :redundancy => integer(),
            :raim_checkable? => boolean(),
            optional(:fde) => %{
              excluded: [{String.t(), :raim_excluded}],
              iterations: non_neg_integer()
            },
            optional(:huber) => %{
              outer_iterations: non_neg_integer(),
              final_scale_m: float()
            }
          }

    @type t :: %__MODULE__{
            position: position(),
            geodetic: geodetic() | nil,
            rx_clock_s: float(),
            system_clocks_s: %{String.t() => float()},
            dop: dop() | nil,
            residuals_m: [float()],
            used_sats: [String.t()],
            rejected_sats: [{String.t(), :no_ephemeris | :low_elevation}],
            metadata: metadata()
          }
  end

  defmodule SourcedSolution do
    @moduledoc """
    A single-point-positioning solution paired with the provenance of the
    ephemeris that produced it.

    Returned by `Sidereon.GNSS.Positioning.solve_with_fallback/5`. `solution` is
    the usual `Sidereon.GNSS.Positioning.Solution`; `source` records which source
    produced the fix and how it related to the requested epoch, so a degraded or
    substituted source is never reported silently:

      * `{:precise, %Sidereon.GNSS.Staleness.StalenessMetadata{}}` - a precise SP3
        product produced the fix. The metadata `kind` is `:exact` (zero staleness,
        the product covered the epoch) or `:nearest_prior` (a stale-but-within-cap
        product was used), with its source epoch and staleness.
      * `{:broadcast, {:precise_unavailable, selection_error}}` - the precise
        selection was declined outright (no precise products, none covering or
        preceding the epoch, or the nearest beyond the cap), so broadcast produced
        the fix. `selection_error` is the typed
        `Sidereon.GNSS.Staleness.selection_error/0` reason.
      * `{:broadcast, {:precise_degraded_unusable, staleness, spp_reason}}` - a
        stale-but-within-cap precise product was selected but could not serve the
        requested epoch (its coverage ends before it), so broadcast produced the
        fix. `staleness` is the tried product's
        `Sidereon.GNSS.Staleness.StalenessMetadata`, and `spp_reason` is the
        precise solve error that triggered the fallback.
    """

    @enforce_keys [:solution, :source]
    defstruct [:solution, :source]

    @type source ::
            {:precise, Sidereon.GNSS.Staleness.StalenessMetadata.t()}
            | {:broadcast, {:precise_unavailable, Sidereon.GNSS.Staleness.selection_error()}}
            | {:broadcast,
               {:precise_degraded_unusable, Sidereon.GNSS.Staleness.StalenessMetadata.t(), term()}}

    @type t :: %__MODULE__{
            solution: Sidereon.GNSS.Positioning.Solution.t(),
            source: source()
          }
  end

  @typedoc "A `{satellite_id, pseudorange_m}` pseudorange observation."
  @type observation :: {String.t(), number()}

  @typedoc "An epoch as a `NaiveDateTime` or `{{y, m, d}, {h, min, s}}` tuple."
  @type epoch :: NaiveDateTime.t() | tuple()

  @default_initial_guess {0.0, 0.0, 0.0, 0.0}
  # Default number of golden-spiral surface seeds when `:coarse_search` is on
  # without an explicit count. Pinned by the cold-start measurement: this many
  # seeds cover the sphere finely enough that at least one lands in the
  # convergence basin on the ESBC00DNK GPS-L1 arc, with margin under the bar.
  @default_coarse_seeds 24
  # Default crate-layer Huber/IRLS tuning, used when :huber is on and the caller
  # does not override. k = 1.345 is the textbook ~95%-efficiency Huber constant.
  @default_huber_k 1.345
  # MAD-scale floor in metres. Matches the value the GSDC measurement validated
  # (huber-irls-measurement-2026-06.md): a 5 m floor sets the down-weighting knee
  # at the metre-class noise of cheap single-frequency receivers. A 1 m floor
  # would start down-weighting around 1.3 m and neuter the robustness on phone
  # data, so the public default must be the validated 5 m.
  @default_huber_sigma 5.0
  @default_huber_max_iter 5
  # Upper bound on a caller-supplied :huber_max_iter. The value is the crate
  # outer-loop cap (a Rust usize); robust IRLS converges in a handful of outer
  # solves, so anything beyond this is a denial-of-service knob, not tuning.
  @huber_max_iter_cap 100
  # Upper bound on the :huber_k / :huber_sigma tuning values. k is dimensionless
  # and near 1; the scale floor is metres. A value this large is nonsensical, and
  # the cap also keeps a huge integer from raising on float coercion downstream.
  @huber_param_cap 1.0e6
  @default_alpha {0.0, 0.0, 0.0, 0.0}
  @default_beta {0.0, 0.0, 0.0, 0.0}
  # Standard-atmosphere surface meteorology, used when the troposphere term is
  # enabled and the caller does not override it.
  @default_pressure_hpa 1013.25
  @default_temperature_k 288.15
  @default_relative_humidity 0.5

  @doc """
  Solve single-point positioning for one receive epoch.

  `source` is a loaded ephemeris product, an `Sidereon.GNSS.SP3` precise product or an
  `Sidereon.GNSS.Broadcast` broadcast-navigation product. `observations` is a
  list of `{satellite_id, pseudorange_m}` pairs (ids like `"G01"`, pseudoranges
  in meters), and `epoch` is a `NaiveDateTime` or `{{y, m, d}, {h, min, s}}`
  tuple in the product's time scale.

  ## Options

    * `:ionosphere` - apply the broadcast Klobuchar ionosphere correction (default
      `false`); the L1 delay is scaled to each satellite's carrier by `(f_L1/f)^2`,
      covering GPS L1, Galileo E1, and BeiDou B1I. A GLONASS satellite's FDMA
      carrier is resolved per satellite from `:glonass_channels`; a GLONASS
      observation with the ionosphere requested but no (or out-of-range) channel
      is rejected with `{:ionosphere_unsupported, sat}`.
    * `:glonass_channels` - the GLONASS FDMA channel map `%{slot => channel}`
      (default `%{}`), where `slot` is the GLONASS satellite slot/PRN and
      `channel` is its FDMA frequency channel `k` (valid `[-7, +6]`), as carried
      in the broadcast nav `freq_channel` field or a RINEX `GLONASS SLOT / FRQ #`
      header. Used only to resolve the GLONASS carrier for the `(f_L1/f_k)^2`
      ionosphere scaling, so it matters only when `:ionosphere` is `true` and the
      set contains GLONASS observations; an empty map leaves every other
      constellation bit-identical. A value that is not a `%{integer => integer}`
      map returns `{:error, {:invalid_option, :glonass_channels}}`.
    * `:troposphere` - apply the Saastamoinen/Niell troposphere correction (default `false`)
    * `:klobuchar_alpha` - broadcast alpha coefficients, 4-tuple (default zeros)
    * `:klobuchar_beta` - broadcast beta coefficients, 4-tuple (default zeros)
    * `:pressure_hpa` - surface pressure, hPa (default `1013.25`)
    * `:temperature_k` - surface temperature, kelvin (default `288.15`)
    * `:relative_humidity` - relative humidity fraction `[0, 1]` (default `0.5`)
    * `:initial_guess` - `{x_m, y_m, z_m, b_m}` start point (default all zeros)
    * `:with_geodetic` - also return the geodetic position (default `true`)
    * `:max_pdop` - optional positive PDOP ceiling. When set, a fix whose
      geometry is rank-deficient or whose PDOP exceeds the ceiling is refused
      with `{:error, {:degenerate_geometry, pdop}}` (a non-positive value is
      `{:error, {:invalid_option, :max_pdop}}`); default unset.

  ### Robustness (opt-in, default off)

    * `:robust` - when `true` (default `false`), route the solve through the
      `Sidereon.GNSS.QC` leave-one-out fault-detection-and-exclusion (FDE) loop: a
      chi-square RAIM test on the post-fit residuals flags an inconsistent set,
      the satellite with the largest normalized residual is excluded, and the
      position is re-solved, repeating until the set is self-consistent or the
      geometry runs out of redundancy. A clean set excludes nothing; the cleaned
      re-solve still runs through every integrity gate above, so `:robust`
      composes with the rank, `:max_pdop`, plausibility, and convergence
      refusals. The returned `Solution` carries the FDE summary at
      `solution.metadata.fde` as `%{excluded: [{sat, :raim_excluded}],
      iterations: n}`. If the loop hits its iteration cap (or runs out of
      satellites) while RAIM still flags a fault, the set could not be made
      self-consistent and the solve returns
      `{:error, {:fault_unresolved, statistic}}` rather than a still-faulted fix.
    * `:weights` - RAIM detection weights for the `:robust` test, a
      `%{sat => inverse_variance_weight}` map (`1 / sigma_i^2`) as built by
      `Sidereon.GNSS.QC.weight_vector/2` from per-satellite elevation and/or C/N0.
      When given, it must carry a positive weight for every observed satellite;
      a partial map (missing an observed satellite) is rejected with
      `{:error, {:robust_requires_noise_model, :incomplete_weights}}`, and a
      non-positive, non-finite, or absurdly large observed weight with
      `{:error, {:invalid_option, :weights}}`, rather than silently falling back
      to unit weight or overflowing the detection statistic.
      A realistic noise model is REQUIRED for `:robust`: with unit weights the
      RAIM test reads ordinary code noise (several metres on a phone) as faults
      and over-excludes, degrading the fix. `:robust` therefore refuses to run
      without a noise basis: `:robust true` with no `:weights` and no
      `:unsafe_unit_weights` returns
      `{:error, {:robust_requires_noise_model, :no_weights}}` before any solve.
      Ignored when `:robust` is not set.
    * `:unsafe_unit_weights` - explicit escape hatch (default `false`). Set to
      `true` to run `:robust` FDE with unit weights (sigma = 1 m assumed), the
      only route to unit-weight FDE. Named to be self-documenting and grep-able
      because unit-weight FDE is the harmful mode on noisy real data; it is
      appropriate only when the measurements are genuinely sigma-1 clean (for
      example a synthetic oracle). Ignored when `:robust` is not set.
    * `:p_fa` - false-alarm probability for the `:robust` RAIM test (default
      `1.0e-3`); malformed values return `{:error, {:invalid_option, :p_fa}}`.
      Ignored when `:robust` is not set. See `Sidereon.GNSS.QC.raim/2`.
    * `:max_iterations` - maximum FDE exclusions before returning
      `{:error, {:fault_unresolved, statistic}}` (default `max(n_obs - 4, 0)`);
      malformed values return `{:error, {:invalid_option, :max_iterations}}`.
    * `:coarse_search` - cold-start convergence-basin widening for a degraded or
      absent position prior (default `nil` = off, exact single solve from
      `:initial_guess`). The crate freezes its elevation mask and weights at the
      seed geometry, so a seed far from the true surface point (the `{0,0,0,0}`
      earth-center default, an antipodal last-known fix) either starves on the
      horizon or is refused by the integrity gates. When set, the solve runs
      once from each of a deterministic golden-spiral lattice of near-surface
      seeds (plus the caller's `:initial_guess`), routes every per-seed candidate
      through the same integrity gates, and selects the best redundant
      (`redundancy >= 1`) converged fix, so no hardcoded prior is needed.
      Accepts `true` (the default seed count), a positive integer seed count, or
      a keyword list `[seeds: n]`. Each seed is one extra crate solve, so the
      cost scales with the seed count; leave it off on the hot path where a good
      prior is known. Composes with the integrity gates (including `:max_pdop`)
      per candidate, but is mutually exclusive with `:robust`: setting both
      returns `{:error, {:incompatible_options, [:coarse_search, :robust]}}`. A
      non-positive or non-integer value returns
      `{:error, {:invalid_option, :coarse_search}}`.
    * `:huber` - when `true` (default `false`), apply opt-in crate-layer
      Huber/IRLS robust reweighting: the per-satellite weight is recomputed each
      outer iteration from the post-fit residual (down-weighting large residuals)
      rather than the FDE all-or-nothing exclusion of `:robust`. On cheap
      single-frequency phone arcs this improves the fix (see
      huber-irls-measurement-2026-06.md). Mutually exclusive with `:robust`
      (`{:error, {:incompatible_options, [:robust, :huber]}}`). Tuning, used only
      when `:huber` is set: `:huber_k` (Huber constant, default `1.345`),
      `:huber_sigma` (MAD scale floor in metres, default `5.0`, sized to
      metre-class single-frequency noise), `:huber_max_iter` (outer-loop cap,
      default `5`). A malformed `:huber`/`:huber_k`/`:huber_sigma`/`:huber_max_iter`
      value returns `{:error, {:invalid_option, key}}` before any solve.

  Regardless of options, a fix that did not converge to a physical receiver
  position is refused rather than returned: one whose geocentric radius is
  outside the plausible band (for example from the earth-center default seed, or
  a wrong-root least-squares fix) gives `{:error, {:implausible_position, radius_m}}`,
  and a converged-flagged fix whose post-fit residual RMS is physically
  implausible gives `{:error, {:no_convergence, rms_m}}`.

  A mixed GPS+Galileo+BeiDou+GLONASS observation set is solved together with one
  receiver clock per GNSS (an inter-system bias is the difference between a
  system's clock and the reference system's), and dilution of precision is
  reported for the combined geometry as well.

  Returns `{:ok, %Sidereon.GNSS.Positioning.Solution{}}` or `{:error, reason}`,
  where `reason` is one of `{:too_few_satellites, used, required}` (`required` is
  `3 + n_systems`), `:singular_geometry`, `{:duplicate_observation, sat}`,
  `{:ephemeris_lost, sat}`, `{:ionosphere_unsupported, sat}` (the ionosphere
  correction was requested for a system with no modeled single-frequency
  carrier), `{:degenerate_geometry, reason}` (the geometry is rank-deficient, so
  `reason` is `:rank_deficient`, or exceeds the optional `:max_pdop` ceiling, so
  `reason` is the PDOP), `{:implausible_position, radius_m}` (the fix is outside
  the plausible geocentric-radius band), `{:no_convergence, rms_m}` (a
  converged-flagged fix with physically implausible post-fit residual RMS),
  `{:invalid_option, :max_pdop}`, `{:invalid_option, :robust}`,
  `{:invalid_option, :coarse_search}`,
  `{:incompatible_options, [:coarse_search, :robust]}`, or, for `:robust`,
  `{:robust_requires_noise_model, :no_weights}` / `{:robust_requires_noise_model, :incomplete_weights}`
  (robust was requested with no realistic noise model, or a weights map that does
  not cover every observed satellite with a positive weight, and no explicit
  unsafe opt-in), `{:invalid_option, :p_fa}`, `{:invalid_option, :weights}`,
  `{:invalid_option, :max_iterations}`, or `{:fault_unresolved, statistic}` (the
  FDE loop exhausted its iterations with a fault still flagged). For `:huber`:
  `{:incompatible_options, [:robust, :huber]}`, or
  `{:invalid_option, key}` for a malformed `:huber`, `:huber_k`, `:huber_sigma`,
  or `:huber_max_iter`.
  """
  @spec solve(SP3.t() | Broadcast.t(), [observation()], epoch(), keyword()) ::
          {:ok, Solution.t()} | {:error, term()}
  def solve(source, observations, epoch, opts \\ [])

  def solve(%SP3{handle: handle} = source, observations, epoch, opts)
      when is_list(observations) do
    dispatch(source, :sp3, handle, observations, epoch, opts)
  end

  def solve(%Broadcast{handle: handle} = source, observations, epoch, opts)
      when is_list(observations) do
    dispatch(source, :broadcast, handle, observations, epoch, opts)
  end

  @doc """
  Solve single-point positioning from broadcast ephemeris ALONE.

  The explicit, named broadcast-only entry point: the supported real-time /
  offline mode, where the satellite states come from a parsed broadcast
  navigation product (`Sidereon.GNSS.Broadcast`) rather than a precise SP3
  product. Broadcast ephemeris is decoded from the navigation message a receiver
  already tracks, so it needs no network.

  This is a thin wrapper over `solve/4` with a `Sidereon.GNSS.Broadcast` source,
  bit-for-bit identical to calling `solve/4` directly; it makes the
  broadcast-only contract explicit in the call site. `observations`, `epoch`, and
  `opts` are exactly as in `solve/4`. Returns
  `{:ok, %Sidereon.GNSS.Positioning.Solution{}}` or `{:error, reason}`.
  """
  @spec solve_broadcast(Broadcast.t(), [observation()], epoch(), keyword()) ::
          {:ok, Solution.t()} | {:error, term()}
  def solve_broadcast(%Broadcast{} = source, observations, epoch, opts \\ [])
      when is_list(observations) do
    solve(source, observations, epoch, opts)
  end

  @doc """
  Solve preferring precise SP3 products, falling back to broadcast ephemeris,
  reporting which source produced the fix and how stale it is.

  The precise path is tried first through the product-staleness selection layer
  (`Sidereon.GNSS.Staleness`) at the receive `epoch`:

    * if a precise product covers the epoch it is used, and the result's source is
      `{:precise, metadata}` with `:exact` (zero staleness) metadata. The solve is
      bit-for-bit identical to `solve/4` on that SP3, and a solve failure here is a
      genuine error returned as `{:error, {:precise, reason}}`, never masked by a
      silent broadcast re-solve;
    * if a stale-but-within-cap precise product is selected and produces a fix,
      the source is `{:precise, metadata}` with `:nearest_prior` (nonzero
      staleness) metadata;
    * if the selected stale product cannot serve the epoch, or the precise
      selection is declined outright, broadcast produces the fix and the source is
      `{:broadcast, reason}` recording why precise was not used.

  `precise` is a list of `Sidereon.GNSS.SP3` products (it may be empty, forcing
  broadcast); `broadcast` is a `Sidereon.GNSS.Broadcast` product.

  ## Options

    * `:policy` - a `Sidereon.GNSS.Staleness.Policy` bounding how stale a precise
      product may be before broadcast is preferred (default: a three-day cap). A
      zero-second cap forces broadcast whenever no product covers the exact epoch.

  The remaining options match `solve/4`: `:ionosphere`, `:troposphere`,
  `:klobuchar_alpha`, `:klobuchar_beta`, `:pressure_hpa`, `:temperature_k`,
  `:relative_humidity`, `:initial_guess`, `:with_geodetic`, and
  `:glonass_channels`. The opt-in robustness levers (`:robust`, `:huber`,
  `:coarse_search`, `:strategy`) are not part of the fallback entry, which uses
  the reference solve on both paths. The broadcast fallback solve applies the
  broadcast NAV header's BeiDou and Galileo ionosphere coefficients, exactly as
  `solve_broadcast/4`.

  Returns `{:ok, %Sidereon.GNSS.Positioning.SourcedSolution{}}` or
  `{:error, {:precise, reason}}` / `{:error, {:broadcast, reason}}` where `reason`
  is the SPP solve error from the path that failed.
  """
  @spec solve_with_fallback([SP3.t()], Broadcast.t(), [observation()], epoch(), keyword()) ::
          {:ok, SourcedSolution.t()} | {:error, term()}
  def solve_with_fallback(precise, %Broadcast{} = broadcast, observations, epoch, opts \\ [])
      when is_list(precise) and is_list(observations) do
    with {:ok, glonass_channels} <-
           validate_glonass_channels(Keyword.get(opts, :glonass_channels, %{})),
         {:ok, t_rx_j2000_s} <- Time.epoch_to_j2000_seconds_fractional(epoch) do
      policy = Keyword.get(opts, :policy, Staleness.Policy.default())

      args = [
        Enum.map(precise, & &1.handle),
        broadcast.handle,
        Enum.map(observations, fn {sat, pr} -> {sat, pr / 1.0} end),
        t_rx_j2000_s,
        Time.second_of_day(epoch),
        Time.day_of_year(epoch),
        to_tuple4(Keyword.get(opts, :initial_guess, @default_initial_guess)),
        Keyword.get(opts, :ionosphere, false),
        Keyword.get(opts, :troposphere, false),
        to_tuple4(Keyword.get(opts, :klobuchar_alpha, @default_alpha)),
        to_tuple4(Keyword.get(opts, :klobuchar_beta, @default_beta)),
        Keyword.get(opts, :pressure_hpa, @default_pressure_hpa) / 1.0,
        Keyword.get(opts, :temperature_k, @default_temperature_k) / 1.0,
        Keyword.get(opts, :relative_humidity, @default_relative_humidity) / 1.0,
        Keyword.get(opts, :with_geodetic, true),
        policy.max_staleness_s,
        glonass_channels
      ]

      NIF
      |> apply(:spp_solve_with_fallback, args)
      |> decode_sourced_solution()
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  # Decode the `{:ok, {solution_body, source}}` / `{:error, {path, reason}}` term
  # the fallback NIF returns. The solution body reuses the SPP decoder; the source
  # provenance reuses the staleness metadata / selection-error decoders so the
  # `{:precise, _}` and `{:broadcast, _}` shapes carry the same structs as the
  # standalone selection layer.
  defp decode_sourced_solution({:ok, {body, source}}) do
    case Decode.decode({:ok, body}) do
      {:ok, solution} ->
        {:ok, %SourcedSolution{solution: solution, source: decode_source(source)}}

      {:error, _} = error ->
        error
    end
  end

  defp decode_sourced_solution({:error, {path, reason}}) when path in [:precise, :broadcast],
    do: {:error, {path, reason}}

  defp decode_sourced_solution(other), do: {:error, other}

  defp decode_source({:precise, metadata}), do: {:precise, Staleness.decode_metadata(metadata)}

  defp decode_source({:broadcast, {:precise_unavailable, selection_error}}),
    do: {:broadcast, {:precise_unavailable, Staleness.decode_selection_error(selection_error)}}

  defp decode_source({:broadcast, {:precise_degraded_unusable, metadata, spp_reason}}),
    do:
      {:broadcast, {:precise_degraded_unusable, Staleness.decode_metadata(metadata), spp_reason}}

  # Opt-in robustness layer over the core solve. The direct SPP path, including
  # Huber reweighting, coarse cold-start search, and solution validation gates,
  # runs in the GNSS crate; the Elixir FDE path remains a wrapper because it
  # composes the public QC surface.
  defp dispatch(source, source_tag, handle, observations, epoch, opts) do
    robust? = Keyword.get(opts, :robust, false)
    huber? = Keyword.get(opts, :huber, false)
    coarse = coarse_search_count(Keyword.get(opts, :coarse_search))
    huber_opt_error = if huber? == true, do: invalid_huber_opt(opts)
    strategy = strategy_opt(opts)

    cond do
      not is_boolean(robust?) ->
        {:error, {:invalid_option, :robust}}

      not is_boolean(huber?) ->
        {:error, {:invalid_option, :huber}}

      coarse == :invalid ->
        {:error, {:invalid_option, :coarse_search}}

      strategy == :invalid ->
        {:error, {:invalid_option, :strategy}}

      huber_opt_error != nil ->
        huber_opt_error

      robust? and strategy == :canonical ->
        # The canonical strategy is a crate-layer op-order selection; the robust
        # FDE path is an Elixir-orchestrated multi-solve loop over the public QC
        # surface, which does not thread a strategy through. Composing them is
        # undefined, so the combination is refused rather than silently honoring
        # the reference path (mirrors the :robust/:huber exclusion).
        {:error, {:incompatible_options, [:robust, :strategy]}}

      robust? and huber? ->
        # The Elixir-layer FDE (:robust, whole-satellite exclusion) and the
        # crate-layer Huber/IRLS reweighting (:huber) are independent robustness
        # levers; composing them is undefined, so the combination is refused
        # rather than silently honoring one (mirrors the :coarse_search/:robust
        # exclusion).
        {:error, {:incompatible_options, [:robust, :huber]}}

      robust? and is_integer(coarse) ->
        # The robust FDE path and the per-seed coarse search are not composed;
        # rejecting the combination avoids silently honoring one.
        {:error, {:incompatible_options, [:coarse_search, :robust]}}

      robust? ->
        robust_solve(source, observations, epoch, opts)

      true ->
        run_solve(source_tag, handle, observations, epoch, opts, coarse)
    end
  end

  # Validate the crate-layer Huber/IRLS option values BEFORE the solve so a
  # malformed value returns a tagged error from solve/4 rather than raising in
  # the Elixir arithmetic or sending a nonsensical config into the NIF/crate.
  defp invalid_huber_opt(opts) do
    cond do
      not valid_pos_number(Keyword.get(opts, :huber_k, @default_huber_k)) ->
        {:error, {:invalid_option, :huber_k}}

      not valid_pos_number(Keyword.get(opts, :huber_sigma, @default_huber_sigma)) ->
        {:error, {:invalid_option, :huber_sigma}}

      not valid_pos_integer(Keyword.get(opts, :huber_max_iter, @default_huber_max_iter)) ->
        {:error, {:invalid_option, :huber_max_iter}}

      true ->
        nil
    end
  end

  # A strictly-positive number in the physically sane range for a Huber tuning
  # constant or a metre-scale floor. BEAM floats are always finite (overflow
  # raises rather than producing infinity or NaN), but BEAM integers are
  # arbitrary-precision and still satisfy is_number/1, so an enormous integer
  # would pass a bare `> 0.0` check and then raise on the `/ 1.0` float coercion
  # in huber_arg/1. The cap rejects it as a tagged error instead, honoring the
  # "never raises" contract; anything above it is nonsensical tuning regardless.
  defp valid_pos_number(v) when is_float(v), do: v > 0.0 and v <= @huber_param_cap
  defp valid_pos_number(v) when is_integer(v), do: v > 0 and v <= @huber_param_cap
  defp valid_pos_number(_), do: false
  # A positive integer capped at @huber_max_iter_cap: the value becomes the
  # crate outer-loop count (decoded to a Rust usize), so an unbounded value is a
  # denial-of-service knob, not a useful tuning.
  defp valid_pos_integer(v), do: is_integer(v) and v > 0 and v <= @huber_max_iter_cap

  # :robust routes through the QC leave-one-out FDE loop. A realistic noise model
  # is required: unit-weight FDE treats ordinary code noise as faults and
  # over-excludes, so it is refused unless the caller passes :weights or the
  # explicit :unsafe_unit_weights escape hatch. The cleaned re-solve flows
  # through the core solution validation gates. The FDE exclusion ledger is
  # folded into metadata.fde.
  defp robust_solve(source, observations, epoch, opts) do
    weights = Keyword.get(opts, :weights)
    unsafe? = Keyword.get(opts, :unsafe_unit_weights, false)

    # Validate the robust contract BEFORE any solve, so solve/4 returns a tagged
    # error rather than raising from deep in the FDE/RAIM path. A weights map is
    # a valid noise model only when it carries a positive weight for EVERY
    # observed satellite: an empty or partial map would otherwise fall back to
    # unit weight per satellite inside RAIM, the exact silent-degrade this
    # contract exists to prevent.
    with :ok <- validate_p_fa(Keyword.get(opts, :p_fa)),
         :ok <- validate_unsafe_unit_weights(unsafe?),
         {:ok, raim_weights} <- robust_weights(weights, unsafe?, observations) do
      run_fde(source, observations, epoch, opts, raim_weights)
    end
  end

  defp validate_p_fa(nil), do: :ok
  # Reject a probability so small that `1.0 - p_fa` rounds to exactly 1.0 in
  # f64, which the chi-square inverse rejects (it would raise after a solve).
  defp validate_p_fa(p) when is_number(p) and p > 0.0 and p < 1.0 and 1.0 - p < 1.0, do: :ok
  defp validate_p_fa(_), do: {:error, {:invalid_option, :p_fa}}

  defp validate_unsafe_unit_weights(v) when is_boolean(v), do: :ok
  defp validate_unsafe_unit_weights(_), do: {:error, {:invalid_option, :unsafe_unit_weights}}

  # robust_weights is the single validation point for the FDE weight map: it
  # filters to the observed satellites before RAIM, so RAIM never sees an
  # unvalidated weight and cannot raise out of solve/4. A weight is 1/sigma^2;
  # the upper bound caps sigma at ~1 micrometre (far below any real GNSS sigma)
  # and keeps RAIM's r^2 * weight term finite rather than overflowing.
  @max_robust_weight 1.0e12

  defp robust_weights(weights, _unsafe?, observations) when is_map(weights) do
    sats = Enum.map(observations, fn {sat, _pr} -> sat end)
    present = Enum.filter(sats, &Map.has_key?(weights, &1))

    cond do
      length(present) < length(sats) ->
        {:error, {:robust_requires_noise_model, :incomplete_weights}}

      not Enum.all?(present, fn sat -> valid_robust_weight?(Map.get(weights, sat)) end) ->
        {:error, {:invalid_option, :weights}}

      true ->
        {:ok, Map.take(weights, sats)}
    end
  end

  defp robust_weights(_weights, true, _observations), do: {:ok, :unit}

  defp robust_weights(_weights, false, _observations),
    do: {:error, {:robust_requires_noise_model, :no_weights}}

  defp valid_robust_weight?(w), do: is_number(w) and w > 0.0 and w <= @max_robust_weight

  defp run_fde(source, observations, epoch, opts, raim_weights) do
    # Drop the robust-only options and RAIM-only options that are not part of the
    # public solve/4 surface (:n_systems would otherwise reach RAIM arithmetic
    # unvalidated and raise); RAIM derives :n_systems from the used satellites.
    core_opts =
      Keyword.drop(opts, [
        :robust,
        :weights,
        :unsafe_unit_weights,
        :p_fa,
        :coarse_search,
        :n_systems
      ])

    fde_opts =
      core_opts
      |> Keyword.put(:weights, raim_weights)
      |> maybe_put(:p_fa, Keyword.get(opts, :p_fa))

    case Sidereon.GNSS.QC.fde(source, observations, epoch, fde_opts) do
      {:ok, %{solution: solution, excluded: excluded, iterations: iterations}} ->
        metadata = Map.put(solution.metadata, :fde, %{excluded: excluded, iterations: iterations})
        {:ok, %{solution | metadata: metadata}}

      {:error, _reason} = error ->
        error
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  # Normalize the :coarse_search option to a seed count, or nil when off.
  defp coarse_search_count(nil), do: nil
  defp coarse_search_count(false), do: nil
  defp coarse_search_count(true), do: @default_coarse_seeds
  defp coarse_search_count(n) when is_integer(n) and n >= 1, do: n

  defp coarse_search_count(opts) when is_list(opts) do
    # Only a proper keyword list is the [seeds: n] form; any other list (a
    # charlist, a positional list) is an invalid request, not a default.
    if Keyword.keyword?(opts) do
      coarse_search_count(Keyword.get(opts, :seeds, true))
    else
      :invalid
    end
  end

  # Any other value (0, negative, non-integer) is an invalid request, surfaced
  # as a tagged error by dispatch rather than crashing solve/4.
  defp coarse_search_count(_other), do: :invalid

  defp run_solve(source, handle, observations, epoch, opts, coarse_search_seeds) do
    with :ok <- validate_max_pdop(Keyword.get(opts, :max_pdop)),
         {:ok, glonass_channels} <-
           validate_glonass_channels(Keyword.get(opts, :glonass_channels, %{})),
         {:ok, t_rx_j2000_s} <- Time.epoch_to_j2000_seconds_fractional(epoch) do
      sod = Time.second_of_day(epoch)
      doy = Time.day_of_year(epoch)

      apply_iono = Keyword.get(opts, :ionosphere, false)
      apply_tropo = Keyword.get(opts, :troposphere, false)
      alpha = Keyword.get(opts, :klobuchar_alpha, @default_alpha)
      beta = Keyword.get(opts, :klobuchar_beta, @default_beta)
      pressure = Keyword.get(opts, :pressure_hpa, @default_pressure_hpa)
      temperature = Keyword.get(opts, :temperature_k, @default_temperature_k)
      humidity = Keyword.get(opts, :relative_humidity, @default_relative_humidity)
      initial_guess = Keyword.get(opts, :initial_guess, @default_initial_guess)
      with_geodetic = Keyword.get(opts, :with_geodetic, true)
      max_pdop = Keyword.get(opts, :max_pdop)

      obs = Enum.map(observations, fn {sat, pr} -> {sat, pr / 1.0} end)

      args = [
        handle,
        obs,
        t_rx_j2000_s,
        sod,
        doy,
        to_tuple4(initial_guess),
        apply_iono,
        apply_tropo,
        to_tuple4(alpha),
        to_tuple4(beta),
        pressure / 1.0,
        temperature / 1.0,
        humidity / 1.0,
        with_geodetic,
        huber_arg(opts),
        optional_float(max_pdop),
        optional_count(coarse_search_seeds),
        Keyword.get(opts, :strategy, :reference),
        glonass_channels
      ]

      result =
        case source do
          :sp3 -> apply(NIF, :spp_solve, args)
          :broadcast -> apply(NIF, :spp_solve_broadcast, args)
        end

      Decode.decode(result)
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  # The opt-in estimation-strategy selector. Absent or `:reference` is the
  # unchanged reference-faithful default; `:canonical` selects the canonical
  # (bounded-tolerance, truth-gated) strategy in the GNSS crate. Any other value
  # is surfaced as `{:invalid_option, :strategy}` by dispatch rather than reaching
  # the NIF.
  defp strategy_opt(opts) do
    case Keyword.get(opts, :strategy, :reference) do
      :reference -> :reference
      :canonical -> :canonical
      _ -> :invalid
    end
  end

  # The crate `robust` NIF argument: `nil` (off, byte-identical to the static
  # elevation-weighted solve) unless `:huber` is set, in which case a
  # `{huber_k, scale_floor_m, max_outer}` tuple drives the opt-in outer IRLS.
  defp huber_arg(opts) do
    if Keyword.get(opts, :huber, false) do
      {
        Keyword.get(opts, :huber_k, @default_huber_k) / 1.0,
        Keyword.get(opts, :huber_sigma, @default_huber_sigma) / 1.0,
        Keyword.get(opts, :huber_max_iter, @default_huber_max_iter)
      }
    end
  end

  defp optional_float(nil), do: nil
  defp optional_float(value), do: value / 1.0

  defp optional_count(nil), do: nil
  defp optional_count(value), do: value

  defp validate_max_pdop(nil), do: :ok
  defp validate_max_pdop(value) when is_number(value) and value > 0.0, do: :ok
  defp validate_max_pdop(_value), do: {:error, {:invalid_option, :max_pdop}}

  # The GLONASS FDMA channel map, `%{slot => channel}`. Slots are GLONASS PRNs
  # (`u8`) and channels are the FDMA `k` index decoded as `i8` at the NIF; only
  # the type/range that the NIF boundary can carry is enforced here. Whether a
  # channel is a *valid* GLONASS index ([-7, +6]) is the crate's concern — an
  # out-of-range channel for an observed GLONASS satellite with the ionosphere
  # requested surfaces as `{:ionosphere_unsupported, sat}`, not an option error.
  # Returned as a `[{slot, channel}]` list (the codebase idiom for map NIF args).
  defp validate_glonass_channels(channels) when is_map(channels) do
    if Enum.all?(channels, fn
         {slot, ch}
         when is_integer(slot) and slot >= 0 and slot <= 255 and is_integer(ch) and ch >= -128 and
                ch <= 127 ->
           true

         _ ->
           false
       end) do
      {:ok, Enum.sort(Map.to_list(channels))}
    else
      {:error, {:invalid_option, :glonass_channels}}
    end
  end

  defp validate_glonass_channels(_other), do: {:error, {:invalid_option, :glonass_channels}}

  # --- helpers -------------------------------------------------------------

  defp to_tuple4({_a, _b, _c, _d} = t), do: t

  defp to_tuple4([a, b, c, d]), do: {a / 1.0, b / 1.0, c / 1.0, d / 1.0}
end
