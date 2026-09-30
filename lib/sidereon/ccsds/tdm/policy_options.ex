defmodule Sidereon.CCSDS.TDM.PolicyOptions do
  @moduledoc false

  # The one place a TDM reader or writer policy is read from caller options.
  #
  # Both policies are a set of axes, each `:strict` or `:forgive`. A key left
  # out takes `:strict`. Nothing falls back to a default for a name it does not
  # recognize: an unknown key, a key stated twice and a choice that is neither
  # atom are each refused by name, and no atom is created for anything a caller
  # passed.

  @choices [:strict, :forgive]

  @doc false
  @spec build(module(), [atom()], term()) :: {:ok, struct()} | {:error, term()}
  def build(module, keys, %{__struct__: module} = policy), do: validate(module, keys, Map.from_struct(policy))

  def build(module, keys, opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      case Keyword.keys(opts) -- Enum.uniq(Keyword.keys(opts)) do
        [] -> validate(module, keys, Map.new(opts))
        [key | _rest] -> {:error, {:duplicate_policy_key, key}}
      end
    else
      {:error, :bad_tdm_policy}
    end
  end

  def build(module, keys, opts) when is_map(opts) and not is_struct(opts), do: validate(module, keys, opts)

  def build(_module, _keys, _other), do: {:error, :bad_tdm_policy}

  @doc false
  @spec to_nif_map(struct()) :: map()
  def to_nif_map(policy), do: Map.from_struct(policy)

  defp validate(module, keys, opts) do
    case Enum.reject(Map.keys(opts), &(&1 in keys)) do
      [] -> choices(module, keys, opts)
      [key | _rest] -> {:error, {:unknown_policy_key, key}}
    end
  end

  defp choices(module, keys, opts) do
    Enum.reduce_while(keys, {:ok, struct(module)}, fn key, {:ok, policy} ->
      case Map.get(opts, key, :strict) do
        value when value in @choices -> {:cont, {:ok, Map.put(policy, key, value)}}
        value -> {:halt, {:error, {:invalid_policy_value, key, value}}}
      end
    end)
  end
end
