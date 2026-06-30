defmodule Sidereon.Lambert do
  @moduledoc """
  Lambert problem solver (Battin's method).

  Given two position vectors and time of flight, find the transfer orbit
  velocities. Algorithm 61, Vallado 2022, pp. 505-510.
  """

  @type vec3 :: {number(), number(), number()}

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

  `{v1t, v2t}` - transfer velocity vectors at r1 and r2 in km/s.
  """
  @spec solve(vec3(), vec3(), vec3(), integer(), integer(), non_neg_integer(), number()) ::
          {{float(), float(), float()}, {float(), float(), float()}}
  defdelegate solve(r1, r2, v1, dm, de, nrev, dtsec), to: Sidereon.NIF, as: :lambert_battin
end
