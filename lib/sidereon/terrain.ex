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

  defmodule DtedLookupOptions do
    @moduledoc """
    Options for DTED height lookup.
    """

    @enforce_keys [:interpolation]
    defstruct interpolation: :bilinear

    @typedoc """
    DTED lookup options.
    """
    @type t :: %__MODULE__{interpolation: Sidereon.Terrain.interpolation()}

    @doc """
    Build DTED lookup options.
    """
    @spec new(Sidereon.Terrain.interpolation()) :: t()
    def new(interpolation \\ :bilinear), do: %__MODULE__{interpolation: interpolation}
  end

  defmodule DtedTile do
    @moduledoc """
    Handle for one loaded DTED tile.
    """
    @enforce_keys [:handle]
    defstruct [:handle]
    @type t :: %__MODULE__{handle: reference()}

    @doc """
    Load one DTED tile from disk.
    """
    @spec from_path(String.t()) :: {:ok, t()} | {:error, term()}
    def from_path(path), do: Sidereon.Terrain.load_tile(path)
  end

  @type interpolation :: :bilinear | :nearest_posting
  @type lookup_options :: keyword() | DtedLookupOptions.t()

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
  @spec height(Dted.t(), number(), number(), lookup_options()) :: {:ok, float()} | {:error, atom()}
  def height(%Dted{handle: handle}, longitude_deg, latitude_deg, opts \\ []) do
    with {:ok, interpolation} <- interpolation(opts) do
      NIF.terrain_dted_height(handle, longitude_deg / 1.0, latitude_deg / 1.0, Atom.to_string(interpolation))
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Alias for `height/4`, matching the Rust/Python/WASM `height_m` name.
  """
  @spec height_m(Dted.t(), number(), number(), lookup_options()) :: {:ok, float()} | {:error, atom()}
  def height_m(%Dted{} = terrain, longitude_deg, latitude_deg, opts \\ []),
    do: height(terrain, longitude_deg, latitude_deg, opts)

  @doc """
  Look up terrain height with explicit lookup options.
  """
  @spec height_m_with_options(Dted.t(), number(), number(), lookup_options()) :: {:ok, float()} | {:error, atom()}
  def height_m_with_options(%Dted{} = terrain, longitude_deg, latitude_deg, opts),
    do: height(terrain, longitude_deg, latitude_deg, opts)

  @doc """
  Look up a batch of terrain heights.

  `points` is a list of `{longitude_deg, latitude_deg}` pairs. The returned list
  has one `{:ok, height_m}` or `{:error, reason}` entry per input, preserving
  order. Heights are meters above the DTED ORTHOMETRIC vertical datum.
  """
  @spec height_batch(Dted.t(), [{number(), number()}], lookup_options()) ::
          [{:ok, float()} | {:error, atom()}] | {:error, term()}
  def height_batch(%Dted{handle: handle}, points, opts \\ []) when is_list(points) do
    with {:ok, interpolation} <- interpolation(opts) do
      normalized =
        Enum.map(points, fn {longitude_deg, latitude_deg} ->
          {longitude_deg / 1.0, latitude_deg / 1.0}
        end)

      NIF.terrain_dted_height_batch(handle, normalized, Atom.to_string(interpolation))
    end
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

  defp interpolation(%DtedLookupOptions{interpolation: interpolation}), do: interpolation(interpolation: interpolation)

  defp interpolation(opts) when is_list(opts) do
    case Keyword.get(opts, :interpolation, :bilinear) do
      mode when mode in [:bilinear, :nearest_posting] -> {:ok, mode}
      other -> {:error, {:bad_interpolation, other}}
    end
  end
end
