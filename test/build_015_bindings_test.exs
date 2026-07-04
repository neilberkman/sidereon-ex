defmodule Sidereon.Build015BindingsTest do
  use ExUnit.Case, async: true

  alias Sidereon.ClockStability
  alias Sidereon.ErrorMetrics
  alias Sidereon.GeodeticTimeSeries
  alias Sidereon.GNSS.SP3
  alias Sidereon.OrbitDetermination
  alias Sidereon.Propagator
  alias Sidereon.Sidereal

  @sp3_path Path.join(__DIR__, "fixtures/sp3/GBM_BDS_C21_C08_trim.sp3")

  test "position error metrics pin isotropic CEP relative 1e-6 and non-PSD typed error" do
    sigma_m = 10.0
    covariance = [[100.0, 0.0, 0.0], [0.0, 100.0, 0.0], [0.0, 0.0, 100.0]]

    assert {:ok, metrics} = ErrorMetrics.from_enu_covariance(covariance)
    expected_cep_m = 1.177410 * sigma_m
    relative = abs(metrics.cep_m.radius_m - expected_cep_m) / expected_cep_m
    assert relative <= 1.0e-6

    non_psd = [[1.0, 2.0, 0.0], [2.0, 1.0, 0.0], [0.0, 0.0, 1.0]]
    assert {:error, :not_positive_semidefinite} = ErrorMetrics.from_enu_covariance(non_psd)
  end

  test "sidereal filter passes under-covered flags exactly" do
    assert {:ok, output} =
             Sidereal.filter([1.0, 2.0, 3.0, 4.0], 2.0,
               sample_interval_s: 1.0,
               prior_periods: 1,
               min_coverage: 2
             )

    assert output.filtered == [1.0, 2.0, 3.0, 4.0]
    assert output.template == [nil, nil]
    assert output.coverage == [1, 1]
    assert output.under_covered == [true, true]
  end

  test "geodetic MIDAS synthetic velocity matches Rust reference exactly" do
    samples =
      for year <- 0..4 do
        t = 2020.0 + year
        {t, {0.012 * year, -0.034 * year, 0.0015 * year}}
      end

    assert {:ok, velocity} = GeodeticTimeSeries.velocity_midas(samples)
    assert velocity.rate_enu_m_per_yr == {0.012, -0.034, 0.0015}
    assert velocity.sample_count == 5
    assert velocity.quality == :nominal
  end

  test "clock WhiteFM ADEV slope is exact" do
    assert ClockStability.power_law_slope(:white_fm, :adev) == -0.5
  end

  test "two-epoch sparse orbit fit reports unbounded covariance and flagged ledger" do
    sp3 = SP3.load!(@sp3_path)
    samples = SP3.precise_ephemeris_samples(sp3)
    sat = hd(samples).sat
    first_two = samples |> Enum.filter(&(&1.sat == sat)) |> Enum.take(2)

    assert {:ok, report} =
             OrbitDetermination.fit_precise_ephemeris_sample_orbit(first_two, sat,
               forces: [:twobody],
               min_ledger_samples: 3
             )

    assert [%{covariance: %{kind: :unbounded, matrix: nil}}] = report.fits
    assert report.ledger.per_sat[sat].n == 2
    assert report.ledger.per_sat[sat].low_sample_count
    assert report.ledger.per_constellation["C"].low_sample_count
  end

  test "composite forces reproduce two-body J2 bit-for-bit when extra forces are disabled" do
    state = {{7000.0, 0.0, 1300.0}, {0.0, 7.4, 1.0}}

    assert {:ok, legacy} = Propagator.propagate(state, 60.0, forces: [:twobody, :j2], tolerance: 1.0e-12)

    assert {:ok, composite} =
             Propagator.propagate(state, 60.0,
               forces: [:composite, :twobody, :j2],
               tolerance: 1.0e-12
             )

    assert composite == legacy
  end
end
