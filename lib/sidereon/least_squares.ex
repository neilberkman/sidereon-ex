defmodule Sidereon.LeastSquares do
  @moduledoc """
  Generic data-driven trust-region least squares.

  Pick a built-in residual kind (`:linear`, `:polynomial`, or `:exponential`),
  hand over the data arrays, and the whole trust-region iteration runs in Rust:
  the residual and Jacobian for every step are evaluated inside the
  `trust-region-least-squares` engine, so a fit pays one boundary crossing in and
  one out, never one per function evaluation. This mirrors SciPy's
  `least_squares(method="trf")` on its unbounded path.

  ## Residual kinds

    * `%{kind: :linear, a: rows, b: rhs}` - dense linear least squares, with `a`
      the `m`-by-`n` design matrix (a list of `m` rows of `n` numbers) and `b`
      the length-`m` right-hand side. Solves `min ||a x - b||`.
    * `%{kind: :polynomial, degree: d, t: ts, y: ys}` - polynomial fit of degree
      `d` (so `n = d + 1` coefficients, lowest-order first) over the `t`/`y`
      sample pairs.
    * `%{kind: :exponential, t: ts, y: ys}` - the three-parameter model
      `y = amp * exp(rate * t) + offset`, i.e. `x = [amp, rate, offset]`.

  ## Options

    * `:x0` - starting parameter vector. Defaults to zeros for `:linear` and
      `:polynomial`, and `[1.0, 0.0, 0.0]` for `:exponential`.
    * `:loss` - `:linear` (default), `:soft_l1`, `:huber`, `:cauchy`, `:arctan`.
    * `:f_scale` - robust-loss soft-margin scale (default `1.0`; only consulted
      for a robust loss).
    * `:x_scale` - `:unit` (default), `:jac`, or a list of positive per-parameter
      scales.
    * `:max_nfev` - residual-evaluation budget (default SciPy's `100 * n`).
    * `:ftol`, `:xtol`, `:gtol` - convergence tolerances (SciPy defaults
      `1.0e-8`, `1.0e-8`, `1.0e-10`).
    * `:backend` - `:native` (default, in-crate nalgebra SVD; works everywhere)
      or `:lapack` (host LAPACK/numpy BLAS for bit-for-bit SciPy parity, requires
      the `TRUST_REGION_LEAST_SQUARES_LAPACK_PATH` environment variable).

  ## Result

  `least_squares/2` returns `{:ok, %Sidereon.LeastSquares.Result{}}` or
  `{:error, reason}` where `reason` is a typed atom from the solver
  (`:insufficient_rows`, `:non_finite_parameters`, ...).
  `least_squares_drop_one/2` returns `{:ok,
  %Sidereon.LeastSquares.DropOneReport{}}`: the base solve over all rows plus one
  re-solve per masked residual row, with the per-row cost deltas (leave-one-out
  RAIM/FDE).
  """

  alias Sidereon.NIF

  defmodule Result do
    @moduledoc """
    A single converged trust-region solve.

    `jacobian` is the `m`-by-`n` Jacobian at the solution (a list of rows);
    `status` is the SciPy-compatible termination code (`1` gtol, `2` ftol,
    `3` xtol, `4` ftol and xtol, `0` max evaluations).
    """
    @enforce_keys [
      :x,
      :cost,
      :residuals,
      :jacobian,
      :grad,
      :optimality,
      :nfev,
      :njev,
      :status,
      :success
    ]
    defstruct [
      :x,
      :cost,
      :residuals,
      :jacobian,
      :grad,
      :optimality,
      :nfev,
      :njev,
      :status,
      :success
    ]

    @type t :: %__MODULE__{
            x: [float()],
            cost: float(),
            residuals: [float()],
            jacobian: [[float()]],
            grad: [float()],
            optimality: float(),
            nfev: non_neg_integer(),
            njev: non_neg_integer(),
            status: integer(),
            success: boolean()
          }
  end

  defmodule DropOneReport do
    @moduledoc """
    A leave-one-out sweep: the `base` solve over all rows, one `drops` solve per
    masked residual row (in row order), and `cost_delta` giving how much the
    optimum cost moves when each row is removed.
    """
    alias Sidereon.LeastSquares.Result

    @enforce_keys [:base, :drops, :cost_delta]
    defstruct [:base, :drops, :cost_delta]

    @type t :: %__MODULE__{
            base: Result.t(),
            drops: [Result.t()],
            cost_delta: [float()]
          }
  end

  @type spec ::
          %{required(:kind) => :linear, required(:a) => [[number()]], required(:b) => [number()]}
          | %{
              required(:kind) => :polynomial,
              required(:degree) => non_neg_integer(),
              required(:t) => [number()],
              required(:y) => [number()]
            }
          | %{required(:kind) => :exponential, required(:t) => [number()], required(:y) => [number()]}

  @doc """
  Solve a data-driven least-squares problem. See the module doc for the `spec`
  shapes and options.
  """
  @spec least_squares(spec(), keyword()) :: {:ok, Result.t()} | {:error, atom()}
  def least_squares(spec, opts \\ []) do
    with {:ok, args} <- build_args(spec, opts) do
      apply(NIF, :trls_solve, args) |> decode_solve()
    end
  end

  @doc """
  Leave-one-out (drop-one) sweep over the residual rows for RAIM/FDE. Same
  `spec`/options as `least_squares/2`.
  """
  @spec least_squares_drop_one(spec(), keyword()) :: {:ok, DropOneReport.t()} | {:error, atom()}
  def least_squares_drop_one(spec, opts \\ []) do
    with {:ok, args} <- build_args(spec, opts) do
      apply(NIF, :trls_solve_drop_one, args) |> decode_drop_one()
    end
  end

  # --- argument assembly ----------------------------------------------------

  defp build_args(spec, opts) do
    with {:ok, kind, a, b, m, n, t, y, degree, default_x0} <- residual_args(spec),
         {:ok, x_scale_kind, x_scale_values} <- x_scale(Keyword.get(opts, :x_scale, :unit)),
         {:ok, loss} <- loss(Keyword.get(opts, :loss, :linear)),
         {:ok, backend} <- backend(Keyword.get(opts, :backend, :native)) do
      x0 = opts |> Keyword.get(:x0, default_x0) |> to_floats()
      f_scale = opts |> Keyword.get(:f_scale, 1.0) |> to_float()
      ftol = opts |> Keyword.get(:ftol, 1.0e-8) |> to_float()
      xtol = opts |> Keyword.get(:xtol, 1.0e-8) |> to_float()
      gtol = opts |> Keyword.get(:gtol, 1.0e-10) |> to_float()
      max_nfev = max_nfev(Keyword.get(opts, :max_nfev))

      {:ok,
       [
         kind,
         a,
         b,
         m,
         n,
         t,
         y,
         degree,
         x0,
         loss,
         f_scale,
         x_scale_kind,
         x_scale_values,
         max_nfev,
         ftol,
         xtol,
         gtol,
         backend
       ]}
    end
  end

  defp residual_args(%{kind: :linear, a: a, b: b}) when is_list(a) and is_list(b) do
    m = length(b)
    n = if a == [], do: 0, else: length(hd(a))
    flat = a |> Enum.flat_map(& &1) |> to_floats()
    {:ok, "linear", flat, to_floats(b), m, n, [], [], 0, List.duplicate(0.0, n)}
  end

  defp residual_args(%{kind: :polynomial, degree: degree, t: t, y: y})
       when is_integer(degree) and degree >= 0 and is_list(t) and is_list(y) do
    {:ok, "polynomial", [], [], 0, 0, to_floats(t), to_floats(y), degree, List.duplicate(0.0, degree + 1)}
  end

  defp residual_args(%{kind: :exponential, t: t, y: y}) when is_list(t) and is_list(y) do
    {:ok, "exponential", [], [], 0, 0, to_floats(t), to_floats(y), 0, [1.0, 0.0, 0.0]}
  end

  defp residual_args(_spec), do: {:error, :invalid_spec}

  defp x_scale(:unit), do: {:ok, "unit", []}
  defp x_scale(:jac), do: {:ok, "jac", []}
  defp x_scale(values) when is_list(values), do: {:ok, "values", to_floats(values)}
  defp x_scale(_other), do: {:error, :invalid_x_scale}

  @losses [:linear, :soft_l1, :huber, :cauchy, :arctan]
  defp loss(loss) when loss in @losses, do: {:ok, Atom.to_string(loss)}
  defp loss(_other), do: {:error, :invalid_loss}

  defp backend(:native), do: {:ok, "native"}
  defp backend(:lapack), do: {:ok, "lapack"}
  defp backend(_other), do: {:error, :invalid_backend}

  # A negative budget tells the core to use the SciPy default (100 * n).
  defp max_nfev(nil), do: -1
  defp max_nfev(n) when is_integer(n), do: n

  defp to_floats(values), do: Enum.map(values, &to_float/1)
  defp to_float(value) when is_number(value), do: value / 1.0

  # --- result decoding ------------------------------------------------------

  defp decode_solve({:ok, result_tuple}), do: {:ok, to_result(result_tuple)}
  defp decode_solve({:error, _reason} = err), do: err

  defp decode_drop_one({:ok, {base, drops, cost_delta}}) do
    {:ok,
     %DropOneReport{
       base: to_result(base),
       drops: Enum.map(drops, &to_result/1),
       cost_delta: cost_delta
     }}
  end

  defp decode_drop_one({:error, _reason} = err), do: err

  defp to_result({{x, cost, fun, jac_flat, m, n}, {grad, optimality, nfev, njev, status, success}}) do
    %Result{
      x: x,
      cost: cost,
      residuals: fun,
      jacobian: reshape(jac_flat, m, n),
      grad: grad,
      optimality: optimality,
      nfev: nfev,
      njev: njev,
      status: status,
      success: success
    }
  end

  defp reshape(_flat, 0, _n), do: []
  defp reshape(_flat, _m, 0), do: []
  defp reshape(flat, _m, n), do: Enum.chunk_every(flat, n)
end
