defmodule Sidereon.GNSS.PrecisePositioning.CycleSlip do
  @moduledoc """
  Stateful dual-frequency Melbourne-Wubbena and geometry-free cycle-slip detection.

  All maps are plain Elixir values and compare structurally with `==`. Numerical
  work and validation are delegated to the precise-positioning core.
  """
  alias Sidereon.GNSS.Time.ExactEpoch
  alias Sidereon.NIF

  defmodule Error do
    @moduledoc "A cycle-slip refusal with stable core detail and display text."
    @enforce_keys [:kind, :message]
    defstruct [:kind, :field, :reason, :message]

    defimpl String.Chars, for: __MODULE__ do
      def to_string(error), do: error.message
    end
  end

  @type observation :: %{required(atom()) => term()}
  @type config :: %{required(atom()) => number() | non_neg_integer()}
  @type state :: %{required(atom()) => term()}

  @doc "Return the core default detector configuration."
  def config do
    {mw, gf, minimum, k, gap} = NIF.pp_cycle_config_default()

    %{
      melbourne_wubbena_threshold_cycles: mw,
      geometry_free_threshold_m: gf,
      minimum_arc_length: minimum,
      running_statistic_k_factor: k,
      maximum_gap_s: gap
    }
  end

  @doc "Return an empty core detector state value."
  def state do
    NIF.pp_cycle_state_default() |> decode_state()
  end

  @doc "Compute the Melbourne-Wubbena combination in wide-lane cycles."
  def melbourne_wubbena_cycles(observation), do: normalize(NIF.pp_cycle_mw(observation_term(observation)))

  @doc "Compute the geometry-free carrier combination in metres."
  def geometry_free_m(observation), do: normalize(NIF.pp_cycle_gf(observation_term(observation)))

  @doc "Update Melbourne-Wubbena state, returning the updated state and classification."
  def update_melbourne_wubbena(state, observation, config \\ config()) do
    case NIF.pp_cycle_update_mw(state_term(state), observation_term(observation), config_term(config)) do
      {:ok, {next, value, slip}} -> {:ok, %{state: decode_state(next), melbourne_wubbena_cycles: value, slip: slip}}
      {:error, detail} -> {:error, decode_error(detail)}
    end
  end

  @doc "Update geometry-free state, returning the updated state and classification."
  def update_geometry_free(state, observation, epoch_time_s, epoch \\ nil, config \\ config()) do
    case NIF.pp_cycle_update_gf(
           state_term(state),
           observation_term(observation),
           epoch_time_s,
           exact_epoch_term(epoch),
           config_term(config)
         ) do
      {:ok, {next, value, slip, reset}} ->
        {:ok, %{state: decode_state(next), geometry_free_m: value, slip: slip, reset: reset}}

      {:error, detail} ->
        {:error, decode_error(detail)}
    end
  end

  @doc "Detect cycle slips across ordered dual-frequency epochs."
  def detect_cycle_slips(epochs, config \\ config()) do
    terms =
      Enum.map(epochs, fn epoch ->
        {Map.get(epoch, :gap_time_s), exact_epoch_term(Map.get(epoch, :gap_epoch)),
         Enum.map(epoch.observations, &observation_term/1)}
      end)

    case NIF.pp_cycle_detect(terms, config_term(config)) do
      {:ok, rows} ->
        {:ok,
         Enum.map(rows, fn {time, exact, observations} ->
           %{
             gap_time_s: time,
             gap_epoch: decode_exact_epoch(exact),
             observations:
               Enum.map(observations, fn {sat, slip, reasons} ->
                 %{satellite_id: sat, slip: slip, reasons: Enum.map(reasons, &String.to_existing_atom/1)}
               end)
           }
         end)}

      {:error, detail} ->
        {:error, decode_error(detail)}
    end
  end

  defp observation_term(o),
    do:
      {o.satellite_id, o.ambiguity_id, {o.p1_m / 1, o.p2_m / 1, o.phi1_cyc / 1, o.phi2_cyc / 1},
       {o.f1_hz / 1, o.f2_hz / 1}, {Map.get(o, :lli1), Map.get(o, :lli2)}}

  defp config_term(c),
    do:
      {c.melbourne_wubbena_threshold_cycles / 1, c.geometry_free_threshold_m / 1, c.minimum_arc_length,
       c.running_statistic_k_factor / 1, c.maximum_gap_s / 1}

  defp state_term(s),
    do:
      {s.previous_epoch_time_s, exact_epoch_term(s.previous_epoch), s.previous_melbourne_wubbena_cycles,
       {s.melbourne_wubbena.sample_count, s.melbourne_wubbena.mean / 1, s.melbourne_wubbena.variance / 1},
       s.previous_geometry_free_m}

  defp decode_state({time, epoch, mw, {count, mean, variance}, gf}),
    do: %{
      previous_epoch_time_s: time,
      previous_epoch: decode_exact_epoch(epoch),
      previous_melbourne_wubbena_cycles: mw,
      melbourne_wubbena: %{sample_count: count, mean: mean, variance: variance},
      previous_geometry_free_m: gf
    }

  defp exact_epoch_term(nil), do: nil
  defp exact_epoch_term(%ExactEpoch{handle: handle}), do: handle
  defp exact_epoch_term(resource) when is_reference(resource), do: resource
  defp decode_exact_epoch(nil), do: nil
  defp decode_exact_epoch(handle), do: ExactEpoch.from_handle(handle)
  defp normalize({:error, detail}), do: {:error, decode_error(detail)}
  defp normalize(result), do: result

  defp decode_error({kind, field, reason, message}),
    do: %Error{kind: cycle_kind(kind), field: field, reason: reason, message: message}

  defp cycle_kind("invalid_config"), do: :invalid_config
  defp cycle_kind("non_finite_observation"), do: :non_finite_observation
  defp cycle_kind("non_finite_epoch_time"), do: :non_finite_epoch_time
  defp cycle_kind("epochs_not_ordered"), do: :epochs_not_ordered
  defp cycle_kind("invalid_frequency"), do: :invalid_frequency
  defp cycle_kind("equal_frequencies"), do: :equal_frequencies
end
