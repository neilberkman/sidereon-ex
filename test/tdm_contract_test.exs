defmodule Sidereon.CCSDS.TDMContractTest do
  @moduledoc """
  The CCSDS TDM contract the binding exposes: positioned comments kept through
  a write, reader and writer policies with every warning and departure,
  metadata built and replaced from its ordered raw fields, and typed refusals.

  The messages are classified synthetic, built for the case each test names on
  the conforming minimum CCSDS 503.0-B-2 requires; the Annex E example is the
  committed fixture.
  """
  use ExUnit.Case, async: true

  alias Sidereon.CCSDS.TDM
  alias Sidereon.CCSDS.TDM.Comment
  alias Sidereon.CCSDS.TDM.Departure
  alias Sidereon.CCSDS.TDM.Field
  alias Sidereon.CCSDS.TDM.Metadata
  alias Sidereon.CCSDS.TDM.Participant
  alias Sidereon.CCSDS.TDM.Policy
  alias Sidereon.CCSDS.TDM.Warning
  alias Sidereon.CCSDS.TDM.WritePolicy

  @tdm_annex Path.join(__DIR__, "fixtures/tdm/annex_e_06.kvn")

  @conforming """
  CCSDS_TDM_VERS = 2.0
  CREATION_DATE = 2005-160T20:15:00Z
  ORIGINATOR = NASA
  META_START
  TIME_SYSTEM = UTC
  PARTICIPANT_1 = DSS-25
  META_STOP
  DATA_START
  RANGE = 2005-159T17:41:00 1.0
  DATA_STOP
  """

  # The conforming message with a data comment after its first record, on line
  # 10, which CCSDS 503.0-B-2 4.5.2 c) places before the first record.
  @late_data_comment String.replace(
                       @conforming,
                       "RANGE = 2005-159T17:41:00 1.0",
                       "RANGE = 2005-159T17:41:00 1.0\nCOMMENT after the first record\nRANGE = 2005-159T17:41:01 2.0"
                     )

  defp field(key, value), do: %Field{key: key, value: value}

  describe "positioned comments" do
    test "a conforming header comment keeps its place after the version through a write" do
      assert {:ok, tdm} = @tdm_annex |> File.read!() |> TDM.parse()

      assert tdm.comments == [%Comment{text: "TDM example created by yyyyy-nnnA Nav Team (JAXA)", before_record: 1}]

      assert {:ok, encoded} = TDM.encode(tdm)

      assert ["CCSDS_TDM_VERS = 2.0", "COMMENT TDM example created by yyyyy-nnnA Nav Team (JAXA)" | _] =
               String.split(encoded, "\n")

      assert {:ok, reparsed} = TDM.parse(encoded)
      assert reparsed == tdm
    end

    test "a data comment after a record is refused strictly and kept where it sits when forgiven" do
      assert {:error, {:keyword_out_of_order, %{line: 10, keyword: "COMMENT", section: :data}}} =
               TDM.parse_kvn(@late_data_comment)

      assert {:ok, %{value: tdm, warnings: [warning]}} =
               TDM.parse_kvn_with_policy(@late_data_comment, keyword_order: :forgive)

      assert %Warning{tag: :keyword_out_of_order, line: 10, keyword: "COMMENT", section: :data} = warning
      assert is_binary(warning.message)

      assert [%TDM.Segment{data: data}] = tdm.segments
      assert data.comments == [%Comment{text: "after the first record", before_record: 1}]

      # The strict writer refuses to write it there, and will not move it.
      assert {:error, {:keyword_out_of_order, %{line: nil, keyword: "COMMENT", section: :data}}} =
               TDM.encode_kvn(tdm)

      # Asked for that departure, the writer emits it and names it, and the
      # message comes back to the text it was read from.
      assert {:ok, %{value: encoded, departures: [departure]}} =
               TDM.encode_kvn_with_policy(tdm, keyword_order: :forgive)

      assert %Departure{tag: :keyword_out_of_order, keyword: "COMMENT", section: :data} = departure
      assert encoded == @late_data_comment
    end

    test "a strict read of a conforming message reports no warning" do
      assert {:ok, %{value: tdm, warnings: []}} = TDM.parse_kvn_with_policy(@conforming, Policy.strict())
      assert {:ok, %{value: @conforming, departures: []}} = TDM.encode_kvn_with_policy(tdm, WritePolicy.strict())
    end
  end

  describe "policies" do
    test "unknown, duplicate and invalid policy options are refused by name" do
      assert {:error, {:unknown_policy_key, :bogus}} = TDM.parse_kvn_with_policy(@conforming, bogus: :forgive)

      assert {:error, {:duplicate_policy_key, :keyword_order}} =
               TDM.parse_kvn_with_policy(@conforming, keyword_order: :forgive, keyword_order: :strict)

      assert {:error, {:invalid_policy_value, :long_lines, :sometimes}} =
               TDM.parse_kvn_with_policy(@conforming, long_lines: :sometimes)

      assert {:error, :bad_tdm_policy} = TDM.parse_kvn_with_policy(@conforming, :lenient)

      # The reader has no repeated-keyword axis; only the writer does.
      assert {:error, {:unknown_policy_key, :repeated_keywords}} =
               TDM.parse_kvn_with_policy(@conforming, repeated_keywords: :forgive)

      assert {:ok, %WritePolicy{repeated_keywords: :forgive}} = WritePolicy.new(repeated_keywords: :forgive)
      assert %Policy{final_terminator: :forgive, keyword_order: :forgive} = Policy.lenient()
    end

    test "a forgiven departure on read is listed with every field it carries" do
      unterminated = String.trim_trailing(@conforming, "\n")

      assert {:error, {:unterminated_final_line, %{line: 10}}} = TDM.parse_kvn(unterminated)

      assert {:ok, %{value: tdm, warnings: [%Warning{tag: :unterminated_final_line, line: 10}]}} =
               TDM.parse_kvn_with_policy(unterminated, final_terminator: :forgive)

      # The writer terminates the line unless asked not to, and says so when it
      # does not.
      assert {:ok, @conforming} = TDM.encode_kvn(tdm)

      assert {:ok, %{value: ^unterminated, departures: [%Departure{tag: :unterminated_final_line}]}} =
               TDM.encode_kvn_with_policy(tdm, final_terminator: :forgive)
    end
  end

  describe "metadata from raw fields" do
    test "from_raw/2 derives every property from the ordered fields" do
      fields = [
        field("TIME_SYSTEM", "UTC"),
        field("PARTICIPANT_1", "DSS-14"),
        field("PARTICIPANT_2", "SPACECRAFT"),
        field("MODE", "SEQUENTIAL"),
        field("PATH", "1,2"),
        field("TIMETAG_REF", "TRANSMIT"),
        field("RANGE_UNITS", "km")
      ]

      comments = [%Comment{text: "conforming metadata comment", before_record: 0}]

      assert {:ok, %Metadata{} = metadata} = Metadata.from_raw(fields, comments)
      assert metadata.fields == fields
      assert metadata.comments == comments
      assert metadata.time_system == "UTC"

      assert metadata.participants == [
               %Participant{index: 1, name: "DSS-14"},
               %Participant{index: 2, name: "SPACECRAFT"}
             ]

      assert metadata.mode == "SEQUENTIAL"
      assert [%TDM.Path{key: "PATH", index: nil, participants: [1, 2]}] = metadata.paths
      assert metadata.timetag_ref == "TRANSMIT"
      assert metadata.range_units == "km"

      # A message carrying it writes and reads back to the same block.
      {:ok, tdm} = TDM.parse(@conforming)
      [segment] = tdm.segments
      tdm = %{tdm | segments: [%{segment | metadata: metadata}]}
      assert {:ok, encoded} = TDM.encode(tdm)
      assert {:ok, reparsed} = TDM.parse(encoded)
      assert [%TDM.Segment{metadata: ^metadata}] = reparsed.segments
    end

    test "from_raw_with_policy/3 returns the block and every departure it forgave" do
      fields = [field("PARTICIPANT_1", "DSS-14")]

      assert {:error, {:missing_keyword, %{keyword: "TIME_SYSTEM", segment: 1}}} = Metadata.from_raw(fields, [])

      assert {:ok, %{value: %Metadata{time_system: nil} = metadata, departures: departures}} =
               Metadata.from_raw_with_policy(fields, [], missing_keywords: :forgive)

      assert [%Departure{tag: :missing_keyword, keyword: "TIME_SYSTEM", segment: 1}] = departures
      assert metadata.participants == [%Participant{index: 1, name: "DSS-14"}]
    end

    test "what no policy forgives is refused under every policy" do
      conflicting = [field("TIME_SYSTEM", "UTC"), field("TIME_SYSTEM", "GPS"), field("PARTICIPANT_1", "DSS-14")]

      expected =
        {:error,
         {:conflicting_keyword,
          %{
            line: nil,
            keyword: "TIME_SYSTEM",
            section: :metadata,
            first: "UTC",
            second: "GPS",
            message: ~s(TDM metadata keyword TIME_SYSTEM carries both "UTC" and "GPS")
          }}}

      assert Metadata.from_raw(conflicting, []) == expected
      assert Metadata.from_raw_with_policy(conflicting, [], WritePolicy.lenient()) == expected

      undefined = [field("TIME_SYSTEM", "UTC"), field("PARTICIPANT_1", "DSS-14"), field("PATH", "1,2")]

      assert {:error, {:undefined_participant, %{segment: 1, keyword: "PATH", index: 2}}} =
               Metadata.from_raw(undefined, [])

      assert {:error, {:invalid_field, %{keyword: "PARTICIPANT_9", kind: :invalid_index}}} =
               Metadata.from_raw([field("TIME_SYSTEM", "UTC"), field("PARTICIPANT_9", "DSS-14")], [])

      assert {:error, {:unwritable, %{keyword: "UNKNOWN_KEYWORD"}}} =
               Metadata.from_raw(
                 [field("TIME_SYSTEM", "UTC"), field("PARTICIPANT_1", "DSS-14"), field("UNKNOWN_KEYWORD", "VAL")],
                 []
               )

      assert {:error, {:invalid_tdm_field, :before_record, -1}} =
               Metadata.from_raw([field("TIME_SYSTEM", "UTC")], [%Comment{text: "x", before_record: -1}])
    end

    test "replace_raw/3 replaces every field and property at once, or nothing" do
      {:ok, original} = Metadata.from_raw([field("TIME_SYSTEM", "UTC"), field("PARTICIPANT_1", "DSS-14")], [])

      assert {:ok, replaced} =
               Metadata.replace_raw(
                 original,
                 [field("TIME_SYSTEM", "TAI"), field("PARTICIPANT_1", "DSS-25"), field("RANGE_UNITS", "s")],
                 [%Comment{text: "replaced", before_record: 0}]
               )

      assert replaced.time_system == "TAI"
      assert replaced.participants == [%Participant{index: 1, name: "DSS-25"}]
      assert replaced.range_units == "s"
      assert replaced.comments == [%Comment{text: "replaced", before_record: 0}]

      assert {:error, {:missing_keyword, %{keyword: "TIME_SYSTEM"}}} =
               Metadata.replace_raw(original, [field("PARTICIPANT_1", "DSS-25")], [])

      assert {:ok, %{value: forgiven, departures: [%Departure{tag: :missing_keyword}]}} =
               Metadata.replace_raw_with_policy(original, [field("PARTICIPANT_1", "DSS-25")], [],
                 missing_keywords: :forgive
               )

      assert forgiven.time_system == nil
      assert original.time_system == "UTC"
    end

    test "a derived property edited apart from its fields is refused, not written as the fields say" do
      {:ok, tdm} = TDM.parse(@conforming)
      [segment] = tdm.segments
      stale = %{tdm | segments: [%{segment | metadata: %{segment.metadata | time_system: "TAI"}}]}

      assert {:error, {:metadata_not_derived, %{segment: 1, property: :time_system}}} = TDM.encode(stale)

      assert {:error, {:metadata_not_derived, %{segment: 1, property: :time_system}}} =
               TDM.encode_kvn_with_policy(stale, WritePolicy.lenient())
    end
  end

  describe "refusals" do
    test "each refusal carries the fields of its variant" do
      no_creation_date = String.replace(@conforming, "CREATION_DATE = 2005-160T20:15:00Z\n", "")
      assert {:error, {:missing_keyword, %{keyword: "CREATION_DATE", segment: nil}}} = TDM.parse(no_creation_date)

      no_participant = String.replace(@conforming, "PARTICIPANT_1 = DSS-25\n", "")
      assert {:error, {:missing_keyword, %{keyword: "PARTICIPANT_n", segment: 1}}} = TDM.parse(no_participant)

      empty_originator = String.replace(@conforming, "ORIGINATOR = NASA", "ORIGINATOR =")
      assert {:error, {:empty_value, %{line: 3, keyword: "ORIGINATOR"}}} = TDM.parse(empty_originator)

      bad_version = String.replace(@conforming, "CCSDS_TDM_VERS = 2.0", "CCSDS_TDM_VERS = 2")
      assert {:error, {:invalid_version, %{line: 1, value: "2"}}} = TDM.parse(bad_version)

      malformed =
        String.replace(@conforming, "RANGE = 2005-159T17:41:00 1.0", "RECEIVE_FREQ_1 = 2005-159T17:41:00")

      assert {:error, {:malformed_record, %{line: 9, keyword: "RECEIVE_FREQ_1"}}} = TDM.parse(malformed)
    end
  end
end
