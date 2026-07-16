defmodule Sidereon.GNSS.SP3ProvenanceTest do
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.Data
  alias Sidereon.GNSS.SP3

  setup do
    {:ok, first_product} = Data.mgex_sp3(:cod, ~D[2026-07-12])
    {:ok, second_product} = Data.mgex_sp3(:esa, ~D[2026-07-12])
    {:ok, first_identity} = Data.identity(first_product)
    {:ok, second_identity} = Data.identity(second_product)

    first = artifact(first_identity, "11")
    second = artifact(second_identity, "22")
    {:ok, first: first, second: second}
  end

  test "stable identity is independent of contributor and map enumeration", %{
    first: first,
    second: second
  } do
    assert {:ok, forward} = SP3.merge_input_identity([first, second])
    assert {:ok, reverse} = SP3.merge_input_identity([Map.new(second), Map.new(first)])
    assert forward.schema_version == 1
    assert forward.stable_id == reverse.stable_id
    assert String.starts_with?(forward.stable_id, "sidereon-sp3-merge-input-v1:")
  end

  test "artifact bytes, resolved identity, contributor set, and policy are bound", %{
    first: first,
    second: second
  } do
    assert {:ok, base} = SP3.merge_input_identity([first, second])

    changed_bytes = %{second | product_sha256: String.duplicate("33", 32)}
    assert {:ok, bytes_identity} = SP3.merge_input_identity([first, changed_bytes])
    refute bytes_identity.stable_id == base.stable_id

    changed_resolved =
      put_in(second, [:resolved_identity, Access.key!(:format_version)], "SP3-c")

    assert {:ok, resolved_identity} = SP3.merge_input_identity([first, changed_resolved])
    refute resolved_identity.stable_id == base.stable_id

    assert {:ok, single} = SP3.merge_input_identity([first])
    refute single.stable_id == base.stable_id

    assert {:ok, policy} = SP3.merge_input_identity([first, second], combine: :median)
    refute policy.stable_id == base.stable_id

    assert {:ok, forward_precedence} =
             SP3.merge_input_identity([first, second], combine: :precedence)

    assert {:ok, reverse_precedence} =
             SP3.merge_input_identity([second, first], combine: :precedence)

    refute forward_precedence.stable_id == reverse_precedence.stable_id

    assert forward_precedence.merge_policy.precedence_artifact_sha256 == [
             first.product_sha256,
             second.product_sha256
           ]
  end

  test "incomplete and malformed contributor records fail closed", %{first: first} do
    assert {:error, {:invalid_merge_contributor, 0, :incomplete}} =
             SP3.merge_input_identity([Map.delete(first, :archive_sha256)])

    malformed = %{first | product_sha256: "not-a-sha256"}
    assert {:error, reason} = SP3.merge_input_identity([malformed])
    assert inspect(reason) =~ "product SHA-256"
  end

  test "public persistence map separates artifacts from acquisition observations", %{
    first: first
  } do
    contributor = %Data.Contributor{
      center: "cod",
      filename: first.official_filename,
      date: ~D[2026-07-12],
      issue: "0000",
      pattern: "canonical",
      artifact_identity: struct!(Data.ArtifactIdentity, first),
      acquisition: %Data.AcquisitionFacts{
        retrieved_at: "2026-07-16T12:00:00Z",
        cache_hit: false,
        original_url: "https://example.invalid/public.SP3.gz",
        final_url: "https://example.invalid/public.SP3.gz"
      }
    }

    assert {:ok, identity} = SP3.merge_input_identity([first])

    persisted =
      Data.merge_report_to_map(%Data.MergeReport{
        contributors: [contributor],
        source_count: 1,
        single_product: true,
        merged: true,
        input_identity_schema_version: identity.schema_version,
        stable_input_identity: identity.stable_id,
        merge_policy: identity.merge_policy
      })

    encoded = Jason.encode!(persisted)
    assert encoded =~ identity.stable_id
    assert :ok = Data.verify_merge_report(persisted)
    assert :ok = encoded |> Jason.decode!() |> Data.verify_merge_report()

    tampered =
      put_in(persisted, [:contributors, Access.at(0), :artifact_identity, :product_sha256], String.duplicate("ff", 32))

    assert {:error, :merge_input_identity_mismatch} = Data.verify_merge_report(tampered)

    refute encoded =~ "authorization"
    refute encoded =~ "cookie"
    refute encoded =~ "cache_path"
    refute encoded =~ "temporary_path"
    refute encoded =~ System.tmp_dir!()
  end

  defp artifact(requested_identity, digest_byte) do
    %{
      requested_identity: requested_identity,
      resolved_identity: %{requested_identity | format_version: "SP3-d"},
      distribution_source: :direct,
      official_filename: requested_identity.official_filename,
      product_sha256: String.duplicate(digest_byte, 32),
      product_byte_length: 12_345,
      archive_sha256: String.duplicate(if(digest_byte == "11", do: "12", else: "23"), 32),
      archive_byte_length: 6_789,
      compression: :gzip
    }
  end
end
