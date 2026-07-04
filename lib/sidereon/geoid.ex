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
  @type egm2008_spacing :: :one_minute | :two_point_five_minute | String.t()

  @doc """
  Built-in coarse-grid geoid undulation `N` (metres) at a geodetic position in
  radians.
  """
  @spec undulation(number(), number()) :: float()
  def undulation(lat_rad, lon_rad) do
    NIF.geoid_undulation_rad(lat_rad / 1.0, lon_rad / 1.0)
  end

  @doc """
  Built-in coarse-grid geoid undulations `N` (metres) for positions in radians.
  """
  @spec undulations([{number(), number()}]) :: [float()]
  def undulations(points_rad) when is_list(points_rad) do
    NIF.geoid_undulations_rad(points(points_rad))
  end

  @doc """
  Built-in coarse-grid geoid undulations `N` (metres) for positions in degrees.
  """
  @spec undulations_deg([{number(), number()}]) :: [float()]
  def undulations_deg(points_deg) when is_list(points_deg) do
    NIF.geoid_undulations_deg(points(points_deg))
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
  Geoid undulation `N` (metres) at a geodetic position in radians, from the
  embedded genuine EGM96 1-degree global grid.

  This is the recommended zero-setup default for metre-class datum work: its
  bilinear lookup agrees with the full 15-arcminute EGM96 grid to ~0.4 m RMS,
  far better than the coarse 30-degree built-in `undulation/2`.
  """
  @spec egm96_undulation(number(), number()) :: float()
  def egm96_undulation(lat_rad, lon_rad) do
    NIF.egm96_undulation_rad(lat_rad / 1.0, lon_rad / 1.0)
  end

  @doc """
  Embedded EGM96 1-degree undulations `N` (metres) for positions in radians.
  """
  @spec egm96_undulations([{number(), number()}]) :: [float()]
  def egm96_undulations(points_rad) when is_list(points_rad) do
    NIF.egm96_undulations_rad(points(points_rad))
  end

  @doc """
  Embedded EGM96 1-degree undulations `N` (metres) for positions in degrees.
  """
  @spec egm96_undulations_deg([{number(), number()}]) :: [float()]
  def egm96_undulations_deg(points_deg) when is_list(points_deg) do
    NIF.egm96_undulations_deg(points(points_deg))
  end

  @doc """
  Orthometric height `H = h - N` (metres) from an ellipsoidal height, using the
  embedded genuine EGM96 1-degree model. Position in radians.
  """
  @spec egm96_orthometric_height_m(number(), number(), number()) :: float()
  def egm96_orthometric_height_m(ellipsoidal_height_m, lat_rad, lon_rad) do
    NIF.egm96_orthometric_height(ellipsoidal_height_m / 1.0, lat_rad / 1.0, lon_rad / 1.0)
  end

  @doc """
  Ellipsoidal height `h = H + N` (metres) from an orthometric height, using the
  embedded genuine EGM96 1-degree model. Position in radians.
  """
  @spec egm96_ellipsoidal_height_m(number(), number(), number()) :: float()
  def egm96_ellipsoidal_height_m(orthometric_height_m, lat_rad, lon_rad) do
    NIF.egm96_ellipsoidal_height(orthometric_height_m / 1.0, lat_rad / 1.0, lon_rad / 1.0)
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
  Parse a full EGM96 WW15MGH.DAC byte buffer into a grid handle.
  """
  @spec load_egm96_dac(binary()) :: {:ok, grid()} | {:error, term()}
  def load_egm96_dac(bytes) when is_binary(bytes) do
    case NIF.geoid_grid_from_egm96_dac(bytes) do
      {:ok, handle} -> {:ok, handle}
      {:error, _} = err -> err
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Parse a full NGA EGM2008 interpolation raster into a grid handle.

  `spacing` is `:one_minute` or `:two_point_five_minute`. The returned handle
  uses the same `grid_undulation_*` and height-conversion functions as every
  loaded grid.
  """
  @spec load_egm2008_raster(binary(), egm2008_spacing()) :: {:ok, grid()} | {:error, term()}
  def load_egm2008_raster(bytes, spacing) when is_binary(bytes) do
    case NIF.geoid_grid_from_egm2008_raster(bytes, egm2008_spacing(spacing)) do
      {:ok, handle} -> {:ok, handle}
      {:error, _} = err -> err
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Parse a cropped NGA EGM2008 interpolation-raster window into a grid handle.

  `lat_min_deg` and `lon_min_deg` are the southwest node of the crop in degrees.
  `n_lat` and `n_lon` are the row and column counts carried by `bytes`.
  """
  @spec load_egm2008_raster_window(
          binary(),
          egm2008_spacing(),
          number(),
          number(),
          pos_integer(),
          pos_integer()
        ) :: {:ok, grid()} | {:error, term()}
  def load_egm2008_raster_window(bytes, spacing, lat_min_deg, lon_min_deg, n_lat, n_lon) when is_binary(bytes) do
    case NIF.geoid_grid_from_egm2008_raster_window(
           bytes,
           egm2008_spacing(spacing),
           lat_min_deg / 1.0,
           lon_min_deg / 1.0,
           n_lat,
           n_lon
         ) do
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

  @doc """
  Bilinearly interpolated undulations `N` (metres) from a loaded grid, with
  positions in degrees.
  """
  @spec grid_undulations_deg(grid(), [{number(), number()}]) :: [float()]
  def grid_undulations_deg(handle, points_deg) when is_reference(handle) and is_list(points_deg) do
    NIF.geoid_grid_undulations_deg(handle, points(points_deg))
  end

  @doc """
  Bilinearly interpolated undulations `N` (metres) from a loaded grid, with
  positions in radians.
  """
  @spec grid_undulations_rad(grid(), [{number(), number()}]) :: [float()]
  def grid_undulations_rad(handle, points_rad) when is_reference(handle) and is_list(points_rad) do
    NIF.geoid_grid_undulations_rad(handle, points(points_rad))
  end

  @doc """
  Loaded-grid orthometric height `H = h - N` (metres), position in degrees.
  """
  @spec grid_orthometric_height_deg(grid(), number(), number(), number()) :: float()
  def grid_orthometric_height_deg(handle, ellipsoidal_height_m, lat_deg, lon_deg) when is_reference(handle) do
    NIF.geoid_grid_orthometric_height_deg(
      handle,
      ellipsoidal_height_m / 1.0,
      lat_deg / 1.0,
      lon_deg / 1.0
    )
  end

  @doc """
  Loaded-grid ellipsoidal height `h = H + N` (metres), position in degrees.
  """
  @spec grid_ellipsoidal_height_deg(grid(), number(), number(), number()) :: float()
  def grid_ellipsoidal_height_deg(handle, orthometric_height_m, lat_deg, lon_deg) when is_reference(handle) do
    NIF.geoid_grid_ellipsoidal_height_deg(
      handle,
      orthometric_height_m / 1.0,
      lat_deg / 1.0,
      lon_deg / 1.0
    )
  end

  @doc """
  Loaded-grid orthometric height `H = h - N` (metres), position in radians.
  """
  @spec grid_orthometric_height_rad(grid(), number(), number(), number()) :: float()
  def grid_orthometric_height_rad(handle, ellipsoidal_height_m, lat_rad, lon_rad) when is_reference(handle) do
    NIF.geoid_grid_orthometric_height_rad(
      handle,
      ellipsoidal_height_m / 1.0,
      lat_rad / 1.0,
      lon_rad / 1.0
    )
  end

  @doc """
  Loaded-grid ellipsoidal height `h = H + N` (metres), position in radians.
  """
  @spec grid_ellipsoidal_height_rad(grid(), number(), number(), number()) :: float()
  def grid_ellipsoidal_height_rad(handle, orthometric_height_m, lat_rad, lon_rad) when is_reference(handle) do
    NIF.geoid_grid_ellipsoidal_height_rad(
      handle,
      orthometric_height_m / 1.0,
      lat_rad / 1.0,
      lon_rad / 1.0
    )
  end

  defp points(points), do: Enum.map(points, fn {lat, lon} -> {lat / 1.0, lon / 1.0} end)

  defp egm2008_spacing(:one_minute), do: "one-minute"
  defp egm2008_spacing(:one_minute_grid), do: "one-minute"
  defp egm2008_spacing(:two_point_five_minute), do: "two-point-five-minute"
  defp egm2008_spacing(:two_point_five_minute_grid), do: "two-point-five-minute"
  defp egm2008_spacing(value) when is_binary(value), do: value
end
