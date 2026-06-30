defmodule Sidereon.GNSS.Ionosphere do
  @moduledoc """
  Single-frequency ionospheric group-delay corrections.

  Two models are exposed over the `sidereon-core` crate: the GPS broadcast
  Klobuchar model (eight alpha/beta coefficients, IS-GPS-200), and an IONEX
  vertical-TEC-grid slant delay (single-layer model). Both return the group
  delay in **positive meters**.

  This is the ionosphere correction for a GNSS signal. It is **not**
  `Sidereon.Atmosphere`, which is NRLMSISE-00 neutral-atmosphere mass density for
  drag, a different quantity entirely.

  ## Sign convention

  The returned delay is a **group delay** and is **positive**: it increases the
  measured pseudorange (the signal arrives later than vacuum geometry would
  predict). The carrier-phase advance is the negation of this value. The
  ionosphere is dispersive, so the delay reported on a carrier other than the
  model's native L1 is the L1 delay scaled by `(f_L1 / f)^2`; pass the carrier
  via `frequency_hz`.

  ## Units at the boundary

  Public inputs are in degrees (`_deg`) and meters/hertz, per the Sidereon naming
  convention. Latitude is positive north, longitude positive east, azimuth
  clockwise from north.
  """

  alias Sidereon.NIF

  @doc """
  GPS broadcast Klobuchar L1 ionospheric group delay, scaled to `frequency_hz`.

  `params` carries the eight broadcast coefficients as
  `%{alpha: {a0, a1, a2, a3}, beta: {b0, b1, b2, b3}}` (or lists). The receiver
  geodetic latitude/longitude and the satellite azimuth/elevation are in
  degrees; `epoch` is a `NaiveDateTime` or `{{y, m, d}, {h, min, s}}` tuple in
  GPS time. Returns `{:ok, delay_m}` (positive meters) or `{:error, reason}`.
  """
  @spec klobuchar_delay(
          map(),
          number(),
          number(),
          number(),
          number(),
          NaiveDateTime.t() | tuple(),
          number()
        ) :: {:ok, float()} | {:error, term()}
  def klobuchar_delay(params, lat_deg, lon_deg, azimuth_deg, elevation_deg, epoch, frequency_hz) do
    with {:ok, alpha, beta} <- klobuchar_coeffs(params) do
      # The model takes degrees and the GPS second-of-day directly. Passing the
      # degree inputs through unchanged and forming the second-of-day from the
      # epoch's integer clock fields (no split-Julian-date round trip) keeps the
      # result bit-for-bit identical to the reference recipe.
      t_gps_s = Sidereon.GNSS.Time.second_of_day(epoch)

      delay =
        NIF.klobuchar_delay(
          lat_deg / 1.0,
          lon_deg / 1.0,
          azimuth_deg / 1.0,
          elevation_deg / 1.0,
          t_gps_s,
          frequency_hz / 1.0,
          alpha,
          beta
        )

      {:ok, delay}
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Galileo NeQuick-G single-frequency ionospheric group delay, scaled to
  `frequency_hz`.

  `coeffs` carries the three Galileo broadcast effective-ionisation coefficients
  as `%{ai0: a0, ai1: a1, ai2: a2}`. The receiver geodetic latitude/longitude and
  the satellite azimuth/elevation are in degrees; `epoch` is a `NaiveDateTime` or
  `{{y, m, d}, {h, min, s}}` tuple in Galileo system time. The NeQuick-G arm maps
  the slant delay by elevation only, so `azimuth_deg` is accepted (to match the
  shared ionosphere-model boundary) but does not change the result. Returns
  `{:ok, delay_m}` (positive meters) or `{:error, reason}`.
  """
  @spec galileo_nequick_g_delay(
          map(),
          number(),
          number(),
          number(),
          number(),
          NaiveDateTime.t() | tuple(),
          number()
        ) :: {:ok, float()} | {:error, term()}
  def galileo_nequick_g_delay(coeffs, lat_deg, lon_deg, azimuth_deg, elevation_deg, epoch, frequency_hz) do
    with {:ok, ai0, ai1, ai2} <- nequick_coeffs(coeffs) do
      # Pass the same split Julian date the SP3/IONEX path uses so the core kernel
      # derives the Galileo second-of-day and fractional day-of-year from one
      # instant (no separate second-of-day argument that could round differently).
      {jd_whole, jd_fraction} = Sidereon.GNSS.Time.epoch_to_split_jd(epoch)

      delay =
        NIF.galileo_nequick_g_delay(
          lat_deg / 1.0,
          lon_deg / 1.0,
          elevation_deg / 1.0,
          azimuth_deg / 1.0,
          jd_whole,
          jd_fraction,
          frequency_hz / 1.0,
          ai0,
          ai1,
          ai2
        )

      {:ok, delay}
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Galileo NeQuick-G full three-dimensional slant total electron content (TECU).

  This is the reference-grade full 3D NeQuick-G integration, distinct from the
  compact single-layer `galileo_nequick_g_delay/7`. The `coeffs` map carries the
  broadcast effective-ionisation coefficients `%{ai0:, ai1:, ai2:}`. The `ray`
  map carries both endpoints of the receiver-to-satellite line of sight, in the
  reference algorithm's native units:

    * `:month` - month of the year, `1..12`
    * `:utc_hours` - UTC time of day in hours, `[0, 24]`
    * `:station_lon_deg`, `:station_lat_deg`, `:station_height_m`
    * `:satellite_lon_deg`, `:satellite_lat_deg`, `:satellite_height_m`

  Returns `{:ok, stec_tecu}` (slant TEC in TECU) or `{:error, reason}`.
  """
  @spec nequick_g_stec(map(), map()) :: {:ok, float()} | {:error, term()}
  def nequick_g_stec(coeffs, ray) do
    with {:ok, ai0, ai1, ai2} <- nequick_coeffs(coeffs),
         {:ok, r} <- nequick_ray(ray) do
      case NIF.nequick_g_stec_tecu(
             ai0,
             ai1,
             ai2,
             r.month,
             r.utc_hours,
             r.station_lon_deg,
             r.station_lat_deg,
             r.station_height_m,
             r.satellite_lon_deg,
             r.satellite_lat_deg,
             r.satellite_height_m
           ) do
        {:error, reason} -> {:error, reason}
        stec when is_number(stec) -> {:ok, stec}
      end
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Galileo NeQuick-G full slant ionospheric group delay (positive meters).

  The full 3D slant TEC from `nequick_g_stec/2` mapped to a dispersive group
  delay on `frequency_hz`. `coeffs` and `ray` are as in `nequick_g_stec/2`.

  Returns `{:ok, delay_m}` (positive meters) or `{:error, reason}`.
  """
  @spec nequick_g_delay(map(), map(), number()) :: {:ok, float()} | {:error, term()}
  def nequick_g_delay(coeffs, ray, frequency_hz) do
    with {:ok, ai0, ai1, ai2} <- nequick_coeffs(coeffs),
         {:ok, r} <- nequick_ray(ray) do
      case NIF.nequick_g_delay_m(
             ai0,
             ai1,
             ai2,
             r.month,
             r.utc_hours,
             r.station_lon_deg,
             r.station_lat_deg,
             r.station_height_m,
             r.satellite_lon_deg,
             r.satellite_lat_deg,
             r.satellite_height_m,
             frequency_hz / 1.0
           ) do
        {:error, reason} -> {:error, reason}
        delay when is_number(delay) -> {:ok, delay}
      end
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Parse an in-memory IONEX byte buffer into a product handle.

  Returns `{:ok, reference()}` or `{:error, reason}`. The buffer is parsed
  exactly once; the parsed grid is held as a resource handle.
  """
  @spec parse_ionex(binary()) :: {:ok, reference()} | {:error, term()}
  def parse_ionex(bytes) when is_binary(bytes) do
    case NIF.ionex_parse(bytes) do
      handle when is_reference(handle) -> {:ok, handle}
      {:error, _} = err -> err
      other -> {:error, other}
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Load and parse an IONEX file into a product handle.

  Returns `{:ok, reference()}` or `{:error, reason}`.
  """
  @spec load_ionex(String.t()) :: {:ok, reference()} | {:error, term()}
  def load_ionex(path) when is_binary(path) do
    with {:ok, bytes} <- File.read(path) do
      parse_ionex(bytes)
    end
  end

  @doc """
  Serialize a parsed IONEX product back to standard IONEX text.

  `handle` is a parsed-IONEX reference from `parse_ionex/1` or `load_ionex/1`.
  This is the inverse of `parse_ionex/1`: re-parsing the output reproduces the
  same TEC grids. The serialization is deterministic and performs no I/O.

  Returns `{:ok, text}` or `{:error, reason}`.

  ## Examples

      {:ok, handle} = Sidereon.GNSS.Ionosphere.parse_ionex(ionex_bytes)
      {:ok, text} = Sidereon.GNSS.Ionosphere.ionex_to_string(handle)
      {:ok, _reparsed} = Sidereon.GNSS.Ionosphere.parse_ionex(text)
  """
  @spec ionex_to_string(reference()) :: {:ok, String.t()} | {:error, term()}
  def ionex_to_string(handle) when is_reference(handle) do
    case NIF.ionex_to_string(handle) do
      text when is_binary(text) -> {:ok, text}
      {:error, _} = err -> err
      other -> {:error, other}
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  IONEX vertical-TEC-grid slant ionospheric group delay, scaled to `frequency_hz`.

  `handle` is a parsed-IONEX reference from `parse_ionex/1` or `load_ionex/1`.
  The receiver geodetic latitude/longitude and the satellite azimuth/elevation
  are in degrees; `epoch` is a `NaiveDateTime` or `{{y, m, d}, {h, min, s}}`
  tuple (the pierce point rides on the IONEX shell, so the receiver height is not
  used). Returns `{:ok, delay_m}` (positive meters) or `{:error, reason}`.
  """
  @spec ionex_slant_delay(
          reference(),
          number(),
          number(),
          number(),
          number(),
          NaiveDateTime.t() | tuple(),
          number()
        ) :: {:ok, float()} | {:error, term()}
  def ionex_slant_delay(handle, lat_deg, lon_deg, azimuth_deg, elevation_deg, epoch, frequency_hz)
      when is_reference(handle) do
    with {:ok, epoch_j2000_s} <- Sidereon.GNSS.Time.epoch_to_j2000_seconds(epoch) do
      delay =
        NIF.ionex_slant(
          handle,
          lat_deg / 1.0,
          lon_deg / 1.0,
          elevation_deg / 1.0,
          azimuth_deg / 1.0,
          epoch_j2000_s,
          frequency_hz / 1.0
        )

      {:ok, delay}
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  # --- helpers -------------------------------------------------------------

  defp klobuchar_coeffs(%{alpha: alpha, beta: beta}) do
    with {:ok, a} <- four_tuple(alpha),
         {:ok, b} <- four_tuple(beta) do
      {:ok, a, b}
    end
  end

  defp klobuchar_coeffs(_other), do: {:error, :bad_klobuchar_params}

  defp nequick_coeffs(%{ai0: ai0, ai1: ai1, ai2: ai2}), do: {:ok, ai0 / 1.0, ai1 / 1.0, ai2 / 1.0}
  defp nequick_coeffs(_other), do: {:error, :bad_nequick_params}

  defp nequick_ray(%{
         month: month,
         utc_hours: utc_hours,
         station_lon_deg: station_lon_deg,
         station_lat_deg: station_lat_deg,
         station_height_m: station_height_m,
         satellite_lon_deg: satellite_lon_deg,
         satellite_lat_deg: satellite_lat_deg,
         satellite_height_m: satellite_height_m
       })
       when is_integer(month) do
    {:ok,
     %{
       month: month,
       utc_hours: utc_hours / 1.0,
       station_lon_deg: station_lon_deg / 1.0,
       station_lat_deg: station_lat_deg / 1.0,
       station_height_m: station_height_m / 1.0,
       satellite_lon_deg: satellite_lon_deg / 1.0,
       satellite_lat_deg: satellite_lat_deg / 1.0,
       satellite_height_m: satellite_height_m / 1.0
     }}
  end

  defp nequick_ray(_other), do: {:error, :bad_nequick_ray}

  defp four_tuple({a, b, c, d}), do: {:ok, {a / 1.0, b / 1.0, c / 1.0, d / 1.0}}
  defp four_tuple([a, b, c, d]), do: {:ok, {a / 1.0, b / 1.0, c / 1.0, d / 1.0}}
  defp four_tuple(_other), do: {:error, :bad_coefficients}
end
