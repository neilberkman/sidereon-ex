defmodule Sidereon.GNSS.PublicArchiveLiveTest do
  use ExUnit.Case, async: false

  alias Sidereon.GNSS.Data
  alias Sidereon.GNSS.Distribution
  alias Sidereon.NIF

  @bkg_igs_final_url "https://igs.bkg.bund.de/root_ftp/IGS/products/orbits/2235/igs22350.sp3.Z"
  @archive_sha256 "cf0e99b00b1767b4e795fee4add2e53921409d3fa97f8b160901038af402b34b"
  @product_sha256 "b5fcb039fc831bdf43f606bd9d4442ac14ded629c63042f0e52b0a2451174301"
  @max_archive_bytes 64 * 1024 * 1024
  @max_product_bytes 500 * 1024 * 1024

  @tag :network
  test "official BKG Unix-compress IGS final product survives exact acquisition and offline reload" do
    root =
      Path.join(
        System.tmp_dir!(),
        "sidereon-bkg-igs-final-live-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    archive = official_archive!()
    assert byte_size(archive) <= @max_archive_bytes
    assert sha256(archive) == @archive_sha256

    assert {:ok, product_bytes} =
             NIF.data_unix_compress_decompress(archive, @max_product_bytes)

    assert sha256(product_bytes) == @product_sha256

    archive_path = Path.join(root, "igs22350.sp3.Z")
    File.write!(archive_path, archive, [:binary])

    {:ok, product} = Data.mgex_sp3(:igs, ~D[2022-11-06])
    {:ok, identity} = Data.identity(product)

    assert identity.official_filename == "igs22350.sp3"
    assert identity.span == "01D"
    assert identity.sample == "15M"

    source = Distribution.local_file(archive_path, compression: :unix_compress)
    {:ok, request} = Data.request(product, [source])

    assert {:ok, acquired} =
             Data.acquire(request,
               cache_dir: Path.join(root, "cache"),
               sha256: @product_sha256,
               max_archive_bytes: @max_archive_bytes,
               max_product_bytes: @max_product_bytes
             )

    assert File.read!(acquired.path) == product_bytes
    assert acquired.provenance.cache_hit == false
    assert acquired.provenance.distribution_source == :local_file
    assert acquired.provenance.requested_identity == identity
    assert acquired.provenance.resolved_identity.format_version == "SP3-c"
    assert acquired.provenance.archive_compression == :unix_compress
    assert acquired.provenance.archive_sha256 == @archive_sha256
    assert acquired.provenance.archive_byte_length == byte_size(archive)
    assert acquired.provenance.sha256 == @product_sha256
    assert acquired.provenance.byte_length == byte_size(product_bytes)

    # A verified cache hit must not need the distributor artifact to remain.
    File.rm!(archive_path)

    assert {:ok, cached} =
             Data.acquire(request,
               cache_dir: Path.join(root, "cache"),
               offline: true,
               sha256: @product_sha256,
               max_archive_bytes: @max_archive_bytes,
               max_product_bytes: @max_product_bytes
             )

    assert cached.path == acquired.path
    assert cached.provenance.cache_hit == true
    assert cached.provenance.requested_identity == identity
    assert cached.provenance.resolved_identity == acquired.provenance.resolved_identity
    assert cached.provenance.archive_sha256 == @archive_sha256
    assert cached.provenance.sha256 == @product_sha256
    assert File.read!(cached.path) == product_bytes
  end

  defp official_archive! do
    case System.get_env("SIDEREON_BKG_IGS_FINAL_ARCHIVE") do
      nil ->
        response =
          Req.get!(
            url: @bkg_igs_final_url,
            decode_body: false,
            retry: false,
            connect_options: [timeout: 60_000],
            pool_timeout: 60_000,
            receive_timeout: 60_000
          )

        assert response.status == 200
        IO.iodata_to_binary(response.body)

      path ->
        File.read!(path)
    end
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
