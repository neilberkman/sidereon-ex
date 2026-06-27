defmodule Sidereon.Covariance do
  @moduledoc """
  Covariance matrix helpers for conjunction and orbit analysis.

  Supports covariance extraction, frame transforms, scaling, combination,
  and validation checks such as positive semidefiniteness.

  The authoritative RTN->ECI frame transform and the symmetric
  positive-semidefinite validation live in the `astrodynamics` Rust core; this
  module marshals inputs, performs structural validation, and decodes results.
  """

  alias Sidereon.NIF

  @type mat3 :: [[float()]]
  @type vec3 :: {float(), float(), float()}

  @doc """
  Add two 3x3 matrices.
  """
  @spec add(mat3(), mat3()) :: mat3()
  def add(a, b) do
    for {ra, rb} <- Enum.zip(a, b),
        do: for({va, vb} <- Enum.zip(ra, rb), do: va + vb)
  end

  @doc """
  Transpose a 3x3 matrix.
  """
  @spec transpose(mat3()) :: mat3()
  def transpose(m), do: m |> Enum.zip() |> Enum.map(&Tuple.to_list/1)

  @doc """
  Matrix multiplication (3x3).
  """
  @spec mat_mul(mat3(), mat3()) :: mat3()
  def mat_mul(a, b) do
    bt = transpose(b)

    for row <- a,
        do:
          for(col <- bt, do: Enum.zip(row, col) |> Enum.map(fn {x, y} -> x * y end) |> Enum.sum())
  end

  @doc """
  Scale a matrix by a scalar.
  """
  @spec scale(mat3(), float()) :: mat3()
  def scale(m, s), do: for(row <- m, do: for(v <- row, do: v * s))

  @doc """
  Transform a 3x3 RTN covariance matrix to ECI.
  """
  @spec rtn_to_eci(mat3(), vec3(), vec3()) :: {:ok, mat3()} | {:error, String.t()}
  def rtn_to_eci(cov_rtn, r, v) do
    if valid_matrix?(cov_rtn) do
      NIF.covariance_rtn_to_eci(cov_rtn, r, v)
    else
      {:error, "invalid covariance matrix: must be a 3x3 numeric matrix"}
    end
  end

  @doc """
  Extract a 3x3 position covariance matrix from a 6-element lower triangle (RTN).
  Expected order: CR_R (0,0), CT_R (1,0), CT_T (1,1), CN_R (2,0), CN_T (2,1), CN_N (2,2).
  """
  @spec extract_pos_cov([float()]) :: {:ok, mat3()} | {:error, String.t()}
  def extract_pos_cov([cr_r, ct_r, ct_t, cn_r, cn_t, cn_n | _]) do
    res = [
      [cr_r, ct_r, cn_r],
      [ct_r, ct_t, cn_t],
      [cn_r, cn_t, cn_n]
    ]

    if Enum.all?(List.flatten(res), &is_number/1) do
      {:ok, res}
    else
      {:error, "non-numeric values in covariance list"}
    end
  end

  def extract_pos_cov(_), do: {:error, "invalid covariance list length"}

  @doc """
  Validate that the input is a 3x3 numeric matrix.
  """
  @spec valid_matrix?(any()) :: boolean()
  def valid_matrix?(m) when is_list(m) and length(m) == 3 do
    Enum.all?(m, fn row ->
      is_list(row) and length(row) == 3 and Enum.all?(row, &is_number/1)
    end)
  end

  def valid_matrix?(_), do: false

  @doc """
  Check if a 3x3 matrix is symmetric and positive semidefinite (PSD).

  A symmetric 3x3 matrix is PSD if all its principal minors are non-negative.
  """
  @spec positive_semidefinite?(mat3()) :: boolean()
  def positive_semidefinite?(m) do
    valid_matrix?(m) and NIF.covariance_positive_semidefinite(m)
  end

  @doc """
  Check if a matrix is symmetric.
  """
  @spec symmetric?(any()) :: boolean()
  def symmetric?(m) do
    valid_matrix?(m) and NIF.covariance_symmetric(m)
  end
end
