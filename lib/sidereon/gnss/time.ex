defmodule Sidereon.GNSS.Time do
  @moduledoc """
  Epoch conversions shared by the GNSS correction wrappers.

  These helpers turn an Elixir `NaiveDateTime` or a
  `{{year, month, day}, {hour, minute, second}}` tuple into the two
  representations the `astrodynamics-gnss` crate consumes:

    * a split Julian date `{jd_whole, fraction}` where `jd_whole` is the `*.5`
      midnight boundary of the civil day and `fraction` is the within-day part
      (the same convention the SP3 reader uses);
    * integer or continuous seconds since the J2000 epoch (JD 2451545.0), used
      by NIF calls that consume either exact product epoch axes or fractional
      receive times.

  No leap-second shifting is applied: the epoch stays in the time scale the
  caller supplied it in (typically GPS time for these models).
  """

  @j2000_jd 2_451_545.0
  @seconds_per_day 86_400.0

  @doc """
  Convert an epoch to the split Julian date `{jd_whole, fraction}`.
  """
  @spec epoch_to_split_jd(NaiveDateTime.t() | tuple()) :: {float(), float()}
  def epoch_to_split_jd(%NaiveDateTime{} = ndt) do
    {micro, _precision} = ndt.microsecond
    seconds = ndt.second + micro / 1_000_000.0
    epoch_to_split_jd({{ndt.year, ndt.month, ndt.day}, {ndt.hour, ndt.minute, seconds}})
  end

  def epoch_to_split_jd({{year, month, day}, {hour, minute, second}}) do
    # Fliegel-Van Flandern Gregorian -> Julian Day Number in integer arithmetic
    # so the whole-day boundary is exact.
    a = div(14 - month, 12)
    y = year + 4800 - a
    m = month + 12 * a - 3

    jdn =
      day + div(153 * m + 2, 5) + 365 * y + div(y, 4) - div(y, 100) + div(y, 400) - 32_045

    jd_whole = jdn - 0.5
    day_seconds = hour * 3600.0 + minute * 60.0 + second / 1.0
    fraction = day_seconds / @seconds_per_day
    {jd_whole, fraction}
  end

  @doc """
  Seconds-of-day in `[0, 86400)`, formed from the epoch's integer clock fields.

  Used by the Klobuchar diurnal term, which takes the GPS second-of-day
  directly. Forming it from `hour`, `minute`, and `second` keeps it exact (no
  split-Julian-date round trip), so the broadcast-model result is bit-for-bit
  identical to the reference.
  """
  @spec second_of_day(NaiveDateTime.t() | tuple()) :: float()
  def second_of_day(%NaiveDateTime{} = ndt) do
    {micro, _precision} = ndt.microsecond
    ndt.hour * 3600.0 + ndt.minute * 60.0 + ndt.second + micro / 1_000_000.0
  end

  def second_of_day({{_year, _month, _day}, {hour, minute, second}}) do
    hour * 3600.0 + minute * 60.0 + second / 1.0
  end

  @doc """
  Convert an epoch to integer seconds since the J2000 epoch (JD 2451545.0).

  The seconds-of-day are formed from the integer clock fields, so a whole-second
  epoch yields an exact integer. Returns `{:ok, seconds}` or
  `{:error, :non_integer_second_epoch}` if the result is not an integer number
  of seconds.
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

  def epoch_to_j2000_seconds({{year, month, day}, {hour, minute, second}})
      when is_integer(second) do
    a = div(14 - month, 12)
    y = year + 4800 - a
    m = month + 12 * a - 3

    jdn =
      day + div(153 * m + 2, 5) + 365 * y + div(y, 4) - div(y, 100) + div(y, 400) - 32_045

    # J2000 (JD 2451545.0) is at this day's noon plus an integer day count, so
    # the day's noon is `(jdn - 2451545)` whole days from J2000. The civil
    # midnight is 12 h (43200 s) earlier; add the within-day seconds.
    noon_seconds_from_j2000 = (jdn - trunc(@j2000_jd)) * 86_400
    day_seconds = hour * 3600 + minute * 60 + second
    {:ok, noon_seconds_from_j2000 - 43_200 + day_seconds}
  end

  def epoch_to_j2000_seconds(_other), do: {:error, :non_integer_second_epoch}

  @doc """
  Convert an epoch to continuous floating-point seconds since J2000.

  Unlike `epoch_to_j2000_seconds/1`, this accepts sub-second `NaiveDateTime`
  values and tuple epochs with a floating-point seconds field.
  """
  @spec epoch_to_j2000_seconds_fractional(NaiveDateTime.t() | tuple()) ::
          {:ok, float()} | {:error, term()}
  def epoch_to_j2000_seconds_fractional(%NaiveDateTime{} = ndt) do
    {micro, _precision} = ndt.microsecond

    {:ok, seconds} = epoch_to_j2000_seconds(%{ndt | microsecond: {0, 0}})
    {:ok, seconds + micro / 1_000_000.0}
  end

  def epoch_to_j2000_seconds_fractional({{_y, _mo, _d} = date, {hour, minute, second}})
      when is_float(second) do
    whole = trunc(second)
    frac = second - whole

    {:ok, seconds} = epoch_to_j2000_seconds({date, {hour, minute, whole}})
    {:ok, seconds + frac}
  end

  def epoch_to_j2000_seconds_fractional(epoch) do
    case epoch_to_j2000_seconds(epoch) do
      {:ok, seconds} -> {:ok, seconds / 1.0}
      {:error, _} = err -> err
    end
  end

  @doc """
  Fractional day-of-year of the epoch, as the `float` the Niell troposphere
  seasonal term consumes.

  January 1 00:00 is 1.0. The value is the integer civil day-of-year plus the
  within-day fraction (the continuous day-of-year), matching the crate's
  fractional `SolveInputs.day_of_year` convention and the standalone
  troposphere recipe, so the SPP troposphere and `Sidereon.GNSS.Troposphere` agree for
  the same epoch.
  """
  @spec day_of_year(NaiveDateTime.t() | tuple()) :: float()
  def day_of_year(%NaiveDateTime{} = ndt) do
    {micro, _precision} = ndt.microsecond
    sod = ndt.hour * 3600 + ndt.minute * 60 + ndt.second + micro / 1_000_000.0
    integer_day_of_year(ndt.year, ndt.month, ndt.day) + sod / 86_400.0
  end

  def day_of_year({{year, month, day}, {hour, minute, second}}) do
    sod = hour * 3600 + minute * 60 + second
    integer_day_of_year(year, month, day) + sod / 86_400.0
  end

  defp integer_day_of_year(year, month, day) do
    # Julian Day Number of the epoch minus the JDN of January 1, plus one, in
    # exact integer arithmetic, so the day count is independent of leap years.
    jdn = jdn(year, month, day)
    jan1 = jdn(year, 1, 1)
    (jdn - jan1 + 1) / 1.0
  end

  defp jdn(year, month, day) do
    a = div(14 - month, 12)
    y = year + 4800 - a
    m = month + 12 * a - 3
    day + div(153 * m + 2, 5) + 365 * y + div(y, 4) - div(y, 100) + div(y, 400) - 32_045
  end
end
