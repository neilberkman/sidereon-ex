defmodule Sidereon.GNSS.PreciseEphemeris.InterpolantArtifactTest do
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.Observables
  alias Sidereon.GNSS.PreciseEphemeris.Interpolant
  alias Sidereon.GNSS.PreciseEphemeris.InterpolantArtifact
  alias Sidereon.GNSS.PreciseEphemeris.PreciseInterpolantArtifact
  alias Sidereon.GNSS.SP3

  @sp3_path Path.join(__DIR__, "fixtures/sp3/GRG0MGXFIN_20201760000_01D_15M_ORB.SP3")
  @receiver {4_027_894.0, 307_046.0, 4_919_474.0}

  test "opened artifact is a named public source over the core store bytes" do
    sp3 = SP3.load!(@sp3_path)
    sat = hd(SP3.satellite_ids(sp3))
    [epoch0, epoch1 | _] = SP3.epochs_j2000_seconds(sp3)
    query = 0.5 * (epoch0 + epoch1)

    assert {:ok, bytes} = InterpolantArtifact.artifact_bytes(sp3)
    assert {:ok, ^bytes} = PreciseInterpolantArtifact.artifact_bytes(sp3)
    assert byte_size(bytes) > 0
    assert {:ok, %InterpolantArtifact{} = artifact} = InterpolantArtifact.open(bytes)
    assert {:ok, %InterpolantArtifact{} = canonical_artifact} = PreciseInterpolantArtifact.open(bytes)
    assert {:ok, ^bytes} = InterpolantArtifact.as_bytes(artifact)
    assert {:ok, checksum} = InterpolantArtifact.checksum64(bytes)
    assert {:ok, ^checksum} = InterpolantArtifact.checksum64(artifact)
    assert {:ok, ^checksum} = PreciseInterpolantArtifact.checksum64(canonical_artifact)
    assert {:ok, byte_len} = InterpolantArtifact.byte_len(artifact)
    assert byte_len == byte_size(bytes)
    assert InterpolantArtifact.time_scale(artifact) == sp3.time_scale
    assert sat in InterpolantArtifact.satellite_ids(artifact)

    assert {:ok, from_sp3} = Interpolant.states_at_shared_j2000_s(sp3, [sat], query)
    assert {:ok, from_artifact} = Interpolant.states_at_shared_j2000_s(artifact, [sat], query)
    assert from_artifact == from_sp3

    assert {:ok, sp3_ranges} = Observables.predict_ranges(sp3, [{sat, @receiver, query}])
    assert {:ok, artifact_ranges} = Observables.predict_ranges(artifact, [{sat, @receiver, query}])
    assert artifact_ranges == sp3_ranges
  end
end
