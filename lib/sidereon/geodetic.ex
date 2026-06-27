defmodule Sidereon.Geodetic do
  @moduledoc """
  WGS84 geodetic position: latitude, longitude, altitude.
  """
  @enforce_keys [:latitude, :longitude, :altitude_km]
  @derive Jason.Encoder
  @derive JSON.Encoder
  defstruct [:latitude, :longitude, :altitude_km]

  @type t :: %__MODULE__{
          latitude: float(),
          longitude: float(),
          altitude_km: float()
        }
end
