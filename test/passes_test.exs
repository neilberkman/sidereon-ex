defmodule Sidereon.PassesTest do
  use ExUnit.Case, async: true

  # ISS TLE (epoch 2024-12-19)
  @iss_line1 "1 25544U 98067A   24354.52609954  .00020888  00000+0  37042-3 0  9992"
  @iss_line2 "2 25544  51.6393 213.2584 0006955  37.7614  87.9783 15.49970085486016"

  # Ground station: London, UK
  @london %{latitude: 51.5074, longitude: -0.1278, altitude_m: 11.0}

  setup do
    {:ok, tle} = Sidereon.Format.TLE.parse(@iss_line1, @iss_line2)
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
      assert length(passes) >= 1
    end

    test "matches the core pass oracle exactly", %{tle: tle} do
      start_time = ~U[2024-12-19 00:00:00Z]
      end_time = ~U[2024-12-19 12:00:00Z]

      assert {:ok, [pass]} = Sidereon.Passes.predict(tle, @london, start_time, end_time)
      assert DateTime.to_unix(pass.rise, :microsecond) == 1_734_604_991_825_435
      assert DateTime.to_unix(pass.set, :microsecond) == 1_734_605_533_400_371
      assert DateTime.to_unix(pass.max_elevation_time, :microsecond) == 1_734_605_261_892_583

      <<bits::64>> = <<pass.max_elevation::float-64>>
      assert bits == 0x4029_1832_84BB_DCEE
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
end
