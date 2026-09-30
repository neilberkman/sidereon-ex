defmodule Sidereon.Test.CoreGolden do
  @moduledoc false

  # Reads the goldens test/generators/core_goldens writes: the inputs a test
  # hands to the binding and the core's own answer on exactly those inputs,
  # every float as the hex of its IEEE-754 bits.

  @dir Path.expand("../fixtures/core_goldens", __DIR__)

  @doc false
  @spec load(String.t()) :: map()
  def load(name), do: @dir |> Path.join(name) |> File.read!() |> Jason.decode!()

  @doc false
  # A hex-encoded float, or a nested list of them, decoded.
  @spec f(String.t() | list() | nil) :: float() | list() | nil
  def f(nil), do: nil
  def f(values) when is_list(values), do: Enum.map(values, &f/1)

  def f("0x" <> hex) do
    <<value::float-64>> = hex |> String.pad_leading(16, "0") |> Base.decode16!(case: :mixed)
    value
  end

  @doc false
  @spec tuple3(list()) :: {float(), float(), float()}
  def tuple3(values), do: values |> f() |> List.to_tuple()

  @doc false
  # `[token, hex]` observation pairs as `{token, pseudorange_m}`.
  @spec observations(list()) :: [{String.t(), float()}]
  def observations(rows), do: Enum.map(rows, fn [sat, pr] -> {sat, f(pr)} end)

  @doc false
  @spec status_atom(String.t()) :: atom()
  def status_atom("GradientTolerance"), do: :gradient_tolerance
  def status_atom("CostTolerance"), do: :cost_tolerance
  def status_atom("StepTolerance"), do: :step_tolerance
  def status_atom("MaxEvaluations"), do: :max_evaluations
  def status_atom("SelectionSettled"), do: :selection_settled
  def status_atom("OuterBudgetExhausted"), do: :outer_budget_exhausted
  def status_atom("OuterOscillation"), do: :outer_oscillation
end
