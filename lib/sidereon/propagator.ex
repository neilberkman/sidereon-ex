defmodule Sidereon.Propagator do
  @moduledoc """
  High-precision numerical orbit propagation.

  Supports high-order adaptive numerical integration (DP54)
  of orbital states using various force models via Rust NIF.
  """

  alias __MODULE__.DenseOutput
  alias __MODULE__.IntegratorOptions
  alias __MODULE__.PropagationResult
  alias Sidereon.Drag.Parameters
  alias Sidereon.Forces
  alias Sidereon.Forces.EarthRadiationPressure
  alias Sidereon.Forces.SolarRadiationPressure
  alias Sidereon.NIF
  alias Sidereon.NifCall
  alias Sidereon.Propagator.Analytic
  alias Sidereon.Propagator.PropagationContext
  alias Sidereon.SpaceWeather

  @type vec3 :: {float(), float(), float()}
  @type state :: {r :: vec3(), v :: vec3()}
  @type covariance_node :: %{
          state: %{epoch_tdb_seconds: float(), position_km: vec3(), velocity_km_s: vec3()},
          covariance: [[float()]],
          frame: String.t()
        }

  @doc """
  Adaptive step propagation using Dormand-Prince 5(4) via Rust NIF.
  Returns the state at exactly `t_end`.

  ## Options
    * `:tolerance` - Integration tolerance (default: 1.0e-12)
    * `:forces` - List of active force models: `[:twobody, :j2]`,
      `[:composite, :j2_j6, :third_body, {:srp, cr, area_to_mass_m2_kg}, :relativity]`,
      `[:composite, {:geopotential, degree, order}]`,
      `[:composite, :solid_earth_tide, :solid_earth_pole_tide]`,
      or `[:earth_phase_a]` (default: `[:twobody]`)
    * `:drag` - optional `%Sidereon.Drag.Parameters{}` drag model
    * `:space_weather_table` - optional `%Sidereon.SpaceWeather{}` used with `:drag`
    * `:space_weather_policy` - the `Sidereon.SpaceWeather.Policy` (or keyword
      list) the table is read under; without it the default policy, which
      refuses Ap values the file does not state and rows with no flux
      observation
    * `:epoch_tdb_seconds` - initial epoch for table-backed drag (default: 0.0)
  """
  @spec propagate(state(), float(), keyword()) :: {:ok, state()} | {:error, any()}
  def propagate({r, v}, dt, opts \\ []) do
    tol = Keyword.get(opts, :tolerance, 1.0e-12)
    forces = force_tokens(opts)

    case {Keyword.get(opts, :drag), Keyword.get(opts, :space_weather_table)} do
      {nil, nil} ->
        Sidereon.NIF.propagate_dp54(r, v, dt * 1.0, forces, tol, tol)

      {%Parameters{} = drag, nil} ->
        Sidereon.NIF.propagate_dp54_with_drag(r, v, dt * 1.0, forces, tol, tol, drag_map(drag))

      {%Parameters{} = drag, %SpaceWeather{handle: handle}} ->
        Sidereon.NIF.propagate_dp54_with_drag_and_space_weather(
          r,
          v,
          Keyword.get(opts, :epoch_tdb_seconds, 0.0) / 1.0,
          dt * 1.0,
          forces,
          tol,
          tol,
          drag_map(drag),
          handle,
          space_weather_policy(opts)
        )

      {nil, %SpaceWeather{}} ->
        {:error, :space_weather_source_without_drag}
    end
  end

  @doc """
  Propagate a Cartesian state and its 6x6 covariance to requested TDB epochs.

  `initial_state` is `{position_km, velocity_km_s}`. `epochs_tdb_seconds` are
  absolute TDB seconds in the same scale as `:epoch_tdb_seconds`. The
  `:forces` option selects the built-in forces, including `:twobody_j2` for
  two-body gravity with J2.
  """
  @spec propagate_covariance(state(), [[number()]], [number()], keyword()) ::
          {:ok, [covariance_node()]} | {:error, term()}
  def propagate_covariance({r, v}, covariance, epochs_tdb_seconds, opts \\ [])
      when is_list(covariance) and is_list(epochs_tdb_seconds) do
    initial_epoch = Keyword.get(opts, :epoch_tdb_seconds, 0.0) / 1.0

    Sidereon.NIF.propagate_covariance(
      {initial_epoch, vec3(r), vec3(v)},
      rows(covariance),
      Enum.map(epochs_tdb_seconds, &(&1 / 1.0)),
      covariance_options(opts)
    )
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :propagate_covariance)
  end

  defp space_weather_policy(opts) do
    case Keyword.get(opts, :space_weather_policy) do
      nil -> nil
      policy -> SpaceWeather.policy_to_native(policy)
    end
  end

  @doc false
  @spec drag_map(Parameters.t()) :: map()
  def drag_map(%Parameters{} = drag) do
    %{
      bc_factor_m2_kg: drag.bc_factor_m2_kg,
      f107: drag.space_weather.f107,
      f107a: drag.space_weather.f107a,
      ap: drag.space_weather.ap,
      cutoff_altitude_km: drag.cutoff_altitude_km
    }
  end

  defp covariance_options(opts, forces \\ nil) do
    tolerance = Keyword.get(opts, :tolerance, 1.0e-12) / 1.0

    %{
      input_frame: frame(Keyword.get(opts, :input_frame, :inertial)),
      output_frame: frame(Keyword.get(opts, :output_frame, :inertial)),
      process_noise: process_noise(Keyword.get(opts, :process_noise, :none)),
      forces: forces || force_tokens(opts),
      integrator: Keyword.get(opts, :integrator, :dp54) |> to_string(),
      abs_tol: Keyword.get(opts, :abs_tol, tolerance) / 1.0,
      rel_tol: Keyword.get(opts, :rel_tol, tolerance) / 1.0,
      min_step: Keyword.get(opts, :min_step, 1.0e-6) / 1.0,
      max_step: Keyword.get(opts, :max_step, 300.0) / 1.0,
      initial_step: Keyword.get(opts, :initial_step, 1.0) / 1.0,
      max_steps: Keyword.get(opts, :max_steps, 100_000),
      dense_output: Keyword.get(opts, :dense_output, false)
    }
  end

  defp frame(:eci), do: "inertial"
  defp frame(:inertial), do: "inertial"
  defp frame(:rtn), do: "rtn"
  defp frame(value) when is_binary(value), do: value

  defp process_noise(:none) do
    %{
      kind: "none",
      q_radial_km2_s3: nil,
      q_transverse_km2_s3: nil,
      q_normal_km2_s3: nil
    }
  end

  defp process_noise({:rtn_acceleration_psd, radial, transverse, normal}) do
    %{
      kind: "rtn_acceleration_psd",
      q_radial_km2_s3: radial / 1.0,
      q_transverse_km2_s3: transverse / 1.0,
      q_normal_km2_s3: normal / 1.0
    }
  end

  defp process_noise(%{kind: _} = noise), do: noise

  @doc false
  @spec force_token(term()) :: String.t()
  def force_token({:srp, cr, area_to_mass_m2_kg}) when is_number(cr) and is_number(area_to_mass_m2_kg) do
    "srp:#{cr / 1.0}:#{area_to_mass_m2_kg / 1.0}"
  end

  def force_token(%SolarRadiationPressure{} = model) do
    "srp:#{model.cr}:#{model.area_to_mass_m2_kg}:#{model.shadow_function}:#{model.earth_shadow_model}:#{model.moon_eclipse_enabled}"
  end

  def force_token(%EarthRadiationPressure{} = model) do
    "earth_radiation_pressure:#{model.cr}:#{model.area_to_mass_m2_kg}:#{model.moon_eclipse_enabled}"
  end

  def force_token({:geopotential, degree, order}) when is_integer(degree) and is_integer(order) do
    "geopotential:#{degree}:#{order}"
  end

  def force_token({:spherical_harmonic, degree, order}) when is_integer(degree) and is_integer(order) do
    "spherical_harmonic:#{degree}:#{order}"
  end

  def force_token({:egm96, degree, order}) when is_integer(degree) and is_integer(order) do
    "egm96:#{degree}:#{order}"
  end

  def force_token({:earth_phase_b, degree, order}) when is_integer(degree) and is_integer(order) do
    "earth_phase_b:#{degree}:#{order}"
  end

  def force_token(:solid_earth_tide), do: "solid_earth_tide"

  def force_token({:solid_earth_tide, tide_system}) when tide_system in [:tide_free, :zero_tide, :mean_tide],
    do: "solid_earth_tide:#{tide_system}"

  def force_token(:solid_earth_pole_tide), do: "solid_earth_pole_tide"

  def force_token(value), do: to_string(value)

  defp rows(matrix), do: Enum.map(matrix, fn row -> Enum.map(row, &(&1 / 1.0)) end)
  defp vec3({x, y, z}), do: {x / 1.0, y / 1.0, z / 1.0}

  defmodule IntegratorOptions do
    @moduledoc "Step and error controls for numerical propagation. This struct compares by value."
    alias Sidereon.NIF

    @enforce_keys [:abs_tol, :rel_tol, :min_step, :max_step, :initial_step, :max_steps]
    defstruct [:abs_tol, :rel_tol, :min_step, :max_step, :initial_step, :max_steps, dense_output: false]

    @type t :: %__MODULE__{
            abs_tol: float(),
            rel_tol: float(),
            min_step: float(),
            max_step: float(),
            initial_step: float(),
            max_steps: non_neg_integer(),
            dense_output: boolean()
          }

    @doc "Return the default numerical integration settings."
    @spec default() :: t()
    def default, do: struct!(__MODULE__, NIF.integration_defaults())
  end

  defmodule VariationalEpoch do
    @moduledoc "A TDB epoch and its elapsed TT since the initial epoch. This struct compares by value."
    alias Sidereon.NIF

    @enforce_keys [:tdb_j2000_s, :elapsed_tt_s]
    defstruct [:tdb_j2000_s, :elapsed_tt_s]
    @type t :: %__MODULE__{tdb_j2000_s: float(), elapsed_tt_s: float()}

    @doc "Resolve elapsed TT from an initial and a requested TDB epoch."
    @spec from_tdb_seconds(number(), number()) :: t()
    def from_tdb_seconds(initial_tdb_j2000_s, tdb_j2000_s) do
      struct!(__MODULE__, NIF.variational_epoch_from_tdb_seconds(initial_tdb_j2000_s / 1.0, tdb_j2000_s / 1.0))
    end
  end

  defmodule VariationalEquations do
    @moduledoc """
    A force model, its parameter values, and zero-based indices of the parameters whose
    sensitivity columns are requested.
    """
    alias Sidereon.Forces

    @enforce_keys [:force, :parameters, :sensitivity_parameters]
    defstruct [:force, :parameters, :sensitivity_parameters]
    @type t :: %__MODULE__{force: Forces.model(), parameters: [number()], sensitivity_parameters: [non_neg_integer()]}
  end

  defmodule VariationalState do
    @moduledoc "A propagated state and row-major state transition and sensitivity matrices. This struct compares by value."
    @enforce_keys [:state, :state_transition, :sensitivity]
    defstruct [:state, :state_transition, :sensitivity]
    @type t :: %__MODULE__{state: Analytic.state(), state_transition: [[float()]], sensitivity: [[float()]]}
  end

  @doc """
  Propagate an inertial state to absolute TDB epochs, integrating over TT.

  The :forces list selects the built-in configuration. The :additional_forces
  list accepts the same force objects as an orbit parameter fit. The additional
  forces are evaluated in list order after the built-in configuration and drag.
  Select :dp54 or :rk4 with :integrator and
  pass an IntegratorOptions struct under :integration. Set :drag and
  :space_weather_table for atmospheric drag or :de_ephemeris for Sun and Moon positions.
  Any tide model in :forces or :additional_forces requires an explicit :context
  with a body-fixed frame provider.
  """
  @spec propagate_state(Analytic.state(), [number()], keyword()) ::
          {:ok, [Analytic.state()]} | {:error, Forces.PropagationError.t()}
  def propagate_state(initial, epochs_tdb_seconds, opts \\ []) do
    with {:ok, options} <- trajectory_options(opts) do
      NIF.propagate_state_nodes(
        Analytic.native_state(initial),
        Forces.floats(epochs_tdb_seconds),
        options
      )
      |> Forces.decode()
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :propagate_state_nodes) |> Forces.decode()
  end

  defmodule DenseOutput do
    @moduledoc "Continuous GCRF position and velocity from the accepted steps of a DP5(4) integration arc."

    alias Sidereon.Propagator.DenseOutputError

    @enforce_keys [:handle]
    defstruct [:handle]
    @opaque t :: %__MODULE__{handle: reference()}

    @doc "Evaluate the GCRF state at an absolute TDB epoch within the integration arc."
    @spec eval(t(), number()) :: {:ok, Analytic.state()} | {:error, DenseOutputError.t()}
    def eval(%__MODULE__{handle: handle}, epoch) do
      case NIF.dense_output_eval(handle, epoch / 1.0) do
        {:ok, _} = result -> result
        {:error, fields} -> {:error, struct!(DenseOutputError, fields)}
      end
    end

    @doc "Return the earliest and latest covered TDB epochs, or nil for an empty arc."
    @spec coverage(t()) :: {float(), float()} | nil
    def coverage(%__MODULE__{handle: handle}), do: NIF.dense_output_coverage(handle)
  end

  defmodule DenseOutputError do
    @moduledoc "A refusal from continuous numerical output with the epoch and range details when available."
    defstruct [:kind, :detail, :message]
    @type t :: %__MODULE__{kind: atom(), detail: map(), message: String.t()}

    defimpl String.Chars do
      def to_string(error), do: error.message
    end
  end

  defmodule PropagationStats do
    @moduledoc "Accepted steps, rejected attempts and derivative evaluations. This struct compares by value."

    @enforce_keys [:accepted_steps, :rejected_steps, :evaluations]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            accepted_steps: non_neg_integer(),
            rejected_steps: non_neg_integer(),
            evaluations: non_neg_integer()
          }
  end

  defmodule PropagationResult do
    @moduledoc """
    Final state, emitted points in integration order, work counters, optional continuous output,
    and any UT1 coverage departure. Event records are empty for the built-in integrators.
    """

    alias Sidereon.Propagator.DenseOutput
    alias Sidereon.Propagator.PropagationStats

    @enforce_keys [:final_state, :points, :events, :stats, :dense, :ut1_degraded]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            final_state: Analytic.state(),
            points: [Analytic.state()],
            events: [],
            stats: PropagationStats.t(),
            dense: DenseOutput.t() | nil,
            ut1_degraded: atom() | nil
          }
  end

  @doc """
  Propagate a GCRF state to an absolute TDB epoch and return the full integration result.

  Use the same options as propagate_state/3, including a :context with a
  body-fixed frame provider for tide forces. Enable dense_output in the
  IntegratorOptions passed under :integration to retain the DP5(4)
  interpolant and all accepted step endpoints.
  RK4 returns nil for dense output.
  """
  @spec propagate_to_with_context(Analytic.state(), number(), keyword()) ::
          {:ok, PropagationResult.t()} | {:error, Forces.PropagationError.t()}
  def propagate_to_with_context(initial, target_tdb_seconds, opts \\ []) do
    with {:ok, options} <- trajectory_options(opts),
         {:ok, result} <-
           initial
           |> Analytic.native_state()
           |> NIF.propagate_to_with_context(target_tdb_seconds / 1.0, options)
           |> Forces.decode() do
      dense = if result.dense, do: %DenseOutput{handle: result.dense}
      stats = struct!(__MODULE__.PropagationStats, result.stats)
      {:ok, struct!(PropagationResult, %{result | dense: dense, stats: stats})}
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :propagate_to_with_context) |> Forces.decode()
  end

  defp trajectory_options(opts) do
    with :ok <- supported_options(opts, [:force_model, :mu_km3_s2]),
         {:ok, forces} <- native_force_tokens(Keyword.get(opts, :forces, [:twobody])),
         {:ok, additional} <- Forces.native_models(Keyword.get(opts, :additional_forces, [])) do
      {:ok,
       %{
         propagation: builtin_propagation_options(opts, forces),
         context: Forces.native_context(opts),
         additional_forces: additional
       }}
    end
  end

  defp force_tokens(opts), do: Enum.map(Keyword.get(opts, :forces, [:twobody]), &force_token/1)

  @doc false
  @spec native_force_tokens(term()) :: {:ok, [String.t()]} | {:error, Forces.PropagationError.t()}
  def native_force_tokens(selectors) when is_list(selectors) do
    {:ok, Enum.map(selectors, &native_force_token/1)}
  end

  def native_force_tokens(selectors), do: Forces.decode({:error, {:invalid_input, {:forces, selectors}}})

  defp native_force_token(selector) do
    force_token(selector)
  rescue
    Protocol.UndefinedError -> inspect(selector)
  end

  defp supported_options(opts, unsupported) do
    case Keyword.take(opts, unsupported) do
      [] -> :ok
      [{key, _} | _] -> Forces.decode({:error, {:unsupported_option, key}})
    end
  end

  @doc """
  Integrate an inertial state, its state transition matrix and its force parameter sensitivities.

  Both matrices are relative to the initial epoch and returned in row-major order.
  The :integrator, :integration and :de_ephemeris options configure the calculation.
  """
  @spec propagate_variational(Analytic.state(), [VariationalEpoch.t()], VariationalEquations.t(), keyword()) ::
          {:ok, [VariationalState.t()]} | {:error, Forces.PropagationError.t()}
  def propagate_variational(initial, epochs, %VariationalEquations{} = equations, opts \\ []) do
    with {:ok, force} <- Forces.native_model(equations.force),
         {:ok, states} <-
           NIF.propagate_variational_states(
             Analytic.native_state(initial),
             epochs,
             %{equations | force: force, parameters: Forces.floats(equations.parameters)},
             Keyword.get(opts, :integrator, :dp54),
             Keyword.get_lazy(opts, :integration, &IntegratorOptions.default/0),
             Forces.native_context(opts)
           )
           |> Forces.decode() do
      {:ok, Enum.map(states, &struct!(VariationalState, &1))}
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :propagate_variational_states) |> Forces.decode()
  end

  @doc """
  Propagate a state and covariance to absolute TDB epochs with shared orientation and ephemeris inputs.
  A covariance with dimensions other than 6×6 returns a `PropagationError` of kind `:invalid_dimensions`.
  """
  @spec propagate_covariance_with_context(state(), [[number()]], [number()], PropagationContext.t(), keyword()) ::
          {:ok, [covariance_node()]} | {:error, Forces.PropagationError.t()}
  def propagate_covariance_with_context({r, v}, covariance, epochs, %PropagationContext{handle: context}, opts \\ []) do
    with {:ok, forces} <- native_force_tokens(Keyword.get(opts, :forces, [:twobody])) do
      initial_epoch = Keyword.get(opts, :epoch_tdb_seconds, 0.0) / 1.0

      NIF.propagate_covariance_with_context(
        {initial_epoch, vec3(r), vec3(v)},
        rows(covariance),
        Forces.floats(epochs),
        covariance_options(opts, forces),
        context
      )
      |> Forces.decode()
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :propagate_covariance_with_context) |> Forces.decode()
  end

  @doc """
  Propagate an inertial state and covariance across a relative span in seconds.
  Use :forces for built-in gravity and perturbations, :integration for tolerances,
  and the context argument for Earth orientation and JPL DE ephemerides.
  A covariance with dimensions other than 6×6 returns a `PropagationError` of kind `:invalid_dimensions`.
  """
  @spec propagate_state_with_covariance_with_context(
          Analytic.state(),
          [[number()]],
          number(),
          PropagationContext.t(),
          keyword()
        ) ::
          {:ok, {Analytic.state(), [[float()]]}} | {:error, Forces.PropagationError.t()}
  def propagate_state_with_covariance_with_context(
        initial,
        covariance,
        span,
        %PropagationContext{handle: context},
        opts \\ []
      ) do
    with :ok <- supported_options(opts, [:force_model, :mu_km3_s2, :additional_forces, :de_ephemeris, :context]),
         {:ok, forces} <- native_force_tokens(Keyword.get(opts, :forces, [:twobody])) do
      NIF.propagate_state_with_covariance_with_context(
        Analytic.native_state(initial),
        rows(covariance),
        span / 1.0,
        builtin_propagation_options(opts, forces),
        context
      )
      |> Forces.decode()
    end
  rescue
    e in ErlangError ->
      NifCall.error(e, __STACKTRACE__, :propagate_state_with_covariance_with_context) |> Forces.decode()
  end

  @doc """
  Evaluate the numerical state transition matrix at an absolute TDB epoch.
  Use :forces for built-in gravity and perturbations, :integration for tolerances,
  and the context argument for Earth orientation and JPL DE ephemerides.
  """
  @spec state_transition_matrix_to_with_context(Analytic.state(), number(), PropagationContext.t(), keyword()) ::
          {:ok, [[float()]]} | {:error, Forces.PropagationError.t()}
  def state_transition_matrix_to_with_context(initial, epoch, %PropagationContext{handle: context}, opts \\ []) do
    with :ok <- supported_options(opts, [:force_model, :mu_km3_s2, :additional_forces, :de_ephemeris, :context]),
         {:ok, forces} <- native_force_tokens(Keyword.get(opts, :forces, [:twobody])) do
      NIF.state_transition_matrix_to_with_context(
        Analytic.native_state(initial),
        epoch / 1.0,
        builtin_propagation_options(opts, forces),
        context
      )
      |> Forces.decode()
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :state_transition_matrix_to_with_context) |> Forces.decode()
  end

  defp builtin_propagation_options(opts, forces) do
    drag = Keyword.get(opts, :drag)
    table = Keyword.get(opts, :space_weather_table)

    %{
      forces: forces,
      integrator: Keyword.get(opts, :integrator, :dp54),
      integration: Keyword.get_lazy(opts, :integration, &IntegratorOptions.default/0),
      drag: if(drag, do: drag_map(drag)),
      space_weather: if(table, do: table.handle),
      space_weather_policy: space_weather_policy(opts)
    }
  end
end
