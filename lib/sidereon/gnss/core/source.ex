defmodule Sidereon.GNSS.Core.Source do
  @moduledoc false

  def same_time_scale(%{time_scale: model_scale}, %{time_scale: source_scale}) do
    if model_scale == source_scale,
      do: :ok,
      else: {:error, {:time_scale_mismatch, model_scale, source_scale}}
  end
end
