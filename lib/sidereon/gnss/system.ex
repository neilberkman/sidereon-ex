defmodule Sidereon.GNSS.System do
  @moduledoc false

  def identity(system) when is_atom(system) or is_binary(system) do
    Sidereon.NIF.data_gnss_system(to_string(system))
  end

  def identity(_system), do: {:error, "unsupported_system"}

  def letter(system) do
    case identity(system) do
      {:ok, letter, _name} -> {:ok, letter}
      error -> error
    end
  end
end
