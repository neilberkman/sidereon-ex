defmodule Sidereon.GNSS.SP3ProvenanceTest do
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.Data
  alias Sidereon.GNSS.Distribution
  alias Sidereon.GNSS.SP3

  @golden_path Path.expand("fixtures/sp3-merge-input-v1.json", __DIR__)

  setup_all do
    {:ok, golden: @golden_path |> File.read!() |> Jason.decode!()}
  end

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

  test "shared golden canonicalization contract has literal all-surface IDs", %{golden: golden} do
    esa = golden_artifact(golden["artifacts"]["esa"])
    cod = golden_artifact(golden["artifacts"]["cod"])
    expected = golden["expected"]
    opts = golden_policy_opts(golden["complete_policy"])

    assert {:ok, mean} = SP3.merge_input_identity([esa, cod], Keyword.put(opts, :combine, :mean))
    assert mean.schema_version == golden["schema_version"]
    assert mean.stable_id == expected["mean_esa_cod"]

    assert Enum.map(mean.contributors, & &1.product_sha256) |> MapSet.new() ==
             MapSet.new([esa.product_sha256, cod.product_sha256])

    assert mean.precedence_contributors == nil

    assert {:ok, reverse_mean} =
             SP3.merge_input_identity([Map.new(cod), Map.new(esa)], Keyword.put(opts, :combine, :mean))

    assert reverse_mean.stable_id == expected["mean_esa_cod"]
    assert reverse_mean.contributors == mean.contributors

    permuted_opts =
      opts
      |> Keyword.update!(:systems, &Enum.reverse/1)
      |> Keyword.update!(:asserted_frame_label_sets, fn sets ->
        sets |> Enum.reverse() |> Enum.map(&Enum.reverse/1)
      end)
      |> Keyword.put(:outlier_reject, Map.new(clock_tolerance_s: 7.5e-9, position_tolerance_m: 1.25))
      |> Keyword.put(:combine, :mean)

    assert {:ok, permuted} = SP3.merge_input_identity([Map.new(esa), Map.new(cod)], permuted_opts)
    assert permuted.stable_id == expected["mean_esa_cod"]

    assert {:ok, median} = SP3.merge_input_identity([esa, cod], Keyword.put(opts, :combine, :median))
    assert median.stable_id == expected["median_esa_cod"]

    assert {:ok, precedence} =
             SP3.merge_input_identity([esa, cod], Keyword.put(opts, :combine, :precedence))

    assert precedence.stable_id == expected["precedence_esa_cod"]
    assert precedence.precedence_contributors == [esa, cod]

    assert {:ok, reverse_precedence} =
             SP3.merge_input_identity([cod, esa], Keyword.put(opts, :combine, :precedence))

    assert reverse_precedence.stable_id == expected["precedence_cod_esa"]
    assert reverse_precedence.precedence_contributors == [cod, esa]

    assert {:ok, single} = SP3.merge_input_identity([esa], Keyword.put(opts, :combine, :mean))
    assert single.stable_id == expected["single_mean_esa"]
  end

  test "shared golden mutations, malformed records, and policy limits fail closed or change identity", %{golden: golden} do
    esa = golden_artifact(golden["artifacts"]["esa"])
    cod = golden_artifact(golden["artifacts"]["cod"])
    mutations = golden["required_mutations"]
    opts = golden_policy_opts(golden["complete_policy"])
    mean_opts = Keyword.put(opts, :combine, :mean)

    assert {:ok, baseline} = SP3.merge_input_identity([esa, cod], mean_opts)

    changed_bytes = %{cod | product_sha256: mutations["changed_product_sha256"]}
    assert {:ok, changed} = SP3.merge_input_identity([esa, changed_bytes], mean_opts)
    refute changed.stable_id == baseline.stable_id

    changed_revision =
      put_in(cod, [:resolved_identity, Access.key!(:format_version)], mutations["changed_resolved_format_version"])

    assert {:ok, changed} = SP3.merge_input_identity([esa, changed_revision], mean_opts)
    refute changed.stable_id == baseline.stable_id

    changed_policy = Keyword.put(mean_opts, :clock_tolerance_s, mutations["changed_clock_tolerance_s"])
    assert {:ok, changed} = SP3.merge_input_identity([esa, cod], changed_policy)
    refute changed.stable_id == baseline.stable_id

    malformed = %{cod | product_sha256: mutations["malformed_product_sha256"]}
    assert {:error, _reason} = SP3.merge_input_identity([esa, malformed], mean_opts)
    assert {:error, _reason} = SP3.merge_input_identity([Map.delete(esa, :archive_sha256)], mean_opts)

    assert {:error, {:invalid_merge_policy, :epoch_interval_s}} =
             SP3.merge_input_identity(
               [esa, cod],
               Keyword.put(mean_opts, :epoch_interval_s, mutations["fractional_target_epoch_interval_s"])
             )

    assert {:error, {:invalid_merge_policy, :systems}} =
             SP3.merge_input_identity([esa, cod], Keyword.put(mean_opts, :systems, mutations["empty_systems"]))
  end

  test "negative-zero policy values canonicalize to the golden positive-zero identity", %{golden: golden} do
    esa = golden_artifact(golden["artifacts"]["esa"])
    cod = golden_artifact(golden["artifacts"]["cod"])
    opts = golden_policy_opts(golden["complete_policy"]) |> Keyword.put(:combine, :mean)

    assert {:ok, positive} = SP3.merge_input_identity([esa, cod], Keyword.put(opts, :position_tolerance_m, 0.0))
    assert {:ok, negative} = SP3.merge_input_identity([esa, cod], Keyword.put(opts, :position_tolerance_m, -0.0))
    assert positive.stable_id == golden["expected"]["mean_esa_cod"]
    assert negative.stable_id == positive.stable_id
    assert negative.merge_policy.position_tolerance_m === 0.0
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
        requested_centers: ["cod"],
        contributors: [contributor],
        source_count: 1,
        single_product: true,
        merged: true,
        input_identity_schema_version: identity.schema_version,
        stable_input_identity: identity.stable_id,
        merge_policy: identity.merge_policy,
        merge_report: empty_merge_report()
      })

    encoded = Jason.encode!(persisted)
    assert encoded =~ identity.stable_id
    assert :ok = Data.verify_merge_report(persisted)
    assert :ok = encoded |> Jason.decode!() |> Data.verify_merge_report()

    tampered =
      put_in(persisted, [:contributors, Access.at(0), :artifact_identity, :product_sha256], String.duplicate("ff", 32))

    assert {:error, :merge_input_identity_mismatch} = Data.verify_merge_report(tampered)

    strict_rejections = [
      Map.put(persisted, :authorization, "secret"),
      put_in(persisted, [:contributors, Access.at(0)], Map.put(hd(persisted.contributors), :cache_path, "/tmp/x")),
      put_in(
        persisted,
        [:contributors, Access.at(0), :artifact_identity],
        Map.put(hd(persisted.contributors).artifact_identity, :temporary_path, "/tmp/x")
      ),
      put_in(
        persisted,
        [:contributors, Access.at(0), :acquisition],
        Map.put(hd(persisted.contributors).acquisition, :cookie, "secret")
      ),
      Map.update!(persisted, :merge_policy, &Map.put(&1, :api_key, "secret")),
      Map.update!(persisted, :merge_report, &Map.put(&1, :local_path, "/tmp/x")),
      %{persisted | source_count: "1"},
      %{persisted | single_product: "true"},
      %{persisted | source_count: 2},
      %{persisted | single_product: false},
      %{persisted | input_identity_schema_version: 2},
      %{persisted | schema_version: 2},
      %{persisted | requested_centers: []},
      %{persisted | requested_centers: ["cod", "esa"]},
      %{persisted | requested_centers: ["cod", "cod"]},
      put_in(persisted, [:contributors, Access.at(0), :center], "esa"),
      put_in(persisted, [:contributors, Access.at(0), :filename], "WRONG.SP3"),
      put_in(persisted, [:contributors, Access.at(0), :date], "2026-07-13"),
      put_in(persisted, [:contributors, Access.at(0), :issue], "0600"),
      put_in(persisted, [:contributors, Access.at(0), :pattern], "alias_latest"),
      %{persisted | contributors: []},
      %{
        persisted
        | absent: [%{center: "cod", filename: nil, pattern: nil, reason: "missing", url: nil, http_status: nil}]
      },
      put_in(persisted, [:merge_report, :single_source], [
        %{satellite: "G01", jd_whole: 2_460_000.0, jd_fraction: 0.5, sources: [1]}
      ])
    ]

    Enum.each(strict_rejections, fn invalid ->
      assert {:error, _reason} = Data.verify_merge_report(invalid)
    end)

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

  defp golden_artifact(artifact) do
    %{
      requested_identity: golden_product_identity(artifact["requested_identity"]),
      resolved_identity: golden_product_identity(artifact["resolved_identity"]),
      distribution_source: String.to_existing_atom(artifact["distribution_source"]),
      official_filename: artifact["official_filename"],
      product_sha256: artifact["product_sha256"],
      product_byte_length: artifact["product_byte_length"],
      archive_sha256: artifact["archive_sha256"],
      archive_byte_length: artifact["archive_byte_length"],
      compression: String.to_existing_atom(artifact["compression"])
    }
  end

  defp golden_product_identity(identity) do
    %Distribution.ProductIdentity{
      family: identity["family"],
      analysis_center: identity["analysis_center"],
      publisher: identity["publisher"],
      solution_class: identity["solution"],
      campaign: identity["campaign"],
      filename_version: identity["version"],
      date: Date.from_iso8601!(identity["date"]),
      issue: identity["issue"],
      span: identity["span"],
      sample: identity["sample"],
      official_filename: identity["official_filename"],
      format: identity["format"],
      format_version: identity["format_version"],
      prediction_horizon_days: identity["prediction_horizon_days"]
    }
  end

  defp golden_policy_opts(policy) do
    frame = policy["frame_reconciliation"]

    [
      position_tolerance_m: policy["position_tolerance_m"],
      clock_tolerance_s: policy["clock_tolerance_s"],
      min_agree: policy["min_agree"],
      clock_min_common: policy["clock_min_common"],
      precedence_scope: String.to_existing_atom(policy["precedence_scope"]),
      outlier_reject: %{
        position_tolerance_m: policy["outlier_reject"]["position_tolerance_m"],
        clock_tolerance_s: policy["outlier_reject"]["clock_tolerance_s"]
      },
      epoch_interval_s: policy["target_epoch_interval_s"],
      systems: policy["systems"],
      asserted_frame_label_sets: frame["asserted_equivalent_label_sets"],
      helmert: frame["helmert"]
    ]
  end

  defp empty_merge_report do
    %{
      frame_reconciliations: [],
      quarantined: [],
      single_source: [],
      position_outliers: [],
      clock_outliers: [],
      agreement: %{
        position_rms_m: nil,
        position_max_m: nil,
        clock_rms_s: nil,
        clock_max_s: nil,
        cells: [],
        epochs: []
      }
    }
  end
end
