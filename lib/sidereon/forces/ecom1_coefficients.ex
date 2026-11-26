defmodule Sidereon.Forces.Ecom1Coefficients do
  @moduledoc "Coefficients for the Ecom1 radiation pressure model. This struct compares by value."
  alias Sidereon.Forces
  alias Sidereon.NIF

  defstruct d0: 0.0, dc: 0.0, ds: 0.0, y0: 0.0, yc: 0.0, ys: 0.0, b0: 0.0, bc: 0.0, bs: 0.0

  @type t :: %__MODULE__{
          d0: float(),
          dc: float(),
          ds: float(),
          y0: float(),
          yc: float(),
          ys: float(),
          b0: float(),
          bc: float(),
          bs: float()
        }

  @doc "Return the short coefficient labels in evaluation order."
  @spec names() :: [String.t()]
  def names, do: NIF.force_ecom1_coefficients_names()

  @doc "Return the estimable parameter names in evaluation order."
  @spec parameter_names() :: [String.t()]
  def parameter_names, do: NIF.force_ecom1_coefficients_parameter_names()

  @doc "Construct coefficients from a list of 9 values in evaluation order."
  @spec from_array([number()]) :: t()
  def from_array(values) when is_list(values) do
    struct!(__MODULE__, NIF.force_ecom1_coefficients_from_array(Forces.floats(values)))
  end

  @doc "Return the coefficients in evaluation order."
  @spec to_array(t()) :: [float()]
  def to_array(%__MODULE__{} = coefficients), do: NIF.force_ecom1_coefficients_to_array(coefficients)
end
