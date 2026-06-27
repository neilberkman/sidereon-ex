defmodule Sidereon.GNSS.SolutionReportTest do
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.Observables
  alias Sidereon.GNSS.Positioning
  alias Sidereon.GNSS.QC
  alias Sidereon.GNSS.SolutionReport
  alias Sidereon.GNSS.SP3

  @grg Path.join(__DIR__, "fixtures/sp3/GRG0MGXFIN_20201760000_01D_15M_ORB.SP3")

  # Known ground receiver in ITRF/ECEF metres (near IGS ESBC, Copenhagen).
  @rx {3_512_900.0, 780_500.0, 5_248_700.0}

  # Interior epoch of the SP3 span (2020-06-24 00:00 -> 23:45 GPST).
  @epoch ~N[2020-06-24 12:00:00]

  @c 299_792_458.0

  # Clean receiver clock bias (~30 km of range); GPS-only -> one clock.
  @rx_bias_s 1.0e-4

  @initial_guess {3_513_900.0, 779_500.0, 5_249_700.0, 0.0}

  @solve_opts [initial_guess: @initial_guess]

  setup_all do
    sp3 = SP3.load!(@grg)

    visible =
      sp3
      |> Observables.predict_all(@rx, @epoch)
      |> Enum.filter(fn {id, r} -> String.starts_with?(id, "G") and match?({:ok, _}, r) end)
      |> Enum.map(fn {id, {:ok, obs}} -> {id, obs} end)
      |> Enum.filter(fn {_id, obs} -> obs.elevation_deg > 0.0 end)
      |> Enum.sort_by(fn {_id, obs} -> -obs.elevation_deg end)
      |> Enum.take(7)

    clean_obs =
      Enum.map(visible, fn {id, obs} ->
        {id, obs.geometric_range_m + @c * (@rx_bias_s - obs.sat_clock_s)}
      end)

    {:ok, sol} = Positioning.solve(sp3, clean_obs, @epoch, @solve_opts)
    {:ok, report} = SolutionReport.build(sol, sp3, @epoch)

    {:ok, sp3: sp3, visible: visible, clean_obs: clean_obs, sol: sol, report: report}
  end

  describe "consistency with source primitives" do
    test "each used-sat residual EQUALS Solution.residuals_m exactly", ctx do
      residual_by_sat = Map.new(Enum.zip(ctx.sol.used_sats, ctx.sol.residuals_m))

      for row <- used_rows(ctx.report) do
        assert row.residual_m == residual_by_sat[row.satellite_id]
      end
    end

    test "each used-sat normalized_residual EQUALS QC.raim exactly", ctx do
      raim = QC.raim(ctx.sol)

      for row <- used_rows(ctx.report) do
        assert row.normalized_residual == raim.normalized_residuals[row.satellite_id]
      end
    end

    test "each row el/az EQUALS Observables.predict at the solved position", ctx do
      for row <- ctx.report.satellites do
        case Observables.predict(ctx.sp3, row.satellite_id, ctx.sol.position, @epoch) do
          {:ok, obs} ->
            assert row.elevation_deg == obs.elevation_deg
            assert row.azimuth_deg == obs.azimuth_deg

          {:error, _} ->
            assert row.elevation_deg == nil
            assert row.azimuth_deg == nil
        end
      end
    end

    test "residual_rms_m EQUALS sqrt(mean of squared residuals)", ctx do
      residuals = ctx.sol.residuals_m

      expected =
        :math.sqrt(Enum.sum(Enum.map(residuals, &(&1 * &1))) / length(residuals))

      assert ctx.report.summary.residual_rms_m == expected
    end

    test "integrity block EQUALS QC.raim(solution)", ctx do
      raim = QC.raim(ctx.sol)

      expected =
        Map.take(raim, [
          :fault_detected?,
          :test_statistic,
          :threshold,
          :dof,
          :testable?,
          :worst_sat
        ])

      assert ctx.report.summary.integrity == expected
    end

    test "dop, position, and geodetic are verbatim pass-throughs", ctx do
      assert ctx.report.summary.dop == ctx.sol.dop
      assert ctx.report.summary.position.ecef == ctx.sol.position
      assert ctx.report.summary.position.geodetic == ctx.sol.geodetic
    end

    test "a clean scenario reports no fault", ctx do
      assert ctx.report.summary.integrity.fault_detected? == false
      assert ctx.report.summary.integrity.testable? == true
    end
  end

  describe "fault injection" do
    setup ctx do
      # Bias the second observation by +200 m. This satellite is deliberately NOT
      # the worst satellite on the clean solution (see the discrimination test
      # below), so any assertion that the bias localizes to it is driven by the
      # injected fault, not by a pre-existing residual ranking. +200 m is far
      # above the clean residual level and localizes under unit weights.
      biased_sat = elem(Enum.at(ctx.clean_obs, 1), 0)

      faulted_obs =
        Enum.map(ctx.clean_obs, fn {sat, pr} ->
          if sat == biased_sat, do: {sat, pr + 200.0}, else: {sat, pr}
        end)

      {:ok, faulted_sol} = Positioning.solve(ctx.sp3, faulted_obs, @epoch, @solve_opts)
      {:ok, faulted_report} = SolutionReport.build(faulted_sol, ctx.sp3, @epoch)

      {:ok, biased_sat: biased_sat, faulted_report: faulted_report}
    end

    test "the biased satellite is not the clean worst satellite (discrimination)", ctx do
      # The localization assertions below would be vacuous if the biased
      # satellite were already worst on the clean solution. Lock that out.
      clean_integrity = ctx.report.summary.integrity
      assert clean_integrity.worst_sat != ctx.biased_sat

      clean_worst =
        ctx.report.satellites
        |> Enum.filter(& &1.normalized_residual)
        |> Enum.max_by(&abs(&1.normalized_residual))

      assert clean_worst.satellite_id != ctx.biased_sat
    end

    test "the biased satellite drives the integrity verdict", ctx do
      integrity = ctx.faulted_report.summary.integrity

      assert integrity.fault_detected? == true
      assert integrity.worst_sat == ctx.biased_sat
    end

    test "the biased satellite has the largest |normalized_residual|", ctx do
      worst =
        ctx.faulted_report.satellites
        |> Enum.filter(& &1.normalized_residual)
        |> Enum.max_by(&abs(&1.normalized_residual))

      assert worst.satellite_id == ctx.biased_sat
    end
  end

  describe "rows: used + rejected" do
    setup ctx do
      # Add a satellite below the elevation mask so rejected_sats is non-empty.
      # Find the lowest-elevation visible GPS sat among the full set and make a
      # negative-elevation entry by using a satellite that is below the horizon.
      below =
        ctx.sp3
        |> Observables.predict_all(@rx, @epoch)
        |> Enum.filter(fn {id, r} -> String.starts_with?(id, "G") and match?({:ok, _}, r) end)
        |> Enum.map(fn {id, {:ok, obs}} -> {id, obs} end)
        |> Enum.find(fn {_id, obs} -> obs.elevation_deg < 0.0 end)

      obs_with_rejected =
        case below do
          {id, obs} ->
            ctx.clean_obs ++
              [{id, obs.geometric_range_m + @c * (@rx_bias_s - obs.sat_clock_s)}]

          nil ->
            ctx.clean_obs
        end

      {:ok, sol} = Positioning.solve(ctx.sp3, obs_with_rejected, @epoch, @solve_opts)
      {:ok, report} = SolutionReport.build(sol, ctx.sp3, @epoch)

      {:ok, rej_sol: sol, rej_report: report}
    end

    test "row counts match Solution used/rejected counts", ctx do
      report = ctx.rej_report
      sol = ctx.rej_sol

      assert Enum.count(report.satellites, & &1.used?) == length(sol.used_sats)
      assert Enum.count(report.satellites, &(not &1.used?)) == length(sol.rejected_sats)
    end

    test "rejected rows carry nil residual and a reason atom", ctx do
      refute Enum.empty?(ctx.rej_sol.rejected_sats)

      for row <- Enum.reject(ctx.rej_report.satellites, & &1.used?) do
        assert row.residual_m == nil
        assert row.normalized_residual == nil
        assert row.rejected_reason in [:no_ephemeris, :low_elevation]
      end
    end

    test "ordering: used rows precede rejected; elevation non-increasing within used", ctx do
      rows = ctx.rej_report.satellites
      used_flags = Enum.map(rows, & &1.used?)

      # No used row appears after a rejected row.
      refute Enum.any?(Enum.drop_while(used_flags, & &1), & &1)

      used_el =
        rows
        |> Enum.filter(& &1.used?)
        |> Enum.map(& &1.elevation_deg)
        |> Enum.reject(&is_nil/1)

      assert used_el == Enum.sort(used_el, :desc)
    end
  end

  describe "format/1" do
    test "returns deterministic binary lines covering position and every row", ctx do
      lines = SolutionReport.format(ctx.report)

      assert is_list(lines)
      assert Enum.all?(lines, &is_binary/1)

      # Deterministic: identical output on repeated calls.
      assert lines == SolutionReport.format(ctx.report)

      # Position x appears somewhere.
      x_str = :erlang.float_to_binary(ctx.sol.position.x_m, decimals: 4)
      assert Enum.any?(lines, &String.contains?(&1, x_str))

      # One line per satellite row (header lines precede them).
      assert Enum.count(lines, fn line ->
               Enum.any?(ctx.report.satellites, &String.starts_with?(line, &1.satellite_id))
             end) == length(ctx.report.satellites)
    end
  end

  describe "errors (no raise)" do
    test "malformed solution is a tagged error", ctx do
      assert {:error, _} = SolutionReport.build(%{}, ctx.sp3, @epoch)
    end

    test "malformed source is a tagged error", ctx do
      assert {:error, _} = SolutionReport.build(ctx.sol, :not_sp3, @epoch)
    end

    test "malformed epoch is a tagged error", ctx do
      assert {:error, _} = SolutionReport.build(ctx.sol, ctx.sp3, :not_epoch)
    end
  end

  describe "degenerate geometry" do
    test "dof <= 0 still reports, surfaced as testable?: false", ctx do
      four_obs = Enum.take(ctx.clean_obs, 4)
      {:ok, sol} = Positioning.solve(ctx.sp3, four_obs, @epoch, @solve_opts)
      assert length(sol.used_sats) == 4

      assert {:ok, report} = SolutionReport.build(sol, ctx.sp3, @epoch)

      assert report.summary.integrity.testable? == false
      assert report.summary.integrity.threshold == nil
      assert report.summary.integrity.dof <= 0
      assert length(report.satellites) == 4
    end
  end

  defp used_rows(report), do: Enum.filter(report.satellites, & &1.used?)
end
