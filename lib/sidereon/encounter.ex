defmodule Sidereon.Encounter do
  @moduledoc """
  Encounter geometry helpers for conjunction assessment.

  This module builds the relative frame used by collision-probability
  calculations and projects states and covariance into the encounter plane.

  It is the geometry layer beneath `Sidereon.Collision`.

  The encounter-frame construction and covariance projection are implemented in
  the `astrodynamics` core; this module marshals inputs across the NIF and
  rebuilds the public `%Sidereon.Encounter.Frame{}` shape.
  """

  alias Sidereon.Encounter.Frame
  alias Sidereon.NIF

  @type vec3 :: {float(), float(), float()}

  @doc """
  Build an orthonormal encounter frame from two objects' states.

  Returns `{:ok, %Frame{}}` or `{:error, reason}`.
  """
  @spec frame(vec3(), vec3(), vec3(), vec3()) :: {:ok, Frame.t()} | {:error, String.t()}
  def frame(r1, v1, r2, v2) do
    case NIF.encounter_frame(r1, v1, r2, v2) do
      {:ok, {x_hat, y_hat, z_hat, dr, dv, miss_km, relative_speed_km_s}} ->
        {:ok,
         %Frame{
           x_hat: x_hat,
           y_hat: y_hat,
           z_hat: z_hat,
           relative_position_km: dr,
           relative_velocity_km_s: dv,
           miss_km: miss_km,
           relative_speed_km_s: relative_speed_km_s
         }}

      {:error, reason} ->
        {:error, conjunction_reason(reason)}
    end
  end

  # The core returns the zero-relative-velocity case as the `:undefined_frame`
  # atom; surface it as this module's documented string reason.
  defp conjunction_reason(:undefined_frame), do: "zero relative velocity"
  defp conjunction_reason(reason), do: reason

  @doc """
  Project a 3x3 ECI covariance matrix into the 2D encounter plane (x, z).
  """
  @spec encounter_plane_covariance(Frame.t(), [[float()]]) :: [[float()]]
  def encounter_plane_covariance(%Frame{x_hat: x_hat, z_hat: z_hat}, cov_eci_3x3) do
    NIF.encounter_plane_covariance(x_hat, z_hat, cov_eci_3x3)
  end
end
