defmodule Sidereon.GNSS.Ionosphere.Epoch do
  @moduledoc """
  A scale-tagged instant at the IONEX boundary.

  `sidereon-core` holds an instant either as a split Julian date or as exact
  integer nanoseconds, and the two are not interchangeable without loss. An
  epoch here names which one it carries, and nothing converts between them or
  rounds in either direction:

    * `%Epoch{time_scale: "UTC", jd_whole: 2_459_024.0, jd_fraction: 0.5}`
    * `%Epoch{time_scale: "UTC", j2000_nanos: 646_228_800_000_000_000}`

  Both examples are 2020-06-24 00:00:00, in the same scale.

  ## The nanosecond origin is J2000, not Unix

  `j2000_nanos` counts nanoseconds from the **J2000 epoch**, JD 2451545.0 in the
  instant's own scale, which is the origin the core reads this representation
  against: it divides the count by `1_000_000_000` and uses the result directly
  as the J2000 second of the map. So `j2000_nanos: 0` is JD 2451545.0, and a
  count before it is negative. It is **not** a Unix timestamp; feeding Unix
  nanoseconds here lands roughly thirty years late.

  The standalone `Sidereon.GNSS.Ionosphere.TecGrid` is the other convention: its
  `epochs_ns` axis and its `unix_nanos` query argument are Unix nanoseconds,
  because that is what its core type carries. The two surfaces keep their own
  origins and neither is converted into the other here.

  Exactly one representation is populated. The IONEX parser builds its map
  epochs as split Julian dates, so a parsed product reads back as split Julian
  dates; a product built from nanosecond epochs reads back as the same integer
  nanosecond count it was given.

  The IONEX epoch axis is whole seconds, so a product built from a count that is
  not a whole number of seconds is refused with `:epoch_not_representable`
  rather than rounded onto it.

  ## What is refused

    * `{:invalid_field, "fraction", "must be within one residual day"}` - a split
      Julian date whose fraction is outside `[-1, 1]`, with the core's own field
      and reason.
    * `{:value_out_of_range, :j2000_nanos, value}` - a count past the signed
      128-bit range the boundary carries it in.
    * `{:value_out_of_range, :jd_whole, value}` or
      `{:value_out_of_range, :jd_fraction, value}` - a split Julian date part
      that is an integer larger in magnitude than the largest finite double,
      which has no double to be read onto.
    * `{:invalid_epoch_field, field, value}` - from `from_civil/2`, a `year`,
      `month`, `day`, `hour` or `minute` that is not an integer, or a `second`
      that is not a number. The shared calendar helper takes the first five as
      32-bit integers, and an `hour` arrived at by division is a float, since
      Elixir's `/` always gives one.
    * `{:value_out_of_range, field, value}` - from `from_civil/2`, a `year`,
      `month`, `day`, `hour` or `minute` that is an integer outside the 32-bit
      range, or an integer `second` larger in magnitude than the largest finite
      double. A `NaiveDateTime` is checked the same way: its year can be past
      the 32-bit range.
    * `:ambiguous_epoch_representation` - both representations are populated, or
      neither is.
    * `:bad_epoch` - the value is not an `Epoch`.

  ## Time scales

  `time_scale` is the core's own abbreviation. The boundary reads all eleven
  scales the core names: `"UTC"`, `"TAI"`, `"TT"`, `"TCG"`, `"TDB"`, `"TCB"`,
  `"GPST"`, `"GST"`, `"BDT"`, `"GLONASST"` and `"QZSST"`. Any other string is
  reported as an unknown scale rather than replaced with a default. IONEX
  products are UTC throughout, so a parsed product's epochs are `"UTC"`; the
  scale is carried because the core instant carries it, and a product built from
  samples is tagged with whatever the caller states.

  There is no default epoch and no default scale: `from_civil/2` takes the scale
  it tags the result with.
  """

  alias Sidereon.GNSS.Ionosphere.CivilFields
  alias Sidereon.GNSS.Ionosphere.Numeric
  alias Sidereon.GNSS.Time

  # `Instant` holds a nanosecond count as an `i128`, which is the range a count
  # must fit for the boundary to carry it as the integer it is.
  @i128_min -170_141_183_460_469_231_731_687_303_715_884_105_728
  @i128_max 170_141_183_460_469_231_731_687_303_715_884_105_727

  @enforce_keys [:time_scale]
  defstruct [:time_scale, :jd_whole, :jd_fraction, :j2000_nanos]

  @type t :: %__MODULE__{
          time_scale: String.t(),
          jd_whole: number() | nil,
          jd_fraction: number() | nil,
          j2000_nanos: integer() | nil
        }

  @doc """
  An epoch held as the split Julian date `jd_whole + jd_fraction` in `time_scale`.

  The two parts are kept as they were given, integer or float, and are read onto
  the doubles the boundary takes when the epoch is converted, so an integer no
  double holds is a named refusal of the build rather than an exception out of
  this constructor.
  """
  @spec julian_date(String.t(), number(), number()) :: t()
  def julian_date(time_scale, jd_whole, jd_fraction)
      when is_binary(time_scale) and is_number(jd_whole) and is_number(jd_fraction) do
    %__MODULE__{time_scale: time_scale, jd_whole: jd_whole, jd_fraction: jd_fraction}
  end

  @doc """
  An epoch held as exact integer nanoseconds since J2000 (JD 2451545.0) in
  `time_scale`.

  The count is carried to the core as the integer it is, with no scaling and no
  rounding. Zero is JD 2451545.0 itself and a count before it is negative.

  ## Examples

      # 2000-01-01 12:00:00 UTC, the J2000 epoch itself
      Epoch.j2000_nanos("UTC", 0)

      # one hour before it
      Epoch.j2000_nanos("UTC", -3_600_000_000_000)
  """
  @spec j2000_nanos(String.t(), integer()) :: t()
  def j2000_nanos(time_scale, nanos) when is_binary(time_scale) and is_integer(nanos) do
    %__MODULE__{time_scale: time_scale, j2000_nanos: nanos}
  end

  @doc """
  An epoch from a civil `NaiveDateTime` or `{{y, m, d}, {h, min, s}}` tuple, as
  the split Julian date of that calendar instant, tagged with `time_scale`.

  The scale is the caller's statement about the calendar fields; this function
  does not shift the instant between scales. A fractional `second` is carried
  into the Julian date fraction as given.

  Returns `{:ok, epoch}`, or `{:error, reason}` when a field has no value of
  the kind the shared calendar helper takes, as listed under "What is refused"
  in this module's documentation. Unlike the other constructors here, this one
  converts when it is called, because the calendar arithmetic runs in the core,
  so its refusals are returned here rather than when the epoch is converted.

  ## Examples

      {:ok, epoch} = Epoch.from_civil("UTC", {{2020, 6, 24}, {0, 0, 0}})

      {:error, {:invalid_epoch_field, :hour, 2.0}} =
        Epoch.from_civil("UTC", {{2020, 6, 24}, {7200 / 3600, 0, 0}})
  """
  @spec from_civil(String.t(), NaiveDateTime.t() | tuple()) :: {:ok, t()} | {:error, term()}
  def from_civil(time_scale, %NaiveDateTime{} = epoch) when is_binary(time_scale) do
    case CivilFields.calendar(epoch) do
      :ok -> {:ok, split(time_scale, epoch)}
      {:error, _reason} = error -> error
    end
  end

  def from_civil(time_scale, {{_year, _month, _day}, {_hour, _minute, second}} = epoch) when is_binary(time_scale) do
    with :ok <- CivilFields.calendar(epoch),
         :ok <- CivilFields.second(second) do
      {:ok, split(time_scale, epoch)}
    end
  end

  @doc false
  @spec to_nif_term(t()) :: {:ok, tuple()} | {:error, term()}
  def to_nif_term(%__MODULE__{time_scale: scale, jd_whole: whole, jd_fraction: fraction, j2000_nanos: nil})
      when is_binary(scale) and is_number(whole) and is_number(fraction) do
    # Both parts cross as doubles, so an integer no double holds is named before
    # it is divided rather than raising out of the division.
    with {:ok, whole} <- part(whole, :jd_whole),
         {:ok, fraction} <- part(fraction, :jd_fraction) do
      # `JulianDateSplit::new` takes a fraction within one residual day. Its
      # refusal names the rejected part and why, and the same pair is reported
      # here, because the boundary's map decoding replaces a field decoder's own
      # error with the name of the field it could not read.
      if fraction >= -1.0 and fraction <= 1.0 do
        {:ok, {:julian_date, scale, whole, fraction}}
      else
        {:error, {:invalid_field, "fraction", "must be within one residual day"}}
      end
    end
  end

  def to_nif_term(%__MODULE__{time_scale: scale, jd_whole: nil, jd_fraction: nil, j2000_nanos: nanos})
      when is_binary(scale) and is_integer(nanos) do
    # The count crosses as an `i128`; a count past that range is named here
    # rather than reaching the boundary as an opaque decode failure.
    if nanos >= @i128_min and nanos <= @i128_max do
      {:ok, {:nanos, scale, nanos}}
    else
      {:error, {:value_out_of_range, :j2000_nanos, nanos}}
    end
  end

  def to_nif_term(%__MODULE__{}), do: {:error, :ambiguous_epoch_representation}
  def to_nif_term(_other), do: {:error, :bad_epoch}

  @doc false
  @spec from_nif_term(tuple()) :: t()
  def from_nif_term({:julian_date, scale, jd_whole, jd_fraction}) do
    %__MODULE__{time_scale: scale, jd_whole: jd_whole, jd_fraction: jd_fraction}
  end

  def from_nif_term({:nanos, scale, nanos}) do
    %__MODULE__{time_scale: scale, j2000_nanos: nanos}
  end

  defp part(value, field) do
    case Numeric.float(value) do
      {:ok, float} -> {:ok, float}
      {:out_of_range, value} -> {:error, {:value_out_of_range, field, value}}
    end
  end

  # The fields were checked by the caller, so the split is taken as it comes.
  defp split(time_scale, epoch) do
    {:ok, {jd_whole, jd_fraction}} = Time.epoch_to_split_jd(epoch)
    julian_date(time_scale, jd_whole, jd_fraction)
  end
end
