defmodule Sidereon.GNSS.EphemerisTest do
  @moduledoc """
  Unified satellite-ephemeris sampling (`Sidereon.GNSS.Ephemeris`) and the
  broadcast-vs-precise accuracy check (`Sidereon.GNSS.BroadcastComparison`), on real
  2020 DOY177 IGS data.

  The broadcast-vs-precise validation differences the IGS combined broadcast
  navigation message (`BRDC00IGS`) against the CODE MGEX final precise orbits
  (`COD0MGXFIN`) over the full UTC day, for GPS, Galileo, and BeiDou. GPS LNAV
  agrees at ~1-2 m, Galileo I/NAV at sub-metre, BeiDou at a few metres
  (IS-GPS-200 / Galileo OS-SIS-ICD / BeiDou BDS-SIS-ICD broadcast accuracy); a
  wild value flags a parse/eval/coverage regression. The combined broadcast is
  used rather than a single station because one station's recording has Galileo
  and BeiDou coverage gaps that would inflate the residual.
  """
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.Broadcast
  alias Sidereon.GNSS.BroadcastComparison
  alias Sidereon.GNSS.Ephemeris
  alias Sidereon.GNSS.SP3

  @nav_path Path.join(__DIR__, "fixtures/nav/ESBC00DNK_R_20201770000_01D_MN.rnx")
  @sp3_path Path.join(__DIR__, "fixtures/sp3/GBM0MGXRAP_20201770000_01D_05M_ORB_73epoch.sp3")

  # Full-day, multi-GNSS broadcast-vs-precise inputs (IGS combined broadcast +
  # CODE MGEX final precise orbits), 2020 DOY177, sampled over the whole day.
  @full_nav_path Path.join(__DIR__, "fixtures/nav/BRDC00IGS_R_20201770000_01D_GEC.rnx")
  @full_sp3_path Path.join(__DIR__, "fixtures/sp3/COD0MGXFIN_20201770000_01D_05M_ORB.SP3")
  @full_window %{from: ~N[2020-06-25 00:15:00], to: ~N[2020-06-25 23:45:00], step_s: 900}

  setup_all do
    {:ok, broadcast: Broadcast.load!(@nav_path), sp3: SP3.load!(@sp3_path)}
  end

  describe "Ephemeris.sample/3" do
    test "samples a precise source into a per-satellite, per-epoch table", %{sp3: sp3} do
      window = %{from: ~N[2020-06-25 00:30:00], to: ~N[2020-06-25 01:00:00], step_s: 900}

      rows = Ephemeris.sample(sp3, ["G05", "G07"], window)

      # 2 satellites x 3 epochs (00:30, 00:45, 01:00), in sat order then epoch.
      assert length(rows) == 6
      assert Enum.map(rows, & &1.satellite_id) == ~w(G05 G05 G05 G07 G07 G07)

      assert Enum.map(rows, & &1.epoch) |> Enum.take(3) == [
               ~N[2020-06-25 00:30:00],
               ~N[2020-06-25 00:45:00],
               ~N[2020-06-25 01:00:00]
             ]

      row = hd(rows)
      assert row.status == :ok
      assert is_float(row.x_m) and is_float(row.y_m) and is_float(row.z_m)
      # GPS satellites sit at ~26 600 km geocentric radius.
      radius = :math.sqrt(row.x_m ** 2 + row.y_m ** 2 + row.z_m ** 2)
      assert radius > 25_000_000.0 and radius < 28_000_000.0
    end

    test "presents the identical surface for a broadcast source", %{broadcast: broadcast} do
      window = %{from: ~N[2020-06-25 01:00:00], to: ~N[2020-06-25 01:00:00], step_s: 900}

      [row] = Ephemeris.sample(broadcast, ["G07"], window)

      assert %Ephemeris.Row{satellite_id: "G07", status: :ok} = row
      assert is_float(row.x_m) and is_float(row.clock_s)
      radius = :math.sqrt(row.x_m ** 2 + row.y_m ** 2 + row.z_m ** 2)
      assert radius > 25_000_000.0 and radius < 28_000_000.0
    end

    test "reports an explicit gap instead of extrapolating", %{sp3: sp3} do
      # A satellite id that is not in the product, and an epoch outside coverage.
      window = %{from: ~N[2020-06-25 00:30:00], to: ~N[2020-06-25 00:30:00], step_s: 900}
      [missing_sat] = Ephemeris.sample(sp3, ["S20"], window)

      assert missing_sat.status == :no_ephemeris
      assert missing_sat.x_m == nil and missing_sat.y_m == nil
      assert missing_sat.z_m == nil and missing_sat.clock_s == nil

      out_of_window = %{from: ~N[2020-06-26 12:00:00], to: ~N[2020-06-26 12:00:00], step_s: 900}
      [out] = Ephemeris.sample(sp3, ["G05"], out_of_window)
      assert out.status == :no_ephemeris
      assert out.x_m == nil
    end

    test "rejects a non-positive step and an inverted window", %{sp3: sp3} do
      assert_raise ArgumentError, fn ->
        Ephemeris.sample(sp3, ["G05"], %{
          from: ~N[2020-06-25 00:00:00],
          to: ~N[2020-06-25 01:00:00],
          step_s: 0
        })
      end

      assert_raise ArgumentError, fn ->
        Ephemeris.sample(sp3, ["G05"], %{
          from: ~N[2020-06-25 01:00:00],
          to: ~N[2020-06-25 00:00:00],
          step_s: 900
        })
      end
    end
  end

  describe "BroadcastComparison.compare/4: broadcast vs precise over a full day" do
    setup do
      nav = Broadcast.load!(@full_nav_path)
      sp3 = SP3.load!(@full_sp3_path)
      sats = SP3.satellite_ids(sp3)

      reports =
        Map.new(["G", "E", "C"], fn sys ->
          ids = sats |> Enum.filter(&String.starts_with?(&1, sys)) |> Enum.sort()
          {sys, BroadcastComparison.compare(nav, sp3, ids, @full_window)}
        end)

      {:ok, reports: reports}
    end

    test "GPS LNAV orbit agreement is ~1-2 m over the day", %{reports: reports} do
      o = reports["G"].overall
      assert o.count > 1000

      # ~1-2 m expected. The lower bound is non-tautological: a zeroed/broken eval
      # collapses to ~0; the upper bound flags a parse/eval/coverage regression.
      assert o.orbit_3d_rms_m > 0.3 and o.orbit_3d_rms_m < 3.0
      assert o.orbit_3d_max_m < 6.0
    end

    test "Galileo I/NAV orbit agreement is sub-metre to ~1 m over the day", %{reports: reports} do
      o = reports["E"].overall
      assert o.count > 1000

      # Galileo broadcast is the most accurate constellation; a gappy single-station
      # nav inflates this past 10 m, so the upper bound guards coverage + eval.
      assert o.orbit_3d_rms_m > 0.1 and o.orbit_3d_rms_m < 2.0
      assert o.orbit_3d_max_m < 4.0
    end

    test "BeiDou orbit agreement is a few metres over the day", %{reports: reports} do
      o = reports["C"].overall
      assert o.count > 300

      # BeiDou-2 SIS is metre-level for MEO/IGSO; the upper bound flags a defect.
      assert o.orbit_3d_rms_m > 0.5 and o.orbit_3d_rms_m < 6.0
      assert o.orbit_3d_max_m < 12.0
    end

    test "the radial/along/cross decomposition is orthonormal per system", %{reports: reports} do
      for sys <- ["G", "E", "C"] do
        o = reports[sys].overall
        assert o.radial_rms_m > 0.0 and o.along_rms_m > 0.0 and o.cross_rms_m > 0.0

        # RAC is an orthonormal rotation of the difference, so the 3D RMS equals the
        # quadrature sum of the component RMS values.
        quadrature =
          :math.sqrt(o.radial_rms_m ** 2 + o.along_rms_m ** 2 + o.cross_rms_m ** 2)

        assert_in_delta o.orbit_3d_rms_m, quadrature, 1.0e-6
      end
    end

    test "clock differences are finite per system, and removing the datum shrinks them",
         %{reports: reports} do
      for sys <- ["G", "E", "C"] do
        o = reports[sys].overall
        assert is_float(o.clock_rms_m)
        assert o.clock_rms_m > 0.0 and o.clock_rms_m < 50.0

        # Removing the per-epoch common reference-clock offset (median over the
        # system's satellites) leaves the true signal-in-space clock error:
        # finite and strictly smaller than the raw, datum-laden value.
        assert is_float(o.clock_datum_removed_rms_m)
        assert o.clock_datum_removed_rms_m > 0.0
        assert o.clock_datum_removed_rms_m < o.clock_rms_m
      end
    end

    test "per-satellite stats are populated and out-of-coverage cells are skipped, not extrapolated",
         %{reports: reports} do
      g = reports["G"]
      assert map_size(g.per_satellite) > 20
      assert is_list(g.missing)

      {_sat, stats} = Enum.find(g.per_satellite, fn {_sat, s} -> s.count > 0 end)
      assert stats.orbit_3d_rms_m > 0.0
    end
  end
end
