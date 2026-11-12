defmodule Sidereon.CCSDS.TDM.InputErrorKind do
  @moduledoc """
  Category of a fine-grained TDM field validation failure.

  Kinds are atoms and therefore compare by value with `==`. `display/1`
  returns the core type's human-readable display text.
  """

  alias Sidereon.NIF

  @kinds [
    :missing,
    :float_parse,
    :non_finite,
    :not_positive,
    :out_of_range,
    :invalid_index,
    :unknown_keyword,
    :unexpected_unit,
    :non_integer,
    :negative,
    :negative_zero,
    :unit_mismatch,
    :decimal_mismatch
  ]

  @type t ::
          :missing
          | :float_parse
          | :non_finite
          | :not_positive
          | :out_of_range
          | :invalid_index
          | :unknown_keyword
          | :unexpected_unit
          | :non_integer
          | :negative
          | :negative_zero
          | :unit_mismatch
          | :decimal_mismatch

  @doc "Returns the core's human-readable display text for `kind`."
  @spec display(t()) :: String.t()
  def display(kind) when kind in @kinds, do: NIF.tdm_input_error_kind_display(kind)

  def display(kind) do
    raise ArgumentError, "invalid TDM input-error kind: #{inspect(kind)}"
  end
end
