defmodule Sidereon.CCSDS.TDM.Warning do
  @moduledoc """
  A departure from CCSDS 503.0-B-2 the TDM reader forgave under a
  `Sidereon.CCSDS.TDM.Policy` instead of refusing the message.

  `tag` names the departure and decides which of the other fields are set; every
  other field is `nil`:

    * `:non_printable_character` - `line`, `keyword`, `column`, `character`
    * `:line_too_long` - `line`, `keyword`, `length`
    * `:repeated_keyword` - `line`, `keyword`, `section`: a keyword repeated
      in one block with the same value, which the reader takes whatever the
      policy says, since both lines say the same thing.
    * `:missing_keyword` - `keyword`, `segment` (`nil` for the header)
    * `:empty_data_section` - `segment`
    * `:records_out_of_order` - `segment`, `keyword`, `epoch`
    * `:duplicate_record` - `segment`, `keyword`, `epoch`; both records are
      kept, in the order the message gives them.
    * `:keyword_out_of_order` - `line`, `keyword`, `section`; in the `:data`
      section, a comment after a record.
    * `:unterminated_final_line` - `line`
    * `:unhandled` - a departure this binding predates. Only `message` is set,
      the core's own text; no other tag stands in for it.

  `line` is the one-based input line, `segment` one-based, `section` `:header`,
  `:metadata` or `:data`, and `character` a one-character string. `message` is
  the core's text for the departure, carried beside the fields.
  """

  @enforce_keys [:tag, :message]
  defstruct [:tag, :line, :keyword, :column, :character, :length, :section, :segment, :epoch, :message]

  @type tag ::
          :non_printable_character
          | :line_too_long
          | :repeated_keyword
          | :missing_keyword
          | :empty_data_section
          | :records_out_of_order
          | :duplicate_record
          | :keyword_out_of_order
          | :unterminated_final_line
          | :unhandled

  @type t :: %__MODULE__{
          tag: tag(),
          line: pos_integer() | nil,
          keyword: String.t() | nil,
          column: pos_integer() | nil,
          character: String.t() | nil,
          length: non_neg_integer() | nil,
          section: :header | :metadata | :data | String.t() | nil,
          segment: pos_integer() | nil,
          epoch: String.t() | nil,
          message: String.t()
        }

  @doc false
  @spec from_nif_map(map()) :: t()
  def from_nif_map(fields) when is_map(fields), do: struct!(__MODULE__, fields)
end
