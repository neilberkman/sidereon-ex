defmodule Sidereon.CelesTrakTest do
  use ExUnit.Case

  # Tests use cached fixtures to avoid hitting CelesTrak on every run.
  # Fixtures were captured from live CelesTrak responses.
  # To refresh: mix run scripts/refresh_celestrak_fixtures.exs

  @fixtures_dir Path.join(__DIR__, "fixtures/celestrak")

  describe "TLE parsing from CelesTrak responses" do
    test "parses ISS TLE" do
      body = File.read!(Path.join(@fixtures_dir, "iss.tle"))
      {:ok, tles} = parse_tle_body(body)
      assert length(tles) == 1
      tle = hd(tles)
      assert tle.catalog_number == "25544"
      assert tle.inclination_deg > 51.0 and tle.inclination_deg < 52.0
    end

    test "parses stations group" do
      body = File.read!(Path.join(@fixtures_dir, "stations.tle"))
      {:ok, tles} = parse_tle_body(body)
      assert length(tles) > 5
      assert Enum.any?(tles, &(&1.catalog_number == "25544"))
    end

    test "parses ISS search result" do
      body = File.read!(Path.join(@fixtures_dir, "iss_search.tle"))
      {:ok, tles} = parse_tle_body(body)
      assert length(tles) >= 1
      assert hd(tles).catalog_number == "25544"
    end

    test "parses OMM JSON" do
      body = File.read!(Path.join(@fixtures_dir, "stations.json"))
      omms = Jason.decode!(body)
      assert is_list(omms)
      refute Enum.empty?(omms)

      iss = Enum.find(omms, &(&1["NORAD_CAT_ID"] == 25544))
      assert iss != nil
      assert iss["OBJECT_NAME"] =~ "ISS"
    end
  end

  describe "fetch and propagate" do
    test "parsed TLE can be propagated" do
      body = File.read!(Path.join(@fixtures_dir, "iss.tle"))
      {:ok, [tle]} = parse_tle_body(body)

      # Propagate to the TLE's own epoch (should always work)
      {:ok, teme} = Sidereon.propagate(tle, tle.epoch)

      {x, y, z} = teme.position
      radius = :math.sqrt(x * x + y * y + z * z)
      # ISS is in LEO
      assert radius > 6500 and radius < 7200
    end
  end

  describe "groups/0" do
    test "returns list of group names" do
      groups = Sidereon.CelesTrak.groups()
      assert "stations" in groups
      assert "starlink" in groups
      assert "active" in groups
    end
  end

  describe "disabled live HTTP client" do
    setup do
      Application.put_env(:sidereon, :celestrak_req_available, false)
      on_exit(fn -> Application.delete_env(:sidereon, :celestrak_req_available) end)
      :ok
    end

    test "TLE live fetches return a typed error when live HTTP is disabled" do
      assert {:error, :req_not_available} = Sidereon.CelesTrak.fetch_tle(25544)
      assert {:error, :req_not_available} = Sidereon.CelesTrak.fetch_group("stations")
      assert {:error, :req_not_available} = Sidereon.CelesTrak.search("ISS")
    end

    test "OMM live fetch returns a typed error when live HTTP is disabled" do
      assert {:error, :req_not_available} = Sidereon.CelesTrak.fetch_omm("gps-ops")
    end
  end

  # Reuse the internal parsing logic from CelesTrak module
  defp parse_tle_body(body) do
    lines =
      body
      |> String.trim()
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    tles =
      lines
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.reduce([], fn
        ["1 " <> _ = l1, "2 " <> _ = l2], acc ->
          case Sidereon.Format.TLE.parse(l1, l2) do
            {:ok, tle} -> [tle | acc]
            _ -> acc
          end

        _, acc ->
          acc
      end)
      |> Enum.reverse()

    if tles == [], do: {:error, "no TLEs"}, else: {:ok, tles}
  end
end
