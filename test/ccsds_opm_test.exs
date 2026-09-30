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

    test "auto-detects XML to the same struct as KVN, less the KVN comments", %{opm: opm, xml: xml} do
      assert {:ok, from_xml} = OPM.parse(xml)
      assert from_xml == without_comments(opm)
    end

    test "keeps each KVN comment in the block of the keyword after it", %{opm: opm} do
      assert opm.comments == []
      assert opm.metadata.comments == ["Annotated OPM fixture for a low Earth orbit servicing spacecraft."]
      assert [%OPM.Maneuver{comments: ["Two planned trim burns."]} | _] = opm.maneuvers
    end

    test "keeps the covariance as the 21 lower-triangle values read", %{opm: opm} do
      assert %OPM.Covariance{cov_ref_frame: "EME2000", lower_triangle: values} = opm.covariance
      assert length(values) == 21
      assert hd(values) == 0.01
      assert List.last(values) == 0.000003

      matrix = OPM.Covariance.to_matrix(opm.covariance)
      assert Enum.at(Enum.at(matrix, 1), 1) == 0.02
      assert Enum.at(Enum.at(matrix, 3), 0) == Enum.at(Enum.at(matrix, 0), 3)
    end

    test "names the line a structurally invalid message fails on" do
      assert {:error, {:malformed_line, 1, "not an opm at all"}} = OPM.parse_kvn("not an opm at all")
    end
  end

  describe "encode/2 round-trip" do
    test "KVN round-trips to an equal struct", %{opm: opm} do
      assert {:ok, kvn} = OPM.encode(opm)
      assert {:ok, reparsed} = OPM.parse_kvn(kvn)
      assert reparsed == opm
    end

    test "XML round-trips to an equal struct", %{opm: opm} do
      assert {:ok, xml} = OPM.encode(opm, format: :xml)
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

    test "user-defined parameters and header items round-trip", %{opm: opm} do
      opm = %{
        opm
        | classification: "public",
          message_id: "OPM-7",
          user_defined: [%OPM.UserDefined{parameter: "OPERATOR", value: "TEST OPS"}]
      }

      assert {:ok, kvn} = OPM.encode_kvn(opm)
      assert {:ok, ^opm} = OPM.parse_kvn(kvn)
    end

    test "refuses text that would not read back unchanged", %{opm: opm} do
      opm = put_in(opm.metadata.object_name, "OSPREY\n1")
      assert {:error, {:unwritable_text, field, "OSPREY\n1", :line_break}} = OPM.encode_kvn(opm)
      assert is_binary(field)
    end

    test "refuses a covariance without 21 values", %{opm: opm} do
      opm = put_in(opm.covariance.lower_triangle, [1.0])
      assert {:error, {:invalid_length, :"covariance.lower_triangle", 21, 1}} = OPM.encode_kvn(opm)
    end
  end

  defp without_comments(%OPM{} = opm) do
    %{
      opm
      | comments: [],
        metadata: %{opm.metadata | comments: []},
        state: %{opm.state | comments: []},
        keplerian: opm.keplerian && %{opm.keplerian | comments: []},
        spacecraft: opm.spacecraft && %{opm.spacecraft | comments: []},
        covariance: opm.covariance && %{opm.covariance | comments: []},
        maneuvers: Enum.map(opm.maneuvers, &%{&1 | comments: []})
    }
  end
end
