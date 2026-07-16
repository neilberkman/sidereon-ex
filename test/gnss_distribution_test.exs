defmodule Sidereon.GNSS.DistributionTest do
  use ExUnit.Case, async: false

  alias Sidereon.GNSS.Data
  alias Sidereon.GNSS.Distribution
  alias Sidereon.GNSS.Distribution.EarthdataAuth
  alias Sidereon.GNSS.Distribution.ProductIdentity

  @date ~D[2026-07-12]
  @filename "COD0MGXFIN_20261930000_01D_05M_ORB.SP3"
  @cddis_url "https://cddis.nasa.gov/archive/gnss/products/2427/#{@filename}.gz"

  setup do
    root = Path.join(System.tmp_dir!(), "sidereon-distribution-test-#{System.unique_integer([:positive])}")
    File.rm_rf!(root)
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "identity and CDDIS locations preserve the exact public product" do
    assert is_binary(Data.default_cache_dir())

    {:ok, product} = Data.mgex_sp3(:cod, @date)
    assert {:ok, identity} = Data.identity(product)

    assert %ProductIdentity{
             family: "sp3",
             analysis_center: "cod",
             publisher: "COD",
             solution_class: "final",
             campaign: "MGX",
             date: @date,
             issue: "0000",
             span: "01D",
             sample: "05M",
             official_filename: @filename,
             format: "SP3"
           } = identity

    assert {:ok, @cddis_url} = Data.cddis_url(identity)

    {:ok, ionex} = Data.mgex_ionex(:esa, ~D[2020-06-24])
    assert {:ok, ionex_identity} = Data.identity(ionex)

    assert {:ok,
            "https://cddis.nasa.gov/archive/gnss/products/ionex/2020/176/" <>
              "ESA0OPSFIN_20201760000_01D_02H_GIM.INX.gz"} = Data.cddis_url(ionex_identity)
  end

  test "CDDIS gzip acquisition records verified secret-free provenance", %{root: root} do
    request = request!([Distribution.nasa_cddis()])
    body = sp3_body(@date)

    client = fn url, opts ->
      assert url == @cddis_url
      refute Keyword.has_key?(opts, :earthdata_auth)
      {:ok, 200, [{"content-type", "application/gzip"}, {"etag", "public-etag"}], :zlib.gzip(body)}
    end

    assert {:ok, result} = Data.acquire(request, cache_dir: root, http_client: client)
    assert File.read!(result.path) == body
    assert result.provenance.distribution_source == :nasa_cddis
    assert result.provenance.requested_identity == request.identity
    assert result.provenance.resolved_identity.format_version == "SP3-c"
    assert result.provenance.original_url == @cddis_url
    assert result.provenance.final_url == @cddis_url
    assert result.provenance.archive_compression == :gzip
    assert result.provenance.sha256 == sha256(body)
    assert result.provenance.archive_sha256 == sha256(:zlib.gzip(body))
    assert result.provenance.etag == "public-etag"
  end

  test "Earthdata redirects retain auth and cookies only on approved hosts and redact secrets", %{root: root} do
    token = "fake-bearer-for-redaction-test"
    query_secret = "fake-query-for-redaction-test"
    auth = EarthdataAuth.bearer(token)
    parent = self()
    body = :zlib.gzip(sp3_body(@date))

    client = fn url, opts ->
      headers = Keyword.fetch!(opts, :headers)
      send(parent, {:request, url, headers, opts})

      cond do
        url == @cddis_url ->
          {:ok, 302,
           [
             {"location", "https://urs.earthdata.nasa.gov/oauth/authorize?token=#{query_secret}"},
             {"set-cookie", "urs_session=one; Secure; HttpOnly"}
           ], ""}

        String.starts_with?(url, "https://urs.earthdata.nasa.gov/") ->
          {:ok, 302,
           [
             {"location", @cddis_url <> "?ticket=#{query_secret}"},
             {"set-cookie", "cddis_session=two; Secure; HttpOnly"}
           ], ""}

        String.starts_with?(url, @cddis_url <> "?") ->
          {:ok, 200, [{"content-type", "application/gzip"}], body}
      end
    end

    assert {:ok, result} =
             Data.acquire(request!([Distribution.nasa_cddis()]),
               cache_dir: root,
               earthdata_auth: auth,
               http_client: client
             )

    assert inspect(auth) =~ "EarthdataAuth"
    refute inspect(auth) =~ token
    assert result.provenance.original_url == @cddis_url
    assert result.provenance.final_url == @cddis_url

    assert_received {:request, @cddis_url, first_headers, first_opts}
    assert header(first_headers, "authorization") == "Bearer " <> token
    assert header(first_headers, "cookie") == nil
    refute Keyword.has_key?(first_opts, :earthdata_auth)

    assert_received {:request, "https://urs.earthdata.nasa.gov/" <> _, urs_headers, urs_opts}
    assert header(urs_headers, "authorization") == "Bearer " <> token
    assert header(urs_headers, "cookie") == nil
    refute Keyword.has_key?(urs_opts, :earthdata_auth)

    assert_received {:request, @cddis_url <> "?" <> _, final_headers, final_opts}
    assert header(final_headers, "authorization") == "Bearer " <> token
    assert header(final_headers, "cookie") == "urs_session=one"
    refute Keyword.has_key?(final_opts, :earthdata_auth)

    sidecar = File.read!(result.path <> ".provenance.json")
    refute sidecar =~ token
    refute sidecar =~ query_secret
    refute inspect(result) =~ token
    refute inspect(result) =~ query_secret
  end

  test "CDDIS status failures remain distinct and sanitized", %{root: root} do
    cases = [
      {401, nil, :authentication_required},
      {401, EarthdataAuth.bearer("invalid-secret"), :authentication_failed},
      {403, nil, :authorization_denied},
      {404, nil, :product_not_published},
      {410, nil, :retired_endpoint}
    ]

    for {status, auth, expected} <- cases do
      client = fn _url, _opts -> {:ok, status, [], ""} end

      opts =
        [cache_dir: Path.join(root, Integer.to_string(status) <> to_string(expected)), http_client: client, retries: 1]
        |> maybe_auth(auth)

      assert {:error, {^expected, ^status, @cddis_url}} =
               Data.acquire(request!([Distribution.nasa_cddis()]), opts)
    end
  end

  test "timeouts retain the sanitized public URL", %{root: root} do
    client = fn _url, _opts -> {:error, :timeout} end

    assert {:error, {:transport, :timeout, @cddis_url}} =
             Data.acquire(request!([Distribution.nasa_cddis()]),
               cache_dir: root,
               http_client: client,
               retries: 1
             )
  end

  test "caller-built inconsistent identities are rejected before cache or transport", %{root: root} do
    request = request!([Distribution.nasa_cddis()])
    invalid = %{request.identity | official_filename: "../../../escape.SP3"}
    parent = self()
    client = fn _url, _opts -> send(parent, :network_called) end

    assert {:error, {:malformed_url, "invalid official filename"}} =
             Data.acquire(%{request | identity: invalid}, cache_dir: root, http_client: client)

    refute_received :network_called
    assert File.ls!(root) == []

    inconsistent = %{request.identity | publisher: "ESA"}
    assert {:error, {:product_validation_failed, :requested_identity}} = Data.cddis_url(inconsistent)
  end

  test "caller-built requests validate source fields before acquisition", %{root: root} do
    request = request!([Distribution.nasa_cddis()])
    parent = self()
    client = fn _url, _opts -> send(parent, :network_called) end

    assert {:error, {:unsupported_distribution, :none, "source list is empty"}} =
             Data.acquire(%{request | sources: []}, cache_dir: root, http_client: client)

    invalid_source = %{Distribution.nasa_cddis() | content: "conflicting bytes"}

    assert {:error, {:unsupported_distribution, :nasa_cddis, "source input is invalid"}} =
             Data.acquire(%{request | sources: [invalid_source]}, cache_dir: root, http_client: client)

    refute_received :network_called
  end

  test "HTTP error documents and length mismatches never enter the cache", %{root: root} do
    cases = [
      {
        fn _url, _opts -> {:ok, 200, [{"content-type", "text/html"}], "<html>login</html>"} end,
        :invalid_content_type
      },
      {
        fn _url, _opts -> {:ok, 200, [{"content-length", "500"}], "short"} end,
        :content_length_mismatch
      },
      {fn _url, _opts -> {:ok, 200, [{"content-type", "application/gzip"}], <<31, 139, 1, 2>>} end,
       :decompression_failed}
    ]

    for {client, expected} <- cases do
      case Data.acquire(request!([Distribution.nasa_cddis()]),
             cache_dir: Path.join(root, to_string(expected)),
             http_client: client,
             retries: 1
           ) do
        {:error, {^expected, _detail}} -> :ok
        {:error, {^expected, _detail, _url}} -> :ok
        {:error, {^expected, _expected_length, _actual_length, _url}} -> :ok
        other -> flunk("unexpected acquisition result: #{inspect(other)}")
      end
    end

    refute Enum.any?(regular_files(root), &String.ends_with?(&1, @filename))
    refute Enum.any?(regular_files(root), &String.starts_with?(Path.basename(&1), ".sidereon-"))
  end

  test "archive byte limits are distinct from decompression errors", %{root: root} do
    client = fn _url, _opts -> {:ok, 200, [], "oversized"} end

    assert {:error, {:download_size_exceeded, 3}} =
             Data.acquire(request!([Distribution.nasa_cddis()]),
               cache_dir: root,
               http_client: client,
               max_archive_bytes: 3,
               retries: 1
             )
  end

  test "decompression is bounded before product parsing", %{root: root} do
    client = fn _url, _opts -> {:ok, 200, [], :zlib.gzip(sp3_body(@date))} end

    assert {:error, {:decompression_failed, :size_limit}} =
             Data.acquire(request!([Distribution.nasa_cddis()]),
               cache_dir: root,
               http_client: client,
               max_product_bytes: 32,
               retries: 1
             )

    assert File.ls!(root) == []
  end

  test "a requested public format version must match parsed content", %{root: root} do
    request = request!([Distribution.in_memory(sp3_body(@date))])
    identity = %{request.identity | format_version: "SP3-d"}

    assert {:error, {:product_validation_failed, :format_version}} =
             Data.acquire(%{request | identity: identity}, cache_dir: root)
  end

  test "local, memory, and CDDIS sources resolve to the same identity and bytes", %{root: root} do
    content = sp3_body(@date)
    archive = :zlib.gzip(content)
    local_path = Path.join(root, "input.sp3.gz")
    File.write!(local_path, archive)

    {:ok, memory} =
      Data.acquire(request!([Distribution.in_memory(content)]), cache_dir: Path.join(root, "memory"))

    {:ok, local} =
      Data.acquire(request!([Distribution.local_file(local_path)]), cache_dir: Path.join(root, "local"))

    client = fn _url, _opts -> {:ok, 200, [], archive} end

    {:ok, remote} =
      Data.acquire(request!([Distribution.nasa_cddis()]),
        cache_dir: Path.join(root, "remote"),
        http_client: client
      )

    assert memory.provenance.sha256 == local.provenance.sha256
    assert local.provenance.sha256 == remote.provenance.sha256
    assert memory.provenance.resolved_identity == local.provenance.resolved_identity
    assert local.provenance.resolved_identity == remote.provenance.resolved_identity
  end

  test "IONEX caller bytes are parsed and matched to exact date and cadence", %{root: root} do
    fixture = File.read!(Path.join(__DIR__, "fixtures/synthetic_2map_7x7.20i"))
    {:ok, product} = Data.mgex_ionex(:esa, ~D[2020-06-24])
    {:ok, request} = Data.request(product, [Distribution.in_memory(fixture)])

    assert {:ok, result} = Data.acquire(request, cache_dir: root)
    assert result.provenance.resolved_identity.format_version == "IONEX-1.1"
    assert result.provenance.resolved_identity.date == ~D[2020-06-24]
    assert result.provenance.resolved_identity.sample == "02H"
  end

  test "verified cache hits avoid transport and corruption is typed offline", %{root: root} do
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    body = :zlib.gzip(sp3_body(@date))

    client = fn _url, _opts ->
      Agent.update(counter, &(&1 + 1))
      {:ok, 200, [], body}
    end

    request = request!([Distribution.nasa_cddis()])
    assert {:ok, first} = Data.acquire(request, cache_dir: root, http_client: client)
    assert {:ok, second} = Data.acquire(request, cache_dir: root, offline: true, http_client: client)
    assert second.provenance.cache_hit
    assert Agent.get(counter, & &1) == 1

    File.write!(first.path, "corrupt")

    assert {:error, {:cache_read_failed, @filename}} =
             Data.acquire(request, cache_dir: root, offline: true, http_client: client)

    assert Agent.get(counter, & &1) == 1
  end

  test "concurrent first acquisition performs one transport request", %{root: root} do
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    body = :zlib.gzip(sp3_body(@date))

    client = fn _url, _opts ->
      Agent.update(counter, &(&1 + 1))
      Process.sleep(25)
      {:ok, 200, [], body}
    end

    request = request!([Distribution.nasa_cddis()])

    results =
      1..8
      |> Task.async_stream(
        fn _ -> Data.acquire(request, cache_dir: root, http_client: client) end,
        max_concurrency: 8,
        ordered: false,
        timeout: 5_000
      )
      |> Enum.to_list()

    assert Enum.all?(results, &match?({:ok, {:ok, _result}}, &1))
    assert Agent.get(counter, & &1) == 1
  end

  test "ordered fallback preserves identity and records the failed source", %{root: root} do
    body = sp3_body(@date)

    client = fn url, _opts ->
      if String.contains?(url, "cddis.nasa.gov"), do: {:ok, 404, [], ""}, else: {:ok, 200, [], body}
    end

    request = request!([Distribution.nasa_cddis(), Distribution.direct()])
    assert {:ok, result} = Data.acquire(request, cache_dir: root, http_client: client, retries: 1)
    assert result.provenance.distribution_source == :direct
    assert result.provenance.requested_identity == request.identity
    assert result.provenance.resolved_identity.official_filename == request.identity.official_filename

    assert [failure] = result.provenance.attempts
    assert failure.source == :nasa_cddis
    assert failure.error_type == :product_not_published
    assert failure.status == 404
  end

  test "all allowed sources failing returns a structured aggregate", %{root: root} do
    client = fn url, _opts ->
      if String.contains?(url, "cddis.nasa.gov"), do: {:ok, 404, [], ""}, else: {:ok, 410, [], ""}
    end

    request = request!([Distribution.nasa_cddis(), Distribution.direct()])

    assert {:error, {:all_distributors_failed, failures}} =
             Data.acquire(request, cache_dir: root, http_client: client, retries: 1)

    assert Enum.map(failures, &{&1.source, &1.error_type, &1.status}) == [
             {:nasa_cddis, :product_not_published, 404},
             {:direct, :retired_endpoint, 410}
           ]
  end

  test "different exact identities never share cache entries", %{root: root} do
    {:ok, first_product} = Data.mgex_sp3(:cod, @date)
    {:ok, second_product} = Data.mgex_sp3(:cod, ~D[2026-07-13])
    {:ok, first_request} = Data.request(first_product, [Distribution.in_memory(sp3_body(@date))])
    {:ok, second_request} = Data.request(second_product, [Distribution.in_memory(sp3_body(~D[2026-07-13]))])

    assert {:ok, first} = Data.acquire(first_request, cache_dir: root)
    assert {:ok, second} = Data.acquire(second_request, cache_dir: root)
    refute first.path == second.path
    refute first.provenance.sha256 == second.provenance.sha256
  end

  defp request!(sources) do
    {:ok, product} = Data.mgex_sp3(:cod, @date)
    {:ok, request} = Data.request(product, sources)
    request
  end

  defp maybe_auth(opts, nil), do: opts
  defp maybe_auth(opts, auth), do: Keyword.put(opts, :earthdata_auth, auth)

  defp header(headers, name) do
    Enum.find_value(headers, fn {key, value} ->
      if String.downcase(to_string(key)) == name, do: IO.iodata_to_binary(value)
    end)
  end

  defp regular_files(root) do
    root
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
  end

  defp sp3_body(date) do
    year = date.year
    month = date.month
    day = date.day

    record =
      "PG01" <>
        (:io_lib.format(~c"~14.6f", [15_000.0]) |> IO.iodata_to_binary()) <>
        " -20000.000000   5000.000000 999999.999999"

    Enum.join(
      [
        :io_lib.format(~c"#cP~4..0B ~2.. B ~2.. B  0  0  0.00000000       1 ORBIT IGS14 FIT  TST", [
          year,
          month,
          day
        ])
        |> IO.iodata_to_binary(),
        "## 2427 000000.00000000   300.00000000 61233 0.0000000000000",
        "+    1   G01  0  0  0  0  0  0  0  0  0  0  0  0  0  0  0  0",
        "++         0  0  0  0  0  0  0  0  0  0  0  0  0  0  0  0  0",
        "%c G  cc GPS ccc cccc cccc cccc cccc ccccc ccccc ccccc ccccc",
        "%c cc cc ccc ccc cccc cccc cccc cccc ccccc ccccc ccccc ccccc",
        "%f  1.2500000  1.025000000  0.00000000000  0.000000000000000",
        "%f  0.0000000  0.000000000  0.00000000000  0.000000000000000",
        "%i    0    0    0    0      0      0      0      0         0",
        "%i    0    0    0    0      0      0      0      0         0",
        "/* TEST SP3-c FIXTURE",
        :io_lib.format(~c"*  ~4..0B ~2.. B ~2.. B  0  0  0.00000000", [year, month, day])
        |> IO.iodata_to_binary(),
        record,
        "EOF",
        ""
      ],
      "\n"
    )
  end

  defp sha256(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
end
