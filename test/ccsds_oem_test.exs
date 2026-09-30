defmodule Sidereon.CCSDS.OEMTest do
  @moduledoc """
  CCSDS OEM (Orbit Ephemeris Message) reader/writer tests.

  Fixtures: a small multi-state GPS-style OEM in both KVN and XML, mirroring the
  CCSDS 502.0-B segment/state layout.
  """
  use ExUnit.Case, async: true

  alias Sidereon.CCSDS.OEM

  @kvn_path "test/fixtures/oem/gps.kvn"
  @xml_path "test/fixtures/oem/gps.xml"

  setup_all do
    kvn = File.read!(@kvn_path)
    xml = File.read!(@xml_path)
    {:ok, oem} = OEM.parse(kvn)
    %{oem: oem, kvn: kvn, xml: xml}
  end

  describe "parse/1" do
    test "auto-detects KVN and exposes the typed struct", %{oem: oem} do
      assert %OEM{} = oem
      assert oem.ccsds_oem_vers == "2.0"
      assert [%OEM.Segment{} = segment] = oem.segments
      assert %OEM.Metadata{} = segment.metadata
      assert segment.metadata.ref_frame != nil
      refute Enum.empty?(segment.states)
    end

    test "exposes Cartesian state samples as tuples", %{oem: oem} do
      [segment] = oem.segments
      [%OEM.State{} = state | _] = segment.states
      assert {x, y, z} = state.position_km
      assert is_float(x) and is_float(y) and is_float(z)
      assert {_, _, _} = state.velocity_km_s
    end

    test "auto-detects XML to the same struct as KVN, less the KVN comments", %{oem: oem, xml: xml} do
      assert {:ok, from_xml} = OEM.parse(xml)
      assert from_xml == without_comments(oem)
    end

    test "keeps header and ephemeris comments at their positions", %{oem: oem} do
      assert oem.comments == ["Annotated OEM fixture for a GPS navigation spacecraft."]
      [segment] = oem.segments

      assert segment.data_comments == [
               %OEM.Comment{
                 position: 0,
                 text: "Epoch X Y Z X_DOT Y_DOT Z_DOT with one acceleration-bearing sample."
               }
             ]
    end

    test "keeps each covariance as its 21 lower-triangle values", %{oem: oem} do
      [segment] = oem.segments
      [%OEM.Covariance{cov_ref_frame: "RTN", lower_triangle: values} = covariance] = segment.covariances
      assert length(values) == 21
      assert hd(values) == 0.0001
      assert Enum.at(Enum.at(OEM.Covariance.to_matrix(covariance), 2), 2) == 0.0003
    end

    test "reports each skipped KVN ephemeris line with its reason", %{kvn: kvn} do
      broken =
        String.replace(
          kvn,
          "2026-06-28T00:15:00.000 17450.223456",
          "2026-06-28T00:15:00.000 17450.223456 extra"
        )

      assert {:ok, oem} = OEM.parse_kvn(broken)
      assert [%OEM.SkippedState{segment: 0, reason: {:item_count, 8}} = skipped] = oem.skipped_states
      assert skipped.line == 22
      assert String.starts_with?(skipped.text, "2026-06-28T00:15:00.000")
    end

    test "names the line a structurally invalid message fails on" do
      assert {:error, {:malformed_line, 1, "not an oem at all"}} = OEM.parse_kvn("not an oem at all")
    end
  end

  describe "encode/2 round-trip" do
    test "KVN round-trips to an equal struct", %{oem: oem} do
      assert {:ok, kvn} = OEM.encode(oem)
      assert {:ok, reparsed} = OEM.parse_kvn(kvn)
      assert reparsed == oem
    end

    test "XML round-trips to an equal struct", %{oem: oem} do
      assert {:ok, xml} = OEM.encode(oem, format: :xml)
      assert {:ok, reparsed} = OEM.parse_xml(xml)
      assert reparsed == oem
    end

    test "encode_kvn/1 and encode_xml/1 match encode/2", %{oem: oem} do
      assert OEM.encode_kvn(oem) == OEM.encode(oem, format: :kvn)
      assert OEM.encode_xml(oem) == OEM.encode(oem, format: :xml)
    end

    test "rejects an unsupported format", %{oem: oem} do
      assert_raise ArgumentError, fn -> OEM.encode(oem, format: :json) end
    end

    test "refuses a covariance without 21 values", %{oem: oem} do
      [segment] = oem.segments
      [covariance] = segment.covariances
      segment = %{segment | covariances: [%{covariance | lower_triangle: [1.0]}]}

      assert {:error, {:invalid_length, :"covariance.lower_triangle", 21, 1}} =
               OEM.encode_kvn(%{oem | segments: [segment]})
    end
  end

  defp without_comments(%OEM{} = oem) do
    %{
      oem
      | comments: [],
        segments:
          Enum.map(oem.segments, fn segment ->
            %{
              segment
              | metadata: %{segment.metadata | comments: []},
                data_comments: [],
                covariance_comments: []
            }
          end)
    }
  end
end
