defmodule Sidereon.GNSS.PreciseInterpolantArtifactTest do
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.Observables
  alias Sidereon.GNSS.PreciseEphemeris.Interpolant
  alias Sidereon.GNSS.SP3
  alias Sidereon.GNSS.Time

  @sp3_path Path.join(__DIR__, "fixtures/sp3/GRG0MGXFIN_20201760000_01D_15M_ORB.SP3")
  @epoch ~N[2020-06-24 12:00:00]
  @receiver {4_027_894.0, 307_046.0, 4_919_474.0}
  @checksum 5_250_867_419_192_089_605

  setup_all do
    {:ok, sp3: SP3.load!(@sp3_path)}
  end

  test "builds, opens, checksums, and evaluates artifact bytes", %{sp3: sp3} do
    # Reference literals generated from sidereon-core through this binding
    # against the patched core on 2026-07-05.
    {:ok, bytes} = Interpolant.artifact_bytes(sp3)
    assert byte_size(bytes) == 926_752
    assert {:ok, @checksum} = Interpolant.checksum(bytes)

    assert {:ok, interpolant} = Interpolant.open(bytes)
    assert Interpolant.time_scale(interpolant) == "GPST"
    assert Enum.take(Interpolant.satellite_ids(interpolant), 3) == ["G01", "G02", "G03"]
    assert {:ok, @checksum} = Interpolant.checksum(interpolant)

    {:ok, t_rx_j2000_s} = Time.epoch_to_j2000_seconds_fractional(@epoch)
    requests = [{"G01", @receiver, t_rx_j2000_s}]

    assert {:ok, [from_sp3]} = Observables.predict_ranges(sp3, requests)
    assert {:ok, [from_artifact]} = Observables.predict_ranges(interpolant, requests)
    assert from_artifact == from_sp3

    assert_in_delta from_artifact.geometric_range_m, 28_508_019.948587343, 1.0e-9
    assert_in_delta from_artifact.sat_clock_s, 1.563156332034656e-5, 1.0e-18
    assert_in_delta from_artifact.transmit_time_j2000_s, 646_271_999.904907, 1.0e-9

    {x, y, z} = from_artifact.sat_pos_ecef_m
    assert_in_delta x, 10_628_162.79544269, 1.0e-9
    assert_in_delta y, -19_620_911.704227246, 1.0e-9
    assert_in_delta z, -14_368_350.007790234, 1.0e-9
  end

  test "returns typed corrupt and truncated artifact errors", %{sp3: sp3} do
    {:ok, bytes} = Interpolant.artifact_bytes(sp3)

    assert {:error, {:truncated, "store has 10 bytes but needs at least 64"}} =
             Interpolant.open(binary_part(bytes, 0, 10))

    corrupt = <<0>> <> binary_part(bytes, 1, byte_size(bytes) - 1)

    assert {:error, {:corrupt, {:parse, "missing precise interpolant store magic"}}} =
             Interpolant.open(corrupt)
  end
end
