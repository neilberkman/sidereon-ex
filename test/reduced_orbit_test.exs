defmodule Sidereon.GNSS.ReducedOrbitTest do
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.ReducedOrbit
  alias Sidereon.GNSS.SP3

  @sp3_path Path.join(__DIR__, "fixtures/sp3/GRG0MGXFIN_20201760000_01D_15M_ORB.SP3")
  @sat "E01"
  @gps "G21"
  @t0 ~N[2020-06-24 00:00:00]

  setup_all do
    sp3 = SP3.load!(@sp3_path)
    {:ok, sp3: sp3, samples: samples(sp3, @sat, @t0, 0..24, 900)}
  end

  describe "fit/2" do
    test "fits ECEF samples through the native model", %{samples: samples} do
      assert {:ok, model} = ReducedOrbit.fit(samples, time_scale: "GPST")
      assert model.model == "circular_secular"
      assert model.time_scale == "GPST"
      assert model.fit.source == "samples"
      assert model.fit.requested == length(samples)
      assert model.fit.n_samples == length(samples)
      assert model.fit.max_m < 10_000.0
      assert_in_delta model.a_m / 1000.0, 29_600.0, 100.0
    end

    test "supports the eccentric model", %{sp3: sp3} do
      samples = samples(sp3, @gps, @t0, 0..24, 900)

      assert {:ok, model} =
               ReducedOrbit.fit(samples, time_scale: "GPST", model: :eccentric_secular)

      assert model.model == "eccentric_secular"
      assert is_float(model.h)
      assert is_float(model.k)
      assert is_float(model.arg_perigee_rad)
      assert model.e > 0.01
    end

    test "returns tagged errors for invalid inputs" do
      assert {:error, {:too_few_samples, 3, 4}} =
               ReducedOrbit.fit(for(k <- 0..2, do: {NaiveDateTime.add(@t0, k, :second), {1, 2, 3}}))

      assert {:error, {:unsupported_source_frame, :gcrs}} =
               ReducedOrbit.fit([{@t0, {1.0, 2.0, 3.0}}], frame: :gcrs)

      assert {:error, {:unsupported_time_scale, "NOPE"}} =
               ReducedOrbit.fit([{@t0, {1.0, 2.0, 3.0}}], time_scale: "NOPE")

      assert {:error, {:unsupported_model, :bad}} =
               ReducedOrbit.fit([{@t0, {1.0, 2.0, 3.0}}], model: :bad)
    end
  end

  describe "evaluation" do
    setup %{samples: samples} do
      {:ok, model} = ReducedOrbit.fit(samples, time_scale: "GPST")
      {:ok, model: model}
    end

    test "position/3 evaluates the fitted model", %{sp3: sp3, model: model} do
      query = NaiveDateTime.add(@t0, 5400, :second)
      {:ok, truth} = SP3.position(sp3, @sat, query)
      assert {:ok, pos} = ReducedOrbit.position(model, query)

      assert distance(pos, truth) < 10_000.0
    end

    test "position_velocity/3 returns inertial speed", %{model: model} do
      query = NaiveDateTime.add(@t0, 5400, :second)
      assert {:ok, %{position: p, velocity: v}} = ReducedOrbit.position_velocity(model, query, frame: :gcrs)

      assert_in_delta radius(p), model.a_m, 1.0
      speed = :math.sqrt(v.vx_m_s ** 2 + v.vy_m_s ** 2 + v.vz_m_s ** 2)
      assert_in_delta speed, model.a_m * model.mean_motion_rad_s, 1.0
    end

    test "drift/3 compares against provided truth samples", %{samples: samples, model: model} do
      assert {:ok, drift} = ReducedOrbit.drift(model, samples, threshold_m: 100_000.0)
      assert drift.used == length(samples)
      assert drift.requested == length(samples)
      assert drift.max_m < 10_000.0
      assert drift.threshold_horizon == nil

      assert {:error, :invalid_threshold} = ReducedOrbit.drift(model, samples, threshold_m: -1.0)
    end
  end

  defp samples(sp3, sat, t0, range, cadence_s) do
    for k <- range do
      epoch = NaiveDateTime.add(t0, k * cadence_s, :second)
      {:ok, pos} = SP3.position(sp3, sat, epoch)
      {epoch, {pos.x_m, pos.y_m, pos.z_m}}
    end
  end

  defp distance(a, b) do
    :math.sqrt((a.x_m - b.x_m) ** 2 + (a.y_m - b.y_m) ** 2 + (a.z_m - b.z_m) ** 2)
  end

  defp radius(p), do: :math.sqrt(p.x_m ** 2 + p.y_m ** 2 + p.z_m ** 2)
end
