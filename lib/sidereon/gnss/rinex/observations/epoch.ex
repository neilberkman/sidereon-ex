defmodule Sidereon.GNSS.RINEX.Observations.Epoch do
  @moduledoc """
  One epoch record of a RINEX observation product, as
  `Sidereon.GNSS.RINEX.Observations.epochs/1` lists them.

    * `index` - the zero-based position in the product, which every per-epoch
      accessor takes.
    * `epoch` - `{{year, month, day}, {hour, minute, second}}` in the file's time
      scale, or `nil` for an event whose epoch fields are blank. RINEX lets an
      event without a significant epoch leave them blank; an observation or
      cycle slip epoch always carries one. No time is made up for an event
      without one.
    * `epoch_picoseconds` - the RINEX 4.02 picosecond extension of the epoch
      line, `nil` where the line has none. `second` does not include it.
    * `flag` - 0 for an observation epoch, 1 after a power failure, 6 for cycle
      slip records, and any other flag above 1 for an event.
    * `rcv_clock_offset_s` - the receiver clock offset on the epoch line,
      seconds, or `nil`.
    * `declared_record_count` - the satellite or record count the epoch line
      declares.
    * `sat_count` - satellites holding observations; 0 for an event and for a
      cycle slip epoch.
    * `cycle_slip_count` - satellites holding cycle slips; non-zero only for a
      flag 6 epoch. The slips are read with
      `Sidereon.GNSS.RINEX.Observations.cycle_slips/3`.
    * `special_records` - the records an event epoch carried, verbatim, in
      order. Header records among them take effect from this epoch; see
      `Sidereon.GNSS.RINEX.Observations.header_at/2`.
  """

  @enforce_keys [
    :index,
    :epoch,
    :epoch_picoseconds,
    :flag,
    :rcv_clock_offset_s,
    :declared_record_count,
    :sat_count,
    :cycle_slip_count,
    :special_records
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          index: non_neg_integer(),
          epoch: {{integer(), integer(), integer()}, {integer(), integer(), float()}} | nil,
          epoch_picoseconds: non_neg_integer() | nil,
          flag: 0..255,
          rcv_clock_offset_s: float() | nil,
          declared_record_count: non_neg_integer(),
          sat_count: non_neg_integer(),
          cycle_slip_count: non_neg_integer(),
          special_records: [String.t()]
        }

  @doc false
  @spec from_nif_map(map(), non_neg_integer()) :: t()
  def from_nif_map(fields, index) when is_map(fields) and is_integer(index) do
    struct!(__MODULE__, Map.put(fields, :index, index))
  end
end
