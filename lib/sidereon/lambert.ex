defmodule Sidereon.Lambert do
  @moduledoc """
  Lambert problem solver (Battin's method).

  Given two position vectors and time of flight, find the transfer orbit
  velocities. Algorithm 61, Vallado 2022, pp. 505-510.
  """

  @type vec3 :: {number(), number(), number()}
  @type error_reason ::
          :no_convergence
          | :zero_vector
          | :non_positive_time_of_flight
          | :degenerate_geometry
          | :non_finite_value
  @type error :: {:error, {error_reason(), String.t()}}

  @doc """
  Solve Lambert's problem using Battin's method.

  ## Parameters

    * `r1`, `r2` - initial and final ECI position vectors in km
    * `v1` - initial velocity in km/s (needed for 180° transfers)
    * `dm` - direction of motion: `0` = short way, `1` = long way
    * `de` - direction of energy: `0` = low, `1` = high
    * `nrev` - number of revolutions (0, 1, 2, ...)
    * `dtsec` - time of flight in seconds

  ## Returns

  Returns `{v1t, v2t}` with the transfer velocity vectors at r1 and r2 in
  km/s, or `{:error, {reason, message}}` when no valid transfer exists.
  """
  @spec solve(vec3(), vec3(), vec3(), integer(), integer(), non_neg_integer(), number()) ::
          {{float(), float(), float()}, {float(), float(), float()}} | error()
  defdelegate solve(r1, r2, v1, dm, de, nrev, dtsec), to: Sidereon.NIF, as: :lambert_battin
end
