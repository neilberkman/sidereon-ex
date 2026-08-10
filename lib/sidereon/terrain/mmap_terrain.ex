defmodule Sidereon.Terrain.MmapTerrain do
  @moduledoc """
  Memory-mappable terrain store conversion and lookup.

  A terrain store is a single byte container built from DTED tiles. The reader
  can be opened from bytes with `from_bytes/1` or from a path with `from_path/1`.
  Heights returned by this module are typed as orthometric height `H` in metres
  above the EGM96 mean sea level geoid. Use the ellipsoidal conversion functions
  when a WGS84 ellipsoidal height `h = H + N` is needed.

  Terrain lookup axes are always `(longitude_deg, latitude_deg)`.
  """

  alias __MODULE__.{
    Egm96FifteenMinuteGeoid,
    EllipsoidalHeightM,
    OrthometricHeightM,
    TerrainDatumError,
    TerrainGeoidModel,
    TerrainStoreError,
    TerrainStoreTileIndex
  }

  alias Sidereon.NIF
  alias Sidereon.Terrain.MmapTerrain

  @enforce_keys [:handle]
  defstruct [:handle]

  @typedoc """
  Parsed terrain store handle.
  """
  @type t :: %__MODULE__{handle: reference()}

  @typedoc """
  Terrain interpolation method.
  """
  @type interpolation :: :bilinear | :nearest_posting

  @typedoc """
  Terrain store conversion or parse error.
  """
  @type terrain_store_error :: TerrainStoreError.t()

  @typedoc """
  Terrain datum conversion or geoid-grid loading error.
  """
  @type terrain_datum_error :: TerrainDatumError.t()

  defmodule VerticalDatum do
    @moduledoc """
    Vertical datum carried by terrain store tile records.
    """

    @typedoc """
    Orthometric height above the EGM96 mean sea level geoid.
    """
    @type t :: :egm96_msl_orthometric

    @doc false
    @spec from_nif(atom() | String.t()) :: t() | term()
    def from_nif(:egm96_msl_orthometric), do: :egm96_msl_orthometric
    def from_nif("egm96_msl_orthometric"), do: :egm96_msl_orthometric
    def from_nif(other), do: other
  end

  defmodule OrthometricHeightM do
    @moduledoc """
    Orthometric terrain height `H` in metres above the EGM96 mean sea level geoid.
    """

    alias MmapTerrain.{EllipsoidalHeightM, TerrainDatumError, TerrainGeoidModel}
    alias Sidereon.NIF

    @enforce_keys [:value_m]
    defstruct [:value_m]

    @typedoc """
    Orthometric height `H` in metres.
    """
    @type t :: %__MODULE__{value_m: float()}

    @doc """
    Build an orthometric height `H` in metres.
    """
    @spec new(number()) :: t()
    def new(value_m), do: %__MODULE__{value_m: value_m / 1.0}

    @doc """
    Return the orthometric height `H` in metres.
    """
    @spec metres(t()) :: float()
    def metres(%__MODULE__{value_m: value_m}), do: value_m

    @doc """
    Convert this orthometric height to WGS84 ellipsoidal height with degree coordinates.

    Coordinates are geoid order `(latitude_deg, longitude_deg)`. The default
    geoid model is the embedded EGM96 1-degree grid. To use the EGM96
    15-minute grid, pass `TerrainGeoidModel.egm96_fifteen_minute/1` with a
    loaded `Egm96FifteenMinuteGeoid`.
    """
    @spec to_ellipsoidal_height_deg(t(), number(), number(), TerrainGeoidModel.t() | :egm96_one_degree) ::
            {:ok, EllipsoidalHeightM.t()} | {:error, TerrainDatumError.t() | term()}
    def to_ellipsoidal_height_deg(height, latitude_deg, longitude_deg, model \\ TerrainGeoidModel.egm96_one_degree())

    def to_ellipsoidal_height_deg(%__MODULE__{value_m: value_m}, latitude_deg, longitude_deg, model) do
      with {:ok, {model_name, geoid_handle}} <- TerrainGeoidModel.to_nif(model) do
        NIF.terrain_store_orthometric_to_ellipsoidal_height_deg(
          value_m,
          latitude_deg / 1.0,
          longitude_deg / 1.0,
          model_name,
          geoid_handle
        )
        |> ellipsoidal_result()
      end
    rescue
      e in ErlangError -> {:error, e.original}
    end

    @doc """
    Convert this orthometric height to WGS84 ellipsoidal height with radian coordinates.

    Coordinates are geoid order `(latitude_rad, longitude_rad)`. The default
    geoid model is the embedded EGM96 1-degree grid.
    """
    @spec to_ellipsoidal_height_rad(t(), number(), number(), TerrainGeoidModel.t() | :egm96_one_degree) ::
            {:ok, EllipsoidalHeightM.t()} | {:error, TerrainDatumError.t() | term()}
    def to_ellipsoidal_height_rad(height, latitude_rad, longitude_rad, model \\ TerrainGeoidModel.egm96_one_degree())

    def to_ellipsoidal_height_rad(%__MODULE__{value_m: value_m}, latitude_rad, longitude_rad, model) do
      with {:ok, {model_name, geoid_handle}} <- TerrainGeoidModel.to_nif(model) do
        NIF.terrain_store_orthometric_to_ellipsoidal_height_rad(
          value_m,
          latitude_rad / 1.0,
          longitude_rad / 1.0,
          model_name,
          geoid_handle
        )
        |> ellipsoidal_result()
      end
    rescue
      e in ErlangError -> {:error, e.original}
    end

    defp ellipsoidal_result({:ok, value_m}), do: {:ok, EllipsoidalHeightM.new(value_m)}
    defp ellipsoidal_result({:error, reason}), do: {:error, TerrainDatumError.from_nif(reason)}
    defp ellipsoidal_result(other), do: {:error, other}
  end

  defmodule EllipsoidalHeightM do
    @moduledoc """
    WGS84 ellipsoidal terrain height `h` in metres.
    """

    @enforce_keys [:value_m]
    defstruct [:value_m]

    @typedoc """
    Ellipsoidal height `h` in metres above the WGS84 ellipsoid.
    """
    @type t :: %__MODULE__{value_m: float()}

    @doc """
    Build an ellipsoidal height `h` in metres.
    """
    @spec new(number()) :: t()
    def new(value_m), do: %__MODULE__{value_m: value_m / 1.0}

    @doc """
    Return the ellipsoidal height `h` in metres.
    """
    @spec metres(t()) :: float()
    def metres(%__MODULE__{value_m: value_m}), do: value_m
  end

  defmodule TerrainStoreTileIndex do
    @moduledoc """
    Metadata for one tile record in a terrain store.
    """

    alias Sidereon.Terrain.MmapTerrain.VerticalDatum

    @enforce_keys [
      :lat_index,
      :lon_index,
      :min_longitude_deg,
      :min_latitude_deg,
      :max_longitude_deg,
      :max_latitude_deg,
      :lon_count,
      :lat_count,
      :data_offset,
      :data_len,
      :checksum64,
      :vertical_datum
    ]
    defstruct [
      :lat_index,
      :lon_index,
      :min_longitude_deg,
      :min_latitude_deg,
      :max_longitude_deg,
      :max_latitude_deg,
      :lon_count,
      :lat_count,
      :data_offset,
      :data_len,
      :checksum64,
      :vertical_datum
    ]

    @typedoc """
    Parsed tile index record.
    """
    @type t :: %__MODULE__{
            lat_index: integer(),
            lon_index: integer(),
            min_longitude_deg: float(),
            min_latitude_deg: float(),
            max_longitude_deg: float(),
            max_latitude_deg: float(),
            lon_count: non_neg_integer(),
            lat_count: non_neg_integer(),
            data_offset: non_neg_integer(),
            data_len: non_neg_integer(),
            checksum64: non_neg_integer(),
            vertical_datum: VerticalDatum.t()
          }

    @doc false
    @spec from_nif(map()) :: t()
    def from_nif(fields) do
      %__MODULE__{
        lat_index: fields.lat_index,
        lon_index: fields.lon_index,
        min_longitude_deg: fields.min_longitude_deg,
        min_latitude_deg: fields.min_latitude_deg,
        max_longitude_deg: fields.max_longitude_deg,
        max_latitude_deg: fields.max_latitude_deg,
        lon_count: fields.lon_count,
        lat_count: fields.lat_count,
        data_offset: fields.data_offset,
        data_len: fields.data_len,
        checksum64: fields.checksum64,
        vertical_datum: VerticalDatum.from_nif(fields.vertical_datum)
      }
    end
  end

  defmodule Egm96FifteenMinuteGeoid do
    @moduledoc """
    Loaded EGM96 15-minute `WW15MGH.DAC` geoid grid.

    This grid is only used when a caller explicitly chooses the
    `:egm96_fifteen_minute` terrain geoid model. Missing files return a typed
    `TerrainDatumError` and do not fall back to the embedded 1-degree grid.
    """

    alias Sidereon.NIF
    alias Sidereon.Terrain.MmapTerrain.TerrainDatumError

    @enforce_keys [:handle]
    defstruct [:handle]

    @typedoc """
    Loaded EGM96 15-minute geoid handle.
    """
    @type t :: %__MODULE__{handle: reference()}

    @doc """
    Load `WW15MGH.DAC` bytes as an EGM96 15-minute geoid grid.
    """
    @spec from_ww15mgh_dac_bytes(binary()) :: {:ok, t()} | {:error, TerrainDatumError.t() | term()}
    def from_ww15mgh_dac_bytes(bytes) when is_binary(bytes) do
      NIF.terrain_store_egm96_fifteen_minute_geoid_from_bytes(bytes)
      |> geoid_result()
    rescue
      e in ErlangError -> {:error, e.original}
    end

    @doc """
    Load a `WW15MGH.DAC` path as an EGM96 15-minute geoid grid.

    If the file is absent, the result is
    `{:error, %TerrainDatumError{kind: :missing_egm96_dac}}` with the path and a
    remediation string.
    """
    @spec from_ww15mgh_dac_path(String.t()) :: {:ok, t()} | {:error, TerrainDatumError.t() | term()}
    def from_ww15mgh_dac_path(path) when is_binary(path) do
      NIF.terrain_store_egm96_fifteen_minute_geoid_from_path(path)
      |> geoid_result()
    rescue
      e in ErlangError -> {:error, e.original}
    end

    defp geoid_result({:ok, handle}) when is_reference(handle), do: {:ok, %__MODULE__{handle: handle}}
    defp geoid_result({:error, reason}), do: {:error, TerrainDatumError.from_nif(reason)}
    defp geoid_result(other), do: {:error, other}
  end

  defmodule TerrainGeoidModel do
    @moduledoc """
    Geoid tier used for terrain orthometric-to-ellipsoidal conversion.
    """

    alias Sidereon.Terrain.MmapTerrain.Egm96FifteenMinuteGeoid

    @enforce_keys [:tier]
    defstruct [:tier, :geoid]

    @typedoc """
    Terrain geoid model.
    """
    @type t :: %__MODULE__{
            tier: :egm96_one_degree | :egm96_fifteen_minute,
            geoid: Egm96FifteenMinuteGeoid.t() | nil
          }

    @doc """
    Use the embedded EGM96 1-degree grid.
    """
    @spec egm96_one_degree() :: t()
    def egm96_one_degree, do: %__MODULE__{tier: :egm96_one_degree}

    @doc """
    Use a caller-supplied EGM96 15-minute grid.
    """
    @spec egm96_fifteen_minute(Egm96FifteenMinuteGeoid.t()) :: t()
    def egm96_fifteen_minute(%Egm96FifteenMinuteGeoid{} = geoid) do
      %__MODULE__{tier: :egm96_fifteen_minute, geoid: geoid}
    end

    @doc false
    @spec to_nif(t() | :egm96_one_degree) :: {:ok, {String.t(), reference() | nil}} | {:error, term()}
    def to_nif(:egm96_one_degree), do: {:ok, {"egm96_one_degree", nil}}
    def to_nif(%__MODULE__{tier: :egm96_one_degree}), do: {:ok, {"egm96_one_degree", nil}}

    def to_nif(%__MODULE__{tier: :egm96_fifteen_minute, geoid: %Egm96FifteenMinuteGeoid{handle: handle}}) do
      {:ok, {"egm96_fifteen_minute", handle}}
    end

    def to_nif(_other), do: {:error, :bad_geoid_model}
  end

  defmodule TerrainStoreError do
    @moduledoc """
    Terrain store conversion, parse, and checksum error.
    """

    @enforce_keys [:kind]
    defstruct [
      :kind,
      :path,
      :message,
      :reason,
      :version,
      :tag,
      :lat_index,
      :lon_index,
      :expected,
      :found
    ]

    @typedoc """
    Typed terrain store error.
    """
    @type t :: %__MODULE__{
            kind:
              :io
              | :parse
              | :unsupported_version
              | :unsupported_datum
              | :duplicate_tile
              | :checksum,
            path: String.t() | nil,
            message: String.t() | nil,
            reason: String.t() | nil,
            version: non_neg_integer() | nil,
            tag: non_neg_integer() | nil,
            lat_index: integer() | nil,
            lon_index: integer() | nil,
            expected: non_neg_integer() | nil,
            found: non_neg_integer() | nil
          }

    @doc false
    @spec from_nif(term()) :: t() | term()
    def from_nif({:io, path, message}), do: %__MODULE__{kind: :io, path: path, message: message}
    def from_nif({:parse, reason}), do: %__MODULE__{kind: :parse, reason: reason}
    def from_nif({:unsupported_version, version}), do: %__MODULE__{kind: :unsupported_version, version: version}
    def from_nif({:unsupported_datum, tag}), do: %__MODULE__{kind: :unsupported_datum, tag: tag}

    def from_nif({:duplicate_tile, lat_index, lon_index}) do
      %__MODULE__{kind: :duplicate_tile, lat_index: lat_index, lon_index: lon_index}
    end

    def from_nif({:checksum, lat_index, lon_index, expected, found}) do
      %__MODULE__{
        kind: :checksum,
        lat_index: lat_index,
        lon_index: lon_index,
        expected: expected,
        found: found
      }
    end

    def from_nif(other), do: other
  end

  defmodule TerrainDatumError do
    @moduledoc """
    Terrain vertical-datum conversion and optional geoid-grid loading error.
    """

    @enforce_keys [:kind]
    defstruct [:kind, :path, :message, :reason, :remediation]

    @typedoc """
    Typed terrain datum error.
    """
    @type t :: %__MODULE__{
            kind: :terrain | :geoid | :io | :missing_egm96_dac,
            path: String.t() | nil,
            message: String.t() | nil,
            reason: String.t() | nil,
            remediation: String.t() | nil
          }

    @doc false
    @spec from_nif(term()) :: t() | term()
    def from_nif({:terrain, reason}), do: %__MODULE__{kind: :terrain, reason: reason}
    def from_nif({:geoid, reason}), do: %__MODULE__{kind: :geoid, reason: reason}
    def from_nif({:io, path, message}), do: %__MODULE__{kind: :io, path: path, message: message}

    def from_nif({:missing_egm96_dac, path, remediation}) do
      %__MODULE__{kind: :missing_egm96_dac, path: path, remediation: remediation}
    end

    def from_nif(other), do: other
  end

  @doc """
  Convert a DTED tile tree into terrain store bytes.
  """
  @spec dted_tree_to_mmap_store(String.t()) :: {:ok, binary()} | {:error, terrain_store_error() | term()}
  def dted_tree_to_mmap_store(root) when is_binary(root) do
    NIF.terrain_store_dted_tree_to_mmap_store(root)
    |> store_binary_result()
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Convert a DTED tile tree and write terrain store bytes to `out_path`.
  """
  @spec write_dted_tree_to_mmap_store(String.t(), String.t()) :: :ok | {:error, terrain_store_error() | term()}
  def write_dted_tree_to_mmap_store(root, out_path) when is_binary(root) and is_binary(out_path) do
    case NIF.terrain_store_write_dted_tree_to_mmap_store(root, out_path) do
      :ok -> :ok
      {:error, reason} -> {:error, TerrainStoreError.from_nif(reason)}
      other -> {:error, other}
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Return the FNV-1a checksum for terrain store bytes.
  """
  @spec terrain_store_checksum64(binary()) :: non_neg_integer()
  def terrain_store_checksum64(bytes) when is_binary(bytes), do: NIF.terrain_store_checksum64_bytes(bytes)

  @doc """
  Parse terrain store bytes into a reader handle.
  """
  @spec from_bytes(binary()) :: {:ok, t()} | {:error, terrain_store_error() | term()}
  def from_bytes(bytes) when is_binary(bytes) do
    NIF.terrain_store_mmap_from_bytes(bytes)
    |> store_handle_result()
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Parse owned terrain store bytes into a reader handle.
  """
  @spec from_vec(binary()) :: {:ok, t()} | {:error, terrain_store_error() | term()}
  def from_vec(bytes) when is_binary(bytes) do
    NIF.terrain_store_mmap_from_vec(bytes)
    |> store_handle_result()
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Open a terrain store file as a reader handle.

  The file is memory-mapped read-only and the reader owns the mapping, so
  opening a store does not cost its size in process memory. The mapping is
  demand-paged: a reader querying a geographically local region faults in only
  the pages covering those tiles, and construction parses the header, datum
  tag, and tile index and nothing else.
  """
  @spec from_path(String.t()) :: {:ok, t()} | {:error, terrain_store_error() | term()}
  def from_path(path) when is_binary(path) do
    NIF.terrain_store_mmap_from_path(path)
    |> store_handle_result()
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Return orthometric terrain height at `(longitude_deg, latitude_deg)`.
  """
  @spec height_m(t(), number(), number(), keyword()) :: {:ok, OrthometricHeightM.t()} | {:error, term()}
  def height_m(%__MODULE__{} = terrain, longitude_deg, latitude_deg, opts \\ []) do
    height_m_with_options(terrain, longitude_deg, latitude_deg, opts)
  end

  @doc """
  Return orthometric terrain height at `(longitude_deg, latitude_deg)` with lookup options.
  """
  @spec height_m_with_options(t(), number(), number(), keyword()) :: {:ok, OrthometricHeightM.t()} | {:error, term()}
  def height_m_with_options(%__MODULE__{handle: handle}, longitude_deg, latitude_deg, opts) do
    with {:ok, interpolation} <- interpolation(opts) do
      NIF.terrain_store_height_m_with_options(handle, longitude_deg / 1.0, latitude_deg / 1.0, interpolation)
      |> orthometric_result()
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Return typed orthometric terrain height at `(longitude_deg, latitude_deg)`.
  """
  @spec orthometric_height_m(t(), number(), number(), keyword()) ::
          {:ok, OrthometricHeightM.t()} | {:error, term()}
  def orthometric_height_m(%__MODULE__{} = terrain, longitude_deg, latitude_deg, opts \\ []) do
    orthometric_height_m_with_options(terrain, longitude_deg, latitude_deg, opts)
  end

  @doc """
  Return typed orthometric terrain height with lookup options.
  """
  @spec orthometric_height_m_with_options(t(), number(), number(), keyword()) ::
          {:ok, OrthometricHeightM.t()} | {:error, term()}
  def orthometric_height_m_with_options(%__MODULE__{handle: handle}, longitude_deg, latitude_deg, opts) do
    with {:ok, interpolation} <- interpolation(opts) do
      NIF.terrain_store_orthometric_height_m_with_options(
        handle,
        longitude_deg / 1.0,
        latitude_deg / 1.0,
        interpolation
      )
      |> orthometric_result()
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Evaluate `(longitude_deg, latitude_deg)` points as orthometric heights.
  """
  @spec height_batch(t(), [{number(), number()}], keyword()) ::
          [{:ok, OrthometricHeightM.t()} | {:error, term()}] | {:error, term()}
  def height_batch(%__MODULE__{} = terrain, points, opts \\ []) do
    orthometric_height_batch(terrain, points, opts)
  end

  @doc """
  Evaluate `(longitude_deg, latitude_deg)` points as typed orthometric heights.
  """
  @spec orthometric_height_batch(t(), [{number(), number()}], keyword()) ::
          [{:ok, OrthometricHeightM.t()} | {:error, term()}] | {:error, term()}
  def orthometric_height_batch(%__MODULE__{handle: handle}, points, opts \\ []) when is_list(points) do
    with {:ok, interpolation} <- interpolation(opts),
         {:ok, normalized} <- points(points) do
      NIF.terrain_store_orthometric_height_batch(handle, normalized, interpolation)
      |> Enum.map(&orthometric_result/1)
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Return WGS84 ellipsoidal terrain height using the embedded EGM96 1-degree grid.
  """
  @spec ellipsoidal_height_m(t(), number(), number(), keyword()) ::
          {:ok, EllipsoidalHeightM.t()} | {:error, terrain_datum_error() | term()}
  def ellipsoidal_height_m(%__MODULE__{} = terrain, longitude_deg, latitude_deg, opts \\ []) do
    ellipsoidal_height_m_with_options(terrain, longitude_deg, latitude_deg, opts)
  end

  @doc """
  Return WGS84 ellipsoidal terrain height with lookup options.
  """
  @spec ellipsoidal_height_m_with_options(t(), number(), number(), keyword()) ::
          {:ok, EllipsoidalHeightM.t()} | {:error, terrain_datum_error() | term()}
  def ellipsoidal_height_m_with_options(%__MODULE__{handle: handle}, longitude_deg, latitude_deg, opts) do
    with {:ok, interpolation} <- interpolation(opts) do
      NIF.terrain_store_ellipsoidal_height_m_with_options(
        handle,
        longitude_deg / 1.0,
        latitude_deg / 1.0,
        interpolation
      )
      |> ellipsoidal_result()
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Return WGS84 ellipsoidal terrain height with an explicit geoid model.

  Passing `TerrainGeoidModel.egm96_fifteen_minute/1` requires a loaded
  `Egm96FifteenMinuteGeoid`; it never falls back to the embedded 1-degree grid.
  """
  @spec ellipsoidal_height_m_with_model(
          t(),
          number(),
          number(),
          TerrainGeoidModel.t() | :egm96_one_degree,
          keyword()
        ) :: {:ok, EllipsoidalHeightM.t()} | {:error, terrain_datum_error() | term()}
  def ellipsoidal_height_m_with_model(%__MODULE__{handle: handle}, longitude_deg, latitude_deg, model, opts \\ []) do
    with {:ok, interpolation} <- interpolation(opts),
         {:ok, {model_name, geoid_handle}} <- TerrainGeoidModel.to_nif(model) do
      NIF.terrain_store_ellipsoidal_height_m_with_model(
        handle,
        longitude_deg / 1.0,
        latitude_deg / 1.0,
        interpolation,
        model_name,
        geoid_handle
      )
      |> ellipsoidal_result()
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Return parsed tile index records.
  """
  @spec tile_index(t()) :: [TerrainStoreTileIndex.t()]
  def tile_index(%__MODULE__{handle: handle}) do
    handle
    |> NIF.terrain_store_tile_index()
    |> Enum.map(&TerrainStoreTileIndex.from_nif/1)
  end

  @doc """
  Return the file-level vertical datum.
  """
  @spec vertical_datum(t()) :: VerticalDatum.t()
  def vertical_datum(%__MODULE__{handle: handle}) do
    handle
    |> NIF.terrain_store_vertical_datum()
    |> VerticalDatum.from_nif()
  end

  @doc """
  Return a checksum for a parsed store handle or terrain store bytes.
  """
  @spec checksum64(t() | binary()) :: non_neg_integer()
  def checksum64(%__MODULE__{handle: handle}), do: NIF.terrain_store_mmap_checksum64(handle)
  def checksum64(bytes) when is_binary(bytes), do: terrain_store_checksum64(bytes)

  @doc """
  Return canonical terrain store bytes from a parsed handle.
  """
  @spec to_bytes(t()) :: binary()
  def to_bytes(%__MODULE__{handle: handle}), do: NIF.terrain_store_to_bytes(handle)

  defp store_binary_result({:ok, bytes}) when is_binary(bytes), do: {:ok, bytes}
  defp store_binary_result({:error, reason}), do: {:error, TerrainStoreError.from_nif(reason)}
  defp store_binary_result(other), do: {:error, other}

  defp store_handle_result({:ok, handle}) when is_reference(handle), do: {:ok, %__MODULE__{handle: handle}}
  defp store_handle_result({:error, reason}), do: {:error, TerrainStoreError.from_nif(reason)}
  defp store_handle_result(other), do: {:error, other}

  defp orthometric_result({:ok, value_m}), do: {:ok, OrthometricHeightM.new(value_m)}
  defp orthometric_result({:error, reason}), do: {:error, reason}
  defp orthometric_result(other), do: {:error, other}

  defp ellipsoidal_result({:ok, value_m}), do: {:ok, EllipsoidalHeightM.new(value_m)}
  defp ellipsoidal_result({:error, reason}), do: {:error, TerrainDatumError.from_nif(reason)}
  defp ellipsoidal_result(other), do: {:error, other}

  defp interpolation(opts) do
    case Keyword.get(opts, :interpolation, :bilinear) do
      :bilinear -> {:ok, "bilinear"}
      :nearest_posting -> {:ok, "nearest_posting"}
      other -> {:error, {:bad_interpolation, other}}
    end
  end

  defp points(points) do
    {:ok,
     Enum.map(points, fn {longitude_deg, latitude_deg} ->
       {longitude_deg / 1.0, latitude_deg / 1.0}
     end)}
  rescue
    _ -> {:error, :bad_points}
  end
end
