defmodule Sidereon.CCSDS.OPMFullDtoFieldsTest do
  use ExUnit.Case, async: true

  alias Sidereon.CCSDS.OPM

  @fixture "test/fixtures/opm/osprey.kvn"

  test "public KVN and XML routes retain every OPM DTO field" do
    {:ok, base} = @fixture |> File.read!() |> OPM.parse_kvn()

    assert base.ccsds_opm_vers == "2.0"
    assert base.comments == []
    assert base.classification == nil
    assert base.creation_date == "2026-06-28T12:30:00.000"
    assert base.originator == "SIDEREON TEST"
    assert base.message_id == nil

    assert base.metadata == %OPM.Metadata{
             comments: ["Annotated OPM fixture for a low Earth orbit servicing spacecraft."],
             object_name: "OSPREY-1",
             object_id: "2026-045A",
             center_name: "EARTH",
             ref_frame: "EME2000",
             ref_frame_epoch: nil,
             time_system: "UTC"
           }

    assert base.state == %OPM.State{
             comments: [],
             epoch: "2026-06-28T12:00:00.000",
             position_km: {6878.137, -120.25, 410.75},
             velocity_km_s: {0.125, 7.612, 1.034}
           }

    assert base.keplerian == %OPM.Keplerian{
             comments: [],
             semi_major_axis_km: 6878.137,
             eccentricity: 0.0012,
             inclination_deg: 51.64,
             ra_of_asc_node_deg: 120.5,
             arg_of_pericenter_deg: 87.2,
             anomaly: {:true_anomaly, 42.0},
             gm_km3_s2: 398_600.4418
           }

    assert base.spacecraft == %OPM.Spacecraft{
             comments: [],
             mass_kg: 425.0,
             solar_rad_area_m2: 9.5,
             solar_rad_coeff: 1.21,
             drag_area_m2: 7.2,
             drag_coeff: 2.2
           }

    assert base.covariance == %OPM.Covariance{
             comments: [],
             cov_ref_frame: "EME2000",
             lower_triangle: [
               0.01,
               0.0,
               0.02,
               0.0,
               0.0,
               0.03,
               0.0,
               0.0,
               0.0,
               0.000001,
               0.0,
               0.0,
               0.0,
               0.0,
               0.000002,
               0.0,
               0.0,
               0.0,
               0.0,
               0.0,
               0.000003
             ]
           }

    assert base.maneuvers == [
             %OPM.Maneuver{
               comments: ["Two planned trim burns."],
               epoch_ignition: "2026-06-28T12:15:00.000",
               duration_s: 12.5,
               delta_mass_kg: -0.42,
               ref_frame: "TNW",
               dv_km_s: {0.0005, 0.001, 0.0}
             },
             %OPM.Maneuver{
               comments: [],
               epoch_ignition: "2026-06-28T13:45:00.000",
               duration_s: 8.0,
               delta_mass_kg: -0.27,
               ref_frame: "TNW",
               dv_km_s: {-0.0002, 0.0008, 0.0001}
             }
           ]

    assert base.user_defined == []
    assert base.user_defined_comments == []

    opm = %{
      base
      | comments: ["header details"],
        classification: "U",
        message_id: "OPM-TEST-1",
        metadata: %{base.metadata | comments: ["metadata details"], ref_frame_epoch: "J2000"},
        state: %{base.state | comments: ["state details"]},
        keplerian: %{
          base.keplerian
          | comments: ["Keplerian details"],
            anomaly: {:mean_anomaly, 41.0}
        },
        spacecraft: %{base.spacecraft | comments: ["spacecraft details"]},
        covariance: %{base.covariance | comments: ["covariance details"]},
        maneuvers:
          Enum.with_index(base.maneuvers, fn maneuver, index ->
            %{maneuver | comments: ["maneuver #{index + 1} details"]}
          end),
        user_defined: [
          %OPM.UserDefined{parameter: "MISSION", value: "SERVICING"},
          %OPM.UserDefined{parameter: "MODE", value: "AUTONOMOUS"}
        ],
        user_defined_comments: ["user parameter details"]
    }

    for {encode, parse} <- [
          {&OPM.encode_kvn/1, &OPM.parse_kvn/1},
          {&OPM.encode_xml/1, &OPM.parse_xml/1}
        ] do
      assert {:ok, text} = encode.(opm)
      assert {:ok, reparsed} = parse.(text)
      assert reparsed == opm
      assert reparsed.keplerian.anomaly == {:mean_anomaly, 41.0}

      assert Enum.map(reparsed.user_defined, &{&1.parameter, &1.value}) == [
               {"MISSION", "SERVICING"},
               {"MODE", "AUTONOMOUS"}
             ]

      assert reparsed.user_defined_comments == ["user parameter details"]
    end
  end
end
