defmodule Sidereon.CCSDS.OPMTest do
  @moduledoc """
  CCSDS OPM (Orbit Parameter Message) reader/writer tests.

  Fixtures: a single-epoch OPM with Keplerian elements, a covariance, and
  maneuvers, in both KVN and XML, mirroring the CCSDS 502.0-B layout.
  """
  use ExUnit.Case, async: true

  alias Sidereon.CCSDS.OPM

  @kvn_path "test/fixtures/opm/osprey.kvn"
  @xml_path "test/fixtures/opm/osprey.xml"

  setup_all do
    kvn = File.read!(@kvn_path)
    xml = File.read!(@xml_path)
    {:ok, opm} = OPM.parse(kvn)
    %{opm: opm, kvn: kvn, xml: xml}
  end

  describe "parse/1" do
    test "auto-detects KVN and exposes the typed struct", %{opm: opm} do
      assert %OPM{} = opm
      assert opm.ccsds_opm_vers == "2.0"
      assert %OPM.Metadata{} = opm.metadata
      assert opm.metadata.object_name != nil
      assert %OPM.State{} = opm.state
      assert {_, _, _} = opm.state.position_km
    end

    test "exposes the anomaly as a tagged tuple when Keplerian is present", %{opm: opm} do
      case opm.keplerian do
        nil ->
          :ok

        %OPM.Keplerian{anomaly: anomaly} ->
          assert match?({:true_anomaly, deg} when is_float(deg), anomaly) or
                   match?({:mean_anomaly, deg} when is_float(deg), anomaly)
      end
    end

    test "auto-detects XML to the same struct as KVN", %{opm: opm, xml: xml} do
      assert {:ok, from_xml} = OPM.parse(xml)
      assert from_xml == opm
    end

    test "maps a structurally invalid message to an atom reason" do
      assert {:error, reason} = OPM.parse_kvn("not an opm at all")
      assert reason in [:missing_field, :invalid_field, :malformed]
    end
  end

  describe "encode/2 round-trip" do
    test "KVN round-trips to an equal struct", %{opm: opm} do
      kvn = OPM.encode(opm)
      assert is_binary(kvn)
      assert {:ok, reparsed} = OPM.parse_kvn(kvn)
      assert reparsed == opm
    end

    test "XML round-trips to an equal struct", %{opm: opm} do
      xml = OPM.encode(opm, format: :xml)
      assert is_binary(xml)
      assert {:ok, reparsed} = OPM.parse_xml(xml)
      assert reparsed == opm
    end

    test "encode_kvn/1 and encode_xml/1 match encode/2", %{opm: opm} do
      assert OPM.encode_kvn(opm) == OPM.encode(opm, format: :kvn)
      assert OPM.encode_xml(opm) == OPM.encode(opm, format: :xml)
    end

    test "rejects an unsupported format", %{opm: opm} do
      assert_raise ArgumentError, fn -> OPM.encode(opm, format: :json) end
    end
  end
end
