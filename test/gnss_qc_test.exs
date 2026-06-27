defmodule Sidereon.GNSS.QCTest do
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.Observables
  alias Sidereon.GNSS.Positioning
  alias Sidereon.GNSS.QC
  alias Sidereon.GNSS.SP3

  @grg Path.join(__DIR__, "fixtures/sp3/GRG0MGXFIN_20201760000_01D_15M_ORB.SP3")

  # Known ground receiver in ITRF/ECEF metres (near IGS ESBC, Copenhagen), as
  # used by the observables/positioning tests.
  @rx {3_512_900.0, 780_500.0, 5_248_700.0}

  # Interior epoch of the SP3 span (2020-06-24 00:00 -> 23:45 GPST).
  @epoch ~N[2020-06-24 12:00:00]

  @c 299_792_458.0

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

    # Clean pseudorange set: P = geometric_range + c*(rx_bias - sat_clock).
    clean_obs =
      Enum.map(visible, fn {id, obs} ->
        {id, obs.geometric_range_m + @c * (@rx_bias_s - obs.sat_clock_s)}
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

    test "invalid (non-positive) elevation is a tagged error" do
      assert QC.pseudorange_variance(0.0) == {:error, :invalid_elevation}
      assert QC.pseudorange_variance(-5.0) == {:error, :invalid_elevation}
    end

    test "C/N0 model without a cn0 value is a tagged error" do
      assert QC.pseudorange_variance(30.0, model: :elevation_cn0) ==
               {:error, :missing_cn0}
    end

    test "sigmas/2 and weight_vector/2 are consistent and drop invalid entries" do
      entries = [{"G01", 90.0}, {"G02", 30.0}, {"G03", -1.0}]
      sigmas = QC.sigmas(entries)
      weights = QC.weight_vector(entries)

      refute Map.has_key?(sigmas, "G03")
      refute Map.has_key?(weights, "G03")

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

    test "rejects invalid probabilities and degrees of freedom at the public boundary" do
      assert_raise ArgumentError, fn -> QC.chi2_inv(0.0, 1) end
      assert_raise ArgumentError, fn -> QC.chi2_inv(1.0, 1) end
      assert_raise ArgumentError, fn -> QC.chi2_inv(0.95, 0) end
      assert_raise ArgumentError, fn -> QC.chi2_inv(0.95, 1.5) end
    end
  end

  describe "raim/2 on a clean SP3-synthesized set" do
    test "clean solve recovers truth and RAIM passes", ctx do
      assert {:ok, sol} = Positioning.solve(ctx.sp3, ctx.clean_obs, @epoch, @solve_opts)

      assert position_error(sol) < 1.0e-2

      result = QC.raim(sol)

      assert result.fault_detected? == false
      assert result.testable? == true
      # GPS-only: n_systems = 1, n_states = 4.
      assert result.dof == length(sol.used_sats) - 4
      assert result.test_statistic < result.threshold
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
      assert position_error(fde.solution) < 1.0e-2
    end
  end

  describe "fde/4 option validation" do
    test "malformed p_fa, weights, and max_iterations return tagged errors", ctx do
      assert QC.fde(ctx.sp3, ctx.clean_obs, @epoch, @solve_opts ++ [p_fa: 0.0]) ==
               {:error, {:invalid_option, :p_fa}}

      assert QC.fde(ctx.sp3, ctx.clean_obs, @epoch, @solve_opts ++ [p_fa: 1.0e-20]) ==
               {:error, {:invalid_option, :p_fa}}

      assert QC.fde(ctx.sp3, ctx.clean_obs, @epoch, @solve_opts ++ [weights: :bad]) ==
               {:error, {:invalid_option, :weights}}

      assert QC.fde(ctx.sp3, ctx.clean_obs, @epoch, @solve_opts ++ [weights: %{"G01" => -1.0}]) ==
               {:error, {:invalid_option, :weights}}

      assert QC.fde(ctx.sp3, ctx.clean_obs, @epoch, @solve_opts ++ [max_iterations: :bad]) ==
               {:error, {:invalid_option, :max_iterations}}

      assert QC.fde(ctx.sp3, ctx.clean_obs, @epoch, @solve_opts ++ [max_iterations: -1]) ==
               {:error, {:invalid_option, :max_iterations}}
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

  describe "solve/4 :robust contract (defect 2)" do
    test "robust:true with no noise model and no escape hatch refuses before solving", ctx do
      assert Positioning.solve(ctx.sp3, ctx.clean_obs, @epoch, @solve_opts ++ [robust: true]) ==
               {:error, {:robust_requires_noise_model, :no_weights}}
    end

    test "robust:true with an empty or partial weights map refuses (no unit-weight bypass)",
         ctx do
      # An empty map must not silently fall back to unit weight per satellite.
      assert Positioning.solve(
               ctx.sp3,
               ctx.clean_obs,
               @epoch,
               @solve_opts ++ [robust: true, weights: %{}]
             ) == {:error, {:robust_requires_noise_model, :incomplete_weights}}

      # A map missing some observed satellites is equally incomplete.
      {one_sat, _pr} = hd(ctx.clean_obs)
      partial = %{one_sat => 1.0 / 25.0}

      assert Positioning.solve(
               ctx.sp3,
               ctx.clean_obs,
               @epoch,
               @solve_opts ++ [robust: true, weights: partial]
             ) == {:error, {:robust_requires_noise_model, :incomplete_weights}}
    end

    test "robust:true with a complete map plus an invalid extra key does not raise", ctx do
      # A weight map covering every observed satellite (positive) plus an extra
      # key for a non-observed satellite (here a non-positive one) must be
      # accepted by dropping the irrelevant extra, never raising from solve/4.
      weights =
        ctx.clean_obs
        |> Map.new(fn {sat, _pr} -> {sat, 1.0 / 25.0} end)
        |> Map.put("G99", -1.0)

      assert {:ok, sol} =
               Positioning.solve(
                 ctx.sp3,
                 ctx.clean_obs,
                 @epoch,
                 @solve_opts ++ [robust: true, weights: weights]
               )

      assert sol.metadata.fde == %{excluded: [], iterations: 0}
    end

    test "robust:true with an invalid observed weight (non-positive or absurd) is a tagged error, not a raise",
         ctx do
      # Non-positive observed weight.
      neg = Map.new(ctx.clean_obs, fn {sat, _pr} -> {sat, -1.0} end)

      assert Positioning.solve(
               ctx.sp3,
               ctx.clean_obs,
               @epoch,
               @solve_opts ++ [robust: true, weights: neg]
             ) ==
               {:error, {:invalid_option, :weights}}

      # Absurd magnitude that would overflow RAIM's r^2 * weight on BEAM.
      huge = Map.new(ctx.clean_obs, fn {sat, _pr} -> {sat, 1.0e308} end)

      assert Positioning.solve(
               ctx.sp3,
               ctx.clean_obs,
               @epoch,
               @solve_opts ++ [robust: true, weights: huge]
             ) ==
               {:error, {:invalid_option, :weights}}

      # Bad :p_fa is also a tagged error.
      good = Map.new(ctx.clean_obs, fn {sat, _pr} -> {sat, 1.0 / 25.0} end)

      assert Positioning.solve(
               ctx.sp3,
               ctx.clean_obs,
               @epoch,
               @solve_opts ++ [robust: true, weights: good, p_fa: 1.5]
             ) ==
               {:error, {:invalid_option, :p_fa}}
    end

    test "robust:true never raises from solve/4 on malformed options",
         ctx do
      weights = Map.new(ctx.clean_obs, fn {sat, _pr} -> {sat, 1.0 / 25.0} end)
      base = @solve_opts ++ [robust: true, weights: weights]

      # Sub-epsilon p_fa rounds 1.0 - p_fa to 1.0; refused, not raised.
      assert Positioning.solve(ctx.sp3, ctx.clean_obs, @epoch, base ++ [p_fa: 1.0e-20]) ==
               {:error, {:invalid_option, :p_fa}}

      # Non-boolean escape hatch is a tagged error, not a FunctionClauseError.
      assert Positioning.solve(
               ctx.sp3,
               ctx.clean_obs,
               @epoch,
               @solve_opts ++ [robust: true, unsafe_unit_weights: :yes]
             ) ==
               {:error, {:invalid_option, :unsafe_unit_weights}}

      # A leaked RAIM-only option must not reach RAIM arithmetic and raise.
      assert {:ok, _sol} =
               Positioning.solve(ctx.sp3, ctx.clean_obs, @epoch, base ++ [n_systems: :bad])

      assert Positioning.solve(ctx.sp3, ctx.clean_obs, @epoch, base ++ [max_iterations: :bad]) ==
               {:error, {:invalid_option, :max_iterations}}
    end

    test "robust and coarse_search are mutually exclusive; bad coarse_search is tagged", ctx do
      weights = Map.new(ctx.clean_obs, fn {sat, _pr} -> {sat, 1.0 / 25.0} end)

      assert Positioning.solve(
               ctx.sp3,
               ctx.clean_obs,
               @epoch,
               @solve_opts ++ [robust: true, weights: weights, coarse_search: 24]
             ) == {:error, {:incompatible_options, [:coarse_search, :robust]}}

      assert Positioning.solve(ctx.sp3, ctx.clean_obs, @epoch, @solve_opts ++ [coarse_search: 0]) ==
               {:error, {:invalid_option, :coarse_search}}
    end

    test "robust:true with :weights is admitted (a clean weighted set excludes nothing)", ctx do
      weights = Map.new(ctx.clean_obs, fn {sat, _pr} -> {sat, 1.0 / 25.0} end)

      assert {:ok, sol} =
               Positioning.solve(
                 ctx.sp3,
                 ctx.clean_obs,
                 @epoch,
                 @solve_opts ++ [robust: true, weights: weights]
               )

      assert sol.metadata.fde == %{excluded: [], iterations: 0}
      assert position_error(sol) < 1.0e-2
    end

    test "robust clean via :unsafe_unit_weights is a no-op bit-identical to the bare solve",
         ctx do
      assert {:ok, bare} = Positioning.solve(ctx.sp3, ctx.clean_obs, @epoch, @solve_opts)

      assert {:ok, robust} =
               Positioning.solve(
                 ctx.sp3,
                 ctx.clean_obs,
                 @epoch,
                 @solve_opts ++ [robust: true, unsafe_unit_weights: true]
               )

      # The escape hatch is the only route to unit-weight FDE; on a clean
      # synthetic set it excludes nothing and the position is bit-identical.
      assert robust.metadata.fde == %{excluded: [], iterations: 0}
      assert robust.position == bare.position
      assert robust.rx_clock_s == bare.rx_clock_s
    end

    test "robust isolates a labelled fault via the escape hatch and folds the ledger", ctx do
      biased_sat = elem(Enum.at(ctx.clean_obs, 4), 0)

      for bias <- [50.0, 100.0, 200.0, 500.0] do
        faulted =
          Enum.map(ctx.clean_obs, fn {sat, pr} ->
            if sat == biased_sat, do: {sat, pr + bias}, else: {sat, pr}
          end)

        assert {:ok, sol} =
                 Positioning.solve(
                   ctx.sp3,
                   faulted,
                   @epoch,
                   @solve_opts ++ [robust: true, unsafe_unit_weights: true]
                 ),
               "bias #{bias}"

        assert sol.metadata.fde.excluded == [{biased_sat, :raim_excluded}], "bias #{bias}"

        clean_err =
          (fn ->
             {:ok, clean_sol} = Positioning.solve(ctx.sp3, ctx.clean_obs, @epoch, @solve_opts)
             position_error(clean_sol)
           end).()

        assert position_error(sol) <= clean_err + 0.5, "bias #{bias}"
      end
    end

    test "robust propagates the {:fault_unresolved, T} refusal out of solve/4", ctx do
      biased_sat = elem(Enum.at(ctx.clean_obs, 4), 0)

      faulted =
        Enum.map(ctx.clean_obs, fn {sat, pr} ->
          if sat == biased_sat, do: {sat, pr + 500.0}, else: {sat, pr}
        end)

      assert {:error, {:fault_unresolved, statistic}} =
               Positioning.solve(
                 ctx.sp3,
                 faulted,
                 @epoch,
                 @solve_opts ++ [robust: true, unsafe_unit_weights: true, max_iterations: 0]
               )

      assert is_float(statistic) and statistic > 0.0
    end

    test "robust composes with the rank/plausibility gates (degenerate is still refused)", ctx do
      # max_pdop below the realized PDOP must refuse even under robust, proving
      # the post_process gates still apply to the cleaned re-solve.
      assert {:error, {:degenerate_geometry, _}} =
               Positioning.solve(
                 ctx.sp3,
                 ctx.clean_obs,
                 @epoch,
                 @solve_opts ++ [robust: true, unsafe_unit_weights: true, max_pdop: 0.1]
               )
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

    test "the loop refuses with {:fault_unresolved, T} at the cap, never a faulted fix", ctx do
      # max_iterations: 0 means no exclusion is permitted; RAIM still flags the
      # fix, so fde/4 must return the tagged refusal carrying the statistic.
      opts = Keyword.put(@solve_opts, :max_iterations, 0)

      assert {:error, {:fault_unresolved, statistic}} =
               QC.fde(ctx.sp3, ctx.faulted_obs, @epoch, opts)

      assert is_float(statistic) and statistic > 0.0

      # Sanity: that statistic is the RAIM statistic of the un-excluded faulted
      # solve (it exceeds the chi-square threshold).
      {:ok, faulted_sol} = Positioning.solve(ctx.sp3, ctx.faulted_obs, @epoch, @solve_opts)
      result = QC.raim(faulted_sol)
      assert result.fault_detected?
      assert_in_delta statistic, result.test_statistic, 1.0e-6
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
    test "an out-of-range p_fa raises ArgumentError, not an obscure math error", ctx do
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

    test "malformed :robust returns a tagged error, never raises", ctx do
      assert Positioning.solve(ctx.sp3, ctx.clean_obs, @epoch, @solve_opts ++ [robust: :yes]) ==
               {:error, {:invalid_option, :robust}}
    end

    test "robust and huber are mutually exclusive", ctx do
      weights = Map.new(ctx.clean_obs, fn {sat, _pr} -> {sat, 1.0 / 25.0} end)

      assert Positioning.solve(
               ctx.sp3,
               ctx.clean_obs,
               @epoch,
               @solve_opts ++ [robust: true, weights: weights, huber: true]
             ) == {:error, {:incompatible_options, [:robust, :huber]}}
    end

    test "QC.fde/4 refuses huber: true rather than forwarding it into re-solves", ctx do
      assert QC.fde(ctx.sp3, ctx.clean_obs, @epoch, huber: true) ==
               {:error, {:incompatible_options, [:robust, :huber]}}
    end
  end
end
