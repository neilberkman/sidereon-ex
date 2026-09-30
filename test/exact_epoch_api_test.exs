defmodule Sidereon.GNSS.ExactEpochApiTest do
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.PreciseEphemerisAccuracySample
  alias Sidereon.GNSS.PreciseEphemerisSample
  alias Sidereon.GNSS.Time.ExactEpoch
  alias Sidereon.GNSS.Time.ExactEpochQuery

  test "integer epoch construction preserves attoseconds without a float conversion" do
    seconds = 9_007_199_254_740_993
    attoseconds = 123_456_789_012_345_678

    assert {:ok, epoch} = ExactEpoch.new(seconds, attoseconds)
    {:ok, whole_epoch} = ExactEpoch.new(seconds, 0)
    assert epoch.whole_seconds == seconds
    assert epoch.attoseconds == attoseconds
    assert ExactEpoch.seconds_since(epoch, whole_epoch) == 0.12345678901234568
    assert ExactEpoch.attoseconds_per_second() == 1_000_000_000_000_000_000
  end

  test "queries compare by exact value across different epoch and offset decompositions" do
    {:ok, half_second_epoch} = ExactEpoch.from_j2000_seconds(0.5)

    {:ok, three_quarter_query} =
      ExactEpochQuery.checked_add_binary_seconds(ExactEpoch.query(half_second_epoch), 0.25)

    {:ok, zero_epoch} = ExactEpoch.new(0, 0)

    {:ok, other_three_quarter_query} =
      ExactEpochQuery.checked_add_binary_seconds(ExactEpoch.query(zero_epoch), 0.75)

    assert ExactEpochQuery.equal?(three_quarter_query, other_three_quarter_query)
    assert ExactEpochQuery.seconds_since_query(three_quarter_query, other_three_quarter_query) == 0.0
  end

  test "binary query APIs reject integer values that would be silently rounded" do
    inexact_integer = 9_007_199_254_740_993
    {:ok, query} = ExactEpochQuery.from_binary_j2000_seconds(0.0)

    assert {:error, :invalid_exact_epoch} =
             ExactEpochQuery.from_binary_j2000_seconds(inexact_integer)

    assert {:error, :invalid_exact_epoch} =
             ExactEpochQuery.checked_add_binary_seconds(query, inexact_integer)

    assert {:error, :invalid_exact_epoch} =
             ExactEpochQuery.checked_sub_binary_seconds(query, inexact_integer)
  end

  test "civil labels that round to the same absolute float remain distinct exact epochs" do
    {:ok, first_label} = ExactEpoch.from_civil(2026, 9, 25, 12, 0, 0.123456789012345)
    {:ok, second_label} = ExactEpoch.from_civil(2026, 9, 25, 12, 0, 0.123456789012346)

    assert ExactEpoch.j2000_seconds(first_label) == ExactEpoch.j2000_seconds(second_label)
    refute ExactEpoch.equal?(first_label, second_label)
  end

  test "decimal checked offsets and split Julian date are available on exact epochs" do
    {:ok, epoch} = ExactEpoch.new(0, 0)
    assert {:ok, later} = ExactEpoch.checked_add_seconds(epoch, 0.1)
    assert ExactEpoch.seconds_since(later, epoch) == 0.1
    assert {:ok, earlier} = ExactEpoch.checked_sub_seconds(epoch, 0.1)
    assert ExactEpoch.compare(earlier, epoch) == :less
    assert is_tuple(ExactEpoch.split_julian_date(epoch))
  end

  test "precise samples and accuracy sidecars retain exact nanosecond epochs" do
    first_ns = 1_000_000_000_000_000_000
    second_ns = first_ns + 1
    first_epoch = %{time_scale: "GPST", nanos_since_j2000: first_ns}
    second_epoch = %{time_scale: "GPST", nanos_since_j2000: second_ns}
    first = sample(first_epoch)
    second = sample(second_epoch)

    assert first.epoch != second.epoch
    assert first_ns / 1_000_000_000 == second_ns / 1_000_000_000

    {:ok, first_term} = PreciseEphemerisSample.to_nif_tuple(first)
    {:ok, second_term} = PreciseEphemerisSample.to_nif_tuple(second)
    assert elem(first_term, 2) != elem(second_term, 2)
    assert PreciseEphemerisSample.from_nif_tuple(first_term).epoch == first_epoch
    assert PreciseEphemerisSample.from_nif_tuple(second_term).epoch == second_epoch

    sidecar = %PreciseEphemerisAccuracySample{
      sat: "G01",
      epoch: first_epoch,
      position_variance_m2: {{:known, 1.0}, {:known, 1.0}, {:known, 1.0}},
      clock_variance_m2: {:known, 1.0}
    }

    {:ok, sidecar_term} =
      PreciseEphemerisAccuracySample.to_nif_tuple(sidecar)

    assert elem(sidecar_term, 2) == elem(first_term, 2)
    assert elem(sidecar_term, 2) != elem(second_term, 2)

    assert PreciseEphemerisAccuracySample.from_nif_tuple(sidecar_term).epoch ==
             first_epoch
  end

  defp sample(epoch) do
    %PreciseEphemerisSample{
      sat: "G01",
      epoch: epoch,
      position_ecef_m: {1.0, 2.0, 3.0},
      clock_s: nil,
      clock_event: false
    }
  end
end
