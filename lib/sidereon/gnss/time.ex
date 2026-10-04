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

  alias Sidereon.GNSS.Ionosphere.CivilFields
  alias Sidereon.GNSS.Ionosphere.Numeric
  alias Sidereon.GNSS.Time.ExactEpoch
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
  GLONASST) whose offset carries the leap-second count (use
  `timescale_offset_at/3` with an epoch), and `{:error, {:unsupported, "TDB"}}`
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
  GPS minus UTC, in seconds, in effect at a UTC calendar date.

  This is the IS-GPS-200 quantity broadcast in the navigation message (the leap
  seconds a GPS receiver applies): 18 s from 2017. It is `leap_seconds/3` minus
  the constant 19 s `TAI - GPST`, so it is the value to use whenever you mean
  "GPS - UTC", not `leap_seconds/3` (which is `TAI - UTC`).
  """
  @spec gps_utc_offset_s(integer(), integer(), integer()) :: float()
  def gps_utc_offset_s(year, month, day) when is_integer(year) and is_integer(month) and is_integer(day) do
    NIF.gps_utc_offset_s(year, month, day)
  end

  @doc """
  TAI minus UTC, in seconds, in effect at a UTC calendar date.

  The unambiguously named alias of `leap_seconds/3` (the IERS Bulletin C
  quantity, 37 s from 2017); it returns the identical value. Use
  `gps_utc_offset_s/3` for the GNSS "GPS - UTC" offset instead.
  """
  @spec tai_utc_offset_s(integer(), integer(), integer()) :: float()
  def tai_utc_offset_s(year, month, day) when is_integer(year) and is_integer(month) and is_integer(day) do
    NIF.tai_utc_offset_s(year, month, day)
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
  Convert an epoch to the split Julian date `{:ok, {jd_whole, fraction}}`.

  The calendar arithmetic lives in `sidereon-core`
  (`sidereon_core::astro::time::civil::split_julian_date`); this module only
  marshals the epoch into civil `(year, month, day, hour, minute, second)`
  fields. A field the core cannot take is named rather than raised; see
  "Epoch refusals" below.

  ## Epoch refusals

  Every epoch helper here reads the fields it passes through the one check the
  IONEX epochs use, so a `NaiveDateTime` and a tuple holding the same fields are
  refused the same way:

    * `{:invalid_epoch_field, field, value}` - a `year`, `month`, `day`, `hour`
      or `minute` that is not an integer, or a `second` that is not a number,
    * `{:value_out_of_range, field, value}` - one of the first five outside the
      signed 32-bit range the core takes, or an integer `second` larger in
      magnitude than the largest finite double,
    * `:bad_epoch` - a value that is neither a `NaiveDateTime` nor a
      `{{year, month, day}, {hour, minute, second}}` tuple.
  """
  @spec epoch_to_split_jd(NaiveDateTime.t() | tuple()) :: {:ok, {float(), float()}} | {:error, term()}
  def epoch_to_split_jd(epoch) do
    with {:ok, {year, month, day, hour, minute, second}} <- civil_fields(epoch) do
      {:ok, NIF.civil_split_julian_date(year, month, day, hour, minute, second)}
    end
  end

  @doc """
  Seconds-of-day in `[0, 86400)`, formed from the epoch's clock fields, as
  `{:ok, seconds}`.

  Used by the Klobuchar diurnal term, which takes the GPS second-of-day
  directly. The arithmetic delegates to
  `sidereon_core::astro::time::civil::second_of_day`. Only the clock fields are
  read, so only `hour`, `minute` and `second` are checked; the refusals are
  those of `epoch_to_split_jd/1`.
  """
  @spec second_of_day(NaiveDateTime.t() | tuple()) :: {:ok, float()} | {:error, term()}
  def second_of_day(epoch) do
    with {:ok, {hour, minute, second}} <- clock_fields(epoch) do
      {:ok, NIF.civil_second_of_day(hour, minute, second)}
    end
  end

  @doc """
  Convert an epoch to integer seconds since the J2000 epoch (JD 2451545.0).

  A whole-second epoch yields an exact integer (the core returns the exact
  whole-second value, which is converted back to an integer here). Returns
  `{:ok, seconds}` or `{:error, :non_integer_second_epoch}` if the epoch carries
  a sub-second part, with the field refusals of `epoch_to_split_jd/1`. The
  continuous seconds come from `sidereon_core::astro::time::civil::j2000_seconds`.
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

  def epoch_to_j2000_seconds({{_year, _month, _day}, {_hour, _minute, second}} = epoch) when is_integer(second) do
    with {:ok, {year, month, day, hour, minute, second}} <- civil_fields(epoch) do
      {:ok, trunc(NIF.civil_j2000_seconds(year, month, day, hour, minute, second))}
    end
  end

  def epoch_to_j2000_seconds(_other), do: {:error, :non_integer_second_epoch}

  @doc """
  Convert an epoch to continuous floating-point seconds since J2000.

  Unlike `epoch_to_j2000_seconds/1`, this accepts sub-second `NaiveDateTime`
  values and tuple epochs with a floating-point seconds field. Delegates to
  `sidereon_core::astro::time::civil::j2000_seconds`. Returns `{:ok, seconds}`
  or the refusals of `epoch_to_split_jd/1`; a value of another shape is
  `{:error, :non_integer_second_epoch}`.
  """
  @spec epoch_to_j2000_seconds_fractional(NaiveDateTime.t() | tuple()) ::
          {:ok, float()} | {:error, term()}
  def epoch_to_j2000_seconds_fractional(%NaiveDateTime{} = epoch), do: j2000_seconds_fractional(epoch)

  def epoch_to_j2000_seconds_fractional({{_year, _month, _day}, {_hour, _minute, _second}} = epoch),
    do: j2000_seconds_fractional(epoch)

  def epoch_to_j2000_seconds_fractional(_other), do: {:error, :non_integer_second_epoch}

  @doc "Build an exact epoch label from a civil time value."
  @spec exact_epoch(NaiveDateTime.t() | tuple()) :: {:ok, ExactEpoch.t()} | {:error, term()}
  def exact_epoch(epoch) do
    with {:ok, {year, month, day, hour, minute, second}} <- civil_fields(epoch) do
      ExactEpoch.from_civil(year, month, day, hour, minute, second)
    end
  end

  @doc """
  Fractional day-of-year of the epoch, as `{:ok, day}` with the `float` the
  Niell troposphere seasonal term consumes.

  January 1 00:00 is 1.0. The continuous day-of-year comes from
  `sidereon_core::astro::time::civil::day_of_year`, matching the crate's
  fractional `SolveInputs.day_of_year` convention, so the SPP troposphere and
  `Sidereon.GNSS.Troposphere` agree for the same epoch. The refusals are those
  of `epoch_to_split_jd/1`.
  """
  @spec day_of_year(NaiveDateTime.t() | tuple()) :: {:ok, float()} | {:error, term()}
  def day_of_year(epoch) do
    with {:ok, {year, month, day, hour, minute, second}} <- civil_fields(epoch) do
      {:ok, NIF.civil_day_of_year(year, month, day, hour, minute, second)}
    end
  end

  @doc """
  Validated UTC instant for an epoch, as the split Julian date `{jd_whole, fraction}`.

  Delegates to `sidereon_core::astro::time::model::Instant::from_utc_civil`, the
  entry the ionosphere/troposphere delay dispatchers build their `epoch` argument
  from. Unlike `epoch_to_split_jd/1`, this runs the core's `JulianDateSplit`
  guard, so an out-of-day clock field is rejected as `{:error, :invalid_instant}`
  rather than producing an out-of-range fraction. A field the core cannot take
  is refused as in `epoch_to_split_jd/1`.

      iex> {:ok, {jd_whole, _fraction}} =
      ...>   Sidereon.GNSS.Time.utc_instant_split({{2020, 6, 25}, {12, 0, 0}})
      iex> jd_whole
      2_459_025.5
  """
  @spec utc_instant_split(NaiveDateTime.t() | tuple()) ::
          {:ok, {float(), float()}} | {:error, term()}
  def utc_instant_split(epoch) do
    with {:ok, {year, month, day, hour, minute, second}} <- civil_fields(epoch) do
      NIF.civil_utc_instant_split(year, month, day, hour, minute, second)
    end
  end

  @typedoc """
  The complete `TimeModelError::InvalidInput` detail returned by the detailed
  UTC split endpoint. `family` is `TimeModelError`, `kind` is
  `TIME_MODEL_INVALID_INPUT`, and `field`/`reason` preserve the core values.
  The family and kind fields are strings with those fixed values; they use
  `String.t()` because Elixir typespecs cannot express binary-string literals.
  """
  @type time_model_error_detail() :: %{
          required(:family) => String.t(),
          required(:kind) => String.t(),
          required(:message) => String.t(),
          required(:field) => String.t(),
          required(:reason) => String.t(),
          required(:debug) => nil
        }

  @doc """
  Typed counterpart to `utc_instant_split/1` that returns the full core time-model
  refusal detail while retaining the legacy endpoint's `:invalid_instant` result.
  """
  @spec utc_instant_split_detailed(NaiveDateTime.t() | tuple()) ::
          {:ok, {float(), float()}}
          | {:error, {:invalid_input, time_model_error_detail()}}
          | {:error, {:invalid_epoch_field, atom(), term()}}
          | {:error, {:value_out_of_range, atom(), integer() | float()}}
          | {:error, :bad_epoch}
  def utc_instant_split_detailed(epoch) do
    with {:ok, {year, month, day, hour, minute, second}} <- civil_fields(epoch) do
      NIF.civil_utc_instant_split_detailed(year, month, day, hour, minute, second)
    end
  end

  defp j2000_seconds_fractional(epoch) do
    with {:ok, {year, month, day, hour, minute, second}} <- civil_fields(epoch) do
      {:ok, NIF.civil_j2000_seconds(year, month, day, hour, minute, second)}
    end
  end

  # Marshal an epoch into civil `(year, month, day, hour, minute, second)` fields
  # with a floating-point seconds component (sub-second microseconds folded in),
  # after checking each against the parameter the core takes it as.
  defp civil_fields(%NaiveDateTime{} = ndt) do
    with :ok <- CivilFields.calendar(ndt) do
      {micro, _precision} = ndt.microsecond
      {:ok, {ndt.year, ndt.month, ndt.day, ndt.hour, ndt.minute, ndt.second + micro / 1_000_000.0}}
    end
  end

  defp civil_fields({{year, month, day}, {hour, minute, second}} = epoch) do
    with :ok <- CivilFields.calendar(epoch),
         {:ok, second} <- float_second(second) do
      {:ok, {year, month, day, hour, minute, second}}
    end
  end

  defp civil_fields(_other), do: {:error, :bad_epoch}

  # The clock fields alone, for a helper that reads no date.
  defp clock_fields(%NaiveDateTime{} = ndt) do
    with :ok <- CivilFields.clock(ndt) do
      {micro, _precision} = ndt.microsecond
      {:ok, {ndt.hour, ndt.minute, ndt.second + micro / 1_000_000.0}}
    end
  end

  defp clock_fields({{_year, _month, _day}, {hour, minute, second}} = epoch) do
    with :ok <- CivilFields.clock(epoch),
         {:ok, second} <- float_second(second) do
      {:ok, {hour, minute, second}}
    end
  end

  defp clock_fields(_other), do: {:error, :bad_epoch}

  defp float_second(second) do
    case Numeric.float(second) do
      {:ok, float} -> {:ok, float}
      {:out_of_range, value} -> {:error, {:value_out_of_range, :second, value}}
      :not_a_number -> {:error, {:invalid_epoch_field, :second, second}}
    end
  end
end
