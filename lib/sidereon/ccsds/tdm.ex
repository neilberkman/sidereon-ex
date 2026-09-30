defmodule Sidereon.CCSDS.TDM do
  @moduledoc """
  Parse and encode CCSDS Tracking Data Messages (TDM) in KVN format.

  Date/time fields are preserved as raw strings. Data record values carry both
  the parsed `float` and the original decimal token so KVN round-trips do not
  rewrite measurement text. Comments keep their place among the fields and
  records they sit between (`Sidereon.CCSDS.TDM.Comment`) and are written back
  there.

  ## Strict and policy entries

  `parse_kvn/1` and `encode_kvn/1` hold a message to CCSDS 503.0-B-2 and refuse
  any departure by name. `parse_kvn_with_policy/2` reads under a
  `Sidereon.CCSDS.TDM.Policy` that may forgive departures which do not change
  what a value means, and returns every one it forgave as a
  `Sidereon.CCSDS.TDM.Warning`; `encode_kvn_with_policy/2` writes under a
  `Sidereon.CCSDS.TDM.WritePolicy` and returns every departure it emitted as a
  `Sidereon.CCSDS.TDM.Departure`. Nothing that changes what the message means is
  forgiven under any policy.

  ## Metadata

  A metadata block's ordered raw `fields` are its authority. Its participants,
  mode, paths, timetag reference, time system and range units are derived from
  them, and the writer emits the fields and derives from them again. Build or
  change a block with `Sidereon.CCSDS.TDM.Metadata.from_raw/2`,
  `from_raw_with_policy/3`, `replace_raw/3` or `replace_raw_with_policy/4`,
  which derive every property from the fields in one step. A block whose
  derived properties were edited apart from its fields is refused by the
  encoders as `{:metadata_not_derived, %{segment, property}}` rather than
  written as the fields say.

  ## Refusals

  Every refusal is `{:error, {tag, fields}}`, `fields` a map holding every field
  the refusal carries:

    * `{:no_segments, %{}}`
    * `{:section, %{line, detail}}`
    * `{:malformed_line, %{line, text}}`
    * `{:non_printable_character, %{line, keyword, column, character}}`
    * `{:line_too_long, %{line, keyword, length}}`
    * `{:malformed_epoch, %{line, keyword, text}}`
    * `{:records_out_of_order, %{segment, keyword, epoch}}`
    * `{:duplicate_record, %{segment, keyword, epoch}}`
    * `{:unterminated_final_line, %{line}}`
    * `{:unwritable, %{keyword, reason}}` - a field or comment the KVN form
      cannot carry, or a comment position or order the writer cannot emit
      unchanged.
    * `{:keyword_out_of_order, %{line, keyword, section}}`
    * `{:undefined_participant, %{segment, keyword, index}}`
    * `{:conflicting_keyword, %{line, keyword, section, first, second}}`
    * `{:repeated_keyword, %{line, keyword, section}}`
    * `{:undefined_keyword, %{line, keyword, section}}`
    * `{:missing_keyword, %{keyword, segment}}` - `segment` is `nil` for the
      header. An absent `CCSDS_TDM_VERS` is refused this way too.
    * `{:empty_data_section, %{segment}}`
    * `{:empty_value, %{line, keyword}}`
    * `{:invalid_version, %{line, value}}`
    * `{:keyword_not_assignable, %{keyword}}`
    * `{:malformed_record, %{line, keyword}}`
    * `{:invalid_field, %{keyword, kind}}` - `kind` is one of `:missing`,
      `:float_parse`, `:non_finite`, `:not_positive`, `:out_of_range`,
      `:invalid_index`, `:unknown_keyword`, `:unexpected_unit`, `:non_integer`,
      `:negative`, `:negative_zero`, `:unit_mismatch` and `:decimal_mismatch`,
      or the core's own text for a kind this binding predates.
    * `{:metadata_not_derived, %{segment, property}}` - see "Metadata".
    * `{:unhandled, %{message}}` - a refusal this binding predates, with the
      core's own text; no other tag stands in for it.

  `line` is the one-based input line, `nil` where the writer raises the refusal
  for a line no input produced. `segment` is one-based. `section` is `:header`,
  `:metadata` or `:data`. `character` is a one-character string.

  A value that cannot cross into the boundary is refused before the call as
  `{:invalid_tdm_field, field, value}`: a comment position or participant index
  that is not a non-negative integer in the range the boundary carries it in,
  or a record value that is not a number a double holds.
  """

  alias Sidereon.CCSDS.TDM.Departure
  alias Sidereon.CCSDS.TDM.Metadata
  alias Sidereon.CCSDS.TDM.Policy
  alias Sidereon.CCSDS.TDM.Warning
  alias Sidereon.CCSDS.TDM.WritePolicy
  alias Sidereon.NIF

  defmodule Field do
    @moduledoc """
    A preserved KVN key/value field.
    """

    @enforce_keys [:key, :value]
    defstruct [:key, :value]

    @type t :: %__MODULE__{key: String.t(), value: String.t()}

    @doc false
    @spec from_nif_map(map()) :: t()
    def from_nif_map(%{key: key, value: value}), do: %__MODULE__{key: key, value: value}

    @doc false
    @spec to_nif_map(t()) :: map()
    def to_nif_map(%__MODULE__{key: key, value: value}), do: %{key: key, value: value}
  end

  defmodule Comment do
    @moduledoc """
    A comment and where it sits.

    `text` is everything after the `COMMENT` keyword and the one space CCSDS
    503.0-B-2 4.5.3 requires, leading indentation included. `before_record` is
    the index of the field or record the comment precedes in its block: header
    fields counting `CCSDS_TDM_VERS` as index 0, metadata fields, or data
    records. A comment at or past the end of its block sits after the last one.

    CCSDS 503.0-B-2 4.5.2 puts comments at the top of their section, so a
    conforming header comment has `before_record: 1` and a conforming metadata
    or data comment `before_record: 0`. Another position is kept, and written
    back where it was under a policy that forgives `:keyword_order`.
    """

    @enforce_keys [:text, :before_record]
    defstruct [:text, :before_record]

    @type t :: %__MODULE__{text: String.t(), before_record: non_neg_integer()}

    @doc false
    @spec from_nif_map(map()) :: t()
    def from_nif_map(%{text: text, before_record: before_record}) do
      %__MODULE__{text: text, before_record: before_record}
    end
  end

  defmodule Observable do
    @moduledoc """
    Parsed TDM observable family.
    """

    @enforce_keys [:kind]
    defstruct [:kind, :participant, :name]

    @type t :: %__MODULE__{
            kind:
              :range
              | :doppler_instantaneous
              | :doppler_integrated
              | :receive_freq
              | :transmit_freq
              | :transmit_freq_rate
              | :angle_1
              | :angle_2
              | :other,
            participant: non_neg_integer() | nil,
            name: String.t() | nil
          }
  end

  defmodule Scalar do
    @moduledoc """
    A numeric TDM data value and its exact source token.
    """

    @enforce_keys [:text, :value]
    defstruct [:text, :value]

    @type t :: %__MODULE__{text: String.t(), value: float()}
  end

  defmodule DataRecord do
    @moduledoc """
    One time-tagged TDM tracking data record.
    """

    alias Sidereon.CCSDS.TDM.Observable
    alias Sidereon.CCSDS.TDM.Scalar

    @enforce_keys [:observable, :keyword, :epoch, :value, :unit]
    defstruct [:observable, :keyword, :epoch, :value, :unit]

    @type t :: %__MODULE__{
            observable: Observable.t(),
            keyword: String.t(),
            epoch: String.t(),
            value: Scalar.t(),
            unit: String.t()
          }
  end

  defmodule DataSection do
    @moduledoc """
    TDM data block containing comments and records.

    Each comment carries the index of the record it precedes, so a comment the
    message placed among the records is written back there.
    """

    alias Sidereon.CCSDS.TDM.Comment
    alias Sidereon.CCSDS.TDM.DataRecord

    defstruct comments: [], records: []

    @type t :: %__MODULE__{
            comments: [Comment.t()],
            records: [DataRecord.t()]
          }
  end

  defmodule Participant do
    @moduledoc """
    One named TDM tracking participant.
    """

    @enforce_keys [:index, :name]
    defstruct [:index, :name]

    @type t :: %__MODULE__{index: non_neg_integer(), name: String.t()}
  end

  defmodule Path do
    @moduledoc """
    Parsed TDM signal path.
    """

    @enforce_keys [:key, :participants]
    defstruct [:key, :index, :participants]

    @type t :: %__MODULE__{
            key: String.t(),
            index: non_neg_integer() | nil,
            participants: [non_neg_integer()]
          }
  end

  defmodule Segment do
    @moduledoc """
    One TDM metadata/data segment.
    """

    alias Sidereon.CCSDS.TDM.DataSection

    @enforce_keys [:metadata, :data]
    defstruct [:metadata, :data]

    @type t :: %__MODULE__{
            metadata: Metadata.t(),
            data: DataSection.t()
          }
  end

  @typedoc "A refusal, `{tag, fields}`, as the moduledoc lists them."
  @type error :: {atom(), map()} | {:invalid_tdm_field, atom(), term()}

  defstruct version: "2.0",
            comments: [],
            creation_date: nil,
            originator: nil,
            message_id: nil,
            header_fields: [],
            segments: []

  @type t :: %__MODULE__{
          version: String.t(),
          comments: [Comment.t()],
          creation_date: String.t() | nil,
          originator: String.t() | nil,
          message_id: String.t() | nil,
          header_fields: [Field.t()],
          segments: [Segment.t()]
        }

  # The boundary carries participant indices as unsigned 8-bit integers and
  # comment positions as unsigned 64-bit integers.
  @max_u8 255
  @max_u64 0xFFFF_FFFF_FFFF_FFFF

  # The largest finite double, as the integer it is.
  @float_max_integer trunc(1.7976931348623157e308)

  @doc """
  Parse a TDM KVN document under the strict policy.
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, error()}
  def parse(text) when is_binary(text), do: parse_kvn(text)

  @doc """
  Parse a TDM KVN document under the strict policy, which forgives nothing.

  Returns `{:ok, tdm}` or `{:error, {tag, fields}}`.
  """
  @spec parse_kvn(String.t()) :: {:ok, t()} | {:error, error()}
  def parse_kvn(text) when is_binary(text) do
    case NIF.tdm_parse_kvn(text) do
      {:ok, fields} -> {:ok, from_nif_map(fields)}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Parse a TDM KVN document under a reader policy.

  `policy` is a `Sidereon.CCSDS.TDM.Policy`, or a keyword list or map of its
  axes. Returns `{:ok, %{value: tdm, warnings: warnings}}`, `warnings` holding
  every departure the policy forgave, in reader order, as
  `Sidereon.CCSDS.TDM.Warning` structs; an empty list means the message departed
  from nothing. A departure the policy does not forgive is refused as
  `{:error, {tag, fields}}`, and a policy that does not read is refused as
  `Sidereon.CCSDS.TDM.Policy` documents.
  """
  @spec parse_kvn_with_policy(String.t(), Policy.t() | keyword() | map()) ::
          {:ok, %{value: t(), warnings: [Warning.t()]}} | {:error, term()}
  def parse_kvn_with_policy(text, policy) when is_binary(text) do
    case Policy.to_nif_map(policy) do
      {:ok, policy_term} -> parse_with_policy_term(text, policy_term)
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Encode a TDM as KVN text under the strict policy.
  """
  @spec encode(t()) :: {:ok, String.t()} | {:error, error()}
  def encode(%__MODULE__{} = tdm), do: encode_kvn(tdm)

  @doc """
  Encode a TDM as KVN text under the strict policy, which emits no departure
  from CCSDS 503.0-B-2.

  The writer holds the value to the rules the reader holds a message to and
  refuses what it cannot write conformingly and unchanged, comments included.
  Returns `{:ok, text}` or `{:error, {tag, fields}}`.
  """
  @spec encode_kvn(t()) :: {:ok, String.t()} | {:error, error()}
  def encode_kvn(%__MODULE__{} = tdm) do
    case to_nif_map(tdm) do
      {:ok, fields} -> NIF.tdm_encode_kvn(fields)
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Encode a TDM as KVN text under a writer policy.

  `policy` is a `Sidereon.CCSDS.TDM.WritePolicy`, or a keyword list or map of
  its axes. Returns `{:ok, %{value: text, departures: departures}}`,
  `departures` holding every departure from CCSDS 503.0-B-2 the writer emitted,
  as `Sidereon.CCSDS.TDM.Departure` structs; an empty list means the text
  conforms. What the policy does not allow is refused as
  `{:error, {tag, fields}}`.
  """
  @spec encode_kvn_with_policy(t(), WritePolicy.t() | keyword() | map()) ::
          {:ok, %{value: String.t(), departures: [Departure.t()]}} | {:error, term()}
  def encode_kvn_with_policy(%__MODULE__{} = tdm, policy) do
    with {:ok, policy_term} <- WritePolicy.to_nif_map(policy),
         {:ok, fields} <- to_nif_map(tdm) do
      case NIF.tdm_encode_kvn_with_policy(fields, policy_term) do
        {:ok, text, departures} ->
          {:ok, %{value: text, departures: Enum.map(departures, &Departure.from_nif_map/1)}}

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp parse_with_policy_term(text, policy_term) do
    case NIF.tdm_parse_kvn_with_policy(text, policy_term) do
      {:ok, fields, warnings} ->
        {:ok, %{value: from_nif_map(fields), warnings: Enum.map(warnings, &Warning.from_nif_map/1)}}

      {:error, _reason} = error ->
        error
    end
  end

  @doc false
  @spec from_nif_map(map()) :: t()
  def from_nif_map(fields) do
    %__MODULE__{
      version: fields.version,
      comments: Enum.map(fields.comments, &Comment.from_nif_map/1),
      creation_date: fields.creation_date,
      originator: fields.originator,
      message_id: fields.message_id,
      header_fields: Enum.map(fields.header_fields, &Field.from_nif_map/1),
      segments: Enum.map(fields.segments, &segment_from_nif_map/1)
    }
  end

  @doc false
  @spec metadata_from_nif_map(map()) :: Metadata.t()
  def metadata_from_nif_map(fields) do
    %Metadata{
      comments: Enum.map(fields.comments, &Comment.from_nif_map/1),
      fields: Enum.map(fields.fields, &Field.from_nif_map/1),
      participants: Enum.map(fields.participants, &participant_from_nif_map/1),
      mode: fields.mode,
      paths: Enum.map(fields.paths, &path_from_nif_map/1),
      timetag_ref: fields.timetag_ref,
      time_system: fields.time_system,
      range_units: fields.range_units
    }
  end

  @doc false
  # The raw parts of a metadata block as the boundary takes them, or the first
  # value that cannot cross.
  @spec raw_to_nif([Field.t()], [Comment.t()]) :: {:ok, {[map()], [map()]}} | {:error, term()}
  def raw_to_nif(fields, comments) when is_list(fields) and is_list(comments) do
    {:ok, {Enum.map(fields, &Field.to_nif_map/1), Enum.map(comments, &comment_to_nif_map/1)}}
  catch
    {:invalid_tdm_field, _field, _value} = reason -> {:error, reason}
  end

  @doc false
  @spec metadata_to_nif(Metadata.t()) :: {:ok, map()} | {:error, term()}
  def metadata_to_nif(%Metadata{} = metadata) do
    {:ok, metadata_to_nif_map(metadata)}
  catch
    {:invalid_tdm_field, _field, _value} = reason -> {:error, reason}
  end

  defp to_nif_map(%__MODULE__{} = tdm) do
    {:ok,
     %{
       version: tdm.version,
       comments: Enum.map(tdm.comments, &comment_to_nif_map/1),
       creation_date: tdm.creation_date,
       originator: tdm.originator,
       message_id: tdm.message_id,
       header_fields: Enum.map(tdm.header_fields, &Field.to_nif_map/1),
       segments: Enum.map(tdm.segments, &segment_to_nif_map/1)
     }}
  catch
    {:invalid_tdm_field, _field, _value} = reason -> {:error, reason}
  end

  defp observable_kind("range"), do: :range
  defp observable_kind("doppler_instantaneous"), do: :doppler_instantaneous
  defp observable_kind("doppler_integrated"), do: :doppler_integrated
  defp observable_kind("receive_freq"), do: :receive_freq
  defp observable_kind("transmit_freq"), do: :transmit_freq
  defp observable_kind("transmit_freq_rate"), do: :transmit_freq_rate
  defp observable_kind("angle_1"), do: :angle_1
  defp observable_kind("angle_2"), do: :angle_2
  defp observable_kind("other"), do: :other

  defp record_from_nif_map(fields) do
    %__MODULE__.DataRecord{
      observable: %__MODULE__.Observable{
        kind: observable_kind(fields.observable.kind),
        participant: fields.observable.participant,
        name: fields.observable.name
      },
      keyword: fields.keyword,
      epoch: fields.epoch,
      value: %__MODULE__.Scalar{text: fields.value.text, value: fields.value.value},
      unit: fields.unit
    }
  end

  defp participant_from_nif_map(fields), do: %__MODULE__.Participant{index: fields.index, name: fields.name}

  defp path_from_nif_map(fields) do
    %__MODULE__.Path{key: fields.key, index: fields.index, participants: fields.participants}
  end

  defp segment_from_nif_map(fields) do
    %__MODULE__.Segment{
      metadata: metadata_from_nif_map(fields.metadata),
      data: %__MODULE__.DataSection{
        comments: Enum.map(fields.data.comments, &Comment.from_nif_map/1),
        records: Enum.map(fields.data.records, &record_from_nif_map/1)
      }
    }
  end

  defp comment_to_nif_map(%Comment{text: text, before_record: before_record}) do
    %{text: text, before_record: bounded_integer(before_record, @max_u64, :before_record)}
  end

  defp observable_to_nif_map(%__MODULE__.Observable{} = observable) do
    %{
      kind: Atom.to_string(observable.kind),
      participant: optional_u8(observable.participant, :participant),
      name: observable.name
    }
  end

  defp record_to_nif_map(%__MODULE__.DataRecord{} = record) do
    %{
      observable: observable_to_nif_map(record.observable),
      keyword: record.keyword,
      epoch: record.epoch,
      value: %{text: record.value.text, value: float_value(record.value.value)},
      unit: record.unit
    }
  end

  defp participant_to_nif_map(%__MODULE__.Participant{} = participant) do
    %{index: bounded_integer(participant.index, @max_u8, :participant_index), name: participant.name}
  end

  defp path_to_nif_map(%__MODULE__.Path{} = path) do
    %{
      key: path.key,
      index: optional_u8(path.index, :path_index),
      participants: Enum.map(path.participants, &bounded_integer(&1, @max_u8, :path_participant))
    }
  end

  defp metadata_to_nif_map(%Metadata{} = metadata) do
    %{
      comments: Enum.map(metadata.comments, &comment_to_nif_map/1),
      fields: Enum.map(metadata.fields, &Field.to_nif_map/1),
      participants: Enum.map(metadata.participants, &participant_to_nif_map/1),
      mode: metadata.mode,
      paths: Enum.map(metadata.paths, &path_to_nif_map/1),
      timetag_ref: metadata.timetag_ref,
      time_system: metadata.time_system,
      range_units: metadata.range_units
    }
  end

  defp segment_to_nif_map(%__MODULE__.Segment{metadata: metadata, data: data}) do
    %{
      metadata: metadata_to_nif_map(metadata),
      data: %{
        comments: Enum.map(data.comments, &comment_to_nif_map/1),
        records: Enum.map(data.records, &record_to_nif_map/1)
      }
    }
  end

  defp optional_u8(nil, _field), do: nil
  defp optional_u8(value, field), do: bounded_integer(value, @max_u8, field)

  defp bounded_integer(value, max, _field) when is_integer(value) and value >= 0 and value <= max, do: value
  defp bounded_integer(value, _max, field), do: throw({:invalid_tdm_field, field, value})

  defp float_value(value) when is_float(value), do: value

  defp float_value(value) when is_integer(value) and value >= -@float_max_integer and value <= @float_max_integer,
    do: value / 1.0

  defp float_value(value), do: throw({:invalid_tdm_field, :value, value})
end
