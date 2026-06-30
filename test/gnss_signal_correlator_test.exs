defmodule Sidereon.GNSS.Signal.CorrelatorTest do
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.Signal.Correlator

  @fs 2.046e6
  @t 1.0e-3

  # Build a clean complex-baseband record from a PRN's sampled C/A replica at a
  # known code phase, with a carrier exp(+j 2*pi*f n/fs) applied so that the
  # acquisition Doppler wipe-off (exp(-j ...)) recovers it.
  defp clean_signal(prn, code_phase_chips, doppler_hz) do
    {:ok, code} =
      Correlator.replica(prn,
        sample_rate_hz: @fs,
        integration_time_s: @t,
        code_phase_chips: code_phase_chips
      )

    w = 2.0 * :math.pi() * doppler_hz / @fs

    code
    |> Enum.with_index()
    |> Enum.map(fn {c, n} ->
      theta = w * n
      {c * :math.cos(theta), c * :math.sin(theta)}
    end)
  end

  # Standard-normal sample via Box-Muller from the seeded :rand stream.
  defp gaussian do
    u1 = :rand.uniform()
    u2 = :rand.uniform()
    :math.sqrt(-2.0 * :math.log(u1)) * :math.cos(2.0 * :math.pi() * u2)
  end

  defp add_noise(signal, sigma) do
    Enum.map(signal, fn {i, q} -> {i + sigma * gaussian(), q + sigma * gaussian()} end)
  end

  describe "replica/2" do
    test "samples the bipolar C/A code at the requested rate and phase" do
      {:ok, s} = Correlator.replica(1, num_samples: 4, sample_rate_hz: 1.023e6)
      # 1 sample/chip, phase 0: first four chips of PRN 1.
      assert s == [-1, -1, 1, 1]
      assert Enum.all?(s, &(&1 in [-1, 1]))
    end

    test "propagates the unsupported-PRN error from CA" do
      assert Correlator.replica(33, num_samples: 8) == {:error, {:unsupported_prn, 33}}
    end
  end

  describe "acquire/3 peak localization (clean signal, no noise)" do
    test "recovers injected code phase and Doppler within one grid bin, high metric" do
      injected_phase = 511.0
      injected_doppler = 1000.0
      signal = clean_signal(5, injected_phase, injected_doppler)

      {:ok, res} = Correlator.acquire(signal, 5, sample_rate_hz: @fs)

      samples_per_chip = res.grid.samples_per_chip
      one_phase_bin_chips = 1.0 / samples_per_chip

      assert abs(res.code_phase_chips - injected_phase) <= one_phase_bin_chips + 1.0e-9
      assert abs(res.doppler_hz - injected_doppler) <= res.grid.doppler_step_hz + 1.0e-9
      # Clean signal: metric is order-of-samples large, far above any noise floor.
      assert res.metric > 100.0
      assert res.peak_metric == res.metric
    end
  end

  describe "acquire/3 cross-PRN rejection" do
    test "low metric when acquiring a PRN against a different PRN's signal" do
      # Signal built ONLY from PRN 10; try to acquire PRN 5.
      signal = clean_signal(10, 200.0, 1000.0)
      {:ok, res} = Correlator.acquire(signal, 5, sample_rate_hz: @fs)

      # Gold-code cross-correlation floor: no clear detection.
      assert res.metric < 30.0

      # And it is far below the matched-PRN metric on the same record.
      {:ok, matched} = Correlator.acquire(signal, 10, sample_rate_hz: @fs)
      assert matched.metric > 100.0
      assert matched.metric > 20.0 * res.metric
    end
  end

  describe "coherent_loss/2 and coherent_loss_db/2 vs sinc^2 theory" do
    test "equals 1 at zero frequency error" do
      assert Correlator.coherent_loss(0.0, @t) == 1.0
      assert Correlator.coherent_loss(0.0, 5.0e-3) == 1.0
    end

    test "first null at f = 1/T" do
      assert_in_delta Correlator.coherent_loss(1.0 / @t, @t), 0.0, 1.0e-9
      assert_in_delta Correlator.coherent_loss(1.0 / 2.0e-3, 2.0e-3), 0.0, 1.0e-9
    end

    test "matches the closed form sinc^2(pi f T) mid-band" do
      for {f, t} <- [{250.0, 1.0e-3}, {500.0, 1.0e-3}, {300.0, 2.0e-3}, {123.0, 4.0e-3}] do
        x = :math.pi() * f * t
        expected = :math.pow(:math.sin(x) / x, 2)
        assert_in_delta Correlator.coherent_loss(f, t), expected, 1.0e-12
      end
    end

    test "coherent_loss_db is 10*log10 of the linear loss" do
      for {f, t} <- [{250.0, 1.0e-3}, {500.0, 1.0e-3}, {123.0, 4.0e-3}] do
        loss = Correlator.coherent_loss(f, t)
        assert_in_delta Correlator.coherent_loss_db(f, t), 10.0 * :math.log10(loss), 1.0e-12
      end
    end
  end

  describe "end-to-end correlation amplitude vs residual Doppler" do
    test "measured envelope follows sqrt(coherent_loss) = |sinc(pi f T)|" do
      {:ok, base} = Correlator.replica(5, sample_rate_hz: @fs, integration_time_s: @t)
      record = Enum.map(base, fn c -> {c * 1.0, 0.0} end)

      {:ok, r0} = Correlator.correlate(record, 5, sample_rate_hz: @fs, doppler_hz: 0.0)
      p0 = r0.power

      for f <- [0.0, 250.0, 500.0, 750.0] do
        {:ok, r} = Correlator.correlate(record, 5, sample_rate_hz: @fs, doppler_hz: f)
        measured = :math.sqrt(r.power / p0)
        theory = :math.sqrt(Correlator.coherent_loss(f, @t))
        # Tight: carrier wipe-off dominates; the matched code is exact.
        assert_in_delta measured, theory, 0.02
      end
    end
  end

  describe "noisy detection (deterministic, seeded)" do
    test "detects at high C/N0 and metric collapses at low C/N0" do
      :rand.seed(:exsss, {1, 2, 3})

      clean = clean_signal(5, 511.0, 1000.0)

      # Per-sample signal amplitude is 1. Low sigma -> high SNR; high sigma -> low SNR.
      high_snr = add_noise(clean, 1.0)
      low_snr = add_noise(clean, 30.0)

      {:ok, hi} = Correlator.acquire(high_snr, 5, sample_rate_hz: @fs)
      {:ok, lo} = Correlator.acquire(low_snr, 5, sample_rate_hz: @fs)

      # High SNR: clear detection at the injected cell.
      assert hi.metric > 100.0
      assert abs(hi.code_phase_chips - 511.0) <= 1.0
      assert abs(hi.doppler_hz - 1000.0) <= hi.grid.doppler_step_hz + 1.0e-9

      # Low SNR: metric collapses toward the noise floor.
      assert lo.metric < 30.0
      assert hi.metric > 20.0 * lo.metric
    end
  end

  describe "snr_post_db/2" do
    test "equals C/N0 + 10*log10(T) (predetection SNR relation)" do
      assert_in_delta Correlator.snr_post_db(40.0, 1.0e-3), 10.0, 1.0e-9
      assert_in_delta Correlator.snr_post_db(35.0, 2.0e-2), 35.0 - 16.9897, 1.0e-3
    end
  end

  describe "degenerate inputs and errors (no raise)" do
    test "empty sample vector is a tagged error" do
      assert Correlator.acquire([], 5, sample_rate_hz: @fs) == {:error, :empty_samples}
      assert Correlator.correlate([], 5) == {:error, :empty_samples}
    end

    test "record shorter than one code period is too_short" do
      short = List.duplicate({1.0, 0.0}, 100)
      assert Correlator.acquire(short, 5, sample_rate_hz: @fs) == {:error, :too_short}
    end

    test "unsupported PRN propagates from CA" do
      signal = clean_signal(5, 0.0, 0.0)

      assert Correlator.acquire(signal, 33, sample_rate_hz: @fs) ==
               {:error, {:unsupported_prn, 33}}

      assert Correlator.correlate(signal, 33) == {:error, {:unsupported_prn, 33}}
    end
  end
end
