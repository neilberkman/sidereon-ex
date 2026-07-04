defmodule Sidereon.CCSDS.TDM do
  @moduledoc """
  Parse and encode CCSDS Tracking Data Messages (TDM) in KVN format.

  Date/time fields are preserved as raw strings. Data record values carry both
  the parsed `float` and the original decimal token so KVN round-trips do not
  rewrite measurement text.
  """

  alias Sidereon.NIF

  defmodule Field do
    @moduledoc """
    A preserved KVN key/value field.
    """

    @enforce_keys [:key, :value]
    defstruct [:key, :value]

    @type t :: %__MODULE__{key: String.t(), value: String.t()}
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
    """

    defstruct comments: [], records: []

    @type t :: %__MODULE__{comments: [String.t()], records: [DataRecord.t()]}
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

  defmodule Metadata do
    @moduledoc """
    Metadata block for one TDM segment.
    """

    defstruct comments: [],
              fields: [],
              participants: [],
              mode: nil,
              paths: [],
              timetag_ref: nil,
              time_system: nil,
              range_units: "km"

    @type t :: %__MODULE__{
            comments: [String.t()],
            fields: [Field.t()],
            participants: [Participant.t()],
            mode: String.t() | nil,
            paths: [Path.t()],
            timetag_ref: String.t() | nil,
            time_system: String.t() | nil,
            range_units: String.t()
          }
  end

  defmodule Segment do
    @moduledoc """
    One TDM metadata/data segment.
    """

    @enforce_keys [:metadata, :data]
    defstruct [:metadata, :data]

    @type t :: %__MODULE__{metadata: Metadata.t(), data: DataSection.t()}
  end

  @typedoc "Failure reason from TDM parsing or encoding."
  @type error ::
          :missing_version
          | :no_segments
          | {:section, {String.t(), String.t()}}
          | {:malformed_line, {String.t(), String.t()}}
          | {:malformed_record, {String.t(), String.t()}}
          | {:invalid_field, {String.t(), String.t()}}

  defstruct version: "2.0",
            comments: [],
            creation_date: nil,
            originator: nil,
            message_id: nil,
            header_fields: [],
            segments: []

  @type t :: %__MODULE__{
          version: String.t(),
          comments: [String.t()],
          creation_date: String.t() | nil,
          originator: String.t() | nil,
          message_id: String.t() | nil,
          header_fields: [Field.t()],
          segments: [Segment.t()]
        }

  @doc """
  Parse a TDM KVN document.
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, error()}
  def parse(text) when is_binary(text), do: parse_kvn(text)

  @doc """
  Parse a TDM KVN document explicitly.
  """
  @spec parse_kvn(String.t()) :: {:ok, t()} | {:error, error()}
  def parse_kvn(text) when is_binary(text) do
    text
    |> NIF.tdm_parse_kvn()
    |> from_nif_result()
  end

  @doc """
  Encode a TDM as KVN text.
  """
  @spec encode(t()) :: {:ok, String.t()} | {:error, error()}
  def encode(%__MODULE__{} = tdm), do: encode_kvn(tdm)

  @doc """
  Encode a TDM as KVN text explicitly.
  """
  @spec encode_kvn(t()) :: {:ok, String.t()} | {:error, error()}
  def encode_kvn(%__MODULE__{} = tdm) do
    tdm
    |> to_fields()
    |> NIF.tdm_encode_kvn()
    |> encoded_result()
  end

  defp from_nif_result({:ok, fields}), do: {:ok, from_fields(fields)}
  defp from_nif_result({:error, reason, detail}), do: {:error, error(reason, detail)}

  defp encoded_result({:ok, text}), do: {:ok, text}
  defp encoded_result({:error, reason, detail}), do: {:error, error(reason, detail)}

  defp error(reason, nil), do: reason
  defp error(reason, detail), do: {reason, detail}

  defp from_fields(fields) do
    %__MODULE__{
      version: fields.version,
      comments: fields.comments,
      creation_date: fields.creation_date,
      originator: fields.originator,
      message_id: fields.message_id,
      header_fields: Enum.map(fields.header_fields, &field_from_fields/1),
      segments: Enum.map(fields.segments, &segment_from_fields/1)
    }
  end

  defp field_from_fields(fields), do: %Field{key: fields.key, value: fields.value}

  defp observable_from_fields(fields) do
    %Observable{
      kind: String.to_atom(fields.kind),
      participant: fields.participant,
      name: fields.name
    }
  end

  defp scalar_from_fields(fields), do: %Scalar{text: fields.text, value: fields.value}

  defp record_from_fields(fields) do
    %DataRecord{
      observable: observable_from_fields(fields.observable),
      keyword: fields.keyword,
      epoch: fields.epoch,
      value: scalar_from_fields(fields.value),
      unit: fields.unit
    }
  end

  defp data_section_from_fields(fields) do
    %DataSection{
      comments: fields.comments,
      records: Enum.map(fields.records, &record_from_fields/1)
    }
  end

  defp participant_from_fields(fields), do: %Participant{index: fields.index, name: fields.name}

  defp path_from_fields(fields) do
    %Path{key: fields.key, index: fields.index, participants: fields.participants}
  end

  defp metadata_from_fields(fields) do
    %Metadata{
      comments: fields.comments,
      fields: Enum.map(fields.fields, &field_from_fields/1),
      participants: Enum.map(fields.participants, &participant_from_fields/1),
      mode: fields.mode,
      paths: Enum.map(fields.paths, &path_from_fields/1),
      timetag_ref: fields.timetag_ref,
      time_system: fields.time_system,
      range_units: fields.range_units
    }
  end

  defp segment_from_fields(fields) do
    %Segment{
      metadata: metadata_from_fields(fields.metadata),
      data: data_section_from_fields(fields.data)
    }
  end

  defp to_fields(%__MODULE__{} = tdm) do
    %{
      version: tdm.version,
      comments: tdm.comments,
      creation_date: tdm.creation_date,
      originator: tdm.originator,
      message_id: tdm.message_id,
      header_fields: Enum.map(tdm.header_fields, &field_to_fields/1),
      segments: Enum.map(tdm.segments, &segment_to_fields/1)
    }
  end

  defp field_to_fields(%Field{} = field), do: %{key: field.key, value: field.value}

  defp observable_to_fields(%Observable{} = observable) do
    %{
      kind: Atom.to_string(observable.kind),
      participant: observable.participant,
      name: observable.name
    }
  end

  defp scalar_to_fields(%Scalar{} = scalar), do: %{text: scalar.text, value: scalar.value / 1.0}

  defp record_to_fields(%DataRecord{} = record) do
    %{
      observable: observable_to_fields(record.observable),
      keyword: record.keyword,
      epoch: record.epoch,
      value: scalar_to_fields(record.value),
      unit: record.unit
    }
  end

  defp data_section_to_fields(%DataSection{} = data) do
    %{
      comments: data.comments,
      records: Enum.map(data.records, &record_to_fields/1)
    }
  end

  defp participant_to_fields(%Participant{} = participant) do
    %{index: participant.index, name: participant.name}
  end

  defp path_to_fields(%Path{} = path) do
    %{key: path.key, index: path.index, participants: path.participants}
  end

  defp metadata_to_fields(%Metadata{} = metadata) do
    %{
      comments: metadata.comments,
      fields: Enum.map(metadata.fields, &field_to_fields/1),
      participants: Enum.map(metadata.participants, &participant_to_fields/1),
      mode: metadata.mode,
      paths: Enum.map(metadata.paths, &path_to_fields/1),
      timetag_ref: metadata.timetag_ref,
      time_system: metadata.time_system,
      range_units: metadata.range_units
    }
  end

  defp segment_to_fields(%Segment{} = segment) do
    %{
      metadata: metadata_to_fields(segment.metadata),
      data: data_section_to_fields(segment.data)
    }
  end
end
