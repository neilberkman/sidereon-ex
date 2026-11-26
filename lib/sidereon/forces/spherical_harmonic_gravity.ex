defmodule Sidereon.Forces.SphericalHarmonicGravity do
  @moduledoc """
  Fully normalized spherical-harmonic perturbing gravity. Body-fixed evaluation
  uses Holmes–Featherstone recursion. The perturbation begins at degree two.
  """

  alias Sidereon.Forces
  alias Sidereon.Forces.IcgemGravityField
  alias Sidereon.Forces.PropagationError
  alias Sidereon.NIF
  alias Sidereon.Propagator.Analytic

  @enforce_keys [:handle]
  defstruct [:handle]
  @opaque t :: %__MODULE__{handle: reference()}

  defmodule SphericalHarmonicCoefficient do
    @moduledoc "Fully normalized cosine and sine coefficients at a degree and order. This struct compares by value."
    @enforce_keys [:degree, :order, :c, :s]
    defstruct [:degree, :order, :c, :s]
    @type t :: %__MODULE__{degree: non_neg_integer(), order: non_neg_integer(), c: float(), s: float()}
  end

  @doc "Construct a truncated gravity model from EGM96 coefficients."
  @spec egm96_truncated(non_neg_integer(), non_neg_integer()) :: {:ok, t()} | {:error, PropagationError.t()}
  def egm96_truncated(degree, order) do
    with {:ok, handle} <- Forces.decode(NIF.harmonic_gravity_egm96_truncated(degree, order)),
         do: {:ok, %__MODULE__{handle: handle}}
  end

  @doc "Compare spherical-harmonic gravity models by value."
  @spec equal?(t(), t()) :: boolean()
  def equal?(%__MODULE__{handle: first}, %__MODULE__{handle: second}), do: NIF.harmonic_gravity_equal(first, second)

  @doc "Return the fully normalized coefficient at TT seconds past J2000, if stored."
  @spec coefficient_at(t(), non_neg_integer(), non_neg_integer(), number()) ::
          {:ok, SphericalHarmonicCoefficient.t() | nil} | {:error, PropagationError.t()}
  def coefficient_at(%__MODULE__{handle: handle}, degree, order, epoch) do
    case Forces.decode(NIF.harmonic_gravity_coefficient_at(handle, degree, order, epoch / 1.0)) do
      {:ok, nil} -> {:ok, nil}
      {:ok, value} -> {:ok, struct!(SphericalHarmonicCoefficient, value)}
      {:error, _error} = error -> error
    end
  end

  @doc "Return the perturbing potential of a static field in km²/s²."
  @spec body_fixed_potential_km2_s2(t(), Analytic.vector()) :: {:ok, float()} | {:error, PropagationError.t()}
  def body_fixed_potential_km2_s2(%__MODULE__{handle: handle}, position) do
    Forces.decode(NIF.harmonic_gravity_body_fixed_potential_km2_s2(handle, Analytic.native_vector(position)))
  end

  @doc "Return the perturbing potential in km²/s² at TT seconds past J2000."
  @spec body_fixed_potential_at_km2_s2(t(), Analytic.vector(), number()) ::
          {:ok, float()} | {:error, PropagationError.t()}
  def body_fixed_potential_at_km2_s2(%__MODULE__{handle: handle}, position, epoch) do
    Forces.decode(
      NIF.harmonic_gravity_body_fixed_potential_at_km2_s2(handle, Analytic.native_vector(position), epoch / 1.0)
    )
  end

  @doc "Return the perturbing acceleration of a static field in km/s²."
  @spec body_fixed_acceleration_km_s2(t(), Analytic.vector()) ::
          {:ok, Analytic.vector()} | {:error, PropagationError.t()}
  def body_fixed_acceleration_km_s2(%__MODULE__{handle: handle}, position) do
    Forces.decode(NIF.harmonic_gravity_body_fixed_acceleration_km_s2(handle, Analytic.native_vector(position)))
  end

  @doc "Return the perturbing acceleration in km/s² at TT seconds past J2000."
  @spec body_fixed_acceleration_at_km_s2(t(), Analytic.vector(), number()) ::
          {:ok, Analytic.vector()} | {:error, PropagationError.t()}
  def body_fixed_acceleration_at_km_s2(%__MODULE__{handle: handle}, position, epoch) do
    Forces.decode(
      NIF.harmonic_gravity_body_fixed_acceleration_at_km_s2(handle, Analytic.native_vector(position), epoch / 1.0)
    )
  end

  @doc "Return the gravitational parameter in km³/s²."
  @spec mu_km3_s2(t()) :: float()
  def mu_km3_s2(%__MODULE__{handle: handle}), do: NIF.harmonic_gravity_mu_km3_s2(handle)

  @doc "Return the reference radius in km."
  @spec reference_radius_km(t()) :: float()
  def reference_radius_km(%__MODULE__{handle: handle}), do: NIF.harmonic_gravity_reference_radius_km(handle)

  @doc "Return the maximum evaluation degree."
  @spec max_degree(t()) :: non_neg_integer()
  def max_degree(%__MODULE__{handle: handle}), do: NIF.harmonic_gravity_max_degree(handle)

  @doc "Return the maximum evaluation order."
  @spec max_order(t()) :: non_neg_integer()
  def max_order(%__MODULE__{handle: handle}), do: NIF.harmonic_gravity_max_order(handle)

  @doc "Return the permanent-tide convention."
  @spec tide_system(t()) :: IcgemGravityField.tide_system()
  def tide_system(%__MODULE__{handle: handle}), do: NIF.harmonic_gravity_tide_system(handle)

  @doc "Return whether the gravity model evaluates time-variable terms."
  @spec time_variable?(t()) :: boolean()
  def time_variable?(%__MODULE__{handle: handle}), do: NIF.harmonic_gravity_is_time_variable(handle)
end
