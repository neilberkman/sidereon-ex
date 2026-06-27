defmodule Sidereon.GNSS.Data.Download do
  # Internal: network transfer for GNSS products over HTTP(S) via `Req`, with
  # bounded retries, sensible timeouts, and a strict host allow-list. Not part of
  # the public API; `Sidereon.GNSS.Data.fetch/2` is the entry point.
  #
  # This module is only reached when `offline: true` is not set and the product
  # is not already cached. It is given a URL built by `Sidereon.GNSS.Data.Catalog`
  # and, as defence in depth against SSRF, re-checks before contacting it that
  # the host is on `Catalog.allowed_hosts/0` AND that the URL scheme matches the
  # requested protocol. Cross-host HTTP redirects are refused rather than
  # followed. Downloads cap the compressed bytes buffered into memory
  # (`:max_compressed_bytes`), since the remote file is untrusted. All failures
  # are mapped to typed errors.
  @moduledoc false

  alias Sidereon.GNSS.Data.Catalog

  @default_timeout_ms 30_000
  @default_retries 3
  @default_backoff_ms 500

  # Generous cap on the compressed payload we will buffer. Real daily GNSS
  # products are a few MiB; this bounds memory against a hostile/oversized
  # response before the (output-side) decompression cap is even reached.
  @default_max_compressed_bytes 64 * 1024 * 1024

  # Download the bytes at `url` using `protocol` (`:https` or `:http`). Options:
  #   :timeout_ms (per-attempt, default 30_000), :retries (transient-error
  #   attempts, default 3), :backoff_ms (base backoff, doubled per attempt,
  #   default 500; 0 in tests), :max_compressed_bytes (buffered payload cap,
  #   default 64 MiB; over it yields {:error, {:download_size_exceeded, max, got}}).
  # Returns {:ok, compressed_bytes} or a typed error. 404/file-not-found is
  # permanent (not retried); transient network errors (incl. 408/429) are.
  @doc false
  @spec get(String.t(), atom(), keyword()) :: {:ok, binary()} | {:error, term()}
  def get(url, protocol, opts \\ [])

  def get(url, protocol, opts) when is_binary(url) and protocol in [:https, :http] do
    with :ok <- check_host(url, protocol) do
      retries = Keyword.get(opts, :retries, @default_retries)
      backoff = Keyword.get(opts, :backoff_ms, @default_backoff_ms)
      attempt(url, protocol, opts, retries, backoff)
    end
  end

  def get(_url, protocol, _opts), do: {:error, {:unsupported_product, {:protocol, protocol}}}

  @doc """
  Whether HTTP client downloads are enabled. `Req` is a required dependency; the
  app config hook is used by offline tests that need to prove fetch behavior
  without touching the network.
  """
  @spec req_available?() :: boolean()
  def req_available? do
    case Application.get_env(:sidereon, :gnss_data_req_available) do
      nil -> true
      override -> override
    end
  end

  # --- retry loop ----------------------------------------------------------

  defp attempt(url, protocol, opts, retries_left, backoff) do
    case do_get(url, protocol, opts) do
      {:ok, _bytes} = ok ->
        ok

      {:error, reason} = err ->
        if retries_left > 1 and transient?(reason) do
          if backoff > 0, do: Process.sleep(backoff)
          attempt(url, protocol, opts, retries_left - 1, backoff * 2)
        else
          err
        end
    end
  end

  # 404 / missing files are permanent; everything else network-related retries.
  defp transient?({:file_not_found, _}), do: false
  # 408 (Request Timeout) and 429 (Too Many Requests) are the canonical
  # retry-me responses; the rest of 4xx is a permanent client error.
  defp transient?({:http_status, status}) when status in [408, 429], do: true
  defp transient?({:http_status, status}) when status in 400..499, do: false
  defp transient?({:http_status, _}), do: true
  # An oversized payload will be oversized again; do not retry it.
  defp transient?({:download_size_exceeded, _, _}), do: false
  defp transient?({:network, _}), do: true
  defp transient?(_), do: false

  # --- HTTP client ---------------------------------------------------------

  defp do_get(url, protocol, opts) when protocol in [:https, :http] do
    if req_available?() do
      timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
      req_get(url, timeout, max_compressed_bytes(opts))
    else
      {:error, :req_not_available}
    end
  end

  defp max_compressed_bytes(opts),
    do: Keyword.get(opts, :max_compressed_bytes, @default_max_compressed_bytes)

  # Redirects are disabled (`redirect: false`): a 3xx surfaces as a response we
  # reject, so a redirect can never carry the fetch to an off-allow-list host.
  # The body is streamed via `:into` and the transfer is halted the moment it
  # would exceed `max_bytes`, so an oversized response is never fully buffered.
  defp req_get(url, timeout, max_bytes) do
    collector = fn {:data, data}, {req, resp} ->
      acc = resp.private[:sidereon_body] || []
      total = (resp.private[:sidereon_total] || 0) + byte_size(data)

      if total > max_bytes do
        resp = Req.Response.put_private(resp, :sidereon_over_limit, true)
        {:halt, {req, resp}}
      else
        resp =
          resp
          |> Req.Response.put_private(:sidereon_body, [acc, data])
          |> Req.Response.put_private(:sidereon_total, total)

        {:cont, {req, resp}}
      end
    end

    case Req.get(url,
           decode_body: false,
           redirect: false,
           into: collector,
           receive_timeout: timeout,
           connect_options: [timeout: timeout]
         ) do
      {:ok, %{status: 200} = resp} ->
        if resp.private[:sidereon_over_limit] do
          {:error, {:download_size_exceeded, max_bytes, :over_limit}}
        else
          {:ok, IO.iodata_to_binary(resp.private[:sidereon_body] || [])}
        end

      {:ok, %{status: 404}} ->
        {:error, {:file_not_found, url}}

      {:ok, %{status: status}} when status in 300..399 ->
        {:error, {:redirect_not_allowed, status}}

      {:ok, %{status: status}} ->
        {:error, {:http_status, status}}

      {:error, %{__exception__: true} = e} ->
        {:error, {:network, Exception.message(e)}}

      {:error, reason} ->
        {:error, {:network, reason}}
    end
  rescue
    e -> {:error, {:network, Exception.message(e)}}
  end

  # --- SSRF guard ----------------------------------------------------------

  defp check_host(url, protocol) do
    uri = URI.parse(url)

    cond do
      not (is_binary(uri.host) and MapSet.member?(Catalog.allowed_hosts(), uri.host)) ->
        {:error, {:unsupported_product, {:host_not_allowed, uri.host}}}

      uri.scheme != scheme_for(protocol) ->
        {:error, {:unsupported_product, {:scheme_mismatch, uri.scheme, protocol}}}

      true ->
        :ok
    end
  end

  defp scheme_for(:https), do: "https"
  defp scheme_for(:http), do: "http"
end
