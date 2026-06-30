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

    test "auto-detects XML to the same struct as KVN", %{oem: oem, xml: xml} do
      assert {:ok, from_xml} = OEM.parse(xml)
      assert from_xml == oem
    end

    test "maps a structurally invalid message to an atom reason" do
      assert {:error, reason} = OEM.parse_kvn("not an oem at all")
      assert reason in [:missing_field, :invalid_field, :malformed]
    end
  end

  describe "encode/2 round-trip" do
    test "KVN round-trips to an equal struct", %{oem: oem} do
      kvn = OEM.encode(oem)
      assert is_binary(kvn)
      assert {:ok, reparsed} = OEM.parse_kvn(kvn)
      assert reparsed == oem
    end

    test "XML round-trips to an equal struct", %{oem: oem} do
      xml = OEM.encode(oem, format: :xml)
      assert is_binary(xml)
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
  end
end
