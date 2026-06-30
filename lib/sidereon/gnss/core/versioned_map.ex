defmodule Sidereon.GNSS.Core.VersionedMap do
  @moduledoc false

  def require_numeric(map, keys) when is_map(map) do
    if Enum.all?(keys, fn key -> is_number(Map.get(map, key)) end), do: :ok, else: :error
  end

  def require_numeric(_map, _keys), do: :error
end
