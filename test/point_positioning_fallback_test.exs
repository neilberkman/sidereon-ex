defmodule Sidereon.GNSS.PositioningFallbackTest do
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.Broadcast
  alias Sidereon.GNSS.Positioning
  alias Sidereon.GNSS.Positioning.Solution
  alias Sidereon.GNSS.Positioning.SourcedSolution
  alias Sidereon.GNSS.SP3
  alias Sidereon.GNSS.Staleness.Policy
  alias Sidereon.GNSS.Staleness.StalenessMetadata

  # Precise GPS orbits for 2020-06-24 (DOY 176) and the matching known-truth SPP
  # trace (the same fixtures the SP3 SPP end-to-end test uses).
  @sp3_path Path.join(__DIR__, "fixtures/sp3/GRG0MGXFIN_20201760000_01D_15M_ORB.SP3")
  @trace_path Path.join(__DIR__, "fixtures/spp_trace_L2_tropo.json")
  @trace_epoch ~N[2020-06-24 12:00:00]

  # The broadcast SPP scenario from point_positioning_test: a RINEX NAV product
  # and GPS pseudoranges for a known receiver near ESBC at 2020-06-25 12:00 GPST.
  @nav_path Path.join(__DIR__, "fixtures/nav/ESBC00DNK_R_20201770000_01D_MN.rnx")
  @broadcast_epoch ~N[2020-06-25 12:00:00]
  @broadcast_truth %{x_m: 3_512_900.0, y_m: 780_500.0, z_m: 5_248_700.0}
  @broadcast_guess {3_513_900.0, 779_500.0, 5_249_700.0, 0.0}
  @broadcast_obs [
    {"G07", 24_602_022.181241553},
    {"G08", 23_676_569.520090435},
    {"G10", 23_359_996.74001386},
    {"G15", 24_308_689.12412482},
    {"G16", 20_729_337.624163955},
    {"G18", 21_218_848.782066472},
    {"G20", 21_331_195.197190672},
    {"G21", 20_769_683.82405165},
    {"G26", 22_031_046.45549123},
    {"G27", 21_170_243.258043874}
  ]

  setup_all do
    trace = @trace_path |> File.read!() |> Jason.decode!()
    inputs = trace["fixture"]["inputs"]
    final = trace["fixture"]["final_solution"]

    trace_obs =
      Enum.map(inputs["observations"], fn obs ->
        {obs["sat_id"], hex_to_float(obs["p_meas_m"])}
      end)

    {:ok,
     sp3: SP3.load!(@sp3_path),
     broadcast: Broadcast.load!(@nav_path),
     trace_obs: trace_obs,
     trace_alpha: inputs["klobuchar_alpha"] |> Enum.map(&hex_to_float/1) |> List.to_tuple(),
     trace_beta: inputs["klobuchar_beta"] |> Enum.map(&hex_to_float/1) |> List.to_tuple(),
     trace_pressure_hpa: hex_to_float(inputs["met"]["pressure_hpa"]),
     trace_temperature_k: hex_to_float(inputs["met"]["temperature_k"]),
     trace_relative_humidity: hex_to_float(inputs["met"]["relative_humidity"]),
     trace_truth_x: Enum.map(final["truth_x"], &hex_to_float/1)}
  end

  defp trace_opts(ctx) do
    [
      ionosphere: true,
      troposphere: true,
      klobuchar_alpha: ctx.trace_alpha,
      klobuchar_beta: ctx.trace_beta,
      pressure_hpa: ctx.trace_pressure_hpa,
      temperature_k: ctx.trace_temperature_k,
      relative_humidity: ctx.trace_relative_humidity,
      initial_guess: {4_500_000.0, 500_000.0, 4_500_000.0, 0.0}
    ]
  end

  describe "solve_broadcast/4" do
    test "is the broadcast-only solve, bit-for-bit identical to solve/4", ctx do
      assert {:ok, %Solution{} = via_named} =
               Positioning.solve_broadcast(ctx.broadcast, @broadcast_obs, @broadcast_epoch,
                 initial_guess: @broadcast_guess
               )

      assert {:ok, %Solution{} = via_generic} =
               Positioning.solve(ctx.broadcast, @broadcast_obs, @broadcast_epoch,
                 initial_guess: @broadcast_guess
               )

      assert via_named == via_generic
      assert_in_delta via_named.position.x_m, @broadcast_truth.x_m, 1.0e-2
    end
  end

  describe "solve_with_fallback/5 precise-exact" do
    test "uses the precise product, reports exact source, and matches solve/4 bit-for-bit", ctx do
      opts = trace_opts(ctx)

      assert {:ok, %SourcedSolution{solution: %Solution{} = solution, source: source}} =
               Positioning.solve_with_fallback(
                 [ctx.sp3],
                 ctx.broadcast,
                 ctx.trace_obs,
                 @trace_epoch,
                 opts
               )

      # A precise product covers the epoch: source is precise-exact, zero staleness.
      assert {:precise, %StalenessMetadata{kind: :exact, staleness_s: +0.0}} = source

      # The fallback precise path is the crate's plain solve on that SP3, so the
      # solution is bit-for-bit the direct solve.
      assert {:ok, %Solution{} = direct} =
               Positioning.solve(ctx.sp3, ctx.trace_obs, @trace_epoch, opts)

      assert solution == direct

      # And it recovers the synthesized truth.
      [tx, ty, tz, _tb] = ctx.trace_truth_x
      assert_in_delta solution.position.x_m, tx, 1.0e-3
      assert_in_delta solution.position.y_m, ty, 1.0e-3
      assert_in_delta solution.position.z_m, tz, 1.0e-3
    end
  end

  describe "solve_with_fallback/5 broadcast fallback" do
    test "falls back to broadcast when no precise product is supplied", ctx do
      assert {:ok, %SourcedSolution{solution: solution, source: source}} =
               Positioning.solve_with_fallback(
                 [],
                 ctx.broadcast,
                 @broadcast_obs,
                 @broadcast_epoch,
                 initial_guess: @broadcast_guess
               )

      # No precise products at all: the precise selection is declined outright.
      assert {:broadcast, {:precise_unavailable, :empty_product_set}} = source

      # The broadcast fix recovers the known receiver.
      assert_in_delta solution.position.x_m, @broadcast_truth.x_m, 1.0e-2
      assert_in_delta solution.position.y_m, @broadcast_truth.y_m, 1.0e-2
      assert_in_delta solution.position.z_m, @broadcast_truth.z_m, 1.0e-2
    end

    test "falls back to broadcast when a stale precise product cannot serve the epoch", ctx do
      # The DOY-176 precise product is within the default 3-day cap of the DOY-177
      # epoch, so it is selected as nearest-prior, but it does not cover that epoch,
      # so the precise solve fails and broadcast produces the fix.
      assert {:ok, %SourcedSolution{solution: solution, source: source}} =
               Positioning.solve_with_fallback(
                 [ctx.sp3],
                 ctx.broadcast,
                 @broadcast_obs,
                 @broadcast_epoch,
                 initial_guess: @broadcast_guess
               )

      assert {:broadcast, {:precise_degraded_unusable, %StalenessMetadata{} = staleness, reason}} =
               source

      assert staleness.kind == :nearest_prior
      assert staleness.staleness_s > 0.0
      # The carried reason is the exact typed precise solve error that triggered
      # the fallback: the prior product reaches none of the epoch's satellites, so
      # the precise solve has zero usable observations against the 4-state minimum.
      assert reason == {:too_few_satellites, 0, 4}

      assert_in_delta solution.position.x_m, @broadcast_truth.x_m, 1.0e-2
      assert_in_delta solution.position.y_m, @broadcast_truth.y_m, 1.0e-2
    end

    test "falls back to broadcast when the precise product is beyond the staleness cap", ctx do
      assert {:ok, %SourcedSolution{solution: solution, source: source}} =
               Positioning.solve_with_fallback(
                 [ctx.sp3],
                 ctx.broadcast,
                 @broadcast_obs,
                 @broadcast_epoch,
                 initial_guess: @broadcast_guess,
                 policy: Policy.seconds(0.0)
               )

      assert {:broadcast, {:precise_unavailable, {:beyond_staleness_cap, info}}} = source
      assert info.staleness_s > 0.0
      assert info.max_staleness_s == 0.0

      assert_in_delta solution.position.x_m, @broadcast_truth.x_m, 1.0e-2
    end

    test "a failed broadcast solve surfaces a typed broadcast error", ctx do
      # Too few observations for the broadcast fallback: no precise product, so the
      # broadcast path is taken and its solve fails with a tagged reason.
      assert {:error, {:broadcast, {:too_few_satellites, _used, _required}}} =
               Positioning.solve_with_fallback(
                 [],
                 ctx.broadcast,
                 Enum.take(@broadcast_obs, 2),
                 @broadcast_epoch,
                 initial_guess: @broadcast_guess
               )
    end
  end

  # Bit-preserving hex -> float, matching the trace fixture's encoding.
  defp hex_to_float("0x" <> hex) do
    bytes = hex |> String.pad_leading(16, "0") |> Base.decode16!(case: :mixed)
    <<value::float-64>> = bytes
    value
  end
end
