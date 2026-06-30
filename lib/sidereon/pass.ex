defmodule Sidereon.Pass do
  @moduledoc """
  A satellite pass over a ground station.
  """
  @enforce_keys [:rise, :set, :max_elevation, :max_elevation_time, :duration_seconds]
  @derive Jason.Encoder
  @derive JSON.Encoder
  defstruct [:rise, :set, :max_elevation, :max_elevation_time, :duration_seconds]

  @type t :: %__MODULE__{
          rise: DateTime.t(),
          set: DateTime.t(),
          max_elevation: float(),
          max_elevation_time: DateTime.t(),
          duration_seconds: float()
        }
end
