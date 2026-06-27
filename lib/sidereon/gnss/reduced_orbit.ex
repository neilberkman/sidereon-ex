defmodule Sidereon.GNSS.ReducedOrbit do
  @moduledoc """
  A compact, fitted mean-element approximation of a satellite's orbit.

  `Sidereon.GNSS.ReducedOrbit` distills a position track, from a precise SP3 product,
  a TLE/SGP4 orbit, or a list of ECEF samples, into a handful of mean elements
  that reproduce the motion cheaply, for caching, transport, and quick visibility
  math. It is **not** orbit determination and **not** a substitute for SGP4 or
  precise ephemeris: it deliberately discards short-period structure and is
  reports the error it leaves behind (`rms_m`/`max_m` on the fit, and a
  source-backed `drift/3`).

  ## Models

  Two models are available, chosen with the `:model` option on `fit/2`:

    * `:circular_secular` (the **default**) - a circular orbit intended for
      near-circular orbits (Galileo).
    * `:eccentric_secular` - adds eccentricity through a nonsingular `(h, k)`
      parameterization, recovering the radial `a·e` signal (~hundreds of km for
      GPS/BeiDou) while degrading smoothly to the circular model as `e -> 0`.

  ### `circular_secular`

  A circular orbit (eccentricity fixed at zero) whose orbital plane precesses at
  a constant nodal rate. At an offset `dt = t - t0` from the reference epoch the
  angles advance linearly,

      u(t)    = arg_lat0 + n * dt          # argument of latitude
      raan(t) = raan0    + raan_rate * dt
      e       = 0

  and the inertial (GCRS) position is the in-plane circle rotated by the node and
  inclination, `r = Rz(raan) * Rx(i) * a * [cos u, sin u, 0]`.

  The nodal rate `raan_rate` is **fitted**, but seeded from the J2 secular nodal
  regression (Vallado, *Fundamentals of Astrodynamics and Applications*):

      raan_rate_j2 = -1.5 * n * J2 * (Re / a)^2 * cos(i)

  Both the fitted value (`raan_rate_rad_s`) and the J2 seed (`raan_rate_j2_rad_s`)
  are kept; `raan_rate_mode` is `"fitted_j2_seeded"`. The model does not claim to
  be a pure J2 propagation.

  ### `eccentric_secular`

  Eight free elements: the four circular plane elements plus `h = e·sin ω`,
  `k = e·cos ω`, `L0` (mean argument of latitude at epoch), and `n`. Derived
  `e = sqrt(h² + k²)` and `ω = atan2(h, k)`. At an offset `dt` the model advances
  `λ = L0 + n·dt`, forms the mean anomaly `M = λ − ω`, solves Kepler's equation
  `E − e·sin E = M`, and places the satellite at radius `r = a(1 − e·cos E)` and
  argument of latitude `u = ω + ν`. The `(h, k)` form is nonsingular: at `e = 0`
  it reproduces `circular_secular` exactly with `arg_lat0 = L0`. The struct then
  carries `h`, `k`, `e`, and `arg_perigee_rad` (= ω).

  ## Frames

  Fitting and evaluation run internally in **GCRS**; positions are returned in
  **ECEF (ITRF) meters by default**, or GCRS via `frame: :gcrs`. ECEF velocity
  includes the Earth-rotation transport term. Sample/query epochs are interpreted
  consistently for the Earth-rotation conversion; the ECEF product (the primary
  output) is self-consistent across the fit, evaluation, and drift.

  ## Expected accuracy

  Representative drift (extrapolated model residual against the source): a fit to the
  first ~6 hours of an MGEX SP3 track, drifted over the rest of the day. Numbers
  are the **max** position error over the full day, measured against vendored MGEX
  products (GRG for GPS/Galileo, a trimmed GBM product for BeiDou) and an ISS
  TLE sampled through SGP4:

  | Orbit class                   | `circular_secular` | `eccentric_secular` |
  |-------------------------------|--------------------|---------------------|
  | GPS, e ~ 0.024 (G21)          | ~8 100 km          | ~8 km               |
  | GPS, e ~ 0.020 (G02)          | ~9 400 km          | ~11 km              |
  | BeiDou IGSO, e ~ 5e-3 (C08)   | ~2 200 km          | ~12 km              |
  | BeiDou MEO, e ~ 9e-4 (C21)    | ~140 km            | ~5 km               |
  | Galileo, e ~ 1e-4 (E01)       | ~8 km              | ~8 km (≈ circular)  |
  | ISS LEO, TLE/SGP4, 4 h        | ~31 km             | ~2.5 km             |

  Reading of the table:

    * For **eccentric** orbits the circular model leaves larger residuals because
      the unmodelled radial `a·e` signal compounds under extrapolation.
      `:eccentric_secular` reduces the max error by one-to-three orders of
      magnitude in these fixtures. Note this holds even for the *small* eccentricities of BeiDou
      MEO/IGSO (e ~ 1e-3 to 5e-3): a few-hundred-metre to ~200 km radial signal
      still affects the circular extrapolation, so the eccentric model has lower
      error in these fixtures.
    * For **near-circular** orbits (Galileo, e ~ 1e-4) both models are comparable:
      the eccentric model is essentially identical to the circular one (~8 km
      either way), so it does not regress and is a safe default when the orbit
      class is unknown.

  These figures are measured through `drift/3` (the public NIF-backed pipeline,
  GPST) against the vendored fixtures; the exact numbers shift slightly with the
  fit window and drift cadence.

  These are characterisations, not guarantees: always measure a given fit with
  `drift/3` against the source. This is a compact approximation for caching /
  visibility, never a substitute for SP3 or SGP4.

  ## Persistence

  `to_map/1` emits a stable, versioned map (frame, model, units, epoch scale,
  elements, fit stats) that `from_map/1` reads back, for caching/transport.
  """
  # Serialization is the explicit, versioned `to_map/1`/`from_map/1` contract
  # (the `fit.window` tuple is not directly JSON-encodable), so no `@derive`.
  alias Sidereon.Elements
  alias Sidereon.GNSS.Core.Epoch
  alias Sidereon.GNSS.Core.Native
  alias Sidereon.GNSS.Core.Sampling
  alias Sidereon.GNSS.Core.Source
  alias Sidereon.GNSS.Core.Validation
  alias Sidereon.GNSS.Core.VersionedMap
  alias Sidereon.NIF

  defstruct version: 1,
            model: "circular_secular",
            frame: "GCRS",
            raan_rate_mode: "fitted_j2_seeded",
            time_scale: "UTC",
            epoch: nil,
            a_m: nil,
            e: 0.0,
            i_rad: nil,
            raan_rad: nil,
            raan_rate_rad_s: nil,
            raan_rate_j2_rad_s: nil,
            arg_lat_rad: nil,
            mean_motion_rad_s: nil,
            h: nil,
            k: nil,
            arg_perigee_rad: nil,
            fit: nil

  @type epoch ::
          NaiveDateTime.t()
          | {{integer(), integer(), integer()}, {integer(), integer(), number()}}
  @type vec3 :: %{x_m: float(), y_m: float(), z_m: float()}

  @type t :: %__MODULE__{
          version: pos_integer(),
          model: String.t(),
          frame: String.t(),
          raan_rate_mode: String.t(),
          time_scale: String.t(),
          epoch: NaiveDateTime.t(),
          a_m: float(),
          e: float(),
          i_rad: float(),
          raan_rad: float(),
          raan_rate_rad_s: float(),
          raan_rate_j2_rad_s: float(),
          arg_lat_rad: float(),
          mean_motion_rad_s: float(),
          h: float() | nil,
          k: float() | nil,
          arg_perigee_rad: float() | nil,
          fit: map()
        }

  @default_cadence_s 900

  # ------------------------------------------------------------------------
  # Fit
  # ------------------------------------------------------------------------

  @doc """
  Fit a mean-element model to a source orbit.

  ## Sources

    * an `Sidereon.GNSS.SP3` handle - requires `:satellite_id` and `:window`; samples the
      product at `:cadence_s` over the window;
    * an `%Sidereon.Elements{}` TLE/OMM element set - requires `:window`; samples
      SGP4 over the window, converts TEME → GCRS → ECEF, and fits in UTC;
    * a list of `{epoch, {x_m, y_m, z_m}}` ECEF samples - the window is taken from
      the samples; `:frame` must be `:ecef` (the default).

  ## Options

    * `:model` - `:circular_secular` (**default**) or `:eccentric_secular`. The
      circular model fixes eccentricity at zero (suited to near-circular orbits);
      the eccentric model recovers the `a·e` radial signal for GPS and other
      eccentric orbits. See the moduledoc accuracy table.
    * `:satellite_id` - e.g. `"G05"` (SP3 source)
    * `:window` - `{t0, t1}` epochs bounding the fit (SP3 source)
    * `:cadence_s` - positive sampling step in seconds (sampled sources,
      default `#{@default_cadence_s}`)
    * `:frame` - for the sample-list source, `:ecef` (default)
    * `:time_scale` - for the sample-list source, the scale its epochs are in
      (`"UTC"` default, e.g. `"GPST"`); SP3 sources use the product's own scale

  Epochs are interpreted in the model's time scale (recorded on the result). The
  reference epoch `t0` is the earliest sample, so the result is independent of the
  caller's sample order.

  Returns `{:ok, %Sidereon.GNSS.ReducedOrbit{}}` or a tagged error:
  `{:too_few_samples, got, required}`, `:invalid_window`, `:invalid_cadence`,
  `:satellite_id_required`, `:singular_plane_fit`, `:raan_ambiguous`,
  `{:unsupported_source_frame, frame}`, `{:unsupported_model, model}`,
  `:transform_unavailable`, `:fit_did_not_converge`.
  """
  @spec fit(
          Sidereon.GNSS.SP3.t() | Elements.t() | [{epoch(), {number(), number(), number()}}],
          keyword()
        ) ::
          {:ok, t()} | {:error, term()}
  def fit(source, opts \\ [])

  def fit(%Sidereon.GNSS.SP3{} = sp3, opts) do
    sat_id = Keyword.get(opts, :satellite_id)

    with :ok <- require_satellite_id(sat_id),
         {:ok, model} <- valid_model(Keyword.get(opts, :model, :circular_secular)),
         {:ok, cadence} <- Validation.cadence(Keyword.get(opts, :cadence_s, @default_cadence_s)),
         {:ok, {t0, t1}} <- Epoch.fetch_window(opts),
         {:ok, samples, requested} <- Sampling.sample_sp3(sp3, sat_id, t0, t1, cadence) do
      # Epochs are interpreted in the product's own scale (typically GPST),
      # matching Sidereon.GNSS.SP3's contract, so the frame conversion is correct.
      meta = %{
        source: "sp3:#{sat_id}",
        window: {Epoch.to_naive!(t0), Epoch.to_naive!(t1)},
        cadence_s: cadence,
        scale: sp3.time_scale,
        model: model,
        requested: requested
      }

      run_fit(samples, meta)
    end
  end

  def fit(%Elements{} = tle, opts) do
    with {:ok, model} <- valid_model(Keyword.get(opts, :model, :circular_secular)),
         {:ok, cadence} <- Validation.cadence(Keyword.get(opts, :cadence_s, @default_cadence_s)),
         {:ok, {t0, t1}} <- Epoch.fetch_window(opts),
         {:ok, samples, requested} <- Sampling.sample_sgp4(tle, t0, t1, cadence) do
      meta = %{
        source: "sgp4:#{String.trim(tle.catalog_number || "unknown")}",
        window: {Epoch.to_naive!(t0), Epoch.to_naive!(t1)},
        cadence_s: cadence,
        scale: "UTC",
        model: model,
        requested: requested
      }

      run_fit(samples, meta)
    end
  end

  def fit(samples, opts) when is_list(samples) do
    scale_opt = Keyword.get(opts, :time_scale, "UTC")

    with {:ok, model} <- valid_model(Keyword.get(opts, :model, :circular_secular)),
         {:ok, scale} <- Validation.time_scale(scale_opt),
         :ecef <- Keyword.get(opts, :frame, :ecef) do
      meta = %{
        source: "samples",
        window: Epoch.window_of_samples(samples),
        cadence_s: nil,
        scale: scale,
        model: model,
        requested: length(samples)
      }

      run_fit(samples, meta)
    else
      {:error, _} = err -> err
      :error -> {:error, {:unsupported_time_scale, scale_opt}}
      other -> {:error, {:unsupported_source_frame, other}}
    end
  end

  defp run_fit([], _meta), do: {:error, {:too_few_samples, 0, 4}}

  defp run_fit(samples, meta) do
    tuples =
      Enum.map(samples, fn {ep, {x, y, z}} ->
        {Epoch.datetime_tuple(ep), x / 1.0, y / 1.0, z / 1.0}
      end)

    model_str = Atom.to_string(meta.model)

    case Native.safe_nif(fn -> NIF.reduced_orbit_fit(tuples, meta.scale, model_str) end) do
      {:ok, model_atom, epoch_tuple, elements, {rms, max, n_samples}} ->
        fit_stats = %{
          rms_m: rms,
          max_m: max,
          n_samples: n_samples,
          requested: meta.requested,
          window: meta.window,
          cadence_s: meta.cadence_s,
          source: meta.source
        }

        # The reference epoch is the fitter's t0 (earliest sample), returned from
        # Rust, so it is correct regardless of the caller's sample order.
        build_model(model_atom, Epoch.to_naive!(epoch_tuple), meta.scale, elements, fit_stats)

      {:error, reason} ->
        {:error, reason}

      {:nif_raised, _} ->
        {:error, :transform_unavailable}
    end
  end

  # Circular elements: eight floats, no eccentricity vector.
  defp build_model(
         :circular_secular,
         epoch,
         scale,
         [a_m, e, i_rad, raan, raan_rate, raan_rate_j2, arg_lat, n],
         fit_stats
       ) do
    {:ok,
     %__MODULE__{
       model: "circular_secular",
       epoch: epoch,
       time_scale: scale,
       a_m: a_m,
       e: e,
       i_rad: i_rad,
       raan_rad: raan,
       raan_rate_rad_s: raan_rate,
       raan_rate_j2_rad_s: raan_rate_j2,
       arg_lat_rad: arg_lat,
       mean_motion_rad_s: n,
       fit: fit_stats
     }}
  end

  # Eccentric elements: ten floats with h, k appended. `e` and arg_perigee are
  # derived for display; the load-bearing values are h and k.
  defp build_model(
         :eccentric_secular,
         epoch,
         scale,
         [a_m, e, i_rad, raan, raan_rate, raan_rate_j2, arg_lat, n, h, k],
         fit_stats
       ) do
    {:ok,
     %__MODULE__{
       model: "eccentric_secular",
       epoch: epoch,
       time_scale: scale,
       a_m: a_m,
       e: e,
       i_rad: i_rad,
       raan_rad: raan,
       raan_rate_rad_s: raan_rate,
       raan_rate_j2_rad_s: raan_rate_j2,
       arg_lat_rad: arg_lat,
       mean_motion_rad_s: n,
       h: h,
       k: k,
       arg_perigee_rad: arg_perigee(h, k),
       fit: fit_stats
     }}
  end

  # omega = atan2(h, k); undefined (pinned to 0) at e -> 0.
  defp arg_perigee(h, k) when h * h + k * k < 1.0e-24, do: 0.0
  defp arg_perigee(h, k), do: :math.atan2(h, k)

  # The numeric element fields every model needs to evaluate. from_map/1 requires
  # them so a malformed persisted map fails with :malformed_map at the boundary
  # rather than producing a struct full of nil that crashes later in the NIF.
  @required_elements ~w(a_m i_rad raan_rad raan_rate_rad_s raan_rate_j2_rad_s arg_lat_rad mean_motion_rad_s)

  # ------------------------------------------------------------------------
  # Evaluation
  # ------------------------------------------------------------------------

  @doc """
  Position of the model at `epoch`, ECEF (ITRF) meters by default.

  Pass `frame: :gcrs` for the inertial position. Returns
  `{:ok, %{x_m:, y_m:, z_m:}}` or `{:error, reason}`.
  """
  @spec position(t(), epoch(), keyword()) :: {:ok, vec3()} | {:error, term()}
  def position(%__MODULE__{} = model, epoch, opts \\ []) do
    with {:ok, frame} <- frame_string(Keyword.get(opts, :frame, :ecef)) do
      case Native.safe_nif(fn ->
             NIF.reduced_orbit_position(
               Epoch.datetime_tuple(model.epoch),
               model.time_scale,
               elements_tuple(model),
               Epoch.datetime_tuple(epoch),
               frame
             )
           end) do
        {:nif_raised, _} -> {:error, :transform_unavailable}
        {x, y, z} -> {:ok, %{x_m: x, y_m: y, z_m: z}}
      end
    end
  end

  @doc """
  Position and velocity of the model at `epoch`.

  ECEF velocity includes the Earth-rotation transport term. Returns
  `{:ok, %{position: %{x_m:, y_m:, z_m:}, velocity: %{vx_m_s:, vy_m_s:, vz_m_s:}}}`.
  """
  @spec position_velocity(t(), epoch(), keyword()) :: {:ok, map()} | {:error, term()}
  def position_velocity(%__MODULE__{} = model, epoch, opts \\ []) do
    with {:ok, frame} <- frame_string(Keyword.get(opts, :frame, :ecef)) do
      case Native.safe_nif(fn ->
             NIF.reduced_orbit_position_velocity(
               Epoch.datetime_tuple(model.epoch),
               model.time_scale,
               elements_tuple(model),
               Epoch.datetime_tuple(epoch),
               frame
             )
           end) do
        {:nif_raised, _} ->
          {:error, :transform_unavailable}

        {{x, y, z}, {vx, vy, vz}} ->
          {:ok,
           %{
             position: %{x_m: x, y_m: y, z_m: z},
             velocity: %{vx_m_s: vx, vy_m_s: vy, vz_m_s: vz}
           }}
      end
    end
  end

  # ------------------------------------------------------------------------
  # Drift (source-backed)
  # ------------------------------------------------------------------------

  @doc """
  Evaluate the model error against the **source** ephemeris over a horizon.

  This compares the model to fresh truth samples (not to itself): for an
  `Sidereon.GNSS.SP3` source it samples the product over `:window` at `:cadence_s` for
  `:satellite_id`; for an `%Sidereon.Elements{}` source it samples SGP4 over the
  window; for a list of `{epoch, {x_m, y_m, z_m}}` samples it uses those
  directly. Returns

      {:ok, %{per_epoch: [%{epoch:, error_m:}], max_m:, rms_m:, threshold_horizon:,
              requested:, used:}}

  where `threshold_horizon` is the first epoch the ECEF error exceeds
  `:threshold_m` (or `nil` if it never does / no threshold given).
  """
  @spec drift(
          t(),
          Sidereon.GNSS.SP3.t() | Elements.t() | [{epoch(), {number(), number(), number()}}],
          keyword()
        ) ::
          {:ok, map()} | {:error, term()}
  def drift(%__MODULE__{} = model, %Sidereon.GNSS.SP3{} = sp3, opts) do
    sat_id = Keyword.get(opts, :satellite_id)

    with :ok <- require_satellite_id(sat_id),
         :ok <- Source.same_time_scale(model, sp3),
         {:ok, cadence} <- Validation.cadence(Keyword.get(opts, :cadence_s, @default_cadence_s)),
         {:ok, {t0, t1}} <- Epoch.fetch_window(opts),
         {:ok, samples, requested} <- Sampling.sample_sp3(sp3, sat_id, t0, t1, cadence) do
      run_drift(model, samples, requested, opts)
    end
  end

  def drift(%__MODULE__{} = model, %Elements{} = tle, opts) do
    with :ok <- Source.same_time_scale(model, %{time_scale: "UTC"}),
         {:ok, cadence} <- Validation.cadence(Keyword.get(opts, :cadence_s, @default_cadence_s)),
         {:ok, {t0, t1}} <- Epoch.fetch_window(opts),
         {:ok, samples, requested} <- Sampling.sample_sgp4(tle, t0, t1, cadence) do
      run_drift(model, samples, requested, opts)
    end
  end

  def drift(%__MODULE__{} = model, samples, opts) when is_list(samples) do
    run_drift(model, samples, length(samples), opts)
  end

  defp run_drift(_model, [], _requested, _opts), do: {:error, {:too_few_samples, 0, 1}}

  defp run_drift(model, samples, requested, opts) do
    with {:ok, threshold_f} <- Validation.threshold(Keyword.get(opts, :threshold_m, :infinity)) do
      epochs = Enum.map(samples, fn {ep, _} -> Epoch.to_naive!(ep) end)

      truth =
        Enum.map(samples, fn {ep, {x, y, z}} ->
          {Epoch.datetime_tuple(ep), x / 1.0, y / 1.0, z / 1.0}
        end)

      run_drift_nif(model, truth, threshold_f, epochs, requested)
    end
  end

  defp run_drift_nif(model, truth, threshold_f, epochs, requested) do
    case Native.safe_nif(fn ->
           NIF.reduced_orbit_drift(
             Epoch.datetime_tuple(model.epoch),
             model.time_scale,
             elements_tuple(model),
             truth,
             threshold_f
           )
         end) do
      {:nif_raised, _} ->
        {:error, :transform_unavailable}

      {errors, max_m, rms_m, idx} ->
        per_epoch =
          epochs
          |> Enum.zip(errors)
          |> Enum.map(fn {ep, err} -> %{epoch: ep, error_m: err} end)

        horizon = if idx >= 0, do: Enum.at(epochs, idx)
        # `requested` vs `used` makes a horizon clipped by partial product
        # coverage visible to the caller (used == length(per_epoch)).
        {:ok,
         %{
           per_epoch: per_epoch,
           max_m: max_m,
           rms_m: rms_m,
           threshold_horizon: horizon,
           requested: requested,
           used: length(per_epoch)
         }}
    end
  end

  # ------------------------------------------------------------------------
  # Persistence
  # ------------------------------------------------------------------------

  @doc """
  Serialize a fitted model to a stable, versioned map (string keys) for caching
  or transport. See `from_map/1` for the inverse.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = m) do
    %{
      "version" => m.version,
      "model" => m.model,
      "frame" => m.frame,
      "time_scale" => m.time_scale,
      "epoch" => NaiveDateTime.to_iso8601(m.epoch),
      "elements" =>
        %{
          "a_m" => m.a_m,
          "e" => m.e,
          "i_rad" => m.i_rad,
          "raan_rad" => m.raan_rad,
          "raan_rate_rad_s" => m.raan_rate_rad_s,
          "raan_rate_j2_rad_s" => m.raan_rate_j2_rad_s,
          "raan_rate_mode" => m.raan_rate_mode,
          "arg_lat_rad" => m.arg_lat_rad,
          "mean_motion_rad_s" => m.mean_motion_rad_s
        }
        |> maybe_put_eccentric(m),
      "fit" => %{
        "rms_m" => m.fit.rms_m,
        "max_m" => m.fit.max_m,
        "n_samples" => m.fit.n_samples,
        "requested" => Map.get(m.fit, :requested),
        "cadence_s" => m.fit.cadence_s,
        "source" => m.fit.source,
        "window" => window_to_map(m.fit.window)
      },
      "units" => %{"length" => "m", "angle" => "rad", "rate" => "rad/s", "time" => "s"}
    }
  end

  # The eccentric model adds the eccentricity vector and derived argument of
  # perigee to the elements map; the circular model's map is unchanged.
  defp maybe_put_eccentric(elements, %__MODULE__{model: "eccentric_secular"} = m) do
    Map.merge(elements, %{
      "h" => m.h,
      "k" => m.k,
      "arg_perigee_rad" => m.arg_perigee_rad
    })
  end

  defp maybe_put_eccentric(elements, _m), do: elements

  @doc """
  Reconstruct a model from a `to_map/1` map. Validates the version and model id.

  Returns `{:ok, %Sidereon.GNSS.ReducedOrbit{}}` or `{:error, {:unsupported_version, v}}` /
  `{:error, {:unsupported_model, model}}` / `{:error, :malformed_map}`.
  """
  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(%{"version" => 1, "model" => "circular_secular"} = map) do
    with %{"elements" => el, "fit" => fit, "epoch" => epoch_iso} <- map,
         :ok <- VersionedMap.require_numeric(el, @required_elements),
         {:ok, scale} <- Validation.time_scale(Map.get(map, "time_scale", "UTC")),
         {:ok, epoch} <- NaiveDateTime.from_iso8601(epoch_iso) do
      {:ok,
       %__MODULE__{
         version: 1,
         model: "circular_secular",
         frame: Map.get(map, "frame", "GCRS"),
         time_scale: scale,
         raan_rate_mode: Map.get(el, "raan_rate_mode", "fitted_j2_seeded"),
         epoch: epoch,
         a_m: el["a_m"],
         e: Map.get(el, "e", 0.0),
         i_rad: el["i_rad"],
         raan_rad: el["raan_rad"],
         raan_rate_rad_s: el["raan_rate_rad_s"],
         raan_rate_j2_rad_s: el["raan_rate_j2_rad_s"],
         arg_lat_rad: el["arg_lat_rad"],
         mean_motion_rad_s: el["mean_motion_rad_s"],
         fit: %{
           rms_m: fit["rms_m"],
           max_m: fit["max_m"],
           n_samples: fit["n_samples"],
           requested: fit["requested"],
           cadence_s: fit["cadence_s"],
           source: fit["source"],
           window: window_from_map(fit["window"])
         }
       }}
    else
      _ -> {:error, :malformed_map}
    end
  end

  def from_map(%{"version" => 1, "model" => "eccentric_secular"} = map) do
    with %{"elements" => el, "fit" => fit, "epoch" => epoch_iso} <- map,
         :ok <- VersionedMap.require_numeric(el, @required_elements),
         h when is_number(h) <- el["h"],
         k when is_number(k) <- el["k"],
         {:ok, scale} <- Validation.time_scale(Map.get(map, "time_scale", "UTC")),
         {:ok, epoch} <- NaiveDateTime.from_iso8601(epoch_iso) do
      {:ok,
       %__MODULE__{
         version: 1,
         model: "eccentric_secular",
         frame: Map.get(map, "frame", "GCRS"),
         time_scale: scale,
         raan_rate_mode: Map.get(el, "raan_rate_mode", "fitted_j2_seeded"),
         epoch: epoch,
         a_m: el["a_m"],
         # e is derived from (h, k); the stored value is display-only.
         e: :math.sqrt(h * h + k * k),
         i_rad: el["i_rad"],
         raan_rad: el["raan_rad"],
         raan_rate_rad_s: el["raan_rate_rad_s"],
         raan_rate_j2_rad_s: el["raan_rate_j2_rad_s"],
         arg_lat_rad: el["arg_lat_rad"],
         mean_motion_rad_s: el["mean_motion_rad_s"],
         h: h,
         k: k,
         # Derived from (h, k), not trusted from the map independently.
         arg_perigee_rad: arg_perigee(h, k),
         fit: %{
           rms_m: fit["rms_m"],
           max_m: fit["max_m"],
           n_samples: fit["n_samples"],
           requested: fit["requested"],
           cadence_s: fit["cadence_s"],
           source: fit["source"],
           window: window_from_map(fit["window"])
         }
       }}
    else
      _ -> {:error, :malformed_map}
    end
  end

  def from_map(%{"version" => v, "model" => "circular_secular"}),
    do: {:error, {:unsupported_version, v}}

  def from_map(%{"version" => v, "model" => "eccentric_secular"}),
    do: {:error, {:unsupported_version, v}}

  def from_map(%{"model" => model}), do: {:error, {:unsupported_model, model}}
  def from_map(_), do: {:error, :malformed_map}

  # ------------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------------

  defp require_satellite_id(nil), do: {:error, :satellite_id_required}
  defp require_satellite_id(_), do: :ok

  defp valid_model(:circular_secular), do: {:ok, :circular_secular}
  defp valid_model(:eccentric_secular), do: {:ok, :eccentric_secular}
  defp valid_model(other), do: {:error, {:unsupported_model, other}}

  # The flat element list the NIF consumes. Circular is eight floats (unchanged);
  # eccentric appends h, k (ten floats), which the NIF reads back by length.
  defp elements_tuple(%__MODULE__{model: "eccentric_secular"} = m) do
    [
      m.a_m,
      m.e,
      m.i_rad,
      m.raan_rad,
      m.raan_rate_rad_s,
      m.raan_rate_j2_rad_s,
      m.arg_lat_rad,
      m.mean_motion_rad_s,
      m.h,
      m.k
    ]
  end

  defp elements_tuple(%__MODULE__{} = m) do
    [
      m.a_m,
      m.e,
      m.i_rad,
      m.raan_rad,
      m.raan_rate_rad_s,
      m.raan_rate_j2_rad_s,
      m.arg_lat_rad,
      m.mean_motion_rad_s
    ]
  end

  defp frame_string(:ecef), do: {:ok, "ecef"}
  defp frame_string(:gcrs), do: {:ok, "gcrs"}
  defp frame_string(other), do: {:error, {:unsupported_frame, other}}

  defp window_to_map(nil), do: nil

  defp window_to_map({t0, t1}),
    do: %{"start" => NaiveDateTime.to_iso8601(t0), "end" => NaiveDateTime.to_iso8601(t1)}

  defp window_from_map(nil), do: nil

  defp window_from_map(%{"start" => s, "end" => e}) do
    with {:ok, t0} <- NaiveDateTime.from_iso8601(s), {:ok, t1} <- NaiveDateTime.from_iso8601(e) do
      {t0, t1}
    else
      _ -> nil
    end
  end
end
