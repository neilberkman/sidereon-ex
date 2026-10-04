defmodule Sidereon.GNSS.RINEX.Observations.Header do
  @moduledoc """
  A RINEX observation header, with every record the product holds.

  `Sidereon.GNSS.RINEX.Observations.header/1` returns the file header;
  `Sidereon.GNSS.RINEX.Observations.header_at/2` returns the header in effect at
  an epoch, which is the file header with the header records of every event at
  or before that epoch laid over it.

  A field is `nil` where the product holds no such record, and an empty list or
  map where the record holds no entries. Nothing absent is read as zero.

  ## Code lists

    * `obs_codes` - per constellation letter, the union of every list the file
      declares, in its header and after its events: the file header's codes
      first, then each code a later list declares, in the order first declared.
      Every observation and cycle slip value is index-aligned to this union.
    * `declared_obs_codes` - the lists this header itself declares. In the file
      header they are its `SYS / # / OBS TYPES` records, or at version 2 what
      `rinex2_types` reads as; in a header from `header_at/2` they are the lists
      in effect at that epoch.
    * `rinex2_types` - the version 2 `# / TYPES OF OBSERV` names as read, and
      `[]` at version 3.
    * `rinex2_system` - the constellation letter a version 2 version record
      names, `nil` for a mixed file or at version 3.

  ## Other records

    * `time_of_first_obs`, `time_of_last_obs` - `{epoch, time_scale}`, `epoch`
      being `{{year, month, day}, {hour, minute, second}}` and `time_scale` the
      scale's abbreviation, such as `"GPST"`.
    * `prn_obs_counts` - per satellite id, the `PRN / # OF OBS` counts, `nil`
      for a blank count.
    * `glonass_cod_phs_bis` - `nil` where the header has no
      `GLONASS COD/PHS/BIS` record; `[]` for a blank record, which RINEX 3.05
      section 5.2.16 gives where "the GLONASS code phase alignment is unknown";
      otherwise `[{code, bias_m}]` with `nil` for a blank bias.
    * `unretained_header_labels` - labels the reader read and does not keep,
      which a rewrite drops.
  """

  alias Sidereon.GNSS.RINEX.Observations.LeapSeconds
  alias Sidereon.GNSS.RINEX.Observations.PhaseShift
  alias Sidereon.GNSS.RINEX.Observations.ScaleFactor

  @enforce_keys [
    :version,
    :approx_position_m,
    :antenna_delta_hen_m,
    :obs_codes,
    :declared_obs_codes,
    :rinex2_types,
    :rinex2_system,
    :program_run_by_date,
    :comments,
    :marker_name,
    :marker_number,
    :marker_type,
    :observer,
    :agency,
    :receiver,
    :antenna,
    :interval_s,
    :time_of_first_obs,
    :time_of_last_obs,
    :n_satellites,
    :prn_obs_counts,
    :phase_shifts,
    :scale_factors,
    :glonass_slots,
    :glonass_cod_phs_bis,
    :signal_strength_unit,
    :leap_seconds,
    :unretained_header_labels
  ]
  defstruct @enforce_keys

  @typedoc "A civil epoch `{{year, month, day}, {hour, minute, second}}` in the file's time scale."
  @type epoch :: {{integer(), integer(), integer()}, {integer(), integer(), float()}}

  @type t :: %__MODULE__{
          version: float(),
          approx_position_m: {float(), float(), float()} | nil,
          antenna_delta_hen_m: {float(), float(), float()} | nil,
          obs_codes: %{String.t() => [String.t()]},
          declared_obs_codes: %{String.t() => [String.t()]},
          rinex2_types: [String.t()],
          rinex2_system: String.t() | nil,
          program_run_by_date: %{program: String.t(), run_by: String.t(), date: String.t()} | nil,
          comments: [String.t()],
          marker_name: String.t() | nil,
          marker_number: String.t() | nil,
          marker_type: String.t() | nil,
          observer: String.t() | nil,
          agency: String.t() | nil,
          receiver: %{number: String.t(), receiver_type: String.t(), version: String.t()} | nil,
          antenna: %{number: String.t(), antenna_type: String.t()} | nil,
          interval_s: float() | nil,
          time_of_first_obs: {epoch(), String.t()} | nil,
          time_of_last_obs: {epoch(), String.t()} | nil,
          n_satellites: non_neg_integer() | nil,
          prn_obs_counts: %{String.t() => [non_neg_integer() | nil]},
          phase_shifts: [PhaseShift.t()],
          scale_factors: [ScaleFactor.t()],
          glonass_slots: %{String.t() => integer()},
          glonass_cod_phs_bis: [{String.t(), float() | nil}] | nil,
          signal_strength_unit: String.t() | nil,
          leap_seconds: LeapSeconds.t() | nil,
          unretained_header_labels: [String.t()]
        }

  @doc false
  @spec from_nif_map(map()) :: t()
  def from_nif_map(fields) when is_map(fields) do
    fields
    |> Map.update!(:obs_codes, &Map.new/1)
    |> Map.update!(:declared_obs_codes, &Map.new/1)
    |> Map.update!(:prn_obs_counts, &Map.new/1)
    |> Map.update!(:glonass_slots, &Map.new/1)
    |> Map.update!(:phase_shifts, fn shifts -> Enum.map(shifts, &PhaseShift.from_nif_map/1) end)
    |> Map.update!(:scale_factors, fn factors -> Enum.map(factors, &ScaleFactor.from_nif_map/1) end)
    |> Map.update!(:leap_seconds, &leap_seconds/1)
    |> then(&struct!(__MODULE__, &1))
  end

  defp leap_seconds(nil), do: nil
  defp leap_seconds(fields), do: LeapSeconds.from_nif_map(fields)
end
