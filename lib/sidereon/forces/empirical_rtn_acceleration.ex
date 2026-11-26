defmodule Sidereon.Forces.EmpiricalRtnAcceleration do
  @moduledoc """
  Empirical acceleration in the radial, along-track and cross-track frame.
  Each axis can have a constant, cosine and sine term. This struct compares by value.
  """

  alias Sidereon.Forces
  alias Sidereon.Forces.PropagationError
  alias Sidereon.NIF

  defmodule RtnAxis do
    @moduledoc "Axes of the radial, along-track and cross-track frame."
    @type t :: :radial | :along_track | :cross_track

    @doc "Compare two RtnAxis values in declaration order."
    @spec compare(t(), t()) :: :lt | :eq | :gt
    def compare(first, second), do: NIF.force_axis_compare(first, second)

    @doc "Return all supported axes in declaration order."
    @spec all() :: [t()]
    def all, do: NIF.force_all_axes()
  end

  defmodule EmpiricalHarmonic do
    @moduledoc "Dependence on the satellite's argument of latitude."
    @type t :: :constant | :cosine | :sine

    @doc "Compare two EmpiricalHarmonic values in declaration order."
    @spec compare(t(), t()) :: :lt | :eq | :gt
    def compare(first, second), do: NIF.force_harmonic_compare(first, second)

    @doc "Return all supported harmonics in declaration order."
    @spec all() :: [t()]
    def all, do: NIF.force_all_harmonics()
  end

  @typedoc "Axis and harmonic identifying one acceleration coefficient."
  @type term_key :: {RtnAxis.t(), EmpiricalHarmonic.t()}
  @typedoc "Axis, harmonic and coefficient in km/s²."
  @type coefficient :: {RtnAxis.t(), EmpiricalHarmonic.t(), float()}

  defstruct terms: []
  @type t :: %__MODULE__{terms: [coefficient()]}

  @doc "Return a model with no empirical terms."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Return a model with the specified terms present at zero."
  @spec with_zero_terms([term_key()]) :: t()
  def with_zero_terms(keys), do: %__MODULE__{terms: NIF.force_empirical_with_zero_terms(keys)}

  @doc "Return a model with the three constant terms present at zero."
  @spec constant_terms() :: t()
  def constant_terms, do: %__MODULE__{terms: NIF.force_empirical_constant_terms()}

  @doc "Return a model with all nine terms present at zero."
  @spec all_terms() :: t()
  def all_terms, do: %__MODULE__{terms: NIF.force_empirical_all_terms()}

  @doc "Add or replace a term with a coefficient in km/s²."
  @spec with_term(t(), RtnAxis.t(), EmpiricalHarmonic.t(), number()) ::
          {:ok, t()} | {:error, PropagationError.t()}
  def with_term(%__MODULE__{terms: terms}, axis, harmonic, coefficient) do
    with {:ok, values} <- Forces.decode(NIF.force_empirical_with_term(terms, axis, harmonic, coefficient / 1.0)) do
      {:ok, %__MODULE__{terms: values}}
    end
  end

  @doc "Return the coefficient in km/s², or nil for an absent term."
  @spec coefficient_km_s2(t(), RtnAxis.t(), EmpiricalHarmonic.t()) ::
          {:ok, float() | nil} | {:error, PropagationError.t()}
  def coefficient_km_s2(%__MODULE__{terms: terms}, axis, harmonic) do
    Forces.decode(NIF.force_empirical_coefficient(terms, axis, harmonic))
  end

  @doc "Return the estimable parameter name for an axis and harmonic."
  @spec parameter_name(RtnAxis.t(), EmpiricalHarmonic.t()) :: String.t()
  def parameter_name(axis, harmonic), do: NIF.force_empirical_parameter_name(axis, harmonic)

  @doc false
  @spec native(t()) :: {:empirical_rtn, [coefficient()]}
  def native(%__MODULE__{terms: terms}), do: {:empirical_rtn, terms}
end
