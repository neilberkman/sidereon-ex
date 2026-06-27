defmodule Sidereon.GNSS.PPPCorrectionsTest do
  @moduledoc """
  Tests for the PPP per-range correction stack: solid-earth tide, carrier-phase
  wind-up, and satellite-antenna PCO/PCV.

  The two physics kernels are checked against independent oracles through the
  NIF: the solid-earth tide against the IERS DEHANTTIDEINEL golden vectors, and
  the Sun/Moon position against a Skyfield/DE440 ITRS reference. The Elixir
  correction algebra (wind-up, PCO projection) is checked for the physical
  properties a faithful implementation must have, and the whole stack is checked
  end-to-end: enabling a correction must move the recovered float position by a
  physically bounded amount on a real GPS arc (ZIM200CHE, 2026/133).
  """
  use ExUnit.Case, async: false

  alias Sidereon.GNSS.Antex
  alias Sidereon.GNSS.IonosphereFree
  alias Sidereon.GNSS.Observables
  alias Sidereon.GNSS.PPPCorrections
  alias Sidereon.GNSS.PrecisePositioning
  alias Sidereon.GNSS.RINEX.Observations
  alias Sidereon.GNSS.SP3

  @ppp_dir Path.join(__DIR__, "fixtures/ppp")
  @sp3 Path.join(@ppp_dir, "IGS0OPSFIN_20261330000_01D_15M_ORB.SP3")
  @obs Path.join(@ppp_dir, "ZIM200CHE_R_20261330000_01D_30S_MO_1h.rnx")
  @atx Path.join(@ppp_dir, "igs20_zim2_gps.atx")
  @tides_golden Path.join(@ppp_dir, "golden/tides_dehant_golden.json")
  @sunmoon_golden Path.join(@ppp_dir, "golden/sun_moon_skyfield_golden.json")
  @elmask_deg 10.0

  # ---------------------------------------------------------------------------
  # Independent-oracle kernel tests (through the NIF)
  # ---------------------------------------------------------------------------

  describe "solid-earth tide (NIF) vs IERS DEHANTTIDEINEL golden" do
    test "reproduces the IERS reference displacement to sub-nanometre" do
      doc = @tides_golden |> File.read!() |> Jason.decode!()

      checked =
        for case <- doc["cases"],
            # case_4 is a documented fixture transcription artifact (non-physical
            # xsun); the IERS reference covers degree 2/3 + step 2 via cases 1-3.
            case["id"] != "case_4_2017_01_15" do
          i = case["inputs"]
          [sx, sy, sz] = i["xsta_m"]["values"]
          xsun = List.to_tuple(i["xsun_m"]["values"])
          xmon = List.to_tuple(i["xmon_m"]["values"])
          y = i["date_utc"]["year"]
          mo = i["date_utc"]["month"]
          d = i["date_utc"]["day"]
          fhr = i["fhr_hours"]["value"]
          [ex, ey, ez] = case["expected"]["dxtide_m"]["values"]

          {gx, gy, gz} = Sidereon.NIF.solid_earth_tide(sx, sy, sz, y, mo, d, fhr, xsun, xmon)

          assert_in_delta gx, ex, 1.0e-9
          assert_in_delta gy, ey, 1.0e-9
          assert_in_delta gz, ez, 1.0e-9
          case["id"]
        end

      assert length(checked) >= 3
    end
  end

  describe "Sun/Moon ECEF (NIF) vs Skyfield/DE440 golden" do
    test "Sun direction within model accuracy and free of the precession double-count" do
      doc = @sunmoon_golden |> File.read!() |> Jason.decode!()

      for case <- doc["cases"] do
        u = case["utc"]
        dt = {{u["year"], u["month"], u["day"]}, {u["hour"], u["minute"], u["second"], 0}}
        {sun, moon} = Sidereon.NIF.sun_moon_ecef(dt)

        # Sun: the low-precision analytic model is good to ~arcminute; a tolerance
        # of 0.05 deg passes the faithful model but fails the 0.37 deg error that
        # a double-counted precession (full GCRS->ITRS on an of-date series) would
        # introduce at epoch 2026.
        assert angle_deg(sun, case["sun_itrs_m"]) < 0.05
        assert angle_deg(moon, case["moon_itrs_m"]) < 0.6
        assert_in_delta norm(sun) / norm_l(case["sun_itrs_m"]), 1.0, 0.003
        assert_in_delta norm(moon) / norm_l(case["moon_itrs_m"]), 1.0, 0.012
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Correction-table properties on a real arc
  # ---------------------------------------------------------------------------

  describe "PPPCorrections.build on a real GPS arc" do
    setup do
      {sp3, epochs, approx, antex} = build_arc(60)
      %{sp3: sp3, epochs: epochs, approx: approx, antex: antex}
    end

    test "solid-earth tide table matches the NIF kernel per epoch", ctx do
      {:ok, c} = PPPCorrections.build(ctx.sp3, ctx.epochs, ctx.approx, %{solid_earth_tide: true})
      assert map_size(c.tide) > 0
      {rx, ry, rz} = ctx.approx

      for {epoch, d_tide} <- c.tide do
        {sun, moon} = Sidereon.NIF.sun_moon_ecef(naive_to_tuple(epoch))
        {{y, mo, d}, {h, mi, s}} = naive_to_ymd_hms(epoch)
        fhr = h + mi / 60.0 + s / 3600.0
        {ex, ey, ez} = Sidereon.NIF.solid_earth_tide(rx, ry, rz, y, mo, d, fhr, sun, moon)
        {gx, gy, gz} = d_tide
        assert_in_delta gx, ex, 1.0e-12
        assert_in_delta gy, ey, 1.0e-12
        assert_in_delta gz, ez, 1.0e-12
        # physical magnitude: solid-earth tide is decimetre-scale at most.
        assert norm(d_tide) < 0.5
      end
    end

    test "wind-up is smooth, bounded, and continuous per satellite", ctx do
      {:ok, c} = PPPCorrections.build(ctx.sp3, ctx.epochs, ctx.approx, %{phase_windup: true})
      assert map_size(c.windup_m) > 0

      by_sat =
        c.windup_m
        |> Enum.group_by(fn {{sat, _e}, _} -> sat end)
        |> Enum.map(fn {sat, kvs} ->
          vals = kvs |> Enum.sort_by(fn {{_s, e}, _} -> e end) |> Enum.map(&elem(&1, 1))
          {sat, vals}
        end)

      for {_sat, vals} <- by_sat, length(vals) >= 2 do
        # Physical magnitude: iono-free wind-up stays well under a cycle (~0.1 m).
        assert Enum.all?(vals, &(abs(&1) < 0.2))
        # Continuity: consecutive 30 s epochs cannot jump (a sign/unwrap bug
        # would show as ~half-wavelength, several cm, steps).
        jumps =
          vals |> Enum.chunk_every(2, 1, :discard) |> Enum.map(fn [a, b] -> abs(b - a) end)

        assert Enum.max(jumps) < 0.01
      end
    end

    test "satellite PCO is a bounded antenna-offset vector", ctx do
      sat_ant = %{antex: ctx.antex, freq1: "G01", freq2: "G02"}

      {:ok, c} =
        PPPCorrections.build(ctx.sp3, ctx.epochs, ctx.approx, %{satellite_antenna: sat_ant})

      assert map_size(c.sat_pco_ecef) > 0

      for {_key, pco} <- c.sat_pco_ecef do
        # GPS block antenna offsets are order ~1-2 m; the iono-free combination
        # stays a few metres at most.
        assert norm(pco) < 5.0
      end
    end

    test "returns an ok tuple with empty tables when all corrections are disabled", ctx do
      assert {:ok, %{tide: %{}, windup_m: %{}, sat_pco_ecef: %{}, sat_pcv_m: %{}}} =
               PPPCorrections.build(ctx.sp3, ctx.epochs, ctx.approx, %{})
    end

    test "missing observation satellite id is a tagged error", ctx do
      epoch = %{epoch: ~N[2026-01-01 00:00:00], observations: [%{f1_hz: 1.0, f2_hz: 2.0}]}

      assert {:error, {:missing_field, :satellite_id}} =
               PPPCorrections.build(ctx.sp3, [epoch], ctx.approx, %{phase_windup: true})
    end

    test "unsupported antenna frequency is a tagged error", ctx do
      sat_ant = %{antex: ctx.antex, freq1: "X99", freq2: "G02"}

      assert {:error, {:unsupported_frequency, "X99"}} =
               PPPCorrections.build(ctx.sp3, ctx.epochs, ctx.approx, %{satellite_antenna: sat_ant})
    end
  end

  # ---------------------------------------------------------------------------
  # End-to-end: a correction must move the recovered float position
  # ---------------------------------------------------------------------------

  describe "corrections shift the recovered float position" do
    setup do
      {sp3, epochs, approx, antex} = build_arc(60)
      {x0, y0, z0} = approx
      seed = {x0 + 100.0, y0 - 100.0, z0 + 100.0, 0.0}

      base = [
        initial_guess: seed,
        max_iterations: 10,
        elevation_weighting: true,
        troposphere: true,
        estimate_ztd: true,
        satellite_clock_relativity: true
      ]

      {:ok, plain} = PrecisePositioning.solve_float_epochs(sp3, epochs, base)
      %{sp3: sp3, epochs: epochs, antex: antex, base: base, plain: plain}
    end

    test "solid-earth tide moves the position by a physically bounded amount", ctx do
      {:ok, tided} =
        PrecisePositioning.solve_float_epochs(
          ctx.sp3,
          ctx.epochs,
          ctx.base ++ [solid_earth_tide: true]
        )

      shift = pos_shift(tided.position, ctx.plain.position)
      assert shift > 0.001
      assert shift < 1.0
    end

    test "satellite antenna PCO/PCV moves the position by a physically bounded amount",
         ctx do
      sat_ant = %{antex: ctx.antex, freq1: "G01", freq2: "G02"}

      {:ok, pcod} =
        PrecisePositioning.solve_float_epochs(
          ctx.sp3,
          ctx.epochs,
          ctx.base ++ [satellite_antenna: sat_ant]
        )

      shift = pos_shift(pcod.position, ctx.plain.position)
      assert shift > 0.001
      assert shift < 2.0
    end
  end

  # ---------------------------------------------------------------------------
  # Canonical strategy selection (Phase-6 increment 4, opt-in)
  # ---------------------------------------------------------------------------

  # Canonical-vs-reference clustering bound (meters). Canonical PPP and the
  # PPP-oracle-faithful reference share the undifferenced ionosphere-free
  # measurement model and differ only in the dense normal solve (the owned
  # Cholesky square-root-information factorization vs the reference last-tie
  # Gaussian elimination), so on the same arc they cluster within the f64 roundoff
  # floor of two factorizations of one SPD system. Mirrors the crate's named
  # CANONICAL_VS_REFERENCE_PPP_TOL_M = 1e-6 m bar (the crate observes ~1.9e-9 m);
  # beyond this band is a bug, not a band to widen.
  @canonical_vs_reference_ppp_bound_m 1.0e-6

  describe "canonical strategy selection on the PPP float arc (opt-in)" do
    setup do
      {sp3, epochs, approx, _antex} = build_arc(60)
      {x0, y0, z0} = approx
      seed = {x0 + 100.0, y0 - 100.0, z0 + 100.0, 0.0}

      base = [
        initial_guess: seed,
        max_iterations: 10,
        elevation_weighting: true,
        troposphere: true,
        estimate_ztd: true,
        satellite_clock_relativity: true
      ]

      %{sp3: sp3, epochs: epochs, base: base}
    end

    test "the default selection is the reference strategy, bit-for-bit", ctx do
      assert {:ok, default} = PrecisePositioning.solve_float_epochs(ctx.sp3, ctx.epochs, ctx.base)

      assert {:ok, reference} =
               PrecisePositioning.solve_float_epochs(
                 ctx.sp3,
                 ctx.epochs,
                 ctx.base ++ [strategy: :reference]
               )

      assert default.position == reference.position
    end

    test "canonical is selectable, deterministic, and clusters within the named band", ctx do
      assert {:ok, reference} =
               PrecisePositioning.solve_float_epochs(ctx.sp3, ctx.epochs, ctx.base)

      assert {:ok, canonical} =
               PrecisePositioning.solve_float_epochs(
                 ctx.sp3,
                 ctx.epochs,
                 ctx.base ++ [strategy: :canonical]
               )

      assert {:ok, canonical_again} =
               PrecisePositioning.solve_float_epochs(
                 ctx.sp3,
                 ctx.epochs,
                 ctx.base ++ [strategy: :canonical]
               )

      # Determinism: a second canonical solve reproduces the first.
      assert canonical.position == canonical_again.position

      # Bounded tolerance: canonical clusters within the named band of the
      # reference float position.
      assert_in_delta canonical.position.x_m,
                      reference.position.x_m,
                      @canonical_vs_reference_ppp_bound_m

      assert_in_delta canonical.position.y_m,
                      reference.position.y_m,
                      @canonical_vs_reference_ppp_bound_m

      assert_in_delta canonical.position.z_m,
                      reference.position.z_m,
                      @canonical_vs_reference_ppp_bound_m
    end

    test "an unknown strategy is rejected with a tagged error", ctx do
      assert PrecisePositioning.solve_float_epochs(
               ctx.sp3,
               ctx.epochs,
               ctx.base ++ [strategy: :bogus]
             ) == {:error, {:invalid_option, :strategy}}
    end
  end

  # ---------------------------------------------------------------------------
  # helpers
  # ---------------------------------------------------------------------------

  defp build_arc(count) do
    sp3 = SP3.load!(@sp3)
    obs = Observations.load!(@obs)
    antex = Antex.load!(@atx)
    approx = Observations.approx_position(obs)
    {:ok, f1} = IonosphereFree.frequency("G", :l1)
    {:ok, f2} = IonosphereFree.frequency("G", :l2)

    epochs =
      obs
      |> Observations.epochs()
      |> Enum.take(count)
      |> Enum.flat_map(fn entry ->
        ndt = naive_datetime(entry.epoch)
        rows = epoch_rows(obs, entry.index, sp3, approx, ndt, f1, f2)
        if length(rows) >= 5, do: [%{epoch: ndt, observations: rows}], else: []
      end)

    {sp3, epochs, approx, antex}
  end

  defp epoch_rows(obs, index, sp3, approx, ndt, f1, f2) do
    {:ok, by_sat} = Observations.values(obs, index, codes: %{"G" => ["C1C", "C2W", "L1C", "L2W"]})

    by_sat
    |> Enum.flat_map(fn {sat, values} ->
      vbc = Map.new(values, &{&1.code, &1.value})
      lbc = Map.new(values, &{&1.code, Map.get(&1, :lli)})

      with c1 when is_number(c1) <- vbc["C1C"],
           c2 when is_number(c2) <- vbc["C2W"],
           l1 when is_number(l1) <- vbc["L1C"],
           l2 when is_number(l2) <- vbc["L2W"],
           {:ok, pred} <- Observables.predict(sp3, sat, approx, ndt),
           true <- pred.elevation_deg >= @elmask_deg,
           {:ok, code_m} <- IonosphereFree.iono_free(c1, c2, f1, f2),
           {:ok, phase_m} <- IonosphereFree.iono_free_phase_cycles(l1, l2, f1, f2) do
        [
          %{
            satellite_id: sat,
            code_m: code_m,
            phase_m: phase_m,
            phi1_cyc: l1,
            phi2_cyc: l2,
            p1_m: c1,
            p2_m: c2,
            f1_hz: f1,
            f2_hz: f2,
            lli1: lbc["L1C"],
            lli2: lbc["L2W"]
          }
        ]
      else
        _ -> []
      end
    end)
    |> Enum.sort_by(& &1.satellite_id)
  end

  defp pos_shift(a, b),
    do: :math.sqrt((a.x_m - b.x_m) ** 2 + (a.y_m - b.y_m) ** 2 + (a.z_m - b.z_m) ** 2)

  defp angle_deg({ax, ay, az}, [bx, by, bz]) do
    dot = ax * bx + ay * by + az * bz
    c = max(-1.0, min(1.0, dot / (norm({ax, ay, az}) * norm_l([bx, by, bz]))))
    :math.acos(c) * 180.0 / :math.pi()
  end

  defp norm({x, y, z}), do: :math.sqrt(x * x + y * y + z * z)
  defp norm_l([x, y, z]), do: :math.sqrt(x * x + y * y + z * z)

  defp naive_datetime({{y, mo, d}, {h, mi, s}}) do
    ws = trunc(s)
    us = round((s - ws) * 1_000_000)
    NaiveDateTime.new!(Date.new!(y, mo, d), Time.new!(h, mi, ws, {us, 6}))
  end

  defp naive_to_tuple(%NaiveDateTime{} = ndt),
    do:
      {{ndt.year, ndt.month, ndt.day},
       {ndt.hour, ndt.minute, ndt.second, elem(ndt.microsecond, 0)}}

  defp naive_to_ymd_hms(%NaiveDateTime{} = ndt) do
    s = ndt.second + elem(ndt.microsecond, 0) / 1_000_000.0
    {{ndt.year, ndt.month, ndt.day}, {ndt.hour, ndt.minute, s}}
  end
end
