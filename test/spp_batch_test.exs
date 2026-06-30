defmodule Sidereon.GNSS.Positioning.BatchTest do
  @moduledoc """
  Batch SPP tests: many independent epochs solved against one shared SP3 product
  in a single call. The per-epoch result must equal the single-epoch `solve/4`
  result for the same inputs, and the parallel path must be byte-for-byte
  identical to the serial path (the core guarantees this).
  """
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.Positioning
  alias Sidereon.GNSS.Positioning.Solution
  alias Sidereon.GNSS.SP3

  @sp3_path Path.join(__DIR__, "fixtures/sp3/GRG0MGXFIN_20201760000_01D_15M_ORB.SP3")
  @trace_path Path.join(__DIR__, "fixtures/spp_trace_L2_tropo.json")
  @epoch ~N[2020-06-24 12:00:00]
  @initial_guess {4_500_000.0, 500_000.0, 4_500_000.0, 0.0}

  setup_all do
    trace = @trace_path |> File.read!() |> Jason.decode!()
    inputs = trace["fixture"]["inputs"]

    observations =
      Enum.map(inputs["observations"], fn obs ->
        {obs["sat_id"], hex_to_float(obs["p_meas_m"])}
      end)

    opts = [
      ionosphere: true,
      troposphere: true,
      klobuchar_alpha: inputs["klobuchar_alpha"] |> Enum.map(&hex_to_float/1) |> List.to_tuple(),
      klobuchar_beta: inputs["klobuchar_beta"] |> Enum.map(&hex_to_float/1) |> List.to_tuple(),
      pressure_hpa: hex_to_float(inputs["met"]["pressure_hpa"]),
      temperature_k: hex_to_float(inputs["met"]["temperature_k"]),
      relative_humidity: hex_to_float(inputs["met"]["relative_humidity"]),
      initial_guess: @initial_guess
    ]

    {:ok, sp3: SP3.load!(@sp3_path), observations: observations, opts: opts}
  end

  test "each batch element equals the single-epoch solve for the same inputs", ctx do
    {:ok, single} = Positioning.solve(ctx.sp3, ctx.observations, @epoch, ctx.opts)

    requests = [
      {ctx.observations, @epoch},
      {ctx.observations, @epoch}
    ]

    assert {:ok, [first, second]} = Positioning.solve_batch(ctx.sp3, requests, ctx.opts)

    assert {:ok, %Solution{} = sol1} = first
    assert {:ok, %Solution{} = sol2} = second

    assert sol1.position == single.position
    assert sol1.rx_clock_s == single.rx_clock_s
    assert sol1.residuals_m == single.residuals_m
    assert sol2.position == single.position
  end

  test "parallel and serial batch paths are byte-for-byte identical", ctx do
    requests = [
      {ctx.observations, @epoch},
      {ctx.observations, @epoch},
      {ctx.observations, @epoch}
    ]

    assert {:ok, parallel} = Positioning.solve_batch(ctx.sp3, requests, ctx.opts ++ [parallel: true])
    assert {:ok, serial} = Positioning.solve_batch(ctx.sp3, requests, ctx.opts ++ [parallel: false])

    assert parallel == serial
    assert length(parallel) == 3
  end

  test "per-epoch opts override the batch-wide options for that epoch only", ctx do
    requests = [
      {ctx.observations, @epoch},
      {ctx.observations, @epoch, [troposphere: false]}
    ]

    assert {:ok, [{:ok, with_tropo}, {:ok, without_tropo}]} =
             Positioning.solve_batch(ctx.sp3, requests, ctx.opts)

    assert with_tropo.metadata.troposphere_applied
    refute without_tropo.metadata.troposphere_applied
  end

  test "a per-epoch solve failure does not fail the whole batch", ctx do
    requests = [
      {ctx.observations, @epoch},
      # Too few satellites for a fix: this epoch errors while the other succeeds.
      {Enum.take(ctx.observations, 2), @epoch}
    ]

    assert {:ok, [{:ok, %Solution{}}, {:error, reason}]} =
             Positioning.solve_batch(ctx.sp3, requests, ctx.opts)

    assert match?({:too_few_satellites, _, _}, reason)
  end

  test "a batch-wide configuration error fails the whole call", ctx do
    requests = [{ctx.observations, @epoch}]

    assert {:error, {:invalid_option, :max_pdop}} =
             Positioning.solve_batch(ctx.sp3, requests, ctx.opts ++ [max_pdop: -1.0])

    assert {:error, {:invalid_option, :parallel}} =
             Positioning.solve_batch(ctx.sp3, requests, ctx.opts ++ [parallel: :yes])
  end

  # Decode an IEEE-754 double from its raw big-endian 8-byte hex string.
  defp hex_to_float("0x" <> hex) do
    bytes = hex |> String.pad_leading(16, "0") |> Base.decode16!(case: :mixed)
    <<value::float-64>> = bytes
    value
  end
end
