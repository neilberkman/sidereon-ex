defmodule Sidereon.ForceModelsTest do
  use ExUnit.Case, async: true

  alias Sidereon.Drag
  alias Sidereon.Forces
  alias Sidereon.Forces.AccelerationPartials
  alias Sidereon.Forces.CompositeForceModel
  alias Sidereon.Forces.EarthRadiationPressure
  alias Sidereon.Forces.Ecom1Coefficients
  alias Sidereon.Forces.Ecom1SolarRadiationPressure
  alias Sidereon.Forces.Ecom2D2b1Coefficients
  alias Sidereon.Forces.Ecom2D4b1Coefficients
  alias Sidereon.Forces.Ecom2SolarRadiationPressure
  alias Sidereon.Forces.EcomGeometry
  alias Sidereon.Forces.EmpiricalRtnAcceleration
  alias Sidereon.Forces.EmpiricalRtnAcceleration.EmpiricalHarmonic
  alias Sidereon.Forces.EmpiricalRtnAcceleration.RtnAxis
  alias Sidereon.Forces.ForceParameter
  alias Sidereon.Forces.PropagationError
  alias Sidereon.Forces.SolarRadiationPressure
  alias Sidereon.GNSS.Attitude.DybAxes
  alias Sidereon.Propagator
  alias Sidereon.Propagator.DenseOutput
  alias Sidereon.Propagator.DenseOutputError
  alias Sidereon.Propagator.IntegratorOptions
  alias Sidereon.Propagator.PropagationContext
  alias Sidereon.Propagator.VariationalEpoch
  alias Sidereon.Propagator.VariationalEquations
  alias Sidereon.Propagator.VariationalState
  alias Sidereon.SpaceWeather
  alias Sidereon.Test.CoreGolden

  @zero {0.0, 0.0, 0.0}
  @zeros [@zero, @zero, @zero]

  test "estimable parameter evaluation, derivatives and composition" do
    assert {:ok, empirical} =
             EmpiricalRtnAcceleration.with_term(EmpiricalRtnAcceleration.new(), :radial, :constant, 3.0)

    param = %ForceParameter{name: "empirical.radial.constant", value: 3.0}
    state = {0.0, {1.0, 0.0, 0.0}, {0.0, 1.0, 0.0}}

    assert Forces.parameters(empirical) === {:ok, [param]}
    assert Forces.parameter_count(empirical) === {:ok, 1}
    assert Forces.parameters(:two_body) === {:ok, []}
    assert Forces.parameter_count(:j2) === {:ok, 0}
    assert Forces.acceleration(empirical, state) === {:ok, {3.0, 0.0, 0.0}}
    assert Forces.acceleration_with_parameters(empirical, [4.0], state) === {:ok, {4.0, 0.0, 0.0}}
    assert Forces.parameter_partials(empirical, [4.0], state) === {:ok, [{1.0, 0.0, 0.0}]}

    jacobian = [{0.0, 0.0, 0.0}, {0.0, 4.0, 0.0}, {0.0, 0.0, 4.0}]

    assert {:ok, %AccelerationPartials{wrt_position: ^jacobian, wrt_velocity: zero}} =
             Forces.acceleration_partials(empirical, [4.0], state)

    assert zero === @zeros

    assert AccelerationPartials.zeros() === %AccelerationPartials{wrt_position: @zeros, wrt_velocity: @zeros}

    assert AccelerationPartials.position_only(jacobian) ===
             %AccelerationPartials{wrt_position: jacobian, wrt_velocity: @zeros}

    assert EmpiricalRtnAcceleration.constant_terms().terms ===
             [{:radial, :constant, 0.0}, {:along_track, :constant, 0.0}, {:cross_track, :constant, 0.0}]

    assert EmpiricalRtnAcceleration.with_zero_terms([{:cross_track, :sine}]).terms === [{:cross_track, :sine, 0.0}]
    assert length(EmpiricalRtnAcceleration.all_terms().terms) == 9
    assert EmpiricalRtnAcceleration.parameter_name(:cross_track, :sine) == "empirical.cross.sin"
    assert EmpiricalRtnAcceleration.coefficient_km_s2(empirical, :radial, :constant) === {:ok, 3.0}
    assert EmpiricalRtnAcceleration.coefficient_km_s2(empirical, :radial, :sine) === {:ok, nil}

    assert RtnAxis.all() == [:radial, :along_track, :cross_track]
    assert RtnAxis.compare(:radial, :cross_track) == :lt
    assert EmpiricalHarmonic.all() == [:constant, :cosine, :sine]
    assert EmpiricalHarmonic.compare(:sine, :cosine) == :gt

    composite = CompositeForceModel.new() |> CompositeForceModel.add(empirical) |> CompositeForceModel.add(empirical)
    assert Forces.acceleration(composite, state) === {:ok, {6.0, 0.0, 0.0}}
    assert Forces.parameters(composite) === {:ok, [param, param]}

    assert {:error, %PropagationError{kind: :invalid_input}} =
             Forces.acceleration_with_parameters(empirical, [], state)
  end

  test "ECOM coefficient order and named model constructors" do
    assert Forces.ecom1_coefficient_count() == 9
    assert Forces.ecom2_d2b1_coefficient_count() == 7
    assert Forces.ecom2_d4b1_coefficient_count() == 9

    d2b1 = [1.0e-9, 0.0, 0.0, 2.0e-9, 0.0, 0.0, 0.0]
    assert Ecom2D2b1Coefficients.from_array(d2b1) === %Ecom2D2b1Coefficients{b0: 1.0e-9, d0: 2.0e-9}
    assert Ecom2D2b1Coefficients.to_array(%Ecom2D2b1Coefficients{b0: 1.0e-9, d0: 2.0e-9}) === d2b1
    assert Ecom2D2b1Coefficients.names() == ~w(B0 B1c B1s D0 D2c D2s Y0)

    assert Ecom2D2b1Coefficients.parameter_names() ==
             ~w(ecom2.b0 ecom2.b1c ecom2.b1s ecom2.d0 ecom2.d2c ecom2.d2s ecom2.y0)

    assert Ecom2SolarRadiationPressure.new(1, 1, d2b1) ===
             {:ok,
              %Ecom2SolarRadiationPressure{
                n_d: 1,
                n_b: 1,
                coefficients: d2b1,
                shadow_function: :apparent_disc,
                earth_shadow_model: :wgs84_oblate,
                moon_eclipse_enabled: true
              }}

    assert Ecom2SolarRadiationPressure.coefficient_count(1, 1) == 7

    assert {:ok, %Ecom2SolarRadiationPressure{n_d: 1, n_b: 1, coefficients: ^d2b1}} =
             Ecom2SolarRadiationPressure.d2b1(%Ecom2D2b1Coefficients{b0: 1.0e-9, d0: 2.0e-9})

    d4b1 = [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0]

    assert Ecom2D4b1Coefficients.from_array(d4b1) ===
             %Ecom2D4b1Coefficients{
               b0: 1.0,
               b1c: 2.0,
               b1s: 3.0,
               d0: 4.0,
               d2c: 5.0,
               d4c: 6.0,
               d2s: 7.0,
               d4s: 8.0,
               y0: 9.0
             }

    assert Ecom2D4b1Coefficients.to_array(%Ecom2D4b1Coefficients{
             b0: 1.0,
             b1c: 2.0,
             b1s: 3.0,
             d0: 4.0,
             d2c: 5.0,
             d4c: 6.0,
             d2s: 7.0,
             d4s: 8.0,
             y0: 9.0
           }) === d4b1

    assert Ecom2D4b1Coefficients.names() == ~w(B0 B1c B1s D0 D2c D4c D2s D4s Y0)
    names = ~w(ecom2.b0 ecom2.b1c ecom2.b1s ecom2.d0 ecom2.d2c ecom2.d4c ecom2.d2s ecom2.d4s ecom2.y0)
    assert Ecom2D4b1Coefficients.parameter_names() == names
    assert Ecom2SolarRadiationPressure.parameter_names(2, 1) == {:ok, names}

    assert {:ok, %Ecom2SolarRadiationPressure{n_d: 2, n_b: 1, coefficients: ^d4b1}} =
             Ecom2SolarRadiationPressure.d4b1(%Ecom2D4b1Coefficients{
               b0: 1.0,
               b1c: 2.0,
               b1s: 3.0,
               d0: 4.0,
               d2c: 5.0,
               d4c: 6.0,
               d2s: 7.0,
               d4s: 8.0,
               y0: 9.0
             })

    assert Ecom1Coefficients.from_array(d4b1) === %Ecom1Coefficients{
             d0: 1.0,
             dc: 2.0,
             ds: 3.0,
             y0: 4.0,
             yc: 5.0,
             ys: 6.0,
             b0: 7.0,
             bc: 8.0,
             bs: 9.0
           }

    assert Ecom1Coefficients.to_array(%Ecom1Coefficients{
             d0: 1.0,
             dc: 2.0,
             ds: 3.0,
             y0: 4.0,
             yc: 5.0,
             ys: 6.0,
             b0: 7.0,
             bc: 8.0,
             bs: 9.0
           }) === d4b1

    assert Ecom1Coefficients.names() == ~w(D0 Dc Ds Y0 Yc Ys B0 Bc Bs)

    assert Ecom1Coefficients.parameter_names() ==
             ~w(ecom1.d0 ecom1.dc ecom1.ds ecom1.y0 ecom1.yc ecom1.ys ecom1.b0 ecom1.bc ecom1.bs)
  end

  test "solar, Earth and ECOM radiation use explicit occultation options" do
    expected = CoreGolden.load("gravity_and_radiation.json")
    {_epoch, position, velocity} = initial = state(expected["initial"])
    sun = CoreGolden.tuple3(expected["sun"])
    moon = CoreGolden.tuple3(expected["moon"])

    assert {:ok, srp} = SolarRadiationPressure.new(1.3, 0.02)
    assert srp.shadow_function == :apparent_disc
    assert srp.earth_shadow_model == :wgs84_oblate
    assert srp.moon_eclipse_enabled
    conical = SolarRadiationPressure.with_shadow_function(srp, :conical)
    refute conical.moon_eclipse_enabled
    assert SolarRadiationPressure.with_moon_eclipse(conical, true) === srp
    assert SolarRadiationPressure.cr_parameter() == "srp.cr"
    assert SolarRadiationPressure.au_km(srp) === {:ok, 149_597_870.7}
    assert Forces.acceleration(:third_body, initial) === {:ok, CoreGolden.tuple3(expected["third_body_acceleration"])}
    assert Forces.acceleration(srp, initial) === {:ok, CoreGolden.tuple3(expected["srp_acceleration"])}

    assert SolarRadiationPressure.acceleration_with_sun_moon(srp, position, sun, moon) ===
             {:ok, CoreGolden.tuple3(expected["srp_explicit"])}

    srp =
      srp
      |> SolarRadiationPressure.with_shadow_function(:conical)
      |> SolarRadiationPressure.with_earth_shadow_model(:spherical)
      |> SolarRadiationPressure.with_moon_eclipse(false)

    assert %{shadow_function: :conical, earth_shadow_model: :spherical, moon_eclipse_enabled: false} = srp

    assert {:ok, earth} = EarthRadiationPressure.new(1.3, 0.02)
    refute earth.moon_eclipse_enabled
    assert EarthRadiationPressure.with_moon_eclipse(earth, true).moon_eclipse_enabled

    assert EarthRadiationPressure.acceleration_with_sun_moon(earth, initial, sun, moon) ===
             {:ok, CoreGolden.tuple3(expected["earth_explicit"])}

    assert {:ok, ecom1} = Ecom1SolarRadiationPressure.new(%Ecom1Coefficients{d0: 1.3e-9, dc: -3.0e-10, y0: 9.0e-11})
    assert {:ok, ecom2} = Ecom2SolarRadiationPressure.d2b1(%Ecom2D2b1Coefficients{b0: 1.0e-9, d0: 2.0e-9})

    for {module, model, fields} <- [
          {Ecom1SolarRadiationPressure, ecom1, expected["ecom1"]},
          {Ecom2SolarRadiationPressure, ecom2, expected["ecom2"]}
        ] do
      conical = module.with_shadow_function(model, :conical)
      refute conical.moon_eclipse_enabled
      assert module.with_moon_eclipse(conical, true) === model
      assert module.with_earth_shadow_model(model, :spherical).earth_shadow_model == :spherical
      sun_only = module.with_moon_eclipse(model, false)

      for {configured, args, acceleration, partials, coefficients} <- [
            {sun_only, [position, velocity, sun], :acceleration_with_sun, :acceleration_partials_with_sun,
             :parameter_partials_with_sun},
            {model, [position, velocity, sun, moon], :acceleration_with_sun_moon, :acceleration_partials_with_sun_moon,
             :parameter_partials_with_sun_moon}
          ] do
        args = [configured | args]
        assert apply(module, acceleration, args) === {:ok, CoreGolden.tuple3(fields[Atom.to_string(acceleration)])}

        want = fields[Atom.to_string(partials)]

        assert apply(module, partials, args) ===
                 {:ok,
                  %AccelerationPartials{
                    wrt_position: Enum.map(want["wrt_position"], &CoreGolden.tuple3/1),
                    wrt_velocity: Enum.map(want["wrt_velocity"], &CoreGolden.tuple3/1)
                  }}

        assert apply(module, coefficients, args) ===
                 {:ok, Enum.map(fields[Atom.to_string(coefficients)], &CoreGolden.tuple3/1)}
      end
    end

    assert Forces.ecom_geometry(position, velocity, sun) === {:ok, geometry(expected["geometry"])}

    assert Forces.ecom_geometry_with_shadow(position, velocity, sun, moon, :spherical) ===
             {:ok, geometry(expected["geometry_with_shadow"])}

    assert {:error,
            %PropagationError{
              kind: :invalid_input,
              detail: %{reason: "ECOM1 lunar eclipse is enabled; call acceleration_with_sun_moon"}
            }} = Ecom1SolarRadiationPressure.acceleration_with_sun(ecom1, position, velocity, sun)

    assert {:error,
            %PropagationError{
              kind: :invalid_input,
              detail: %{reason: "ECOM2 lunar eclipse is enabled; call acceleration_with_sun_moon"}
            }} = Ecom2SolarRadiationPressure.acceleration_with_sun(ecom2, position, velocity, sun)
  end

  test "force-model failures retain the rejected eclipse input" do
    assert {:ok, model} = SolarRadiationPressure.new(1.25, 0.02)

    reason = "Could not decode field on position 1"

    assert Forces.parameters(%{model | cr: :invalid}) ===
             {:error, %PropagationError{kind: :invalid_input, detail: %{reason: reason}, message: reason}}

    assert {:error, %PropagationError{kind: :force_model_failure, detail: detail}} =
             SolarRadiationPressure.acceleration_with_sun_moon(
               model,
               {7000.0, 0.0, 0.0},
               {1.5e8, 0.0, 0.0},
               {0.0, 0.0, 0.0}
             )

    assert detail === %{reason: "eclipse: invalid eclipse input moon_pos: zero vector"}
  end

  test "TT trajectory, state transition and UT1 drag values" do
    expected = CoreGolden.load("numerical_orbits.json")
    initial = {0.0, {7000.0, 0.0, 0.0}, {0.0, 7.546049108166282, 0.0}}
    epoch = VariationalEpoch.from_tdb_seconds(0.0, 30.0)

    assert epoch === %VariationalEpoch{
             tdb_j2000_s: 30.0,
             elapsed_tt_s: CoreGolden.f(expected["variational_elapsed_tt_s"])
           }

    assert IntegratorOptions.default() === %IntegratorOptions{
             abs_tol: 1.0e-9,
             rel_tol: 1.0e-12,
             min_step: 1.0e-6,
             max_step: 3600.0,
             initial_step: 60.0,
             max_steps: 1_000_000
           }

    equations = %VariationalEquations{force: :two_body, parameters: [], sensitivity_parameters: []}
    want = state(expected["variational_state"])

    assert Propagator.propagate_variational(initial, [epoch], equations) ===
             {:ok,
              [
                %VariationalState{
                  state: want,
                  state_transition: CoreGolden.f(expected["state_transition"]),
                  sensitivity: [[], [], [], [], [], []]
                }
              ]}

    for {key, value} <- [force_model: :two_body, mu_km3_s2: 400_000] do
      assert {:error, %PropagationError{kind: :unsupported_option, detail: %{reason: {:unsupported_option, ^key}}}} =
               Propagator.propagate_state(initial, [30.0], [{key, value}])
    end

    assert {:ok, drag} = Drag.from_bc_factor(0.02)
    assert Forces.acceleration(drag, state(expected["drag_state"])) === {:ok, CoreGolden.tuple3(expected["drag_accel"])}

    {start, _, _} = drag_state = state(expected["drag_state"])
    assert {:ok, srp} = SolarRadiationPressure.new(1.3, 0.02)

    context = PropagationContext.with_body_fixed_frame_provider(PropagationContext.new(), :tdb)

    assert Propagator.propagate_state(drag_state, [start + 120.0],
             context: context,
             forces: [:composite, {:geopotential, 8, 8}, :third_body, :relativity, srp],
             drag: drag
           ) ===
             {:ok, [state(expected["perturbed_state"])]}

    context = PropagationContext.new()
    identity = for row <- 0..5, do: for(col <- 0..5, do: if(col == row, do: 1.0, else: 0.0))

    assert {:ok,
            [
              %{
                state: %{epoch_tdb_seconds: +0.0, position_km: {7000.0, +0.0, +0.0}},
                covariance: ^identity,
                frame: "inertial"
              }
            ]} =
             Propagator.propagate_covariance_with_context(
               {elem(initial, 1), elem(initial, 2)},
               identity,
               [0.0],
               context
             )

    assert {:ok, earth} = EarthRadiationPressure.new(1.3, 0.02)

    assert Propagator.propagate_state(initial, [30.0], forces: [earth]) ===
             {:ok, [state(expected["earth_radiation_state"])]}

    assert Propagator.state_transition_matrix_to_with_context(initial, 0.0, context) === {:ok, identity}

    assert Propagator.propagate_state_with_covariance_with_context(initial, identity, 0.0, context) ===
             {:ok, {initial, identity}}

    assert {:error, %PropagationError{kind: :invalid_input}} =
             Propagator.propagate_variational(initial, [epoch], %{equations | sensitivity_parameters: [0]})
  end

  test "additional forces follow gravity and fixed or table-driven drag" do
    expected = CoreGolden.load("numerical_orbits.json")["additional_forces"]
    initial = {start, _, _} = state(expected["initial"])
    {:ok, radial} = EmpiricalRtnAcceleration.with_term(EmpiricalRtnAcceleration.new(), :radial, :constant, 1.0e-6)
    {:ok, cross} = EmpiricalRtnAcceleration.with_term(EmpiricalRtnAcceleration.new(), :cross_track, :constant, 3.0e-6)
    {:ok, drag} = Drag.from_bc_factor(0.02)
    weather = File.read!(Path.join(__DIR__, "fixtures/space_weather/drag_arc.csv"))
    {:ok, table} = SpaceWeather.parse(weather)
    integration = %{IntegratorOptions.default() | dense_output: true}
    opts = [forces: [:twobody, :j2], additional_forces: [radial, cross], drag: drag, integration: integration]
    target = start + 60.0

    assert Propagator.propagate_state(initial, [target], opts) === {:ok, [state(expected["fixed"])]}
    opts = Keyword.put(opts, :space_weather_table, table)
    assert Propagator.propagate_state(initial, [target], opts) === {:ok, [state(expected["table"])]}
    assert {:ok, result} = Propagator.propagate_to_with_context(initial, target, opts)
    assert result.final_state === state(expected["table"])

    assert DenseOutput.coverage(result.dense) === List.to_tuple(CoreGolden.f(expected["coverage"]))
    assert DenseOutput.eval(result.dense, start + 30.0) === {:ok, state(expected["dense_sample"])}

    assert {:error,
            %DenseOutputError{
              kind: :output_out_of_range,
              detail: %{t: 108_061.0, t_min: 108_000.0, t_max: 108_060.0}
            }} = DenseOutput.eval(result.dense, target + 1.0)

    [query, first, last, fraction] = CoreGolden.f(expected["segment_refusal"])

    assert {:error,
            %DenseOutputError{
              kind: :segment_out_of_range,
              detail: %{t: ^query, t_start: ^first, t_end: ^last, theta: ^fraction}
            }} =
             DenseOutput.eval(result.dense, query)

    assert {:ok, backward} = Propagator.propagate_to_with_context(initial, start - 60.0, opts)
    assert DenseOutput.coverage(backward.dense) === List.to_tuple(CoreGolden.f(expected["backward_coverage"]))

    assert {:ok, empty} = Propagator.propagate_to_with_context(initial, start, opts)
    assert DenseOutput.coverage(empty.dense) === nil
    assert {:error, %DenseOutputError{kind: :empty, detail: %{}}} = DenseOutput.eval(empty.dense, start)

    assert {:error, %PropagationError{kind: :invalid_input, detail: %{reason: "space weather source without drag"}}} =
             Propagator.propagate_state(initial, [target], Keyword.delete(opts, :drag))
  end

  test "relative propagation preserves force-token refusals and ignores unknown options" do
    expected = CoreGolden.load("numerical_orbits.json")
    initial = {{7000.0, 0.0, 0.0}, {0.0, 7.546049108166282, 0.0}}
    {_, position, velocity} = state(expected["legacy_twobody"])

    assert Propagator.propagate(initial, 60.0,
             force_model: :unused,
             mu_km3_s2: :unused,
             additional_forces: :unused,
             context: :unused,
             de_ephemeris: :unused,
             forces: [:unrecognized]
           ) === {:ok, {position, velocity}}

    {:ok, table} = SpaceWeather.parse(File.read!(Path.join(__DIR__, "fixtures/space_weather/drag_arc.csv")))

    assert Propagator.propagate(initial, 60.0, space_weather_table: table) ===
             {:error, :space_weather_source_without_drag}

    invalid = [forces: ["srp:1.2"]]
    assert Propagator.propagate(initial, 60.0, invalid) === {:error, "srp token must be srp:cr:area_to_mass"}

    assert Propagator.propagate(initial, 60.0, [space_weather_table: table] ++ invalid) ===
             {:error, :space_weather_source_without_drag}

    {_, position, velocity} = state(expected["legacy_tide"])

    assert Propagator.propagate(initial, 60.0, forces: [:solid_earth_tide, :solid_earth_pole_tide]) ===
             {:ok, {position, velocity}}
  end

  test "numerical tide propagation requires an explicit body-fixed frame provider" do
    expected = CoreGolden.load("numerical_orbits.json")["de_tides"]
    {epoch, _, _} = initial = state(expected["initial"])
    target = epoch + 60.0
    {:ok, de} = Sidereon.DeEphemeris.load(Path.join(__DIR__, "fixtures/de/lnxp1990.440"))
    context = PropagationContext.with_body_fixed_frame_provider(PropagationContext.new(), :tdb)
    integration = %{IntegratorOptions.default() | abs_tol: 1.0e-12, max_step: 30.0, initial_step: 1.0}
    reason = "solid Earth tide geopotential forces require a body-fixed frame provider"

    for {force_opts, golden} <- [
          {[forces: [:solid_earth_tide, :solid_earth_pole_tide]], "propagated"},
          {[additional_forces: [:solid_earth_tide]], "additional_tide"}
        ] do
      opts = [integration: integration, de_ephemeris: de] ++ force_opts
      body_opts = [context: context] ++ opts
      assert Propagator.propagate_state(initial, [target], body_opts) === {:ok, [state(expected[golden])]}
      assert {:ok, result} = Propagator.propagate_to_with_context(initial, target, body_opts)
      assert result.final_state === state(expected[golden])

      for no_provider <- [opts, Keyword.delete(opts, :de_ephemeris)] do
        assert {:error, %PropagationError{kind: :invalid_input, detail: %{reason: ^reason}}} =
                 Propagator.propagate_state(initial, [target], no_provider)

        assert {:error, %PropagationError{kind: :invalid_input, detail: %{reason: ^reason}}} =
                 Propagator.propagate_to_with_context(initial, target, no_provider)
      end
    end
  end

  test "the TDB orientation provider supplies tides to force evaluation and covariance propagation" do
    expected = CoreGolden.load("numerical_orbits.json")
    context = PropagationContext.with_body_fixed_frame_provider(PropagationContext.new(), :tdb)
    force_state = {0.0, {7000.0, -1210.0, 1300.0}, @zero}

    for {force, key} <- [solid_earth_tide: "tide_acceleration", solid_earth_pole_tide: "pole_tide_acceleration"] do
      assert Forces.acceleration(force, force_state, context: context) === {:ok, CoreGolden.tuple3(expected[key])}
    end

    de_expected = expected["de_tides"]
    {de_epoch, _, _} = de_initial = state(de_expected["initial"])
    {:ok, de} = Sidereon.DeEphemeris.load(Path.join(__DIR__, "fixtures/de/lnxp1990.440"))
    body_options = [context: context, de_ephemeris: de]

    assert Forces.acceleration(:solid_earth_tide, de_initial, body_options) ===
             {:ok, CoreGolden.tuple3(de_expected["acceleration"])}

    integration = %{IntegratorOptions.default() | abs_tol: 1.0e-12, max_step: 30.0, initial_step: 1.0}
    equations = %VariationalEquations{force: :solid_earth_tide, parameters: [], sensitivity_parameters: []}
    epoch = VariationalEpoch.from_tdb_seconds(de_epoch, de_epoch + 60.0)

    assert Propagator.propagate_variational(de_initial, [epoch], equations, body_options) ===
             {:ok,
              [
                %VariationalState{
                  state: state(de_expected["variational"]),
                  state_transition: CoreGolden.f(de_expected["stm"]),
                  sensitivity: [[], [], [], [], [], []]
                }
              ]}

    position = {7000.0, 0.0, 0.0}
    velocity = {0.0, 7.546049108166282, 0.0}
    initial = {0.0, position, velocity}
    diagonal = [1.0e-6, 2.0e-6, 3.0e-6, 1.0e-8, 2.0e-8, 3.0e-8]

    covariance =
      diagonal
      |> Enum.with_index()
      |> Enum.map(fn {value, index} -> List.replace_at(List.duplicate(0.0, 6), index, value) end)

    forces = [:solid_earth_tide, :solid_earth_pole_tide]
    legacy = [forces: forces, max_step: 30.0, initial_step: 1.0]

    nodes = covariance_nodes(expected["tide_covariance_nodes"])

    assert Propagator.propagate_covariance({position, velocity}, covariance, [60.0, 120.0], legacy) === {:ok, nodes}

    assert Propagator.propagate_covariance_with_context(
             {position, velocity},
             covariance,
             [60.0, 120.0],
             context,
             legacy
           ) ===
             {:ok, nodes}

    opts = [forces: forces, integration: integration]

    assert Propagator.state_transition_matrix_to_with_context(initial, 60.0, context, opts) ===
             {:ok, CoreGolden.f(expected["tide_stm"])}

    [target, target_covariance] = expected["tide_state_covariance"]

    assert Propagator.propagate_state_with_covariance_with_context(initial, covariance, 60.0, context, opts) ===
             {:ok, {state(target), CoreGolden.f(target_covariance)}}

    asymmetric = List.update_at(covariance, 0, &List.replace_at(&1, 1, 1.0))
    indefinite = List.update_at(covariance, 0, &List.replace_at(&1, 0, -1.0))

    malformed = [[1.0]]

    assert {:error, %PropagationError{kind: :invalid_dimensions, detail: %{reason: :invalid_dimensions}}} =
             Propagator.propagate_state_with_covariance_with_context(initial, malformed, 60.0, context, opts)

    assert {:error, %PropagationError{kind: :invalid_dimensions, detail: %{reason: :invalid_dimensions}}} =
             Propagator.propagate_covariance_with_context({position, velocity}, malformed, [60.0], context, legacy)

    assert Propagator.propagate_covariance({position, velocity}, malformed, [60.0], legacy) === {:error, :non_finite}

    for {invalid, reason} <- [
          {asymmetric, :asymmetric},
          {indefinite, :not_positive_semidefinite}
        ] do
      assert {:error, %PropagationError{kind: ^reason, detail: %{reason: ^reason}}} =
               Propagator.propagate_state_with_covariance_with_context(initial, invalid, 60.0, context, opts)

      assert Propagator.propagate_covariance({position, velocity}, invalid, [60.0], legacy) === {:error, reason}
    end

    for option <- [:force_model, :mu_km3_s2, :de_ephemeris] do
      assert {:error, %PropagationError{kind: :unsupported_option, detail: %{reason: {:unsupported_option, ^option}}}} =
               Propagator.state_transition_matrix_to_with_context(initial, 60.0, context, [{option, :unused}])
    end
  end

  test "new propagation calls return structured force selector refusals" do
    context = PropagationContext.new()
    position = {7000.0, 0.0, 0.0}
    velocity = {0.0, 7.5, 0.0}
    initial = {0.0, position, velocity}
    covariance = List.duplicate(List.duplicate(0.0, 6), 6)

    for {forces, reason, message} <- [
          {[:unrecognized], "unknown force token: unrecognized", "unknown force token: unrecognized"},
          {["srp:1.2"], "srp token must be srp:cr:area_to_mass", "srp token must be srp:cr:area_to_mass"},
          {[{:geopotential, 2, 3}], "max_order must not exceed max_degree",
           "Invalid input: max_order must not exceed max_degree"},
          {[{:solid_earth_tide, :other}], "unknown force token: {:solid_earth_tide, :other}",
           "unknown force token: {:solid_earth_tide, :other}"}
        ] do
      opts = [forces: forces]
      expected = {:error, %PropagationError{kind: :invalid_input, detail: %{reason: reason}, message: message}}

      assert Propagator.propagate_state(initial, [60.0], opts) === expected
      assert Propagator.propagate_to_with_context(initial, 60.0, opts) === expected
      assert Propagator.state_transition_matrix_to_with_context(initial, 60.0, context, opts) === expected

      assert Propagator.propagate_state_with_covariance_with_context(initial, covariance, 60.0, context, opts) ===
               expected

      assert Propagator.propagate_covariance_with_context({position, velocity}, covariance, [60.0], context, opts) ===
               expected
    end

    {:ok, drag} = Drag.from_bc_factor(0.02)
    drag = %{drag | bc_factor_m2_kg: -1.0}

    expected =
      {:error,
       %PropagationError{
         kind: :invalid_input,
         detail: %{reason: "bc_factor_m2_kg not positive"},
         message: "Invalid input: bc_factor_m2_kg not positive"
       }}

    for opts <- [[drag: drag], [additional_forces: [drag]]] do
      assert Propagator.propagate_state(initial, [60.0], opts) === expected
      assert Propagator.propagate_to_with_context(initial, 60.0, opts) === expected
    end

    opts = [forces: [:solid_earth_tide]]

    assert {:error, %PropagationError{kind: :invalid_input, detail: %{reason: reason}}} =
             Propagator.propagate_covariance_with_context({position, velocity}, covariance, [60.0], context, opts)

    assert reason === "solid Earth tide geopotential forces require a body-fixed frame provider"
  end

  test "covariance propagation preserves J2 selectors and reports force-list refusals" do
    expected = CoreGolden.load("numerical_orbits.json")
    initial = {{7000.0, 0.0, 0.0}, {0.0, 7.546049108166282, 0.0}}
    diagonal = [1.0e-6, 2.0e-6, 3.0e-6, 1.0e-8, 2.0e-8, 3.0e-8]

    covariance =
      for {value, index} <- Enum.with_index(diagonal), do: List.replace_at(List.duplicate(0.0, 6), index, value)

    epochs = [60.0, 120.0]
    integrator = [max_step: 30.0, initial_step: 1.0]

    for {forces, golden} <- [
          {[:twobody_j2], "j2_covariance_nodes"},
          {["twobody_j2"], "j2_covariance_nodes"},
          {[:j2], "j2_covariance_nodes"},
          {["twobody", "j2"], "j2_covariance_nodes"},
          {[:twobody], "covariance_nodes"},
          {[], "covariance_nodes"}
        ] do
      assert Propagator.propagate_covariance(initial, covariance, epochs, [forces: forces] ++ integrator) ===
               {:ok, covariance_nodes(expected[golden])}
    end

    for {forces, reason} <- [
          {[:unrecognized], "unknown force token: unrecognized"},
          {[:twobody, :unrecognized], "unknown force token: unrecognized"},
          {["srp:1.2"], "srp token must be srp:cr:area_to_mass"},
          {["srp:bad:0.02"], "invalid srp cr"},
          {["srp:1.2:0.02:conical:other:false"], "invalid SRP Earth shadow model"},
          {["geopotential:bad:8"], "invalid geopotential degree"},
          {[{:geopotential, 2, 3}], "Invalid input: max_order must not exceed max_degree"},
          {["solid_earth_tide:other"], "invalid solid-earth-tide system"},
          {[:earth_phase_a, :solid_earth_tide], "earth_phase_a does not accept a solid-earth-tide selector"}
        ] do
      assert Propagator.propagate_covariance(initial, covariance, epochs, forces: forces) === {:error, reason}
    end

    assert Propagator.propagate_covariance(initial, covariance, epochs, forces: [:unrecognized], integrator: :unused) ===
             {:error, :invalid_input}
  end

  defp covariance_nodes(nodes) do
    Enum.map(nodes, fn node ->
      {epoch, position, velocity} = state(node["state"])

      %{
        state: %{epoch_tdb_seconds: epoch, position_km: position, velocity_km_s: velocity},
        covariance: CoreGolden.f(node["covariance"]),
        frame: "inertial"
      }
    end)
  end

  defp geometry(expected) do
    %EcomGeometry{
      dyb: %DybAxes{
        d: CoreGolden.tuple3(expected["dyb"]["d"]),
        y: CoreGolden.tuple3(expected["dyb"]["y"]),
        b: CoreGolden.tuple3(expected["dyb"]["b"])
      },
      delta_u_rad: CoreGolden.f(expected["delta_u_rad"]),
      argument_of_latitude_rad: CoreGolden.f(expected["argument_of_latitude_rad"]),
      lighting_ratio: CoreGolden.f(expected["lighting_ratio"])
    }
  end

  defp state([epoch, position, velocity]),
    do: {CoreGolden.f(epoch), CoreGolden.tuple3(position), CoreGolden.tuple3(velocity)}
end
