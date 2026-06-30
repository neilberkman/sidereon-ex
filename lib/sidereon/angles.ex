defmodule Sidereon.Angles do
  @moduledoc """
  Angular geometry calculations for satellites.

  Computes angular separations between a satellite and celestial bodies
  (Sun, Moon) using vector geometry in the GCRS frame. Useful for:

  - Solar panel pointing analysis
  - Lunar interference assessment
  - Optical brightness estimation (phase angle)
  - Eclipse geometry (Earth angular radius)

  All positions are expected in km in the GCRS (J2000/ICRF) frame.
  All returned angles are in degrees.

  ## Example

      {:ok, eph} = Sidereon.Ephemeris.load("de421.bsp")
      {:ok, tle} = Sidereon.parse_tle(line1, line2)
      result = Sidereon.Angles.compute(tle, ~U[2024-06-21 12:00:00Z], eph)
      result.sun_angle      # degrees
      result.moon_angle     # degrees
      result.sun_elevation  # degrees (positive = sunlit side)
      result.earth_angle    # degrees (angular radius of Earth)
  """

  @doc """
  Angle between satellite nadir (toward Earth) and the Sun direction.

  The nadir vector points from the satellite toward Earth's center,
  i.e., it is the negation of the satellite's GCRS position.

  ## Parameters

    - `satellite_gcrs_position` - `{x, y, z}` satellite position in GCRS (km)
    - `sun_position_from_earth` - `{x, y, z}` Sun position relative to Earth (km)

  Returns angle in degrees (0 = Sun is directly below satellite toward Earth,
  180 = Sun is directly above/away from Earth).
  """
  @spec sun_angle(
          {number(), number(), number()},
          {number(), number(), number()}
        ) :: float()
  def sun_angle(satellite_gcrs_position, sun_position_from_earth) do
    Sidereon.NIF.angles_sun_angle(
      floats(satellite_gcrs_position),
      floats(sun_position_from_earth)
    )
  end

  @doc """
  Angle between satellite nadir (toward Earth) and the Moon direction.

  ## Parameters

    - `satellite_gcrs_position` - `{x, y, z}` satellite position in GCRS (km)
    - `moon_position_from_earth` - `{x, y, z}` Moon position relative to Earth (km)

  Returns angle in degrees.
  """
  @spec moon_angle(
          {number(), number(), number()},
          {number(), number(), number()}
        ) :: float()
  def moon_angle(satellite_gcrs_position, moon_position_from_earth) do
    Sidereon.NIF.angles_moon_angle(
      floats(satellite_gcrs_position),
      floats(moon_position_from_earth)
    )
  end

  @doc """
  Sun elevation above or below the satellite's local horizontal plane.

  The local horizontal plane is perpendicular to the radial (nadir) vector.
  Positive elevation means the Sun is on the sunlit (away from Earth) side;
  negative means it is on the shadow (Earth) side.

  ## Parameters

    - `satellite_gcrs_position` - `{x, y, z}` satellite position in GCRS (km)
    - `sun_position_from_earth` - `{x, y, z}` Sun position relative to Earth (km)

  Returns elevation in degrees (-90 to +90).
  """
  @spec sun_elevation(
          {number(), number(), number()},
          {number(), number(), number()}
        ) :: float()
  def sun_elevation(satellite_gcrs_position, sun_position_from_earth) do
    Sidereon.NIF.angles_sun_elevation(
      floats(satellite_gcrs_position),
      floats(sun_position_from_earth)
    )
  end

  @doc """
  Sun-satellite-observer phase angle.

  The phase angle is the angle at the satellite between the Sun and the
  observer. It determines the illumination geometry for optical brightness
  estimation:

  - 0 deg = full phase (Sun behind observer, satellite fully lit)
  - 180 deg = new phase (Sun behind satellite, satellite in shadow from observer)

  ## Parameters

    - `satellite_gcrs_position` - `{x, y, z}` satellite position in GCRS (km)
    - `sun_position_from_earth` - `{x, y, z}` Sun position relative to Earth (km)
    - `observer_position` - `{x, y, z}` observer position in GCRS (km)

  Returns phase angle in degrees (0 to 180).
  """
  @spec phase_angle(
          {number(), number(), number()},
          {number(), number(), number()},
          {number(), number(), number()}
        ) :: float()
  def phase_angle(satellite_gcrs_position, sun_position_from_earth, observer_position) do
    Sidereon.NIF.angles_phase_angle(
      floats(satellite_gcrs_position),
      floats(sun_position_from_earth),
      floats(observer_position)
    )
  end

  @doc """
  Angular radius of the Earth as seen from the satellite.

  This is the half-angle of the cone that just encloses the Earth's disk
  as seen from the satellite's position: `asin(R_earth / |sat_position|)`.

  Useful for eclipse geometry: if the Sun is within this angular radius
  of the anti-nadir direction, the satellite may be in Earth's shadow.

  ## Parameters

    - `satellite_gcrs_position` - `{x, y, z}` satellite position in GCRS (km)

  Returns angular radius in degrees.
  """
  @spec earth_angular_radius({number(), number(), number()}) :: float()
  def earth_angular_radius(satellite_gcrs_position) do
    Sidereon.NIF.angles_earth_angular_radius(floats(satellite_gcrs_position))
  end

  @doc """
  Compute all standard angles for a satellite at a given time.

  Propagates the TLE, gets Sun and Moon positions from the ephemeris,
  and returns a map of angles.

  ## Parameters

    - `tle` - parsed `%Sidereon.Elements{}` struct
    - `datetime` - `DateTime.t()` observation time
    - `ephemeris` - loaded `%Sidereon.Ephemeris{}` handle

  ## Returns

      %{
        sun_angle: float(),       # nadir-to-Sun angle in degrees
        moon_angle: float(),      # nadir-to-Moon angle in degrees
        sun_elevation: float(),   # Sun elevation above local horizontal
        earth_angle: float()      # Earth angular radius from satellite
      }
  """
  @spec compute(Sidereon.Elements.t(), DateTime.t(), Sidereon.Ephemeris.t()) ::
          {:ok, map()} | {:error, term()}
  def compute(%Sidereon.Elements{} = tle, %DateTime{} = datetime, %Sidereon.Ephemeris{} = ephemeris) do
    with {:ok, teme} <- Sidereon.SGP4.propagate(tle, datetime),
         {:ok, sun_pos} <- Sidereon.Ephemeris.position(ephemeris, :sun, :earth, datetime),
         {:ok, moon_pos} <- Sidereon.Ephemeris.position(ephemeris, :moon, :earth, datetime) do
      gcrs = Sidereon.Coordinates.teme_to_gcrs(teme, datetime)
      sat_pos = gcrs.position

      {:ok,
       %{
         sun_angle: sun_angle(sat_pos, sun_pos),
         moon_angle: moon_angle(sat_pos, moon_pos),
         sun_elevation: sun_elevation(sat_pos, sun_pos),
         earth_angle: earth_angular_radius(sat_pos)
       }}
    end
  end

  # Coerce a position tuple to floats so the NIF receives f64 components even
  # when callers pass integer coordinates.
  defp floats({x, y, z}), do: {x * 1.0, y * 1.0, z * 1.0}
end
