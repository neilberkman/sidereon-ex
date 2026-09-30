defmodule Sidereon.GNSS.RINEX.Observations.PhaseRow do
  @moduledoc """
  One carrier-phase observation, as `Sidereon.GNSS.RINEX.Observations.phases/3`
  returns it.

  Every carrier-phase observation of the epoch has a row, whatever the header
  says about its correction.

    * `value_cycles`, `value_m` - the phase as the file records it, in cycles
      and in meters; `nil` for a blank observation or, for meters, an unknown
      wavelength.
    * `phase_shift` - what the header in effect at the epoch states about the
      signal's `SYS / PHASE SHIFT` correction:
      * `:available` - one correction, in `phase_shift_cycles`. No record, or a
        blank correction, is `0.0`; from RINEX 4.00, whose Table A2 says the
        record "should be ignored by RINEX decoders", it is `0.0` whatever the
        records say.
      * `:unknown` - the only record covering the signal names just its
        constellation, which declares the alignment unknown.
      * `:ambiguous` - records in one header block give the signal different
        corrections, listed in `phase_shift_corrections` in record order with
        `nil` for a blank one.
    * `phase_shift_cycles` - the correction for `:available`, `nil` otherwise.
    * `phase_shift_corrections` - the conflicting corrections for `:ambiguous`,
      `[]` otherwise.
    * `frequency_hz`, `wavelength_m` - the carrier, `nil` where it is not known,
      such as a GLONASS FDMA signal whose slot has no channel in the header in
      effect.

  The correction is metadata about the phase, not a term to add to it. RINEX 3
  phases are stored already aligned, and `SYS / PHASE SHIFT` reports the
  correction that alignment applied, so `value_cycles` already includes it;
  adding `phase_shift_cycles` would apply it a second time. It is what a caller
  subtracts to reconstruct the phase before alignment.
  """

  @enforce_keys [
    :code,
    :value_cycles,
    :value_m,
    :lli,
    :ssi,
    :frequency_hz,
    :wavelength_m,
    :phase_shift,
    :phase_shift_cycles,
    :phase_shift_corrections
  ]
  defstruct @enforce_keys

  @type phase_shift :: :available | :unknown | :ambiguous

  @type t :: %__MODULE__{
          code: String.t(),
          value_cycles: float() | nil,
          value_m: float() | nil,
          lli: non_neg_integer() | nil,
          ssi: non_neg_integer() | nil,
          frequency_hz: float() | nil,
          wavelength_m: float() | nil,
          phase_shift: phase_shift(),
          phase_shift_cycles: float() | nil,
          phase_shift_corrections: [float() | nil]
        }

  @doc false
  @spec from_nif_map(map()) :: t()
  def from_nif_map(fields) when is_map(fields), do: struct!(__MODULE__, fields)
end
