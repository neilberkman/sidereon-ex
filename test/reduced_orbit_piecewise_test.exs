defmodule Sidereon.GNSS.ReducedOrbit.PiecewiseTest do
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.ReducedOrbit
  alias Sidereon.GNSS.ReducedOrbit.Piecewise
  alias Sidereon.GNSS.SP3

  @sp3_path Path.join(__DIR__, "fixtures/sp3/GRG0MGXFIN_20201760000_01D_15M_ORB.SP3")
  @sat "G21"
  @t0 ~N[2020-06-24 00:00:00]
  @t1 ~N[2020-06-24 10:00:00]

  setup_all do
    sp3 = SP3.load!(@sp3_path)
    samples = samples(sp3, @sat, @t0, 0..40, 900)
    {:ok, sp3: sp3, samples: samples}
  end

  describe "fit/2" do
    test "fits contiguous segments from ECEF samples", %{samples: samples} do
      assert {:ok, pw} =
               Piecewise.fit(samples,
                 window: {@t0, @t1},
                 segment_s: 7200,
                 time_scale: "GPST",
                 model: :eccentric_secular
               )

      assert pw.model == "eccentric_secular"
      assert pw.time_scale == "GPST"
      assert pw.segment_s == 7200
      assert length(pw.segments) == 5
      assert Enum.all?(pw.segments, &(&1.model.fit.source == "samples"))
    end

    test "returns tagged errors for invalid fit inputs", %{samples: samples} do
      assert {:error, :invalid_window} =
               Piecewise.fit(samples, window: {@t1, @t0}, segment_s: 7200)

      assert {:error, :invalid_segment} =
               Piecewise.fit(samples, window: {@t0, @t1}, segment_s: 0)

      assert {:error, {:unsupported_model, :bad}} =
               Piecewise.fit(samples, window: {@t0, @t1}, segment_s: 7200, model: :bad)

      assert {:error, {:unsupported_time_scale, "NOPE"}} =
               Piecewise.fit(samples, window: {@t0, @t1}, segment_s: 7200, time_scale: "NOPE")
    end
  end

  describe "evaluation" do
    setup %{samples: samples} do
      {:ok, pw} =
        Piecewise.fit(samples,
          window: {@t0, @t1},
          segment_s: 7200,
          time_scale: "GPST",
          model: :eccentric_secular
        )

      {:ok, pw: pw}
    end

    test "select_segment/2 resolves boundary and interior epochs", %{pw: pw} do
      second = Enum.at(pw.segments, 1)
      assert {:ok, ^second} = Piecewise.select_segment(pw, second.t0)

      query = NaiveDateTime.add(second.t0, 1800, :second)
      assert {:ok, ^second} = Piecewise.select_segment(pw, query)

      assert {:error, :out_of_range} =
               Piecewise.select_segment(pw, NaiveDateTime.add(@t0, -1, :second))
    end

    test "position/3 delegates to the selected segment", %{pw: pw} do
      segment = Enum.at(pw.segments, 2)
      query = NaiveDateTime.add(segment.t0, 900, :second)

      assert {:ok, direct} = ReducedOrbit.position(segment.model, query)
      assert {:ok, via_piecewise} = Piecewise.position(pw, query)
      assert via_piecewise == direct
    end

    test "position_velocity/3 delegates to the selected segment", %{pw: pw} do
      segment = Enum.at(pw.segments, 3)
      query = NaiveDateTime.add(segment.t0, 900, :second)

      assert {:ok, direct} = ReducedOrbit.position_velocity(segment.model, query, frame: :gcrs)
      assert {:ok, via_piecewise} = Piecewise.position_velocity(pw, query, frame: :gcrs)
      assert via_piecewise == direct
    end

    test "drift/3 compares against provided truth samples", %{samples: samples, pw: pw} do
      assert {:ok, drift} = Piecewise.drift(pw, samples, threshold_m: 1.0e9)
      assert drift.requested == length(samples)
      assert drift.used == length(samples)
      assert drift.max_m < 2_000.0

      assert {:error, :invalid_threshold} = Piecewise.drift(pw, samples, threshold_m: -1.0)
    end

    test "out-of-range evaluation returns a tagged error", %{pw: pw} do
      after_span = NaiveDateTime.add(@t1, 1, :second)
      assert {:error, :out_of_range} = Piecewise.position(pw, after_span)
      assert {:error, :out_of_range} = Piecewise.position_velocity(pw, after_span)
    end
  end

  defp samples(sp3, sat, t0, range, cadence_s) do
    for k <- range do
      epoch = NaiveDateTime.add(t0, k * cadence_s, :second)
      {:ok, pos} = SP3.position(sp3, sat, epoch)
      {epoch, {pos.x_m, pos.y_m, pos.z_m}}
    end
  end
end
