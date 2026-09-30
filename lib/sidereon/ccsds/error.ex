defmodule Sidereon.CCSDS.Error do
  @moduledoc """
  Typed refusal reasons of the CCSDS NDM readers and writers (OMM, OPM, OEM,
  CDM) and of the TLE codec.

  Every reason carries every field the core refusal holds, in one shape: a
  refusal with no fields is its atom (`:incomplete_state_vector`), and one
  with fields is a tuple of its atom and its fields in order
  (`{:duplicate_field, field, first, second}`).

  A field the core names with a fixed identifier (`MEAN_MOTION`,
  `epoch.month`) is an atom, lowercased (`:mean_motion`, `:"epoch.month"`).
  Text taken from the input, such as a keyword a message states, is a string,
  so no atom is formed from input. Counts, indices and line numbers are
  integers, and an optional value is `nil` when absent.

  The writers refuse fields that cannot form a message before the core sees
  them: `{:invalid_length, group, expected, got}` for a list of the wrong
  length (a covariance without 21 lower-triangle values, a CDM covariance row
  group of the wrong length), and `{:invalid_field, field, :out_of_range |
  :non_finite}` for an integer no core field holds or a number that is not
  finite.
  """

  @typedoc "Why a text value cannot be written so that its reader returns it unchanged."
  @type text_issue ::
          :line_break
          | :surrounding_whitespace
          | :interior_whitespace
          | :keyword_separator
          | :xml_illegal_character
          | :empty
          | :detached_comment
          | :repeated_parameter
          | :comment_not_carried

  @typedoc "Why a numeric or civil-time field was refused."
  @type input_kind ::
          :missing
          | :non_finite
          | :float_parse
          | :int_parse
          | :not_positive
          | :negative
          | :out_of_range
          | :invalid_civil_date
          | :invalid_civil_time

  @typedoc "A refusal of fields that do not form a message, before a writer runs."
  @type input_refusal ::
          {:invalid_length, atom(), non_neg_integer(), non_neg_integer()}
          | {:invalid_field, atom(), :out_of_range | :non_finite}

  @typedoc """
  The refusals the OMM, OPM, OEM and CDM readers and writers share: a field
  that does not read, a keyword repeated with a different value, a unit that
  contradicts the standard's table, a document holding several messages, a
  keyword the standard does not define at its position, a KVN line that is not
  blank, a comment or an assignment, and text a writer cannot write so that its
  reader returns it unchanged.
  """
  @type shared ::
          {:invalid_field, atom(), input_kind()}
          | {:duplicate_field, String.t(), String.t(), String.t()}
          | {:unit_mismatch, String.t(), String.t(), String.t() | nil}
          | {:multiple_messages, non_neg_integer()}
          | {:unknown_field, String.t()}
          | {:malformed_line, pos_integer(), String.t()}
          | {:unwritable_text, String.t(), String.t(), text_issue()}

  @typedoc "An OMM reader or writer refusal. `:in_record` names the record of a GP JSON array or CSV file it concerns."
  @type omm ::
          shared()
          | {:missing_field, atom()}
          | {:field, String.t()}
          | {:epoch, String.t()}
          | {:csv_column_count, non_neg_integer(), non_neg_integer()}
          | {:csv_empty_block, atom()}
          | {:in_record, non_neg_integer(), omm()}
          | {:csv_column_order, String.t(), String.t()}
          | {:incompatible_metadata, atom(), String.t()}
          | input_refusal()

  @typedoc "An OPM reader or writer refusal."
  @type opm :: shared() | {:missing_field, atom()} | {:field, String.t()} | input_refusal()

  @typedoc "An OEM reader or writer refusal."
  @type oem :: shared() | {:missing_field, atom()} | {:field, String.t()} | input_refusal()

  @typedoc "Why the OEM KVN reader skipped an ephemeris data line."
  @type oem_state_line :: {:item_count, non_neg_integer()} | {:invalid_field, atom(), input_kind()}

  @typedoc "A CDM reader or writer refusal."
  @type cdm ::
          shared()
          | :incomplete_state_vector
          | {:malformed_xml, String.t()}
          | {:unexpected_object_count, non_neg_integer()}
          | {:unknown_object, String.t()}
          | {:repeated_object, String.t()}
          | {:hard_body_radius_comment, String.t()}
          | input_refusal()

  @typedoc """
  A TLE codec refusal. `reason` fields are the core's fixed description of the
  refusal, and line labels are `"line 1"` or `"line 2"`.
  """
  @type tle ::
          :non_ascii
          | :format
          | :satellite_mismatch
          | {:invalid_catalog_number, String.t(), String.t()}
          | {:catalog_number_out_of_range, non_neg_integer()}
          | {:invalid_field, atom(), String.t()}
          | {:field, String.t()}
          | {:checksum_mismatch, String.t(), 0..9, 0..9}
          | {:checksum_not_digit, String.t(), String.t(), 0..9}

  @typedoc "An SGP4 element-set refusal."
  @type sgp4 ::
          {:invalid_input, atom(), input_kind()}
          | {:non_finite_output, atom()}
          | {:invalid_tle, String.t()}
          | {:sgp4, integer()}
end
