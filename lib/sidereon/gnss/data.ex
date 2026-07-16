defmodule Sidereon.GNSS.Data do
  @moduledoc """
  Cache-first acquisition for GNSS products and DTED terrain tiles.

  This module performs transport, cache IO, checksum verification, and
  provenance recording. Product names, archive URLs, terrain cache paths, and HGT
  to DTED conversion are delegated to the core NIF, so cache files produced by
  another binding under the same root are verified by the same relative path and
  data-file digest.

  Numeric modules do not fetch data. Fetch first, then pass the cached file or
  terrain root to the reader or solver.

  ## Quick Start

      {:ok, tile_path} = Sidereon.GNSS.Data.fetch_dted(36.75, -106.25)
      terrain_root = Path.dirname(Path.dirname(tile_path))
      {:ok, terrain} = Sidereon.Terrain.dted(terrain_root)
      {:ok, height_m} = Sidereon.Terrain.height(terrain, -106.25, 36.75)

  ## Bulk Terrain Workflow

      {:ok, report} =
        Sidereon.GNSS.Data.prefetch_dted_bbox({36.0, -107.0, 37.0, -106.0},
          cache_dir: "/tmp/sidereon-terrain"
        )

      {:ok, terrain} = Sidereon.Terrain.dted("/tmp/sidereon-terrain")
      {:ok, _height_m} = Sidereon.Terrain.height(terrain, -106.5, 36.5)

  C and WASM consumers use the pure core derivation and conversion functions
  directly and provide their own transport and cache policy.
  """

  alias Sidereon.GNSS.Distribution
  alias Sidereon.GNSS.SP3
  alias Sidereon.NIF
  alias Sidereon.SpaceWeather

  @default_max_compressed_bytes 64 * 1024 * 1024
  @default_max_decompressed_bytes 500 * 1024 * 1024
  @default_timeout_s 30.0
  @default_retries 3
  @default_backoff_s 0.5
  @max_redirects 5
  @aiub_web_host "www.aiub.unibe.ch"
  @aiub_download_host "download.aiub.unibe.ch"
  @aiub_object_store_suffix ".s3.cloud.switch.ch"

  @type error_reason ::
          :offline_cache_miss
          | {:not_found_on_archive, String.t()}
          | {:http_status, integer(), String.t()}
          | {:redirect_not_allowed, integer(), String.t()}
          | {:network, term()}
          | {:checksum_mismatch, String.t(), String.t()}
          | {:download_size_exceeded, non_neg_integer()}
          | {:decompress, term()}
          | {:cache_not_writable, term()}
          | {:unknown_center, String.t()}
          | {:unsupported_product, term()}
          | {:invalid_coordinate, number(), number()}
          | {:invalid_tile_index, integer(), integer()}
          | {:invalid_tile_id, String.t()}
          | {:incompatible_sources, [String.t()], term()}
          | {:no_products, [term()]}
          | {:no_coverage, String.t()}
          | {:unknown_product, term()}

  defmodule Product do
    @moduledoc """
    Pure identity for one GNSS archive product.
    """
    @enforce_keys [:center, :product_type, :date, :sample]
    defstruct [
      :center,
      :product_type,
      :date,
      :sample,
      :issue,
      :span,
      :pattern,
      :filename,
      :cache_filename,
      :url,
      :compression
    ]

    @type t :: %__MODULE__{
            center: String.t(),
            product_type: String.t(),
            date: Date.t(),
            sample: String.t(),
            issue: String.t() | nil,
            span: String.t() | nil,
            pattern: String.t() | nil,
            filename: String.t() | nil,
            cache_filename: String.t() | nil,
            url: String.t() | nil,
            compression: String.t() | nil
          }
  end

  defmodule TerrainFetchReport do
    @moduledoc """
    Result partition for region and tile-list terrain prefetches.
    """
    defstruct fetched: [], cached: [], no_coverage: [], errors: []

    @type t :: %__MODULE__{
            fetched: [String.t()],
            cached: [String.t()],
            no_coverage: [String.t()],
            errors: [{term(), term()}]
          }
  end

  defmodule AbsentCenter do
    @moduledoc """
    SP3 center that did not contribute to a merge.
    """
    @enforce_keys [:center, :reason]
    defstruct [:center, :filename, :pattern, :reason, :url, :http_status]
  end

  defmodule Contributor do
    @moduledoc """
    SP3 center that contributed a product to a merge.
    """
    @enforce_keys [:center, :filename, :date]
    defstruct [:center, :filename, :date, :issue, :pattern, :artifact_identity, :acquisition]

    @type t :: %__MODULE__{}
  end

  defmodule ArtifactIdentity do
    @moduledoc """
    Reproducible, secret-free identity of one exact merge input artifact.
    """
    @enforce_keys [
      :requested_identity,
      :resolved_identity,
      :distribution_source,
      :official_filename,
      :product_sha256,
      :product_byte_length,
      :archive_sha256,
      :archive_byte_length,
      :compression
    ]
    defstruct @enforce_keys

    @type t :: %__MODULE__{}
  end

  defmodule AcquisitionFacts do
    @moduledoc """
    Observations from one acquisition. These fields never affect merge identity.
    """
    @enforce_keys [:retrieved_at, :cache_hit]
    defstruct [
      :retrieved_at,
      :cache_hit,
      :original_url,
      :final_url,
      :etag,
      :last_modified,
      attempts: []
    ]

    @type t :: %__MODULE__{}
  end

  defmodule MergeReport do
    @moduledoc """
    Audit report for merged SP3 acquisition. `requested_centers` preserves the
    normalized caller order and authenticates the exact contributor/absent
    partition when a report is persisted and verified.
    """
    defstruct requested_centers: [],
              contributors: [],
              absent: [],
              source_count: 0,
              single_product: false,
              merged: false,
              merge_report: nil,
              input_identity_schema_version: nil,
              stable_input_identity: nil,
              merge_policy: nil

    @type t :: %__MODULE__{}
  end

  @doc """
  Default GNSS cache root.
  """
  @spec default_cache_dir() :: String.t()
  def default_cache_dir, do: default_cache_dir(:gnss)

  @doc """
  Default cache root for `:gnss` or `:terrain`.
  """
  @spec default_cache_dir(:gnss | :terrain) :: String.t()
  def default_cache_dir(kind) when kind in [:gnss, :terrain] do
    Path.join(user_cache_root(), Atom.to_string(kind))
  end

  @doc """
  Supported analysis-center codes.
  """
  @spec centers() :: [String.t()]
  def centers, do: NIF.data_centers()

  @doc """
  Supported GNSS product type codes.
  """
  @spec content_types() :: [String.t()]
  def content_types, do: NIF.data_content_types()

  @doc """
  Archive hosts allowed by the core catalog.
  """
  @spec allowed_hosts() :: [String.t()]
  def allowed_hosts, do: NIF.data_allowed_hosts()

  @doc "Resolve an exact GNSS product identity independently from its distributor."
  defdelegate identity(product), to: Distribution

  @doc "Build an exact GNSS request with an ordered caller-controlled source list."
  defdelegate request(product, sources), to: Distribution

  @doc "Build the official NASA CDDIS URL for an exact SP3 or IONEX identity."
  defdelegate cddis_url(identity), to: Distribution

  @doc "Require available identities to be exactly the declared product set."
  defdelegate validate_exact_product_set(expected, available), to: Distribution

  @doc "Acquire an exact GNSS product and return its path plus public provenance."
  defdelegate acquire(request, opts \\ []), to: Distribution

  @doc """
  GPS week number for a date.
  """
  @spec gps_week(Date.t() | NaiveDateTime.t() | tuple()) :: {:ok, non_neg_integer()} | {:error, error_reason()}
  def gps_week(date) do
    with {:ok, date} <- normalize_date(date) do
      core(NIF.data_gps_week(date.year, date.month, date.day))
    end
  end

  @doc """
  Day-of-year for a date.
  """
  @spec day_of_year(Date.t() | NaiveDateTime.t() | tuple()) :: {:ok, non_neg_integer()} | {:error, error_reason()}
  def day_of_year(date) do
    with {:ok, date} <- normalize_date(date) do
      core(NIF.data_day_of_year(date.year, date.month, date.day))
    end
  end

  @doc """
  Build a product specification for any supported center/product/date.
  """
  @spec product(term(), term(), Date.t() | NaiveDateTime.t() | tuple(), keyword()) ::
          {:ok, Product.t()} | {:error, error_reason()}
  def product(center, product_type, date, opts \\ []) do
    center = normalize_code(center)
    product_type = normalize_code(product_type)

    with {:ok, date} <- normalize_date(date),
         {:ok, sample} <- product_sample(center, product_type, opts),
         issue = Keyword.get(opts, :issue),
         issue = if(!is_nil(issue), do: to_string(issue)),
         product = %Product{center: center, product_type: product_type, date: date, sample: sample, issue: issue},
         {:ok, _filename} <- canonical_filename(product) do
      {:ok, product}
    end
  end

  @doc """
  Build an SP3 product.
  """
  def mgex_sp3(center, date, opts \\ []), do: product(center, :sp3, date, opts)

  @doc """
  Build a RINEX clock product.
  """
  def mgex_clk(center, date, opts \\ []), do: product(center, :clk, date, opts)

  @doc """
  Build a merged broadcast-navigation product.
  """
  def mgex_nav(center, date, opts \\ []), do: product(center, :nav, date, opts)

  @doc """
  Build an IONEX product.
  """
  def mgex_ionex(center, date, opts \\ []), do: product(center, :ionex, date, opts)

  @doc """
  Build the rapid IONEX product for a date.
  """
  def rapid_ionex(date, opts \\ []), do: product(:cod_rap, :ionex, date, opts)

  @doc """
  Build a predicted IONEX product.
  """
  def predicted_ionex(center, date, opts \\ []) do
    center = normalize_code(center)

    with {:ok, date} <- normalize_date(date),
         {:ok, offset} <- core(NIF.data_predicted_day_offset(center)) do
      product(center, :ionex, Date.add(date, offset), opts)
    end
  end

  @doc """
  Build an ultra-rapid OPS SP3 product.
  """
  def ops_ultra_sp3(center, target, opts \\ []) do
    center = normalize_code(center)

    with {:ok, sample} <- product_sample(center, "sp3", opts),
         {:ok, {date, issue}} <- ultra_target(center, target, Keyword.get(opts, :issue)) do
      product(center, :sp3, date, sample: sample, issue: issue)
    end
  end

  @doc """
  Canonical archive filename for a product.
  """
  @spec canonical_filename(Product.t()) :: {:ok, String.t()} | {:error, error_reason()}
  def canonical_filename(%Product{filename: filename}) when is_binary(filename), do: {:ok, filename}

  def canonical_filename(%Product{} = product) do
    date = product.date

    core(
      NIF.data_canonical_filename(
        product.center,
        product.product_type,
        date.year,
        date.month,
        date.day,
        product.sample,
        product.issue
      )
    )
  end

  def canonical_filename(center, product_type, date, opts \\ []) do
    with {:ok, product} <- product(center, product_type, date, opts) do
      canonical_filename(product)
    end
  end

  @doc """
  Full archive URL for a product.
  """
  @spec archive_url(Product.t()) :: {:ok, String.t()} | {:error, error_reason()}
  def archive_url(%Product{url: url}) when is_binary(url), do: {:ok, url}

  def archive_url(%Product{} = product) do
    date = product.date

    core(
      NIF.data_archive_url(
        product.center,
        product.product_type,
        date.year,
        date.month,
        date.day,
        product.sample,
        product.issue
      )
    )
  end

  def archive_url(center, product_type, date, opts \\ []) do
    with {:ok, product} <- product(center, product_type, date, opts) do
      archive_url(product)
    end
  end

  @doc """
  Derive the terrain tile index covering a coordinate.
  """
  def terrain_tile_index(lat_deg, lon_deg) when is_number(lat_deg) and is_number(lon_deg) do
    core(NIF.data_terrain_tile_index(lat_deg / 1.0, lon_deg / 1.0))
  end

  @doc """
  Derive a Skadi tile id.
  """
  def skadi_tile_id(lat_index, lon_index) when is_integer(lat_index) and is_integer(lon_index) do
    core(NIF.data_skadi_tile_id(lat_index, lon_index))
  end

  @doc """
  Derive a Skadi latitude band.
  """
  def skadi_band(lat_index) when is_integer(lat_index), do: core(NIF.data_skadi_band(lat_index))

  @doc """
  Derive a Skadi archive URL.
  """
  def skadi_archive_url(lat_index, lon_index) when is_integer(lat_index) and is_integer(lon_index) do
    core(NIF.data_skadi_archive_url(lat_index, lon_index))
  end

  @doc """
  Derive the DTED tile filename.
  """
  def dted_tile_filename(lat_index, lon_index) when is_integer(lat_index) and is_integer(lon_index) do
    core(NIF.data_dted_tile_filename(lat_index, lon_index))
  end

  @doc """
  Derive the DTED ten-degree block directory.
  """
  def dted_block_dir(lat_index, lon_index) when is_integer(lat_index) and is_integer(lon_index) do
    core(NIF.data_dted_block_dir(lat_index, lon_index))
  end

  @doc """
  Derive the DTED cache relative path.
  """
  def dted_cache_relpath(lat_index, lon_index) when is_integer(lat_index) and is_integer(lon_index) do
    core(NIF.data_dted_cache_relpath(lat_index, lon_index))
  end

  @doc """
  Derive a space-weather filename.
  """
  def space_weather_filename(product \\ :sw_all) do
    core(NIF.data_space_weather_filename(normalize_space_weather_product(product)))
  end

  @doc """
  Derive the space-weather archive URL.
  """
  def space_weather_archive_url(product \\ :sw_all) do
    core(NIF.data_space_weather_archive_url(normalize_space_weather_product(product)))
  end

  @doc """
  Derive the space-weather cache relative path.
  """
  def space_weather_cache_relpath(product \\ :sw_all) do
    core(NIF.data_space_weather_cache_relpath(normalize_space_weather_product(product)))
  end

  @doc """
  Parse a Skadi tile id.
  """
  def parse_skadi_tile_id(tile_id) when is_binary(tile_id), do: core(NIF.data_parse_skadi_tile_id(tile_id))

  @doc """
  Fetch a GNSS product and return the verified local file path.
  """
  @spec fetch(Product.t(), keyword()) :: {:ok, String.t()} | {:error, error_reason()}
  def fetch(%Product{} = product, opts \\ []) do
    with {:ok, filename} <- canonical_filename(product),
         cache_filename = product.cache_filename || filename,
         {:ok, path} <- safe_cache_path(resolve_cache_dir(opts, :gnss), [cache_filename]),
         {:ok, url} <- archive_url(product),
         {:ok, protocol} <- product_protocol(product.center),
         {:ok, compression} <- product_archive_compression(product) do
      case classify_data_file(path, Keyword.get(opts, :sha256)) do
        {:hit, _path} ->
          {:ok, path}

        {:absent, _} ->
          fetch_on_miss(product, path, url, protocol, compression, opts)

        {:unverified, _} ->
          fetch_on_miss(product, path, url, protocol, compression, opts)

        {:stale, reason} ->
          if truthy?(Keyword.get(opts, :offline)),
            do: {:error, reason},
            else: download_and_cache_gnss(product, path, url, protocol, compression, opts)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Fetch, verify, cache, and parse a space-weather product.
  """
  @spec fetch_space_weather(keyword()) :: {:ok, SpaceWeather.t()} | {:error, error_reason()}
  def fetch_space_weather(opts \\ []) do
    product = Keyword.get(opts, :product, :sw_all) |> normalize_space_weather_product()

    with {:ok, relpath} <- space_weather_cache_relpath(product),
         {:ok, path} <- safe_terrain_path(resolve_cache_dir(opts, :gnss), relpath),
         {:ok, url} <- space_weather_archive_url(product),
         {protocol, _host, compression, _root_url} <- NIF.data_space_weather_source_entry() do
      case classify_space_weather(path, Keyword.get(opts, :sha256), Keyword.get(opts, :max_age_s, 86_400.0), opts) do
        {:hit, _path} ->
          SpaceWeather.load(path)

        {:absent, _} ->
          fetch_space_weather_on_miss(product, path, url, protocol, compression, opts)

        {:unverified, _} ->
          fetch_space_weather_on_miss(product, path, url, protocol, compression, opts)

        {:stale, _reason} ->
          if truthy?(Keyword.get(opts, :offline)) do
            SpaceWeather.load(path)
          else
            download_and_cache_space_weather(product, path, url, protocol, compression, opts)
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Fetch the newest available IONEX candidate for a target date.
  """
  def fetch_ionex(center, target, opts \\ []) do
    center = normalize_code(center)
    lookback = Keyword.get(opts, :lookback, 2)

    with {:ok, date} <- normalize_date(target),
         {:ok, dates} <- core(NIF.data_gim_date_candidates(center, date.year, date.month, date.day, lookback)) do
      fetch_first_ionex(center, dates, opts, nil)
    end
  end

  @doc """
  Fetch SP3 products from several centers and merge the contributors.

  Ultra-rapid centers try the current primary duration/sampling pattern, known
  alternates, and documented latest-product aliases on archive 404s. Each
  successful contributor records the satisfying `:pattern` in the report.

  All `Sidereon.GNSS.SP3.merge/2` options are forwarded, including `:combine`,
  `:min_agree`, `:precedence_scope`, and `:outlier_reject`. A single successful
  contributor also passes through `SP3.merge/2`, so filters, target cadence, and
  validation behave consistently; its report has `single_product: true` and
  `merged: true`.
  """
  def fetch_merged_sp3(target, centers, opts \\ [])

  def fetch_merged_sp3(target, centers, opts) when is_list(centers) do
    normalized_centers = Enum.map(centers, &normalize_code/1)

    with :ok <- validate_centers(normalized_centers) do
      results =
        Enum.map(normalized_centers, fn center ->
          fetch_center_sp3(center, target, opts)
        end)

      contributors = Enum.filter(results, &match?({:ok, _info, _sp3}, &1))
      absent = Enum.filter(results, &match?({:absent, _info}, &1)) |> Enum.map(fn {:absent, info} -> info end)

      if contributors == [],
        do: {:error, {:no_products, absent}},
        else: merge_sp3_contributors(contributors, absent, normalized_centers, opts)
    end
  end

  def fetch_merged_sp3(_target, centers, _opts), do: {:error, {:unsupported_product, {:centers, centers}}}

  @doc """
  Fetch merged SP3 and write it to a file.
  """
  def fetch_merged_sp3_file(target, centers, path, opts \\ []) do
    with {:ok, written, _report} <-
           fetch_merged_sp3_file_with_report(target, centers, path, opts) do
      {:ok, written}
    end
  end

  @doc """
  Fetch and write merged SP3 while returning the complete acquisition report.
  """
  def fetch_merged_sp3_file_with_report(target, centers, path, opts \\ []) do
    with {:ok, sp3, report} <- fetch_merged_sp3(target, centers, opts),
         {:ok, written} <- write_sp3(sp3, path, opts) do
      {:ok, written, report}
    end
  end

  @doc """
  Convert a merged-SP3 report to a secret-free persistence map.

  The map never includes credentials, authorization headers, cache paths, or
  temporary paths. Recomputing `stable_input_identity` requires only the
  contributor artifact identities and `merge_policy` in this map.
  """
  def merge_report_to_map(%MergeReport{} = report) do
    %{
      schema_version: 1,
      requested_centers: report.requested_centers,
      input_identity_schema_version: report.input_identity_schema_version,
      stable_input_identity: report.stable_input_identity,
      merge_policy: report.merge_policy,
      source_count: report.source_count,
      single_product: report.single_product,
      merged: report.merged,
      contributors: Enum.map(report.contributors, &contributor_to_map/1),
      absent: Enum.map(report.absent, &absent_to_map/1),
      merge_report: merge_result_to_map(report.merge_report)
    }
  end

  @doc """
  Verify a merged-SP3 report or a decoded persistence map.

  This reconstructs no filename and reads no cache directory. It validates the
  complete persisted artifact records and merge policy through the shared Rust
  canonicalizer, then compares both the schema version and stable identity. All
  report and nested record schemas are exact: unknown, duplicated, coercive, or
  internally inconsistent fields fail closed.
  Maps returned by `merge_report_to_map/1`, including a JSON encode/decode
  round-trip with string keys, are accepted.
  """
  @spec verify_merge_report(MergeReport.t() | map()) :: :ok | {:error, term()}
  def verify_merge_report(%MergeReport{} = report) do
    report
    |> merge_report_to_map()
    |> verify_merge_report()
  end

  def verify_merge_report(report) when is_map(report) do
    fields = [
      :schema_version,
      :requested_centers,
      :input_identity_schema_version,
      :stable_input_identity,
      :merge_policy,
      :source_count,
      :single_product,
      :merged,
      :contributors,
      :absent,
      :merge_report
    ]

    with {:ok, values} <- exact_fields(report, fields, :report),
         :ok <- exact_value(values.schema_version, 1, :schema_version),
         true <- is_list(values.contributors) || {:error, {:invalid_field, :contributors}},
         true <- values.contributors != [] || {:error, {:invalid_field, :contributors}},
         {:ok, requested_centers} <- persisted_requested_centers(values.requested_centers),
         {:ok, artifacts, contributor_centers} <- persisted_contributors(values.contributors),
         {:ok, opts, normalized_policy, precedence} <- persisted_merge_policy(values.merge_policy),
         :ok <- validate_persisted_precedence(artifacts, precedence, opts),
         {:ok, recomputed} <- SP3.merge_input_identity(artifacts, opts),
         :ok <- verify_report_identity(values, recomputed, normalized_policy),
         :ok <- verify_report_counts(values, artifacts),
         {:ok, absent_centers} <- verify_absent(values.absent, contributor_centers),
         :ok <- verify_requested_partition(requested_centers, contributor_centers, absent_centers),
         :ok <- verify_merge_result(values.merge_report, length(artifacts)) do
      :ok
    else
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_merge_report}
    end
  end

  def verify_merge_report(_report), do: {:error, :invalid_merge_report}

  @doc """
  Write an SP3 product atomically.
  """
  def write_sp3(%SP3{} = sp3, path, opts \\ []) when is_binary(path) do
    data = SP3.to_iodata(sp3) |> IO.iodata_to_binary()
    data = if truthy?(Keyword.get(opts, :gzip)), do: :zlib.gzip(data), else: data

    with :ok <- ensure_dir(Path.dirname(Path.expand(path))),
         {:ok, tmp} <- write_temp(Path.dirname(Path.expand(path)), data),
         :ok <- rename_file(tmp, path) do
      {:ok, path}
    end
  end

  @doc """
  Fetch the DTED tile covering `lat_deg`, `lon_deg`.
  """
  def fetch_dted(lat_deg, lon_deg, opts \\ []) when is_number(lat_deg) and is_number(lon_deg) do
    with {:ok, {lat_index, lon_index}} <- terrain_tile_index(lat_deg, lon_deg),
         {:ok, result} <- fetch_dted_tile({lat_index, lon_index}, opts) do
      case result do
        {:cached, path} -> {:ok, path}
        {:fetched, path} -> {:ok, path}
        {:no_coverage, tile_id} -> no_coverage_result(tile_id, opts)
      end
    end
  end

  @doc """
  Prefetch all terrain tiles in an inclusive bounding box.
  """
  def prefetch_dted_bbox(bbox, opts \\ [])

  def prefetch_dted_bbox({min_lat, min_lon, max_lat, max_lon}, opts) do
    cond do
      not Enum.all?([min_lat, min_lon, max_lat, max_lon], &is_number/1) ->
        {:error, {:invalid_coordinate, min_lat, min_lon}}

      max_lat < min_lat or max_lon < min_lon ->
        {:error, {:invalid_bbox, {min_lat, min_lon, max_lat, max_lon}}}

      true ->
        with {:ok, {lat_min, lon_min}} <- terrain_tile_index(min_lat, min_lon),
             {:ok, {lat_max, lon_max}} <- terrain_tile_index(max_lat, max_lon) do
          tiles = for lat <- lat_min..lat_max, lon <- lon_min..lon_max, do: {lat, lon}
          prefetch_dted_tiles(tiles, opts)
        end
    end
  end

  def prefetch_dted_bbox(_bbox, _opts), do: {:error, {:invalid_bbox, :badarg}}

  @doc """
  Prefetch an explicit list of terrain tile indices or Skadi tile ids.
  """
  def prefetch_dted_tiles(tiles, opts \\ [])

  def prefetch_dted_tiles(tiles, opts) when is_list(tiles) do
    report =
      Enum.reduce(tiles, %TerrainFetchReport{}, fn tile, report ->
        case normalize_tile(tile) do
          {:ok, {lat_index, lon_index, tile_id}} ->
            case fetch_dted_tile({lat_index, lon_index}, Keyword.put(opts, :strict, false)) do
              {:ok, {:cached, path}} -> %{report | cached: [path | report.cached]}
              {:ok, {:fetched, path}} -> %{report | fetched: [path | report.fetched]}
              {:ok, {:no_coverage, id}} -> %{report | no_coverage: [id | report.no_coverage]}
              {:error, reason} -> %{report | errors: [{tile_id, reason} | report.errors]}
            end

          {:error, reason} ->
            %{report | errors: [{tile, reason} | report.errors]}
        end
      end)

    {:ok,
     %TerrainFetchReport{
       fetched: Enum.reverse(report.fetched),
       cached: Enum.reverse(report.cached),
       no_coverage: Enum.reverse(report.no_coverage),
       errors: Enum.reverse(report.errors)
     }}
  end

  def prefetch_dted_tiles(_tiles, _opts), do: {:error, {:unsupported_product, :tiles_not_list}}

  @doc """
  Populate a terrain cache from a bbox tuple or tile list.
  """
  def populate_terrain_cache(region, opts \\ [])

  def populate_terrain_cache({_, _, _, _} = bbox, opts), do: prefetch_dted_bbox(bbox, opts)
  def populate_terrain_cache(tiles, opts) when is_list(tiles), do: prefetch_dted_tiles(tiles, opts)
  def populate_terrain_cache(region, _opts), do: {:error, {:unsupported_product, {:region, region}}}

  defp fetch_on_miss(product, path, url, protocol, compression, opts) do
    if truthy?(Keyword.get(opts, :offline)) do
      {:error, :offline_cache_miss}
    else
      download_and_cache_gnss(product, path, url, protocol, compression, opts)
    end
  end

  defp fetch_space_weather_on_miss(product, path, url, protocol, compression, opts) do
    if truthy?(Keyword.get(opts, :offline)) do
      {:error, :offline_cache_miss}
    else
      download_and_cache_space_weather(product, path, url, protocol, compression, opts)
    end
  end

  defp download_and_cache_gnss(product, path, url, protocol, compression, opts) do
    with {:ok, downloaded} <- download(url, protocol, opts),
         {:ok, data} <- decompress_if_needed(downloaded, compression, max_decompressed_bytes(opts)),
         :ok <- verify_sha256(data, Keyword.get(opts, :sha256)),
         provenance = gnss_provenance(product, url, protocol, compression, downloaded, data),
         :ok <- commit_file(path, data, provenance) do
      {:ok, path}
    end
  end

  defp download_and_cache_space_weather(product, path, url, protocol, compression, opts) do
    with {:ok, downloaded} <- download(url, protocol, opts),
         {:ok, data} <- decompress_if_needed(downloaded, compression, max_decompressed_bytes(opts)),
         :ok <- verify_sha256(data, Keyword.get(opts, :sha256)),
         provenance = space_weather_provenance(product, url, protocol, compression, downloaded, data),
         :ok <- commit_file(path, data, provenance) do
      SpaceWeather.load(path)
    end
  end

  defp fetch_first_ionex(_center, [], _opts, nil), do: {:error, :offline_cache_miss}
  defp fetch_first_ionex(_center, [], _opts, last_error), do: {:error, last_error}

  defp fetch_first_ionex(center, [{year, month, day} | rest], opts, _last_error) do
    sample = Keyword.get(opts, :sample)

    with {:ok, date} <- Date.new(year, month, day),
         {:ok, product} <- product(center, :ionex, date, sample: sample),
         {:ok, request} <- request(product, [Distribution.direct()]) do
      case acquire(request, exact_ionex_opts(opts)) do
        {:ok, result} ->
          {:ok, result.path}

        {:error, :offline_cache_miss} ->
          fetch_first_ionex(center, rest, opts, :offline_cache_miss)

        {:error, {:product_not_published, 404, _} = reason} ->
          fetch_first_ionex(center, rest, opts, reason)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp exact_ionex_opts(opts) do
    opts
    |> Keyword.drop([:lookback, :sample])
    |> rename_option(:max_compressed_bytes, :max_archive_bytes)
    |> rename_option(:max_decompressed_bytes, :max_product_bytes)
  end

  defp rename_option(opts, old, new) do
    case Keyword.pop(opts, old) do
      {nil, opts} -> opts
      {value, opts} -> Keyword.put(opts, new, value)
    end
  end

  defp fetch_center_sp3(center, target, opts) do
    case sp3_candidates(center, target, opts) do
      {:ok, candidates} ->
        fetch_first_center_sp3(center, candidates, opts, {nil, []})

      {:error, {:unsupported_product, reason}} ->
        {:absent, %AbsentCenter{center: center, reason: reason_string({:unsupported_product, reason})}}

      {:error, reason} ->
        {:absent, %AbsentCenter{center: center, reason: reason_string(reason)}}
    end
  end

  defp fetch_first_center_sp3(center, [], _opts, {nil, []}),
    do: {:absent, %AbsentCenter{center: center, reason: "no_candidate"}}

  defp fetch_first_center_sp3(center, [], _opts, {{filename, pattern, candidate_url, reason}, _attempts}),
    do: {:absent, absent_center(center, filename, pattern, candidate_url, reason)}

  defp fetch_first_center_sp3(center, [product | rest], opts, {_last, attempts}) do
    {:ok, filename} = canonical_filename(product)
    {:ok, candidate_url} = archive_url(product)

    case Distribution.acquire_catalog_product(product, exact_sp3_opts(opts)) do
      {:ok, result} ->
        case SP3.load(result.path) do
          {:ok, sp3} ->
            {contributor_filename, contributor_pattern} = contributor_candidate(product, result.provenance)

            {:ok,
             %Contributor{
               center: center,
               filename: contributor_filename,
               date: product.date,
               issue: product.issue,
               pattern: contributor_pattern,
               artifact_identity: artifact_identity(result.provenance),
               acquisition: acquisition_facts(result.provenance, Enum.reverse(attempts))
             }, sp3}

          {:error, reason} ->
            {:absent, absent_center(center, filename, product.pattern || "canonical", candidate_url, reason)}
        end

      {:error, :offline_cache_miss} ->
        fetch_first_center_sp3(
          center,
          rest,
          opts,
          {
            {filename, product.pattern || "canonical", candidate_url, :offline_cache_miss},
            [candidate_attempt(:offline_cache_miss, candidate_url) | attempts]
          }
        )

      {:error, {:product_not_published, 404, _} = reason} ->
        fetch_first_center_sp3(
          center,
          rest,
          opts,
          {
            {filename, product.pattern || "canonical", candidate_url, reason},
            [candidate_attempt(reason, candidate_url) | attempts]
          }
        )

      {:error, reason} ->
        {:absent, absent_center(center, filename, product.pattern || "canonical", candidate_url, reason)}
    end
  end

  defp exact_sp3_opts(opts) do
    opts
    |> Keyword.drop([
      :systems,
      :epoch_interval_s,
      :position_tolerance_m,
      :clock_tolerance_s,
      :min_agree,
      :clock_min_common,
      :combine,
      :precedence_scope,
      :outlier_reject,
      :asserted_frame_label_sets,
      :helmert,
      :sample,
      :issue,
      :catalog_variants,
      :gzip
    ])
    |> rename_option(:max_compressed_bytes, :max_archive_bytes)
    |> rename_option(:max_decompressed_bytes, :max_product_bytes)
  end

  defp contributor_candidate(%Product{issue: issue} = product, provenance) when is_binary(issue) do
    NIF.data_ultra_sp3_locations(
      product.center,
      product.date.year,
      product.date.month,
      product.date.day,
      issue
    )
    |> core()
    |> case do
      {:ok, rows} ->
        case Enum.find(rows, fn {_pattern, _span, _sample, _filename, url, _compression} ->
               url == provenance.original_url
             end) do
          {pattern, _span, _sample, filename, _url, _compression} -> {filename, pattern}
          nil -> {product.filename || provenance.official_filename, product.pattern || "canonical"}
        end

      {:error, _reason} ->
        {product.filename || provenance.official_filename, product.pattern || "canonical"}
    end
  end

  defp contributor_candidate(product, provenance),
    do: {product.filename || provenance.official_filename, product.pattern || "canonical"}

  defp merge_sp3_contributors(contributors, absent, requested_centers, opts) do
    sources = Enum.map(contributors, fn {:ok, _info, sp3} -> sp3 end)
    infos = Enum.map(contributors, fn {:ok, info, _sp3} -> info end)

    merge_opts =
      Keyword.take(opts, [
        :systems,
        :epoch_interval_s,
        :position_tolerance_m,
        :clock_tolerance_s,
        :min_agree,
        :clock_min_common,
        :combine,
        :precedence_scope,
        :outlier_reject,
        :asserted_frame_label_sets,
        :helmert
      ])

    case SP3.merge(sources, merge_opts) do
      {:ok, merged, merge_report} ->
        artifacts = Enum.map(infos, &Map.from_struct(&1.artifact_identity))

        with {:ok, input_identity} <- SP3.merge_input_identity(artifacts, merge_opts) do
          {:ok, merged,
           %MergeReport{
             requested_centers: requested_centers,
             contributors: infos,
             absent: absent,
             source_count: length(infos),
             single_product: length(infos) == 1,
             merged: true,
             merge_report: merge_report,
             input_identity_schema_version: input_identity.schema_version,
             stable_input_identity: input_identity.stable_id,
             merge_policy: input_identity.merge_policy
           }}
        end

      {:error, reason} ->
        {:error, {:incompatible_sources, Enum.map(infos, & &1.center), reason}}
    end
  end

  defp artifact_identity(provenance) do
    %ArtifactIdentity{
      requested_identity: provenance.requested_identity,
      resolved_identity: provenance.resolved_identity,
      distribution_source: provenance.distribution_source,
      official_filename: provenance.official_filename,
      product_sha256: provenance.sha256,
      product_byte_length: provenance.byte_length,
      archive_sha256: provenance.archive_sha256,
      archive_byte_length: provenance.archive_byte_length,
      compression: provenance.archive_compression
    }
  end

  defp acquisition_facts(provenance, prior_attempts) do
    %AcquisitionFacts{
      retrieved_at: provenance.retrieved_at,
      cache_hit: provenance.cache_hit,
      original_url: provenance.original_url,
      final_url: provenance.final_url,
      etag: provenance.etag,
      last_modified: provenance.last_modified,
      attempts: prior_attempts ++ provenance.attempts
    }
  end

  defp candidate_attempt(reason, url) do
    {_response_url, status} = diagnostic_fields(reason)

    %Distribution.SourceFailure{
      source: :direct,
      error_type: candidate_error_type(reason),
      message: reason_string(reason),
      url: url,
      status: status
    }
  end

  defp candidate_error_type(:offline_cache_miss), do: :offline_cache_miss
  defp candidate_error_type({:product_not_published, _status, _url}), do: :product_not_published
  defp candidate_error_type(_reason), do: :acquisition

  defp contributor_to_map(%Contributor{} = contributor) do
    %{
      center: contributor.center,
      filename: contributor.filename,
      date: Date.to_iso8601(contributor.date),
      issue: contributor.issue,
      pattern: contributor.pattern,
      artifact_identity: artifact_identity_to_map(contributor.artifact_identity),
      acquisition: acquisition_to_map(contributor.acquisition)
    }
  end

  defp artifact_identity_to_map(%ArtifactIdentity{} = artifact) do
    artifact
    |> Map.from_struct()
    |> Map.update!(:requested_identity, &product_identity_to_map/1)
    |> Map.update!(:resolved_identity, &product_identity_to_map/1)
  end

  defp product_identity_to_map(identity) do
    identity
    |> Map.from_struct()
    |> Map.update!(:date, &Date.to_iso8601/1)
  end

  defp acquisition_to_map(%AcquisitionFacts{} = acquisition) do
    acquisition
    |> Map.from_struct()
    |> Map.update!(:attempts, fn attempts ->
      Enum.map(attempts, fn attempt -> Map.from_struct(attempt) end)
    end)
  end

  defp absent_to_map(%AbsentCenter{} = absent), do: Map.from_struct(absent)

  defp merge_result_to_map(nil), do: nil

  defp merge_result_to_map(report) when is_map(report) do
    Map.update!(report, :frame_reconciliations, fn reconciliations ->
      Enum.map(reconciliations, fn reconciliation ->
        Map.update!(reconciliation, :epoch_year_span, fn
          nil -> nil
          {first, last} -> [first, last]
          [first, last] -> [first, last]
        end)
      end)
    end)
  end

  defp merge_result_to_map(report), do: report

  defp persisted_contributors(contributors) do
    contributors
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], []}, fn {contributor, index}, {:ok, artifacts, centers} ->
      with {:ok, values} <-
             exact_fields(
               contributor,
               [:center, :filename, :date, :issue, :pattern, :artifact_identity, :acquisition],
               {:contributor, index}
             ),
           :ok <- nonempty_binary(values.center, {:contributor, index, :center}),
           :ok <- nonempty_binary(values.filename, {:contributor, index, :filename}),
           {:ok, date} <- persisted_date(values.date),
           :ok <- optional_binary(values.issue, {:contributor, index, :issue}),
           :ok <- nonempty_binary(values.pattern, {:contributor, index, :pattern}),
           {:ok, artifact} <- persisted_artifact(values.artifact_identity, index),
           {:ok, acquisition} <- persisted_acquisition(values.acquisition, index),
           :ok <-
             verify_contributor_metadata(
               %{values | date: date},
               artifact,
               acquisition,
               index
             ) do
        {:cont, {:ok, [artifact | artifacts], [values.center | centers]}}
      else
        {:error, _} = error -> {:halt, error}
        _error -> {:halt, {:error, {:invalid_merge_contributor, index}}}
      end
    end)
    |> case do
      {:ok, artifacts, centers} ->
        artifacts = Enum.reverse(artifacts)
        centers = Enum.reverse(centers)

        if length(centers) == MapSet.size(MapSet.new(centers)),
          do: {:ok, artifacts, centers},
          else: {:error, :duplicate_contributor_center}

      {:error, _reason} = error ->
        error
    end
  end

  defp persisted_requested_centers(centers) when is_list(centers) and centers != [] do
    with true <-
           Enum.all?(centers, &(is_binary(&1) and &1 != "")) ||
             {:error, {:invalid_field, :requested_centers}},
         true <-
           length(centers) == MapSet.size(MapSet.new(centers)) ||
             {:error, :duplicate_requested_center},
         :ok <- validate_centers(centers) do
      {:ok, centers}
    end
  end

  defp persisted_requested_centers(_centers), do: {:error, {:invalid_field, :requested_centers}}

  defp persisted_artifact(artifact, index) when is_map(artifact) do
    fields = [
      :requested_identity,
      :resolved_identity,
      :distribution_source,
      :official_filename,
      :product_sha256,
      :product_byte_length,
      :archive_sha256,
      :archive_byte_length,
      :compression
    ]

    with {:ok, values} <- exact_fields(artifact, fields, {:artifact, index}),
         {:ok, requested} <- persisted_product_identity(values.requested_identity, {:artifact, index, :requested}),
         {:ok, resolved} <- persisted_product_identity(values.resolved_identity, {:artifact, index, :resolved}),
         {:ok, source} <- persisted_source(values.distribution_source),
         :ok <- nonempty_binary(values.official_filename, {:artifact, index, :official_filename}),
         :ok <- valid_digest(values.product_sha256, {:artifact, index, :product_sha256}),
         :ok <- positive_integer(values.product_byte_length, {:artifact, index, :product_byte_length}),
         :ok <- valid_digest(values.archive_sha256, {:artifact, index, :archive_sha256}),
         :ok <- positive_integer(values.archive_byte_length, {:artifact, index, :archive_byte_length}),
         {:ok, compression} <- persisted_compression(values.compression) do
      {:ok,
       %{
         requested_identity: requested,
         resolved_identity: resolved,
         distribution_source: source,
         official_filename: values.official_filename,
         product_sha256: values.product_sha256,
         product_byte_length: values.product_byte_length,
         archive_sha256: values.archive_sha256,
         archive_byte_length: values.archive_byte_length,
         compression: compression
       }}
    end
  end

  defp persisted_artifact(_artifact, index), do: {:error, {:invalid_field, {:artifact, index}}}

  defp persisted_product_identity(identity, context) when is_map(identity) do
    fields = [
      :family,
      :analysis_center,
      :publisher,
      :solution_class,
      :campaign,
      :filename_version,
      :date,
      :issue,
      :span,
      :sample,
      :official_filename,
      :format,
      :format_version,
      :prediction_horizon_days
    ]

    with {:ok, values} <- exact_fields(identity, fields, context),
         :ok <- nonempty_binary(values.family, {context, :family}),
         :ok <- nonempty_binary(values.analysis_center, {context, :analysis_center}),
         :ok <- nonempty_binary(values.publisher, {context, :publisher}),
         :ok <- nonempty_binary(values.solution_class, {context, :solution_class}),
         :ok <- nonempty_binary(values.campaign, {context, :campaign}),
         :ok <- nonnegative_integer(values.filename_version, {context, :filename_version}),
         {:ok, date} <- persisted_date(values.date),
         :ok <- optional_binary(values.issue, {context, :issue}),
         :ok <- nonempty_binary(values.span, {context, :span}),
         :ok <- nonempty_binary(values.sample, {context, :sample}),
         :ok <- nonempty_binary(values.official_filename, {context, :official_filename}),
         :ok <- nonempty_binary(values.format, {context, :format}),
         :ok <- optional_binary(values.format_version, {context, :format_version}),
         :ok <- optional_nonnegative_integer(values.prediction_horizon_days, {context, :prediction_horizon_days}) do
      {:ok, struct!(Distribution.ProductIdentity, %{values | date: date})}
    end
  rescue
    _error -> {:error, {:invalid_field, context}}
  end

  defp persisted_product_identity(_identity, context), do: {:error, {:invalid_field, context}}

  defp persisted_acquisition(acquisition, index) when is_map(acquisition) do
    fields = [:retrieved_at, :cache_hit, :original_url, :final_url, :etag, :last_modified, :attempts]

    with {:ok, values} <- exact_fields(acquisition, fields, {:acquisition, index}),
         :ok <- valid_timestamp(values.retrieved_at, {:acquisition, index, :retrieved_at}),
         true <- is_boolean(values.cache_hit) || {:error, {:invalid_field, {:acquisition, index, :cache_hit}}},
         :ok <- public_url(values.original_url, {:acquisition, index, :original_url}),
         :ok <- public_url(values.final_url, {:acquisition, index, :final_url}),
         :ok <- optional_binary(values.etag, {:acquisition, index, :etag}),
         :ok <- optional_binary(values.last_modified, {:acquisition, index, :last_modified}),
         true <- is_list(values.attempts) || {:error, {:invalid_field, {:acquisition, index, :attempts}}},
         :ok <- persisted_attempts(values.attempts, index) do
      {:ok, values}
    end
  end

  defp persisted_acquisition(_acquisition, index), do: {:error, {:invalid_field, {:acquisition, index}}}

  @failure_types ~w(
    authentication_required authentication_failed authorization_denied product_not_published
    retired_endpoint redirect_policy_failure malformed_url transport http_status invalid_content_type
    error_document content_length_mismatch download_size_exceeded decompression_failed checksum_mismatch
    product_validation_failed cache_read_failed cache_write_failed offline_cache_miss unsupported_distribution
    acquisition unknown
  )

  defp persisted_attempts(attempts, contributor_index) do
    attempts
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {attempt, attempt_index}, :ok ->
      context = {:attempt, contributor_index, attempt_index}

      with {:ok, values} <- exact_fields(attempt, [:source, :error_type, :message, :url, :status], context),
           {:ok, _source} <- persisted_source(values.source),
           :ok <- failure_type(values.error_type, context),
           :ok <- nonempty_binary(values.message, {context, :message}),
           :ok <- public_url(values.url, {context, :url}),
           :ok <- optional_http_status(values.status, {context, :status}) do
        {:cont, :ok}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp failure_type(value, context) when is_atom(value), do: failure_type(Atom.to_string(value), context)
  defp failure_type(value, _context) when is_binary(value) and value in @failure_types, do: :ok
  defp failure_type(_value, context), do: {:error, {:invalid_field, {context, :error_type}}}

  defp verify_contributor_metadata(values, artifact, acquisition, index) do
    requested = artifact.requested_identity
    resolved = artifact.resolved_identity

    with true <- values.center == requested.analysis_center || {:error, {:contributor_mismatch, index, :center}},
         true <- values.center == resolved.analysis_center || {:error, {:contributor_mismatch, index, :center}},
         true <- values.date == requested.date || {:error, {:contributor_mismatch, index, :date}},
         true <- values.date == resolved.date || {:error, {:contributor_mismatch, index, :date}},
         true <- values.issue == requested.issue || {:error, {:contributor_mismatch, index, :issue}} do
      verify_contributor_catalog(values, artifact, acquisition, index)
    end
  end

  defp verify_contributor_catalog(%{pattern: pattern, filename: filename}, artifact, _acquisition, _index)
       when pattern in ["canonical", "requested_sample"] do
    if filename == artifact.official_filename,
      do: :ok,
      else: {:error, :contributor_filename_mismatch}
  end

  defp verify_contributor_catalog(values, artifact, acquisition, index) do
    identity = artifact.requested_identity

    with true <- identity.solution_class == "ultra_rapid" || {:error, {:contributor_mismatch, index, :pattern}},
         true <- is_binary(acquisition.original_url) || {:error, {:contributor_mismatch, index, :original_url}},
         {:ok, rows} <-
           core(
             NIF.data_ultra_sp3_locations(
               identity.analysis_center,
               identity.date.year,
               identity.date.month,
               identity.date.day,
               identity.issue
             )
           ),
         {pattern, span, sample, filename, url, compression} <-
           Enum.find(rows, fn {pattern, span, sample, filename, url, compression} ->
             pattern == values.pattern and filename == values.filename and
               span == identity.span and sample == identity.sample and
               url == acquisition.original_url and
               compression == Atom.to_string(artifact.compression)
           end),
         true <-
           pattern == values.pattern and filename == values.filename and url == acquisition.original_url and
             span == identity.span and sample == identity.sample and
             compression == Atom.to_string(artifact.compression) do
      :ok
    else
      _ -> {:error, {:contributor_mismatch, index, :catalog}}
    end
  end

  defp persisted_merge_policy(policy) when is_map(policy) do
    fields = [
      :position_tolerance_m,
      :clock_tolerance_s,
      :min_agree,
      :clock_min_common,
      :combine,
      :precedence_artifact_sha256,
      :precedence_scope,
      :outlier_reject,
      :epoch_interval_s,
      :systems,
      :asserted_frame_label_sets,
      :helmert
    ]

    with {:ok, values} <- exact_fields(policy, fields, :merge_policy),
         {:ok, position_tolerance_m} <- persisted_nonnegative_float(values.position_tolerance_m, :position_tolerance_m),
         {:ok, clock_tolerance_s} <- persisted_nonnegative_float(values.clock_tolerance_s, :clock_tolerance_s),
         :ok <- positive_integer(values.min_agree, {:merge_policy, :min_agree}),
         :ok <- positive_integer(values.clock_min_common, {:merge_policy, :clock_min_common}),
         {:ok, combine} <- persisted_combine(values.combine),
         {:ok, precedence_scope} <- persisted_precedence_scope(values.precedence_scope),
         {:ok, outlier_reject, outlier_map} <- persisted_outlier_reject(values.outlier_reject),
         {:ok, epoch_interval_s} <- persisted_epoch_interval(values.epoch_interval_s),
         {:ok, systems} <- persisted_systems(values.systems),
         {:ok, label_sets} <- persisted_label_sets(values.asserted_frame_label_sets),
         true <- is_boolean(values.helmert) || {:error, {:invalid_field, {:merge_policy, :helmert}}},
         :ok <- persisted_precedence_list(values.precedence_artifact_sha256) do
      opts = [
        position_tolerance_m: position_tolerance_m,
        clock_tolerance_s: clock_tolerance_s,
        min_agree: values.min_agree,
        clock_min_common: values.clock_min_common,
        combine: combine,
        precedence_scope: precedence_scope,
        outlier_reject: outlier_reject,
        epoch_interval_s: epoch_interval_s,
        asserted_frame_label_sets: label_sets,
        helmert: values.helmert
      ]

      opts = if systems == [], do: opts, else: Keyword.put(opts, :systems, systems)

      normalized = %{
        position_tolerance_m: position_tolerance_m,
        clock_tolerance_s: clock_tolerance_s,
        min_agree: values.min_agree,
        clock_min_common: values.clock_min_common,
        combine: Atom.to_string(combine),
        precedence_artifact_sha256: values.precedence_artifact_sha256,
        precedence_scope: Atom.to_string(precedence_scope),
        outlier_reject: outlier_map,
        epoch_interval_s: epoch_interval_s,
        systems: systems,
        asserted_frame_label_sets: label_sets,
        helmert: values.helmert
      }

      {:ok, opts, normalized, values.precedence_artifact_sha256}
    end
  end

  defp persisted_merge_policy(_policy), do: {:error, :invalid_merge_policy}

  defp validate_persisted_precedence(_artifacts, nil, opts) do
    if Keyword.fetch!(opts, :combine) == :precedence,
      do: {:error, :merge_precedence_mismatch},
      else: :ok
  end

  defp validate_persisted_precedence(artifacts, precedence, opts) when is_list(precedence) do
    if Keyword.fetch!(opts, :combine) == :precedence and
         Enum.map(artifacts, & &1.product_sha256) == precedence,
       do: :ok,
       else: {:error, :merge_precedence_mismatch}
  end

  defp validate_persisted_precedence(_artifacts, _precedence, _opts), do: {:error, :invalid_merge_policy}

  defp persisted_outlier_reject(nil), do: {:ok, nil, nil}

  defp persisted_outlier_reject(value) when is_map(value) do
    with {:ok, values} <-
           exact_fields(value, [:position_tolerance_m, :clock_tolerance_s], {:merge_policy, :outlier_reject}),
         {:ok, position} <- persisted_nonnegative_float(values.position_tolerance_m, :outlier_position_tolerance_m),
         {:ok, clock} <- persisted_nonnegative_float(values.clock_tolerance_s, :outlier_clock_tolerance_s) do
      {:ok, %{position_tolerance_m: position, clock_tolerance_s: clock},
       %{position_tolerance_m: position, clock_tolerance_s: clock}}
    end
  end

  defp persisted_outlier_reject(_value), do: {:error, :invalid_outlier_reject}

  defp persisted_nonnegative_float(value, field) when is_float(value) do
    if value >= 0.0 and value - value == 0.0,
      do: {:ok, if(value == 0.0, do: 0.0, else: value)},
      else: {:error, {:invalid_field, {:merge_policy, field}}}
  end

  defp persisted_nonnegative_float(_value, field), do: {:error, {:invalid_field, {:merge_policy, field}}}

  defp persisted_epoch_interval(nil), do: {:ok, nil}

  defp persisted_epoch_interval(value) when is_float(value) do
    rounded = Float.round(value)

    if value - value == 0.0 and rounded >= 1.0 and abs(value - rounded) <= 1.0e-9,
      do: {:ok, rounded},
      else: {:error, {:invalid_field, {:merge_policy, :epoch_interval_s}}}
  end

  defp persisted_epoch_interval(_value), do: {:error, {:invalid_field, {:merge_policy, :epoch_interval_s}}}

  defp persisted_systems(systems) when is_list(systems) do
    valid = Enum.all?(systems, &(&1 in ~w(G R E C J I S)))
    canonical = systems |> Enum.uniq() |> Enum.sort()

    if valid and systems == canonical,
      do: {:ok, systems},
      else: {:error, {:invalid_field, {:merge_policy, :systems}}}
  end

  defp persisted_systems(_systems), do: {:error, {:invalid_field, {:merge_policy, :systems}}}

  defp persisted_label_sets(label_sets) when is_list(label_sets) do
    with true <-
           Enum.all?(label_sets, fn labels ->
             is_list(labels) and length(labels) >= 2 and
               Enum.all?(labels, &(is_binary(&1) and String.trim(&1) == &1 and &1 != "")) and
               labels == labels |> Enum.uniq() |> Enum.sort()
           end) || {:error, {:invalid_field, {:merge_policy, :asserted_frame_label_sets}}},
         true <-
           label_sets == Enum.sort(label_sets) ||
             {:error, {:invalid_field, {:merge_policy, :asserted_frame_label_sets}}},
         true <-
           length(label_sets) == MapSet.size(MapSet.new(label_sets)) ||
             {:error, {:invalid_field, {:merge_policy, :asserted_frame_label_sets}}} do
      {:ok, label_sets}
    end
  end

  defp persisted_label_sets(_label_sets), do: {:error, {:invalid_field, {:merge_policy, :asserted_frame_label_sets}}}

  defp persisted_precedence_list(nil), do: :ok

  defp persisted_precedence_list(values) when is_list(values) do
    if values != [] and Enum.all?(values, &valid_digest_value?/1),
      do: :ok,
      else: {:error, {:invalid_field, {:merge_policy, :precedence_artifact_sha256}}}
  end

  defp persisted_precedence_list(_values), do: {:error, {:invalid_field, {:merge_policy, :precedence_artifact_sha256}}}

  defp persisted_date(date) when is_binary(date), do: Date.from_iso8601(date)
  defp persisted_date(_date), do: {:error, :invalid_date}

  defp persisted_source(value) when value in [:direct, "direct"], do: {:ok, :direct}
  defp persisted_source(value) when value in [:nasa_cddis, "nasa_cddis"], do: {:ok, :nasa_cddis}
  defp persisted_source(value) when value in [:local_file, "local_file"], do: {:ok, :local_file}
  defp persisted_source(value) when value in [:in_memory, "in_memory"], do: {:ok, :in_memory}
  defp persisted_source(_value), do: {:error, :invalid_distribution_source}

  defp persisted_compression(value) when value in [:gzip, "gzip"], do: {:ok, :gzip}
  defp persisted_compression(value) when value in [:none, "none"], do: {:ok, :none}
  defp persisted_compression(_value), do: {:error, :invalid_compression}

  defp persisted_combine(value) when value in [:mean, "mean"], do: {:ok, :mean}
  defp persisted_combine(value) when value in [:median, "median"], do: {:ok, :median}
  defp persisted_combine(value) when value in [:precedence, "precedence"], do: {:ok, :precedence}
  defp persisted_combine(_value), do: {:error, :invalid_merge_policy}

  defp persisted_precedence_scope(value) when value in [:cell, "cell"], do: {:ok, :cell}
  defp persisted_precedence_scope(value) when value in [:satellite_arc, "satellite_arc"], do: {:ok, :satellite_arc}
  defp persisted_precedence_scope(_value), do: {:error, :invalid_merge_policy}

  defp verify_report_identity(values, recomputed, normalized_policy) do
    cond do
      not is_integer(values.input_identity_schema_version) -> {:error, {:invalid_field, :input_identity_schema_version}}
      not is_binary(values.stable_input_identity) -> {:error, {:invalid_field, :stable_input_identity}}
      recomputed.schema_version != values.input_identity_schema_version -> {:error, :merge_input_identity_mismatch}
      recomputed.stable_id != values.stable_input_identity -> {:error, :merge_input_identity_mismatch}
      recomputed.merge_policy != normalized_policy -> {:error, :merge_policy_mismatch}
      true -> :ok
    end
  end

  defp verify_report_counts(values, artifacts) do
    count = length(artifacts)

    if is_integer(values.source_count) and values.source_count == count and
         is_boolean(values.single_product) and values.single_product == (count == 1) and
         values.merged == true do
      :ok
    else
      {:error, :merge_report_count_mismatch}
    end
  end

  defp verify_absent(absent, contributor_centers) when is_list(absent) do
    absent
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {entry, index}, {:ok, centers} ->
      fields = [:center, :filename, :pattern, :reason, :url, :http_status]

      with {:ok, values} <- exact_fields(entry, fields, {:absent, index}),
           :ok <- nonempty_binary(values.center, {:absent, index, :center}),
           :ok <- optional_binary(values.filename, {:absent, index, :filename}),
           :ok <- optional_binary(values.pattern, {:absent, index, :pattern}),
           :ok <- nonempty_binary(values.reason, {:absent, index, :reason}),
           :ok <- public_url(values.url, {:absent, index, :url}),
           :ok <- optional_http_status(values.http_status, {:absent, index, :http_status}),
           true <- values.center not in contributor_centers || {:error, :absent_contributor_overlap} do
        {:cont, {:ok, [values.center | centers]}}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, centers} ->
        centers = Enum.reverse(centers)

        if length(centers) == MapSet.size(MapSet.new(centers)),
          do: {:ok, centers},
          else: {:error, :duplicate_absent_center}

      {:error, _} = error ->
        error
    end
  end

  defp verify_absent(_absent, _contributor_centers), do: {:error, {:invalid_field, :absent}}

  defp verify_requested_partition(requested, contributors, absent) do
    contributor_set = MapSet.new(contributors)
    absent_set = MapSet.new(absent)

    cond do
      not MapSet.disjoint?(contributor_set, absent_set) ->
        {:error, :requested_center_partition_overlap}

      MapSet.union(contributor_set, absent_set) != MapSet.new(requested) ->
        {:error, :requested_center_partition_mismatch}

      contributors != Enum.filter(requested, &MapSet.member?(contributor_set, &1)) ->
        {:error, :contributor_order_mismatch}

      absent != Enum.filter(requested, &MapSet.member?(absent_set, &1)) ->
        {:error, :absent_order_mismatch}

      true ->
        :ok
    end
  end

  defp verify_merge_result(report, source_count) when is_map(report) do
    fields = [
      :frame_reconciliations,
      :quarantined,
      :single_source,
      :position_outliers,
      :clock_outliers,
      :agreement
    ]

    with {:ok, values} <- exact_fields(report, fields, :merge_result),
         :ok <- verify_frame_reconciliations(values.frame_reconciliations, source_count),
         :ok <- verify_flags(values.quarantined, source_count, :quarantined),
         :ok <- verify_flags(values.single_source, source_count, :single_source),
         :ok <- verify_flags(values.position_outliers, source_count, :position_outliers),
         :ok <- verify_flags(values.clock_outliers, source_count, :clock_outliers) do
      verify_agreement(values.agreement, source_count)
    end
  end

  defp verify_merge_result(_report, _source_count), do: {:error, {:invalid_field, :merge_result}}

  defp verify_flags(flags, source_count, kind) when is_list(flags) do
    flags
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {flag, index}, :ok ->
      context = {kind, index}

      with {:ok, values} <- exact_fields(flag, [:satellite, :jd_whole, :jd_fraction, :sources], context),
           :ok <- satellite_id(values.satellite, {context, :satellite}),
           :ok <- finite_float(values.jd_whole, {context, :jd_whole}),
           :ok <- finite_float(values.jd_fraction, {context, :jd_fraction}),
           :ok <- source_indices(values.sources, source_count, {context, :sources}) do
        {:cont, :ok}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp verify_flags(_flags, _source_count, kind), do: {:error, {:invalid_field, kind}}

  defp verify_agreement(agreement, source_count) when is_map(agreement) do
    fields = [:position_rms_m, :position_max_m, :clock_rms_s, :clock_max_s, :cells, :epochs]

    with {:ok, values} <- exact_fields(agreement, fields, :agreement),
         :ok <- optional_nonnegative_float(values.position_rms_m, {:agreement, :position_rms_m}),
         :ok <- optional_nonnegative_float(values.position_max_m, {:agreement, :position_max_m}),
         :ok <- optional_nonnegative_float(values.clock_rms_s, {:agreement, :clock_rms_s}),
         :ok <- optional_nonnegative_float(values.clock_max_s, {:agreement, :clock_max_s}),
         :ok <- verify_agreement_cells(values.cells, source_count) do
      verify_agreement_epochs(values.epochs)
    end
  end

  defp verify_agreement(_agreement, _source_count), do: {:error, {:invalid_field, :agreement}}

  defp verify_agreement_cells(cells, source_count) when is_list(cells) do
    cells
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {cell, index}, :ok ->
      context = {:agreement_cell, index}

      fields = [
        :satellite,
        :jd_whole,
        :jd_fraction,
        :position_members,
        :position_rms_m,
        :position_max_m,
        :clock_members,
        :clock_rms_s,
        :clock_max_s
      ]

      with {:ok, values} <- exact_fields(cell, fields, context),
           :ok <- satellite_id(values.satellite, {context, :satellite}),
           :ok <- finite_float(values.jd_whole, {context, :jd_whole}),
           :ok <- finite_float(values.jd_fraction, {context, :jd_fraction}),
           :ok <- bounded_count(values.position_members, source_count, {context, :position_members}, false),
           :ok <- nonnegative_float(values.position_rms_m, {context, :position_rms_m}),
           :ok <- nonnegative_float(values.position_max_m, {context, :position_max_m}),
           :ok <- bounded_count(values.clock_members, source_count, {context, :clock_members}, true),
           :ok <- optional_nonnegative_float(values.clock_rms_s, {context, :clock_rms_s}),
           :ok <- optional_nonnegative_float(values.clock_max_s, {context, :clock_max_s}),
           :ok <- verify_clock_metric_presence(values, context) do
        {:cont, :ok}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp verify_agreement_cells(_cells, _source_count), do: {:error, {:invalid_field, :agreement_cells}}

  defp verify_clock_metric_presence(%{clock_members: 0, clock_rms_s: nil, clock_max_s: nil}, _context), do: :ok

  defp verify_clock_metric_presence(%{clock_members: members, clock_rms_s: rms, clock_max_s: max}, _context)
       when members > 0 and is_float(rms) and is_float(max), do: :ok

  defp verify_clock_metric_presence(_values, context), do: {:error, {:invalid_field, {context, :clock_metrics}}}

  defp verify_agreement_epochs(epochs) when is_list(epochs) do
    epochs
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {epoch, index}, :ok ->
      context = {:agreement_epoch, index}
      fields = [:jd_whole, :jd_fraction, :satellites, :position_rms_m, :position_max_m, :clock_rms_s, :clock_max_s]

      with {:ok, values} <- exact_fields(epoch, fields, context),
           :ok <- finite_float(values.jd_whole, {context, :jd_whole}),
           :ok <- finite_float(values.jd_fraction, {context, :jd_fraction}),
           :ok <- nonnegative_integer(values.satellites, {context, :satellites}),
           :ok <- nonnegative_float(values.position_rms_m, {context, :position_rms_m}),
           :ok <- nonnegative_float(values.position_max_m, {context, :position_max_m}),
           :ok <- optional_nonnegative_float(values.clock_rms_s, {context, :clock_rms_s}),
           :ok <- optional_nonnegative_float(values.clock_max_s, {context, :clock_max_s}) do
        {:cont, :ok}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp verify_agreement_epochs(_epochs), do: {:error, {:invalid_field, :agreement_epochs}}

  defp verify_frame_reconciliations(reconciliations, source_count) when is_list(reconciliations) do
    reconciliations
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {reconciliation, index}, :ok ->
      case verify_frame_reconciliation(reconciliation, source_count, index) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp verify_frame_reconciliations(_reconciliations, _source_count),
    do: {:error, {:invalid_field, :frame_reconciliations}}

  defp verify_frame_reconciliation(reconciliation, source_count, index) do
    context = {:frame_reconciliation, index}

    fields = [
      :source_index,
      :source_label,
      :target_label,
      :method,
      :asserted_label_set,
      :source_frame,
      :target_frame,
      :catalog_source_frame,
      :catalog_target_frame,
      :catalog_inverse,
      :reference_epoch_year,
      :parameters,
      :rates,
      :provenance,
      :epoch_year_span,
      :records_affected,
      :identity
    ]

    with {:ok, values} <- exact_fields(reconciliation, fields, context),
         :ok <- source_index(values.source_index, source_count, {context, :source_index}),
         :ok <- nonempty_binary(values.source_label, {context, :source_label}),
         :ok <- nonempty_binary(values.target_label, {context, :target_label}),
         :ok <- reconciliation_method(values.method, {context, :method}),
         :ok <- optional_label_set(values.asserted_label_set, {context, :asserted_label_set}),
         :ok <- optional_binary(values.source_frame, {context, :source_frame}),
         :ok <- optional_binary(values.target_frame, {context, :target_frame}),
         :ok <- optional_binary(values.catalog_source_frame, {context, :catalog_source_frame}),
         :ok <- optional_binary(values.catalog_target_frame, {context, :catalog_target_frame}),
         true <- is_boolean(values.catalog_inverse) || {:error, {:invalid_field, {context, :catalog_inverse}}},
         :ok <- optional_float(values.reference_epoch_year, {context, :reference_epoch_year}),
         :ok <- optional_transform(values.parameters, :parameters, context),
         :ok <- optional_transform(values.rates, :rates, context),
         :ok <- optional_binary(values.provenance, {context, :provenance}),
         :ok <- optional_epoch_span(values.epoch_year_span, {context, :epoch_year_span}),
         :ok <- positive_integer(values.records_affected, {context, :records_affected}),
         true <- is_boolean(values.identity) || {:error, {:invalid_field, {context, :identity}}} do
      :ok
    end
  end

  defp reconciliation_method(value, _field)
       when value in [:asserted_equivalence, "asserted_equivalence", :helmert, "helmert"], do: :ok

  defp reconciliation_method(_value, field), do: {:error, {:invalid_field, field}}

  defp optional_label_set(nil, _field), do: :ok

  defp optional_label_set(labels, field) when is_list(labels) do
    if length(labels) >= 2 and Enum.all?(labels, &(is_binary(&1) and &1 != "")) and
         labels == labels |> Enum.uniq() |> Enum.sort(),
       do: :ok,
       else: {:error, {:invalid_field, field}}
  end

  defp optional_label_set(_labels, field), do: {:error, {:invalid_field, field}}

  defp optional_transform(nil, _kind, _context), do: :ok

  defp optional_transform(transform, kind, context) when is_map(transform) do
    {translation, scale, rotation} =
      case kind do
        :parameters -> {:translation_mm, :scale_ppb, :rotation_mas}
        :rates -> {:translation_mm_per_year, :scale_ppb_per_year, :rotation_mas_per_year}
      end

    with {:ok, values} <- exact_fields(transform, [translation, scale, rotation], {context, kind}),
         :ok <- float_vector(Map.fetch!(values, translation), {context, kind, translation}),
         :ok <- finite_float(Map.fetch!(values, scale), {context, kind, scale}) do
      float_vector(Map.fetch!(values, rotation), {context, kind, rotation})
    end
  end

  defp optional_transform(_transform, kind, context), do: {:error, {:invalid_field, {context, kind}}}

  defp optional_epoch_span(nil, _field), do: :ok

  defp optional_epoch_span([first, last], field) do
    with :ok <- finite_float(first, field),
         :ok <- finite_float(last, field),
         true <- first <= last || {:error, {:invalid_field, field}} do
      :ok
    end
  end

  defp optional_epoch_span(_span, field), do: {:error, {:invalid_field, field}}

  defp source_indices(indices, source_count, field) when is_list(indices) and indices != [] do
    if Enum.all?(indices, &(is_integer(&1) and &1 >= 0 and &1 < source_count)) and
         length(indices) == MapSet.size(MapSet.new(indices)),
       do: :ok,
       else: {:error, {:invalid_field, field}}
  end

  defp source_indices(_indices, _source_count, field), do: {:error, {:invalid_field, field}}

  defp source_index(value, source_count, _field) when is_integer(value) and value >= 0 and value < source_count, do: :ok

  defp source_index(_value, _source_count, field), do: {:error, {:invalid_field, field}}

  defp bounded_count(value, maximum, _field, allow_zero)
       when is_integer(value) and value <= maximum and ((allow_zero and value >= 0) or value > 0), do: :ok

  defp bounded_count(_value, _maximum, field, _allow_zero), do: {:error, {:invalid_field, field}}

  defp satellite_id(value, _field) when is_binary(value) do
    if String.match?(value, ~r/^[GRECJIS][0-9]{2,3}$/), do: :ok, else: {:error, :invalid_satellite_id}
  end

  defp satellite_id(_value, field), do: {:error, {:invalid_field, field}}

  defp float_vector(values, field) when is_list(values) and length(values) == 3 do
    if Enum.all?(values, &(finite_float(&1, field) == :ok)), do: :ok, else: {:error, {:invalid_field, field}}
  end

  defp float_vector(_values, field), do: {:error, {:invalid_field, field}}

  defp finite_float(value, _field) when is_float(value) and value - value == 0.0, do: :ok
  defp finite_float(_value, field), do: {:error, {:invalid_field, field}}

  defp optional_float(nil, _field), do: :ok
  defp optional_float(value, field), do: finite_float(value, field)

  defp nonnegative_float(value, field) when is_float(value) and value >= 0.0, do: finite_float(value, field)
  defp nonnegative_float(_value, field), do: {:error, {:invalid_field, field}}

  defp optional_nonnegative_float(nil, _field), do: :ok
  defp optional_nonnegative_float(value, field), do: nonnegative_float(value, field)

  defp exact_fields(map, fields, context) when is_map(map) do
    allowed = MapSet.new(Enum.flat_map(fields, &[&1, Atom.to_string(&1)]))

    with nil <- Enum.find(Map.keys(map), &(not MapSet.member?(allowed, &1))),
         nil <- Enum.find(fields, &(Map.has_key?(map, &1) and Map.has_key?(map, Atom.to_string(&1)))) do
      Enum.reduce_while(fields, {:ok, %{}}, fn field, {:ok, values} ->
        case Map.fetch(map, field) do
          {:ok, value} ->
            {:cont, {:ok, Map.put(values, field, value)}}

          :error ->
            case Map.fetch(map, Atom.to_string(field)) do
              {:ok, value} -> {:cont, {:ok, Map.put(values, field, value)}}
              :error -> {:halt, {:error, {:missing_field, context, field}}}
            end
        end
      end)
    else
      unknown when not is_nil(unknown) -> {:error, {:unknown_or_duplicate_field, context, unknown}}
    end
  end

  defp exact_fields(_map, _fields, context), do: {:error, {:invalid_field, context}}

  defp exact_value(value, expected, _field) when value === expected, do: :ok
  defp exact_value(_value, _expected, field), do: {:error, {:invalid_field, field}}

  defp nonempty_binary(value, _field) when is_binary(value) and byte_size(value) > 0, do: :ok
  defp nonempty_binary(_value, field), do: {:error, {:invalid_field, field}}

  defp optional_binary(nil, _field), do: :ok
  defp optional_binary(value, field), do: nonempty_binary(value, field)

  defp positive_integer(value, _field) when is_integer(value) and value > 0, do: :ok
  defp positive_integer(_value, field), do: {:error, {:invalid_field, field}}

  defp nonnegative_integer(value, _field) when is_integer(value) and value >= 0, do: :ok
  defp nonnegative_integer(_value, field), do: {:error, {:invalid_field, field}}

  defp optional_nonnegative_integer(nil, _field), do: :ok

  defp optional_nonnegative_integer(value, _field) when is_integer(value) and value >= 0, do: :ok

  defp optional_nonnegative_integer(_value, field), do: {:error, {:invalid_field, field}}

  defp valid_digest(value, _field) when is_binary(value) do
    if valid_digest_value?(value), do: :ok, else: {:error, :invalid_digest}
  end

  defp valid_digest(_value, field), do: {:error, {:invalid_field, field}}

  defp valid_digest_value?(value) do
    is_binary(value) and String.match?(value, ~r/^[0-9a-f]{64}$/)
  end

  defp valid_timestamp(value, field) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, _datetime, _offset} -> :ok
      _ -> {:error, {:invalid_field, field}}
    end
  end

  defp valid_timestamp(_value, field), do: {:error, {:invalid_field, field}}

  defp public_url(nil, _field), do: :ok

  defp public_url(value, field) when is_binary(value) do
    uri = URI.parse(value)

    if uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" and
         is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment),
       do: :ok,
       else: {:error, {:invalid_field, field}}
  end

  defp public_url(_value, field), do: {:error, {:invalid_field, field}}

  defp optional_http_status(nil, _field), do: :ok

  defp optional_http_status(value, _field) when is_integer(value) and value >= 100 and value <= 599, do: :ok

  defp optional_http_status(_value, field), do: {:error, {:invalid_field, field}}

  defp sp3_candidates(center, target, opts) do
    with {:ok, entry} <- center_entry(center),
         true <- "sp3" in entry.products || {:error, {:unsupported_product, "#{center}/sp3"}},
         {:ok, sample} <- product_sample(center, "sp3", opts) do
      cond do
        entry.issues != [] and match?(%NaiveDateTime{}, target) and is_nil(Keyword.get(opts, :issue)) ->
          with {:ok, rows} <- ultra_issue_rows(center, target) do
            build_sp3_candidates(center, rows, sample, not Keyword.has_key?(opts, :sample))
          end

        entry.issues != [] ->
          with {:ok, date} <- normalize_date(target) do
            issue = Keyword.get(opts, :issue, "0000") |> to_string()

            build_sp3_candidates(
              center,
              [{date.year, date.month, date.day, issue}],
              sample,
              not Keyword.has_key?(opts, :sample)
            )
          end

        true ->
          with {:ok, date} <- normalize_date(target),
               {:ok, product} <- product(center, :sp3, date, sample: sample) do
            {:ok, [product]}
          end
      end
    end
  end

  defp build_sp3_candidates(center, rows, sample, use_catalog_variants) do
    rows
    |> Enum.reduce_while({:ok, []}, fn {year, month, day, issue}, {:ok, acc} ->
      with {:ok, date} <- Date.new(year, month, day),
           {:ok, products} <-
             sp3_products_for_issue(center, date, issue, sample, use_catalog_variants) do
        {:cont, {:ok, [products | acc]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, groups} ->
        products =
          groups
          |> Enum.reverse()
          |> List.flatten()
          |> Enum.uniq_by(fn product ->
            product.url || {product.date, product.issue, product.sample}
          end)

        {:ok, products}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp sp3_products_for_issue(center, date, issue, _sample, true) do
    center
    |> NIF.data_ultra_sp3_locations(date.year, date.month, date.day, issue)
    |> core()
    |> case do
      {:ok, locations} ->
        {:ok,
         Enum.map(locations, fn {pattern, span, candidate_sample, filename, url, compression} ->
           %Product{
             center: center,
             product_type: "sp3",
             date: date,
             sample: candidate_sample,
             issue: issue,
             span: span,
             pattern: pattern,
             filename: filename,
             cache_filename: candidate_cache_filename(pattern, center, date, issue, filename),
             url: url,
             compression: compression
           }
         end)}

      {:error, _} = error ->
        error
    end
  end

  defp sp3_products_for_issue(center, date, issue, sample, false) do
    case product(center, :sp3, date, sample: sample, issue: issue) do
      {:ok, product} -> {:ok, [%{product | pattern: "requested_sample"}]}
      {:error, _} = error -> error
    end
  end

  defp ultra_target(center, %NaiveDateTime{} = target, nil) do
    with {:ok, [{year, month, day, issue} | _]} <- ultra_issue_rows(center, target),
         {:ok, date} <- Date.new(year, month, day) do
      {:ok, {date, issue}}
    else
      {:ok, []} -> {:error, {:unsupported_product, :no_ultra_issue}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ultra_target(_center, target, issue) do
    with {:ok, date} <- normalize_date(target) do
      {:ok, {date, (issue || "0000") |> to_string()}}
    end
  end

  defp ultra_issue_rows(center, %NaiveDateTime{} = target) do
    core(
      NIF.data_ultra_issue_candidates(
        center,
        target.year,
        target.month,
        target.day,
        target.hour,
        target.minute,
        target.second
      )
    )
  end

  defp fetch_dted_tile({lat_index, lon_index}, opts) do
    with {:ok, tile_id} <- skadi_tile_id(lat_index, lon_index),
         {:ok, relpath} <- dted_cache_relpath(lat_index, lon_index),
         {:ok, path} <- safe_terrain_path(resolve_cache_dir(opts, :terrain), relpath),
         {:ok, url} <- skadi_archive_url(lat_index, lon_index),
         {protocol, _host, compression, _root_url} <- NIF.data_skadi_source_entry() do
      marker = no_coverage_marker_path(path)

      case classify_terrain(path, marker, tile_id, url, protocol, Keyword.get(opts, :sha256)) do
        {:hit, _path} ->
          {:ok, {:cached, path}}

        {:no_coverage, ^tile_id} ->
          {:ok, {:no_coverage, tile_id}}

        {:absent, _} ->
          fetch_dted_on_miss(path, marker, tile_id, url, protocol, compression, lat_index, lon_index, opts)

        {:unverified, _} ->
          fetch_dted_on_miss(path, marker, tile_id, url, protocol, compression, lat_index, lon_index, opts)

        {:stale, reason} ->
          if truthy?(Keyword.get(opts, :offline)),
            do: {:error, reason},
            else: download_and_cache_dted(path, marker, tile_id, url, protocol, compression, lat_index, lon_index, opts)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp fetch_dted_on_miss(path, marker, tile_id, url, protocol, compression, lat_index, lon_index, opts) do
    if truthy?(Keyword.get(opts, :offline)) do
      {:error, :offline_cache_miss}
    else
      download_and_cache_dted(path, marker, tile_id, url, protocol, compression, lat_index, lon_index, opts)
    end
  end

  defp download_and_cache_dted(path, marker, tile_id, url, protocol, compression, lat_index, lon_index, opts) do
    case download(url, protocol, opts) do
      {:ok, hgt_gz} ->
        with {:ok, hgt} <- decompress_if_needed(hgt_gz, compression, max_decompressed_bytes(opts)),
             {:ok, dt2} <- core(NIF.data_hgt_to_dted(lat_index, lon_index, hgt)),
             :ok <- verify_sha256(dt2, Keyword.get(opts, :sha256)),
             provenance =
               terrain_provenance(url, protocol, compression, tile_id, lat_index, lon_index, hgt_gz, hgt, dt2),
             :ok <- commit_file(path, dt2, provenance),
             :ok <- remove_file(marker) do
          {:ok, {:fetched, path}}
        end

      {:error, {:not_found_on_archive, _}} ->
        with :ok <- commit_no_coverage_marker(marker, tile_id, url, protocol) do
          {:ok, {:no_coverage, tile_id}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp classify_terrain(path, marker, tile_id, url, protocol, expected_sha256) do
    case classify_data_file(path, expected_sha256) do
      {:absent, _} ->
        classify_marker(marker, tile_id, url, protocol)

      other ->
        other
    end
  end

  defp classify_marker(marker, tile_id, url, protocol) do
    case read_json(marker) do
      {:ok, %{"status" => 404, "tile_id" => ^tile_id, "source_url" => ^url, "protocol" => ^protocol}} ->
        {:no_coverage, tile_id}

      _ ->
        {:absent, nil}
    end
  end

  defp normalize_tile(tile_id) when is_binary(tile_id) do
    with {:ok, {lat_index, lon_index}} <- parse_skadi_tile_id(tile_id) do
      {:ok, {lat_index, lon_index, tile_id}}
    end
  end

  defp normalize_tile({lat_index, lon_index}) when is_integer(lat_index) and is_integer(lon_index) do
    with {:ok, tile_id} <- skadi_tile_id(lat_index, lon_index) do
      {:ok, {lat_index, lon_index, tile_id}}
    end
  end

  defp normalize_tile(tile), do: {:error, {:invalid_tile_id, inspect(tile)}}

  defp no_coverage_result(tile_id, opts) do
    if truthy?(Keyword.get(opts, :strict)),
      do: {:error, {:no_coverage, tile_id}},
      else: {:ok, {:no_coverage, tile_id}}
  end

  defp commit_no_coverage_marker(marker, tile_id, url, protocol) do
    payload = %{
      source_url: url,
      protocol: protocol,
      status: 404,
      tile_id: tile_id,
      fetched_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    with :ok <- ensure_dir(Path.dirname(marker)),
         {:ok, tmp} <- write_temp(Path.dirname(marker), Jason.encode!(payload, pretty: true)) do
      rename_file(tmp, marker)
    end
  end

  defp no_coverage_marker_path(path), do: path <> ".no_coverage.json"

  defp classify_data_file(path, expected_sha256) do
    case File.read(path) do
      {:ok, data} ->
        got = sha256(data)

        cond do
          is_binary(expected_sha256) and got == String.downcase(expected_sha256) ->
            {:hit, path}

          is_binary(expected_sha256) ->
            {:stale, {:checksum_mismatch, String.downcase(expected_sha256), got}}

          true ->
            classify_with_provenance(path, got)
        end

      {:error, :enoent} ->
        {:absent, nil}

      {:error, reason} ->
        {:error, {:cache_not_writable, {:read, path, reason}}}
    end
  end

  defp classify_space_weather(path, expected_sha256, max_age_s, opts) do
    case File.read(path) do
      {:ok, data} ->
        got = sha256(data)

        cond do
          is_binary(expected_sha256) and got == String.downcase(expected_sha256) ->
            {:hit, path}

          is_binary(expected_sha256) ->
            {:error, {:checksum_mismatch, String.downcase(expected_sha256), got}}

          true ->
            classify_space_weather_with_provenance(path, got, max_age_s, truthy?(Keyword.get(opts, :offline)))
        end

      {:error, :enoent} ->
        {:absent, nil}

      {:error, reason} ->
        {:error, {:cache_not_writable, {:read, path, reason}}}
    end
  end

  defp classify_space_weather_with_provenance(path, got, max_age_s, offline?) do
    case read_json(provenance_path(path)) do
      {:ok, provenance} ->
        expected = provenance["sha256_data"] || provenance["sha256_decompressed"]

        cond do
          is_binary(expected) and got != String.downcase(expected) ->
            {:error, {:checksum_mismatch, String.downcase(expected), got}}

          is_binary(expected) and (offline? or fresh_provenance?(provenance, max_age_s)) ->
            {:hit, path}

          is_binary(expected) ->
            {:stale, :expired}

          true ->
            {:unverified, path}
        end

      _ ->
        {:unverified, path}
    end
  end

  defp fresh_provenance?(%{"fetched_at" => fetched_at}, max_age_s) when is_number(max_age_s) do
    case DateTime.from_iso8601(fetched_at) do
      {:ok, dt, _offset} -> DateTime.diff(DateTime.utc_now(), dt, :second) <= max_age_s
      _ -> false
    end
  end

  defp fresh_provenance?(_provenance, _max_age_s), do: false

  defp classify_with_provenance(path, got) do
    case read_json(provenance_path(path)) do
      {:ok, provenance} ->
        expected = provenance["sha256_data"] || provenance["sha256_decompressed"]

        cond do
          is_binary(expected) and got == String.downcase(expected) ->
            {:hit, path}

          is_binary(expected) ->
            {:stale, {:checksum_mismatch, String.downcase(expected), got}}

          true ->
            {:unverified, path}
        end

      _ ->
        {:unverified, path}
    end
  end

  defp read_json(path) do
    with {:ok, bytes} <- File.read(path),
         {:ok, json} <- Jason.decode(bytes) do
      {:ok, json}
    else
      _ -> :error
    end
  end

  defp download(url, protocol, opts) do
    with :ok <- check_host(url, protocol) do
      do_download(url, opts, 1)
    end
  end

  defp do_download(url, opts, attempt) do
    retries = Keyword.get(opts, :retries, @default_retries)

    case download_once(url, opts) do
      {:ok, body} ->
        if byte_size(body) > max_compressed_bytes(opts),
          do: {:error, {:download_size_exceeded, max_compressed_bytes(opts)}},
          else: {:ok, body}

      {:error, {:http_status, status, _}} when (status in [408, 429] or status >= 500) and attempt < retries ->
        sleep_backoff(opts, attempt)
        do_download(url, opts, attempt + 1)

      {:error, {:network, _}} when attempt < retries ->
        sleep_backoff(opts, attempt)
        do_download(url, opts, attempt + 1)

      other ->
        other
    end
  end

  defp download_once(url, opts), do: do_download_once(url, opts, 0)

  defp do_download_once(url, opts, redirect_count) do
    case Keyword.get(opts, :http_client) do
      fun when is_function(fun, 2) ->
        fun.(url, opts)
        |> normalize_http_response(url)
        |> handle_http_response(url, opts, redirect_count)

      nil ->
        url
        |> req_download(opts)
        |> handle_http_response(url, opts, redirect_count)
    end
  rescue
    e -> {:error, {:network, Exception.message(e)}}
  catch
    kind, reason -> {:error, {:network, {kind, reason}}}
  end

  defp req_download(url, opts) do
    timeout_ms = opts |> Keyword.get(:timeout, Keyword.get(opts, :timeout_s, @default_timeout_s)) |> seconds_to_ms()

    case Req.get(
           url: url,
           redirect: false,
           retry: false,
           receive_timeout: timeout_ms,
           finch: :"Elixir.Sidereon.GNSS.Data.Finch",
           decode_body: false
         ) do
      {:ok, %Req.Response{status: status, headers: headers, body: body}} ->
        {:ok, status, headers, IO.iodata_to_binary(body)}

      {:error, reason} ->
        {:error, {:network, reason}}
    end
  end

  defp normalize_http_response({:ok, %{status: status, body: body} = response}, _url),
    do: {:ok, status, Map.get(response, :headers, []), IO.iodata_to_binary(body)}

  defp normalize_http_response({:ok, status, headers, body}, _url) when is_integer(status),
    do: {:ok, status, headers, IO.iodata_to_binary(body)}

  defp normalize_http_response({:ok, status, body}, _url) when is_integer(status),
    do: {:ok, status, [], IO.iodata_to_binary(body)}

  defp normalize_http_response({:error, reason}, _url), do: {:error, {:network, reason}}
  defp normalize_http_response(other, _url), do: {:error, {:network, {:bad_http_response, other}}}

  defp handle_http_response({:ok, status, headers, body}, url, opts, redirect_count) do
    cond do
      status in 200..299 ->
        {:ok, body}

      status == 404 ->
        {:error, {:not_found_on_archive, url}}

      status in 300..399 ->
        with true <- redirect_count < @max_redirects,
             location when is_binary(location) <- header_value(headers, "location"),
             {:ok, target_url} <- validated_redirect_url(url, status, location) do
          do_download_once(target_url, opts, redirect_count + 1)
        else
          _ -> {:error, {:redirect_not_allowed, status, url}}
        end

      true ->
        {:error, {:http_status, status, url}}
    end
  end

  defp handle_http_response({:error, _} = error, _url, _opts, _redirect_count), do: error

  defp validated_redirect_url(source_url, status, location) do
    source = URI.parse(source_url)
    target = URI.merge(source_url, location)
    source_host = source.host && String.downcase(source.host)
    target_host = target.host && String.downcase(target.host)

    allowed? =
      source.scheme == "https" and target.scheme == "https" and
        ((source_host == @aiub_web_host and target_host == @aiub_download_host) or
           (source_host in [@aiub_web_host, @aiub_download_host] and
              is_binary(target_host) and String.ends_with?(target_host, @aiub_object_store_suffix)))

    if allowed?,
      do: {:ok, URI.to_string(target)},
      else: {:error, {:redirect_not_allowed, status, source_url}}
  end

  defp header_value(headers, name) when is_map(headers) do
    headers
    |> Enum.find_value(fn {key, value} ->
      if String.downcase(to_string(key)) == name, do: first_header_value(value)
    end)
  end

  defp header_value(headers, name) when is_list(headers) do
    Enum.find_value(headers, fn
      {key, value} ->
        if String.downcase(to_string(key)) == name, do: first_header_value(value)

      _ ->
        nil
    end)
  end

  defp header_value(_headers, _name), do: nil

  defp first_header_value([value | _]), do: IO.iodata_to_binary(value)
  defp first_header_value(value) when is_binary(value), do: value
  defp first_header_value(_value), do: nil

  defp check_host(url, protocol) do
    uri = URI.parse(url)

    cond do
      uri.host not in allowed_hosts() ->
        {:error, {:network, {:host_not_allowed, uri.host}}}

      uri.scheme != protocol ->
        {:error, {:network, {:scheme_mismatch, uri.scheme, protocol, url}}}

      true ->
        :ok
    end
  end

  defp decompress_if_needed(data, "gzip", max_bytes) do
    decompressed = :zlib.gunzip(data)

    if byte_size(decompressed) > max_bytes,
      do: {:error, {:decompress, {:decompressed_size_exceeded, max_bytes}}},
      else: {:ok, decompressed}
  rescue
    e in ErlangError -> {:error, {:decompress, e.original}}
  end

  defp decompress_if_needed(data, "none", max_bytes) do
    if byte_size(data) > max_bytes,
      do: {:error, {:decompress, {:decompressed_size_exceeded, max_bytes}}},
      else: {:ok, data}
  end

  defp decompress_if_needed(_data, compression, _max_bytes),
    do: {:error, {:decompress, {:unknown_compression, compression}}}

  defp verify_sha256(_data, nil), do: :ok

  defp verify_sha256(data, expected) when is_binary(expected) do
    got = sha256(data)
    if got == String.downcase(expected), do: :ok, else: {:error, {:checksum_mismatch, String.downcase(expected), got}}
  end

  defp verify_sha256(_data, expected), do: {:error, {:checksum_mismatch, inspect(expected), ""}}

  defp commit_file(path, data, provenance) do
    directory = Path.dirname(path)
    sidecar = provenance_path(path)
    json = Jason.encode!(provenance, pretty: true)

    with :ok <- ensure_dir(directory),
         {:ok, data_tmp} <- write_temp(directory, data),
         {:ok, provenance_tmp} <- write_temp(directory, json),
         :ok <- rename_file(provenance_tmp, sidecar) do
      rename_file(data_tmp, path)
    end
  end

  defp ensure_dir(directory) do
    case File.mkdir_p(directory) do
      :ok -> :ok
      {:error, reason} -> {:error, {:cache_not_writable, {:mkdir, directory, reason}}}
    end
  end

  defp write_temp(directory, data) do
    path = Path.join(directory, ".tmp-#{System.unique_integer([:positive, :monotonic])}-#{System.os_time(:nanosecond)}")

    case :file.open(String.to_charlist(path), [:write, :binary, :exclusive]) do
      {:ok, io} ->
        with :ok <- :file.write(io, data),
             :ok <- :file.sync(io),
             :ok <- :file.close(io) do
          {:ok, path}
        else
          {:error, reason} ->
            :file.close(io)
            remove_file(path)
            {:error, {:cache_not_writable, {:write, path, reason}}}
        end

      {:error, reason} ->
        {:error, {:cache_not_writable, {:open, path, reason}}}
    end
  end

  defp rename_file(from, to) do
    case File.rename(from, to) do
      :ok -> :ok
      {:error, reason} -> {:error, {:cache_not_writable, {:rename, from, to, reason}}}
    end
  end

  defp remove_file(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp safe_cache_path(root, [filename]) do
    with :ok <- validate_cache_component(filename) do
      {:ok, Path.join(root, filename)}
    end
  end

  defp safe_terrain_path(root, relpath) do
    case Path.split(relpath) do
      [block, filename] ->
        with :ok <- validate_cache_component(block),
             :ok <- validate_cache_component(filename) do
          {:ok, Path.join([root, block, filename])}
        end

      _ ->
        {:error, {:cache_not_writable, {:unsafe_cache_path, relpath}}}
    end
  end

  defp validate_cache_component(component) when is_binary(component) and component not in ["", ".", ".."] do
    if String.contains?(component, ["/", "\\", "\0", ".."]) or Path.type(component) == :absolute do
      {:error, {:cache_not_writable, {:unsafe_cache_name, component}}}
    else
      :ok
    end
  end

  defp validate_cache_component(component), do: {:error, {:cache_not_writable, {:unsafe_cache_name, component}}}

  defp gnss_provenance(product, url, protocol, compression, downloaded, data) do
    digest = sha256(data)

    %{
      source_url: url,
      protocol: protocol,
      compression: compression,
      sha256_data: digest,
      size_data: byte_size(data),
      sha256_downloaded: sha256(downloaded),
      sha256_compressed: sha256(downloaded),
      sha256_decompressed: digest,
      size_downloaded: byte_size(downloaded),
      size_compressed: byte_size(downloaded),
      size_decompressed: byte_size(data),
      center: product.center,
      product_type: product.product_type,
      fetched_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      fetcher: "Sidereon.GNSS.Data"
    }
  end

  defp terrain_provenance(url, protocol, compression, tile_id, lat_index, lon_index, hgt_gz, hgt, dt2) do
    digest = sha256(dt2)

    %{
      source_url: url,
      protocol: protocol,
      compression: compression,
      sha256_data: digest,
      size_data: byte_size(dt2),
      sha256_hgt_gz: sha256(hgt_gz),
      sha256_hgt: sha256(hgt),
      sha256_dt2: digest,
      size_downloaded: byte_size(hgt_gz),
      size_compressed: byte_size(hgt_gz),
      size_decompressed: byte_size(hgt),
      size_dt2: byte_size(dt2),
      converter: "sidereon-core hgt_to_dted v1",
      tile_id: tile_id,
      lat_index: lat_index,
      lon_index: lon_index,
      fetched_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      fetcher: "Sidereon.GNSS.Data"
    }
  end

  defp space_weather_provenance(product, url, protocol, compression, downloaded, data) do
    digest = sha256(data)

    %{
      source_url: url,
      protocol: protocol,
      compression: compression,
      sha256_data: digest,
      size_data: byte_size(data),
      sha256_downloaded: sha256(downloaded),
      size_downloaded: byte_size(downloaded),
      product: product,
      fetched_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      fetcher: "Sidereon.GNSS.Data"
    }
  end

  defp provenance_path(path), do: path <> ".provenance.json"
  defp sha256(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

  defp max_compressed_bytes(opts), do: Keyword.get(opts, :max_compressed_bytes, @default_max_compressed_bytes)
  defp max_decompressed_bytes(opts), do: Keyword.get(opts, :max_decompressed_bytes, @default_max_decompressed_bytes)

  defp resolve_cache_dir(opts, kind) do
    case Keyword.get(opts, :cache_dir) do
      nil -> default_cache_dir(kind)
      path when is_binary(path) -> path
      path -> to_string(path)
    end
  end

  defp sleep_backoff(opts, attempt) do
    backoff_s = Keyword.get(opts, :backoff, Keyword.get(opts, :backoff_s, @default_backoff_s))
    Process.sleep(round(backoff_s * :math.pow(2, attempt - 1) * 1000))
  end

  defp seconds_to_ms(ms) when is_integer(ms) and ms > 1000, do: ms
  defp seconds_to_ms(seconds) when is_number(seconds), do: round(seconds * 1000)
  defp seconds_to_ms(_), do: round(@default_timeout_s * 1000)

  defp product_sample(center, product_type, opts) do
    case Keyword.fetch(opts, :sample) do
      {:ok, sample} when not is_nil(sample) -> {:ok, to_string(sample)}
      _ -> core(NIF.data_default_sample(center, product_type))
    end
  end

  defp product_protocol(center) do
    with {:ok, entry} <- center_entry(center), do: {:ok, entry.protocol}
  end

  defp center_entry(center) do
    case core(NIF.data_center_entry(center)) do
      {:ok, {protocol, host, root_url, products, issues}} ->
        {:ok, %{protocol: protocol, host: host, root_url: root_url, products: products, issues: issues}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_centers(centers) do
    normalized = Enum.map(centers, &normalize_code/1)

    if length(normalized) == MapSet.size(MapSet.new(normalized)) do
      Enum.reduce_while(normalized, :ok, fn center, :ok ->
        case center_entry(center) do
          {:ok, _} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    else
      {:error, {:unsupported_product, {:duplicate_centers, normalized}}}
    end
  end

  defp normalize_date(%Date{} = date), do: {:ok, date}
  defp normalize_date(%NaiveDateTime{} = datetime), do: {:ok, NaiveDateTime.to_date(datetime)}
  defp normalize_date({year, month, day}), do: Date.new(year, month, day)
  defp normalize_date({{year, month, day}, _time}), do: Date.new(year, month, day)
  defp normalize_date(other), do: {:error, {:unsupported_product, {:date, other}}}

  defp normalize_code(value) when is_atom(value), do: value |> Atom.to_string() |> String.replace("-", "_")
  defp normalize_code(value) when is_binary(value), do: value
  defp normalize_code(value), do: to_string(value)

  defp normalize_space_weather_product(:all), do: "sw_all"
  defp normalize_space_weather_product(:last5), do: "sw_last5"
  defp normalize_space_weather_product(:last_5_years), do: "sw_last5"
  defp normalize_space_weather_product(value), do: normalize_code(value)

  defp core({:ok, value}), do: {:ok, value}
  defp core({:error, reason}), do: {:error, reason}
  defp core(value), do: {:ok, value}

  defp product_archive_compression(%Product{compression: compression}) when is_binary(compression),
    do: {:ok, compression}

  defp product_archive_compression(%Product{} = product),
    do: core(NIF.data_archive_compression(product.center, product.product_type))

  defp candidate_cache_filename("alias_" <> _, center, date, issue, filename) do
    compact_date = date |> Date.to_iso8601() |> String.replace("-", "")
    "#{center}_#{compact_date}_#{issue}_#{filename}"
  end

  defp candidate_cache_filename(_pattern, _center, _date, _issue, _filename), do: nil

  defp absent_center(center, filename, pattern, candidate_url, reason) do
    {_response_url, http_status} = diagnostic_fields(reason)

    %AbsentCenter{
      center: center,
      filename: filename,
      pattern: pattern,
      reason: reason_string(reason),
      url: candidate_url,
      http_status: http_status
    }
  end

  defp diagnostic_fields({:not_found_on_archive, url}), do: {url, 404}
  defp diagnostic_fields({:product_not_published, status, url}), do: {url, status}
  defp diagnostic_fields({:http_status, status, url}), do: {url, status}
  defp diagnostic_fields(_reason), do: {nil, nil}

  defp reason_string(:offline_cache_miss), do: "offline_miss"
  defp reason_string({:not_found_on_archive, _}), do: "candidate_not_found"
  defp reason_string({:product_not_published, 404, _}), do: "candidate_not_found"
  defp reason_string({:product_not_published, status, _}), do: "product_not_published:#{status}"
  defp reason_string({:checksum_mismatch, _, _}), do: "checksum"
  defp reason_string({:http_status, status, _}), do: "http_status:#{status}"
  defp reason_string(reason), do: inspect(reason)

  defp truthy?(value), do: value in [true, "true", "1", 1]

  defp user_cache_root do
    cond do
      function_exported?(:filename, :basedir, 2) ->
        case :filename.basedir(:user_cache, "sidereon") do
          path when is_binary(path) -> path
          path when is_list(path) -> List.to_string(path)
        end

      is_binary(System.get_env("XDG_CACHE_HOME")) ->
        Path.join(System.fetch_env!("XDG_CACHE_HOME"), "sidereon")

      true ->
        Path.join([System.user_home!(), ".cache", "sidereon"])
    end
  end
end
