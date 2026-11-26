defmodule Sidereon.OrbitParameterFitTest do
  use ExUnit.Case, async: true

  alias Sidereon.Forces.Ecom1Coefficients
  alias Sidereon.Forces.Ecom1SolarRadiationPressure
  alias Sidereon.Forces.Ecom2SolarRadiationPressure
  alias Sidereon.Forces.EmpiricalRtnAcceleration
  alias Sidereon.Forces.SolarRadiationPressure
  alias Sidereon.GNSS.SP3
  alias Sidereon.Iers2010EarthOrientationProvider, as: Iers
  alias Sidereon.Iers2010EarthOrientationProvider.Iers2010EopSample
  alias Sidereon.OrbitDetermination.OrbitResidualStats
  alias Sidereon.OrbitDetermination.Parameters
  alias Sidereon.OrbitDetermination.Parameters.EstimatedForceParameter
  alias Sidereon.OrbitDetermination.Parameters.InertialPositionSample
  alias Sidereon.OrbitDetermination.Parameters.OrbitParameterCovariance
  alias Sidereon.OrbitDetermination.Parameters.OrbitParameterFit
  alias Sidereon.OrbitDetermination.Parameters.OrbitParameterFitError
  alias Sidereon.OrbitDetermination.Parameters.OrbitParameterFitOptions
  alias Sidereon.OrbitDetermination.Parameters.OrbitRtnResidual
  alias Sidereon.Propagator.IntegratorOptions
  alias Sidereon.Propagator.PropagationContext
  alias Sidereon.Propagator.VariationalEpoch
  alias Sidereon.Test.CoreGolden

  @parameter "empirical.radial.constant"
  @reference Path.expand("fixtures/sp3/GBM0MGXRAP_20201770000_01D_05M_ORB_73epoch.sp3", __DIR__)

  test "fit estimates the GCRF initial state and an empirical coefficient in one batch" do
    expected = CoreGolden.load("orbit_assessment.json")["fit"]

    samples = samples(expected)
    options = fit_options()

    assert {:ok, %OrbitParameterFit{} = fit} =
             Parameters.fit_inertial_orbit_parameters(samples, "G01", options: options)

    [epoch, pos, vel] = expected["initial_state"]
    assert fit.satellite == "G01"
    assert fit.initial_state === {CoreGolden.f(epoch), CoreGolden.tuple3(pos), CoreGolden.tuple3(vel)}
    assert fit.parameter_names === expected["names"]
    assert fit.condition_number === CoreGolden.f(expected["condition_number"])
    assert Parameters.state_parameter_names() == ~w(x_km y_km z_km vx_km_s vy_km_s vz_km_s)

    assert OrbitParameterFit.force_parameter(fit, @parameter) === %EstimatedForceParameter{
             name: @parameter,
             initial_value: 1.0e-8,
             value: CoreGolden.f(expected["force_parameter"])
           }

    covariance = expected["covariance"]

    assert fit.covariance === %OrbitParameterCovariance{
             kind: :estimated,
             degrees_of_freedom: covariance["degrees_of_freedom"],
             matrix: CoreGolden.f(covariance["matrix"]),
             correlation: CoreGolden.f(covariance["correlation"]),
             variance_factor: CoreGolden.f(covariance["variance_factor"])
           }

    assert fit.residuals ===
             Enum.map(expected["residuals"], fn row ->
               [epoch, elapsed, radial, along, cross] = CoreGolden.f(row)

               %OrbitRtnResidual{
                 epoch_tdb_j2000_s: epoch,
                 elapsed_tt_s: elapsed,
                 radial_m: radial,
                 along_m: along,
                 cross_m: cross
               }
             end)

    [radial, along, cross, rms] = CoreGolden.f(expected["residual_stats"])

    assert fit.residual_stats === %OrbitResidualStats{
             n: 7,
             low_sample_count: false,
             radial_rms_m: radial,
             along_rms_m: along,
             cross_rms_m: cross,
             rms_3d_m: rms
           }

    assert fit.sigmas === CoreGolden.f(expected["sigmas"])
    assert OrbitParameterFit.sigma(fit, "x_km") === CoreGolden.f(hd(expected["sigmas"]))
    assert fit.seed_rms_3d_m === CoreGolden.f(expected["seed_rms_3d_m"])
    assert fit.iterations === expected["iterations"]
    [first_correlation | _] = hd(expected["covariance"]["correlation"])
    assert OrbitParameterFit.correlation(fit, "x_km", "x_km") === CoreGolden.f(first_correlation)
    off_diagonal = expected["covariance"]["correlation"] |> hd() |> Enum.at(1)
    assert OrbitParameterFit.correlation(fit, "x_km", "y_km") === CoreGolden.f(off_diagonal)
    assert OrbitParameterFit.correlation(fit, @parameter, @parameter) === 1.0
    assert OrbitParameterFit.sigma(fit, "unlisted") == nil
    assert [first | _rest] = fit.residuals

    assert OrbitRtnResidual.variational_epoch(first) === %VariationalEpoch{
             tdb_j2000_s: CoreGolden.f(epoch),
             elapsed_tt_s: 0.0
           }

    assert Parameters.fit_inertial_orbit_parameters_with_validity(samples, "G01", :permissive, options: options) ===
             {:ok, {fit, nil}}
  end

  test "fit validation preserves the satellite and rejected name" do
    assert {:error,
            %OrbitParameterFitError{
              kind: :fit,
              detail: %{error: %{kind: :too_few_samples, detail: %{satellite: "G01", got: 0, required: 2}}}
            } = error} = Parameters.fit_inertial_orbit_parameters([], "G01")

    assert to_string(error) === "satellite G01 has 0 samples; need at least 2"

    product = SP3.load!(@reference)
    options = %OrbitParameterFitOptions{estimated_parameters: ["unlisted"]}
    detail = %{name: "unlisted", reason: "is not a parameter of the force models"}

    assert {:error, %OrbitParameterFitError{kind: :invalid_parameter, detail: ^detail}} =
             Parameters.fit_sp3_ecef_orbit_parameters(product, "G01", options: options)

    assert {:error, %OrbitParameterFitError{kind: :invalid_parameter, detail: ^detail}} =
             Parameters.fit_sp3_ecef_orbit_parameters_with_validity(product, "G01", :permissive, options: options)
  end

  test "Earth-fixed SP3 fitting returns the GCRF state and post-fit RMS" do
    expected = CoreGolden.load("orbit_assessment.json")["sp3_fit"]
    product = SP3.load!(@reference)
    assert {:ok, %OrbitParameterFit{} = fit} = Parameters.fit_sp3_ecef_orbit_parameters(product, "G01")

    [epoch, position, velocity] = expected["initial_state"]
    assert fit.initial_state === {CoreGolden.f(epoch), CoreGolden.tuple3(position), CoreGolden.tuple3(velocity)}
    assert fit.condition_number === CoreGolden.f(expected["condition_number"])
    assert fit.iterations == expected["iterations"]
    assert fit.residual_stats.rms_3d_m === CoreGolden.f(expected["rms_3d_m"])

    assert Parameters.fit_sp3_ecef_orbit_parameters_with_validity(product, "G01", :strict) === {:ok, {fit, nil}}
  end

  test "both fits return structured refusals for invalid force and drag options" do
    product = SP3.load!(@reference)
    assert {:ok, drag} = Sidereon.Drag.from_bc_factor(0.02)
    drag = %{drag | bc_factor_m2_kg: -1.0}

    for {options, reason, message} <- [
          {%OrbitParameterFitOptions{forces: [:unrecognized]}, "unknown force token: unrecognized",
           "unknown force token: unrecognized"},
          {%OrbitParameterFitOptions{forces: ["srp:1.2"]}, "srp token must be srp:cr:area_to_mass",
           "srp token must be srp:cr:area_to_mass"},
          {%OrbitParameterFitOptions{forces: [{:geopotential, 2, 3}]}, "max_order must not exceed max_degree",
           "Invalid input: max_order must not exceed max_degree"},
          {%OrbitParameterFitOptions{drag: drag}, "bc_factor_m2_kg not positive",
           "Invalid input: bc_factor_m2_kg not positive"}
        ] do
      expected = {:error, %OrbitParameterFitError{kind: :invalid_input, detail: %{reason: reason}, message: message}}
      assert Parameters.fit_inertial_orbit_parameters([], "G01", options: options) === expected
      assert Parameters.fit_sp3_ecef_orbit_parameters(product, "G01", options: options) === expected
    end

    options = %OrbitParameterFitOptions{additional_forces: [drag]}

    expected =
      {:error,
       %OrbitParameterFitError{
         kind: :invalid_input,
         detail: %{reason: "bc_factor_m2_kg not positive"},
         message: "Invalid input: bc_factor_m2_kg not positive"
       }}

    assert Parameters.fit_inertial_orbit_parameters([], "G01", options: options) === expected
    assert Parameters.fit_sp3_ecef_orbit_parameters(product, "G01", options: options) === expected
  end

  test "ill-conditioned normal equations return the weakest combination and requested limit" do
    fixture = CoreGolden.load("orbit_assessment.json")
    expected = fixture["ill_conditioned"]
    options = %{fit_options() | max_condition_number: 1.5}

    assert {:error, %OrbitParameterFitError{kind: :ill_conditioned_normal_equations, detail: detail}} =
             Parameters.fit_inertial_orbit_parameters(samples(fixture["fit"]), "G01", options: options)

    assert detail === %{
             satellite: "G01",
             condition_number: CoreGolden.f(expected["condition_number"]),
             limit: 1.5,
             weakest: Enum.map(expected["weakest"], fn [name, value] -> {name, CoreGolden.f(value)} end)
           }
  end

  test "an exhausted fit returns its last step in formal standard deviations" do
    fixture = CoreGolden.load("orbit_assessment.json")
    expected = fixture["no_convergence"]
    options = %{fit_options() | max_iterations: 1}

    assert {:error, %OrbitParameterFitError{kind: :did_not_converge, detail: detail}} =
             Parameters.fit_inertial_orbit_parameters(samples(fixture["fit"]), "G01", options: options)

    assert detail === %{satellite: "G01", iterations: 1, last_step_sigmas: CoreGolden.f(expected["last_step_sigmas"])}
  end

  test "an estimated force parameter with a zero observation derivative is refused" do
    expected = CoreGolden.load("orbit_assessment.json")["fit"]
    assert {:ok, srp} = SolarRadiationPressure.new(1.3, CoreGolden.f("0x0000000000000001"))
    opts = %{fit_options() | additional_forces: [srp], estimated_parameters: ["srp.cr"]}

    assert {:error, %OrbitParameterFitError{kind: :unobservable_parameter, detail: %{satellite: "G01", name: "srp.cr"}}} =
             Parameters.fit_inertial_orbit_parameters(samples(expected), "G01", options: opts)
  end

  test "collinear radiation parameters report singular normal equations" do
    fixture = CoreGolden.load("orbit_assessment.json")
    expected = fixture["singular"]
    assert {:ok, first} = Ecom1SolarRadiationPressure.new(%Ecom1Coefficients{})
    assert {:ok, second} = Ecom2SolarRadiationPressure.new(0, 0, [0.0, 0.0, 0.0])
    options = %{fit_options() | additional_forces: [first, second], estimated_parameters: ~w(ecom1.d0 ecom2.d0)}

    assert {:error, %OrbitParameterFitError{kind: :singular_normal_equations, detail: details}} =
             Parameters.fit_inertial_orbit_parameters(samples(fixture["fit"]), "G01", options: options)

    assert details === %{
             satellite: "G01",
             condition_number: CoreGolden.f(expected["condition_number"]),
             weakest: Enum.map(expected["weakest"], fn [name, value] -> {name, CoreGolden.f(value)} end)
           }
  end

  test "a variance factor outside binary64 is refused with its quantity" do
    fixture = CoreGolden.load("orbit_assessment.json")
    options = %{fit_options() | observation_sigma_m: 1.0e-200, convergence_threshold: 1.0e300}

    assert {:error,
            %OrbitParameterFitError{kind: :numerical_failure, detail: %{satellite: "G01", quantity: "variance factor"}}} =
             Parameters.fit_inertial_orbit_parameters(samples(fixture["fit"]), "G01", options: options)
  end

  test "a fit with exactly six residual components has unbounded covariance" do
    expected = CoreGolden.load("orbit_assessment.json")["fit"]
    options = %OrbitParameterFitOptions{forces: [:twobody]}
    [first, second | _] = samples(expected)

    assert {:ok, fit} = Parameters.fit_inertial_orbit_parameters([first, second], "G01", options: options)
    assert fit.covariance === %OrbitParameterCovariance{kind: :unbounded}
    assert fit.sigmas === [nil, nil, nil, nil, nil, nil]
    assert OrbitParameterFit.sigma(fit, "x_km") === nil
    assert OrbitParameterFit.correlation(fit, "x_km", "y_km") === nil
  end

  test "radial fit geometry preserves the refusal reason" do
    fixture = CoreGolden.load("orbit_assessment.json")
    [epoch, position, velocity] = fixture["radial_seed"]

    samples = [
      %InertialPositionSample{
        epoch: %{time_scale: "TDB", nanos_since_j2000: 0},
        position_gcrf_m: {7_000_000.0, 0.0, 0.0}
      },
      %InertialPositionSample{
        epoch: %{time_scale: "TDB", nanos_since_j2000: 1_000_000_000},
        position_gcrf_m: CoreGolden.tuple3(fixture["radial_position_1s_m"])
      }
    ]

    initial = {CoreGolden.f(epoch), CoreGolden.tuple3(position), CoreGolden.tuple3(velocity)}
    options = %OrbitParameterFitOptions{forces: [:twobody], convergence_threshold: 1.0e10}

    assert_fit_error(
      Parameters.fit_inertial_orbit_parameters(samples, "G01", options: options, initial_state: initial),
      :rtn_frame,
      %{satellite: "G01", reason: :parallel_position_velocity}
    )
  end

  test "nested fit refusals preserve option, epoch, propagation and orientation details" do
    expected = CoreGolden.load("orbit_assessment.json")["fit"]
    [first | _] = samples = samples(expected)
    options = fit_options()
    [epoch | _] = expected["initial_state"]
    seed = {CoreGolden.f(epoch), {7000.0, 0.0, 0.0}, {0.0, 7.5, 1.0}}

    assert_fit_error(
      Parameters.fit_inertial_orbit_parameters(samples, "G01", options: %{options | observation_sigma_m: 0.0}),
      :invalid_option,
      %{field: "observation_sigma_m", reason: "not finite and positive"}
    )

    assert_fit_error(
      Parameters.fit_inertial_orbit_parameters([first, first], "G01", options: options),
      :non_monotonic_epochs,
      %{satellite: "G01"}
    )

    assert_fit_error(
      Parameters.fit_inertial_orbit_parameters(samples, "G01", options: options, initial_state: put_elem(seed, 0, 1.0)),
      :invalid_epoch,
      %{satellite: "G01", reason: "initial-state seed epoch must match the first sample"}
    )

    integration = %{IntegratorOptions.default() | max_steps: 0}

    assert_fit_error(
      Parameters.fit_inertial_orbit_parameters(samples, "G01",
        options: %{options | integrator_options: integration},
        initial_state: seed
      ),
      :propagation,
      %{satellite: "G01", source: %{kind: :max_steps_exceeded, detail: %{}}}
    )

    sample = %Iers2010EopSample{
      mjd_utc: 59_020,
      xp_arcsec: 0.0,
      yp_arcsec: 0.0,
      ut1_minus_utc_s: 0.0,
      lod_s: 0.0,
      dx_arcsec: 0.0,
      dy_arcsec: 0.0
    }

    assert {:ok, iers} = Iers.new([sample, %{sample | mjd_utc: 59_021}])
    product = SP3.load!(@reference)

    assert_fit_error(
      Parameters.fit_sp3_ecef_orbit_parameters(product, "G01", orientation_provider: iers),
      :frame,
      %{satellite: "G01", source: %{kind: :ut1_outside_coverage, detail: %{reason: :after_coverage}}}
    )

    assert_fit_error(
      Parameters.fit_sp3_ecef_orbit_parameters(product, "G01",
        orientation_provider: Iers.with_validity(iers, :permissive)
      ),
      :ut1_validity_mismatch,
      %{fit: :strict, provider: :orientation, provider_mode: :permissive}
    )
  end

  test "fit uses default options from the core and reports departures from the fallback UT1 table" do
    expected = CoreGolden.load("orbit_assessment.json")
    product = SP3.load!(@reference)
    defaults = expected["fit_defaults"]

    explicit = %OrbitParameterFitOptions{
      forces: [:earth_phase_a],
      integrator: :dp54,
      observation_sigma_m: CoreGolden.f(defaults["observation_sigma_m"]),
      max_iterations: defaults["max_iterations"],
      convergence_threshold: CoreGolden.f(defaults["convergence_threshold"]),
      max_condition_number: CoreGolden.f(defaults["max_condition_number"]),
      min_ledger_samples: defaults["min_ledger_samples"]
    }

    expected_fit = expected["sp3_fit"]
    [epoch, position, velocity] = expected_fit["initial_state"]
    initial = {CoreGolden.f(epoch), CoreGolden.tuple3(position), CoreGolden.tuple3(velocity)}

    for options <- [%OrbitParameterFitOptions{}, explicit] do
      assert {:ok, fit} = Parameters.fit_sp3_ecef_orbit_parameters(product, "G01", options: options)
      assert fit.initial_state === initial
      assert fit.iterations === expected_fit["iterations"]
      assert fit.condition_number === CoreGolden.f(expected_fit["condition_number"])
    end

    tide_options = %OrbitParameterFitOptions{forces: [:solid_earth_tide]}

    assert_fit_error(
      Parameters.fit_inertial_orbit_parameters(samples(expected["fit"]), "G01", options: tide_options),
      :propagation,
      %{
        satellite: "G01",
        source: %{
          kind: :invalid_input,
          detail: %{reason: "solid Earth tide geopotential forces require a body-fixed frame provider"}
        }
      }
    )

    assert {:ok, drag} = Sidereon.Drag.from_bc_factor(0.02)

    options = %OrbitParameterFitOptions{
      forces: [:twobody],
      drag: drag,
      propagation_context: PropagationContext.new()
    }

    samples =
      Enum.map(expected["late_fit_samples"], fn [nanos, pos] ->
        %InertialPositionSample{
          epoch: %{time_scale: "TDB", nanos_since_j2000: nanos},
          position_gcrf_m: CoreGolden.tuple3(pos)
        }
      end)

    assert_fit_error(
      Parameters.fit_inertial_orbit_parameters(samples, "G01", options: options),
      :ut1_outside_coverage,
      %{reason: :after_coverage}
    )
  end

  test "a permissive fit uses a TDB tide provider with matching validity" do
    expected = CoreGolden.load("orbit_assessment.json")
    samples = samples(expected["fit"])
    base = PropagationContext.new()

    for context <- [
          PropagationContext.with_body_fixed_frame_provider(base, :tdb),
          PropagationContext.with_body_fixed_frame_provider(base, :tdb, :strict)
        ] do
      options = %OrbitParameterFitOptions{forces: [:solid_earth_tide], propagation_context: context}

      assert_fit_error(
        Parameters.fit_inertial_orbit_parameters_with_validity(samples, "G01", :permissive, options: options),
        :ut1_validity_mismatch,
        %{fit: :permissive, provider: :propagation, provider_mode: :strict}
      )
    end

    context = PropagationContext.with_body_fixed_frame_provider(base, :tdb, :permissive)
    options = %OrbitParameterFitOptions{forces: [:solid_earth_tide], propagation_context: context}

    assert {:ok, {fit, nil}} =
             Parameters.fit_inertial_orbit_parameters_with_validity(samples, "G01", :permissive, options: options)

    expected = expected["permissive_tide_fit"]
    [epoch, position, velocity] = expected["initial_state"]
    assert fit.initial_state === {CoreGolden.f(epoch), CoreGolden.tuple3(position), CoreGolden.tuple3(velocity)}
    assert fit.condition_number === CoreGolden.f(expected["condition_number"])
    assert fit.iterations === expected["iterations"]
  end

  defp assert_fit_error({:error, %OrbitParameterFitError{kind: :fit, detail: %{error: error}}}, kind, expected) do
    assert error.kind === kind

    if kind == :non_monotonic_epochs do
      assert error.message === "satellite G01 sample epochs are not strictly increasing"
    end

    detail =
      case error.detail do
        %{source: %{kind: _, detail: _} = source} -> %{error.detail | source: Map.take(source, [:kind, :detail])}
        detail -> detail
      end

    assert detail === expected
  end

  defp samples(expected) do
    Enum.map(expected["samples"], fn [epoch, position] ->
      %InertialPositionSample{
        epoch: %{time_scale: "TDB", nanos_since_j2000: epoch},
        position_gcrf_m: CoreGolden.tuple3(position)
      }
    end)
  end

  defp fit_options do
    {:ok, acceleration} =
      EmpiricalRtnAcceleration.with_term(EmpiricalRtnAcceleration.new(), :radial, :constant, 1.0e-8)

    %OrbitParameterFitOptions{forces: [:twobody], additional_forces: [acceleration], estimated_parameters: [@parameter]}
  end
end
