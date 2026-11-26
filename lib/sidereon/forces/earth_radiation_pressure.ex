defmodule Sidereon.Forces.EarthRadiationPressure do
  @moduledoc """
  Earth albedo and infrared radiation pressure.
  This struct compares by value.
  """

  alias Sidereon.Forces
  alias Sidereon.Forces.PropagationError
  alias Sidereon.NIF
  alias Sidereon.Propagator.Analytic

  @enforce_keys [:cr, :area_to_mass_m2_kg]
  defstruct [:cr, :area_to_mass_m2_kg, moon_eclipse_enabled: nil]
  @type t :: %__MODULE__{cr: float(), area_to_mass_m2_kg: float(), moon_eclipse_enabled: boolean() | nil}

  @doc "Construct and validate the force model."
  @spec new(number(), number()) :: {:ok, t()} | {:error, PropagationError.t()}
  def new(cr, area_to_mass_m2_kg) do
    model = %__MODULE__{cr: cr / 1.0, area_to_mass_m2_kg: area_to_mass_m2_kg / 1.0}

    with {:ok, fields} <- Forces.decode(NIF.force_update_occultation(native(model), :defaults)),
         do: {:ok, struct!(model, fields)}
  end

  @doc "Return a model using the requested lunar occultation setting."
  @spec with_moon_eclipse(t(), boolean()) :: t()
  def with_moon_eclipse(%__MODULE__{} = model, enabled) when is_boolean(enabled),
    do: %{model | moon_eclipse_enabled: enabled}

  @doc false
  @spec native(t()) :: tuple()
  def native(%__MODULE__{cr: cr, area_to_mass_m2_kg: area_to_mass_m2_kg} = model) do
    {:earth_radiation_pressure, cr, area_to_mass_m2_kg, model.moon_eclipse_enabled}
  end

  @doc "Evaluate acceleration with explicit Sun and Moon coordinates in kilometres."
  @spec acceleration_with_sun_moon(t(), Analytic.state(), Analytic.vector(), Analytic.vector()) ::
          {:ok, Analytic.vector()} | {:error, PropagationError.t()}
  def acceleration_with_sun_moon(%__MODULE__{} = model, state, sun, moon) do
    Forces.decode(
      NIF.force_earth_acceleration_with_sun_moon(
        native(model),
        Analytic.native_state(state),
        Analytic.native_vector(sun),
        Analytic.native_vector(moon)
      )
    )
  end
end
