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

      # CelesTrak GP JSON states no version, and none is filled in.
      assert omm.ccsds_omm_vers == nil
      assert {:ok, kvn} = OMM.to_kvn_string(omm)
      refute String.contains?(kvn, "CCSDS_OMM_VERS")
      assert {:ok, kvn} = OMM.to_kvn_string(%{omm | ccsds_omm_vers: "2.0"})
      assert String.contains?(kvn, "CCSDS_OMM_VERS = 2.0")

      assert {:ok, xml} = OMM.to_xml_string(omm)
      assert String.contains?(xml, "<omm>\n")
      assert {:ok, xml} = OMM.to_xml_string(%{omm | ccsds_omm_vers: "2.0"})
      assert String.contains?(xml, ~s(<omm id="CCSDS_OMM_VERS" version="2.0">))

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

  @full_kvn """
  CCSDS_OMM_VERS = 3.0
  COMMENT header note
  CLASSIFICATION = unclassified
  CREATION_DATE = 2026-06-17T00:00:00
  ORIGINATOR = TEST
  MESSAGE_ID = OMM-0001
  COMMENT metadata note
  OBJECT_NAME = ISS (ZARYA)
  OBJECT_ID = 1998-067A
  CENTER_NAME = EARTH
  REF_FRAME = TEME
  TIME_SYSTEM = UTC
  MEAN_ELEMENT_THEORY = SGP/SGP4
  COMMENT elements note
  EPOCH = 2026-06-17T04:32:52.099296
  MEAN_MOTION = 15.49273435
  ECCENTRICITY = .0004737
  INCLINATION = 51.6332
  RA_OF_ASC_NODE = 300.0813
  ARG_OF_PERICENTER = 195.1146
  MEAN_ANOMALY = 164.9702
  GM = 398600.4418
  COMMENT spacecraft note
  MASS = 420000
  DRAG_AREA = 1500
  DRAG_COEFF = 2.2
  EPHEMERIS_TYPE = 0
  CLASSIFICATION_TYPE = U
  NORAD_CAT_ID = 25544
  ELEMENT_SET_NO = 999
  REV_AT_EPOCH = 57175
  BSTAR = .17172E-3
  MEAN_MOTION_DOT = .9113E-4
  MEAN_MOTION_DDOT = 0
  COV_REF_FRAME = TEME
  CX_X = 1.0
  CY_X = 0.1
  CY_Y = 1.0
  CZ_X = 0.1
  CZ_Y = 0.1
  CZ_Z = 1.0
  CX_DOT_X = 0.01
  CX_DOT_Y = 0.01
  CX_DOT_Z = 0.01
  CX_DOT_X_DOT = 0.001
  CY_DOT_X = 0.01
  CY_DOT_Y = 0.01
  CY_DOT_Z = 0.01
  CY_DOT_X_DOT = 0.0001
  CY_DOT_Y_DOT = 0.001
  CZ_DOT_X = 0.01
  CZ_DOT_Y = 0.01
  CZ_DOT_Z = 0.01
  CZ_DOT_X_DOT = 0.0001
  CZ_DOT_Y_DOT = 0.0001
  CZ_DOT_Z_DOT = 0.001
  USER_DEFINED_OPERATOR = NASA
  """

  describe "retained OMM items" do
    test "keeps header, metadata, spacecraft, covariance, user-defined and comment items" do
      assert {:ok, omm} = OMM.parse_kvn(@full_kvn)

      assert omm.ccsds_omm_vers == "3.0"
      assert omm.classification == "unclassified"
      assert omm.message_id == "OMM-0001"
      assert omm.gm_km3_s2 == 398_600.4418
      assert omm.comments.header == ["header note"]
      assert omm.comments.metadata == ["metadata note"]
      assert omm.comments.mean_elements == ["elements note"]

      assert %OMM.Spacecraft{comments: ["spacecraft note"], mass_kg: 420_000.0, drag_coeff: 2.2} =
               omm.spacecraft

      assert omm.spacecraft.solar_rad_area_m2 == nil
      assert %OMM.Covariance{cov_ref_frame: "TEME", lower_triangle: values} = omm.covariance
      assert length(values) == 21
      assert hd(values) == 1.0
      assert List.last(values) == 0.001
      assert omm.user_defined == [%OMM.UserDefined{parameter: "OPERATOR", value: "NASA"}]
    end

    test "every retained item survives a KVN and an XML round trip" do
      {:ok, omm} = OMM.parse_kvn(@full_kvn)

      for {encode, parse} <- [{&OMM.encode_kvn/1, &OMM.parse_kvn/1}, {&OMM.encode_xml/1, &OMM.parse_xml/1}] do
        assert {:ok, text} = encode.(omm)
        assert {:ok, ^omm} = parse.(text)
      end
    end

    test "GP JSON refuses comments it cannot carry unless asked to discard them" do
      {:ok, omm} = OMM.parse_kvn(@full_kvn)

      assert {:error, {:unwritable_text, field, _value, :comment_not_carried}} = OMM.encode_json(omm)
      assert is_binary(field)

      assert {:ok, json} = OMM.encode_json_discarding_comments(omm)
      assert {:ok, reparsed} = OMM.parse_json(json)
      assert reparsed.comments.metadata == []
      assert reparsed.norad_cat_id == 25_544
    end

    test "a keyword repeated with a different value is refused naming both values" do
      kvn = core_omm_fixture("25544", "kvn")
      repeated = String.replace(kvn, ~r/^(OBJECT_NAME\s*=.*)$/m, "\\1\nOBJECT_NAME    = ISS DUPLICATE", global: false)

      assert {:error, {:duplicate_field, "OBJECT_NAME", "ISS (ZARYA)", "ISS DUPLICATE"}} =
               OMM.parse_kvn(repeated)
    end

    test "a writer refuses text that would not read back unchanged" do
      {:ok, omm} = OMM.parse_kvn(core_omm_fixture("25544", "kvn"))

      assert {:error, {:unwritable_text, field, "ISS\nZARYA", :line_break}} =
               OMM.encode_kvn(%{omm | object_name: "ISS\nZARYA"})

      assert is_binary(field)
    end
  end

  describe "multi-record OMM documents" do
    test "parse_json_array/1 reads every record and reports the ones it skips" do
      [record] = core_omm_fixture("28884", "json") |> Jason.decode!()
      broken = Map.delete(record, "EPOCH")
      json = Jason.encode!([record, broken, record])

      assert {:ok, [first, second], [{1, {:missing_field, :epoch}}]} = OMM.parse_json_array(json)
      assert first.norad_cat_id == 28_884
      assert second == first
    end

    test "parse_json/1 refuses a document holding several records" do
      [record] = core_omm_fixture("28884", "json") |> Jason.decode!()
      assert {:error, {:multiple_messages, 2}} = OMM.parse_json(Jason.encode!([record, record]))
    end

    test "parse_xml_all/1 reads a single-message document" do
      assert {:ok, [omm], []} = OMM.parse_xml_all(core_omm_fixture("25544", "xml"))
      assert omm.norad_cat_id == 25_544
    end
  end

  describe "to_elements/1 SGP4 requirements" do
    test "refuses a stated theory other than SGP4 by name" do
      {:ok, omm} = OMM.parse_kvn(core_omm_fixture("25544", "kvn"))

      assert {:error, {:incompatible_metadata, :mean_element_theory, "DSST"}} =
               OMM.to_elements(%{omm | mean_element_theory: "DSST", ref_frame: "EME2000"})

      assert {:error, {:incompatible_metadata, :ref_frame, "EME2000"}} =
               OMM.to_elements(%{omm | ref_frame: "EME2000"})

      assert {:ok, _} = OMM.to_elements(%{omm | mean_element_theory: " sgp4 "})
    end

    test "refuses an OMM without MEAN_MOTION or BSTAR and keeps unstated derivatives nil" do
      {:ok, omm} = OMM.parse_kvn(core_omm_fixture("25544", "kvn"))

      assert {:error, {:missing_field, :mean_motion}} = OMM.to_elements(%{omm | mean_motion: nil})
      assert {:error, {:missing_field, :bstar}} = OMM.to_elements(%{omm | bstar: nil})

      assert {:ok, elements} = OMM.to_elements(%{omm | mean_motion_dot: nil, element_set_no: nil})
      assert elements.mean_motion_dot == nil
      assert elements.elset_number == nil
      assert {:ok, _teme} = Sidereon.propagate(elements, elements.epoch)
    end

    test "an OMM without NORAD_CAT_ID gives elements without a catalog number" do
      {:ok, omm} = OMM.parse_kvn(core_omm_fixture("25544", "kvn"))

      assert {:ok, elements} = OMM.to_elements(%{omm | norad_cat_id: nil})
      assert elements.catalog_number == nil
      assert {:ok, _teme} = Sidereon.propagate(elements, elements.epoch)

      # A TLE states a catalog number, so such elements cannot be written as one.
      assert {:error, {:missing_field, :catalog_number}} = TLE.encode(elements)
    end

    test "the epoch keeps its femtoseconds and a UTC leap second" do
      {:ok, omm} = OMM.parse_kvn(core_omm_fixture("25544", "kvn"))

      assert {:ok, whole} = OMM.to_elements(%{omm | epoch: %{omm.epoch | femtosecond: 0}})
      assert {:ok, finer} = OMM.to_elements(%{omm | epoch: %{omm.epoch | femtosecond: 500_000_000}})

      # Half a microsecond below the microsecond field: the DateTime cannot
      # show it, the Julian date the core propagates with does.
      assert finer.epoch == whole.epoch
      refute finer.epoch_jd == whole.epoch_jd

      leap = %OMM.Epoch{year: 2016, month: 12, day: 31, hour: 23, minute: 59, second: 60, microsecond: 250_000}
      assert {:ok, at_leap} = OMM.to_elements(%{omm | epoch: leap})
      assert at_leap.epoch == ~U[2017-01-01 00:00:00.250000Z]
      %{jd_whole: jd_whole, jd_fraction: jd_fraction} = at_leap.epoch_jd
      assert_in_delta jd_whole + jd_fraction, 2_457_754.5 + 0.25 / 86_400.0, 1.0e-9
    end

    test "B* and the second mean-motion derivative are quantized as the TLE fields hold them" do
      {:ok, omm} = OMM.parse_kvn(core_omm_fixture("25544", "kvn"))

      # An epoch a tenth of a microsecond off the microsecond grid is no instant
      # python-sgp4 reads, so the OMM is bridged as a TLE and B* and the second
      # derivative are quantized. The second derivative is below 1e-10, where
      # a TLE field rounds it at exponent -9 (`-00235-9`).
      finer_epoch = %{omm.epoch | femtosecond: 100_000_000}

      assert {:ok, elements} =
               OMM.to_elements(%{omm | epoch: finer_epoch, bstar: 1.23456789e-4, mean_motion_ddot: -2.3456789e-12})

      assert elements.omm_epoch_days == nil
      refute elements.mean_motion_double_dot == -2.3456789e-12
      assert_in_delta elements.mean_motion_double_dot, -2.35e-12, 1.0e-24
      refute elements.bstar == 1.23456789e-4

      # The quantized values are the ones the TLE fields state, so writing the
      # elements as a TLE and reading them back returns them unchanged. The
      # elements carry the OMM OBJECT_ID (`1998-067A`); a TLE states the
      # designator in its own eight-column form.
      assert elements.international_designator == "1998-067A"
      assert {:ok, {line1, line2}} = TLE.encode(%{elements | international_designator: "98067A"})
      assert {:ok, read} = TLE.parse(line1, line2)
      assert read.bstar == elements.bstar
      assert read.mean_motion_double_dot == elements.mean_motion_double_dot
    end

    test "an epoch of whole microseconds is initialised as python-sgp4 initialises the OMM" do
      {:ok, omm} = OMM.parse_kvn(core_omm_fixture("25544", "kvn"))

      assert {:ok, elements} = OMM.to_elements(%{omm | bstar: 1.23456789e-4, mean_motion_ddot: -2.3456789e-12})

      # python-sgp4 reads B* and the second derivative with `float()`, so the
      # element set carries them as stated, with the epoch's day count since
      # 1949-12-31.
      assert is_float(elements.omm_epoch_days)
      assert elements.bstar == 1.23456789e-4
      assert elements.mean_motion_double_dot == -2.3456789e-12
      assert {:ok, _state} = Sidereon.SGP4.propagate(elements, ~U[2026-06-17 06:00:00Z])
    end

    test "the legacy map path requires BSTAR" do
      map = %{
        "NORAD_CAT_ID" => 25_544,
        "EPOCH" => "2024-01-01T00:00:00",
        "INCLINATION" => 51.6,
        "RA_OF_ASC_NODE" => 300.0,
        "ECCENTRICITY" => 0.0007,
        "ARG_OF_PERICENTER" => 90.0,
        "MEAN_ANOMALY" => 270.0,
        "MEAN_MOTION" => 15.5
      }

      assert {:error, {:missing_field, "BSTAR"}} = OMM.parse(map)
      assert {:ok, elements} = OMM.parse(Map.put(map, "BSTAR", 0.0))
      assert elements.mean_motion_dot == nil
      assert elements.rev_number == nil
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
