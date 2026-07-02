defmodule Sidereon.Astro.Equinoctial do
  @moduledoc """
  Equinoctial and modified equinoctial orbital element conversions.
  """

  alias Sidereon.NIF
  alias Sidereon.OrbitalElements

  defmodule EquinoctialElements do
    @moduledoc """
    Equinoctial orbital elements.
    """
    @enforce_keys [:a, :h, :k, :p, :q, :lambda, :retrograde]
    defstruct [:a, :h, :k, :p, :q, :lambda, :retrograde]

    @type retrograde_factor :: :prograde | :retrograde
    @type t :: %__MODULE__{
            a: float(),
            h: float(),
            k: float(),
            p: float(),
            q: float(),
            lambda: float(),
            retrograde: retrograde_factor()
          }
  end

  defmodule ModifiedEquinoctialElements do
    @moduledoc """
    Modified equinoctial orbital elements.
    """
    @enforce_keys [:p, :f, :g, :h, :k, :l, :retrograde]
    defstruct [:p, :f, :g, :h, :k, :l, :retrograde]

    @type t :: %__MODULE__{
            p: float(),
            f: float(),
            g: float(),
            h: float(),
            k: float(),
            l: float(),
            retrograde: EquinoctialElements.retrograde_factor()
          }
  end

  @type vec3 :: {number(), number(), number()}

  def coe2eq(%OrbitalElements{} = coe, factor \\ :prograde),
    do: call_eq(:equinoctial_coe2eq, [classical_map(coe), factor_string(factor)])

  def eq2coe(%EquinoctialElements{} = eq), do: call_classical(:equinoctial_eq2coe, [eq_map(eq)])

  def coe2mee(%OrbitalElements{} = coe, factor \\ :prograde),
    do: call_mee(:equinoctial_coe2mee, [classical_map(coe), factor_string(factor)])

  def mee2coe(%ModifiedEquinoctialElements{} = mee), do: call_classical(:equinoctial_mee2coe, [mee_map(mee)])

  def rv2eq(r, v, mu \\ OrbitalElements.mu_earth(), factor \\ :prograde) do
    call_eq(:equinoctial_rv2eq, [floats3(r), floats3(v), mu / 1.0, factor_string(factor)])
  end

  def eq2rv(%EquinoctialElements{} = eq, mu \\ OrbitalElements.mu_earth()) do
    case NIF.equinoctial_eq2rv(eq_map(eq), mu / 1.0) do
      {r, v} -> {:ok, %{position_km: r, velocity_km_s: v}}
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  def rv2mee(r, v, mu \\ OrbitalElements.mu_earth(), factor \\ :prograde) do
    call_mee(:equinoctial_rv2mee, [floats3(r), floats3(v), mu / 1.0, factor_string(factor)])
  end

  def mee2rv(%ModifiedEquinoctialElements{} = mee, mu \\ OrbitalElements.mu_earth()) do
    case NIF.equinoctial_mee2rv(mee_map(mee), mu / 1.0) do
      {r, v} -> {:ok, %{position_km: r, velocity_km_s: v}}
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  def eq2mee(%EquinoctialElements{} = eq), do: call_mee(:equinoctial_eq2mee, [eq_map(eq)])
  def mee2eq(%ModifiedEquinoctialElements{} = mee), do: call_eq(:equinoctial_mee2eq, [mee_map(mee)])

  def coe2eq!(coe, factor \\ :prograde), do: bang(coe2eq(coe, factor))
  def eq2coe!(eq), do: bang(eq2coe(eq))
  def coe2mee!(coe, factor \\ :prograde), do: bang(coe2mee(coe, factor))
  def mee2coe!(mee), do: bang(mee2coe(mee))
  def rv2eq!(r, v, mu \\ OrbitalElements.mu_earth(), factor \\ :prograde), do: bang(rv2eq(r, v, mu, factor))
  def eq2rv!(eq, mu \\ OrbitalElements.mu_earth()), do: bang(eq2rv(eq, mu))
  def rv2mee!(r, v, mu \\ OrbitalElements.mu_earth(), factor \\ :prograde), do: bang(rv2mee(r, v, mu, factor))
  def mee2rv!(mee, mu \\ OrbitalElements.mu_earth()), do: bang(mee2rv(mee, mu))
  def eq2mee!(eq), do: bang(eq2mee(eq))
  def mee2eq!(mee), do: bang(mee2eq(mee))

  defp call_eq(fun, args), do: decode(apply(NIF, fun, args), &to_eq/1)
  defp call_mee(fun, args), do: decode(apply(NIF, fun, args), &to_mee/1)
  defp call_classical(fun, args), do: decode(apply(NIF, fun, args), &to_classical/1)

  defp decode({:ok, fields}, mapper), do: {:ok, mapper.(fields)}
  defp decode({:error, reason}, _mapper), do: {:error, reason}

  defp to_eq(fields) do
    %EquinoctialElements{
      a: fields.a,
      h: fields.h,
      k: fields.k,
      p: fields.p,
      q: fields.q,
      lambda: fields.lambda,
      retrograde: retrograde_atom(fields.retrograde)
    }
  end

  defp to_mee(fields) do
    %ModifiedEquinoctialElements{
      p: fields.p,
      f: fields.f,
      g: fields.g,
      h: fields.h,
      k: fields.k,
      l: fields.l,
      retrograde: retrograde_atom(fields.retrograde)
    }
  end

  defp to_classical(fields) do
    %OrbitalElements{
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
      orbit_type: orbit_type_atom(fields.orbit_type)
    }
  end

  defp classical_map(%OrbitalElements{} = coe),
    do: coe |> Map.from_struct() |> Map.update!(:orbit_type, &Atom.to_string/1)

  defp eq_map(%EquinoctialElements{} = eq), do: eq |> Map.from_struct() |> Map.update!(:retrograde, &Atom.to_string/1)

  defp mee_map(%ModifiedEquinoctialElements{} = mee),
    do: mee |> Map.from_struct() |> Map.update!(:retrograde, &Atom.to_string/1)

  defp factor_string(factor) when factor in [:prograde, :retrograde], do: Atom.to_string(factor)
  defp floats3({x, y, z}), do: {x / 1.0, y / 1.0, z / 1.0}
  defp retrograde_atom("prograde"), do: :prograde
  defp retrograde_atom("retrograde"), do: :retrograde
  defp retrograde_atom(other), do: other
  defp orbit_type_atom("elliptic"), do: :elliptic
  defp orbit_type_atom("circular"), do: :circular
  defp orbit_type_atom("parabolic"), do: :parabolic
  defp orbit_type_atom("hyperbolic"), do: :hyperbolic
  defp orbit_type_atom("elliptical_inclined"), do: :elliptical_inclined
  defp orbit_type_atom("elliptical_equatorial"), do: :elliptical_equatorial
  defp orbit_type_atom("circular_inclined"), do: :circular_inclined
  defp orbit_type_atom("circular_equatorial"), do: :circular_equatorial
  defp orbit_type_atom(other), do: other
  defp bang({:ok, value}), do: value
  defp bang({:error, reason}), do: raise(ArgumentError, "equinoctial conversion failed: #{inspect(reason)}")
end
