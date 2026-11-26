defmodule Sidereon.OrbitDetermination.Parameters do
  @moduledoc """
  Fit an inertial initial state and selected force parameters to an arc of
  positions in GCRF or to Earth-fixed SP3 observations.
  """

  alias Sidereon.Drag
  alias Sidereon.Forces
  alias Sidereon.GNSS.PreciseEphemerisSample
  alias Sidereon.GNSS.SP3
  alias Sidereon.Iers2010EarthOrientationProvider
  alias Sidereon.NIF
  alias Sidereon.NifCall
  alias Sidereon.OrbitDetermination.OrbitResidualStats
  alias Sidereon.OrbitScoring
  alias Sidereon.Propagator
  alias Sidereon.Propagator.Analytic
  alias Sidereon.Propagator.IntegratorOptions
  alias Sidereon.Propagator.PropagationContext
  alias Sidereon.Propagator.VariationalEpoch
  alias Sidereon.SpaceWeather

  defmodule InertialPositionSample do
    @moduledoc "A GCRF observation in metres with a time-scale-tagged epoch. This struct compares by value."
    @enforce_keys [:epoch, :position_gcrf_m]
    defstruct @enforce_keys
    @type t :: %__MODULE__{epoch: PreciseEphemerisSample.epoch(), position_gcrf_m: Analytic.vector()}
  end

  defmodule EstimatedForceParameter do
    @moduledoc "An initial and estimated force parameter in its model's units. This struct compares by value."
    @enforce_keys [:name, :initial_value, :value]
    defstruct @enforce_keys
    @type t :: %__MODULE__{name: String.t(), initial_value: float(), value: float()}
  end

  defmodule OrbitParameterCovariance do
    @moduledoc """
    Row-major parameter covariance and correlation matrices in fit parameter order.
    Without residual degrees of freedom, the covariance is unbounded.
    This struct compares by value.
    """
    @enforce_keys [:kind]
    defstruct [:kind, :matrix, :correlation, :variance_factor, :degrees_of_freedom]

    @type t :: %__MODULE__{
            kind: :estimated | :unbounded,
            matrix: [[float()]] | nil,
            correlation: [[float()]] | nil,
            variance_factor: float() | nil,
            degrees_of_freedom: non_neg_integer() | nil
          }
  end

  defmodule OrbitParameterFitError do
    @moduledoc "An orbit parameter fit refusal with its details."
    defstruct [:kind, :detail, :message]
    @type t :: %__MODULE__{kind: atom(), detail: map(), message: String.t()}

    defimpl String.Chars do
      def to_string(error), do: error.message
    end
  end

  defmodule OrbitRtnResidual do
    @moduledoc "Observed minus computed position in the radial, along-track and cross-track frame in metres. This struct compares by value."
    @enforce_keys [:epoch_tdb_j2000_s, :elapsed_tt_s, :radial_m, :along_m, :cross_m]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            epoch_tdb_j2000_s: float(),
            elapsed_tt_s: float(),
            radial_m: float(),
            along_m: float(),
            cross_m: float()
          }

    @doc "Return the observation epoch for variational propagation from the fitted initial state."
    @spec variational_epoch(t()) :: VariationalEpoch.t()
    def variational_epoch(%__MODULE__{} = residual) do
      %VariationalEpoch{tdb_j2000_s: residual.epoch_tdb_j2000_s, elapsed_tt_s: residual.elapsed_tt_s}
    end
  end

  defmodule OrbitParameterFit do
    @moduledoc """
    Initial state, estimated force parameters, covariance and post-fit residuals.
    Matrices take their row and column order from parameter_names.
    This struct compares by value.
    """

    @enforce_keys [
      :satellite,
      :initial_state,
      :force_parameters,
      :parameter_names,
      :covariance,
      :residuals,
      :residual_stats,
      :seed_rms_3d_m,
      :iterations,
      :condition_number,
      :sigmas,
      :named_correlations,
      :named_force_parameters
    ]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            satellite: String.t(),
            initial_state: Analytic.state(),
            force_parameters: [EstimatedForceParameter.t()],
            parameter_names: [String.t()],
            covariance: OrbitParameterCovariance.t(),
            residuals: [OrbitRtnResidual.t()],
            residual_stats: OrbitResidualStats.t(),
            seed_rms_3d_m: float(),
            iterations: non_neg_integer(),
            condition_number: float(),
            sigmas: [float() | nil],
            named_correlations: %{optional(String.t()) => %{optional(String.t()) => float() | nil}},
            named_force_parameters: %{optional(String.t()) => EstimatedForceParameter.t()}
          }

    @doc "Return the standard deviation for a named parameter, if available."
    @spec sigma(t(), String.t()) :: float() | nil
    def sigma(%__MODULE__{} = fit, name) do
      with index when is_integer(index) <- Enum.find_index(fit.parameter_names, &(&1 == name)) do
        Enum.at(fit.sigmas, index)
      end
    end

    @doc "Return the correlation between two named parameters, if available."
    @spec correlation(t(), String.t(), String.t()) :: float() | nil
    def correlation(%__MODULE__{} = fit, first, second) do
      fit.named_correlations |> Map.get(first, %{}) |> Map.get(second)
    end

    @doc "Return the initial and estimated value of a named force parameter, if available."
    @spec force_parameter(t(), String.t()) :: EstimatedForceParameter.t() | nil
    def force_parameter(%__MODULE__{} = fit, name), do: Map.get(fit.named_force_parameters, name)
  end

  defmodule OrbitParameterFitOptions do
    @moduledoc """
    Built-in force configuration, optional drag and additional models, and
    parameters to estimate. Observation noise is a per-component standard
    deviation in metres. The convergence threshold is in formal standard deviations.
    A nil option uses the core default.
    Use :infinity to accept every numerically regular normal system.
    """
    defstruct forces: nil,
              drag: nil,
              space_weather: nil,
              space_weather_policy: nil,
              additional_forces: [],
              estimated_parameters: [],
              integrator: nil,
              integrator_options: nil,
              propagation_context: nil,
              observation_sigma_m: nil,
              max_iterations: nil,
              convergence_threshold: nil,
              max_condition_number: nil,
              min_ledger_samples: nil

    @type t :: %__MODULE__{
            forces: list() | nil,
            drag: Drag.Parameters.t() | nil,
            space_weather: SpaceWeather.t() | nil,
            space_weather_policy: SpaceWeather.Policy.t() | keyword() | nil,
            additional_forces: [Forces.model()],
            estimated_parameters: [String.t()],
            integrator: :dp54 | :rk4 | nil,
            integrator_options: IntegratorOptions.t() | nil,
            propagation_context: PropagationContext.t() | nil,
            observation_sigma_m: float() | nil,
            max_iterations: non_neg_integer() | nil,
            convergence_threshold: float() | nil,
            max_condition_number: float() | :infinity | nil,
            min_ledger_samples: non_neg_integer() | nil
          }
  end

  @typedoc "Policy for UT1 outside the orientation provider's coverage."
  @type validity :: :strict | :permissive
  @typedoc "The first UT1 table departure in a permissive fit."
  @type departure :: :before_coverage | :after_coverage | nil

  @doc "Return the six fitted initial-state parameter names in covariance order."
  @spec state_parameter_names() :: [String.t()]
  def state_parameter_names, do: NIF.orbit_fit_state_parameter_names()

  @doc "Fit a satellite's initial state and selected force parameters to GCRF position observations."
  @spec fit_inertial_orbit_parameters([InertialPositionSample.t()], OrbitScoring.satellite_id(), keyword()) ::
          {:ok, OrbitParameterFit.t()} | {:error, OrbitParameterFitError.t()}
  def fit_inertial_orbit_parameters(samples, satellite, opts \\ []) do
    with {:ok, {fit, nil}} <- fit_inertial_orbit_parameters_with_validity(samples, satellite, :strict, opts),
         do: {:ok, fit}
  end

  @doc "Fit GCRF position observations under an explicit UT1 policy and return any departure."
  @spec fit_inertial_orbit_parameters_with_validity(
          [InertialPositionSample.t()],
          OrbitScoring.satellite_id(),
          validity(),
          keyword()
        ) ::
          {:ok, {OrbitParameterFit.t(), departure()}} | {:error, OrbitParameterFitError.t()}
  def fit_inertial_orbit_parameters_with_validity(samples, satellite, mode, opts \\ []) do
    with {:ok, sat} <- OrbitScoring.native_satellite(satellite),
         {:ok, samples} <- OrbitScoring.convert_all(samples, &native_sample/1),
         {:ok, options} <- native_options(Keyword.get(opts, :options, %OrbitParameterFitOptions{})) do
      decode(NIF.fit_inertial_orbit_parameters(samples, sat, initial_state(opts), options, mode))
    else
      {:error, _} = error -> decode(error)
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :fit_inertial_orbit_parameters) |> decode()
  end

  @doc "Fit a satellite's initial state and selected force parameters to Earth-fixed SP3 positions."
  @spec fit_sp3_ecef_orbit_parameters(SP3.t(), OrbitScoring.satellite_id(), keyword()) ::
          {:ok, OrbitParameterFit.t()} | {:error, OrbitParameterFitError.t()}
  def fit_sp3_ecef_orbit_parameters(product, satellite, opts \\ []) do
    with {:ok, {fit, nil}} <- fit_sp3_ecef_orbit_parameters_with_validity(product, satellite, :strict, opts),
         do: {:ok, fit}
  end

  @doc "Fit Earth-fixed SP3 positions under an explicit UT1 policy and return any departure."
  @spec fit_sp3_ecef_orbit_parameters_with_validity(SP3.t(), OrbitScoring.satellite_id(), validity(), keyword()) ::
          {:ok, {OrbitParameterFit.t(), departure()}} | {:error, OrbitParameterFitError.t()}
  def fit_sp3_ecef_orbit_parameters_with_validity(%SP3{handle: product}, satellite, mode, opts \\ []) do
    with {:ok, sat} <- OrbitScoring.native_satellite(satellite),
         {:ok, options} <- native_options(Keyword.get(opts, :options, %OrbitParameterFitOptions{})),
         {:ok, provider} <- native_orientation(Keyword.get(opts, :orientation_provider)) do
      decode(NIF.fit_sp3_ecef_orbit_parameters(product, sat, initial_state(opts), options, mode, provider))
    else
      {:error, _} = error -> decode(error)
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :fit_sp3_ecef_orbit_parameters) |> decode()
  end

  defp native_orientation(nil), do: {:ok, nil}
  defp native_orientation(%Iers2010EarthOrientationProvider{handle: handle}), do: {:ok, handle}
  defp native_orientation(provider), do: invalid_option(:orientation_provider, provider)

  defp initial_state(opts) do
    case Keyword.get(opts, :initial_state) do
      nil -> nil
      state -> Analytic.native_state(state)
    end
  end

  defp native_sample(%InertialPositionSample{} = sample) do
    with {:ok, epoch} <- PreciseEphemerisSample.epoch_to_nif(sample.epoch) do
      {:ok, %{epoch: epoch, position_gcrf_m: Analytic.native_vector(sample.position_gcrf_m)}}
    end
  end

  defp native_options(%OrbitParameterFitOptions{} = opts) do
    with {:ok, selectors} <- native_force_tokens(opts.forces),
         {:ok, forces} <- Forces.native_models(opts.additional_forces),
         {:ok, drag} <- native_drag(opts.drag),
         {:ok, weather} <- native_handle(:space_weather, opts.space_weather, SpaceWeather),
         {:ok, context} <- native_handle(:propagation_context, opts.propagation_context, PropagationContext),
         {:ok, policy} <- native_policy(opts.space_weather_policy) do
      {:ok,
       %{
         opts
         | forces: selectors,
           additional_forces: forces,
           drag: drag,
           space_weather: weather,
           space_weather_policy: policy,
           propagation_context: context,
           observation_sigma_m: optional_float(opts.observation_sigma_m),
           convergence_threshold: optional_float(opts.convergence_threshold),
           max_condition_number:
             if(opts.max_condition_number == :infinity, do: :infinity, else: optional_float(opts.max_condition_number))
       }}
    end
  end

  defp native_options(options), do: invalid_option(:options, options)

  defp native_force_tokens(nil), do: {:ok, nil}
  defp native_force_tokens(forces), do: Propagator.native_force_tokens(forces)

  defp native_drag(nil), do: {:ok, nil}

  defp native_drag(%Drag.Parameters{space_weather: %Drag.SpaceWeather{}} = drag), do: {:ok, Propagator.drag_map(drag)}

  defp native_drag(drag), do: invalid_option(:drag, drag)

  defp native_handle(_key, nil, _module), do: {:ok, nil}
  defp native_handle(_key, %module{handle: handle}, module), do: {:ok, handle}
  defp native_handle(key, value, _module), do: invalid_option(key, value)

  defp native_policy(nil), do: {:ok, nil}
  defp native_policy(%SpaceWeather.Policy{} = policy), do: {:ok, SpaceWeather.policy_to_native(policy)}

  defp native_policy(policy) do
    if Keyword.keyword?(policy),
      do: {:ok, SpaceWeather.policy_to_native(policy)},
      else: invalid_option(:space_weather_policy, policy)
  end

  defp invalid_option(key, value), do: {:error, {:invalid_input, {key, value}}}

  defp optional_float(nil), do: nil
  defp optional_float(value), do: value / 1.0

  defp decode({:error, _} = error), do: NifCall.decode(error, OrbitParameterFitError)

  defp decode({:ok, {fit, departure}}) do
    fit =
      struct!(OrbitParameterFit, %{
        fit
        | force_parameters: Enum.map(fit.force_parameters, &struct!(EstimatedForceParameter, &1)),
          named_force_parameters: Map.new(fit.named_force_parameters, &{&1.name, struct!(EstimatedForceParameter, &1)}),
          named_correlations:
            Map.new(Enum.zip(fit.parameter_names, fit.named_correlations), fn {name, row} ->
              {name, Map.new(Enum.zip(fit.parameter_names, row))}
            end),
          covariance: struct!(OrbitParameterCovariance, fit.covariance),
          residuals: Enum.map(fit.residuals, &struct!(OrbitRtnResidual, &1)),
          residual_stats: struct!(OrbitResidualStats, fit.residual_stats)
      })

    {:ok, {fit, departure}}
  end
end
