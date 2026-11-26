defmodule Sidereon.Forces do
  @moduledoc """
  Inertial force evaluation and estimable parameters for numerical propagation.

  Models are evaluated at TDB seconds past J2000, with position in km,
  velocity in km/s and acceleration in km/s².
  """

  alias Sidereon.DeEphemeris
  alias Sidereon.Drag.Parameters
  alias Sidereon.Drag.SpaceWeather
  alias Sidereon.Forces.EarthRadiationPressure
  alias Sidereon.Forces.Ecom1SolarRadiationPressure
  alias Sidereon.Forces.Ecom2SolarRadiationPressure
  alias Sidereon.Forces.EmpiricalRtnAcceleration
  alias Sidereon.Forces.SolarRadiationPressure
  alias Sidereon.Forces.SphericalHarmonicGravity
  alias Sidereon.GNSS.Attitude.DybAxes
  alias Sidereon.NIF
  alias Sidereon.NifCall
  alias Sidereon.Propagator.Analytic
  alias Sidereon.Propagator.PropagationContext

  defmodule PropagationError do
    @moduledoc "A refusal from a force model or numerical propagator with its details."
    defstruct [:kind, :detail, :message]
    @type t :: %__MODULE__{kind: atom(), detail: map(), message: String.t()}
    defimpl String.Chars do
      def to_string(error), do: error.message
    end
  end

  defmodule ForceParameter do
    @moduledoc "A named estimable force coefficient in its model's units. This struct compares by value."
    @enforce_keys [:name, :value]
    defstruct [:name, :value]
    @type t :: %__MODULE__{name: String.t(), value: float()}
  end

  defmodule AccelerationPartials do
    @moduledoc "Row-major Jacobians with respect to position and velocity. This struct compares by value."
    @enforce_keys [:wrt_position, :wrt_velocity]
    defstruct [:wrt_position, :wrt_velocity]
    @type t :: %__MODULE__{wrt_position: [Analytic.vector()], wrt_velocity: [Analytic.vector()]}

    @doc "Return zero position and velocity partials."
    @spec zeros() :: t()
    def zeros, do: struct!(__MODULE__, NIF.force_partials_zeros())

    @doc "Return the given position partials with zero velocity partials."
    @spec position_only([Analytic.vector()]) :: t()
    def position_only([first, second, third]) do
      matrix = {Analytic.native_vector(first), Analytic.native_vector(second), Analytic.native_vector(third)}
      struct!(__MODULE__, NIF.force_partials_position_only(matrix))
    end
  end

  defmodule CompositeForceModel do
    @moduledoc "An ordered sum of force models. Each component retains its own estimable parameters."
    alias Sidereon.Forces

    @enforce_keys [:models]
    defstruct [:models]
    @type t :: %__MODULE__{models: [Forces.model()]}

    @doc "Return an empty composite."
    @spec new() :: t()
    def new, do: %__MODULE__{models: []}

    @doc "Append a model to the force evaluation order."
    @spec add(t(), Forces.model()) :: t()
    def add(%__MODULE__{models: models}, model), do: %__MODULE__{models: models ++ [model]}
  end

  @builtin_models [
    :two_body,
    :j2,
    :zonal,
    :third_body,
    :sun,
    :moon,
    :relativity,
    :solid_earth_tide,
    :solid_earth_pole_tide
  ]

  @typedoc "A concrete force model or an ordered composite."
  @type model ::
          :two_body
          | :j2
          | :zonal
          | :third_body
          | :sun
          | :moon
          | :relativity
          | :solid_earth_tide
          | :solid_earth_pole_tide
          | CompositeForceModel.t()
          | Ecom1SolarRadiationPressure.t()
          | Ecom2SolarRadiationPressure.t()
          | EmpiricalRtnAcceleration.t()
          | SolarRadiationPressure.t()
          | EarthRadiationPressure.t()
          | SphericalHarmonicGravity.t()
          | Parameters.t()

  @typedoc "Body ephemeris for force evaluation. The default uses analytic Sun and Moon positions."
  @type options :: [context: PropagationContext.t(), de_ephemeris: DeEphemeris.t()]

  @doc "Return the model's estimable parameters in evaluation order."
  @spec parameters(model()) :: {:ok, [ForceParameter.t()]} | {:error, PropagationError.t()}
  def parameters(model) do
    with {:ok, handle} <- native_model(model) do
      {:ok, Enum.map(NIF.force_parameters(handle), &struct!(ForceParameter, &1))}
    end
  end

  @doc "Return the number of estimable parameters."
  @spec parameter_count(model()) :: {:ok, non_neg_integer()} | {:error, PropagationError.t()}
  def parameter_count(model) do
    with {:ok, handle} <- native_model(model), do: {:ok, NIF.force_parameter_count(handle)}
  end

  @doc "Evaluate the acceleration at the model's parameter values."
  @spec acceleration(model(), Analytic.state(), options()) ::
          {:ok, Analytic.vector()} | {:error, PropagationError.t()}
  def acceleration(model, state, opts \\ []) do
    with {:ok, handle} <- native_model(model) do
      NIF.force_acceleration(handle, Analytic.native_state(state), native_context(opts))
      |> decode()
    end
  end

  @doc "Evaluate the acceleration in km/s² at parameter values in model order."
  @spec acceleration_with_parameters(model(), [number()], Analytic.state(), options()) ::
          {:ok, Analytic.vector()} | {:error, PropagationError.t()}
  def acceleration_with_parameters(model, parameters, state, opts \\ []) do
    with {:ok, handle} <- native_model(model) do
      NIF.force_acceleration_with_parameters(
        handle,
        floats(parameters),
        Analytic.native_state(state),
        native_context(opts)
      )
      |> decode()
    end
  end

  @doc "Evaluate the position and velocity partial derivatives of acceleration."
  @spec acceleration_partials(model(), [number()], Analytic.state(), options()) ::
          {:ok, AccelerationPartials.t()} | {:error, PropagationError.t()}
  def acceleration_partials(model, parameters, state, opts \\ []) do
    with {:ok, handle} <- native_model(model),
         {:ok, partials} <-
           NIF.force_acceleration_partials(
             handle,
             floats(parameters),
             Analytic.native_state(state),
             native_context(opts)
           )
           |> decode() do
      {:ok, struct!(AccelerationPartials, partials)}
    end
  end

  @doc "Evaluate one acceleration derivative per parameter, in model order."
  @spec parameter_partials(model(), [number()], Analytic.state(), options()) ::
          {:ok, [Analytic.vector()]} | {:error, PropagationError.t()}
  def parameter_partials(model, parameters, state, opts \\ []) do
    with {:ok, handle} <- native_model(model) do
      NIF.force_parameter_partials(handle, floats(parameters), Analytic.native_state(state), native_context(opts))
      |> decode()
    end
  end

  @doc false
  @spec native_model(model()) :: {:ok, reference()} | {:error, PropagationError.t()}
  def native_model(model) when model in @builtin_models, do: decode(NIF.force_builtin_model(model))

  def native_model(%SphericalHarmonicGravity{handle: handle}), do: {:ok, handle}

  def native_model(%Parameters{space_weather: %SpaceWeather{}} = parameters) do
    NIF.force_drag_model(Sidereon.Propagator.drag_map(parameters)) |> decode()
  rescue
    error in ErlangError -> NifCall.error(error, __STACKTRACE__, :force_drag_model) |> decode()
  end

  def native_model(%CompositeForceModel{models: models}) do
    with {:ok, handles} <- native_models(models), do: {:ok, NIF.force_composite(handles)}
  end

  def native_model(%module{} = model)
      when module in [
             Ecom1SolarRadiationPressure,
             Ecom2SolarRadiationPressure,
             EmpiricalRtnAcceleration,
             SolarRadiationPressure,
             EarthRadiationPressure
           ] do
    model |> module.native() |> NIF.force_model_new() |> decode()
  rescue
    error in ErlangError ->
      NifCall.error(error, __STACKTRACE__, :force_model_new) |> decode()
  end

  def native_model(model) do
    {:error, %PropagationError{kind: :invalid_input, detail: %{model: model}, message: "Invalid force model"}}
  end

  @doc false
  @spec update_occultation(model(), tuple()) :: model() | {:error, PropagationError.t()}
  def update_occultation(%module{} = model, change) do
    case decode(NIF.force_update_occultation(module.native(model), change)) do
      {:ok, fields} -> struct!(model, fields)
      {:error, _} = error -> error
    end
  end

  @doc false
  @spec native_models([model()]) :: {:ok, [reference()]} | {:error, PropagationError.t()}
  def native_models(models) when is_list(models) do
    result =
      Enum.reduce_while(models, {:ok, []}, fn model, {:ok, acc} ->
        case native_model(model) do
          {:ok, handle} -> {:cont, {:ok, [handle | acc]}}
          {:error, _} = error -> {:halt, error}
        end
      end)

    with {:ok, handles} <- result, do: {:ok, Enum.reverse(handles)}
  end

  def native_models(models), do: decode({:error, {:invalid_input, {:additional_forces, models}}})

  @doc false
  @spec native_context(options()) :: reference() | nil
  def native_context(opts) do
    case {Keyword.get(opts, :context), Keyword.get(opts, :de_ephemeris)} do
      {nil, nil} ->
        nil

      {%PropagationContext{handle: handle}, nil} ->
        handle

      {context, %DeEphemeris{} = ephemeris} ->
        context = context || PropagationContext.new()
        PropagationContext.with_de_ephemeris(context, ephemeris).handle
    end
  end

  @doc false
  @spec decode(term()) :: term()
  def decode(result), do: NifCall.decode(result, PropagationError)

  @doc false
  @spec floats([number()]) :: [float()]
  def floats(values), do: Enum.map(values, &(&1 / 1.0))

  defmodule EcomGeometry do
    @moduledoc "Solar axes, orbit angles in radians and lighting ratio for the ECOM models. This struct compares by value."
    @enforce_keys [:dyb, :delta_u_rad, :argument_of_latitude_rad, :lighting_ratio]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            dyb: DybAxes.t(),
            delta_u_rad: float() | nil,
            argument_of_latitude_rad: float() | nil,
            lighting_ratio: float()
          }
  end

  @doc "Evaluate ECOM geometry with explicit Sun position and an oblate Earth."
  @spec ecom_geometry(Analytic.vector(), Analytic.vector(), Analytic.vector()) ::
          {:ok, EcomGeometry.t()} | {:error, PropagationError.t()}
  def ecom_geometry(position, velocity, sun) do
    NIF.force_ecom_geometry(
      Analytic.native_vector(position),
      Analytic.native_vector(velocity),
      Analytic.native_vector(sun)
    )
    |> decode_geometry()
  end

  @doc "Evaluate ECOM geometry with an explicit Earth figure and optional Moon position."
  @spec ecom_geometry_with_shadow(
          Analytic.vector(),
          Analytic.vector(),
          Analytic.vector(),
          Analytic.vector() | nil,
          atom()
        ) ::
          {:ok, EcomGeometry.t()} | {:error, PropagationError.t()}
  def ecom_geometry_with_shadow(position, velocity, sun, moon, earth) do
    NIF.force_ecom_geometry_with_shadow(
      Analytic.native_vector(position),
      Analytic.native_vector(velocity),
      Analytic.native_vector(sun),
      if(moon, do: Analytic.native_vector(moon)),
      earth
    )
    |> decode_geometry()
  end

  @doc "Return the number of ECOM1 coefficients."
  @spec ecom1_coefficient_count() :: pos_integer()
  def ecom1_coefficient_count, do: NIF.force_ecom1_coefficient_count()

  @doc "Return the number of ECOM2 D2B1 coefficients."
  @spec ecom2_d2b1_coefficient_count() :: pos_integer()
  def ecom2_d2b1_coefficient_count, do: NIF.force_ecom2_d2b1_coefficient_count()

  @doc "Return the number of ECOM2 D4B1 coefficients."
  @spec ecom2_d4b1_coefficient_count() :: pos_integer()
  def ecom2_d4b1_coefficient_count, do: NIF.force_ecom2_d4b1_coefficient_count()

  defp decode_geometry(result) do
    with {:ok, fields} <- decode(result) do
      {:ok, struct!(EcomGeometry, %{fields | dyb: struct!(DybAxes, fields.dyb)})}
    end
  end
end
