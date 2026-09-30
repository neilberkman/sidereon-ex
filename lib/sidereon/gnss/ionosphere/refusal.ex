defmodule Sidereon.GNSS.Ionosphere.Refusal do
  @moduledoc false

  # The one place a refusal the NIF names is given its public payload struct.
  #
  # The boundary encodes a node gap and a height-map node as plain maps, because
  # a Rust struct crosses as a map. Every path that can return one - the scalar
  # slant delay, the policy evaluation, each batch row and the standalone TEC
  # grid query - converts through here, so the same refusal reads the same way
  # whichever call produced it. A reason this function does not name is returned
  # as it arrived rather than restated as one it does.

  alias Sidereon.GNSS.Ionosphere.HeightNode
  alias Sidereon.GNSS.Ionosphere.NodeGap

  @spec from_nif(term()) :: term()
  def from_nif({:nodes_not_available, gap}) when is_map(gap) do
    {:nodes_not_available, NodeGap.from_nif_map(gap)}
  end

  def from_nif({:varying_heights, node}) when is_map(node) do
    {:varying_heights, HeightNode.from_nif_map(node)}
  end

  def from_nif({:height_not_available, node}) when is_map(node) do
    {:height_not_available, HeightNode.from_nif_map(node)}
  end

  def from_nif(reason), do: reason

  @doc false
  @spec error(term()) :: {:error, term()}
  def error(reason), do: {:error, from_nif(reason)}
end
