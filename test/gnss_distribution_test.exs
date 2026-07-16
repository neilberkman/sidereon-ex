defmodule Sidereon.GNSS.DistributionTest do
  use ExUnit.Case, async: false

  alias Sidereon.GNSS.Data
  alias Sidereon.GNSS.Distribution
  alias Sidereon.GNSS.Distribution.EarthdataAuth
  alias Sidereon.GNSS.Distribution.ProductIdentity
  alias Sidereon.GNSS.ExactCache

  @date ~D[2026-07-12]
  @filename "COD0MGXFIN_20261930000_01D_05M_ORB.SP3"
  @cddis_url "https://cddis.nasa.gov/archive/gnss/products/2427/#{@filename}.gz"
  @ionex_fixture Path.join(__DIR__, "fixtures/synthetic_2map_7x7.20i")

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

    assert Distribution.identity_key(identity) == "cod-final-a91258c21fa4860c34ce"

    assert {:ok, @cddis_url} = Data.cddis_url(identity)

    {:ok, ionex} = Data.mgex_ionex(:esa, ~D[2020-06-24])
    assert {:ok, ionex_identity} = Data.identity(ionex)

    assert {:ok,
            "https://cddis.nasa.gov/archive/gnss/products/ionex/2020/176/" <>
              "ESA0OPSFIN_20201760000_01D_02H_GIM.INX.gz"} = Data.cddis_url(ionex_identity)
  end

  test "exact product sets are order independent and fail closed" do
    {:ok, first_product} = Data.mgex_sp3(:cod, ~D[2026-07-12])
    {:ok, second_product} = Data.mgex_sp3(:cod, ~D[2026-07-13])
    {:ok, first} = Data.identity(first_product)
    {:ok, second} = Data.identity(second_product)

    assert :ok = Data.validate_exact_product_set([first, second], [second, first])

    assert {:error, {:exact_product_set, message}} =
             Data.validate_exact_product_set([first, second], [first])

    assert message =~ "missing:"

    assert {:error, {:exact_product_set, message}} =
             Data.validate_exact_product_set([first, first], [first, second, second])

    assert message =~ "duplicate expected:"
  end

  test "exact product sets retain prediction tier metadata" do
    {:ok, one_day_product} = Data.predicted_ionex(:cod_prd1, ~D[2026-07-15])
    {:ok, two_day_product} = Data.predicted_ionex(:cod_prd2, ~D[2026-07-14])
    {:ok, one_day} = Data.identity(one_day_product)
    {:ok, two_day} = Data.identity(two_day_product)
    assert one_day.official_filename == two_day.official_filename

    assert {:error, {:exact_product_set, message}} =
             Data.validate_exact_product_set([one_day], [two_day])

    assert message =~ "unexpected:"
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

  test "predicted IONEX direct paths preserve tier, year, and semantic identity", %{root: root} do
    {:ok, p1} = Data.predicted_ionex(:cod_prd1, ~D[2026-07-15])
    {:ok, p2} = Data.predicted_ionex(:cod_prd2, ~D[2026-07-15])

    assert {:ok,
            "https://www.aiub.unibe.ch/download/CODE/IONO/P1/2026/" <>
              "COD0OPSPRD_20261960000_01D_01H_GIM.INX.gz"} = Data.archive_url(p1)

    assert {:ok,
            "https://www.aiub.unibe.ch/download/CODE/IONO/P2/2026/" <>
              "COD0OPSPRD_20261970000_01D_01H_GIM.INX.gz"} = Data.archive_url(p2)

    {:ok, request} = Data.request(p1, [Distribution.in_memory(ionex_body(p1.date))])
    assert {:ok, result} = Data.acquire(request, cache_dir: root)
    assert result.provenance.requested_identity == request.identity
    assert result.provenance.resolved_identity.date == p1.date

    {:ok, boundary} = Data.predicted_ionex(:cod_prd2, ~D[2026-12-31])
    assert boundary.date == ~D[2027-01-01]

    assert {:ok,
            "https://www.aiub.unibe.ch/download/CODE/IONO/P2/2027/" <>
              "COD0OPSPRD_20270010000_01D_01H_GIM.INX.gz"} = Data.archive_url(boundary)
  end

  test "wrong-date IONEX bytes fail with a typed validation error", %{root: root} do
    {:ok, product} = Data.predicted_ionex(:cod_prd2, ~D[2026-07-15])
    {:ok, request} = Data.request(product, [Distribution.in_memory(ionex_body(~D[2026-07-15]))])

    assert {:error, {:product_validation_failed, :ionex_identity_metadata}} =
             Data.acquire(request, cache_dir: root)
  end

  test "P1 and P2 with the same filename cannot share a cache hit", %{root: root} do
    {:ok, p1} = Data.predicted_ionex(:cod_prd1, ~D[2026-07-16])
    {:ok, p2} = Data.predicted_ionex(:cod_prd2, ~D[2026-07-15])
    {:ok, p1_identity} = Data.identity(p1)
    {:ok, p2_identity} = Data.identity(p2)
    assert p1_identity.official_filename == p2_identity.official_filename

    {:ok, seed} = Data.request(p1, [Distribution.in_memory(ionex_body(p1.date))])
    assert {:ok, seeded} = Data.acquire(seed, cache_dir: root)

    {:ok, exact_p2} = Data.request(p2, [Distribution.direct()])
    assert {:error, :offline_cache_miss} = Data.acquire(exact_p2, cache_dir: root, offline: true)
    refute String.contains?(seeded.path, "cod_prd2")
  end

  test "exact predicted IONEX 404 is typed and never looks back", %{root: root} do
    {:ok, product} = Data.predicted_ionex(:cod_prd1, ~D[2026-07-15])
    {:ok, request} = Data.request(product, [Distribution.direct()])
    parent = self()

    client = fn url, _opts ->
      send(parent, {:requested, url})
      {:ok, 404, [], ""}
    end

    assert {:error, {:product_not_published, 404, url}} =
             Data.acquire(request, cache_dir: root, http_client: client, retries: 1)

    assert_receive {:requested, ^url}
    refute_receive {:requested, _other}
  end

  test "legacy fetch_ionex uses exact semantic validation", %{root: root} do
    wrong = ionex_body(~D[2026-07-16]) |> :zlib.gzip()

    client = fn _url, _opts -> {:ok, 200, [{"content-type", "application/gzip"}], wrong} end

    assert {:error, {:product_validation_failed, :ionex_identity_metadata}} =
             Data.fetch_ionex(:cod_prd1, ~D[2026-07-15],
               cache_dir: root,
               http_client: client,
               lookback: 2
             )
  end

  test "concurrent different predicted products leave immutable snapshots", %{root: root} do
    products = [
      {:cod_prd1, ~D[2026-07-15]},
      {:cod_prd2, ~D[2026-07-15]}
    ]

    requests =
      Enum.map(products, fn {center, target} ->
        {:ok, product} = Data.predicted_ionex(center, target)
        bytes = ionex_body(product.date)
        {:ok, request} = Data.request(product, [Distribution.in_memory(bytes)])
        {request, bytes}
      end)

    results =
      requests
      |> Task.async_stream(fn {request, _bytes} -> Data.acquire(request, cache_dir: root) end,
        ordered: false,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, {:ok, result}} -> result end)

    assert results |> Enum.map(& &1.path) |> Enum.uniq() |> length() == 2
    snapshots = Map.new(results, &{&1.path, File.read!(&1.path)})
    assert Enum.sort(Map.values(snapshots)) == Enum.sort(Enum.map(requests, &elem(&1, 1)))
    assert Map.new(Map.keys(snapshots), &{&1, File.read!(&1)}) == snapshots
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
    refute Enum.any?(regular_files(root), &String.starts_with?(Path.basename(&1), ".current.json."))
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

    refute Enum.any?(regular_files(root), &String.ends_with?(&1, "current.json"))
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

  test "independent OS processes racing one exact source acquire only once", %{root: root} do
    outcomes = run_child_race(root, [:local_file, :local_file])
    assert Enum.sort(Enum.map(outcomes, &elem(&1, 0))) == [false, true]
    assert outcomes |> Enum.map(&elem(&1, 2)) |> Enum.uniq() |> length() == 1
    assert outcomes |> Enum.map(&elem(&1, 3)) |> Enum.uniq() |> length() == 1
  end

  test "independent OS processes keep identical bytes from different sources isolated", %{root: root} do
    outcomes = run_child_race(root, [:local_file, :in_memory])
    refute Enum.any?(outcomes, &elem(&1, 0))
    assert outcomes |> MapSet.new(&elem(&1, 1)) == MapSet.new([:local_file, :in_memory])
    assert outcomes |> Enum.map(&elem(&1, 2)) |> Enum.uniq() |> length() == 2
    assert outcomes |> Enum.map(&elem(&1, 3)) |> Enum.uniq() |> length() == 1
  end

  test "process death at each publication boundary accepts only none or a complete entry", %{root: root} do
    source = Path.join(root, "crash-source.SP3")
    File.write!(source, sp3_body(@date))

    steps = [
      after_payload: false,
      after_archive: false,
      after_metadata: false,
      after_entry_sync: false,
      after_marker_write: false,
      after_marker_rename: true,
      after_commit_sync: true
    ]

    for {step, committed?} <- steps do
      cache = Path.join(root, Atom.to_string(step))

      env = [
        {"SIDEREON_CACHE", cache},
        {"SIDEREON_SOURCE", source},
        {"SIDEREON_TEST_EXACT_CACHE_FAILPOINT", Atom.to_string(step)}
      ]

      {_output, 86} = System.cmd(System.find_executable("elixir"), child_args(crash_child_code()), env: env)

      markers = Path.wildcard(Path.join(cache, "**/current.json"), match_dot: true)
      assert markers != [] == committed?

      {:ok, product} = Data.mgex_sp3(:cod, @date)
      {:ok, request} = Data.request(product, [Distribution.in_memory(File.read!(source))])
      assert {:ok, result} = Data.acquire(request, cache_dir: cache)
      assert result.provenance.cache_hit == committed?
      assert File.read!(result.path) == File.read!(source)
      assert result.provenance.sha256 == sha256(File.read!(result.path))
    end
  end

  test "an existing entry remains current until one commit-record rename", %{root: root} do
    content = sp3_body(@date)
    {:ok, product} = Data.mgex_sp3(:cod, @date)
    {:ok, request} = Data.request(product, [Distribution.in_memory(content)])
    {:ok, first} = Data.acquire(request, cache_dir: root)

    stable =
      first.path
      |> Path.dirname()
      |> Path.dirname()
      |> Path.dirname()
      |> Path.dirname()
      |> Path.join(@filename)

    {:ok, old_files} = ExactCache.committed_files(stable, request.identity, :in_memory)
    assert old_files.provenance_bytes == File.read!(old_files.provenance)

    staged =
      Path.join([
        Path.dirname(stable),
        ExactCache.control_directory(),
        "entries",
        String.duplicate("e", 32)
      ])

    File.mkdir_p!(staged)
    File.cp!(old_files.product, Path.join(staged, Path.basename(old_files.product)))
    File.cp!(old_files.archive, Path.join(staged, Path.basename(old_files.archive)))
    File.cp!(old_files.provenance, Path.join(staged, Path.basename(old_files.provenance)))

    assert {:ok, during_files} = ExactCache.committed_files(stable, request.identity, :in_memory)
    assert during_files.entry_id == old_files.entry_id

    assert {:ok, published} =
             ExactCache.with_lock(stable, request.identity, :in_memory, 1_000, fn cache ->
               ExactCache.publish(
                 cache,
                 old_files.product_bytes,
                 old_files.archive_bytes,
                 old_files.provenance_bytes
               )
             end)

    assert published.product_bytes == old_files.product_bytes
    assert published.archive_bytes == old_files.archive_bytes
    assert published.provenance_bytes == old_files.provenance_bytes

    assert {:ok, new_files} = ExactCache.committed_files(stable, request.identity, :in_memory)
    refute new_files.entry_id == old_files.entry_id
    assert new_files.product == published.product
    assert {:ok, cached} = Data.acquire(request, cache_dir: root)
    assert cached.provenance.cache_hit
    assert File.read!(cached.path) == content
  end

  test "a failed legacy migration is terminal before transport", %{root: root} do
    body = :zlib.gzip(sp3_body(@date))
    seed_root = Path.join(root, "legacy-seed")
    target_root = Path.join(root, "legacy-target")
    client = fn _url, _opts -> {:ok, 200, [], body} end
    request = request!([Distribution.nasa_cddis()])
    assert {:ok, seeded} = Data.acquire(request, cache_dir: seed_root, http_client: client)

    seed_stable =
      seeded.path
      |> Path.dirname()
      |> Path.dirname()
      |> Path.dirname()
      |> Path.dirname()
      |> Path.join(@filename)

    stable = Path.join(target_root, Path.relative_to(seed_stable, seed_root))
    File.mkdir_p!(Path.dirname(stable))
    File.cp!(seeded.path, stable)
    File.cp!(seeded.path <> ".archive", stable <> ".archive")
    File.cp!(seeded.path <> ".provenance.json", stable <> ".provenance.json")
    control = Path.join(Path.dirname(stable), ExactCache.control_directory())
    File.mkdir_p!(control)
    File.write!(Path.join(control, "entries"), "not a directory")
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    should_not_run = fn _url, _opts ->
      Agent.update(counter, &(&1 + 1))
      {:ok, 200, [], body}
    end

    assert {:error, {:cache_write_failed, _detail}} =
             Data.acquire(request, cache_dir: target_root, http_client: should_not_run)

    assert Agent.get(counter, & &1) == 0
  end

  test "abandoned cleanup cannot pass a live OS writer lock", %{root: root} do
    source = Path.join(root, "lock-source.SP3")
    File.write!(source, sp3_body(@date))
    {:ok, product} = Data.mgex_sp3(:cod, @date)
    {:ok, seeded_request} = Data.request(product, [Distribution.in_memory(File.read!(source))])
    {:ok, seeded} = Data.acquire(seeded_request, cache_dir: root)

    stable =
      seeded.path
      |> Path.dirname()
      |> Path.dirname()
      |> Path.dirname()
      |> Path.dirname()
      |> Path.join(@filename)

    ready = Path.join(root, "lock-ready")
    release = Path.join(root, "lock-release")

    orphan =
      Path.join([
        Path.dirname(stable),
        ExactCache.control_directory(),
        "entries",
        String.duplicate("f", 32)
      ])

    env = [{"SIDEREON_STABLE", stable}, {"SIDEREON_READY", ready}, {"SIDEREON_RELEASE", release}]

    holder = Task.async(fn -> System.cmd(System.find_executable("elixir"), child_args(lock_child_code()), env: env) end)
    wait_for_paths!([ready])
    assert File.dir?(orphan)

    assert {:error, {:cache_write_failed, {:lock_timeout, _name}}} =
             ExactCache.with_lock(stable, seeded_request.identity, :in_memory, 25, fn cache ->
               ExactCache.cleanup_abandoned(cache)
             end)

    assert File.dir?(orphan)

    {:ok, two_sources} =
      Data.request(product, [
        Distribution.in_memory(File.read!(source)),
        Distribution.local_file(source, compression: :none)
      ])

    assert {:error, {:cache_write_failed, {:lock_timeout, _name}}} =
             Data.acquire(two_sources, cache_dir: root, cache_lock_timeout_ms: 25)

    File.write!(release, "release")
    assert {_output, 0} = Task.await(holder, 10_000)

    assert :ok =
             ExactCache.with_lock(
               stable,
               seeded_request.identity,
               :in_memory,
               1_000,
               fn cache -> ExactCache.cleanup_abandoned(cache) end
             )

    refute File.exists?(orphan)
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

  defp run_child_race(root, source_kinds) do
    source = Path.join(root, "process-source.SP3")
    cache = Path.join(root, "process-cache")
    start = Path.join(root, "process-start")
    File.write!(source, sp3_body(@date))

    tasks =
      source_kinds
      |> Enum.with_index()
      |> Enum.map(fn {kind, index} ->
        ready = Path.join(root, "process-ready-#{index}")

        env = [
          {"SIDEREON_CACHE", cache},
          {"SIDEREON_SOURCE", source},
          {"SIDEREON_SOURCE_KIND", Atom.to_string(kind)},
          {"SIDEREON_READY", ready},
          {"SIDEREON_START", start}
        ]

        task =
          Task.async(fn ->
            System.cmd(System.find_executable("elixir"), child_args(acquire_child_code()), env: env)
          end)

        {task, ready}
      end)

    wait_for_paths!(Enum.map(tasks, &elem(&1, 1)))
    File.write!(start, "start")

    Enum.map(tasks, fn {task, _ready} ->
      assert {output, 0} = Task.await(task, 20_000)
      encoded = output |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "RESULT "))
      assert is_binary(encoded), output
      encoded |> String.replace_prefix("RESULT ", "") |> Base.decode64!() |> :erlang.binary_to_term([:safe])
    end)
  end

  defp child_args(code) do
    code_paths =
      :code.get_path()
      |> Enum.map(&(&1 |> List.to_string() |> Path.expand()))
      |> Enum.flat_map(&["-pa", &1])

    code_paths ++ ["-e", code]
  end

  defp acquire_child_code do
    """
    Application.ensure_all_started(:sidereon)
    alias Sidereon.GNSS.Data
    alias Sidereon.GNSS.Distribution
    content = File.read!(System.fetch_env!("SIDEREON_SOURCE"))
    source = case System.fetch_env!("SIDEREON_SOURCE_KIND") do
      "local_file" -> Distribution.local_file(System.fetch_env!("SIDEREON_SOURCE"), compression: :none)
      "in_memory" -> Distribution.in_memory(content, compression: :none)
    end
    {:ok, product} = Data.mgex_sp3(:cod, Date.new!(2026, 7, 12))
    {:ok, request} = Data.request(product, [source])
    File.write!(System.fetch_env!("SIDEREON_READY"), "ready")
    wait = fn wait -> if File.exists?(System.fetch_env!("SIDEREON_START")), do: :ok, else: (Process.sleep(5); wait.(wait)) end
    wait.(wait)
    {:ok, result} = Data.acquire(request, cache_dir: System.fetch_env!("SIDEREON_CACHE"))
    payload = {result.provenance.cache_hit, result.provenance.distribution_source, result.path, result.provenance.sha256}
    IO.puts("RESULT " <> Base.encode64(:erlang.term_to_binary(payload)))
    """
  end

  defp crash_child_code do
    """
    Application.ensure_all_started(:sidereon)
    alias Sidereon.GNSS.Data
    alias Sidereon.GNSS.Distribution
    content = File.read!(System.fetch_env!("SIDEREON_SOURCE"))
    {:ok, product} = Data.mgex_sp3(:cod, Date.new!(2026, 7, 12))
    {:ok, request} = Data.request(product, [Distribution.in_memory(content, compression: :none)])
    Data.acquire(request, cache_dir: System.fetch_env!("SIDEREON_CACHE"))
    """
  end

  defp lock_child_code do
    """
    Application.ensure_all_started(:sidereon)
    alias Sidereon.GNSS.Data
    alias Sidereon.GNSS.Distribution
    stable = System.fetch_env!("SIDEREON_STABLE")
    {:ok, product} = Data.mgex_sp3(:cod, Date.new!(2026, 7, 12))
    {:ok, request} = Data.request(product, [Distribution.in_memory(<<>>, compression: :none)])
    result = Sidereon.GNSS.ExactCache.with_lock(stable, request.identity, :in_memory, 5_000, fn _cache ->
      orphan = Path.join([Path.dirname(stable), Sidereon.GNSS.ExactCache.control_directory(), "entries", String.duplicate("f", 32)])
      File.mkdir_p!(orphan)
      File.write!(System.fetch_env!("SIDEREON_READY"), "ready")
      wait = fn wait -> if File.exists?(System.fetch_env!("SIDEREON_RELEASE")), do: :ok, else: (Process.sleep(5); wait.(wait)) end
      wait.(wait)
    end)
    :ok = result
    """
  end

  defp wait_for_paths!(paths) do
    deadline = System.monotonic_time(:millisecond) + 10_000
    wait_for_paths!(paths, deadline)
  end

  defp wait_for_paths!(paths, deadline) do
    if Enum.all?(paths, &File.exists?/1) do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline, do: flunk("child process did not reach barrier")
      Process.sleep(5)
      wait_for_paths!(paths, deadline)
    end
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

  defp ionex_body(date) do
    {lines, _map_count} =
      @ionex_fixture
      |> File.read!()
      |> String.split("\n")
      |> Enum.map_reduce(0, fn line, map_count ->
        if line |> String.trim_trailing() |> String.ends_with?("EPOCH OF CURRENT MAP") do
          prefix =
            [date.year, date.month, date.day, map_count, 0, 0]
            |> Enum.map_join(&(&1 |> Integer.to_string() |> String.pad_leading(6)))

          {prefix <> String.slice(line, 36..-1//1), map_count + 1}
        else
          {line, map_count}
        end
      end)

    Enum.join(lines, "\n")
  end

  defp sha256(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
end
