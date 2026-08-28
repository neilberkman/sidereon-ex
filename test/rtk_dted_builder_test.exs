defmodule Sidereon.RtkDtedBuilderTest do
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.RINEX.Observations, as: RinexObservations
  alias Sidereon.GNSS.RTK
  alias Sidereon.GNSS.RTK.{DualFrequencyRinexArc, IonosphereFreeArcSolution, RinexArc}
  alias Sidereon.GNSS.SP3
  alias Sidereon.Terrain.MmapTerrain
  alias Sidereon.Terrain.MmapTerrain.{DtedTileListEntry, TerrainStoreError, TerrainTileId}

  @sp3_path Path.join(__DIR__, "fixtures/sp3/GBM0MGXRAP_20201770000_01D_05M_ORB_120epoch.sp3")
  @base_obs_path Path.join(__DIR__, "fixtures/obs/WTZR00DEU_R_20201770000_01D_30S_MO_120epoch.rnx")
  @rover_obs_path Path.join(__DIR__, "fixtures/obs/WTZZ00DEU_R_20201770000_01D_30S_MO_120epoch.rnx")
  @dted_root Path.join(__DIR__, "fixtures/dted/tiles")
  @c 299_792_458.0
  @f_l1 1_575_420_000.0
  @f_l2 1_227_600_000.0
  @max_native_usize Integer.pow(2, :erlang.system_info(:wordsize) * 8) - 1

  setup_all do
    {:ok,
     sp3: SP3.load!(@sp3_path),
     base_obs: RinexObservations.load!(@base_obs_path),
     rover_obs: RinexObservations.load!(@rover_obs_path)}
  end

  test "single-frequency builder retains ordered observations, scales, and skip count", context do
    assert {:ok, %RinexArc{} = arc} =
             RTK.build_rinex_rtk_arc(context.sp3, context.base_obs, context.rover_obs, max_epochs: 2)

    assert RinexArc.epoch_count(arc) == 2
    assert RinexArc.skipped_epoch_count(arc) == 0

    [first | _] = RinexArc.epochs(arc)
    satellite_ids = Enum.map(first.base, & &1.satellite_id)

    assert satellite_ids == Enum.sort(satellite_ids)
    assert satellite_ids == Enum.map(first.rover, & &1.satellite_id)
    assert Enum.all?(first.base, &is_float(&1.code_m))
    assert Enum.all?(first.base, &is_float(&1.phase_m))
    assert Enum.all?(first.base, &(&1.ambiguity_id == &1.satellite_id))
    assert is_float(first.prediction_time_s)

    wavelengths = RinexArc.wavelengths_m(arc)
    offsets = RinexArc.offsets_m(arc)
    assert Map.keys(wavelengths) == Enum.sort(satellite_ids)
    assert Map.keys(offsets) == Map.keys(wavelengths)
    assert Enum.all?(wavelengths, fn {_id, value} -> abs(value - @c / @f_l1) < 1.0e-15 end)
    assert Enum.all?(offsets, fn {_id, value} -> value == 0.0 end)
    assert RinexArc.wavelength_pairs(arc) == Enum.sort_by(wavelengths, &elem(&1, 0))
  end

  test "dual-frequency builder retains paired records and frequency metadata", context do
    assert {:ok, %DualFrequencyRinexArc{} = arc} =
             RTK.build_dual_frequency_rinex_rtk_arc(
               context.sp3,
               context.base_obs,
               context.rover_obs,
               max_epochs: 2
             )

    assert DualFrequencyRinexArc.epoch_count(arc) == 2
    assert DualFrequencyRinexArc.skipped_epoch_count(arc) == 0

    [first | _] = DualFrequencyRinexArc.epochs(arc)
    satellite_ids = Enum.map(first.observations, & &1.satellite_id)
    assert satellite_ids == Enum.sort(satellite_ids)

    assert Enum.all?(first.observations, fn observation ->
             Map.get(observation.base, :satellite_id) == nil and
               Map.get(observation.rover, :satellite_id) == nil and
               observation.base.ambiguity_id == observation.satellite_id and
               observation.rover.ambiguity_id == observation.satellite_id and
               abs(observation.base.f1_hz - @f_l1) < 1.0 and
               abs(observation.base.f2_hz - @f_l2) < 1.0 and
               is_float(observation.base.p1_m) and
               is_float(observation.base.phi1_cycles)
           end)

    assert is_float(first.jd_whole)
    assert is_float(first.jd_fraction)
    assert is_binary(first.epoch_sort_key)
    assert is_float(first.gap_time_s)

    [baseline_epoch | _] = DualFrequencyRinexArc.baseline_epochs(arc)
    assert is_number(baseline_epoch.epoch)
    assert baseline_epoch.jd_whole == first.jd_whole
    assert baseline_epoch.jd_fraction == first.jd_fraction
    assert Enum.map(baseline_epoch.base_observations, & &1.satellite_id) == satellite_ids
    assert Enum.all?(baseline_epoch.base_observations, &Map.has_key?(&1, :phi1_cyc))
    refute Enum.any?(baseline_epoch.base_observations, &Map.has_key?(&1, :phi1_cycles))
  end

  test "dual-frequency baseline epoch contract documents split Julian metadata" do
    assert {:ok, types} = Code.Typespec.fetch_types(RTK)

    assert {:type, {:dual_frequency_baseline_epoch, {:type, _, :map, fields}, []}} =
             Enum.find(types, fn
               {:type, {:dual_frequency_baseline_epoch, _, _}} -> true
               _ -> false
             end)

    assert {:type, _, :map_field_assoc, [{:atom, _, :jd_whole}, {:type, _, :number, []}]} =
             Enum.find(fields, fn
               {:type, _, _, [{:atom, _, :jd_whole}, _]} -> true
               _ -> false
             end)

    assert {:type, _, :map_field_assoc, [{:atom, _, :jd_fraction}, {:type, _, :number, []}]} =
             Enum.find(fields, fn
               {:type, _, _, [{:atom, _, :jd_fraction}, _]} -> true
               _ -> false
             end)

    assert {:docs_v1, _, _, _, _, _, docs} = Code.fetch_docs(RTK)

    assert {{:type, :dual_frequency_baseline_epoch, 0}, _, _, %{"en" => typedoc}, _} =
             Enum.find(docs, fn
               {{:type, :dual_frequency_baseline_epoch, 0}, _, _, _, _} -> true
               _ -> false
             end)

    assert typedoc =~ ":jd_whole"
    assert typedoc =~ ":jd_fraction"
    assert typedoc =~ "civil `:epoch`"
  end

  test "dual-frequency arc split-JD metadata reaches troposphere preparation", context do
    assert {:ok, arc} =
             RTK.build_dual_frequency_rinex_rtk_arc(
               context.sp3,
               context.base_obs,
               context.rover_obs,
               max_epochs: 2
             )

    assert {:ok, wide_lane} =
             RTK.fix_wide_lane_rtk_arc(arc, %{
               base_m: {4_075_580.3111, 931_854.0543, 4_801_568.2808},
               reference: :auto,
               min_epochs: 2,
               tolerance_cycles: 0.5,
               skip_short_fragments: false,
               cycle_slip: nil
             })

    assert {:ok, %IonosphereFreeArcSolution{} = solution} =
             RTK.prepare_ionosphere_free_rtk_arc(
               arc,
               wide_lane.wide_lane_cycles,
               %{
                 base_m: {4_075_580.3111, 931_854.0543, 4_801_568.2808},
                 initial_baseline_m: {0.0, 0.0, 0.0},
                 reference: :auto,
                 apply_troposphere: true
               }
             )

    assert solution.epochs != []
  end

  test "RTK troposphere options reject non-booleans on every native route", context do
    assert {:ok, arc} =
             RTK.build_dual_frequency_rinex_rtk_arc(
               context.sp3,
               context.base_obs,
               context.rover_obs,
               max_epochs: 2
             )

    assert {:error, {:invalid_option, :apply_troposphere}} =
             RTK.prepare_ionosphere_free_rtk_arc(
               arc,
               %{},
               %{
                 base_m: {4_075_580.3111, 931_854.0543, 4_801_568.2808},
                 initial_baseline_m: {0.0, 0.0, 0.0},
                 reference: :auto,
                 apply_troposphere: :invalid
               }
             )

    assert {:error, {:invalid_option, :apply_troposphere}} =
             RTK.prepare_ionosphere_free_rtk_arc(
               [],
               %{},
               %{
                 base_m: {4_075_580.3111, 931_854.0543, 4_801_568.2808},
                 initial_baseline_m: {0.0, 0.0, 0.0},
                 reference: :auto,
                 apply_troposphere: :invalid
               }
             )

    for opts <- [%{apply_troposphere: :invalid}, [apply_troposphere: :invalid]] do
      assert {:error, {:invalid_option, :apply_troposphere}} =
               RTK.solve_wide_lane_fixed_rinex_rtk_baseline(
                 context.sp3,
                 context.base_obs,
                 context.rover_obs,
                 {4_075_580.3111, 931_854.0543, 4_801_568.2808},
                 opts
               )
    end
  end

  test "RTK arc builders reject invalid direct and nested native options", context do
    invalid_options = [
      {:max_epochs, -1},
      {:max_epochs, :invalid},
      {:max_epochs, @max_native_usize + 1},
      {:min_common_satellites, 0},
      {:min_common_satellites, :invalid},
      {:min_common_satellites, @max_native_usize + 1},
      {:include_prediction_time, :invalid}
    ]

    Enum.each([:direct, :nested], fn location ->
      Enum.each(invalid_options, fn {key, value} ->
        opts =
          case location do
            :direct -> %{key => value}
            :nested -> %{arc_options: %{key => value}}
          end

        results = [
          RTK.build_rinex_rtk_arc(context.sp3, context.base_obs, context.rover_obs, opts),
          RTK.build_dual_frequency_rinex_rtk_arc(context.sp3, context.base_obs, context.rover_obs, opts)
        ]

        Enum.each(results, fn result ->
          assert {:error, {:invalid_option, ^key}} = result
        end)
      end)
    end)
  end

  test "explicit DTED tile-list builder canonicalizes caller order and writes bytes" do
    entries = [
      DtedTileListEntry.new(
        TerrainTileId.new(36, -106),
        Path.join(@dted_root, "n36_w106_1arc_v3.dt2")
      ),
      DtedTileListEntry.new(
        {36, -107},
        Path.join(@dted_root, "n36_w107_1arc_v3.dt2")
      )
    ]

    assert {:ok, listed_bytes} = MmapTerrain.dted_tile_list_to_mmap_store(entries)
    assert {:ok, tree_bytes} = MmapTerrain.dted_tree_to_mmap_store(@dted_root)
    assert listed_bytes == tree_bytes

    output_path = Path.join(System.tmp_dir!(), "sidereon-dted-list-#{System.unique_integer([:positive])}.bin")
    on_exit(fn -> File.rm(output_path) end)
    assert :ok = MmapTerrain.write_dted_tile_list_to_mmap_store(Enum.reverse(entries), output_path)
    assert File.read!(output_path) == listed_bytes

    assert {:ok, store} = MmapTerrain.from_bytes(listed_bytes)
    assert Enum.map(MmapTerrain.tile_index(store), &{&1.lat_index, &1.lon_index}) == [{36, -107}, {36, -106}]
  end

  test "explicit DTED tile-list builder reports caller identity mismatch" do
    entry = %{
      tile_id: {35, -107},
      path: Path.join(@dted_root, "n36_w107_1arc_v3.dt2")
    }

    assert {:error,
            %TerrainStoreError{
              kind: :tile_id_mismatch,
              expected_tile_id: {35, -107},
              found_tile_id: {36, -107}
            }} = MmapTerrain.dted_tile_list_to_mmap_store([entry])
  end

  test "DTED tile-list builder validates signed 32-bit tile indices before the NIF" do
    for tile_id <- [{2_147_483_648, -106}, {-2_147_483_649, -106}, {36, 2_147_483_648}, {36, -2_147_483_649}] do
      entry = %{tile_id: tile_id, path: "unused.dt2"}
      assert {:error, {:invalid_tile_list_entry, 0}} = MmapTerrain.dted_tile_list_to_mmap_store([entry])
    end
  end

  test "DTED writer distinguishes invalid output paths from invalid tile lists" do
    entry = %{
      tile_id: {36, -107},
      path: Path.join(@dted_root, "n36_w107_1arc_v3.dt2")
    }

    assert {:error, :invalid_output_path} = MmapTerrain.write_dted_tile_list_to_mmap_store([entry], nil)
    assert {:error, :invalid_tile_list} = MmapTerrain.write_dted_tile_list_to_mmap_store(:invalid, "/tmp/out.bin")
  end
end
