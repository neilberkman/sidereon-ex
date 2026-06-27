defmodule Sidereon.Nx.Geometry do
  @moduledoc """
  Tensorized geometry helpers.

  The first milestone should stay focused on post-propagation geometry:
  topocentric look angles, elevation/azimuth, and simple geodetic helpers.
  """

  import Nx.Defn

  # Constants shared with the Rust coordinate kernels.
  @au_km Sidereon.Constants.au_km()
  @wgs84_a Sidereon.Constants.wgs84_a_km()
  @wgs84_e2 Sidereon.Constants.wgs84_e2()

  @doc """
  Compute azimuth, elevation, and slant range for satellite/station pairs.

  Inputs:
  - `sat_positions`: `[n, 3]` ITRS km
  - `stations`: `[m, 3]` lat/lon/alt_m

  Returns `%{azimuth: [n, m], elevation: [n, m], range_km: [n, m]}`.
  """
  defn look_angles(sat_positions, stations, _opts \\ []) do
    n = Nx.axis_size(sat_positions, 0)
    m = Nx.axis_size(stations, 0)
    type = Nx.type(sat_positions)
    tau = 2.0 * Nx.Constants.pi(type)

    # Convert stations to ITRS
    stn_itrs = geodetic_to_itrs(stations)

    # Reshape for broadcasting
    sat_broadcast = Nx.reshape(sat_positions, {n, 1, 3})
    stn_broadcast = Nx.reshape(stn_itrs, {1, m, 3})

    # Difference vector in ITRS
    diff = sat_broadcast - stn_broadcast

    # Rotate to ENU frame at each station
    enu_mats = ecef_to_enu_matrices(stations)

    diff_reshaped = Nx.reshape(diff, {n, m, 3, 1})
    enu_reshaped = Nx.reshape(enu_mats, {1, m, 3, 3})

    enu_vectors =
      Nx.dot(enu_reshaped, [3], [0], diff_reshaped, [2], [0])
      |> Nx.reshape({n, m, 3})

    east = Nx.squeeze(enu_vectors[[.., .., 0..0]], axes: [2])
    north = Nx.squeeze(enu_vectors[[.., .., 1..1]], axes: [2])
    up = Nx.squeeze(enu_vectors[[.., .., 2..2]], axes: [2])

    range_km = Nx.sqrt(east * east + north * north + up * up)
    elevation = Nx.atan2(up, Nx.sqrt(east * east + north * north)) * 360.0 / tau

    azimuth_raw = Nx.atan2(east, north) * 360.0 / tau
    azimuth = Nx.select(azimuth_raw < 0, azimuth_raw + 360.0, azimuth_raw)

    %{
      azimuth: azimuth,
      elevation: elevation,
      range_km: range_km
    }
  end

  @doc """
  Convert geodetic coordinates `[m, 3]` (lat, lon, alt_m) to ITRS `[m, 3]`.
  """
  defn geodetic_to_itrs(stations) do
    type = Nx.type(stations)
    tau = 2.0 * Nx.Constants.pi(type)

    lat = Nx.squeeze(stations[[.., 0..0]], axes: [1]) * tau / 360.0
    lon = Nx.squeeze(stations[[.., 1..1]], axes: [1]) * tau / 360.0
    alt_km = Nx.squeeze(stations[[.., 2..2]], axes: [1]) / 1000.0

    sin_lat = Nx.sin(lat)
    cos_lat = Nx.cos(lat)
    sin_lon = Nx.sin(lon)
    cos_lon = Nx.cos(lon)

    n = @wgs84_a / Nx.sqrt(1.0 - @wgs84_e2 * sin_lat * sin_lat)

    x = (n + alt_km) * cos_lat * cos_lon
    y = (n + alt_km) * cos_lat * sin_lon
    z = (n * (1.0 - @wgs84_e2) + alt_km) * sin_lat

    Nx.stack([x, y, z], axis: -1)
  end

  defn ecef_to_enu_matrices(stations) do
    type = Nx.type(stations)
    tau = 2.0 * Nx.Constants.pi(type)

    lat = Nx.squeeze(stations[[.., 0..0]], axes: [1]) * tau / 360.0
    lon = Nx.squeeze(stations[[.., 1..1]], axes: [1]) * tau / 360.0

    slat = Nx.sin(lat)
    clat = Nx.cos(lat)
    slon = Nx.sin(lon)
    clon = Nx.cos(lon)

    row1 = Nx.stack([-slon, clon, Nx.broadcast(0.0, slon)], axis: -1)
    row2 = Nx.stack([-slat * clon, -slat * slon, clat], axis: -1)
    row3 = Nx.stack([clat * clon, clat * slon, slat], axis: -1)

    Nx.stack([row1, row2, row3], axis: 1)
  end

  @doc """
  Convert ITRS/ECEF positions `[n, 3]` to geodetic coordinates.

  Returns `%{latitude: [n], longitude: [n], altitude_km: [n]}`.
  """
  defn geodetic(itrs_positions) do
    type = Nx.type(itrs_positions)
    pi = Nx.Constants.pi(type)
    tau = 2.0 * pi

    # Convert to AU for the geodetic iteration.
    x_au = itrs_positions[[.., 0]] / @au_km
    y_au = itrs_positions[[.., 1]] / @au_km
    z_au = itrs_positions[[.., 2]] / @au_km

    a_au = @wgs84_a / @au_km
    r_xy = Nx.sqrt(x_au * x_au + y_au * y_au)

    # Longitude
    lon_raw = Nx.atan2(y_au, x_au)
    lon_shifted = Nx.remainder(lon_raw - pi, tau)
    lon_shifted = Nx.select(lon_shifted < 0, lon_shifted + tau, lon_shifted)
    longitude = lon_shifted - pi

    # Latitude (3 iterations manually unrolled)
    lat = Nx.atan2(z_au, r_xy)

    # Iteration 1
    sin_lat = Nx.sin(lat)
    e2_sin_lat = @wgs84_e2 * sin_lat
    a_c = a_au / Nx.sqrt(1.0 - e2_sin_lat * sin_lat)
    hyp = z_au + a_c * e2_sin_lat
    lat = Nx.atan2(hyp, r_xy)

    # Iteration 2
    sin_lat = Nx.sin(lat)
    e2_sin_lat = @wgs84_e2 * sin_lat
    a_c = a_au / Nx.sqrt(1.0 - e2_sin_lat * sin_lat)
    hyp = z_au + a_c * e2_sin_lat
    lat = Nx.atan2(hyp, r_xy)

    # Iteration 3
    sin_lat = Nx.sin(lat)
    e2_sin_lat = @wgs84_e2 * sin_lat
    a_c = a_au / Nx.sqrt(1.0 - e2_sin_lat * sin_lat)
    hyp = z_au + a_c * e2_sin_lat
    lat = Nx.atan2(hyp, r_xy)

    # Elevation in AU, then convert to km
    altitude_km = (Nx.sqrt(hyp * hyp + r_xy * r_xy) - a_c) * @au_km

    # Convert to degrees
    %{
      latitude: lat * 360.0 / tau,
      longitude: longitude * 360.0 / tau,
      altitude_km: altitude_km
    }
  end
end
