defmodule Sidereon.GNSS.Ionosphere.MissingNodes do
  @moduledoc """
  The nodes of one map's interpolation cell that carry weight in a query and
  that the product gives as non-available.

  A node carries weight when its bilinear weight is nonzero, so a query sitting
  on a node, or on the edge between two, uses only the nodes it lies on.

  `map_number` counts from 1 as a file numbers its maps. `lat_index`,
  `lon_index` and `lon_index_next` are positions in the node axes, which count
  from 0. Within the grid `lon_index_next` is `lon_index + 1`; on the cell that
  closes the longitude circle it is `0`, because an axis such as 0 to 355 by 5
  covers every longitude without naming the seam twice. The latitude axis does
  not wrap, so the cell's other row is always `lat_index + 1`.

  `missing` is the four corners in the order
  `[lat_index][lon_index]`, `[lat_index][lon_index_next]`,
  `[lat_index + 1][lon_index]`, `[lat_index + 1][lon_index_next]`.

  This is the payload of both the `degraded` status field and the
  `{:nodes_not_available, node_gap}` refusal, on the IONEX slant surface and on
  `Sidereon.GNSS.Ionosphere.TecGrid`, carried inside a
  `Sidereon.GNSS.Ionosphere.NodeGap`.
  """

  @enforce_keys [:map_number, :lat_index, :lon_index, :lon_index_next, :missing]
  defstruct [:map_number, :lat_index, :lon_index, :lon_index_next, :missing]

  @type t :: %__MODULE__{
          map_number: pos_integer(),
          lat_index: non_neg_integer(),
          lon_index: non_neg_integer(),
          lon_index_next: non_neg_integer(),
          missing: [boolean()]
        }

  @doc false
  @spec from_nif_map(map()) :: t()
  def from_nif_map(fields) when is_map(fields), do: struct!(__MODULE__, fields)
end
