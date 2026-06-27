defmodule Sidereon.Nx.Coverage do
  @moduledoc """
  Higher-level batched access and coverage metrics.
  """

  import Nx.Defn

  @doc """
  Count visible samples over time from an elevation tensor `[t, s, g]`.

  Returns `[s, g]`.
  """
  def access_counts(elevation_series, opts \\ []) do
    min_elevation = Keyword.get(opts, :min_elevation, 0.0)
    do_access_counts(elevation_series, min_elevation)
  end

  defn do_access_counts(elevation_series, min_elevation) do
    elevation_series
    |> Nx.greater_equal(min_elevation)
    |> Nx.as_type({:u, 8})
    |> Nx.sum(axes: [0])
  end
end
