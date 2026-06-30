defmodule Sidereon.RoundtripTest do
  @moduledoc """
  Round-trip tests: parse → encode → parse produces equivalent elements.
  """
  use ExUnit.Case

  alias Sidereon.Format.OMM
  alias Sidereon.Format.TLE

  @fixtures_dir Path.join(__DIR__, "fixtures/celestrak")

  describe "TLE round-trip" do
    test "ISS TLE round-trips character-exact" do
      l1 = "1 25544U 98067A   18184.80969102  .00001614  00000-0  31745-4 0  9993"
      l2 = "2 25544  51.6414 295.8524 0003435 262.6267 204.2868 15.54005638121106"

      {:ok, el} = TLE.parse(l1, l2)
      {:ok, {gen_l1, gen_l2}} = TLE.encode(el)

      assert gen_l1 == l1
      assert gen_l2 == l2
    end

    test "all stations TLEs round-trip" do
      body = File.read!(Path.join(@fixtures_dir, "stations.tle"))

      lines =
        body
        |> String.trim()
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      # Extract TLE pairs from 3-line format (name + line1 + line2)
      tle_pairs =
        lines
        |> Enum.chunk_every(3, 3, :discard)
        |> Enum.filter(fn
          [_, "1 " <> _, "2 " <> _] -> true
          _ -> false
        end)
        |> Enum.map(fn [_name, l1, l2] -> [l1, l2] end)

      assert length(tle_pairs) > 10

      for [l1, l2] <- tle_pairs do
        {:ok, el} = TLE.parse(l1, l2)
        {:ok, {gen_l1, gen_l2}} = TLE.encode(el)

        # Line 2 should be exact
        assert gen_l2 == l2, "Line 2 mismatch for #{el.catalog_number}"

        # Line 1: allow +0 vs -0 for zero-valued exponent fields (nddot, bstar)
        # and checksum differences that result from that
        l1_norm = l1 |> String.replace("+0 ", "-0 ") |> String.slice(0, 68)
        gen_l1_norm = gen_l1 |> String.slice(0, 68)
        assert gen_l1_norm == l1_norm, "Line 1 mismatch for #{el.catalog_number}"
      end
    end
  end

  describe "OMM round-trip" do
    test "all stations OMMs round-trip" do
      omms = Path.join(@fixtures_dir, "stations.json") |> File.read!() |> Jason.decode!()

      for omm <- omms do
        {:ok, el} = OMM.parse(omm)
        encoded = OMM.encode(el)

        # Numeric fields should be identical
        assert encoded["NORAD_CAT_ID"] == omm["NORAD_CAT_ID"]
        assert_in_delta encoded["INCLINATION"], omm["INCLINATION"], 1.0e-12
        assert_in_delta encoded["ECCENTRICITY"], omm["ECCENTRICITY"], 1.0e-12
        assert_in_delta encoded["MEAN_MOTION"], omm["MEAN_MOTION"], 1.0e-12
        assert_in_delta encoded["RA_OF_ASC_NODE"], omm["RA_OF_ASC_NODE"], 1.0e-12

        # Object name preserved
        assert encoded["OBJECT_NAME"] == omm["OBJECT_NAME"]
      end
    end
  end

  describe "TLE → OMM → TLE cross-format" do
    test "elements survive TLE → OMM → back" do
      l1 = "1 25544U 98067A   18184.80969102  .00001614  00000-0  31745-4 0  9993"
      l2 = "2 25544  51.6414 295.8524 0003435 262.6267 204.2868 15.54005638121106"

      {:ok, el1} = TLE.parse(l1, l2)
      omm = OMM.encode(el1)
      {:ok, el2} = OMM.parse(omm)

      # Core elements should match
      assert el1.catalog_number == el2.catalog_number
      assert_in_delta el1.inclination_deg, el2.inclination_deg, 1.0e-10
      assert_in_delta el1.eccentricity, el2.eccentricity, 1.0e-10
      assert_in_delta el1.mean_motion, el2.mean_motion, 1.0e-10
      assert_in_delta el1.raan_deg, el2.raan_deg, 1.0e-10
      assert_in_delta el1.arg_perigee_deg, el2.arg_perigee_deg, 1.0e-10
      assert_in_delta el1.mean_anomaly_deg, el2.mean_anomaly_deg, 1.0e-10
    end
  end
end
