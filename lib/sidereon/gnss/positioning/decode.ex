defmodule Sidereon.GNSS.Positioning.Decode do
  @moduledoc false

  alias Sidereon.GNSS.Positioning.Solution

  def decode(
        {:ok,
         {position, rx_clock_s, geodetic, dop, residuals, used, rejected, metadata, system_clocks}}
      ) do
    {:ok,
     %Solution{
       position: position_map(position),
       geodetic: geodetic_map(geodetic),
       rx_clock_s: rx_clock_s,
       system_clocks_s: Map.new(system_clocks),
       dop: dop_map(dop),
       residuals_m: residuals,
       used_sats: used,
       rejected_sats: Enum.map(rejected, fn {sat, reason} -> {sat, reason} end),
       metadata: metadata_map(metadata)
     }}
  end

  def decode(error), do: map_solve_error(error)

  def map_solve_error({:error, :too_few_satellites, used, required}),
    do: {:error, {:too_few_satellites, used, required}}

  def map_solve_error({:error, :singular_geometry}), do: {:error, :singular_geometry}

  def map_solve_error({:error, :duplicate_observation, sat}),
    do: {:error, {:duplicate_observation, sat}}

  def map_solve_error({:error, :ephemeris_lost, sat}), do: {:error, {:ephemeris_lost, sat}}

  def map_solve_error({:error, :ionosphere_unsupported, sat}),
    do: {:error, {:ionosphere_unsupported, sat}}

  def map_solve_error({:error, reason}), do: {:error, reason}

  def map_solve_error(other), do: {:error, other}

  defp position_map({x, y, z}), do: %{x_m: x, y_m: y, z_m: z}

  defp geodetic_map(nil), do: nil
  defp geodetic_map({lat, lon, h}), do: %{lat_rad: lat, lon_rad: lon, height_m: h}

  defp dop_map(nil), do: nil

  defp dop_map({gdop, pdop, hdop, vdop, tdop}),
    do: %{gdop: gdop, pdop: pdop, hdop: hdop, vdop: vdop, tdop: tdop}

  defp metadata_map(
         {iterations, converged, status, iono, tropo, outer_iterations, final_robust_scale_m,
          used_count, systems, redundancy, raim_checkable?}
       ) do
    base = %{
      iterations: iterations,
      converged: converged,
      status: status,
      ionosphere_applied: iono,
      troposphere_applied: tropo,
      used_count: used_count,
      systems: systems,
      redundancy: redundancy,
      raim_checkable?: raim_checkable?
    }

    case final_robust_scale_m do
      nil -> base
      scale -> Map.put(base, :huber, %{outer_iterations: outer_iterations, final_scale_m: scale})
    end
  end
end
