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

  alias Sidereon.GNSS.SP3
  alias Sidereon.NIF

  @default_max_compressed_bytes 64 * 1024 * 1024
  @default_max_decompressed_bytes 500 * 1024 * 1024
  @default_timeout_s 30.0
  @default_retries 3
  @default_backoff_s 0.5

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

  defmodule Product do
    @moduledoc """
    Pure identity for one GNSS archive product.
    """
    @enforce_keys [:center, :product_type, :date, :sample]
    defstruct [:center, :product_type, :date, :sample, :issue]

    @type t :: %__MODULE__{
            center: String.t(),
            product_type: String.t(),
            date: Date.t(),
            sample: String.t(),
            issue: String.t() | nil
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
    defstruct [:center, :filename, :reason]
  end

  defmodule Contributor do
    @moduledoc """
    SP3 center that contributed a product to a merge.
    """
    @enforce_keys [:center, :filename, :date]
    defstruct [:center, :filename, :date, :issue]
  end

  defmodule MergeReport do
    @moduledoc """
    Audit report for merged SP3 acquisition.
    """
    defstruct contributors: [],
              absent: [],
              source_count: 0,
              single_product: false,
              merged: false,
              merge_report: nil
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
  Parse a Skadi tile id.
  """
  def parse_skadi_tile_id(tile_id) when is_binary(tile_id), do: core(NIF.data_parse_skadi_tile_id(tile_id))

  @doc """
  Fetch a GNSS product and return the verified local file path.
  """
  @spec fetch(Product.t(), keyword()) :: {:ok, String.t()} | {:error, error_reason()}
  def fetch(%Product{} = product, opts \\ []) do
    with {:ok, filename} <- canonical_filename(product),
         {:ok, path} <- safe_cache_path(resolve_cache_dir(opts, :gnss), [filename]),
         {:ok, url} <- archive_url(product),
         {:ok, protocol} <- product_protocol(product.center),
         {:ok, compression} <- core(NIF.data_archive_compression(product.center, product.product_type)) do
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
  """
  def fetch_merged_sp3(target, centers, opts \\ [])

  def fetch_merged_sp3(target, centers, opts) when is_list(centers) do
    with :ok <- validate_centers(centers) do
      results =
        Enum.map(centers, fn center ->
          fetch_center_sp3(normalize_code(center), target, opts)
        end)

      contributors = Enum.filter(results, &match?({:ok, _info, _sp3}, &1))
      absent = Enum.filter(results, &match?({:absent, _info}, &1)) |> Enum.map(fn {:absent, info} -> info end)

      cond do
        contributors == [] ->
          {:error, {:no_products, absent}}

        length(contributors) == 1 ->
          [{:ok, info, sp3}] = contributors

          {:ok, sp3,
           %MergeReport{
             contributors: [info],
             absent: absent,
             source_count: 1,
             single_product: true,
             merged: false
           }}

        true ->
          merge_sp3_contributors(contributors, absent, opts)
      end
    end
  end

  def fetch_merged_sp3(_target, centers, _opts), do: {:error, {:unsupported_product, {:centers, centers}}}

  @doc """
  Fetch merged SP3 and write it to a file.
  """
  def fetch_merged_sp3_file(target, centers, path, opts \\ []) do
    with {:ok, sp3, _report} <- fetch_merged_sp3(target, centers, opts) do
      write_sp3(sp3, path, opts)
    end
  end

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

  defp download_and_cache_gnss(product, path, url, protocol, compression, opts) do
    with {:ok, downloaded} <- download(url, protocol, opts),
         {:ok, data} <- decompress_if_needed(downloaded, compression, max_decompressed_bytes(opts)),
         :ok <- verify_sha256(data, Keyword.get(opts, :sha256)),
         provenance = gnss_provenance(product, url, protocol, compression, downloaded, data),
         :ok <- commit_file(path, data, provenance) do
      {:ok, path}
    end
  end

  defp fetch_first_ionex(_center, [], _opts, nil), do: {:error, :offline_cache_miss}
  defp fetch_first_ionex(_center, [], _opts, last_error), do: {:error, last_error}

  defp fetch_first_ionex(center, [{year, month, day} | rest], opts, _last_error) do
    sample = Keyword.get(opts, :sample)

    with {:ok, date} <- Date.new(year, month, day),
         {:ok, product} <- product(center, :ionex, date, sample: sample) do
      case fetch(product, opts) do
        {:ok, path} ->
          {:ok, path}

        {:error, :offline_cache_miss} ->
          fetch_first_ionex(center, rest, opts, :offline_cache_miss)

        {:error, {:not_found_on_archive, _} = reason} ->
          fetch_first_ionex(center, rest, opts, reason)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp fetch_center_sp3(center, target, opts) do
    case sp3_candidates(center, target, opts) do
      {:ok, candidates} ->
        fetch_first_center_sp3(center, candidates, opts, nil)

      {:error, {:unsupported_product, reason}} ->
        {:absent, %AbsentCenter{center: center, reason: reason_string({:unsupported_product, reason})}}

      {:error, reason} ->
        {:absent, %AbsentCenter{center: center, reason: reason_string(reason)}}
    end
  end

  defp fetch_first_center_sp3(center, [], _opts, nil),
    do: {:absent, %AbsentCenter{center: center, reason: "no_candidate"}}

  defp fetch_first_center_sp3(center, [], _opts, {filename, reason}),
    do: {:absent, %AbsentCenter{center: center, filename: filename, reason: reason_string(reason)}}

  defp fetch_first_center_sp3(center, [product | rest], opts, _last) do
    {:ok, filename} = canonical_filename(product)

    case fetch(product, opts) do
      {:ok, path} ->
        case SP3.load(path) do
          {:ok, sp3} ->
            {:ok,
             %Contributor{
               center: center,
               filename: filename,
               date: product.date,
               issue: product.issue
             }, sp3}

          {:error, reason} ->
            {:absent, %AbsentCenter{center: center, filename: filename, reason: reason_string(reason)}}
        end

      {:error, :offline_cache_miss} ->
        fetch_first_center_sp3(center, rest, opts, {filename, :offline_cache_miss})

      {:error, {:not_found_on_archive, _} = reason} ->
        fetch_first_center_sp3(center, rest, opts, {filename, reason})

      {:error, reason} ->
        {:absent, %AbsentCenter{center: center, filename: filename, reason: reason_string(reason)}}
    end
  end

  defp merge_sp3_contributors(contributors, absent, opts) do
    sources = Enum.map(contributors, fn {:ok, _info, sp3} -> sp3 end)
    infos = Enum.map(contributors, fn {:ok, info, _sp3} -> info end)

    merge_opts =
      []
      |> maybe_put(:systems, Keyword.get(opts, :systems))
      |> maybe_put(:epoch_interval_s, Keyword.get(opts, :epoch_interval_s))

    case SP3.merge(sources, merge_opts) do
      {:ok, merged, merge_report} ->
        {:ok, merged,
         %MergeReport{
           contributors: infos,
           absent: absent,
           source_count: length(infos),
           single_product: false,
           merged: true,
           merge_report: merge_report
         }}

      {:error, reason} ->
        {:error, {:incompatible_sources, Enum.map(infos, & &1.center), reason}}
    end
  end

  defp sp3_candidates(center, target, opts) do
    with {:ok, entry} <- center_entry(center),
         true <- "sp3" in entry.products || {:error, {:unsupported_product, "#{center}/sp3"}},
         {:ok, sample} <- product_sample(center, "sp3", opts) do
      cond do
        entry.issues != [] and match?(%NaiveDateTime{}, target) and is_nil(Keyword.get(opts, :issue)) ->
          with {:ok, rows} <- ultra_issue_rows(center, target) do
            build_sp3_candidates(center, rows, sample)
          end

        entry.issues != [] ->
          with {:ok, date} <- normalize_date(target) do
            issue = Keyword.get(opts, :issue, "0000") |> to_string()
            build_sp3_candidates(center, [{date.year, date.month, date.day, issue}], sample)
          end

        true ->
          with {:ok, date} <- normalize_date(target),
               {:ok, product} <- product(center, :sp3, date, sample: sample) do
            {:ok, [product]}
          end
      end
    end
  end

  defp build_sp3_candidates(center, rows, sample) do
    rows
    |> Enum.reduce_while({:ok, []}, fn {year, month, day, issue}, {:ok, acc} ->
      with {:ok, date} <- Date.new(year, month, day),
           {:ok, product} <- product(center, :sp3, date, sample: sample, issue: issue) do
        {:cont, {:ok, [product | acc]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, products} -> {:ok, Enum.reverse(products)}
      {:error, reason} -> {:error, reason}
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

  defp download_once(url, opts) do
    case Keyword.get(opts, :http_client) do
      fun when is_function(fun, 2) ->
        normalize_http_response(fun.(url, opts), url)

      nil ->
        req_download(url, opts)
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
      {:ok, %Req.Response{status: status, body: body}} ->
        normalize_http_response({:ok, status, IO.iodata_to_binary(body)}, url)

      {:error, reason} ->
        {:error, {:network, reason}}
    end
  end

  defp normalize_http_response({:ok, %{status: status, body: body}}, url),
    do: normalize_http_response({:ok, status, body}, url)

  defp normalize_http_response({:ok, status, body}, url) when is_integer(status) do
    cond do
      status in 200..299 -> {:ok, IO.iodata_to_binary(body)}
      status == 404 -> {:error, {:not_found_on_archive, url}}
      status in 300..399 -> {:error, {:redirect_not_allowed, status, url}}
      true -> {:error, {:http_status, status, url}}
    end
  end

  defp normalize_http_response({:error, reason}, _url), do: {:error, {:network, reason}}
  defp normalize_http_response(other, _url), do: {:error, {:network, {:bad_http_response, other}}}

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
    Enum.reduce_while(centers, :ok, fn center, :ok ->
      case center_entry(normalize_code(center)) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp normalize_date(%Date{} = date), do: {:ok, date}
  defp normalize_date(%NaiveDateTime{} = datetime), do: {:ok, NaiveDateTime.to_date(datetime)}
  defp normalize_date({year, month, day}), do: Date.new(year, month, day)
  defp normalize_date({{year, month, day}, _time}), do: Date.new(year, month, day)
  defp normalize_date(other), do: {:error, {:unsupported_product, {:date, other}}}

  defp normalize_code(value) when is_atom(value), do: value |> Atom.to_string() |> String.replace("-", "_")
  defp normalize_code(value) when is_binary(value), do: value
  defp normalize_code(value), do: to_string(value)

  defp core({:ok, value}), do: {:ok, value}
  defp core({:error, reason}), do: {:error, reason}
  defp core(value), do: {:ok, value}

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp reason_string(:offline_cache_miss), do: "offline_miss"
  defp reason_string({:not_found_on_archive, _}), do: "not_published"
  defp reason_string({:checksum_mismatch, _, _}), do: "checksum"
  defp reason_string({:http_status, status, _}), do: "http_status:#{status}"
  defp reason_string(reason), do: inspect(reason)

  defp truthy?(value), do: value in [true, "true", "1", 1]

  defp user_cache_root do
    cond do
      function_exported?(:filename, :basedir, 2) ->
        :filename.basedir(:user_cache, "sidereon") |> List.to_string()

      is_binary(System.get_env("XDG_CACHE_HOME")) ->
        Path.join(System.fetch_env!("XDG_CACHE_HOME"), "sidereon")

      true ->
        Path.join([System.user_home!(), ".cache", "sidereon"])
    end
  end
end
