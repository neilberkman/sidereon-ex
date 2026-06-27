defmodule Sidereon.GNSS.ReducedOrbit.PiecewiseTest do
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.ReducedOrbit
  alias Sidereon.GNSS.ReducedOrbit.Piecewise

  @grg Path.join(__DIR__, "fixtures/sp3/GRG0MGXFIN_20201760000_01D_15M_ORB.SP3")
  @gbm Path.join(__DIR__, "fixtures/sp3/GBM_BDS_C21_C08_trim.sp3")

  # GRG: GPS G + Galileo E, GPST, 2020-06-24 00:00:00 -> 23:45:00 on a 15-min grid.
  @gps "G21"
  @gal "E01"
  @t0 ~N[2020-06-24 00:00:00]
  @day_end ~N[2020-06-24 23:45:00]
  @span {@t0, @day_end}

  # GBM (trimmed): BeiDou C21 (MEO) + C08 (IGSO), GPST, 2020-06-25 00:00:00 ->
  # 23:55:00 on a 5-min grid.
  @bt0 ~N[2020-06-25 00:00:00]
  @b_end ~N[2020-06-25 23:55:00]
  @bspan {@bt0, @b_end}

  setup_all do
    {:ok, grg: Sidereon.GNSS.SP3.load!(@grg), gbm: Sidereon.GNSS.SP3.load!(@gbm)}
  end

  # Fit single + 2h-piecewise over the whole span and drift both over it.
  defp single_vs_pw(sp3, sat, span, fit_cad, drift_cad, model) do
    {:ok, single} =
      ReducedOrbit.fit(sp3, satellite_id: sat, window: span, cadence_s: fit_cad, model: model)

    {:ok, pw} =
      Piecewise.fit(sp3,
        satellite_id: sat,
        window: span,
        segment_s: 7200,
        cadence_s: fit_cad,
        model: model
      )

    {:ok, ds} =
      ReducedOrbit.drift(single, sp3,
        satellite_id: sat,
        window: span,
        cadence_s: drift_cad,
        threshold_m: 1.0e9
      )

    {:ok, dp} =
      Piecewise.drift(pw, sp3,
        satellite_id: sat,
        window: span,
        cadence_s: drift_cad,
        threshold_m: 1.0e9
      )

    {single, pw, ds, dp}
  end

  describe "piecewise-vs-single drift table (real SP3, measure-first bounds)" do
    # Measured: single max 1436.94 km, pw 2h max 330.54 km (12 segments).
    test "GPS G21 circular: 2h piecewise collapses the a*e drift", %{grg: grg} do
      {_single, pw, ds, dp} = single_vs_pw(grg, @gps, @span, 900, 1800, :circular_secular)

      assert length(pw.segments) == 12
      assert ds.max_m > 800_000.0, "single max #{Float.round(ds.max_m / 1000, 1)} km"
      assert dp.max_m < 500_000.0, "pw max #{Float.round(dp.max_m / 1000, 1)} km"
      # Dramatically better (>3x), not a tautology.
      assert dp.max_m < ds.max_m / 3.0
      assert dp.rms_m < ds.rms_m / 3.0
    end

    # Measured: single max 0.44 km, pw 2h max 0.09 km.
    test "GPS G21 eccentric: already sub-km, piecewise tighter still", %{grg: grg} do
      {_single, _pw, ds, dp} = single_vs_pw(grg, @gps, @span, 900, 1800, :eccentric_secular)

      assert ds.max_m < 2_000.0, "single max #{Float.round(ds.max_m, 1)} m"
      assert dp.max_m < 1_000.0, "pw max #{Float.round(dp.max_m, 1)} m"
      assert dp.max_m < ds.max_m
    end

    # Measured: single max 6.78 km, pw 2h max 1.24 km.
    test "Galileo E01 circular: near-circular, piecewise still clearly better", %{grg: grg} do
      {_single, _pw, ds, dp} = single_vs_pw(grg, @gal, @span, 900, 1800, :circular_secular)

      assert ds.max_m < 20_000.0, "single max #{Float.round(ds.max_m / 1000, 2)} km"
      assert dp.max_m < 5_000.0, "pw max #{Float.round(dp.max_m / 1000, 2)} km"
      # Not a regression, and a real improvement on this small-error orbit.
      assert dp.max_m < ds.max_m
    end

    # Measured: single max 0.78 km, pw 2h max 0.09 km.
    test "Galileo E01 eccentric: comparable single, piecewise tighter", %{grg: grg} do
      {_single, _pw, ds, dp} = single_vs_pw(grg, @gal, @span, 900, 1800, :eccentric_secular)

      assert ds.max_m < 3_000.0, "single max #{Float.round(ds.max_m, 1)} m"
      assert dp.max_m < 1_000.0, "pw max #{Float.round(dp.max_m, 1)} m"
      assert dp.max_m < ds.max_m
    end

    # Measured: C21 circular single 53.8 km / pw 11.67 km; C08 circular single
    # 533.47 km / pw 49.73 km.
    test "BeiDou MEO C21 + IGSO C08 circular: piecewise beats single", %{gbm: gbm} do
      for sat <- ["C21", "C08"] do
        {_single, _pw, ds, dp} = single_vs_pw(gbm, sat, @bspan, 300, 1200, :circular_secular)

        assert ds.max_m > 30_000.0, "#{sat} single #{Float.round(ds.max_m / 1000, 1)} km"
        assert dp.max_m < ds.max_m / 3.0, "#{sat} pw #{Float.round(dp.max_m / 1000, 1)} km"
        assert dp.rms_m < ds.rms_m / 3.0
      end
    end

    # Measured: C21 eccentric single 0.43 km / pw 0.12 km; C08 eccentric single
    # 0.87 km / pw 0.02 km.
    test "BeiDou MEO C21 + IGSO C08 eccentric: sub-km, piecewise tighter", %{gbm: gbm} do
      for sat <- ["C21", "C08"] do
        {_single, _pw, ds, dp} = single_vs_pw(gbm, sat, @bspan, 300, 1200, :eccentric_secular)

        assert ds.max_m < 3_000.0, "#{sat} single #{Float.round(ds.max_m, 1)} m"
        assert dp.max_m < 1_000.0, "#{sat} pw #{Float.round(dp.max_m, 1)} m"
        assert dp.max_m < ds.max_m
      end
    end

    # Shorter segments are monotonically more accurate (accuracy-for-bytes).
    test "shorter segments shrink the residual", %{grg: grg} do
      drift_for = fn seg_s ->
        {:ok, pw} =
          Piecewise.fit(grg,
            satellite_id: @gps,
            window: @span,
            segment_s: seg_s,
            cadence_s: 900,
            model: :circular_secular
          )

        {:ok, d} =
          Piecewise.drift(pw, grg,
            satellite_id: @gps,
            window: @span,
            cadence_s: 1800,
            threshold_m: 1.0e9
          )

        d.max_m
      end

      m2 = drift_for.(7200)
      m4 = drift_for.(14_400)
      m6 = drift_for.(21_600)
      assert m2 < m4
      assert m4 < m6
    end

    test "ISS TLE/SGP4 source: 30-minute eccentric segments stay near SGP4" do
      tle = iss_tle!()
      t0 = ~N[2018-07-04 00:00:00]
      tend = ~N[2018-07-04 04:00:00]

      {:ok, pw} =
        Piecewise.fit(tle,
          window: {t0, tend},
          segment_s: 1800,
          cadence_s: 120,
          model: :eccentric_secular
        )

      assert pw.time_scale == "UTC"
      assert length(pw.segments) == 8
      assert Enum.all?(pw.segments, &(&1.model.fit.source == "sgp4:25544"))

      {:ok, d} =
        Piecewise.drift(pw, tle,
          window: {t0, tend},
          cadence_s: 300,
          threshold_m: 2_000.0
        )

      assert d.requested == 49
      assert d.used == 49
      assert d.max_m < 1_500.0
      assert d.rms_m < 1_000.0
      assert d.threshold_horizon == nil
    end
  end

  describe "segment selection" do
    setup %{grg: grg} do
      {:ok, pw} =
        Piecewise.fit(grg,
          satellite_id: @gps,
          window: @span,
          segment_s: 7200,
          cadence_s: 900,
          model: :circular_secular
        )

      {:ok, pw: pw}
    end

    test "segment count is ceil(span / segment_s)", %{pw: pw} do
      span_s = NaiveDateTime.diff(@day_end, @t0)
      assert length(pw.segments) == ceil(span_s / 7200)
    end

    test "a query inside segment k uses segment k's evaluation", %{pw: pw} do
      seg = Enum.at(pw.segments, 3)
      # Middle of the 4th segment.
      epoch = NaiveDateTime.add(seg.t0, 1800, :second)

      {:ok, direct} = ReducedOrbit.position(seg.model, epoch)
      {:ok, via_pw} = Piecewise.position(pw, epoch)
      assert via_pw == direct

      # And it is *not* a neighbouring segment's value.
      {:ok, other} = ReducedOrbit.position(Enum.at(pw.segments, 4).model, epoch)
      assert via_pw != other
    end

    test "an interior boundary epoch resolves to the later segment", %{pw: pw} do
      seg_k = Enum.at(pw.segments, 2)
      seg_k1 = Enum.at(pw.segments, 3)
      # Exactly seg_k.t1 == seg_k1.t0.
      boundary = seg_k.t1
      assert NaiveDateTime.compare(boundary, seg_k1.t0) == :eq

      {:ok, via_pw} = Piecewise.position(pw, boundary)
      {:ok, later} = ReducedOrbit.position(seg_k1.model, boundary)
      {:ok, earlier} = ReducedOrbit.position(seg_k.model, boundary)
      assert via_pw == later
      assert via_pw != earlier
    end

    test "the exact end-of-span epoch resolves to the last segment", %{pw: pw} do
      last = List.last(pw.segments)
      {:ok, via_pw} = Piecewise.position(pw, @day_end)
      {:ok, direct} = ReducedOrbit.position(last.model, @day_end)
      assert via_pw == direct
    end

    test "epochs before t0 or after t1 are out of range", %{pw: pw} do
      before = NaiveDateTime.add(@t0, -1, :second)
      aft = NaiveDateTime.add(@day_end, 1, :second)
      assert {:error, :out_of_range} = Piecewise.position(pw, before)
      assert {:error, :out_of_range} = Piecewise.position(pw, aft)
      assert {:error, :out_of_range} = Piecewise.position_velocity(pw, aft)
    end

    test "position_velocity delegates to the covering segment", %{pw: pw} do
      seg = Enum.at(pw.segments, 1)
      epoch = NaiveDateTime.add(seg.t0, 900, :second)
      {:ok, direct} = ReducedOrbit.position_velocity(seg.model, epoch, frame: :gcrs)
      {:ok, via_pw} = Piecewise.position_velocity(pw, epoch, frame: :gcrs)
      assert via_pw == direct
    end

    test "a dropped under-covered terminal segment shrinks the window to real coverage",
         %{grg: grg} do
      # The trailing 5-min segment over a 15-min grid is under-covered and dropped;
      # the stored window must end at the last kept segment so there is no
      # uncovered tail and the end-of-span epoch still resolves to the last segment.
      wend = ~N[2020-06-24 04:05:00]

      {:ok, pw} =
        Piecewise.fit(grg,
          satellite_id: @gps,
          window: {@t0, wend},
          segment_s: 7200,
          cadence_s: 900
        )

      {_w0, coverage_end} = pw.window
      last = List.last(pw.segments)
      assert NaiveDateTime.compare(coverage_end, last.t1) == :eq
      # Below the requested wend: the dropped tail is not advertised.
      assert NaiveDateTime.before?(coverage_end, wend)

      # The (new) end-of-span resolves to the last kept segment, not :out_of_range.
      {:ok, via_pw} = Piecewise.position(pw, coverage_end)
      {:ok, direct} = ReducedOrbit.position(last.model, coverage_end)
      assert via_pw == direct

      # Anything past the real coverage is out of range.
      assert {:error, :out_of_range} =
               Piecewise.position(pw, NaiveDateTime.add(coverage_end, 1, :second))
    end
  end

  describe "to_map/1 and from_map/1" do
    setup %{grg: grg} do
      {:ok, pw} =
        Piecewise.fit(grg,
          satellite_id: @gps,
          window: @span,
          segment_s: 7200,
          cadence_s: 900,
          model: :eccentric_secular
        )

      {:ok, pw: pw}
    end

    test "round-trips segment count, windows, elements and metadata", %{pw: pw} do
      map = Piecewise.to_map(pw)
      assert map["version"] == 1
      assert map["kind"] == "piecewise"
      assert map["model"] == "eccentric_secular"
      assert map["frame"] == "GCRS"
      assert map["time_scale"] == "GPST"
      assert map["segment_s"] == 7200
      assert length(map["segments"]) == length(pw.segments)

      assert {:ok, back} = Piecewise.from_map(map)
      assert length(back.segments) == length(pw.segments)
      assert back.window == pw.window
      assert back.segment_s == pw.segment_s
      assert back.model == pw.model
      assert back.time_scale == pw.time_scale

      for {a, b} <- Enum.zip(pw.segments, back.segments) do
        assert a.t0 == b.t0
        assert a.t1 == b.t1
        assert b.model.model == "eccentric_secular"
        assert_in_delta b.model.a_m, a.model.a_m, 1.0e-6
        assert_in_delta b.model.h, a.model.h, 1.0e-12
        assert_in_delta b.model.k, a.model.k, 1.0e-12
        assert b.model.epoch == a.model.epoch
      end
    end

    test "survives a JSON round-trip", %{pw: pw} do
      decoded = pw |> Piecewise.to_map() |> Jason.encode!() |> Jason.decode!()
      assert {:ok, back} = Piecewise.from_map(decoded)
      assert length(back.segments) == length(pw.segments)
      assert back.window == pw.window

      first_a = hd(pw.segments).model
      first_b = hd(back.segments).model
      assert_in_delta first_b.a_m, first_a.a_m, 1.0e-6
      assert_in_delta first_b.h, first_a.h, 1.0e-12
    end

    test "a circular piecewise model also round-trips", %{grg: grg} do
      {:ok, circ} =
        Piecewise.fit(grg,
          satellite_id: @gal,
          window: @span,
          segment_s: 7200,
          cadence_s: 900
        )

      assert {:ok, back} = circ |> Piecewise.to_map() |> Piecewise.from_map()
      assert back.model == "circular_secular"
      assert length(back.segments) == length(circ.segments)
      assert hd(back.segments).model.h == nil
    end
  end

  describe "fit/2 segment validation" do
    test "a :segment_s that rounds below one second is rejected, not hung", %{grg: grg} do
      win = {@t0, ~N[2020-06-24 04:00:00]}

      # round(0.1) == 0 would make the segment tiling step 0 and loop forever;
      # it must be rejected up front instead.
      assert {:error, :invalid_segment} =
               Piecewise.fit(grg, satellite_id: @gps, window: win, segment_s: 0.1)

      assert {:error, :invalid_segment} =
               Piecewise.fit(grg, satellite_id: @gps, window: win, segment_s: 0)

      assert {:error, :invalid_segment} =
               Piecewise.fit(grg, satellite_id: @gps, window: win, segment_s: -5)
    end
  end

  describe "malformed piecewise maps" do
    setup %{grg: grg} do
      {:ok, pw} =
        Piecewise.fit(grg,
          satellite_id: @gps,
          window: @span,
          segment_s: 7200,
          cadence_s: 900
        )

      {:ok, map: Piecewise.to_map(pw)}
    end

    test "missing segments is malformed", %{map: map} do
      assert {:error, :malformed_map} = Piecewise.from_map(Map.delete(map, "segments"))
    end

    test "a segment with a malformed inner model is malformed", %{map: map} do
      [first | rest] = map["segments"]
      broken = Map.put(first, "model", Map.put(first["model"], "elements", %{}))

      assert {:error, :malformed_map} =
               Piecewise.from_map(Map.put(map, "segments", [broken | rest]))
    end

    test "a segment whose model id differs from the container is malformed", %{grg: grg, map: map} do
      # Build an eccentric single-model map and graft it into a circular container.
      {:ok, ecc} =
        ReducedOrbit.fit(grg,
          satellite_id: @gps,
          window: {@t0, ~N[2020-06-24 02:00:00]},
          cadence_s: 900,
          model: :eccentric_secular
        )

      [first | rest] = map["segments"]
      grafted = Map.put(first, "model", ReducedOrbit.to_map(ecc))

      assert {:error, :malformed_map} =
               Piecewise.from_map(Map.put(map, "segments", [grafted | rest]))
    end

    test "a segment whose time scale differs from the container is malformed", %{map: map} do
      # GRG is GPST, so the container and every segment model serialize as GPST.
      # Flip one segment model to UTC: that breaks the scale contract that
      # drift/3 and position/3 rely on, so the whole map must be rejected.
      assert map["time_scale"] == "GPST"
      [first | rest] = map["segments"]
      mixed = Map.put(first, "model", Map.put(first["model"], "time_scale", "UTC"))

      assert {:error, :malformed_map} =
               Piecewise.from_map(Map.put(map, "segments", [mixed | rest]))
    end

    test "an unsupported version is surfaced", %{map: map} do
      assert {:error, {:unsupported_version, 99}} =
               Piecewise.from_map(Map.put(map, "version", 99))
    end

    test "an unsupported model is surfaced", %{map: map} do
      assert {:error, {:unsupported_model, "wat"}} =
               Piecewise.from_map(Map.put(map, "model", "wat"))
    end

    test "a non-piecewise map is malformed" do
      assert {:error, :malformed_map} =
               Piecewise.from_map(%{"version" => 1, "model" => "circular_secular"})

      assert {:error, :malformed_map} = Piecewise.from_map(%{})
    end

    test "a bad time scale is malformed", %{map: map} do
      assert {:error, :malformed_map} = Piecewise.from_map(Map.put(map, "time_scale", "NOPE"))
    end

    test "a non-string segment timestamp is malformed, not a raise", %{map: map} do
      # A JSON decoder can hand back an integer for a corrupt document; parsing
      # must surface a typed error, never raise.
      [first | rest] = map["segments"]
      bad_t0 = Map.put(map, "segments", [Map.put(first, "t0", 123) | rest])
      bad_t1 = Map.put(map, "segments", [Map.put(first, "t1", 456) | rest])
      assert {:error, :malformed_map} = Piecewise.from_map(bad_t0)
      assert {:error, :malformed_map} = Piecewise.from_map(bad_t1)
    end

    test "a non-string window bound is malformed, not a raise", %{map: map} do
      bad_start = Map.put(map, "window", %{"start" => 123, "end" => "2020-06-24T02:00:00"})
      bad_end = Map.put(map, "window", %{"start" => "2020-06-24T00:00:00", "end" => 456})
      assert {:error, :malformed_map} = Piecewise.from_map(bad_start)
      assert {:error, :malformed_map} = Piecewise.from_map(bad_end)
    end

    test "an empty segment list is malformed (fit can never produce it)", %{map: map} do
      assert {:error, :malformed_map} = Piecewise.from_map(Map.put(map, "segments", []))
    end
  end

  describe "tagged errors (parity with the single model + piecewise-specific)" do
    test "inverted window", %{grg: grg} do
      assert {:error, :invalid_window} =
               Piecewise.fit(grg, satellite_id: @gps, window: {@day_end, @t0}, segment_s: 7200)
    end

    test "non-positive segment length is :invalid_segment", %{grg: grg} do
      assert {:error, :invalid_segment} =
               Piecewise.fit(grg, satellite_id: @gps, window: @span, segment_s: 0)

      assert {:error, :invalid_segment} =
               Piecewise.fit(grg, satellite_id: @gps, window: @span, segment_s: -100)

      assert {:error, :invalid_segment} =
               Piecewise.fit(grg, satellite_id: @gps, window: @span)
    end

    test "missing satellite id is surfaced from the inner fit", %{grg: grg} do
      assert {:error, :satellite_id_required} =
               Piecewise.fit(grg, window: @span, segment_s: 7200)
    end

    test "an unknown model is surfaced from the inner fit", %{grg: grg} do
      assert {:error, {:unsupported_model, :wat}} =
               Piecewise.fit(grg, satellite_id: @gps, window: @span, segment_s: 7200, model: :wat)
    end

    test "a non-positive cadence is surfaced from the inner fit", %{grg: grg} do
      assert {:error, :invalid_cadence} =
               Piecewise.fit(grg,
                 satellite_id: @gps,
                 window: @span,
                 segment_s: 7200,
                 cadence_s: 0
               )
    end

    test "drift rejects a model whose scale differs from the SP3 product", %{grg: grg} do
      # A piecewise model fit from UTC sample lists must not drift against a GPST SP3.
      samples =
        for k <- 0..30 do
          ep = NaiveDateTime.add(@t0, k * 900, :second)
          {:ok, st} = Sidereon.GNSS.SP3.position(grg, @gps, ep)
          {ep, {st.x_m, st.y_m, st.z_m}}
        end

      {:ok, utc_pw} =
        Piecewise.fit(samples,
          window: {@t0, NaiveDateTime.add(@t0, 30 * 900, :second)},
          segment_s: 7200
        )

      assert utc_pw.time_scale == "UTC"

      assert {:error, {:time_scale_mismatch, "UTC", "GPST"}} =
               Piecewise.drift(utc_pw, grg, satellite_id: @gps, window: @span, cadence_s: 1800)
    end

    test "drift rejects a negative threshold", %{grg: grg} do
      {:ok, pw} =
        Piecewise.fit(grg, satellite_id: @gps, window: @span, segment_s: 7200, cadence_s: 900)

      assert {:error, :invalid_threshold} =
               Piecewise.drift(pw, grg,
                 satellite_id: @gps,
                 window: @span,
                 cadence_s: 1800,
                 threshold_m: -1.0
               )
    end

    test "an interior under-covered segment surfaces too_few_samples", %{grg: grg} do
      # A 60 s segment over a 15-min grid leaves interior segments with no samples;
      # that is a surfaced error, not a silent hole.
      assert {:error, {:too_few_samples, _, _}} =
               Piecewise.fit(grg,
                 satellite_id: @gps,
                 window: {@t0, ~N[2020-06-24 01:00:00]},
                 segment_s: 60,
                 cadence_s: 900
               )
    end
  end

  describe "sample-list source" do
    test "partitions samples by interval and fits contiguous segments", %{grg: grg} do
      samples =
        for k <- 0..40 do
          ep = NaiveDateTime.add(@t0, k * 900, :second)
          {:ok, st} = Sidereon.GNSS.SP3.position(grg, @gps, ep)
          {ep, {st.x_m, st.y_m, st.z_m}}
        end

      span_end = NaiveDateTime.add(@t0, 40 * 900, :second)

      {:ok, pw} =
        Piecewise.fit(samples, window: {@t0, span_end}, segment_s: 7200, time_scale: "GPST")

      assert pw.time_scale == "GPST"
      assert length(pw.segments) >= 2
      # Every in-range epoch resolves to a segment.
      mid = NaiveDateTime.add(@t0, 20 * 900, :second)
      assert {:ok, _} = Piecewise.position(pw, mid)
    end

    test "drifts a sample-list-fit model against the same samples", %{grg: grg} do
      samples =
        for k <- 0..40 do
          ep = NaiveDateTime.add(@t0, k * 900, :second)
          {:ok, st} = Sidereon.GNSS.SP3.position(grg, @gps, ep)
          {ep, {st.x_m, st.y_m, st.z_m}}
        end

      span_end = NaiveDateTime.add(@t0, 40 * 900, :second)

      {:ok, pw} =
        Piecewise.fit(samples,
          window: {@t0, span_end},
          segment_s: 7200,
          time_scale: "GPST",
          model: :eccentric_secular
        )

      assert {:ok, d} = Piecewise.drift(pw, samples, threshold_m: 1.0e9)
      assert d.used == length(samples)
      assert is_float(d.max_m) and d.max_m >= 0.0
      # In-window residual for the eccentric model is sub-km.
      assert d.max_m < 2_000.0
    end
  end

  defp iss_tle! do
    l1 = "1 25544U 98067A   18184.80969102  .00001614  00000-0  31745-4 0  9993"
    l2 = "2 25544  51.6414 295.8524 0003435 262.6267 204.2868 15.54005638121106"
    {:ok, tle} = Sidereon.Format.TLE.parse(l1, l2)
    tle
  end
end
