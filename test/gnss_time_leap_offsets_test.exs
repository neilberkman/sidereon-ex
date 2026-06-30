defmodule Sidereon.GNSS.TimeLeapOffsetsTest do
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.Time

  test "gps_utc_offset_s is 18 s from 2017" do
    assert_in_delta Time.gps_utc_offset_s(2020, 1, 1), 18.0, 1.0e-12
  end

  test "tai_utc_offset_s is 37 s from 2017 and equals leap_seconds/3" do
    assert_in_delta Time.tai_utc_offset_s(2020, 1, 1), 37.0, 1.0e-12
    assert_in_delta Time.tai_utc_offset_s(2020, 1, 1), Time.leap_seconds(2020, 1, 1), 1.0e-12
  end

  test "TAI - UTC and GPS - UTC differ by the constant 19 s (TAI - GPST)" do
    for {y, m, d} <- [{2017, 6, 1}, {2020, 1, 1}, {2024, 3, 15}] do
      assert_in_delta Time.tai_utc_offset_s(y, m, d) - Time.gps_utc_offset_s(y, m, d), 19.0, 1.0e-12
    end
  end

  test "reflects an earlier leap-second epoch" do
    # GPS - UTC was 16 s through most of 2014 (before the 2015/2016 leaps).
    assert_in_delta Time.gps_utc_offset_s(2014, 1, 1), 16.0, 1.0e-12
  end
end
