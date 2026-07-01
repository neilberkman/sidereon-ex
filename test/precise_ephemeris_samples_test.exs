defmodule Sidereon.GNSS.PreciseEphemerisSamplesTest do
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.{Observables, PreciseEphemeris, PreciseEphemerisSample, SP3}

  # Real IGS final product (the same fixture the core parity tests use). On a
  # real product the km -> meters map is not injective, so a meters-carrying
  # sample reconstructs to the correctly-rounded km, within <= 1 ULP of the fit
  # node. The resulting round-trip divergence is bounded well below a micron.
  @sp3_path Path.join(__DIR__, "fixtures/sp3/GRG0MGXFIN_20201760000_01D_15M_ORB.SP3")

  # Documented round-trip tolerance: sub-micron position/range, from the
  # SI-vs-native reconstruction bound described in the core module docs.
  @position_tol_m 1.0e-6
  @range_tol_m 1.0e-6
  @clock_tol_s 1.0e-15
  # transmit_time is seconds since J2000 (~6.4e8 for 2020), so its float
  # resolution near that magnitude dominates any sub-micron range difference.
  @transmit_tol_s 1.0e-6

  # Two static receivers to exercise the geometry from different look angles.
  @receivers [
    {4_027_894.0, 307_046.0, 4_919_474.0},
    {1_130_000.0, -4_830_000.0, 3_994_000.0}
  ]

  defp gps_sample(prn, j2000_s, position, clock_s, clock_event \\ false) do
    %PreciseEphemerisSample{
      sat: "G" <> String.pad_leading(Integer.to_string(prn), 2, "0"),
      epoch: %{time_scale: "GPST", jd_whole: 2_451_545.0, jd_fraction: j2000_s / 86_400.0},
      position_ecef_m: position,
      clock_s: clock_s,
      clock_event: clock_event
    }
  end

  describe "SP3.precise_ephemeris_samples/1" do
    test "extracts one sample per real position record" do
      {:ok, sp3} = SP3.parse(File.read!(@sp3_path))
      samples = SP3.precise_ephemeris_samples(sp3)

      assert is_list(samples)
      refute Enum.empty?(samples)
      assert Enum.all?(samples, &match?(%PreciseEphemerisSample{}, &1))

      sample = hd(samples)
      assert is_binary(sample.sat)
      assert %{time_scale: "GPST", jd_whole: jw, jd_fraction: jf} = sample.epoch
      assert is_float(jw) and is_float(jf)
      assert {x, y, z} = sample.position_ecef_m
      assert is_float(x) and is_float(y) and is_float(z)
      assert is_nil(sample.clock_s) or is_float(sample.clock_s)
      assert is_boolean(sample.clock_event)
    end
  end

  describe "PreciseEphemeris.from_samples/1 validation" do
    test "empty sample set" do
      assert {:error, :empty} = PreciseEphemeris.from_samples([])
    end

    test "single-sample satellite" do
      samples = [gps_sample(21, 0.0, {2.0e7, 1.4e7, 2.1e7}, 1.0e-6)]
      assert {:error, :single_sample_satellite} = PreciseEphemeris.from_samples(samples)
    end

    test "non-monotonic epochs" do
      samples = [
        gps_sample(21, 900.0, {1.0e7, 2.0e7, 3.0e7}, nil),
        gps_sample(21, 900.0, {1.0e7, 2.0e7, 3.0e7}, nil)
      ]

      assert {:error, :non_monotonic} = PreciseEphemeris.from_samples(samples)
    end

    test "mixed time scales" do
      samples = [
        gps_sample(21, 0.0, {1.0e7, 2.0e7, 3.0e7}, nil),
        %{
          gps_sample(21, 900.0, {1.0e7, 2.0e7, 3.0e7}, nil)
          | epoch: %{time_scale: "UTC", jd_whole: 2_451_545.0, jd_fraction: 900.0 / 86_400.0}
        }
      ]

      assert {:error, :mixed_timescale} = PreciseEphemeris.from_samples(samples)
    end

    test "malformed satellite token is returned without raising" do
      samples = [
        %{gps_sample(21, 0.0, {1.0e7, 2.0e7, 3.0e7}, nil) | sat: "not-a-sat"},
        gps_sample(21, 900.0, {1.0e7, 2.0e7, 3.0e7}, nil)
      ]

      assert {:error, {:bad_sat_id, _}} = PreciseEphemeris.from_samples(samples)
    end
  end

  describe "Observables.predict_ranges/3 parity" do
    setup do
      {:ok, sp3} = SP3.parse(File.read!(@sp3_path))
      {:ok, source} = PreciseEphemeris.from_samples(SP3.precise_ephemeris_samples(sp3))
      sat = hd(SP3.satellite_ids(sp3))
      epochs = SP3.epochs_j2000_seconds(sp3)

      # Interior query epochs: midpoints of a handful of node intervals well
      # inside coverage (so light-time back-off stays in range).
      queries =
        epochs
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.slice(4, 8)
        |> Enum.map(fn [a, b] -> 0.5 * (a + b) end)

      {:ok, sp3: sp3, source: source, sat: sat, queries: queries}
    end

    test "sample source matches the SP3-parsed source within round-trip tolerance",
         %{sp3: sp3, source: source, sat: sat, queries: queries} do
      requests = for q <- queries, rx <- @receivers, do: {sat, rx, q}

      assert {:ok, sp3_rows} = Observables.predict_ranges(sp3, requests)
      assert {:ok, sample_rows} = Observables.predict_ranges(source, requests)
      assert length(sp3_rows) == length(requests)
      assert length(sample_rows) == length(requests)

      Enum.zip(sp3_rows, sample_rows)
      |> Enum.each(fn {a, b} ->
        assert_in_delta a.geometric_range_m, b.geometric_range_m, @range_tol_m
        assert_in_delta a.transmit_time_j2000_s, b.transmit_time_j2000_s, @transmit_tol_s

        {ax, ay, az} = a.sat_pos_ecef_m
        {bx, by, bz} = b.sat_pos_ecef_m
        assert_in_delta ax, bx, @position_tol_m
        assert_in_delta ay, by, @position_tol_m
        assert_in_delta az, bz, @position_tol_m

        case {a.sat_clock_s, b.sat_clock_s} do
          {nil, nil} -> :ok
          {ca, cb} -> assert_in_delta ca, cb, @clock_tol_s
        end
      end)
    end

    test "batch result equals per-request results", %{source: source, sat: sat, queries: queries} do
      requests = for q <- queries, rx <- @receivers, do: {sat, rx, q}

      assert {:ok, batch} = Observables.predict_ranges(source, requests)

      per_request =
        Enum.map(requests, fn request ->
          assert {:ok, [row]} = Observables.predict_ranges(source, [request])
          row
        end)

      assert batch == per_request
    end

    test "unknown satellite aborts the batch with an error", %{source: source, queries: queries} do
      request = {"G99", hd(@receivers), hd(queries)}
      assert {:error, _reason} = Observables.predict_ranges(source, [request])
    end

    test "malformed request is reported without raising", %{source: source} do
      assert {:error, :invalid_receiver} = Observables.predict_ranges(source, [{"G01", :bad, 0.0}])
      assert {:error, :invalid_request} = Observables.predict_ranges(source, [:not_a_request])
    end
  end
end
