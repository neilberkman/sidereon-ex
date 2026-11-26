defmodule Sidereon.Forces.Ecom1SolarRadiationPressure do
  @moduledoc """
  First-generation CODE empirical solar radiation pressure.
  This struct compares by value.
  """

  alias Sidereon.Eclipse.EarthShadowModel
  alias Sidereon.Eclipse.ShadowFunction
  alias Sidereon.Forces
  alias Sidereon.Forces.Ecom1Coefficients
  alias Sidereon.Forces.PropagationError
  alias Sidereon.NIF
  alias Sidereon.Propagator.Analytic

  @enforce_keys [:coefficients]
  defstruct [
    :coefficients,
    moon_eclipse_enabled: nil,
    shadow_function: nil,
    earth_shadow_model: nil
  ]

  @type t :: %__MODULE__{
          coefficients: Ecom1Coefficients.t(),
          moon_eclipse_enabled: boolean() | nil,
          shadow_function: ShadowFunction.t() | nil,
          earth_shadow_model: EarthShadowModel.t() | nil
        }

  @doc "Construct and validate the force model."
  @spec new(Ecom1Coefficients.t()) :: {:ok, t()} | {:error, PropagationError.t()}
  def new(coefficients) do
    model = %__MODULE__{coefficients: coefficients}

    with {:ok, fields} <- Forces.decode(NIF.force_update_occultation(native(model), :defaults)),
         do: {:ok, struct!(model, fields)}
  end

  @doc "Return a model using the requested lunar occultation setting. Enabling it selects apparent-disc shadow."
  @spec with_moon_eclipse(t(), boolean()) :: t() | {:error, PropagationError.t()}
  def with_moon_eclipse(%__MODULE__{} = model, enabled) when is_boolean(enabled),
    do: Forces.update_occultation(model, {:moon_eclipse, enabled})

  @doc "Return a model using the requested Earth figure."
  @spec with_earth_shadow_model(t(), EarthShadowModel.t()) :: t()
  def with_earth_shadow_model(%__MODULE__{} = model, figure) when figure in [:spherical, :wgs84_oblate],
    do: %{model | earth_shadow_model: figure}

  @doc "Return a model using the requested shadow function. Conical shadow disables lunar occultation."
  @spec with_shadow_function(t(), ShadowFunction.t()) :: t() | {:error, PropagationError.t()}
  def with_shadow_function(%__MODULE__{} = model, function) when function in [:apparent_disc, :conical],
    do: Forces.update_occultation(model, {:shadow_function, function})

  @doc false
  @spec native(t()) :: tuple()
  def native(%__MODULE__{coefficients: coefficients} = model) do
    {:ecom1, Ecom1Coefficients.to_array(coefficients),
     Map.take(model, [:shadow_function, :earth_shadow_model, :moon_eclipse_enabled])}
  end

  @doc "Evaluate acceleration with explicit Sun coordinates in kilometres."
  @spec acceleration_with_sun(t(), Analytic.vector(), Analytic.vector(), Analytic.vector()) ::
          {:ok, Analytic.vector()} | {:error, PropagationError.t()}
  def acceleration_with_sun(%__MODULE__{} = model, position, velocity, sun) do
    Forces.decode(
      NIF.force_ecom1_acceleration_with_sun(
        native(model),
        Analytic.native_vector(position),
        Analytic.native_vector(velocity),
        Analytic.native_vector(sun)
      )
    )
  end

  @doc "Evaluate acceleration partials with explicit Sun coordinates in kilometres."
  @spec acceleration_partials_with_sun(t(), Analytic.vector(), Analytic.vector(), Analytic.vector()) ::
          {:ok, Forces.AccelerationPartials.t()} | {:error, PropagationError.t()}
  def acceleration_partials_with_sun(%__MODULE__{} = model, position, velocity, sun) do
    with {:ok, partials} <-
           Forces.decode(
             NIF.force_ecom1_acceleration_partials_with_sun(
               native(model),
               Analytic.native_vector(position),
               Analytic.native_vector(velocity),
               Analytic.native_vector(sun)
             )
           ) do
      {:ok, struct!(Forces.AccelerationPartials, partials)}
    end
  end

  @doc "Evaluate parameter partials with explicit Sun coordinates in kilometres."
  @spec parameter_partials_with_sun(t(), Analytic.vector(), Analytic.vector(), Analytic.vector()) ::
          {:ok, [Analytic.vector()]} | {:error, PropagationError.t()}
  def parameter_partials_with_sun(%__MODULE__{} = model, position, velocity, sun) do
    Forces.decode(
      NIF.force_ecom1_parameter_partials_with_sun(
        native(model),
        Analytic.native_vector(position),
        Analytic.native_vector(velocity),
        Analytic.native_vector(sun)
      )
    )
  end

  @doc "Evaluate acceleration with explicit Sun and Moon coordinates in kilometres."
  @spec acceleration_with_sun_moon(t(), Analytic.vector(), Analytic.vector(), Analytic.vector(), Analytic.vector()) ::
          {:ok, Analytic.vector()} | {:error, PropagationError.t()}
  def acceleration_with_sun_moon(%__MODULE__{} = model, position, velocity, sun, moon) do
    Forces.decode(
      NIF.force_ecom1_acceleration_with_sun_moon(
        native(model),
        Analytic.native_vector(position),
        Analytic.native_vector(velocity),
        Analytic.native_vector(sun),
        Analytic.native_vector(moon)
      )
    )
  end

  @doc "Evaluate acceleration partials with explicit Sun and Moon coordinates in kilometres."
  @spec acceleration_partials_with_sun_moon(
          t(),
          Analytic.vector(),
          Analytic.vector(),
          Analytic.vector(),
          Analytic.vector()
        ) :: {:ok, Forces.AccelerationPartials.t()} | {:error, PropagationError.t()}
  def acceleration_partials_with_sun_moon(%__MODULE__{} = model, position, velocity, sun, moon) do
    with {:ok, partials} <-
           Forces.decode(
             NIF.force_ecom1_acceleration_partials_with_sun_moon(
               native(model),
               Analytic.native_vector(position),
               Analytic.native_vector(velocity),
               Analytic.native_vector(sun),
               Analytic.native_vector(moon)
             )
           ) do
      {:ok, struct!(Forces.AccelerationPartials, partials)}
    end
  end

  @doc "Evaluate parameter partials with explicit Sun and Moon coordinates in kilometres."
  @spec parameter_partials_with_sun_moon(
          t(),
          Analytic.vector(),
          Analytic.vector(),
          Analytic.vector(),
          Analytic.vector()
        ) :: {:ok, [Analytic.vector()]} | {:error, PropagationError.t()}
  def parameter_partials_with_sun_moon(%__MODULE__{} = model, position, velocity, sun, moon) do
    Forces.decode(
      NIF.force_ecom1_parameter_partials_with_sun_moon(
        native(model),
        Analytic.native_vector(position),
        Analytic.native_vector(velocity),
        Analytic.native_vector(sun),
        Analytic.native_vector(moon)
      )
    )
  end
end
