defmodule Sidereon.AnalyticPropagationTest do
  use ExUnit.Case, async: true

  alias Sidereon.Propagator.Analytic
  alias Sidereon.Propagator.Analytic.AnalyticPropagationError
  alias Sidereon.Propagator.Analytic.AnalyticTheory
  alias Sidereon.Propagator.Analytic.BrouwerLyddanePropagator
  alias Sidereon.Propagator.Analytic.CircularElements
  alias Sidereon.Propagator.Analytic.EcksteinHechlerPropagator
  alias Sidereon.Propagator.Analytic.KeplerianElements
  alias Sidereon.Propagator.Analytic.MeanConversionOptions
  alias Sidereon.Propagator.Analytic.MeanElements
  alias Sidereon.Propagator.Analytic.ZonalHarmonics
  alias Sidereon.Test.CoreGolden

  @circular %CircularElements{
    a_km: 7200.0,
    ex: 0.01,
    ey: -0.004,
    i_rad: 0.62,
    raan_rad: 1.2,
    mean_latitude_argument_rad: 0.15
  }
  @keplerian %KeplerianElements{
    a_km: 7200.0,
    e: 0.03,
    i_rad: 0.62,
    arg_perigee_rad: 0.22,
    raan_rad: 1.15,
    mean_anomaly_rad: 0.34
  }

  test "closed-form trajectories evaluate states and osculating elements at TDB epochs" do
    expected = CoreGolden.load("analytic_orbits.json")
    [mu, re, c20, c30, c40, c50, c60] = CoreGolden.f(expected["gravity"])

    gravity = %ZonalHarmonics{mu_km3_s2: mu, re_km: re, c20: c20, c30: c30, c40: c40, c50: c50, c60: c60}
    assert ZonalHarmonics.earth() === gravity
    assert AnalyticTheory.to_string(:brouwer_lyddane) === "Brouwer-Lyddane"
    assert AnalyticTheory.to_string(:eckstein_hechler) === "Eckstein-Hechler"

    assert {:ok, eh} = EcksteinHechlerPropagator.from_mean_elements(10.0, @circular, gravity)
    assert {:ok, bl} = BrouwerLyddanePropagator.from_mean_elements(10.0, @keplerian, gravity, 1.0e-15)
    assert EcksteinHechlerPropagator.epoch_tdb_seconds(eh) === 10.0
    assert BrouwerLyddanePropagator.epoch_tdb_seconds(bl) === 10.0
    assert BrouwerLyddanePropagator.m2_rad_s2(bl) === 1.0e-15
    assert EcksteinHechlerPropagator.gravity(eh) === gravity
    assert BrouwerLyddanePropagator.gravity(bl) === gravity
    assert EcksteinHechlerPropagator.mean_elements(eh) === @circular
    assert BrouwerLyddanePropagator.mean_elements(bl) === @keplerian

    want_eh = state(expected["eh_state"])
    want_bl = state(expected["bl_state"])

    assert EcksteinHechlerPropagator.propagate(eh, 600.0) === {:ok, want_eh}
    assert BrouwerLyddanePropagator.propagate(bl, 600.0) === {:ok, want_bl}
    assert EcksteinHechlerPropagator.ephemeris(eh, [600.0]) === {:ok, [want_eh]}
    assert BrouwerLyddanePropagator.ephemeris(bl, [600.0]) === {:ok, [want_bl]}

    assert EcksteinHechlerPropagator.osculating_elements(eh, 600.0) === {:ok, circular(expected["eh_osc"])}
    assert BrouwerLyddanePropagator.osculating_elements(bl, 600.0) === {:ok, keplerian(expected["bl_osc"])}

    assert Analytic.eckstein_hechler_osculating_elements(@circular, gravity) ===
             {:ok, circular(expected["eh_initial_osc"])}

    assert Analytic.brouwer_lyddane_osculating_elements(@keplerian, gravity) ===
             {:ok, keplerian(expected["bl_initial_osc"])}
  end

  test "Cartesian and mean conversions use the model-specific element types" do
    expected = CoreGolden.load("analytic_orbits.json")
    gravity = ZonalHarmonics.earth()
    mu = gravity.mu_km3_s2
    circ_pos = CoreGolden.tuple3(expected["circular_position"])
    circ_vel = CoreGolden.tuple3(expected["circular_velocity"])
    kep_pos = CoreGolden.tuple3(expected["keplerian_position"])
    kep_vel = CoreGolden.tuple3(expected["keplerian_velocity"])

    assert CircularElements.to_cartesian(@circular, mu) === {:ok, {circ_pos, circ_vel}}
    assert KeplerianElements.to_cartesian(@keplerian, mu) === {:ok, {kep_pos, kep_vel}}

    assert CircularElements.from_cartesian(circ_pos, circ_vel, mu) ===
             {:ok, circular(expected["circular_from_cartesian"])}

    assert KeplerianElements.from_cartesian(kep_pos, kep_vel, mu) ===
             {:ok, keplerian(expected["keplerian_from_cartesian"])}

    assert CircularElements.eccentricity(@circular) === CoreGolden.f(expected["eccentricity"])

    eh_opts = MeanConversionOptions.eckstein_hechler_default()
    bl_opts = MeanConversionOptions.brouwer_lyddane_default()
    assert eh_opts === %MeanConversionOptions{tolerance: 1.0e-11, max_iterations: 100}
    assert bl_opts === %MeanConversionOptions{tolerance: 1.0e-13, max_iterations: 200}

    initial = {10.0, circ_pos, circ_vel}
    [eh_elements, eh_iterations] = expected["eh_mean"]
    [bl_elements, bl_iterations] = expected["bl_mean"]
    want_eh = circular(eh_elements)
    want_bl = keplerian(bl_elements)

    assert Analytic.eckstein_hechler_mean_elements(initial, gravity, eh_opts) ===
             {:ok, %MeanElements{elements: want_eh, iterations: eh_iterations}}

    assert Analytic.brouwer_lyddane_mean_elements(initial, gravity, bl_opts) ===
             {:ok, %MeanElements{elements: want_bl, iterations: bl_iterations}}

    assert {:ok, eh} = EcksteinHechlerPropagator.new(initial, gravity, eh_opts)
    assert {:ok, bl} = BrouwerLyddanePropagator.new(initial, gravity, 0.0, bl_opts)
    assert EcksteinHechlerPropagator.mean_elements(eh) === want_eh
    assert BrouwerLyddanePropagator.mean_elements(bl) === want_bl
  end

  test "analytic domain errors name rejected orbital elements and values" do
    gravity = ZonalHarmonics.earth()

    assert {:error, %AnalyticPropagationError{kind: :nearly_equatorial, detail: %{inclination_rad: +0.0}}} =
             EcksteinHechlerPropagator.from_mean_elements(0.0, %{@circular | i_rad: 0.0}, gravity)

    assert {:error,
            %AnalyticPropagationError{
              kind: :inside_reference_sphere,
              detail: %{
                semi_major_axis_km: 1000.0,
                reference_radius_km: radius
              }
            }} =
             BrouwerLyddanePropagator.from_mean_elements(0.0, %{@keplerian | a_km: 1000.0}, gravity, 0.0)

    assert radius === gravity.re_km

    assert {:error, %AnalyticPropagationError{kind: :eccentricity_too_large, detail: %{eccentricity: 0.25, limit: 0.1}}} =
             Analytic.eckstein_hechler_osculating_elements(%{@circular | ex: 0.25, ey: 0.0}, gravity)

    assert {:error, %AnalyticPropagationError{kind: :not_elliptic, detail: %{field: "elements"}}} =
             KeplerianElements.to_cartesian(%{@keplerian | e: 1.0}, gravity.mu_km3_s2)
  end

  test "element conversions refuse retrograde equatorial states and exhausted convergence" do
    gravity = ZonalHarmonics.earth()
    options = %MeanConversionOptions{tolerance: 1.0e-13, max_iterations: 1}

    assert {:error,
            %AnalyticPropagationError{kind: :retrograde_equatorial, detail: %{inclination_rad: 3.141592653589793}}} =
             Analytic.brouwer_lyddane_mean_elements({0.0, {7000.0, 0.0, 0.0}, {0.0, -7.546, 0.0}}, gravity, options)

    assert {:error, %AnalyticPropagationError{kind: :near_critical_inclination, detail: %{inclination_rad: 1.107}}} =
             Analytic.eckstein_hechler_osculating_elements(%{@circular | i_rad: 1.107}, gravity)

    expected = CoreGolden.load("analytic_orbits.json")
    initial = {10.0, CoreGolden.tuple3(expected["circular_position"]), CoreGolden.tuple3(expected["circular_velocity"])}

    assert {:error,
            %AnalyticPropagationError{
              kind: :mean_elements_not_converged,
              detail: %{theory: :brouwer_lyddane, iterations: 1}
            }} =
             Analytic.brouwer_lyddane_mean_elements(initial, gravity, options)
  end

  test "gravity validation preserves the rejected parameter" do
    gravity = %{ZonalHarmonics.earth() | c20: 0.0}

    assert {:error, %AnalyticPropagationError{kind: :invalid_parameter, detail: details} = error} =
             Analytic.eckstein_hechler_osculating_elements(@circular, gravity)

    assert details == %{field: "c20", reason: "must be nonzero: both theories expand in J2"}
    assert to_string(error) == "invalid c20: must be nonzero: both theories expand in J2"
  end

  test "the Kepler solver reports an eccentric anomaly that does not converge" do
    elements = %{@keplerian | e: 0.9999999995343387, mean_anomaly_rad: 2.842170943040401e-14}

    assert {:error, %AnalyticPropagationError{kind: :kepler_not_converged, detail: %{field: "eccentric anomaly"}}} =
             KeplerianElements.to_cartesian(elements, ZonalHarmonics.earth().mu_km3_s2)
  end

  test "an out-of-range secular term is refused with the theory and quantity" do
    gravity = ZonalHarmonics.earth()
    assert {:ok, bl} = BrouwerLyddanePropagator.from_mean_elements(10.0, @keplerian, gravity, 1.0e-15)

    assert {:error,
            %AnalyticPropagationError{kind: :non_finite_result, detail: %{theory: :brouwer_lyddane, field: "a_km"}}} =
             BrouwerLyddanePropagator.propagate(bl, 1.0e200)
  end

  defp state([epoch, position, velocity]),
    do: {CoreGolden.f(epoch), CoreGolden.tuple3(position), CoreGolden.tuple3(velocity)}

  defp circular(values) do
    [a, ex, ey, i, raan, u] = CoreGolden.f(values)
    %CircularElements{a_km: a, ex: ex, ey: ey, i_rad: i, raan_rad: raan, mean_latitude_argument_rad: u}
  end

  defp keplerian(values) do
    [a, e, i, arg, raan, m] = CoreGolden.f(values)
    %KeplerianElements{a_km: a, e: e, i_rad: i, arg_perigee_rad: arg, raan_rad: raan, mean_anomaly_rad: m}
  end
end
