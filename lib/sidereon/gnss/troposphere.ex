defmodule Sidereon.GNSS.Troposphere do
  @moduledoc """
  Neutral-atmosphere (tropospheric) signal-delay corrections.

  Computes the GNSS tropospheric delay over the `astrodynamics-gnss` crate as a
  Saastamoinen (1972) zenith hydrostatic and wet delay, driven by supplied
  surface meteorology, mapped to the line of sight by the Niell (1996) mapping
  functions (NMF). The zenith delays and the mapping factors are exposed
  separately, and a convenience entry composes the full slant delay.

  This is the neutral-atmosphere signal-path delay. It is **not**
  `Sidereon.Atmosphere`, which is NRLMSISE-00 neutral-atmosphere mass density for
  drag; a different quantity.

  ## Sign convention

  The tropospheric delay is **non-dispersive**: it has the same sign and
  magnitude for code and carrier phase. The returned delays are **positive
  meters** that increase the measured pseudorange; `delay_m > 0` means the
  signal arrived later and the pseudorange is too long by `delay_m`.

  ## Units at the boundary

  Elevation and latitude are degrees (`_deg`); height is the WGS84 ellipsoidal
  height in meters (`_m`). Surface meteorology is supplied as
  `%{pressure_hpa: p, temperature_k: t, relative_humidity: rh}` where pressure is
  hectopascals, temperature is kelvin, and relative humidity is a unit fraction
  in `[0, 1]` (not a percentage). A below-sea-level (negative) height is used
  with its sign.
  """

  alias Sidereon.NIF

  @doc """
  Zenith hydrostatic and wet tropospheric delays from supplied meteorology.

  Returns `{:ok, %{dry_m: dry, wet_m: wet}}` (both positive meters) or
  `{:error, reason}`. The hydrostatic delay carries the gravity correction for
  the receiver latitude and height.
  """
  @spec zenith_delay(number(), number(), map()) ::
          {:ok, %{dry_m: float(), wet_m: float()}} | {:error, term()}
  def zenith_delay(lat_deg, height_m, met) do
    with {:ok, p, t, rh} <- meteorology(met) do
      {dry_m, wet_m} =
        NIF.tropo_zenith_delay(deg_to_rad(lat_deg), height_m / 1.0, p, t, rh)

      {:ok, %{dry_m: dry_m, wet_m: wet_m}}
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Niell hydrostatic and wet mapping factors at an elevation.

  `epoch` is a `NaiveDateTime` or `{{y, m, d}, {h, min, s}}` tuple (the Niell
  seasonal term needs the day-of-year). Returns
  `{:ok, %{dry: dry, wet: wet}}` (dimensionless) or `{:error, reason}`.
  """
  @spec mapping(number(), number(), number(), NaiveDateTime.t() | tuple()) ::
          {:ok, %{dry: float(), wet: float()}} | {:error, term()}
  def mapping(elevation_deg, lat_deg, height_m, epoch) do
    with {jd_whole, jd_fraction} <- Sidereon.GNSS.Time.epoch_to_split_jd(epoch) do
      {dry, wet} =
        NIF.tropo_mapping_factors(
          deg_to_rad(elevation_deg),
          deg_to_rad(lat_deg),
          height_m / 1.0,
          jd_whole,
          jd_fraction
        )

      {:ok, %{dry: dry, wet: wet}}
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Full slant tropospheric delay in positive meters.

  Composes the Saastamoinen zenith delays with the Niell mapping at the given
  elevation. `epoch` sets the seasonal day-of-year. Returns `{:ok, delay_m}`
  (positive meters; zero at or below the horizon and outside the height validity
  range) or `{:error, reason}`.
  """
  @spec slant_delay(number(), number(), number(), number(), map(), NaiveDateTime.t() | tuple()) ::
          {:ok, float()} | {:error, term()}
  def slant_delay(elevation_deg, _lat_deg, _lon_deg, _height_m, _met, _epoch)
      when elevation_deg < 0.0 do
    # Below the horizon there is no signal path, so the slant delay is zero. The
    # core rejects a negative elevation as out-of-range input, so honor the
    # documented "zero at or below the horizon" contract here.
    {:ok, 0.0}
  end

  def slant_delay(elevation_deg, lat_deg, lon_deg, height_m, met, epoch) do
    with {:ok, p, t, rh} <- meteorology(met),
         {jd_whole, jd_fraction} <- Sidereon.GNSS.Time.epoch_to_split_jd(epoch) do
      delay =
        NIF.tropo_slant_delay(
          deg_to_rad(elevation_deg),
          deg_to_rad(lat_deg),
          deg_to_rad(lon_deg),
          height_m / 1.0,
          p,
          t,
          rh,
          jd_whole,
          jd_fraction
        )

      {:ok, delay}
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  # --- helpers -------------------------------------------------------------

  # Single multiply by a precomputed constant matches the core/Python
  # `math.radians` to the last bit (one rounding, not two).
  @deg_to_rad :math.pi() / 180.0

  defp deg_to_rad(deg), do: deg * @deg_to_rad

  defp meteorology(%{pressure_hpa: p, temperature_k: t, relative_humidity: rh})
       when is_number(p) and is_number(t) and is_number(rh) do
    {:ok, p / 1.0, t / 1.0, rh / 1.0}
  end

  defp meteorology(_other), do: {:error, :bad_meteorology}
end
