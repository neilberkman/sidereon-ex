defmodule Sidereon.ILS do
  @moduledoc """
  Integer least-squares search helpers.
  """

  alias Sidereon.NIF

  @type result :: %{
          fixed: [integer()],
          fixed_status: boolean(),
          ratio: float() | :infinity,
          best_score: float(),
          second_best_score: float() | nil,
          candidates_evaluated: non_neg_integer(),
          covariance: [[float()]],
          covariance_inverse: [[float()]]
        }

  @doc """
  Run LAMBDA integer least-squares search.
  """
  @spec lambda_ils_search([number()], [[number()]], number()) ::
          {:ok, result()} | {:error, term()}
  def lambda_ils_search(float_cycles, covariance, ratio_threshold \\ 3.0)
      when is_list(float_cycles) and is_list(covariance) and is_number(ratio_threshold) do
    with :ok <- validate_inputs(float_cycles, covariance) do
      NIF.ils_lambda_search(float_list(float_cycles), matrix(covariance), ratio_threshold / 1.0)
      |> decode_result()
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Run bounded integer least-squares search.
  """
  @spec bounded_ils_search([number()], [[number()]], integer(), pos_integer(), number()) ::
          {:ok, result()} | {:error, term()}
  def bounded_ils_search(float_cycles, covariance, radius \\ 1, candidate_limit \\ 200_000, ratio_threshold \\ 3.0)
      when is_list(float_cycles) and is_list(covariance) and is_integer(radius) and is_integer(candidate_limit) and
             is_number(ratio_threshold) do
    with :ok <- validate_inputs(float_cycles, covariance) do
      NIF.ils_search(
        float_list(float_cycles),
        matrix(covariance),
        radius,
        candidate_limit,
        ratio_threshold / 1.0
      )
      |> decode_result()
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  defp validate_inputs(float_cycles, covariance) do
    n = length(float_cycles)
    bad_row = Enum.find(covariance, fn row -> not is_list(row) or length(row) != n end)
    bad_width = if is_list(bad_row), do: length(bad_row), else: :non_list

    cond do
      n == 0 -> {:error, {:invalid_dimensions, 0, 0}}
      length(covariance) != n -> {:error, {:invalid_dimensions, n, length(covariance)}}
      bad_row -> {:error, {:invalid_dimensions, n, bad_width}}
      not Enum.all?(float_cycles, &is_number/1) -> {:error, :non_finite_input}
      not Enum.all?(covariance, fn row -> Enum.all?(row, &is_number/1) end) -> {:error, :non_finite_input}
      true -> :ok
    end
  end

  defp float_list(values), do: Enum.map(values, &(&1 / 1.0))
  defp matrix(rows), do: Enum.map(rows, &float_list/1)

  defp decode_result({:ok, {fixed, status, ratio, best, second, evaluated, {covariance, covariance_inverse}}}) do
    {:ok,
     %{
       fixed: fixed,
       fixed_status: status,
       ratio: ratio,
       best_score: best,
       second_best_score: second,
       candidates_evaluated: evaluated,
       covariance: covariance,
       covariance_inverse: covariance_inverse
     }}
  end

  defp decode_result({:error, reason}), do: {:error, reason}
end
