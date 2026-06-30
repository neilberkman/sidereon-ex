defmodule Sidereon.Encounter.Frame do
  @moduledoc """
  Relative encounter geometry at a common epoch.

  Defines an orthonormal encounter frame and the relative state used by
  conjunction and collision-probability calculations.

  Axes:
  - `x_hat`: In-plane cross-track axis.
  - `y_hat`: Along relative velocity.
  - `z_hat`: Encounter-plane normal.
  """

  @type vec3 :: {float(), float(), float()}

  @type t :: %__MODULE__{
          x_hat: vec3(),
          y_hat: vec3(),
          z_hat: vec3(),
          relative_position_km: vec3(),
          relative_velocity_km_s: vec3(),
          miss_km: float(),
          relative_speed_km_s: float()
        }

  defstruct [
    :x_hat,
    :y_hat,
    :z_hat,
    :relative_position_km,
    :relative_velocity_km_s,
    :miss_km,
    :relative_speed_km_s
  ]
end
