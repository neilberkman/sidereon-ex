defmodule Sidereon.CCSDS.CDMTopLevelFieldsTest do
  use ExUnit.Case, async: true

  alias Sidereon.CCSDS.CDM

  @kvn_path "test/fixtures/cdm/ccsds_example2.kvn"

  test "public KVN and XML readers retain exact message metadata and times" do
    {:ok, kvn} = @kvn_path |> File.read!() |> CDM.parse_kvn()
    {:ok, xml_text} = CDM.encode_xml(kvn)
    {:ok, xml} = CDM.parse_xml(xml_text)

    for cdm <- [kvn, xml] do
      assert cdm.ccsds_cdm_vers == "1.0"
      assert cdm.comments == []
      assert cdm.creation_date == ~U[2010-03-12 22:31:12.000Z]
      assert cdm.originator == "JSPOC"
      assert cdm.message_for == "SATELLITE A"
      assert cdm.message_id == "201113719185"
      assert cdm.relative_comments == ["Relative Metadata/Data"]
      assert cdm.tca == ~U[2010-03-13 22:37:52.618Z]
      assert cdm.miss_distance_m == 715.0
      assert cdm.relative_speed_m_s == 14_762.0
      assert cdm.relative_position_rtn_m == {27.4, -70.2, 711.8}
      assert cdm.relative_velocity_rtn_m_s == {-7.2, -14_692.0, -1437.2}
      assert cdm.start_screen_period == "2010-03-12T18:29:32.212"
      assert cdm.stop_screen_period == "2010-03-15T18:29:32.212"
      assert cdm.screen_volume_frame == "RTN"
      assert cdm.screen_volume_shape == "ELLIPSOID"
      assert cdm.screen_volume_m == {200.0, 1000.0, 1000.0}
      assert cdm.screen_entry_time == "2010-03-13T22:37:52.222"
      assert cdm.screen_exit_time == "2010-03-13T22:37:52.824"
      assert cdm.collision_probability == 4.835e-5
      assert cdm.collision_probability_method == "FOSTER-1992"
      assert cdm.hard_body_radius_m == nil
    end

    assert Map.from_struct(kvn) == Map.from_struct(xml)
  end

  test "absent message optionals and component-wise zero values round-trip" do
    {:ok, base} = @kvn_path |> File.read!() |> CDM.parse_kvn()

    cdm = %{
      base
      | ccsds_cdm_vers: nil,
        comments: [],
        creation_date: base.creation_date,
        originator: nil,
        message_for: nil,
        message_id: base.message_id,
        relative_comments: [],
        tca: base.tca,
        miss_distance_m: nil,
        relative_speed_m_s: nil,
        relative_position_rtn_m: {0.0, nil, 0.0},
        relative_velocity_rtn_m_s: {nil, 0.0, nil},
        start_screen_period: nil,
        stop_screen_period: nil,
        screen_volume_frame: nil,
        screen_volume_shape: nil,
        screen_volume_m: {0.0, nil, 0.0},
        screen_entry_time: nil,
        screen_exit_time: nil,
        collision_probability: nil,
        collision_probability_method: nil,
        hard_body_radius_m: nil
    }

    for {encode, parse} <- [
          {&CDM.encode_kvn/1, &CDM.parse_kvn/1},
          {&CDM.encode_xml/1, &CDM.parse_xml/1}
        ] do
      assert {:ok, text} = encode.(cdm)
      assert {:ok, reparsed} = parse.(text)
      assert Map.from_struct(reparsed) == Map.from_struct(cdm)
    end
  end
end
