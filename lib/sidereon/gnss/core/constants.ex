defmodule Sidereon.GNSS.Core.Constants do
  @moduledoc false

  alias Sidereon.Constants, as: SidereonConstants
  alias Sidereon.GNSS.IonosphereFree

  @ca_code_length 1023
  @ca_chip_rate_hz 1_023_000
  @time_scales ~w(UTC TAI TT TDB GPST GST BDT)

  def speed_of_light_m_s, do: SidereonConstants.speed_of_light_m_s()
  def earth_rotation_rate_rad_s, do: SidereonConstants.omega_e_dot_rad_s()
  def gps_l1_hz, do: frequency!("G", :l1)
  def gps_l2_hz, do: frequency!("G", :l2)
  def galileo_e1_hz, do: frequency!("E", :e1)
  def galileo_e5a_hz, do: frequency!("E", :e5a)
  def beidou_b1i_hz, do: frequency!("C", :b1i)
  def beidou_b3i_hz, do: frequency!("C", :b3i)
  def ca_code_length, do: @ca_code_length
  def ca_chip_rate_hz, do: @ca_chip_rate_hz
  def time_scales, do: @time_scales

  def carrier_frequencies_hz, do: IonosphereFree.frequencies()

  defp frequency!(system, band) do
    {:ok, frequency_hz} = IonosphereFree.frequency(system, band)
    frequency_hz
  end
end
