defmodule Sidereon.Format.OMMFullDtoFieldsTest do
  use ExUnit.Case, async: true

  alias Sidereon.Format.OMM

  @fixture "test/fixtures/core/omm/25544.kvn"

  test "public KVN and XML routes retain nested spacecraft, covariance and comments" do
    {:ok, base} = @fixture |> File.read!() |> OMM.parse_kvn()

    assert base.ccsds_omm_vers == "2.0"
    assert base.classification == nil
    assert base.creation_date == nil
    assert base.originator == nil
    assert base.message_id == nil
    assert base.object_name == "ISS (ZARYA)"
    assert base.object_id == "1998-067A"
    assert base.center_name == "EARTH"
    assert base.ref_frame == "TEME"
    assert base.ref_frame_epoch == nil
    assert base.time_system == "UTC"
    assert base.mean_element_theory == "SGP/SGP4"

    assert base.epoch == %OMM.Epoch{
             year: 2026,
             month: 6,
             day: 17,
             hour: 4,
             minute: 32,
             second: 52,
             microsecond: 99_296,
             femtosecond: 0
           }

    assert base.mean_motion == 15.49273435
    assert base.semi_major_axis_km == nil
    assert base.eccentricity == 0.0004737
    assert base.inclination_deg == 51.6332
    assert base.ra_of_asc_node_deg == 300.0813
    assert base.arg_of_pericenter_deg == 195.1146
    assert base.mean_anomaly_deg == 164.9702
    assert base.gm_km3_s2 == nil
    assert base.spacecraft == nil
    assert base.ephemeris_type == 0
    assert base.classification_type == "U"
    assert base.norad_cat_id == 25_544
    assert base.element_set_no == 999
    assert base.rev_at_epoch == 57_175
    assert base.bstar == 0.00017172
    assert base.bterm_m2_kg == nil
    assert base.mean_motion_dot == 0.00009113
    assert base.mean_motion_ddot == 0.0
    assert base.agom_m2_kg == nil
    assert base.covariance == nil
    assert base.user_defined == []
    assert base.comments == %OMM.Comments{}
    assert base.exact_sgp4_epoch == nil
    assert base.quantize_tle_derived_fields

    spacecraft = %OMM.Spacecraft{
      comments: ["spacecraft details"],
      mass_kg: 1250.5,
      solar_rad_area_m2: 22.25,
      solar_rad_coeff: 1.125,
      drag_area_m2: 18.5,
      drag_coeff: 2.25
    }

    covariance = %OMM.Covariance{
      comments: ["covariance details"],
      cov_ref_frame: "TEME",
      lower_triangle: Enum.map(1..21, &(&1 / 8))
    }

    omm = %{
      base
      | classification: "U",
        creation_date: "2026-06-17T00:00:00.000",
        originator: "SIDEREON TEST",
        message_id: "CDM-OMM-1",
        object_id: "2024-001A",
        center_name: "EARTH",
        ref_frame_epoch: "J2000",
        time_system: "UTC",
        mean_element_theory: "SGP/SGP4",
        mean_motion: 15.125,
        semi_major_axis_km: 7000.25,
        gm_km3_s2: 398_600.5,
        spacecraft: spacecraft,
        ephemeris_type: 0,
        classification_type: "U",
        norad_cat_id: 90_001,
        element_set_no: 1024,
        rev_at_epoch: 12_345,
        bstar: 0.000125,
        bterm_m2_kg: 0.00025,
        mean_motion_dot: 0.000375,
        mean_motion_ddot: 0.0005,
        agom_m2_kg: 0.000625,
        covariance: covariance,
        user_defined: [
          %OMM.UserDefined{parameter: "MISSION", value: "TEST FLIGHT"},
          %OMM.UserDefined{parameter: "NOTE", value: "RETAIN THIS"}
        ],
        comments: %OMM.Comments{
          header: ["header details"],
          metadata: ["metadata details"],
          mean_elements: ["element details"],
          tle_parameters: ["tle details"],
          user_defined: ["user parameter details"]
        }
    }

    for {encode, parse} <- [
          {&OMM.encode_kvn/1, &OMM.parse_kvn/1},
          {&OMM.encode_xml/1, &OMM.parse_xml/1}
        ] do
      assert {:ok, text} = encode.(omm)
      assert {:ok, reparsed} = parse.(text)
      assert reparsed == omm
      assert reparsed.spacecraft == spacecraft
      assert reparsed.covariance == covariance
      assert reparsed.user_defined == omm.user_defined
      assert reparsed.comments == omm.comments
    end
  end
end
