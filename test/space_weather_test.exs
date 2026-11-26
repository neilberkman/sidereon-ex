defmodule Sidereon.SpaceWeatherTest do
  use ExUnit.Case, async: true

  alias Sidereon.Astro.Relative.State
  alias Sidereon.Drag
  alias Sidereon.Drag.DecayError
  alias Sidereon.GNSS.Data
  alias Sidereon.Iers2010EarthOrientationProvider, as: Iers
  alias Sidereon.Iers2010EarthOrientationProvider.Iers2010EopSample
  alias Sidereon.Propagator.PropagationContext
  alias Sidereon.SpaceWeather
  alias Sidereon.Test.CoreGolden

  @csv """
  DATE,BSRN,ND,KP1,KP2,KP3,KP4,KP5,KP6,KP7,KP8,KP_SUM,AP1,AP2,AP3,AP4,AP5,AP6,AP7,AP8,AP_AVG,CP,C9,ISN,F10.7_OBS,F10.7_ADJ,F10.7_DATA_TYPE,F10.7_OBS_CENTER81,F10.7_OBS_LAST81,F10.7_ADJ_CENTER81,F10.7_ADJ_LAST81
  2000-01-01,1,1,10,10,10,10,10,10,10,10,80,4,4,4,4,4,4,4,4,4,0.0,0,10,100.0,101.0,OBS,99.0,98.0,102.0,103.0
  2000-01-02,1,2,20,20,20,20,20,20,20,20,160,5,6,7,8,9,10,11,12,8,0.1,1,11,110.0,111.0,OBS,109.0,108.0,112.0,113.0
  2000-01-03,1,3,30,30,30,30,30,30,30,30,240,13,14,15,16,17,18,19,20,16,0.2,2,12,120.0,121.0,OBS,119.0,118.0,122.0,123.0
  """

  test "decay controls are validated with fixed and sourced space weather" do
    state = %State{epoch_tdb_seconds: 0.0, position_km: {7000.0, 0.0, 0.0}, velocity_km_s: {0.0, 7.5, 0.0}}
    assert {:ok, drag} = Drag.from_bc_factor(0.02)
    assert {:ok, source} = SpaceWeather.parse(@csv)
    context = PropagationContext.new()
    options = [max_duration_s: 0.0]

    assert {:error, %DecayError{kind: :invalid_config, detail: %{field: "max_duration_s"}}} =
             Drag.estimate_decay_with_context(state, drag, context, options)

    assert {:error, %DecayError{kind: :invalid_config, detail: %{field: "max_duration_s"}}} =
             Drag.estimate_decay_with_source_and_context(state, drag, source, context, options)

    expected =
      {:error,
       %DecayError{kind: :invalid_input, detail: %{reason: "unknown force model"}, message: "unknown force model"}}

    assert Drag.estimate_decay_with_context(state, drag, context, force_model: :unknown) === expected
    assert Drag.estimate_decay_with_source_and_context(state, drag, source, context, force_model: :unknown) === expected

    invalid_drag = %{drag | bc_factor_m2_kg: -1.0}

    expected =
      {:error,
       %DecayError{
         kind: :invalid_input,
         detail: %{reason: "bc_factor_m2_kg not positive"},
         message: "Invalid input: bc_factor_m2_kg not positive"
       }}

    assert Drag.estimate_decay_with_context(state, invalid_drag, context) === expected
    assert Drag.estimate_decay_with_source_and_context(state, invalid_drag, source, context) === expected

    assert Drag.estimate_decay(state, invalid_drag) === {:error, :invalid_input}
    assert Drag.estimate_decay(state, invalid_drag, space_weather_table: source) === {:error, :invalid_input}
  end

  test "decay results preserve initial reentry, scan limits and propagation failures" do
    context = PropagationContext.new()
    assert {:ok, drag} = Drag.from_bc_factor(0.02)
    assert {:ok, source} = SpaceWeather.parse(@csv)
    state = %State{epoch_tdb_seconds: 0.0, position_km: {7000.0, 0.0, 0.0}, velocity_km_s: {0.0, 7.5, 0.0}}
    expected = CoreGolden.load("numerical_orbits.json")["decay_initial_altitude"]

    for result <- [
          Drag.estimate_decay_with_context(state, drag, context, reentry_altitude_km: 1000.0),
          Drag.estimate_decay_with_source_and_context(state, drag, source, context, reentry_altitude_km: 1000.0)
        ] do
      assert result ===
               {:ok,
                %Drag.DecayEstimate{
                  time_to_decay_s: 0.0,
                  reentry_state: state,
                  reentry_altitude_km: CoreGolden.f(expected)
                }}
    end

    assert {:error, %DecayError{kind: :no_decay_within_horizon, detail: detail}} =
             Drag.estimate_decay_with_context(state, drag, context, scan_step_s: 1.0, max_duration_s: 1.0)

    assert detail === %{horizon_s: 1.0}

    assert {:error, %DecayError{kind: :scan_budget_exhausted, detail: detail}} =
             Drag.estimate_decay_with_context(state, drag, context,
               scan_step_s: 1.0,
               max_duration_s: 5.0,
               max_scan_samples: 1
             )

    assert detail === %{scanned_s: 1.0, samples: 1}

    centre = %{state | position_km: {0.0, 0.0, 0.0}}

    assert {:error, %DecayError{kind: :propagation, detail: %{source: error}}} =
             Drag.estimate_decay_with_context(centre, drag, context)

    assert error.kind === :numerical_failure
    assert error.detail === %{reason: "Zero position magnitude"}

    eop = %Iers2010EopSample{
      mjd_utc: 59_025,
      xp_arcsec: 0.0,
      yp_arcsec: 0.0,
      ut1_minus_utc_s: 0.0,
      lod_s: 0.0,
      dx_arcsec: 0.0,
      dy_arcsec: 0.0
    }

    assert {:ok, iers} = Iers.new([eop, %{eop | mjd_utc: 59_026}])
    context = PropagationContext.with_body_fixed_frame_provider(context, iers)

    assert {:error, %DecayError{kind: :propagation, detail: %{source: error}}} =
             Drag.estimate_decay_with_context(state, drag, context)

    assert error.kind === :ut1_outside_coverage
    assert error.detail === %{reason: :before_coverage}
  end

  setup do
    root = Path.join(System.tmp_dir!(), "sidereon-space-weather-test-#{System.unique_integer([:positive])}")
    File.rm_rf!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "parses and looks up NRLMSISE inputs" do
    assert {:ok, table} = SpaceWeather.parse(@csv)
    epoch = Sidereon.NIF.civil_j2000_seconds(2000, 1, 2, 12, 0, 0.0)

    assert {:ok, sample} = SpaceWeather.sample_at(table, epoch)
    assert sample.space_weather.f107 == 100.0
    assert sample.space_weather.f107a == 109.0
    assert sample.space_weather.ap == 8.0
    assert sample.class == :observed
    refute sample.ap_defaulted

    history_epoch = Sidereon.NIF.civil_j2000_seconds(2000, 1, 3, 12, 0, 0.0)
    assert {:ok, [16.0, 17.0, 16.0, 15.0, 14.0, 9.5, 4.125]} = SpaceWeather.ap_array_at(table, history_epoch)
    assert {:ok, coverage} = SpaceWeather.coverage(table)
    assert coverage.first_j2000_s < epoch
    assert coverage.end_j2000_s > epoch
  end

  test "Ap history carries the row class and substitutions under a policy" do
    assert {:ok, table} = SpaceWeather.parse(@csv)
    epoch = Sidereon.NIF.civil_j2000_seconds(2000, 1, 3, 12, 0, 0.0)

    assert {:ok, history} = SpaceWeather.ap_history_at_with_policy(table, epoch, %SpaceWeather.Policy{})
    assert {:ok, history.ap} == SpaceWeather.ap_array_at(table, epoch)
    assert history.class == :observed
    refute history.ap_defaulted
    assert history.bins_from_daily_ap == 0
  end

  test "the default policy is the core default and lenient/0 accepts every class" do
    policy = %SpaceWeather.Policy{}
    assert policy.require_geomagnetic
    refute policy.allow_not_observed
    assert policy.allow_interpolated
    assert policy.allow_daily_predicted
    assert policy.allow_monthly_predicted

    lenient = SpaceWeather.Policy.lenient()
    refute lenient.require_geomagnetic
    assert lenient.allow_not_observed
  end

  test "a row out of date order is kept, sorted into place and reported" do
    [header, first, second, third] = @csv |> String.trim_trailing() |> String.split("\n")
    shuffled = Enum.join([header, first, third, second], "\n") <> "\n"

    assert {:ok, table} = SpaceWeather.parse(shuffled)
    assert %{warnings: [_ | _]} = SpaceWeather.diagnostics(table)

    assert {:ok, sorted} = SpaceWeather.parse(@csv)
    assert %{skips: [], warnings: []} = SpaceWeather.diagnostics(sorted)

    epoch = Sidereon.NIF.civil_j2000_seconds(2000, 1, 3, 12, 0, 0.0)
    assert SpaceWeather.ap_array_at(table, epoch) == SpaceWeather.ap_array_at(sorted, epoch)
  end

  test "drag propagation reads a table under the policy it is given" do
    assert {:ok, table} = SpaceWeather.parse(@csv)
    assert {:ok, drag} = Sidereon.Drag.from_area_mass(2.2, 1.0, 100.0)
    state = {{6778.0, 0.0, 0.0}, {0.0, 7.6686, 0.0}}
    # 2000-01-02 18:00 TDB, inside the table with the day before it.
    opts = [forces: [:twobody], drag: drag, space_weather_table: table, epoch_tdb_seconds: 108_000.0]

    assert {:ok, default} = Sidereon.Propagator.propagate(state, 60.0, opts)

    assert {:ok, ^default} =
             Sidereon.Propagator.propagate(state, 60.0, [space_weather_policy: %SpaceWeather.Policy{}] ++ opts)

    # Every value the lookup reads is stated in the file, so the lenient policy
    # substitutes nothing and propagates identically.
    assert {:ok, ^default} =
             Sidereon.Propagator.propagate(state, 60.0, [space_weather_policy: SpaceWeather.Policy.lenient()] ++ opts)
  end

  test "fetch_space_weather is cache-first and offline-safe", %{root: root} do
    http_client = fn url, _opts ->
      assert String.ends_with?(url, "/SW-All.csv")
      {:ok, 200, @csv}
    end

    assert {:ok, table} = Data.fetch_space_weather(cache_dir: root, http_client: http_client)
    epoch = Sidereon.NIF.civil_j2000_seconds(2000, 1, 2, 12, 0, 0.0)
    assert {:ok, sw} = SpaceWeather.space_weather_at(table, epoch)
    assert sw.f107 == 100.0

    deny = fn _url, _opts -> flunk("fresh verified cache should avoid transport") end
    assert {:ok, cached} = Data.fetch_space_weather(cache_dir: root, offline: true, http_client: deny)
    assert {:ok, ^sw} = SpaceWeather.space_weather_at(cached, epoch)

    assert {:ok, relpath} = Data.space_weather_cache_relpath()
    path = Path.join(root, relpath)
    assert File.exists?(path <> ".provenance.json")
  end
end
