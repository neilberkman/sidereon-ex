defmodule Sidereon.GNSS.ObservablesTest do
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.Observables
  alias Sidereon.GNSS.SP3

  @grg Path.join(__DIR__, "fixtures/sp3/GRG0MGXFIN_20201760000_01D_15M_ORB.SP3")

  # A plausible, attested ground receiver in ITRF/ECEF metres (near IGS ESBC,
  # Copenhagen; ~55.74 N, 12.53 E). Same position used as a known receiver in
  # the point-positioning tests.
  @rx {3_512_900.0, 780_500.0, 5_248_700.0}

  # Interior epoch (file spans 2020-06-24 00:00 -> 23:45 GPST at 900 s nodes),
  # safe for sub-second light-time / finite-difference evaluation.
  @epoch ~N[2020-06-24 12:00:00]

  @c 299_792_458.0
  @f_l1 1_575_420_000.0

  describe "predict/5 receiver validation" do
    test "a malformed receiver yields {:error, :invalid_receiver}, never raising" do
      sp3 = SP3.load!(@grg)

      for bad <- [{1.0, 2.0}, {:a, :b, :c}, {1.0, 2.0, :z}, nil, "nope", %{x_m: 1.0}, %{}] do
        assert Observables.predict(sp3, "G21", bad, @epoch) == {:error, :invalid_receiver}
      end
    end
  end

  setup do
    sp3 = SP3.load!(@grg)

    results = Observables.predict_all(sp3, @rx, @epoch)

    visible =
      results
      |> Enum.filter(fn {_id, r} -> match?({:ok, _}, r) end)
      |> Enum.filter(fn {id, _} -> String.starts_with?(id, "G") end)
      |> Enum.map(fn {id, {:ok, obs}} -> {id, obs} end)

    # Highest GPS satellite in the sky and one below the horizon, chosen
    # empirically so the test does not hard-code a fragile PRN.
    {high_id, high} = Enum.max_by(visible, fn {_id, obs} -> obs.elevation_deg end)

    below =
      Enum.find(visible, fn {_id, obs} -> obs.elevation_deg < 0.0 end)

    {:ok, sp3: sp3, high_id: high_id, high: high, below: below, visible: visible}
  end

  describe "predict/5 physics" do
    test "range_rate equals the central finite difference of geometric range (mm/s)",
         %{sp3: sp3, high_id: id} do
      {:ok, obs} = Observables.predict(sp3, id, @rx, @epoch)

      dt = 0.5
      t_plus = NaiveDateTime.add(@epoch, round(dt * 1_000_000), :microsecond)
      t_minus = NaiveDateTime.add(@epoch, -round(dt * 1_000_000), :microsecond)

      {:ok, op} = Observables.predict(sp3, id, @rx, t_plus)
      {:ok, om} = Observables.predict(sp3, id, @rx, t_minus)

      fd = (op.geometric_range_m - om.geometric_range_m) / (2.0 * dt)

      assert_in_delta obs.range_rate_m_s, fd, 1.0e-3
    end

    test "light-time: transmit_time is ~67-90 ms before epoch for a GPS MEO sat",
         %{sp3: sp3, high_id: id} do
      {:ok, obs} = Observables.predict(sp3, id, @rx, @epoch)

      light_time_s =
        NaiveDateTime.diff(@epoch, obs.transmit_time, :microsecond) / 1.0e6

      assert light_time_s >= 0.06
      assert light_time_s <= 0.092
    end

    test "light-time correction shifts the range by tens of metres of along-track geometry",
         %{sp3: sp3, high_id: id} do
      {:ok, on} = Observables.predict(sp3, id, @rx, @epoch, light_time: true)
      {:ok, off} = Observables.predict(sp3, id, @rx, @epoch, light_time: false)

      # With light_time: false the satellite is sampled at the receive epoch.
      assert off.transmit_time == @epoch

      # The along-track displacement over the ~70 ms light time, projected onto
      # the line of sight, is metres to tens of metres depending on geometry.
      diff = abs(on.geometric_range_m - off.geometric_range_m)
      assert diff > 1.0
      assert diff < 1000.0
    end

    test "geometric range is in the MEO band", %{high: high} do
      assert high.geometric_range_m >= 2.0e7
      assert high.geometric_range_m <= 2.7e7
    end

    test "a satellite high in the sky gives high elevation", %{high: high} do
      assert high.elevation_deg > 40.0
      assert high.azimuth_deg >= 0.0
      assert high.azimuth_deg < 360.0
    end

    test "a satellite below the horizon gives negative elevation", %{below: below} do
      assert below != nil, "expected at least one GPS sat below the horizon at this epoch"
      {_id, obs} = below
      assert obs.elevation_deg < 0.0
    end

    test "azimuth is in [0, 360) for all visible satellites", %{visible: visible} do
      for {_id, obs} <- visible do
        assert obs.azimuth_deg >= 0.0
        assert obs.azimuth_deg < 360.0
      end
    end

    test "elevation/azimuth match an independent ENU recomputation", %{high_id: id, sp3: sp3} do
      {:ok, obs} = Observables.predict(sp3, id, @rx, @epoch)

      {rx, ry, rz} = @rx

      # Build the ECEF line-of-sight from scratch (NOT from obs.los_unit): run an
      # independent light-time + Sagnac model directly off Sidereon.GNSS.SP3.position so
      # the dx,dy,dz that feed the ENU rotation are derived by a separate code
      # path, not reused from the value under test.
      {dx, dy, dz, r} = independent_los(sp3, id, rx, ry, rz)

      {lat, lon} = independent_geodetic(rx, ry, rz)

      sl = :math.sin(lat)
      cl = :math.cos(lat)
      so = :math.sin(lon)
      co = :math.cos(lon)

      e = -so * dx + co * dy
      n = -sl * co * dx - sl * so * dy + cl * dz
      u = cl * co * dx + cl * so * dy + sl * dz

      az = :math.atan2(e, n) * 180.0 / :math.pi()
      az = if az < 0.0, do: az + 360.0, else: az
      el = :math.asin(u / r) * 180.0 / :math.pi()

      assert_in_delta obs.elevation_deg, el, 1.0e-6
      assert_in_delta obs.azimuth_deg, az, 1.0e-6

      # Sanity: the independently reconstructed range agrees with the reported one.
      assert_in_delta r, obs.geometric_range_m, 1.0e-3
    end

    test "Doppler is within the GPS static envelope and has the right sign", %{high: high} do
      assert abs(high.doppler_hz) <= 5000.0

      # Doppler is the negative of the (scaled) range rate.
      assert_in_delta high.doppler_hz, -high.range_rate_m_s * @f_l1 / @c, 1.0e-6

      if high.range_rate_m_s != 0.0 do
        assert sign(high.doppler_hz) == -sign(high.range_rate_m_s)
      end
    end

    test "carrier_hz scales Doppler linearly", %{sp3: sp3, high_id: id} do
      {:ok, base} = Observables.predict(sp3, id, @rx, @epoch)
      {:ok, scaled} = Observables.predict(sp3, id, @rx, @epoch, carrier_hz: 2.0 * @f_l1)

      assert_in_delta scaled.doppler_hz, 2.0 * base.doppler_hz, 1.0e-6
    end

    test "sat_clock_s equals the SP3 clock at the transmit time", %{sp3: sp3, high_id: id} do
      {:ok, obs} = Observables.predict(sp3, id, @rx, @epoch)
      {:ok, state} = SP3.position(sp3, id, obs.transmit_time)

      assert_in_delta obs.sat_clock_s, state.clock_s, 1.0e-15
    end
  end

  describe "predict/5 errors" do
    test "unknown satellite -> tagged error, no raise", %{sp3: sp3} do
      # G23 is not declared in the GRG product header.
      refute "G23" in SP3.satellite_ids(sp3)
      assert {:error, _reason} = Observables.predict(sp3, "G23", @rx, @epoch)
    end

    # The SP3 primitive gates its node coverage: an epoch well beyond the product
    # is refused with a tagged error rather than extrapolating the spline to a
    # non-physical range. Edge epochs within one sampling step still interpolate.
    test "out-of-coverage epoch is refused instead of extrapolating",
         %{sp3: sp3, high_id: id} do
      assert {:error, :outside_coverage} =
               Observables.predict(sp3, id, @rx, ~N[2020-06-26 12:00:00])
    end

    test "malformed satellite token -> tagged error", %{sp3: sp3} do
      assert {:error, {:bad_sat_id, _}} = Observables.predict(sp3, "GXX", @rx, @epoch)
    end
  end

  # Independent light-time + Sagnac line-of-sight straight from Sidereon.GNSS.SP3.position,
  # so the ENU cross-check is fed dx,dy,dz from a different code path than the one
  # under test. Returns {dx, dy, dz, range} in the receive-epoch ECEF frame.
  @omega_e 7.2921151467e-5

  defp independent_los(sp3, id, rx, ry, rz) do
    # Fixed-point on tau = range / c, starting at the receive epoch.
    tau =
      Enum.reduce(1..5, 0.0, fn _i, tau_acc ->
        t_tx = NaiveDateTime.add(@epoch, -round(tau_acc * 1_000_000), :microsecond)
        {:ok, s} = SP3.position(sp3, id, t_tx)
        {sx, sy, sz} = sagnac_rotate(s.x_m, s.y_m, s.z_m, tau_acc)
        dx = sx - rx
        dy = sy - ry
        dz = sz - rz
        :math.sqrt(dx * dx + dy * dy + dz * dz) / @c
      end)

    t_tx = NaiveDateTime.add(@epoch, -round(tau * 1_000_000), :microsecond)
    {:ok, s} = SP3.position(sp3, id, t_tx)
    {sx, sy, sz} = sagnac_rotate(s.x_m, s.y_m, s.z_m, tau)
    dx = sx - rx
    dy = sy - ry
    dz = sz - rz
    {dx, dy, dz, :math.sqrt(dx * dx + dy * dy + dz * dz)}
  end

  defp sagnac_rotate(x, y, z, tau) do
    theta = @omega_e * tau
    c = :math.cos(theta)
    s = :math.sin(theta)
    {c * x + s * y, -s * x + c * y, z}
  end

  # Independent closed-form WGS84 inverse (Bowring) for the ENU cross-check;
  # returns {lat_rad, lon_rad}. Does not call the production helper.
  defp independent_geodetic(x, y, z) do
    a = 6_378_137.0
    f = 1.0 / 298.257223563
    e2 = f * (2.0 - f)
    b = a * (1.0 - f)
    ep2 = (a * a - b * b) / (b * b)

    lon = :math.atan2(y, x)
    p = :math.sqrt(x * x + y * y)
    theta = :math.atan2(z * a, p * b)

    lat =
      :math.atan2(
        z + ep2 * b * :math.pow(:math.sin(theta), 3),
        p - e2 * a * :math.pow(:math.cos(theta), 3)
      )

    {lat, lon}
  end

  defp sign(v) when v > 0.0, do: 1
  defp sign(v) when v < 0.0, do: -1
  defp sign(_), do: 0
end
