defmodule Sidereon.CCSDS.TDM.Departure do
  @moduledoc """
  A departure from CCSDS 503.0-B-2 the TDM writer emitted under a
  `Sidereon.CCSDS.TDM.WritePolicy`.

  Each names what makes the written text non-conforming, in the vocabulary
  `Sidereon.CCSDS.TDM.Warning` uses for the same departure on the way in; a
  reader under the matching `Sidereon.CCSDS.TDM.Policy` forgives exactly these.
  `tag` decides which of the other fields are set; every other field is `nil`:

    * `:non_printable_character` - `keyword`, `character`
    * `:line_too_long` - `keyword`, `length`
    * `:missing_keyword` - `keyword`, `segment` (`nil` for the header)
    * `:empty_data_section` - `segment`
    * `:records_out_of_order` - `segment`, `keyword`, `epoch`
    * `:duplicate_record` - `segment`, `keyword`, `epoch`
    * `:repeated_keyword` - `keyword`, `section`
    * `:keyword_out_of_order` - `keyword`, `section`; in the `:data` section, a
      comment written after a record.
    * `:unterminated_final_line` - no field: the last line has no terminator.
    * `:unhandled` - a departure this binding predates. Only `message` is set,
      the core's own text.

  `segment` is one-based and `section` is `:header`, `:metadata` or `:data`.
  `message` is the core's text for the departure.
  """

  @enforce_keys [:tag, :message]
  defstruct [:tag, :keyword, :character, :length, :segment, :epoch, :section, :message]

  @type tag ::
          :non_printable_character
          | :line_too_long
          | :missing_keyword
          | :empty_data_section
          | :records_out_of_order
          | :duplicate_record
          | :repeated_keyword
          | :keyword_out_of_order
          | :unterminated_final_line
          | :unhandled

  @type t :: %__MODULE__{
          tag: tag(),
          keyword: String.t() | nil,
          character: String.t() | nil,
          length: non_neg_integer() | nil,
          segment: pos_integer() | nil,
          epoch: String.t() | nil,
          section: :header | :metadata | :data | String.t() | nil,
          message: String.t()
        }

  @doc false
  @spec from_nif_map(map()) :: t()
  def from_nif_map(fields) when is_map(fields), do: struct!(__MODULE__, fields)
end
