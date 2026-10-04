defmodule Sidereon.Test.ModelClock do
  @moduledoc false

  # The satellite clock a single-frequency positioning model uses for a
  # predicted observation: the source clock, plus the relativistic term a
  # product clock leaves to the user, less the broadcast group delay. Tests
  # that synthesize pseudoranges from `Sidereon.GNSS.Observables.predict/5`
  # form them with this clock so the solver inverts the model it applies.

  alias Sidereon.GNSS.Observables

  @speed_of_light_m_s 299_792_458.0

  @doc false
  @spec sat_clock_s(map()) :: float()
  def sat_clock_s(%{sat_clock_s: clock_s} = observables) when is_float(clock_s) do
    clock_s + relativity_s(observables) - group_delay_s(observables)
  end

  @doc false
  # The pseudorange `P` a receiver at `receiver` time-tagging `epoch` records
  # when the positioning models place the satellite from `P` itself (RTKLIB
  # `satposs`): the fixed point of `P = range(P) + delay(geometry(P))`, where
  # `geometry(P)` is `Observables.pseudorange_transmit_geometry/6`
  # and `delay` gives the rest of the pseudorange (clock terms, media) from
  # that geometry. The iteration starts from `initial_m`; each step moves the
  # transmission epoch by the change in `P` over `c`, so the change shrinks by
  # the range rate over `c`, about 3e-6, per step.
  @spec placed_pseudorange(term(), String.t(), tuple(), NaiveDateTime.t(), float(), (map() -> float())) :: float()
  def placed_pseudorange(source, sat, receiver, epoch, initial_m, delay_fun) do
    Enum.reduce_while(1..8, initial_m, fn _step, pseudorange_m ->
      {:ok, geometry} =
        Observables.pseudorange_transmit_geometry(source, sat, receiver, epoch, pseudorange_m)

      next = geometry.geometric_range_m + delay_fun.(geometry)

      if next == pseudorange_m, do: {:halt, next}, else: {:cont, next}
    end)
  end

  @doc false
  # The clean single-frequency pseudorange of `sat` for a receiver at `receiver`
  # with clock offset `rx_clock_s`, time-tagged `epoch`, as SPP models it:
  # `range + c (rx_clock - sat_clock)`, with the model's satellite clock
  # (`sat_clock_s/1`) and the satellite placed from the pseudorange.
  @spec spp_pseudorange(term(), String.t(), tuple(), NaiveDateTime.t(), float()) :: float()
  def spp_pseudorange(source, sat, receiver, epoch, rx_clock_s) do
    {:ok, predicted} = Observables.predict(source, sat, receiver, epoch)
    delay = fn geometry -> @speed_of_light_m_s * (rx_clock_s - sat_clock_s(geometry)) end
    placed_pseudorange(source, sat, receiver, epoch, predicted.geometric_range_m + delay.(predicted), delay)
  end

  defp relativity_s(%{sat_clock_relativity_s: term}) when is_float(term), do: term
  defp relativity_s(%{sat_clock_relativity_s: :not_applicable}), do: 0.0

  defp group_delay_s(%{single_frequency_group_delay_s: delay}) when is_float(delay), do: delay
  defp group_delay_s(%{single_frequency_group_delay_s: nil}), do: 0.0
end
