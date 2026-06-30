defmodule Sidereon.ConjunctionTest do
  use ExUnit.Case

  alias Sidereon.GNSS.Time

  @iss_l1 "1 25544U 98067A   18184.80969102  .00001614  00000-0  31745-4 0  9993"
  @iss_l2 "2 25544  51.6414 295.8524 0003435 262.6267 204.2868 15.54005638121106"
  @debris_l1 "1 43115U 18004E   18184.93592192  .00002627  00000-0  42316-4 0  9996"
  @debris_l2 "2 43115  51.6381 296.5429 0001844 127.5881 232.5326 15.56879558 25072"

  @iridium_l1 "1 24946U 97051C   09040.78448243 +.00000153 +00000-0 +47668-4 0  9994"
  @iridium_l2 "2 24946 086.3994 121.7028 0002288 085.1644 274.9812 14.34219863597336"
  @cosmos_l1 "1 22675U 93036A   09040.49834364 -.00000001  00000-0  95251-5 0  9996"
  @cosmos_l2 "2 22675 074.0355 019.4646 0016027 098.7014 261.5952 14.31135643817415"

  test "ISS vs debris finds periodic TCA candidates" do
    assert {:ok, candidates} =
             Sidereon.Conjunction.find_tca_candidates(
               @iss_l1,
               @iss_l2,
               @debris_l1,
               @debris_l2,
               split(~N[2018-07-03 19:25:57]),
               split(~N[2018-07-04 19:25:57]),
               coarse_step_seconds: 60.0
             )

    assert length(candidates) > 5

    for candidate <- candidates do
      assert candidate.tca_seconds_since_window_start >= 0.0
      assert candidate.miss_distance_km > 0.0
    end

    if length(candidates) >= 2 do
      [first, second | _] = candidates
      period_min = (second.tca_seconds_since_window_start - first.tca_seconds_since_window_start) / 60.0
      assert period_min > 80.0 and period_min < 100.0
    end
  end

  test "screen_tca_candidates returns no hits for a tight threshold" do
    assert {:ok, []} =
             Sidereon.Conjunction.screen_tca_candidates(
               @iss_l1,
               @iss_l2,
               [{@debris_l1, @debris_l2}],
               split(~N[2018-07-03 19:25:57]),
               split(~N[2018-07-04 19:25:57]),
               10.0,
               coarse_step_seconds: 60.0
             )
  end

  test "find_tca_conjunctions returns Pc metadata for candidates" do
    assert {:ok, [conjunction | _]} =
             Sidereon.Conjunction.find_tca_conjunctions(
               @iss_l1,
               @iss_l2,
               @debris_l1,
               @debris_l2,
               split(~N[2018-07-03 19:25:57]),
               split(~N[2018-07-04 19:25:57]),
               0.02,
               coarse_step_seconds: 60.0
             )

    assert conjunction.pc >= 0.0
    assert_in_delta conjunction.miss_km, conjunction.candidate.miss_distance_km, 1.0e-9
    assert conjunction.relative_speed_km_s > 0.0
  end

  test "screen_tca_conjunctions returns secondary indexes and conjunctions" do
    assert {:ok, [%{secondary_index: 0, conjunction: conjunction} | _]} =
             Sidereon.Conjunction.screen_tca_conjunctions(
               @iss_l1,
               @iss_l2,
               [{@debris_l1, @debris_l2}],
               split(~N[2018-07-03 19:25:57]),
               split(~N[2018-07-04 19:25:57]),
               10_000.0,
               0.02,
               coarse_step_seconds: 60.0
             )

    assert conjunction.pc >= 0.0
    assert conjunction.candidate.miss_distance_km < 10_000.0
  end

  test "standard TCA options are validated" do
    assert {:error, {:invalid_option, :coarse_step_seconds}} =
             Sidereon.Conjunction.find_tca_candidates(
               @iss_l1,
               @iss_l2,
               @debris_l1,
               @debris_l2,
               split(~N[2018-07-03 19:25:57]),
               split(~N[2018-07-04 19:25:57]),
               coarse_step_seconds: 0.0
             )
  end

  test "invalid TLE input returns an error" do
    bad_l1 = String.replace(@iss_l1, "25544U", "123456")

    assert {:error, _reason} =
             Sidereon.Conjunction.find_tca_candidates(
               bad_l1,
               @iss_l2,
               @debris_l1,
               @debris_l2,
               split(~N[2018-07-03 19:25:57]),
               split(~N[2018-07-04 19:25:57])
             )
  end

  test "Iridium 33 and Cosmos 2251 TCA lands near the 2009 event" do
    start_epoch = ~N[2009-02-09 18:49:39]

    assert {:ok, candidates} =
             Sidereon.Conjunction.find_tca_candidates(
               @iridium_l1,
               @iridium_l2,
               @cosmos_l1,
               @cosmos_l2,
               split(start_epoch),
               split(~N[2009-02-11 18:49:39]),
               coarse_step_seconds: 60.0
             )

    refute Enum.empty?(candidates)

    closest = Enum.min_by(candidates, & &1.miss_distance_km)
    tca_hours = closest.tca_seconds_since_window_start / 3600.0

    assert_in_delta tca_hours, 22.1, 1.0
    assert closest.miss_distance_km < 10.0
  end

  defp split(epoch), do: Time.epoch_to_split_jd(epoch)
end
