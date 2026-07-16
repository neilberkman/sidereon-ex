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
    {:ok, third_product} = Data.mgex_sp3(:gfz, ~D[2026-07-12])
    {:ok, first_identity} = Data.identity(first_product)
    {:ok, second_identity} = Data.identity(second_product)
    {:ok, third_identity} = Data.identity(third_product)

    first = artifact(first_identity, "11")
    second = artifact(second_identity, "22")
    third = artifact(third_identity, "33")
    {:ok, first: first, second: second, third: third}
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
        %{satellite: "G01", jd_whole: 2_460_000.5, jd_fraction: 0.5, sources: [1]}
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

  test "strict persistence schemas reject nil unknown keys and atom/string duplicates", %{
    first: first,
    second: second
  } do
    persisted = persisted_report([first, second], [], semantic_merge_report())

    nested =
      persisted_report(
        [first, second],
        [
          outlier_reject: %{position_tolerance_m: 0.5, clock_tolerance_s: 5.0e-9},
          asserted_frame_label_sets: [["IGS14", "ITRF2"]]
        ],
        semantic_merge_report([asserted_frame_reconciliation()])
      )

    with_attempt =
      put_in(nested, [:contributors, Access.at(0), :acquisition, :attempts], [
        %{
          source: :direct,
          error_type: :acquisition,
          message: "public source unavailable",
          url: "https://example.invalid/unavailable.SP3",
          status: nil
        }
      ])

    with_absent = %{
      nested
      | requested_centers: nested.requested_centers ++ ["igs_ult"],
        absent: [
          %{
            center: "igs_ult",
            filename: nil,
            pattern: nil,
            reason: "not published",
            url: nil,
            http_status: nil
          }
        ]
    }

    helmert =
      persisted_report(
        [first, second],
        [helmert: true],
        semantic_merge_report([helmert_frame_reconciliation()])
      )

    assert :ok = Data.verify_merge_report(nested)
    assert :ok = Data.verify_merge_report(with_attempt)
    assert :ok = Data.verify_merge_report(with_absent)
    assert :ok = Data.verify_merge_report(helmert)

    nil_key_mutations = [
      Map.put(persisted, nil, "unknown"),
      update_in(persisted, [:contributors, Access.at(0)], &Map.put(&1, nil, "unknown")),
      update_in(persisted, [:contributors, Access.at(0), :artifact_identity], &Map.put(&1, nil, "unknown")),
      update_in(
        persisted,
        [:contributors, Access.at(0), :artifact_identity, :requested_identity],
        &Map.put(&1, nil, "unknown")
      ),
      update_in(persisted, [:contributors, Access.at(0), :acquisition], &Map.put(&1, nil, "unknown")),
      update_in(persisted, [:merge_policy], &Map.put(&1, nil, "unknown")),
      update_in(nested, [:merge_policy, :outlier_reject], &Map.put(&1, nil, "unknown")),
      update_in(persisted, [:merge_report], &Map.put(&1, nil, "unknown")),
      update_in(persisted, [:merge_report, :single_source, Access.at(0)], &Map.put(&1, nil, "unknown")),
      update_in(persisted, [:merge_report, :agreement], &Map.put(&1, nil, "unknown")),
      update_in(persisted, [:merge_report, :agreement, :cells, Access.at(0)], &Map.put(&1, nil, "unknown")),
      update_in(persisted, [:merge_report, :agreement, :epochs, Access.at(0)], &Map.put(&1, nil, "unknown")),
      update_in(nested, [:merge_report, :frame_reconciliations, Access.at(0)], &Map.put(&1, nil, "unknown")),
      update_in(with_attempt, [:contributors, Access.at(0), :acquisition, :attempts, Access.at(0)], fn attempt ->
        Map.put(attempt, nil, "unknown")
      end),
      update_in(with_absent, [:absent, Access.at(0)], &Map.put(&1, nil, "unknown")),
      update_in(helmert, [:merge_report, :frame_reconciliations, Access.at(0), :parameters], fn parameters ->
        Map.put(parameters, nil, "unknown")
      end),
      update_in(helmert, [:merge_report, :frame_reconciliations, Access.at(0), :rates], fn rates ->
        Map.put(rates, nil, "unknown")
      end)
    ]

    duplicate_mutations = [
      Map.put(persisted, "schema_version", 1),
      update_in(persisted, [:contributors, Access.at(0)], &Map.put(&1, "center", &1.center)),
      update_in(persisted, [:merge_report, :agreement, :cells, Access.at(0)], fn cell ->
        Map.put(cell, "satellite", cell.satellite)
      end)
    ]

    Enum.each(nil_key_mutations ++ duplicate_mutations, fn invalid ->
      assert {:error, {:unknown_or_duplicate_field, _context, _field}} = Data.verify_merge_report(invalid)
    end)
  end

  test "merge flags and agreement aggregates fail closed on contradictions", %{
    first: first,
    second: second,
    third: third
  } do
    persisted = persisted_report([first, second], [], semantic_merge_report())
    assert :ok = Data.verify_merge_report(persisted)
    assert :ok = persisted |> Jason.encode!() |> Jason.decode!() |> Data.verify_merge_report()

    g01 = hd(persisted.merge_report.agreement.cells)

    excessive_clock_contributors =
      persisted
      |> put_in([:merge_report, :agreement, :cells, Access.at(1), :clock_members], 2)
      |> put_in([:merge_report, :agreement, :clock_rms_s], :math.sqrt(5.0e-19))
      |> put_in([:merge_report, :agreement, :epochs, Access.at(0), :clock_rms_s], :math.sqrt(5.0e-19))

    assert {:error, :clock_contributor_mismatch} = Data.verify_merge_report(excessive_clock_contributors)

    impossible_quarantine =
      persisted_report(
        [first, second],
        [min_agree: 1],
        put_in(empty_merge_report(), [:quarantined], [
          %{satellite: "G01", jd_whole: 2_460_000.5, jd_fraction: 0.5, sources: [0, 1]}
        ])
      )

    assert {:error, :invalid_quarantined_consensus} = Data.verify_merge_report(impossible_quarantine)

    strict_policy = persisted_report([first, second], [combine: :precedence], precedence_semantic_merge_report())

    preferred_outlier =
      put_in(strict_policy, [:merge_report, :position_outliers], [
        %{satellite: "G01", jd_whole: 2_460_000.5, jd_fraction: 0.5, sources: [0]}
      ])

    assert {:error, :precedence_outlier_contains_preferred_source} =
             Data.verify_merge_report(preferred_outlier)

    arc_owner_conflict =
      persisted_report(
        [first, second],
        [combine: :precedence, precedence_scope: :satellite_arc],
        conflicting_arc_owner_merge_report()
      )

    assert {:error, :satellite_arc_precedence_mismatch} = Data.verify_merge_report(arc_owner_conflict)

    precedence_later_rms = :math.sqrt(0.5 * 0.5 / 2)
    oversized_position_rms = :math.sqrt(1.0 * 1.0 / 2)

    oversized_position =
      strict_policy
      |> put_in([:merge_report, :agreement, :cells, Access.at(0), :position_rms_m], oversized_position_rms)
      |> put_in([:merge_report, :agreement, :cells, Access.at(0), :position_max_m], 1.0)
      |> put_in(
        [:merge_report, :agreement, :position_rms_m],
        :math.sqrt(
          (0.0 + oversized_position_rms * oversized_position_rms * 2 +
             precedence_later_rms * precedence_later_rms * 2) / 4
        )
      )
      |> put_in([:merge_report, :agreement, :position_max_m], 1.0)
      |> put_in([:merge_report, :agreement, :epochs, Access.at(0), :position_rms_m], oversized_position_rms)
      |> put_in([:merge_report, :agreement, :epochs, Access.at(0), :position_max_m], 1.0)

    assert {:error, :position_agreement_exceeds_policy} = Data.verify_merge_report(oversized_position)

    oversized_clock_rms = :math.sqrt(6.0e-9 * 6.0e-9 / 2)

    oversized_clock =
      strict_policy
      |> put_in([:merge_report, :agreement, :cells, Access.at(0), :clock_rms_s], oversized_clock_rms)
      |> put_in([:merge_report, :agreement, :cells, Access.at(0), :clock_max_s], 6.0e-9)
      |> put_in([:merge_report, :agreement, :clock_rms_s], oversized_clock_rms)
      |> put_in([:merge_report, :agreement, :clock_max_s], 6.0e-9)
      |> put_in([:merge_report, :agreement, :epochs, Access.at(0), :clock_rms_s], oversized_clock_rms)
      |> put_in([:merge_report, :agreement, :epochs, Access.at(0), :clock_max_s], 6.0e-9)

    assert {:error, :clock_agreement_exceeds_policy} = Data.verify_merge_report(oversized_clock)

    guard_position_rms = :math.sqrt(0.8 * 0.8 / 2)

    guard_position_aggregate =
      :math.sqrt((guard_position_rms * guard_position_rms * 2 + precedence_later_rms * precedence_later_rms * 2) / 4)

    guard_clock_rms = :math.sqrt(8.0e-9 * 8.0e-9 / 2)

    guarded_precedence =
      persisted_report(
        [first, second],
        [
          combine: :precedence,
          outlier_reject: %{position_tolerance_m: 1.0, clock_tolerance_s: 1.0e-8}
        ],
        precedence_semantic_merge_report()
      )
      |> put_in([:merge_report, :agreement, :cells, Access.at(0), :position_rms_m], guard_position_rms)
      |> put_in([:merge_report, :agreement, :cells, Access.at(0), :position_max_m], 0.8)
      |> put_in([:merge_report, :agreement, :position_rms_m], guard_position_aggregate)
      |> put_in([:merge_report, :agreement, :position_max_m], 0.8)
      |> put_in([:merge_report, :agreement, :epochs, Access.at(0), :position_rms_m], guard_position_rms)
      |> put_in([:merge_report, :agreement, :epochs, Access.at(0), :position_max_m], 0.8)
      |> put_in([:merge_report, :agreement, :cells, Access.at(0), :clock_rms_s], guard_clock_rms)
      |> put_in([:merge_report, :agreement, :cells, Access.at(0), :clock_max_s], 8.0e-9)
      |> put_in([:merge_report, :agreement, :clock_rms_s], guard_clock_rms)
      |> put_in([:merge_report, :agreement, :clock_max_s], 8.0e-9)
      |> put_in([:merge_report, :agreement, :epochs, Access.at(0), :clock_rms_s], guard_clock_rms)
      |> put_in([:merge_report, :agreement, :epochs, Access.at(0), :clock_max_s], 8.0e-9)

    assert :ok = Data.verify_merge_report(guarded_precedence)

    impossible_precedence_rms =
      strict_policy
      |> put_in([:merge_report, :agreement, :cells, Access.at(0), :position_rms_m], 0.2)
      |> put_in(
        [:merge_report, :agreement, :position_rms_m],
        :math.sqrt((0.0 + 0.2 * 0.2 * 2 + precedence_later_rms * precedence_later_rms * 2) / 4)
      )
      |> put_in([:merge_report, :agreement, :epochs, Access.at(0), :position_rms_m], 0.2)

    assert {:error, {:invalid_field, :selected_position_dispersion}} =
             Data.verify_merge_report(impossible_precedence_rms)

    median_position_rms =
      :math.sqrt((0.0 + 0.2 * 0.2 * 3 + 0.4 * 0.4 * 2) / 5)

    impossible_odd_median_clock =
      persisted_report([first, second, third], [combine: :median], semantic_merge_report())
      |> put_in([:merge_report, :agreement, :cells, Access.at(0), :position_members], 3)
      |> put_in([:merge_report, :agreement, :cells, Access.at(0), :clock_members], 3)
      |> put_in([:merge_report, :agreement, :position_rms_m], median_position_rms)

    assert {:error, {:invalid_field, :selected_clock_dispersion}} =
             Data.verify_merge_report(impossible_odd_median_clock)

    huge_tolerance =
      persisted_report(
        [first, second],
        [combine: :median, position_tolerance_m: 1.0e308, clock_tolerance_s: 1.0e308],
        semantic_merge_report()
      )

    assert :ok = Data.verify_merge_report(huge_tolerance)

    zero_report = zero_dispersion_merge_report()

    Enum.each([:precedence, :median], fn combine ->
      zero_policy =
        persisted_report(
          [first, second],
          [combine: combine, position_tolerance_m: 0.0, clock_tolerance_s: 0.0],
          zero_report
        )

      assert :ok = Data.verify_merge_report(zero_policy)

      tiny_rms = :math.sqrt(1.0e-12 * 1.0e-12 / 2)
      tiny_aggregate = :math.sqrt(tiny_rms * tiny_rms * 2 / 4)

      nonzero_at_zero_tolerance =
        zero_policy
        |> put_in([:merge_report, :agreement, :cells, Access.at(0), :position_rms_m], tiny_rms)
        |> put_in([:merge_report, :agreement, :cells, Access.at(0), :position_max_m], 1.0e-12)
        |> put_in([:merge_report, :agreement, :position_rms_m], tiny_aggregate)
        |> put_in([:merge_report, :agreement, :position_max_m], 1.0e-12)
        |> put_in([:merge_report, :agreement, :epochs, Access.at(0), :position_rms_m], tiny_rms)
        |> put_in([:merge_report, :agreement, :epochs, Access.at(0), :position_max_m], 1.0e-12)

      assert {:error, :position_agreement_exceeds_policy} =
               Data.verify_merge_report(nonzero_at_zero_tolerance)
    end)

    off_grid_fraction = 0.5 + 1.5 / 86_400.0

    off_grid =
      persisted_report([first, second], [epoch_interval_s: 300.0], semantic_merge_report())
      |> put_in([:merge_report, :single_source, Access.at(0), :jd_fraction], off_grid_fraction)
      |> put_in([:merge_report, :agreement, :cells, Access.at(1), :jd_fraction], off_grid_fraction)
      |> put_in([:merge_report, :agreement, :epochs], [
        %{
          jd_whole: 2_460_000.5,
          jd_fraction: 0.5,
          satellites: 1,
          position_rms_m: 0.2,
          position_max_m: 0.2,
          clock_rms_s: 1.0e-9,
          clock_max_s: 1.0e-9
        },
        %{
          jd_whole: 2_460_000.5,
          jd_fraction: off_grid_fraction,
          satellites: 0,
          position_rms_m: 0.0,
          position_max_m: 0.0,
          clock_rms_s: nil,
          clock_max_s: nil
        },
        %{
          jd_whole: 2_460_001.5,
          jd_fraction: 0.5,
          satellites: 1,
          position_rms_m: 0.4,
          position_max_m: 0.5,
          clock_rms_s: nil,
          clock_max_s: nil
        }
      ])

    assert {:error, :merge_report_epoch_grid_mismatch} = Data.verify_merge_report(off_grid)

    impossible_position_rms =
      persisted
      |> put_in([:merge_report, :agreement, :cells, Access.at(0), :position_rms_m], 0.0)
      |> put_in([:merge_report, :agreement, :position_rms_m], :math.sqrt(0.08))
      |> put_in([:merge_report, :agreement, :epochs, Access.at(0), :position_rms_m], 0.0)

    assert {:error, {:invalid_field, {{:agreement_cell, 0}, :position_dispersion}}} =
             Data.verify_merge_report(impossible_position_rms)

    impossible_clock_rms =
      persisted
      |> put_in([:merge_report, :agreement, :cells, Access.at(0), :clock_rms_s], 0.0)
      |> put_in([:merge_report, :agreement, :clock_rms_s], 0.0)
      |> put_in([:merge_report, :agreement, :epochs, Access.at(0), :clock_rms_s], 0.0)

    assert {:error, {:invalid_field, {{:agreement_cell, 0}, :clock_dispersion}}} =
             Data.verify_merge_report(impossible_clock_rms)

    underflow_position_rms =
      persisted
      |> put_in([:merge_report, :agreement, :cells, Access.at(0), :position_rms_m], 0.0)
      |> put_in([:merge_report, :agreement, :cells, Access.at(0), :position_max_m], 1.0e-300)
      |> put_in(
        [:merge_report, :agreement, :position_rms_m],
        :math.sqrt((0.0 + 0.0 * 0.0 * 2 + 0.4 * 0.4 * 2) / 4)
      )
      |> put_in([:merge_report, :agreement, :epochs, Access.at(0), :position_rms_m], 0.0)
      |> put_in([:merge_report, :agreement, :epochs, Access.at(0), :position_max_m], 1.0e-300)

    assert :ok = Data.verify_merge_report(underflow_position_rms)

    equal_distance_rms =
      1..3
      |> Enum.reduce(0.0, fn _member, sum -> sum + 0.3 * 0.3 end)
      |> Kernel./(3)
      |> :math.sqrt()

    assert equal_distance_rms > 0.3

    rounded_rms_above_max =
      persisted_report([first, second, third], [], semantic_merge_report())
      |> put_in([:merge_report, :agreement, :cells, Access.at(0), :position_members], 3)
      |> put_in([:merge_report, :agreement, :cells, Access.at(0), :position_rms_m], equal_distance_rms)
      |> put_in([:merge_report, :agreement, :cells, Access.at(0), :position_max_m], 0.3)
      |> put_in(
        [:merge_report, :agreement, :position_rms_m],
        :math.sqrt((equal_distance_rms * equal_distance_rms * 3 + 0.4 * 0.4 * 2) / 5)
      )
      |> put_in([:merge_report, :agreement, :epochs, Access.at(0), :position_rms_m], equal_distance_rms)
      |> put_in([:merge_report, :agreement, :epochs, Access.at(0), :position_max_m], 0.3)

    assert :ok = Data.verify_merge_report(rounded_rms_above_max)

    large = 9.0e153

    aggregate_overflow =
      persisted
      |> put_in([:merge_report, :agreement, :cells, Access.at(0), :position_rms_m], large)
      |> put_in([:merge_report, :agreement, :cells, Access.at(0), :position_max_m], large)
      |> put_in([:merge_report, :agreement, :cells, Access.at(2), :position_rms_m], large)
      |> put_in([:merge_report, :agreement, :cells, Access.at(2), :position_max_m], large)
      |> put_in([:merge_report, :agreement, :position_rms_m], large)
      |> put_in([:merge_report, :agreement, :position_max_m], large)
      |> put_in([:merge_report, :agreement, :epochs, Access.at(0), :position_rms_m], large)
      |> put_in([:merge_report, :agreement, :epochs, Access.at(0), :position_max_m], large)
      |> put_in([:merge_report, :agreement, :epochs, Access.at(1), :position_rms_m], large)
      |> put_in([:merge_report, :agreement, :epochs, Access.at(1), :position_max_m], large)

    assert {:error, :invalid_numeric_arithmetic} = Data.verify_merge_report(aggregate_overflow)

    accepted_alias =
      persisted
      |> put_in([:merge_report, :single_source, Access.at(0), :jd_whole], 2_457_753.5)
      |> put_in([:merge_report, :single_source, Access.at(0), :jd_fraction], 1.0)
      |> put_in([:merge_report, :agreement, :cells, Access.at(0), :jd_whole], 2_457_753.5)
      |> put_in([:merge_report, :agreement, :cells, Access.at(0), :jd_fraction], 1.0)
      |> put_in([:merge_report, :agreement, :cells, Access.at(1), :jd_whole], 2_457_753.5)
      |> put_in([:merge_report, :agreement, :cells, Access.at(1), :jd_fraction], 1.0)
      |> put_in([:merge_report, :agreement, :epochs, Access.at(0), :jd_whole], 2_457_753.5)
      |> put_in([:merge_report, :agreement, :epochs, Access.at(0), :jd_fraction], 1.0)
      |> put_in([:merge_report, :quarantined], [
        %{satellite: "G01", jd_whole: 2_457_754.5, jd_fraction: 0.0, sources: [0, 1]}
      ])

    assert {:error, :merge_report_epoch_alias_mismatch} = Data.verify_merge_report(accepted_alias)

    duplicate_epoch_alias =
      accepted_alias
      |> put_in([:merge_report, :quarantined], [])
      |> put_in([:merge_report, :agreement, :cells, Access.at(2), :jd_whole], 2_457_754.5)
      |> put_in([:merge_report, :agreement, :cells, Access.at(2), :jd_fraction], 0.0)
      |> put_in([:merge_report, :agreement, :epochs, Access.at(1), :jd_whole], 2_457_754.5)
      |> put_in([:merge_report, :agreement, :epochs, Access.at(1), :jd_fraction], 0.0)

    assert {:error, :merge_report_epoch_alias_mismatch} = Data.verify_merge_report(duplicate_epoch_alias)

    invalid_reports = [
      put_in(persisted, [:merge_report, :single_source, Access.at(0), :sources], [0, 1]),
      put_in(persisted, [:merge_report, :single_source, Access.at(0), :sources], [1, 0]),
      update_in(persisted, [:merge_report, :single_source], &(&1 ++ &1)),
      put_in(persisted, [:merge_report, :single_source, Access.at(0), :satellite], "G01"),
      put_in(persisted, [:merge_report, :quarantined], [
        %{satellite: "G03", jd_whole: 2_460_000.5, jd_fraction: 0.5, sources: [0]}
      ]),
      put_in(persisted, [:merge_report, :quarantined], [
        %{satellite: "G01", jd_whole: 2_460_000.5, jd_fraction: 0.5, sources: [0, 1]}
      ]),
      put_in(persisted, [:merge_report, :position_outliers], [
        %{satellite: "G01", jd_whole: 2_460_000.5, jd_fraction: 0.5, sources: [1]}
      ]),
      put_in(persisted, [:merge_report, :clock_outliers], [
        %{satellite: "G03", jd_whole: 2_460_000.5, jd_fraction: 0.5, sources: [1]}
      ]),
      put_in(persisted, [:merge_report, :agreement, :cells, Access.at(1), :position_rms_m], 0.1),
      put_in(persisted, [:merge_report, :agreement, :cells, Access.at(0), :position_rms_m], 0.4),
      put_in(persisted, [:merge_report, :agreement, :cells, Access.at(0), :clock_rms_s], 3.0e-9),
      put_in(persisted, [:merge_report, :agreement, :position_rms_m], 0.0),
      put_in(persisted, [:merge_report, :agreement, :position_max_m], 0.4),
      put_in(persisted, [:merge_report, :agreement, :clock_max_s], 0.5e-9),
      put_in(persisted, [:merge_report, :agreement, :epochs, Access.at(0), :satellites], 2),
      put_in(persisted, [:merge_report, :agreement, :epochs, Access.at(0), :position_rms_m], 0.25),
      put_in(persisted, [:merge_report, :agreement, :epochs, Access.at(0), :clock_max_s], 0.5e-9),
      update_in(persisted, [:merge_report, :agreement, :cells], &Enum.reverse/1),
      update_in(persisted, [:merge_report, :agreement, :cells], &[g01 | &1]),
      update_in(persisted, [:merge_report, :agreement, :epochs], &Enum.reverse/1),
      put_in(persisted, [:merge_report, :agreement, :cells, Access.at(0), :jd_whole], 2_460_000.25),
      put_in(persisted, [:merge_report, :agreement, :cells, Access.at(0), :jd_fraction], 1.000_001)
    ]

    invalid_reports
    |> Enum.with_index()
    |> Enum.each(fn {invalid, index} ->
      case Data.verify_merge_report(invalid) do
        {:error, _reason} -> :ok
        :ok -> flunk("semantic contradiction mutation #{index} was accepted")
      end
    end)
  end

  test "single-contributor reports cannot claim outliers or multi-source cells", %{first: first} do
    persisted = persisted_report([first], [], single_source_merge_report())
    assert :ok = Data.verify_merge_report(persisted)

    leap_second =
      persisted
      |> put_in([:merge_report, :single_source, Access.at(0), :jd_whole], 2_457_753.5)
      |> put_in([:merge_report, :single_source, Access.at(0), :jd_fraction], 1.0)
      |> put_in([:merge_report, :agreement, :cells, Access.at(0), :jd_whole], 2_457_753.5)
      |> put_in([:merge_report, :agreement, :cells, Access.at(0), :jd_fraction], 1.0)
      |> put_in([:merge_report, :agreement, :epochs, Access.at(0), :jd_whole], 2_457_753.5)
      |> put_in([:merge_report, :agreement, :epochs, Access.at(0), :jd_fraction], 1.0)

    assert :ok = Data.verify_merge_report(leap_second)
    assert :ok = leap_second |> Jason.encode!() |> Jason.decode!() |> Data.verify_merge_report()

    ordinary_date_leap_label =
      persisted
      |> put_in([:merge_report, :single_source, Access.at(0), :jd_fraction], 1.0)
      |> put_in([:merge_report, :agreement, :cells, Access.at(0), :jd_fraction], 1.0)
      |> put_in([:merge_report, :agreement, :epochs, Access.at(0), :jd_fraction], 1.0)

    assert {:error, {:invalid_field, {{:single_source, 0}, :jd_fraction}}} =
             Data.verify_merge_report(ordinary_date_leap_label)

    Enum.each([1_721_058.5, 5_373_484.5], fn out_of_range ->
      invalid = put_in(persisted, [:merge_report, :single_source, Access.at(0), :jd_whole], out_of_range)
      assert {:error, {:invalid_field, {{:single_source, 0}, :jd_whole}}} = Data.verify_merge_report(invalid)
    end)

    Enum.each(~w(G32 R27 E36 C63 J09 I14 S20 S58), fn satellite ->
      boundary =
        persisted
        |> put_in([:merge_report, :single_source, Access.at(0), :satellite], satellite)
        |> put_in([:merge_report, :agreement, :cells, Access.at(0), :satellite], satellite)

      assert :ok = Data.verify_merge_report(boundary)
    end)

    Enum.each(~w(G00 G33 R28 E37 C64 J10 I15 S19 S59 G999), fn satellite ->
      invalid = put_in(persisted, [:merge_report, :agreement, :cells, Access.at(0), :satellite], satellite)
      assert {:error, :invalid_satellite_id} = Data.verify_merge_report(invalid)
    end)

    valid_grid =
      persisted_report(
        [first],
        [epoch_interval_s: 300.0],
        single_source_grid_merge_report([11, 311, 611])
      )

    assert :ok = Data.verify_merge_report(valid_grid)

    mixed_phase_grid =
      persisted_report(
        [first],
        [epoch_interval_s: 300.0],
        single_source_grid_merge_report([0.999_999_99, 301.0])
      )

    assert :ok = Data.verify_merge_report(mixed_phase_grid)

    invalid_reports = [
      put_in(persisted, [:merge_report, :position_outliers], [
        %{satellite: "G01", jd_whole: 2_460_000.5, jd_fraction: 0.5, sources: [0]}
      ]),
      put_in(persisted, [:merge_report, :clock_outliers], [
        %{satellite: "G01", jd_whole: 2_460_000.5, jd_fraction: 0.5, sources: [0]}
      ]),
      put_in(persisted, [:merge_report, :agreement, :cells, Access.at(0), :position_members], 2),
      put_in(persisted, [:merge_report, :single_source], [])
    ]

    Enum.each(invalid_reports, fn invalid ->
      assert {:error, _reason} = Data.verify_merge_report(invalid)
    end)
  end

  test "asserted frame reconciliation fields are mutually consistent", %{first: first, second: second} do
    opts = [asserted_frame_label_sets: [["IGS14", "ITRF2"]]]
    frame = asserted_frame_reconciliation()
    persisted = persisted_report([first, second], opts, semantic_merge_report([frame]))
    assert :ok = Data.verify_merge_report(persisted)

    later_overlapping_set =
      frame
      |> Map.put(:asserted_label_set, ["B", "IGS14", "ITRF2"])
      |> then(fn later ->
        persisted_report(
          [first, second],
          [asserted_frame_label_sets: [["A", "IGS14", "ITRF2"], ["B", "IGS14", "ITRF2"]]],
          semantic_merge_report([later])
        )
      end)

    assert {:error, :invalid_asserted_frame_reconciliation} = Data.verify_merge_report(later_overlapping_set)

    invalid_reports = [
      put_in(persisted, [:merge_report, :frame_reconciliations, Access.at(0), :source_index], 0),
      put_in(persisted, [:merge_report, :frame_reconciliations, Access.at(0), :asserted_label_set], ["IGS14", "OTHER"]),
      put_in(persisted, [:merge_report, :frame_reconciliations, Access.at(0), :source_frame], "ITRF2014"),
      put_in(persisted, [:merge_report, :frame_reconciliations, Access.at(0), :catalog_inverse], true),
      put_in(persisted, [:merge_report, :frame_reconciliations, Access.at(0), :identity], false),
      update_in(persisted, [:merge_report, :frame_reconciliations], &(&1 ++ &1))
    ]

    Enum.each(invalid_reports, fn invalid ->
      assert {:error, _reason} = Data.verify_merge_report(invalid)
    end)
  end

  test "Helmert reconciliation authenticates frame mapping and the public catalog row", %{
    first: first,
    second: second
  } do
    persisted =
      persisted_report([first, second], [helmert: true], semantic_merge_report([helmert_frame_reconciliation()]))

    assert :ok = Data.verify_merge_report(persisted)
    assert :ok = persisted |> Jason.encode!() |> Jason.decode!() |> Data.verify_merge_report()

    invalid_reports = [
      put_in(persisted, [:merge_report, :frame_reconciliations, Access.at(0), :source_frame], "ITRF2008"),
      put_in(persisted, [:merge_report, :frame_reconciliations, Access.at(0), :catalog_inverse], true),
      put_in(persisted, [:merge_report, :frame_reconciliations, Access.at(0), :identity], true),
      put_in(persisted, [:merge_report, :frame_reconciliations, Access.at(0), :reference_epoch_year], 2010.0),
      put_in(persisted, [:merge_report, :frame_reconciliations, Access.at(0), :epoch_year_span], [-1.0, 2026.0]),
      put_in(persisted, [:merge_report, :frame_reconciliations, Access.at(0), :epoch_year_span], [2026.0, 10_000.0]),
      put_in(
        persisted,
        [:merge_report, :frame_reconciliations, Access.at(0), :parameters, :scale_ppb],
        -0.41
      ),
      put_in(persisted, [:merge_report, :frame_reconciliations, Access.at(0), :provenance], "other")
    ]

    Enum.each(invalid_reports, fn invalid ->
      assert {:error, _reason} = Data.verify_merge_report(invalid)
    end)

    identity =
      persisted_report(
        [first, second],
        [helmert: true],
        semantic_merge_report([identity_helmert_frame_reconciliation()])
      )

    assert :ok = Data.verify_merge_report(identity)

    invalid_identity =
      put_in(identity, [:merge_report, :frame_reconciliations, Access.at(0), :parameters], %{
        translation_mm: [0.0, 0.0, 0.0],
        scale_ppb: 0.0,
        rotation_mas: [0.0, 0.0, 0.0]
      })

    assert {:error, _reason} = Data.verify_merge_report(invalid_identity)
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

  defp persisted_report(artifacts, opts, merge_report) do
    assert {:ok, identity} = SP3.merge_input_identity(artifacts, opts)

    contributors =
      Enum.map(artifacts, fn artifact ->
        requested = artifact.requested_identity

        %Data.Contributor{
          center: requested.analysis_center,
          filename: artifact.official_filename,
          date: requested.date,
          issue: requested.issue,
          pattern: "canonical",
          artifact_identity: struct!(Data.ArtifactIdentity, artifact),
          acquisition: %Data.AcquisitionFacts{
            retrieved_at: "2026-07-16T12:00:00Z",
            cache_hit: false,
            original_url: "https://example.invalid/#{artifact.official_filename}",
            final_url: "https://example.invalid/#{artifact.official_filename}"
          }
        }
      end)

    Data.merge_report_to_map(%Data.MergeReport{
      requested_centers: Enum.map(contributors, & &1.center),
      contributors: contributors,
      source_count: length(contributors),
      single_product: length(contributors) == 1,
      merged: true,
      input_identity_schema_version: identity.schema_version,
      stable_input_identity: identity.stable_id,
      merge_policy: identity.merge_policy,
      merge_report: merge_report
    })
  end

  defp semantic_merge_report(frame_reconciliations \\ []) do
    position_rms = :math.sqrt(0.1)

    %{
      frame_reconciliations: frame_reconciliations,
      quarantined: [],
      single_source: [
        %{satellite: "G02", jd_whole: 2_460_000.5, jd_fraction: 0.5, sources: [0]}
      ],
      position_outliers: [],
      clock_outliers: [],
      agreement: %{
        position_rms_m: position_rms,
        position_max_m: 0.5,
        clock_rms_s: 1.0e-9,
        clock_max_s: 1.0e-9,
        cells: [
          %{
            satellite: "G01",
            jd_whole: 2_460_000.5,
            jd_fraction: 0.5,
            position_members: 2,
            position_rms_m: 0.2,
            position_max_m: 0.2,
            clock_members: 2,
            clock_rms_s: 1.0e-9,
            clock_max_s: 1.0e-9
          },
          %{
            satellite: "G02",
            jd_whole: 2_460_000.5,
            jd_fraction: 0.5,
            position_members: 1,
            position_rms_m: 0.0,
            position_max_m: 0.0,
            clock_members: 1,
            clock_rms_s: 0.0,
            clock_max_s: 0.0
          },
          %{
            satellite: "E01",
            jd_whole: 2_460_001.5,
            jd_fraction: 0.5,
            position_members: 2,
            position_rms_m: 0.4,
            position_max_m: 0.5,
            clock_members: 0,
            clock_rms_s: nil,
            clock_max_s: nil
          }
        ],
        epochs: [
          %{
            jd_whole: 2_460_000.5,
            jd_fraction: 0.5,
            satellites: 1,
            position_rms_m: 0.2,
            position_max_m: 0.2,
            clock_rms_s: 1.0e-9,
            clock_max_s: 1.0e-9
          },
          %{
            jd_whole: 2_460_001.5,
            jd_fraction: 0.5,
            satellites: 1,
            position_rms_m: 0.4,
            position_max_m: 0.5,
            clock_rms_s: nil,
            clock_max_s: nil
          }
        ]
      }
    }
  end

  defp precedence_semantic_merge_report do
    report = semantic_merge_report()
    position_rms = :math.sqrt(0.2 * 0.2 / 2)
    later_position_rms = :math.sqrt(0.5 * 0.5 / 2)
    clock_rms = :math.sqrt(1.0e-9 * 1.0e-9 / 2)

    report
    |> put_in([:agreement, :cells, Access.at(0), :position_rms_m], position_rms)
    |> put_in([:agreement, :cells, Access.at(0), :clock_rms_s], clock_rms)
    |> put_in([:agreement, :cells, Access.at(2), :position_rms_m], later_position_rms)
    |> put_in(
      [:agreement, :position_rms_m],
      :math.sqrt((0.0 + position_rms * position_rms * 2 + later_position_rms * later_position_rms * 2) / 4)
    )
    |> put_in([:agreement, :clock_rms_s], clock_rms)
    |> put_in([:agreement, :epochs, Access.at(0), :position_rms_m], position_rms)
    |> put_in([:agreement, :epochs, Access.at(0), :clock_rms_s], clock_rms)
    |> put_in([:agreement, :epochs, Access.at(1), :position_rms_m], later_position_rms)
  end

  defp single_source_merge_report do
    %{
      frame_reconciliations: [],
      quarantined: [],
      single_source: [
        %{satellite: "G01", jd_whole: 2_460_000.5, jd_fraction: 0.5, sources: [0]}
      ],
      position_outliers: [],
      clock_outliers: [],
      agreement: %{
        position_rms_m: nil,
        position_max_m: 0.0,
        clock_rms_s: nil,
        clock_max_s: 0.0,
        cells: [
          %{
            satellite: "G01",
            jd_whole: 2_460_000.5,
            jd_fraction: 0.5,
            position_members: 1,
            position_rms_m: 0.0,
            position_max_m: 0.0,
            clock_members: 1,
            clock_rms_s: 0.0,
            clock_max_s: 0.0
          }
        ],
        epochs: [
          %{
            jd_whole: 2_460_000.5,
            jd_fraction: 0.5,
            satellites: 0,
            position_rms_m: 0.0,
            position_max_m: 0.0,
            clock_rms_s: nil,
            clock_max_s: nil
          }
        ]
      }
    }
  end

  defp zero_dispersion_merge_report do
    report = semantic_merge_report()

    cells =
      Enum.map(report.agreement.cells, fn cell ->
        %{
          cell
          | position_rms_m: 0.0,
            position_max_m: 0.0,
            clock_rms_s: if(!is_nil(cell.clock_rms_s), do: 0.0),
            clock_max_s: if(!is_nil(cell.clock_max_s), do: 0.0)
        }
      end)

    epochs =
      Enum.map(report.agreement.epochs, fn epoch ->
        %{
          epoch
          | position_rms_m: 0.0,
            position_max_m: 0.0,
            clock_rms_s: if(!is_nil(epoch.clock_rms_s), do: 0.0),
            clock_max_s: if(!is_nil(epoch.clock_max_s), do: 0.0)
        }
      end)

    put_in(report, [:agreement], %{
      position_rms_m: 0.0,
      position_max_m: 0.0,
      clock_rms_s: 0.0,
      clock_max_s: 0.0,
      cells: cells,
      epochs: epochs
    })
  end

  defp single_source_grid_merge_report(seconds) do
    flags =
      Enum.map(seconds, fn second ->
        %{satellite: "G01", jd_whole: 2_460_000.5, jd_fraction: second / 86_400.0, sources: [0]}
      end)

    cells =
      Enum.map(seconds, fn second ->
        %{
          satellite: "G01",
          jd_whole: 2_460_000.5,
          jd_fraction: second / 86_400.0,
          position_members: 1,
          position_rms_m: 0.0,
          position_max_m: 0.0,
          clock_members: 0,
          clock_rms_s: nil,
          clock_max_s: nil
        }
      end)

    epochs =
      Enum.map(seconds, fn second ->
        %{
          jd_whole: 2_460_000.5,
          jd_fraction: second / 86_400.0,
          satellites: 0,
          position_rms_m: 0.0,
          position_max_m: 0.0,
          clock_rms_s: nil,
          clock_max_s: nil
        }
      end)

    %{
      frame_reconciliations: [],
      quarantined: [],
      single_source: flags,
      position_outliers: [],
      clock_outliers: [],
      agreement: %{
        position_rms_m: nil,
        position_max_m: 0.0,
        clock_rms_s: nil,
        clock_max_s: nil,
        cells: cells,
        epochs: epochs
      }
    }
  end

  defp conflicting_arc_owner_merge_report do
    seconds = [11, 311]
    report = single_source_grid_merge_report(seconds)

    put_in(report, [:single_source, Access.at(1), :sources], [1])
  end

  defp asserted_frame_reconciliation do
    %{
      source_index: 1,
      source_label: "ITRF2",
      target_label: "IGS14",
      method: :asserted_equivalence,
      asserted_label_set: ["IGS14", "ITRF2"],
      source_frame: nil,
      target_frame: nil,
      catalog_source_frame: nil,
      catalog_target_frame: nil,
      catalog_inverse: false,
      reference_epoch_year: nil,
      parameters: nil,
      rates: nil,
      provenance: nil,
      epoch_year_span: nil,
      records_affected: 1,
      identity: true
    }
  end

  defp helmert_frame_reconciliation do
    %{
      source_index: 1,
      source_label: "IGS20",
      target_label: "IGS14",
      method: :helmert,
      asserted_label_set: nil,
      source_frame: "ITRF2020",
      target_frame: "ITRF2014",
      catalog_source_frame: "ITRF2020",
      catalog_target_frame: "ITRF2014",
      catalog_inverse: false,
      reference_epoch_year: 2015.0,
      parameters: %{
        translation_mm: [-1.4, -0.9, 1.4],
        scale_ppb: -0.42,
        rotation_mas: [0.0, 0.0, 0.0]
      },
      rates: %{
        translation_mm_per_year: [0.0, -0.1, 0.2],
        scale_ppb_per_year: 0.0,
        rotation_mas_per_year: [0.0, 0.0, 0.0]
      },
      provenance: "ITRF/IGN Transfo-ITRF2020_TRFs.txt, ITRF2020 to past ITRFs, epoch 2015.0",
      epoch_year_span: [2026.0, 2026.5],
      records_affected: 1,
      identity: false
    }
  end

  defp identity_helmert_frame_reconciliation do
    %{
      source_index: 1,
      source_label: "IGc20",
      target_label: "IGS20",
      method: :helmert,
      asserted_label_set: nil,
      source_frame: "ITRF2020",
      target_frame: "ITRF2020",
      catalog_source_frame: nil,
      catalog_target_frame: nil,
      catalog_inverse: false,
      reference_epoch_year: nil,
      parameters: nil,
      rates: nil,
      provenance: nil,
      epoch_year_span: [2026.0, 2026.5],
      records_affected: 1,
      identity: true
    }
  end
end
