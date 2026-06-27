defmodule Sidereon.NxTest do
  use ExUnit.Case, async: true

  alias Sidereon.Nx, as: SidereonNx

  test "fspl computes correctly" do
    # 32.45 + 20 log10(2400) + 20 log10(400)
    # 32.45 + 67.60 + 52.04 = 152.09
    res = SidereonNx.fspl(400.0, 2400.0)
    assert_in_delta Nx.to_number(res), 152.09, 0.01
  end

  test "link_margin computes correctly" do
    params = %{
      eirp_dbw: 10.0,
      fspl_db: 150.0,
      receiver_gt_dbk: -10.0,
      other_losses_db: 2.0,
      required_cn0_dbhz: 40.0
    }

    # 10.0 + (-10.0) - 150.0 + 228.6 - 2.0 - 40.0 = 36.6
    res = SidereonNx.link_margin(params)
    assert_in_delta Nx.to_number(res), 36.6, 0.01
  end

  test "access_counts counts correctly" do
    # [t, s, g] = [3, 1, 1]
    series = Nx.tensor([[[5.0]], [[15.0]], [[2.0]]])
    counts = SidereonNx.access_counts(series, min_elevation: 10.0)
    assert Nx.to_number(counts[0][0]) == 1
  end

  test "geodetic converts correctly" do
    # Equator 0 lon
    pos1 = Nx.tensor([[6378.137, 0.0, 0.0]], type: :f64)
    res1 = SidereonNx.Geometry.geodetic(pos1)
    assert_in_delta Nx.to_number(res1.latitude[0]), 0.0, 0.001
    assert_in_delta Nx.to_number(res1.longitude[0]), 0.0, 0.001
    assert_in_delta Nx.to_number(res1.altitude_km[0]), 0.0, 0.001

    # North Pole
    pos2 = Nx.tensor([[0.0, 0.0, 6356.752314245179]], type: :f64)
    res2 = SidereonNx.Geometry.geodetic(pos2)
    assert_in_delta Nx.to_number(res2.latitude[0]), 90.0, 0.001
    assert_in_delta Nx.to_number(res2.altitude_km[0]), 0.0, 0.01
  end

  test "look_angles computes correctly" do
    # Station: Austin, TX (30.26, -97.74, 150m)
    # Sat: overhead at 400km
    stations = Nx.tensor([[30.2672, -97.7431, 150.0]], type: :f64)
    stn_itrs = SidereonNx.Geometry.geodetic_to_itrs(stations)

    # Put satellite 400km directly above station
    stn_pos = stn_itrs[0]
    stn_norm = Nx.sqrt(Nx.dot(stn_pos, stn_pos))
    unit_up = Nx.divide(stn_pos, stn_norm)
    sat_pos = Nx.add(stn_pos, Nx.multiply(unit_up, 400.0))

    sat_positions = Nx.reshape(sat_pos, {1, 3})

    res = SidereonNx.look_angles(sat_positions, stations)

    # Elevation should be near 90
    # Higher tolerance because "overhead" in ITRS isn't exactly "overhead" in ENU due to ellipsoid
    assert_in_delta Nx.to_number(res.elevation[0][0]), 90.0, 0.5
    assert_in_delta Nx.to_number(res.range_km[0][0]), 400.0, 0.1
  end
end
