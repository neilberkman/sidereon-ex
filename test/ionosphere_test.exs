defmodule Sidereon.GNSS.IonosphereTest do
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.Ionosphere

  # Synthetic 7x7 two-map IONEX grid (committed fixture): latitudes 60..-60 step
  # -20, longitudes -180..180 step 60, two epochs at 2020-06-24 00:00 and 02:00.
  # Same bytes the parity generator uses, so the slant delay below can be checked
  # against the IONEX reference fixture.
  @ionex_path Path.join(__DIR__, "fixtures/synthetic_2map_7x7.20i")
  @ionex File.read!(@ionex_path)

  # GPS broadcast coefficients used across the Klobuchar reference fixtures.
  @klobuchar_params %{
    alpha: {0.1490116119384766e-7, 0.2235174179077148e-7, -0.1192092895507813e-6, -0.1192092895507813e-6},
    beta: {96_256.0, 131_072.0, -65_536.0, -589_824.0}
  }

  # Galileo broadcast effective-ionisation coefficients (high-activity reference
  # set) and a single reference ray from the NeQuick-G benchmark suite, with the
  # reference slant TEC the full 3D integration reproduces.
  @nequick_coeffs %{ai0: 236.831641, ai1: -0.39362878, ai2: 0.00402826613}
  @nequick_ray %{
    month: 4,
    utc_hours: 0.0,
    station_lon_deg: 297.66,
    station_lat_deg: 82.49,
    station_height_m: 78.11,
    satellite_lon_deg: 8.23,
    satellite_lat_deg: 54.29,
    satellite_height_m: 20_281_546.18
  }
  @nequick_reference_stec 20.40224
  @galileo_e1_hz 1_575_420_000.0

  describe "nequick_g_stec/2 (full 3D slant integration)" do
    test "reproduces the reference benchmark slant TEC" do
      assert {:ok, stec} = Ionosphere.nequick_g_stec(@nequick_coeffs, @nequick_ray)
      assert_in_delta stec, @nequick_reference_stec, 1.0e-4
    end

    test "rejects an out-of-range month" do
      assert {:error, _reason} =
               Ionosphere.nequick_g_stec(@nequick_coeffs, %{@nequick_ray | month: 13})
    end

    test "rejects a malformed ray" do
      assert {:error, :bad_nequick_ray} =
               Ionosphere.nequick_g_stec(@nequick_coeffs, %{month: 4})
    end
  end

  describe "nequick_g_delay/3 (full 3D slant delay)" do
    test "maps the slant TEC with the dispersive factor" do
      assert {:ok, stec} = Ionosphere.nequick_g_stec(@nequick_coeffs, @nequick_ray)
      assert {:ok, delay} = Ionosphere.nequick_g_delay(@nequick_coeffs, @nequick_ray, @galileo_e1_hz)

      expected = stec * (40.3e16 / (@galileo_e1_hz * @galileo_e1_hz))
      assert_in_delta delay, expected, 1.0e-9
      assert delay > 0.0
    end
  end

  describe "klobuchar_delay/7" do
    test "returns a positive L1 group delay in meters" do
      assert {:ok, delay_m} =
               Ionosphere.klobuchar_delay(
                 @klobuchar_params,
                 40.0,
                 -100.0,
                 30.0,
                 85.0,
                 {{2020, 6, 24}, {14, 0, 0}},
                 1_575_420_000.0
               )

      assert is_float(delay_m)
      assert delay_m > 0.0
    end

    test "an L2 carrier delay exceeds the L1 delay (dispersive 1/f^2 scaling)" do
      epoch = {{2020, 6, 24}, {14, 0, 0}}

      {:ok, l1} =
        Ionosphere.klobuchar_delay(
          @klobuchar_params,
          40.0,
          -100.0,
          30.0,
          85.0,
          epoch,
          1_575_420_000.0
        )

      {:ok, l2} =
        Ionosphere.klobuchar_delay(
          @klobuchar_params,
          40.0,
          -100.0,
          30.0,
          85.0,
          epoch,
          1_227_600_000.0
        )

      assert l2 > l1
    end

    test "rejects malformed coefficient parameters" do
      assert {:error, :bad_klobuchar_params} =
               Ionosphere.klobuchar_delay(
                 %{},
                 40.0,
                 -100.0,
                 30.0,
                 85.0,
                 {{2020, 6, 24}, {0, 0, 0}},
                 1_575_420_000.0
               )

      assert {:error, :bad_coefficients} =
               Ionosphere.klobuchar_delay(
                 %{alpha: {1, 2, 3}, beta: {1, 2, 3, 4}},
                 40.0,
                 -100.0,
                 30.0,
                 85.0,
                 {{2020, 6, 24}, {0, 0, 0}},
                 1_575_420_000.0
               )
    end

    test "matches the Klobuchar reference fixture (klobuchar_golden.json) exactly (0 ULP) through the public path" do
      # The exact inputs and coefficients of the `zenith_midlat_day` golden case
      # (parity/fixtures/klobuchar_golden.json): 14:00:00 == second-of-day 50400.
      # The public path passes degrees straight through and forms the
      # second-of-day from the integer clock fields, so the result is bit-for-bit
      # the golden delay (== compares the full f64).
      params = %{
        alpha: {1.024454832077e-08, 2.235174179077e-08, -5.960464477539e-08, -1.192092895508e-07},
        beta: {96_256.0, 131_072.0, -65_536.0, -589_824.0}
      }

      {:ok, delay_m} =
        Ionosphere.klobuchar_delay(
          params,
          40.0,
          -100.0,
          30.0,
          85.0,
          {{2020, 6, 24}, {14, 0, 0}},
          1_575_420_000.0
        )

      assert delay_m == 2.2425167984123626
    end
  end

  describe "galileo_nequick_g_delay/7" do
    # Galileo broadcast effective-ionisation coefficients (ai0/ai1/ai2).
    @nequick_coeffs %{ai0: 65.0, ai1: 0.25, ai2: -0.02}

    test "returns a positive E1 group delay in meters" do
      assert {:ok, delay_m} =
               Ionosphere.galileo_nequick_g_delay(
                 @nequick_coeffs,
                 47.0,
                 8.0,
                 122.0,
                 37.0,
                 {{2021, 3, 21}, {0, 0, 0}},
                 1_575_420_000.0
               )

      assert is_float(delay_m)
      assert delay_m > 0.0
    end

    test "matches the core NeQuick-G kernel bit-for-bit (0 ULP) across three epochs" do
      # Goldens produced directly by sidereon-core
      # `atmosphere::ionosphere::ionosphere_delay` with the `GalileoNequickG`
      # model over the same split-Julian-date instant the public path forms, so
      # the public wrapper agrees to the full f64 (== compares all bits).
      assert {:ok, 0.2275379061294803} =
               Ionosphere.galileo_nequick_g_delay(
                 %{ai0: 65.0, ai1: 0.25, ai2: -0.02},
                 47.0,
                 8.0,
                 122.0,
                 37.0,
                 {{2021, 3, 21}, {0, 0, 0}},
                 1_575_420_000.0
               )

      assert {:ok, 12.9844374686208432} =
               Ionosphere.galileo_nequick_g_delay(
                 %{ai0: 120.0, ai1: -1.5, ai2: 0.3},
                 -12.5,
                 130.0,
                 300.0,
                 20.0,
                 {{2021, 7, 2}, {12, 0, 0}},
                 1_575_420_000.0
               )

      assert {:ok, 0.870160732798960779} =
               Ionosphere.galileo_nequick_g_delay(
                 %{ai0: 40.0, ai1: 0.0, ai2: 0.0},
                 0.0,
                 0.0,
                 0.0,
                 90.0,
                 {{2021, 9, 22}, {6, 0, 0}},
                 1_575_420_000.0
               )
    end

    test "an E5a carrier delay exceeds the E1 delay (dispersive 1/f^2 scaling)" do
      epoch = {{2021, 3, 21}, {0, 0, 0}}

      {:ok, e1} =
        Ionosphere.galileo_nequick_g_delay(
          @nequick_coeffs,
          47.0,
          8.0,
          122.0,
          37.0,
          epoch,
          1_575_420_000.0
        )

      {:ok, e5a} =
        Ionosphere.galileo_nequick_g_delay(
          @nequick_coeffs,
          47.0,
          8.0,
          122.0,
          37.0,
          epoch,
          1_176_450_000.0
        )

      assert e5a > e1
    end

    test "azimuth does not change the NeQuick-G delay (slant by elevation only)" do
      epoch = {{2021, 3, 21}, {0, 0, 0}}

      {:ok, a} =
        Ionosphere.galileo_nequick_g_delay(
          @nequick_coeffs,
          47.0,
          8.0,
          0.0,
          37.0,
          epoch,
          1_575_420_000.0
        )

      {:ok, b} =
        Ionosphere.galileo_nequick_g_delay(
          @nequick_coeffs,
          47.0,
          8.0,
          270.0,
          37.0,
          epoch,
          1_575_420_000.0
        )

      assert a == b
    end

    test "rejects malformed coefficient parameters" do
      assert {:error, :bad_nequick_params} =
               Ionosphere.galileo_nequick_g_delay(
                 %{},
                 47.0,
                 8.0,
                 122.0,
                 37.0,
                 {{2021, 3, 21}, {0, 0, 0}},
                 1_575_420_000.0
               )
    end
  end

  describe "parse_ionex/1 and ionex_slant_delay/7" do
    setup do
      {:ok, handle} = Ionosphere.parse_ionex(@ionex)
      {:ok, handle: handle}
    end

    test "parse_ionex/1 returns a resource handle" do
      assert {:ok, handle} = Ionosphere.parse_ionex(@ionex)
      assert is_reference(handle)
    end

    test "parse_ionex/1 errors on a malformed buffer" do
      assert {:error, _reason} = Ionosphere.parse_ionex("not an ionex file\n")
    end

    test "ionex_to_string/1 round-trips to a re-parseable product", %{handle: handle} do
      assert {:ok, text} = Ionosphere.ionex_to_string(handle)
      assert is_binary(text)
      assert {:ok, reparsed} = Ionosphere.parse_ionex(text)
      assert is_reference(reparsed)

      epoch = {{2020, 6, 24}, {1, 0, 0}}

      {:ok, original} =
        Ionosphere.ionex_slant_delay(handle, 45.0, 10.0, 60.0, 60.0, epoch, 1_575_420_000.0)

      {:ok, after_round_trip} =
        Ionosphere.ionex_slant_delay(reparsed, 45.0, 10.0, 60.0, 60.0, epoch, 1_575_420_000.0)

      assert after_round_trip == original
    end

    test "slant delay matches the reference fixture L1 value bit-for-bit (0 ULP)", %{
      handle: handle
    } do
      # Same inputs as the IONEX reference fixture 'interior_l1': lat 45, lon 10,
      # az 60, el 60, L1, epoch 2020-06-24 01:00:00.
      assert {:ok, delay_m} =
               Ionosphere.ionex_slant_delay(
                 handle,
                 45.0,
                 10.0,
                 60.0,
                 60.0,
                 {{2020, 6, 24}, {1, 0, 0}},
                 1_575_420_000.0
               )

      assert delay_m == 2.9414773797764737
    end

    test "an L2 slant delay exceeds the L1 slant delay", %{handle: handle} do
      epoch = {{2020, 6, 24}, {1, 0, 0}}

      {:ok, l1} =
        Ionosphere.ionex_slant_delay(handle, 45.0, 10.0, 60.0, 60.0, epoch, 1_575_420_000.0)

      {:ok, l2} =
        Ionosphere.ionex_slant_delay(handle, 45.0, 10.0, 60.0, 60.0, epoch, 1_227_600_000.0)

      assert l2 > l1
    end

    test "rejects a non-integer-second epoch (IONEX axis is integer seconds)", %{handle: handle} do
      assert {:error, :non_integer_second_epoch} =
               Ionosphere.ionex_slant_delay(
                 handle,
                 45.0,
                 10.0,
                 60.0,
                 60.0,
                 ~N[2020-06-24 01:00:00.500],
                 1_575_420_000.0
               )
    end
  end
end
