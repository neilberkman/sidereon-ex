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
end
