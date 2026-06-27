defmodule Sidereon.Nx.RF do
  @moduledoc """
  Tensorized RF helpers for large access and coverage studies.
  """

  import Nx.Defn

  @doc """
  Batch free-space path loss in dB.

  Formula:
      32.45 + 20 log10(f_MHz) + 20 log10(d_km)
  """
  defn fspl(range_km, frequency_mhz) do
    32.45 + 20.0 * Nx.log10(frequency_mhz) + 20.0 * Nx.log10(range_km)
  end

  @doc """
  Batch link-margin calculation with broadcastable scalar/tensor inputs.

  Required keys:
  - `:eirp_dbw`
  - `:fspl_db`
  - `:receiver_gt_dbk`
  - `:other_losses_db`
  - `:required_cn0_dbhz`
  """
  defn link_margin(%{
         eirp_dbw: eirp_dbw,
         fspl_db: fspl_db,
         receiver_gt_dbk: gt,
         other_losses_db: losses,
         required_cn0_dbhz: required
       }) do
    eirp_dbw + gt - fspl_db + 228.6 - losses - required
  end
end
