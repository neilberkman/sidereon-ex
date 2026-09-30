defmodule Sidereon.IOD do
  @moduledoc """
  Initial Orbit Determination methods.

  Given observations (position vectors, angles, or times), determine
  the orbit of a satellite.
  """

  @type vec3 :: {number(), number(), number()}
  @type iod_error_kind ::
          :determinant_too_small
          | :orbit_not_possible
          | :zero_vector
          | :collinear_vectors
          | :not_coplanar
          | :invalid_time_geometry
          | :no_positive_root
          | :root_solve_failed
          | :non_finite_value
  @type iod_error :: {:error, {:iod_error, iod_error_kind(), String.t()}}

  @doc """
  Gibbs method: determine velocity at r2 from three coplanar position vectors.

  Algorithm 54, Vallado 2022, pp. 460-467.

  ## Parameters

    * `r1`, `r2`, `r3` - ECI position vectors in km as `{x, y, z}` tuples

  ## Returns

  `{v2, theta12, theta23, copa}` where:
    * `v2` - velocity at r2 in km/s
    * `theta12`, `theta23` - angles between position vectors in radians
    * `copa` - coplanarity angle in radians
  """
  @spec gibbs(vec3(), vec3(), vec3()) ::
          {{float(), float(), float()}, float(), float(), float()} | iod_error()
  def gibbs(r1, r2, r3), do: unwrap_result(Sidereon.NIF.iod_gibbs(r1, r2, r3))

  @doc """
  Herrick-Gibbs method: determine velocity at r2 from three closely-spaced
  position vectors with timestamps.

  Algorithm 55, Vallado 2022, pp. 467-472.

  ## Parameters

    * `r1`, `r2`, `r3` - ECI position vectors in km
    * `jd1`, `jd2`, `jd3` - Julian day fractions (only differences matter)
  """
  @spec hgibbs(vec3(), vec3(), vec3(), number(), number(), number()) ::
          {{float(), float(), float()}, float(), float(), float()} | iod_error()
  def hgibbs(r1, r2, r3, jd1, jd2, jd3), do: unwrap_result(Sidereon.NIF.iod_hgibbs(r1, r2, r3, jd1, jd2, jd3))

  @doc """
  Gauss angles-only IOD: determine orbit from three angular observations.

  Algorithm 52, Vallado 2022, pp. 448-459.

  ## Parameters

    * `decl1..3` - declinations in radians
    * `rtasc1..3` - right ascensions in radians
    * `jd1..3`, `jdf1..3` - Julian dates (whole + fraction)
    * `site1..3` - ECI site position vectors in km as `{x, y, z}` tuples

  ## Returns

  `{r2, v2}` - position and velocity at the middle observation.
  """
  @spec gauss(
          number(),
          number(),
          number(),
          number(),
          number(),
          number(),
          number(),
          number(),
          number(),
          number(),
          number(),
          number(),
          vec3(),
          vec3(),
          vec3()
        ) :: {{float(), float(), float()}, {float(), float(), float()}} | iod_error()
  def gauss(d1, d2, d3, ra1, ra2, ra3, jd1, jdf1, jd2, jdf2, jd3, jdf3, s1, s2, s3) do
    unwrap_result(Sidereon.NIF.iod_gauss(d1, d2, d3, ra1, ra2, ra3, jd1, jdf1, jd2, jdf2, jd3, jdf3, s1, s2, s3))
  end

  defp unwrap_result({:ok, value}), do: value
  defp unwrap_result({:error, _reason} = error), do: error
end
