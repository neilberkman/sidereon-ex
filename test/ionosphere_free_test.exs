defmodule Sidereon.GNSS.IonosphereFreeTest do
  @moduledoc """
  The dual-frequency ionosphere-free pseudorange combination.

  The gates here are the physics, not self-consistency: a synthetic first-order
  ionospheric delay (`I = K / f^2`) injected onto two bands must cancel exactly in
  the combination, and an end-to-end position solve fed the combined pseudoranges
  must recover the receiver orders of magnitude better than the single-frequency
  solve that ignores the same ionosphere.

  The end-to-end case uses **synthesized** dual-frequency observations: a true
  range and satellite clock from the precise SP3 fixture, plus a `1 / f^2`
  ionospheric delay on each band. A real dual-band RINEX file lacks a clean,
  SP3-aligned ionospheric truth, so the cancellation/recovery physics is proven on
  synthesized data; a separate smoke test proves both bands extract and combine on
  a real station file.
  """
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.IonosphereFree
  alias Sidereon.GNSS.Observables
  alias Sidereon.GNSS.Positioning
  alias Sidereon.GNSS.RINEX.Observations
  alias Sidereon.GNSS.SP3

  @c 299_792_458.0

  @sp3_path Path.join(__DIR__, "fixtures/sp3/GRG0MGXFIN_20201760000_01D_15M_ORB.SP3")
  @obs_path Path.join(__DIR__, "fixtures/obs/ESBC00DNK_R_20201770000_01D_30S_MO_trim.crx")

  # GPS L1/L2 and Galileo E1/E5a carriers, in hertz.
  @f_l1 1_575_420_000.0
  @f_l2 1_227_600_000.0
  @f_e1 1_575_420_000.0
  @f_e5a 1_176_450_000.0

  describe "frequency table" do
    test "frequency/2 returns the standard carriers per system" do
      assert {:ok, 1_575_420_000.0} = IonosphereFree.frequency("G", :l1)
      assert {:ok, 1_227_600_000.0} = IonosphereFree.frequency("G", :l2)
      assert {:ok, 1_575_420_000.0} = IonosphereFree.frequency("E", :e1)
      assert {:ok, 1_176_450_000.0} = IonosphereFree.frequency("E", :e5a)
      assert {:ok, 1_561_098_000.0} = IonosphereFree.frequency("C", :b1i)
      assert {:ok, 1_268_520_000.0} = IonosphereFree.frequency("C", :b3i)
    end

    test "default_pair/1 returns the standard combination pair per system" do
      assert {:ok, {:l1, :l2}} = IonosphereFree.default_pair("G")
      assert {:ok, {:e1, :e5a}} = IonosphereFree.default_pair("E")
      assert {:ok, {:b1i, :b3i}} = IonosphereFree.default_pair("C")
    end

    test "frequencies/0 exposes the ionosphere-free pair table" do
      table = IonosphereFree.frequencies()
      assert table["G"][:l1] == 1_575_420_000.0
      assert table["E"][:e5a] == 1_176_450_000.0
      assert table["C"][:b1i] == 1_561_098_000.0
      refute Map.has_key?(table["G"], :l5)
    end

    test "an unknown band is a tagged error (no raise)" do
      assert {:error, {:unknown_band, "G", :bogus}} = IonosphereFree.frequency("G", :bogus)
      assert {:error, {:unknown_band, "X", :l1}} = IonosphereFree.frequency("X", :l1)
    end

    test "an unknown system is a tagged error (no raise)" do
      assert {:error, {:unknown_system, "X"}} = IonosphereFree.default_pair("X")
    end
  end

  describe "iono_free/4 cancellation (synthetic 1/f^2 ionosphere)" do
    # A true range and a TEC-like constant K give per-band pseudoranges
    # pr_i = R + K / f_i^2. The combination must return R to numerical precision.
    test "cancels the 1/f^2 term for GPS L1/L2 at several TEC levels" do
      r = 2.3e7
      # K spans no ionosphere, a modest delay, and a strong-storm delay. With
      # K = 1.0e19 the L1 delay K/f1^2 is ~4 m, a realistic order of magnitude.
      for k <- [0.0, 1.0e18, 1.0e19, 5.0e19] do
        pr1 = r + k / (@f_l1 * @f_l1)
        pr2 = r + k / (@f_l2 * @f_l2)
        assert {:ok, recovered} = IonosphereFree.iono_free(pr1, pr2, @f_l1, @f_l2)
        # Tolerance scaled to the f64 resolution near R (~a few ULP of 2.3e7).
        assert_in_delta recovered, r, 1.0e-6
      end
    end

    test "cancels the 1/f^2 term for Galileo E1/E5a at several TEC levels" do
      r = 2.45e7

      for k <- [0.0, 1.0e18, 1.0e19, 5.0e19] do
        pr1 = r + k / (@f_e1 * @f_e1)
        pr2 = r + k / (@f_e5a * @f_e5a)
        assert {:ok, recovered} = IonosphereFree.iono_free(pr1, pr2, @f_e1, @f_e5a)
        assert_in_delta recovered, r, 1.0e-6
      end
    end

    test "measured cancellation residual is at machine-epsilon scale" do
      r = 2.3e7
      k = 1.0e19
      pr1 = r + k / (@f_l1 * @f_l1)
      pr2 = r + k / (@f_l2 * @f_l2)
      {:ok, recovered} = IonosphereFree.iono_free(pr1, pr2, @f_l1, @f_l2)
      residual = abs(recovered - r)
      # A few ULP of 2.3e7 is ~1e-8 m; assert it is sub-nanometre.
      assert residual < 1.0e-7
    end

    test "equal frequencies is a tagged error, not a raise" do
      assert {:error, :equal_frequencies} =
               IonosphereFree.iono_free(2.3e7, 2.3e7, @f_l1, @f_l1)
    end
  end

  describe "iono_free_phase/4 carrier-phase combinations" do
    test "phase in metres uses the same first-order cancellation coefficients" do
      r = 2.3e7
      k = 1.0e19
      lambda1 = @c / @f_l1
      lambda2 = @c / @f_l2
      l1 = r - k / (@f_l1 * @f_l1) + 123_456 * lambda1
      l2 = r - k / (@f_l2 * @f_l2) + 234_567 * lambda2

      assert {:ok, l_if} = IonosphereFree.iono_free_phase(l1, l2, @f_l1, @f_l2)

      {:ok, g} = IonosphereFree.gamma(@f_l1, @f_l2)
      expected = g * l1 - (g - 1.0) * l2
      assert_in_delta l_if, expected, 1.0e-9
    end

    test "phase in cycles is converted to metres before combining" do
      phi1 = 123_456_789.25
      phi2 = 98_765_432.5
      l1 = @c / @f_l1 * phi1
      l2 = @c / @f_l2 * phi2

      assert {:ok, direct} = IonosphereFree.iono_free_phase(l1, l2, @f_l1, @f_l2)
      assert {:ok, from_cycles} = IonosphereFree.iono_free_phase_cycles(phi1, phi2, @f_l1, @f_l2)
      assert from_cycles == direct
    end

    test "bad carrier frequencies are tagged errors" do
      assert {:error, :equal_frequencies} =
               IonosphereFree.iono_free_phase_cycles(1.0, 2.0, @f_l1, @f_l1)

      assert {:error, :invalid_frequency} =
               IonosphereFree.iono_free_phase_cycles(1.0, 2.0, 0.0, @f_l2)

      assert {:error, :invalid_frequency} =
               IonosphereFree.iono_free_phase_cycles(1.0, 2.0, "bad", @f_l2)
    end
  end

  describe "coefficients and noise amplification" do
    test "gamma matches the closed form for GPS L1/L2" do
      expected = @f_l1 * @f_l1 / (@f_l1 * @f_l1 - @f_l2 * @f_l2)
      assert {:ok, g} = IonosphereFree.gamma(@f_l1, @f_l2)
      assert_in_delta g, expected, 1.0e-12
      # The documented value is ~2.5457.
      assert_in_delta g, 2.5457, 1.0e-3
    end

    test "noise amplification is ~2.978 for GPS L1/L2" do
      assert {:ok, amp} = IonosphereFree.noise_amplification(@f_l1, @f_l2)
      assert_in_delta amp, 2.978, 1.0e-3

      {:ok, g} = IonosphereFree.gamma(@f_l1, @f_l2)
      assert_in_delta amp, :math.sqrt(g * g + (g - 1.0) * (g - 1.0)), 1.0e-12
    end

    test "noise amplification matches the closed form for Galileo E1/E5a" do
      assert {:ok, amp} = IonosphereFree.noise_amplification(@f_e1, @f_e5a)
      {:ok, g} = IonosphereFree.gamma(@f_e1, @f_e5a)
      assert_in_delta amp, :math.sqrt(g * g + (g - 1.0) * (g - 1.0)), 1.0e-12
      # The documented value is ~2.588.
      assert_in_delta amp, 2.588, 1.0e-3
    end

    test "iono_free is linear in each pseudorange with the documented coefficients" do
      {:ok, g} = IonosphereFree.gamma(@f_l1, @f_l2)
      base_pr1 = 2.30e7
      base_pr2 = 2.30e7
      d = 10.0

      {:ok, base} = IonosphereFree.iono_free(base_pr1, base_pr2, @f_l1, @f_l2)
      {:ok, bumped1} = IonosphereFree.iono_free(base_pr1 + d, base_pr2, @f_l1, @f_l2)
      {:ok, bumped2} = IonosphereFree.iono_free(base_pr1, base_pr2 + d, @f_l1, @f_l2)

      # Partial w.r.t. pr1 is +gamma, w.r.t. pr2 is -(gamma - 1).
      assert_in_delta bumped1 - base, g * d, 1.0e-6
      assert_in_delta bumped2 - base, -(g - 1.0) * d, 1.0e-6
    end

    test "gamma and noise amplification reject equal frequencies" do
      assert {:error, :equal_frequencies} = IonosphereFree.gamma(@f_l1, @f_l1)
      assert {:error, :equal_frequencies} = IonosphereFree.noise_amplification(@f_l1, @f_l1)
    end
  end

  describe "iono_free_pseudoranges/3 pairing" do
    test "combines each satellite with its own system's frequency pair" do
      r_g = 2.30e7
      r_e = 2.45e7
      k = 1.0e19

      band1 = [
        {"G05", r_g + k / (@f_l1 * @f_l1)},
        {"E11", r_e + k / (@f_e1 * @f_e1)}
      ]

      band2 = [
        {"G05", r_g + k / (@f_l2 * @f_l2)},
        {"E11", r_e + k / (@f_e5a * @f_e5a)}
      ]

      assert {combined, []} = IonosphereFree.iono_free_pseudoranges(band1, band2, [])
      combined_map = Map.new(combined)
      assert_in_delta combined_map["G05"], r_g, 1.0e-6
      assert_in_delta combined_map["E11"], r_e, 1.0e-6
    end

    test "a satellite present in only one band is dropped and reported" do
      band1 = [{"G05", 2.30e7}, {"G07", 2.31e7}]
      band2 = [{"G05", 2.30e7}, {"G09", 2.32e7}]

      {combined, dropped} = IonosphereFree.iono_free_pseudoranges(band1, band2, [])

      assert [{"G05", _}] = combined
      assert {"G07", :missing_band2} in dropped
      assert {"G09", :missing_band1} in dropped
    end

    test "a satellite of an unknown system is reported, not raised" do
      band1 = [{"X07", 2.30e7}]
      band2 = [{"X07", 2.30e7}]

      assert {[], [{"X07", :unknown_system}]} =
               IonosphereFree.iono_free_pseudoranges(band1, band2, [])
    end

    test "empty input yields an empty result" do
      assert {[], []} = IonosphereFree.iono_free_pseudoranges([], [], [])
    end

    test "a satellite repeated within a band is dropped, not silently collapsed" do
      # G01 appears twice in band1 with different ranges; the result must not
      # depend on which entry comes last. It is reported as a duplicate and a
      # clean satellite (G02) still combines.
      band1 = [{"G01", 2.30e7}, {"G01", 2.31e7}, {"G02", 2.20e7}]
      band2 = [{"G01", 2.30e7}, {"G02", 2.20e7}]

      {combined, dropped} = IonosphereFree.iono_free_pseudoranges(band1, band2, [])

      assert Enum.map(combined, &elem(&1, 0)) == ["G02"]
      assert {"G01", :duplicate_observation} in dropped
    end

    test "the :pairs option overrides the band pair per system" do
      r = 2.30e7
      k = 1.0e19
      band1 = [{"G05", r + k / (@f_l1 * @f_l1)}]
      band2 = [{"G05", r + k / (@f_l2 * @f_l2)}]

      assert {[{"G05", v}], []} =
               IonosphereFree.iono_free_pseudoranges(band1, band2, pairs: %{"G" => {:l1, :l2}})

      assert_in_delta v, r, 1.0e-6
    end
  end

  describe "iono_free_from_obs/3 (real dual-band smoke)" do
    test "extracts and combines GPS L1/L2 from a real station file" do
      obs = Observations.load!(@obs_path)
      [%{index: index} | _] = Observations.epochs(obs)

      assert {:ok, {combined, _dropped}} =
               IonosphereFree.iono_free_from_obs(obs, index, codes: %{"G" => {["C1C"], ["C2W"]}})

      # An over-determined GPS set, all in a plausible pseudorange range.
      assert length(combined) >= 6

      assert Enum.all?(combined, fn {sat, pr} ->
               String.starts_with?(sat, "G") and is_float(pr) and pr > 1.9e7 and pr < 2.8e7
             end)
    end

    test "default codes extract GPS, Galileo and BeiDou bands present in the file" do
      obs = Observations.load!(@obs_path)
      [%{index: index} | _] = Observations.epochs(obs)

      assert {:ok, {combined, _dropped}} = IonosphereFree.iono_free_from_obs(obs, index)

      systems = combined |> Enum.map(fn {sat, _} -> String.first(sat) end) |> Enum.uniq()
      # The ESBC file carries dual-band GPS, Galileo and BeiDou.
      assert "G" in systems
      assert "E" in systems
      assert "C" in systems

      assert Enum.all?(combined, fn {_sat, pr} -> is_float(pr) and pr > 1.9e7 and pr < 4.5e7 end)
    end
  end

  describe "end-to-end: iono-free solve beats single-frequency-with-iono" do
    # Synthesize dual-frequency GPS pseudoranges from the precise SP3 fixture for a
    # known mid-latitude receiver at 2020-06-24 12:00 GPST, with a 1/f^2
    # ionospheric delay on each band. The L1-only solve (ionosphere off) is biased
    # by the uncorrected delay; the iono-free solve recovers the receiver to the
    # no-iono baseline.
    @epoch ~N[2020-06-24 12:00:00]
    # A real ECEF point near the ESBC station (Esbjerg, Denmark).
    @truth {3_512_900.0, 780_500.0, 5_248_700.0}
    # TEC-like constant for the vertical first-order delay; K/f_L1^2 is the
    # vertical L1 delay in metres (~4 m here), scaled per satellite by an
    # obliquity factor (~4-11 m slant across the sky). Sized at strong-ionosphere
    # TEC so the elevation-dependent (non-common-mode) part of the delay biases
    # the single-frequency position by metres.
    @k 1.0e19

    test "iono-free recovers the receiver; L1-only-with-iono is badly biased" do
      sp3 = SP3.load!(@sp3_path)
      {tx, ty, tz} = @truth

      # Per-GPS-satellite true range, clock, and the slant ionosphere constant from
      # the forward model. The first-order delay is dispersive (K_slant / f^2); the
      # slant constant is a vertical TEC scaled by a standard obliquity (mapping)
      # factor that grows toward the horizon, so the delay is NOT common-mode
      # across satellites; it varies with geometry and so genuinely biases the
      # single-frequency position, while still obeying the 1/f^2 law per band so
      # the combination cancels it exactly.
      preds =
        sp3
        |> SP3.satellite_ids()
        |> Enum.filter(&String.starts_with?(&1, "G"))
        |> Enum.flat_map(fn sat ->
          case Observables.predict(sp3, sat, @truth, @epoch) do
            {:ok, %{geometric_range_m: range, sat_clock_s: clk, elevation_deg: el}}
            when is_float(clk) and el > 10.0 ->
              r = range - @c * clk
              # Obliquity factor: 1 at zenith, larger toward the horizon (a thin-
              # shell mapping with mean ionospheric height ~350 km, Earth ~6371 km).
              el_rad = el * :math.pi() / 180.0
              z = 6371.0 / (6371.0 + 350.0) * :math.cos(el_rad)
              obliquity = 1.0 / :math.sqrt(1.0 - z * z)
              k_slant = @k * obliquity
              [{sat, r, k_slant}]

            _ ->
              []
          end
        end)

      assert length(preds) >= 6, "need an over-determined GPS set"

      l1_obs = Enum.map(preds, fn {sat, r, k} -> {sat, r + k / (@f_l1 * @f_l1)} end)
      l2_obs = Enum.map(preds, fn {sat, r, k} -> {sat, r + k / (@f_l2 * @f_l2)} end)
      clean_obs = Enum.map(preds, fn {sat, r, _k} -> {sat, r} end)

      guess = {tx + 3_000.0, ty - 2_000.0, tz + 2_500.0, 0.0}

      # Baseline: no ionosphere at all -> recovers the truth (the forward model the
      # position solve inverts, with the receiver clock estimated).
      {:ok, base_sol} =
        Positioning.solve(sp3, clean_obs, @epoch,
          ionosphere: false,
          troposphere: false,
          initial_guess: guess
        )

      base_err = err(base_sol, @truth)

      # (a) L1-only, ionosphere off: biased by the uncorrected 1/f^2 delay.
      {:ok, l1_sol} =
        Positioning.solve(sp3, l1_obs, @epoch,
          ionosphere: false,
          troposphere: false,
          initial_guess: guess
        )

      l1_err = err(l1_sol, @truth)

      # (b) Iono-free combination, ionosphere off: cancels the 1/f^2 delay.
      {combined, []} = IonosphereFree.iono_free_pseudoranges(l1_obs, l2_obs, [])

      {:ok, if_sol} =
        Positioning.solve(sp3, combined, @epoch,
          ionosphere: false,
          troposphere: false,
          initial_guess: guess
        )

      if_err = err(if_sol, @truth)

      # The no-iono baseline recovers the truth to sub-centimetre.
      assert base_err < 1.0e-2, "baseline error #{base_err} m"

      # The single-frequency-with-iono solve is biased by metres (a common-mode +
      # geometry-dependent error from the ~16 m L1 delay).
      assert l1_err > 5.0, "L1-only error only #{l1_err} m (expected large bias)"

      # The iono-free solve recovers the receiver to the no-iono baseline: orders
      # of magnitude better than the single-frequency solve.
      assert if_err < 1.0e-2, "iono-free error #{if_err} m"
      assert if_err < l1_err / 100.0, "iono-free #{if_err} m not << L1-only #{l1_err} m"
    end
  end

  defp err(sol, {tx, ty, tz}) do
    :math.sqrt((sol.position.x_m - tx) ** 2 + (sol.position.y_m - ty) ** 2 + (sol.position.z_m - tz) ** 2)
  end
end
