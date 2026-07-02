defmodule Sidereon.GNSS.Ephemeris do
  @moduledoc """
  A unified satellite-ephemeris sampling surface over precise SP3 products and
  broadcast navigation messages.

  `sample/3` evaluates a list of satellites across an epoch range at a fixed step
  and returns a tidy per-satellite, per-epoch table of ECEF position and satellite
  clock bias. The call is **identical** whether the source is an `Sidereon.GNSS.SP3`
  precise product or an `Sidereon.GNSS.Broadcast` navigation product, so a caller can
  swap precise for broadcast transparently; the dispatch is on the handle's type.

  The grid sampler delegates to the core `ephemeris::sample` API. The underlying
  products are parsed once into resource handles and reused across every cell; no
  file is re-read per epoch.

  The broadcast models follow IS-GPS-200 (GPS LNAV), the Galileo OS-SIS-ICD, and
  the BeiDou BDS-SIS-ICD; precise products are SP3-c / SP3-d (IGS).

  ## Frame, time, and sign conventions

    * **Frame:** position is ITRF/IGS-realization ECEF, in meters
      (`x_m`, `y_m`, `z_m`), the same frame both products evaluate in.
    * **Time:** every epoch is interpreted in **GPS time (GPST)**. No
      leap-second shifting is applied to the supplied epochs; the broadcast
      evaluator maps GPST onto each system's own scale (BDT for BeiDou,
      UTC-referenced for GLONASS) internally.
    * **Clock sign:** `clock_s` is the satellite clock offset in seconds, with a
      **positive value meaning the satellite clock is ahead of system time**. The
      pseudorange geometric correction is therefore `range + c * clock_s`. The SP3
      and broadcast paths share this convention (the broadcast value is the
      clock-polynomial total including the relativistic eccentricity term and the
      broadcast group delay).

  ## Gaps are explicit

  A cell whose satellite has no valid ephemeris at its epoch carries
  `status: :no_ephemeris` and `nil` position/clock fields. The sampler **never**
  extrapolates beyond a product's validity: an SP3 epoch outside the file's span,
  or a broadcast epoch outside any record's fit interval, is reported as a gap,
  not filled.

  ## Example

      {:ok, sp3} = Sidereon.GNSS.SP3.load("igs.sp3")

      rows =
        Sidereon.GNSS.Ephemeris.sample(sp3, ["G01", "E11"], %{
          from: ~N[2020-06-25 00:00:00],
          to: ~N[2020-06-25 01:00:00],
          step_s: 300
        })

      [%Sidereon.GNSS.Ephemeris.Row{} = row | _] = rows
      row.satellite_id   # "G01"
      row.status         # :ok | :no_ephemeris
      row.x_m            # ITRF/IGS ECEF X, meters (nil on a gap)
  """

  alias Sidereon.GNSS.Broadcast
  alias Sidereon.GNSS.SP3
  alias Sidereon.GNSS.Time
  alias Sidereon.NIF

  defmodule Row do
    @moduledoc """
    One sampled satellite state at one epoch in the unified ephemeris table.

    `satellite_id` is the canonical RINEX token (e.g. `"G01"`); `epoch` is the
    `NaiveDateTime` in GPST the cell was evaluated at. When `status` is `:ok`,
    `x_m`/`y_m`/`z_m` are the ITRF/IGS ECEF position in meters and `clock_s` is the
    satellite clock offset in seconds (positive = satellite clock ahead of system
    time, see `Sidereon.GNSS.Ephemeris`). When `status` is `:no_ephemeris` the source
    had no valid ephemeris at that epoch and the four value fields are `nil`; a
    gap is never extrapolated.
    """
    @enforce_keys [:satellite_id, :epoch, :status, :x_m, :y_m, :z_m, :clock_s]
    defstruct [:satellite_id, :epoch, :status, :x_m, :y_m, :z_m, :clock_s]

    @type t :: %__MODULE__{
            satellite_id: String.t(),
            epoch: NaiveDateTime.t(),
            status: :ok | :no_ephemeris,
            x_m: float() | nil,
            y_m: float() | nil,
            z_m: float() | nil,
            clock_s: float() | nil
          }
  end

  @typedoc """
  The sampling window: a `from`/`to` epoch pair (inclusive of `from`, and of `to`
  when it falls on a step boundary) and a positive `step_s` in seconds.
  """
  @type window :: %{
          required(:from) => NaiveDateTime.t(),
          required(:to) => NaiveDateTime.t(),
          required(:step_s) => pos_integer()
        }

  @typedoc "A parsed ephemeris source: a precise SP3 product or a broadcast product."
  @type source :: SP3.t() | Broadcast.t()

  @doc """
  Sample `sat_ids` across the `window` from a precise or broadcast source.

  `source` is a loaded `Sidereon.GNSS.SP3` or `Sidereon.GNSS.Broadcast` handle,
  with the same call shape for both. `sat_ids` is a list of canonical RINEX tokens
  (`"G01"`, `"E11"`, `"C06"`, `"R07"`). `window` is a map with `:from`, `:to`
  (`NaiveDateTime` in GPST), and `:step_s` (a positive integer number of seconds).

  Returns a flat list of `Sidereon.GNSS.Ephemeris.Row` structs, one per
  satellite-epoch cell, in `sat_ids` order then ascending epoch. A cell with no
  valid ephemeris carries `status: :no_ephemeris` and `nil` values; the handle is
  reused for every cell, so no file is re-read.

  Raises `ArgumentError` for a non-positive step or a window with `to` before
  `from`.
  """
  @spec sample(source(), [String.t()], window()) :: [Row.t()]
  def sample(source, sat_ids, %{from: from, to: to, step_s: step_s})
      when is_list(sat_ids) and is_integer(step_s) and step_s > 0 do
    if NaiveDateTime.before?(to, from) do
      raise ArgumentError, "window `to` (#{to}) precedes `from` (#{from})"
    end

    with {:ok, start_s} <- Time.epoch_to_j2000_seconds_fractional(from),
         {:ok, stop_s} <- Time.epoch_to_j2000_seconds_fractional(to) do
      source
      |> core_sample(sat_ids, start_s, stop_s, step_s / 1.0)
      |> Enum.map(&decode_row(&1, from, start_s))
    end
  end

  def sample(_source, _sat_ids, %{step_s: step_s}) do
    raise ArgumentError, "step_s must be a positive integer, got: #{inspect(step_s)}"
  end

  defp core_sample(%SP3{handle: handle}, sat_ids, start_s, stop_s, step_s) do
    NIF.ephemeris_sample_sp3(handle, sat_ids, start_s, stop_s, step_s)
  end

  defp core_sample(%Broadcast{handle: handle}, sat_ids, start_s, stop_s, step_s) do
    NIF.ephemeris_sample_broadcast(handle, sat_ids, start_s, stop_s, step_s)
  end

  defp decode_row(%{status: "valid", position_ecef_m: {x, y, z}} = row, from, start_s) do
    %Row{
      satellite_id: row.satellite_id,
      epoch: row_epoch(row.epoch_j2000_s, from, start_s),
      status: :ok,
      x_m: x,
      y_m: y,
      z_m: z,
      clock_s: row.clock_s
    }
  end

  defp decode_row(row, from, start_s) do
    %Row{
      satellite_id: row.satellite_id,
      epoch: row_epoch(row.epoch_j2000_s, from, start_s),
      status: :no_ephemeris,
      x_m: nil,
      y_m: nil,
      z_m: nil,
      clock_s: nil
    }
  end

  defp row_epoch(epoch_j2000_s, from, start_s) do
    offset_us = round((epoch_j2000_s - start_s) * 1_000_000)
    epoch = NaiveDateTime.add(from, offset_us, :microsecond)

    if rem(offset_us, 1_000_000) == 0 and elem(from.microsecond, 0) == 0 do
      NaiveDateTime.truncate(epoch, :second)
    else
      epoch
    end
  end
end
