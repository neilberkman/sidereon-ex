defmodule Sidereon.Nx do
  @moduledoc """
  Batch/tensor analysis helpers for Sidereon.

  This layer is for high-throughput workflows like visibility matrices,
  coverage grids, and Monte Carlo studies. It complements the exact scalar
  APIs in `Sidereon`, rather than replacing them.
  """

  alias Sidereon.Nx.{Coverage, Geometry, RF, Visibility}

  @type tensor :: Nx.Tensor.t() | number()

  @doc """
  Compute topocentric look angles for many ITRS positions and stations.

  Expected shapes:
  - `sat_positions`: `[n, 3]` in ITRS km
  - `stations`: `[m, 3]` as `{lat_deg, lon_deg, alt_m}`

  Returns tensors shaped `[n, m]`.
  """
  @spec look_angles(Nx.Tensor.t(), Nx.Tensor.t(), keyword()) :: %{
          azimuth: Nx.Tensor.t(),
          elevation: Nx.Tensor.t(),
          range_km: Nx.Tensor.t()
        }
  defdelegate look_angles(sat_positions, stations, opts \\ []), to: Geometry

  @doc """
  Return a boolean visibility mask for `min_elevation` degrees.

  Result shape: `[n, m]`.
  """
  @spec visible_mask(Nx.Tensor.t(), Nx.Tensor.t(), keyword()) :: Nx.Tensor.t()
  defdelegate visible_mask(sat_positions, stations, opts \\ []), to: Visibility

  @doc """
  Batch free-space path loss.

  `range_km` may be any broadcastable tensor.
  """
  @spec fspl(tensor(), tensor()) :: Nx.Tensor.t()
  defdelegate fspl(range_km, frequency_mhz), to: RF

  @doc """
  Batch link-margin calculation with broadcastable inputs.
  """
  @spec link_margin(map()) :: Nx.Tensor.t()
  defdelegate link_margin(params), to: RF

  @doc """
  Compute simple access counts over a time series.

  Expected shape for `elevation_series`: `[t, s, g]`.
  """
  @spec access_counts(Nx.Tensor.t(), keyword()) :: Nx.Tensor.t()
  defdelegate access_counts(elevation_series, opts \\ []), to: Coverage
end
