defmodule Sidereon.Collision.Result do
  @moduledoc """
  Result of a collision-probability evaluation.
  """

  @type t :: %__MODULE__{
          pc: float(),
          miss_km: float(),
          relative_speed_km_s: float(),
          sigma_x_km: float(),
          sigma_z_km: float(),
          method: atom(),
          warnings: [String.t()]
        }

  defstruct [
    :pc,
    :miss_km,
    :relative_speed_km_s,
    :sigma_x_km,
    :sigma_z_km,
    :method,
    warnings: []
  ]
end
