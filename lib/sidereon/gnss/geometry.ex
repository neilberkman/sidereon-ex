defmodule Sidereon.GNSS.Geometry do
  @moduledoc """
  Satellite-geometry and mission-planning layer above the GNSS observables:
  from a static receiver position and a precise (SP3) ephemeris, answer the
  three planning questions: which satellites are visible, how good is the
  geometry (dilution of precision), and when does each satellite rise and set.

  This module solves no positioning problem; it reads satellite states through
  `Sidereon.GNSS.Observables` and applies standard textbook GNSS geometry.

  ## Visibility

  A satellite is *visible* when its topocentric elevation is at or above an
  elevation mask. Azimuth and elevation come from `Sidereon.GNSS.Observables`, which
  rotates the receiver-to-satellite line of sight into the local east-north-up
  (ENU) frame at the receiver's geodetic latitude/longitude.

  ## Dilution of precision (DOP)

  Dilution of precision summarises how the receiver-to-satellite geometry maps
  range-measurement noise into solution uncertainty. From a design (geometry)
  matrix `G` whose rows are the line-of-sight unit vectors plus a receiver-clock
  column, and an optional diagonal weight matrix `W`, the cofactor matrix is

      Q = (G^T W G)^-1

  a 4x4 symmetric matrix ordered `[x, y, z, clock]`. The position block is in
  ECEF metres and the clock state is in the same length unit as the ranges.

  ### Sign and column convention

  Each row is `[-e_x, -e_y, -e_z, 1]`, where `e` is the **ECEF** receiver-to-
  satellite unit line of sight (the partial derivative of the predicted range
  with respect to the receiver position is `-e`; the clock column is `+1`). The
  geometry matrix is therefore built in ECEF, exactly as
  `Sidereon.GNSS.Positioning` builds it; the horizontal/vertical split is taken
  *after* inverting, by rotating the 3x3 position block into the local ENU frame
  at the receiver's geodetic latitude/longitude:

      R = [[-sin l,         cos l,        0   ],
           [-sin p cos l,  -sin p sin l,  cos p],
           [ cos p cos l,   cos p sin l,  sin p]]

  with `p` the geodetic latitude and `l` the longitude (radians); the rotated
  block is `Q_enu = R Q_pos R^T`. The DOP scalars are then

    * `pdop = sqrt(qE + qN + qU)` (the ENU position block),
    * `hdop = sqrt(qE + qN)`,
    * `vdop = sqrt(qU)`,
    * `tdop = sqrt(Q[3][3])` (the clock variance),
    * `gdop = sqrt(Q[0][0] + Q[1][1] + Q[2][2] + Q[3][3])` (the cofactor trace,
      which is rotation invariant, so it equals the ENU-frame trace).

  ### Weights

  The default is the unweighted geometric DOP (`W = I`), the standard textbook
  cofactor `(G^T G)^-1`. An elevation weighting (`weights: :elevation`, with
  `w = sin^2(elevation)`) is also available; it reproduces the weighting that a
  least-squares positioning solve applies, and is what lets the DOP here be
  cross-checked component-for-component against `Sidereon.GNSS.Positioning`'s
  reported DOP for the same satellite set and epoch.

  ### Limitation

  This is a single-receiver-clock (single-system) DOP. A mixed-constellation
  geometry with one receiver clock per system (extra clock columns) is out of
  scope; restrict the visible set to one system (e.g. `systems: ["G"]`) for a
  well-posed DOP.

  ## Passes

  A *pass* is a contiguous interval over which a satellite stays above the mask.
  Rise and set are detected by threshold-crossing on the sampled elevation, so
  they are resolved only to the sampling step `step_seconds`: a finer step gives
  finer rise/set epochs.
  """

  alias Sidereon.GNSS.Core.Types
  alias Sidereon.GNSS.{SP3, Time}
  alias Sidereon.NIF

  @default_mask_deg 5.0

  @type receiver ::
          {number(), number(), number()} | %{x_m: number(), y_m: number(), z_m: number()}

  @type visible_sat :: %{
          satellite_id: String.t(),
          elevation_deg: float(),
          azimuth_deg: float()
        }

  @type dop_result :: %{
          gdop: float(),
          pdop: float(),
          hdop: float(),
          vdop: float(),
          tdop: float(),
          n_satellites: non_neg_integer(),
          satellites: [String.t()]
        }

  @type option_error :: {:invalid_option, atom()}

  @type geometry_error ::
          :invalid_receiver
          | :outside_coverage
          | :too_few_satellites
          | :singular_geometry
          | option_error()

  # --- visibility -----------------------------------------------------------

  @doc """
  List the satellites visible from `receiver` at `epoch`, above the elevation
  mask, sorted by elevation descending.

  ## Options

    * `:elevation_mask_deg` - minimum elevation in degrees (default `5.0`); a
      satellite is included iff its elevation is at or above this value.
    * `:systems` - keep only these constellations, given as leading-letter
      strings (e.g. `["G"]` for GPS, `["G", "E"]` for GPS + Galileo). Default:
      keep all systems.
    * `:extrapolate` - allow evaluation outside the parsed SP3 coverage.
      Default `false`.

  Returns a list of `%{satellite_id, elevation_deg, azimuth_deg}` or a tagged
  error for malformed input. Never raises.
  """
  @spec visible(SP3.t(), receiver(), NaiveDateTime.t(), keyword()) ::
          [visible_sat()] | {:error, :invalid_receiver | :outside_coverage | option_error()}
  def visible(%SP3{handle: handle} = sp3, receiver, %NaiveDateTime{} = epoch, opts \\ []) do
    with {:ok, rx} <- Types.normalize_ecef(receiver),
         {:ok, {elevation_mask_deg, systems, extrapolate?}} <- visibility_options(opts),
         :ok <- validate_epoch_coverage(sp3, epoch, extrapolate?) do
      {jd_whole, jd_fraction} = Time.epoch_to_split_jd(epoch)

      handle
      |> NIF.sp3_geometry_visible(
        rx,
        jd_whole,
        jd_fraction,
        elevation_mask_deg,
        systems
      )
      |> Enum.map(fn {sat_id, elevation_deg, azimuth_deg} ->
        %{
          satellite_id: sat_id,
          elevation_deg: elevation_deg,
          azimuth_deg: azimuth_deg
        }
      end)
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  # --- dilution of precision ------------------------------------------------

  @doc """
  Dilution of precision for the visible satellites at `epoch`.

  Builds the geometry matrix from the visible satellites' ECEF line-of-sight
  unit vectors (rows `[-e_x, -e_y, -e_z, 1]`), forms `Q = (G^T W G)^-1`, rotates
  the position block into ENU, and returns all five DOP scalars plus the
  satellite count and ids.

  ## Options

  In addition to the `visible/4` options (`:elevation_mask_deg`, `:systems`):

    * `:weights` - `:unit` (default, `W = I`, the standard geometric DOP) or
      `:elevation` (`w = sin^2(elevation)`, the least-squares weighting).
    * `:light_time` - apply the light-time / Sagnac line-of-sight corrections
      when forming the geometry (default `false`, the planning value). Set
      `true` to match a converged positioning geometry exactly.
    * `:satellites` - an explicit list of satellite ids to use instead of the
      visibility scan (still subject to predicting successfully); useful to pin
      the geometry to a known set.

  Returns `%{gdop, pdop, hdop, vdop, tdop, n_satellites, satellites}` or a
  tagged error: `{:error, :invalid_receiver}`, `{:error, :too_few_satellites}`
  (fewer than four usable directions), `{:error, :singular_geometry}`, or
  `{:error, :outside_coverage}`, or `{:error, {:invalid_option, key}}`. Never
  raises.
  """
  @spec dop(SP3.t(), receiver(), NaiveDateTime.t(), keyword()) ::
          dop_result() | {:error, geometry_error()}
  def dop(%SP3{handle: handle} = sp3, receiver, %NaiveDateTime{} = epoch, opts \\ []) do
    with {:ok, rx} <- Types.normalize_ecef(receiver),
         {:ok, dop_opts} <- dop_options(opts) do
      {jd_whole, jd_fraction} = Time.epoch_to_split_jd(epoch)

      {elevation_mask_deg, systems, weighting, light_time?, use_explicit?, satellites,
       extrapolate?} = dop_opts

      with :ok <- validate_epoch_coverage(sp3, epoch, extrapolate?) do
        case NIF.sp3_geometry_dop(
               handle,
               rx,
               jd_whole,
               jd_fraction,
               elevation_mask_deg,
               systems,
               weighting,
               light_time?,
               use_explicit?,
               satellites
             ) do
          {:ok, {{gdop, pdop, hdop, vdop, tdop}, ids}} ->
            %{
              gdop: gdop,
              pdop: pdop,
              hdop: hdop,
              vdop: vdop,
              tdop: tdop,
              n_satellites: length(ids),
              satellites: ids
            }

          {:error, _} = error ->
            error
        end
      end
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  # --- time series ----------------------------------------------------------

  @doc """
  Per-epoch dilution of precision over a time window.

  Samples `{t0, t1}` (inclusive of `t0`, up to and including `t1`) every
  `step_seconds` and computes `dop/4` at each sample. Returns a list of
  `%{epoch, gdop, pdop, hdop, vdop, tdop, n_satellites, satellites}` for the
  epochs whose geometry yields a finite DOP; epochs with too few satellites or a
  singular geometry are skipped. An empty or inverted window returns `[]`.

  `opts` are the `dop/4` options. Malformed receivers, options, or windows
  outside the SP3 coverage return tagged errors before calling the native
  geometry code.
  """
  @spec dop_series(
          SP3.t(),
          receiver(),
          {NaiveDateTime.t(), NaiveDateTime.t()},
          pos_integer(),
          keyword()
        ) ::
          [map()] | {:error, geometry_error()}
  def dop_series(%SP3{handle: handle} = sp3, receiver, {t0, t1}, step_seconds, opts \\ []) do
    with {:ok, rx} <- Types.normalize_ecef(receiver),
         {:ok, step_seconds} <- validate_step_seconds(step_seconds),
         {:ok, dop_opts} <- dop_options(opts) do
      {start_jd_whole, start_jd_fraction} = Time.epoch_to_split_jd(t0)
      {end_jd_whole, end_jd_fraction} = Time.epoch_to_split_jd(t1)

      {elevation_mask_deg, systems, weighting, light_time?, use_explicit?, satellites,
       extrapolate?} = dop_opts

      with :ok <- validate_window_coverage(sp3, {t0, t1}, extrapolate?) do
        handle
        |> NIF.sp3_geometry_dop_series(
          rx,
          start_jd_whole,
          start_jd_fraction,
          end_jd_whole,
          end_jd_fraction,
          step_seconds,
          elevation_mask_deg,
          systems,
          weighting,
          light_time?,
          use_explicit?,
          satellites
        )
        |> Enum.map(fn {step_index, {gdop, pdop, hdop, vdop, tdop}, ids} ->
          %{
            epoch: sample_epoch(t0, step_index, step_seconds),
            gdop: gdop,
            pdop: pdop,
            hdop: hdop,
            vdop: vdop,
            tdop: tdop,
            n_satellites: length(ids),
            satellites: ids
          }
        end)
      end
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Per-epoch count of visible satellites over a time window.

  Samples `{t0, t1}` every `step_seconds` and returns a list of
  `%{epoch, n_visible}`. An empty or inverted window returns `[]`. `opts` are the
  `visible/4` options. Malformed receivers or options return tagged errors
  before calling the native geometry code. Windows outside the SP3 coverage
  return `{:error, :outside_coverage}` unless `extrapolate: true` is set.
  """
  @spec visibility_series(
          SP3.t(),
          receiver(),
          {NaiveDateTime.t(), NaiveDateTime.t()},
          pos_integer(),
          keyword()
        ) ::
          [%{epoch: NaiveDateTime.t(), n_visible: non_neg_integer()}]
          | {:error, :invalid_receiver | :outside_coverage | option_error()}
  def visibility_series(%SP3{handle: handle} = sp3, receiver, {t0, t1}, step_seconds, opts \\ []) do
    with {:ok, rx} <- Types.normalize_ecef(receiver),
         {:ok, step_seconds} <- validate_step_seconds(step_seconds),
         {:ok, {elevation_mask_deg, systems, extrapolate?}} <- visibility_options(opts) do
      {start_jd_whole, start_jd_fraction} = Time.epoch_to_split_jd(t0)
      {end_jd_whole, end_jd_fraction} = Time.epoch_to_split_jd(t1)

      with :ok <- validate_window_coverage(sp3, {t0, t1}, extrapolate?) do
        handle
        |> NIF.sp3_geometry_visibility_series(
          rx,
          start_jd_whole,
          start_jd_fraction,
          end_jd_whole,
          end_jd_fraction,
          step_seconds,
          elevation_mask_deg,
          systems
        )
        |> Enum.map(fn {step_index, n_visible} ->
          %{epoch: sample_epoch(t0, step_index, step_seconds), n_visible: n_visible}
        end)
      end
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  # --- passes ---------------------------------------------------------------

  @doc """
  Rise / peak / set passes for each satellite over a time window.

  Samples `{t0, t1}` every `step_seconds` and, for each satellite, splits the
  samples into contiguous runs above the elevation mask. Each run is one pass:

      %{
        satellite_id: String.t(),
        rise_epoch: NaiveDateTime.t(),
        set_epoch: NaiveDateTime.t(),
        peak_elevation_deg: float(),
        peak_epoch: NaiveDateTime.t()
      }

  `rise_epoch` is the first sample above the mask and `set_epoch` the last; both
  are resolved only to the sampling step (the true crossing lies within one
  `step_seconds` of the reported epoch). A satellite already above the mask at
  `t0`, or still above it at `t1`, yields a pass clamped to the window. `opts`
  are the `visible/4` options. Malformed receivers, options, or windows outside
  the SP3 coverage return tagged errors before calling the native geometry code.
  """
  @spec passes(
          SP3.t(),
          receiver(),
          {NaiveDateTime.t(), NaiveDateTime.t()},
          pos_integer(),
          keyword()
        ) ::
          [map()] | {:error, :invalid_receiver | :outside_coverage | option_error()}
  def passes(%SP3{handle: handle} = sp3, receiver, {t0, t1}, step_seconds, opts \\ []) do
    with {:ok, rx} <- Types.normalize_ecef(receiver),
         {:ok, step_seconds} <- validate_step_seconds(step_seconds),
         {:ok, {elevation_mask_deg, systems, extrapolate?}} <- visibility_options(opts) do
      {start_jd_whole, start_jd_fraction} = Time.epoch_to_split_jd(t0)
      {end_jd_whole, end_jd_fraction} = Time.epoch_to_split_jd(t1)

      with :ok <- validate_window_coverage(sp3, {t0, t1}, extrapolate?) do
        handle
        |> NIF.sp3_geometry_passes(
          rx,
          start_jd_whole,
          start_jd_fraction,
          end_jd_whole,
          end_jd_fraction,
          step_seconds,
          elevation_mask_deg,
          systems
        )
        |> Enum.map(fn {sat_id, rise_step, set_step, peak_elevation_deg, peak_step} ->
          %{
            satellite_id: sat_id,
            rise_epoch: sample_epoch(t0, rise_step, step_seconds),
            set_epoch: sample_epoch(t0, set_step, step_seconds),
            peak_elevation_deg: peak_elevation_deg,
            peak_epoch: sample_epoch(t0, peak_step, step_seconds)
          }
        end)
      end
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  # --- linear algebra (4x4 cofactor inverse) --------------------------------

  @doc """
  Explicit 4x4 cofactor (adjugate / determinant) inverse.

  `a` is a 4x4 matrix as a tuple of four 4-tuples. Returns `{:ok, inverse}` (same
  shape) or `:singular` when the determinant is exactly zero. The `(i, j)`
  cofactor is `(-1)^(i+j)` times the `(i, j)` minor; the inverse is the transpose
  of the cofactor matrix over the determinant, so `inv[j][i] = cofactor(i, j) / det`.
  """
  @spec inv4(tuple()) :: {:ok, tuple()} | :singular
  def inv4(a) do
    NIF.geometry_inv4(a)
  end

  # --- option and time helpers ---------------------------------------------

  defp dop_options(opts) do
    with {:ok, {elevation_mask_deg, systems, extrapolate?}} <- visibility_options(opts),
         {:ok, weighting} <- validate_weighting(Keyword.get(opts, :weights, :unit)),
         {:ok, light_time?} <- validate_boolean_option(opts, :light_time, false),
         {:ok, {use_explicit?, satellites}} <- validate_explicit_satellites(opts) do
      {:ok,
       {elevation_mask_deg, systems, weighting, light_time?, use_explicit?, satellites,
        extrapolate?}}
    end
  end

  defp visibility_options(opts) do
    with :ok <- validate_keyword_options(opts),
         {:ok, elevation_mask_deg} <-
           validate_number_option(
             Keyword.get(opts, :elevation_mask_deg, @default_mask_deg),
             :elevation_mask_deg
           ),
         {:ok, systems} <- validate_systems(Keyword.get(opts, :systems)),
         {:ok, extrapolate?} <- validate_boolean_option(opts, :extrapolate, false) do
      {:ok, {elevation_mask_deg, systems, extrapolate?}}
    end
  end

  defp validate_keyword_options(opts) when is_list(opts) do
    if Keyword.keyword?(opts), do: :ok, else: {:error, {:invalid_option, :opts}}
  end

  defp validate_keyword_options(_opts), do: {:error, {:invalid_option, :opts}}

  defp validate_number_option(value, _key) when is_number(value), do: {:ok, value / 1.0}
  defp validate_number_option(_value, key), do: {:error, {:invalid_option, key}}

  defp validate_systems(nil), do: {:ok, []}

  defp validate_systems(systems) when is_list(systems) do
    if Enum.all?(systems, &is_binary/1) do
      {:ok, systems}
    else
      {:error, {:invalid_option, :systems}}
    end
  end

  defp validate_systems(_systems), do: {:error, {:invalid_option, :systems}}

  defp validate_weighting(:unit), do: {:ok, "unit"}
  defp validate_weighting(:elevation), do: {:ok, "elevation"}
  defp validate_weighting(_weighting), do: {:error, {:invalid_option, :weights}}

  defp validate_boolean_option(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_boolean(value) -> {:ok, value}
      _value -> {:error, {:invalid_option, key}}
    end
  end

  defp validate_explicit_satellites(opts) do
    case Keyword.fetch(opts, :satellites) do
      {:ok, satellites} when is_list(satellites) ->
        if Enum.all?(satellites, &is_binary/1) do
          {:ok, {true, satellites}}
        else
          {:error, {:invalid_option, :satellites}}
        end

      {:ok, _satellites} ->
        {:error, {:invalid_option, :satellites}}

      :error ->
        {:ok, {false, []}}
    end
  end

  defp validate_step_seconds(step_seconds) when is_integer(step_seconds) and step_seconds > 0,
    do: {:ok, step_seconds}

  defp validate_step_seconds(_step_seconds), do: {:error, {:invalid_option, :step_seconds}}

  defp validate_epoch_coverage(_sp3, _epoch, true), do: :ok

  defp validate_epoch_coverage(sp3, epoch, false) do
    if SP3.covers_epoch?(sp3, epoch), do: :ok, else: {:error, :outside_coverage}
  end

  defp validate_window_coverage(_sp3, _window, true), do: :ok

  defp validate_window_coverage(sp3, {t0, t1} = window, false) do
    cond do
      NaiveDateTime.after?(t0, t1) -> :ok
      SP3.covers_window?(sp3, window) -> :ok
      true -> {:error, :outside_coverage}
    end
  end

  defp sample_epoch(t0, step_index, step_seconds) do
    NaiveDateTime.add(t0, step_index * step_seconds, :second)
  end
end
