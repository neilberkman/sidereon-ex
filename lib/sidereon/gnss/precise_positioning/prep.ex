defmodule Sidereon.GNSS.PrecisePositioning.Prep do
  @moduledoc "Dual-frequency preparation for float and wide-lane-fixed PPP."
  alias Sidereon.GNSS.Time.ExactEpoch
  alias Sidereon.NIF

  defmodule Error do
    @moduledoc "A PPP preparation refusal with stable variant and complete fields."
    @enforce_keys [:kind, :message]
    defstruct [
      :kind,
      :ambiguity_id,
      :satellite_id,
      :epoch_index,
      :count,
      :minimum,
      :mean_cycles,
      :fixed_cycles,
      :reasons,
      :reason,
      :message
    ]

    defimpl String.Chars, for: __MODULE__ do
      def to_string(error), do: error.message
    end
  end

  @doc "Return the core carrier-phase cycle-slip preparation defaults."
  def cycle_slip_options do
    {gf, mw, gap} = NIF.pp_prep_cycle_slip_options_default()
    %{gf_threshold_m: gf, mw_threshold_cycles: mw, min_arc_gap_s: gap}
  end

  @doc "Prepare wide-lane-fixed dual-frequency epochs through the core."
  def prepare_widelane_fixed_epochs(epochs, wide_lane, policy, slip \\ cycle_slip_options()) do
    case NIF.pp_prepare_widelane(
           Enum.map(epochs, &dual_epoch_term/1),
           {wide_lane.min_epochs, wide_lane.tolerance_cycles / 1},
           Atom.to_string(policy),
           slip_term(slip)
         ) do
      {:ok, {epochs, wavelengths, offsets, cycles, dropped, arcs}} ->
        {:ok,
         %{
           epochs: Enum.map(epochs, &decode_prepared_epoch/1),
           wavelengths_m: Map.new(wavelengths),
           offsets_m: Map.new(offsets),
           wide_lane_cycles: Map.new(cycles),
           dropped_sats: dropped,
           split_arcs: Enum.map(arcs, &decode_arc/1)
         }}

      {:error, detail} ->
        {:error, decode_error(detail)}
    end
  end

  @doc "Rewrite float ambiguity ids at detected dual-frequency cycle slips."
  def split_float_cycle_slip_epochs(epochs, slip \\ cycle_slip_options()) do
    NIF.pp_split_float_slips(Enum.map(epochs, &float_epoch_term/1), slip_term(slip))
    |> Enum.map(fn rows ->
      %{observations: Enum.map(rows, fn {sat, id} -> %{satellite_id: sat, ambiguity_id: id} end)}
    end)
  end

  defp decode_prepared_epoch({index, rows}),
    do: %{
      epoch_index: index,
      observations:
        Enum.map(rows, fn {sat, id, code, phase} ->
          %{satellite_id: sat, ambiguity_id: id, code_m: code, phase_m: phase}
        end)
    }

  defp decode_arc({sat, id, first, last, count}),
    do: %{satellite_id: sat, ambiguity_id: id, start_epoch_index: first, end_epoch_index: last, n_epochs: count}

  defp dual_epoch_term(epoch),
    do:
      {Map.get(epoch, :gap_time_s), exact(Map.get(epoch, :gap_epoch)),
       Enum.map(epoch.observations, &observation_term/1)}

  defp float_epoch_term(epoch),
    do:
      {Map.get(epoch, :gap_time_s), exact(Map.get(epoch, :gap_epoch)),
       Enum.map(epoch.observations, fn row ->
         {row.satellite_id, row.ambiguity_id,
          case Map.get(row, :raw) do
            nil -> nil
            raw -> observation_term(raw)
          end}
       end)}

  defp observation_term(o),
    do:
      {o.satellite_id, o.ambiguity_id, {o.p1_m / 1, o.p2_m / 1, o.phi1_cyc / 1, o.phi2_cyc / 1},
       {o.f1_hz / 1, o.f2_hz / 1}, {Map.get(o, :lli1), Map.get(o, :lli2)}}

  defp slip_term(o), do: {o.gf_threshold_m / 1, o.mw_threshold_cycles / 1, o.min_arc_gap_s / 1}
  defp exact(nil), do: nil
  defp exact(%ExactEpoch{handle: handle}), do: handle

  defp decode_error(detail) when is_map(detail), do: struct!(Error, Map.update!(detail, :kind, &prep_kind/1))

  defp decode_error("unknown cycle-slip policy" = message),
    do: %Error{kind: :invalid_cycle_slip_policy, message: message}

  defp prep_kind("cycle_slip_detected"), do: :cycle_slip_detected
  defp prep_kind("wide_lane_failed"), do: :wide_lane_failed
  defp prep_kind("too_few_wide_lane_epochs"), do: :too_few_wide_lane_epochs
  defp prep_kind("wide_lane_not_integer"), do: :wide_lane_not_integer
  defp prep_kind("missing_wide_lane_ambiguity"), do: :missing_wide_lane_ambiguity
  defp prep_kind("inconsistent_frequencies"), do: :inconsistent_frequencies
  defp prep_kind("ionosphere_free_failed"), do: :ionosphere_free_failed
end
