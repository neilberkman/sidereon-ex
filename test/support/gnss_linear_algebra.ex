defmodule Sidereon.TestSupport.LinearAlgebra do
  @moduledoc false

  @pivot_epsilon 1.0e-12

  @spec solve_normal_equations([map()], pos_integer()) :: {:ok, [float()]} | {:error, term()}
  def solve_normal_equations(rows, n) do
    {ata, aty} = normal_equations(rows, n)
    solve_linear(ata, aty)
  end

  @spec normal_equations([map()], pos_integer()) :: {[[float()]], [float()]}
  def normal_equations(rows, n) do
    Enum.reduce(rows, {zero_matrix(n), zero_vector(n)}, fn row, {ata, aty} ->
      h = Enum.map(row.h, &(&1 * row.weight))
      y = row.y * row.weight
      {accumulate_ata(ata, h), accumulate_aty(aty, h, y)}
    end)
  end

  @spec correlated_normal_equations([map()], pos_integer()) :: {[[float()]], [float()]}
  def correlated_normal_equations(blocks, n) do
    Enum.reduce(blocks, {zero_matrix(n), zero_vector(n)}, fn block, {ata, aty} ->
      {block_ata, block_aty} =
        block_normal_equations(block.rows, block.inverse_covariance, n)

      {matrix_add(ata, block_ata), vector_add(aty, block_aty)}
    end)
  end

  @spec solve_linear([[float()]], [float()]) :: {:ok, [float()]} | {:error, :singular_geometry}
  def solve_linear(a, b) do
    augmented = Enum.zip_with(a, b, fn row, bi -> row ++ [bi] end)

    case eliminate(augmented, 0, length(b)) do
      :singular -> {:error, :singular_geometry}
      upper -> {:ok, back_substitute(upper)}
    end
  end

  @spec invert_matrix([[float()]]) :: {:ok, [[float()]]} | {:error, term()}
  def invert_matrix(a) do
    n = length(a)

    0..(n - 1)
    |> Enum.reduce_while({:ok, []}, fn col, {:ok, columns} ->
      case solve_linear(a, unit_vector(n, col)) do
        {:ok, solution} -> {:cont, {:ok, [solution | columns]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, columns} -> {:ok, columns |> Enum.reverse() |> transpose()}
      {:error, _} = err -> err
    end
  end

  @spec solve_matrix([[float()]], [[float()]]) :: {:ok, [[float()]]} | {:error, term()}
  def solve_matrix(a, b) do
    columns = transpose(b)

    columns
    |> Enum.reduce_while({:ok, []}, fn col, {:ok, acc} ->
      case solve_linear(a, col) do
        {:ok, solution} -> {:cont, {:ok, [solution | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, solved_columns} -> {:ok, solved_columns |> Enum.reverse() |> transpose()}
      {:error, _} = err -> err
    end
  end

  @spec submatrix(
          [[number()]],
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) ::
          [[number()]]
  def submatrix(matrix, row_start, row_count, col_start, col_count) do
    matrix
    |> Enum.slice(row_start, row_count)
    |> Enum.map(&Enum.slice(&1, col_start, col_count))
  end

  @spec zero_matrix(non_neg_integer()) :: [[float()]]
  def zero_matrix(n), do: for(_ <- 1..n, do: zero_vector(n))

  @spec zero_vector(non_neg_integer()) :: [float()]
  def zero_vector(n), do: for(_ <- 1..n, do: 0.0)

  @spec identity_matrix(non_neg_integer()) :: [[float()]]
  def identity_matrix(n) do
    for i <- 0..(n - 1) do
      for j <- 0..(n - 1), do: if(i == j, do: 1.0, else: 0.0)
    end
  end

  @spec matrix_add([[number()]], [[number()]]) :: [[number()]]
  def matrix_add(a, b) do
    a
    |> Enum.zip(b)
    |> Enum.map(fn {row_a, row_b} -> vector_add(row_a, row_b) end)
  end

  @spec matrix_sub([[number()]], [[number()]]) :: [[number()]]
  def matrix_sub(a, b) do
    a
    |> Enum.zip(b)
    |> Enum.map(fn {row_a, row_b} ->
      row_a
      |> Enum.zip(row_b)
      |> Enum.map(fn {x, y} -> x - y end)
    end)
  end

  @spec matvec([[number()]], [number()]) :: [number()]
  def matvec(matrix, vector) do
    Enum.map(matrix, fn row ->
      row
      |> Enum.zip(vector)
      |> Enum.reduce(0.0, fn {a, b}, acc -> acc + a * b end)
    end)
  end

  @spec matvec_transpose([[number()]], [number()]) :: [number()]
  def matvec_transpose(matrix, vector) do
    matrix
    |> transpose()
    |> matvec(vector)
  end

  @spec matmul([[number()]], [[number()]]) :: [[number()]]
  def matmul(a, b) do
    b_t = transpose(b)

    Enum.map(a, fn row ->
      Enum.map(b_t, fn col ->
        row
        |> Enum.zip(col)
        |> Enum.reduce(0.0, fn {x, y}, acc -> acc + x * y end)
      end)
    end)
  end

  @spec transpose([[number()]]) :: [[number()]]
  def transpose(matrix) do
    matrix
    |> Enum.zip()
    |> Enum.map(&Tuple.to_list/1)
  end

  @spec unit_vector(pos_integer(), non_neg_integer()) :: [float()]
  def unit_vector(n, col) do
    for idx <- 0..(n - 1), do: if(idx == col, do: 1.0, else: 0.0)
  end

  defp block_normal_equations(rows, inverse_covariance, n) do
    r_inv_y = matvec(inverse_covariance, Enum.map(rows, & &1.y))

    ata =
      for i <- 0..(n - 1) do
        for j <- 0..(n - 1) do
          rows
          |> Enum.with_index()
          |> Enum.reduce(0.0, fn {row_a, a}, acc ->
            hi = Enum.at(row_a.h, i)

            row_sum =
              rows
              |> Enum.with_index()
              |> Enum.reduce(0.0, fn {row_b, b}, inner ->
                inner + (inverse_covariance |> Enum.at(a) |> Enum.at(b)) * Enum.at(row_b.h, j)
              end)

            acc + hi * row_sum
          end)
        end
      end

    aty =
      for i <- 0..(n - 1) do
        rows
        |> Enum.with_index()
        |> Enum.reduce(0.0, fn {row, idx}, acc ->
          acc + Enum.at(row.h, i) * Enum.at(r_inv_y, idx)
        end)
      end

    {ata, aty}
  end

  defp accumulate_ata(ata, h) do
    Enum.with_index(ata)
    |> Enum.map(fn {row, i} ->
      hi = Enum.at(h, i)

      row
      |> Enum.with_index()
      |> Enum.map(fn {aij, j} -> aij + hi * Enum.at(h, j) end)
    end)
  end

  defp accumulate_aty(aty, h, y) do
    aty
    |> Enum.zip(h)
    |> Enum.map(fn {acc, hi} -> acc + hi * y end)
  end

  defp vector_add(a, b) do
    a
    |> Enum.zip(b)
    |> Enum.map(fn {x, y} -> x + y end)
  end

  defp eliminate(rows, col, n) when col >= n, do: rows

  defp eliminate(rows, col, n) do
    {pivot_row, pivot_abs} =
      rows
      |> Enum.with_index()
      |> Enum.drop(col)
      |> Enum.map(fn {row, idx} -> {idx, abs(Enum.at(row, col))} end)
      |> Enum.max_by(fn {_idx, value} -> value end)

    if pivot_abs <= @pivot_epsilon do
      :singular
    else
      rows = swap_rows(rows, col, pivot_row)
      pivot = Enum.at(rows, col)
      pivot_value = Enum.at(pivot, col)

      rows =
        rows
        |> Enum.with_index()
        |> Enum.map(fn {row, idx} ->
          if idx <= col do
            row
          else
            factor = Enum.at(row, col) / pivot_value

            row
            |> Enum.zip(pivot)
            |> Enum.map(fn {rij, pij} -> rij - factor * pij end)
          end
        end)

      eliminate(rows, col + 1, n)
    end
  end

  defp swap_rows(rows, i, i), do: rows

  defp swap_rows(rows, i, j) do
    ri = Enum.at(rows, i)
    rj = Enum.at(rows, j)

    rows
    |> List.replace_at(i, rj)
    |> List.replace_at(j, ri)
  end

  defp back_substitute(rows) do
    n = length(rows)

    solved =
      (n - 1)..0//-1
      |> Enum.reduce(%{}, fn i, solved ->
        row = Enum.at(rows, i)

        known =
          if i == n - 1 do
            0.0
          else
            Enum.reduce((i + 1)..(n - 1), 0.0, fn j, acc ->
              acc + Enum.at(row, j) * Map.fetch!(solved, j)
            end)
          end

        xi = (Enum.at(row, n) - known) / Enum.at(row, i)
        Map.put(solved, i, xi)
      end)

    Enum.map(0..(n - 1), &Map.fetch!(solved, &1))
  end
end
