defmodule Sidereon.Forces.TwoBody do
  @moduledoc """
  Standard Keplerian Two-Body gravity force model.
  """

  alias Sidereon.NIF

  @doc """
  Compute the acceleration due to two-body gravity.
  """
  @spec acceleration({float(), float(), float()}, {float(), float(), float()}) ::
          {float(), float(), float()}
  def acceleration({_x, _y, _z} = position, {_vx, _vy, _vz} = velocity),
    do: NIF.force_twobody_acceleration(position, velocity)
end
