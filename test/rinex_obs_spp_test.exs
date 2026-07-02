defmodule Sidereon.GNSS.RINEX.ObservationsSppTest do
  @moduledoc """
  End-to-end single-point positioning from a real station observation file: load
  the CRINEX, extract single-frequency pseudoranges, solve against the matching
  broadcast navigation product, and recover the receiver's surveyed position.

  This proves the whole last mile: CRINEX decode, RINEX 3 observation parse,
  pseudorange extraction, and the solve on real data for the ESBC00DNK station
  (Esbjerg, Denmark) at 2020-06-25 00:00 GPST.
  """
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.Broadcast
  alias Sidereon.GNSS.Positioning
  alias Sidereon.GNSS.RINEX.Observations

  defp err_3d(sol, {tx, ty, tz}) do
    p = sol.position
    :math.sqrt(:math.pow(p.x_m - tx, 2) + :math.pow(p.y_m - ty, 2) + :math.pow(p.z_m - tz, 2))
  end

  @obs_path Path.join(__DIR__, "fixtures/obs/ESBC00DNK_R_20201770000_01D_30S_MO_trim.crx")
  @nav_path Path.join(__DIR__, "fixtures/nav/ESBC00DNK_R_20201770000_01D_MN.rnx")

  # GPS broadcast Klobuchar coefficients from the committed NAV header (GPSA/GPSB).
  @gps_alpha {4.6566e-09, 1.4901e-08, -5.9605e-08, -1.1921e-07}
  @gps_beta {81_920.0, 98_304.0, -65_536.0, -524_290.0}

  test "recovers the surveyed station position from real GPS observations" do
    obs = Observations.load!(@obs_path)
    eph = Broadcast.load!(@nav_path)

    {truth_x, truth_y, truth_z} = Observations.approx_position(obs)

    [%{index: index, epoch: epoch} | _] = Observations.epochs(obs)

    # Default GPS code (C1C), single frequency.
    {:ok, prs} = Observations.pseudoranges(obs, index, codes: %{"G" => ["C1C"]})

    # An over-determined GPS-only set at epoch 0.
    assert length(prs) >= 6

    # Seed with a coarse a-priori position ~45 km off the surveyed truth (not the
    # answer), so the test demonstrates convergence to the surveyed position
    # rather than assuming it. The solver freezes its elevation mask and weights
    # at the initial geometry, so the seed must be a near-surface point.
    coarse_guess = {truth_x + 30_000.0, truth_y - 20_000.0, truth_z + 25_000.0, 0.0}

    assert {:ok, sol} =
             Positioning.solve(eph, prs, epoch,
               ionosphere: true,
               troposphere: true,
               klobuchar_alpha: @gps_alpha,
               klobuchar_beta: @gps_beta,
               initial_guess: coarse_guess
             )

    assert sol.metadata.converged

    # Single-frequency broadcast SPP is metre-level; assert each axis is within a
    # few metres of the surveyed APPROX POSITION XYZ.
    assert_in_delta sol.position.x_m, truth_x, 5.0
    assert_in_delta sol.position.y_m, truth_y, 5.0
    assert_in_delta sol.position.z_m, truth_z, 5.0

    # The 3D position error is metre-level (the real solve lands within ~3 m).
    err =
      :math.sqrt(
        :math.pow(sol.position.x_m - truth_x, 2) +
          :math.pow(sol.position.y_m - truth_y, 2) +
          :math.pow(sol.position.z_m - truth_z, 2)
      )

    assert err < 5.0
  end

  test "pseudoranges/3 accepts an epoch tuple as well as an index" do
    obs = Observations.load!(@obs_path)
    [%{index: index, epoch: epoch} | _] = Observations.epochs(obs)

    {:ok, by_index} = Observations.pseudoranges(obs, index, codes: %{"G" => ["C1C"]})
    {:ok, by_tuple} = Observations.pseudoranges(obs, epoch, codes: %{"G" => ["C1C"]})

    assert by_index == by_tuple
  end

  test "pseudoranges/3 reports an out-of-range epoch index" do
    obs = Observations.load!(@obs_path)
    assert {:error, :epoch_out_of_range} = Observations.pseudoranges(obs, 9_999)
  end

  describe "values/3 (raw multi-code observations)" do
    test "exposes pseudorange, carrier-phase, Doppler, and signal-strength values" do
      obs = Observations.load!(@obs_path)
      {:ok, by_sat} = Observations.values(obs, 0)

      g05 = Map.fetch!(by_sat, "G05")
      codes = Enum.map(g05, & &1.code)
      # The fixture carries L1/L2/L5 code + phase + Doppler + SNR for G05.
      assert "C1C" in codes and "L1C" in codes and "L2W" in codes and "D1C" in codes

      l1c = Enum.find(g05, &(&1.code == "L1C"))
      assert l1c.kind == :carrier_phase
      assert l1c.units == :cycles
      assert is_float(l1c.value) and l1c.value > 0.0

      c1c = Enum.find(g05, &(&1.code == "C1C"))
      assert c1c.kind == :pseudorange and c1c.units == :meters

      assert Enum.find(g05, &(&1.code == "D1C")).kind == :doppler
      assert Enum.find(g05, &(&1.code == "S1C")).kind == :signal_strength
    end

    test "the :codes option scopes the systems and codes that cross the boundary" do
      obs = Observations.load!(@obs_path)

      {:ok, all} = Observations.values(obs, 0)

      # Restrict to GPS L1C/L2W only.
      {:ok, gps_two} = Observations.values(obs, 0, codes: %{"G" => ["L1C", "L2W"]})
      assert Enum.all?(Map.keys(gps_two), &String.starts_with?(&1, "G"))
      assert Enum.sort(Enum.map(Map.fetch!(gps_two, "G05"), & &1.code)) == ["L1C", "L2W"]
      # Non-GPS systems present in the unfiltered result are excluded.
      assert map_size(gps_two) < map_size(all)

      # A system mapped to [] keeps all of that system's codes (GPS-only).
      {:ok, gps_all} = Observations.values(obs, 0, codes: %{"G" => []})
      assert Enum.all?(Map.keys(gps_all), &String.starts_with?(&1, "G"))
      assert length(Map.fetch!(gps_all, "G05")) == length(Map.fetch!(all, "G05"))
    end

    test "index and epoch-tuple selection agree; out-of-range is tagged" do
      obs = Observations.load!(@obs_path)
      [%{index: index, epoch: epoch} | _] = Observations.epochs(obs)

      assert Observations.values(obs, index) == Observations.values(obs, epoch)
      assert {:error, :epoch_out_of_range} = Observations.values(obs, 9_999)
    end
  end

  describe "glonass_slots/1" do
    test "exposes the RINEX GLONASS FDMA channel map" do
      obs = Observations.load!(@obs_path)
      slots = Observations.glonass_slots(obs)

      assert map_size(slots) == 23
      assert slots["R01"] == 1
      assert slots["R10"] == -7
      assert slots["R21"] == 4
    end
  end

  describe "phases/3 (carrier phase with wavelength)" do
    test "returns cycles plus metres for GPS, and the L1/L2 geometry-free offset is small" do
      obs = Observations.load!(@obs_path)
      {:ok, by_sat} = Observations.phases(obs, 0)

      g05 = Map.fetch!(by_sat, "G05")
      assert Enum.all?(g05, &(&1.code |> String.starts_with?("L")))

      l1 = Enum.find(g05, &(&1.code == "L1C"))
      l2 = Enum.find(g05, &(&1.code == "L2W"))

      # GPS L1 wavelength is ~0.190294 m; L2 ~0.244210 m.
      assert_in_delta l1.wavelength_m, 0.190_294, 1.0e-5
      assert_in_delta l2.wavelength_m, 0.244_210, 1.0e-5

      # value_m = cycles * wavelength; both phases track the same geometric range,
      # so L1 - L2 in metres is the small (sub-metre) geometry-free combination,
      # not a full pseudorange-scale difference.
      assert abs(l1.value_m - l2.value_m) < 5.0
    end

    test "returns channel-dependent GLONASS G1/G2 wavelengths from the header slot map" do
      obs = Observations.load!(@obs_path)
      {:ok, by_sat} = Observations.phases(obs, 0, codes: %{"R" => ["L1C", "L2C"]})

      r01 = Map.fetch!(by_sat, "R01")
      l1 = Enum.find(r01, &(&1.code == "L1C"))
      l2 = Enum.find(r01, &(&1.code == "L2C"))

      # R01 has frequency channel +1 in the fixture's GLONASS SLOT / FRQ # map.
      f1 = 1_602_000_000.0 + 562_500.0
      f2 = 1_246_000_000.0 + 437_500.0

      assert_in_delta l1.wavelength_m, 299_792_458.0 / f1, 1.0e-15
      assert_in_delta l2.wavelength_m, 299_792_458.0 / f2, 1.0e-15
      assert_in_delta l1.value_m, l1.value_cycles * l1.wavelength_m, 1.0e-8
      assert_in_delta l2.value_m, l2.value_cycles * l2.wavelength_m, 1.0e-8
    end
  end

  describe "solve/4 default-path integrity" do
    setup do
      obs = Observations.load!(@obs_path)
      eph = Broadcast.load!(@nav_path)
      [%{index: index, epoch: epoch} | _] = Observations.epochs(obs)
      {:ok, prs} = Observations.pseudoranges(obs, index, codes: %{"G" => ["C1C"]})
      {:ok, eph: eph, prs: prs, epoch: epoch}
    end

    test "refuses an implausible converged fix instead of returning garbage", ctx do
      # From the earth-center default seed with iono/troposphere on, the kernel
      # step-tolerance test can fire at iteration 0 and flag a ~6.36e6 m fix as
      # converged. It must be refused: the position-plausibility gate catches it
      # (the fix is near radius zero), or failing that the residual-RMS gate does.
      assert {:error, reason} =
               Positioning.solve(ctx.eph, ctx.prs, ctx.epoch,
                 ionosphere: true,
                 troposphere: true,
                 klobuchar_alpha: @gps_alpha,
                 klobuchar_beta: @gps_beta
               )

      assert match?({:implausible_position, _}, reason) or match?({:no_convergence, _}, reason)
    end

    test "surfaces redundancy and RAIM checkability in metadata", ctx do
      coarse = {3_582_135.0, 532_569.0, 5_232_779.0, 0.0}
      assert {:ok, sol} = Positioning.solve(ctx.eph, ctx.prs, ctx.epoch, initial_guess: coarse)

      assert sol.metadata.used_count == length(sol.used_sats)
      assert sol.metadata.systems == ["G"]
      assert sol.metadata.redundancy == sol.metadata.used_count - 4
      assert sol.metadata.raim_checkable? == sol.metadata.redundancy >= 1
    end

    test "max_pdop rejects weak geometry and validates the threshold", ctx do
      coarse = {3_582_135.0, 532_569.0, 5_232_779.0, 0.0}

      assert {:error, {:degenerate_geometry, pdop}} =
               Positioning.solve(ctx.eph, ctx.prs, ctx.epoch,
                 initial_guess: coarse,
                 max_pdop: 0.1
               )

      assert pdop > 0.1

      assert {:ok, _sol} =
               Positioning.solve(ctx.eph, ctx.prs, ctx.epoch,
                 initial_guess: coarse,
                 max_pdop: 100.0
               )

      assert Positioning.solve(ctx.eph, ctx.prs, ctx.epoch,
               initial_guess: coarse,
               max_pdop: 0.0
             ) == {:error, {:invalid_option, :max_pdop}}
    end
  end

  describe "solve/4 :coarse_search cold start" do
    setup do
      obs = Observations.load!(@obs_path)
      eph = Broadcast.load!(@nav_path)
      {tx, ty, tz} = Observations.approx_position(obs)
      [%{index: index, epoch: epoch} | _] = Observations.epochs(obs)
      {:ok, prs} = Observations.pseudoranges(obs, index, codes: %{"G" => ["C1C"]})
      {:ok, eph: eph, prs: prs, epoch: epoch, truth: {tx, ty, tz}}
    end

    test "nil (off) is byte-identical to the single solve", ctx do
      g =
        {elem(ctx.truth, 0) + 30_000.0, elem(ctx.truth, 1) - 20_000.0, elem(ctx.truth, 2) + 25_000.0, 0.0}

      assert {:ok, single} =
               Positioning.solve(ctx.eph, ctx.prs, ctx.epoch, troposphere: true, initial_guess: g)

      assert {:ok, off} =
               Positioning.solve(ctx.eph, ctx.prs, ctx.epoch,
                 troposphere: true,
                 initial_guess: g,
                 coarse_search: nil
               )

      assert single.position == off.position
      assert single.rx_clock_s == off.rx_clock_s
      assert single.metadata == off.metadata
    end

    test "recovers a real fix from the earth-center default prior", ctx do
      assert {:ok, sol} =
               Positioning.solve(ctx.eph, ctx.prs, ctx.epoch,
                 troposphere: true,
                 coarse_search: 24
               )

      assert sol.metadata.converged
      assert sol.metadata.redundancy >= 1
      # A real near-surface fix, not the never-iterated earth-center seed
      # pass-through; metre-class on this single-frequency arc.
      assert err_3d(sol, ctx.truth) < 6.0
    end

    test "recovers a real fix from an antipodal prior that the single solve cannot", ctx do
      {tx, ty, tz} = ctx.truth
      antipodal = {-tx, -ty, -tz, 0.0}

      # The bare single solve from the antipodal seed starves on the frozen
      # horizon mask.
      assert {:error, _} =
               Positioning.solve(ctx.eph, ctx.prs, ctx.epoch,
                 troposphere: true,
                 initial_guess: antipodal
               )

      assert {:ok, sol} =
               Positioning.solve(ctx.eph, ctx.prs, ctx.epoch,
                 troposphere: true,
                 initial_guess: antipodal,
                 coarse_search: 24
               )

      assert sol.metadata.converged
      assert sol.metadata.redundancy >= 1
      assert err_3d(sol, ctx.truth) < 6.0
    end

    test "accepts true and [seeds: n] forms", ctx do
      assert {:ok, _} =
               Positioning.solve(ctx.eph, ctx.prs, ctx.epoch,
                 troposphere: true,
                 coarse_search: true
               )

      assert {:ok, _} =
               Positioning.solve(ctx.eph, ctx.prs, ctx.epoch,
                 troposphere: true,
                 coarse_search: [seeds: 12]
               )
    end

    test "every returned candidate is converged and redundant (gates applied per seed)", ctx do
      # max_pdop composes per candidate: a generous ceiling still returns a fix.
      assert {:ok, sol} =
               Positioning.solve(ctx.eph, ctx.prs, ctx.epoch,
                 troposphere: true,
                 coarse_search: 24,
                 max_pdop: 100.0
               )

      assert sol.metadata.converged
      assert sol.metadata.raim_checkable?
    end
  end
end
