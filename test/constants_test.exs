defmodule Sidereon.ConstantsTest do
  @moduledoc """
  Drift guards: every physical constant the binding mirrors, and every solver
  default it carries, must be bit-equal to its canonical `sidereon_core` value.
  The core values are read back through `Sidereon.NIF.core_constants/0` and
  `Sidereon.NIF.core_defaults/0`, so a future edit cannot silently diverge a
  binding literal from the core.
  """
  use ExUnit.Case, async: true

  alias Sidereon.Constants

  describe "physical constants mirror the core (no drift)" do
    test "every Sidereon.Constants value is bit-equal to the core constant" do
      core = Sidereon.NIF.core_constants()

      assert Constants.speed_of_light_m_s() === core.speed_of_light_m_s
      assert Constants.gm_earth_km3_s2() === core.gm_earth_km3_s2
      assert Constants.wgs84_a_km() === core.wgs84_a_km
      assert Constants.wgs84_f() === core.wgs84_f
      assert Constants.wgs84_e2() === core.wgs84_e2
      assert Constants.j2_earth() === core.j2_earth
      assert Constants.omega_e_dot_rad_s() === core.omega_e_dot_rad_s
      assert Constants.au_km() === core.au_km
    end
  end

  describe "solver defaults mirror the core (no drift)" do
    test "RTK and Huber defaults are bit-equal to the core defaults" do
      core = Sidereon.NIF.core_defaults()

      # RTK measurement / iteration defaults (sidereon_core::rtk_filter::defaults).
      assert core.rtk_code_sigma_m === 0.3
      assert core.rtk_phase_sigma_m === 0.003
      assert core.rtk_max_iterations === 10

      # RTK convergence / integer defaults (sidereon_core::rtk_filter::defaults).
      # These mirror Sidereon.GNSS.RTK's @default_position_tolerance_m,
      # @default_ambiguity_tolerance_m, @default_integer_ratio_threshold, and
      # @default_partial_min_ambiguities.
      assert core.rtk_position_tol_m === 1.0e-4
      assert core.rtk_ambiguity_tol_m === 1.0e-4
      assert core.rtk_ratio_threshold === 3.0
      assert core.rtk_partial_min_ambiguities === 4

      # Static-PPP convergence / iteration / integer defaults
      # (sidereon_core::precise_positioning::defaults). These mirror
      # Sidereon.GNSS.PrecisePositioning's @default_position_tolerance_m,
      # @default_clock_tolerance_m, @default_ambiguity_tolerance_m,
      # @default_ztd_tolerance_m, @default_max_iterations, and
      # @default_integer_ratio_threshold.
      assert core.ppp_position_tol_m === 1.0e-4
      assert core.ppp_clock_tol_m === 1.0e-4
      assert core.ppp_ambiguity_tol_m === 1.0e-4
      assert core.ppp_ztd_tol_m === 1.0e-4
      assert core.ppp_max_iterations === 8
      assert core.ppp_ratio_threshold === 3.0

      # Robust SPP IRLS defaults (sidereon_core::positioning::DEFAULT_ROBUST_*).
      # scale-floor and max-outer mirror Sidereon.GNSS.Positioning's
      # @default_huber_sigma and @default_huber_max_iter; outer-tol has no binding
      # mirror but is pinned here so a core change surfaces in the binding.
      assert core.robust_scale_floor_m === 1.0
      assert core.robust_max_outer === 5
      assert core.robust_outer_tol_m === 1.0e-4

      # Huber constant (sidereon_core::astro::math::robust::HUBER_K).
      assert core.huber_k === 1.345
    end

    test "standard-atmosphere surface meteorology defaults are bit-equal to the core" do
      core = Sidereon.NIF.core_defaults()

      # Single binding home in Sidereon.Constants, shared by
      # Sidereon.GNSS.Positioning and Sidereon.GNSS.QC, mirroring
      # sidereon_core::positioning::SurfaceMet::default().
      assert Constants.surface_met_pressure_hpa() === core.surface_met_pressure_hpa
      assert Constants.surface_met_temperature_k() === core.surface_met_temperature_k
      assert Constants.surface_met_relative_humidity() === core.surface_met_relative_humidity

      assert core.surface_met_pressure_hpa === 1013.25
      assert core.surface_met_temperature_k === 288.15
      assert core.surface_met_relative_humidity === 0.5
    end
  end
end
