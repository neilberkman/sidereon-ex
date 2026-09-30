defmodule Sidereon.CCSDS.TDM.Metadata do
  @moduledoc """
  Metadata block for one TDM segment.

  `fields` holds the block's `KEY = value` assignments in order, and is the
  block's authority. `participants`, `mode`, `paths`, `timetag_ref`,
  `time_system` and `range_units` are derived from it: read them, but change a
  block through `from_raw/2`, `from_raw_with_policy/3`, `replace_raw/3` or
  `replace_raw_with_policy/4`, which validate the fields and derive every
  property from them in one step. The encoders refuse a block whose derived
  properties disagree with its fields as
  `{:metadata_not_derived, %{segment, property}}`.

  `comments` holds the block's comments, each with the index of the field it
  precedes.

  `range_units` is `"km"` when the block states no `RANGE_UNITS`.
  """

  alias Sidereon.CCSDS.TDM
  alias Sidereon.CCSDS.TDM.Comment
  alias Sidereon.CCSDS.TDM.Departure
  alias Sidereon.CCSDS.TDM.Field
  alias Sidereon.CCSDS.TDM.WritePolicy
  alias Sidereon.NIF

  defstruct comments: [],
            fields: [],
            participants: [],
            mode: nil,
            paths: [],
            timetag_ref: nil,
            time_system: nil,
            range_units: "km"

  @type t :: %__MODULE__{
          comments: [Comment.t()],
          fields: [Field.t()],
          participants: [TDM.Participant.t()],
          mode: String.t() | nil,
          paths: [TDM.Path.t()],
          timetag_ref: String.t() | nil,
          time_system: String.t() | nil,
          range_units: String.t()
        }

  @doc """
  Build a metadata block from its ordered raw fields and positioned comments
  under the strict writer policy.

  The fields are held to table 3-3's keywords, order and mandatory entries,
  single value assignment and path participant references, and the comments to
  positions the writer can emit unchanged; every derived property comes from the
  fields. Returns `{:ok, %Metadata{}}` or `{:error, {tag, fields}}` as
  `Sidereon.CCSDS.TDM` lists them; a segment-specific refusal names segment 1.
  """
  @spec from_raw([Field.t()], [Comment.t()]) :: {:ok, t()} | {:error, term()}
  def from_raw(fields, comments) when is_list(fields) and is_list(comments) do
    case TDM.raw_to_nif(fields, comments) do
      {:ok, {field_terms, comment_terms}} -> metadata_result(NIF.tdm_metadata_from_raw(field_terms, comment_terms))
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Build a metadata block from its ordered raw fields and positioned comments
  under a writer policy.

  `policy` is a `Sidereon.CCSDS.TDM.WritePolicy`, or a keyword list or map of its
  axes. Returns `{:ok, %{value: metadata, departures: departures}}`, every
  forgiven departure listed as a `Sidereon.CCSDS.TDM.Departure`, or
  `{:error, reason}`. What no policy forgives, such as conflicting keywords or an
  undefined path participant, is refused under every policy.
  """
  @spec from_raw_with_policy([Field.t()], [Comment.t()], WritePolicy.t() | keyword() | map()) ::
          {:ok, %{value: t(), departures: [Departure.t()]}} | {:error, term()}
  def from_raw_with_policy(fields, comments, policy) when is_list(fields) and is_list(comments) do
    with {:ok, policy_term} <- WritePolicy.to_nif_map(policy),
         {:ok, {field_terms, comment_terms}} <- TDM.raw_to_nif(fields, comments) do
      case NIF.tdm_metadata_from_raw_with_policy(field_terms, comment_terms, policy_term) do
        {:ok, metadata, departures} -> {:ok, with_departures(metadata, departures)}
        {:error, _reason} = error -> error
      end
    end
  end

  @doc """
  Replace a block's raw fields and comments under the strict writer policy.

  The replacement is atomic: on success every field, comment and derived
  property is the new one; on refusal nothing is replaced and the refusal is
  returned. Returns `{:ok, %Metadata{}}` or `{:error, reason}` as `from_raw/2`.
  """
  @spec replace_raw(t(), [Field.t()], [Comment.t()]) :: {:ok, t()} | {:error, term()}
  def replace_raw(%__MODULE__{} = metadata, fields, comments) when is_list(fields) and is_list(comments) do
    with {:ok, current} <- TDM.metadata_to_nif(metadata),
         {:ok, {field_terms, comment_terms}} <- TDM.raw_to_nif(fields, comments) do
      metadata_result(NIF.tdm_metadata_replace_raw(current, field_terms, comment_terms))
    end
  end

  @doc """
  Replace a block's raw fields and comments under a writer policy.

  Atomic as `replace_raw/3`. Returns
  `{:ok, %{value: metadata, departures: departures}}` or `{:error, reason}` as
  `from_raw_with_policy/3`.
  """
  @spec replace_raw_with_policy(t(), [Field.t()], [Comment.t()], WritePolicy.t() | keyword() | map()) ::
          {:ok, %{value: t(), departures: [Departure.t()]}} | {:error, term()}
  def replace_raw_with_policy(%__MODULE__{} = metadata, fields, comments, policy)
      when is_list(fields) and is_list(comments) do
    with {:ok, policy_term} <- WritePolicy.to_nif_map(policy),
         {:ok, current} <- TDM.metadata_to_nif(metadata),
         {:ok, {field_terms, comment_terms}} <- TDM.raw_to_nif(fields, comments) do
      case NIF.tdm_metadata_replace_raw_with_policy(current, field_terms, comment_terms, policy_term) do
        {:ok, replaced, departures} -> {:ok, with_departures(replaced, departures)}
        {:error, _reason} = error -> error
      end
    end
  end

  defp metadata_result({:ok, metadata}), do: {:ok, TDM.metadata_from_nif_map(metadata)}
  defp metadata_result({:error, _reason} = error), do: error

  defp with_departures(metadata, departures) do
    %{value: TDM.metadata_from_nif_map(metadata), departures: Enum.map(departures, &Departure.from_nif_map/1)}
  end
end
