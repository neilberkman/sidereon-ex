defmodule Sidereon.GNSS.Ionosphere.Warning do
  @moduledoc """
  A finding the IONEX reader reports without refusing the file.

  Most concern a header record that summarizes or describes the maps. The values
  read do not depend on such a record: every map carries its own epoch and
  bands, so the file reads the same with or without it.

  `tag` names the finding and decides which of the other fields are set:

    * `:missing_record` - `label`
    * `:version_record_not_first` - `line`
    * `:epoch_mismatch` - `label`, `line`, `declared_epoch`, `maps_epoch`
    * `:map_count_mismatch` - `line`, `declared_count`, `tec_maps`, `all_maps`
    * `:not_a_number_value` - `kind`, `map_number`, `line`, `lat_deg`, `lon_deg`
    * `:interval_mismatch` - `line`, `declared_s`, `map_number`, `spacing_s`
    * `:exponent_carried_into_map` - `kind`, `map_number`, `line`, `exponent`,
      `set_by_line`
    * `:unhandled` - a finding the core reports that this binding predates. Only
      `message` is set, and it is the core's own text; no other tag stands in
      for it.

  `kind` is the band the finding concerns: `:tec`, `:rms` or `:height` for the
  names the core uses, and the core's own string for any other.

  `message` is the core's formatted text for the finding, carried beside the
  fields rather than instead of them.

  A record the reader passes over raises no finding here. It is counted instead,
  and read with `Sidereon.GNSS.Ionosphere.skipped_records/1` or from a
  `Sidereon.GNSS.Ionosphere.ParseResult`, so an empty warning list does not by
  itself say that nothing was left out.
  """

  alias Sidereon.GNSS.Ionosphere.Epoch

  @enforce_keys [:tag, :message]
  defstruct [
    :tag,
    :label,
    :line,
    :declared_epoch,
    :maps_epoch,
    :declared_count,
    :tec_maps,
    :all_maps,
    :kind,
    :map_number,
    :lat_deg,
    :lon_deg,
    :declared_s,
    :spacing_s,
    :exponent,
    :set_by_line,
    :message
  ]

  @type tag ::
          :missing_record
          | :version_record_not_first
          | :epoch_mismatch
          | :map_count_mismatch
          | :not_a_number_value
          | :interval_mismatch
          | :exponent_carried_into_map
          | :unhandled

  @type kind :: :tec | :rms | :height | String.t()

  @type t :: %__MODULE__{
          tag: tag(),
          label: String.t() | nil,
          line: non_neg_integer() | nil,
          declared_epoch: Epoch.t() | nil,
          maps_epoch: Epoch.t() | nil,
          declared_count: non_neg_integer() | nil,
          tec_maps: non_neg_integer() | nil,
          all_maps: non_neg_integer() | nil,
          kind: kind() | nil,
          map_number: non_neg_integer() | nil,
          lat_deg: float() | nil,
          lon_deg: float() | nil,
          declared_s: non_neg_integer() | nil,
          spacing_s: integer() | nil,
          exponent: integer() | nil,
          set_by_line: non_neg_integer() | nil,
          message: String.t()
        }

  @doc false
  @spec from_nif_map(map()) :: t()
  def from_nif_map(fields) when is_map(fields) do
    fields
    |> Map.update!(:declared_epoch, &epoch/1)
    |> Map.update!(:maps_epoch, &epoch/1)
    |> then(&struct!(__MODULE__, &1))
  end

  defp epoch(nil), do: nil
  defp epoch(term), do: Epoch.from_nif_term(term)
end
