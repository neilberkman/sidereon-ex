defmodule Sidereon.GNSS.Ionosphere.Numeric do
  @moduledoc false

  # The one place an Elixir number is measured against the ranges the IONEX
  # boundary carries its numbers in.
  #
  # `value / 1.0` is not a total function on integers. Elixir carries an integer
  # of any magnitude, and an integer larger in magnitude than the largest finite
  # double has no double to be read onto: dividing it raises `ArithmeticError`,
  # which is neither the `ErlangError` a decoder raises nor a value any caller
  # asked for. So the range is checked before the division rather than the
  # division being attempted and its failure caught.
  #
  # The tag for a value that is not a number is the caller's, not this module's:
  # the public surfaces do not agree on one. A slant request field is
  # `:invalid_request_field`, a grid field `:invalid_grid_field`, a node sample
  # field `:invalid_sample_field` and a header record `:invalid_header_field`,
  # and a grid field must not come back named as a request field. So this module
  # reports which of the three cases a value falls in and each caller names its
  # own field under its own tag.

  # The largest finite double, as the integer it is.
  @float_max_integer trunc(1.7976931348623157e308)

  @i32_min -2_147_483_648
  @i32_max 2_147_483_647

  @typedoc false
  @type outcome :: {:ok, float()} | {:out_of_range, integer()} | :not_a_number

  @doc false
  @spec float(term()) :: outcome()
  def float(value) when is_float(value), do: {:ok, value}

  def float(value) when is_integer(value) and value >= -@float_max_integer and value <= @float_max_integer do
    {:ok, value / 1.0}
  end

  def float(value) when is_integer(value), do: {:out_of_range, value}

  def float(_value), do: :not_a_number

  @doc false
  # True for a value the boundary can carry as one of its `i32` fields. A value
  # that is not an integer is not one: a non-integer calendar field has no `i32`
  # to be read onto any more than an out-of-range integer does.
  @spec i32?(term()) :: boolean()
  def i32?(value) when is_integer(value), do: value >= @i32_min and value <= @i32_max
  def i32?(_value), do: false
end
