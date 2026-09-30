defmodule Sidereon.GNSS.QCTest do
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.Broadcast
  alias Sidereon.GNSS.Observables
  alias Sidereon.GNSS.Positioning
  alias Sidereon.GNSS.QC
  alias Sidereon.GNSS.SP3
  alias Sidereon.Test.ModelClock

  @grg Path.join(__DIR__, "fixtures/sp3/GRG0MGXFIN_20201760000_01D_15M_ORB.SP3")

  # Known ground receiver in ITRF/ECEF metres (near IGS ESBC, Copenhagen), as
  # used by the observables/positioning tests.
  @rx {3_512_900.0, 780_500.0, 5_248_700.0}

  # Interior epoch of the SP3 span (2020-06-24 00:00 -> 23:45 GPST).
  @epoch ~N[2020-06-24 12:00:00]

  # Chosen clean receiver clock bias (~30 km of range); GPS-only -> one clock.
  @rx_bias_s 1.0e-4

  # An initial guess a few km off truth with a zero clock seed.
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

    # Clean pseudorange set: P = geometric_range + c*(rx_bias - sat_clock), with
    # each satellite placed from its pseudorange as the solver places it.
    clean_obs =
      Enum.map(visible, fn {id, _obs} ->
        {id, ModelClock.spp_pseudorange(sp3, id, @rx, @epoch, @rx_bias_s)}
      end)

    {:ok, sp3: sp3, visible: visible, clean_obs: clean_obs}
  end

  defp position_error(solution) do
    {x, y, z} = @rx
    p = solution.position
    :math.sqrt(:math.pow(p.x_m - x, 2) + :math.pow(p.y_m - y, 2) + :math.pow(p.z_m - z, 2))
  end

  describe "pseudorange_variance/2 (elevation-dependent weighting)" do
    test "monotonically decreases as elevation rises" do
      vars = Enum.map([5, 15, 30, 60, 90], &QC.pseudorange_variance/1)

      assert vars == Enum.sort(vars, :desc)
      assert Enum.uniq(vars) == vars
    end

    test "matches sigma^2 = a^2 + b^2 / sin^2(el) at sample elevations" do
      a = 0.3
      b = 0.3

      for el <- [30.0, 90.0] do
        expected = a * a + b * b / :math.pow(:math.sin(el * :math.pi() / 180.0), 2)
        assert_in_delta QC.pseudorange_variance(el), expected, 1.0e-12
      end

      # At zenith sin(el) = 1, so variance = a^2 + b^2 = 0.18.
      assert_in_delta QC.pseudorange_variance(90.0), 0.18, 1.0e-9
    end

    test "C/N0 variant returns smaller variance for a higher C/N0" do
      strong = QC.pseudorange_variance(30.0, model: :elevation_cn0, cn0: 50.0)
      weak = QC.pseudorange_variance(30.0, model: :elevation_cn0, cn0: 30.0)

      assert is_float(strong) and is_float(weak)
      assert strong < weak
    end

    test "elevation validation is delegated to the core variance model" do
      assert QC.pseudorange_variance(0.0) == {:error, :invalid_elevation}
      assert_in_delta QC.pseudorange_variance(0.0, b: 0.0), 0.09, 1.0e-12
      assert is_float(QC.pseudorange_variance(-5.0))
      assert QC.pseudorange_variance(91.0) == {:error, :invalid_elevation}
      assert QC.pseudorange_variance(30.0, a: -1.0) == {:error, :invalid_parameter}
    end

    test "C/N0 model without a cn0 value is a tagged error" do
      assert QC.pseudorange_variance(30.0, model: :elevation_cn0) ==
               {:error, :missing_cn0}
    end

    test "sigmas/2 and weight_vector/2 are consistent and drop invalid entries" do
      entries = [{"G01", 90.0}, {"G02", 30.0}, {"G03", -1.0}, {"G04", 0.0}]
      sigmas = QC.sigmas(entries)
      weights = QC.weight_vector(entries)

      assert Map.has_key?(sigmas, "G03")
      assert Map.has_key?(weights, "G03")
      refute Map.has_key?(sigmas, "G04")
      refute Map.has_key?(weights, "G04")

      for {sat, sigma} <- sigmas do
        assert_in_delta weights[sat], 1.0 / (sigma * sigma), 1.0e-12
      end
    end
  end

  describe "chi2_inv/2 (chi-square threshold)" do
    test "matches published 99.9th-percentile critical values for dof 1..5" do
      # Standard chi-square distribution critical values at the 0.999 quantile.
      published = %{1 => 10.828, 2 => 13.816, 3 => 16.266, 4 => 18.467, 5 => 20.515}

      for {dof, ref} <- published do
        got = QC.chi2_inv(0.999, dof)
        assert_in_delta got, ref, 1.0e-3
      end
    end

    test "core probability and degree refusals retain their typed quality kind" do
      invalid_probability = assert_raise QC.QualityError, fn -> QC.chi2_inv(0.0, 1) end
      assert invalid_probability.kind == :invalid_probability

      invalid_dof = assert_raise QC.QualityError, fn -> QC.chi2_inv(0.95, 0) end
      assert invalid_dof.kind == :invalid_dof
      probability_first = assert_raise QC.QualityError, fn -> QC.chi2_inv(0.0, 0) end
      assert probability_first.kind == :invalid_probability
      negative_dof = assert_raise QC.QualityError, fn -> QC.chi2_inv(0.95, -1) end
      assert negative_dof.kind == :invalid_dof
      assert_raise ArgumentError, fn -> QC.chi2_inv(0.95, 1.5) end
      assert_raise ArgumentError, fn -> QC.chi2_inv(Integer.pow(10, 400), 1) end
    end
  end

  describe "raim/2 on a clean SP3-synthesized set" do
    test "clean solve recovers truth and RAIM passes", ctx do
      assert {:ok, sol} = Positioning.solve(ctx.sp3, ctx.clean_obs, @epoch, @solve_opts)

      assert position_error(sol) < 1.0e-2

      result = QC.raim(sol)
      direct = QC.raim_for_solution(sol)

      assert result.fault_detected? == false
      assert result.testable? == true
      assert direct == result
      # GPS-only: n_systems = 1, n_states = 4.
      assert result.dof == length(sol.used_sats) - 4
      assert result.test_statistic < result.threshold
    end

    test "solution RAIM uses its stored variance vector and solved clock count", ctx do
      assert {:ok, solution} = Positioning.solve(ctx.sp3, ctx.clean_obs, @epoch, @solve_opts)

      assert length(solution.pseudorange_variances_m2) == length(solution.used_sats)
      assert length(solution.weights) == length(solution.used_sats)

      aliases = ["J01", "S20" | Enum.drop(solution.used_sats, 2)]

      aliased_solution = %{
        solution
        | used_sats: aliases,
          system_clocks_s: %{"G" => solution.rx_clock_s}
      }

      result = QC.raim_for_solution(aliased_solution)

      assert result.dof == length(aliases) - 4
      assert QC.raim_for_solution(aliased_solution, n_systems: nil) == result
      assert QC.raim_for_solution(aliased_solution, n_systems: 3).dof == length(aliases) - 6

      for invalid <- [1.5, :bad, 0] do
        error =
          assert_raise QC.QualityError, fn ->
            QC.raim_for_solution(aliased_solution, n_systems: invalid)
          end

        assert error.kind == :invalid_system_count
      end
    end
  end

  describe "raim/2 direct post-solve input" do
    test "builds input from lists and returns the core diagnostic fields" do
      used_sats = ["G01", "G02", "G03", "G04", "G05"]
      residuals_m = [0.15, -0.20, 0.05, 0.10, -0.12]
      weight_entries = [{"G01", 70.0}, {"G02", 55.0}, {"G03", 40.0}, {"G04", 35.0}, {"G05", 25.0}]

      input = QC.RaimInput.new(used_sats, residuals_m)
      result = QC.raim(input, weights: weight_entries, n_systems: 1)
      weights = QC.weight_vector(weight_entries)

      expected_statistic =
        Enum.zip(used_sats, residuals_m)
        |> Enum.reduce(0.0, fn {sat, residual}, acc ->
          acc + residual * residual * weights[sat]
        end)

      expected_rms =
        :math.sqrt(Enum.reduce(residuals_m, 0.0, fn residual, acc -> acc + residual * residual end) / 5.0)

      assert %QC.RaimResult{} = result
      assert result.fault_detected == false
      assert result.testable
      assert result.dof == 1
      assert_in_delta result.test_statistic, expected_statistic, 1.0e-12
      assert_in_delta result.threshold, QC.chi2_inv(0.999, 1), 1.0e-12
      assert_in_delta result.reduced_chi_square, expected_statistic, 1.0e-12
      assert_in_delta result.rms_m, expected_rms, 1.0e-12
      assert Map.keys(result.normalized_residuals) == used_sats
      assert result.worst_sat in used_sats

      no_overrides = QC.raim(input, weights: [], n_systems: 1)
      assert no_overrides.testable
      assert no_overrides.dof == 1
    end

    test "solution weighting requires actual variances and unit weighting ignores them" do
      used_sats = ["G01", "G02", "G03", "G04", "G05"]
      residuals_m = [0.15, -0.20, 0.05, 0.10, -0.12]
      input = QC.RaimInput.new(used_sats, residuals_m)

      missing = assert_raise QC.QualityError, fn -> QC.raim(input) end
      assert missing.kind == :missing_variances

      with_variances = QC.RaimInput.new(used_sats, residuals_m, [0.25, 0.25, 0.25, 0.25, 0.25])
      result = QC.raim(with_variances)

      expected =
        Enum.reduce(residuals_m, 0.0, fn residual, sum -> sum + residual * residual / 0.25 end)

      assert_in_delta result.test_statistic, expected, 1.0e-12

      invalid_variances = QC.RaimInput.new(used_sats, residuals_m, [0.25, 0.25, 0.0, 0.25, 0.25])
      invalid = assert_raise QC.QualityError, fn -> QC.raim(invalid_variances) end
      assert invalid.kind == :invalid_variance
      assert %QC.RaimResult{} = QC.raim(invalid_variances, weights: :unit)
    end
  end

  describe "raim/2 fault detection" do
    setup ctx do
      # Inject the fault on a known-localizing satellite. Detection
      # (fault_detected?, T > threshold) and the FDE exclusion of the
      # largest-normalized-residual satellite are robust for any choice, but the
      # `worst_sat == biased_sat` equality is geometry-dependent: with unit
      # weights least squares can spread a single bias across the residual
      # vector so the largest post-fit residual lands on a neighbour rather than
      # the faulted satellite. Which satellites localize is a non-monotonic
      # function of the full geometry (not simply elevation), so this test fixes
      # on one index empirically confirmed to localize for this fixture/epoch;
      # it is not a claim that every satellite would.
      biased_sat = elem(Enum.at(ctx.clean_obs, 4), 0)

      faulted_obs =
        Enum.map(ctx.clean_obs, fn {sat, pr} ->
          if sat == biased_sat, do: {sat, pr + 200.0}, else: {sat, pr}
        end)

      {:ok, biased_sat: biased_sat, faulted_obs: faulted_obs}
    end

    test "a +200 m bias on one satellite is detected and is the worst sat", ctx do
      assert {:ok, sol} = Positioning.solve(ctx.sp3, ctx.faulted_obs, @epoch, @solve_opts)

      result = QC.raim(sol)

      assert result.fault_detected? == true
      assert result.test_statistic > result.threshold
      assert result.worst_sat == ctx.biased_sat
    end

    test "FDE excludes exactly the biased satellite and recovers the position", ctx do
      # The faulted solve's own error, for the recovery comparison.
      {:ok, faulted_sol} = Positioning.solve(ctx.sp3, ctx.faulted_obs, @epoch, @solve_opts)
      faulted_error = position_error(faulted_sol)

      assert {:ok, fde} = QC.fde(ctx.sp3, ctx.faulted_obs, @epoch, @solve_opts)

      assert fde.excluded == [{ctx.biased_sat, :raim_excluded}]
      assert fde.iterations == 1
      assert fde.raim == QC.raim(fde.solution)

      recovered_error = position_error(fde.solution)
      assert recovered_error < 1.0e-2
      assert recovered_error < faulted_error

      # The cleaned solution passes RAIM.
      assert QC.raim(fde.solution).fault_detected? == false
    end
  end

  describe "fde/4 on a clean set" do
    test "excludes nothing and converges immediately", ctx do
      assert {:ok, fde} = QC.fde(ctx.sp3, ctx.clean_obs, @epoch, @solve_opts)

      assert fde.excluded == []
      assert fde.iterations == 0
      assert fde.raim == QC.raim(fde.solution)
      assert position_error(fde.solution) < 1.0e-2
    end
  end

  describe "fde/4 option validation" do
    test "malformed p_fa, weights, exclusion budgets, and RMS caps return tagged errors", ctx do
      assert QC.fde(ctx.sp3, ctx.clean_obs, @epoch, @solve_opts ++ [p_fa: 0.0]) ==
               {:error, {:invalid_option, :p_fa}}

      assert {:error, %QC.QualityError{kind: :invalid_probability} = quality_error} =
               QC.fde(ctx.sp3, ctx.clean_obs, @epoch, @solve_opts ++ [p_fa: 1.0e-20])

      assert quality_error.message == "invalid probability"

      assert QC.fde(ctx.sp3, ctx.clean_obs, @epoch, @solve_opts ++ [weights: :bad]) ==
               {:error, {:invalid_option, :weights}}

      assert QC.fde(ctx.sp3, ctx.clean_obs, @epoch, @solve_opts ++ [weights: %{"G01" => -1.0}]) ==
               {:error, {:invalid_option, :weights}}

      assert QC.fde(ctx.sp3, ctx.clean_obs, @epoch, @solve_opts ++ [max_exclusions: :bad]) ==
               {:error, {:invalid_option, :max_exclusions}}

      assert QC.fde(ctx.sp3, ctx.clean_obs, @epoch, @solve_opts ++ [max_exclusions: -1]) ==
               {:error, {:invalid_option, :max_exclusions}}

      assert QC.fde(ctx.sp3, ctx.clean_obs, @epoch, @solve_opts ++ [max_exclusion_rms_m: 0.0]) ==
               {:error, {:invalid_option, :max_exclusion_rms_m}}

      assert QC.fde(
               ctx.sp3,
               ctx.clean_obs,
               @epoch,
               @solve_opts ++ [max_exclusions: 0, max_exclusion_rms_m: :nan]
             ) ==
               {:error, {:invalid_option, :max_exclusion_rms_m}}

      huge = Integer.pow(10, 400)

      assert QC.fde(ctx.sp3, ctx.clean_obs, @epoch, @solve_opts ++ [max_exclusion_rms_m: huge]) ==
               {:error, {:invalid_option, :max_exclusion_rms_m}}
    end

    test "removed max_iterations is refused on all SP3 and broadcast FDE routes" do
      sp3 = %SP3{handle: nil, time_scale: "GPS", coverage_start: 0.0, coverage_end: 0.0}
      broadcast = %Broadcast{handle: nil}

      assert QC.fde(sp3, [], @epoch, max_iterations: nil) ==
               {:error, {:invalid_option, :max_iterations}}

      assert QC.robust_fde(sp3, [], @epoch, max_iterations: 0, max_exclusions: 0) ==
               {:error, {:invalid_option, :max_iterations}}

      assert QC.fde(broadcast, [], @epoch, max_iterations: 0) ==
               {:error, {:invalid_option, :max_iterations}}

      assert QC.robust_fde(broadcast, [], @epoch, max_iterations: 1) ==
               {:error, {:invalid_option, :max_iterations}}
    end

    test "range FDE rejects the removed option and unrepresentable RMS caps" do
      huge = Integer.pow(10, 400)

      assert QC.raim_fde_design([], max_iterations: 0) ==
               {:error, {:invalid_option, :max_iterations}}

      assert QC.raim_fde_design([], max_exclusion_rms_m: huge) ==
               {:error, {:invalid_option, :max_exclusion_rms_m}}
    end
  end

  describe "degenerate geometry" do
    test "dof <= 0 -> RAIM reports a non-testable result without raising", ctx do
      # Exactly four GPS sats: n_used == n_states (4), so dof == 0.
      four_obs = Enum.take(ctx.clean_obs, 4)
      assert {:ok, sol} = Positioning.solve(ctx.sp3, four_obs, @epoch, @solve_opts)
      assert length(sol.used_sats) == 4

      result = QC.raim(sol)

      assert result.testable? == false
      assert result.fault_detected? == false
      assert result.dof <= 0
      assert result.threshold == nil
    end

    test "fde/4 with too few satellites returns a tagged error", ctx do
      three_obs = Enum.take(ctx.clean_obs, 3)

      assert {:error, {:too_few_satellites, _used, _required}} =
               QC.fde(ctx.sp3, three_obs, @epoch, @solve_opts)
    end
  end

  describe "fde/4 exhausted-but-faulted (defect 1)" do
    setup ctx do
      # Inject a large bias on the same localizing satellite, but cap the loop at
      # zero iterations so the fault cannot be excluded: the loop is forced past
      # its budget with RAIM still flagging the fix.
      biased_sat = elem(Enum.at(ctx.clean_obs, 4), 0)

      faulted_obs =
        Enum.map(ctx.clean_obs, fn {sat, pr} ->
          if sat == biased_sat, do: {sat, pr + 500.0}, else: {sat, pr}
        end)

      {:ok, biased_sat: biased_sat, faulted_obs: faulted_obs}
    end

    test "the loop preserves the unresolved state and RAIM result at the cap", ctx do
      # max_exclusions: 0 means no exclusion is permitted; RAIM still flags the
      # fix, so fde/4 must return the tagged refusal carrying the statistic.
      opts = Keyword.merge(@solve_opts, max_exclusions: 0, weights: :unit)

      assert {:error, {:fault_unresolved, unresolved}} =
               QC.fde(ctx.sp3, ctx.faulted_obs, @epoch, opts)

      assert unresolved.reason == "exclusion_budget_exhausted"
      assert unresolved.solution.used_sats != []
      assert unresolved.excluded == []
      assert unresolved.iterations == 0
      assert unresolved.raim.fault_detected?
      assert is_float(unresolved.raim.test_statistic) and unresolved.raim.test_statistic > 0.0

      # The preserved RAIM result is the test for the last faulted solution.
      {:ok, faulted_sol} = Positioning.solve(ctx.sp3, ctx.faulted_obs, @epoch, @solve_opts)
      assert unresolved.raim == QC.raim(faulted_sol, weights: :unit)
    end

    test "a non-testable (dof <= 0) set is a legitimate {:ok} success, not a refusal", ctx do
      # Exactly four GPS sats: dof == 0, so RAIM is non-testable and reports
      # fault_detected? false. fde/4 returns {:ok} with nothing excluded.
      four_obs = Enum.take(ctx.clean_obs, 4)

      assert {:ok, fde} = QC.fde(ctx.sp3, four_obs, @epoch, @solve_opts)
      assert fde.excluded == []
    end
  end

  describe "raim/2 option validation" do
    test "p_fa outside its documented interval raises ArgumentError", ctx do
      assert {:ok, sol} = Positioning.solve(ctx.sp3, ctx.clean_obs, @epoch, @solve_opts)

      assert_raise ArgumentError, fn -> QC.raim(sol, p_fa: 0.0) end
      assert_raise ArgumentError, fn -> QC.raim(sol, p_fa: 1.0) end
      assert_raise ArgumentError, fn -> QC.raim(sol, p_fa: -0.1) end
    end

    test "a non-positive custom weight raises ArgumentError", ctx do
      assert {:ok, sol} = Positioning.solve(ctx.sp3, ctx.clean_obs, @epoch, @solve_opts)
      bad_weights = Map.new(sol.used_sats, fn s -> {s, -1.0} end)

      assert_raise ArgumentError, fn -> QC.raim(sol, weights: bad_weights) end
    end

    test "tiny positive p_fa reaches the core and is only refused when a quantile is needed" do
      four = QC.RaimInput.new(["G01", "G02", "G03", "G04"], [0.1, -0.2, 0.3, -0.1])
      untestable = QC.raim(four, p_fa: 1.0e-20, weights: :unit, n_systems: 1)
      refute untestable.testable

      five = QC.RaimInput.new(["G01", "G02", "G03", "G04", "G05"], [0.1, -0.2, 0.3, -0.1, 0.2])

      error =
        assert_raise QC.QualityError, fn ->
          QC.raim(five, p_fa: 1.0e-20, weights: :unit, n_systems: 1)
        end

      assert error.kind == :invalid_probability
    end
  end

  describe "solve/4 :pseudorange_code" do
    test "an SP3 source states no group delay; the code kind sets the RTKLIB pseudorange variance",
         ctx do
      assert {:ok, single} = Positioning.solve(ctx.sp3, ctx.clean_obs, @epoch, @solve_opts)

      assert {:ok, iono_free} =
               Positioning.solve(
                 ctx.sp3,
                 ctx.clean_obs,
                 @epoch,
                 @solve_opts ++ [pseudorange_code: :ionosphere_free]
               )

      # RTKLIB rescode adds 0.3^2 m^2 and, with the ionosphere uncorrected,
      # 25 (f_L1 / f)^4 m^2 to single-frequency code; ionosphere-free code takes
      # neither and nine times the code error, at most 9 * 1.12 m^2 above the
      # 5 degree floor. Every single-frequency variance is therefore larger, so
      # its position covariance is larger on each axis, and the weights move
      # the fix while the satellites used stay the same.
      assert single.used_sats == iono_free.used_sats
      assert single.position != iono_free.position

      for axis <- 0..2 do
        assert Enum.at(Enum.at(single.position_covariance.ecef_m2, axis), axis) >
                 Enum.at(Enum.at(iono_free.position_covariance.ecef_m2, axis), axis)
      end

      assert single.metadata.ut1_degraded == nil
    end

    test "any other value is refused as an invalid option", ctx do
      assert Positioning.solve(
               ctx.sp3,
               ctx.clean_obs,
               @epoch,
               @solve_opts ++ [pseudorange_code: :dual]
             ) ==
               {:error, {:invalid_option, :pseudorange_code}}

      assert QC.fde(ctx.sp3, ctx.clean_obs, @epoch, @solve_opts ++ [pseudorange_code: "IF"]) ==
               {:error, {:invalid_option, :pseudorange_code}}
    end
  end

  describe "solve/4 :huber contract" do
    test "huber:true with no overrides solves (uses the validated 5 m scale-floor default)",
         ctx do
      # A clean synthetic set has no outliers, so Huber is a no-op here; the point
      # is that the default opt-in path is accepted and returns a fix using the
      # validated default rather than a neutered 1 m floor.
      assert {:ok, sol} =
               Positioning.solve(ctx.sp3, ctx.clean_obs, @epoch, @solve_opts ++ [huber: true])

      assert position_error(sol) < 1.0e-2
    end

    test "omitting :huber is byte-identical to huber: false (whole Solution)", ctx do
      assert {:ok, a} = Positioning.solve(ctx.sp3, ctx.clean_obs, @epoch, @solve_opts)

      assert {:ok, b} =
               Positioning.solve(ctx.sp3, ctx.clean_obs, @epoch, @solve_opts ++ [huber: false])

      # The additive-off guarantee covers the ENTIRE decoded solution, not just
      # the position: clock(s), DOP, residuals, used/rejected sets, and metadata
      # must match exactly. The off path carries no :huber metadata key at all
      # (it is surfaced only when the reweighting actually runs), so both solves
      # produce byte-identical structs.
      assert a == b
      refute Map.has_key?(a.metadata, :huber)
    end

    test "huber: true surfaces :huber metadata (outer_iterations + final_scale_m)", ctx do
      assert {:ok, sol} =
               Positioning.solve(ctx.sp3, ctx.clean_obs, @epoch, @solve_opts ++ [huber: true])

      assert %{outer_iterations: outer, final_scale_m: scale} = sol.metadata.huber
      assert is_integer(outer) and outer >= 0
      assert is_float(scale) and scale > 0.0
    end

    test "robust FDE requires an explicit noise model", ctx do
      assert Positioning.solve(ctx.sp3, ctx.clean_obs, @epoch, @solve_opts ++ [robust: true]) ==
               {:error, {:robust_requires_noise_model, :no_weights}}
    end

    test "robust FDE succeeds with explicit weights and surfaces FDE metadata", ctx do
      weights = Map.new(ctx.clean_obs, fn {sat, _pr} -> {sat, 1.0 / 25.0} end)

      assert {:ok, sol} =
               Positioning.solve(
                 ctx.sp3,
                 ctx.clean_obs,
                 @epoch,
                 @solve_opts ++ [robust: true, weights: weights]
               )

      assert position_error(sol) < 1.0e-2
      assert %{excluded: excluded, iterations: iterations, raim: raim} = sol.metadata.fde
      assert excluded == []
      assert iterations == 0
      assert raim.fault_detected? == false
    end

    test "malformed :huber options return tagged errors, never raise", ctx do
      base = @solve_opts ++ [huber: true]

      assert Positioning.solve(ctx.sp3, ctx.clean_obs, @epoch, @solve_opts ++ [huber: :yes]) ==
               {:error, {:invalid_option, :huber}}

      assert Positioning.solve(ctx.sp3, ctx.clean_obs, @epoch, base ++ [huber_k: :bad]) ==
               {:error, {:invalid_option, :huber_k}}

      assert Positioning.solve(ctx.sp3, ctx.clean_obs, @epoch, base ++ [huber_sigma: 0.0]) ==
               {:error, {:invalid_option, :huber_sigma}}

      assert Positioning.solve(ctx.sp3, ctx.clean_obs, @epoch, base ++ [huber_max_iter: 5.0]) ==
               {:error, {:invalid_option, :huber_max_iter}}
    end

    test "an out-of-range :huber_max_iter is rejected (DoS cap), never raises", ctx do
      base = @solve_opts ++ [huber: true]

      # The value becomes the crate outer-loop count; an unbounded value is a
      # denial-of-service knob, so reject above the cap rather than honor it.
      assert Positioning.solve(
               ctx.sp3,
               ctx.clean_obs,
               @epoch,
               base ++ [huber_max_iter: 1_000_000]
             ) ==
               {:error, {:invalid_option, :huber_max_iter}}
    end

    test "QC.fde/4 refuses huber: true rather than forwarding it into re-solves", ctx do
      assert QC.fde(ctx.sp3, ctx.clean_obs, @epoch, huber: true) ==
               {:error, {:incompatible_options, [:robust, :huber]}}
    end
  end

  describe "raim_fde_design/2 (standalone linearized range FDE)" do
    # One-state weighted least squares over five unit-design measurements: four
    # consistent residuals and one gross outlier the exclusion loop must remove.
    @clean_rows [
      %{id: "m0", residual_m: 0.0, design_row: [1.0], weight: 1.0},
      %{id: "m1", residual_m: 0.0, design_row: [1.0], weight: 1.0},
      %{id: "m2", residual_m: 0.0, design_row: [1.0], weight: 1.0},
      %{id: "m3", residual_m: 0.0, design_row: [1.0], weight: 1.0}
    ]

    test "a consistent set passes the global chi-square test with no exclusions" do
      assert {:ok, result} = QC.raim_fde_design(@clean_rows, p_fa: 0.001)

      assert result.excluded == []
      assert result.iterations == 0
      refute result.global_test.fault_detected
      assert result.global_test.testable
      assert_in_delta hd(result.state_correction), 0.0, 1.0e-9
    end

    test "excludes a single gross outlier and re-passes the test" do
      rows = @clean_rows ++ [%{id: "m4", residual_m: 50.0, design_row: [1.0], weight: 1.0}]

      assert {:ok, result} = QC.raim_fde_design(rows, p_fa: 0.001)

      assert result.excluded == ["m4"]
      assert result.iterations == 1
      refute result.global_test.fault_detected
      assert_in_delta hd(result.state_correction), 0.0, 1.0e-9

      outlier = Enum.find(result.diagnostics, &(&1.id == "m4"))
      assert outlier.excluded
      assert abs(outlier.post_fit_residual_m) > 1.0

      assert {:ok, uncapped} =
               QC.raim_fde_design(rows, p_fa: 0.001, max_exclusion_rms_m: :infinity)

      assert uncapped.excluded == ["m4"]

      assert {:ok, budgeted} = QC.raim_fde_design(rows, p_fa: 0.001, max_exclusions: 0)
      assert budgeted.excluded == []
      assert budgeted.iterations == 0
      assert budgeted.global_test.fault_detected
    end

    test "a rank-deficient design is reported as an error" do
      rows = [
        %{id: "m0", residual_m: 0.0, design_row: [0.0], weight: 1.0},
        %{id: "m1", residual_m: 0.0, design_row: [0.0], weight: 1.0}
      ]

      assert {:error, %QC.QualityError{kind: :singular_geometry} = error} =
               QC.raim_fde_design(rows, p_fa: 0.001)

      assert error.kind == :singular_geometry
      assert error.message == "singular or rank-deficient geometry"
    end
  end
end
