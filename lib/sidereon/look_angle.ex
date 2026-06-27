defmodule Sidereon.LookAngle do
  @moduledoc """
  Topocentric look angle from a ground station to a satellite.
  """
  @enforce_keys [:azimuth, :elevation, :range_km]
  @derive Jason.Encoder
  @derive JSON.Encoder
  defstruct [:azimuth, :elevation, :range_km]

  @type t :: %__MODULE__{
          azimuth: float(),
          elevation: float(),
          range_km: float()
        }
end
