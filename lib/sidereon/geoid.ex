defmodule Sidereon.Geoid do
  @moduledoc """
  Geoid undulation lookup and orthometric/ellipsoidal height conversion.

  The geoid undulation `N` is the height of the geoid (mean sea level) above the
  WGS84 ellipsoid in metres. GNSS yields the ellipsoidal height `h`; the
  orthometric height (height above mean sea level) is `H = h - N`.

  Two entry points are exposed over the `sidereon-core` `geoid` module:

    * zero-setup lookups against the crate's COARSE 30-degree built-in global grid
      (`undulation/2`, `orthometric_height_m/3`, `ellipsoidal_height_m/3`), and
    * a loaded grid handle (`load_grid/1`, `grid/7`) for a real vendor model,
      queried with `grid_undulation_deg/3` / `grid_undulation_rad/3`.

  The built-in grid is suitable for sanity checks and metre-scale fallback, not
  survey work; load a real model for accuracy.

  Latitude is positive north, longitude positive east. The built-in lookups and
  `grid_undulation_rad/3` take **radians**; `grid_undulation_deg/3` takes degrees.
  """

  alias Sidereon.NIF

  @type grid :: reference()

  @doc """
  Built-in coarse-grid geoid undulation `N` (metres) at a geodetic position in
  radians.
  """
  @spec undulation(number(), number()) :: float()
  def undulation(lat_rad, lon_rad) do
    NIF.geoid_undulation_rad(lat_rad / 1.0, lon_rad / 1.0)
  end

  @doc """
  Orthometric height `H = h - N` (metres) from an ellipsoidal height, using the
  built-in grid. Position in radians.
  """
  @spec orthometric_height_m(number(), number(), number()) :: float()
  def orthometric_height_m(ellipsoidal_height_m, lat_rad, lon_rad) do
    NIF.geoid_orthometric_height_m(ellipsoidal_height_m / 1.0, lat_rad / 1.0, lon_rad / 1.0)
  end

  @doc """
  Ellipsoidal height `h = H + N` (metres) from an orthometric height, using the
  built-in grid. Position in radians.
  """
  @spec ellipsoidal_height_m(number(), number(), number()) :: float()
  def ellipsoidal_height_m(orthometric_height_m, lat_rad, lon_rad) do
    NIF.geoid_ellipsoidal_height_m(orthometric_height_m / 1.0, lat_rad / 1.0, lon_rad / 1.0)
  end

  @doc """
  Parse a geoid grid in the crate's documented text format into a handle.

  The format is whitespace-delimited with `#` comments: a six-field header
  `lat_min lon_min dlat dlon n_lat n_lon` (degrees) followed by `n_lat * n_lon`
  undulation samples in metres, row-major (latitude ascending outer). Returns
  `{:ok, reference()}` or `{:error, reason}`.
  """
  @spec load_grid(binary()) :: {:ok, grid()} | {:error, term()}
  def load_grid(text) when is_binary(text) do
    case NIF.geoid_grid_from_text(text) do
      {:ok, handle} -> {:ok, handle}
      {:error, _} = err -> err
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Build a geoid grid handle from its origin, spacing, dimensions, and row-major
  samples (metres).

  `values_m` is a flat list of `n_lat * n_lon` floats. Returns
  `{:ok, reference()}` or `{:error, reason}`.
  """
  @spec grid(number(), number(), number(), number(), non_neg_integer(), non_neg_integer(), [number()]) ::
          {:ok, grid()} | {:error, term()}
  def grid(lat_min_deg, lon_min_deg, dlat_deg, dlon_deg, n_lat, n_lon, values_m) when is_list(values_m) do
    case NIF.geoid_grid_new(
           lat_min_deg / 1.0,
           lon_min_deg / 1.0,
           dlat_deg / 1.0,
           dlon_deg / 1.0,
           n_lat,
           n_lon,
           Enum.map(values_m, &(&1 / 1.0))
         ) do
      {:ok, handle} -> {:ok, handle}
      {:error, _} = err -> err
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Bilinearly interpolated undulation `N` (metres) from a loaded grid handle, at a
  geodetic position in degrees.
  """
  @spec grid_undulation_deg(grid(), number(), number()) :: float()
  def grid_undulation_deg(handle, lat_deg, lon_deg) when is_reference(handle) do
    NIF.geoid_grid_undulation_deg(handle, lat_deg / 1.0, lon_deg / 1.0)
  end

  @doc """
  Bilinearly interpolated undulation `N` (metres) from a loaded grid handle, at a
  geodetic position in radians.
  """
  @spec grid_undulation_rad(grid(), number(), number()) :: float()
  def grid_undulation_rad(handle, lat_rad, lon_rad) when is_reference(handle) do
    NIF.geoid_grid_undulation_rad(handle, lat_rad / 1.0, lon_rad / 1.0)
  end
end
