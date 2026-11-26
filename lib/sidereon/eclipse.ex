defmodule Sidereon.Eclipse do
  @moduledoc """
  Earth shadow (eclipse) prediction for satellites.

  Determines whether a satellite is in full sunlight, penumbra, or umbra
  using a conical shadow model. This is critical for satellite power budgets,
  thermal analysis, and optical visibility.

  ## Shadow Model

  Uses the conical shadow model which computes the penumbra and umbra cones
  cast by Earth given the Sun's position. The satellite's position relative
  to these cones determines its illumination state.

  ## Example

      # Direct usage with pre-computed positions
      status = Sidereon.Eclipse.status(satellite_gcrs_position, sun_position_from_earth)
      # => :sunlit | :penumbra | :umbra

      # Convenience: propagate + transform + check in one call
      {:ok, status} = Sidereon.Eclipse.check(tle, datetime, ephemeris)
  """

  alias Sidereon.NIF

  defmodule EarthShadowModel do
    @moduledoc """
    Earth shape model used by eclipse shadow calculations.
    """

    @typedoc "Supported Earth shadow geometry models."
    @type t :: :spherical | :wgs84_oblate | String.t()
  end

  defmodule ShadowFunction do
    @moduledoc "Illumination functions for radiation pressure forces."
    @type t :: :apparent_disc | :conical
  end

  defmodule EclipseError do
    @moduledoc "An eclipse evaluation refusal with its input details."
    defstruct [:kind, :detail, :message]
    @type t :: %__MODULE__{kind: atom(), detail: map(), message: String.t()}
    defimpl String.Chars do
      def to_string(error), do: error.message
    end
  end

  defmodule ShadowGradientError do
    @moduledoc "A shadow-gradient evaluation refusal with its details."
    defstruct [:kind, :detail, :message]
    @type t :: %__MODULE__{kind: atom(), detail: map(), message: String.t()}
    defimpl String.Chars do
      def to_string(error), do: error.message
    end
  end

  @typedoc "A geocentric Cartesian position in kilometres."
  @type position :: {number(), number(), number()}

  @typedoc "Illumination from the visible portion of the Sun."
  @type eclipse_status :: :sunlit | :penumbra | :umbra

  @typedoc "Shadow fraction and its derivative with respect to position, per kilometre."
  @type gradient :: {float(), {float(), float(), float()}}

  @doc """
  Determine the eclipse status of a satellite.

  ## Parameters

    * `sat_pos` - satellite GCRS position `{x, y, z}` in km
    * `sun_pos` - Sun position relative to Earth `{x, y, z}` in km
      (i.e., the vector from Earth center to the Sun)

  ## Returns

    * `:sunlit` - satellite is in full sunlight
    * `:penumbra` - satellite is partially shadowed
    * `:umbra` - satellite is in full shadow
  """
  @spec status(
          {float(), float(), float()},
          {float(), float(), float()}
        ) :: :sunlit | :penumbra | :umbra
  def status({_x, _y, _z} = sat_pos, {_sx, _sy, _sz} = sun_pos), do: NIF.eclipse_status(sat_pos, sun_pos)

  @doc """
  Compute the shadow fraction for a satellite.

  Returns a value from `0.0` (full sunlight) to `1.0` (full umbra).
  Values between 0 and 1 indicate partial shadow (penumbra).

  ## Parameters

    * `sat_pos` - satellite GCRS position `{x, y, z}` in km
    * `sun_pos` - Sun position relative to Earth `{x, y, z}` in km
      (vector from Earth center to the Sun)
  """
  @spec shadow_fraction(
          {float(), float(), float()},
          {float(), float(), float()}
        ) :: float()
  def shadow_fraction({_x, _y, _z} = sat_pos, {_sx, _sy, _sz} = sun_pos),
    do: NIF.eclipse_shadow_fraction(sat_pos, sun_pos)

  @doc """
  Compute the shadow fraction with an explicit Earth shadow model.
  """
  @spec shadow_fraction_with_model(
          {float(), float(), float()},
          {float(), float(), float()},
          EarthShadowModel.t()
        ) :: float()
  def shadow_fraction_with_model({_x, _y, _z} = sat_pos, {_sx, _sy, _sz} = sun_pos, model) do
    NIF.eclipse_shadow_fraction_with_model(sat_pos, sun_pos, shadow_model(model))
  end

  @doc """
  Determine eclipse status with an explicit Earth shadow model.
  """
  @spec status_with_model(
          {float(), float(), float()},
          {float(), float(), float()},
          EarthShadowModel.t()
        ) :: :sunlit | :penumbra | :umbra
  def status_with_model({_x, _y, _z} = sat_pos, {_sx, _sy, _sz} = sun_pos, model) do
    NIF.eclipse_status_with_model(sat_pos, sun_pos, shadow_model(model))
  end

  @doc """
  Convenience function: propagate a TLE, transform to GCRS, fetch the Sun
  position from an ephemeris, and return the eclipse status.

  ## Parameters

    * `tle` - parsed `%Sidereon.Elements{}` struct
    * `datetime` - `DateTime.t()` observation time
    * `ephemeris` - loaded `%Sidereon.Ephemeris{}` handle

  ## Returns

    * `:sunlit`, `:penumbra`, or `:umbra`

  ## Example

      {:ok, tle} = Sidereon.parse_tle(line1, line2)
      {:ok, eph} = Sidereon.Ephemeris.load("de421.bsp")
      {:ok, status} = Sidereon.Eclipse.check(tle, ~U[2024-06-21 12:00:00Z], eph)
  """
  @spec check(Sidereon.Elements.t(), DateTime.t(), Sidereon.Ephemeris.t()) ::
          {:ok, :sunlit | :penumbra | :umbra} | {:error, term()}
  def check(%Sidereon.Elements{} = tle, %DateTime{} = datetime, %Sidereon.Ephemeris{} = ephemeris) do
    with {:ok, teme} <- Sidereon.SGP4.propagate(tle, datetime),
         {:ok, sun_pos} <- Sidereon.Ephemeris.position(ephemeris, :sun, :earth, datetime) do
      gcrs = Sidereon.Coordinates.teme_to_gcrs(teme, datetime)

      {:ok, status(gcrs.position, sun_pos)}
    end
  end

  defp shadow_model(:spherical), do: "spherical"
  defp shadow_model(:wgs84_oblate), do: "wgs84_oblate"
  defp shadow_model(value) when is_binary(value), do: value

  @doc "Compute the apparent-disc shadow fraction cast by the Moon."
  @spec moon_shadow_fraction(position(), position(), position()) :: {:ok, float()} | {:error, EclipseError.t()}
  def moon_shadow_fraction(satellite, sun, moon) do
    case NIF.eclipse_moon_shadow_fraction(float_position(satellite), float_position(sun), float_position(moon)) do
      {:error, details} -> {:error, struct!(EclipseError, details)}
      result -> result
    end
  end

  @doc "Compute the apparent-disc shadow fraction cast by a spherical Earth and the Moon."
  @spec shadow_fraction_with_moon(position(), position(), position()) :: {:ok, float()} | {:error, EclipseError.t()}
  def shadow_fraction_with_moon(satellite, sun, moon) do
    case NIF.eclipse_shadow_fraction_with_moon(float_position(satellite), float_position(sun), float_position(moon)) do
      {:error, details} -> {:error, struct!(EclipseError, details)}
      result -> result
    end
  end

  @doc "Compute Earth and Moon apparent-disc shadow with an explicit Earth model."
  @spec shadow_fraction_with_model_and_moon(position(), position(), position(), EarthShadowModel.t()) ::
          {:ok, float()} | {:error, EclipseError.t()}
  def shadow_fraction_with_model_and_moon(satellite, sun, moon, model) do
    case NIF.eclipse_shadow_fraction_with_model_and_moon(
           float_position(satellite),
           float_position(sun),
           float_position(moon),
           model
         ) do
      {:error, details} -> {:error, struct!(EclipseError, details)}
      result -> result
    end
  end

  @doc "Classify illumination with occultation by a spherical Earth and the Moon."
  @spec status_with_moon(position(), position(), position()) :: {:ok, eclipse_status()} | {:error, EclipseError.t()}
  def status_with_moon(satellite, sun, moon) do
    case NIF.eclipse_status_with_moon(float_position(satellite), float_position(sun), float_position(moon)) do
      {:error, details} -> {:error, struct!(EclipseError, details)}
      result -> result
    end
  end

  @doc "Classify illumination with occultation by Earth and the Moon using an explicit Earth model."
  @spec status_with_model_and_moon(position(), position(), position(), EarthShadowModel.t()) ::
          {:ok, eclipse_status()} | {:error, EclipseError.t()}
  def status_with_model_and_moon(satellite, sun, moon, model) do
    case NIF.eclipse_status_with_model_and_moon(
           float_position(satellite),
           float_position(sun),
           float_position(moon),
           model
         ) do
      {:error, details} -> {:error, struct!(EclipseError, details)}
      result -> result
    end
  end

  @doc "Compute spherical Earth conical shadow and its position gradient."
  @spec shadow_fraction_with_gradient(position(), position()) :: {:ok, gradient()} | {:error, ShadowGradientError.t()}
  def shadow_fraction_with_gradient(satellite, sun) do
    case NIF.eclipse_shadow_fraction_with_gradient(float_position(satellite), float_position(sun)) do
      {:error, details} -> {:error, struct!(ShadowGradientError, details)}
      result -> result
    end
  end

  @doc "Compute Earth conical shadow and its position gradient with an explicit Earth model."
  @spec shadow_fraction_with_model_and_gradient(position(), position(), EarthShadowModel.t()) ::
          {:ok, gradient()} | {:error, ShadowGradientError.t()}
  def shadow_fraction_with_model_and_gradient(satellite, sun, model) do
    case NIF.eclipse_shadow_fraction_with_model_and_gradient(float_position(satellite), float_position(sun), model) do
      {:error, details} -> {:error, struct!(ShadowGradientError, details)}
      result -> result
    end
  end

  @doc "Compute Earth and Moon apparent-disc shadow and its position gradient."
  @spec shadow_fraction_with_model_moon_and_gradient(position(), position(), position(), EarthShadowModel.t()) ::
          {:ok, gradient()} | {:error, ShadowGradientError.t()}
  def shadow_fraction_with_model_moon_and_gradient(satellite, sun, moon, model) do
    case NIF.eclipse_shadow_fraction_with_model_moon_and_gradient(
           float_position(satellite),
           float_position(sun),
           float_position(moon),
           model
         ) do
      {:error, details} -> {:error, struct!(ShadowGradientError, details)}
      result -> result
    end
  end

  defp float_position({x, y, z}), do: {x / 1.0, y / 1.0, z / 1.0}

  @doc "Return the IAU 2015 nominal solar radius in kilometres."
  @spec iau_2015_solar_radius_km() :: float()
  def iau_2015_solar_radius_km, do: NIF.eclipse_iau_2015_solar_radius_km()
end
