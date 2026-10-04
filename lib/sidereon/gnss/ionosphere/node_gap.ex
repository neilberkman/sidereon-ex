defmodule Sidereon.GNSS.Ionosphere.NodeGap do
  @moduledoc """
  The non-available nodes a query weights, on each bracketing map that has any.

  `earlier` is the earlier of the two maps bracketing the query epoch, or the
  only map; `later` is the later one. Either is `nil` where that map's weighted
  nodes all hold values.

  The same struct is the `degraded` status field of a value a `:renormalize`
  policy produced and the payload of the `{:nodes_not_available, node_gap}`
  refusal a `:strict` policy returns, so one match reads both.
  """

  alias Sidereon.GNSS.Ionosphere.MissingNodes

  defstruct [:earlier, :later]

  @type t :: %__MODULE__{earlier: MissingNodes.t() | nil, later: MissingNodes.t() | nil}

  @doc false
  @spec from_nif_map(map()) :: t()
  def from_nif_map(%{earlier: earlier, later: later}) do
    %__MODULE__{earlier: nodes(earlier), later: nodes(later)}
  end

  defp nodes(nil), do: nil
  defp nodes(fields), do: MissingNodes.from_nif_map(fields)
end
