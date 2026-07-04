defmodule Sidereon.Terrain do
  @moduledoc """
  DTED terrain loading and elevation lookup.
  """

  alias Sidereon.NIF

  defmodule Dted do
    @moduledoc """
    Handle for a DTED terrain directory.

    Heights read through this handle are meters above the DTED ORTHOMETRIC
    vertical datum.
    """
    @enforce_keys [:handle]
    defstruct [:handle]
    @type t :: %__MODULE__{handle: reference()}
  end

  defmodule DtedTile do
    @moduledoc """
    Handle for one loaded DTED tile.
    """
    @enforce_keys [:handle]
    defstruct [:handle]
    @type t :: %__MODULE__{handle: reference()}
  end

  @type interpolation :: :bilinear | :nearest_posting

  @doc """
  Open a DTED terrain directory.

  The returned handle loads tiles lazily as lookups request them.
  """
  @spec dted(String.t()) :: {:ok, Dted.t()} | {:error, term()}
  def dted(root) when is_binary(root), do: {:ok, %Dted{handle: NIF.terrain_dted_new(root)}}

  @doc """
  Look up terrain height at `{longitude_deg, latitude_deg}`.

  Returns `{:ok, height_m}` in meters above the DTED ORTHOMETRIC vertical datum,
  or `{:error, reason}`. Points outside cached DTED coverage return `0.0` from
  the core terrain model. Longitude is first by design.
  """
  @spec height(Dted.t(), number(), number(), keyword()) :: {:ok, float()} | {:error, atom()}
  def height(%Dted{handle: handle}, longitude_deg, latitude_deg, opts \\ []) do
    interpolation = Keyword.get(opts, :interpolation, :bilinear)
    NIF.terrain_dted_height(handle, longitude_deg / 1.0, latitude_deg / 1.0, Atom.to_string(interpolation))
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Look up a batch of terrain heights.

  `points` is a list of `{longitude_deg, latitude_deg}` pairs. The returned list
  has one `{:ok, height_m}` or `{:error, reason}` entry per input, preserving
  order. Heights are meters above the DTED ORTHOMETRIC vertical datum.
  """
  @spec height_batch(Dted.t(), [{number(), number()}], keyword()) ::
          [{:ok, float()} | {:error, atom()}] | {:error, term()}
  def height_batch(%Dted{handle: handle}, points, opts \\ []) when is_list(points) do
    interpolation = Keyword.get(opts, :interpolation, :bilinear)

    normalized =
      Enum.map(points, fn {longitude_deg, latitude_deg} ->
        {longitude_deg / 1.0, latitude_deg / 1.0}
      end)

    NIF.terrain_dted_height_batch(handle, normalized, Atom.to_string(interpolation))
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Load one DTED tile from disk.
  """
  @spec load_tile(String.t()) :: {:ok, DtedTile.t()} | {:error, term()}
  def load_tile(path) when is_binary(path) do
    {:ok, %DtedTile{handle: NIF.terrain_dted_tile_load(path)}}
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Read the nearest posting elevation from a loaded DTED tile.

  Returns an integer height in meters above the DTED ORTHOMETRIC vertical datum.
  Longitude is first.
  """
  @spec tile_elevation(DtedTile.t(), number(), number()) :: {:ok, integer()} | {:error, atom()}
  def tile_elevation(%DtedTile{handle: handle}, longitude_deg, latitude_deg) do
    NIF.terrain_dted_tile_elevation(handle, longitude_deg / 1.0, latitude_deg / 1.0)
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Open a DTED terrain directory or raise.
  """
  def dted!(root), do: bang(dted(root))

  @doc """
  Look up one ORTHOMETRIC terrain height in meters or raise.
  """
  def height!(terrain, longitude_deg, latitude_deg, opts \\ []),
    do: bang(height(terrain, longitude_deg, latitude_deg, opts))

  @doc """
  Look up a batch of ORTHOMETRIC terrain heights in meters or raise.
  """
  def height_batch!(terrain, points, opts \\ []), do: bang_batch(height_batch(terrain, points, opts))

  @doc """
  Load one DTED tile or raise.
  """
  def load_tile!(path), do: bang(load_tile(path))

  @doc """
  Read one ORTHOMETRIC tile posting height in meters or raise.
  """
  def tile_elevation!(tile, longitude_deg, latitude_deg), do: bang(tile_elevation(tile, longitude_deg, latitude_deg))

  defp bang({:ok, value}), do: value
  defp bang({:error, reason}), do: raise(ArgumentError, "terrain lookup failed: #{inspect(reason)}")

  defp bang_batch({:error, reason}), do: raise(ArgumentError, "terrain lookup failed: #{inspect(reason)}")

  defp bang_batch(results) when is_list(results) do
    Enum.map(results, fn
      {:ok, value} -> value
      {:error, reason} -> raise ArgumentError, "terrain lookup failed: #{inspect(reason)}"
    end)
  end
end
