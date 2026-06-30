defmodule Sidereon.GNSS.Core.Validation do
  @moduledoc false

  alias Sidereon.GNSS.Core.Constants

  def cadence(c) when is_number(c) and c > 0, do: {:ok, c / 1.0}
  def cadence(_), do: {:error, :invalid_cadence}

  def threshold(:infinity), do: {:ok, 1.0e308}
  def threshold(t) when is_number(t) and t >= 0, do: {:ok, t / 1.0}
  def threshold(_), do: {:error, :invalid_threshold}

  def time_scale(scale) when is_binary(scale) do
    if scale in Constants.time_scales(), do: {:ok, scale}, else: :error
  end

  def time_scale(_), do: :error
end
