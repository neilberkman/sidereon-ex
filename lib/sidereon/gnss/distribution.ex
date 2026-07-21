defmodule Sidereon.GNSS.Distribution do
  @moduledoc """
  Exact GNSS product acquisition from explicit public distributors.

  Product identity is independent from transport. An ordered source list may
  contain the cataloged direct archive, NASA CDDIS/Earthdata, a local file, or
  caller-provided bytes. Switching source never changes center, solution class,
  issue, cadence, date, family, or official filename.

  This module owns authenticated HTTP and cache IO. The Rust core and NIF remain
  network-free and continue to own catalog derivation and SP3/IONEX parsing.
  `Sidereon.GNSS.Data` delegates `identity/1`, `request/2`, `cddis_url/1`, and
  `acquire/2` here.
  """

  alias Sidereon.GNSS.Data
  alias Sidereon.GNSS.ExactCache
  alias Sidereon.GNSS.Ionosphere
  alias Sidereon.GNSS.SP3
  alias Sidereon.NIF

  @default_max_archive_bytes 64 * 1024 * 1024
  @default_max_product_bytes 500 * 1024 * 1024
  @default_timeout_s 30.0
  @default_cache_lock_timeout_ms 30_000
  @default_retries 3
  @default_backoff_s 0.5
  @max_redirects 8
  @cddis_host "cddis.nasa.gov"
  @urs_host "urs.earthdata.nasa.gov"
  @aiub_web_host "www.aiub.unibe.ch"
  @aiub_download_host "download.aiub.unibe.ch"
  @aiub_object_store_suffix ".s3.cloud.switch.ch"

  defmodule Source do
    @moduledoc "One explicit public distributor or caller-provided input."
    @enforce_keys [:type]
    @derive {Inspect, except: [:content]}
    defstruct [:type, :path, :content, compression: :auto]

    @type source_type :: :direct | :nasa_cddis | :local_file | :in_memory
    @type t :: %__MODULE__{
            type: source_type(),
            path: String.t() | nil,
            content: binary() | nil,
            compression: :auto | :none | :gzip | :unix_compress
          }
  end

  defmodule ProductIdentity do
    @moduledoc "Exact public GNSS product identity, independent of distributor."
    @enforce_keys [
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
      :format
    ]
    defstruct [
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

    @type t :: %__MODULE__{
            family: String.t(),
            analysis_center: String.t(),
            publisher: String.t(),
            solution_class: String.t(),
            campaign: String.t(),
            filename_version: non_neg_integer(),
            date: Date.t(),
            issue: String.t() | nil,
            span: String.t(),
            sample: String.t(),
            official_filename: String.t(),
            format: String.t(),
            format_version: String.t() | nil,
            prediction_horizon_days: non_neg_integer() | nil
          }
  end

  defmodule Request do
    @moduledoc "Exact product identity and ordered acceptable distributors."
    @enforce_keys [:identity, :sources]
    defstruct [:identity, :sources]

    @type t :: %__MODULE__{identity: ProductIdentity.t(), sources: [Source.t()]}
  end

  defmodule EarthdataAuth do
    @moduledoc "Caller-supplied Earthdata bearer-token or netrc mechanism."
    @derive {Inspect, except: [:bearer_token, :netrc_path]}
    defstruct [:bearer_token, :netrc_path, use_netrc: false]

    @type t :: %__MODULE__{
            bearer_token: String.t() | nil,
            netrc_path: String.t() | nil,
            use_netrc: boolean()
          }

    @spec bearer(String.t()) :: t()
    def bearer(token) when is_binary(token) and byte_size(token) > 0, do: %__MODULE__{bearer_token: token}

    @spec netrc(String.t() | nil) :: t()
    def netrc(path \\ nil), do: %__MODULE__{use_netrc: true, netrc_path: path}
  end

  defmodule SourceFailure do
    @moduledoc "Sanitized structured failure from one explicitly allowed source."
    @enforce_keys [:source, :error_type, :message]
    defstruct [:source, :error_type, :message, :url, :status]

    @type t :: %__MODULE__{
            source: Source.source_type(),
            error_type: atom(),
            message: String.t(),
            url: String.t() | nil,
            status: integer() | nil
          }
  end

  defmodule Provenance do
    @moduledoc "Reproducible, secret-free provenance for a successful acquisition."
    @enforce_keys [
      :requested_identity,
      :resolved_identity,
      :publisher,
      :distribution_source,
      :official_filename,
      :retrieved_at,
      :byte_length,
      :sha256,
      :cache_hit,
      :archive_compression,
      :archive_byte_length,
      :archive_sha256
    ]
    defstruct [
      :requested_identity,
      :resolved_identity,
      :publisher,
      :distribution_source,
      :official_filename,
      :original_url,
      :final_url,
      :retrieved_at,
      :byte_length,
      :sha256,
      :etag,
      :last_modified,
      :cache_hit,
      :archive_compression,
      :archive_byte_length,
      :archive_sha256,
      attempts: []
    ]

    @type t :: %__MODULE__{
            requested_identity: ProductIdentity.t(),
            resolved_identity: ProductIdentity.t(),
            publisher: String.t(),
            distribution_source: Source.source_type(),
            official_filename: String.t(),
            original_url: String.t() | nil,
            final_url: String.t() | nil,
            retrieved_at: String.t(),
            byte_length: non_neg_integer(),
            sha256: String.t(),
            etag: String.t() | nil,
            last_modified: String.t() | nil,
            cache_hit: boolean(),
            archive_compression: :none | :gzip | :unix_compress,
            archive_byte_length: non_neg_integer(),
            archive_sha256: String.t(),
            attempts: [SourceFailure.t()]
          }
  end

  defmodule Result do
    @moduledoc "Verified local product path plus acquisition provenance."
    @enforce_keys [:path, :provenance]
    defstruct [:path, :provenance]

    @type t :: %__MODULE__{path: String.t(), provenance: Provenance.t()}
  end

  @type error_reason ::
          :offline_cache_miss
          | {:invalid_option, :max_archive_bytes | :max_product_bytes}
          | {:unsupported_distribution, atom(), String.t()}
          | {:authentication_required, integer(), String.t()}
          | {:authentication_failed, integer(), String.t()}
          | {:authorization_denied, integer(), String.t()}
          | {:product_not_published, integer(), String.t()}
          | {:retired_endpoint, integer(), String.t()}
          | {:redirect_policy_failure, integer(), String.t()}
          | {:malformed_url, String.t()}
          | {:transport, atom(), String.t()}
          | {:http_client_failure, atom(), String.t()}
          | {:http_status, integer(), String.t()}
          | {:invalid_content_type, String.t(), String.t()}
          | {:error_document, String.t()}
          | {:content_length_mismatch, term(), non_neg_integer(), String.t()}
          | {:download_size_exceeded, non_neg_integer()}
          | {:decompression_failed, term()}
          | {:checksum_mismatch, String.t(), String.t()}
          | {:product_validation_failed, term()}
          | {:cache_read_failed, term()}
          | {:cache_write_failed, term()}
          | {:all_distributors_failed, [SourceFailure.t()]}

  @doc "Cataloged direct analysis-center distribution."
  @spec direct() :: Source.t()
  def direct, do: %Source{type: :direct, compression: :auto}

  @doc "Official NASA CDDIS/Earthdata HTTPS distribution."
  @spec nasa_cddis() :: Source.t()
  def nasa_cddis, do: %Source{type: :nasa_cddis, compression: :gzip}

  @doc "Caller-provided local file source."
  @spec local_file(String.t(), keyword()) :: Source.t()
  def local_file(path, opts \\ []) when is_binary(path) do
    %Source{type: :local_file, path: path, compression: Keyword.get(opts, :compression, :auto)}
  end

  @doc "Caller-provided in-memory product bytes."
  @spec in_memory(binary(), keyword()) :: Source.t()
  def in_memory(content, opts \\ []) when is_binary(content) do
    %Source{type: :in_memory, content: content, compression: Keyword.get(opts, :compression, :auto)}
  end

  @doc "Resolve an existing data product to exact distributor-independent identity."
  @spec identity(Data.Product.t()) :: {:ok, ProductIdentity.t()} | {:error, error_reason() | term()}
  def identity(%Data.Product{filename: nil} = product) do
    date = product.date

    with %Date{} <- date,
         {:ok, fields} <-
           core(
             NIF.data_product_identity(
               product.center,
               product.product_type,
               date.year,
               date.month,
               date.day,
               product.sample,
               product.issue
             )
           ),
         {:ok, identity} <- decode_core_product_identity(fields) do
      {:ok, identity}
    else
      {:error, _reason} = error -> error
      _ -> {:error, {:product_validation_failed, :requested_identity}}
    end
  end

  def identity(%Data.Product{} = product) do
    with {:ok, filename} <- Data.canonical_filename(product),
         :ok <- validate_filename(filename),
         {:ok, fields} <- parse_long_filename(filename),
         true <- fields.family == product.product_type do
      {:ok,
       %ProductIdentity{
         family: product.product_type,
         analysis_center: product.center,
         publisher: fields.publisher,
         solution_class: fields.solution_class,
         campaign: fields.campaign,
         filename_version: fields.filename_version,
         date: product.date,
         issue: fields.issue,
         span: fields.span,
         sample: fields.sample,
         official_filename: filename,
         format: if(product.product_type == "sp3", do: "SP3", else: "IONEX"),
         prediction_horizon_days: prediction_horizon(product.center)
       }}
    else
      false -> {:error, {:unsupported_product, product.product_type}}
      {:error, _} = error -> error
    end
  end

  @doc "Build an exact request from an ordered list of acceptable distributors."
  @spec request(Data.Product.t(), [Source.t() | Source.source_type()]) ::
          {:ok, Request.t()} | {:error, error_reason() | term()}
  def request(%Data.Product{} = product, sources) when is_list(sources) do
    with {:ok, identity} <- identity(product),
         :ok <- validate_request_identity(identity),
         {:ok, normalized} <- normalize_sources(sources),
         true <- normalized != [] do
      {:ok, %Request{identity: identity, sources: normalized}}
    else
      false -> {:error, {:unsupported_distribution, :none, "source list is empty"}}
      {:error, _} = error -> error
    end
  end

  @doc """
  Require available identities to be exactly the declared product set.

  The expected set must be non-empty. Both lists reject duplicates; missing and
  undeclared identities fail. Comparison includes every identity field, not
  only the official filename. For SP3 observed/predicted timing, use
  `Sidereon.GNSS.SP3.prediction_summary/1`; catalog fields and issue times are
  not substitutes for product record flags.
  """
  @spec validate_exact_product_set([ProductIdentity.t()], [ProductIdentity.t()]) ::
          :ok | {:error, error_reason() | term()}
  def validate_exact_product_set(expected, available) when is_list(expected) and is_list(available) do
    with {:ok, expected} <- identity_fields(expected),
         {:ok, available} <- identity_fields(available) do
      NIF.data_validate_exact_product_set(expected, available)
    end
  end

  def validate_exact_product_set(_expected, _available),
    do: {:error, {:exact_product_set, "expected and available must be lists"}}

  @doc "Resolve an official distribution location for a complete exact identity."
  @spec location(ProductIdentity.t(), Source.source_type() | String.t()) ::
          {:ok,
           %{
             source: Source.source_type(),
             original_url: String.t() | nil,
             archive_filename: String.t(),
             compression: :none | :gzip | :unix_compress
           }}
          | {:error, error_reason() | term()}
  def location(%ProductIdentity{} = identity, source) when is_atom(source) or is_binary(source) do
    source_code = to_string(source)

    with :ok <- validate_core_identity(identity),
         {:ok, {resolved_source, original_url, archive_filename, compression}} <-
           core(
             NIF.data_distribution_location_for_identity(
               ExactCache.identity_fields(identity),
               source_code
             )
           ),
         {:ok, resolved_source} <- decode_source(resolved_source),
         {:ok, compression} <- decode_compression(compression) do
      {:ok,
       %{
         source: resolved_source,
         original_url: original_url,
         archive_filename: archive_filename,
         compression: compression
       }}
    end
  end

  def location(_identity, source), do: {:error, {:unsupported_distribution, source, "invalid exact product identity"}}

  @doc "Build the official CDDIS URL for an exact SP3 or IONEX identity."
  @spec cddis_url(ProductIdentity.t()) :: {:ok, String.t()} | {:error, error_reason() | term()}
  def cddis_url(%ProductIdentity{} = identity) do
    with :ok <- validate_request_identity(identity),
         {:ok, %{original_url: url}} <- location(identity, :nasa_cddis),
         true <- is_binary(url) do
      {:ok, url}
    else
      false -> {:error, {:unsupported_distribution, :nasa_cddis, identity.family}}
      {:error, _reason} = error -> error
    end
  end

  @doc "Acquire an exact product from only its ordered, caller-selected sources."
  @spec acquire(Request.t(), keyword()) :: {:ok, Result.t()} | {:error, error_reason() | term()}
  def acquire(%Request{} = request, opts \\ []) do
    with :ok <- validate_request_identity(request.identity),
         :ok <- validate_size_limits(opts),
         :ok <- validate_cache_lock_timeout(opts),
         {:ok, sources} <- normalize_sources(request.sources),
         true <- sources != [] do
      do_acquire(%{request | sources: sources}, opts)
    else
      false -> {:error, {:unsupported_distribution, :none, "source list is empty"}}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec acquire_catalog_product(Data.Product.t(), keyword()) ::
          {:ok, Result.t()} | {:error, error_reason() | term()}
  def acquire_catalog_product(%Data.Product{} = product, opts \\ []) do
    with {:ok, identity} <- catalog_product_identity(product),
         :ok <- validate_request_identity(identity),
         {:ok, location} <- catalog_direct_location(product, identity),
         :ok <- validate_size_limits(opts),
         :ok <- validate_cache_lock_timeout(opts) do
      do_acquire(
        %Request{identity: identity, sources: [direct()]},
        opts,
        location
      )
    end
  end

  defp do_acquire(request, opts, direct_location \\ nil) do
    auth = Keyword.get(opts, :earthdata_auth, %EarthdataAuth{})

    request.sources
    |> Enum.reduce_while({[], nil, nil}, fn source, {attempts, _last_error, first_availability_error} ->
      path = cache_path(request.identity, source.type, opts)

      result =
        ExactCache.with_lock(
          path,
          request.identity,
          source.type,
          cache_lock_timeout_ms(opts),
          fn exact_cache ->
            :ok = ExactCache.cleanup_abandoned(exact_cache)

            acquire_locked(
              request.identity,
              source,
              path,
              auth,
              attempts,
              opts,
              exact_cache,
              direct_location
            )
          end
        )

      case result do
        {:ok, %Result{} = success} ->
          {:halt, {:ok, success}}

        {:error, reason} ->
          case distributor_fallback_kind(reason) do
            nil ->
              {:halt, {:error, reason}}

            kind ->
              failure = source_failure(source.type, reason)

              first_availability_error =
                if kind == :availability and is_nil(first_availability_error),
                  do: reason,
                  else: first_availability_error

              {:cont, {[failure | attempts], reason, first_availability_error}}
          end
      end
    end)
    |> finish_acquisition()
  end

  defp finish_acquisition({:ok, %Result{} = result}), do: {:ok, result}
  defp finish_acquisition({:error, _reason} = error), do: error

  defp finish_acquisition({_attempts, _reason, first_availability_error}) when not is_nil(first_availability_error),
    do: {:error, first_availability_error}

  defp finish_acquisition({[_one], reason, nil}), do: {:error, reason}

  defp finish_acquisition({attempts, _reason, nil}), do: {:error, {:all_distributors_failed, Enum.reverse(attempts)}}

  defp distributor_fallback_kind(:offline_cache_miss), do: :absence
  defp distributor_fallback_kind({:product_not_published, 404, _url}), do: :absence
  defp distributor_fallback_kind({:retired_endpoint, 410, _url}), do: :absence
  defp distributor_fallback_kind(reason), do: if(retryable?(reason), do: :availability)

  defp acquire_locked(identity, source, path, auth, attempts, opts, exact_cache, direct_location) do
    case load_cache(path, identity, source.type, attempts, opts, exact_cache) do
      {:ok, %Result{} = result} ->
        {:ok, result}

      :miss ->
        acquire_after_cache_miss(
          identity,
          source,
          path,
          auth,
          attempts,
          opts,
          nil,
          exact_cache,
          direct_location
        )

      {:error, {:cache_write_failed, _detail}} = error ->
        error

      {:error, cache_error} ->
        acquire_after_cache_miss(
          identity,
          source,
          path,
          auth,
          attempts,
          opts,
          cache_error,
          exact_cache,
          direct_location
        )
    end
  end

  defp acquire_after_cache_miss(identity, source, path, auth, attempts, opts, cache_error, exact_cache, direct_location) do
    network? = source.type in [:direct, :nasa_cddis]

    if network? and truthy?(Keyword.get(opts, :offline)) do
      {:error, cache_error || :offline_cache_miss}
    else
      case acquire_source(
             identity,
             source,
             path,
             auth,
             attempts,
             opts,
             exact_cache,
             direct_location
           ) do
        {:ok, %Result{} = result} -> {:ok, result}
        {:error, _reason} when not is_nil(cache_error) -> {:error, cache_error}
        {:error, _reason} = error -> error
      end
    end
  end

  defp acquire_source(identity, source, _path, auth, attempts, opts, exact_cache, direct_location) do
    with {:ok, fetched} <- read_source(identity, source, auth, opts, direct_location),
         :ok <- enforce_size(fetched.archive, max_archive_bytes(opts)),
         {:ok, compression} <-
           resolve_compression(source_compression(source, fetched), fetched.archive),
         {:ok, content} <- decompress(fetched.archive, compression, max_product_bytes(opts)),
         :ok <- verify_checksum(content, Keyword.get(opts, :sha256)),
         {:ok, resolved_identity} <- validate_product(identity, content, fetched.original_url),
         provenance =
           provenance(
             identity,
             resolved_identity,
             source.type,
             fetched,
             compression,
             content,
             attempts
           ),
         {:ok, committed_path} <- commit_cache(exact_cache, content, fetched.archive, provenance) do
      {:ok, %Result{path: committed_path, provenance: provenance}}
    end
  end

  defp read_source(identity, %Source{type: :direct}, auth, opts, direct_location) do
    with {:ok, %{url: url, compression: compression}} <-
           direct_location(identity, direct_location),
         {:ok, fetched} <- download(url, :direct, auth, opts) do
      {:ok, %{fetched | compression: compression}}
    end
  end

  defp read_source(identity, %Source{type: :nasa_cddis}, auth, opts, _direct_location) do
    with {:ok, %{original_url: url, compression: compression}} <-
           location(identity, :nasa_cddis),
         true <- is_binary(url),
         {:ok, fetched} <- download(url, :nasa_cddis, auth, opts) do
      {:ok, %{fetched | compression: compression}}
    else
      false -> {:error, {:unsupported_distribution, :nasa_cddis, identity.family}}
      {:error, _reason} = error -> error
    end
  end

  defp read_source(_identity, %Source{type: :local_file, path: path}, _auth, _opts, _direct_location)
       when is_binary(path) do
    case File.read(path) do
      {:ok, bytes} -> {:ok, local_fetch(bytes)}
      {:error, _reason} -> {:error, {:cache_read_failed, :local_file}}
    end
  end

  defp read_source(_identity, %Source{type: :in_memory, content: bytes}, _auth, _opts, _direct_location)
       when is_binary(bytes), do: {:ok, local_fetch(bytes)}

  defp read_source(_identity, %Source{type: type}, _auth, _opts, _direct_location),
    do: {:error, {:unsupported_distribution, type, "source input is invalid"}}

  defp direct_location(identity, nil) do
    with {:ok, %{original_url: url, compression: compression}} <- location(identity, :direct),
         true <- is_binary(url) do
      {:ok, %{url: url, compression: compression}}
    else
      false -> {:error, {:unsupported_distribution, :direct, identity.family}}
      {:error, _reason} = error -> error
    end
  end

  defp direct_location(_identity, %{url: url, compression: compression}),
    do: {:ok, %{url: url, compression: compression}}

  defp catalog_product_identity(product) do
    case identity(product) do
      {:ok, identity} ->
        {:ok, identity}

      {:error, _reason} ->
        if is_binary(product.pattern) and String.starts_with?(product.pattern, "alias_") do
          identity(%{
            product
            | filename: nil,
              cache_filename: nil,
              url: nil,
              compression: nil,
              span: nil,
              pattern: nil
          })
        else
          {:error, {:product_validation_failed, :catalog_identity}}
        end
    end
  end

  defp catalog_direct_location(%Data.Product{url: nil}, identity) do
    direct_location(identity, nil)
  end

  defp catalog_direct_location(%Data.Product{} = product, _identity) do
    with true <- product.product_type == "sp3",
         true <- is_binary(product.issue),
         {:ok, rows} <-
           core(
             NIF.data_ultra_sp3_locations(
               product.center,
               product.date.year,
               product.date.month,
               product.date.day,
               product.issue
             )
           ),
         {_pattern, _span, _sample, _filename, _url, compression} <-
           Enum.find(rows, fn {pattern, span, sample, filename, url, row_compression} ->
             pattern == product.pattern and span == product.span and sample == product.sample and
               filename == product.filename and url == product.url and
               row_compression == product.compression
           end) do
      {:ok, %{url: product.url, compression: normalize_compression(compression)}}
    else
      _ -> {:error, {:product_validation_failed, :catalog_location}}
    end
  end

  defp local_fetch(bytes) do
    %{
      archive: bytes,
      original_url: nil,
      final_url: nil,
      headers: [],
      compression: :auto
    }
  end

  defp download(url, source, auth, opts), do: do_download(url, source, auth, opts, 1)

  defp do_download(url, source, auth, opts, attempt) do
    retries = Keyword.get(opts, :retries, @default_retries)

    case download_once(url, source, auth, opts) do
      {:error, reason} = error ->
        if retryable?(reason) and attempt < retries do
          sleep_backoff(opts, attempt)
          do_download(url, source, auth, opts, attempt + 1)
        else
          error
        end

      success ->
        success
    end
  end

  defp download_once(url, source, auth, opts) do
    do_download_once(url, url, source, auth, opts, 0, %{})
  end

  defp do_download_once(current, original, source, auth, opts, redirect_count, cookies) do
    with :ok <- validate_url(current, source),
         {:ok, auth_headers} <- auth_headers(current, source, auth),
         headers = auth_headers ++ cookie_headers(cookies, current),
         {:ok, status, response_headers, body} <- request_http(current, headers, opts) do
      cookies = collect_cookies(response_headers, cookies, current)
      handle_response(status, response_headers, body, current, original, source, auth, opts, redirect_count, cookies)
    end
  end

  defp request_http(url, headers, opts) do
    request_opts =
      opts
      |> Keyword.drop([:earthdata_auth, :http_client, :sha256])
      |> Keyword.put(:headers, headers)

    case Keyword.fetch(opts, :http_client) do
      {:ok, fun} when is_function(fun, 2) -> request_custom_http(fun, url, request_opts)
      {:ok, nil} -> request_req_http(url, headers, opts)
      :error -> request_req_http(url, headers, opts)
      {:ok, _invalid} -> http_client_failure(:invalid_option, url)
    end
  end

  defp request_custom_http(fun, url, request_opts) do
    result =
      try do
        {:ok, fun.(url, request_opts)}
      rescue
        _exception -> {:error, :raised}
      catch
        :throw, _reason -> {:error, :thrown}
        :exit, _reason -> {:error, :exited}
      end

    case result do
      {:ok, response} -> normalize_custom_http_response(response, url)
      {:error, kind} -> http_client_failure(kind, url)
    end
  end

  defp normalize_custom_http_response({:ok, %{status: status, body: body} = response}, url) when is_integer(status),
    do: custom_http_success(status, Map.get(response, :headers, []), body, url)

  defp normalize_custom_http_response({:ok, status, headers, body}, url) when is_integer(status),
    do: custom_http_success(status, headers, body, url)

  defp normalize_custom_http_response({:ok, status, body}, url) when is_integer(status),
    do: custom_http_success(status, [], body, url)

  defp normalize_custom_http_response({:error, reason}, url) do
    case custom_retryable_transport_kind(reason) do
      {:ok, kind} -> {:error, {:transport, kind, sanitize_url(url)}}
      :error -> http_client_failure(:reported_failure, url)
    end
  end

  defp normalize_custom_http_response(_other, url), do: http_client_failure(:invalid_response, url)

  defp custom_http_success(status, headers, body, url) do
    {:ok, status, headers, IO.iodata_to_binary(body)}
  rescue
    _exception -> http_client_failure(:invalid_response, url)
  catch
    _kind, _reason -> http_client_failure(:invalid_response, url)
  end

  defp custom_retryable_transport_kind(%Req.TransportError{} = reason), do: {:ok, transport_kind(reason)}

  defp custom_retryable_transport_kind(:timeout), do: {:ok, :timeout}
  defp custom_retryable_transport_kind(reason) when reason in [:econnrefused, :nxdomain], do: {:ok, :connection}
  defp custom_retryable_transport_kind(_reason), do: :error

  defp http_client_failure(kind, url), do: {:error, {:http_client_failure, kind, sanitize_url(url)}}

  defp request_req_http(url, headers, opts) do
    timeout_ms =
      opts
      |> Keyword.get(:timeout, Keyword.get(opts, :timeout_s, @default_timeout_s))
      |> seconds_to_ms()

    case Req.get(
           url: url,
           headers: headers,
           redirect: false,
           retry: false,
           receive_timeout: timeout_ms,
           finch: :"Elixir.Sidereon.GNSS.Data.Finch",
           decode_body: false
         ) do
      {:ok, %Req.Response{status: status, headers: response_headers, body: body}} ->
        {:ok, status, response_headers, IO.iodata_to_binary(body)}

      {:error, reason} ->
        {:error, {:transport, transport_kind(reason), sanitize_url(url)}}
    end
  rescue
    _exception -> {:error, {:transport, :other, sanitize_url(url)}}
  catch
    _kind, _reason -> {:error, {:transport, :other, sanitize_url(url)}}
  end

  defp handle_response(status, headers, _body, current, original, source, auth, opts, redirects, cookies)
       when status in 300..399 do
    with true <- redirects < @max_redirects,
         location when is_binary(location) <- header_value(headers, "location"),
         {:ok, target} <- redirect_target(current, status, location, source) do
      do_download_once(target, original, source, auth, opts, redirects + 1, cookies)
    else
      _ -> {:error, {:redirect_policy_failure, status, sanitize_url(current)}}
    end
  end

  defp handle_response(401, _headers, _body, current, _original, _source, auth, _opts, _redirects, _cookies) do
    type = if auth_configured?(auth), do: :authentication_failed, else: :authentication_required
    {:error, {type, 401, sanitize_url(current)}}
  end

  defp handle_response(403, _headers, _body, current, _original, _source, _auth, _opts, _redirects, _cookies),
    do: {:error, {:authorization_denied, 403, sanitize_url(current)}}

  defp handle_response(404, _headers, _body, current, _original, _source, _auth, _opts, _redirects, _cookies),
    do: {:error, {:product_not_published, 404, sanitize_url(current)}}

  defp handle_response(410, _headers, _body, current, _original, _source, _auth, _opts, _redirects, _cookies),
    do: {:error, {:retired_endpoint, 410, sanitize_url(current)}}

  defp handle_response(status, headers, body, current, original, _source, _auth, opts, _redirects, _cookies)
       when status in 200..299 do
    with :ok <- enforce_size(body, max_archive_bytes(opts)),
         :ok <- verify_content_length(headers, body, current),
         :ok <- reject_error_document(headers, body, current) do
      {:ok,
       %{
         archive: body,
         original_url: sanitize_url(original),
         final_url: sanitize_url(current),
         headers: headers,
         compression: :auto
       }}
    end
  end

  defp handle_response(status, _headers, _body, current, _original, _source, _auth, _opts, _redirects, _cookies),
    do: {:error, {:http_status, status, sanitize_url(current)}}

  defp validate_url(url, source) do
    uri = URI.parse(url)
    scheme_ok? = if source == :nasa_cddis, do: uri.scheme == "https", else: uri.scheme in ["http", "https"]
    host = uri.host && String.downcase(uri.host)

    host_ok? =
      case source do
        :nasa_cddis ->
          host in [@cddis_host, @urs_host]

        :direct ->
          host in Data.allowed_hosts() or (is_binary(host) and String.ends_with?(host, @aiub_object_store_suffix))
      end

    if scheme_ok? and is_binary(host) and is_nil(uri.userinfo) and host_ok?,
      do: :ok,
      else: {:error, {:malformed_url, sanitize_url(url)}}
  end

  defp redirect_target(current, status, location, source) do
    source_uri = URI.parse(current)
    target = URI.merge(current, location)
    source_host = source_uri.host && String.downcase(source_uri.host)
    target_host = target.host && String.downcase(target.host)

    allowed? =
      target.scheme == "https" and is_binary(target_host) and
        case source do
          :nasa_cddis ->
            source_host in [@cddis_host, @urs_host] and target_host in [@cddis_host, @urs_host]

          :direct ->
            source_host == target_host or
              (source_host == @aiub_web_host and target_host == @aiub_download_host) or
              (source_host in [@aiub_web_host, @aiub_download_host] and
                 String.ends_with?(target_host, @aiub_object_store_suffix))
        end

    if allowed?,
      do: {:ok, URI.to_string(target)},
      else: {:error, {:redirect_policy_failure, status, sanitize_url(current)}}
  end

  defp auth_headers(_url, :direct, _auth), do: {:ok, []}

  defp auth_headers(url, :nasa_cddis, %EarthdataAuth{} = auth) do
    host = URI.parse(url).host

    cond do
      host not in [@cddis_host, @urs_host] ->
        {:ok, []}

      is_binary(auth.bearer_token) ->
        {:ok, [{"authorization", "Bearer " <> auth.bearer_token}]}

      auth.use_netrc and host == @urs_host ->
        with {:ok, {login, password}} <- read_netrc(auth) do
          {:ok, [{"authorization", "Basic " <> Base.encode64(login <> ":" <> password)}]}
        end

      true ->
        {:ok, []}
    end
  end

  defp read_netrc(auth) do
    path = auth.netrc_path || Path.join(System.user_home!(), ".netrc")

    with {:ok, contents} <- File.read(path),
         {:ok, entry} <- netrc_entry(String.split(contents), @urs_host),
         login when is_binary(login) <- Map.get(entry, "login"),
         password when is_binary(password) <- Map.get(entry, "password") do
      {:ok, {login, password}}
    else
      _ -> {:error, {:authentication_failed, 0, "https://#{@urs_host}/"}}
    end
  end

  defp netrc_entry(tokens, host), do: netrc_entry(tokens, host, false, %{})
  defp netrc_entry([], _host, true, entry), do: {:ok, entry}
  defp netrc_entry([], _host, false, _entry), do: {:error, :not_found}

  defp netrc_entry(["machine", value | _rest], host, true, entry) when value != host, do: {:ok, entry}

  defp netrc_entry(["machine", value | rest], host, _found, _entry), do: netrc_entry(rest, host, value == host, %{})

  defp netrc_entry([key, value | rest], host, true, entry) when key in ["login", "password"],
    do: netrc_entry(rest, host, true, Map.put(entry, key, value))

  defp netrc_entry([_token | rest], host, found, entry), do: netrc_entry(rest, host, found, entry)

  defp auth_configured?(%EarthdataAuth{bearer_token: token, use_netrc: netrc?}), do: is_binary(token) or netrc?

  defp cookie_headers(cookies, _url) when map_size(cookies) == 0, do: []

  defp cookie_headers(cookies, url) do
    uri = URI.parse(url)
    host = uri.host && String.downcase(uri.host)
    path = uri.path || "/"

    value =
      cookies
      |> Map.values()
      |> Enum.filter(&cookie_available?(&1, host, path, uri.scheme))
      |> Enum.sort_by(& &1.name)
      |> Enum.map_join("; ", &"#{&1.name}=#{&1.value}")

    if value == "", do: [], else: [{"cookie", value}]
  end

  defp collect_cookies(headers, cookies, url) do
    headers
    |> header_values("set-cookie")
    |> Enum.reduce(cookies, fn value, acc ->
      case parse_set_cookie(value, url) do
        {:put, key, cookie} -> Map.put(acc, key, cookie)
        {:delete, key} -> Map.delete(acc, key)
        :ignore -> acc
      end
    end)
  end

  defp parse_set_cookie(value, url) do
    uri = URI.parse(url)
    request_host = uri.host && String.downcase(uri.host)
    request_path = uri.path || "/"
    [pair | attribute_parts] = String.split(value, ";")

    with [name, cookie_value] <- String.split(String.trim(pair), "=", parts: 2),
         true <- name != "" and is_binary(request_host),
         attributes = cookie_attributes(attribute_parts),
         {domain, host_only?} <- cookie_domain(attributes, request_host),
         true <- cookie_domain_matches?(request_host, domain, host_only?) do
      path = cookie_path(attributes, request_path)
      key = {domain, path, name}

      if attributes["max-age"] == "0" do
        {:delete, key}
      else
        {:put, key,
         %{
           name: name,
           value: cookie_value,
           domain: domain,
           path: path,
           host_only?: host_only?,
           secure?: Map.has_key?(attributes, "secure")
         }}
      end
    else
      _ -> :ignore
    end
  rescue
    _error -> :ignore
  end

  defp cookie_attributes(parts) do
    Enum.reduce(parts, %{}, fn part, attributes ->
      case String.split(String.trim(part), "=", parts: 2) do
        [name, value] -> Map.put(attributes, String.downcase(name), String.trim(value))
        [name] -> Map.put(attributes, String.downcase(name), true)
      end
    end)
  end

  defp cookie_domain(attributes, request_host) do
    case attributes["domain"] do
      domain when is_binary(domain) -> {domain |> String.trim_leading(".") |> String.downcase(), false}
      _ -> {request_host, true}
    end
  end

  defp cookie_path(attributes, request_path) do
    case attributes["path"] do
      "/" <> _ = path -> path
      _ -> default_cookie_path(request_path)
    end
  end

  defp default_cookie_path("/" <> _ = request_path) do
    String.split(request_path, "/")
    |> Enum.drop(-1)
    |> Enum.join("/")
    |> case do
      "" -> "/"
      path -> path
    end
  end

  defp default_cookie_path(_request_path), do: "/"

  defp cookie_available?(cookie, host, path, scheme) do
    is_binary(host) and cookie_domain_matches?(host, cookie.domain, cookie.host_only?) and
      cookie_path_matches?(path, cookie.path) and (not cookie.secure? or scheme == "https")
  end

  defp cookie_domain_matches?(host, domain, true), do: host == domain

  defp cookie_domain_matches?(host, domain, false), do: host == domain or String.ends_with?(host, "." <> domain)

  defp cookie_path_matches?(request_path, cookie_path) do
    request_path == cookie_path or
      (String.ends_with?(cookie_path, "/") and String.starts_with?(request_path, cookie_path)) or
      String.starts_with?(request_path, cookie_path <> "/")
  end

  defp verify_content_length(headers, body, url) do
    case header_value(headers, "content-length") do
      nil ->
        :ok

      declared ->
        case Integer.parse(declared) do
          {expected, ""} when expected == byte_size(body) -> :ok
          {expected, ""} -> {:error, {:content_length_mismatch, expected, byte_size(body), sanitize_url(url)}}
          _ -> {:error, {:content_length_mismatch, :invalid, byte_size(body), sanitize_url(url)}}
        end
    end
  end

  defp reject_error_document(headers, body, url) do
    content_type =
      (header_value(headers, "content-type") || "") |> String.split(";", parts: 2) |> hd() |> String.downcase()

    prefix = body |> binary_part(0, min(byte_size(body), 512)) |> String.trim_leading() |> String.downcase()

    cond do
      content_type in ["text/html", "application/xhtml+xml"] ->
        {:error, {:invalid_content_type, content_type, sanitize_url(url)}}

      Enum.any?(["<!doctype html", "<html", "<head", "<body"], &String.starts_with?(prefix, &1)) ->
        {:error, {:error_document, sanitize_url(url)}}

      true ->
        :ok
    end
  end

  defp header_value(headers, name), do: headers |> header_values(name) |> List.first()

  defp header_values(headers, name) when is_map(headers) do
    headers
    |> Enum.flat_map(fn {key, value} ->
      if String.downcase(to_string(key)) == name, do: List.wrap(value), else: []
    end)
    |> Enum.map(&IO.iodata_to_binary/1)
  end

  defp header_values(headers, name) when is_list(headers) do
    headers
    |> Enum.flat_map(fn
      {key, value} -> if String.downcase(to_string(key)) == name, do: List.wrap(value), else: []
      _ -> []
    end)
    |> Enum.map(&IO.iodata_to_binary/1)
  end

  defp header_values(_headers, _name), do: []

  defp resolve_compression(:auto, <<0x1F, 0x8B, _rest::binary>>), do: {:ok, :gzip}
  defp resolve_compression(:auto, <<0x1F, 0x9D, _rest::binary>>), do: {:ok, :unix_compress}
  defp resolve_compression(:auto, _bytes), do: {:ok, :none}

  defp resolve_compression(compression, _bytes) when compression in [:none, :gzip, :unix_compress],
    do: {:ok, compression}

  defp resolve_compression(compression, _bytes), do: {:error, {:decompression_failed, {:unknown, compression}}}

  defp normalize_compression("gzip"), do: :gzip
  defp normalize_compression("none"), do: :none
  defp normalize_compression("unix_compress"), do: :unix_compress
  defp normalize_compression(:gzip), do: :gzip
  defp normalize_compression(:none), do: :none
  defp normalize_compression(:unix_compress), do: :unix_compress
  defp normalize_compression(_), do: :auto

  defp source_compression(%Source{type: type}, %{compression: compression})
       when type in [:direct, :nasa_cddis] and compression in [:none, :gzip, :unix_compress], do: compression

  defp source_compression(%Source{compression: compression}, _fetched), do: compression

  defp decompress(bytes, :none, limit),
    do: if(byte_size(bytes) <= limit, do: {:ok, bytes}, else: {:error, {:decompression_failed, :size_limit}})

  defp decompress(bytes, :gzip, limit) do
    stream = :zlib.open()

    try do
      :ok = :zlib.inflateInit(stream, 31)
      bounded_inflate(stream, :zlib.safeInflate(stream, bytes), limit, 0, [], 0)
    rescue
      _error -> {:error, {:decompression_failed, :invalid_gzip}}
    catch
      _kind, _reason -> {:error, {:decompression_failed, :invalid_gzip}}
    after
      try do
        :zlib.inflateEnd(stream)
      rescue
        _error -> :ok
      catch
        _kind, _reason -> :ok
      end

      :zlib.close(stream)
    end
  end

  defp decompress(bytes, :unix_compress, limit) do
    case NIF.data_unix_compress_decompress(bytes, limit) do
      {:ok, content} -> {:ok, content}
      {:error, {:decompress, detail}} -> {:error, {:decompression_failed, detail}}
      {:error, detail} -> {:error, {:decompression_failed, detail}}
    end
  end

  defp bounded_inflate(stream, {status, chunk}, limit, size, chunks, empty_count)
       when status in [:continue, :finished] do
    chunk_size = :erlang.iolist_size(chunk)
    empty_count = if chunk_size == 0, do: empty_count + 1, else: 0

    cond do
      size + chunk_size > limit ->
        {:error, {:decompression_failed, :size_limit}}

      status == :finished ->
        {:ok, [chunk | chunks] |> Enum.reverse() |> IO.iodata_to_binary()}

      empty_count > 4 ->
        {:error, {:decompression_failed, :invalid_gzip}}

      true ->
        bounded_inflate(
          stream,
          :zlib.safeInflate(stream, []),
          limit,
          size + chunk_size,
          [chunk | chunks],
          empty_count
        )
    end
  end

  defp bounded_inflate(_stream, {:need_dictionary, _adler, _chunk}, _limit, _size, _chunks, _empty_count),
    do: {:error, {:decompression_failed, :dictionary_required}}

  defp verify_checksum(_bytes, nil), do: :ok

  defp verify_checksum(bytes, expected) when is_binary(expected) do
    got = sha256(bytes)
    expected = String.downcase(expected)
    if got == expected, do: :ok, else: {:error, {:checksum_mismatch, expected, got}}
  end

  defp verify_checksum(_bytes, expected), do: {:error, {:checksum_mismatch, inspect(expected), ""}}

  defp validate_product(%ProductIdentity{family: "sp3"} = identity, bytes, _original_url) do
    with {:ok, request} <- SP3.ExactRequest.from_identity(identity),
         {:ok, _sp3, _coverage} <- SP3.parse_exact(bytes, request),
         {:ok, version} <- sp3_version(bytes),
         resolved_version = "SP3-#{version}",
         :ok <- validate_requested_format_version(identity.format_version, resolved_version) do
      {:ok, %{identity | format_version: resolved_version}}
    else
      {:error, {:product_validation_failed, _} = reason} -> {:error, reason}
      {:error, reason} -> {:error, {:product_validation_failed, reason}}
    end
  end

  defp validate_product(%ProductIdentity{family: "ionex"} = identity, bytes, _original_url) do
    with {:ok, _handle} <- Ionosphere.parse_ionex(bytes),
         {:ok, version} <- ionex_version(bytes),
         :ok <- validate_ionex_metadata(identity, bytes),
         resolved_version = "IONEX-#{version}",
         :ok <- validate_requested_format_version(identity.format_version, resolved_version) do
      {:ok, %{identity | format_version: resolved_version}}
    else
      {:error, {:product_validation_failed, _} = reason} -> {:error, reason}
      {:error, reason} -> {:error, {:product_validation_failed, reason}}
    end
  end

  defp validate_product(identity, _bytes, _original_url),
    do: {:error, {:unsupported_distribution, :validation, identity.family}}

  defp validate_requested_format_version(nil, _resolved), do: :ok
  defp validate_requested_format_version(version, version), do: :ok

  defp validate_requested_format_version(_requested, _resolved),
    do: {:error, {:product_validation_failed, :format_version}}

  defp sp3_version(<<"#", version, _rest::binary>>) when version in ~c"aAbBcCdD",
    do: {:ok, <<version>> |> String.downcase()}

  defp sp3_version(_bytes), do: {:error, {:product_validation_failed, :sp3_version}}

  defp ionex_version(bytes) do
    first = bytes |> String.split("\n", parts: 2) |> hd()

    if String.contains?(first, "IONEX VERSION / TYPE") do
      version = first |> String.slice(0, 20) |> String.trim()
      if version == "", do: {:error, {:product_validation_failed, :ionex_version}}, else: {:ok, version}
    else
      {:error, {:product_validation_failed, :ionex_version}}
    end
  end

  defp validate_ionex_metadata(identity, bytes) do
    epochs =
      bytes
      |> String.split("\n")
      |> Enum.flat_map(fn line ->
        if line |> String.trim_trailing() |> String.ends_with?("EPOCH OF CURRENT MAP") do
          line
          |> String.slice(0, 36)
          |> String.split()
          |> Enum.take(5)
          |> Enum.map(&Integer.parse/1)
          |> case do
            [{year, ""}, {month, ""}, {day, ""}, {hour, ""}, {minute, ""}] ->
              [{year, month, day, hour, minute}]

            _ ->
              []
          end
        else
          []
        end
      end)

    with [{year, month, day, hour, minute} | _] <- epochs,
         {:ok, date} <- Date.new(year, month, day),
         true <- date == identity.date,
         true <- "#{pad2(hour)}#{pad2(minute)}" == identity.issue,
         :ok <- validate_ionex_cadence(identity.sample, epochs) do
      :ok
    else
      _ -> {:error, {:product_validation_failed, :ionex_identity_metadata}}
    end
  end

  defp validate_ionex_cadence(_sample, [_one]), do: :ok

  defp validate_ionex_cadence(sample, [first, second | _]) do
    with {:ok, first_dt} <- tuple_datetime(first),
         {:ok, second_dt} <- tuple_datetime(second),
         expected when is_integer(expected) <- sample_seconds(sample),
         true <- NaiveDateTime.diff(second_dt, first_dt, :second) == expected do
      :ok
    else
      _ -> {:error, {:product_validation_failed, :ionex_cadence}}
    end
  end

  defp tuple_datetime({year, month, day, hour, minute}), do: NaiveDateTime.new(year, month, day, hour, minute, 0)

  defp sample_seconds(<<digits::binary-size(2), unit>>) do
    case Integer.parse(digits) do
      {value, ""} ->
        case unit do
          ?S -> value
          ?M -> value * 60
          ?H -> value * 3600
          ?D -> value * 86_400
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp sample_seconds(_sample), do: nil
  defp pad2(value), do: value |> Integer.to_string() |> String.pad_leading(2, "0")

  defp provenance(identity, resolved, source, fetched, compression, content, attempts) do
    %Provenance{
      requested_identity: identity,
      resolved_identity: resolved,
      publisher: identity.publisher,
      distribution_source: source,
      official_filename: identity.official_filename,
      original_url: fetched.original_url,
      final_url: fetched.final_url,
      retrieved_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      byte_length: byte_size(content),
      sha256: sha256(content),
      etag: header_value(fetched.headers, "etag"),
      last_modified: header_value(fetched.headers, "last-modified"),
      cache_hit: false,
      archive_compression: compression,
      archive_byte_length: byte_size(fetched.archive),
      archive_sha256: sha256(fetched.archive),
      attempts: Enum.reverse(attempts)
    }
  end

  defp cache_path(identity, source, opts) do
    root =
      case Keyword.fetch(opts, :cache_dir) do
        {:ok, path} -> to_string(path)
        :error -> Data.default_cache_dir()
      end

    Path.join([
      root,
      "products",
      "v1",
      Atom.to_string(source),
      identity.family,
      identity_key(identity),
      identity.official_filename
    ])
  end

  @doc "Returns the stable cache key derived from every exact identity field."
  @spec identity_key(ProductIdentity.t()) :: String.t()
  def identity_key(%ProductIdentity{} = identity) do
    payload =
      [
        identity.family,
        identity.analysis_center,
        identity.publisher,
        identity.solution_class,
        identity.campaign,
        Integer.to_string(identity.filename_version),
        Date.to_iso8601(identity.date),
        identity.issue,
        identity.span,
        identity.sample,
        identity.official_filename,
        identity.format,
        identity.format_version || "",
        if(identity.prediction_horizon_days,
          do: Integer.to_string(identity.prediction_horizon_days),
          else: ""
        )
      ]
      |> Enum.join(<<0>>)

    digest = :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower) |> binary_part(0, 20)
    "#{String.downcase(identity.publisher)}-#{identity.solution_class}-#{digest}"
  end

  defp load_cache(path, identity, source, attempts, opts, exact_cache) do
    case cache_files(path, identity, source, exact_cache) do
      :miss ->
        :miss

      {:error, _reason} ->
        {:error, {:cache_read_failed, Path.basename(path)}}

      {:ok, files, legacy?} ->
        with {:ok, content} <- cache_content(files, :product),
             {:ok, archive} <- cache_content(files, :archive),
             {:ok, json} <- cache_provenance(files),
             {:ok, map} <- Jason.decode(json),
             {:ok, provenance} <- provenance_from_map(map),
             true <- provenance.requested_identity == identity,
             true <- provenance.distribution_source == source,
             true <- provenance.sha256 == sha256(content),
             true <- provenance.byte_length == byte_size(content),
             true <- provenance.archive_sha256 == sha256(archive),
             true <- provenance.archive_byte_length == byte_size(archive),
             :ok <- verify_checksum(content, Keyword.get(opts, :sha256)),
             {:ok, resolved} <- validate_product(identity, content, provenance.original_url),
             true <- resolved == provenance.resolved_identity,
             {:ok, committed_path} <-
               maybe_migrate_cache(exact_cache, content, archive, provenance, files.product, legacy?) do
          {:ok,
           %Result{
             path: committed_path,
             provenance: %{provenance | cache_hit: true, attempts: Enum.reverse(attempts)}
           }}
        else
          {:error, {:checksum_mismatch, _, _} = reason} -> {:error, reason}
          {:error, {:cache_write_failed, _detail}} = error -> error
          _ -> {:error, {:cache_read_failed, Path.basename(path)}}
        end
    end
  end

  defp cache_files(path, _identity, _source, exact_cache) do
    case ExactCache.committed_files(exact_cache) do
      {:ok, files} ->
        {:ok, files, false}

      :miss ->
        if File.exists?(path) do
          {:ok,
           %{
             product: path,
             archive: archive_path(path),
             provenance: provenance_path(path),
             product_bytes: nil,
             archive_bytes: nil,
             provenance_bytes: nil
           }, true}
        else
          :miss
        end

      {:error, _reason} ->
        {:error, {:cache_read_failed, Path.basename(path)}}
    end
  end

  defp maybe_migrate_cache(exact_cache, content, archive, provenance, _product_path, true),
    do: commit_cache(exact_cache, content, archive, provenance)

  defp maybe_migrate_cache(_exact_cache, _content, _archive, _provenance, product_path, false), do: {:ok, product_path}

  defp cache_content(%{product_bytes: bytes}, :product) when is_binary(bytes), do: {:ok, bytes}
  defp cache_content(%{archive_bytes: bytes}, :archive) when is_binary(bytes), do: {:ok, bytes}
  defp cache_content(files, kind), do: cache_read(Map.fetch!(files, kind))

  defp cache_read(path) do
    case File.read(path) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, _reason} -> {:error, {:cache_read_failed, Path.basename(path)}}
    end
  end

  defp cache_provenance(%{provenance_bytes: bytes}) when is_binary(bytes), do: {:ok, bytes}
  defp cache_provenance(files), do: cache_read(files.provenance)

  defp commit_cache(exact_cache, content, archive, provenance) do
    provenance_json = Jason.encode!(provenance_to_map(provenance), pretty: true)

    case ExactCache.publish(exact_cache, content, archive, provenance_json) do
      {:ok, files} -> {:ok, files.product}
      {:error, _reason} = error -> error
    end
  end

  defp archive_path(path), do: path <> ".archive"
  defp provenance_path(path), do: path <> ".provenance.json"

  defp provenance_to_map(provenance) do
    %{
      "schema_version" => 1,
      "requested_identity" => identity_to_map(provenance.requested_identity),
      "resolved_identity" => identity_to_map(provenance.resolved_identity),
      "publisher" => provenance.publisher,
      "distribution_source" => Atom.to_string(provenance.distribution_source),
      "official_filename" => provenance.official_filename,
      "original_url" => provenance.original_url,
      "final_url" => provenance.final_url,
      "retrieved_at" => provenance.retrieved_at,
      "byte_length" => provenance.byte_length,
      "sha256" => provenance.sha256,
      "etag" => provenance.etag,
      "last_modified" => provenance.last_modified,
      "cache_hit" => provenance.cache_hit,
      "archive_compression" => Atom.to_string(provenance.archive_compression),
      "archive_byte_length" => provenance.archive_byte_length,
      "archive_sha256" => provenance.archive_sha256,
      "attempts" => Enum.map(provenance.attempts, &failure_to_map/1)
    }
  end

  defp provenance_from_map(map) do
    with {:ok, requested} <- identity_from_map(map["requested_identity"]),
         {:ok, resolved} <- identity_from_map(map["resolved_identity"]),
         {:ok, source} <- source_atom(map["distribution_source"]),
         {:ok, compression} <- compression_atom(map["archive_compression"]),
         {:ok, attempts} <- failures_from_maps(map["attempts"] || []) do
      {:ok,
       %Provenance{
         requested_identity: requested,
         resolved_identity: resolved,
         publisher: map["publisher"],
         distribution_source: source,
         official_filename: map["official_filename"],
         original_url: map["original_url"],
         final_url: map["final_url"],
         retrieved_at: map["retrieved_at"],
         byte_length: map["byte_length"],
         sha256: map["sha256"],
         etag: map["etag"],
         last_modified: map["last_modified"],
         cache_hit: map["cache_hit"],
         archive_compression: compression,
         archive_byte_length: map["archive_byte_length"],
         archive_sha256: map["archive_sha256"],
         attempts: attempts
       }}
    end
  rescue
    _error -> {:error, :invalid_provenance}
  end

  defp identity_to_map(identity) do
    %{
      "family" => identity.family,
      "analysis_center" => identity.analysis_center,
      "publisher" => identity.publisher,
      "solution_class" => identity.solution_class,
      "campaign" => identity.campaign,
      "filename_version" => identity.filename_version,
      "date" => Date.to_iso8601(identity.date),
      "issue" => identity.issue,
      "span" => identity.span,
      "sample" => identity.sample,
      "official_filename" => identity.official_filename,
      "format" => identity.format,
      "format_version" => identity.format_version,
      "prediction_horizon_days" => identity.prediction_horizon_days
    }
  end

  defp identity_from_map(map) when is_map(map) do
    with {:ok, date} <- Date.from_iso8601(map["date"]) do
      {:ok,
       %ProductIdentity{
         family: map["family"],
         analysis_center: map["analysis_center"],
         publisher: map["publisher"],
         solution_class: map["solution_class"],
         campaign: map["campaign"],
         filename_version: map["filename_version"],
         date: date,
         issue: map["issue"],
         span: map["span"],
         sample: map["sample"],
         official_filename: map["official_filename"],
         format: map["format"],
         format_version: map["format_version"],
         prediction_horizon_days: map["prediction_horizon_days"]
       }}
    end
  end

  defp identity_from_map(_map), do: {:error, :invalid_identity}

  defp failure_to_map(failure) do
    %{
      "source" => Atom.to_string(failure.source),
      "error_type" => Atom.to_string(failure.error_type),
      "message" => failure.message,
      "url" => failure.url,
      "status" => failure.status
    }
  end

  defp failures_from_maps(maps) when is_list(maps) do
    maps
    |> Enum.reduce_while({:ok, []}, fn map, {:ok, failures} ->
      with {:ok, source} <- source_atom(map["source"]),
           {:ok, error_type} <- failure_atom(map["error_type"]) do
        failure = %SourceFailure{
          source: source,
          error_type: error_type,
          message: map["message"],
          url: map["url"],
          status: map["status"]
        }

        {:cont, {:ok, [failure | failures]}}
      else
        _ -> {:halt, {:error, :invalid_failure}}
      end
    end)
    |> case do
      {:ok, failures} -> {:ok, Enum.reverse(failures)}
      error -> error
    end
  end

  defp failures_from_maps(_maps), do: {:error, :invalid_failures}

  defp source_failure(source, reason) do
    {type, message, url, status} = failure_fields(reason)
    %SourceFailure{source: source, error_type: type, message: message, url: url, status: status}
  end

  defp failure_fields({type, status, url})
       when type in [
              :authentication_required,
              :authentication_failed,
              :authorization_denied,
              :product_not_published,
              :retired_endpoint,
              :redirect_policy_failure,
              :http_status
            ], do: {type, Atom.to_string(type), url, status}

  defp failure_fields({:transport, kind, url}), do: {:transport, "transport:#{kind}", url, nil}

  defp failure_fields({:http_client_failure, kind, url}),
    do: {:http_client_failure, "http_client_failure:#{kind}", url, nil}

  defp failure_fields({:malformed_url, url}), do: {:malformed_url, "malformed_url", url, nil}

  defp failure_fields({type, _expected, _got}) when type in [:checksum_mismatch],
    do: {type, Atom.to_string(type), nil, nil}

  defp failure_fields({type, _source, _detail}) when type in [:unsupported_distribution],
    do: {type, Atom.to_string(type), nil, nil}

  defp failure_fields({type, _, _, url}) when type in [:content_length_mismatch],
    do: {type, Atom.to_string(type), url, nil}

  defp failure_fields({type, _, url}) when type in [:invalid_content_type], do: {type, Atom.to_string(type), url, nil}
  defp failure_fields({type, url}) when type in [:error_document], do: {type, Atom.to_string(type), url, nil}
  defp failure_fields({type, _detail}) when is_atom(type), do: {type, Atom.to_string(type), nil, nil}
  defp failure_fields(type) when is_atom(type), do: {type, Atom.to_string(type), nil, nil}
  defp failure_fields(reason), do: {:unknown, inspect(reason), nil, nil}

  defp source_atom(value) when value in ["direct", "nasa_cddis", "local_file", "in_memory"],
    do: {:ok, String.to_existing_atom(value)}

  defp source_atom(_value), do: {:error, :invalid_source}

  defp compression_atom("gzip"), do: {:ok, :gzip}
  defp compression_atom("none"), do: {:ok, :none}
  defp compression_atom("unix_compress"), do: {:ok, :unix_compress}
  defp compression_atom(_value), do: {:error, :invalid_compression}

  @failure_atoms ~w(authentication_required authentication_failed authorization_denied product_not_published retired_endpoint redirect_policy_failure malformed_url transport http_client_failure http_status invalid_content_type error_document content_length_mismatch download_size_exceeded decompression_failed checksum_mismatch product_validation_failed cache_read_failed cache_write_failed offline_cache_miss unsupported_distribution)a

  defp failure_atom(value) when is_binary(value) do
    atom = String.to_existing_atom(value)
    if atom in @failure_atoms, do: {:ok, atom}, else: {:error, :invalid_failure}
  rescue
    ArgumentError -> {:error, :invalid_failure}
  end

  defp normalize_sources(sources) when is_list(sources) do
    sources
    |> Enum.reduce_while({:ok, []}, fn source, {:ok, acc} ->
      case normalize_source(source) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp normalize_sources(_sources), do: {:error, {:unsupported_distribution, :invalid, "source list is invalid"}}

  defp normalize_source(%Source{type: :direct, path: nil, content: nil, compression: :auto} = source), do: {:ok, source}

  defp normalize_source(%Source{type: :nasa_cddis, path: nil, content: nil, compression: :gzip} = source),
    do: {:ok, source}

  defp normalize_source(%Source{type: :local_file, path: path, content: nil, compression: compression} = source)
       when is_binary(path) and byte_size(path) > 0 and compression in [:auto, :none, :gzip, :unix_compress],
       do: {:ok, source}

  defp normalize_source(%Source{type: :in_memory, path: nil, content: content, compression: compression} = source)
       when is_binary(content) and compression in [:auto, :none, :gzip, :unix_compress], do: {:ok, source}

  defp normalize_source(%Source{type: type}), do: {:error, {:unsupported_distribution, type, "source input is invalid"}}

  defp normalize_source(:direct), do: {:ok, direct()}
  defp normalize_source(:nasa_cddis), do: {:ok, nasa_cddis()}
  defp normalize_source(type), do: {:error, {:unsupported_distribution, type, "unknown source"}}

  defp parse_long_filename(filename) do
    regex = ~r/^([A-Z]{3})(\d)([A-Z]{3})(FIN|RAP|ULT|PRD)_(\d{7})(\d{4})_([^_]+)_([^_]+)_(ORB\.SP3|GIM\.INX)$/

    case Regex.run(regex, filename) do
      [_, publisher, version, campaign, solution, _date, issue, span, sample, suffix] ->
        {:ok,
         %{
           publisher: publisher,
           filename_version: String.to_integer(version),
           campaign: campaign,
           solution_class: solution_class(solution),
           issue: issue,
           span: span,
           sample: sample,
           family: if(suffix == "ORB.SP3", do: "sp3", else: "ionex")
         }}

      _ ->
        {:error, {:product_validation_failed, :official_filename}}
    end
  end

  defp solution_class("FIN"), do: "final"
  defp solution_class("RAP"), do: "rapid"
  defp solution_class("ULT"), do: "ultra_rapid"
  defp solution_class("PRD"), do: "predicted"

  defp prediction_horizon("cod_prd1"), do: 1
  defp prediction_horizon("cod_prd2"), do: 2
  defp prediction_horizon(_center), do: nil

  defp decode_core_product_identity([
         family,
         analysis_center,
         publisher,
         solution_class,
         campaign,
         filename_version,
         year,
         month,
         day,
         issue,
         span,
         sample,
         official_filename,
         format,
         format_version,
         prediction_horizon_days
       ]) do
    with {filename_version, ""} <- Integer.parse(filename_version),
         {year, ""} <- Integer.parse(year),
         {month, ""} <- Integer.parse(month),
         {day, ""} <- Integer.parse(day),
         {:ok, date} <- Date.new(year, month, day),
         {:ok, prediction_horizon_days} <- decode_optional_integer(prediction_horizon_days) do
      {:ok,
       %ProductIdentity{
         family: family,
         analysis_center: analysis_center,
         publisher: publisher,
         solution_class: solution_class,
         campaign: campaign,
         filename_version: filename_version,
         date: date,
         issue: empty_to_nil(issue),
         span: span,
         sample: sample,
         official_filename: official_filename,
         format: format,
         format_version: empty_to_nil(format_version),
         prediction_horizon_days: prediction_horizon_days
       }}
    else
      _ -> {:error, :invalid_core_product_identity}
    end
  end

  defp decode_core_product_identity(_fields), do: {:error, :invalid_core_product_identity}

  defp decode_optional_integer(""), do: {:ok, nil}

  defp decode_optional_integer(value) do
    case Integer.parse(value) do
      {integer, ""} -> {:ok, integer}
      _ -> {:error, :invalid_core_product_identity}
    end
  end

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value

  defp decode_source("direct"), do: {:ok, :direct}
  defp decode_source("nasa_cddis"), do: {:ok, :nasa_cddis}
  defp decode_source("local_file"), do: {:ok, :local_file}
  defp decode_source("in_memory"), do: {:ok, :in_memory}
  defp decode_source(_source), do: {:error, :invalid_core_distribution_source}

  defp decode_compression("gzip"), do: {:ok, :gzip}
  defp decode_compression("none"), do: {:ok, :none}
  defp decode_compression("unix_compress"), do: {:ok, :unix_compress}
  defp decode_compression(_compression), do: {:error, :invalid_core_compression}

  defp identity_fields(identities) do
    identities
    |> Enum.reduce_while({:ok, []}, fn
      %ProductIdentity{date: %Date{} = date} = identity, {:ok, fields} ->
        values = [
          identity.family,
          identity.analysis_center,
          identity.publisher,
          identity.solution_class,
          identity.campaign,
          to_string(identity.filename_version),
          to_string(date.year),
          to_string(date.month),
          to_string(date.day),
          identity.issue || "",
          identity.span,
          identity.sample,
          identity.official_filename,
          identity.format,
          identity.format_version || "",
          if(identity.prediction_horizon_days,
            do: to_string(identity.prediction_horizon_days),
            else: ""
          )
        ]

        case validate_core_identity(identity) do
          :ok ->
            if Enum.all?(values, &is_binary/1) do
              {:cont, {:ok, [values | fields]}}
            else
              {:halt, {:error, {:exact_product_set, "identity fields must use their declared types"}}}
            end

          {:error, _reason} = error ->
            {:halt, error}
        end

      _, _acc ->
        {:halt, {:error, {:exact_product_set, "entries must be ProductIdentity structs"}}}
    end)
    |> case do
      {:ok, fields} -> {:ok, Enum.reverse(fields)}
      error -> error
    end
  end

  defp validate_request_identity(%ProductIdentity{} = identity) do
    with true <- identity.family in ["sp3", "ionex"],
         :ok <- validate_core_identity(identity) do
      :ok
    else
      {:error, _reason} = error -> error
      _ -> {:error, {:unsupported_product, identity.family}}
    end
  rescue
    _error -> {:error, {:product_validation_failed, :requested_identity}}
  end

  defp validate_request_identity(_identity), do: {:error, {:product_validation_failed, :requested_identity}}

  defp validate_core_identity(%ProductIdentity{} = identity) do
    supported_combination = identity.analysis_center <> "/" <> identity.family

    with :ok <- validate_filename(identity.official_filename),
         fields = ExactCache.identity_fields(identity),
         true <- Enum.all?(fields, &is_binary/1),
         :ok <- NIF.data_validate_exact_product_set([fields], [fields]) do
      :ok
    else
      {:error, {:malformed_url, _message}} = error ->
        error

      {:error, {:unknown_center, _code}} = error ->
        error

      {:error, {:unsupported_product, ^supported_combination}} = error ->
        error

      {:error, _reason} ->
        {:error, {:product_validation_failed, :requested_identity}}

      _ ->
        {:error, {:product_validation_failed, :requested_identity}}
    end
  rescue
    _error -> {:error, {:product_validation_failed, :requested_identity}}
  end

  defp validate_filename(filename) when is_binary(filename) and filename not in ["", ".", ".."] do
    if Path.basename(filename) == filename and not String.contains?(filename, ["..", "\0", "/", "\\"]),
      do: :ok,
      else: {:error, {:malformed_url, "invalid official filename"}}
  end

  defp validate_filename(_filename), do: {:error, {:malformed_url, "invalid official filename"}}

  defp sanitize_url(nil), do: nil

  defp sanitize_url(url) when is_binary(url) do
    uri = URI.parse(url)

    if is_binary(uri.host) do
      URI.to_string(%{uri | userinfo: nil, query: nil, fragment: nil})
    else
      "<invalid-url>"
    end
  rescue
    _error -> "<invalid-url>"
  end

  defp enforce_size(bytes, limit) when byte_size(bytes) <= limit, do: :ok
  defp enforce_size(_bytes, limit), do: {:error, {:download_size_exceeded, limit}}

  defp retryable?({:transport, _kind, _url}), do: true
  defp retryable?({:http_status, status, _url}), do: status in [408, 429] or status in 500..599
  defp retryable?(_reason), do: false

  defp transport_kind(%Req.TransportError{reason: :timeout}), do: :timeout
  defp transport_kind(%Req.TransportError{reason: reason}) when reason in [:econnrefused, :nxdomain], do: :connection
  defp transport_kind(:timeout), do: :timeout
  defp transport_kind(reason) when reason in [:econnrefused, :nxdomain], do: :connection
  defp transport_kind(_reason), do: :other

  defp max_archive_bytes(opts), do: Keyword.get(opts, :max_archive_bytes, @default_max_archive_bytes)
  defp max_product_bytes(opts), do: Keyword.get(opts, :max_product_bytes, @default_max_product_bytes)
  defp cache_lock_timeout_ms(opts), do: Keyword.get(opts, :cache_lock_timeout_ms, @default_cache_lock_timeout_ms)

  defp validate_size_limits(opts) do
    with :ok <- validate_positive_byte_limit(max_archive_bytes(opts), :max_archive_bytes) do
      validate_positive_byte_limit(max_product_bytes(opts), :max_product_bytes)
    end
  end

  defp validate_positive_byte_limit(value, _option) when is_integer(value) and value > 0, do: :ok
  defp validate_positive_byte_limit(_value, option), do: {:error, {:invalid_option, option}}

  defp validate_cache_lock_timeout(opts) do
    case cache_lock_timeout_ms(opts) do
      value when is_integer(value) and value >= 0 -> :ok
      _ -> {:error, {:cache_write_failed, {:invalid_lock_timeout, :cache_lock_timeout_ms}}}
    end
  end

  defp sleep_backoff(opts, attempt) do
    backoff = Keyword.get(opts, :backoff_s, @default_backoff_s)
    Process.sleep(round(backoff * :math.pow(2, attempt - 1) * 1000))
  end

  defp seconds_to_ms(milliseconds) when is_integer(milliseconds) and milliseconds > 1000, do: milliseconds
  defp seconds_to_ms(seconds) when is_number(seconds), do: round(seconds * 1000)
  defp seconds_to_ms(_value), do: round(@default_timeout_s * 1000)

  defp truthy?(value), do: value in [true, "true", "1", 1]
  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp core({:ok, value}), do: {:ok, value}
  defp core({:error, reason}), do: {:error, reason}
  defp core(value), do: {:ok, value}
end
