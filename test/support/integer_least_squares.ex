defmodule Sidereon.TestSupport.IntegerLeastSquares do
  @moduledoc false

  alias Sidereon.NIF

  @doc """
  Integer least squares via the LAMBDA method (RTKLIB `lambda()` port).

  The production ambiguity-resolution solver: LtDL factorization + integer-Gauss
  /permutation decorrelation reduction + modified-LAMBDA search. Correct for any
  positive-definite covariance — it finds the true ILS optimum even on
  strongly-correlated geometry, with no search box and no combinatorial blow-up.
  Gated against RTKLIB's own reference vectors in the Rust crate.

  `opts` only needs `:ratio_threshold`; `:radius_cycles`/`:candidate_limit` (used
  by `bounded_search/3`) are accepted and ignored.
  """
  @spec search(%{String.t() => number()}, [[number()]], map()) ::
          {:ok, %{String.t() => integer()}, map()} | {:error, term()}
  def search(float_cycles_by_id, covariance_cycles, opts)
      when is_map(float_cycles_by_id) and is_list(covariance_cycles) do
    ids = float_cycles_by_id |> Map.keys() |> Enum.sort()
    floats = Enum.map(ids, &Map.fetch!(float_cycles_by_id, &1))

    with :ok <- validate_inputs(floats, covariance_cycles) do
      NIF.ils_lambda_search(floats, covariance_cycles, opts.ratio_threshold)
      |> build_result(ids, float_cycles_by_id, :lambda)
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Bounded ±radius box integer search (the Rust `bounded_ils_search` kernel).

  Enumerates the lattice within `:radius_cycles` of each rounded float ambiguity,
  scoring `Δᵀ Q⁻¹ Δ`. Correct ONLY when the ILS optimum lies within that box
  (weakly-correlated geometry); on strongly-correlated covariance it returns a
  suboptimal fix — use `search/3` (LAMBDA) for the general case. Kept as a fast
  in-regime alternative and as the documented box reference. Honors
  `:radius_cycles`, `:candidate_limit`, and `:ratio_threshold`.
  """
  @spec bounded_search(%{String.t() => number()}, [[number()]], map()) ::
          {:ok, %{String.t() => integer()}, map()} | {:error, term()}
  def bounded_search(float_cycles_by_id, covariance_cycles, opts)
      when is_map(float_cycles_by_id) and is_list(covariance_cycles) do
    ids = float_cycles_by_id |> Map.keys() |> Enum.sort()
    floats = Enum.map(ids, &Map.fetch!(float_cycles_by_id, &1))

    with :ok <- validate_inputs(floats, covariance_cycles) do
      NIF.ils_search(
        floats,
        covariance_cycles,
        opts.radius_cycles,
        opts.candidate_limit,
        opts.ratio_threshold
      )
      |> build_result(ids, float_cycles_by_id, :bounded_ils)
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  # Reject malformed dimensions BEFORE the NIF: an undersized covariance would
  # index out of bounds (NIF panic) and an oversized one would be silently
  # truncated to a wrong-dimension submatrix. Mirrors the Rust kernel's
  # `validate_inputs` shape check, and also guards sidereon against any published
  # NIF that predates that guard. (Non-finite values are checked in the Rust
  # kernel; the BEAM cannot represent NaN/Inf float terms, so they cannot arrive
  # here from Elixir.)
  defp validate_inputs(floats, covariance) do
    n = length(floats)
    bad_row = Enum.find(covariance, fn row -> not is_list(row) or length(row) != n end)
    bad_row_width = if is_list(bad_row), do: length(bad_row), else: :non_list

    cond do
      n == 0 -> {:error, {:invalid_dimensions, 0, 0}}
      length(covariance) != n -> {:error, {:invalid_dimensions, n, length(covariance)}}
      bad_row -> {:error, {:invalid_dimensions, n, bad_row_width}}
      true -> :ok
    end
  end

  # Shared decode of the NIF result tuple into the public fixed-cycles + metadata
  # shape (both the bounded-box and LAMBDA kernels return the same shape).
  defp build_result(nif_result, ids, float_cycles_by_id, method) do
    case nif_result do
      {:ok, {fixed_list, status?, ratio, best, second, evaluated, {q_cycles, q_inv}}} ->
        fixed_cycles = ids |> Enum.zip(fixed_list) |> Map.new()

        {:ok, fixed_cycles,
         %{
           integer_status: if(status?, do: :fixed, else: :not_fixed),
           integer_method: method,
           integer_ratio: ratio,
           integer_best_score: best,
           integer_second_best_score: second,
           integer_candidates: evaluated,
           ambiguity_search: %{
             order: ids,
             float_cycles: float_cycles_by_id,
             covariance_cycles: q_cycles,
             covariance_inverse_cycles: q_inv
           }
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
