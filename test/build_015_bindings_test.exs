defmodule Sidereon.Build015BindingsTest do
  use ExUnit.Case, async: true

  alias Sidereon.ClockStability
  alias Sidereon.ErrorMetrics
  alias Sidereon.GeodeticTimeSeries
  alias Sidereon.GNSS.ARAIM
  alias Sidereon.GNSS.SBAS
  alias Sidereon.GNSS.SBAS.{ProtectionGeometry, ProtectionRow, SbasErrorModel, SbasKMultipliers, SbasSisError}
  alias Sidereon.GNSS.SP3
  alias Sidereon.OrbitDetermination
  alias Sidereon.Propagator
  alias Sidereon.Reliability
  alias Sidereon.Reliability.RangeReliabilityRow
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

  test "Baarda W-test constants pin delta0 and lambda0" do
    assert {:ok, %{delta0: delta0, lambda0: lambda0}} = Reliability.wtest_noncentrality(0.001, 0.80)

    assert abs(delta0 - 4.132147965064809) / 4.132147965064809 <= 1.0e-14
    assert abs(lambda0 - delta0 * delta0) / lambda0 <= 1.0e-15
  end

  test "reliability design sums redundancy and preserves nil uncheckable fields" do
    rows = [
      RangeReliabilityRow.new("r1", [1.0, 0.3, -0.2], 0.9),
      RangeReliabilityRow.new("r2", [0.2, 1.1, 0.4], 1.1),
      RangeReliabilityRow.new("r3", [-0.5, 0.7, 1.0], 1.3),
      RangeReliabilityRow.new("r4", [1.2, -0.4, 0.6], 0.8),
      RangeReliabilityRow.new("r5", [-0.7, -0.9, 0.3], 1.5),
      RangeReliabilityRow.new("r6", [0.4, -0.2, -1.1], 1.2)
    ]

    assert {:ok, report} = Reliability.reliability_design(rows, lambda0_override: 17.075)
    assert abs(report.summary.sum_redundancy - report.summary.dof) <= 2.0e-14
    assert Enum.all?(report.per_observation, &(&1.redundancy >= 0.0 and &1.redundancy <= 1.0))

    saturated = [RangeReliabilityRow.new("z1", [1.0], 1.0)]
    assert {:ok, saturated_report} = Reliability.reliability_design(saturated)
    assert saturated_report.summary.sum_redundancy == 0.0
    assert saturated_report.summary.n_uncheckable == 1

    assert [
             %Reliability.ObservationReliability{
               uncheckable: true,
               mdb_m: nil,
               external_enu_m: nil,
               bias_to_noise: nil
             }
           ] = saturated_report.per_observation
  end

  test "reliability ARAIM returns geometry-aligned observations" do
    geometry = araim_reliability_geometry()

    default_sat =
      ARAIM.SatelliteIsmModel.new(1.0, 1.0, 0.0, 1.0e-5,
        effective_sigma_int_m: 1.0,
        effective_sigma_acc_m: 1.0
      )

    ism = ARAIM.Ism.new([ARAIM.ConstellationIsm.new(:gps, 1.0e-4, default_sat)])

    assert {:ok, report} = Reliability.reliability_araim(geometry, ism, lambda0_override: 17.075)
    assert Enum.map(report.per_observation, & &1.id) == ["G01", "G02", "G03", "G04", "G05"]
    assert abs(report.summary.sum_redundancy - report.summary.dof) <= 2.0e-13
    assert Enum.all?(report.per_observation, &match?({_east, _north, _up}, &1.external_enu_m))
  end

  test "SBAS K multipliers and fixed protection levels match core reference" do
    assert %SbasKMultipliers{k_h: 6.0, k_v: 5.33} = SbasKMultipliers.precision_approach()
    assert %SbasKMultipliers{k_h: 6.18, k_v: 5.33} = SbasKMultipliers.en_route_npa()

    geometry = sbas_pl_geometry()

    model =
      SbasErrorModel.new([
        SbasSisError.new("G01", 0.8, 0.3, 0.41, 0.12),
        SbasSisError.new("G02", 0.9, 0.25, 0.39, 0.14),
        SbasSisError.new("G03", 0.75, 0.35, 0.37, 0.11),
        SbasSisError.new("G04", 0.85, 0.28, 0.40, 0.13),
        SbasSisError.new("G05", 1.1, 0.45, 0.42, 0.15)
      ])

    assert {:ok, protection} =
             SBAS.sbas_protection_levels(geometry, model, SbasKMultipliers.en_route_npa())

    assert abs(protection.hpl_m - 5.168422057397793) / 5.168422057397793 <= 1.0e-12
    assert abs(protection.vpl_m - 4.103813573161629) / 4.103813573161629 <= 1.0e-12
  end

  defp sbas_pl_geometry do
    rows =
      fixed_los_vectors()
      |> Enum.with_index(1)
      |> Enum.map(fn {los, idx} ->
        ProtectionRow.new("G#{String.pad_leading(Integer.to_string(idx), 2, "0")}", los, 0.8, :gps)
      end)

    ProtectionGeometry.new(rows, {0.5, 0.2, 0.0}, [:gps])
  end

  defp araim_reliability_geometry do
    rows =
      fixed_los_vectors()
      |> Enum.with_index(1)
      |> Enum.map(fn {los, idx} ->
        ARAIM.Row.new("G#{String.pad_leading(Integer.to_string(idx), 2, "0")}", los, 0.8, :gps)
      end)

    ARAIM.Geometry.new(rows, {0.5, 0.2, 0.0}, [:gps])
  end

  defp fixed_los_vectors do
    inv_sqrt_3 = 0.5773502691896258

    [
      {inv_sqrt_3, inv_sqrt_3, inv_sqrt_3},
      {inv_sqrt_3, -inv_sqrt_3, -inv_sqrt_3},
      {-inv_sqrt_3, inv_sqrt_3, -inv_sqrt_3},
      {-inv_sqrt_3, -inv_sqrt_3, inv_sqrt_3},
      {0.2, 0.6, 0.7745966692414834}
    ]
  end
end
