defmodule Sidereon.GNSS.TimeTest do
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.Time

  doctest Time

  describe "timescale_offset/2" do
    test "fixed atomic offset to - from, in seconds" do
      assert {:ok, 19.0} = Time.timescale_offset(:gpst, :tai)
      assert {:ok, -19.0} = Time.timescale_offset(:tai, :gpst)
      assert {:ok, -32.184} = Time.timescale_offset(:tt, :tai)
      # GST and QZSST share the GPST atomic datum.
      assert {:ok, +0.0} = Time.timescale_offset(:gst, :gpst)
      assert {:ok, +0.0} = Time.timescale_offset(:qzsst, :gpst)
    end

    test "accepts uppercase abbreviation strings" do
      assert {:ok, 19.0} = Time.timescale_offset("GPST", "TAI")
    end

    test "errors for the UTC-based scales (offset is epoch-dependent)" do
      assert {:error, {:epoch_required, "UTC"}} = Time.timescale_offset(:gpst, :utc)
      assert {:error, {:epoch_required, "GLONASST"}} = Time.timescale_offset(:glonasst, :tai)
    end

    test "errors for TDB (no fixed offset) and unknown scales" do
      assert {:error, {:unsupported, "TDB"}} = Time.timescale_offset(:tdb, :tt)
      assert {:error, {:unknown_time_scale, :foo}} = Time.timescale_offset(:foo, :tai)
    end
  end

  describe "timescale_offset_at/3" do
    test "resolves leap-aware UTC-based offsets at an epoch" do
      # GLONASST = UTC + 3 h, so UTC - GLONASST = -10800 s regardless of leaps.
      assert {:ok, -10_800.0} = Time.timescale_offset_at(:glonasst, :utc, 2_451_545.0)
      # At J2000 TAI-UTC = 32 s and GPST = TAI - 19 s, so GPST - UTC = 13 s.
      assert {:ok, 13.0} = Time.timescale_offset_at(:utc, :gpst, 2_451_545.0)
    end

    test "matches the fixed offset for purely atomic pairs (epoch ignored)" do
      assert {:ok, 19.0} = Time.timescale_offset_at(:gpst, :tai, 2_451_545.0)
    end
  end

  describe "leap-second and UT1 metadata" do
    test "resolves scalar and batched TAI minus UTC values" do
      assert 32.0 = Time.leap_seconds(2000, 1, 1)
      assert 37.0 = Time.leap_seconds(2017, 1, 1)
      assert [32.0, 37.0] = Time.leap_seconds_batch([{2000, 1, 1}, {2017, 1, 1}])
    end

    test "exposes core table coverage descriptors" do
      leap_table = Time.leap_second_table_info()

      assert is_binary(leap_table.source)
      assert leap_table.first_mjd <= leap_table.last_mjd
      assert leap_table.entries > 0

      ut1 = Time.ut1_coverage_info()

      assert is_binary(ut1.source)
      assert ut1.first_mjd <= ut1.last_mjd
      assert ut1.first_jd_tt < ut1.last_jd_tt
      assert ut1.entries > 0
    end
  end

  describe "epoch_to_split_jd/1" do
    test "puts midnight on the *.5 day boundary with a zero fraction" do
      assert {jd_whole, fraction} = Time.epoch_to_split_jd({{2020, 6, 24}, {0, 0, 0}})
      assert jd_whole == 2_459_024.5
      assert fraction == 0.0
    end

    test "carries the within-day time into the fraction" do
      assert {2_459_024.5, fraction} = Time.epoch_to_split_jd({{2020, 6, 24}, {12, 0, 0}})
      assert fraction == 0.5
    end

    test "accepts a NaiveDateTime" do
      assert {2_459_024.5, fraction} = Time.epoch_to_split_jd(~N[2020-06-24 00:00:00])
      assert fraction == 0.0
    end
  end

  describe "epoch_to_j2000_seconds/1" do
    test "matches the IONEX fixture epoch axis" do
      # 2020-06-24 01:00:00 is 646232400 s after the J2000 epoch.
      assert {:ok, 646_232_400} = Time.epoch_to_j2000_seconds({{2020, 6, 24}, {1, 0, 0}})
    end

    test "J2000 epoch itself is zero seconds" do
      assert {:ok, 0} = Time.epoch_to_j2000_seconds({{2000, 1, 1}, {12, 0, 0}})
    end

    test "rejects a sub-second epoch" do
      assert {:error, :non_integer_second_epoch} =
               Time.epoch_to_j2000_seconds(~N[2020-06-24 01:00:00.250])
    end
  end

  describe "utc_instant_split/1" do
    test "builds a validated UTC instant from a civil epoch" do
      assert {:ok, {jd_whole, fraction}} =
               Time.utc_instant_split({{2020, 6, 25}, {12, 0, 0}})

      assert jd_whole == 2_459_025.5
      assert_in_delta fraction, 0.5, 1.0e-12
    end

    test "agrees with the raw split-Julian-date path for a valid epoch" do
      {raw_whole, raw_fraction} = Time.epoch_to_split_jd({{2020, 6, 25}, {6, 30, 0}})

      assert {:ok, {jd_whole, fraction}} =
               Time.utc_instant_split({{2020, 6, 25}, {6, 30, 0}})

      assert jd_whole == raw_whole
      assert_in_delta fraction, raw_fraction, 1.0e-12
    end

    test "rejects an out-of-day clock field" do
      assert {:error, :invalid_instant} = Time.utc_instant_split({{2020, 6, 25}, {25, 0, 0}})
    end
  end
end
