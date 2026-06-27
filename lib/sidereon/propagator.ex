defmodule Sidereon.Propagator do
  @moduledoc """
  High-precision numerical orbit propagation.

  Supports high-order adaptive numerical integration (DP54)
  of orbital states using various force models via Rust NIF.
  """

  @type vec3 :: {float(), float(), float()}
  @type state :: {r :: vec3(), v :: vec3()}
  @type force_model :: (vec3(), vec3() -> vec3())

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

  @doc """
  Legacy RK4 fixed-step implementation in pure Elixir.
  Maintained for baselines.
  """
  @spec propagate_rk4(state(), float(), [force_model()]) :: state()
  def propagate_rk4({r, v}, dt, force_funs) do
    k1 = derivatives({r, v}, force_funs)
    s2 = add_step({r, v}, k1, dt * 0.5)
    k2 = derivatives(s2, force_funs)
    s3 = add_step({r, v}, k2, dt * 0.5)
    k3 = derivatives(s3, force_funs)
    s4 = add_step({r, v}, k3, dt)
    k4 = derivatives(s4, force_funs)

    {r1, v1} = k1
    {r2, v2} = k2
    {r3, v3} = k3
    {r4, v4} = k4

    rf =
      vec_add(r, vec_scale(vec_sum([r1, vec_scale(r2, 2.0), vec_scale(r3, 2.0), r4]), dt / 6.0))

    vf =
      vec_add(v, vec_scale(vec_sum([v1, vec_scale(v2, 2.0), vec_scale(v3, 2.0), v4]), dt / 6.0))

    {rf, vf}
  end

  defp derivatives({r, v}, forces) do
    accel =
      Enum.reduce(forces, {0.0, 0.0, 0.0}, fn f, acc ->
        a = f.(r, v)
        vec_add(acc, a)
      end)

    {v, accel}
  end

  defp add_step({r, v}, {dr, dv}, dt) do
    {vec_add(r, vec_scale(dr, dt)), vec_add(v, vec_scale(dv, dt))}
  end

  defp vec_add({x1, y1, z1}, {x2, y2, z2}), do: {x1 + x2, y1 + y2, z1 + z2}
  defp vec_scale({x, y, z}, s), do: {x * s, y * s, z * s}
  defp vec_sum(vecs), do: Enum.reduce(vecs, {0.0, 0.0, 0.0}, &vec_add/2)
end
