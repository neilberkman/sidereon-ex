defmodule Sidereon.GNSS.ReducedOrbit.Piecewise do
  @moduledoc """
  A long position track approximated by a sequence of contiguous, independently
  fitted `Sidereon.GNSS.ReducedOrbit` segments.

  A single `Sidereon.GNSS.ReducedOrbit` distills a whole track into one set of mean
  elements; extrapolated over a day it drifts (GPS ~thousands of km with the
  circular model, ~8 km eccentric). A `Piecewise` model instead splits the span
  `[t0, t1]` into contiguous segments of `:segment_s` seconds and fits each one
  with the **existing** `Sidereon.GNSS.ReducedOrbit.fit/2`. Every query then lands
  *inside* a fit window, so the error collapses to the in-window residual
  (sub-km to a few km) rather than the extrapolation error, at the cost of
  storing N small models. It is pure orchestration over the single-segment
  primitives; the orbit math, frames, and time scales are unchanged.

  For caching and transport, this trades stored segment count for the measured
  residuals shown below. It is **not** orbit determination and **not** a substitute
  for SP3 or SGP4. It is a compact approximation whose residual can be measured
  with the source-backed `drift/3`.

  ## Models

  Each segment is one of the two `Sidereon.GNSS.ReducedOrbit` models, selected with the
  same `:model` option:

    * `:circular_secular` (the **default**) - a circular orbit;
    * `:eccentric_secular` - recovers the radial `a·e` signal.

  See `Sidereon.GNSS.ReducedOrbit` for the per-model details.

  ## Size / residual tradeoff

  Storage grows ~linearly with the number of segments: a span of `T` seconds
  split at `:segment_s` holds `ceil(T / segment_s)` models, each serialized via
  `Sidereon.GNSS.ReducedOrbit.to_map/1`. Shorter segments cost more bytes but keep every
  query closer to the centre of a fit window, shrinking the residual. The table
  below is the **max** position error over a full day (model residual against
  the source, measured
  through `drift/3` against the vendored MGEX fixtures, GPST), where both the
  single and piecewise models are fitted over that same full day and evaluated
  across it. (Fitting only part of the span and extrapolating is far worse for
  the single model; see `Sidereon.GNSS.ReducedOrbit`. Here the single model is
  fit across the whole span for comparison.)

  ### `circular_secular`

  | Orbit class                  | single    | 2 h pw | 4 h pw | 6 h pw |
  |------------------------------|-----------|--------|--------|--------|
  | GPS, e ~ 0.024 (G21)         | ~1 437 km | ~331 km| ~653 km| ~830 km|
  | Galileo, e ~ 1e-4 (E01)      | ~7 km     | ~1 km  | ~3 km  | ~4 km  |
  | BeiDou MEO, e ~ 9e-4 (C21)   | ~54 km    | ~12 km | ~24 km | ~38 km |
  | BeiDou IGSO, e ~ 5e-3 (C08)  | ~533 km   | ~50 km | ~102 km| ~147 km|

  ### `eccentric_secular`

  | Orbit class                  | single  | 2 h pw  | 4 h pw  | 6 h pw  |
  |------------------------------|---------|---------|---------|---------|
  | GPS, e ~ 0.024 (G21)         | ~440 m  | ~90 m   | ~280 m  | ~310 m  |
  | Galileo, e ~ 1e-4 (E01)      | ~780 m  | ~90 m   | ~260 m  | ~380 m  |
  | BeiDou MEO, e ~ 9e-4 (C21)   | ~430 m  | ~120 m  | ~330 m  | ~420 m  |
  | BeiDou IGSO, e ~ 5e-3 (C08)  | ~870 m  | ~20 m   | ~70 m   | ~130 m  |

  For the eccentric model the single whole-day fit is already sub-km; piecewise
  reduces the max error by roughly 3× to tens of × (most cells ~3-9×, the
  near-circular IGSO as much as ~40×). For the circular model the unmodelled
  `a·e` radial signal dominates and piecewise's difference is largest in absolute
  terms (hundreds of km for GPS/IGSO). In these fixtures, the 2 h split has a
  lower residual than the 4 h and 6 h splits in every cell, showing the storage
  and residual tradeoff.

  These are characterisations, not guarantees; the exact numbers shift with the
  fit window, segment length, and drift cadence. Always measure a given fit with
  `drift/3` against the source.

  ## Segment selection

  Segments tile `[t0, t1]` with no gaps. A query epoch is resolved by finding the
  segment whose half-open interval `[seg_t0, seg_t1)` contains it; the final
  segment is treated as inclusive at the very end so the exact end-of-span epoch
  resolves to the last segment. An epoch exactly on an interior boundary resolves
  to the **later** segment (where it is the in-window start), which is
  deterministic. Selection is `O(segments)`; the segment count is modest and the
  ordered list is binary-searchable if it ever grows large. An epoch before `t0`
  or after `t1` returns `{:error, :out_of_range}`.

  ## Persistence

  `to_map/1` emits a stable, versioned container (string keys, JSON-safe) holding
  the per-segment maps via `Sidereon.GNSS.ReducedOrbit.to_map/1`; `from_map/1` validates
  the version and model and reconstructs, with the same tagged-error discipline
  as the single model.
  """
  alias Sidereon.Elements
  alias Sidereon.GNSS.Core.Epoch
  alias Sidereon.GNSS.Core.Native
  alias Sidereon.GNSS.Core.Sampling
  alias Sidereon.GNSS.Core.Source
  alias Sidereon.GNSS.Core.Validation
  alias Sidereon.GNSS.ReducedOrbit
  alias Sidereon.NIF

  defstruct version: 1,
            model: "circular_secular",
            frame: "GCRS",
            time_scale: "UTC",
            window: nil,
            segment_s: nil,
            segments: []

  @type epoch :: ReducedOrbit.epoch()
  @type segment :: %{t0: NaiveDateTime.t(), t1: NaiveDateTime.t(), model: ReducedOrbit.t()}

  @type t :: %__MODULE__{
          version: pos_integer(),
          model: String.t(),
          frame: String.t(),
          time_scale: String.t(),
          window: {NaiveDateTime.t(), NaiveDateTime.t()},
          segment_s: number(),
          segments: [segment()]
        }

  # The crate requires four samples to fit one segment; mirror that count for the
  # whole-thing "nothing fit" surface.
  @min_samples 4

  @model_ids ~w(circular_secular eccentric_secular)

  # ------------------------------------------------------------------------
  # Fit
  # ------------------------------------------------------------------------

  @doc """
  Fit a piecewise model over a span, one contiguous `Sidereon.GNSS.ReducedOrbit` segment
  per `:segment_s` seconds.

  ## Sources

    * an `Sidereon.GNSS.SP3` handle - requires `:satellite_id` and `:window`; each
      segment is fitted with `Sidereon.GNSS.ReducedOrbit.fit/2` over its sub-window at
      `:cadence_s`;
    * an `%Sidereon.Elements{}` TLE/OMM element set - requires `:window`; each
      segment samples SGP4 over its sub-window and fits in UTC;
    * a list of `{epoch, {x_m, y_m, z_m}}` ECEF samples - partitioned by segment
      interval, each sublist fitted directly.

  ## Options

    * `:window` - `{t0, t1}` epochs bounding the full span (`t1` strictly after
      `t0`, else `:invalid_window`)
    * `:segment_s` - positive segment length in seconds, e.g. `7200`
      (non-positive → `:invalid_segment`)
    * `:cadence_s` - positive sampling step in seconds for SP3/TLE sources
    * `:satellite_id` - e.g. `"G05"` (SP3 source)
    * `:model` - `:circular_secular` (**default**) or `:eccentric_secular`
    * `:time_scale` - for the sample-list source, the scale its epochs are in

  Segments are contiguous (`seg_t1` of one is `seg_t0` of the next); the final
  segment may be shorter. A `:segment_s` at least the full span yields a single
  segment equal to the whole window (piecewise with one segment ≡ single).

  Returns `{:ok, %Sidereon.GNSS.ReducedOrbit.Piecewise{}}` or a tagged error. The error
  set is exactly the single model's fit errors (`{:too_few_samples, got, req}`,
  `:invalid_window`, `:invalid_cadence`, `:satellite_id_required`,
  `{:unsupported_model, m}`, `{:unsupported_source_frame, f}`,
  `{:unsupported_time_scale, s}`, `:transform_unavailable`, …) plus
  `:invalid_segment`. A too-few-samples failure on a non-terminal segment is
  surfaced (a genuinely under-covered interior span is an error, not a silent
  hole); only the terminal short segment may be dropped. If nothing fits at all,
  `{:error, {:too_few_samples, 0, #{@min_samples}}}`.
  """
  @spec fit(
          Sidereon.GNSS.SP3.t() | Elements.t() | [{epoch(), {number(), number(), number()}}],
          keyword()
        ) ::
          {:ok, t()} | {:error, term()}
  def fit(source, opts \\ []) do
    with {:ok, {t0, t1}} <- Epoch.fetch_window(opts),
         {:ok, segment_s} <- validate_segment_s(Keyword.get(opts, :segment_s)),
         {:ok, meta, samples} <- source_samples(source, opts, t0, t1) do
      run_fit(samples, meta, t0, t1, segment_s)
    end
  end

  # The segment length drives a second-resolution tiling, so it must round to at
  # least one whole second; otherwise the step is 0 and the tiling cannot
  # advance. Return the rounded integer so the stored length is the one used.
  defp validate_segment_s(s) when is_number(s) and s > 0 do
    step = round(s)
    if step >= 1, do: {:ok, step}, else: {:error, :invalid_segment}
  end

  defp validate_segment_s(_), do: {:error, :invalid_segment}

  defp source_samples(%Sidereon.GNSS.SP3{} = sp3, opts, t0, t1) do
    sat_id = Keyword.get(opts, :satellite_id)

    with :ok <- require_satellite_id(sat_id),
         {:ok, model} <- valid_model(Keyword.get(opts, :model, :circular_secular)),
         {:ok, cadence} <- Validation.cadence(Keyword.get(opts, :cadence_s, 900)),
         {:ok, samples, _requested} <- Sampling.sample_sp3(sp3, sat_id, t0, t1, cadence) do
      {:ok,
       %{
         source: "sp3:#{sat_id}",
         scale: sp3.time_scale,
         cadence_s: cadence,
         model: model
       }, samples}
    end
  end

  defp source_samples(%Elements{} = tle, opts, t0, t1) do
    with {:ok, model} <- valid_model(Keyword.get(opts, :model, :circular_secular)),
         {:ok, cadence} <- Validation.cadence(Keyword.get(opts, :cadence_s, 900)),
         {:ok, samples, _requested} <- Sampling.sample_sgp4(tle, t0, t1, cadence) do
      {:ok,
       %{
         source: "sgp4:#{String.trim(tle.catalog_number || "unknown")}",
         scale: "UTC",
         cadence_s: cadence,
         model: model
       }, samples}
    end
  end

  defp source_samples(samples, opts, _t0, _t1) when is_list(samples) do
    scale_opt = Keyword.get(opts, :time_scale, "UTC")

    with {:ok, model} <- valid_model(Keyword.get(opts, :model, :circular_secular)),
         {:ok, scale} <- Validation.time_scale(scale_opt),
         :ecef <- Keyword.get(opts, :frame, :ecef) do
      {:ok,
       %{
         source: "samples",
         scale: scale,
         cadence_s: nil,
         model: model
       }, samples}
    else
      {:error, _} = err -> err
      :error -> {:error, {:unsupported_time_scale, scale_opt}}
      other -> {:error, {:unsupported_source_frame, other}}
    end
  end

  defp run_fit(samples, meta, t0, t1, segment_s) do
    tuples =
      Enum.map(samples, fn {ep, {x, y, z}} ->
        {Epoch.datetime_tuple(ep), x / 1.0, y / 1.0, z / 1.0}
      end)

    case Native.safe_nif(fn ->
           NIF.reduced_orbit_piecewise_fit(
             tuples,
             meta.scale,
             Atom.to_string(meta.model),
             Epoch.datetime_tuple(t0),
             Epoch.datetime_tuple(t1),
             segment_s
           )
         end) do
      {:ok, coverage_end, used_segment_s, rows} ->
        segments =
          Enum.map(rows, fn {seg_t0, seg_t1, model_atom, epoch, elements, {rms, max, n_samples}} ->
            seg_t0 = Epoch.to_naive!(seg_t0)
            seg_t1 = Epoch.to_naive!(seg_t1)

            fit_stats = %{
              rms_m: rms,
              max_m: max,
              n_samples: n_samples,
              requested: n_samples,
              window: {seg_t0, seg_t1},
              cadence_s: meta.cadence_s,
              source: meta.source
            }

            {:ok, model} =
              build_model(model_atom, Epoch.to_naive!(epoch), meta.scale, elements, fit_stats)

            %{t0: seg_t0, t1: seg_t1, model: model}
          end)

        first = hd(segments)

        {:ok,
         %__MODULE__{
           version: 1,
           model: first.model.model,
           frame: first.model.frame,
           time_scale: first.model.time_scale,
           window: {t0, Epoch.to_naive!(coverage_end)},
           segment_s: used_segment_s,
           segments: segments
         }}

      {:error, reason} ->
        {:error, reason}

      {:nif_raised, _} ->
        {:error, :transform_unavailable}
    end
  end

  defp build_model(
         :circular_secular,
         epoch,
         scale,
         [a_m, e, i_rad, raan, raan_rate, raan_rate_j2, arg_lat, n],
         fit_stats
       ) do
    {:ok,
     %ReducedOrbit{
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

  defp build_model(
         :eccentric_secular,
         epoch,
         scale,
         [a_m, e, i_rad, raan, raan_rate, raan_rate_j2, arg_lat, n, h, k],
         fit_stats
       ) do
    {:ok,
     %ReducedOrbit{
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

  defp arg_perigee(h, k) when h * h + k * k < 1.0e-24, do: 0.0
  defp arg_perigee(h, k), do: :math.atan2(h, k)

  # ------------------------------------------------------------------------
  # Evaluation
  # ------------------------------------------------------------------------

  @doc """
  Position of the piecewise model at `epoch`, ECEF (ITRF) meters by default.

  Selects the segment covering `epoch` and delegates to
  `Sidereon.GNSS.ReducedOrbit.position/3`. Pass `frame: :gcrs` for the inertial position.
  An epoch outside the full span returns `{:error, :out_of_range}`.
  """
  @spec position(t(), epoch(), keyword()) :: {:ok, ReducedOrbit.vec3()} | {:error, term()}
  def position(%__MODULE__{} = pw, epoch, opts \\ []) do
    with {:ok, frame} <- frame_string(Keyword.get(opts, :frame, :ecef)) do
      case Native.safe_nif(fn ->
             {w0, w1} = pw.window

             NIF.reduced_orbit_piecewise_position(
               Epoch.datetime_tuple(w0),
               Epoch.datetime_tuple(w1),
               pw.segment_s,
               segment_terms(pw),
               pw.time_scale,
               Epoch.datetime_tuple(epoch),
               frame
             )
           end) do
        {:ok, {x, y, z}} -> {:ok, %{x_m: x, y_m: y, z_m: z}}
        {:error, reason} -> {:error, reason}
        {:nif_raised, _} -> {:error, :transform_unavailable}
      end
    end
  end

  @doc """
  Position and velocity of the piecewise model at `epoch`.

  Selects the covering segment and delegates to
  `Sidereon.GNSS.ReducedOrbit.position_velocity/3`. An epoch outside the full span
  returns `{:error, :out_of_range}`.
  """
  @spec position_velocity(t(), epoch(), keyword()) :: {:ok, map()} | {:error, term()}
  def position_velocity(%__MODULE__{} = pw, epoch, opts \\ []) do
    with {:ok, frame} <- frame_string(Keyword.get(opts, :frame, :ecef)) do
      case Native.safe_nif(fn ->
             {w0, w1} = pw.window

             NIF.reduced_orbit_piecewise_position_velocity(
               Epoch.datetime_tuple(w0),
               Epoch.datetime_tuple(w1),
               pw.segment_s,
               segment_terms(pw),
               pw.time_scale,
               Epoch.datetime_tuple(epoch),
               frame
             )
           end) do
        {:ok, {{x, y, z}, {vx, vy, vz}}} ->
          {:ok,
           %{
             position: %{x_m: x, y_m: y, z_m: z},
             velocity: %{vx_m_s: vx, vy_m_s: vy, vz_m_s: vz}
           }}

        {:error, reason} ->
          {:error, reason}

        {:nif_raised, _} ->
          {:error, :transform_unavailable}
      end
    end
  end

  @doc """
  Select the segment whose coverage interval contains `epoch`.

  Returns `{:ok, segment}` or `{:error, :out_of_range}`. Interior boundaries
  resolve to the later segment; the exact end-of-span epoch resolves to the last
  segment.
  """
  @spec select_segment(t(), epoch()) :: {:ok, segment()} | {:error, term()}
  def select_segment(%__MODULE__{} = pw, epoch) do
    case Native.safe_nif(fn ->
           {w0, w1} = pw.window

           NIF.reduced_orbit_piecewise_select_segment(
             Epoch.datetime_tuple(w0),
             Epoch.datetime_tuple(w1),
             pw.segment_s,
             segment_terms(pw),
             Epoch.datetime_tuple(epoch)
           )
         end) do
      {:ok, index} -> {:ok, Enum.at(pw.segments, index)}
      {:error, reason} -> {:error, reason}
      {:nif_raised, _} -> {:error, :transform_unavailable}
    end
  end

  # ------------------------------------------------------------------------
  # Drift (source-backed, whole span)
  # ------------------------------------------------------------------------

  @doc """
  Evaluate the piecewise model error against the **source** ephemeris over the
  whole span.

  Samples the source across the span and compares each truth sample to the
  covering segment's ECEF position (the single-segment drift NIF is per-model, so
  the piecewise report is composed in Elixir from `position/3`). For an
  `Sidereon.GNSS.SP3` source it samples over `:window` (defaulting to the model's full
  span) at `:cadence_s` for `:satellite_id`; for an `%Sidereon.Elements{}` source it
  samples SGP4 over the window; for a sample list it uses those directly. Returns

      {:ok, %{per_epoch: [%{epoch:, error_m:}], max_m:, rms_m:, threshold_horizon:,
              requested:, used:}}

  matching the single-segment `Sidereon.GNSS.ReducedOrbit.drift/3` report. Epochs outside
  the model's span are skipped (counted in `requested`, not `used`).
  `threshold_horizon` is the first epoch the ECEF error exceeds `:threshold_m`
  (or `nil`).
  """
  @spec drift(
          t(),
          Sidereon.GNSS.SP3.t() | Elements.t() | [{epoch(), {number(), number(), number()}}],
          keyword()
        ) ::
          {:ok, map()} | {:error, term()}
  def drift(%__MODULE__{} = pw, %Sidereon.GNSS.SP3{} = sp3, opts) do
    sat_id = Keyword.get(opts, :satellite_id)

    with :ok <- require_satellite_id(sat_id),
         :ok <- Source.same_time_scale(pw, sp3),
         {:ok, cadence} <- Validation.cadence(Keyword.get(opts, :cadence_s, 900)),
         {:ok, {t0, t1}} <- Epoch.fetch_window(opts, pw.window),
         {:ok, samples, requested} <- Sampling.sample_sp3(sp3, sat_id, t0, t1, cadence) do
      run_drift(pw, samples, requested, opts)
    end
  end

  def drift(%__MODULE__{} = pw, %Elements{} = tle, opts) do
    with :ok <- Source.same_time_scale(pw, %{time_scale: "UTC"}),
         {:ok, cadence} <- Validation.cadence(Keyword.get(opts, :cadence_s, 900)),
         {:ok, {t0, t1}} <- Epoch.fetch_window(opts, pw.window),
         {:ok, samples, requested} <- Sampling.sample_sgp4(tle, t0, t1, cadence) do
      run_drift(pw, samples, requested, opts)
    end
  end

  def drift(%__MODULE__{} = pw, samples, opts) when is_list(samples) do
    run_drift(pw, samples, length(samples), opts)
  end

  defp run_drift(_pw, [], _requested, _opts), do: {:error, {:too_few_samples, 0, 1}}

  defp run_drift(pw, samples, requested, opts) do
    with {:ok, threshold_f} <- Validation.threshold(Keyword.get(opts, :threshold_m, :infinity)) do
      truth =
        Enum.map(samples, fn {ep, {x, y, z}} ->
          {Epoch.datetime_tuple(ep), x / 1.0, y / 1.0, z / 1.0}
        end)

      case Native.safe_nif(fn ->
             {w0, w1} = pw.window

             NIF.reduced_orbit_piecewise_drift(
               Epoch.datetime_tuple(w0),
               Epoch.datetime_tuple(w1),
               pw.segment_s,
               segment_terms(pw),
               pw.time_scale,
               truth,
               threshold_f
             )
           end) do
        {:ok, rows, max_m, rms_m, idx} ->
          per_epoch =
            Enum.map(rows, fn {ep, err} ->
              %{epoch: Epoch.to_naive!(ep), error_m: err}
            end)

          horizon = if idx >= 0, do: Enum.at(per_epoch, idx).epoch

          {:ok,
           %{
             per_epoch: per_epoch,
             max_m: max_m,
             rms_m: rms_m,
             threshold_horizon: horizon,
             requested: requested,
             used: length(per_epoch)
           }}

        {:error, reason} ->
          {:error, reason}

        {:nif_raised, _} ->
          {:error, :transform_unavailable}
      end
    end
  end

  # ------------------------------------------------------------------------
  # Persistence
  # ------------------------------------------------------------------------

  @doc """
  Serialize a piecewise model to a stable, versioned, JSON-safe map (string
  keys). Each segment's model is serialized via `Sidereon.GNSS.ReducedOrbit.to_map/1`.
  See `from_map/1` for the inverse.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = pw) do
    {t0, t1} = pw.window

    %{
      "version" => pw.version,
      "kind" => "piecewise",
      "model" => pw.model,
      "frame" => pw.frame,
      "time_scale" => pw.time_scale,
      "segment_s" => pw.segment_s,
      "window" => %{
        "start" => NaiveDateTime.to_iso8601(t0),
        "end" => NaiveDateTime.to_iso8601(t1)
      },
      "segments" =>
        Enum.map(pw.segments, fn seg ->
          %{
            "t0" => NaiveDateTime.to_iso8601(seg.t0),
            "t1" => NaiveDateTime.to_iso8601(seg.t1),
            "model" => ReducedOrbit.to_map(seg.model)
          }
        end)
    }
  end

  @doc """
  Reconstruct a piecewise model from a `to_map/1` map. Validates the version and
  model id.

  Returns `{:ok, %Sidereon.GNSS.ReducedOrbit.Piecewise{}}` or
  `{:error, {:unsupported_version, v}}` / `{:error, {:unsupported_model, m}}` /
  `{:error, :malformed_map}`. A segment whose inner model fails `from_map`, or
  whose model id differs from the container, makes the whole map malformed:
  never a raise, never a nil-filled struct.
  """
  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(%{"version" => 1, "kind" => "piecewise", "model" => model} = map)
      when model in @model_ids do
    frame = Map.get(map, "frame", "GCRS")

    with %{"segments" => seg_maps, "window" => window_map, "segment_s" => segment_s} <- map,
         true <- is_list(seg_maps),
         # An empty segment list is a state fit/2 can never produce (it surfaces
         # {:too_few_samples, 0, _} when nothing fits); reject it as malformed.
         false <- seg_maps == [],
         true <- is_number(segment_s),
         {:ok, scale} <- Validation.time_scale(Map.get(map, "time_scale", "UTC")),
         {:ok, {t0, t1}} <- window_from_map(window_map),
         # Each segment's inner model must agree with the container on model id,
         # frame, and time scale, or the persisted scale/frame contract is a lie
         # (position/3 would evaluate mixed-scale segments under a single
         # container scale). fit/2 only ever emits agreeing, gap-free segments.
         {:ok, segments} <- segments_from_maps(seg_maps, model, scale, frame),
         :ok <- validate_contiguity(segments, t0, t1) do
      {:ok,
       %__MODULE__{
         version: 1,
         model: model,
         frame: frame,
         time_scale: scale,
         window: {t0, t1},
         segment_s: segment_s,
         segments: segments
       }}
    else
      _ -> {:error, :malformed_map}
    end
  end

  def from_map(%{"version" => v, "kind" => "piecewise", "model" => model})
      when model in @model_ids, do: {:error, {:unsupported_version, v}}

  def from_map(%{"kind" => "piecewise", "model" => model}),
    do: {:error, {:unsupported_model, model}}

  def from_map(_), do: {:error, :malformed_map}

  defp segments_from_maps(seg_maps, model, scale, frame) do
    Enum.reduce_while(seg_maps, {:ok, []}, fn seg_map, {:ok, acc} ->
      case segment_from_map(seg_map, model, scale, frame) do
        {:ok, seg} -> {:cont, {:ok, [seg | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, segs} -> {:ok, Enum.reverse(segs)}
      :error -> :error
    end
  end

  defp segment_from_map(
         %{"t0" => t0_iso, "t1" => t1_iso, "model" => model_map},
         container_model,
         container_scale,
         container_frame
       )
       when is_binary(t0_iso) and is_binary(t1_iso) do
    with {:ok, t0} <- NaiveDateTime.from_iso8601(t0_iso),
         {:ok, t1} <- NaiveDateTime.from_iso8601(t1_iso),
         {:ok,
          %ReducedOrbit{
            model: ^container_model,
            time_scale: ^container_scale,
            frame: ^container_frame
          } = model} <-
           ReducedOrbit.from_map(model_map) do
      {:ok, %{t0: t0, t1: t1, model: model}}
    else
      _ -> :error
    end
  end

  defp segment_from_map(_, _, _, _), do: :error

  # A genuine fit/2 product tiles [t0, t1] with gap-free, abutting segments whose
  # ends meet exactly and whose span equals the container window. Reject a
  # persisted map that violates this (an interior gap or a window that does not
  # match the segments).
  defp validate_contiguity([first | _] = segments, t0, t1) do
    last = List.last(segments)

    abutting? =
      segments
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.all?(fn [a, b] -> NaiveDateTime.compare(a.t1, b.t0) == :eq end)

    if abutting? and NaiveDateTime.compare(first.t0, t0) == :eq and
         NaiveDateTime.compare(last.t1, t1) == :eq do
      :ok
    else
      :error
    end
  end

  defp validate_contiguity(_, _, _), do: :error

  # ------------------------------------------------------------------------
  # Helpers (mirrored from the single model for parity)
  # ------------------------------------------------------------------------

  defp require_satellite_id(nil), do: {:error, :satellite_id_required}
  defp require_satellite_id(_), do: :ok

  defp window_from_map(%{"start" => s, "end" => e}) when is_binary(s) and is_binary(e) do
    with {:ok, t0} <- NaiveDateTime.from_iso8601(s), {:ok, t1} <- NaiveDateTime.from_iso8601(e) do
      {:ok, {t0, t1}}
    else
      _ -> :error
    end
  end

  defp window_from_map(_), do: :error

  defp valid_model(:circular_secular), do: {:ok, :circular_secular}
  defp valid_model(:eccentric_secular), do: {:ok, :eccentric_secular}
  defp valid_model(other), do: {:error, {:unsupported_model, other}}

  defp frame_string(:ecef), do: {:ok, "ecef"}
  defp frame_string(:gcrs), do: {:ok, "gcrs"}
  defp frame_string(other), do: {:error, {:unsupported_frame, other}}

  defp segment_terms(%__MODULE__{} = pw) do
    Enum.map(pw.segments, fn seg ->
      {
        Epoch.datetime_tuple(seg.t0),
        Epoch.datetime_tuple(seg.t1),
        Epoch.datetime_tuple(seg.model.epoch),
        elements_tuple(seg.model)
      }
    end)
  end

  defp elements_tuple(%ReducedOrbit{model: "eccentric_secular"} = m) do
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

  defp elements_tuple(%ReducedOrbit{} = m) do
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
end
