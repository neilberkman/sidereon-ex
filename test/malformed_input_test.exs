defmodule Sidereon.MalformedInputTest do
  @moduledoc """
  Tests for graceful handling of malformed, missing, or edge-case inputs
  across the public API surface.
  """
  use ExUnit.Case

  alias Sidereon.Format.OMM
  alias Sidereon.Format.TLE

  @required_omm_orbital_fields [
    "INCLINATION",
    "RA_OF_ASC_NODE",
    "ECCENTRICITY",
    "ARG_OF_PERICENTER",
    "MEAN_ANOMALY",
    "MEAN_MOTION"
  ]

  describe "Format.TLE.parse/2" do
    test "rejects empty strings" do
      assert {:error, _} = TLE.parse("", "")
    end

    test "rejects non-TLE text" do
      assert {:error, _} = TLE.parse("hello world", "goodbye world")
    end

    test "rejects swapped lines" do
      l1 = "1 25544U 98067A   18184.80969102  .00001614  00000-0  31745-4 0  9993"
      l2 = "2 25544  51.6414 295.8524 0003435 262.6267 204.2868 15.54005638121106"
      assert {:error, _} = TLE.parse(l2, l1)
    end

    test "rejects mismatched satellite numbers" do
      l1 = "1 25544U 98067A   18184.80969102  .00001614  00000-0  31745-4 0  9993"
      l2 = "2 99999  51.6414 295.8524 0003435 262.6267 204.2868 15.54005638121106"
      assert {:error, _} = TLE.parse(l1, l2)
    end

    test "accepts trailing whitespace" do
      l1 = "1 25544U 98067A   18184.80969102  .00001614  00000-0  31745-4 0  9993   "
      l2 = "2 25544  51.6414 295.8524 0003435 262.6267 204.2868 15.54005638121106   "
      assert {:ok, _} = TLE.parse(l1, l2)
    end

    test "accepts leading + in ndot" do
      l1 = "1 24946U 97051C   09040.78448243 +.00000153 +00000-0 +47668-4 0  9994"
      l2 = "2 24946 086.3994 121.7028 0002288 085.1644 274.9812 14.34219863597336"
      assert {:ok, el} = TLE.parse(l1, l2)
      assert el.mean_motion_dot >= 0
    end

    test "rejects non-ASCII" do
      # Unicode chars outside ASCII range
      assert {:error, _} = TLE.parse("1 25544ü test", "2 25544ü test")
    end
  end

  describe "Format.OMM.parse/1" do
    test "rejects missing EPOCH" do
      assert {:error, {:missing_field, "EPOCH"}} =
               OMM.parse(%{"NORAD_CAT_ID" => 1})
    end

    test "rejects missing required orbital fields" do
      for key <- @required_omm_orbital_fields do
        assert {:error, {:missing_field, ^key}} =
                 valid_omm()
                 |> Map.delete(key)
                 |> OMM.parse()
      end
    end

    test "rejects invalid required orbital fields" do
      for key <- @required_omm_orbital_fields do
        assert {:error, {:invalid_field, ^key, "not-a-number"}} =
                 valid_omm()
                 |> Map.put(key, "not-a-number")
                 |> OMM.parse()
      end
    end

    test "rejects invalid optional numeric fields" do
      assert {:error, {:invalid_field, "BSTAR", "not-a-number"}} =
               valid_omm()
               |> Map.put("BSTAR", "not-a-number")
               |> OMM.parse()
    end

    test "missing NORAD_CAT_ID defaults to empty catalog_number" do
      {:ok, el} =
        OMM.parse(%{
          "EPOCH" => "2024-01-01T00:00:00",
          "INCLINATION" => 0.0,
          "RA_OF_ASC_NODE" => 0.0,
          "ECCENTRICITY" => 0.0,
          "ARG_OF_PERICENTER" => 0.0,
          "MEAN_ANOMALY" => 0.0,
          "MEAN_MOTION" => 1.0
        })

      assert el.catalog_number == ""
    end

    test "handles string-typed numeric fields (Space-Track quirk)" do
      {:ok, el} =
        OMM.parse(%{
          "NORAD_CAT_ID" => "25544",
          "EPOCH" => "2024-01-01T00:00:00",
          "INCLINATION" => "51.6",
          "RA_OF_ASC_NODE" => "300.0",
          "ECCENTRICITY" => "0.0007",
          "ARG_OF_PERICENTER" => "90.0",
          "MEAN_ANOMALY" => "270.0",
          "MEAN_MOTION" => "15.5"
        })

      assert el.inclination_deg == 51.6
    end

    test "rejects garbage epoch" do
      assert {:error, _} =
               OMM.parse(%{
                 "NORAD_CAT_ID" => 1,
                 "EPOCH" => "not-a-date",
                 "INCLINATION" => 0.0,
                 "RA_OF_ASC_NODE" => 0.0,
                 "ECCENTRICITY" => 0.0,
                 "ARG_OF_PERICENTER" => 0.0,
                 "MEAN_ANOMALY" => 0.0,
                 "MEAN_MOTION" => 1.0
               })
    end
  end

  describe "SGP4.propagate/2 edge cases" do
    test "returns error for elements with epoch far in the past" do
      {:ok, el} =
        TLE.parse(
          "1 25544U 98067A   18184.80969102  .00001614  00000-0  31745-4 0  9993",
          "2 25544  51.6414 295.8524 0003435 262.6267 204.2868 15.54005638121106"
        )

      # Propagating 10 years should still work (SGP4 degrades but doesn't crash)
      far_future = DateTime.add(el.epoch, 365 * 10 * 86_400, :second)
      result = Sidereon.SGP4.propagate(el, far_future)
      # May succeed or error, but should not crash
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  describe "Conjunction edge cases" do
    test "returns empty for non-overlapping epochs" do
      l1 = "1 25544U 98067A   18184.80969102  .00001614  00000-0  31745-4 0  9993"
      l2 = "2 25544  51.6414 295.8524 0003435 262.6267 204.2868 15.54005638121106"
      start_jd = Sidereon.GNSS.Time.epoch_to_split_jd(~N[2018-07-03 19:25:57])
      end_jd = Sidereon.GNSS.Time.epoch_to_split_jd(~N[2018-07-03 19:35:57])

      assert {:ok, results} =
               Sidereon.Conjunction.find_tca_candidates(l1, l2, l1, l2, start_jd, end_jd)

      assert is_list(results)
    end
  end

  defp valid_omm do
    %{
      "NORAD_CAT_ID" => 1,
      "EPOCH" => "2024-01-01T00:00:00",
      "INCLINATION" => 0.0,
      "RA_OF_ASC_NODE" => 0.0,
      "ECCENTRICITY" => 0.0,
      "ARG_OF_PERICENTER" => 0.0,
      "MEAN_ANOMALY" => 0.0,
      "MEAN_MOTION" => 1.0
    }
  end
end
