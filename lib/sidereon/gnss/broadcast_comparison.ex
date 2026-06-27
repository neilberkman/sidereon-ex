defmodule Sidereon.GNSS.BroadcastComparison do
  @moduledoc """
  Broadcast-ephemeris accuracy: compare a broadcast navigation product against a
  precise SP3 product over a window.

  This is the standard broadcast-orbit / clock accuracy check (the orbit and clock
  pieces of the signal-in-space range error, SISRE). For each satellite at each
  epoch it differences the broadcast-evaluated ECEF position and clock against the
  precise SP3 values, decomposes the position error into radial / along-track /
  cross-track (RAC) components, and summarizes the differences as RMS and maximum
  statistics per satellite and overall.

  Both products are evaluated through `Sidereon.GNSS.Ephemeris`, so the frame
  (ITRF/IGS ECEF, meters), the time scale (GPST), and the clock sign convention
  (positive = satellite clock ahead of system time) are exactly as documented
  there. Only epochs where **both** sources return a valid state contribute to the
  statistics; an epoch missing from either product is skipped, never extrapolated.

  ## RAC frame

  The radial/along-track/cross-track unit vectors are built from the **precise**
  state: radial along the position vector, cross-track along the orbital angular
  momentum `r x v`, and along-track completing the right-handed triad. The SP3
  position/clock interpolation does not expose a velocity, so the velocity is
  derived by a centered finite difference of the precise position
  (`(r(t+dt) - r(t-dt)) / 2dt`, falling back to a one-sided difference at a window
  edge). The position-difference vector `broadcast - precise` is projected onto
  this triad.

  ## Expected magnitudes

  GPS LNAV broadcast orbits differ from IGS precise orbits at roughly the 1-2 m
  RMS level (3D), dominated by the along-track and radial components; Galileo and
  BeiDou MEO are comparable. A result far outside this band (tens of meters or
  more) indicates a parse or evaluation defect rather than normal broadcast error.

  The broadcast models follow IS-GPS-200 (GPS LNAV), the Galileo OS-SIS-ICD, and
  the BeiDou BDS-SIS-ICD; the precise product is SP3-c / SP3-d (IGS).

  ## Example

      {:ok, broadcast} = Sidereon.GNSS.Broadcast.load("BRDC.rnx")
      {:ok, sp3} = Sidereon.GNSS.SP3.load("igs.sp3")

      report =
        Sidereon.GNSS.BroadcastComparison.compare(broadcast, sp3, ["G01", "E11"], %{
          from: ~N[2020-06-25 02:00:00],
          to: ~N[2020-06-25 04:00:00],
          step_s: 300
        })

      report.overall.orbit_3d_rms_m   # 3D orbit RMS over all satellites, meters
      report.per_satellite["G01"].radial_rms_m

  ## Broadcast and precise products on a sample day

  Comparing the GPS LNAV broadcast message against the GBM precise SP3 product for
  2020 day-of-year 177, all GPS satellites over a multi-hour window at a 15 min
  step, gives an overall 3D orbit RMS of about **1.5 m** (max ~4 m), split as
  roughly 1.1 m radial / 0.9 m along-track / 0.5 m cross-track, the expected GPS
  broadcast accuracy. The raw clock differences (`clock_rms_m`) are larger
  (several meters) because the broadcast and precise clocks are referenced to
  different time datums, which differ by a common per-epoch offset that drifts
  over the day. `clock_datum_removed_rms_m` removes that common offset (the
  per-epoch median over satellites) and reports the actual signal-in-space clock
  error, which is several times smaller.
  The same call works against a broadcast product with no change of shape, so
  `mix gnss.broadcast_diff --nav BRDC.rnx --sp3 igs.sp3 --from ... --to ...`
  prints this table from the command line.

  The orbit/clock differencing, RAC decomposition, finite-difference velocity, and
  the RMS/median/datum statistics are computed in the Rust core; this module
  validates inputs, marshals the per-epoch evaluation keys across the NIF, and
  rebuilds the public report.
  """

  alias Sidereon.GNSS.Broadcast
  alias Sidereon.GNSS.Ephemeris
  alias Sidereon.GNSS.SP3
  alias Sidereon.GNSS.Time
  alias Sidereon.NIF

  defmodule Stats do
    @moduledoc """
    Orbit and clock difference statistics for one satellite (or the overall set).

    All values are meters except `count` (the number of compared epochs).
    `orbit_3d_rms_m` / `orbit_3d_max_m` are the Euclidean position-difference
    magnitudes. `radial_*`, `along_*`, `cross_*` are the RMS and max of the signed
    RAC components of the position difference (`broadcast - precise`).
    `clock_rms_m` / `clock_max_m` are the **raw** satellite-clock differences
    scaled to meters by the speed of light; they are `nil` when neither product
    carried a clock estimate for any compared epoch. They are dominated by the
    per-epoch common reference-clock offset between the two products' time
    datums. `clock_datum_removed_rms_m` / `clock_datum_removed_max_m` are the
    same differences after that per-epoch common offset (the median over all
    satellites at the epoch) is removed, the actual signal-in-space clock error
    (the SISRE clock term), typically several times smaller than the raw value.
    """
    @enforce_keys [
      :count,
      :orbit_3d_rms_m,
      :orbit_3d_max_m,
      :radial_rms_m,
      :radial_max_m,
      :along_rms_m,
      :along_max_m,
      :cross_rms_m,
      :cross_max_m,
      :clock_rms_m,
      :clock_max_m,
      :clock_datum_removed_rms_m,
      :clock_datum_removed_max_m
    ]
    defstruct [
      :count,
      :orbit_3d_rms_m,
      :orbit_3d_max_m,
      :radial_rms_m,
      :radial_max_m,
      :along_rms_m,
      :along_max_m,
      :cross_rms_m,
      :cross_max_m,
      :clock_rms_m,
      :clock_max_m,
      :clock_datum_removed_rms_m,
      :clock_datum_removed_max_m
    ]

    @type t :: %__MODULE__{
            count: non_neg_integer(),
            orbit_3d_rms_m: float() | nil,
            orbit_3d_max_m: float() | nil,
            radial_rms_m: float() | nil,
            radial_max_m: float() | nil,
            along_rms_m: float() | nil,
            along_max_m: float() | nil,
            cross_rms_m: float() | nil,
            cross_max_m: float() | nil,
            clock_rms_m: float() | nil,
            clock_max_m: float() | nil,
            clock_datum_removed_rms_m: float() | nil,
            clock_datum_removed_max_m: float() | nil
          }
  end

  defmodule Report do
    @moduledoc """
    The result of a broadcast and precise product comparison.

    `per_satellite` maps each satellite id to its `Stats`; `overall` aggregates
    every compared epoch across all satellites. `missing` lists `{satellite_id,
    count}` pairs counting epochs that were skipped because one or both products
    had no valid state there.
    """
    @enforce_keys [:per_satellite, :overall, :missing]
    defstruct [:per_satellite, :overall, :missing]

    @type t :: %__MODULE__{
            per_satellite: %{String.t() => Stats.t()},
            overall: Stats.t(),
            missing: [{String.t(), non_neg_integer()}]
          }
  end

  @doc """
  Compare a broadcast product against a precise SP3 product over `window`.

  `broadcast` is an `Sidereon.GNSS.Broadcast` handle and `precise` an
  `Sidereon.GNSS.SP3` handle for the same day; `sat_ids` is a list of canonical
  RINEX tokens; `window` is the `Sidereon.GNSS.Ephemeris` window map (`:from`,
  `:to`, `:step_s`). Returns an `Sidereon.GNSS.BroadcastComparison.Report`.

  The window should sit within both the SP3 file span and the broadcast records'
  fit intervals; epochs missing from either product are counted in
  `report.missing` and excluded from the statistics.
  """
  @spec compare(Broadcast.t(), SP3.t(), [String.t()], Ephemeris.window()) :: Report.t()
  def compare(%Broadcast{handle: broadcast}, %SP3{handle: precise}, sat_ids, window)
      when is_list(sat_ids) do
    epochs = window_epochs(window)
    half = round(window.step_s / 2.0)
    epoch_keys = Enum.map(epochs, &epoch_keys(&1, half))

    {overall, per_satellite, missing} =
      NIF.broadcast_comparison(broadcast, precise, sat_ids, epoch_keys, half / 1.0)

    %Report{
      overall: decode_stats(overall),
      per_satellite: Map.new(per_satellite, fn {sat, stats} -> {sat, decode_stats(stats)} end),
      missing: Enum.map(missing, fn {sat, count} -> {sat, count} end)
    }
  end

  # The per-epoch evaluation keys the core consumes: the broadcast query is a
  # continuous J2000 second (the same value `Sidereon.GNSS.Broadcast.position`
  # marshals), the precise queries are split Julian dates for the epoch and the
  # +/-half-step velocity finite-difference neighbours.
  defp epoch_keys(epoch, half) do
    {jd_whole, jd_fraction} = Time.epoch_to_split_jd(epoch)
    {jd_whole_p, jd_fraction_p} = Time.epoch_to_split_jd(NaiveDateTime.add(epoch, half, :second))
    {jd_whole_m, jd_fraction_m} = Time.epoch_to_split_jd(NaiveDateTime.add(epoch, -half, :second))
    {:ok, broadcast_j2000_s} = Time.epoch_to_j2000_seconds_fractional(epoch)

    {broadcast_j2000_s, jd_whole, jd_fraction, jd_whole_p, jd_fraction_p, jd_whole_m,
     jd_fraction_m}
  end

  defp decode_stats(
         {count,
          [
            orbit_3d_rms_m,
            orbit_3d_max_m,
            radial_rms_m,
            radial_max_m,
            along_rms_m,
            along_max_m,
            cross_rms_m,
            cross_max_m,
            clock_rms_m,
            clock_max_m,
            clock_datum_removed_rms_m,
            clock_datum_removed_max_m
          ]}
       ) do
    %Stats{
      count: count,
      orbit_3d_rms_m: orbit_3d_rms_m,
      orbit_3d_max_m: orbit_3d_max_m,
      radial_rms_m: radial_rms_m,
      radial_max_m: radial_max_m,
      along_rms_m: along_rms_m,
      along_max_m: along_max_m,
      cross_rms_m: cross_rms_m,
      cross_max_m: cross_max_m,
      clock_rms_m: clock_rms_m,
      clock_max_m: clock_max_m,
      clock_datum_removed_rms_m: clock_datum_removed_rms_m,
      clock_datum_removed_max_m: clock_datum_removed_max_m
    }
  end

  defp window_epochs(%{from: from, to: to, step_s: step_s}) do
    total_s = NaiveDateTime.diff(to, from, :second)
    n = div(total_s, step_s)
    for i <- 0..n//1, do: NaiveDateTime.add(from, i * step_s, :second)
  end
end
