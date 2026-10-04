defmodule Sidereon.GNSS.Ionosphere.CivilFields do
  @moduledoc false

  # The one place a civil epoch's fields are measured against the parameters of
  # the shared calendar helper, before any of them reaches it.
  #
  # The helper takes `year`, `month`, `day`, `hour` and `minute` as 32-bit
  # integers and `second` as a double. A field that has no value of the kind its
  # parameter takes is named here, with the value that has none. Unchecked, a
  # date or clock field that is not an `i32` reaches the boundary as rustler's
  # `BadArg`, which raises `ArgumentError` naming no field, and a `second` no
  # double holds raises `ArithmeticError` out of the helper's own division.
  #
  # Two refusals stay apart:
  #
  #   * a field that is not an integer (or, for `second`, not a number) is
  #     `:invalid_epoch_field` - `{{2020, 6, 24}, {seconds / 3600, 0, 0}}` is a
  #     producer's ordinary mistake, since Elixir's `/` always gives a float,
  #   * an integer outside the range its parameter carries is
  #     `:value_out_of_range`.
  #
  # Both epoch forms are read through here, so a `NaiveDateTime` and a tuple
  # holding the same fields are refused the same way. A struct update can put
  # any value in a `NaiveDateTime` field without `Calendar.ISO` checking it, so
  # its `second` is checked as well; only the shape of its `microsecond` is
  # taken from `Calendar.ISO`.
  #
  # Whether a whole-number `second` is required is the caller's decision, not
  # this module's: the IONEX epoch axis is whole seconds and refuses a
  # fractional one as its own refusal, while a split Julian date carries it.

  alias Sidereon.GNSS.Ionosphere.Numeric

  @calendar_fields [:year, :month, :day, :hour, :minute]

  @doc false
  @spec calendar(NaiveDateTime.t() | tuple()) :: :ok | {:error, term()}
  def calendar(%NaiveDateTime{year: year, month: month, day: day, hour: hour, minute: minute} = epoch) do
    case check(@calendar_fields, [year, month, day, hour, minute]) do
      :ok -> second(epoch.second)
      error -> error
    end
  end

  def calendar({{year, month, day}, {hour, minute, _second}}) do
    check(@calendar_fields, [year, month, day, hour, minute])
  end

  @doc false
  # The clock fields alone (`hour`, `minute`, and a `NaiveDateTime`'s
  # `second`), for a helper that reads no date. A tuple's `second` is the
  # caller's to check, as in `calendar/1`.
  @spec clock(NaiveDateTime.t() | tuple()) :: :ok | {:error, term()}
  def clock(%NaiveDateTime{hour: hour, minute: minute} = epoch) do
    case check([:hour, :minute], [hour, minute]) do
      :ok -> second(epoch.second)
      error -> error
    end
  end

  def clock({{_year, _month, _day}, {hour, minute, _second}}) do
    check([:hour, :minute], [hour, minute])
  end

  @doc false
  # An epoch's `second`, read onto the double the helper takes.
  @spec second(term()) :: :ok | {:error, term()}
  def second(value) do
    case Numeric.float(value) do
      {:ok, _float} -> :ok
      {:out_of_range, value} -> {:error, {:value_out_of_range, :second, value}}
      :not_a_number -> {:error, {:invalid_epoch_field, :second, value}}
    end
  end

  defp check(names, values) do
    names
    |> Enum.zip(values)
    |> Enum.find(fn {_name, value} -> not Numeric.i32?(value) end)
    |> case do
      nil -> :ok
      {name, value} when is_integer(value) -> {:error, {:value_out_of_range, name, value}}
      {name, value} -> {:error, {:invalid_epoch_field, name, value}}
    end
  end
end
