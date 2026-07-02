defmodule Sidereon.Astro.Anomaly do
  @moduledoc """
  Kepler anomaly conversions and two-body propagation for classical elements.
  """

  alias Sidereon.NIF
  alias Sidereon.OrbitalElements

  @type scalar_result :: {:ok, float()} | {:error, atom()}
  @type kepler_solution :: %{anomaly: float(), iterations: non_neg_integer()}

  @doc "Mean anomaly to eccentric anomaly."
  @spec mean_to_eccentric(number(), number()) :: scalar_result()
  def mean_to_eccentric(mean_anom, ecc), do: scalar(:anomaly_mean_to_eccentric, mean_anom, ecc)

  @doc "Eccentric anomaly to mean anomaly."
  @spec eccentric_to_mean(number(), number()) :: scalar_result()
  def eccentric_to_mean(ecc_anom, ecc), do: scalar(:anomaly_eccentric_to_mean, ecc_anom, ecc)

  @doc "Eccentric anomaly to true anomaly."
  @spec eccentric_to_true(number(), number()) :: scalar_result()
  def eccentric_to_true(ecc_anom, ecc), do: scalar(:anomaly_eccentric_to_true, ecc_anom, ecc)

  @doc "True anomaly to eccentric anomaly."
  @spec true_to_eccentric(number(), number()) :: scalar_result()
  def true_to_eccentric(true_anom, ecc), do: scalar(:anomaly_true_to_eccentric, true_anom, ecc)

  @doc "Mean anomaly to true anomaly."
  @spec mean_to_true(number(), number()) :: scalar_result()
  def mean_to_true(mean_anom, ecc), do: scalar(:anomaly_mean_to_true, mean_anom, ecc)

  @doc "True anomaly to mean anomaly."
  @spec true_to_mean(number(), number()) :: scalar_result()
  def true_to_mean(true_anom, ecc), do: scalar(:anomaly_true_to_mean, true_anom, ecc)

  @doc "Solve Kepler's equation for the middle anomaly."
  @spec solve_kepler(number(), number()) :: {:ok, kepler_solution()} | {:error, atom()}
  def solve_kepler(mean_anom, ecc) do
    case NIF.anomaly_solve_kepler(mean_anom / 1.0, ecc / 1.0) do
      {:ok, fields} -> {:ok, %{anomaly: fields.anomaly, iterations: fields.iterations}}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc "Propagate classical elements by `dt_s` under two-body Kepler motion."
  @spec propagate_kepler(OrbitalElements.t(), number(), number()) ::
          {:ok, OrbitalElements.t()} | {:error, term()}
  def propagate_kepler(%OrbitalElements{} = elements, dt_s, mu \\ OrbitalElements.mu_earth()) do
    case NIF.anomaly_propagate_kepler(classical_map(elements), mu / 1.0, dt_s / 1.0) do
      {:ok, fields} -> {:ok, to_classical(fields)}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  def mean_to_eccentric!(m, e), do: bang(mean_to_eccentric(m, e))
  def eccentric_to_mean!(a, e), do: bang(eccentric_to_mean(a, e))
  def eccentric_to_true!(a, e), do: bang(eccentric_to_true(a, e))
  def true_to_eccentric!(a, e), do: bang(true_to_eccentric(a, e))
  def mean_to_true!(m, e), do: bang(mean_to_true(m, e))
  def true_to_mean!(a, e), do: bang(true_to_mean(a, e))
  def solve_kepler!(m, e), do: bang(solve_kepler(m, e))

  def propagate_kepler!(elements, dt_s, mu \\ OrbitalElements.mu_earth()),
    do: bang(propagate_kepler(elements, dt_s, mu))

  defp scalar(fun, value, ecc) do
    apply(NIF, fun, [value / 1.0, ecc / 1.0])
  rescue
    e in ErlangError -> {:error, e.original}
  end

  defp classical_map(%OrbitalElements{} = elements) do
    elements
    |> Map.from_struct()
    |> Map.update!(:orbit_type, &Atom.to_string/1)
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
  defp bang({:error, reason}), do: raise(ArgumentError, "anomaly calculation failed: #{inspect(reason)}")
end
