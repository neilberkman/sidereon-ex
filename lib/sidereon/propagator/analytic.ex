defmodule Sidereon.Propagator.Analytic do
  @moduledoc """
  Closed-form zonal propagation and mean-to-osculating element conversions.
  Angles are in radians and epochs are TDB seconds past J2000.
  """

  alias __MODULE__.CircularElements
  alias __MODULE__.KeplerianElements
  alias __MODULE__.MeanConversionOptions
  alias __MODULE__.MeanElements
  alias __MODULE__.ZonalHarmonics
  alias Sidereon.NIF
  alias Sidereon.Propagator.Analytic

  @typedoc "An epoch, inertial position in kilometres, and inertial velocity in kilometres per second."
  @type state :: {number(), vector(), vector()}
  @typedoc "Cartesian components in x, y, z order."
  @type vector :: {number(), number(), number()}

  defmodule AnalyticTheory do
    @moduledoc "Zonal perturbation theories for closed-form propagation."
    @type t :: :eckstein_hechler | :brouwer_lyddane
    @doc "Return the published name of the analytic theory."
    @spec to_string(t()) :: String.t()
    def to_string(theory), do: NIF.analytic_theory_display(theory)
  end

  defmodule AnalyticPropagationError do
    @moduledoc "An analytic propagation or element conversion refusal with its details."
    defstruct [:kind, :detail, :message]
    @type t :: %__MODULE__{kind: atom(), detail: map(), message: String.t()}
    defimpl String.Chars do
      def to_string(error), do: error.message
    end
  end

  defmodule CircularElements do
    @moduledoc "Circular elements with eccentricity components and mean argument of latitude. This struct compares by value."

    alias Sidereon.Propagator.Analytic.AnalyticPropagationError

    @enforce_keys [:a_km, :ex, :ey, :i_rad, :raan_rad, :mean_latitude_argument_rad]
    defstruct [:a_km, :ex, :ey, :i_rad, :raan_rad, :mean_latitude_argument_rad]

    @type t :: %__MODULE__{
            a_km: float(),
            ex: float(),
            ey: float(),
            i_rad: float(),
            raan_rad: float(),
            mean_latitude_argument_rad: float()
          }

    @doc "Convert an inertial Cartesian position and velocity to elements."
    @spec from_cartesian(Analytic.vector(), Analytic.vector(), number()) ::
            {:ok, t()} | {:error, AnalyticPropagationError.t()}
    def from_cartesian(position, velocity, mu_km3_s2) do
      NIF.analytic_circular_elements_from_cartesian(
        Analytic.native_vector(position),
        Analytic.native_vector(velocity),
        mu_km3_s2 / 1.0
      )
      |> Analytic.decode(__MODULE__)
    end

    @doc "Convert the elements to Cartesian position in kilometres and velocity in kilometres per second."
    @spec to_cartesian(t(), number()) ::
            {:ok, {Analytic.vector(), Analytic.vector()}} | {:error, AnalyticPropagationError.t()}
    def to_cartesian(%__MODULE__{} = elements, mu_km3_s2) do
      NIF.analytic_circular_elements_to_cartesian(elements, mu_km3_s2 / 1.0) |> Analytic.decode()
    end

    @doc "Return the magnitude of the eccentricity vector."
    @spec eccentricity(t()) :: float()
    def eccentricity(%__MODULE__{} = elements), do: NIF.analytic_eccentricity(elements)
  end

  defmodule KeplerianElements do
    @moduledoc "Keplerian elements with mean anomaly for analytic propagation. This struct compares by value."

    alias Sidereon.Propagator.Analytic.AnalyticPropagationError

    @enforce_keys [:a_km, :e, :i_rad, :arg_perigee_rad, :raan_rad, :mean_anomaly_rad]
    defstruct [:a_km, :e, :i_rad, :arg_perigee_rad, :raan_rad, :mean_anomaly_rad]

    @type t :: %__MODULE__{
            a_km: float(),
            e: float(),
            i_rad: float(),
            arg_perigee_rad: float(),
            raan_rad: float(),
            mean_anomaly_rad: float()
          }

    @doc "Convert an inertial Cartesian position and velocity to elements."
    @spec from_cartesian(Analytic.vector(), Analytic.vector(), number()) ::
            {:ok, t()} | {:error, AnalyticPropagationError.t()}
    def from_cartesian(position, velocity, mu_km3_s2) do
      NIF.analytic_keplerian_elements_from_cartesian(
        Analytic.native_vector(position),
        Analytic.native_vector(velocity),
        mu_km3_s2 / 1.0
      )
      |> Analytic.decode(__MODULE__)
    end

    @doc "Convert the elements to Cartesian position in kilometres and velocity in kilometres per second."
    @spec to_cartesian(t(), number()) ::
            {:ok, {Analytic.vector(), Analytic.vector()}} | {:error, AnalyticPropagationError.t()}
    def to_cartesian(%__MODULE__{} = elements, mu_km3_s2) do
      NIF.analytic_keplerian_elements_to_cartesian(elements, mu_km3_s2 / 1.0) |> Analytic.decode()
    end
  end

  defmodule ZonalHarmonics do
    @moduledoc "Unnormalized zonal gravity coefficients and reference constants. This struct compares by value."

    @enforce_keys [:mu_km3_s2, :re_km, :c20, :c30, :c40, :c50, :c60]
    defstruct [:mu_km3_s2, :re_km, :c20, :c30, :c40, :c50, :c60]

    @type t :: %__MODULE__{
            mu_km3_s2: float(),
            re_km: float(),
            c20: float(),
            c30: float(),
            c40: float(),
            c50: float(),
            c60: float()
          }

    @doc "Return the Earth reference constants and zonal coefficients."
    @spec earth() :: t()
    def earth, do: struct!(__MODULE__, NIF.analytic_zonal_earth())
  end

  defmodule MeanConversionOptions do
    @moduledoc "Convergence settings for osculating-to-mean conversion. This struct compares by value."

    @enforce_keys [:tolerance, :max_iterations]
    defstruct [:tolerance, :max_iterations]

    @type t :: %__MODULE__{
            tolerance: float(),
            max_iterations: non_neg_integer()
          }

    @doc "Return the default convergence settings for Eckstein Hechler."
    @spec eckstein_hechler_default() :: t()
    def eckstein_hechler_default, do: struct!(__MODULE__, NIF.analytic_eckstein_hechler_default())

    @doc "Return the default convergence settings for Brouwer Lyddane."
    @spec brouwer_lyddane_default() :: t()
    def brouwer_lyddane_default, do: struct!(__MODULE__, NIF.analytic_brouwer_lyddane_default())
  end

  defmodule MeanElements do
    @moduledoc "Mean elements and the number of conversion iterations. This struct compares by value."
    @enforce_keys [:elements, :iterations]
    defstruct [:elements, :iterations]
    @type t :: %__MODULE__{elements: CircularElements.t() | KeplerianElements.t(), iterations: non_neg_integer()}
  end

  @doc "Compute mean elements with the Eckstein-Hechler theory."
  @spec eckstein_hechler_mean_elements(state(), ZonalHarmonics.t(), MeanConversionOptions.t()) ::
          {:ok, MeanElements.t()} | {:error, AnalyticPropagationError.t()}
  def eckstein_hechler_mean_elements(state, gravity, options) do
    result = NIF.analytic_eckstein_hechler_mean_elements(native_state(state), gravity, options)

    with {:ok, {elements, iterations}} <- decode(result) do
      {:ok, %MeanElements{elements: struct!(CircularElements, elements), iterations: iterations}}
    end
  end

  @doc "Compute osculating elements with the Eckstein-Hechler theory."
  @spec eckstein_hechler_osculating_elements(CircularElements.t(), ZonalHarmonics.t()) ::
          {:ok, CircularElements.t()} | {:error, AnalyticPropagationError.t()}
  def eckstein_hechler_osculating_elements(elements, gravity) do
    result = NIF.analytic_eckstein_hechler_osculating_elements(elements, gravity)
    decode(result, CircularElements)
  end

  defmodule EcksteinHechlerPropagator do
    @moduledoc "Closed-form propagation with the Eckstein-Hechler zonal theory."
    alias Sidereon.Propagator.Analytic.AnalyticPropagationError

    @enforce_keys [:handle]
    defstruct [:handle]
    @opaque t :: %__MODULE__{handle: reference()}

    @doc "Construct a propagator from an osculating Cartesian state."
    @spec new(Analytic.state(), ZonalHarmonics.t(), MeanConversionOptions.t()) ::
            {:ok, t()} | {:error, AnalyticPropagationError.t()}
    def new(state, gravity, options),
      do: decode_handle(NIF.analytic_eckstein_hechler_new(Analytic.native_state(state), gravity, options))

    @doc "Construct a propagator from mean elements at a TDB epoch."
    @spec from_mean_elements(number(), CircularElements.t(), ZonalHarmonics.t()) ::
            {:ok, t()} | {:error, AnalyticPropagationError.t()}
    def from_mean_elements(epoch, elements, gravity),
      do: decode_handle(NIF.analytic_eckstein_hechler_from_mean_elements(epoch / 1.0, elements, gravity))

    @doc "Return the osculating Cartesian state at the requested epoch."
    @spec propagate(t(), number()) :: {:ok, Analytic.state()} | {:error, AnalyticPropagationError.t()}
    def propagate(%__MODULE__{handle: handle}, epoch),
      do: Analytic.decode(NIF.analytic_eckstein_hechler_propagate(handle, epoch / 1.0))

    @doc "Return the osculating elements at the requested epoch."
    @spec osculating_elements(t(), number()) :: {:ok, CircularElements.t()} | {:error, AnalyticPropagationError.t()}
    def osculating_elements(%__MODULE__{handle: handle}, epoch),
      do:
        Analytic.decode(
          NIF.analytic_eckstein_hechler_propagator_osculating_elements(handle, epoch / 1.0),
          CircularElements
        )

    @doc "Return the osculating Cartesian states at the requested epochs, in input order."
    @spec ephemeris(t(), [number()]) :: {:ok, [Analytic.state()]} | {:error, AnalyticPropagationError.t()}
    def ephemeris(%__MODULE__{handle: handle}, epochs),
      do: Analytic.decode(NIF.analytic_eckstein_hechler_ephemeris(handle, Enum.map(epochs, &(&1 / 1.0))))

    @doc "Return the mean-element epoch in TDB seconds past J2000."
    @spec epoch_tdb_seconds(t()) :: float()
    def epoch_tdb_seconds(%__MODULE__{handle: handle}),
      do: NIF.analytic_eckstein_hechler_propagator_epoch_tdb_seconds(handle)

    @doc "Return the initial mean elements."
    @spec mean_elements(t()) :: CircularElements.t()
    def mean_elements(%__MODULE__{handle: handle}),
      do: struct!(CircularElements, NIF.analytic_eckstein_hechler_propagator_mean_elements(handle))

    @doc "Return the zonal gravity field."
    @spec gravity(t()) :: ZonalHarmonics.t()
    def gravity(%__MODULE__{handle: handle}),
      do: struct!(ZonalHarmonics, NIF.analytic_eckstein_hechler_propagator_gravity(handle))

    defp decode_handle(result) do
      with {:ok, handle} <- Analytic.decode(result), do: {:ok, %__MODULE__{handle: handle}}
    end
  end

  @doc "Compute mean elements with the Brouwer-Lyddane theory."
  @spec brouwer_lyddane_mean_elements(state(), ZonalHarmonics.t(), MeanConversionOptions.t()) ::
          {:ok, MeanElements.t()} | {:error, AnalyticPropagationError.t()}
  def brouwer_lyddane_mean_elements(state, gravity, options) do
    result = NIF.analytic_brouwer_lyddane_mean_elements(native_state(state), gravity, options)

    with {:ok, {elements, iterations}} <- decode(result) do
      {:ok, %MeanElements{elements: struct!(KeplerianElements, elements), iterations: iterations}}
    end
  end

  @doc "Compute osculating elements with the Brouwer-Lyddane theory."
  @spec brouwer_lyddane_osculating_elements(KeplerianElements.t(), ZonalHarmonics.t()) ::
          {:ok, KeplerianElements.t()} | {:error, AnalyticPropagationError.t()}
  def brouwer_lyddane_osculating_elements(elements, gravity) do
    result = NIF.analytic_brouwer_lyddane_osculating_elements(elements, gravity)
    decode(result, KeplerianElements)
  end

  defmodule BrouwerLyddanePropagator do
    @moduledoc "Closed-form propagation with the Brouwer-Lyddane zonal theory."
    alias Sidereon.Propagator.Analytic.AnalyticPropagationError

    @enforce_keys [:handle]
    defstruct [:handle]
    @opaque t :: %__MODULE__{handle: reference()}

    @doc "Construct a propagator from an osculating Cartesian state."
    @spec new(Analytic.state(), ZonalHarmonics.t(), number(), MeanConversionOptions.t()) ::
            {:ok, t()} | {:error, AnalyticPropagationError.t()}
    def new(state, gravity, m2_rad_s2, options),
      do:
        decode_handle(NIF.analytic_brouwer_lyddane_new(Analytic.native_state(state), gravity, m2_rad_s2 / 1.0, options))

    @doc "Construct a propagator from mean elements at a TDB epoch."
    @spec from_mean_elements(number(), KeplerianElements.t(), ZonalHarmonics.t(), number()) ::
            {:ok, t()} | {:error, AnalyticPropagationError.t()}
    def from_mean_elements(epoch, elements, gravity, m2_rad_s2),
      do:
        decode_handle(NIF.analytic_brouwer_lyddane_from_mean_elements(epoch / 1.0, elements, gravity, m2_rad_s2 / 1.0))

    @doc "Return the osculating Cartesian state at the requested epoch."
    @spec propagate(t(), number()) :: {:ok, Analytic.state()} | {:error, AnalyticPropagationError.t()}
    def propagate(%__MODULE__{handle: handle}, epoch),
      do: Analytic.decode(NIF.analytic_brouwer_lyddane_propagate(handle, epoch / 1.0))

    @doc "Return the osculating elements at the requested epoch."
    @spec osculating_elements(t(), number()) :: {:ok, KeplerianElements.t()} | {:error, AnalyticPropagationError.t()}
    def osculating_elements(%__MODULE__{handle: handle}, epoch),
      do:
        Analytic.decode(
          NIF.analytic_brouwer_lyddane_propagator_osculating_elements(handle, epoch / 1.0),
          KeplerianElements
        )

    @doc "Return the osculating Cartesian states at the requested epochs, in input order."
    @spec ephemeris(t(), [number()]) :: {:ok, [Analytic.state()]} | {:error, AnalyticPropagationError.t()}
    def ephemeris(%__MODULE__{handle: handle}, epochs),
      do: Analytic.decode(NIF.analytic_brouwer_lyddane_ephemeris(handle, Enum.map(epochs, &(&1 / 1.0))))

    @doc "Return the mean-element epoch in TDB seconds past J2000."
    @spec epoch_tdb_seconds(t()) :: float()
    def epoch_tdb_seconds(%__MODULE__{handle: handle}),
      do: NIF.analytic_brouwer_lyddane_propagator_epoch_tdb_seconds(handle)

    @doc "Return the initial mean elements."
    @spec mean_elements(t()) :: KeplerianElements.t()
    def mean_elements(%__MODULE__{handle: handle}),
      do: struct!(KeplerianElements, NIF.analytic_brouwer_lyddane_propagator_mean_elements(handle))

    @doc "Return the zonal gravity field."
    @spec gravity(t()) :: ZonalHarmonics.t()
    def gravity(%__MODULE__{handle: handle}),
      do: struct!(ZonalHarmonics, NIF.analytic_brouwer_lyddane_propagator_gravity(handle))

    @doc "Return the secular along-track coefficient in radians per second squared."
    @spec m2_rad_s2(t()) :: float()
    def m2_rad_s2(%__MODULE__{handle: handle}), do: NIF.analytic_brouwer_lyddane_propagator_m2_rad_s2(handle)

    defp decode_handle(result) do
      with {:ok, handle} <- Analytic.decode(result), do: {:ok, %__MODULE__{handle: handle}}
    end
  end

  @doc false
  @spec decode(term()) :: term()
  def decode({:ok, _value} = result), do: result
  def decode({:error, details}), do: {:error, struct!(AnalyticPropagationError, details)}

  @doc false
  @spec decode(term(), module()) :: term()
  def decode(result, module) do
    with {:ok, value} <- decode(result), do: {:ok, struct!(module, value)}
  end

  @doc false
  @spec native_state(state()) :: state()
  def native_state({epoch, position, velocity}), do: {epoch / 1.0, native_vector(position), native_vector(velocity)}

  @doc false
  @spec native_vector(vector()) :: {float(), float(), float()}
  def native_vector({x, y, z}), do: {x / 1.0, y / 1.0, z / 1.0}
end
