defmodule Sidereon.GNSSSignalAnalysisTest do
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.Signal.Analysis

  describe "closed-form signal analysis parity" do
    test "exposes modulation constructors and module-level helper names over core paths" do
      ref = Analysis.signal_reference_chip_rate_hz()
      bandwidth = Analysis.signal_betz_l1_receiver_bandwidth_hz()

      assert ref == 1_023_000.0
      assert bandwidth == 24_000_000.0

      assert {:ok, "BPSK(n)"} = Analysis.label(Analysis.bpsk1())
      assert {:ok, 1_023_000.0} = Analysis.code_rate_hz(Analysis.bpsk1())

      assert {:ok, boc_cosine_psd} = Analysis.signal_psd_hz(Analysis.boc_cosine(10, 5), 10.0 * ref)
      assert_close(boc_cosine_psd, 7.923455221297185e-8, 1.0e-20)

      assert {:ok, mboc_psd} = Analysis.signal_psd_hz(Analysis.mboc_6_1_1_over_11(), 5.5 * ref)
      assert_close(mboc_psd, 2.0149590862158405e-8, 1.0e-20)

      assert {:ok, tmboc_psd} = Analysis.signal_psd_hz(Analysis.tmboc_6_1_4_over_33(), 5.5 * ref)
      assert_close(tmboc_psd, 2.5774736132836937e-8, 1.0e-20)

      assert {:ok, [psd0, psd_half]} = Analysis.signal_psd(Analysis.bpsk1(), [0.0, 0.5 * ref])
      assert_close(psd0, 9.775171065493646e-7, 1.0e-18)
      assert_close(psd_half, 3.961727610648594e-7, 1.0e-18)

      assert {:ok, power} = Analysis.signal_power_in_band(Analysis.bpsk1(), bandwidth)
      assert_close(power, 0.9914781372217897, 1.0e-15)

      assert {:ok, fraction} = Analysis.signal_fraction_power_in_band(Analysis.bpsk1(), bandwidth)
      assert_close(fraction, 0.9914781372217897, 1.0e-15)

      assert {:ok, rms} = Analysis.signal_rms_bandwidth_hz(Analysis.bpsk1(), bandwidth)
      assert_close(rms, 1_127_563.4193815086, 1.0e-6)

      assert {:ok, ssc} =
               Analysis.signal_spectral_separation_coefficient_hz(
                 Analysis.bpsk1(),
                 Analysis.boc_sine(1, 1),
                 bandwidth
               )

      assert_close(ssc, 1.629171137084864e-7, 1.0e-18)

      assert {:ok, ssc_db} =
               Analysis.signal_spectral_separation_coefficient_db_hz(
                 Analysis.bpsk1(),
                 Analysis.boc_sine(1, 1),
                 bandwidth
               )

      assert_close(ssc_db, -67.88033292617351, 1.0e-12)

      assert {:ok, white} = Analysis.signal_white_noise_spectral_separation_hz(Analysis.bpsk1(), bandwidth)
      assert_close(white, 4.13115890509079e-8, 1.0e-20)
    end

    test "typed signal-analysis option structs marshal through NIF-backed metrics" do
      desired = Analysis.bpsk1()
      interference = Analysis.InterferenceTerm.new(Analysis.boc_sine(1, 1), 0.1)

      assert {:ok, cn0} =
               Analysis.signal_effective_cn0_degradation(desired, 45.0, 24_000_000.0, [
                 interference
               ])

      assert_close(cn0.effective_cn0_hz, 31_606.353395057544, 1.0e-9)
      assert_close(cn0.effective_cn0_db_hz, 44.99774391702884, 1.0e-12)
      assert_close(cn0.degradation_db, 0.00225608297115798, 1.0e-15)

      dll_options = Analysis.DllTrackingOptions.new(45.0, 1.0, 0.02, 0.1, 24_000_000.0)
      assert {:ok, jitter} = Analysis.signal_dll_thermal_noise_jitter(desired, dll_options, :coherent)
      assert_close(jitter.seconds, 1.0138114605038942e-9, 1.0e-21)
      assert_close(jitter.chips, 0.0010371291240954838, 1.0e-15)
      assert_close(jitter.meters, 0.3039330296930324, 1.0e-13)

      multipath_options = Analysis.MultipathOptions.new(0.5, 0.1, 24_000_000.0)
      assert {:ok, [point]} = Analysis.signal_multipath_error_envelope(desired, multipath_options, [0.1])
      assert_close(point.delay_chips, 0.1, 0.0)
      assert_close(point.in_phase_chips, 0.02359128345352953, 1.0e-15)
      assert_close(point.anti_phase_chips, -0.022509263589519688, 1.0e-15)
    end

    test "pins BPSK and BOC spectrum metrics to core values" do
      desired = Analysis.bpsk(1)
      interference = Analysis.boc_sine(1, 1)

      assert {:ok, [psd0, psd_half]} = Analysis.psd_hz(desired, [0.0, 511_500.0])
      assert_close(psd0, 9.775171065493646e-7, 1.0e-18)
      assert_close(psd_half, 3.961727610648594e-7, 1.0e-18)

      assert {:ok, fraction} = Analysis.fraction_power(desired, 24_000_000.0)
      assert_close(fraction, 0.9914781372217897, 1.0e-15)

      assert {:ok, rms} = Analysis.rms_bandwidth_hz(desired, 24_000_000.0)
      assert_close(rms, 1_127_563.4193815086, 1.0e-6)

      assert {:ok, ssc} = Analysis.ssc_hz(desired, interference, 24_000_000.0)
      assert_close(ssc, 1.629171137084864e-7, 1.0e-18)

      assert {:ok, ssc_db} = Analysis.ssc_db_hz(desired, interference, 24_000_000.0)
      assert_close(ssc_db, -67.88033292617351, 1.0e-12)
    end

    test "pins C/N0, DLL jitter, lower bound, and multipath envelopes" do
      desired = Analysis.bpsk(1)
      interference = Analysis.boc_sine(1, 1)

      assert {:ok, cn0} =
               Analysis.effective_cn0_degradation(desired, 45.0, 24_000_000.0, [
                 %{modulation: interference, power_ratio_to_carrier: 0.1}
               ])

      assert_close(cn0.effective_cn0_hz, 31_606.353395057544, 1.0e-9)
      assert_close(cn0.effective_cn0_db_hz, 44.99774391702884, 1.0e-12)
      assert_close(cn0.degradation_db, 0.00225608297115798, 1.0e-15)

      options = %{
        cn0_db_hz: 45.0,
        loop_bandwidth_hz: 1.0,
        integration_time_s: 0.02,
        correlator_spacing_chips: 0.1,
        receiver_bandwidth_hz: 24_000_000.0
      }

      assert {:ok, coherent} = Analysis.dll_jitter(desired, options, :coherent)
      assert_close(coherent.seconds, 1.0138114605038942e-9, 1.0e-21)
      assert_close(coherent.chips, 0.0010371291240954838, 1.0e-15)
      assert_close(coherent.meters, 0.3039330296930324, 1.0e-13)
      assert_close(coherent.squaring_loss, 1.0, 0.0)

      assert {:ok, non_coherent} = Analysis.dll_jitter(desired, options, :non_coherent)
      assert_close(non_coherent.seconds, 1.0146519967621128e-9, 1.0e-21)
      assert_close(non_coherent.chips, 0.0010379889926876414, 1.0e-15)
      assert_close(non_coherent.meters, 0.30418501612392185, 1.0e-13)
      assert_close(non_coherent.squaring_loss, 1.001658858139089, 1.0e-15)

      assert {:ok, lower_bound} = Analysis.dll_lower_bound(desired, options)
      assert_close(lower_bound.seconds, 7.931497284817671e-10, 1.0e-21)
      assert_close(lower_bound.chips, 8.113921722368477e-4, 1.0e-15)
      assert_close(lower_bound.meters, 0.23778030666358158, 1.0e-13)

      assert {:ok, [zero, early, late]} =
               Analysis.multipath_envelope(
                 desired,
                 %{
                   multipath_to_direct_ratio: 0.5,
                   correlator_spacing_chips: 0.1,
                   receiver_bandwidth_hz: 24_000_000.0
                 },
                 [0.0, 0.1, 0.2]
               )

      assert zero.delay_chips == 0.0
      assert zero.in_phase_chips == 0.0
      assert zero.anti_phase_chips == 0.0
      assert zero.running_average_m == 0.0

      assert_close(early.delay_chips, 0.1, 0.0)
      assert_close(early.in_phase_chips, 0.02359128345352953, 1.0e-15)
      assert_close(early.anti_phase_chips, -0.022509263589519688, 1.0e-15)
      assert_close(early.running_average_m, 3.4567394202875596, 1.0e-12)

      assert_close(late.delay_chips, 0.2, 0.0)
      assert_close(late.in_phase_chips, 0.023020409303197396, 1.0e-15)
      assert_close(late.anti_phase_chips, -0.02279967312471342, 1.0e-15)
      assert_close(late.running_average_m, 5.143285141003984, 1.0e-12)
    end
  end

  defp assert_close(actual, expected, tolerance) do
    if tolerance == 0.0 do
      assert actual == expected
    else
      assert_in_delta actual, expected, tolerance
    end
  end
end
