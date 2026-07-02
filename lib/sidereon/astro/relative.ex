defmodule Sidereon.Astro.Relative do
  @moduledoc """
  RSW, RTN, RIC, LVLH relative frames and Clohessy-Wiltshire motion.
  """

  alias Sidereon.NIF

  defmodule State do
    @moduledoc """
    Cartesian state used by relative-frame and Clohessy-Wiltshire helpers.
    """
    @enforce_keys [:epoch_tdb_seconds, :position_km, :velocity_km_s]
    defstruct [:epoch_tdb_seconds, :position_km, :velocity_km_s]

    @type vec3 :: {float(), float(), float()}
    @type t :: %__MODULE__{
            epoch_tdb_seconds: float(),
            position_km: vec3(),
            velocity_km_s: vec3()
          }
  end

  @type frame :: :rsw | :rtn | :ric | :lvlh

  def rotation(frame, %State{} = chief) when frame in [:rsw, :rtn, :ric, :lvlh] do
    {:ok, NIF.relative_rotation(Atom.to_string(frame), state_map(chief))}
  rescue
    e in ErlangError -> {:error, e.original}
  end

  def relative_state(%State{} = chief, %State{} = deputy),
    do: call_state(:relative_state, [state_map(chief), state_map(deputy)])

  def absolute_from_relative(%State{} = chief, %State{} = rel),
    do: call_state(:relative_absolute_from_relative, [state_map(chief), state_map(rel)])

  def cw_stm(n, dt), do: {:ok, NIF.relative_cw_stm(n / 1.0, dt / 1.0)}
  def cw_propagate(%State{} = rel, n, dt), do: call_state(:relative_cw_propagate, [state_map(rel), n / 1.0, dt / 1.0])
  def mean_motion_circular(radius_km), do: {:ok, NIF.relative_mean_motion_circular(radius_km / 1.0)}
  def mean_motion_from_state(%State{} = chief), do: {:ok, NIF.relative_mean_motion_from_state(state_map(chief))}

  def rotation!(frame, chief), do: bang(rotation(frame, chief))
  def relative_state!(chief, deputy), do: bang(relative_state(chief, deputy))
  def absolute_from_relative!(chief, rel), do: bang(absolute_from_relative(chief, rel))
  def cw_stm!(n, dt), do: bang(cw_stm(n, dt))
  def cw_propagate!(rel, n, dt), do: bang(cw_propagate(rel, n, dt))
  def mean_motion_circular!(radius_km), do: bang(mean_motion_circular(radius_km))
  def mean_motion_from_state!(chief), do: bang(mean_motion_from_state(chief))

  defp call_state(fun, args) do
    case apply(NIF, fun, args) do
      {:ok, fields} -> {:ok, to_state(fields)}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  defp to_state(fields) do
    %State{
      epoch_tdb_seconds: fields.epoch_tdb_seconds,
      position_km: fields.position_km,
      velocity_km_s: fields.velocity_km_s
    }
  end

  defp state_map(%State{} = state), do: Map.from_struct(state)
  defp bang({:ok, value}), do: value
  defp bang({:error, reason}), do: raise(ArgumentError, "relative-frame calculation failed: #{inspect(reason)}")
end
