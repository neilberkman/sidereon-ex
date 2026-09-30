defmodule Sidereon.GNSS.RTCMTest do
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.RTCM

  # A real RTCM 3 frame carrying a 1006 station-coordinate message, produced by
  # the sidereon-core encoder (reference station 2003, ECEF 0.0001 m integers).
  @frame_1006 <<211, 0, 21, 62, 231, 211, 3, 2, 170, 60, 109, 24, 62, 70, 5, 255, 12, 2, 239, 43, 84, 132, 58, 152, 216,
                180, 135>>
  @frame_1046 <<211, 0, 63, 65, 96, 213, 232, 7, 107, 6, 201, 65, 224, 63, 254, 211, 255, 227, 57, 23, 243, 164, 144,
                233, 132, 210, 8, 155, 244, 244, 1, 16, 48, 176, 52, 58, 168, 19, 171, 93, 65, 239, 255, 183, 228, 79,
                232, 207, 255, 82, 119, 208, 176, 17, 162, 65, 99, 151, 255, 255, 252, 34, 128, 20, 7, 0, 128, 10, 142>>

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

  test "all network and transformation families construct from typed field maps" do
    empty_records = []

    messages = [
      {:network_correction_differences,
       %{
         message_number: 1015,
         network_id: 0,
         subnetwork_id: 0,
         epoch_time: 0,
         multiple_message: false,
         master_station_id: 0,
         auxiliary_station_id: 0,
         satellite_count: 0,
         satellites: empty_records,
         trailing_bits: []
       }},
      {:helmert_transformation,
       %{
         message_number: 1021,
         source_name: "",
         target_name: "",
         system_id: 0,
         utilized_messages: 0,
         plate_number: 0,
         computation_indicator: 0,
         height_indicator: 0,
         validity_latitude: 0,
         validity_longitude: 0,
         validity_extension_latitude: 0,
         validity_extension_longitude: 0,
         dx: 0,
         dy: 0,
         dz: 0,
         r1: 0,
         r2: 0,
         r3: 0,
         ds: 0,
         rotation_point: nil,
         add_as: 0,
         add_bs: 0,
         add_at: 0,
         add_bt: 0,
         horizontal_quality: 0,
         vertical_quality: 0,
         trailing_bits: []
       }},
      {:residual_grid,
       %{
         message_number: 1023,
         system_id: 0,
         horizontal_shift: false,
         vertical_shift: false,
         origin_1: 0,
         origin_2: 0,
         extension_1: 0,
         extension_2: 0,
         mean_offset_1: 0,
         mean_offset_2: 0,
         mean_height_offset: 0,
         residuals: List.duplicate(%{horizontal_1: 0, horizontal_2: 0, height: 0}, 16),
         horizontal_interpolation: 0,
         vertical_interpolation: 0,
         horizontal_quality: 0,
         vertical_quality: 0,
         mjd: 0,
         trailing_bits: []
       }},
      {:projection,
       %{
         message_number: 1025,
         system_id: 0,
         projection_type: 0,
         parameter_kind: "natural_origin",
         latitude: 0,
         longitude: 0,
         add_scale: 0,
         false_easting: 0,
         false_northing: 0,
         standard_parallel_1: nil,
         standard_parallel_2: nil,
         rectification: nil,
         azimuth: nil,
         rectified_to_skew: nil,
         easting: nil,
         northing: nil,
         trailing_bits: []
       }},
      {:network_residuals,
       %{
         message_number: 1030,
         epoch_time: 0,
         reference_station_id: 0,
         reference_station_count: 0,
         satellite_count: 0,
         satellites: empty_records,
         trailing_bits: []
       }},
      {:physical_reference_station,
       %{
         message_number: 1032,
         non_physical_station_id: 0,
         physical_station_id: 0,
         itrf_realization_year: 0,
         ecef_x: 0,
         ecef_y: 0,
         ecef_z: 0,
         trailing_bits: []
       }},
      {:fkp_gradients,
       %{
         message_number: 1034,
         reference_station_id: 0,
         epoch_time: 0,
         satellite_count: 0,
         satellites: empty_records,
         trailing_bits: []
       }}
    ]

    Enum.each(messages, fn {type, fields} ->
      assert {:ok, frame} = RTCM.encode_frame({type, fields})
      assert {:ok, [{^type, decoded_fields}]} = RTCM.decode_messages(frame)
      assert decoded_fields.message_number == fields.message_number
    end)
  end

  test "RTCM encoder refusals retain structured variant payloads" do
    fields = %{
      message_number: 1015,
      network_id: 0,
      subnetwork_id: 0,
      epoch_time: 0,
      multiple_message: false,
      master_station_id: 0,
      auxiliary_station_id: 0,
      satellite_count: 1,
      satellites: [],
      trailing_bits: []
    }

    assert {:error, {:rtcm_encode_error, %{variant: "count_mismatch", message_number: 1015, expected: 1, actual: 0}}} =
             RTCM.encode({:network_correction_differences, fields})
  end

  test "VTEC evaluation exposes typed model refusal details" do
    fields = %{
      message_number: 1264,
      igs_ssr_version: nil,
      epoch_time_s: 0,
      update_interval: 0,
      multiple_message: false,
      iod_ssr: 0,
      provider_id: 0,
      solution_id: 0,
      quality_indicator: 0,
      # DF473 carries the layer height in 10 km units: 35 is 350 km.
      layers: [%{height: 35, degree: 1, order: 1, cosine: [0, 0, 0], sine: [0]}],
      trailing_bits: []
    }

    assert {:error, {:vtec_evaluation, %{kind: "computation_time"}}} =
             RTCM.evaluate_ssr_vtec(
               {:ssr_vtec, fields},
               [6_378_137.0, 0.0, 0.0],
               [26_000_000.0, 0.0, 0.0],
               86_400.0,
               1.0e9
             )

    # A raw field the message cannot carry is refused by name.
    too_high = %{fields | layers: [%{hd(fields.layers) | height: 350}]}

    assert {:error, "invalid VTEC field height: 350 does not fit its raw width"} =
             RTCM.evaluate_ssr_vtec(
               {:ssr_vtec, too_high},
               [6_378_137.0, 0.0, 0.0],
               [26_000_000.0, 0.0, 0.0],
               3_600.0,
               1.0e9
             )
  end

  test "system-parameter and text messages construct from typed fields" do
    parameters = %{
      message_number: 1013,
      reference_station_id: 42,
      mjd: 60_000,
      seconds_of_day: 1234,
      announcement_count: 1,
      leap_seconds: 18,
      announcements: [%{message_number: 1005, synchronous: true, interval: 10}],
      trailing_bits: []
    }

    assert {:ok, parameters_body} = RTCM.encode({:system_parameters, parameters})
    assert {:ok, {:system_parameters, ^parameters}} = RTCM.decode_message(parameters_body)

    text = %{
      message_number: 1029,
      reference_station_id: 42,
      mjd: 60_000,
      seconds_of_day: 1234,
      character_count: 2,
      code_units: [?O, ?K],
      trailing_bits: []
    }

    assert {:ok, text_body} = RTCM.encode({:text, text})
    assert {:ok, {:text, ^text}} = RTCM.decode_message(text_body)

    auxiliary = %{
      message_number: 1014,
      network_id: 3,
      subnetwork_id: 2,
      auxiliary_station_count: 1,
      master_station_id: 42,
      auxiliary_station_id: 43,
      delta_latitude: -12,
      delta_longitude: 34,
      delta_height: -56,
      trailing_bits: []
    }

    assert {:ok, auxiliary_body} = RTCM.encode({:network_auxiliary_station, auxiliary})

    assert {:ok, {:network_auxiliary_station, ^auxiliary}} =
             RTCM.decode_message(auxiliary_body)

    biases = %{
      message_number: 1230,
      reference_station_id: 42,
      aligned: true,
      reserved: 0,
      l1_ca: -7,
      l1_p: nil,
      l2_ca: 11,
      l2_p: nil,
      trailing_bits: []
    }

    assert {:ok, biases_body} = RTCM.encode({:glonass_code_phase_biases, biases})

    assert {:ok, {:glonass_code_phase_biases, ^biases}} =
             RTCM.decode_message(biases_body)
  end

  test "legacy observation construction and decoding use typed fields" do
    fields = %{
      message_number: 1001,
      reference_station_id: 7,
      epoch_time: 42,
      synchronous_gnss: false,
      satellite_count: 0,
      divergence_free_smoothing: false,
      smoothing_interval: 0,
      satellites: [],
      trailing_bits: []
    }

    assert {:ok, frame} = RTCM.encode_frame({:legacy_observations, fields})
    assert {:ok, [{:legacy_observations, decoded}]} = RTCM.decode_messages(frame)
    assert decoded == fields
    refute Map.has_key?(decoded, :body)
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

  test "decode_messages refuses a CRC-corrupted frame; decode_stream reports it" do
    corrupted = :binary.replace(@frame_1006, <<62, 231>>, <<0, 0>>)
    assert {:error, message} = RTCM.decode_messages(corrupted)
    assert message =~ "CRC-24Q"

    assert {:ok, %{messages: [], diagnostics: diagnostics}} = RTCM.decode_stream(corrupted)
    assert diagnostics.crc_failures == 1
    assert diagnostics.resync_bytes == byte_size(corrupted)
  end

  test "decode_messages refuses a buffer with bytes outside any frame" do
    assert {:error, _message} = RTCM.decode_messages(<<0, 1, 2, 3, 4, 5>>)
    assert {:error, _message} = RTCM.decode_messages(<<"junk", @frame_1006::binary>>)
  end

  test "decode_stream returns messages and diagnostics" do
    assert {:ok, stream} = RTCM.decode_stream(<<"junk", @frame_1006::binary>>)

    assert [{:station_coordinates, fields}] = stream.messages
    assert fields.message_number == 1006
    assert fields.trailing_bits == []
    assert stream.diagnostics.resync_bytes == 4
    assert stream.diagnostics.crc_failures == 0
    assert stream.diagnostics.skipped_frames == []
    assert stream.diagnostics.departures == []
  end

  test "bits after the last field are refused under :strict and kept under :lenient" do
    {:ok, %{body: body, reserved: 0}} = RTCM.decode_frame(@frame_1006)
    padded = body <> <<0xFF>>
    ones = List.duplicate(true, 8)

    assert {:error, _reason} = RTCM.decode_message(padded)

    assert {:ok, {:station_coordinates, fields}, [{:trailing_bits, 1006, ^ones}]} =
             RTCM.decode_message_with_policy(padded, :lenient)

    assert fields.trailing_bits == ones
    assert {:error, _reason} = RTCM.encode({:station_coordinates, fields})
    assert {:ok, ^padded, departures} = RTCM.encode_with_policy({:station_coordinates, fields}, :lenient)
    assert is_list(departures)

    {:ok, frame} = RTCM.encode_frame(padded)
    assert {:ok, %{messages: [], diagnostics: strict}} = RTCM.decode_stream(frame)
    assert [%{reason: :departure, detail: {:trailing_bits, 1006, ^ones}}] = strict.skipped_frames

    assert {:ok, %{messages: [{:station_coordinates, _}], diagnostics: lenient}} =
             RTCM.decode_stream(frame, policy: :lenient)

    assert [{0, {:trailing_bits, 1006, ^ones}}] = lenient.departures
  end

  test "frame reserved bits are read and written back" do
    {:ok, %{body: body}} = RTCM.decode_frame(@frame_1006)
    assert {:ok, frame} = RTCM.encode_frame_with_reserved(body, 5)
    assert {:ok, %{reserved: 5, body: ^body}} = RTCM.decode_frame(frame)
    # The frame's reserved field is six bits, 0..=63.
    assert {:error, {:rtcm_encode_error, %{variant: "frame_reserved_out_of_range", value: "64"}}} =
             RTCM.encode_frame_with_reserved(body, 64)
  end

  test "decode_frame errors on a truncated buffer" do
    assert {:error, _reason} = RTCM.decode_frame(<<211, 0>>)
  end

  test "LLI helper functions delegate to core tables and rules" do
    assert RTCM.lli_bits() == %{loss_of_lock: 1, half_cycle: 2}
    assert {:ok, 0} = RTCM.minimum_lock_time_ms("msm4", 0)
    assert {:ok, 512} = RTCM.minimum_lock_time_ms("msm4", 5)
    assert {:ok, nil} = RTCM.minimum_lock_time_ms("msm4", 16)
    assert {:ok, 67_108_864} = RTCM.minimum_lock_time_ms("msm7", 704)
    assert {:ok, nil} = RTCM.minimum_lock_time_ms("msm7", 705)

    assert RTCM.derive_lli(nil, nil, 0, true) == 2
    assert RTCM.derive_lli(1024, 500, 512, false) == 1
    assert RTCM.derive_lli(512, 600, 512, false) == 1
    assert RTCM.derive_lli(512, 512, 512, false) == 0

    assert {:ok, 2_000} = RTCM.msm_epoch_dt_ms("G", 604_799_000, 1_000)
    assert {:ok, "1C"} = RTCM.msm_signal_rinex_code("G", 2)
    assert {:ok, nil} = RTCM.msm_signal_rinex_code("G", 1)
  end

  test "msm_lli runs one lock-time tracker over MSM field maps" do
    first = msm_fields("msm4", 1074)
    second = put_in(first.header.epoch_time, 700)

    assert {:ok, [[first_cell], [second_cell]]} = RTCM.msm_lli([first, second])
    assert first_cell == %{satellite_id: 5, signal_id: 2, lli: 0, min_lock_time_ms: 512}
    assert second_cell == %{satellite_id: 5, signal_id: 2, lli: 1, min_lock_time_ms: 512}
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

    test "round-trips a 1042 BeiDou ephemeris built from scratch" do
      assert_roundtrip(:beidou_ephemeris, beidou_ephemeris_fields())
    end

    test "round-trips a 1044 QZSS ephemeris built from scratch" do
      assert_roundtrip(:qzss_ephemeris, qzss_ephemeris_fields())
    end

    test "round-trips a 1045 Galileo F/NAV ephemeris built from scratch" do
      assert_roundtrip(:galileo_fnav_ephemeris, galileo_fnav_ephemeris_fields())
    end

    test "round-trips a 1046 Galileo I/NAV ephemeris built from scratch" do
      assert_roundtrip(:galileo_inav_ephemeris, galileo_inav_ephemeris_fields())
    end

    test "decodes a real 1046 Galileo I/NAV frame and re-encodes it exactly" do
      assert {:ok, [{:galileo_inav_ephemeris, fields}]} = RTCM.decode_messages(@frame_1046)
      assert fields.satellite_id == 3
      assert fields.week_number == 1402
      assert fields.iod_nav == 7
      assert fields.sqrt_a == 2_852_448_983
      assert fields.eccentricity == 4_459_564
      assert {:ok, @frame_1046} = RTCM.encode_message({:galileo_inav_ephemeris, fields})
    end

    test "round-trips an MSM4 observation message built from scratch" do
      fields = msm_fields("msm4", 1074)
      assert {:ok, frame} = RTCM.encode_message({:msm, fields})
      assert {:ok, [{:msm, decoded}]} = RTCM.decode_messages(frame)

      assert decoded.message_number == 1074
      assert decoded.system == "G"
      assert decoded.kind == "msm4"
      # Built without a mask, the message states the mask of its cells' signals.
      assert decoded.signal_mask ==
               Enum.reduce(fields.signals, 0, fn signal, mask ->
                 Bitwise.bor(mask, Bitwise.bsl(1, 32 - signal.signal_id))
               end)

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

  describe "encode refusals" do
    test "an MSM satellite outside the 64-bit mask is refused by name, not written as another" do
      fields = msm_with_satellite(msm_fields("msm4", 1074), 65)

      for encoder <- [&RTCM.encode/1, &RTCM.encode_frame/1, &RTCM.encode_message/1] do
        assert {:error, {:rtcm_encode_error, %{variant: "msm_mask", satellite: 65}}} =
                 encoder.({:msm, fields})
      end
    end

    test "an MSM satellite number wider than a byte is refused before conversion" do
      fields = msm_with_satellite(msm_fields("msm4", 1074), 257)

      assert {:error, {:invalid_input, message}} = RTCM.encode({:msm, fields})
      assert message =~ "257"
    end

    test "an MSM signal naming an unlisted satellite, or a repeated satellite, is refused" do
      fields = msm_fields("msm7", 1077)
      [signal] = fields.signals

      unlisted = %{fields | signals: [%{signal | satellite_id: 6}]}

      assert {:error, {:rtcm_encode_error, %{variant: "msm_mask", satellite: 6, signal: signal_id}}} =
               RTCM.encode({:msm, unlisted})

      assert signal_id == signal.signal_id

      [satellite] = fields.satellites
      repeated = %{fields | satellites: [satellite, satellite]}

      assert {:error, {:rtcm_encode_error, %{variant: "msm_mask", satellite: 5}}} =
               RTCM.encode({:msm, repeated})

      out_of_mask = %{fields | signals: [%{signal | signal_id: 33}]}

      assert {:error, {:rtcm_encode_error, %{variant: "msm_mask", signal: 33}}} =
               RTCM.encode({:msm, out_of_mask})
    end

    test "an ephemeris satellite wider than the message's raw field is refused" do
      # QZSS 1044 carries a four-bit satellite field, GPS 1019 a six-bit one.
      # The core refuses each with its typed encode error.
      assert {:error,
              {:rtcm_encode_error,
               %{
                 variant: "satellite_id_out_of_range",
                 message_number: 1044,
                 field: "QZSS satellite ID",
                 value: "16",
                 width: 4
               }}} = RTCM.encode({:qzss_ephemeris, %{qzss_ephemeris_fields() | satellite_id: 16}})

      assert {:error,
              {:rtcm_encode_error,
               %{
                 variant: "satellite_id_out_of_range",
                 message_number: 1019,
                 field: "GPS PRN",
                 value: "64",
                 width: 6
               }}} =
               RTCM.encode_frame({:gps_ephemeris, %{gps_ephemeris_fields() | satellite_id: 64}})

      assert {:error, {:invalid_input, _message}} =
               RTCM.encode({:gps_ephemeris, %{gps_ephemeris_fields() | satellite_id: 256}})

      # The widest value each field holds still encodes.
      assert {:ok, _body} = RTCM.encode({:qzss_ephemeris, %{qzss_ephemeris_fields() | satellite_id: 15}})
      assert {:ok, _body} = RTCM.encode({:gps_ephemeris, %{gps_ephemeris_fields() | satellite_id: 63}})
    end
  end

  defp msm_with_satellite(fields, id) do
    %{
      fields
      | satellites: Enum.map(fields.satellites, &%{&1 | id: id}),
        signals: Enum.map(fields.signals, &%{&1 | satellite_id: id})
    }
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

  defp beidou_ephemeris_fields do
    %{
      satellite_id: 19,
      week_number: 902,
      sv_urai: 1,
      idot: 1,
      aode: 17,
      t_oc: 12_000,
      a_f2: -3,
      a_f1: 12_345,
      a_f0: -45_678,
      aodc: 12,
      c_rs: -1000,
      delta_n: 100,
      m0: 1000,
      c_uc: -50,
      eccentricity: 4_459_564,
      c_us: 51,
      sqrt_a: 2_852_448_983,
      t_oe: 12_000,
      c_ic: -5,
      omega0: 1000,
      c_is: 6,
      i0: 1000,
      c_rc: 100,
      omega: 1000,
      omega_dot: -100,
      t_gd1: 5,
      t_gd2: 7,
      sv_health: false
    }
  end

  defp qzss_ephemeris_fields do
    %{
      satellite_id: 3,
      t_oc: 7200,
      a_f2: 1,
      a_f1: 1,
      a_f0: 23_456,
      iode: 11,
      c_rs: 1,
      delta_n: 1,
      m0: 1,
      c_uc: 1,
      eccentricity: 1,
      c_us: 1,
      sqrt_a: 2_702_336_448,
      t_oe: 3600,
      c_ic: 1,
      omega0: 1,
      c_is: 1,
      i0: 1,
      c_rc: 1,
      omega: 1,
      omega_dot: 1,
      idot: 1,
      codes_on_l2: 1,
      week_number: 123,
      ura: 1,
      sv_health: 1,
      t_gd: 1,
      iodc: 1,
      fit_interval: false
    }
  end

  defp galileo_fnav_ephemeris_fields do
    %{
      satellite_id: 12,
      week_number: 1402,
      iod_nav: 7,
      sisa: 42,
      idot: 434,
      t_oc: 5150,
      a_f2: 0,
      a_f1: -151,
      a_f0: -471_483,
      c_rs: -791,
      delta_n: 9274,
      m0: 1_630_831_142,
      c_uc: -707,
      eccentricity: 4_459_564,
      c_us: 3342,
      sqrt_a: 2_852_448_983,
      t_oe: 5150,
      c_ic: -5,
      omega0: 2_118_450_828,
      c_is: -11,
      i0: 662_506_241,
      c_rc: 6692,
      omega: 372_867_071,
      omega_dot: -15_832,
      bgd_e5a_e1: 5,
      e5a_signal_health: 0,
      e5a_data_validity: false,
      reserved: 0
    }
  end

  defp galileo_inav_ephemeris_fields do
    %{
      satellite_id: 3,
      week_number: 1402,
      iod_nav: 7,
      sisa_index: 107,
      idot: 434,
      t_oc: 5150,
      a_f2: 0,
      a_f1: -151,
      a_f0: -471_483,
      c_rs: -791,
      delta_n: 9274,
      m0: 1_630_831_142,
      c_uc: -707,
      eccentricity: 4_459_564,
      c_us: 3342,
      sqrt_a: 2_852_448_983,
      t_oe: 5150,
      c_ic: -5,
      omega0: 2_118_450_828,
      c_is: -11,
      i0: 662_506_241,
      c_rc: 6692,
      omega: 372_867_071,
      omega_dot: -15_832,
      bgd_e5a_e1: 5,
      bgd_e5b_e1: 7,
      e5b_signal_health: 0,
      e5b_data_validity: false,
      e1b_signal_health: 0,
      e1b_data_validity: false,
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
