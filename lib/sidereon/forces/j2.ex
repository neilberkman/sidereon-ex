defmodule Sidereon.Forces.J2 do
  @moduledoc """
  Earth's oblateness (J2) perturbation force model.
  """

  alias Sidereon.NIF

  @doc """
  Compute the acceleration due to J2 perturbation in ECI.
  Ref: Vallado (4th ed), Eq 8-30.
  """
  @spec acceleration({float(), float(), float()}, {float(), float(), float()}) ::
          {float(), float(), float()}
  def acceleration({_x, _y, _z} = position, {_vx, _vy, _vz} = velocity),
    do: NIF.force_j2_acceleration(position, velocity)
end
