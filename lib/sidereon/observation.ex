defmodule Sidereon.Observation do
  @moduledoc """
  Observational-astronomy geometry primitives.

  Small, side-effect-free geometry helpers used when reducing or planning ground-
  and space-based observations: the sub-solar point, the day-night terminator, the
  parallactic angle, a diffuse-sphere visual-magnitude phase law, and the
  sub-observer (central-meridian) point on a rotating body. Each function is a
  pure delegation to the `sidereon-core` `astro::observation` kernels.

  ## Units at the boundary

  Angles are in degrees and vectors are `{x, y, z}` tuples in the frame the
  function documents. Latitudes are geocentric and returned in degrees on
  `[-90, 90]`; longitudes on `(-180, 180]`.
  """

  alias Sidereon.NIF

  @type vec3 :: {number(), number(), number()}
  @type surface_point :: %{latitude_deg: float(), longitude_deg: float()}

  @doc """
  Sub-solar point: the geographic point where the Sun is at the zenith.

  `sun_ecef` is the geocentric Sun position in an Earth-fixed (ITRS/ECEF) frame
  in any length unit (only its direction matters). Returns
  `{:ok, %{latitude_deg: lat, longitude_deg: lon}}` or `{:error, reason}` for a
  zero or non-finite vector.
  """
  @spec sub_solar_point(vec3()) :: {:ok, surface_point()} | {:error, term()}
  def sub_solar_point(sun_ecef) do
    case NIF.observation_sub_solar_point(floats3(sun_ecef)) do
      {:error, reason} -> {:error, reason}
      {lat, lon} -> {:ok, %{latitude_deg: lat, longitude_deg: lon}}
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Latitude (degrees) of the day-night terminator at a query longitude.

  `sub_solar` is the sub-solar point as `%{latitude_deg: _, longitude_deg: _}` (or
  a `{lat, lon}` tuple); `longitude_deg` is the query meridian. Returns
  `{:ok, latitude_deg}` or `{:error, reason}`.
  """
  @spec terminator_latitude_deg(surface_point() | {number(), number()}, number()) ::
          {:ok, float()} | {:error, term()}
  def terminator_latitude_deg(sub_solar, longitude_deg) do
    {sub_lat, sub_lon} = surface_point_fields(sub_solar)

    wrap_scalar(NIF.observation_terminator_latitude_deg(sub_lat / 1.0, sub_lon / 1.0, longitude_deg / 1.0))
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Parallactic angle (degrees) of a target at a station.

  `observer_latitude_deg` is the observer geodetic latitude, `hour_angle_deg` the
  local hour angle (positive west of the meridian), and `declination_deg` the
  target declination. The result is on `(-180, 180]`: `0` on the meridian,
  positive west of it. Returns `{:ok, angle_deg}` or `{:error, reason}`.
  """
  @spec parallactic_angle_deg(number(), number(), number()) ::
          {:ok, float()} | {:error, term()}
  def parallactic_angle_deg(observer_latitude_deg, hour_angle_deg, declination_deg) do
    wrap_scalar(
      NIF.observation_parallactic_angle_deg(
        observer_latitude_deg / 1.0,
        hour_angle_deg / 1.0,
        declination_deg / 1.0
      )
    )
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Apparent visual magnitude of a sunlit body from a diffuse-sphere phase law.

  `standard_magnitude` is the body's brightness at `reference_range_km` and zero
  phase; `range_km` is the observer range and `phase_angle_deg` the solar phase
  angle (clamped to `[0, 180]`). Returns `{:ok, magnitude}` or `{:error, reason}`.
  """
  @spec satellite_visual_magnitude(number(), number(), number(), number()) ::
          {:ok, float()} | {:error, term()}
  def satellite_visual_magnitude(range_km, phase_angle_deg, standard_magnitude, reference_range_km) do
    wrap_scalar(
      NIF.observation_satellite_visual_magnitude(
        range_km / 1.0,
        phase_angle_deg / 1.0,
        standard_magnitude / 1.0,
        reference_range_km / 1.0
      )
    )
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Sub-observer point (planetary central meridian) on a rotating body.

  `observer_from_body` is the observer position relative to the body center in an
  inertial (ICRF/J2000 equatorial) frame; `pole_ra_deg`/`pole_dec_deg` are the
  body's IAU pole and `prime_meridian_deg` its prime-meridian angle `W`. Returns
  `{:ok, %{latitude_deg: lat, longitude_deg: lon}}` (planetocentric) or
  `{:error, reason}`.
  """
  @spec sub_observer_point(vec3(), number(), number(), number()) ::
          {:ok, surface_point()} | {:error, term()}
  def sub_observer_point(observer_from_body, pole_ra_deg, pole_dec_deg, prime_meridian_deg) do
    case NIF.observation_sub_observer_point(
           floats3(observer_from_body),
           pole_ra_deg / 1.0,
           pole_dec_deg / 1.0,
           prime_meridian_deg / 1.0
         ) do
      {:error, reason} -> {:error, reason}
      {lat, lon} -> {:ok, %{latitude_deg: lat, longitude_deg: lon}}
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  defp floats3({x, y, z}), do: {x * 1.0, y * 1.0, z * 1.0}

  defp surface_point_fields(%{latitude_deg: lat, longitude_deg: lon}), do: {lat, lon}
  defp surface_point_fields({lat, lon}), do: {lat, lon}

  # The observation NIFs return the scalar result directly, or `{:error, atom}`
  # for a degenerate/out-of-domain input (the crate's `Error::Term` shape).
  defp wrap_scalar({:error, reason}), do: {:error, reason}
  defp wrap_scalar(value) when is_number(value), do: {:ok, value}
end
