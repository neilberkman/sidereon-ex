defmodule Sidereon.ObservableStateBatchTest do
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.Observables
  alias Sidereon.GNSS.PreciseEphemeris
  alias Sidereon.GNSS.PreciseEphemeris.Interpolant
  alias Sidereon.GNSS.PreciseEphemeris.StateBatch
  alias Sidereon.GNSS.SP3

  @sp3_path Path.join(__DIR__, "fixtures/sp3/GRG0MGXFIN_20201760000_01D_15M_ORB.SP3")
  @receiver {4_027_894.0, 307_046.0, 4_919_474.0}

  test "observable state batches and cached interpolant match scalar SP3 state" do
    {:ok, sp3} = SP3.parse(File.read!(@sp3_path))
    {:ok, interpolant} = Interpolant.from_sp3(sp3)
    {:ok, sample_source} = PreciseEphemeris.from_samples(SP3.precise_ephemeris_samples(sp3))
    {:ok, sample_interpolant} = Interpolant.from_precise_ephemeris_samples(sample_source)

    sat = hd(SP3.satellite_ids(sp3))
    [epoch0, epoch1 | _] = SP3.epochs_j2000_seconds(sp3)
    midpoint = 0.5 * (epoch0 + epoch1)

    assert Enum.sort(Interpolant.satellite_ids(interpolant)) == Enum.sort(SP3.satellite_ids(sp3))
    assert Interpolant.time_scale(interpolant) == sp3.time_scale

    assert {:ok, exact} = SP3.state(sp3, sat, 0)
    assert {:ok, direct_batch} = Interpolant.states_at_j2000_s(sp3, [sat], [epoch0])
    assert {:ok, %{position_ecef_m: {x, y, z}, clock_s: clock_s}} = StateBatch.element(direct_batch, 0)
    assert_in_delta x, exact.x_m, 1.0e-8
    assert_in_delta y, exact.y_m, 1.0e-8
    assert_in_delta z, exact.z_m, 1.0e-8
    assert clock_s == exact.clock_s

    assert {:ok, sp3_shared} = Interpolant.states_at_shared_j2000_s(sp3, [sat, sat], midpoint)
    assert {:ok, handle_shared} = Interpolant.states_at_shared_j2000_s(interpolant, [sat, sat], midpoint)
    assert {:ok, sample_handle_shared} = Interpolant.states_at_shared_j2000_s(sample_interpolant, [sat, sat], midpoint)

    assert handle_shared == sp3_shared
    assert sample_handle_shared == sp3_shared

    assert {:ok, sp3_ranges} = Observables.predict_ranges(sp3, [{sat, @receiver, midpoint}])
    assert {:ok, handle_ranges} = Observables.predict_ranges(interpolant, [{sat, @receiver, midpoint}])
    assert handle_ranges == sp3_ranges
  end

  test "observable state batch reports gap rows with the sentinel position" do
    {:ok, sp3} = SP3.parse(File.read!(@sp3_path))
    sat = hd(SP3.satellite_ids(sp3))
    [epoch0, epoch1 | _] = SP3.epochs_j2000_seconds(sp3)
    outside_epoch = epoch0 - 100.0 * (epoch1 - epoch0)

    assert {:ok, batch} = Interpolant.states_at_j2000_s(sp3, [sat, sat], [epoch0, outside_epoch])
    assert batch.statuses == [:valid, :gap]
    assert [:ok, {:error, :epoch_out_of_range}] = batch.results
    assert {:error, :epoch_out_of_range} = StateBatch.element(batch, 1)

    assert StateBatch.missing_position_ecef_m() == {:nan, :nan, :nan}
    assert Enum.at(batch.positions_ecef_m, 1) == StateBatch.missing_position_ecef_m()
  end
end
