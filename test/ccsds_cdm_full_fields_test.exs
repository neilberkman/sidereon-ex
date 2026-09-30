defmodule Sidereon.CCSDS.CDMFullFieldsTest do
  @moduledoc """
  CDM comprehensive-field round-trip tests: the full CCSDS metadata block and the
  RTN velocity covariance must survive parse -> encode -> parse through the
  binding, matching what the core `CdmObject` carries.
  """
  use ExUnit.Case, async: true

  alias Sidereon.CCSDS.CDM

  @fixture_path "test/fixtures/cdm/ccsds_example2.kvn"

  # Distinct values per slot so a reordered or dropped element is caught.
  @velocity_covariance for i <- 1..15, do: i * 1.0e-4

  setup_all do
    {:ok, base} = @fixture_path |> File.read!() |> CDM.parse()

    enriched_object = %{
      base.object1
      | operator_contact_position: "FLIGHT DIRECTOR",
        operator_organization: "SIDEREON OPS",
        operator_phone: "+1-555-0100",
        operator_email: "ops@example.test",
        ephemeris_name: "NONE",
        covariance_method: "CALCULATED",
        maneuverable: "NO",
        orbit_center: "EARTH",
        gravity_model: "EGM-96: 36D 36O",
        atmospheric_model: "JACCHIA 70 DCA",
        n_body_perturbations: "MOON, SUN",
        solar_rad_pressure: "YES",
        earth_tides: "YES",
        intrack_thrust: "NO",
        velocity_covariance_rtn: @velocity_covariance
    }

    %{cdm: %{base | object1: enriched_object}}
  end

  defp assert_full_metadata_survives(obj) do
    assert obj.operator_contact_position == "FLIGHT DIRECTOR"
    assert obj.operator_organization == "SIDEREON OPS"
    assert obj.operator_phone == "+1-555-0100"
    assert obj.operator_email == "ops@example.test"
    assert obj.ephemeris_name == "NONE"
    assert obj.covariance_method == "CALCULATED"
    assert obj.maneuverable == "NO"
    assert obj.orbit_center == "EARTH"
    assert obj.gravity_model == "EGM-96: 36D 36O"
    assert obj.atmospheric_model == "JACCHIA 70 DCA"
    assert obj.n_body_perturbations == "MOON, SUN"
    assert obj.solar_rad_pressure == "YES"
    assert obj.earth_tides == "YES"
    assert obj.intrack_thrust == "NO"
  end

  defp assert_velocity_covariance_survives(obj) do
    assert length(obj.velocity_covariance_rtn) == 15

    Enum.zip(obj.velocity_covariance_rtn, @velocity_covariance)
    |> Enum.each(fn {got, expected} -> assert_in_delta got, expected, 1.0e-12 end)
  end

  test "KVN round-trip preserves the full metadata block and velocity covariance", %{cdm: cdm} do
    {:ok, kvn} = CDM.encode_kvn(cdm)
    assert {:ok, reparsed} = CDM.parse_kvn(kvn)

    assert_full_metadata_survives(reparsed.object1)
    assert_velocity_covariance_survives(reparsed.object1)
  end

  test "XML round-trip preserves the full metadata block and velocity covariance", %{cdm: cdm} do
    {:ok, xml} = CDM.encode_xml(cdm)
    assert {:ok, reparsed} = CDM.parse_xml(xml)

    assert_full_metadata_survives(reparsed.object1)
    assert_velocity_covariance_survives(reparsed.object1)
  end

  test "object2's own velocity covariance from the fixture round-trips unchanged", %{cdm: cdm} do
    # The fixture's object2 carries a full velocity covariance block; the old
    # `None` stub dropped it. It must now survive the round trip element-for-element.
    original = cdm.object2.velocity_covariance_rtn
    assert length(original) == 15

    {:ok, kvn} = CDM.encode_kvn(cdm)
    assert {:ok, reparsed} = CDM.parse_kvn(kvn)

    Enum.zip(reparsed.object2.velocity_covariance_rtn, original)
    |> Enum.each(fn {got, expected} -> assert_in_delta got, expected, 1.0e-12 end)
  end

  describe "retained CDM items" do
    test "keeps the header, relative metadata/data and screening items" do
      {:ok, cdm} = @fixture_path |> File.read!() |> CDM.parse()

      assert cdm.ccsds_cdm_vers == "1.0"
      assert cdm.message_for == "SATELLITE A"
      assert cdm.relative_comments == ["Relative Metadata/Data"]
      assert cdm.relative_position_rtn_m == {27.4, -70.2, 711.8}
      assert cdm.relative_velocity_rtn_m_s == {-7.2, -14_692.0, -1437.2}
      assert cdm.start_screen_period == "2010-03-12T18:29:32.212"
      assert cdm.screen_volume_frame == "RTN"
      assert cdm.screen_volume_shape == "ELLIPSOID"
      assert cdm.screen_volume_m == {200.0, 1000.0, 1000.0}
      assert cdm.screen_exit_time == "2010-03-13T22:37:52.824"
      assert %CDM.OdParameters{} = cdm.object1.od_parameters
      assert %CDM.AdditionalParameters{} = cdm.object1.additional_parameters
    end

    test "the retained items survive a KVN and an XML round trip", %{cdm: cdm} do
      cdm = %{
        cdm
        | object1: %{
            cdm.object1
            | od_parameters: %CDM.OdParameters{obs_available: 592, obs_used: 579, weighted_rms: 1.102},
              additional_parameters: %CDM.AdditionalParameters{mass_kg: 1500.0, area_pc_m2: 5.2},
              drag_covariance_rtn: for(i <- 1..7, do: i * 1.0e-6)
          }
      }

      for {encode, parse} <- [{&CDM.encode_kvn/1, &CDM.parse_kvn/1}, {&CDM.encode_xml/1, &CDM.parse_xml/1}] do
        assert {:ok, text} = encode.(cdm)
        assert {:ok, reparsed} = parse.(text)

        for field <- [
              :ccsds_cdm_vers,
              :message_for,
              :relative_comments,
              :relative_position_rtn_m,
              :relative_velocity_rtn_m_s,
              :start_screen_period,
              :stop_screen_period,
              :screen_volume_m,
              :screen_entry_time,
              :screen_exit_time
            ] do
          assert Map.fetch!(reparsed, field) == Map.fetch!(cdm, field)
        end

        assert reparsed.object1.od_parameters == cdm.object1.od_parameters
        assert reparsed.object1.additional_parameters == cdm.object1.additional_parameters
        assert reparsed.object1.drag_covariance_rtn == cdm.object1.drag_covariance_rtn
      end
    end

    test "refuses a covariance row group of the wrong length", %{cdm: cdm} do
      cdm = %{cdm | object1: %{cdm.object1 | covariance_rtn: [1.0, 2.0]}}
      assert {:error, {:invalid_length, :covariance_rtn, 6, 2}} = CDM.encode_kvn(cdm)
    end
  end
end
