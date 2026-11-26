defmodule Sidereon.Forces.SolarRadiationPressure do
  @moduledoc """
  Cannonball solar radiation pressure.
  This struct compares by value.
  """

  alias Sidereon.Eclipse.EarthShadowModel
  alias Sidereon.Eclipse.ShadowFunction
  alias Sidereon.Forces
  alias Sidereon.Forces.PropagationError
  alias Sidereon.NIF
  alias Sidereon.Propagator.Analytic

  @enforce_keys [:cr, :area_to_mass_m2_kg]
  defstruct [
    :cr,
    :area_to_mass_m2_kg,
    moon_eclipse_enabled: nil,
    shadow_function: nil,
    earth_shadow_model: nil
  ]

  @type t :: %__MODULE__{
          cr: float(),
          area_to_mass_m2_kg: float(),
          moon_eclipse_enabled: boolean() | nil,
          shadow_function: ShadowFunction.t() | nil,
          earth_shadow_model: EarthShadowModel.t() | nil
        }

  @doc "Construct and validate the force model."
  @spec new(number(), number()) :: {:ok, t()} | {:error, PropagationError.t()}
  def new(cr, area_to_mass_m2_kg) do
    model = %__MODULE__{cr: cr / 1.0, area_to_mass_m2_kg: area_to_mass_m2_kg / 1.0}

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
  def native(%__MODULE__{cr: cr, area_to_mass_m2_kg: area_to_mass_m2_kg} = model) do
    {:solar_radiation_pressure, cr, area_to_mass_m2_kg,
     Map.take(model, [:shadow_function, :earth_shadow_model, :moon_eclipse_enabled])}
  end

  @doc "Return the estimable reflectivity coefficient name."
  @spec cr_parameter() :: String.t()
  def cr_parameter, do: NIF.force_cr_parameter()

  @doc "Evaluate acceleration with explicit Sun and Moon coordinates in kilometres."
  @spec acceleration_with_sun_moon(t(), Analytic.vector(), Analytic.vector(), Analytic.vector()) ::
          {:ok, Analytic.vector()} | {:error, PropagationError.t()}
  def acceleration_with_sun_moon(%__MODULE__{} = model, position, sun, moon) do
    Forces.decode(
      NIF.force_solar_acceleration_with_sun_moon(
        native(model),
        Analytic.native_vector(position),
        Analytic.native_vector(sun),
        Analytic.native_vector(moon)
      )
    )
  end

  @doc "Return the reference astronomical unit in kilometres."
  @spec au_km(t()) :: {:ok, float()} | {:error, PropagationError.t()}
  def au_km(%__MODULE__{} = model), do: Forces.decode(NIF.force_solar_au_km(model.cr, model.area_to_mass_m2_kg))
end
