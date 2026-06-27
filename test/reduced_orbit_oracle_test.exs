defmodule Sidereon.GNSS.ReducedOrbitOracleTest do
  use ExUnit.Case, async: true

  import Sidereon.TestHelpers, only: [hex_to_float: 1]

  alias Sidereon.GNSS.ReducedOrbit
  alias Sidereon.GNSS.ReducedOrbit.Piecewise

  @golden_path Path.join(__DIR__, "fixtures/reduced_orbit_golden.json")

  setup_all do
    {:ok, golden: @golden_path |> File.read!() |> Jason.decode!()}
  end

  describe "ReducedOrbit vs Astropy/scipy reference fixture" do
    test "fit/2 recovers the independent circular scipy fit", %{golden: golden} do
      c = golden["cases"]["circular"]

      assert {:ok, fit} =
               ReducedOrbit.fit(samples(c), model: :circular_secular, time_scale: "UTC")

      assert fit.model == "circular_secular"
      assert fit.time_scale == "UTC"
      assert fit.fit.n_samples == c["fit"]["stats"]["n_samples"]
      assert_in_delta fit.a_m, h(element(c, "a_m")), 25.0
      assert_in_delta fit.i_rad, h(element(c, "i_rad")), 2.0e-6
      assert_in_delta fit.raan_rad, h(element(c, "raan_rad")), 2.0e-6
      assert_in_delta fit.raan_rate_rad_s, h(element(c, "raan_rate_rad_s")), 5.0e-10
      assert_in_delta fit.arg_lat_rad, h(element(c, "arg_lat_rad")), 6.0e-6
      assert_in_delta fit.mean_motion_rad_s, h(element(c, "mean_motion_rad_s")), 5.0e-10
      assert fit.fit.rms_m < 25.0
      assert fit.fit.max_m < 50.0
    end

    test "fit/2 recovers the independent eccentric scipy fit", %{golden: golden} do
      c = golden["cases"]["eccentric"]

      assert {:ok, fit} =
               ReducedOrbit.fit(samples(c), model: :eccentric_secular, time_scale: "UTC")

      assert fit.model == "eccentric_secular"
      assert fit.fit.n_samples == c["fit"]["stats"]["n_samples"]
      assert_in_delta fit.a_m, h(element(c, "a_m")), 50.0
      assert_in_delta fit.e, h(element(c, "e")), 2.0e-6
      assert_in_delta fit.h, h(element(c, "h")), 2.0e-6
      assert_in_delta fit.k, h(element(c, "k")), 2.0e-6
      assert_in_delta fit.i_rad, h(element(c, "i_rad")), 2.0e-6
      assert_in_delta fit.raan_rad, h(element(c, "raan_rad")), 6.0e-6
      assert_in_delta fit.raan_rate_rad_s, h(element(c, "raan_rate_rad_s")), 5.0e-10
      assert_in_delta fit.arg_lat_rad, h(element(c, "arg_lat_rad")), 6.0e-6
      assert_in_delta fit.mean_motion_rad_s, h(element(c, "mean_motion_rad_s")), 5.0e-10
      assert fit.fit.rms_m < 50.0
      assert fit.fit.max_m < 100.0
    end

    test "position/3 and position_velocity/3 evaluate the Python model map", %{golden: golden} do
      for {_name, c} <- golden["cases"] do
        assert {:ok, model} = c["fit"]["map"] |> dehex_map() |> ReducedOrbit.from_map()

        for pos <- c["positions"] do
          epoch = NaiveDateTime.from_iso8601!(pos["epoch"])

          assert {:ok, gcrs} = ReducedOrbit.position(model, epoch, frame: :gcrs)
          assert_vec3(gcrs, pos["gcrs_m"], 1.0e-5)

          assert {:ok, ecef} = ReducedOrbit.position(model, epoch, frame: :ecef)
          # Astropy/ERFA and the Rust IAU transform are independent frame
          # implementations. Treat ECEF as an external-library agreement check.
          assert_vec3(ecef, pos["ecef_m"], 100.0)
        end

        for vel <- c["velocities"] do
          epoch = NaiveDateTime.from_iso8601!(vel["epoch"])
          assert {:ok, state} = ReducedOrbit.position_velocity(model, epoch, frame: :gcrs)
          assert_vec3(state.velocity, vel["gcrs_m_s"], 1.0e-9, [:vx_m_s, :vy_m_s, :vz_m_s])
        end
      end
    end

    test "drift/3 errors match the Python source-backed drift reference fixture", %{
      golden: golden
    } do
      for {_name, c} <- golden["cases"] do
        assert {:ok, model} = c["fit"]["map"] |> dehex_map() |> ReducedOrbit.from_map()
        assert {:ok, drift} = ReducedOrbit.drift(model, samples(c), threshold_m: 1.0e9)

        assert length(drift.per_epoch) == length(c["drift"]["per_epoch"])
        assert_in_delta drift.max_m, h(c["drift"]["max_m"]), 100.0
        assert_in_delta drift.rms_m, h(c["drift"]["rms_m"]), 100.0

        for {got, exp} <- Enum.zip(drift.per_epoch, c["drift"]["per_epoch"]) do
          assert got.epoch == NaiveDateTime.from_iso8601!(exp["epoch"])
          assert_in_delta got.error_m, h(exp["error_m"]), 100.0
        end
      end
    end

    test "TLE/SGP4 source fit matches the Python sgp4 + Astropy/scipy reference fixture", %{
      golden: golden
    } do
      c = golden["tle_sgp4"]
      {:ok, tle} = Sidereon.Format.TLE.parse(c["tle"]["line1"], c["tle"]["line2"])
      fit_end = NaiveDateTime.from_iso8601!("2018-07-04T01:30:00")

      assert {:ok, fit} =
               ReducedOrbit.fit(tle,
                 window: {NaiveDateTime.from_iso8601!("2018-07-04T00:00:00"), fit_end},
                 cadence_s: 120,
                 model: :eccentric_secular
               )

      assert fit.model == "eccentric_secular"
      assert fit.time_scale == "UTC"
      assert fit.fit.n_samples == c["fit"]["stats"]["n_samples"]
      assert fit.fit.requested == c["fit"]["stats"]["n_samples"]

      assert_in_delta fit.a_m, h(tle_element(c, "a_m")), 0.01
      assert_in_delta fit.e, h(tle_element(c, "e")), 1.0e-9
      assert_in_delta fit.h, h(tle_element(c, "h")), 1.0e-9
      assert_in_delta fit.k, h(tle_element(c, "k")), 1.0e-9
      assert_in_delta fit.i_rad, h(tle_element(c, "i_rad")), 1.0e-8
      assert_in_delta fit.raan_rad, h(tle_element(c, "raan_rad")), 1.0e-8
      assert_in_delta fit.raan_rate_rad_s, h(tle_element(c, "raan_rate_rad_s")), 1.0e-11
      assert_in_delta fit.arg_lat_rad, h(tle_element(c, "arg_lat_rad")), 1.0e-8
      assert_in_delta fit.mean_motion_rad_s, h(tle_element(c, "mean_motion_rad_s")), 1.0e-11
      assert_in_delta fit.fit.rms_m, h(c["fit"]["stats"]["rms_m"]), 0.1
      assert_in_delta fit.fit.max_m, h(c["fit"]["stats"]["max_m"]), 0.1
    end

    test "TLE/SGP4 source drift matches the Python source-backed drift reference fixture", %{
      golden: golden
    } do
      c = golden["tle_sgp4"]
      {:ok, tle} = Sidereon.Format.TLE.parse(c["tle"]["line1"], c["tle"]["line2"])
      t0 = NaiveDateTime.from_iso8601!("2018-07-04T00:00:00")
      fit_end = NaiveDateTime.from_iso8601!("2018-07-04T01:30:00")
      drift_end = NaiveDateTime.from_iso8601!("2018-07-04T04:00:00")

      assert {:ok, fit} =
               ReducedOrbit.fit(tle,
                 window: {t0, fit_end},
                 cadence_s: 120,
                 model: :eccentric_secular
               )

      assert {:ok, drift} =
               ReducedOrbit.drift(fit, tle,
                 window: {t0, drift_end},
                 cadence_s: 300,
                 threshold_m: 1.0e9
               )

      assert length(drift.per_epoch) == length(c["drift"]["per_epoch"])
      assert_in_delta drift.max_m, h(c["drift"]["max_m"]), 0.1
      assert_in_delta drift.rms_m, h(c["drift"]["rms_m"]), 0.1

      for {got, exp} <- Enum.zip(drift.per_epoch, c["drift"]["per_epoch"]) do
        assert NaiveDateTime.compare(got.epoch, NaiveDateTime.from_iso8601!(exp["epoch"])) == :eq
        assert_in_delta got.error_m, h(exp["error_m"]), 0.1
      end
    end
  end

  describe "Piecewise vs Astropy/scipy reference fixture" do
    test "fit/2 segment count and query positions match the independent piecewise fit", %{
      golden: golden
    } do
      c = golden["cases"]["eccentric"]
      pw = golden["piecewise"]

      assert {:ok, fit} =
               Piecewise.fit(samples(c),
                 window: {
                   NaiveDateTime.from_iso8601!(golden["epoch0"]),
                   NaiveDateTime.from_iso8601!(List.last(c["samples"])["epoch"])
                 },
                 model: :eccentric_secular,
                 segment_s: h(pw["segment_s"]),
                 time_scale: "UTC"
               )

      assert length(fit.segments) == length(pw["segments"])

      for pos <- pw["positions"] do
        epoch = NaiveDateTime.from_iso8601!(pos["epoch"])
        assert {:ok, got} = Piecewise.position(fit, epoch, frame: :gcrs)
        assert_vec3(got, pos["gcrs_m"], 150.0)
      end
    end
  end

  defp samples(c) do
    Enum.map(c["samples"], fn s ->
      [x, y, z] = Enum.map(s["ecef_m"], &h/1)
      {NaiveDateTime.from_iso8601!(s["epoch"]), {x, y, z}}
    end)
  end

  defp element(c, key), do: c["fit"]["map"]["elements"][key]
  defp tle_element(c, key), do: c["fit"]["map"]["elements"][key]

  defp assert_vec3(got, expected_hex, delta, keys \\ [:x_m, :y_m, :z_m]) do
    for {key, exp} <- Enum.zip(keys, expected_hex) do
      assert_in_delta Map.fetch!(got, key), h(exp), delta
    end
  end

  defp dehex_map(map) when is_map(map), do: Map.new(map, fn {k, v} -> {k, dehex_map(v)} end)
  defp dehex_map(list) when is_list(list), do: Enum.map(list, &dehex_map/1)

  defp dehex_map("0x" <> _ = hex), do: h(hex)
  defp dehex_map("-0x" <> _ = hex), do: h(hex)
  defp dehex_map(other), do: other

  defp h(hex), do: hex_to_float(hex)
end
