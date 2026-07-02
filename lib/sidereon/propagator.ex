defmodule Sidereon.Propagator do
  @moduledoc """
  High-precision numerical orbit propagation.

  Supports high-order adaptive numerical integration (DP54)
  of orbital states using various force models via Rust NIF.
  """

  alias Sidereon.Drag.Parameters

  @type vec3 :: {float(), float(), float()}
  @type state :: {r :: vec3(), v :: vec3()}

  @doc """
  Adaptive step propagation using Dormand-Prince 5(4) via Rust NIF.
  Returns the state at exactly `t_end`.

  ## Options
    * `:tolerance` - Integration tolerance (default: 1.0e-12)
    * `:forces` - List of active force models: `["twobody", "j2"]` (default: `["twobody"]`)
    * `:drag` - optional `%Sidereon.Drag.Parameters{}` drag model
  """
  @spec propagate(state(), float(), keyword()) :: {:ok, state()} | {:error, any()}
  def propagate({r, v}, dt, opts \\ []) do
    tol = Keyword.get(opts, :tolerance, 1.0e-12)
    forces = Keyword.get(opts, :forces, ["twobody"]) |> Enum.map(&to_string/1)

    case Keyword.get(opts, :drag) do
      nil ->
        Sidereon.NIF.propagate_dp54(r, v, dt * 1.0, forces, tol, tol)

      %Parameters{} = drag ->
        Sidereon.NIF.propagate_dp54_with_drag(r, v, dt * 1.0, forces, tol, tol, drag_map(drag))
    end
  end

  defp drag_map(%Parameters{} = drag) do
    %{
      bc_factor_m2_kg: drag.bc_factor_m2_kg,
      f107: drag.space_weather.f107,
      f107a: drag.space_weather.f107a,
      ap: drag.space_weather.ap,
      cutoff_altitude_km: drag.cutoff_altitude_km
    }
  end
end
