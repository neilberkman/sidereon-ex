defmodule Sidereon.GNSS.Troposphere do
  @moduledoc """
  Neutral-atmosphere (tropospheric) signal-delay corrections.

  Computes the GNSS tropospheric delay over the `sidereon-core` crate as a
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
  alias Sidereon.NifCall

  @typedoc "Failure reason returned by checked troposphere mapping."
  @type mapping_error :: :below_mapping_elevation | :above_mapping_elevation | :outside_mapping_height | term()

  @typedoc """
  Complete typed refusal returned by the detailed troposphere calls.

  `family` is `CoreError`, `FrameValueError`, or `TimeModelError`. `kind` is
  `INVALID_INPUT`, `FRAME_VALUE_INVALID_INPUT`, or
  `TIME_MODEL_INVALID_INPUT`; frame and time-model details also retain their
  exact `field` and `reason` strings. The NIF map always includes `field`,
  `reason`, and `debug`; fields not used by a family are `nil`.
  """
  @type core_error_detail :: %{
          required(:family) => String.t(),
          required(:kind) => String.t(),
          required(:message) => String.t(),
          required(:field) => String.t() | nil,
          required(:reason) => String.t() | nil,
          required(:debug) => String.t() | nil
        }

  @typedoc "Input failure returned by a detailed troposphere call."
  @type detailed_error ::
          {:invalid_input, core_error_detail()}
          | :bad_meteorology
          | :bad_epoch
          | {:invalid_epoch_field, atom(), term()}
          | {:value_out_of_range, atom(), term()}
          | {:invalid_argument, atom()}
          | {:arithmetic_error, atom()}
          | :nif_panicked

  @typedoc "Detailed troposphere result with typed input and core refusals."
  @type detailed_result(value) :: {:ok, value} | {:error, detailed_error()}

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
      case NIF.tropo_zenith_delay(lat_deg / 1.0, height_m / 1.0, p, t, rh) do
        {dry_m, wet_m} when is_number(dry_m) and is_number(wet_m) ->
          {:ok, %{dry_m: dry_m, wet_m: wet_m}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :tropo_zenith_delay)
  end

  @doc """
  Detailed sibling of `zenith_delay/3` that returns complete typed refusals.

  Successful values match `zenith_delay/3`. Core errors retain their kind,
  message, and debug detail; frame-value and time-model errors retain their
  family, message, exact field, and reason. The original `zenith_delay/3`
  continues to return its established error atom.
  """
  @spec zenith_delay_detailed(number(), number(), map()) :: detailed_result(%{dry_m: float(), wet_m: float()})
  def zenith_delay_detailed(lat_deg, height_m, met) do
    with {:ok, p, t, rh} <- meteorology(met) do
      case NIF.tropo_zenith_delay_detailed(lat_deg / 1.0, height_m / 1.0, p, t, rh) do
        {dry_m, wet_m} when is_number(dry_m) and is_number(wet_m) ->
          {:ok, %{dry_m: dry_m, wet_m: wet_m}}

        {:error, {kind, detail}} ->
          {:error, {kind, detail}}
      end
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :tropo_zenith_delay_detailed)
  end

  @doc """
  Niell hydrostatic and wet mapping factors at an elevation.

  `epoch` is a `NaiveDateTime` or `{{y, m, d}, {h, min, s}}` tuple (the Niell
  seasonal term needs the day-of-year). Returns
  `{:ok, %{dry: dry, wet: wet}}` (dimensionless) or `{:error, reason}`. Niell
  mapping rejects elevations below its 3 degree validity bound with
  `{:error, :below_mapping_elevation}`.
  """
  @spec mapping(number(), number(), number(), NaiveDateTime.t() | tuple()) ::
          {:ok, %{dry: float(), wet: float()}} | {:error, mapping_error()}
  def mapping(elevation_deg, lat_deg, height_m, epoch) do
    with {:ok, {jd_whole, jd_fraction}} <- Sidereon.GNSS.Time.epoch_to_split_jd(epoch) do
      case NIF.tropo_mapping_factors(
             elevation_deg / 1.0,
             lat_deg / 1.0,
             height_m / 1.0,
             jd_whole,
             jd_fraction
           ) do
        {dry, wet} when is_number(dry) and is_number(wet) -> {:ok, %{dry: dry, wet: wet}}
        {:error, reason} -> {:error, reason}
      end
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :tropo_mapping_factors)
  end

  @doc """
  Detailed sibling of `mapping/4` that returns complete typed refusals,
  including field and reason for frame-value and time-model constructor errors.

  The legacy mapping function keeps returning its existing error categories.
  """
  @spec mapping_detailed(number(), number(), number(), NaiveDateTime.t() | tuple()) ::
          detailed_result(%{dry: float(), wet: float()})
  def mapping_detailed(elevation_deg, lat_deg, height_m, epoch) do
    with {:ok, {jd_whole, jd_fraction}} <- Sidereon.GNSS.Time.epoch_to_split_jd(epoch) do
      case NIF.tropo_mapping_factors_detailed(
             elevation_deg / 1.0,
             lat_deg / 1.0,
             height_m / 1.0,
             jd_whole,
             jd_fraction
           ) do
        {dry, wet} when is_number(dry) and is_number(wet) -> {:ok, %{dry: dry, wet: wet}}
        {:error, {kind, detail}} -> {:error, {kind, detail}}
      end
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :tropo_mapping_factors_detailed)
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
  def slant_delay(elevation_deg, _lat_deg, _lon_deg, _height_m, _met, _epoch) when elevation_deg < 0.0 do
    # Below the horizon there is no signal path, so the slant delay is zero. The
    # core rejects a negative elevation as out-of-range input, so honor the
    # documented "zero at or below the horizon" contract here.
    {:ok, 0.0}
  end

  def slant_delay(elevation_deg, lat_deg, lon_deg, height_m, met, epoch) do
    with {:ok, p, t, rh} <- meteorology(met),
         {:ok, {jd_whole, jd_fraction}} <- Sidereon.GNSS.Time.epoch_to_split_jd(epoch) do
      case NIF.tropo_slant_delay(
             elevation_deg / 1.0,
             lat_deg / 1.0,
             lon_deg / 1.0,
             height_m / 1.0,
             p,
             t,
             rh,
             jd_whole,
             jd_fraction
           ) do
        delay when is_number(delay) -> {:ok, delay}
        {:error, reason} -> {:error, reason}
      end
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :tropo_slant_delay)
  end

  @doc """
  Detailed sibling of `slant_delay/6` that returns complete typed refusals,
  including field and reason for frame-value and time-model constructor errors.

  Successful values and the below-horizon zero retain the legacy behavior.
  """
  @spec slant_delay_detailed(number(), number(), number(), number(), map(), NaiveDateTime.t() | tuple()) ::
          detailed_result(float())
  def slant_delay_detailed(elevation_deg, _lat_deg, _lon_deg, _height_m, _met, _epoch) when elevation_deg < 0.0,
    do: {:ok, 0.0}

  def slant_delay_detailed(elevation_deg, lat_deg, lon_deg, height_m, met, epoch) do
    with {:ok, p, t, rh} <- meteorology(met),
         {:ok, {jd_whole, jd_fraction}} <- Sidereon.GNSS.Time.epoch_to_split_jd(epoch) do
      case NIF.tropo_slant_delay_detailed(
             elevation_deg / 1.0,
             lat_deg / 1.0,
             lon_deg / 1.0,
             height_m / 1.0,
             p,
             t,
             rh,
             jd_whole,
             jd_fraction
           ) do
        delay when is_number(delay) -> {:ok, delay}
        {:error, {kind, detail}} -> {:error, {kind, detail}}
      end
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :tropo_slant_delay_detailed)
  end

  # --- helpers -------------------------------------------------------------

  defp meteorology(%{pressure_hpa: p, temperature_k: t, relative_humidity: rh})
       when is_number(p) and is_number(t) and is_number(rh) do
    {:ok, p / 1.0, t / 1.0, rh / 1.0}
  end

  defp meteorology(_other), do: {:error, :bad_meteorology}
end
