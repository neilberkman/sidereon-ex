defmodule Sidereon.GNSS.RTCMTest do
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.RTCM

  # A real RTCM 3 frame carrying a 1006 station-coordinate message, produced by
  # the sidereon-core encoder (reference station 2003, ECEF 0.0001 m integers).
  @frame_1006 <<211, 0, 21, 62, 231, 211, 3, 2, 170, 60, 109, 24, 62, 70, 5, 255, 12, 2, 239, 43, 84, 132, 58, 152, 216,
                180, 135>>

  test "decode_messages decodes a 1006 station-coordinate frame" do
    assert {:ok, [{:station_coordinates, fields}]} = RTCM.decode_messages(@frame_1006)

    assert fields.message_number == 1006
    assert fields.reference_station_id == 2003
    assert fields.ecef_x == 11_446_021_400
    assert_in_delta fields.x_m, 1_144_602.14, 1.0e-6
    assert_in_delta fields.y_m, -741_513.65, 1.0e-6
    assert_in_delta fields.z_m, 1_260_252.89, 1.0e-6
    assert_in_delta fields.antenna_height_m, 1.5, 1.0e-9
    assert fields.gps_indicator
    assert fields.glonass_indicator
    refute fields.galileo_indicator
  end

  test "decode_frame returns the framed body and message number" do
    assert {:ok, %{message_number: 1006, frame_len: 27, body: body}} =
             RTCM.decode_frame(@frame_1006)

    assert is_binary(body)
    assert byte_size(body) == 21
    assert {:ok, 1006} = RTCM.message_number(body)
    assert {:ok, {:station_coordinates, fields}} = RTCM.decode_message(body)
    assert fields.reference_station_id == 2003
  end

  test "decode_messages skips a CRC-corrupted frame (forgiving stream)" do
    corrupted = :binary.replace(@frame_1006, <<62, 231>>, <<0, 0>>)
    assert {:ok, []} = RTCM.decode_messages(corrupted)
  end

  test "decode_messages on a buffer with no preamble yields no messages" do
    assert {:ok, []} = RTCM.decode_messages(<<0, 1, 2, 3, 4, 5>>)
  end

  test "decode_frame errors on a truncated buffer" do
    assert {:error, _reason} = RTCM.decode_frame(<<211, 0>>)
  end

  describe "encode_message/1 (from-scratch construction + encode)" do
    test "re-encodes a decoded 1006 station message to byte-identical bytes" do
      assert {:ok, [{:station_coordinates, fields}]} = RTCM.decode_messages(@frame_1006)
      assert {:ok, body} = RTCM.encode({:station_coordinates, fields})
      assert {:ok, 1006} = RTCM.message_number(body)
      assert {:ok, @frame_1006} == RTCM.encode_frame(body)
      assert {:ok, frame} = RTCM.encode_message({:station_coordinates, fields})
      assert frame == @frame_1006
    end

    test "round-trips a 1005 station message built from scratch" do
      fields = %{
        message_number: 1005,
        reference_station_id: 2003,
        itrf_realization_year: 0,
        gps_indicator: true,
        glonass_indicator: true,
        galileo_indicator: false,
        reference_station_indicator: false,
        ecef_x: 11_446_021_400,
        single_receiver_oscillator: false,
        reserved: false,
        ecef_y: -7_415_136_500,
        quarter_cycle_indicator: 0,
        ecef_z: 12_602_528_900,
        antenna_height: nil
      }

      assert_roundtrip(:station_coordinates, fields)
    end

    test "round-trips a 1033 antenna/receiver descriptor built from scratch" do
      fields = %{
        message_number: 1033,
        reference_station_id: 2003,
        antenna_descriptor: "TRM59800.00",
        antenna_setup_id: 0,
        antenna_serial_number: "SN-ANT-1",
        receiver_type: "SEPT POLARX5",
        receiver_firmware_version: "5.3.0",
        receiver_serial_number: "SN-RX-9"
      }

      assert_roundtrip(:antenna_descriptor, fields)
    end

    test "round-trips a 1019 GPS ephemeris built from scratch" do
      assert_roundtrip(:gps_ephemeris, gps_ephemeris_fields())
    end

    test "round-trips a 1020 GLONASS ephemeris built from scratch" do
      assert_roundtrip(:glonass_ephemeris, glonass_ephemeris_fields())
    end

    test "round-trips an MSM4 observation message built from scratch" do
      fields = msm_fields("msm4", 1074)
      assert {:ok, frame} = RTCM.encode_message({:msm, fields})
      assert {:ok, [{:msm, decoded}]} = RTCM.decode_messages(frame)

      assert decoded.message_number == 1074
      assert decoded.system == "G"
      assert decoded.kind == "msm4"
      assert decoded.header == fields.header
      assert decoded.satellites == fields.satellites
      assert decoded.signals == fields.signals
    end

    test "round-trips an MSM7 observation message built from scratch" do
      fields = msm_fields("msm7", 1077)
      assert {:ok, frame} = RTCM.encode_message({:msm, fields})
      assert {:ok, [{:msm, decoded}]} = RTCM.decode_messages(frame)

      assert decoded.message_number == 1077
      assert decoded.kind == "msm7"
      assert decoded.satellites == fields.satellites
      assert decoded.signals == fields.signals
    end

    test "an unsupported type is rejected" do
      assert {:error, _reason} = RTCM.encode_message({:unsupported, %{message_number: 9999}})
    end
  end

  defp assert_roundtrip(type, fields) do
    assert {:ok, frame} = RTCM.encode_message({type, fields})
    assert is_binary(frame)
    assert {:ok, [{^type, decoded}]} = RTCM.decode_messages(frame)

    Enum.each(fields, fn {key, value} ->
      assert Map.fetch!(decoded, key) == value, "field #{key} did not round-trip"
    end)

    decoded
  end

  defp gps_ephemeris_fields do
    %{
      satellite_id: 5,
      week_number: 100,
      sv_accuracy: 1,
      code_on_l2: 1,
      idot: 1,
      iode: 1,
      t_oc: 1,
      a_f2: 1,
      a_f1: 1,
      a_f0: 1,
      iodc: 1,
      c_rs: 1,
      delta_n: 1,
      m0: 1,
      c_uc: 1,
      eccentricity: 1,
      c_us: 1,
      sqrt_a: 1,
      t_oe: 1,
      c_ic: 1,
      omega0: 1,
      c_is: 1,
      i0: 1,
      c_rc: 1,
      omega: 1,
      omega_dot: 1,
      t_gd: 1,
      sv_health: 1,
      l2_p_data_flag: false,
      fit_interval: false
    }
  end

  defp glonass_ephemeris_fields do
    %{
      satellite_id: 5,
      frequency_channel: 1,
      almanac_health: true,
      almanac_health_availability: true,
      p1: 1,
      t_k: 1,
      b_n_msb: false,
      p2: false,
      t_b: 1,
      xn_dot: 1,
      xn: 1,
      xn_dot_dot: 1,
      yn_dot: 1,
      yn: 1,
      yn_dot_dot: 1,
      zn_dot: 1,
      zn: 1,
      zn_dot_dot: 1,
      p3: false,
      gamma_n: 1,
      m_p: 1,
      m_l_n_third: false,
      tau_n: 1,
      delta_tau_n: 1,
      e_n: 1,
      m_p4: false,
      m_f_t: 1,
      m_n_t: 1,
      m_m: 1,
      additional_data_available: false,
      n_a: 1,
      tau_c: 1,
      m_n4: 1,
      m_tau_gps: 1,
      m_l_n_fifth: false,
      reserved: 0
    }
  end

  defp msm_fields(kind, message_number) do
    # MSM7 carries the extended satellite info, the rough phase-range-rate, and
    # the fine phase-range-rate; MSM4 omits them (decode yields nil there).
    {extended_info, rough_rate, fine_rate} =
      case kind do
        "msm7" -> {2, 3, 4}
        _ -> {nil, nil, nil}
      end

    %{
      message_number: message_number,
      system: "G",
      kind: kind,
      header: %{
        reference_station_id: 2003,
        epoch_time: 100,
        multiple_message: false,
        iods: 0,
        reserved: 0,
        clock_steering: 0,
        external_clock: 0,
        divergence_free_smoothing: false,
        smoothing_interval: 0
      },
      satellites: [
        %{
          id: 5,
          rough_range_ms: 70,
          rough_range_mod1: 100,
          extended_info: extended_info,
          rough_phase_range_rate_m_s: rough_rate
        }
      ],
      signals: [
        %{
          satellite_id: 5,
          signal_id: 2,
          fine_pseudorange: 10,
          fine_phase_range: 20,
          lock_time_indicator: 5,
          half_cycle_ambiguity: false,
          cnr: 30,
          fine_phase_range_rate: fine_rate
        }
      ]
    }
  end
end
