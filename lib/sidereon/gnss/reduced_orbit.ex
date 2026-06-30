defmodule Sidereon.GNSS.ReducedOrbit do
  @moduledoc """
  A compact, fitted mean-element approximation of a satellite's orbit.

  `Sidereon.GNSS.ReducedOrbit` fits a list of ECEF position samples into a compact
  mean-element model that can be evaluated cheaply. It is **not** orbit
  determination and **not** a substitute for SGP4 or precise ephemeris: it
  deliberately discards short-period structure and reports the residual it leaves
  behind (`rms_m`/`max_m` on the fit, and sample-backed `drift/3`).

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
  `k = e·cos ω`, `L0` (mean argument of latitude at epoch), and `n`. The core
  fit returns `e` and `ω`. At an offset `dt` the model advances
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

  Representative drift values depend on the sample span, cadence, and orbit class.
  Measure a fitted model with `drift/3` against caller-provided truth samples.

  This is a compact approximation for caching or visibility, never a substitute
  for precise source data.
  """
  alias Sidereon.GNSS.Core.Epoch
  alias Sidereon.GNSS.Core.Native
  alias Sidereon.GNSS.Core.Validation
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

  # ------------------------------------------------------------------------
  # Fit
  # ------------------------------------------------------------------------

  @doc """
  Fit a mean-element model to ECEF samples.

  ## Options

    * `:model` - `:circular_secular` (**default**) or `:eccentric_secular`. The
      circular model fixes eccentricity at zero (suited to near-circular orbits);
      the eccentric model recovers the `a·e` radial signal for GPS and other
      eccentric orbits. See the moduledoc accuracy table.
    * `:frame` - `:ecef` (default)
    * `:time_scale` - the scale the sample epochs are in (`"UTC"` default)

  Epochs are interpreted in the model's time scale (recorded on the result). The
  reference epoch `t0` is the earliest sample, so the result is independent of the
  caller's sample order.

  Returns `{:ok, %Sidereon.GNSS.ReducedOrbit{}}` or a tagged error:
  `{:too_few_samples, got, required}`, `:invalid_window`, `:invalid_cadence`,
  `:singular_plane_fit`, `:raan_ambiguous`, `{:unsupported_source_frame, frame}`,
  `{:unsupported_model, model}`, `:transform_unavailable`, `:fit_did_not_converge`.
  """
  @spec fit([{epoch(), {number(), number(), number()}}], keyword()) :: {:ok, t()} | {:error, term()}
  def fit(source, opts \\ [])

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

  # Eccentric elements: core returns h, k, and arg_perigee_rad with the fitted e.
  defp build_model(
         :eccentric_secular,
         epoch,
         scale,
         [a_m, e, i_rad, raan, raan_rate, raan_rate_j2, arg_lat, n, h, k, arg_perigee_rad],
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
       arg_perigee_rad: arg_perigee_rad,
       fit: fit_stats
     }}
  end

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
  # Drift
  # ------------------------------------------------------------------------

  @doc """
  Evaluate the model error against truth samples.

  Returns

      {:ok, %{per_epoch: [%{epoch:, error_m:}], max_m:, rms_m:, threshold_horizon:,
              requested:, used:}}

  where `threshold_horizon` is the first epoch the ECEF error exceeds
  `:threshold_m` (or `nil` if it never does / no threshold given).
  """
  @spec drift(t(), [{epoch(), {number(), number(), number()}}], keyword()) :: {:ok, map()} | {:error, term()}

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
  # Helpers
  # ------------------------------------------------------------------------

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
end
