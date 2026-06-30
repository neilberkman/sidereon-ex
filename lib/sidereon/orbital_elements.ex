defmodule Sidereon.OrbitalElements do
  @moduledoc """
  Classical (Keplerian) orbital elements and the two-body state transforms.

  Converts between a Cartesian state (position in km, velocity in km/s) and the
  classical element set via the `sidereon-core` `astro::elements` kernels
  (`rv2coe` / `coe2rv`). Angles are in **radians**, the crate's native element
  unit; distances are in km and `mu` is in km^3/s^2 (defaulting to Earth's
  gravitational parameter).

  This struct is distinct from `Sidereon.Elements`, which holds the mean
  TLE/OMM element set used to seed SGP4. The `orbit_type` tag reports which
  auxiliary angle (`arglat`, `truelon`, `lonper`) carries the meaningful value
  for a degenerate (circular and/or equatorial) orbit.
  """

  alias Sidereon.NIF

  # Earth's gravitational parameter, km^3/s^2 (matches sidereon_core MU_EARTH).
  @mu_earth_km3_s2 398_600.4418

  @orbit_types %{
    "elliptical_inclined" => :elliptical_inclined,
    "elliptical_equatorial" => :elliptical_equatorial,
    "circular_inclined" => :circular_inclined,
    "circular_equatorial" => :circular_equatorial
  }

  @type orbit_type ::
          :elliptical_inclined
          | :elliptical_equatorial
          | :circular_inclined
          | :circular_equatorial

  @type t :: %__MODULE__{
          p: float(),
          a: float(),
          ecc: float(),
          incl: float(),
          raan: float() | nil,
          argp: float() | nil,
          nu: float() | nil,
          arglat: float() | nil,
          truelon: float() | nil,
          lonper: float() | nil,
          orbit_type: orbit_type()
        }

  @enforce_keys [:p, :a, :ecc, :incl, :raan, :argp, :nu, :arglat, :truelon, :lonper, :orbit_type]
  defstruct [:p, :a, :ecc, :incl, :raan, :argp, :nu, :arglat, :truelon, :lonper, :orbit_type]

  @type vec3 :: {number(), number(), number()}

  @doc "Earth's gravitational parameter in km^3/s^2, the default `mu`."
  @spec mu_earth() :: float()
  def mu_earth, do: @mu_earth_km3_s2

  @doc """
  Classical orbital elements from a Cartesian state.

  `r` is the position `{x, y, z}` in km, `v` the velocity `{vx, vy, vz}` in km/s,
  and `mu` the gravitational parameter in km^3/s^2 (default Earth). Returns
  `{:ok, %Sidereon.OrbitalElements{}}` (angles in radians) or `{:error, reason}`
  for a degenerate or non-finite state.
  """
  @spec rv2coe(vec3(), vec3(), number()) :: {:ok, t()} | {:error, term()}
  def rv2coe(r, v, mu \\ @mu_earth_km3_s2) do
    case NIF.elements_rv2coe(floats3(r), floats3(v), mu / 1.0) do
      {:error, reason} ->
        {:error, reason}

      {:ok, fields} ->
        {:ok,
         %__MODULE__{
           p: fields.p,
           a: fields.a,
           ecc: fields.ecc,
           incl: fields.incl,
           raan: fields.raan,
           argp: fields.argp,
           nu: fields.nu,
           arglat: fields.arglat,
           truelon: fields.truelon,
           lonper: fields.lonper,
           orbit_type: Map.fetch!(@orbit_types, fields.orbit_type)
         }}
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Cartesian position (km) and velocity (km/s) from a classical element set.

  `coe` is a `%Sidereon.OrbitalElements{}` (angles in radians); `mu` is the
  gravitational parameter in km^3/s^2 (default Earth). The `orbit_type` tag
  selects which auxiliary angle the core reads for a degenerate orbit. Returns
  `{:ok, %{position_km: {x, y, z}, velocity_km_s: {vx, vy, vz}}}` or
  `{:error, reason}`.
  """
  @spec coe2rv(t(), number()) ::
          {:ok, %{position_km: vec3(), velocity_km_s: vec3()}} | {:error, term()}
  def coe2rv(%__MODULE__{} = coe, mu \\ @mu_earth_km3_s2) do
    with {:ok, orbit_type} <- orbit_type_name(coe.orbit_type) do
      # Angles undefined for this orbit type cross as nil; coe2rv reads only the
      # angles meaningful for `orbit_type`, so the irrelevant ones default to 0.0.
      case NIF.elements_coe2rv(
             coe.p / 1.0,
             coe.ecc / 1.0,
             coe.incl / 1.0,
             angle(coe.raan),
             angle(coe.argp),
             angle(coe.nu),
             angle(coe.arglat),
             angle(coe.truelon),
             angle(coe.lonper),
             orbit_type,
             mu / 1.0
           ) do
        {:error, reason} -> {:error, reason}
        {position, velocity} -> {:ok, %{position_km: position, velocity_km_s: velocity}}
      end
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  defp orbit_type_name(atom) do
    case Enum.find(@orbit_types, fn {_name, value} -> value == atom end) do
      {name, _value} -> {:ok, name}
      nil -> {:error, {:unknown_orbit_type, atom}}
    end
  end

  defp floats3({x, y, z}), do: {x * 1.0, y * 1.0, z * 1.0}

  defp angle(nil), do: 0.0
  defp angle(value), do: value / 1.0
end
