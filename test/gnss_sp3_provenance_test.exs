defmodule Sidereon.GNSS.SP3ProvenanceTest do
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.Data
  alias Sidereon.GNSS.Distribution
  alias Sidereon.GNSS.SP3

  @golden_path Path.expand("fixtures/sp3-merge-input-v1.json", __DIR__)
  @report_golden_path Path.expand("fixtures/sp3-merge-report-v3.json", __DIR__)

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

    assert {:ok, _fractional} =
             SP3.merge_input_identity(
               [esa, cod],
               Keyword.put(mean_opts, :epoch_interval_s, mutations["fractional_target_epoch_interval_s"])
             )

    assert {:error, %{kind: "sp3_epoch_interval", field: "target_epoch_interval_s"} = interval_error} =
             SP3.merge_input_identity(
               [esa, cod],
               Keyword.put(mean_opts, :epoch_interval_s, 1.0e-9)
             )

    assert is_binary(interval_error.value)

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
    assert persisted.schema_version == 3
    assert persisted.merge_policy.verify_continuity == nil
    assert persisted.merge_policy.provenance == nil
    assert :ok = Data.verify_merge_report(persisted)
    assert :ok = encoded |> Jason.decode!() |> Data.verify_merge_report()
    assert :ok = Data.verify_merge_report(put_in(persisted, [:contributors, Access.at(0), :issue], nil))

    # A version 2 map, written before the report carried the continuity report
    # and the provenance and the policy recorded the options that request
    # them, verifies without those four fields.
    version_2 =
      %{legacy_layout(persisted) | schema_version: 2}
      |> Map.update!(:merge_report, &Map.drop(&1, [:continuity, :provenance]))

    assert :ok = Data.verify_merge_report(version_2)
    assert :ok = version_2 |> Jason.encode!() |> Jason.decode!() |> Data.verify_merge_report()

    # A version 1 map written before the merge report stated what it did not
    # write verifies without the four omission fields.
    legacy =
      %{version_2 | schema_version: 1}
      |> Map.update!(
        :merge_report,
        &Map.drop(&1, [:dropped_input_epochs, :omitted_epochs, :arc_withheld, :clock_omissions])
      )

    assert :ok = Data.verify_merge_report(legacy)
    assert :ok = legacy |> Jason.encode!() |> Jason.decode!() |> Data.verify_merge_report()

    # Each version carries exactly its own fields, in its own layout.
    for invalid <- [
          %{version_2 | schema_version: 3},
          %{persisted | schema_version: 2},
          %{legacy_layout(persisted) | schema_version: 3},
          Map.update!(version_2, :merge_report, &Map.put(&1, :continuity, nil)),
          Map.update!(version_2, :merge_policy, &Map.put(&1, :provenance, nil)),
          Map.update!(persisted, :merge_policy, &Map.delete(&1, :verify_continuity)),
          Map.update!(persisted, :merge_policy, &Map.put(&1, :schema_version, 1)),
          put_in(persisted, [:contributors, Access.at(0), :artifact_identity, :schema_version], 2),
          Map.update!(persisted, :merge_report, &Map.delete(&1, :provenance))
        ] do
      assert {:error, _reason} = Data.verify_merge_report(invalid)
    end

    # The omission records are checked field by field and against the policy:
    # a withheld arc cell and a clock without its preferred source need
    # precedence, the arc cell satellite-arc precedence.
    arc_persisted =
      persisted_report(
        [first],
        [combine: :precedence, precedence_scope: :satellite_arc, min_agree: 1],
        empty_merge_report()
      )

    epoch = %{time_scale: "GPST", jd_whole: 2_460_000.5, jd_fraction: 0.5}

    valid_omissions = %{
      dropped_input_epochs: [%{source: 0, epoch_index: 3, epoch: epoch, reason: :not_on_tick_axis}],
      omitted_epochs: [%{time_scale: "GPST", nanos_since_j2000: 810_000_000_000_000_000}],
      arc_withheld: [%{satellite: "G01", epoch: epoch, sources: [0]}],
      clock_omissions: [
        %{
          epoch: epoch,
          satellite: "G01",
          source: 0,
          reason: :preferred_source_without_clock,
          preferred: nil,
          cell_has_clock: false
        }
      ]
    }

    with_omissions = Map.update!(arc_persisted, :merge_report, &Map.merge(&1, valid_omissions))
    assert :ok = Data.verify_merge_report(with_omissions)
    assert :ok = with_omissions |> Jason.encode!() |> Jason.decode!() |> Data.verify_merge_report()

    # The core holds a UTC 23:59:60.5 label on the next day's boundary less the
    # half second remaining to it; 2016-12-31 ended with a leap second, and
    # 2017-01-01 00:00 is JD 2457754.5.
    leap_label = %{time_scale: "UTC", jd_whole: 2_457_754.5, jd_fraction: -0.5 / 86_400.0}
    assert :ok = Data.verify_merge_report(put_in(persisted, [:merge_report, :omitted_epochs], [leap_label]))

    # 2017-12-31 ended without one.
    assert {:error, _reason} =
             Data.verify_merge_report(
               put_in(persisted, [:merge_report, :omitted_epochs], [%{leap_label | jd_whole: 2_458_119.5}])
             )

    for invalid <- [
          put_in(with_omissions, [:merge_report, :dropped_input_epochs, Access.at(0), :source], 1),
          put_in(with_omissions, [:merge_report, :dropped_input_epochs, Access.at(0), :reason], :other),
          # No target grid, so no input epoch is off one.
          put_in(with_omissions, [:merge_report, :dropped_input_epochs, Access.at(0), :reason], :off_target_grid),
          put_in(with_omissions, [:merge_report, :arc_withheld, Access.at(0), :sources], []),
          put_in(with_omissions, [:merge_report, :clock_omissions, Access.at(0), :preferred], 1),
          put_in(with_omissions, [:merge_report, :clock_omissions, Access.at(0), :cell_has_clock], "no"),
          put_in(with_omissions, [:merge_report, :clock_omissions, Access.at(0), :cell_has_clock], true),
          put_in(with_omissions, [:merge_report, :omitted_epochs], [%{time_scale: "GPST", nanos_since_j2000: 1.5}]),
          # Every epoch of a report is on one time scale.
          put_in(with_omissions, [:merge_report, :omitted_epochs], [
            %{time_scale: "UTC", nanos_since_j2000: 810_000_000_000_000_000}
          ]),
          # Under the mean the policy states, neither record is possible.
          Map.update!(persisted, :merge_report, &Map.merge(&1, %{valid_omissions | clock_omissions: []})),
          Map.update!(persisted, :merge_report, &Map.merge(&1, %{valid_omissions | arc_withheld: []})),
          Map.update!(arc_persisted, :merge_report, &Map.delete(&1, :clock_omissions))
        ] do
      assert {:error, _reason} = Data.verify_merge_report(invalid)
    end

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
        [:contributors, Access.at(0), :acquisition_facts],
        Map.put(hd(persisted.contributors).acquisition_facts, :cookie, "secret")
      ),
      Map.update!(persisted, :merge_policy, &Map.put(&1, :api_key, "secret")),
      Map.update!(persisted, :merge_report, &Map.put(&1, :local_path, "/tmp/x")),
      %{persisted | source_count: "1"},
      %{persisted | single_product: "true"},
      %{persisted | source_count: 2},
      %{persisted | single_product: false},
      %{persisted | input_identity_schema_version: 2},
      %{persisted | schema_version: 4},
      # A version 1 map predates the omission fields, so it may not carry them.
      %{persisted | schema_version: 1},
      %{persisted | requested_centers: []},
      %{persisted | requested_centers: ["cod", "esa"]},
      %{persisted | requested_centers: ["cod", "cod"]},
      put_in(persisted, [:contributors, Access.at(0), :center], "esa"),
      put_in(persisted, [:contributors, Access.at(0), :filename], "WRONG.SP3"),
      put_in(persisted, [:contributors, Access.at(0), :date], "2026-07-13"),
      put_in(persisted, [:contributors, Access.at(0), :issue], "0600"),
      put_in(persisted, [:contributors, Access.at(0), :issue], ""),
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

  test "a version 3 map carries the merge continuity report and provenance losslessly", %{
    first: first,
    second: second
  } do
    # G01 from source 0 at 00:00 and from source 1 at 00:15, 10,000 km apart
    # in X: an 11.1 km/s step the MEO speed gate refuses, across the change of
    # contributor.
    opts = [
      combine: :precedence,
      min_agree: 1,
      verify_continuity: [orbit_class: :meo_gnss, residual_tolerance_m: nil],
      provenance: :full
    ]

    assert {:ok, _merged, merge_report} = SP3.merge([g01_sp3(" 0", 15_000.0), g01_sp3("15", 25_000.0)], opts)
    assert %{splices: [_splice]} = merge_report.continuity
    assert %{mode: :full, cells: [_, _]} = merge_report.provenance

    persisted = persisted_report([first, second], opts, merge_report)
    assert persisted.schema_version == 3

    assert persisted.merge_policy.verify_continuity == %{
             orbit_class: "meo_gnss",
             residual_tolerance_m: nil,
             gap_threshold_factor: nil
           }

    assert persisted.merge_policy.provenance == "full"
    # The shared record states the attestation as `attested`.
    {attested, continuity} = Map.pop!(merge_report.continuity, :attested?)
    assert persisted.merge_report.continuity == Map.put(continuity, :attested, attested)
    assert persisted.merge_report.provenance == merge_report.provenance
    assert :ok = Data.verify_merge_report(persisted)

    decoded = persisted |> Jason.encode!() |> Jason.decode!()
    assert :ok = Data.verify_merge_report(decoded)
    assert decoded |> Jason.encode!() |> Jason.decode!() == decoded

    [splice] = persisted.merge_report.continuity.splices
    [first_cell, second_cell] = splice.cells
    defect = splice.defect

    unusable_defect = %{
      kind: :unusable_sample,
      satellite: defect.satellite,
      from_j2000_s: defect.from_j2000_s,
      to_j2000_s: defect.from_j2000_s,
      magnitude: nil,
      bound: nil,
      epoch_j2000_s: defect.from_j2000_s,
      sample_index: 0,
      reason: :non_finite_position
    }

    unusable_violation = %{
      defect: unusable_defect,
      from_sources: [],
      to_sources: [],
      cells: [],
      sources: [],
      crosses_contributors: false
    }

    unusable_report =
      persisted
      |> put_in([:merge_report, :continuity, :defects], [unusable_defect])
      |> put_in([:merge_report, :continuity, :violations], [unusable_violation])
      |> put_in([:merge_report, :continuity, :splices], [])

    assert :ok = Data.verify_merge_report(unusable_report)
    assert :ok = unusable_report |> Jason.encode!() |> Jason.decode!() |> Data.verify_merge_report()

    no_epoch_defect = %{
      unusable_defect
      | from_j2000_s: nil,
        to_j2000_s: nil,
        epoch_j2000_s: nil,
        reason: :epoch_not_placed
    }

    no_epoch_report =
      unusable_report
      |> put_in([:merge_report, :continuity, :defects], [no_epoch_defect])
      |> put_in([:merge_report, :continuity, :violations, Access.at(0), :defect], no_epoch_defect)

    assert :ok = Data.verify_merge_report(no_epoch_report)

    placed_but_unplaced_reason =
      unusable_report
      |> put_in([:merge_report, :continuity, :defects, Access.at(0), :reason], :epoch_not_placed)
      |> put_in([:merge_report, :continuity, :violations, Access.at(0), :defect, :reason], :epoch_not_placed)

    unplaced_but_placed_reason =
      no_epoch_report
      |> put_in([:merge_report, :continuity, :defects, Access.at(0), :reason], :non_finite_position)
      |> put_in([:merge_report, :continuity, :violations, Access.at(0), :defect, :reason], :non_finite_position)

    assert {:error, {:invalid_field, {{:continuity_defects, 0}, :reason_epoch}}} =
             Data.verify_merge_report(placed_but_unplaced_reason)

    assert {:error, {:invalid_field, {{:continuity_defects, 0}, :reason_epoch}}} =
             Data.verify_merge_report(unplaced_but_placed_reason)

    for invalid <- [
          put_in(unusable_report, [:merge_report, :continuity, :defects, Access.at(0), :sample_index], -1),
          put_in(unusable_report, [:merge_report, :continuity, :violations, Access.at(0), :defect, :reason], :unknown),
          put_in(unusable_report, [:merge_report, :continuity, :defects, Access.at(0), :to_j2000_s], 0.0),
          update_in(
            unusable_report,
            [:merge_report, :continuity, :defects, Access.at(0)],
            &Map.delete(&1, :sample_index)
          )
        ] do
      assert {:error, _reason} = Data.verify_merge_report(invalid)
    end

    assert first_cell.selection == %{kind: :single_source, source: 0}
    assert second_cell.selection == %{kind: :single_source, source: 1}

    for invalid <- [
          # The report and the policy disagree about what was requested.
          put_in(persisted, [:merge_policy, :verify_continuity], nil),
          put_in(persisted, [:merge_policy, :provenance], "summary"),
          put_in(persisted, [:merge_report, :continuity], nil),
          put_in(persisted, [:merge_report, :provenance], nil),
          # The continuity report contradicts itself.
          put_in(persisted, [:merge_report, :continuity, :attested], true),
          put_in(persisted, [:merge_report, :continuity, :splices], []),
          put_in(persisted, [:merge_report, :continuity, :defects], [%{defect | magnitude: defect.magnitude * 2.0}]),
          put_in(persisted, [:merge_report, :continuity, :violations, Access.at(0), :cells], [
            first_cell,
            %{second_cell | selection: %{kind: :single_source, source: 0}}
          ]),
          put_in(persisted, [:merge_report, :continuity, :violations, Access.at(0), :sources], [0]),
          # The continuity report contradicts the options that requested it:
          # no speed gate ran without an orbit class, and no residual was
          # checked without a tolerance.
          put_in(persisted, [:merge_policy, :verify_continuity, :orbit_class], nil),
          put_in(persisted, [:merge_report, :continuity, :residuals_checked], 1),
          # The provenance contradicts the agreement or the source count.
          update_in(persisted, [:merge_report, :provenance, :cells], &Enum.reverse/1),
          update_in(persisted, [:merge_report, :provenance, :cells], &tl/1),
          put_in(persisted, [:merge_report, :provenance, :coverage, Access.at(0), :cells_absent], 0),
          update_in(persisted, [:merge_report, :provenance, :coverage], &tl/1),
          put_in(persisted, [:merge_report, :provenance, :transitions, Access.at(0), :reason], :other),
          # Without a target grid no input epoch is off one.
          put_in(persisted, [:merge_report, :dropped_input_epochs], [
            %{
              source: 1,
              epoch_index: 0,
              epoch: hd(persisted.merge_report.provenance.cells).epoch,
              reason: :off_target_grid
            }
          ])
        ] do
      assert {:error, _reason} = Data.verify_merge_report(invalid)
    end
  end

  test "the shared schema 3 golden is the record this interface writes, and it verifies", %{golden: golden} do
    # The same record, in the layout every interface writes, is committed for
    # each interface's verifier.
    fixture = @report_golden_path |> File.read!() |> Jason.decode!()
    assert :ok = Data.verify_merge_report(fixture)

    summary_options = fixture_policy_opts(fixture["merge_policy"]) |> Keyword.put(:provenance, :summary)

    summary =
      fixture
      |> put_in(["merge_policy", "provenance"], "summary")
      |> put_in(["merge_report", "provenance", "mode"], "summary")
      |> put_in(["merge_report", "provenance", "cells"], [])
      |> rebind_fixture_policy(summary_options)

    assert :ok = Data.verify_merge_report(summary)

    absent_satellite =
      put_in(summary, ["merge_report", "provenance", "transitions", Access.at(0), "satellite"], "G02")

    assert {:error, _reason} = Data.verify_merge_report(absent_satellite)

    absent_aligned_epoch =
      update_in(
        summary,
        ["merge_report", "provenance", "transitions", Access.at(0), "epoch", "jd_whole"],
        &(&1 + 1)
      )

    assert {:error, _reason} = Data.verify_merge_report(absent_aligned_epoch)

    absent_coverage_span =
      update_in(summary, ["merge_report", "provenance", "coverage", Access.at(0)], fn coverage ->
        Enum.reduce(["first_epoch", "last_epoch"], coverage, fn key, acc ->
          update_in(acc, [key, "jd_whole"], &(&1 + 1))
        end)
      end)

    assert {:error, _reason} = Data.verify_merge_report(absent_coverage_span)

    off_grid_coverage_span =
      update_in(summary, ["merge_report", "provenance", "coverage", Access.at(0)], fn coverage ->
        Enum.reduce(["first_epoch", "last_epoch"], coverage, fn key, acc ->
          update_in(acc, [key, "jd_fraction"], &(&1 + 0.001))
        end)
      end)

    assert {:error, _reason} = Data.verify_merge_report(off_grid_coverage_span)

    for {orbit_class, core_class} <- [
          {"meo_gnss", :meo_gnss},
          {"geosynchronous", :geosynchronous},
          {"leo", :leo}
        ] do
      options =
        fixture_policy_opts(fixture["merge_policy"])
        |> Keyword.put(:verify_continuity, orbit_class: core_class, residual_tolerance_m: nil)
        |> Keyword.put(:provenance, :full)

      bound = Sidereon.NIF.sp3_orbit_class_speed_bound_m_s(orbit_class) |> elem(1)

      class_report =
        fixture
        |> update_in(["merge_policy", "verify_continuity", "orbit_class"], fn _ -> orbit_class end)
        |> update_in(
          ["merge_report", "continuity", "defects"],
          &Enum.map(&1, fn d -> rebind_speed_defect(d, bound) end)
        )
        |> update_in(
          ["merge_report", "continuity", "violations"],
          &Enum.map(&1, fn v ->
            %{v | "defect" => rebind_speed_defect(v["defect"], bound)}
          end)
        )
        |> rebind_fixture_policy(options)

      assert :ok = Data.verify_merge_report(class_report)
    end

    wrong_class_bound =
      fixture
      |> update_in(
        ["merge_report", "continuity", "defects"],
        &Enum.map(&1, fn d -> if d["kind"] == "speed_bound", do: %{d | "bound" => 1.0, "bound_m_s" => 1.0}, else: d end)
      )
      |> update_in(
        ["merge_report", "continuity", "violations"],
        &Enum.map(&1, fn v ->
          d = v["defect"]
          if d["kind"] == "speed_bound", do: %{v | "defect" => %{d | "bound" => 1.0, "bound_m_s" => 1.0}}, else: v
        end)
      )

    assert {:error, _reason} = Data.verify_merge_report(wrong_class_bound)

    esa = golden_artifact(golden["artifacts"]["esa"])
    opts = golden["complete_policy"] |> golden_policy_opts() |> Keyword.put(:combine, :mean)

    assert {:ok, identity} =
             SP3.merge_input_identity(
               [esa],
               opts ++ [verify_continuity: [orbit_class: :meo_gnss, residual_tolerance_m: nil], provenance: :full]
             )

    assert identity.stable_id == golden["expected"]["single_mean_esa"]
    url = "https://example.invalid/#{esa.official_filename}.gz"

    report = %Data.MergeReport{
      requested_centers: ["esa", "cod"],
      absent: [
        %Data.AbsentCenter{
          center: "cod",
          filename: "COD0MGXFIN_20261970000_01D_05M_ORB.SP3",
          pattern: "canonical",
          reason: "product_not_published",
          url: "https://example.invalid/COD0MGXFIN_20261970000_01D_05M_ORB.SP3.gz",
          http_status: 404
        }
      ],
      contributors: [
        %Data.Contributor{
          center: "esa",
          filename: esa.official_filename,
          date: ~D[2026-07-16],
          # A fetched final product carries no issue; its identity states the
          # catalog's "0000".
          issue: nil,
          pattern: "canonical",
          artifact_identity: struct!(Data.ArtifactIdentity, esa),
          acquisition: %Data.AcquisitionFacts{
            retrieved_at: "2026-07-16T12:00:00Z",
            cache_hit: false,
            original_url: url,
            final_url: url,
            # This binding's transport failure, which the record spells as
            # the shared vocabulary does.
            attempts: [
              %Distribution.SourceFailure{
                source: :direct,
                error_type: :transport,
                message: "transport:timeout",
                url: url,
                status: nil
              },
              # A failure no case describes keeps its inspected reason.
              %Distribution.SourceFailure{
                source: :direct,
                error_type: :unclassified_failure,
                message: "{:tls_alert, :bad_record_mac}",
                url: url,
                status: nil,
                detail: "{:tls_alert, :bad_record_mac}"
              }
            ]
          }
        }
      ],
      source_count: 1,
      single_product: true,
      merged: true,
      input_identity_schema_version: identity.schema_version,
      stable_input_identity: identity.stable_id,
      merge_policy: identity.merge_policy,
      merge_report: in_memory_merge_report(fixture["merge_report"])
    }

    written = report |> Data.merge_report_to_map() |> Jason.encode!() |> Jason.decode!()
    assert written == fixture
    assert :ok = Data.verify_merge_report(report)

    first_cell = hd(fixture["merge_report"]["agreement"]["cells"])

    first_epoch = %{
      "time_scale" => "GPST",
      "jd_whole" => first_cell["jd_whole"],
      "jd_fraction" => first_cell["jd_fraction"]
    }

    for mutation <- [
          # The record and the policy disagree about what was requested.
          &put_in(&1, ["merge_report", "provenance"], nil),
          &put_in(&1, ["merge_policy", "provenance"], "summary"),
          &put_in(&1, ["merge_report", "continuity"], nil),
          &put_in(&1, ["merge_policy", "verify_continuity", "orbit_class"], nil),
          # A residual tolerance is a distance.
          &put_in(&1, ["merge_policy", "verify_continuity", "residual_tolerance_m"], -1.0),
          # The provenance contradicts itself, the agreement or the policy.
          &put_in(&1, ["merge_report", "provenance", "cells", Access.at(0), "position"], %{
            "kind" => "combined",
            "rule" => "median",
            "members" => [0]
          }),
          &update_in(&1, ["merge_report", "provenance", "cells"], fn cells -> Enum.drop(cells, -1) end),
          &put_in(&1, ["merge_report", "provenance", "cells", Access.at(0), "epoch", "time_scale"], "UT1"),
          &put_in(&1, ["merge_report", "provenance", "coverage", Access.at(0), "cells_selected"], 1),
          &put_in(&1, ["merge_report", "provenance", "coverage", Access.at(0), "cells_contributed"], 1),
          &put_in(&1, ["merge_report", "provenance", "transitions", Access.at(0), "reason"], "whim"),
          &update_in(&1, ["merge_report", "provenance", "transitions"], fn [transition] ->
            [transition, %{transition | "from_source" => 0}]
          end),
          # The continuity record contradicts itself.
          &put_in(&1, ["merge_report", "continuity", "attested"], true),
          &put_in(&1, ["merge_report", "continuity", "splices"], [%{}]),
          &put_in(
            &1,
            ["merge_report", "continuity", "violations", Access.at(0), "cells", Access.at(0), "role"],
            "held_out"
          ),
          &update_in(&1, ["merge_report", "continuity", "violations", Access.at(0), "cells"], fn cells ->
            Enum.reverse(cells)
          end),
          &put_in(&1, ["merge_report", "continuity", "violations", Access.at(0), "from_sources"], []),
          &put_in(&1, ["merge_report", "continuity", "pairs_checked"], 0),
          # What the merge did not write contradicts what it wrote.
          &update_in(&1, ["merge_report", "omitted_epochs"], fn _ -> [first_epoch] end),
          &update_in(&1, ["merge_report", "arc_withheld"], fn _ ->
            [%{"satellite" => "G01", "epoch" => first_epoch, "sources" => [0]}]
          end),
          &update_in(&1, ["merge_report", "clock_omissions"], fn _ ->
            [
              %{
                "epoch" => first_epoch,
                "satellite" => "G01",
                "source" => 0,
                "reason" => "datum_not_observable",
                "preferred" => nil,
                "cell_has_clock" => true
              }
            ]
          end),
          &update_in(&1, ["merge_report", "clock_omissions"], fn _ ->
            [
              %{
                "epoch" => first_epoch,
                "satellite" => "G01",
                "source" => 0,
                "reason" => "preferred_source_without_clock",
                "preferred" => 0,
                "cell_has_clock" => true
              }
            ]
          end),
          &update_in(&1, ["merge_report", "clock_omissions"], fn _ ->
            [
              %{
                "epoch" => first_epoch,
                "satellite" => "G01",
                "source" => 0,
                "reason" => "no_consensus",
                "preferred" => nil,
                "cell_has_clock" => false
              }
            ]
          end),
          # The contributor names another issue than its identity's.
          &put_in(&1, ["contributors", Access.at(0), "issue"], "0600"),
          # A retrieval time not in the one form that restates it unchanged.
          &put_in(&1, ["contributors", Access.at(0), "acquisition_facts", "retrieved_at"], "2026-07-16T12:00:00Z"),
          # The shared layout is exact.
          &put_in(&1, ["merge_policy", "schema_version"], 1),
          &put_in(&1, ["contributors", Access.at(0), "acquisition_facts", "schema_version"], 2),
          &update_in(&1, ["contributors", Access.at(0)], fn contributor ->
            contributor |> Map.delete("acquisition_facts") |> Map.put("acquisition", contributor["acquisition_facts"])
          end),
          &update_in(&1, ["merge_policy"], fn policy ->
            policy |> Map.delete("target_epoch_interval_s") |> Map.put("epoch_interval_s", 900.0)
          end),
          &put_in(&1, ["merge_policy", "systems"], []),
          &update_in(&1, ["merge_report", "continuity"], fn continuity ->
            continuity |> Map.delete("attested") |> Map.put("attested?", false)
          end)
        ] do
      assert {:error, _reason} = Data.verify_merge_report(mutation.(fixture))
    end

    # The 900 s target grid leaves an input epoch at 00:05 off it.
    off_grid = %{first_epoch | "jd_fraction" => 1 / 288}
    dropped = %{"source" => 0, "epoch_index" => 1, "epoch" => off_grid, "reason" => "off_target_grid"}
    assert :ok = Data.verify_merge_report(put_in(fixture, ["merge_report", "dropped_input_epochs"], [dropped]))
  end

  test "a version 3 map verifies core withheld arcs, omissions and splices against its agreement", %{
    first: first,
    second: second
  } do
    # Source A carries epochs 0-71 and source B epochs 60-83 of the core's
    # merge-coverage fixture. Satellite-arc precedence omits B's epochs past
    # A's end and withholds and omits B's positions and clocks there; cell
    # precedence over a 0.8 m displacement of B splices across contributors.
    arc_opts = [
      combine: :precedence,
      precedence_scope: :satellite_arc,
      min_agree: 1,
      position_tolerance_m: 5.0,
      provenance: :full
    ]

    assert {:ok, _merged, arc_report} =
             SP3.merge([coverage_product(0, 72, 0.0), coverage_product(60, 24, 0.0)], arc_opts)

    arc = persisted_report([first, second], arc_opts, arc_report)
    assert :ok = Data.verify_merge_report(arc)
    assert :ok = arc |> Jason.encode!() |> Jason.decode!() |> Data.verify_merge_report()

    result = arc.merge_report
    assert length(result.omitted_epochs) == 12
    assert length(result.arc_withheld) == 6 * 12
    assert length(result.clock_omissions) == 6 * 12
    assert length(result.provenance.cells) == length(result.agreement.cells)

    accepted = hd(result.agreement.cells)

    accepted_epoch = %{
      time_scale: hd(result.omitted_epochs).time_scale,
      jd_whole: accepted.jd_whole,
      jd_fraction: accepted.jd_fraction
    }

    for mutation <- [
          # A withheld position is one the product does not hold.
          &update_in(&1, [:merge_report, :arc_withheld, Access.at(0)], fn cell ->
            %{cell | epoch: accepted_epoch, satellite: accepted.satellite}
          end),
          # An omitted epoch holds no accepted cell, and they are in time order.
          &put_in(&1, [:merge_report, :omitted_epochs, Access.at(0)], accepted_epoch),
          &update_in(&1, [:merge_report, :omitted_epochs], fn epochs -> Enum.reverse(epochs) end),
          # Source 0 is the clock datum, and an omitted epoch's cells hold no clock.
          &put_in(&1, [:merge_report, :clock_omissions, Access.at(0), :source], 0),
          &put_in(&1, [:merge_report, :clock_omissions, Access.at(0), :cell_has_clock], true),
          &update_in(&1, [:merge_report, :clock_omissions], fn omissions -> Enum.reverse(omissions) end),
          # The full provenance of an accepted cell names its writer.
          &put_in(&1, [:merge_report, :provenance, :cells, Access.at(0), :position], %{
            kind: :single_source,
            source: 1
          })
        ] do
      assert {:error, _reason} = Data.verify_merge_report(mutation.(arc))
    end

    # Cell precedence always prefers a source that carries the cell.
    cell_opts = Keyword.put(arc_opts, :precedence_scope, :cell)
    assert {:error, _reason} = Data.verify_merge_report(persisted_report([first, second], cell_opts, arc_report))

    splice_opts = [
      combine: :precedence,
      precedence_scope: :cell,
      min_agree: 1,
      position_tolerance_m: 5.0,
      verify_continuity: true,
      provenance: :summary
    ]

    assert {:ok, _merged, splice_report} =
             SP3.merge([coverage_product(0, 72, 0.0), coverage_product(60, 24, 0.8)], splice_opts)

    splice = persisted_report([first, second], splice_opts, splice_report)
    assert :ok = Data.verify_merge_report(splice)
    assert :ok = splice |> Jason.encode!() |> Jason.decode!() |> Data.verify_merge_report()

    continuity = splice.merge_report.continuity
    refute continuity.attested
    assert [first_splice | _] = continuity.splices
    assert splice.merge_report.provenance.cells == []
    index = Enum.find_index(continuity.violations, &(&1 == first_splice))

    for mutation <- [
          &put_in(&1, [:merge_report, :continuity, :violations, Access.at(index), :crosses_contributors], false),
          &update_in(&1, [:merge_report, :continuity, :violations, Access.at(index), :cells], fn cells ->
            Enum.drop(cells, -1)
          end),
          &put_in(&1, [:merge_report, :continuity, :violations, Access.at(index), :sources], [1]),
          &put_in(
            &1,
            [:merge_report, :continuity, :violations, Access.at(index), :cells, Access.at(0), :role],
            :pair_end
          ),
          &update_in(&1, [:merge_report, :continuity, :splices], fn splices -> Enum.drop(splices, -1) end),
          &update_in(&1, [:merge_report, :continuity, :violations], fn violations -> Enum.drop(violations, -1) end),
          &update_in(&1, [:merge_report, :continuity, :defects, Access.at(0), :magnitude], fn magnitude ->
            magnitude * 2.0
          end),
          &put_in(&1, [:merge_report, :provenance, :cells], arc.merge_report.provenance.cells)
        ] do
      assert {:error, _reason} = Data.verify_merge_report(mutation.(splice))
    end
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
      put_in(nested, [:contributors, Access.at(0), :acquisition_facts, :attempts], [
        %{
          source: :direct,
          error_type: "transport_failure",
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
            reason: "no_candidate",
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

    # A schema 3 record spells each failure and absence one way; a schema 2
    # record may carry the spellings this binding wrote before.
    attempt_path = [:contributors, Access.at(0), :acquisition_facts, :attempts, Access.at(0)]
    absent_path = [:absent, Access.at(0)]
    legacy_attempt = put_in(with_attempt, attempt_path ++ [:error_type], "transport")
    assert {:error, _reason} = Data.verify_merge_report(legacy_attempt)

    assert :ok =
             legacy_attempt
             |> legacy_layout()
             |> Map.put(:schema_version, 2)
             |> Map.update!(:merge_report, &Map.drop(&1, [:continuity, :provenance]))
             |> Data.verify_merge_report()

    named_absence = %{
      center: "igs_ult",
      filename: "IGS0OPSULT_20260710000_02D_15M_ORB.SP3",
      pattern: "primary_02D_15M",
      reason: "http_status",
      url: "https://example.invalid/IGS0OPSULT_20260710000_02D_15M_ORB.SP3.gz",
      http_status: 503
    }

    assert :ok = Data.verify_merge_report(put_in(with_absent, absent_path, named_absence))

    # A schema 2 absence may carry a spelling written before the shared
    # vocabulary, and no other.
    legacy_absent =
      with_absent
      |> legacy_layout()
      |> Map.put(:schema_version, 2)
      |> Map.update!(:merge_report, &Map.drop(&1, [:continuity, :provenance]))

    legacy_named = %{named_absence | reason: "http_status:503"}
    assert :ok = Data.verify_merge_report(put_in(legacy_absent, absent_path, legacy_named))

    assert {:error, _reason} =
             Data.verify_merge_report(put_in(legacy_absent, absent_path, %{legacy_named | reason: "http_status:0503"}))

    assert {:error, _reason} =
             Data.verify_merge_report(put_in(legacy_absent, absent_path ++ [:reason], "not published"))

    # A failure no other case describes is recorded, losslessly, as
    # unclassified with its raw text; the detail exists for it alone.
    unclassified_attempt =
      update_in(
        with_attempt,
        attempt_path,
        &Map.merge(&1, %{error_type: "unclassified_failure", detail: "{:tls_alert, :bad_record_mac}"})
      )

    unclassified_absence = %{named_absence | reason: "unclassified", http_status: nil} |> Map.put(:detail, "{:eof, 0}")
    assert :ok = Data.verify_merge_report(unclassified_attempt)
    assert :ok = Data.verify_merge_report(put_in(with_absent, absent_path, unclassified_absence))

    for invalid <- [
          update_in(unclassified_attempt, attempt_path, &Map.delete(&1, :detail)),
          put_in(unclassified_attempt, attempt_path ++ [:detail], ""),
          put_in(with_attempt, attempt_path ++ [:detail], "transport:timeout"),
          put_in(with_absent, absent_path, Map.delete(unclassified_absence, :detail)),
          put_in(with_absent, absent_path, %{unclassified_absence | filename: nil, pattern: nil, url: nil}),
          put_in(with_absent, absent_path, Map.put(named_absence, :detail, "{:eof, 0}")),
          # Neither exists before schema 3.
          unclassified_attempt
          |> legacy_layout()
          |> Map.put(:schema_version, 2)
          |> Map.update!(:merge_report, &Map.drop(&1, [:continuity, :provenance])),
          put_in(legacy_absent, absent_path, unclassified_absence)
        ] do
      assert {:error, _reason} = Data.verify_merge_report(invalid)
    end

    for invalid <- [
          put_in(with_attempt, attempt_path ++ [:error_type], "whim"),
          put_in(with_attempt, attempt_path ++ [:error_type], "http_status"),
          put_in(with_absent, absent_path ++ [:reason], "candidate_not_found"),
          put_in(with_absent, absent_path ++ [:reason], "offline_cache_miss"),
          put_in(with_absent, absent_path, %{named_absence | http_status: nil}),
          put_in(with_absent, absent_path, %{named_absence | url: nil}),
          put_in(with_absent, absent_path, %{named_absence | reason: "no_candidate"})
        ] do
      assert {:error, _reason} = Data.verify_merge_report(invalid)
    end

    nil_key_mutations = [
      Map.put(persisted, nil, "unknown"),
      update_in(persisted, [:contributors, Access.at(0)], &Map.put(&1, nil, "unknown")),
      update_in(persisted, [:contributors, Access.at(0), :artifact_identity], &Map.put(&1, nil, "unknown")),
      update_in(
        persisted,
        [:contributors, Access.at(0), :artifact_identity, :requested_identity],
        &Map.put(&1, nil, "unknown")
      ),
      update_in(persisted, [:contributors, Access.at(0), :acquisition_facts], &Map.put(&1, nil, "unknown")),
      update_in(persisted, [:merge_policy], &Map.put(&1, nil, "unknown")),
      update_in(nested, [:merge_policy, :outlier_reject], &Map.put(&1, nil, "unknown")),
      update_in(persisted, [:merge_report], &Map.put(&1, nil, "unknown")),
      update_in(persisted, [:merge_report, :single_source, Access.at(0)], &Map.put(&1, nil, "unknown")),
      update_in(persisted, [:merge_report, :agreement], &Map.put(&1, nil, "unknown")),
      update_in(persisted, [:merge_report, :agreement, :cells, Access.at(0)], &Map.put(&1, nil, "unknown")),
      update_in(persisted, [:merge_report, :agreement, :epochs, Access.at(0)], &Map.put(&1, nil, "unknown")),
      update_in(nested, [:merge_report, :frame_reconciliations, Access.at(0)], &Map.put(&1, nil, "unknown")),
      update_in(with_attempt, [:contributors, Access.at(0), :acquisition_facts, :attempts, Access.at(0)], fn attempt ->
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
      update_in(persisted, [:contributors, Access.at(0)], &Map.put(&1, "issue", &1.issue)),
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

    # A clock-only record gives a clock without a position, so a cell's clock can
    # have more contributors than its position: here the second source gives G02
    # only a clock.
    clock_record_contributor =
      persisted
      |> put_in([:merge_report, :agreement, :cells, Access.at(1), :clock_members], 2)
      |> put_in([:merge_report, :agreement, :clock_rms_s], :math.sqrt(5.0e-19))
      |> put_in([:merge_report, :agreement, :epochs, Access.at(0), :clock_rms_s], :math.sqrt(5.0e-19))

    assert :ok = Data.verify_merge_report(clock_record_contributor)

    # A cell with an accepted clock and no accepted position is written as a
    # clock-only record, with no position members or metrics; its single-source
    # flag names the one clock. A quarantined position leaves such a cell.
    clock_only =
      persisted
      |> put_in([:merge_report, :agreement, :cells, Access.at(1), :position_members], 0)
      |> put_in([:merge_report, :agreement, :cells, Access.at(1), :position_rms_m], nil)
      |> put_in([:merge_report, :agreement, :cells, Access.at(1), :position_max_m], nil)

    assert :ok = Data.verify_merge_report(clock_only)

    g02_quarantined = [%{satellite: "G02", jd_whole: 2_460_000.5, jd_fraction: 0.5, sources: [0, 1]}]

    assert :ok = clock_only |> put_in([:merge_report, :quarantined], g02_quarantined) |> Data.verify_merge_report()

    assert {:error, :unexplained_single_member_cell} =
             clock_only |> put_in([:merge_report, :single_source], []) |> Data.verify_merge_report()

    assert {:error, {:invalid_field, {{:agreement_cell, 1}, :position_metrics}}} =
             clock_only
             |> put_in([:merge_report, :agreement, :cells, Access.at(1), :position_rms_m], 0.0)
             |> Data.verify_merge_report()

    # A quarantined position is never also written.
    assert {:error, :contradictory_quarantined_flags} =
             persisted |> put_in([:merge_report, :quarantined], g02_quarantined) |> Data.verify_merge_report()

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
          position_rms_m: nil,
          position_max_m: nil,
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

    # The shared satellite-token range: `01`..`99` for every constellation,
    # including the extended slots real products carry (R28, G34, S19).
    Enum.each(~w(G01 G32 G33 G99 R27 R28 E36 E37 C63 C64 J09 J10 I14 I15 S01 S19 S20 S58 S59 S99), fn satellite ->
      boundary =
        persisted
        |> put_in([:merge_report, :single_source, Access.at(0), :satellite], satellite)
        |> put_in([:merge_report, :agreement, :cells, Access.at(0), :satellite], satellite)

      assert :ok = Data.verify_merge_report(boundary)
    end)

    Enum.each(~w(G00 R00 S00 G100 G999 L01 G1), fn satellite ->
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

  test "catalog inputs reject explicit empty sample and issue instead of defaulting", %{first: first} do
    {:ok, valid_cod} = Data.mgex_sp3(:cod, ~D[2026-07-12])
    assert is_nil(valid_cod.issue)
    assert is_binary(valid_cod.sample) and byte_size(valid_cod.sample) > 0

    # Public Product struct: nil issue succeeds; explicit empty issue or sample fails
    assert {:ok, cod_identity} = Distribution.identity(valid_cod)
    assert {:ok, ^cod_identity} = Data.identity(valid_cod)
    assert {:ok, cod_filename} = Data.canonical_filename(valid_cod)
    assert {:ok, cod_url} = Data.archive_url(valid_cod)

    empty_issue_product = %{valid_cod | issue: ""}
    assert {:error, _reason} = Distribution.identity(empty_issue_product)
    assert {:error, _reason} = Data.identity(empty_issue_product)
    assert {:error, _reason} = Data.canonical_filename(empty_issue_product)
    assert {:error, _reason} = Data.archive_url(empty_issue_product)

    empty_sample_product = %{valid_cod | sample: "", issue: nil}
    assert {:error, _reason} = Distribution.identity(empty_sample_product)
    assert {:error, _reason} = Data.identity(empty_sample_product)
    assert {:error, _reason} = Data.canonical_filename(empty_sample_product)
    assert {:error, _reason} = Data.archive_url(empty_sample_product)

    # Direct NIF validation across identity, filename, and archive URL
    assert {:ok, _fields} =
             Sidereon.NIF.data_product_identity("cod", "sp3", 2026, 7, 12, valid_cod.sample, nil)

    assert {:error, _reason} =
             Sidereon.NIF.data_product_identity("cod", "sp3", 2026, 7, 12, valid_cod.sample, "")

    assert {:error, _reason} =
             Sidereon.NIF.data_product_identity("cod", "sp3", 2026, 7, 12, "", nil)

    assert {:ok, ^cod_filename} =
             Sidereon.NIF.data_canonical_filename("cod", "sp3", 2026, 7, 12, valid_cod.sample, nil)

    assert {:error, _reason} =
             Sidereon.NIF.data_canonical_filename("cod", "sp3", 2026, 7, 12, valid_cod.sample, "")

    assert {:error, _reason} =
             Sidereon.NIF.data_canonical_filename("cod", "sp3", 2026, 7, 12, "", nil)

    assert {:ok, ^cod_url} =
             Sidereon.NIF.data_archive_url("cod", "sp3", 2026, 7, 12, valid_cod.sample, nil)

    assert {:error, _reason} =
             Sidereon.NIF.data_archive_url("cod", "sp3", 2026, 7, 12, valid_cod.sample, "")

    assert {:error, _reason} =
             Sidereon.NIF.data_archive_url("cod", "sp3", 2026, 7, 12, "", nil)

    # Direct data_sp3_content_start_convention and data_supported_samples
    assert {:ok, _convention} =
             Sidereon.NIF.data_sp3_content_start_convention("cod", 2026, 7, 12, nil)

    assert {:error, _reason} =
             Sidereon.NIF.data_sp3_content_start_convention("cod", 2026, 7, 12, "")

    assert {:ok, _samples} =
             Sidereon.NIF.data_supported_samples("cod", "sp3", 2026, 7, 12, nil)

    assert {:error, _reason} =
             Sidereon.NIF.data_supported_samples("cod", "sp3", 2026, 7, 12, "")

    # For an issued center, nil issue selects 0000; empty issue fails syntax validation
    assert {:ok, ["15M", "05M"]} =
             Sidereon.NIF.data_supported_samples("gfz_ult", "sp3", 2021, 5, 15, nil)

    assert {:error, _reason} =
             Sidereon.NIF.data_supported_samples("gfz_ult", "sp3", 2021, 5, 15, "")

    assert {:ok, ["15M", "05M"]} =
             Data.supported_samples(:gfz_ult, :sp3, ~D[2021-05-15])

    assert {:error, _reason} =
             Data.supported_samples(:gfz_ult, :sp3, ~D[2021-05-15], "")

    # Direct predicted IONEX candidate call
    assert {:ok, ionex_candidates} =
             Sidereon.NIF.data_predicted_ionex_line_candidates(2026, 7, 12, nil)

    assert is_list(ionex_candidates) and ionex_candidates != []

    assert {:error, _reason} =
             Sidereon.NIF.data_predicted_ionex_line_candidates(2026, 7, 12, "")

    # Public predicted IONEX line candidates
    assert {:ok, _candidates} = Data.predicted_ionex_line_candidates(~D[2026-07-12])
    assert {:error, _reason} = Data.predicted_ionex_line_candidates(~D[2026-07-12], sample: "")

    # Valid persisted COD report with identity issue 0000 verifies
    persisted = persisted_report([first], [], empty_merge_report())
    assert :ok = Data.verify_merge_report(persisted)

    # Nil contributor representation remains supported
    nil_contributor = put_in(persisted, [:contributors, Access.at(0), :issue], nil)
    assert :ok = Data.verify_merge_report(nil_contributor)

    # Isolated 0600 and empty contributor issue mutations fail
    mutation_0600 = put_in(persisted, [:contributors, Access.at(0), :issue], "0600")
    assert {:error, _reason} = Data.verify_merge_report(mutation_0600)

    mutation_empty = put_in(persisted, [:contributors, Access.at(0), :issue], "")
    assert {:error, _reason} = Data.verify_merge_report(mutation_empty)
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
    source = Map.get(artifact, "distribution_source") || Map.get(artifact, :distribution_source)
    compression = Map.get(artifact, "compression") || Map.get(artifact, :compression)

    %{
      requested_identity:
        golden_product_identity(Map.get(artifact, "requested_identity") || Map.get(artifact, :requested_identity)),
      resolved_identity:
        golden_product_identity(Map.get(artifact, "resolved_identity") || Map.get(artifact, :resolved_identity)),
      distribution_source: if(is_binary(source), do: String.to_existing_atom(source), else: source),
      official_filename: Map.get(artifact, "official_filename") || Map.get(artifact, :official_filename),
      product_sha256: Map.get(artifact, "product_sha256") || Map.get(artifact, :product_sha256),
      product_byte_length: Map.get(artifact, "product_byte_length") || Map.get(artifact, :product_byte_length),
      archive_sha256: Map.get(artifact, "archive_sha256") || Map.get(artifact, :archive_sha256),
      archive_byte_length: Map.get(artifact, "archive_byte_length") || Map.get(artifact, :archive_byte_length),
      compression: if(is_binary(compression), do: String.to_existing_atom(compression), else: compression)
    }
  end

  defp golden_product_identity(identity) do
    date_val = Map.get(identity, "date") || Map.get(identity, :date)

    date =
      case date_val do
        %Date{} = d -> d
        bin when is_binary(bin) -> Date.from_iso8601!(bin)
      end

    %Distribution.ProductIdentity{
      family: Map.get(identity, "family") || Map.get(identity, :family),
      analysis_center: Map.get(identity, "analysis_center") || Map.get(identity, :analysis_center),
      publisher: Map.get(identity, "publisher") || Map.get(identity, :publisher),
      solution_class:
        Map.get(identity, "solution_class") || Map.get(identity, :solution_class) ||
          Map.get(identity, "solution") || Map.get(identity, :solution),
      campaign: Map.get(identity, "campaign") || Map.get(identity, :campaign),
      filename_version:
        Map.get(identity, "filename_version") || Map.get(identity, :filename_version) ||
          Map.get(identity, "version") || Map.get(identity, :version),
      date: date,
      issue: Map.get(identity, "issue") || Map.get(identity, :issue),
      span: Map.get(identity, "span") || Map.get(identity, :span),
      sample: Map.get(identity, "sample") || Map.get(identity, :sample),
      official_filename: Map.get(identity, "official_filename") || Map.get(identity, :official_filename),
      format: Map.get(identity, "format") || Map.get(identity, :format),
      format_version: Map.get(identity, "format_version") || Map.get(identity, :format_version),
      prediction_horizon_days:
        Map.get(identity, "prediction_horizon_days") || Map.get(identity, :prediction_horizon_days)
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

  defp fixture_policy_opts(policy) do
    [
      position_tolerance_m: policy["position_tolerance_m"],
      clock_tolerance_s: policy["clock_tolerance_s"],
      min_agree: policy["min_agree"],
      clock_min_common: policy["clock_min_common"],
      combine: String.to_existing_atom(policy["combine"]),
      precedence_scope: String.to_existing_atom(policy["precedence_scope"]),
      outlier_reject: %{
        position_tolerance_m: policy["outlier_reject"]["position_tolerance_m"],
        clock_tolerance_s: policy["outlier_reject"]["clock_tolerance_s"]
      },
      epoch_interval_s: policy["target_epoch_interval_s"],
      systems: policy["systems"],
      asserted_frame_label_sets: policy["asserted_frame_label_sets"],
      helmert: policy["helmert"],
      verify_continuity: [
        orbit_class: String.to_existing_atom(policy["verify_continuity"]["orbit_class"]),
        residual_tolerance_m: policy["verify_continuity"]["residual_tolerance_m"],
        gap_threshold_factor: policy["verify_continuity"]["gap_threshold_factor"]
      ],
      provenance: String.to_existing_atom(policy["provenance"])
    ]
  end

  defp rebind_speed_defect(%{"kind" => "speed_bound"} = defect, bound) do
    displacement = (bound + 1.0) * defect["interval_s"]
    speed = displacement / defect["interval_s"]

    %{
      defect
      | "displacement_m" => displacement,
        "implied_speed_m_s" => speed,
        "magnitude" => speed,
        "bound" => bound,
        "bound_m_s" => bound
    }
  end

  defp rebind_speed_defect(defect, _bound), do: defect

  defp rebind_fixture_policy(fixture, opts) do
    artifacts =
      fixture["contributors"]
      |> Enum.map(&golden_artifact(&1["artifact_identity"]))

    assert {:ok, identity} = SP3.merge_input_identity(artifacts, opts)

    policy =
      %{
        schema_version: 2,
        position_tolerance_m: identity.merge_policy.position_tolerance_m,
        clock_tolerance_s: identity.merge_policy.clock_tolerance_s,
        min_agree: identity.merge_policy.min_agree,
        clock_min_common: identity.merge_policy.clock_min_common,
        combine: identity.merge_policy.combine,
        precedence_scope: identity.merge_policy.precedence_scope,
        outlier_reject: identity.merge_policy.outlier_reject,
        target_epoch_interval_s: identity.merge_policy.epoch_interval_s,
        systems: if(identity.merge_policy.systems != [], do: identity.merge_policy.systems),
        asserted_frame_label_sets: identity.merge_policy.asserted_frame_label_sets,
        helmert: identity.merge_policy.helmert,
        precedence_artifact_sha256: identity.merge_policy.precedence_artifact_sha256 || [],
        verify_continuity: identity.merge_policy.verify_continuity,
        provenance: identity.merge_policy.provenance
      }
      |> Jason.encode!()
      |> Jason.decode!()

    fixture
    |> Map.put("input_identity_schema_version", identity.schema_version)
    |> Map.put("stable_input_identity", identity.stable_id)
    |> Map.put("merge_policy", policy)
  end

  # A merge report as `SP3.merge/2` returns it, from its shared record: atom
  # keys, and the continuity attestation under `:attested?`.
  defp in_memory_merge_report(record) do
    record
    |> atomize_keys()
    |> Map.update!(:continuity, fn continuity ->
      continuity |> Map.delete(:attested) |> Map.put(:attested?, continuity.attested)
    end)
  end

  defp atomize_keys(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {String.to_atom(key), atomize_keys(value)} end)

  defp atomize_keys(list) when is_list(list), do: Enum.map(list, &atomize_keys/1)
  defp atomize_keys(value), do: value

  # Six GPS satellites on circular trajectories on a 300 s grid from 2020-06-25
  # 00:00, the core's merge-coverage fixture: `first` and `count` pick the
  # epochs in 300 s steps from 00:00, and `offset_m` displaces X.
  defp coverage_product(first, count, offset_m) do
    padded = fn integer, width -> String.pad_leading(Integer.to_string(integer), width) end

    fixed = fn value, decimals, width ->
      String.pad_leading(:erlang.float_to_binary(value, decimals: decimals), width)
    end

    epoch_fields = fn index ->
      "2020  6 25 #{padded.(div(index, 12), 2)}#{padded.(rem(index, 12) * 5, 3)}  0.00000000"
    end

    header = [
      "#cP#{epoch_fields.(first)}     #{padded.(count, 3)} ORBIT IGS14 FIT  TST",
      "## 2111 #{fixed.(345_600.0 + first * 300, 8, 14)}   300.00000000 59025 #{fixed.(first * 300 / 86_400, 13, 0)}",
      "+    6   G01G02G03G04G05G06  0  0  0  0  0  0  0  0  0  0  0",
      "++         0  0  0  0  0  0  0  0  0  0  0  0  0  0  0  0  0",
      "%c G  cc GPS ccc cccc cccc cccc cccc ccccc ccccc ccccc ccccc",
      "%c cc cc ccc ccc cccc cccc cccc cccc ccccc ccccc ccccc ccccc",
      "%f  1.2500000  1.025000000  0.00000000000  0.000000000000000",
      "%f  0.0000000  0.000000000  0.00000000000  0.000000000000000",
      "%i    0    0    0    0      0      0      0      0         0",
      "%i    0    0    0    0      0      0      0      0         0",
      "/* SYNTHETIC SP3 COVERAGE FIXTURE"
    ]

    records =
      Enum.flat_map(first..(first + count - 1)//1, fn index ->
        seconds = index * 300.0

        ["*  " <> epoch_fields.(index)] ++
          Enum.map(1..6, fn prn ->
            angle = seconds * 2.0 * :math.pi() / 43_200.0 + prn * 0.3

            "PG0#{prn}" <>
              Enum.map_join(
                [
                  26_560.0 * :math.cos(angle) + offset_m / 1000.0,
                  26_560.0 * :math.sin(angle) * 0.6,
                  26_560.0 * :math.sin(angle) * 0.8,
                  10.0 + prn
                ],
                &fixed.(&1, 6, 14)
              )
          end)
      end)

    {:ok, sp3} = SP3.parse(Enum.join(header ++ records ++ ["EOF", ""], "\n"))
    sp3
  end

  # G01 alone at one 900 s epoch of 2020-06-25, at `x_km` in X.
  defp g01_sp3(minute, x_km) do
    seconds_of_week = if minute == " 0", do: "432000.00000000", else: "432900.00000000"
    x_field = String.pad_leading(:erlang.float_to_binary(x_km, decimals: 6), 14)

    text =
      Enum.join(
        [
          "#cP2020  6 25  0 #{minute}  0.00000000       1 ORBIT IGS14 FIT  TST",
          "## 2111 #{seconds_of_week}   900.00000000 59025 0.0000000000000",
          "+    1   G01  0  0  0  0  0  0  0  0  0  0  0  0  0  0  0  0",
          "++         0  0  0  0  0  0  0  0  0  0  0  0  0  0  0  0  0",
          "%c G  cc GPS ccc cccc cccc cccc cccc ccccc ccccc ccccc ccccc",
          "%c cc cc ccc ccc cccc cccc cccc cccc ccccc ccccc ccccc ccccc",
          "%f  1.2500000  1.025000000  0.00000000000  0.000000000000000",
          "%f  0.0000000  0.000000000  0.00000000000  0.000000000000000",
          "%i    0    0    0    0      0      0      0      0         0",
          "%i    0    0    0    0      0      0      0      0         0",
          "/* TEST SP3-c FIXTURE",
          "*  2020  6 25  0 #{minute}  0.00000000",
          "PG01#{x_field} -20000.000000   5000.000000    100.000000",
          "EOF",
          ""
        ],
        "\n"
      )

    {:ok, product} = SP3.parse(text)
    product
  end

  # The layout schema 1 and 2 records carry: the acquisition facts under
  # `acquisition`, neither record versioned, and the merge policy's own keys.
  defp legacy_layout(persisted) do
    persisted
    |> Map.update!(:contributors, fn contributors ->
      Enum.map(contributors, fn contributor ->
        contributor
        |> Map.delete(:acquisition_facts)
        |> Map.put(:acquisition, Map.delete(contributor.acquisition_facts, :schema_version))
        |> Map.update!(:artifact_identity, &Map.delete(&1, :schema_version))
      end)
    end)
    |> Map.update!(:merge_policy, fn policy ->
      policy
      |> Map.drop([:schema_version, :target_epoch_interval_s, :verify_continuity, :provenance])
      |> Map.merge(%{
        epoch_interval_s: policy.target_epoch_interval_s,
        systems: policy.systems || [],
        precedence_artifact_sha256: if(policy.combine == "precedence", do: policy.precedence_artifact_sha256)
      })
    end)
  end

  defp empty_merge_report do
    %{
      frame_reconciliations: [],
      quarantined: [],
      single_source: [],
      position_outliers: [],
      clock_outliers: [],
      dropped_input_epochs: [],
      omitted_epochs: [],
      arc_withheld: [],
      clock_omissions: [],
      continuity: nil,
      provenance: nil,
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
      dropped_input_epochs: [],
      omitted_epochs: [],
      arc_withheld: [],
      clock_omissions: [],
      continuity: nil,
      provenance: nil,
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
      dropped_input_epochs: [],
      omitted_epochs: [],
      arc_withheld: [],
      clock_omissions: [],
      continuity: nil,
      provenance: nil,
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
            position_rms_m: nil,
            position_max_m: nil,
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
          position_rms_m: nil,
          position_max_m: nil,
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
      dropped_input_epochs: [],
      omitted_epochs: [],
      arc_withheld: [],
      clock_omissions: [],
      continuity: nil,
      provenance: nil,
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
