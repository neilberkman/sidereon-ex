defmodule Sidereon.PassesTest do
  use ExUnit.Case, async: true

  alias Sidereon.Format.TLE

  # ISS TLE (epoch 2024-12-19)
  @iss_line1 "1 25544U 98067A   24354.52609954  .00020888  00000+0  37042-3 0  9992"
  @iss_line2 "2 25544  51.6393 213.2584 0006955  37.7614  87.9783 15.49970085486016"

  # Ground station: London, UK
  @london %{latitude: 51.5074, longitude: -0.1278, altitude_m: 11.0}

  setup do
    {:ok, tle} = TLE.parse(@iss_line1, @iss_line2)
    %{tle: tle}
  end

  describe "predict/5" do
    test "returns a list of Pass structs", %{tle: tle} do
      start_time = ~U[2024-12-19 00:00:00Z]
      end_time = ~U[2024-12-19 12:00:00Z]

      {:ok, passes} = Sidereon.Passes.predict(tle, @london, start_time, end_time)

      assert is_list(passes)

      for pass <- passes do
        assert %DateTime{} = pass.rise
        assert %DateTime{} = pass.set
        assert %DateTime{} = pass.max_elevation_time
        assert is_float(pass.max_elevation)

        # Set must be after rise
        assert DateTime.after?(pass.set, pass.rise)

        # Max elevation time must be between rise and set
        assert DateTime.compare(pass.max_elevation_time, pass.rise) in [:gt, :eq]
        assert DateTime.compare(pass.max_elevation_time, pass.set) in [:lt, :eq]

        # Max elevation must be non-negative (we default min_elevation to 0)
        assert pass.max_elevation >= 0.0

        # Duration must be positive and consistent with rise/set
      end
    end

    test "finds at least one ISS pass in a 12-hour window", %{tle: tle} do
      start_time = ~U[2024-12-19 00:00:00Z]
      end_time = ~U[2024-12-19 12:00:00Z]

      {:ok, passes} = Sidereon.Passes.predict(tle, @london, start_time, end_time)

      # ISS orbits ~15.5 times/day at 51.6 deg inclination.
      # Over 12 hours from a mid-latitude station, we should see several passes.
      refute Enum.empty?(passes)
    end

    test "matches the core pass oracle exactly", %{tle: tle} do
      # Pinned bit-exactly against the satellite-based core finder
      # (`find_passes_for_satellite`), which is the path the AFSPC default now
      # routes through so passes share the same initialized SGP4 handle/opsmode
      # as the look-angle path. These differ from the old coarse-scan
      # `predict_passes` oracle only by sub-millisecond refinement.
      start_time = ~U[2024-12-19 00:00:00Z]
      end_time = ~U[2024-12-19 12:00:00Z]

      assert {:ok, [pass]} = Sidereon.Passes.predict(tle, @london, start_time, end_time)
      assert DateTime.to_unix(pass.rise, :microsecond) == 1_734_604_991_825_121
      assert DateTime.to_unix(pass.set, :microsecond) == 1_734_605_533_400_794
      assert DateTime.to_unix(pass.max_elevation_time, :microsecond) == 1_734_605_261_892_714

      # Native-arch (aarch64) reference value. Pass geometry runs transcendental
      # math (sin/cos/sqrt) whose libm differs by a few ULP across architectures,
      # so the value is compared within tolerance rather than bit-for-bit (CI runs
      # x86_64; the reference was captured on aarch64, ~19 ULP apart).
      <<expected_max_elevation::float-64>> = <<0x4029_1832_84BB_CFCD::64>>
      assert_in_delta pass.max_elevation, expected_max_elevation, 1.0e-9
    end

    test "min_elevation option filters out low passes", %{tle: tle} do
      start_time = ~U[2024-12-19 00:00:00Z]
      end_time = ~U[2024-12-19 12:00:00Z]

      {:ok, all_passes} =
        Sidereon.Passes.predict(tle, @london, start_time, end_time, min_elevation: 0.0)

      {:ok, high_passes} =
        Sidereon.Passes.predict(tle, @london, start_time, end_time, min_elevation: 30.0)

      assert length(high_passes) <= length(all_passes)

      for pass <- high_passes do
        assert pass.max_elevation >= 30.0
      end
    end

    test "min_elevation is a PEAK filter: excludes low-peak passes, leaves AOS/LOS on the horizon",
         %{tle: tle} do
      # 24-hour window yields ISS passes spanning a wide range of peak
      # elevations (~2 deg grazing up to ~87 deg overhead), so a 30 deg
      # threshold both keeps and drops passes.
      start_time = ~U[2024-12-19 00:00:00Z]
      end_time = ~U[2024-12-20 00:00:00Z]
      min_el = 30.0

      {:ok, all_passes} =
        Sidereon.Passes.predict(tle, @london, start_time, end_time, min_elevation: 0.0)

      {:ok, kept_passes} =
        Sidereon.Passes.predict(tle, @london, start_time, end_time, min_elevation: min_el)

      # There is at least one pass on each side of the threshold (the filter is
      # actually exercised, not a no-op or an empty result).
      assert Enum.any?(all_passes, &(&1.max_elevation < min_el))
      assert Enum.any?(all_passes, &(&1.max_elevation >= min_el))

      # The kept set is exactly the horizon passes whose PEAK clears the
      # threshold — low-peak passes are dropped, nothing else.
      expected_kept = Enum.filter(all_passes, &(&1.max_elevation >= min_el))
      assert length(kept_passes) == length(expected_kept)

      key = fn p -> DateTime.to_unix(p.max_elevation_time, :microsecond) end
      assert Enum.map(kept_passes, key) == Enum.map(expected_kept, key)

      # Critical: a nonzero :min_elevation must NOT move AOS/LOS to the threshold
      # crossing. Each kept pass keeps the SAME rise/set (and thus duration) it
      # had under min_elevation: 0.0 — bit-for-bit — and its rise sits on the
      # 0-degree horizon, not on the 30-degree mask.
      by_key = Map.new(all_passes, &{key.(&1), &1})

      for kept <- kept_passes do
        baseline = Map.fetch!(by_key, key.(kept))

        assert DateTime.to_unix(kept.rise, :microsecond) ==
                 DateTime.to_unix(baseline.rise, :microsecond)

        assert DateTime.to_unix(kept.set, :microsecond) ==
                 DateTime.to_unix(baseline.set, :microsecond)

        assert kept.duration_seconds == baseline.duration_seconds

        {:ok, aos} = Sidereon.look_angle(tle, kept.rise, @london)
        assert_in_delta aos.elevation, 0.0, 1.0e-3
        refute_in_delta aos.elevation, min_el, 1.0
      end
    end

    test "returns empty list for zero-length window", %{tle: tle} do
      t = ~U[2024-12-19 06:00:00Z]
      assert Sidereon.Passes.predict(tle, @london, t, t) == {:ok, []}
    end

    test "passes are sorted by rise time", %{tle: tle} do
      start_time = ~U[2024-12-19 00:00:00Z]
      end_time = ~U[2024-12-20 00:00:00Z]

      {:ok, passes} = Sidereon.Passes.predict(tle, @london, start_time, end_time)

      rise_times = Enum.map(passes, & &1.rise)

      assert rise_times ==
               Enum.sort(rise_times, fn a, b -> DateTime.compare(a, b) != :gt end)
    end

    test "delegate from Sidereon module works", %{tle: tle} do
      start_time = ~U[2024-12-19 00:00:00Z]
      end_time = ~U[2024-12-19 06:00:00Z]

      {:ok, passes} = Sidereon.predict_passes(tle, @london, start_time, end_time)
      assert is_list(passes)
    end

    test "returns TLE marshal errors instead of empty passes", %{tle: tle} do
      start_time = ~U[2024-12-19 00:00:00Z]
      end_time = ~U[2024-12-19 06:00:00Z]

      assert {:error, {:missing_field, :mean_motion}} =
               tle
               |> Map.put(:mean_motion, nil)
               |> Sidereon.Passes.predict(@london, start_time, end_time)
    end

    test "returns errors for invalid station fields", %{tle: tle} do
      start_time = ~U[2024-12-19 00:00:00Z]
      end_time = ~U[2024-12-19 06:00:00Z]

      assert {:error, {:missing_field, :altitude_m}} =
               Sidereon.Passes.predict(
                 tle,
                 Map.delete(@london, :altitude_m),
                 start_time,
                 end_time
               )

      assert {:error, {:invalid_field, :latitude, "51.5"}} =
               Sidereon.Passes.predict(
                 tle,
                 Map.put(@london, :latitude, "51.5"),
                 start_time,
                 end_time
               )
    end

    test "returns errors for invalid options", %{tle: tle} do
      start_time = ~U[2024-12-19 00:00:00Z]
      end_time = ~U[2024-12-19 06:00:00Z]

      assert {:error, {:invalid_option, :step_seconds}} =
               Sidereon.Passes.predict(tle, @london, start_time, end_time, step_seconds: 0)

      assert {:error, {:invalid_option, :min_elevation}} =
               Sidereon.Passes.predict(tle, @london, start_time, end_time, min_elevation: "30")

      assert {:error, {:invalid_option, :unexpected}} =
               Sidereon.Passes.predict(tle, @london, start_time, end_time, unexpected: true)
    end

    test "predict!/5 raises on error", %{tle: tle} do
      assert_raise ArgumentError, ~r/pass prediction failed/, fn ->
        Sidereon.Passes.predict!(
          tle,
          @london,
          ~U[2024-12-19 00:00:00Z],
          ~U[2024-12-19 12:00:00Z],
          step_seconds: 0
        )
      end
    end
  end

  describe "opsmode is honored (regression)" do
    # ISS TLE specified by the task (epoch 2018-07-03). The ISS is a near-Earth
    # satellite, so the deep-space periodics never run and AFSPC vs Improved are
    # bit-identical in correct SGP4 — opsmode only changes results through the
    # deep-space `dpper` negative-node branch. We therefore prove the
    # passes<->look_angle *consistency* with the ISS, and prove the AFSPC-vs-
    # Improved *difference* with a deep-space object (below), where opsmode
    # genuinely matters.
    @iss_2018_l1 "1 25544U 98067A   18184.80969102  .00001614  00000-0  31745-4 0  9993"
    @iss_2018_l2 "2 25544  51.6414 295.8524 0003435 262.6267 204.2868 15.54005638121106"

    # Deep-space object 23599 (period > 225 min). Its node goes negative within a
    # day of epoch, so the AFSPC-only branch in the core periodics fires and the
    # propagation — and thus look angle and passes — differs by opsmode.
    @ds_l1 "1 23599U 95029B   06171.76535463  .00085586  12891-6  12956-2 0  2905"
    @ds_l2 "2 23599   6.9327   0.2849 5782022 274.4436  25.2425  4.47796565123555"

    @equator %{latitude: 0.0, longitude: 0.0, altitude_m: 0.0}

    test "passes reject an invalid :opsmode" do
      {:ok, tle} = TLE.parse(@iss_2018_l1, @iss_2018_l2)

      assert {:error, {:invalid_option, :opsmode}} =
               Sidereon.Passes.predict(
                 tle,
                 @london,
                 ~U[2018-07-03 00:00:00Z],
                 ~U[2018-07-03 12:00:00Z],
                 opsmode: :bogus
               )
    end

    test "look_angle rejects an invalid :opsmode" do
      {:ok, tle} = TLE.parse(@iss_2018_l1, @iss_2018_l2)

      assert {:error, {:invalid_option, {:opsmode, :bogus}}} =
               Sidereon.look_angle(tle, ~U[2018-07-03 06:00:00Z], @london, opsmode: :bogus)
    end

    test "deep-space look_angle differs between :improved and :afspc" do
      {:ok, tle} = TLE.parse(@ds_l1, @ds_l2)
      # 12 hours past epoch, where the deep-space periodics have diverged.
      datetime = DateTime.add(tle.epoch, 720 * 60, :second)

      {:ok, afspc} = Sidereon.look_angle(tle, datetime, @equator, opsmode: :afspc)
      {:ok, improved} = Sidereon.look_angle(tle, datetime, @equator, opsmode: :improved)

      refute afspc == improved
      assert afspc.elevation != improved.elevation
      # A real, opsmode-sized difference (sub-degree but well above float noise).
      assert_in_delta afspc.elevation, improved.elevation, 0.01
      refute_in_delta afspc.elevation, improved.elevation, 1.0e-9
    end

    test "deep-space passes differ between :improved and :afspc" do
      {:ok, tle} = TLE.parse(@ds_l1, @ds_l2)
      start_time = ~U[2006-06-21 00:00:00Z]
      end_time = ~U[2006-06-22 00:00:00Z]

      {:ok, afspc} = Sidereon.Passes.predict(tle, @equator, start_time, end_time, opsmode: :afspc)

      {:ok, improved} =
        Sidereon.Passes.predict(tle, @equator, start_time, end_time, opsmode: :improved)

      assert length(afspc) == length(improved)
      refute Enum.empty?(afspc)

      a = hd(afspc)
      i = hd(improved)

      # Same pass, different opsmode -> the AOS time and peak elevation move.
      assert DateTime.to_unix(a.rise, :microsecond) != DateTime.to_unix(i.rise, :microsecond)
      assert a.max_elevation != i.max_elevation
    end

    test "near-Earth ISS is opsmode-invariant (correct SGP4: no deep-space path)" do
      {:ok, tle} = TLE.parse(@iss_2018_l1, @iss_2018_l2)
      datetime = ~U[2018-07-03 06:00:00Z]

      assert Sidereon.look_angle(tle, datetime, @london, opsmode: :afspc) ==
               Sidereon.look_angle(tle, datetime, @london, opsmode: :improved)

      start_time = ~U[2018-07-03 00:00:00Z]
      end_time = ~U[2018-07-03 12:00:00Z]

      assert Sidereon.Passes.predict(tle, @london, start_time, end_time, opsmode: :afspc) ==
               Sidereon.Passes.predict(tle, @london, start_time, end_time, opsmode: :improved)
    end

    test "an improved satellite's passes are consistent with its improved look_angle" do
      {:ok, tle} = TLE.parse(@iss_2018_l1, @iss_2018_l2)
      start_time = ~U[2018-07-03 00:00:00Z]
      end_time = ~U[2018-07-03 12:00:00Z]

      {:ok, passes} =
        Sidereon.Passes.predict(tle, @london, start_time, end_time, opsmode: :improved)

      refute Enum.empty?(passes)

      for pass <- passes do
        # The pass finder and look_angle must agree when both are run under the
        # SAME opsmode: at culmination the independent look_angle elevation is
        # bit-for-bit the pass's max elevation, and at AOS the satellite sits on
        # the 0-degree mask.
        {:ok, peak} =
          Sidereon.look_angle(tle, pass.max_elevation_time, @london, opsmode: :improved)

        assert peak.elevation == pass.max_elevation

        {:ok, aos} = Sidereon.look_angle(tle, pass.rise, @london, opsmode: :improved)
        assert_in_delta aos.elevation, 0.0, 1.0e-3
      end
    end
  end
end
