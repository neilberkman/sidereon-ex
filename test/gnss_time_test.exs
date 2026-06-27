defmodule Sidereon.GNSS.TimeTest do
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.Time

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
end
