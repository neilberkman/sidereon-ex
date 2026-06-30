defmodule Sidereon.Constants do
  @moduledoc false

  # Each value below mirrors its canonical `sidereon_core` constant (see
  # `Sidereon.NIF.core_constants/0`) or default (see
  # `Sidereon.NIF.core_defaults/0`). The literals are kept for compile-time
  # ergonomics; `test/constants_test.exs` asserts every one is bit-equal to the
  # core value via the NIF, so a binding constant can never silently drift from
  # the core.

  @speed_of_light_m_s 299_792_458.0
  @gm_earth_km3_s2 398_600.4418
  @wgs84_a_km 6378.137
  @wgs84_f 1.0 / 298.257_223_563
  @wgs84_e2 2.0 * (1.0 / 298.257_223_563) -
              1.0 / 298.257_223_563 * (1.0 / 298.257_223_563)
  @j2_earth 1.082_626_68e-3
  @omega_e_dot_rad_s 7.292_115_146_7e-5
  @au_km 149_597_870.700

  # Standard-atmosphere surface meteorology, the troposphere term's fallback when
  # a caller does not supply pressure / temperature / humidity. Mirrors
  # `sidereon_core::positioning::SurfaceMet::default()` (exposed by
  # `Sidereon.NIF.core_defaults/0`); this is the single binding home shared by
  # `Sidereon.GNSS.Positioning` and `Sidereon.GNSS.QC`.
  @surface_met_pressure_hpa 1013.25
  @surface_met_temperature_k 288.15
  @surface_met_relative_humidity 0.5

  def speed_of_light_m_s, do: @speed_of_light_m_s
  def gm_earth_km3_s2, do: @gm_earth_km3_s2
  def wgs84_a_km, do: @wgs84_a_km
  def wgs84_f, do: @wgs84_f
  def wgs84_e2, do: @wgs84_e2
  def j2_earth, do: @j2_earth
  def omega_e_dot_rad_s, do: @omega_e_dot_rad_s
  def au_km, do: @au_km
  def surface_met_pressure_hpa, do: @surface_met_pressure_hpa
  def surface_met_temperature_k, do: @surface_met_temperature_k
  def surface_met_relative_humidity, do: @surface_met_relative_humidity
end
