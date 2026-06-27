defmodule Sidereon.Nx.Visibility do
  @moduledoc """
  Tensorized visibility products built on top of `Sidereon.Nx.Geometry`.
  """

  import Nx.Defn

  alias Sidereon.Nx.Geometry

  @doc """
  Compute a boolean `[n, m]` visibility mask from batched satellite positions.
  """
  def visible_mask(sat_positions, stations, opts \\ []) do
    min_elevation = Keyword.get(opts, :min_elevation, 0.0)
    look = Geometry.look_angles(sat_positions, stations, opts)
    Nx.greater_equal(look.elevation, min_elevation)
  end

  @doc """
  Compute maximum elevation across time from `[t, s, g]` elevations.
  """
  defn max_elevation(elevation_series) do
    Nx.reduce_max(elevation_series, axes: [0])
  end
end
