defmodule Sidereon.GNSS.Ionosphere.EpochAxis do
  @moduledoc false

  # The one place a civil epoch is read onto the IONEX epoch axis.
  #
  # The axis is whole J2000 seconds carried across the boundary as an `i64`. The
  # shared calendar helper takes `year`, `month`, `day`, `hour` and `minute` as
  # 32-bit integers and `second` as a double. A field that has no value of the
  # kind its parameter takes is named here, with the value that has none, rather
  # than reaching the boundary: there it becomes rustler's `BadArg`, which
  # raises `ArgumentError` out of the call instead of returning, and which in a
  # batch would take every other row's result with it.
  #
  # A field is refused by which parameter it cannot be read onto, so the three
  # refusals stay apart:
  #
  #   * a date or clock field that is not an integer is `:invalid_epoch_field` -
  #     `{{2020, 6, 24}, {seconds / 3600, 0, 0}}` is a producer's ordinary
  #     mistake, since Elixir's `/` always gives a float,
  #   * one that is an integer outside the 32-bit range is `:value_out_of_range`,
  #     and
  #   * a fractional `second` is `:non_integer_second_epoch`, the distinct
  #     refusal of the axis itself: the axis is whole seconds, so a sub-second
  #     epoch is refused rather than rounded onto it.
  #
  # The scalar slant calls and every batch row read their epochs through this
  # function, so one epoch is refused the same way whichever call carries it.
  # The field checks themselves are `Sidereon.GNSS.Ionosphere.CivilFields`,
  # shared with `Epoch.from_civil/2`.

  alias Sidereon.GNSS.Ionosphere.CivilFields
  alias Sidereon.GNSS.Time

  @i64_min -9_223_372_036_854_775_808
  @i64_max 9_223_372_036_854_775_807

  @spec j2000_seconds(term()) :: {:ok, integer()} | {:error, term()}
  def j2000_seconds(%NaiveDateTime{} = epoch) do
    # A `NaiveDateTime`'s year is an integer of any magnitude, so it is checked
    # the same way as the tuple holding the same fields.
    case CivilFields.calendar(epoch) do
      :ok -> epoch |> Time.epoch_to_j2000_seconds() |> in_i64()
      {:error, _reason} = error -> error
    end
  end

  def j2000_seconds({{_year, _month, _day}, {_hour, _minute, second}} = epoch) do
    with :ok <- CivilFields.calendar(epoch),
         :ok <- whole_second(second) do
      epoch |> Time.epoch_to_j2000_seconds() |> in_i64()
    end
  end

  def j2000_seconds(_other), do: {:error, :non_integer_second_epoch}

  # A second that is not an integer is the axis's own sub-second refusal, which
  # the shared helper already gives; an integer is read onto the double the
  # helper takes, so one no double holds is named before its division.
  defp whole_second(second) when is_integer(second), do: CivilFields.second(second)
  defp whole_second(_second), do: {:error, :non_integer_second_epoch}

  defp in_i64({:ok, seconds}) when seconds >= @i64_min and seconds <= @i64_max, do: {:ok, seconds}
  defp in_i64({:ok, seconds}), do: {:error, {:value_out_of_range, :epoch_j2000_s, seconds}}
  defp in_i64({:error, _reason} = error), do: error
end
