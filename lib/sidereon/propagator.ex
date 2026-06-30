defmodule Sidereon.Propagator do
  @moduledoc """
  High-precision numerical orbit propagation.

  Supports high-order adaptive numerical integration (DP54)
  of orbital states using various force models via Rust NIF.
  """

  @type vec3 :: {float(), float(), float()}
  @type state :: {r :: vec3(), v :: vec3()}

  @doc """
  Adaptive step propagation using Dormand-Prince 5(4) via Rust NIF.
  Returns the state at exactly `t_end`.

  ## Options
    * `:tolerance` - Integration tolerance (default: 1.0e-12)
    * `:forces` - List of active force models: `["twobody", "j2"]` (default: `["twobody"]`)
  """
  @spec propagate(state(), float(), keyword()) :: {:ok, state()} | {:error, any()}
  def propagate({r, v}, dt, opts \\ []) do
    tol = Keyword.get(opts, :tolerance, 1.0e-12)
    forces = Keyword.get(opts, :forces, ["twobody"]) |> Enum.map(&to_string/1)

    Sidereon.NIF.propagate_dp54(r, v, dt * 1.0, forces, tol, tol)
  end
end
