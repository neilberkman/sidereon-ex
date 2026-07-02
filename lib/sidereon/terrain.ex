defmodule Sidereon.Terrain do
  @moduledoc """
  DTED terrain loading and elevation lookup.
  """

  alias Sidereon.NIF

  defmodule Dted do
    @moduledoc """
    Handle for a DTED terrain directory.
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

  @spec dted(String.t()) :: {:ok, Dted.t()} | {:error, term()}
  def dted(root) when is_binary(root), do: {:ok, %Dted{handle: NIF.terrain_dted_new(root)}}

  @spec height(Dted.t(), number(), number(), keyword()) :: {:ok, float()} | {:error, atom()}
  def height(%Dted{handle: handle}, longitude_deg, latitude_deg, opts \\ []) do
    interpolation = Keyword.get(opts, :interpolation, :bilinear)
    NIF.terrain_dted_height(handle, longitude_deg / 1.0, latitude_deg / 1.0, Atom.to_string(interpolation))
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @spec load_tile(String.t()) :: {:ok, DtedTile.t()} | {:error, term()}
  def load_tile(path) when is_binary(path) do
    {:ok, %DtedTile{handle: NIF.terrain_dted_tile_load(path)}}
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @spec tile_elevation(DtedTile.t(), number(), number()) :: {:ok, integer()} | {:error, atom()}
  def tile_elevation(%DtedTile{handle: handle}, longitude_deg, latitude_deg) do
    NIF.terrain_dted_tile_elevation(handle, longitude_deg / 1.0, latitude_deg / 1.0)
  rescue
    e in ErlangError -> {:error, e.original}
  end

  def dted!(root), do: bang(dted(root))

  def height!(terrain, longitude_deg, latitude_deg, opts \\ []),
    do: bang(height(terrain, longitude_deg, latitude_deg, opts))

  def load_tile!(path), do: bang(load_tile(path))
  def tile_elevation!(tile, longitude_deg, latitude_deg), do: bang(tile_elevation(tile, longitude_deg, latitude_deg))

  defp bang({:ok, value}), do: value
  defp bang({:error, reason}), do: raise(ArgumentError, "terrain lookup failed: #{inspect(reason)}")
end
