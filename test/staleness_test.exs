defmodule Sidereon.GNSS.StalenessTest do
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.Ionosphere
  alias Sidereon.GNSS.SP3
  alias Sidereon.GNSS.Staleness
  alias Sidereon.GNSS.Staleness.IonexSelection
  alias Sidereon.GNSS.Staleness.Policy
  alias Sidereon.GNSS.Staleness.Sp3Selection
  alias Sidereon.GNSS.Staleness.StalenessMetadata
  alias Sidereon.GNSS.Time

  # One day's worth of GPS precise orbits (2020-06-24, DOY 176). Coverage is the
  # first..last node epoch of this single product.
  @sp3_path Path.join(__DIR__, "fixtures/sp3/GRG0MGXFIN_20201760000_01D_15M_ORB.SP3")

  # A 2-map synthetic IONEX (2020-06-24 00:00 and 02:00). Same bytes the IONEX
  # parity fixtures use, so the slant delay below is the committed reference value.
  @ionex_path Path.join(__DIR__, "fixtures/synthetic_2map_7x7.20i")

  # The committed IONEX 'interior_l1' reference: lat 45, lon 10, az 60, el 60, L1,
  # epoch 2020-06-24 01:00:00.
  @ionex_l1_hz 1_575_420_000.0
  @ionex_l1_ref_m 2.9414773797764737

  describe "Policy" do
    test "days/1, seconds/1, and the default three-day cap" do
      assert Policy.days(1.0).max_staleness_s == 86_400.0
      assert Policy.seconds(3600.0).max_staleness_s == 3600.0
      assert Policy.default().max_staleness_s == 3.0 * 86_400.0
    end
  end

  describe "select_sp3/3" do
    setup do
      {:ok, sp3: SP3.load!(@sp3_path)}
    end

    test "an in-coverage epoch is exact and bit-for-bit the caller's product", %{sp3: sp3} do
      epoch = ~N[2020-06-24 12:00:00]

      assert {:ok, %Sp3Selection{sp3: selected, metadata: meta}} =
               Staleness.select_sp3([sp3], epoch)

      assert %StalenessMetadata{kind: :exact, staleness_s: +0.0, staleness_days: +0.0} = meta

      # The exact selection is the caller's own product, so the interpolated state
      # is identical to querying the input directly.
      assert {:ok, direct} = SP3.position(sp3, "G01", epoch)
      assert {:ok, via_selection} = SP3.position(selected, "G01", epoch)
      assert via_selection == direct
    end

    test "an epoch past coverage degrades to the nearest prior product within the cap",
         %{sp3: sp3} do
      epoch = ~N[2020-06-25 12:00:00]
      {:ok, requested_s} = Time.epoch_to_j2000_seconds_fractional(epoch)
      coverage_end = SP3.coverage(sp3).end_j2000_s

      assert {:ok, %Sp3Selection{metadata: meta}} = Staleness.select_sp3([sp3], epoch)

      assert meta.kind == :nearest_prior
      assert meta.source_epoch_j2000_s == coverage_end
      assert meta.requested_epoch_j2000_s == requested_s
      assert meta.staleness_s == requested_s - coverage_end
      assert meta.staleness_s > 0.0
      assert meta.staleness_days == meta.staleness_s / 86_400.0
    end

    test "a prior product beyond the staleness cap is a typed error", %{sp3: sp3} do
      assert {:error, {:beyond_staleness_cap, info}} =
               Staleness.select_sp3([sp3], ~N[2020-06-25 12:00:00], Policy.seconds(0.0))

      assert %{
               requested_epoch_j2000_s: _,
               source_epoch_j2000_s: _,
               staleness_s: staleness,
               max_staleness_s: +0.0
             } = info

      assert staleness > 0.0
    end

    test "an empty product set is a typed error" do
      assert {:error, :empty_product_set} = Staleness.select_sp3([], ~N[2020-06-24 12:00:00])
    end
  end

  describe "select_ionex/3" do
    setup do
      {:ok, handle} = Ionosphere.parse_ionex(File.read!(@ionex_path))
      {:ok, handle: handle}
    end

    test "an in-coverage epoch is exact and bit-for-bit the caller's grid", %{handle: handle} do
      epoch = {{2020, 6, 24}, {1, 0, 0}}

      assert {:ok, %IonexSelection{handle: selected, metadata: meta}} =
               Staleness.select_ionex([handle], epoch)

      assert %StalenessMetadata{kind: :exact, staleness_s: +0.0} = meta
      # The exact selection returns the caller's own handle, so the slant delay is
      # the committed reference value, bit-for-bit.
      assert selected == handle

      assert {:ok, @ionex_l1_ref_m} =
               Ionosphere.ionex_slant_delay(selected, 45.0, 10.0, 60.0, 60.0, epoch, @ionex_l1_hz)
    end

    test "an epoch one day past coverage is a whole-day diurnal shift", %{handle: handle} do
      # No map covers 2020-06-25; the prior day's grid is advanced one whole day.
      epoch = {{2020, 6, 25}, {1, 0, 0}}

      assert {:ok, %IonexSelection{handle: shifted, metadata: meta}} =
               Staleness.select_ionex([handle], epoch)

      assert meta.kind == :diurnal_shift
      assert meta.staleness_s == 86_400.0
      assert meta.staleness_days == 1.0
      assert shifted != handle

      # Diurnal persistence moves only the epoch axis: querying the shifted grid at
      # the same time-of-day one day later lands between the same two maps, so the
      # slant delay is bit-for-bit the un-shifted exact-day value.
      assert {:ok, @ionex_l1_ref_m} =
               Ionosphere.ionex_slant_delay(shifted, 45.0, 10.0, 60.0, 60.0, epoch, @ionex_l1_hz)
    end

    test "a diurnal shift beyond the staleness cap is a typed error", %{handle: handle} do
      assert {:error, {:beyond_staleness_cap, info}} =
               Staleness.select_ionex([handle], {{2020, 6, 25}, {1, 0, 0}}, Policy.seconds(0.0))

      assert info.staleness_s == 86_400.0
      assert info.max_staleness_s == 0.0
    end

    test "an empty product set is a typed error" do
      assert {:error, :empty_product_set} =
               Staleness.select_ionex([], {{2020, 6, 24}, {1, 0, 0}})
    end
  end
end
