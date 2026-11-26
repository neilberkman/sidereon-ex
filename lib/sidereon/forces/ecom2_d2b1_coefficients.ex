defmodule Sidereon.Forces.Ecom2D2b1Coefficients do
  @moduledoc "Coefficients for the Ecom2D2b1 radiation pressure model. This struct compares by value."
  alias Sidereon.Forces
  alias Sidereon.NIF

  defstruct b0: 0.0, b1c: 0.0, b1s: 0.0, d0: 0.0, d2c: 0.0, d2s: 0.0, y0: 0.0
  @type t :: %__MODULE__{b0: float(), b1c: float(), b1s: float(), d0: float(), d2c: float(), d2s: float(), y0: float()}

  @doc "Return the short coefficient labels in evaluation order."
  @spec names() :: [String.t()]
  def names, do: NIF.force_ecom2_d2b1_coefficients_names()

  @doc "Return the estimable parameter names in evaluation order."
  @spec parameter_names() :: [String.t()]
  def parameter_names, do: NIF.force_ecom2_d2b1_coefficients_parameter_names()

  @doc "Construct coefficients from a list of 7 values in evaluation order."
  @spec from_array([number()]) :: t()
  def from_array(values) when is_list(values) do
    struct!(__MODULE__, NIF.force_ecom2_d2b1_coefficients_from_array(Forces.floats(values)))
  end

  @doc "Return the coefficients in evaluation order."
  @spec to_array(t()) :: [float()]
  def to_array(%__MODULE__{} = coefficients), do: NIF.force_ecom2_d2b1_coefficients_to_array(coefficients)
end
