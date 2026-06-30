defmodule Sidereon.OMMTest do
  use ExUnit.Case

  alias Sidereon.Format.OMM
  alias Sidereon.Format.TLE

  @fixtures_dir Path.join(__DIR__, "fixtures/celestrak")
  @core_omm_dir Path.join(__DIR__, "fixtures/core/omm")

  setup do
    omms = Path.join(@fixtures_dir, "stations.json") |> File.read!() |> Jason.decode!()
    iss_omm = Enum.find(omms, &(&1["NORAD_CAT_ID"] == 25_544))
    %{omms: omms, iss_omm: iss_omm}
  end

  describe "parse/1" do
    test "parses ISS OMM record", %{iss_omm: omm} do
      {:ok, tle} = OMM.parse(omm)
      assert tle.catalog_number == "25544"
      assert tle.inclination_deg > 51.0 and tle.inclination_deg < 52.0
      assert tle.eccentricity > 0.0 and tle.eccentricity < 0.01
      assert tle.mean_motion > 15.0 and tle.mean_motion < 16.0
      assert tle.object_name == "ISS (ZARYA)"
    end

    test "parses all station OMMs", %{omms: omms} do
      results = Enum.map(omms, &OMM.parse/1)
      ok_count = Enum.count(results, &match?({:ok, _}, &1))
      assert ok_count == length(omms)
    end
  end

  describe "propagation from OMM" do
    test "OMM-sourced TLE propagates correctly", %{iss_omm: omm} do
      {:ok, tle} = OMM.parse(omm)
      {:ok, teme} = Sidereon.propagate(tle, tle.epoch)

      {x, y, z} = teme.position
      radius = :math.sqrt(x * x + y * y + z * z)
      assert radius > 6500 and radius < 7200
    end
  end

  describe "encode/1" do
    test "round-trips through OMM", %{iss_omm: original} do
      {:ok, tle} = OMM.parse(original)
      omm = OMM.encode(tle)

      assert omm["NORAD_CAT_ID"] == 25_544
      assert_in_delta omm["INCLINATION"], original["INCLINATION"], 1.0e-10
      assert_in_delta omm["ECCENTRICITY"], original["ECCENTRICITY"], 1.0e-10
      assert_in_delta omm["MEAN_MOTION"], original["MEAN_MOTION"], 1.0e-10
    end
  end

  describe "text OMM parsing" do
    test "parses KVN, XML, and JSON fixtures into typed OMM structs" do
      {:ok, kvn} = OMM.parse_kvn(core_omm_fixture("25544", "kvn"))
      {:ok, xml} = OMM.parse_xml(core_omm_fixture("25544", "xml"))
      {:ok, json} = OMM.parse_json(core_omm_fixture("25544", "json"))

      assert %OMM{} = kvn
      assert kvn.ccsds_omm_vers == "2.0"
      assert kvn.object_name == "ISS (ZARYA)"
      assert kvn.object_id == "1998-067A"
      assert kvn.norad_cat_id == 25_544

      assert kvn.epoch == %OMM.Epoch{
               year: 2026,
               month: 6,
               day: 17,
               hour: 4,
               minute: 32,
               second: 52,
               microsecond: 99_296
             }

      assert canonical_omm(xml) == canonical_omm(kvn)
      assert canonical_omm(json) == canonical_omm(kvn)
    end

    test "parse/1 auto-detects text encodings" do
      assert {:ok, %OMM{norad_cat_id: 25_544}} = OMM.parse(core_omm_fixture("25544", "kvn"))
      assert {:ok, %OMM{norad_cat_id: 25_544}} = OMM.parse(core_omm_fixture("25544", "xml"))
      assert {:ok, %OMM{norad_cat_id: 25_544}} = OMM.parse(core_omm_fixture("25544", "json"))
    end
  end

  describe "text OMM serialization" do
    test "round-trips through KVN, XML, and JSON encoders" do
      {:ok, omm} = OMM.parse_kvn(core_omm_fixture("24876", "kvn"))

      for {encode, parse} <- [
            {&OMM.encode_kvn/1, &OMM.parse_kvn/1},
            {&OMM.encode_xml/1, &OMM.parse_xml/1},
            {&OMM.encode_json/1, &OMM.parse_json/1}
          ] do
        {:ok, text} = encode.(omm)
        {:ok, reparsed} = parse.(text)

        assert canonical_omm(reparsed) == canonical_omm(omm)
        assert reparsed.epoch == omm.epoch
      end
    end

    test "core-style to_*_string aliases serialize typed OMMs" do
      {:ok, omm} = OMM.parse_json(core_omm_fixture("28884", "json"))

      assert {:ok, kvn} = OMM.to_kvn_string(omm)
      assert String.contains?(kvn, "CCSDS_OMM_VERS = 2.0")

      assert {:ok, xml} = OMM.to_xml_string(omm)
      assert String.contains?(xml, "<omm ")

      assert {:ok, json} = OMM.to_json_string(omm)
      assert Jason.decode!(json)["NORAD_CAT_ID"] == 28_884
    end
  end

  describe "typed OMM conversion" do
    test "to_elements/1 matches the matching TLE fixture" do
      {:ok, omm} = OMM.parse_kvn(core_omm_fixture("25544", "kvn"))
      {:ok, elements} = OMM.to_elements(omm)
      [_, line1, line2] = core_omm_fixture("25544", "tle") |> String.split("\n", trim: true)
      {:ok, tle_elements} = TLE.parse(line1, line2)

      assert elements.catalog_number == tle_elements.catalog_number
      assert elements.epoch == tle_elements.epoch
      assert elements.inclination_deg == tle_elements.inclination_deg
      assert elements.raan_deg == tle_elements.raan_deg
      assert elements.eccentricity == tle_elements.eccentricity
      assert elements.arg_perigee_deg == tle_elements.arg_perigee_deg
      assert elements.mean_anomaly_deg == tle_elements.mean_anomaly_deg
      assert elements.mean_motion == tle_elements.mean_motion
      assert_in_delta elements.bstar, tle_elements.bstar, 1.0e-18
    end
  end

  defp core_omm_fixture(catalog_number, extension) do
    @core_omm_dir
    |> Path.join("#{catalog_number}.#{extension}")
    |> File.read!()
  end

  defp canonical_omm(%OMM{} = omm) do
    Map.take(omm, [
      :object_name,
      :object_id,
      :epoch,
      :mean_motion,
      :eccentricity,
      :inclination_deg,
      :ra_of_asc_node_deg,
      :arg_of_pericenter_deg,
      :mean_anomaly_deg,
      :ephemeris_type,
      :classification_type,
      :norad_cat_id,
      :element_set_no,
      :rev_at_epoch,
      :bstar,
      :mean_motion_dot,
      :mean_motion_ddot
    ])
  end
end
