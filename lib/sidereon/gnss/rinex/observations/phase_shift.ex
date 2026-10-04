defmodule Sidereon.GNSS.RINEX.Observations.PhaseShift do
  @moduledoc """
  One `SYS / PHASE SHIFT` header record, as the header holds it.

    * `system` - the constellation letter, such as `"G"`.
    * `code` - the carrier observable code, such as `"L1C"`, or `nil` for a
      record naming only its constellation. RINEX 3.05 section 5.2.12 leaves the
      code and the rest of the record blank where "the applied phase
      corrections or the phase alignment is unknown", so such a record gives no
      correction and declares the alignment of the constellation's signals no
      other record covers unknown.
    * `correction_cycles` - the correction in cycles, or `nil` where the record
      leaves the field blank ("Correction applied (cycles) or blank if none").
      A blank correction is not read as `0.0` here; the phase rows of
      `Sidereon.GNSS.RINEX.Observations.phases/3` state what correction applies.
    * `satellites` - the satellites the record names. An empty list, with no
      `unrepresentable_satellites` either, means every satellite of the system
      and code.
    * `unrepresentable_satellites` - satellites the record names by a
      well-formed designator no satellite id holds, such as `"R28"`, as
      written. No observation of theirs is kept, so the correction applies to
      none of them; they are kept so the record is written back whole.
  """

  @enforce_keys [:system, :code, :correction_cycles, :satellites, :unrepresentable_satellites]
  defstruct [:system, :code, :correction_cycles, :satellites, :unrepresentable_satellites]

  @type t :: %__MODULE__{
          system: String.t(),
          code: String.t() | nil,
          correction_cycles: float() | nil,
          satellites: [String.t()],
          unrepresentable_satellites: [String.t()]
        }

  @doc false
  @spec from_nif_map(map()) :: t()
  def from_nif_map(fields) when is_map(fields), do: struct!(__MODULE__, fields)
end
