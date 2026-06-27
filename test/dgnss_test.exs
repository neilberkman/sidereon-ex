defmodule Sidereon.GNSS.DGNSSTest do
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.DGNSS
  alias Sidereon.GNSS.Geometry
  alias Sidereon.GNSS.Observables
  alias Sidereon.GNSS.Positioning
  alias Sidereon.GNSS.SP3

  # Precise ephemeris fixture: 2020-06-24 00:00..23:45 GPST, 15-min, 96 epochs.
  @sp3_path Path.join(__DIR__, "fixtures/sp3/GRG0MGXFIN_20201760000_01D_15M_ORB.SP3")
  @trace_path Path.join(__DIR__, "fixtures/spp_trace_L2_tropo.json")

  # Noon, well inside the fixture span.
  @epoch ~N[2020-06-24 12:00:00]

  @c 299_792_458.0

  # Distinct receiver clocks (seconds) prove the base clock is absorbed, not leaked.
  @rx_clock_base 1.0e-6
  @rx_clock_rover -2.0e-6

  describe "base position validation" do
    test "corrections/5 with a malformed base position is tagged, never raises" do
      sp3 = SP3.load!(@sp3_path)
      obs = [{"G21", 2.3e7}]

      for bad <- [{1.0, 2.0}, {:a, :b, :c}, {1.0, 2.0, :z}, nil, "nope", %{x_m: 1.0}, %{}] do
        assert DGNSS.corrections(sp3, bad, obs, @epoch) == {:error, :invalid_base_position}
      end
    end

    test "position/6 with a malformed base position is tagged, never raises" do
      sp3 = SP3.load!(@sp3_path)
      obs = [{"G21", 2.3e7}, {"G16", 2.1e7}, {"G20", 2.2e7}, {"G10", 2.4e7}]

      assert DGNSS.position(sp3, {:a, :b, :c}, obs, obs, @epoch) ==
               {:error, :invalid_base_position}
    end
  end

  setup_all do
    sp3 = SP3.load!(@sp3_path)

    trace = @trace_path |> File.read!() |> Jason.decode!()
    [tx, ty, tz, _b] = Enum.map(trace["fixture"]["final_solution"]["truth_x"], &hex_to_float/1)

    base = {tx, ty, tz}

    # Rover offset by a real ~2.6 km baseline (a fixed ECEF delta).
    rover = {tx + 2000.0, ty + 1000.0, tz + 1500.0}

    {:ok, sp3: sp3, base: base, rover: rover}
  end

  describe "common-mode cancellation (strong)" do
    test "a common per-sat error cancels and DGNSS recovers the rover truth", ctx do
      sats = common_visible(ctx.sp3, ctx.base, ctx.rover)
      assert length(sats) >= 5

      # Seeded per-satellite common error in +/- 30 m.
      :rand.seed(:exsss, {1, 2, 3})
      errors = Map.new(sats, fn sat -> {sat, (:rand.uniform() - 0.5) * 60.0} end)

      base_clean = synth(ctx.sp3, sats, ctx.base, @rx_clock_base)
      rover_clean = synth(ctx.sp3, sats, ctx.rover, @rx_clock_rover)

      base_obs = inject(base_clean, errors)
      rover_obs = inject(rover_clean, errors)

      # (a) Absolute solve of the rover's errored pseudoranges: biased.
      {:ok, abs_sol} =
        Positioning.solve(ctx.sp3, rover_obs, @epoch,
          ionosphere: false,
          troposphere: false,
          initial_guess: guess(ctx.rover)
        )

      abs_err = dist(abs_sol.position, ctx.rover)

      # (b) DGNSS-corrected rover solve.
      {:ok, dg} =
        DGNSS.position(ctx.sp3, ctx.base, base_obs, rover_obs, @epoch,
          initial_guess: guess(ctx.rover)
        )

      dgnss_err = dist(dg.solution.position, ctx.rover)

      # Reference: a clean (no common error) DGNSS solve.
      {:ok, dg_clean} =
        DGNSS.position(ctx.sp3, ctx.base, base_clean, rover_clean, @epoch,
          initial_guess: guess(ctx.rover)
        )

      no_error_err = dist(dg_clean.solution.position, ctx.rover)

      # The injected common error biases the absolute solve by metres.
      assert abs_err > 5.0,
             "expected the absolute errored solve to be biased; got #{abs_err} m"

      # The DGNSS solve recovers the rover truth to the no-error baseline: the
      # common per-sat error cancels to ~machine precision.
      assert_in_delta dgnss_err, no_error_err, 1.0e-3

      # And the DGNSS error is far smaller than the absolute error.
      assert dgnss_err < abs_err / 100.0,
             "dgnss_err=#{dgnss_err} abs_err=#{abs_err}"

      # PRC recovers the injected common error one-for-one.
      {:ok, prc} = DGNSS.corrections(ctx.sp3, ctx.base, base_obs, @epoch)
      {:ok, prc0} = DGNSS.corrections(ctx.sp3, ctx.base, base_clean, @epoch)

      for sat <- sats do
        recovered = prc[sat] - prc0[sat]
        assert_in_delta recovered, errors[sat], 1.0e-6
      end

      # The baseline length is reported and matches the true ~2.6 km separation.
      true_baseline = dist_xyz(ctx.base, ctx.rover)
      assert_in_delta dg_clean.baseline_m, true_baseline, 1.0e-2
    end
  end

  describe "zero baseline" do
    test "base == rover with a pure common bias recovers the position exactly", ctx do
      sats = common_visible(ctx.sp3, ctx.base, ctx.base)
      clean = synth(ctx.sp3, sats, ctx.base, @rx_clock_base)

      # A pure common per-sat bias (same on base and rover).
      :rand.seed(:exsss, {7, 8, 9})
      errors = Map.new(sats, fn sat -> {sat, (:rand.uniform() - 0.5) * 50.0} end)
      obs = inject(clean, errors)

      {:ok, dg} =
        DGNSS.position(ctx.sp3, ctx.base, obs, obs, @epoch, initial_guess: guess(ctx.base))

      assert dist(dg.solution.position, ctx.base) < 1.0e-3
      assert dg.baseline_m < 1.0e-3
    end
  end

  describe "atmosphere-like common term" do
    test "an elevation-scaled common delay cancels", ctx do
      sats = common_visible(ctx.sp3, ctx.base, ctx.rover)

      base_clean = synth(ctx.sp3, sats, ctx.base, @rx_clock_base)
      rover_clean = synth(ctx.sp3, sats, ctx.rover, @rx_clock_rover)

      # Common iono/tropo-like delay: larger at low elevation, +5..+15 m.
      delays =
        Map.new(sats, fn sat ->
          {:ok, o} = Observables.predict(ctx.sp3, sat, ctx.base, @epoch)
          el = max(o.elevation_deg, 5.0)
          {sat, 5.0 + 10.0 / :math.sin(el * :math.pi() / 180.0)}
        end)

      base_obs = inject(base_clean, delays)
      rover_obs = inject(rover_clean, delays)

      {:ok, dg} =
        DGNSS.position(ctx.sp3, ctx.base, base_obs, rover_obs, @epoch,
          initial_guess: guess(ctx.rover)
        )

      {:ok, dg_clean} =
        DGNSS.position(ctx.sp3, ctx.base, base_clean, rover_clean, @epoch,
          initial_guess: guess(ctx.rover)
        )

      assert_in_delta dist(dg.solution.position, ctx.rover),
                      dist(dg_clean.solution.position, ctx.rover),
                      1.0e-3
    end
  end

  describe "apply/2 pairing" do
    test "an unmatched rover sat is dropped and reported; corrections-only sats ignored" do
      corrections = %{"G01" => 1.0, "G02" => 2.0, "G05" => 5.0}
      rover = [{"G01", 100.0}, {"G02", 200.0}, {"G09", 900.0}]

      {corrected, dropped} = DGNSS.apply(rover, corrections)

      assert corrected == [{"G01", 99.0}, {"G02", 198.0}]
      assert dropped == ["G09"]
    end

    test "pairing is order-independent" do
      corrections = %{"G01" => 1.0, "G02" => 2.0, "G05" => 5.0}
      a = [{"G01", 100.0}, {"G02", 200.0}, {"G05", 500.0}]
      b = [{"G05", 500.0}, {"G01", 100.0}, {"G02", 200.0}]

      {ca, _} = DGNSS.apply(a, corrections)
      {cb, _} = DGNSS.apply(b, corrections)

      assert Map.new(ca) == Map.new(cb)
    end
  end

  describe "error cases (tagged, no raise)" do
    test "too few common satellites propagates from the position solve", ctx do
      sats = common_visible(ctx.sp3, ctx.base, ctx.rover) |> Enum.take(2)
      base_obs = synth(ctx.sp3, sats, ctx.base, @rx_clock_base)
      rover_obs = synth(ctx.sp3, sats, ctx.rover, @rx_clock_rover)

      assert {:error, {:too_few_satellites, _used, _required}} =
               DGNSS.position(ctx.sp3, ctx.base, base_obs, rover_obs, @epoch)
    end

    test "a malformed base observation is tagged", ctx do
      assert {:error, {:invalid_base_observations, _}} =
               DGNSS.corrections(ctx.sp3, ctx.base, [{"G01", :bad}], @epoch)
    end

    test "an empty base observation list is tagged", ctx do
      assert {:error, :empty_base_observations} =
               DGNSS.corrections(ctx.sp3, ctx.base, [], @epoch)
    end

    test "a malformed rover observation is tagged", ctx do
      base_obs = synth(ctx.sp3, common_visible(ctx.sp3, ctx.base, ctx.rover), ctx.base, 0.0)

      assert {:error, {:invalid_rover_observations, _}} =
               DGNSS.position(ctx.sp3, ctx.base, base_obs, [{"G01", :bad}], @epoch)
    end

    test "an empty rover observation list is tagged", ctx do
      base_obs = synth(ctx.sp3, common_visible(ctx.sp3, ctx.base, ctx.rover), ctx.base, 0.0)

      assert {:error, :empty_rover_observations} =
               DGNSS.position(ctx.sp3, ctx.base, base_obs, [], @epoch)
    end

    test "a base sat with no ephemeris is dropped from corrections, not a crash", ctx do
      sats = common_visible(ctx.sp3, ctx.base, ctx.rover)
      obs = synth(ctx.sp3, sats, ctx.base, 0.0) ++ [{"G99", 2.0e7}]

      {:ok, prc} = DGNSS.corrections(ctx.sp3, ctx.base, obs, @epoch)
      refute Map.has_key?(prc, "G99")
      assert map_size(prc) == length(sats)
    end
  end

  # --- helpers -------------------------------------------------------------

  # Satellites visible from BOTH stations (GPS, 10 deg mask).
  defp common_visible(sp3, base, rover) do
    b = visible_ids(sp3, base)
    r = visible_ids(sp3, rover)
    MapSet.intersection(MapSet.new(b), MapSet.new(r)) |> MapSet.to_list() |> Enum.sort()
  end

  defp visible_ids(sp3, station) do
    sp3
    |> Geometry.visible(station, @epoch, systems: ["G"], elevation_mask_deg: 10.0)
    |> Enum.map(& &1.satellite_id)
  end

  # Clean pseudorange: pr = geometric_range + c*(rx_clock - sat_clock).
  defp synth(sp3, sats, station, rx_clock_s) do
    Enum.map(sats, fn sat ->
      {:ok, o} =
        Observables.predict(sp3, sat, station, @epoch, light_time: true, sagnac: true)

      {sat, o.geometric_range_m + @c * (rx_clock_s - (o.sat_clock_s || 0.0))}
    end)
  end

  defp inject(observations, errors) do
    Enum.map(observations, fn {sat, pr} -> {sat, pr + Map.fetch!(errors, sat)} end)
  end

  defp guess({x, y, z}), do: {x, y, z, 0.0}

  defp dist(%{x_m: x, y_m: y, z_m: z}, {tx, ty, tz}) do
    :math.sqrt((x - tx) * (x - tx) + (y - ty) * (y - ty) + (z - tz) * (z - tz))
  end

  defp dist_xyz({ax, ay, az}, {bx, by, bz}) do
    :math.sqrt((ax - bx) * (ax - bx) + (ay - by) * (ay - by) + (az - bz) * (az - bz))
  end

  defp hex_to_float("0x" <> hex), do: hex_to_float(hex)

  defp hex_to_float(hex) do
    <<f::float-64>> = Base.decode16!(hex, case: :mixed)
    f
  end
end
