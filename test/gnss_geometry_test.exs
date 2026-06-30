defmodule Sidereon.GNSS.GeometryTest do
  use ExUnit.Case, async: true

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

  setup_all do
    sp3 = SP3.load!(@sp3_path)

    trace = @trace_path |> File.read!() |> Jason.decode!()
    [tx, ty, tz, _b] = Enum.map(trace["fixture"]["final_solution"]["truth_x"], &hex_to_float/1)

    {:ok, sp3: sp3, receiver: {tx, ty, tz}}
  end

  describe "dop/4 cross-check against Positioning" do
    test "every DOP component matches the point-positioning reported DOP", ctx do
      rx = ctx.receiver

      # A GPS-only visible set at the epoch, masked at a 10 deg elevation mask.
      visible =
        Geometry.visible(ctx.sp3, rx, @epoch, systems: ["G"], elevation_mask_deg: 10.0)

      assert length(visible) >= 4

      # Synthesize clean pseudoranges (no atmosphere): the modelled pseudorange
      # is the geometric range plus the receiver clock minus the satellite
      # clock; here the receiver clock is zero, so pr = range - c * sat_clock.
      observations =
        Enum.flat_map(visible, fn %{satellite_id: sat} ->
          case Observables.predict(ctx.sp3, sat, rx, @epoch, light_time: true, sagnac: true) do
            {:ok, o} -> [{sat, o.geometric_range_m - @c * (o.sat_clock_s || 0.0)}]
            {:error, _} -> []
          end
        end)

      {tx, ty, tz} = rx

      {:ok, sol} =
        Positioning.solve(ctx.sp3, observations, @epoch,
          ionosphere: false,
          troposphere: false,
          initial_guess: {tx, ty, tz, 0.0}
        )

      assert %{gdop: _, pdop: _, hdop: _, vdop: _, tdop: _} = sol.dop

      # Independent DOP over the SAME used-satellite set and the SAME converged
      # receiver, with the elevation weighting and corrected line of sight that
      # the point-positioning geometry uses, so the two code paths are
      # apples-to-apples.
      geom =
        Geometry.dop(ctx.sp3, sol.position, @epoch,
          satellites: sol.used_sats,
          weights: :elevation,
          light_time: true
        )

      assert geom.n_satellites == length(sol.used_sats)
      assert geom.satellites == sol.used_sats

      for component <- [:gdop, :pdop, :hdop, :vdop, :tdop] do
        a = Map.fetch!(sol.dop, component)
        b = Map.fetch!(geom, component)
        rel = abs(a - b) / abs(a)

        assert rel < 1.0e-3,
               "#{component}: positioning=#{a} geometry=#{b} relative diff=#{rel}"
      end
    end
  end

  describe "visible/4" do
    test "no returned satellite is below the elevation mask", ctx do
      mask = 15.0
      vis = Geometry.visible(ctx.sp3, ctx.receiver, @epoch, elevation_mask_deg: mask)
      assert vis != []
      assert Enum.all?(vis, &(&1.elevation_deg >= mask))
    end

    test "raising the mask only removes satellites", ctx do
      low = Geometry.visible(ctx.sp3, ctx.receiver, @epoch, elevation_mask_deg: 5.0)
      high = Geometry.visible(ctx.sp3, ctx.receiver, @epoch, elevation_mask_deg: 30.0)

      low_ids = MapSet.new(low, & &1.satellite_id)
      high_ids = MapSet.new(high, & &1.satellite_id)

      assert MapSet.subset?(high_ids, low_ids)
      assert length(high) <= length(low)
    end

    test "counts match a manual az/el filter via Observables", ctx do
      mask = 10.0

      manual =
        ctx.sp3
        |> Observables.predict_all(ctx.receiver, @epoch, light_time: false)
        |> Enum.count(fn
          {<<"G", _::binary>>, {:ok, o}} -> o.elevation_deg >= mask
          _ -> false
        end)

      vis =
        Geometry.visible(ctx.sp3, ctx.receiver, @epoch,
          systems: ["G"],
          elevation_mask_deg: mask
        )

      assert length(vis) == manual
    end

    test "results are sorted by elevation descending", ctx do
      vis = Geometry.visible(ctx.sp3, ctx.receiver, @epoch)
      els = Enum.map(vis, & &1.elevation_deg)
      assert els == Enum.sort(els, :desc)
    end

    test "the system filter keeps only the requested constellations", ctx do
      vis = Geometry.visible(ctx.sp3, ctx.receiver, @epoch, systems: ["G"])
      assert vis != []
      assert Enum.all?(vis, &String.starts_with?(&1.satellite_id, "G"))
    end

    test "an excluded (below-horizon) satellite is not returned", ctx do
      # The full visible set under a low mask; a satellite below the horizon
      # never appears regardless of mask.
      vis =
        Geometry.visible(ctx.sp3, ctx.receiver, @epoch,
          systems: ["G"],
          elevation_mask_deg: 0.0
        )

      below =
        ctx.sp3
        |> Observables.predict_all(ctx.receiver, @epoch, light_time: false)
        |> Enum.find_value(fn
          {<<"G", _::binary>> = sat, {:ok, o}} when o.elevation_deg < 0.0 -> sat
          _ -> false
        end)

      assert below, "expected at least one below-horizon GPS satellite at this epoch"
      refute Enum.any?(vis, &(&1.satellite_id == below))
    end
  end

  describe "dop/4 monotonicity and shape" do
    test "adding a satellite does not increase GDOP", ctx do
      rx = ctx.receiver

      ids =
        ctx.sp3
        |> Geometry.visible(rx, @epoch, systems: ["G"], elevation_mask_deg: 10.0)
        |> Enum.map(& &1.satellite_id)

      assert length(ids) >= 5

      base = Enum.take(ids, 4)
      grown = Enum.take(ids, 5)

      base_dop = Geometry.dop(ctx.sp3, rx, @epoch, satellites: base)
      grown_dop = Geometry.dop(ctx.sp3, rx, @epoch, satellites: grown)

      assert grown_dop.gdop <= base_dop.gdop * (1.0 + 1.0e-9)
    end

    test "a clustered four-satellite set has much worse DOP than a spread set", ctx do
      rx = ctx.receiver

      vis = Geometry.visible(ctx.sp3, rx, @epoch, systems: ["G"], elevation_mask_deg: 10.0)

      # Spread set: extreme azimuths give a well-conditioned geometry.
      spread =
        vis
        |> Enum.sort_by(& &1.azimuth_deg)
        |> pick_spread(4)
        |> Enum.map(& &1.satellite_id)

      # Clustered set: the four highest-elevation satellites point in similar
      # directions, so the geometry is near-degenerate.
      clustered =
        vis
        |> Enum.sort_by(& &1.elevation_deg, :desc)
        |> Enum.take(4)
        |> Enum.map(& &1.satellite_id)

      spread_dop = Geometry.dop(ctx.sp3, rx, @epoch, satellites: spread)
      clustered_dop = Geometry.dop(ctx.sp3, rx, @epoch, satellites: clustered)

      assert clustered_dop.gdop > spread_dop.gdop * 1.5
    end

    test "exposes all five components plus the satellite count and ids", ctx do
      d =
        Geometry.dop(ctx.sp3, ctx.receiver, @epoch, systems: ["G"], elevation_mask_deg: 10.0)

      assert %{gdop: _, pdop: _, hdop: _, vdop: _, tdop: _, n_satellites: n, satellites: ids} = d
      assert n == length(ids)
      assert Enum.all?([d.gdop, d.pdop, d.hdop, d.vdop, d.tdop], &(&1 > 0.0))
    end
  end

  describe "inv4/1" do
    test "A * A^-1 = I to 1e-9 on a known matrix" do
      a = {
        {4.0, 7.0, 2.0, 1.0},
        {3.0, 6.0, 1.0, 2.0},
        {2.0, 5.0, 9.0, 1.0},
        {1.0, 0.0, 3.0, 8.0}
      }

      assert {:ok, inv} = Geometry.inv4(a)

      product =
        for i <- 0..3 do
          for j <- 0..3 do
            Enum.reduce(0..3, 0.0, fn k, acc ->
              acc + elem(elem(a, i), k) * elem(elem(inv, k), j)
            end)
          end
        end

      for i <- 0..3, j <- 0..3 do
        expected = if i == j, do: 1.0, else: 0.0
        got = product |> Enum.at(i) |> Enum.at(j)
        assert abs(got - expected) < 1.0e-9
      end
    end

    test "a singular matrix yields :singular" do
      # Two identical rows -> zero determinant.
      a = {
        {1.0, 2.0, 3.0, 4.0},
        {1.0, 2.0, 3.0, 4.0},
        {5.0, 6.0, 7.0, 8.0},
        {9.0, 1.0, 2.0, 3.0}
      }

      assert :singular = Geometry.inv4(a)
    end
  end

  describe "series" do
    test "dop_series yields one finite-DOP entry per usable epoch", ctx do
      window = {~N[2020-06-24 12:00:00], ~N[2020-06-24 13:00:00]}
      series = Geometry.dop_series(ctx.sp3, ctx.receiver, window, 300, systems: ["G"])

      assert length(series) == 13
      assert Enum.all?(series, fn d -> match?(%NaiveDateTime{}, d.epoch) and d.gdop > 0.0 end)
    end

    test "visibility_series counts visible satellites per epoch", ctx do
      window = {~N[2020-06-24 12:00:00], ~N[2020-06-24 13:00:00]}
      series = Geometry.visibility_series(ctx.sp3, ctx.receiver, window, 300, systems: ["G"])

      assert length(series) == 13
      assert Enum.all?(series, &(&1.n_visible >= 4))
    end

    test "an empty (inverted) window gives an empty series", ctx do
      window = {~N[2020-06-24 13:00:00], ~N[2020-06-24 12:00:00]}
      assert Geometry.dop_series(ctx.sp3, ctx.receiver, window, 300) == []
      assert Geometry.visibility_series(ctx.sp3, ctx.receiver, window, 300) == []
    end
  end

  describe "passes/5" do
    test "a satellite that rises and sets has its peak between rise and set", ctx do
      # A whole-day window samples a satellite from below the mask, up through a
      # peak, and back below it.
      window = {~N[2020-06-24 00:00:00], ~N[2020-06-24 23:45:00]}

      passes =
        Geometry.passes(ctx.sp3, ctx.receiver, window, 900,
          systems: ["G"],
          elevation_mask_deg: 10.0
        )

      assert passes != []

      # Find a pass that both rises and sets strictly inside the window (so the
      # threshold is crossed on both ends, not clamped to the window edge).
      interior =
        Enum.find(passes, fn p ->
          NaiveDateTime.after?(p.rise_epoch, elem(window, 0)) and
            NaiveDateTime.before?(p.set_epoch, elem(window, 1))
        end)

      assert interior, "expected at least one fully-interior pass over the day"

      # Peak lies within [rise, set] and is the maximum elevation.
      assert NaiveDateTime.compare(interior.peak_epoch, interior.rise_epoch) != :lt
      assert NaiveDateTime.compare(interior.peak_epoch, interior.set_epoch) != :gt
      assert interior.peak_elevation_deg >= 10.0

      # The sample just before rise and just after set straddle the mask: below
      # the mask outside the pass.
      before_rise = NaiveDateTime.add(interior.rise_epoch, -900, :second)
      after_set = NaiveDateTime.add(interior.set_epoch, 900, :second)

      {:ok, o_before} =
        Observables.predict(ctx.sp3, interior.satellite_id, ctx.receiver, before_rise, light_time: false)

      {:ok, o_after} =
        Observables.predict(ctx.sp3, interior.satellite_id, ctx.receiver, after_set, light_time: false)

      assert o_before.elevation_deg < 10.0
      assert o_after.elevation_deg < 10.0
    end
  end

  describe "degenerate and error cases (no raise)" do
    test "fewer than four visible satellites yields a tagged error", ctx do
      # An impossibly high mask leaves no usable directions.
      assert {:error, :too_few_satellites} =
               Geometry.dop(ctx.sp3, ctx.receiver, @epoch, elevation_mask_deg: 89.9)
    end

    test "an explicit set of fewer than four satellites yields a tagged error", ctx do
      assert {:error, :too_few_satellites} =
               Geometry.dop(ctx.sp3, ctx.receiver, @epoch, satellites: ["G08", "G10", "G16"])
    end

    test "an unknown receiver shape yields :invalid_receiver from every entry point", ctx do
      bad = %{lat: 1.0, lon: 2.0}
      window = {~N[2020-06-24 12:00:00], ~N[2020-06-24 13:00:00]}

      assert {:error, :invalid_receiver} = Geometry.visible(ctx.sp3, bad, @epoch)
      assert {:error, :invalid_receiver} = Geometry.dop(ctx.sp3, bad, @epoch)
      assert {:error, :invalid_receiver} = Geometry.dop_series(ctx.sp3, bad, window, 300)

      assert {:error, :invalid_receiver} =
               Geometry.visibility_series(ctx.sp3, bad, window, 300)

      assert {:error, :invalid_receiver} = Geometry.passes(ctx.sp3, bad, window, 300)
    end

    test "malformed DOP options return tagged errors", ctx do
      window = {~N[2020-06-24 12:00:00], ~N[2020-06-24 13:00:00]}

      assert Geometry.dop(ctx.sp3, ctx.receiver, @epoch, weights: :bad) ==
               {:error, {:invalid_option, :weights}}

      assert Geometry.dop_series(ctx.sp3, ctx.receiver, window, 300, weights: :bad) ==
               {:error, {:invalid_option, :weights}}

      assert Geometry.dop(ctx.sp3, ctx.receiver, @epoch, satellites: "G01") ==
               {:error, {:invalid_option, :satellites}}

      assert Geometry.dop_series(ctx.sp3, ctx.receiver, window, 300, satellites: "G01") ==
               {:error, {:invalid_option, :satellites}}
    end

    test "series step_seconds is validated before native calls", ctx do
      window = {~N[2020-06-24 12:00:00], ~N[2020-06-24 13:00:00]}

      assert Geometry.dop_series(ctx.sp3, ctx.receiver, window, 0) ==
               {:error, {:invalid_option, :step_seconds}}

      assert Geometry.visibility_series(ctx.sp3, ctx.receiver, window, -1) ==
               {:error, {:invalid_option, :step_seconds}}

      assert Geometry.passes(ctx.sp3, ctx.receiver, window, 300.0) ==
               {:error, {:invalid_option, :step_seconds}}
    end

    test "out-of-coverage epochs and windows return tagged errors", ctx do
      outside_epoch = ~N[2020-06-26 12:00:00]
      outside_window = {~N[2020-06-24 23:30:00], ~N[2020-06-25 00:15:00]}

      assert {:error, :outside_coverage} =
               Geometry.visible(ctx.sp3, ctx.receiver, outside_epoch)

      assert {:error, :outside_coverage} =
               Geometry.dop(ctx.sp3, ctx.receiver, outside_epoch)

      assert {:error, :outside_coverage} =
               Geometry.dop_series(ctx.sp3, ctx.receiver, outside_window, 300)

      assert {:error, :outside_coverage} =
               Geometry.visibility_series(ctx.sp3, ctx.receiver, outside_window, 300)

      assert {:error, :outside_coverage} =
               Geometry.passes(ctx.sp3, ctx.receiver, outside_window, 300)

      refute Geometry.visible(ctx.sp3, ctx.receiver, outside_epoch, extrapolate: true) ==
               {:error, :outside_coverage}
    end
  end

  # Pick `n` roughly evenly-spaced entries from a list (for an azimuth-spread set).
  defp pick_spread(list, n) do
    len = length(list)
    step = max(div(len, n), 1)

    list
    |> Enum.take_every(step)
    |> Enum.take(n)
  end

  defp hex_to_float("0x" <> hex), do: hex_to_float(hex)

  defp hex_to_float(hex) do
    <<f::float-64>> = Base.decode16!(hex, case: :mixed)
    f
  end
end
