defmodule Sidereon.GNSS.RINEX.Observations.DowngradeChange do
  @moduledoc """
  One change `Sidereon.GNSS.RINEX.Observations.downgrade_to_rinex2/2` made to
  turn a product into one a version 2 file states exactly.

  `tag` names the change and decides which of the other fields are set; every
  field the change does not carry is `nil`:

    * `:code_renamed` - `system`, `from_code`, `to_code`: a code became the one
      its version 2 column reads as.
    * `:code_moved` - `system`, `code`, `from_position`, `to_position`: a code
      moved within its list, its values with it. Positions are zero-based.
    * `:code_added` - `system`, `code`: a code with no values was added so the
      constellations' lists line up under one list of version 2 names.
    * `:code_list_removed` - `system`, `codes`: a list no version 2 reader would
      build, since no observation or count names the constellation.
    * `:value_rounded` - `epoch_index`, `satellite`, `code`, `from_value`,
      `to_value`: an observation rounded to the three decimals its field holds.
    * `:cycle_slip_rounded` - the same fields, for a cycle slip.
    * `:scale_factors_removed` - `count`: the `SYS / SCALE FACTOR` records, over
      values that are already physical.
    * `:epoch_picoseconds_removed` - `epoch_index`, `picoseconds`.
    * `:clock_offset_rounded` - `epoch_index`, `from_value`, `to_value`: a
      receiver clock offset rounded to the nine decimals of the version 2
      field, in seconds.
    * `:in_event_lists` - `epoch_index`, `change`: a change to the code lists in
      effect from that event epoch, `change` being another `DowngradeChange`.
    * `:deprecated_records_removed` - `label`, `epoch_index`, `records`: the
      `SYS / PHASE SHIFT` or `GLONASS COD/PHS/BIS` records of a product read
      from RINEX 4, which version 4 declares ignored. `epoch_index` is `nil` for
      the file header.
    * `:event_records_rewritten` - `epoch_index`, `from_records`, `to_records`:
      an event's records as they were and as they are now.

  `message` is the core's description of the change.
  """

  @enforce_keys [:tag, :message]
  defstruct [
    :tag,
    :system,
    :code,
    :from_code,
    :to_code,
    :from_position,
    :to_position,
    :codes,
    :epoch_index,
    :satellite,
    :from_value,
    :to_value,
    :count,
    :picoseconds,
    :label,
    :records,
    :from_records,
    :to_records,
    :change,
    :message
  ]

  @type tag ::
          :code_renamed
          | :code_moved
          | :code_added
          | :code_list_removed
          | :value_rounded
          | :cycle_slip_rounded
          | :scale_factors_removed
          | :epoch_picoseconds_removed
          | :clock_offset_rounded
          | :in_event_lists
          | :deprecated_records_removed
          | :event_records_rewritten

  @type t :: %__MODULE__{
          tag: tag(),
          system: String.t() | nil,
          code: String.t() | nil,
          from_code: String.t() | nil,
          to_code: String.t() | nil,
          from_position: non_neg_integer() | nil,
          to_position: non_neg_integer() | nil,
          codes: [String.t()] | nil,
          epoch_index: non_neg_integer() | nil,
          satellite: String.t() | nil,
          from_value: float() | nil,
          to_value: float() | nil,
          count: non_neg_integer() | nil,
          picoseconds: non_neg_integer() | nil,
          label: String.t() | nil,
          records: [String.t()] | nil,
          from_records: [String.t()] | nil,
          to_records: [String.t()] | nil,
          change: t() | nil,
          message: String.t()
        }

  @doc false
  @spec from_nif_map(map()) :: t()
  def from_nif_map(fields) when is_map(fields) do
    fields
    |> Map.update!(:change, &nested/1)
    |> then(&struct!(__MODULE__, &1))
  end

  defp nested(nil), do: nil
  defp nested(fields), do: from_nif_map(fields)
end
