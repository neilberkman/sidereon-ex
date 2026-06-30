defmodule Sidereon.GNSS.ReducedOrbit.Piecewise do
  @moduledoc """
  A long position track approximated by a sequence of contiguous, independently
  fitted `Sidereon.GNSS.ReducedOrbit` segments.

  A single `Sidereon.GNSS.ReducedOrbit` distills a whole track into one set of mean
  elements. A `Piecewise` model instead splits the span `[t0, t1]` into
  contiguous segments of `:segment_s` seconds and fits each segment. Every query
  lands inside one fit window, so residuals are controlled by the samples in that
  segment. The orbit math, frames, and time scales are unchanged.

  This trades stored segment count for residual control. It is **not** orbit
  determination and **not** a substitute for source ephemeris data. Measure the
  residual with `drift/3` against caller-provided truth samples.

  ## Models

  Each segment is one of the two `Sidereon.GNSS.ReducedOrbit` models, selected with the
  same `:model` option:

    * `:circular_secular` (the **default**) - a circular orbit;
    * `:eccentric_secular` - recovers the radial `a·e` signal.

  See `Sidereon.GNSS.ReducedOrbit` for the per-model details.

  ## Size / residual tradeoff

  Storage grows roughly linearly with segment count. Shorter segments cost more
  memory but keep queries closer to a fit window center.

  ## Segment selection

  Segments tile `[t0, t1]` with no gaps. A query epoch is resolved by finding the
  segment whose half-open interval `[seg_t0, seg_t1)` contains it; the final
  segment is treated as inclusive at the very end so the exact end-of-span epoch
  resolves to the last segment. An epoch exactly on an interior boundary resolves
  to the **later** segment (where it is the in-window start), which is
  deterministic. Selection is `O(segments)`; the segment count is modest and the
  ordered list is binary-searchable if it ever grows large. An epoch before `t0`
  or after `t1` returns `{:error, :out_of_range}`.

  """
  alias Sidereon.GNSS.Core.Epoch
  alias Sidereon.GNSS.Core.Native
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

  # ------------------------------------------------------------------------
  # Fit
  # ------------------------------------------------------------------------

  @doc """
  Fit a piecewise model over a span, one contiguous `Sidereon.GNSS.ReducedOrbit` segment
  per `:segment_s` seconds.

  Accepts a list of `{epoch, {x_m, y_m, z_m}}` ECEF samples.

  ## Options

    * `:window` - `{t0, t1}` epochs bounding the full span (`t1` strictly after
      `t0`, else `:invalid_window`)
    * `:segment_s` - positive segment length in seconds, e.g. `7200`
      (non-positive → `:invalid_segment`)
    * `:model` - `:circular_secular` (**default**) or `:eccentric_secular`
    * `:time_scale` - the scale the sample epochs are in

  Segments are contiguous (`seg_t1` of one is `seg_t0` of the next); the final
  segment may be shorter. A `:segment_s` at least the full span yields a single
  segment equal to the whole window (piecewise with one segment ≡ single).

  Returns `{:ok, %Sidereon.GNSS.ReducedOrbit.Piecewise{}}` or a tagged error. The error
  set is exactly the single model's fit errors (`{:too_few_samples, got, req}`,
  `:invalid_window`, `{:unsupported_model, m}`, `{:unsupported_source_frame, f}`,
  `{:unsupported_time_scale, s}`, `:transform_unavailable`, …) plus
  `:invalid_segment`. A too-few-samples failure on a non-terminal segment is
  surfaced (a genuinely under-covered interior span is an error, not a silent
  hole); only the terminal short segment may be dropped. If nothing fits at all,
  `{:error, {:too_few_samples, 0, #{@min_samples}}}`.
  """
  @spec fit([{epoch(), {number(), number(), number()}}], keyword()) :: {:ok, t()} | {:error, term()}
  def fit(samples, opts \\ []) when is_list(samples) do
    with {:ok, {t0, t1}} <- Epoch.fetch_window(opts),
         {:ok, segment_s} <- validate_segment_s(Keyword.get(opts, :segment_s)),
         {:ok, meta} <- sample_meta(samples, opts) do
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

  defp sample_meta(samples, opts) when is_list(samples) do
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
       }}
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
         [a_m, e, i_rad, raan, raan_rate, raan_rate_j2, arg_lat, n, h, k, arg_perigee_rad],
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
       arg_perigee_rad: arg_perigee_rad,
       fit: fit_stats
     }}
  end

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
  # Drift
  # ------------------------------------------------------------------------

  @doc """
  Evaluate the piecewise model error against truth samples.

  Returns

      {:ok, %{per_epoch: [%{epoch:, error_m:}], max_m:, rms_m:, threshold_horizon:,
              requested:, used:}}

  matching the single-segment `Sidereon.GNSS.ReducedOrbit.drift/3` report. Epochs outside
  the model's span are skipped (counted in `requested`, not `used`).
  `threshold_horizon` is the first epoch the ECEF error exceeds `:threshold_m`
  (or `nil`).
  """
  @spec drift(t(), [{epoch(), {number(), number(), number()}}], keyword()) :: {:ok, map()} | {:error, term()}

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
  # Helpers
  # ------------------------------------------------------------------------

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
