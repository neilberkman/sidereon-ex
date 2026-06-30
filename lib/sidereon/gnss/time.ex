defmodule Sidereon.GNSS.Time do
  @moduledoc """
  Epoch conversions shared by the GNSS correction wrappers.

  These helpers turn an Elixir `NaiveDateTime` or a
  `{{year, month, day}, {hour, minute, second}}` tuple into the two
  representations the `sidereon-core` crate consumes:

    * a split Julian date `{jd_whole, fraction}` where `jd_whole` is the `*.5`
      midnight boundary of the civil day and `fraction` is the within-day part
      (the same convention the SP3 reader uses);
    * integer or continuous seconds since the J2000 epoch (JD 2451545.0), used
      by NIF calls that consume either exact product epoch axes or fractional
      receive times.

  No leap-second shifting is applied: the epoch stays in the time scale the
  caller supplied it in (typically GPS time for these models).
  """

  alias Sidereon.NIF

  # Named time scales the core resolves, mapped to the abbreviations the NIF
  # boundary expects. GLONASST and QZSST are the GNSS scales added with the
  # multi-system catalog work; GLONASST (like UTC) is leap-second-based.
  @time_scales %{
    utc: "UTC",
    tai: "TAI",
    tt: "TT",
    tdb: "TDB",
    gpst: "GPST",
    gst: "GST",
    bdt: "BDT",
    glonasst: "GLONASST",
    qzsst: "QZSST"
  }

  @typedoc """
  A time scale, named either by atom (`:gpst`, `:utc`, `:glonasst`, ...) or by
  its uppercase abbreviation string (`"GPST"`, `"UTC"`, ...).
  """
  @type time_scale :: atom() | String.t()

  @type leap_second_table :: %{
          source: String.t(),
          first_mjd: integer(),
          last_mjd: integer(),
          entries: non_neg_integer()
        }

  @type ut1_coverage :: %{
          source: String.t(),
          first_mjd: integer(),
          last_mjd: integer(),
          first_jd_tt: float(),
          last_jd_tt: float(),
          entries: non_neg_integer()
        }

  @doc """
  Fixed inter-system time offset `to - from`, in seconds.

  Returns the value that, added to a reading in the `from` scale, yields the
  `to`-scale reading of the same instant. Defined only for the atomic scales
  (TAI/TT/GPST/GST/QZSST/BDT) whose mutual offset is a constant.

  Returns `{:error, {:epoch_required, scale}}` for the UTC-based scales (UTC and
  GLONASST) whose offset carries the leap-second count — use
  `timescale_offset_at/3` with an epoch — and `{:error, {:unsupported, "TDB"}}`
  for TDB (its offset from TT is an epoch-dependent periodic term).

      iex> Sidereon.GNSS.Time.timescale_offset(:gpst, :tai)
      {:ok, 19.0}

      iex> Sidereon.GNSS.Time.timescale_offset(:gpst, :utc)
      {:error, {:epoch_required, "UTC"}}
  """
  @spec timescale_offset(time_scale(), time_scale()) :: {:ok, float()} | {:error, term()}
  def timescale_offset(from, to) do
    with {:ok, from} <- scale_abbrev(from),
         {:ok, to} <- scale_abbrev(to) do
      NIF.timescale_offset(from, to)
    end
  end

  @doc """
  Leap-aware inter-system time offset `to - from`, in seconds, at `utc_jd`.

  `utc_jd` is the UTC Julian date of the instant; it only affects the result
  when `from` or `to` is UTC-based (UTC/GLONASST), resolving the leap-second
  count. For purely atomic pairs it is ignored and the result matches
  `timescale_offset/2`.

      iex> {:ok, off} = Sidereon.GNSS.Time.timescale_offset_at(:glonasst, :utc, 2_451_545.0)
      iex> Float.round(off, 1)
      -10800.0
  """
  @spec timescale_offset_at(time_scale(), time_scale(), number()) ::
          {:ok, float()} | {:error, term()}
  def timescale_offset_at(from, to, utc_jd) when is_number(utc_jd) do
    with {:ok, from} <- scale_abbrev(from),
         {:ok, to} <- scale_abbrev(to) do
      NIF.timescale_offset_at(from, to, utc_jd / 1.0)
    end
  end

  @doc """
  TAI minus UTC, in seconds, in effect at a UTC calendar date.

  Delegates to `sidereon_core::astro::time::scales::julian_day_number` and
  `sidereon_core::astro::time::scales::find_leap_seconds`.
  """
  @spec leap_seconds(integer(), integer(), integer()) :: float()
  def leap_seconds(year, month, day) when is_integer(year) and is_integer(month) and is_integer(day) do
    NIF.leap_seconds(year, month, day)
  end

  @doc """
  TAI minus UTC for a list of UTC calendar dates.

  Each date is `{year, month, day}` and each result delegates to the same core
  functions as `leap_seconds/3`.
  """
  @spec leap_seconds_batch([{integer(), integer(), integer()}]) :: [float()]
  def leap_seconds_batch(dates) when is_list(dates) do
    NIF.leap_seconds_batch(dates)
  end

  @doc """
  Provenance and coverage of the embedded leap-second table.
  """
  @spec leap_second_table_info() :: leap_second_table()
  def leap_second_table_info do
    {source, first_mjd, last_mjd, entries} = NIF.leap_second_table_info()

    %{
      source: source,
      first_mjd: first_mjd,
      last_mjd: last_mjd,
      entries: entries
    }
  end

  @doc """
  Provenance and coverage of the embedded UT1/EOP table.
  """
  @spec ut1_coverage_info() :: ut1_coverage()
  def ut1_coverage_info do
    {source, first_mjd, last_mjd, first_jd_tt, last_jd_tt, entries} =
      NIF.ut1_coverage_info()

    %{
      source: source,
      first_mjd: first_mjd,
      last_mjd: last_mjd,
      first_jd_tt: first_jd_tt,
      last_jd_tt: last_jd_tt,
      entries: entries
    }
  end

  @doc "The supported time-scale atoms."
  @spec time_scales() :: [atom()]
  def time_scales, do: Map.keys(@time_scales)

  defp scale_abbrev(scale) when is_atom(scale) do
    case Map.fetch(@time_scales, scale) do
      {:ok, abbrev} -> {:ok, abbrev}
      :error -> {:error, {:unknown_time_scale, scale}}
    end
  end

  defp scale_abbrev(scale) when is_binary(scale) do
    upcased = String.upcase(scale)

    if upcased in Map.values(@time_scales) do
      {:ok, upcased}
    else
      {:error, {:unknown_time_scale, scale}}
    end
  end

  defp scale_abbrev(scale), do: {:error, {:unknown_time_scale, scale}}

  @doc """
  Convert an epoch to the split Julian date `{jd_whole, fraction}`.

  The calendar arithmetic lives in `sidereon-core`
  (`sidereon_core::astro::time::civil::split_julian_date`); this module only
  marshals the epoch into civil `(year, month, day, hour, minute, second)`
  fields.
  """
  @spec epoch_to_split_jd(NaiveDateTime.t() | tuple()) :: {float(), float()}
  def epoch_to_split_jd(epoch) do
    {year, month, day, hour, minute, second} = civil_fields(epoch)
    NIF.civil_split_julian_date(year, month, day, hour, minute, second)
  end

  @doc """
  Seconds-of-day in `[0, 86400)`, formed from the epoch's clock fields.

  Used by the Klobuchar diurnal term, which takes the GPS second-of-day
  directly. The arithmetic delegates to
  `sidereon_core::astro::time::civil::second_of_day`.
  """
  @spec second_of_day(NaiveDateTime.t() | tuple()) :: float()
  def second_of_day(epoch) do
    {_year, _month, _day, hour, minute, second} = civil_fields(epoch)
    NIF.civil_second_of_day(hour, minute, second)
  end

  @doc """
  Convert an epoch to integer seconds since the J2000 epoch (JD 2451545.0).

  A whole-second epoch yields an exact integer (the core returns the exact
  whole-second value, which is converted back to an integer here). Returns
  `{:ok, seconds}` or `{:error, :non_integer_second_epoch}` if the epoch carries
  a sub-second part. The continuous seconds come from
  `sidereon_core::astro::time::civil::j2000_seconds`.
  """
  @spec epoch_to_j2000_seconds(NaiveDateTime.t() | tuple()) ::
          {:ok, integer()} | {:error, term()}
  def epoch_to_j2000_seconds(%NaiveDateTime{} = ndt) do
    {micro, _precision} = ndt.microsecond

    if micro == 0 do
      epoch_to_j2000_seconds({{ndt.year, ndt.month, ndt.day}, {ndt.hour, ndt.minute, ndt.second}})
    else
      {:error, :non_integer_second_epoch}
    end
  end

  def epoch_to_j2000_seconds({{year, month, day}, {hour, minute, second}}) when is_integer(second) do
    seconds = NIF.civil_j2000_seconds(year, month, day, hour, minute, second / 1.0)
    {:ok, trunc(seconds)}
  end

  def epoch_to_j2000_seconds(_other), do: {:error, :non_integer_second_epoch}

  @doc """
  Convert an epoch to continuous floating-point seconds since J2000.

  Unlike `epoch_to_j2000_seconds/1`, this accepts sub-second `NaiveDateTime`
  values and tuple epochs with a floating-point seconds field. Delegates to
  `sidereon_core::astro::time::civil::j2000_seconds`.
  """
  @spec epoch_to_j2000_seconds_fractional(NaiveDateTime.t() | tuple()) ::
          {:ok, float()} | {:error, term()}
  def epoch_to_j2000_seconds_fractional(%NaiveDateTime{} = epoch) do
    {year, month, day, hour, minute, second} = civil_fields(epoch)
    {:ok, NIF.civil_j2000_seconds(year, month, day, hour, minute, second)}
  end

  def epoch_to_j2000_seconds_fractional({{_year, _month, _day}, {_hour, _minute, _second}} = epoch) do
    {year, month, day, hour, minute, second} = civil_fields(epoch)
    {:ok, NIF.civil_j2000_seconds(year, month, day, hour, minute, second)}
  end

  def epoch_to_j2000_seconds_fractional(_other), do: {:error, :non_integer_second_epoch}

  @doc """
  Fractional day-of-year of the epoch, as the `float` the Niell troposphere
  seasonal term consumes.

  January 1 00:00 is 1.0. The continuous day-of-year comes from
  `sidereon_core::astro::time::civil::day_of_year`, matching the crate's
  fractional `SolveInputs.day_of_year` convention, so the SPP troposphere and
  `Sidereon.GNSS.Troposphere` agree for the same epoch.
  """
  @spec day_of_year(NaiveDateTime.t() | tuple()) :: float()
  def day_of_year(epoch) do
    {year, month, day, hour, minute, second} = civil_fields(epoch)
    NIF.civil_day_of_year(year, month, day, hour, minute, second)
  end

  @doc """
  Validated UTC instant for an epoch, as the split Julian date `{jd_whole, fraction}`.

  Delegates to `sidereon_core::astro::time::model::Instant::from_utc_civil`, the
  entry the ionosphere/troposphere delay dispatchers build their `epoch` argument
  from. Unlike `epoch_to_split_jd/1`, this runs the core's `JulianDateSplit`
  guard, so an out-of-day clock field is rejected as `{:error, :invalid_instant}`
  rather than producing an out-of-range fraction.

      iex> {:ok, {jd_whole, _fraction}} =
      ...>   Sidereon.GNSS.Time.utc_instant_split({{2020, 6, 25}, {12, 0, 0}})
      iex> jd_whole
      2_459_025.5
  """
  @spec utc_instant_split(NaiveDateTime.t() | tuple()) ::
          {:ok, {float(), float()}} | {:error, term()}
  def utc_instant_split(epoch) do
    {year, month, day, hour, minute, second} = civil_fields(epoch)
    NIF.civil_utc_instant_split(year, month, day, hour, minute, second)
  end

  # Marshal an epoch into civil `(year, month, day, hour, minute, second)` fields
  # with a floating-point seconds component (sub-second microseconds folded in).
  defp civil_fields(%NaiveDateTime{} = ndt) do
    {micro, _precision} = ndt.microsecond
    {ndt.year, ndt.month, ndt.day, ndt.hour, ndt.minute, ndt.second + micro / 1_000_000.0}
  end

  defp civil_fields({{year, month, day}, {hour, minute, second}}) do
    {year, month, day, hour, minute, second / 1.0}
  end
end
