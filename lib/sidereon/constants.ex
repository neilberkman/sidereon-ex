defmodule Sidereon.Constants do
  @moduledoc false

  @speed_of_light_m_s 299_792_458.0
  @gm_earth_km3_s2 398_600.4418
  @wgs84_a_km 6378.137
  @wgs84_f 1.0 / 298.257_223_563
  @wgs84_e2 2.0 * (1.0 / 298.257_223_563) -
              1.0 / 298.257_223_563 * (1.0 / 298.257_223_563)
  @j2_earth 1.082_626_68e-3
  @omega_e_dot_rad_s 7.292_115_146_7e-5
  @au_km 149_597_870.700

  def speed_of_light_m_s, do: @speed_of_light_m_s
  def gm_earth_km3_s2, do: @gm_earth_km3_s2
  def wgs84_a_km, do: @wgs84_a_km
  def wgs84_f, do: @wgs84_f
  def wgs84_e2, do: @wgs84_e2
  def j2_earth, do: @j2_earth
  def omega_e_dot_rad_s, do: @omega_e_dot_rad_s
  def au_km, do: @au_km
end
