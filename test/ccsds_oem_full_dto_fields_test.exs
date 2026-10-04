defmodule Sidereon.CCSDS.OEMFullDtoFieldsTest do
  use ExUnit.Case, async: true

  alias Sidereon.CCSDS.OEM

  @fixture "test/fixtures/oem/gps.kvn"

  test "public KVN and XML routes retain every OEM DTO field" do
    kvn = File.read!(@fixture)
    {:ok, base} = OEM.parse_kvn(kvn)

    assert base.ccsds_oem_vers == "2.0"
    assert base.comments == ["Annotated OEM fixture for a GPS navigation spacecraft."]
    assert base.classification == nil
    assert base.creation_date == "2026-06-28T12:00:00.000"
    assert base.originator == "SIDEREON TEST"
    assert base.message_id == nil
    assert base.skipped_states == []

    assert [
             %OEM.Segment{
               metadata: metadata,
               data_comments: [
                 %OEM.Comment{
                   position: 0,
                   text: "Epoch X Y Z X_DOT Y_DOT Z_DOT with one acceleration-bearing sample."
                 }
               ],
               covariance_comments: [],
               states: states,
               covariances: covariances
             }
           ] = base.segments

    assert metadata == %OEM.Metadata{
             comments: [],
             object_name: "GPS BIIRM-8",
             object_id: "2005-038A",
             center_name: "EARTH",
             ref_frame: "EME2000",
             ref_frame_epoch: nil,
             time_system: "GPS",
             start_time: "2026-06-28T00:00:00.000",
             stop_time: "2026-06-28T00:30:00.000",
             useable_start_time: "2026-06-28T00:00:00.000",
             useable_stop_time: "2026-06-28T00:30:00.000",
             interpolation: "LAGRANGE",
             interpolation_degree: 5
           }

    assert states == [
             %OEM.State{
               epoch: "2026-06-28T00:00:00.000",
               position_km: {15_600.123456, -21_000.654321, 20_100.111111},
               velocity_km_s: {2.102345, 1.305678, -2.987654},
               acceleration_km_s2: nil
             },
             %OEM.State{
               epoch: "2026-06-28T00:15:00.000",
               position_km: {17_450.223456, -19_750.754321, 17_210.211111},
               velocity_km_s: {2.008765, 1.504321, -3.112345},
               acceleration_km_s2: nil
             },
             %OEM.State{
               epoch: "2026-06-28T00:30:00.000",
               position_km: {19_200.323456, -18_200.854321, 14_200.311111},
               velocity_km_s: {1.812345, 1.701234, -3.201234},
               acceleration_km_s2: {0.000001, -0.000002, 0.000003}
             }
           ]

    assert covariances == [
             %OEM.Covariance{
               epoch: "2026-06-28T00:15:00.000",
               cov_ref_frame: "RTN",
               lower_triangle: [
                 0.0001,
                 0.0,
                 0.0002,
                 0.0,
                 0.0,
                 0.0003,
                 0.0,
                 0.0,
                 0.0,
                 0.00000001,
                 0.0,
                 0.0,
                 0.0,
                 0.0,
                 0.00000002,
                 0.0,
                 0.0,
                 0.0,
                 0.0,
                 0.0,
                 0.00000003
               ]
             }
           ]

    segment = hd(base.segments)

    oem = %{
      base
      | classification: "U",
        message_id: "OEM-TEST-1",
        segments: [
          %{
            segment
            | metadata: %{
                segment.metadata
                | comments: ["metadata details"],
                  ref_frame_epoch: "J2000"
              },
              data_comments: [
                %OEM.Comment{position: 1, text: "between state vectors"}
              ],
              covariance_comments: [
                %OEM.Comment{position: 0, text: "covariance data"}
              ]
          }
        ]
    }

    for {encode, parse} <- [
          {&OEM.encode_kvn/1, &OEM.parse_kvn/1},
          {&OEM.encode_xml/1, &OEM.parse_xml/1}
        ] do
      assert {:ok, text} = encode.(oem)
      assert {:ok, reparsed} = parse.(text)
      assert reparsed == oem

      assert reparsed.segments |> hd() |> Map.fetch!(:data_comments) == [
               %OEM.Comment{position: 1, text: "between state vectors"}
             ]

      assert reparsed.segments |> hd() |> Map.fetch!(:covariance_comments) == [
               %OEM.Comment{position: 0, text: "covariance data"}
             ]
    end

    wrong_count =
      String.replace(
        kvn,
        "2026-06-28T00:15:00.000 17450.223456",
        "2026-06-28T00:15:00.000 17450.223456 extra"
      )

    assert {:ok, count_refusal} = OEM.parse_kvn(wrong_count)

    assert count_refusal.skipped_states == [
             %OEM.SkippedState{
               line: 22,
               segment: 0,
               text:
                 "2026-06-28T00:15:00.000 17450.223456 extra -19750.754321 17210.211111 2.008765 1.504321 -3.112345",
               reason: {:item_count, 8}
             }
           ]

    bad_number =
      String.replace(
        kvn,
        "2026-06-28T00:00:00.000 15600.123456",
        "2026-06-28T00:00:00.000 invalid"
      )

    assert {:ok, numeric_refusal} = OEM.parse_kvn(bad_number)

    assert numeric_refusal.skipped_states == [
             %OEM.SkippedState{
               line: 21,
               segment: 0,
               text: "2026-06-28T00:00:00.000 invalid -21000.654321 20100.111111 2.102345 1.305678 -2.987654",
               reason: {:invalid_field, :x, :float_parse}
             }
           ]
  end
end
