defmodule Sidereon.GNSS.SolutionReport do
  @moduledoc """
  A consolidated, read-only diagnostic for a single-point-positioning result.

  Given an already-computed `Sidereon.GNSS.Positioning.Solution`, an ephemeris
  source, and the receive epoch, `build/4` assembles one report that explains
  the solved position: the per-satellite sky geometry (elevation / azimuth),
  the post-fit pseudorange residuals, the RAIM integrity verdict and per-
  satellite normalized residuals, and a top-level solution summary including the
  dilution-of-precision scalars and the residual RMS.

  This module performs no estimation. Every value is read straight from an
  existing primitive, so each field is traceable to its source:

    * `residual_m` is copied from `Solution.residuals_m`, paired with
      `Solution.used_sats` by index (the same pairing `Sidereon.GNSS.QC.raim/2`
      uses);
    * `normalized_residual` is copied from `Sidereon.GNSS.QC.raim/2`'s
      `normalized_residuals` map;
    * `elevation_deg` / `azimuth_deg` come from
      `Sidereon.GNSS.Observables.predict/5` evaluated at the **solved** position,
      with `predict`'s defaults (light-time and Sagnac corrections on);
    * `dop`, `geodetic`, the ECEF position, `metadata`, and every integrity
      scalar are passed through verbatim;
    * `residual_rms_m` is the only newly derived scalar: the root mean square
      of the post-fit residuals over the used satellites.

  ## Row ordering

  Satellite rows are emitted **used satellites first, then rejected
  satellites**; within each group rows are sorted by `elevation_deg`
  descending, with `nil` elevation last (a rejected satellite with no ephemeris
  cannot be located in the sky).

  ## Example

      {:ok, solution} = Sidereon.GNSS.Positioning.solve(sp3, observations, epoch)
      {:ok, report} = Sidereon.GNSS.SolutionReport.build(solution, sp3, epoch)

      report.summary.residual_rms_m
      report.summary.integrity.fault_detected?

      report |> Sidereon.GNSS.SolutionReport.format() |> Enum.each(&IO.puts/1)
  """

  alias Sidereon.GNSS.Observables
  alias Sidereon.GNSS.Positioning.Solution
  alias Sidereon.GNSS.QC
  alias Sidereon.GNSS.SP3

  @enforce_keys [:summary, :satellites]
  defstruct [:summary, :satellites]

  @type satellite_row :: %{
          satellite_id: String.t(),
          used?: boolean(),
          elevation_deg: float() | nil,
          azimuth_deg: float() | nil,
          residual_m: float() | nil,
          normalized_residual: float() | nil,
          rejected_reason: atom() | nil
        }

  @type summary :: %{
          position: %{ecef: map(), geodetic: map() | nil},
          n_used: non_neg_integer(),
          n_rejected: non_neg_integer(),
          dop: map() | nil,
          residual_rms_m: float(),
          integrity: map(),
          metadata: map(),
          status: atom()
        }

  @type t :: %__MODULE__{summary: summary(), satellites: [satellite_row()]}

  @doc """
  Assemble a `%Sidereon.GNSS.SolutionReport{}` from a solved result, its ephemeris
  source, and the receive epoch.

  Returns `{:ok, report}` on success or a tagged `{:error, reason}` for a
  malformed solution, source, or epoch. Never raises.

  ## Options

    * `:raim` - a keyword list forwarded verbatim to `Sidereon.GNSS.QC.raim/2`
      (supports `:p_fa`, `:weights`, `:n_systems`).
    * `:weights`, `:p_fa` - convenience top-level options merged into the `:raim`
      options. A value given here takes precedence over the same key inside
      `:raim`.

  The integrity block and per-satellite normalized residuals come from the
  single `Sidereon.GNSS.QC.raim/2` call those options drive, so the report cannot
  diverge from RAIM.
  """
  @spec build(Solution.t(), SP3.t(), NaiveDateTime.t(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def build(solution, source, epoch, opts \\ [])

  def build(%Solution{} = solution, %SP3{} = source, %NaiveDateTime{} = epoch, opts)
      when is_list(opts) do
    raim_opts =
      opts
      |> Keyword.get(:raim, [])
      |> Keyword.merge(Keyword.take(opts, [:weights, :p_fa]))

    raim = QC.raim(solution, raim_opts)

    residual_by_sat = Map.new(Enum.zip(solution.used_sats, solution.residuals_m))

    used_rows =
      Enum.map(solution.used_sats, fn sat ->
        {el, az} = sky(source, sat, solution.position, epoch)

        %{
          satellite_id: sat,
          used?: true,
          elevation_deg: el,
          azimuth_deg: az,
          residual_m: Map.get(residual_by_sat, sat),
          normalized_residual: Map.get(raim.normalized_residuals, sat),
          rejected_reason: nil
        }
      end)

    rejected_rows =
      Enum.map(solution.rejected_sats, fn {sat, reason} ->
        {el, az} = sky(source, sat, solution.position, epoch)

        %{
          satellite_id: sat,
          used?: false,
          elevation_deg: el,
          azimuth_deg: az,
          residual_m: nil,
          normalized_residual: nil,
          rejected_reason: reason
        }
      end)

    satellites = sort_rows(used_rows) ++ sort_rows(rejected_rows)

    summary = %{
      position: %{ecef: solution.position, geodetic: solution.geodetic},
      n_used: length(solution.used_sats),
      n_rejected: length(solution.rejected_sats),
      dop: solution.dop,
      residual_rms_m: residual_rms(solution.residuals_m),
      integrity:
        Map.take(raim, [
          :fault_detected?,
          :test_statistic,
          :threshold,
          :dof,
          :testable?,
          :worst_sat
        ]),
      metadata: solution.metadata,
      status: Map.get(solution.metadata || %{}, :status)
    }

    {:ok, %__MODULE__{summary: summary, satellites: satellites}}
  rescue
    e -> {:error, {:report_failed, e}}
  end

  def build(solution, _source, _epoch, _opts) when not is_struct(solution, Solution),
    do: {:error, :invalid_solution}

  def build(_solution, source, _epoch, _opts) when not is_struct(source, SP3),
    do: {:error, :invalid_source}

  def build(_solution, _source, epoch, _opts) when not is_struct(epoch, NaiveDateTime),
    do: {:error, :invalid_epoch}

  def build(_solution, _source, _epoch, _opts), do: {:error, :invalid_arguments}

  @doc """
  Render an already-built report as a deterministic list of human-readable
  lines: a summary header followed by one line per satellite row, in the
  report's row order.

  Pure formatting; it performs no new computation and calls no primitive.
  """
  @spec format(t()) :: [String.t()]
  def format(%__MODULE__{summary: summary, satellites: satellites}) do
    %{ecef: ecef} = summary.position

    header = [
      "Position solve diagnostic",
      "  ECEF (m): x=#{fmt(ecef.x_m)} y=#{fmt(ecef.y_m)} z=#{fmt(ecef.z_m)}",
      "  geodetic: #{fmt_geodetic(summary.position.geodetic)}",
      "  satellites: #{summary.n_used} used, #{summary.n_rejected} rejected",
      "  dop: #{fmt_dop(summary.dop)}",
      "  residual RMS (m): #{fmt(summary.residual_rms_m)}",
      "  integrity: #{fmt_integrity(summary.integrity)}",
      "  status: #{inspect(summary.status)}",
      "  sat   used  el(deg)  az(deg)  resid(m)  norm  reason"
    ]

    rows = Enum.map(satellites, &format_row/1)

    header ++ rows
  end

  @doc """
  Alias for `format/1`.
  """
  @spec summary_lines(t()) :: [String.t()]
  def summary_lines(%__MODULE__{} = report), do: format(report)

  # --- helpers ---------------------------------------------------------------

  defp sky(source, sat, position, epoch) do
    case Observables.predict(source, sat, position, epoch) do
      {:ok, obs} -> {obs.elevation_deg, obs.azimuth_deg}
      {:error, _reason} -> {nil, nil}
    end
  end

  # RMS of the post-fit residuals over the used satellites. Defined precisely as
  # sqrt(mean of squared residuals); an empty residual list reports 0.0.
  defp residual_rms([]), do: 0.0

  defp residual_rms(residuals) do
    n = length(residuals)
    sum_sq = Enum.reduce(residuals, 0.0, fn r, acc -> acc + r * r end)
    :math.sqrt(sum_sq / n)
  end

  # Sort by elevation descending; nil elevation sorts last (stable within ties).
  defp sort_rows(rows) do
    Enum.sort_by(rows, fn row -> elevation_sort_key(row.elevation_deg) end)
  end

  defp elevation_sort_key(nil), do: {1, 0.0}
  defp elevation_sort_key(el), do: {0, -el}

  defp format_row(row) do
    [
      String.pad_trailing(row.satellite_id, 5),
      String.pad_trailing(if(row.used?, do: "yes", else: "no"), 5),
      String.pad_leading(fmt(row.elevation_deg), 8),
      String.pad_leading(fmt(row.azimuth_deg), 8),
      String.pad_leading(fmt(row.residual_m), 9),
      String.pad_leading(fmt(row.normalized_residual), 6),
      "  #{inspect(row.rejected_reason)}"
    ]
    |> Enum.join("  ")
  end

  defp fmt(nil), do: "-"
  defp fmt(v) when is_float(v), do: :erlang.float_to_binary(v, decimals: 4)
  defp fmt(v), do: to_string(v)

  defp fmt_geodetic(nil), do: "-"

  defp fmt_geodetic(%{lat_rad: lat, lon_rad: lon, height_m: h}) do
    "lat=#{fmt(lat)} rad lon=#{fmt(lon)} rad h=#{fmt(h)} m"
  end

  defp fmt_dop(nil), do: "-"

  defp fmt_dop(%{gdop: g, pdop: p, hdop: hd, vdop: vd, tdop: td}) do
    "gdop=#{fmt(g)} pdop=#{fmt(p)} hdop=#{fmt(hd)} vdop=#{fmt(vd)} tdop=#{fmt(td)}"
  end

  defp fmt_integrity(integrity) do
    "fault=#{integrity.fault_detected?} T=#{fmt(integrity.test_statistic)} " <>
      "thr=#{fmt(integrity.threshold)} dof=#{integrity.dof} " <>
      "testable=#{integrity.testable?} worst=#{inspect(integrity.worst_sat)}"
  end
end
