defmodule Sidereon.GNSS.Data do
  @moduledoc """
  Optional fetch-and-cache layer for GNSS products (SP3, RINEX clock, broadcast
  navigation, IONEX).

  `Sidereon.GNSS.Data` downloads, decompresses, checksums, and records provenance
  for the precise- and broadcast-product files that `Sidereon.GNSS.SP3`,
  `Sidereon.GNSS.Broadcast`, and `Sidereon.GNSS.Positioning` consume, then
  hands back a **local file path** (or a loaded handle). It is deliberately
  one-directional: the numerical layers never call into this module, so a solve
  never depends on network availability. You fetch once, then point the solver
  at the cached file.

  ## Quick start

      product = Sidereon.GNSS.Data.mgex_sp3(:esa, ~D[2020-06-24])

      # Download (or reuse cache) and get a decompressed file path:
      {:ok, path} = Sidereon.GNSS.Data.fetch(product)

      # Or fetch and load in one step:
      {:ok, sp3} = Sidereon.GNSS.Data.sp3(product)
      {:ok, state} = Sidereon.GNSS.SP3.position(sp3, "G01", ~N[2020-06-24 00:00:00])

  ## Catalog

  Products are identified by analysis center, content type, date, and sampling.

  Supported centers and what each publishes:

    * `:gfz`: GFZ operational rapid SP3/CLK over HTTPS (`isdc-data.gfz.de`)
    * `:cod`: CODE MGEX final SP3/CLK and CODE IONEX over plain HTTP
      (`ftp.aiub.unibe.ch`; AIUB does not offer HTTPS for this archive)
    * `:esa`: ESA Navigation Office final SP3/CLK and IONEX over HTTPS
      (`navigation-office.esa.int`)
    * `:igs_ult`, `:cod_ult`, `:esa_ult`, `:gfz_ult`: ultra-rapid `OPSULT`
      SP3 products for current-day/live-latency use
    * `:cod_rap`: CODE rapid IONEX (`COD0OPSRAP`) over plain HTTP, the
      low-latency global ionosphere map (final lags ~1-3 weeks)
    * `:cod_prd1`, `:cod_prd2`: CODE 1-day and 2-day predicted IONEX
      (`COD0OPSPRD`); published ahead of time, so `:cod_prd1` resolves for the
      current/near-future UTC day
    * `:igs`: the IGS merged broadcast navigation file (`:nav`) over HTTPS from
      the BKG IGS archive

  Content types: `:sp3`, `:clk`, `:nav`, `:ionex`, `:obs` (station observation
  data, RINEX 3 / CRINEX). Precise products and IONEX
  follow the IGS long-name convention `AAAVPPPTTT_YYYYDDDHHMM_LEN_SMP_CNT.EXT`;
  broadcast navigation uses the no-sampling RINEX long-name
  `BRDC00WRD_R_YYYYDDDHHMM_01D_MN.rnx`. See `Sidereon.GNSS.Data.Catalog`.

  ## The fetch pipeline

  `fetch/2` is cache-first:

    1. Resolve the canonical filename and cache path (pure, from the catalog).
    2. If the file is already cached, verify it: against the caller's `:sha256`
       when given, otherwise against the decompressed SHA-256 recorded in the
       file's provenance sidecar (every downloaded file has one). A verified hit
       returns with **no network**. A *corrupt* hit (checksum mismatch) or an
       *unverifiable* one (such as a hand-placed file with no sidecar) is, online,
       discarded and re-downloaded; offline, a corrupt hit is terminal and an
       unverifiable one is returned as the best available.
    3. Otherwise (and only when not `offline:`) download over the cataloged
       HTTP(S) URL (`Req`, a required dependency) to memory. Gzipped products
       are decompressed with a gzip-bomb cap; explicitly uncompressed products
       are committed as downloaded. The fetch then verifies any known checksum
       and **atomically** commits the local file into the cache (temp file +
       rename) together with its required `.provenance.json` sidecar (the commit
       fails if the sidecar cannot be written, so a cached file always carries
       its integrity hash).

  ## Offline mode

  Pass `offline: true` (or set `config :sidereon, gnss_data_offline: true`) to
  forbid all network access: a verified cache hit is returned, a corrupt hit
  yields `{:error, {:checksum_mismatch, _, _}}`, and a miss returns
  `{:error, {:offline_miss, name}}`. This is how the test suite, and any user
  without connectivity, runs deterministically.

  ## Network tests

  Live-archive fetching is exercised by tests tagged `:network`, which are
  **excluded by default** (including in CI, which has no network); the rest of
  the suite is fully offline and deterministic. Run the live gate manually with
  `mix test --include network`.

  ## Options

    * `:offline`: when `true`, never touch the network (default from app config,
      else `false`)
    * `:cache_dir`: cache root (default `:filename.basedir(:user_cache,
      "sidereon/gnss")`, overridable via `config :sidereon, gnss_data_cache_dir:`)
    * `:systems`: for merged SP3 fetches, restrict the output to constellations
      such as `[:gps]` or `["G", "E"]`
    * `:epoch_interval_s`: for merged SP3 fetches, require this exact target
      epoch interval; mixed-cadence products are rejected rather than unioned
      onto a corrupt grid
    * `:sha256`: expected SHA-256 (hex) of the **decompressed** file; verified
      on both cache hits and fresh downloads
    * `:max_decompressed_bytes`: gzip-bomb cap (default 500 MiB)
    * `:timeout_ms`: per-attempt network timeout (default 30_000)
    * `:retries`: attempts for transient network errors (default 3)
    * `:backoff_ms`: base backoff between retries, doubled each attempt
      (default 500)
    * `:max_compressed_bytes`: cap on the compressed payload buffered into
      memory while downloading (default 64 MiB)

  ## Typed errors

  Every failure is a tagged tuple so callers can branch on it:

    * `{:error, {:offline_miss, name}}`: `offline: true` and not cached
    * `{:error, {:checksum_mismatch, expected, got}}`: digest verification failed
    * `{:error, {:unsupported_product, detail}}`: unknown center/content/sample,
      or a host outside the catalog
    * `{:error, {:no_open_mirror, {center, content}}}`: the product was removed
      because no verified anonymous HTTP(S) mirror is known
    * `{:error, :req_not_available}`: HTTP client downloads are disabled by config
    * `{:error, {:http_status, code}}`: non-2xx HTTP response
    * `{:error, {:redirect_not_allowed, code}}`: a 3xx redirect was refused
      (redirects are not followed, to keep the SSRF allow-list intact)
    * `{:error, {:file_not_found, url}}`: 404 / missing on the archive
    * `{:error, {:network, detail}}`: connection/timeout/DNS failure
    * `{:error, {:download_size_exceeded, max, got}}`: download payload cap hit
    * `{:error, {:decompress_failed, reason}}`: corrupt gzip
    * `{:error, {:decompress_size_exceeded, max, got}}`: gzip-bomb cap hit
    * `{:error, {:cache_dir_not_writable, reason}}`: cannot create/write cache
    * `{:error, {:provenance_write_failed, reason}}`: the product downloaded but
      its required provenance sidecar could not be written (the product is rolled
      back so nothing unverifiable is left in the cache)
    * `{:error, {:unsafe_cache_name, name}}`: filename failed path-safety checks
    * `{:error, {:temp_file_error, reason}}`: temp write/rename failure
  """

  alias Sidereon.GNSS.Broadcast
  alias Sidereon.GNSS.Data.{Cache, Catalog, Download, Product}
  alias Sidereon.GNSS.RINEX.Observations
  alias Sidereon.GNSS.SP3

  @typedoc "A fetch error, always a tagged tuple. See the module docs."
  @type error :: {:error, term()}
  @merge_opts ~w(
    position_tolerance_m
    clock_tolerance_s
    min_agree
    clock_min_common
    combine
    epoch_interval_s
    systems
  )a

  # --- product builders ----------------------------------------------------

  @doc """
  Build an MGEX SP3 (precise orbit) product for a center and date.

  Defaults to `05M` (5-minute) sampling; override with `sample:`.

  ## Examples

      iex> p = Sidereon.GNSS.Data.mgex_sp3(:esa, ~D[2020-06-24])
      iex> p.center
      :esa
      iex> Sidereon.GNSS.Data.Product.canonical_filename(p)
      {:ok, "ESA0MGNFIN_20201760000_01D_05M_ORB.SP3"}
  """
  @spec mgex_sp3(atom(), Date.t(), keyword()) :: Product.t()
  def mgex_sp3(center, %Date{} = date, opts \\ []),
    do: build!(center, :sp3, date, Keyword.get(opts, :sample) || default_sample!(center, :sp3))

  @doc """
  Build an MGEX clock (RINEX clock) product. Defaults to `30S` sampling.
  """
  @spec mgex_clk(atom(), Date.t(), keyword()) :: Product.t()
  def mgex_clk(center, %Date{} = date, opts \\ []),
    do: build!(center, :clk, date, Keyword.get(opts, :sample) || default_sample!(center, :clk))

  @doc """
  Build an ultra-rapid OPS SP3 product.

  Ultra-rapid products are two-day (`02D`) files issued several times per day,
  with roughly one observed day and one predicted day. Pass a `Date` with an
  explicit `issue:` (defaults to `"0000"`), or pass a `NaiveDateTime` /
  `DateTime` target and Sidereon will select the latest issue not after that time.
  If `:available_issues` is supplied, selection falls back to the newest issue
  present in that list.

  ## Examples

      iex> p = Sidereon.GNSS.Data.ops_ultra_sp3(:igs_ult, ~D[2024-09-03], issue: "0600")
      iex> Sidereon.GNSS.Data.Product.canonical_filename(p)
      {:ok, "IGS0OPSULT_20242470600_02D_15M_ORB.SP3"}

      iex> available = [{~D[2024-09-03], "0000"}, {~D[2024-09-03], "0600"}]
      iex> p = Sidereon.GNSS.Data.ops_ultra_sp3(:gfz_ult, ~N[2024-09-03 13:00:00], available_issues: available)
      iex> Sidereon.GNSS.Data.Product.canonical_filename(p)
      {:ok, "GFZ0OPSULT_20242470600_02D_05M_ORB.SP3"}
  """
  @spec ops_ultra_sp3(atom(), Date.t() | NaiveDateTime.t() | DateTime.t(), keyword()) ::
          Product.t()
  def ops_ultra_sp3(center, date_or_target, opts \\ []),
    do: ultra_product!(center, :sp3, date_or_target, opts)

  @doc """
  Build an ultra-rapid OPS clock product.

  Issue-time behavior matches `ops_ultra_sp3/3`. The current HTTPS catalog does
  not include an ultra-rapid clock product; retired clock products raise
  `{:no_open_mirror, {center, :clk}}`.
  """
  @spec ops_ultra_clk(atom(), Date.t() | NaiveDateTime.t() | DateTime.t(), keyword()) ::
          Product.t()
  def ops_ultra_clk(center, date_or_target, opts \\ []),
    do: ultra_product!(center, :clk, date_or_target, opts)

  @doc """
  Build a broadcast-navigation (merged multi-GNSS RINEX NAV) product.

  Only `:igs` publishes this product (`BRDC00WRD_R_..._MN.rnx`). The RINEX
  navigation long-name carries no sampling field, so the `sample` argument is
  not part of the filename; it defaults to `01D` purely to satisfy validation.

  ## Examples

      iex> p = Sidereon.GNSS.Data.mgex_nav(:igs, ~D[2020-06-25])
      iex> Sidereon.GNSS.Data.Product.canonical_filename(p)
      {:ok, "BRDC00WRD_R_20201770000_01D_MN.rnx"}
  """
  @spec mgex_nav(atom(), Date.t(), keyword()) :: Product.t()
  def mgex_nav(center, %Date{} = date, opts \\ []),
    do: build!(center, :nav, date, Keyword.get(opts, :sample) || default_sample!(center, :nav))

  @doc """
  Build an IONEX (global ionosphere TEC map) product.

  Served by `:esa` (`ESA0OPSFIN`). IONEX maps are sub-daily, so the catalog
  sampling defaults to `02H`; pass `sample:` to override.

  `fetch/2` on the returned product is a single-shot fetch of that exact day. For
  the lower-latency CODE rapid (`:cod_rap`) and predicted (`:cod_prd1`,
  `:cod_prd2`) maps, whose availability is time-sensitive, use `fetch_ionex/3` to
  fetch with a latest-available-day candidate fallback.

  ## Examples

      iex> p = Sidereon.GNSS.Data.mgex_ionex(:esa, ~D[2024-06-24])
      iex> Sidereon.GNSS.Data.Product.canonical_filename(p)
      {:ok, "ESA0OPSFIN_20241760000_01D_02H_GIM.INX"}
  """
  @spec mgex_ionex(atom(), Date.t(), keyword()) :: Product.t()
  def mgex_ionex(center, %Date{} = date, opts \\ []),
    do:
      build!(center, :ionex, date, Keyword.get(opts, :sample) || default_sample!(center, :ionex))

  @doc """
  Build the CODE **rapid** IONEX product (`COD0OPSRAP`) for a UTC day.

  The rapid global ionosphere map is the low-latency CODE GIM; the final
  `COD0OPSFIN` map lags one to three weeks. It resolves on the AIUB `/CODE` root
  over plain HTTP and defaults to `01H` sampling.

  The rapid map is a **rolling-recent window** on AIUB: the current day is not
  yet published and files older than roughly three days roll off the `/CODE`
  root, so `fetch/2` on a single day can `:file_not_found` on either edge. For
  the freshest available map prefer `fetch_ionex/3`, which walks candidate days
  newest-first; for same-day use prefer the predicted map (`:cod_prd1`), which is
  published before its day starts.

  ## Examples

      iex> p = Sidereon.GNSS.Data.rapid_ionex(~D[2026-06-13])
      iex> Sidereon.GNSS.Data.Product.canonical_filename(p)
      {:ok, "COD0OPSRAP_20261640000_01D_01H_GIM.INX"}
  """
  @spec rapid_ionex(Date.t(), keyword()) :: Product.t()
  def rapid_ionex(%Date{} = date, opts \\ []),
    do:
      build!(
        :cod_rap,
        :ionex,
        date,
        Keyword.get(opts, :sample) || default_sample!(:cod_rap, :ionex)
      )

  @doc """
  Build a CODE **predicted** IONEX product (`COD0OPSPRD`) for a UTC day.

  CODE publishes a single predicted GIM; the catalog distinguishes horizons by
  the day each alias targets. `center` is `:cod_prd1` (1-day-ahead, the
  current/near-future day) or `:cod_prd2` (2-day-ahead, the day after `date`).
  Predicted maps are published before their target day starts, so a predicted
  product is resolvable for the current/near-future UTC day. Resolves on the
  AIUB `/CODE` root over plain HTTP and defaults to `01H` sampling.

  To fetch with a latest-available-day fallback (walking candidate days
  newest-first), use `fetch_ionex/3` rather than `fetch/2` on a single product.

  ## Examples

      iex> p = Sidereon.GNSS.Data.predicted_ionex(:cod_prd1, ~D[2026-06-14])
      iex> Sidereon.GNSS.Data.Product.canonical_filename(p)
      {:ok, "COD0OPSPRD_20261650000_01D_01H_GIM.INX"}

      iex> p = Sidereon.GNSS.Data.predicted_ionex(:cod_prd2, ~D[2026-06-14])
      iex> Sidereon.GNSS.Data.Product.canonical_filename(p)
      {:ok, "COD0OPSPRD_20261660000_01D_01H_GIM.INX"}
  """
  @spec predicted_ionex(atom(), Date.t(), keyword()) :: Product.t()
  def predicted_ionex(center, %Date{} = date, opts \\ []) when center in [:cod_prd1, :cod_prd2] do
    target = Date.add(date, Catalog.predicted_day_offset(center))
    build!(center, :ionex, target, Keyword.get(opts, :sample) || default_sample!(center, :ionex))
  end

  @doc """
  Build a daily **station observation** product (RINEX 3 CRINEX, 30 s default).

  Station observation files are keyed by a 9-character site id (e.g.
  `"WTZR00DEU"`), not an analysis-center token, and resolve on the BKG IGS
  observation tree. Override the sampling with `sample:`.

  ## Examples

      iex> p = Sidereon.GNSS.Data.station_obs("WTZR00DEU", ~D[2020-06-25])
      iex> Sidereon.GNSS.Data.Product.canonical_filename(p)
      {:ok, "WTZR00DEU_R_20201770000_01D_30S_MO.crx"}
  """
  @spec station_obs(String.t(), Date.t(), keyword()) :: Product.t()
  def station_obs(station, %Date{} = date, opts \\ []) when is_binary(station) do
    sample = Keyword.get(opts, :sample, "30S")

    case Product.new(:igs, :obs, date, sample, station: station) do
      {:ok, p} -> p
      {:error, reason} -> raise ArgumentError, "invalid station OBS product: #{inspect(reason)}"
    end
  end

  @doc """
  Build a `Product` for any center/content/date/sample, returning a tuple.

  Use this instead of the bang builders when the inputs may be invalid.
  """
  @spec product(atom(), atom(), Date.t(), String.t()) ::
          {:ok, Product.t()} | Catalog.error()
  def product(center, content, %Date{} = date, sample),
    do: Product.new(center, content, date, sample)

  @doc """
  Build a `Product` for any center/content/date/sample with product-specific
  options such as `issue: "0600"` for ultra-rapid products.
  """
  @spec product(atom(), atom(), Date.t(), String.t(), keyword()) ::
          {:ok, Product.t()} | Catalog.error()
  def product(center, content, %Date{} = date, sample, opts),
    do: Product.new(center, content, date, sample, opts)

  defp build!(center, content, date, sample, opts \\ []) do
    case Product.new(center, content, date, sample, opts) do
      {:ok, p} ->
        p

      {:error, reason} ->
        raise ArgumentError, "invalid GNSS product: #{inspect(reason)}"
    end
  end

  defp ultra_product!(center, content, %Date{} = date, opts) do
    sample = Keyword.get(opts, :sample) || default_sample!(center, content)
    issue = Keyword.get(opts, :issue, "0000")
    build!(center, content, date, sample, issue: issue)
  end

  defp ultra_product!(center, content, %NaiveDateTime{} = target, opts) do
    sample = Keyword.get(opts, :sample) || default_sample!(center, content)
    {date, issue} = resolve_ultra_issue!(center, target, opts)
    build!(center, content, date, sample, issue: issue)
  end

  defp ultra_product!(center, content, %DateTime{} = target, opts) do
    sample = Keyword.get(opts, :sample) || default_sample!(center, content)
    {date, issue} = resolve_ultra_issue!(center, target, opts)
    build!(center, content, date, sample, issue: issue)
  end

  defp ultra_product!(center, content, _target, _opts) do
    raise ArgumentError,
          "invalid ultra GNSS product: #{inspect({:bad_target, center, content})}"
  end

  defp resolve_ultra_issue!(center, target, opts) do
    case Keyword.fetch(opts, :issue) do
      {:ok, issue} ->
        {target_date(target), issue}

      :error ->
        available = Keyword.get(opts, :available_issues)

        case Catalog.latest_ultra_issue(center, target, available) do
          {:ok, %{date: date, issue: issue}} ->
            {date, issue}

          {:error, reason} ->
            raise ArgumentError, "invalid ultra GNSS product: #{inspect(reason)}"
        end
    end
  end

  defp default_sample!(center, content) do
    case Catalog.default_sample(center, content) do
      {:ok, sample} -> sample
      {:error, reason} -> raise ArgumentError, "invalid GNSS product: #{inspect(reason)}"
    end
  end

  defp target_date(%DateTime{} = target), do: target |> DateTime.to_date()
  defp target_date(%NaiveDateTime{} = target), do: NaiveDateTime.to_date(target)

  # --- fetch ---------------------------------------------------------------

  @doc """
  Fetch a product, returning the local path to its **decompressed** file.

  Cache-first: a verified cache hit returns immediately with no network. See the
  module docs for the full pipeline, options, and error taxonomy.

  Returns `{:ok, path}` or a typed `{:error, _}`.
  """
  @spec fetch(Product.t(), keyword()) :: {:ok, String.t()} | error()
  def fetch(%Product{} = product, opts \\ []) do
    cache_dir = cache_dir(opts)
    sha = Keyword.get(opts, :sha256)

    with {:ok, filename} <- Product.canonical_filename(product),
         {:ok, path} <- Cache.path_for(cache_dir, filename) do
      case Cache.classify(path, sha) do
        # Present and verified (against the caller's :sha256 if given, else the
        # provenance sidecar's stored hash).
        {:hit, ^path} ->
          {:ok, path}

        :absent ->
          fetch_miss(product, path, filename, sha, opts)

        # Present but unverifiable: no caller hash and no usable sidecar, as with
        # a file placed by hand. Online, fetch a verified, provenance-stamped copy;
        # offline, return it as the best available.
        :unverified ->
          if offline?(opts), do: {:ok, path}, else: download_and_cache(product, path, sha, opts)

        # Corrupt or stale. Offline it is terminal (nothing better to offer);
        # online we discard it and re-download. The atomic commit overwrites it,
        # and the fresh copy is verified before commit, so one bad file does not
        # permanently wedge the product.
        {:stale, mismatch} ->
          if offline?(opts),
            do: {:error, mismatch},
            else: download_and_cache(product, path, sha, opts)

        {:error, _} = err ->
          err
      end
    end
  end

  @doc """
  Fetch a CODE rapid or predicted IONEX map for a target day, walking candidate
  days newest first.

  The rapid map (`:cod_rap`) lands a day or two late and the predicted maps
  (`:cod_prd1`, `:cod_prd2`) are published ahead of their target day, so the
  freshest file present may be for a slightly earlier day than first requested.
  This tries `Sidereon.GNSS.Data.Catalog.gim_date_candidates/3` newest first through
  the ordinary `fetch/2` path and returns the first hit, or the last error when
  every candidate misses (preserving the `{:offline_miss, _}` taxonomy offline).

  Returns `{:ok, path}` or a typed `{:error, _}`.
  """
  @spec fetch_ionex(atom(), Date.t() | NaiveDateTime.t() | DateTime.t(), keyword()) ::
          {:ok, String.t()} | error()
  def fetch_ionex(center, target, opts \\ []) do
    lookback = Keyword.get(opts, :lookback, 2)
    sample_opts = Keyword.take(opts, [:sample])

    case Catalog.gim_date_candidates(center, target, lookback) do
      dates when is_list(dates) ->
        fetch_first_ionex(center, dates, sample_opts, opts, nil)

      {:error, _} = err ->
        err
    end
  end

  defp fetch_first_ionex(_center, [], _sample_opts, _opts, last_error),
    do: last_error || {:error, {:unsupported_product, :no_candidate}}

  defp fetch_first_ionex(center, [date | rest], sample_opts, opts, _last_error) do
    # gim_date_candidates already applied the predicted horizon offset, so build
    # the product directly at the candidate date (no further offset here).
    product =
      build!(
        center,
        :ionex,
        date,
        Keyword.get(sample_opts, :sample) || default_sample!(center, :ionex)
      )

    case fetch(product, opts) do
      {:ok, path} -> {:ok, path}
      {:error, _} = err -> fetch_first_ionex(center, rest, sample_opts, opts, err)
    end
  end

  defp fetch_miss(product, path, filename, sha, opts) do
    if offline?(opts) do
      {:error, {:offline_miss, filename}}
    else
      download_and_cache(product, path, sha, opts)
    end
  end

  defp download_and_cache(product, path, sha, opts) do
    max_bytes = Keyword.get(opts, :max_decompressed_bytes, Cache.default_max_decompressed_bytes())

    with {:ok, url} <- Product.archive_url(product),
         {:ok, protocol} <- protocol_for(product),
         {:ok, compression} <- compression_for(product),
         {:ok, downloaded} <- Download.get(url, protocol, opts),
         {:ok, decompressed} <- decode_download(downloaded, compression, max_bytes),
         :ok <- verify(decompressed, sha),
         provenance = provenance(url, protocol, compression, downloaded, decompressed),
         {:ok, ^path} <- Cache.commit(path, decompressed, provenance) do
      {:ok, path}
    end
  end

  # Station observation products are not analysis-center products; they resolve
  # their protocol from the dedicated station archive path, not the @centers
  # token table.
  defp protocol_for(%Product{content: :obs}), do: {:ok, Catalog.station_obs_protocol()}
  defp protocol_for(%Product{center: center}), do: Catalog.protocol(center)

  defp compression_for(%Product{content: :obs}), do: {:ok, :gzip}

  defp compression_for(%Product{center: center, content: content}),
    do: Catalog.compression(center, content)

  defp decode_download(downloaded, :gzip, max_bytes), do: Cache.gunzip(downloaded, max_bytes)
  defp decode_download(downloaded, :none, _max_bytes), do: {:ok, downloaded}

  defp decode_download(_downloaded, compression, _max_bytes),
    do: {:error, {:unsupported_product, {:compression, compression}}}

  defp verify(_decompressed, nil), do: :ok

  defp verify(decompressed, expected) do
    got = Cache.sha256(decompressed)

    if String.downcase(expected) == got do
      :ok
    else
      {:error, {:checksum_mismatch, expected, got}}
    end
  end

  defp provenance(url, protocol, compression, downloaded, decompressed) do
    %{
      "source_url" => url,
      "protocol" => Atom.to_string(protocol),
      "compression" => Atom.to_string(compression),
      "sha256_downloaded" => Cache.sha256(downloaded),
      "sha256_compressed" => Cache.sha256(downloaded),
      "sha256_decompressed" => Cache.sha256(decompressed),
      "size_downloaded" => byte_size(downloaded),
      "size_compressed" => byte_size(downloaded),
      "size_decompressed" => byte_size(decompressed),
      "fetched_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "fetcher" => "Sidereon.GNSS.Data"
    }
  end

  # --- convenience loaders -------------------------------------------------

  @doc """
  Fetch an SP3 product and load it into an `Sidereon.GNSS.SP3` handle.

  Equivalent to `fetch/2` followed by `Sidereon.GNSS.SP3.load/1`. Returns
  `{:ok, %Sidereon.GNSS.SP3{}}` or a typed error.
  """
  @spec sp3(Product.t(), keyword()) :: {:ok, SP3.t()} | error()
  def sp3(%Product{content: :sp3} = product, opts \\ []) do
    with {:ok, path} <- fetch(product, opts), do: SP3.load(path)
  end

  @doc """
  Write an `Sidereon.GNSS.SP3` product to `path`, the inverse of the fetch layer's
  read.

  The product is serialized with `Sidereon.GNSS.SP3.to_iodata/2` (pure) and
  committed atomically: the bytes are written to a temporary file in the same
  directory, then `File.rename/2`d into place (atomic on POSIX), so a reader
  never observes a half-written file. The unblocking case is persisting a
  `merge/2` product, which is otherwise only an in-memory handle.

  Returns `{:ok, path}` or `{:error, reason}`.

  ## Options

    * `:gzip`: gzip-compress the output, matching the gzipped archive products
      (default `false`). Pair it with a `.gz` extension on `path`.

  ## Examples

      {:ok, merged, _report} = Sidereon.GNSS.Data.fetch_merged_sp3(date, [:igs_ult, :gfz_ult])
      {:ok, _path} = Sidereon.GNSS.Data.write_sp3(merged, "/tmp/merged.sp3")
      {:ok, _path} = Sidereon.GNSS.Data.write_sp3(merged, "/tmp/merged.sp3.gz", gzip: true)
  """
  @spec write_sp3(SP3.t(), Path.t(), keyword()) :: {:ok, Path.t()} | error()
  def write_sp3(%SP3{} = sp3, path, opts \\ []) when is_binary(path) do
    iodata = SP3.to_iodata(sp3)

    bytes =
      if Keyword.get(opts, :gzip, false) do
        :zlib.gzip(iodata)
      else
        iodata
      end

    atomic_write(path, bytes)
  rescue
    e in ArgumentError -> {:error, {:serialize_failed, e.message}}
  end

  # Commit `bytes` to `path` via a same-directory temp file + atomic rename, so a
  # concurrent reader never sees a partial file (mirrors the cache write path).
  defp atomic_write(path, bytes) do
    dir = Path.dirname(path)
    tmp = Path.join(dir, ".tmp-sp3-#{System.unique_integer([:positive])}-#{:os.getpid()}")

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(tmp, bytes),
         :ok <- File.rename(tmp, path) do
      {:ok, path}
    else
      {:error, reason} ->
        _ = File.rm(tmp)
        {:error, {:write_failed, reason}}
    end
  end

  @doc """
  Fetch a broadcast-navigation product and load it into an
  `Sidereon.GNSS.Broadcast` handle.

  Returns `{:ok, %Sidereon.GNSS.Broadcast{}}` or a typed error.
  """
  @spec broadcast(Product.t(), keyword()) :: {:ok, Broadcast.t()} | error()
  def broadcast(%Product{content: :nav} = product, opts \\ []) do
    with {:ok, path} <- fetch(product, opts), do: Broadcast.load(path)
  end

  @doc """
  Fetch a station observation product and load it into an `Sidereon.GNSS.RINEX.Observations`
  handle.

  `fetch/2` gunzips the `.gz`; the committed cache file is the (still Hatanaka)
  CRINEX text, which `Sidereon.GNSS.RINEX.Observations.load/1` decodes before parsing. Returns
  `{:ok, %Sidereon.GNSS.RINEX.Observations{}}` or a typed error.
  """
  @spec observations(Product.t(), keyword()) :: {:ok, Observations.t()} | error()
  def observations(%Product{content: :obs} = product, opts \\ []) do
    with {:ok, path} <- fetch(product, opts), do: Observations.load(path)
  end

  @doc """
  Fetch SP3 products from several centers and merge the available ones.

  `centers` are tried in precedence order. A missing or not-yet-published center
  is recorded in the returned report and does not abort the call. For
  ultra-rapid centers and timestamp targets, Sidereon tries issue candidates newest
  to oldest until it finds a cached/downloadable product, so callers near the
  publication frontier can fall back from a not-yet-landed latest issue.

  Returns:

    * `{:ok, merged, report}` when at least one center contributes. With one
      contributor, `merged` is that source SP3 and `report.single_product?` is
      `true`.
    * `{:error, {:no_products, reasons}}` when every center is absent or fails.
    * `{:error, {:incompatible_sources, %{centers:, reason:}}}` when the fetched
      centers exist but cannot be combined (their SP3 headers disagree on time
      scale or coordinate system, which the merge refuses rather than mixing
      frames).

  The report includes `:contributors`, `:absent`, `:source_count`,
  `:single_product?`, and the normal SP3 merge audit keys (`:quarantined`,
  `:single_source`, `:position_outliers`).

  ## Examples

      iex> cache = System.tmp_dir!()
      iex> {:error, {:no_products, reasons}} =
      ...>   Sidereon.GNSS.Data.fetch_merged_sp3(~D[2024-09-03], [:igs_ult], offline: true, cache_dir: cache)
      iex> [%{center: :igs_ult, reason: :offline_miss}] = reasons
  """
  @spec fetch_merged_sp3(Date.t() | NaiveDateTime.t() | DateTime.t(), [atom()], keyword()) ::
          {:ok, SP3.t(), map()}
          | {:error, {:no_products, [map()]}}
          | {:error, {:incompatible_sources, map()}}
          | error()
  def fetch_merged_sp3(target, centers, opts \\ []) when is_list(centers) do
    centers
    |> Enum.map(&fetch_center_sp3(&1, target, opts))
    |> merge_available_sp3(opts)
  end

  @doc """
  Fetch the merged current-day SP3 product from several centers **and persist it
  to `path`** in one call, the live-latency workflow's entry point.

  This composes `fetch_merged_sp3/3` (fetch + merge, in the numeric layer's
  in-memory form) with `write_sp3/3` (the data layer's atomic file write), so the
  result is a standard, self-contained SP3 file on disk. That file is exactly
  what the cache / `Sidereon.GNSS.SP3` / `Sidereon.GNSS.Positioning` layers consume,
  which unblocks the end-to-end path:

      merged current-day SP3 -> standard file -> Observables / Positioning

  Because the numeric layer never reaches for I/O, a later solve reads the cached
  file with no network. Fetch once here, then point the solver at `path`.

  `target`, `centers`, and the fetch/merge options behave exactly as in
  `fetch_merged_sp3/3` (ultra-rapid issue selection, per-center precedence,
  offline mode, `:cache_dir`, the SP3 `merge/2` tuning keys, …). Write options
  are shared with `write_sp3/3`:

    * `:gzip`: gzip-compress the written file (default `false`); pair it with a
      `.gz` extension on `path`.

  Returns:

    * `{:ok, path, report}`: the merged product was written; `report` is the
      same merge/contributor audit `fetch_merged_sp3/3` returns
      (`:contributors`, `:absent`, `:source_count`, `:single_product?`,
      `:quarantined`, …).
    * `{:error, {:no_products, reasons}}` / `{:error, {:incompatible_sources, _}}`
      are propagated from the fetch/merge step; nothing is written.
    * any `write_sp3/3` error (e.g. `{:error, {:write_failed, reason}}`): the
      product merged but could not be persisted.

  ## Examples

      iex> cache = System.tmp_dir!()
      iex> path = Path.join(cache, "no_such_product.sp3")
      iex> {:error, {:no_products, [%{center: :igs_ult, reason: :offline_miss}]}} =
      ...>   Sidereon.GNSS.Data.fetch_merged_sp3_file(~D[2024-09-03], [:igs_ult], path,
      ...>     offline: true, cache_dir: cache)
      iex> File.exists?(path)
      false
  """
  @spec fetch_merged_sp3_file(
          Date.t() | NaiveDateTime.t() | DateTime.t(),
          [atom()],
          Path.t(),
          keyword()
        ) ::
          {:ok, Path.t(), map()}
          | {:error, {:no_products, [map()]}}
          | {:error, {:incompatible_sources, map()}}
          | error()
  def fetch_merged_sp3_file(target, centers, path, opts \\ [])
      when is_list(centers) and is_binary(path) do
    with {:ok, merged, report} <- fetch_merged_sp3(target, centers, opts),
         {:ok, path} <- write_sp3(merged, path, Keyword.take(opts, [:gzip])) do
      {:ok, path, report}
    end
  end

  defp fetch_center_sp3(center, target, opts) do
    case sp3_candidates(center, target, opts) do
      {:ok, candidates} ->
        fetch_first_sp3_candidate(center, candidates, opts, [])

      {:error, reason} ->
        {:absent, absence(center, nil, reason, [])}
    end
  end

  defp fetch_first_sp3_candidate(center, [], _opts, attempts) do
    attempts = Enum.reverse(attempts)
    final_attempt = List.last(attempts)

    {:absent,
     %{
       center: center,
       filename: if(final_attempt, do: final_attempt.filename),
       reason: if(final_attempt, do: final_attempt.reason, else: :no_candidate),
       attempts: attempts
     }}
  end

  defp fetch_first_sp3_candidate(center, [product | rest], opts, attempts) do
    filename = product_filename(product)

    case sp3(product, opts) do
      {:ok, sp3} ->
        {:ok,
         %{
           center: center,
           product: product,
           filename: filename,
           issue: product.issue,
           date: product.date,
           sp3: sp3,
           attempts: Enum.reverse(attempts)
         }}

      {:error, reason} ->
        attempt = %{filename: filename, reason: normalize_absence_reason(reason)}
        fetch_first_sp3_candidate(center, rest, opts, [attempt | attempts])
    end
  end

  defp sp3_candidates(center, target, opts) do
    cond do
      ultra_timestamp_target?(center, target) ->
        ultra_sp3_candidates(center, target, opts)

      match?(%Date{}, target) ->
        dated_sp3_candidate(center, target, opts)

      match?(%NaiveDateTime{}, target) or match?(%DateTime{}, target) ->
        dated_sp3_candidate(center, target_date(target), opts)

      true ->
        {:error, {:unsupported_product, :bad_target}}
    end
  end

  defp ultra_timestamp_target?(center, %DateTime{} = target),
    do: ultra_timestamp_target?(center, DateTime.to_naive(target))

  defp ultra_timestamp_target?(center, %NaiveDateTime{} = target) do
    match?(candidates when is_list(candidates), Catalog.ultra_issue_candidates(center, target))
  end

  defp ultra_timestamp_target?(_center, _target), do: false

  defp ultra_sp3_candidates(center, target, opts) do
    with candidates when is_list(candidates) <- Catalog.ultra_issue_candidates(center, target),
         {:ok, available} <- available_issues_for(center, opts) do
      built =
        candidates
        |> Enum.filter(&candidate_available?(&1, available))
        |> Enum.reduce_while({:ok, []}, fn %{date: date, issue: issue}, {:ok, acc} ->
          case ultra_product_for_issue(center, date, issue, opts) do
            {:ok, product} -> {:cont, {:ok, [product | acc]}}
            {:error, _} = err -> {:halt, err}
          end
        end)

      case built do
        {:ok, products} -> {:ok, Enum.reverse(products)}
        {:error, _} = err -> err
      end
    else
      {:error, _} = err -> err
    end
  end

  defp dated_sp3_candidate(center, %Date{} = date, opts) do
    with {:ok, sample} <- sample_for(center, :sp3, opts) do
      issue =
        cond do
          Keyword.has_key?(opts, :issue) -> Keyword.fetch!(opts, :issue)
          ultra_center?(center) -> "0000"
          true -> nil
        end

      case Product.new(center, :sp3, date, sample, maybe_issue(issue)) do
        {:ok, product} -> {:ok, [product]}
        {:error, _} = err -> err
      end
    end
  end

  defp ultra_product_for_issue(center, date, issue, opts) do
    with {:ok, sample} <- sample_for(center, :sp3, opts) do
      Product.new(center, :sp3, date, sample, issue: issue)
    end
  end

  defp sample_for(center, content, opts) do
    case Keyword.fetch(opts, :sample) do
      {:ok, sample} -> {:ok, sample}
      :error -> Catalog.default_sample(center, content)
    end
  end

  defp maybe_issue(nil), do: []
  defp maybe_issue(issue), do: [issue: issue]

  defp available_issues_for(center, opts) do
    case Keyword.fetch(opts, :available_issues) do
      :error ->
        {:ok, nil}

      {:ok, available} when is_map(available) ->
        {:ok, available |> Map.get(center) |> normalize_available_issues()}

      {:ok, available} when is_list(available) ->
        {:ok, normalize_available_issues(available)}

      {:ok, _bad} ->
        {:error, {:unsupported_product, :bad_available_issues}}
    end
  end

  defp normalize_available_issues(nil), do: nil

  defp normalize_available_issues(available) do
    Enum.map(available, fn
      {%Date{} = date, issue} when is_binary(issue) -> {date, issue}
      %{date: %Date{} = date, issue: issue} when is_binary(issue) -> {date, issue}
      other -> other
    end)
  end

  defp candidate_available?(_candidate, nil), do: true

  defp candidate_available?(candidate, available),
    do: {candidate.date, candidate.issue} in available

  defp ultra_center?(center) do
    match?(
      candidates when is_list(candidates),
      Catalog.ultra_issue_candidates(center, ~N[2024-01-01 00:00:00])
    )
  end

  defp merge_available_sp3(results, opts) do
    contributors = for {:ok, info} <- results, do: info
    absent = for {:absent, info} <- results, do: info

    case contributors do
      [] ->
        {:error, {:no_products, absent}}

      [one] ->
        {:ok, one.sp3, report(contributors, absent, false, empty_merge_report())}

      many ->
        sources = Enum.map(many, & &1.sp3)

        case SP3.merge(sources, Keyword.take(opts, @merge_opts)) do
          {:ok, merged, merge_report} ->
            {:ok, merged, report(contributors, absent, true, merge_report)}

          # The fetched centers exist but cannot be combined. For example, their SP3
          # headers disagree on time scale or coordinate system, which the merge
          # refuses rather than mixing frames. Surface a tagged reason with the
          # involved centers instead of leaking the raw merge error.
          {:error, reason} ->
            {:error,
             {:incompatible_sources,
              %{centers: Enum.map(contributors, & &1.center), reason: reason}}}
        end
    end
  end

  defp report(contributors, absent, merged?, merge_report) do
    merge_report
    |> Map.merge(%{
      contributors: Enum.map(contributors, &contributor_report/1),
      absent: absent,
      source_count: length(contributors),
      single_product?: length(contributors) == 1,
      merged?: merged?
    })
  end

  defp empty_merge_report do
    %{quarantined: [], single_source: [], position_outliers: []}
  end

  defp contributor_report(info) do
    %{
      center: info.center,
      filename: info.filename,
      date: info.date,
      issue: info.issue,
      attempts: info.attempts
    }
  end

  defp absence(center, product, reason, attempts) do
    %{
      center: center,
      filename: product_filename(product),
      reason: normalize_absence_reason(reason),
      attempts: attempts
    }
  end

  defp product_filename(nil), do: nil

  defp product_filename(product) do
    case Product.canonical_filename(product) do
      {:ok, filename} -> filename
      _ -> nil
    end
  end

  defp normalize_absence_reason({:file_not_found, _}), do: :not_published
  defp normalize_absence_reason({:offline_miss, _}), do: :offline_miss
  defp normalize_absence_reason({:http_status, status}), do: {:http_status, status}
  defp normalize_absence_reason({:checksum_mismatch, _expected, _got}), do: :checksum
  defp normalize_absence_reason({:unsupported_product, _} = reason), do: reason
  defp normalize_absence_reason(reason), do: reason

  # --- option resolution ---------------------------------------------------

  defp cache_dir(opts) do
    Keyword.get(opts, :cache_dir) ||
      Application.get_env(:sidereon, :gnss_data_cache_dir) ||
      Cache.default_dir()
  end

  defp offline?(opts) do
    case Keyword.fetch(opts, :offline) do
      {:ok, value} -> value
      :error -> Application.get_env(:sidereon, :gnss_data_offline, false)
    end
  end
end
