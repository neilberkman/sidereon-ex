defmodule Sidereon.Atmosphere do
  @moduledoc """
  Atmospheric density via the NRLMSISE-00 empirical model.

  NRLMSISE-00 computes total mass density and temperature from the surface
  to the lower exosphere (~1000 km). It is the standard model used for
  satellite drag prediction.

  The reported `density` is the drag-effective total mass density (`gtd7d`):
  anomalous oxygen is folded in, which matters above ~500 km. This is the
  correct quantity for drag users.

  ## Valid domain

  Altitude must be in `[0, 1000]` km (the model's validity range); `:f107`,
  `:f107a`, and `:ap` must be finite and non-negative. Inputs outside this
  domain return a tagged error rather than an extrapolated result.

  ## Quick example

      position = %{latitude: 0.0, longitude: 0.0, altitude_km: 400.0}
      {:ok, result} = Sidereon.Atmosphere.density(position, ~U[2024-06-20 12:00:00Z])
      result.density    # kg/m^3 (e.g., ~3e-12 at ISS altitude)
      result.temperature # K

  ## Solar/geomagnetic indices

  The model depends on space weather conditions. You can supply these via
  the `:f107`, `:f107a`, and `:ap` options. If omitted, moderate defaults
  are used (F10.7 = F10.7A = 150.0, Ap = 4.0).

  For operational use, fetch current indices from NOAA/SWPC.
  """

  @default_f107 150.0
  @default_f107a 150.0
  @default_ap 4.0
  @allowed_options [:f107, :f107a, :ap]
  @max_altitude_km 1000.0

  @type position :: %{
          latitude: number(),
          longitude: number(),
          altitude_km: number()
        }
  @type datetime ::
          DateTime.t()
          | {{integer(), integer(), integer()}, {integer(), integer(), number()}}
  @type result :: %{density: float(), temperature: float()}
  @type density_error ::
          {:missing_field, atom()}
          | {:invalid_field, atom(), term()}
          | {:invalid_option, atom()}
          | {:invalid_datetime, term()}
          | {:nif_error, term()}

  @doc """
  Compute atmospheric density and temperature at a given position and time.

  ## Parameters

    - `position` - geodetic position as `%{latitude: deg, longitude: deg, altitude_km: km}`
    - `datetime` - observation time as `DateTime` or `{{y,m,d},{h,m,s}}` tuple
    - `opts` - keyword list of optional space weather indices:
      - `:f107` - daily 10.7 cm solar radio flux (default #{@default_f107})
      - `:f107a` - 81-day average of F10.7 (default #{@default_f107a})
      - `:ap` - daily geomagnetic Ap index (default #{@default_ap})

  ## Returns

  `{:ok, %{density: kg_per_m3, temperature: kelvin}}` or `{:error, reason}`.

  ## Examples

      # ISS altitude with default solar activity
      pos = %{latitude: 28.5, longitude: -80.6, altitude_km: 408.0}
      {:ok, result} = Sidereon.Atmosphere.density(pos, ~U[2024-06-20 12:00:00Z])

      # With explicit solar indices
      {:ok, result} = Sidereon.Atmosphere.density(pos, ~U[2024-06-20 12:00:00Z],
        f107: 180.0, f107a: 160.0, ap: 15.0)
  """
  @spec density(term(), term(), keyword()) :: {:ok, result()} | {:error, density_error()}
  def density(position, datetime, opts \\ [])

  def density(position, datetime, opts) do
    with {:ok, %{latitude: lat, longitude: lon, altitude_km: alt}} <- validate_position(position),
         {:ok, %{year: year, doy: doy, seconds_of_day: seconds_of_day}} <-
           datetime_fields(datetime),
         {:ok, %{f107: f107, f107a: f107a, ap: ap}} <- validate_options(opts) do
      call_nif(lat, lon, alt, year, doy, seconds_of_day, f107, f107a, ap)
    end
  end

  defp call_nif(lat, lon, alt, year, doy, sec, f107, f107a, ap) do
    {density, temperature} =
      Sidereon.NIF.atmosphere_density(
        lat * 1.0,
        lon * 1.0,
        alt * 1.0,
        year,
        doy,
        sec * 1.0,
        f107 * 1.0,
        f107a * 1.0,
        ap * 1.0
      )

    {:ok, %{density: density, temperature: temperature}}
  rescue
    e in ErlangError -> {:error, {:nif_error, e.original}}
  end

  defp validate_position(%{} = position) do
    with {:ok, latitude} <- required_number(position, :latitude),
         {:ok, longitude} <- required_number(position, :longitude),
         {:ok, altitude_km} <- required_number(position, :altitude_km),
         :ok <- validate_altitude(altitude_km) do
      {:ok, %{latitude: latitude, longitude: longitude, altitude_km: altitude_km}}
    end
  end

  defp validate_position(value), do: {:error, {:invalid_field, :position, value}}

  defp validate_altitude(alt) when alt >= 0 and alt <= @max_altitude_km, do: :ok
  defp validate_altitude(alt), do: {:error, {:invalid_field, :altitude_km, alt}}

  defp required_number(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_number(value) -> {:ok, value}
      {:ok, value} -> {:error, {:invalid_field, key, value}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp datetime_fields(%DateTime{} = dt) do
    {:ok,
     %{
       year: dt.year,
       doy: Date.day_of_year(DateTime.to_date(dt)),
       seconds_of_day:
         dt.hour * 3600 + dt.minute * 60 + dt.second + elem(dt.microsecond, 0) / 1_000_000
     }}
  end

  defp datetime_fields({{year, month, day}, {hour, minute, second}} = datetime)
       when is_integer(year) and is_integer(month) and is_integer(day) and is_integer(hour) and
              is_integer(minute) and is_number(second) do
    with {:ok, date} <- Date.new(year, month, day),
         true <- valid_time?(hour, minute, second) do
      {:ok,
       %{
         year: year,
         doy: Date.day_of_year(date),
         seconds_of_day: hour * 3600 + minute * 60 + second
       }}
    else
      _ -> {:error, {:invalid_datetime, datetime}}
    end
  end

  defp datetime_fields(datetime), do: {:error, {:invalid_datetime, datetime}}

  defp valid_time?(hour, minute, second) do
    hour in 0..23 and minute in 0..59 and second >= 0 and second < 60
  end

  defp validate_options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      with :ok <- validate_option_keys(opts),
           {:ok, f107} <- optional_number(opts, :f107, @default_f107),
           {:ok, f107a} <- optional_number(opts, :f107a, @default_f107a),
           {:ok, ap} <- optional_number(opts, :ap, @default_ap) do
        {:ok, %{f107: f107, f107a: f107a, ap: ap}}
      end
    else
      {:error, {:invalid_option, :opts}}
    end
  end

  defp validate_options(_opts), do: {:error, {:invalid_option, :opts}}

  defp validate_option_keys(opts) do
    case Enum.find(opts, fn {key, _value} -> key not in @allowed_options end) do
      nil -> :ok
      {key, _value} -> {:error, {:invalid_option, key}}
    end
  end

  defp optional_number(opts, key, default) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_number(value) and value >= 0 -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_option, key}}
      :error -> {:ok, default}
    end
  end
end
