defmodule Sidereon.Terrain do
  @moduledoc """
  DTED terrain loading and elevation lookup.
  """

  alias Sidereon.NIF
  alias Sidereon.NifCall

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

  @typedoc """
  Horizontal datum a DTED tile's DSI record states: `:wgs84`, `:wgs72`,
  `:unstated` for a blank or zero-filled field (read as WGS84), or
  `{:other, text}` with the field as read.
  """
  @type horizontal_datum :: :wgs84 | :wgs72 | :unstated | {:other, String.t()}

  @typedoc """
  Why a terrain lookup has no height although the query is valid.

    * `{:unknown_terrain_elevation, fields}` - the lookup gives nonzero weight
      to a posting holding the DTED null value (MIL-PRF-89020B 3.11.3.1), and
      no neighbouring tile knows the height at the same place. `fields` names
      the tile (`lat_index`, `lon_index`) and the zero-based posting
      (`latitude_posting`, `longitude_posting`).
    * `{:non_wgs84_terrain_tile, fields}` - the tile states a horizontal datum
      other than WGS84 (`datum`), so it does not answer a WGS84 query; no datum
      transformation is performed.
    * `{:missing_terrain_tile, fields}` - the store holds no tile for the cell.
    * `{:parse, message}` - a DTED tile parse failure not represented by the
      typed `:terrain_tile` or `:terrain_tile_origin` cases below.
    * `{:terrain_tile, fields}` - a stored DTED tile could not be read; `fields`
      retains its indices and complete typed `:error` reason.
    * `{:terrain_tile_origin, fields}` - a tile's parsed origin disagrees with
      its indexed origin; `fields` retains the path and both tile identities.
    * `{:invalid_input, fields}` - a coordinate or other lookup input was refused;
      `fields.message` retains the core reason.
  """
  @type lookup_error ::
          {:unknown_terrain_elevation,
           %{
             lat_index: integer(),
             lon_index: integer(),
             latitude_posting: non_neg_integer(),
             longitude_posting: non_neg_integer()
           }}
          | {:non_wgs84_terrain_tile, %{lat_index: integer(), lon_index: integer(), datum: horizontal_datum()}}
          | {:missing_terrain_tile, %{lat_index: integer(), lon_index: integer()}}
          | {:terrain_tile, %{lat_index: integer(), lon_index: integer(), error: tile_error()}}
          | {:terrain_tile_origin,
             %{
               path: String.t(),
               lat_index: integer(),
               lon_index: integer(),
               origin_latitude: integer(),
               origin_longitude: integer()
             }}
          | {:invalid_input, %{message: String.t()}}
          | {:parse, String.t()}

  @typedoc """
  Why a DTED tile could not be read or queried, one tag per core
  `DtedTileError` variant with its fields. `{:null_posting, fields}` is a
  posting holding the DTED null value, an unknown elevation rather than a
  height. The UHL metadata refusals (`:coordinate_out_of_range`,
  `:wrong_hemisphere`, `:origin_not_whole_degree`, `:interval_count_mismatch`,
  `:profile_longitude_count_mismatch`, `:unsupported_partial_profile`) name the
  metadata the reader places postings by.
  """
  @type tile_error ::
          {:io, %{path: String.t(), message: String.t()}}
          | {:too_short, %{path: String.t()}}
          | {:missing_uhl1, %{path: String.t()}}
          | {:invalid_encoding, String.t()}
          | {:invalid_field, String.t()}
          | {:invalid_dimensions, %{path: String.t(), lon_count: non_neg_integer(), lat_count: non_neg_integer()}}
          | {:truncated, %{path: String.t(), actual: non_neg_integer(), expected: non_neg_integer()}}
          | {:outside, %{longitude: float(), latitude: float(), origin_longitude: float(), origin_latitude: float()}}
          | {:posting_index_out_of_bounds, %{longitude_index: non_neg_integer(), latitude_index: non_neg_integer()}}
          | {:missing_data_sentinel, %{longitude_index: non_neg_integer()}}
          | {:checksum, %{longitude_index: non_neg_integer(), checksum: integer(), sum: integer()}}
          | :empty_coordinate
          | {:invalid_hemisphere, %{hemisphere: String.t()}}
          | {:negative_posting_index, %{index: integer()}}
          | {:coordinate_out_of_range, %{field: String.t(), text: String.t()}}
          | {:wrong_hemisphere, %{field: String.t(), hemisphere: String.t(), expected: String.t()}}
          | {:origin_not_whole_degree, %{field: String.t(), text: String.t()}}
          | {:interval_count_mismatch,
             %{field: String.t(), interval_tenths_arcsec: non_neg_integer(), count: non_neg_integer()}}
          | {:profile_longitude_count_mismatch, %{longitude_index: non_neg_integer(), declared: integer()}}
          | {:unsupported_partial_profile, %{longitude_index: non_neg_integer(), first_latitude_index: integer()}}
          | {:null_posting, %{longitude_index: non_neg_integer(), latitude_index: non_neg_integer()}}
          | {:other, String.t()}

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

  A lookup that gives nonzero weight to a null posting returns
  `{:error, {:unknown_terrain_elevation, fields}}` unless a neighbouring tile
  knows the height at the same place, and a tile whose DSI names a horizontal
  datum other than WGS84 returns `{:error, {:non_wgs84_terrain_tile, fields}}`;
  see `t:lookup_error/0`. A query the lookup refuses, such as a non-finite
  coordinate, returns `{:error, {:invalid_input, fields}}` with the core reason
  in `fields.message`.
  """
  @spec height(Dted.t(), number(), number(), lookup_options()) ::
          {:ok, float()} | {:error, lookup_error() | atom() | Sidereon.argument_error()}
  def height(%Dted{handle: handle}, longitude_deg, latitude_deg, opts \\ []) do
    with {:ok, interpolation} <- interpolation(opts) do
      handle
      |> NIF.terrain_dted_height(longitude_deg / 1.0, latitude_deg / 1.0, Atom.to_string(interpolation))
      |> lookup_result()
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :terrain_dted_height)
  end

  @doc """
  Alias for `height/4`, matching the Rust/Python/WASM `height_m` name.
  """
  @spec height_m(Dted.t(), number(), number(), lookup_options()) ::
          {:ok, float()} | {:error, lookup_error() | atom() | Sidereon.argument_error()}
  def height_m(%Dted{} = terrain, longitude_deg, latitude_deg, opts \\ []),
    do: height(terrain, longitude_deg, latitude_deg, opts)

  @doc """
  Look up terrain height with explicit lookup options.
  """
  @spec height_m_with_options(Dted.t(), number(), number(), lookup_options()) ::
          {:ok, float()} | {:error, lookup_error() | atom() | Sidereon.argument_error()}
  def height_m_with_options(%Dted{} = terrain, longitude_deg, latitude_deg, opts),
    do: height(terrain, longitude_deg, latitude_deg, opts)

  @doc """
  Look up a batch of terrain heights.

  `points` is a list of `{longitude_deg, latitude_deg}` pairs. The returned list
  has one `{:ok, height_m}` or `{:error, reason}` entry per input, preserving
  order, with the reasons `height/4` returns. Heights are meters above the DTED
  ORTHOMETRIC vertical datum.
  """
  @spec height_batch(Dted.t(), [{number(), number()}], lookup_options()) ::
          [{:ok, float()} | {:error, lookup_error() | atom()}] | {:error, term()}
  def height_batch(%Dted{handle: handle}, points, opts \\ []) when is_list(points) do
    with {:ok, interpolation} <- interpolation(opts) do
      normalized =
        Enum.map(points, fn {longitude_deg, latitude_deg} ->
          {longitude_deg / 1.0, latitude_deg / 1.0}
        end)

      handle
      |> NIF.terrain_dted_height_batch(normalized, Atom.to_string(interpolation))
      |> Enum.map(&lookup_result/1)
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :terrain_dted_height_batch)
  end

  @doc """
  Load one DTED tile from disk.

  Returns `{:ok, %DtedTile{}}` or `{:error, reason}` with a `t:tile_error/0`.
  A tile is checked against the metadata the reader places postings by: UHL
  origins must be whole degrees inside their axis with that axis's hemisphere
  letters, a stated UHL data interval must span one degree over the posting
  count, and each data record must declare the longitude count of its position
  and latitude count zero. A tile on any horizontal datum loads; see
  `tile_horizontal_datum/1`.
  """
  @spec load_tile(String.t()) :: {:ok, DtedTile.t()} | {:error, tile_error() | term()}
  def load_tile(path) when is_binary(path) do
    case NIF.terrain_dted_tile_load(path) do
      {:ok, handle} -> {:ok, %DtedTile{handle: handle}}
      {:error, reason} -> {:error, tile_error(reason)}
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :terrain_dted_tile_load)
  end

  @doc """
  Read the nearest posting elevation from a loaded DTED tile.

  Returns an integer height in meters above the DTED ORTHOMETRIC vertical datum.
  Longitude is first. A posting holding the DTED null value is an unknown
  elevation, `{:error, {:null_posting, %{longitude_index: i, latitude_index: j}}}`;
  a point outside the tile is `{:error, {:outside, fields}}`.
  """
  @spec tile_elevation(DtedTile.t(), number(), number()) ::
          {:ok, integer()} | {:error, tile_error() | Sidereon.argument_error()}
  def tile_elevation(%DtedTile{handle: handle}, longitude_deg, latitude_deg) do
    case NIF.terrain_dted_tile_elevation(handle, longitude_deg / 1.0, latitude_deg / 1.0) do
      {:ok, height} -> {:ok, height}
      {:error, reason} -> {:error, tile_error(reason)}
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :terrain_dted_tile_elevation)
  end

  @doc """
  Return the horizontal datum a loaded DTED tile's DSI record states.

  `DtedTerrain` lookups answer only from a tile whose datum is `:wgs84` or
  `:unstated`, since queries are WGS84 positions.
  """
  @spec tile_horizontal_datum(DtedTile.t()) :: horizontal_datum()
  def tile_horizontal_datum(%DtedTile{handle: handle}), do: NIF.terrain_dted_tile_horizontal_datum(handle)

  @doc false
  # A terrain lookup result with the core's typed product refusals as maps.
  @spec lookup_result(term()) :: term()
  def lookup_result({:ok, _height} = ok), do: ok
  def lookup_result({:error, reason}), do: {:error, lookup_error(reason)}

  @doc false
  @spec lookup_error(term()) :: lookup_error() | term()
  def lookup_error({:unknown_terrain_elevation, lat_index, lon_index, latitude_posting, longitude_posting}) do
    {:unknown_terrain_elevation,
     %{
       lat_index: lat_index,
       lon_index: lon_index,
       latitude_posting: latitude_posting,
       longitude_posting: longitude_posting
     }}
  end

  def lookup_error({:non_wgs84_terrain_tile, lat_index, lon_index, datum}),
    do: {:non_wgs84_terrain_tile, %{lat_index: lat_index, lon_index: lon_index, datum: datum}}

  def lookup_error({:missing_terrain_tile, lat_index, lon_index}),
    do: {:missing_terrain_tile, %{lat_index: lat_index, lon_index: lon_index}}

  def lookup_error({:terrain_tile, lat_index, lon_index, error}) do
    {:terrain_tile, %{lat_index: lat_index, lon_index: lon_index, error: tile_error(error)}}
  end

  def lookup_error({:terrain_tile_origin, path, lat_index, lon_index, origin_latitude, origin_longitude}) do
    {:terrain_tile_origin,
     %{
       path: path,
       lat_index: lat_index,
       lon_index: lon_index,
       origin_latitude: origin_latitude,
       origin_longitude: origin_longitude
     }}
  end

  def lookup_error({:invalid_input, message}), do: {:invalid_input, %{message: message}}

  def lookup_error(other), do: other

  @doc false
  @spec tile_error(term()) :: tile_error() | term()
  def tile_error({:io, {path, message}}), do: {:io, %{path: path, message: message}}
  def tile_error({:too_short, path}), do: {:too_short, %{path: path}}
  def tile_error({:missing_uhl1, path}), do: {:missing_uhl1, %{path: path}}

  def tile_error({:invalid_dimensions, {path, lon_count, lat_count}}),
    do: {:invalid_dimensions, %{path: path, lon_count: lon_count, lat_count: lat_count}}

  def tile_error({:truncated, {path, actual, expected}}),
    do: {:truncated, %{path: path, actual: actual, expected: expected}}

  def tile_error({:outside, {longitude, latitude, origin_longitude, origin_latitude}}) do
    {:outside,
     %{longitude: longitude, latitude: latitude, origin_longitude: origin_longitude, origin_latitude: origin_latitude}}
  end

  def tile_error({:posting_index_out_of_bounds, {longitude_index, latitude_index}}),
    do: {:posting_index_out_of_bounds, %{longitude_index: longitude_index, latitude_index: latitude_index}}

  def tile_error({:missing_data_sentinel, longitude_index}),
    do: {:missing_data_sentinel, %{longitude_index: longitude_index}}

  def tile_error({:checksum, {longitude_index, checksum, sum}}),
    do: {:checksum, %{longitude_index: longitude_index, checksum: checksum, sum: sum}}

  def tile_error({:invalid_hemisphere, hemisphere}), do: {:invalid_hemisphere, %{hemisphere: hemisphere}}
  def tile_error({:negative_posting_index, index}), do: {:negative_posting_index, %{index: index}}
  def tile_error({:coordinate_out_of_range, {field, text}}), do: {:coordinate_out_of_range, %{field: field, text: text}}

  def tile_error({:wrong_hemisphere, {field, hemisphere, expected}}),
    do: {:wrong_hemisphere, %{field: field, hemisphere: hemisphere, expected: expected}}

  def tile_error({:origin_not_whole_degree, {field, text}}), do: {:origin_not_whole_degree, %{field: field, text: text}}

  def tile_error({:interval_count_mismatch, {field, interval_tenths_arcsec, count}}),
    do: {:interval_count_mismatch, %{field: field, interval_tenths_arcsec: interval_tenths_arcsec, count: count}}

  def tile_error({:profile_longitude_count_mismatch, {longitude_index, declared}}),
    do: {:profile_longitude_count_mismatch, %{longitude_index: longitude_index, declared: declared}}

  def tile_error({:unsupported_partial_profile, {longitude_index, first_latitude_index}}),
    do: {:unsupported_partial_profile, %{longitude_index: longitude_index, first_latitude_index: first_latitude_index}}

  def tile_error({:null_posting, {longitude_index, latitude_index}}),
    do: {:null_posting, %{longitude_index: longitude_index, latitude_index: latitude_index}}

  def tile_error(other), do: other

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
