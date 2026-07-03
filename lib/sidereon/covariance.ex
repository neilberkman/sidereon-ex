defmodule Sidereon.Covariance do
  @moduledoc """
  Covariance matrix helpers for conjunction and orbit analysis.

  Supports covariance extraction, frame transforms, and validation checks such
  as positive semidefiniteness.

  The authoritative RTN->ECI frame transform and the symmetric
  positive-semidefinite validation live in the `sidereon-core` Rust core; this
  module marshals inputs, performs structural validation, and decodes results.
  """

  alias Sidereon.NIF

  @type mat3 :: [[float()]]
  @type mat6 :: [[float()]]
  @type vec3 :: {float(), float(), float()}
  @type state :: {number(), vec3(), vec3()}

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

  @doc """
  Build a 6x6 covariance matrix from six diagonal variances.
  """
  @spec from_diagonal6([number()]) :: {:ok, mat6()} | {:error, atom()}
  def from_diagonal6(diagonal) when is_list(diagonal) do
    NIF.covariance6_from_diagonal(Enum.map(diagonal, &(&1 / 1.0)))
  end

  @doc """
  Validate a 6x6 covariance matrix for symmetry and positive semidefiniteness.
  """
  @spec validate6(mat6()) :: {:ok, %{symmetric: boolean(), positive_semidefinite: boolean()}} | {:error, atom()}
  def validate6(matrix) when is_list(matrix) do
    NIF.covariance6_validate(to_rows(matrix))
  end

  @doc """
  Transform a 6x6 RTN state covariance to inertial ECI at `state`.
  """
  @spec rtn_to_eci6(mat6(), state()) :: {:ok, mat6()} | {:error, term()}
  def rtn_to_eci6(matrix, state) when is_list(matrix) do
    NIF.covariance6_rtn_to_eci(to_rows(matrix), state_term(state))
  end

  @doc """
  Transform a 6x6 inertial ECI state covariance to RTN at `state`.
  """
  @spec eci_to_rtn6(mat6(), state()) :: {:ok, mat6()} | {:error, term()}
  def eci_to_rtn6(matrix, state) when is_list(matrix) do
    NIF.covariance6_eci_to_rtn(to_rows(matrix), state_term(state))
  end

  @doc """
  Convert a 6x6 state covariance from kilometre units to metre units.
  """
  @spec km_to_m6(mat6()) :: {:ok, mat6()} | {:error, atom()}
  def km_to_m6(matrix) when is_list(matrix), do: NIF.covariance6_km_to_m(to_rows(matrix))

  @doc """
  Convert a 6x6 state covariance from metre units to kilometre units.
  """
  @spec m_to_km6(mat6()) :: {:ok, mat6()} | {:error, atom()}
  def m_to_km6(matrix) when is_list(matrix), do: NIF.covariance6_m_to_km(to_rows(matrix))

  @doc """
  PSD-preserving interpolation between two 6x6 covariance matrices.
  """
  @spec interpolate_psd6(mat6(), mat6(), number()) :: {:ok, mat6()} | {:error, atom()}
  def interpolate_psd6(a, b, u) when is_list(a) and is_list(b) do
    NIF.covariance6_interpolate_psd(to_rows(a), to_rows(b), u / 1.0)
  end

  @doc """
  Transport a 6x6 covariance through precomputed state-transition segments.
  """
  @spec transport_segments6(mat6(), [map()], keyword()) :: {:ok, [mat6()]} | {:error, term()}
  def transport_segments6(matrix, segments, opts \\ []) when is_list(matrix) and is_list(segments) do
    NIF.covariance6_transport_segments(to_rows(matrix), Enum.map(segments, &segment_term/1), transport_options(opts))
  end

  @doc """
  Parameter covariance `variance_scale * (J^T J)^-1` from a design (Jacobian)
  matrix.

  `jacobian` is an `m`-by-`n` matrix (a list of `m` rows of `n` numbers) with
  `m >= n`. The covariance is formed from the thin SVD of `J` directly, the same
  quantity (and construction) `scipy.optimize.curve_fit` reports as `pcov`: pass
  the post-fit reduced chi-square as `variance_scale` for the fitted covariance,
  or `1.0` for the bare `(J^T J)^-1` cofactor.

  Returns `{:ok, covariance_rows}` or `{:error, :singular_jacobian | :invalid_input}`.
  """
  @spec normal_covariance([[number()]], number()) :: {:ok, [[float()]]} | {:error, atom()}
  def normal_covariance(jacobian, variance_scale) when is_list(jacobian) do
    NIF.covariance_normal_covariance(to_rows(jacobian), variance_scale / 1.0)
  end

  @doc """
  Trace of the Gauss-Newton Hessian approximation `J^T J`, i.e. the sum of the
  squared column norms of `jacobian`. No inverse is formed.
  """
  @spec hessian_trace([[number()]]) :: float()
  def hessian_trace(jacobian) when is_list(jacobian) do
    NIF.covariance_hessian_trace(to_rows(jacobian))
  end

  @doc """
  Fitted parameter covariance directly from a converged solve's design matrix
  and cost.

  Scales `(J^T J)^-1` by the post-fit reduced chi-square `2 * cost / (m - n)`,
  the same scale `scipy.optimize.curve_fit` applies to its `pcov`. `jacobian` is
  the `m`-by-`n` design matrix and `cost` the optimum `0.5 * dot(r, r)`. The
  redundancy comes from the Jacobian's dimensions, so no residual or parameter
  vectors are needed. Requires positive redundancy `m > n`.

  Returns `{:ok, covariance_rows}` or `{:error, :singular_jacobian | :invalid_input}`.
  """
  @spec covariance_from_jacobian([[number()]], number()) ::
          {:ok, [[float()]]} | {:error, atom()}
  def covariance_from_jacobian(jacobian, cost) when is_list(jacobian) do
    NIF.covariance_from_jacobian(to_rows(jacobian), cost / 1.0)
  end

  @doc """
  Confidence ellipse from an arbitrary 2x2 covariance block.

  The semi-axes are scaled by the two-degree-of-freedom chi-square quantile
  `-2 ln(1 - confidence)` applied to the eigenvalues of the symmetrized block.
  Returns `{:ok, %{confidence:, chi_square_scale:, semi_major:, semi_minor:,
  orientation_rad:}}` or `{:error, reason}`.
  """
  @spec error_ellipse_2x2([[number()]], number()) ::
          {:ok,
           %{
             confidence: float(),
             chi_square_scale: float(),
             semi_major: float(),
             semi_minor: float(),
             orientation_rad: float()
           }}
          | {:error, atom()}
  def error_ellipse_2x2(covariance_2x2, confidence) when is_list(covariance_2x2) do
    case NIF.covariance_error_ellipse_2x2(to_rows(covariance_2x2), confidence / 1.0) do
      {:ok, {conf, chi_square_scale, semi_major, semi_minor, orientation_rad}} ->
        {:ok,
         %{
           confidence: conf,
           chi_square_scale: chi_square_scale,
           semi_major: semi_major,
           semi_minor: semi_minor,
           orientation_rad: orientation_rad
         }}

      {:error, _reason} = err ->
        err
    end
  end

  defp to_rows(rows), do: Enum.map(rows, &to_floats/1)
  defp to_floats(values), do: Enum.map(values, &(&1 / 1.0))

  defp state_term({epoch_tdb_seconds, position_km, velocity_km_s}) do
    {epoch_tdb_seconds / 1.0, vec3(position_km), vec3(velocity_km_s)}
  end

  defp vec3({x, y, z}), do: {x / 1.0, y / 1.0, z / 1.0}

  defp segment_term(%{stm: stm, dt_seconds: dt_seconds, q_rotation_state: state}) do
    %{
      stm: to_rows(stm),
      dt_seconds: dt_seconds / 1.0,
      q_rotation_state: state_term(state)
    }
  end

  defp transport_options(opts) do
    %{process_noise: process_noise(Keyword.get(opts, :process_noise, :none))}
  end

  defp process_noise(:none) do
    %{
      kind: "none",
      q_radial_km2_s3: nil,
      q_transverse_km2_s3: nil,
      q_normal_km2_s3: nil
    }
  end

  defp process_noise({:rtn_acceleration_psd, radial, transverse, normal}) do
    %{
      kind: "rtn_acceleration_psd",
      q_radial_km2_s3: radial / 1.0,
      q_transverse_km2_s3: transverse / 1.0,
      q_normal_km2_s3: normal / 1.0
    }
  end

  defp process_noise(%{kind: "rtn_acceleration_psd"} = noise), do: noise
  defp process_noise(%{kind: "none"} = noise), do: noise
end
