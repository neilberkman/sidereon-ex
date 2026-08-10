defmodule Sidereon.AttestedArtifactOpenTest do
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.PreciseEphemeris.InterpolantArtifact
  alias Sidereon.GNSS.PreciseEphemeris.PreciseInterpolantArtifact
  alias Sidereon.GNSS.SP3
  alias Sidereon.Terrain.MmapTerrain
  alias Sidereon.Terrain.MmapTerrain.TerrainStoreError

  @dted_root Path.join(__DIR__, "fixtures/dted/tiles")
  @sp3_path Path.join(__DIR__, "fixtures/sp3/GRG0MGXFIN_20201760000_01D_15M_ORB.SP3")

  @terrain_data_offset_offset 24
  @interpolant_index_offset_offset 16
  @interpolant_checksum_offset 40
  @interpolant_pos_kx_offset_offset 24

  setup_all do
    root =
      Path.join(
        System.tmp_dir!(),
        "sidereon-attested-open-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, terrain_bytes} = MmapTerrain.dted_tree_to_mmap_store(@dted_root)
    terrain_claim = MmapTerrain.checksum64(terrain_bytes)
    terrain_path = write_fixture(root, "terrain.tmm", terrain_bytes)
    terrain_data_offset = read_u64(terrain_bytes, @terrain_data_offset_offset)

    corrupt_terrain_path =
      write_fixture(
        root,
        "corrupt-terrain.tmm",
        flip_byte(terrain_bytes, terrain_data_offset + 1)
      )

    sp3 = SP3.load!(@sp3_path)
    satellite = hd(SP3.satellite_ids(sp3))
    [epoch0, epoch1 | _] = SP3.epochs_j2000_seconds(sp3)
    query_epoch = 0.5 * (epoch0 + epoch1)
    {:ok, interpolant_bytes} = InterpolantArtifact.artifact_bytes(sp3)
    interpolant_claim = read_u64(interpolant_bytes, @interpolant_checksum_offset)
    interpolant_path = write_fixture(root, "interpolant.spi", interpolant_bytes)
    index_offset = read_u64(interpolant_bytes, @interpolant_index_offset_offset)
    pos_kx_offset = read_u64(interpolant_bytes, index_offset + @interpolant_pos_kx_offset_offset)

    corrupt_interpolant_path =
      write_fixture(
        root,
        "corrupt-interpolant.spi",
        flip_byte(interpolant_bytes, pos_kx_offset + 1)
      )

    {:ok,
     corrupt_interpolant_path: corrupt_interpolant_path,
     corrupt_terrain_path: corrupt_terrain_path,
     interpolant_bytes: interpolant_bytes,
     interpolant_claim: interpolant_claim,
     interpolant_path: interpolant_path,
     query_epoch: query_epoch,
     satellite: satellite,
     terrain_claim: terrain_claim,
     terrain_path: terrain_path}
  end

  test "terrain attested open defers payload hashing and verify detects corruption", context do
    assert {:error, %TerrainStoreError{kind: :checksum} = verified_error} =
             MmapTerrain.from_path(context.corrupt_terrain_path)

    claim = 0x0123_4567_89AB_CDEF

    assert {:ok, terrain} =
             MmapTerrain.from_path_attested(context.corrupt_terrain_path, claim)

    assert MmapTerrain.digest_provenance(terrain) == :attested
    assert MmapTerrain.checksum64(terrain) == claim
    assert {:error, ^verified_error} = MmapTerrain.verify(terrain)
    assert MmapTerrain.digest_provenance(terrain) == :attested
  end

  test "precise-interpolant attested open defers payload hashing and verify detects corruption", context do
    assert {:error, verified_error} =
             InterpolantArtifact.from_path(context.corrupt_interpolant_path)

    assert match?({:corrupt, {:checksum, _, _}}, verified_error) or
             match?({:corrupt, {:satellite_checksum, _, _, _}}, verified_error)

    assert {:ok, artifact} =
             InterpolantArtifact.from_path_attested(
               context.corrupt_interpolant_path,
               context.interpolant_claim
             )

    assert InterpolantArtifact.digest_provenance(artifact) == :attested
    assert {:ok, context.interpolant_claim} == InterpolantArtifact.checksum64(artifact)
    assert {:error, ^verified_error} = InterpolantArtifact.verify(artifact)
    assert InterpolantArtifact.digest_provenance(artifact) == :attested
  end

  test "precise-interpolant attested open rejects a claim that differs from the header", context do
    declared = context.interpolant_claim
    claimed = Bitwise.bxor(declared, 1)

    assert {:error, {:attested_checksum_mismatch, ^claimed, ^declared}} =
             PreciseInterpolantArtifact.from_path_attested(context.interpolant_path, claimed)
  end

  test "pristine terrain attested and verified opens agree and provenance escalates", context do
    assert {:ok, verified} = MmapTerrain.from_path(context.terrain_path)
    assert {:ok, attested} = MmapTerrain.from_path_attested(context.terrain_path, context.terrain_claim)

    assert MmapTerrain.digest_provenance(verified) == :verified
    assert MmapTerrain.digest_provenance(attested) == :attested
    assert MmapTerrain.checksum64(attested) == context.terrain_claim

    assert MmapTerrain.height_m(attested, -106.875, 36.125) ==
             MmapTerrain.height_m(verified, -106.875, 36.125)

    assert :ok = MmapTerrain.verify(attested)
    assert MmapTerrain.digest_provenance(attested) == :verified
    assert MmapTerrain.checksum64(attested) == context.terrain_claim

    terrain_claim = context.terrain_claim
    wrong_claim = Bitwise.bxor(terrain_claim, 1)
    assert {:ok, wrong} = MmapTerrain.from_path_attested(context.terrain_path, wrong_claim)

    assert {:error,
            %TerrainStoreError{
              kind: :attested_checksum_mismatch,
              expected: ^wrong_claim,
              found: ^terrain_claim
            }} = MmapTerrain.verify(wrong)
  end

  test "pristine precise-interpolant attested and verified opens agree and provenance escalates", context do
    assert {:ok, verified} = PreciseInterpolantArtifact.from_path(context.interpolant_path)

    assert {:ok, attested} =
             PreciseInterpolantArtifact.from_path_attested(
               context.interpolant_path,
               context.interpolant_claim
             )

    assert PreciseInterpolantArtifact.digest_provenance(verified) == :verified
    assert PreciseInterpolantArtifact.digest_provenance(attested) == :attested
    assert {:ok, context.interpolant_claim} == PreciseInterpolantArtifact.checksum64(attested)
    assert {:ok, context.interpolant_bytes} == PreciseInterpolantArtifact.as_bytes(attested)
    assert {:ok, byte_size(context.interpolant_bytes)} == PreciseInterpolantArtifact.byte_len(attested)

    assert PreciseInterpolantArtifact.states_at_shared_j2000_s(
             attested,
             [context.satellite],
             context.query_epoch
           ) ==
             PreciseInterpolantArtifact.states_at_shared_j2000_s(
               verified,
               [context.satellite],
               context.query_epoch
             )

    assert :ok = PreciseInterpolantArtifact.verify(attested)
    assert PreciseInterpolantArtifact.digest_provenance(attested) == :verified
    assert {:ok, context.interpolant_claim} == PreciseInterpolantArtifact.checksum64(attested)
  end

  test "malformed checksum claims return typed errors", context do
    for claim <- ["1", -1, 0x1_0000_0000_0000_0000] do
      assert {:error, {:invalid_checksum64, ^claim}} =
               MmapTerrain.from_path_attested(context.terrain_path, claim)

      assert {:error, {:invalid_checksum64, ^claim}} =
               PreciseInterpolantArtifact.from_path_attested(context.interpolant_path, claim)
    end
  end

  defp read_u64(bytes, offset) do
    <<_::binary-size(^offset), value::little-unsigned-64, _::binary>> = bytes
    value
  end

  defp flip_byte(bytes, offset) do
    <<prefix::binary-size(^offset), byte, suffix::binary>> = bytes
    prefix <> <<Bitwise.bxor(byte, 1)>> <> suffix
  end

  defp write_fixture(root, name, bytes) do
    path = Path.join(root, name)
    File.write!(path, bytes)
    path
  end
end
